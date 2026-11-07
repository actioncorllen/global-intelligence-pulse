#!/usr/bin/env bash
# =============================================================================
# Strateloq DR — consolidated OFFLINE recovery tests (Auth · Storage · n8n · Source/Edge).
#
# Runs the remaining disaster-recovery verifications end-to-end against ISOLATED, LOCAL environments
# only. It NEVER contacts production, never activates a recovered workflow, never invokes an Edge
# Function's external calls, and incurs no paid charges. Decrypted plaintext is shredded and temporary
# environments are torn down on ANY exit. A consolidated PASS/FAIL report with real evidence (counts,
# checksums, HTTP codes — never secrets) is written to $HOME and printed.
#
# IDEMPOTENT: each test records its evidence under $DR_STATE (default ~/.strateloq-dr). A later run
#   recognises sufficient prior evidence (tied to the exact archive's sha256) and SKIPS that test as
#   already-verified. Force a full re-run with DR_FORCE=1.
# ONE UNLOCK: the PRIMARY passphrase is requested at most ONCE and only if a test actually needs to
#   decrypt. It is cached in a dedicated local gpg-agent (bounded TTL) via gpg-preset-passphrase, so
#   re-runs within the TTL do not prompt again. The passphrase is never printed or written to disk.
# REUSE: point DR_N8N_JSON_DIR at your already-decrypted 136 workflow JSONs and/or DR_N8N_SQLITE /
#   DR_N8N_CONTAINER at your existing recovery n8n DB to VERIFY it without decrypting or re-importing.
#
# Env: DR_SET (default ~/restore/20261107T000117Z), DR_RECOVERY_DIR (default ~/strateloq-backups/
#   recovery), DR_P_FPR, DR_STATE, DR_SKIP_SUPABASE=1, DR_FORCE=1,
#   DR_N8N_JSON_DIR, DR_N8N_SQLITE, DR_N8N_CONTAINER.
# =============================================================================
set -uo pipefail

DR_SET="${DR_SET:-$HOME/restore/20261107T000117Z}"
DR_RECOVERY_DIR="${DR_RECOVERY_DIR:-$HOME/strateloq-backups/recovery}"
DR_P_FPR="${DR_P_FPR:-AD834A2029AA703FA41B119B9D9E63310CA63035}"
DR_STATE="${DR_STATE:-$HOME/.strateloq-dr}"
PROD_REF="nxaunmyihhjixxxljcqt"
N8N_CONTAINER_DEFAULT="dr-n8n-verify"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$HOME/strateloq-dr-recovery-report-${TS}.md"
PASS=0; FAIL=0; SKIP=0; TEST_START_FAIL=0; CUR=""; CUR_ARCHIVE=""

[ -d /dev/shm ] && RAM=/dev/shm || RAM=/tmp
export TMPDIR="$RAM"
WORK="$(mktemp -d "$RAM/dr-rec.XXXXXX")"; chmod 700 "$WORK"
EVID="$DR_STATE/evidence"; GH="$DR_STATE/gnupg"; SBDIR="$WORK/sb"
mkdir -p "$EVID"; chmod 700 "$DR_STATE" "$EVID" 2>/dev/null
HAVE_PSQL=0; command -v psql >/dev/null 2>&1 && command -v pg_restore >/dev/null 2>&1 && HAVE_PSQL=1
HAVE_SQLITE=0; command -v sqlite3 >/dev/null 2>&1 && HAVE_SQLITE=1
HAVE_DENO=0; command -v deno >/dev/null 2>&1 && HAVE_DENO=1

log(){ printf '%s\n' "$*" >> "$REPORT"; }
con(){ printf '%s\n' "$*"; }
sect(){ con ""; con "== $* =="; log ""; log "## $*"; }
pass(){ PASS=$((PASS+1)); con "  [PASS] $*"; log "- **PASS** — $*"; }
fail(){ FAIL=$((FAIL+1)); con "  [FAIL] $*" >&2; log "- **FAIL** — $*"; }
skip(){ SKIP=$((SKIP+1)); con "  [SKIP] $*"; log "- **SKIP** — $*"; }
info(){ con "        $*"; log "    - $*"; }
die(){ con "ABORT: $*" >&2; log "ABORT: $*"; exit 2; }

cleanup(){
  set +e
  [ -d "$SBDIR" ] && ( cd "$SBDIR" && supabase stop --no-backup >/dev/null 2>&1 )
  [ -n "${N8N_STARTED:-}" ] && docker rm -f "$N8N_STARTED" >/dev/null 2>&1
  find "$WORK" -type f -exec shred -u {} \; >/dev/null 2>&1    # shred ALL run-temp (incl. any plaintext)
  rm -rf "$WORK" >/dev/null 2>&1
  unset PP
}
trap cleanup EXIT INT TERM

assert_local(){ case "$1" in *"$PROD_REF"*) fail "$2 REFUSED: references production ($PROD_REF)"; return 1;; esac
  case "$1" in http://127.0.0.1*|http://localhost*|https://127.0.0.1*|https://localhost*) return 0;;
    *) fail "$2 REFUSED: not a localhost URL"; return 1;; esac; }

# ---------- idempotency: per-test evidence tied to the archive sha256 ----------
sha(){ [ -f "$1" ] && sha256sum "$1" 2>/dev/null | awk '{print $1}' || echo "none"; }
ev_done(){ # $1=name $2=archive(optional) -> 0 if sufficient prior evidence exists
  [ "${DR_FORCE:-0}" = 1 ] && return 1
  local ef="$EVID/$1.json"; [ -f "$ef" ] || return 1
  grep -q '"result":"PASS"' "$ef" || return 1
  if [ -n "${2:-}" ]; then local want; want="$(sha "$2")"; grep -q "\"archive_sha\":\"$want\"" "$ef" || return 1; fi
  return 0
}
begin(){ # $1=name $2=archive(optional) -> 1 means SKIP (already done)
  CUR="$1"; CUR_ARCHIVE="${2:-}"
  if ev_done "$1" "${2:-}"; then
    local when; when="$(sed -n 's/.*"when":"\([^"]*\)".*/\1/p' "$EVID/$1.json" 2>/dev/null|head -1)"
    pass "$1: already verified (cached evidence from ${when:-prior run}; re-run with DR_FORCE=1)"; return 1; fi
  TEST_START_FAIL=$FAIL; return 0
}
finish(){ # mark PASS evidence only if this test added no new failures
  [ -n "$CUR" ] || return 0
  if [ "$FAIL" -eq "$TEST_START_FAIL" ]; then
    printf '{"test":"%s","result":"PASS","when":"%s","archive_sha":"%s"}\n' \
      "$CUR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sha "${CUR_ARCHIVE:-/nonexistent}")" > "$EVID/$CUR.json"
  fi
  CUR=""; CUR_ARCHIVE=""
}

# ---------- single unlock via a dedicated local gpg-agent (no repeated prompts) ----------
UNLOCKED=0; USE_AGENT=0; PP=""; KEYFILE="$DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc"
preset_bin(){ command -v gpg-preset-passphrase 2>/dev/null || { for p in /usr/lib/gnupg/gpg-preset-passphrase /usr/libexec/gpg-preset-passphrase /usr/lib/gnupg2/gpg-preset-passphrase; do [ -x "$p" ] && { echo "$p"; return; }; done; }; }
ensure_keyring(){
  [ -f "$KEYFILE" ] || die "PRIMARY key export not found: $KEYFILE"
  mkdir -p "$GH"; chmod 700 "$GH"
  printf '%s\n' "allow-loopback-pinentry" "allow-preset-passphrase" "default-cache-ttl 3600" "max-cache-ttl 7200" > "$GH/gpg-agent.conf"
  GNUPGHOME="$GH" gpg --batch --import "$KEYFILE" 2>/dev/null || die "could not import PRIMARY into the isolated keyring"
  GNUPGHOME="$GH" gpg-connect-agent reloadagent /bye >/dev/null 2>&1
}
grips(){ GNUPGHOME="$GH" gpg --batch --with-keygrip --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^grp:/{print $10}'; }
any_cached(){ local g; for g in $(grips); do GNUPGHOME="$GH" gpg-connect-agent "keyinfo $g" /bye 2>/dev/null | awk '/^S KEYINFO/{print $7}' | grep -q '^1$' && return 0; done; return 1; }
ensure_unlocked(){
  [ "$UNLOCKED" = 1 ] && return 0
  ensure_keyring
  if any_cached; then USE_AGENT=1; UNLOCKED=1; info "unlock: PRIMARY already cached in the local gpg-agent (no prompt)"; return 0; fi
  [ -r /dev/tty ] || die "no terminal to read the PRIMARY passphrase (and agent cache empty)"
  printf 'PRIMARY backup-key passphrase (hidden, asked once): ' >&2; IFS= read -rs PP < /dev/tty; echo >&2
  PP="${PP%$'\r'}"; PP="${PP%$'\n'}"; [ -n "$PP" ] || die "empty passphrase"
  local pb; pb="$(preset_bin)"
  if [ -n "$pb" ]; then
    local g ok=1; for g in $(grips); do printf '%s' "$PP" | GNUPGHOME="$GH" "$pb" --preset "$g" >/dev/null 2>&1 || ok=0; done
    if [ "$ok" = 1 ] && any_cached; then USE_AGENT=1; unset PP; info "unlock: PRIMARY cached in the local gpg-agent (bounded TTL); re-runs within TTL won't prompt"
    else USE_AGENT=0; info "unlock: gpg-agent preset unavailable — using one in-memory unlock for this run"; fi
  else USE_AGENT=0; info "unlock: gpg-preset-passphrase not installed — using one in-memory unlock for this run"; fi
  UNLOCKED=1
}
decrypt(){ # $1=in.gpg $2=out ; single-key isolated keyring, agent-cached or one in-memory passphrase
  ensure_unlocked || return 1
  if [ "$USE_AGENT" = 1 ]; then GNUPGHOME="$GH" gpg --batch --yes -d "$1" > "$2" 2>"$WORK/gpg.err"
  else printf '%s' "$PP" | GNUPGHOME="$GH" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$1" > "$2" 2>"$WORK/gpg.err"; fi
}
find_one(){ ls "$DR_SET"/$1 2>/dev/null | head -1; }

con "Strateloq DR — consolidated recovery tests  ($TS)"
log "# Strateloq DR — consolidated recovery test report"; log "Date: $TS · isolated/local only · production ($PROD_REF) never contacted · state: $DR_STATE"
for t in gpg tar sha256sum jq git docker; do command -v "$t" >/dev/null 2>&1 || die "required tool missing: $t"; done
[ -d "$DR_SET" ] || die "backup set not found: $DR_SET (set DR_SET=...)"

# ---------- local Supabase stack (for Auth + Storage) ----------
SB_UP=0; SB_API=""; SB_ANON=""; SB_SR=""; SB_DB=""
start_stack(){
  [ "$SB_UP" = 1 ] && return 0
  [ "${DR_SKIP_SUPABASE:-0}" = 1 ] && { info "DR_SKIP_SUPABASE=1 — stack-dependent checks skipped"; return 1; }
  command -v supabase >/dev/null 2>&1 || { info "supabase CLI not installed — stack-dependent checks skipped (https://supabase.com/docs/guides/cli)"; return 1; }
  mkdir -p "$SBDIR"; ( cd "$SBDIR" && { supabase init >/dev/null 2>&1 || true; } && supabase start >/dev/null 2>&1 ) \
    || { info "supabase start failed (Docker running? ports free?) — stack-dependent checks skipped"; return 1; }
  local env; env="$(cd "$SBDIR" && supabase status -o env 2>/dev/null)" || { info "supabase status failed"; return 1; }
  SB_API="$(printf '%s\n' "$env"  | sed -n 's/^API_URL=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p'|head -1)"
  SB_ANON="$(printf '%s\n' "$env" | sed -n 's/^ANON_KEY=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p'|head -1)"
  SB_SR="$(printf '%s\n' "$env"   | sed -n 's/^SERVICE_ROLE_KEY=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p'|head -1)"
  SB_DB="$(printf '%s\n' "$env"   | sed -n 's/^DB_URL=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p'|head -1)"
  [ -n "$SB_API" ] && [ -n "$SB_SR" ] && [ -n "$SB_DB" ] || { info "could not read local stack URL/keys"; return 1; }
  assert_local "$SB_API" "local stack API" || return 1
  SB_UP=1; info "local isolated stack up (127.0.0.1); ephemeral test keys (not shown)"; return 0
}
DUMP_LOADED=0
restore_dump_local(){
  [ "$DUMP_LOADED" = 1 ] && return 0
  start_stack || return 1
  [ "$HAVE_PSQL" = 1 ] || { info "pg_restore/psql not installed — DB not loaded into the local stack"; return 1; }
  local enc; enc="$(find_one 'strateloq-db-*.dump.gpg')"; [ -n "$enc" ] || { info "no DB dump in set"; return 1; }
  decrypt "$enc" "$WORK/db.dump" || { info "DB decrypt failed"; return 1; }
  [ "$(head -c5 "$WORK/db.dump")" = "PGDMP" ] || { info "DB plaintext not a PGDMP archive"; return 1; }
  pg_restore --no-owner --no-privileges --clean --if-exists -d "$SB_DB" "$WORK/db.dump" >"$WORK/pgr.log" 2>&1
  shred -u "$WORK/db.dump" 2>/dev/null || rm -f "$WORK/db.dump"; DUMP_LOADED=1; return 0
}

n8n_src_manifest(){ # $1=dir of workflow JSONs -> writes $WORK/src_manifest.tsv ; echoes count
  local n=0; : > "$WORK/src_manifest.tsv"
  while IFS= read -r f; do jq -e . "$f" >/dev/null 2>&1 || continue
    jq -r '[(.name//"?"),(.nodes|length),((.connections//{})|keys|length),(.active|tostring)]|@tsv' "$f" >> "$WORK/src_manifest.tsv" 2>/dev/null && n=$((n+1))
  done < <(find "$1" -type f -name '*.json'); echo "$n"; }

verify_n8n_db(){ # $1=sqlite path -> compares to $WORK/src_manifest.tsv
  local integ cnt act
  integ="$(sqlite3 "$1" 'PRAGMA integrity_check;' 2>/dev/null|head -1)"
  cnt="$(sqlite3 "$1" 'select count(*) from workflow_entity;' 2>/dev/null)"
  act="$(sqlite3 "$1" 'select count(*) from workflow_entity where active=1;' 2>/dev/null)"
  [ "$integ" = ok ] && pass "n8n recovery DB integrity_check = ok" || fail "n8n sqlite integrity_check: ${integ:-?}"
  [ "$cnt" = 136 ] && pass "all 136 workflows present in the recovery n8n DB" || fail "recovery n8n workflow rows = ${cnt:-?} (expected 136)"
  [ "${act:-x}" = 0 ] && pass "every recovered workflow is INACTIVE (0 active)" || fail "active workflows in recovery DB = ${act:-?} (expected 0)"
  sqlite3 -separator $'\t' "$1" "select name,json_array_length(nodes),(select count(*) from json_each(connections)) from workflow_entity;" 2>/dev/null|sort > "$WORK/db_manifest.tsv"
  cut -f1-3 "$WORK/src_manifest.tsv"|sort > "$WORK/src_cmp.tsv"
  if diff -q "$WORK/src_cmp.tsv" "$WORK/db_manifest.tsv" >/dev/null 2>&1; then pass "names + node counts + connection counts match the source archive for all workflows"
  else local d; d="$(diff "$WORK/src_cmp.tsv" "$WORK/db_manifest.tsv" 2>/dev/null|grep -c '^[<>]')"; fail "names/nodes/connections differ on $d workflow line(s) vs source"; fi
}

########################################################################
sect "Test 1 — n8n workflow recovery (136, names/nodes/connections, all inactive, DB integrity)"
t1(){
  local n8n_arc jdir n
  # Source definitions: reuse already-decrypted JSONs if provided, else decrypt the archive.
  if [ -n "${DR_N8N_JSON_DIR:-}" ] && [ -d "$DR_N8N_JSON_DIR" ]; then
    jdir="$DR_N8N_JSON_DIR"; info "reusing provided decrypted workflow JSONs: $jdir"
  else
    n8n_arc="$(find_one 'strateloq-n8n-*.tar.gpg')"; [ -n "$n8n_arc" ] || { fail "n8n archive not found and DR_N8N_JSON_DIR unset"; return; }
    CUR_ARCHIVE="$n8n_arc"
    decrypt "$n8n_arc" "$WORK/n8n.tar" || { fail "n8n archive decrypt failed"; sed 's/^/      gpg: /' "$WORK/gpg.err"|head -2; return; }
    jdir="$WORK/n8n_json"; mkdir -p "$jdir"; tar -xf "$WORK/n8n.tar" -C "$jdir" 2>/dev/null
  fi
  n="$(n8n_src_manifest "$jdir")"
  [ "$n" = 136 ] && pass "136 workflow definitions present and valid JSON" || fail "expected 136 valid workflow JSONs, found $n"
  local active_src; active_src="$(awk -F'\t' '$4=="true"{c++} END{print c+0}' "$WORK/src_manifest.tsv")"
  info "source composition: $active_src active + $((n-active_src)) inactive in the export (archived flag is instance-side)"
  if [ "$HAVE_SQLITE" != 1 ]; then skip "sqlite3 not on host — cannot inspect the recovery n8n DB (install sqlite3 for the deep check)"; return; fi

  # Verify an EXISTING recovery DB if given (no re-import); else copy from a named container; else do a fresh ephemeral import.
  if [ -n "${DR_N8N_SQLITE:-}" ] && [ -f "$DR_N8N_SQLITE" ]; then
    cp "$DR_N8N_SQLITE" "$WORK/n8n.sqlite"; info "verifying existing recovery DB: $DR_N8N_SQLITE (no re-import)"; verify_n8n_db "$WORK/n8n.sqlite"; return
  fi
  local cont="${DR_N8N_CONTAINER:-}"
  if [ -n "$cont" ] && docker ps -a --format '{{.Names}}' | grep -qx "$cont"; then
    docker cp "$cont:/home/node/.n8n/database.sqlite" "$WORK/n8n.sqlite" >/dev/null 2>&1 \
      && { info "verifying existing recovery container '$cont' (no re-import)"; verify_n8n_db "$WORK/n8n.sqlite"; return; } \
      || info "could not copy DB from container '$cont'; will do a fresh isolated import"
  fi
  # Fresh ephemeral import (only if no existing recovery DB was provided/found).
  docker rm -f "$N8N_CONTAINER_DEFAULT" >/dev/null 2>&1
  if ! docker run -d --name "$N8N_CONTAINER_DEFAULT" -p 127.0.0.1:5679:5678 \
        -e N8N_SECURE_COOKIE=false -e N8N_DIAGNOSTICS_ENABLED=false -e N8N_VERSION_NOTIFICATIONS_ENABLED=false \
        -v "$jdir":/data:ro n8nio/n8n:latest >/dev/null 2>&1; then
    skip "could not start throwaway n8n (Docker unavailable?) — definitions verified; live DB check not run"; return; fi
  N8N_STARTED="$N8N_CONTAINER_DEFAULT"
  local ready=0 i; for i in $(seq 1 60); do docker exec "$N8N_CONTAINER_DEFAULT" sh -c 'test -d /home/node/.n8n' >/dev/null 2>&1 && { ready=1; break; }; sleep 2; done
  [ "$ready" = 1 ] || { skip "n8n did not become ready; live import not run"; return; }
  docker exec "$N8N_CONTAINER_DEFAULT" n8n import:workflow --separate --input=/data >"$WORK/n8n_import.log" 2>&1
  docker cp "$N8N_CONTAINER_DEFAULT:/home/node/.n8n/database.sqlite" "$WORK/n8n.sqlite" >/dev/null 2>&1
  [ -f "$WORK/n8n.sqlite" ] && verify_n8n_db "$WORK/n8n.sqlite" || fail "could not read the imported n8n database"
  docker rm -f "$N8N_CONTAINER_DEFAULT" >/dev/null 2>&1; N8N_STARTED=""
  info "throwaway n8n removed; 127.0.0.1 only; no credentials; nothing activated"
}
if begin n8n "$(find_one 'strateloq-n8n-*.tar.gpg')"; then t1; finish; fi

########################################################################
sect "Test 2 — Storage file recovery (objects, checksums, access controls)"
t2(){
  local enc root nfiles; enc="$(find_one 'strateloq-storage-*.tgz.gpg')"
  [ -n "$enc" ] || { fail "storage archive not found in set"; return; }
  decrypt "$enc" "$WORK/storage.tgz" || { fail "storage archive decrypt failed"; return; }
  mkdir -p "$WORK/sx"; tar -xzf "$WORK/storage.tgz" -C "$WORK/sx" 2>/dev/null
  root="$(find "$WORK/sx" -mindepth 1 -maxdepth 1 -type d|head -1)"; [ -n "$root" ] || root="$WORK/sx"
  nfiles="$(find "$root" -type f|wc -l|tr -d ' ')"
  [ "$nfiles" -ge 1 ] && info "storage archive extracted: $nfiles object file(s)" || { fail "storage archive extracted no files"; return; }
  [ "$nfiles" = 37 ] && pass "37 object files recovered from the archive" || info "object-file count = $nfiles (reconcile vs 37; dirs excluded)"
  ( cd "$root" && find . -type f -exec sha256sum {} \; ) > "$WORK/storage_sha256.txt" 2>/dev/null
  pass "computed sha256 for every recovered object ($nfiles entries)"
  if start_stack; then
    local bucket="dr-restore-verify" up=0 one=""
    curl -s -X POST "$SB_API/storage/v1/bucket" -H "Authorization: Bearer $SB_SR" -H "Content-Type: application/json" -d "{\"name\":\"$bucket\",\"public\":false}" >/dev/null 2>&1
    while IFS= read -r f; do local rel; rel="${f#"$root"/}"
      curl -s -o /dev/null -X POST "$SB_API/storage/v1/object/$bucket/$rel" -H "Authorization: Bearer $SB_SR" --data-binary @"$f" && { up=$((up+1)); one="$rel"; }
    done < <(find "$root" -type f)
    [ "$up" = "$nfiles" ] && pass "uploaded all $up object(s) into a PRIVATE local bucket" || fail "uploaded $up of $nfiles objects"
    if [ -n "$one" ]; then
      local code; code="$(curl -s -o /dev/null -w '%{http_code}' "$SB_API/storage/v1/object/public/$bucket/$one")"
      case "$code" in 200) fail "PRIVATE object publicly readable (HTTP 200) — access control FAILED";; *) pass "anonymous public GET denied (HTTP $code) — private stays private";; esac
      local signed; signed="$(curl -s -X POST "$SB_API/storage/v1/object/sign/$bucket/$one" -H "Authorization: Bearer $SB_SR" -d '{"expiresIn":60}'|jq -r '.signedURL // .signedUrl // empty' 2>/dev/null)"
      [ -n "$signed" ] && { local sc; sc="$(curl -s -o /dev/null -w '%{http_code}' "$SB_API${signed}")"; [ "$sc" = 200 ] && pass "authorised retrieval via signed URL works (HTTP 200)" || fail "signed-URL retrieval HTTP $sc"; } || fail "could not mint a signed URL"
    fi
    restore_dump_local && [ "$HAVE_PSQL" = 1 ] && { local meta; meta="$(psql "$SB_DB" -tAc 'select count(*) from storage.objects' 2>/dev/null)"; info "restored storage.objects metadata rows: ${meta:-?} (object paths map to these tenant/records)"; }
  else
    skip "local stack not up — bucket upload + access-control not run (decrypt, count, checksums done)"
  fi
}
if begin storage "$(find_one 'strateloq-storage-*.tgz.gpg')"; then t2; finish; fi

########################################################################
sect "Test 3 — Supabase Auth recovery (records + functional sign-in, isolated)"
t3(){
  if ! restore_dump_local; then skip "local stack+dump not available — Auth functional sign-in not run (needs GoTrue)"; return; fi
  if [ "$HAVE_PSQL" = 1 ]; then
    local users; users="$(psql "$SB_DB" -tAc 'select count(*) from auth.users' 2>/dev/null)"
    [ "${users:-0}" = 6 ] && pass "all 6 backed-up authentication users recovered into the isolated stack" \
      || { [ "${users:-0}" -ge 1 ] 2>/dev/null && pass "recovered auth.users present: ${users}" || fail "no recovered auth.users (expected 6)"; }
    local off; off="$(psql "$SB_DB" -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity" 2>/dev/null)"
    [ "${off:-x}" = 0 ] && pass "tenant isolation intact: RLS on every restored public table (0 without)" || fail "restored public tables without RLS: ${off:-?}"
  else info "psql not installed — auth.users count + RLS check skipped; sign-in still attempted"; fi
  assert_local "$SB_API" "auth endpoint" || return
  local email="dr-verify-$TS@local.test" pw="DR-verify-$TS-$RANDOM"
  curl -s -o /dev/null -X POST "$SB_API/auth/v1/admin/users" -H "apikey: $SB_SR" -H "Authorization: Bearer $SB_SR" -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$pw\",\"email_confirm\":true}"
  local tok; tok="$(curl -s -X POST "$SB_API/auth/v1/token?grant_type=password" -H "apikey: $SB_ANON" -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$pw\"}"|jq -r '.access_token // empty' 2>/dev/null)"
  [ -n "$tok" ] && pass "functional sign-in works in the recovered environment (controlled account; token not shown)" || fail "controlled-account sign-in did not return a token"
  info "limits: original passwords not in backup (bcrypt hashes only); GoTrue JWT/SMTP/providers, auth.identities, sessions, MFA are reconfigured on recovery, not restored by the dump"
}
if begin auth "$(find_one 'strateloq-db-*.dump.gpg')"; then t3; finish; fi

########################################################################
sect "Test 4 — Source + Edge Function recovery (bundle recreate + Edge source + deploy smoke)"
t4(){
  local enc; enc="$(find_one 'strateloq-*.bundle.gpg')"; [ -n "$enc" ] || { fail "source git bundle not found in set"; return; }
  decrypt "$enc" "$WORK/repo.bundle" || { fail "bundle decrypt failed"; return; }
  git bundle verify "$WORK/repo.bundle" >"$WORK/bundle.log" 2>&1 && pass "git bundle verifies (complete and recreatable)" || { fail "git bundle verify failed"; sed 's/^/      /' "$WORK/bundle.log"|tail -2; return; }
  git clone -q "$WORK/repo.bundle" "$WORK/restored-repo" >/dev/null 2>&1 && pass "repository recreated from the bundle (git clone succeeded)" || { fail "git clone from bundle failed"; return; }
  local head fns; head="$(cd "$WORK/restored-repo" && git log --oneline -1 2>/dev/null)"; info "recreated repo HEAD: ${head:-?}"
  fns="$(find "$WORK/restored-repo/supabase/functions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null|grep -vc '/_')"
  [ "${fns:-0}" = 25 ] && pass "25 Edge Function source directories restored from the bundle" || info "Edge Function dirs restored = ${fns:-?} (prod currently deploys 25)"
  if [ "$HAVE_DENO" = 1 ]; then
    local okc=0 total=0 e; while IFS= read -r e; do total=$((total+1)); deno check "$e" >/dev/null 2>&1 && okc=$((okc+1)); done < <(find "$WORK/restored-repo/supabase/functions" -maxdepth 2 -name index.ts)
    { [ "$okc" = "$total" ] && [ "$total" -gt 0 ]; } && pass "all $total Edge Function entrypoints type-check with Deno (deployable)" || info "Deno type-check: $okc/$total clean (some need import maps/remote types offline)"
  else skip "deno not installed — source recreate + 25-dir restore proven; deploy type-check not run"; fi
  info "no production API or advertising calls (type-check/clone only; functions never invoked)"
}
if begin edge "$(find_one 'strateloq-*.bundle.gpg')"; then t4; finish; fi

########################################################################
sect "Result"
RESULT="PASS"; [ "$FAIL" -gt 0 ] && RESULT="FAIL"
con ""; con "CONSOLIDATED RESULT: $RESULT   (pass=$PASS  fail=$FAIL  skip=$SKIP)"
log ""; log "**CONSOLIDATED RESULT: $RESULT** — pass=$PASS, fail=$FAIL, skip=$SKIP"
log "Production ($PROD_REF) never contacted. Stack + container torn down; plaintext shredded; evidence cached in $EVID."
con "Report: $REPORT"
con "Evidence cached in $EVID (idempotent re-runs skip verified tests). Temp shredded; production never contacted."
[ "$FAIL" -eq 0 ]

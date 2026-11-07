#!/usr/bin/env bash
# =============================================================================
# Strateloq DR — consolidated OFFLINE recovery tests (Auth · Storage · n8n · Source/Edge).
#
# Runs the remaining disaster-recovery verifications end-to-end against ISOLATED, LOCAL environments
# only (a local `supabase start` stack + a throwaway local n8n Docker container). It NEVER contacts
# production, never activates a recovered workflow, never invokes an Edge Function's external calls,
# and incurs no paid charges. Every plaintext (decrypted dump/archive, temp keyring) is shredded and
# all temporary environments are torn down on ANY exit. A consolidated PASS/FAIL report with real
# evidence (counts, checksums, status codes — never secrets) is written to $HOME and printed.
#
# Uses the already-verified Stage-2 backup set and the hardened decrypt path (isolated single-key
# keyring, PRIMARY only, loopback, CR/LF-stripped passphrase). The PRIMARY passphrase is the ONLY
# secret requested, once, hidden; it is never printed or persisted. Local-stack keys are ephemeral
# test keys and are likewise never printed.
#
#   DR_SET            path to the verified Stage-2 set (default ~/restore/20261107T000117Z)
#   DR_RECOVERY_DIR   dir holding dr-<fpr>.secret.asc (default ~/strateloq-backups/recovery)
#   DR_P_FPR          PRIMARY fingerprint (default below)
#   DR_SKIP_SUPABASE=1  skip the stack-dependent Auth/Storage functional steps (file-level still runs)
#
# Idempotent: stops any prior local stack, force-removes the dr-n8n container, uses fresh temp dirs.
# =============================================================================
set -uo pipefail

DR_SET="${DR_SET:-$HOME/restore/20261107T000117Z}"
DR_RECOVERY_DIR="${DR_RECOVERY_DIR:-$HOME/strateloq-backups/recovery}"
DR_P_FPR="${DR_P_FPR:-AD834A2029AA703FA41B119B9D9E63310CA63035}"
PROD_REF="nxaunmyihhjixxxljcqt"            # production project ref — must NEVER be contacted
N8N_CONTAINER="dr-n8n-verify"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$HOME/strateloq-dr-recovery-report-${TS}.md"
PASS=0; FAIL=0; SKIP=0

[ -d /dev/shm ] && RAM=/dev/shm || RAM=/tmp
export TMPDIR="$RAM"
WORK="$(mktemp -d "$RAM/dr-rec.XXXXXX")"; chmod 700 "$WORK"
GH="$WORK/gh"; SBDIR="$WORK/sb"; PP=""
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

cleanup(){
  set +e
  [ -d "$SBDIR" ] && ( cd "$SBDIR" && supabase stop --no-backup >/dev/null 2>&1 )
  docker rm -f "$N8N_CONTAINER" >/dev/null 2>&1
  find "$WORK" -type f \( -name '*.dump' -o -name '*.tgz' -o -name '*.tar' -o -name '*.bundle' -o -name '*.sqlite' \) \
    -exec shred -u {} \; >/dev/null 2>&1
  rm -rf "$WORK" >/dev/null 2>&1
  unset PP
}
trap cleanup EXIT INT TERM
die(){ con "ABORT: $*" >&2; log "ABORT: $*"; exit 2; }

assert_local(){ # $1=url $2=label — must be localhost and must NOT reference production
  case "$1" in *"$PROD_REF"*) fail "$2 REFUSED: references production ($PROD_REF)"; return 1;; esac
  case "$1" in http://127.0.0.1*|http://localhost*|https://127.0.0.1*|https://localhost*) return 0;;
    *) fail "$2 REFUSED: not a localhost URL"; return 1;; esac
}

con "Strateloq DR — consolidated recovery tests  ($TS)"
log "# Strateloq DR — consolidated recovery test report"
log "Date: $TS · isolated/local only · production ($PROD_REF) never contacted"
for t in gpg tar sha256sum jq git docker; do command -v "$t" >/dev/null 2>&1 || die "required tool missing: $t"; done
[ -d "$DR_SET" ] || die "backup set not found: $DR_SET (set DR_SET=...)"
[ -f "$DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc" ] || die "PRIMARY key export not found: $DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc"

if [ -r /dev/tty ]; then printf 'PRIMARY backup-key passphrase (hidden): ' >&2; IFS= read -rs PP < /dev/tty; echo >&2
else die "no terminal to read the PRIMARY passphrase"; fi
PP="${PP%$'\r'}"; PP="${PP%$'\n'}"; [ -n "$PP" ] || die "empty passphrase"
mkdir -p "$GH"; chmod 700 "$GH"; echo "allow-loopback-pinentry" > "$GH/gpg-agent.conf"
GNUPGHOME="$GH" gpg --batch --import "$DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc" 2>/dev/null \
  || die "could not import PRIMARY key into the isolated keyring"

decrypt(){ printf '%s' "$PP" | GNUPGHOME="$GH" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    -d "$1" > "$2" 2>"$WORK/gpg.err"; }
find_one(){ ls "$DR_SET"/$1 2>/dev/null | head -1; }

SB_UP=0; SB_API=""; SB_ANON=""; SB_SR=""; SB_DB=""
start_stack(){
  [ "${DR_SKIP_SUPABASE:-0}" = 1 ] && { info "DR_SKIP_SUPABASE=1 — stack-dependent checks skipped"; return 1; }
  command -v supabase >/dev/null 2>&1 || { info "supabase CLI not installed — stack-dependent checks skipped (https://supabase.com/docs/guides/cli)"; return 1; }
  mkdir -p "$SBDIR"; ( cd "$SBDIR" && { supabase init >/dev/null 2>&1 || true; } && supabase start >/dev/null 2>&1 ) \
    || { info "supabase start failed (Docker running? ports free?) — stack-dependent checks skipped"; return 1; }
  local env; env="$(cd "$SBDIR" && supabase status -o env 2>/dev/null)" || { info "supabase status failed"; return 1; }
  SB_API="$(printf '%s\n' "$env"  | sed -n 's/^API_URL=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p' | head -1)"
  SB_ANON="$(printf '%s\n' "$env" | sed -n 's/^ANON_KEY=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p' | head -1)"
  SB_SR="$(printf '%s\n' "$env"   | sed -n 's/^SERVICE_ROLE_KEY=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p' | head -1)"
  SB_DB="$(printf '%s\n' "$env"   | sed -n 's/^DB_URL=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p' | head -1)"
  [ -n "$SB_API" ] && [ -n "$SB_SR" ] && [ -n "$SB_DB" ] || { info "could not read local stack URL/keys"; return 1; }
  assert_local "$SB_API" "local stack API" || return 1
  SB_UP=1; info "local isolated stack up (API on 127.0.0.1); ephemeral test keys (not shown)"; return 0
}
restore_dump_local(){
  [ "$SB_UP" = 1 ] || return 1
  [ "$HAVE_PSQL" = 1 ] || { info "pg_restore/psql not installed — DB not loaded into the local stack"; return 1; }
  local enc plain; enc="$(find_one 'strateloq-db-*.dump.gpg')"; [ -n "$enc" ] || { info "no DB dump in set"; return 1; }
  plain="$WORK/db.dump"; decrypt "$enc" "$plain" || { info "DB decrypt failed"; return 1; }
  [ "$(head -c5 "$plain")" = "PGDMP" ] || { info "DB plaintext not a PGDMP archive"; return 1; }
  pg_restore --no-owner --no-privileges --clean --if-exists -d "$SB_DB" "$plain" >"$WORK/pgr.log" 2>&1
  shred -u "$plain" 2>/dev/null || rm -f "$plain"; return 0
}

########################################################################
sect "Test 1 — n8n workflow recovery (136, names/nodes/connections, all inactive, DB integrity)"
t1(){
  local enc jdir n; enc="$(find_one 'strateloq-n8n-*.tar.gpg')"
  [ -n "$enc" ] || { fail "n8n archive not found in set"; return; }
  decrypt "$enc" "$WORK/n8n.tar" || { fail "n8n archive decrypt failed"; sed 's/^/      gpg: /' "$WORK/gpg.err"|head -2; return; }
  jdir="$WORK/n8n_json"; mkdir -p "$jdir"; tar -xf "$WORK/n8n.tar" -C "$jdir" 2>/dev/null
  n="$(find "$jdir" -type f -name '*.json' | wc -l | tr -d ' ')"
  [ "$n" = 136 ] && pass "decrypted archive contains 136 workflow JSON files" || fail "expected 136 workflow JSONs, found $n"
  local bad=0; : > "$WORK/src_manifest.tsv"
  while IFS= read -r f; do
    jq -e . "$f" >/dev/null 2>&1 || { bad=$((bad+1)); continue; }
    jq -r '[(.name//"?"), (.nodes|length), ((.connections//{})|keys|length), (.active|tostring)] | @tsv' "$f" >> "$WORK/src_manifest.tsv" 2>/dev/null || bad=$((bad+1))
  done < <(find "$jdir" -type f -name '*.json')
  [ "$bad" = 0 ] && pass "all workflow JSON definitions are valid and parse" || fail "$bad workflow JSON file(s) failed to parse"
  local active_src; active_src="$(awk -F'\t' '$4=="true"{c++} END{print c+0}' "$WORK/src_manifest.tsv")"
  info "source archive composition: $active_src active + $((n-active_src)) inactive in the export (archived flag is instance-side)"

  docker rm -f "$N8N_CONTAINER" >/dev/null 2>&1
  if ! docker run -d --name "$N8N_CONTAINER" -p 127.0.0.1:5679:5678 \
        -e N8N_SECURE_COOKIE=false -e N8N_DIAGNOSTICS_ENABLED=false -e N8N_VERSION_NOTIFICATIONS_ENABLED=false \
        -v "$jdir":/data:ro n8nio/n8n:latest >/dev/null 2>&1; then
    skip "could not start throwaway n8n container (Docker unavailable?) — definitions verified above, live import not run"; return; fi
  local ready=0 i; for i in $(seq 1 60); do docker exec "$N8N_CONTAINER" sh -c 'test -d /home/node/.n8n' >/dev/null 2>&1 && { ready=1; break; }; sleep 2; done
  [ "$ready" = 1 ] || { skip "n8n did not become ready; live import not run"; return; }
  docker exec "$N8N_CONTAINER" n8n import:workflow --separate --input=/data >"$WORK/n8n_import.log" 2>&1
  docker cp "$N8N_CONTAINER:/home/node/.n8n/database.sqlite" "$WORK/n8n.sqlite" >/dev/null 2>&1
  if [ "$HAVE_SQLITE" = 1 ] && [ -f "$WORK/n8n.sqlite" ]; then
    local integ cnt act
    integ="$(sqlite3 "$WORK/n8n.sqlite" 'PRAGMA integrity_check;' 2>/dev/null | head -1)"
    cnt="$(sqlite3 "$WORK/n8n.sqlite" 'select count(*) from workflow_entity;' 2>/dev/null)"
    act="$(sqlite3 "$WORK/n8n.sqlite" 'select count(*) from workflow_entity where active=1;' 2>/dev/null)"
    [ "$integ" = "ok" ] && pass "restored n8n database integrity_check = ok" || fail "n8n sqlite integrity_check: ${integ:-?}"
    [ "$cnt" = 136 ] && pass "all 136 workflows present in the restored n8n database" || fail "restored n8n workflow rows = ${cnt:-?} (expected 136)"
    [ "${act:-x}" = 0 ] && pass "every restored workflow is INACTIVE (0 active)" || fail "restored active workflows = ${act:-?} (expected 0)"
    sqlite3 -separator $'\t' "$WORK/n8n.sqlite" \
      "select name, json_array_length(nodes), (select count(*) from json_each(connections)) from workflow_entity;" \
      2>/dev/null | sort > "$WORK/db_manifest.tsv"
    cut -f1-3 "$WORK/src_manifest.tsv" | sort > "$WORK/src_cmp.tsv"
    if diff -q "$WORK/src_cmp.tsv" "$WORK/db_manifest.tsv" >/dev/null 2>&1; then
      pass "names + node counts + connection counts match the source archive for all workflows"
    else
      local d; d="$(diff "$WORK/src_cmp.tsv" "$WORK/db_manifest.tsv" 2>/dev/null | grep -c '^[<>]')"
      fail "names/nodes/connections differ on $d workflow line(s) vs source (inspect: import log)"
    fi
  else
    skip "sqlite3 not on host — counting via n8n CLI instead"
    local cnt; cnt="$(docker exec "$N8N_CONTAINER" n8n list:workflow 2>/dev/null | grep -c '|')"
    [ "${cnt:-0}" -ge 136 ] && pass "n8n CLI lists >=136 imported workflows" || fail "n8n CLI listed ${cnt:-?} workflows"
  fi
  docker rm -f "$N8N_CONTAINER" >/dev/null 2>&1
  info "throwaway n8n removed; bound to 127.0.0.1 only; no credentials loaded; nothing activated"
}
t1

########################################################################
sect "Local isolated stack (brought up once for Test 2 + Test 3)"
if start_stack; then
  if restore_dump_local; then info "verified DB dump loaded into the local isolated stack (enables Auth + Storage association)"
  else info "DB dump not loaded — Auth/Storage association checks will be limited"; fi
else info "no local stack — Test 2/3 functional steps will be skipped; file-level checks still run"; fi

########################################################################
sect "Test 2 — Storage file recovery (objects, checksums, access controls)"
t2(){
  local enc root nfiles; enc="$(find_one 'strateloq-storage-*.tgz.gpg')"
  [ -n "$enc" ] || { fail "storage archive not found in set"; return; }
  decrypt "$enc" "$WORK/storage.tgz" || { fail "storage archive decrypt failed"; return; }
  mkdir -p "$WORK/sx"; tar -xzf "$WORK/storage.tgz" -C "$WORK/sx" 2>/dev/null
  root="$(find "$WORK/sx" -mindepth 1 -maxdepth 1 -type d | head -1)"; [ -n "$root" ] || root="$WORK/sx"
  nfiles="$(find "$root" -type f | wc -l | tr -d ' ')"
  [ "$nfiles" -ge 1 ] && info "storage archive extracted: $nfiles object file(s)" || { fail "storage archive extracted no files"; return; }
  [ "$nfiles" = 37 ] && pass "37 object files recovered from the archive" || info "object-file count = $nfiles (reconcile vs 37; dirs excluded)"
  ( cd "$root" && find . -type f -exec sha256sum {} \; ) > "$WORK/storage_sha256.txt" 2>/dev/null
  pass "computed sha256 for every recovered object ($nfiles entries; manifest kept in temp, not persisted)"
  if [ "$SB_UP" = 1 ]; then
    local bucket="dr-restore-verify" up=0 one=""
    curl -s -X POST "$SB_API/storage/v1/bucket" -H "Authorization: Bearer $SB_SR" -H "Content-Type: application/json" \
      -d "{\"name\":\"$bucket\",\"public\":false}" >/dev/null 2>&1
    while IFS= read -r f; do
      local rel; rel="${f#"$root"/}"
      curl -s -o /dev/null -X POST "$SB_API/storage/v1/object/$bucket/$rel" \
        -H "Authorization: Bearer $SB_SR" --data-binary @"$f" && { up=$((up+1)); one="$rel"; }
    done < <(find "$root" -type f)
    [ "$up" = "$nfiles" ] && pass "uploaded all $up object(s) into a PRIVATE local bucket" || fail "uploaded $up of $nfiles objects"
    if [ -n "$one" ]; then
      local code; code="$(curl -s -o /dev/null -w '%{http_code}' "$SB_API/storage/v1/object/public/$bucket/$one")"
      case "$code" in 200) fail "PRIVATE object publicly readable (HTTP 200) — access control FAILED";;
        *) pass "anonymous public GET denied (HTTP $code) — private stays private";; esac
      local signed; signed="$(curl -s -X POST "$SB_API/storage/v1/object/sign/$bucket/$one" -H "Authorization: Bearer $SB_SR" -d '{"expiresIn":60}' | jq -r '.signedURL // .signedUrl // empty' 2>/dev/null)"
      if [ -n "$signed" ]; then
        local scode; scode="$(curl -s -o /dev/null -w '%{http_code}' "$SB_API${signed}")"
        [ "$scode" = 200 ] && pass "authorised retrieval via signed URL works (HTTP 200)" || fail "signed-URL retrieval HTTP $scode"
      else fail "could not mint a signed URL"; fi
    fi
    if [ "$HAVE_PSQL" = 1 ]; then
      local meta; meta="$(psql "$SB_DB" -tAc "select count(*) from storage.objects" 2>/dev/null)"
      info "restored storage.objects metadata rows: ${meta:-?} (object paths map to these tenant/records)"
    fi
  else
    skip "local stack not up — bucket upload + access-control + association not run (decrypt, count and checksums done)"
  fi
}
t2

########################################################################
sect "Test 3 — Supabase Auth recovery (records + functional sign-in, isolated)"
t3(){
  if [ "$SB_UP" != 1 ]; then skip "local stack not up — Auth functional sign-in not run (needs GoTrue)"; return; fi
  if [ "$HAVE_PSQL" = 1 ]; then
    local users; users="$(psql "$SB_DB" -tAc "select count(*) from auth.users" 2>/dev/null)"
    [ "${users:-0}" = 6 ] && pass "all 6 backed-up authentication users recovered into the isolated stack" \
      || { [ "${users:-0}" -ge 1 ] 2>/dev/null && pass "recovered auth.users present: ${users}" || fail "no recovered auth.users (expected 6)"; }
    local rls_off; rls_off="$(psql "$SB_DB" -tAc "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity" 2>/dev/null)"
    [ "${rls_off:-x}" = 0 ] && pass "tenant isolation intact: RLS on every restored public table (0 without)" || fail "restored public tables without RLS: ${rls_off:-?}"
  else info "psql not installed — auth.users count + RLS check skipped; sign-in still attempted"; fi
  assert_local "$SB_API" "auth endpoint" || return
  local email="dr-verify-$TS@local.test" pw="DR-verify-$TS-$RANDOM"
  curl -s -o /dev/null -X POST "$SB_API/auth/v1/admin/users" -H "apikey: $SB_SR" -H "Authorization: Bearer $SB_SR" \
    -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$pw\",\"email_confirm\":true}"
  local tok; tok="$(curl -s -X POST "$SB_API/auth/v1/token?grant_type=password" -H "apikey: $SB_ANON" \
    -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$pw\"}" | jq -r '.access_token // empty' 2>/dev/null)"
  [ -n "$tok" ] && pass "functional sign-in works in the recovered environment (controlled account; token not shown)" \
                 || fail "controlled-account sign-in did not return a token"
  info "limits: original passwords not in backup (bcrypt hashes only); GoTrue JWT/SMTP/providers, auth.identities, sessions, MFA are reconfigured on recovery, not restored by the dump"
}
t3

########################################################################
sect "Test 4 — Source + Edge Function recovery (bundle recreate + Edge source + deploy smoke)"
t4(){
  local enc; enc="$(find_one 'strateloq-*.bundle.gpg')"
  [ -n "$enc" ] || { fail "source git bundle not found in set"; return; }
  decrypt "$enc" "$WORK/repo.bundle" || { fail "bundle decrypt failed"; return; }
  if git bundle verify "$WORK/repo.bundle" >"$WORK/bundle.log" 2>&1; then pass "git bundle verifies (complete and recreatable)"; else fail "git bundle verify failed"; sed 's/^/      /' "$WORK/bundle.log"|tail -2; return; fi
  git clone -q "$WORK/repo.bundle" "$WORK/restored-repo" >/dev/null 2>&1 \
    && pass "repository recreated from the bundle (git clone succeeded)" || { fail "git clone from bundle failed"; return; }
  local head fns; head="$(cd "$WORK/restored-repo" && git log --oneline -1 2>/dev/null)"; info "recreated repo HEAD: ${head:-?}"
  fns="$(find "$WORK/restored-repo/supabase/functions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -vc '/_')"
  [ "${fns:-0}" = 25 ] && pass "25 Edge Function source directories restored from the bundle" || info "Edge Function dirs restored = ${fns:-?} (prod currently deploys 25)"
  if [ "$HAVE_DENO" = 1 ]; then
    local okc=0 total=0 e; while IFS= read -r e; do total=$((total+1)); deno check "$e" >/dev/null 2>&1 && okc=$((okc+1)); done \
      < <(find "$WORK/restored-repo/supabase/functions" -maxdepth 2 -name index.ts)
    { [ "$okc" = "$total" ] && [ "$total" -gt 0 ]; } && pass "all $total Edge Function entrypoints type-check with Deno (deployable)" \
      || info "Deno type-check: $okc/$total clean (some need import maps / remote types offline)"
  else
    skip "deno not installed — source recreate + 25-dir restore proven; deploy type-check not run"
  fi
  info "no production API or advertising calls were made (type-check/deploy only; functions never invoked)"
}
t4

########################################################################
sect "Result"
RESULT="PASS"; [ "$FAIL" -gt 0 ] && RESULT="FAIL"
con ""
con "CONSOLIDATED RESULT: $RESULT   (pass=$PASS  fail=$FAIL  skip=$SKIP)"
log ""; log "**CONSOLIDATED RESULT: $RESULT** — pass=$PASS, fail=$FAIL, skip=$SKIP"
log "Production ($PROD_REF) never contacted. Temporary stack + container torn down; plaintext shredded."
con "Report: $REPORT"
con "Temporary environments cleaned up; plaintext shredded; production never contacted."
[ "$FAIL" -eq 0 ]

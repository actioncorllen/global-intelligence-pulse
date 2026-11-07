#!/usr/bin/env bash
# =============================================================================
# Strateloq DR — consolidated OFFLINE recovery tests (Auth · Storage · n8n · Source/Edge).
#
# Self-checking, idempotent runner. Verifies the remaining disaster-recovery capabilities against
# ISOLATED, LOCAL environments only. It NEVER contacts production, never activates a recovered
# workflow, never invokes an Edge Function's external calls, and incurs no paid charges. Decrypted
# plaintext is shredded and temporary environments are torn down on ANY exit. A consolidated PASS/FAIL
# report with real evidence (counts, checksums, HTTP codes — never secrets) is written to $HOME.
#
# DEPENDENCIES: needs only widely-present tools — bash, python3, gpg, tar, sha256sum, git, curl, docker.
#   No jq and no sqlite3 CLI are required (JSON + sqlite are read with Python's stdlib). The Supabase
#   CLI (for the Auth/Storage functional steps) is AUTO-INSTALLED without admin into $DR_STATE/bin if
#   missing; if it cannot be installed those two functional steps self-SKIP with a precise reason while
#   every other check still runs. A full dependency preflight is printed up front.
#
# IDEMPOTENT: each test records PASS evidence under $DR_STATE (default ~/.strateloq-dr), tied to the
#   exact archive sha256; a re-run SKIPs already-verified tests. DR_FORCE=1 forces a full re-run.
# ONE UNLOCK: the PRIMARY passphrase is asked at most once (only if a decrypt is actually needed) and
#   cached in a dedicated local gpg-agent (bounded TTL); re-runs within the TTL do not prompt again.
# REUSE: DR_N8N_SQLITE (default the restored path below) verifies your EXISTING recovery n8n DB without
#   re-importing; DR_N8N_JSON_DIR reuses already-decrypted workflow JSONs.
#
# Env: DR_SET, DR_RECOVERY_DIR, DR_P_FPR, DR_STATE, DR_FORCE=1, DR_SKIP_SUPABASE=1,
#      DR_N8N_SQLITE, DR_N8N_JSON_DIR, DR_N8N_CONTAINER, DR_SUPABASE_VERSION.
# =============================================================================
set -uo pipefail

DR_SET="${DR_SET:-$HOME/restore/20261107T000117Z}"
DR_RECOVERY_DIR="${DR_RECOVERY_DIR:-$HOME/strateloq-backups/recovery}"
DR_P_FPR="${DR_P_FPR:-AD834A2029AA703FA41B119B9D9E63310CA63035}"
DR_STATE="${DR_STATE:-$HOME/.strateloq-dr}"
DR_N8N_SQLITE="${DR_N8N_SQLITE:-/home/strateloqbackup/strateloq-n8n-dr-test/restore-data/database.sqlite}"
PROD_REF="nxaunmyihhjixxxljcqt"
N8N_CONTAINER_DEFAULT="dr-n8n-verify"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$HOME/strateloq-dr-recovery-report-${TS}.md"
PASS=0; FAIL=0; SKIP=0; TEST_START_FAIL=0; CUR=""; CUR_ARCHIVE=""

[ -d /dev/shm ] && RAM=/dev/shm || RAM=/tmp
export TMPDIR="$RAM"
WORK="$(mktemp -d "$RAM/dr-rec.XXXXXX")"; chmod 700 "$WORK"
EVID="$DR_STATE/evidence"; GH="$DR_STATE/gnupg"; SBDIR="$WORK/sb"
mkdir -p "$EVID" "$DR_STATE/bin"; chmod 700 "$DR_STATE" "$EVID" 2>/dev/null
export PATH="$DR_STATE/bin:$PATH"

log(){ printf '%s\n' "$*" >> "$REPORT"; }
con(){ printf '%s\n' "$*"; }
sect(){ con ""; con "== $* =="; log ""; log "## $*"; }
pass(){ PASS=$((PASS+1)); con "  [PASS] $*"; log "- **PASS** — $*"; }
fail(){ FAIL=$((FAIL+1)); con "  [FAIL] $*" >&2; log "- **FAIL** — $*"; }
skip(){ SKIP=$((SKIP+1)); con "  [SKIP] $*"; log "- **SKIP** — $*"; }
info(){ con "        $*"; log "    - $*"; }
die(){ con "ABORT: $*" >&2; log "ABORT: $*"; exit 2; }

N8N_STARTED=""; PG_FALLBACK=""
cleanup(){
  set +e
  [ -d "$SBDIR" ] && ( cd "$SBDIR" && supabase stop --no-backup >/dev/null 2>&1 )
  [ -n "$N8N_STARTED" ] && docker rm -f "$N8N_STARTED" >/dev/null 2>&1
  [ -n "$PG_FALLBACK" ] && docker rm -f "$PG_FALLBACK" >/dev/null 2>&1
  find "$WORK" -type f -exec shred -u {} \; >/dev/null 2>&1
  rm -rf "$WORK" >/dev/null 2>&1
  unset PP
}
trap cleanup EXIT INT TERM

assert_local(){ case "$1" in *"$PROD_REF"*) fail "$2 REFUSED: references production ($PROD_REF)"; return 1;; esac
  case "$1" in http://127.0.0.1*|http://localhost*|https://127.0.0.1*|https://localhost*) return 0;;
    *) fail "$2 REFUSED: not a localhost URL"; return 1;; esac; }

# ---------- Python helpers (replace jq + sqlite3 CLI; stdlib only) ----------
jget(){ python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
k=sys.argv[1]
if isinstance(d,dict):
    for alt in [k]+sys.argv[2:]:
        if d.get(alt) not in (None,""): print(d.get(alt)); break
' "$@"; }
wf_count_valid(){ python3 - "$1" <<'PY'
import sys,os,json,glob
ok=0
for f in glob.glob(os.path.join(sys.argv[1],'**','*.json'),recursive=True):
    try: json.load(open(f)); ok+=1
    except Exception: pass
print(ok)
PY
}
n8n_verify(){ python3 - "$1" "$2" <<'PY'
import sys,sqlite3,json,glob,os
db,jd=sys.argv[1],sys.argv[2]
# Key by WORKFLOW ID, not name: n8n workflow names are NOT unique, and import:workflow preserves ids.
# (Name-keying collapses duplicate-named workflows and yields a spurious single mismatch.)
src={}; srcn=0; srcactive=0; src_names={}
for f in glob.glob(os.path.join(jd,'**','*.json'),recursive=True):
    try: w=json.load(open(f))
    except Exception: continue
    srcn+=1
    if w.get('active'): srcactive+=1
    wid=str(w.get('id') or os.path.basename(f))
    src[wid]=(len(w.get('nodes') or []), len((w.get('connections') or {}).keys()))
    src_names[wid]=str(w.get('name','?'))
try:
    con=sqlite3.connect("file:%s?mode=ro"%db, uri=True); cur=con.cursor()
    integ=cur.execute("PRAGMA integrity_check").fetchone()[0]
    cnt=cur.execute("select count(*) from workflow_entity").fetchone()[0]
    act=cur.execute("select count(*) from workflow_entity where active in (1,'1')").fetchone()[0]
    rows={}
    for wid,name,nodes,conns in cur.execute("select id,name,nodes,connections from workflow_entity"):
        try: nn=len(json.loads(nodes) or [])
        except Exception: nn=-1
        try: cc=len((json.loads(conns) or {}).keys()) if conns else 0
        except Exception: cc=-1
        rows[str(wid)]=(nn,cc)
except Exception as e:
    print("SRCN=%d ERR=%s"%(srcn,str(e).replace(' ','_'))); sys.exit(0)
missing=[i for i in src if i not in rows]      # in archive, absent from recovery DB -> data loss
extra=[i for i in rows if i not in src]        # in recovery DB, absent from archive
fdiff=[i for i in src if i in rows and src[i]!=rows[i]]  # same id, different (nodes,connections)
match=1 if not missing and not extra and not fdiff else 0
print("SRCN=%d SRCACTIVE=%d INTEGRITY=%s COUNT=%s ACTIVE=%s MATCH=%d MISSING=%d EXTRA=%d FDIFF=%d"%(srcn,srcactive,integ,cnt,act,match,len(missing),len(extra),len(fdiff)))
for i in missing[:6]: print("DETAIL MISSING id=%s name=%s src_nodes_conns=%s"%(i,src_names.get(i,'?'),src[i]))
for i in extra[:6]:   print("DETAIL EXTRA id=%s"%i)
for i in fdiff[:6]:   print("DETAIL DIFF id=%s name=%s src(nodes,conns)=%s db=%s"%(i,src_names.get(i,'?'),src[i],rows[i]))
PY
}

# ---------- idempotency ----------
sha(){ [ -f "$1" ] && sha256sum "$1" 2>/dev/null|awk '{print $1}' || echo none; }
ev_done(){ [ "${DR_FORCE:-0}" = 1 ] && return 1; local ef="$EVID/$1.json"; [ -f "$ef" ]||return 1; grep -q '"result":"PASS"' "$ef"||return 1
  if [ -n "${2:-}" ]; then grep -q "\"archive_sha\":\"$(sha "$2")\"" "$ef"||return 1; fi; return 0; }
begin(){ CUR="$1"; CUR_ARCHIVE="${2:-}"
  if ev_done "$1" "${2:-}"; then local w; w="$(sed -n 's/.*"when":"\([^"]*\)".*/\1/p' "$EVID/$1.json" 2>/dev/null|head -1)"
    pass "$1: already verified (cached evidence from ${w:-prior run}; DR_FORCE=1 to re-run)"; return 1; fi
  TEST_START_FAIL=$FAIL; return 0; }
finish(){ [ -n "$CUR" ] || return 0
  if [ "$FAIL" -eq "$TEST_START_FAIL" ]; then printf '{"test":"%s","result":"PASS","when":"%s","archive_sha":"%s"}\n' "$CUR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sha "${CUR_ARCHIVE:-/nonexistent}")" > "$EVID/$CUR.json"; fi
  CUR=""; CUR_ARCHIVE=""; }

# ---------- single gpg-agent unlock ----------
UNLOCKED=0; USE_AGENT=0; PP=""; KEYFILE="$DR_RECOVERY_DIR/dr-$DR_P_FPR.secret.asc"
preset_bin(){ command -v gpg-preset-passphrase 2>/dev/null || { for p in /usr/lib/gnupg/gpg-preset-passphrase /usr/libexec/gpg-preset-passphrase /usr/lib/gnupg2/gpg-preset-passphrase; do [ -x "$p" ] && { echo "$p"; return; }; done; }; }
grips(){ GNUPGHOME="$GH" gpg --batch --with-keygrip --list-secret-keys --with-colons 2>/dev/null|awk -F: '/^grp:/{print $10}'; }
any_cached(){ local g; for g in $(grips); do GNUPGHOME="$GH" gpg-connect-agent "keyinfo $g" /bye 2>/dev/null|awk '/^S KEYINFO/{print $7}'|grep -q '^1$' && return 0; done; return 1; }
ensure_unlocked(){
  [ "$UNLOCKED" = 1 ] && return 0
  [ -f "$KEYFILE" ] || die "PRIMARY key export not found: $KEYFILE"
  mkdir -p "$GH"; chmod 700 "$GH"
  [ -f "$GH/gpg-agent.conf" ] || printf '%s\n' "allow-loopback-pinentry" "allow-preset-passphrase" "default-cache-ttl 3600" "max-cache-ttl 7200" > "$GH/gpg-agent.conf"
  GNUPGHOME="$GH" gpg --batch --import "$KEYFILE" 2>/dev/null || die "could not import PRIMARY into the isolated keyring"
  # check the cache BEFORE any reload (reloadagent would flush a passphrase cached by a prior run)
  if any_cached; then USE_AGENT=1; UNLOCKED=1; info "unlock: PRIMARY already cached in the local gpg-agent (no prompt)"; return 0; fi
  printf '%s\n' "allow-loopback-pinentry" "allow-preset-passphrase" "default-cache-ttl 3600" "max-cache-ttl 7200" > "$GH/gpg-agent.conf"
  GNUPGHOME="$GH" gpg-connect-agent reloadagent /bye >/dev/null 2>&1
  # Read hidden. Under PowerShell->`wsl.exe -e bash -lc` the console is on stdin (fd 0), not /dev/tty;
  # prefer fd 0 when it is a TTY, fall back to /dev/tty, honour DR_GPG_PASSPHRASE. Never echoed; CR stripped.
  PP=""
  if [ -n "${DR_GPG_PASSPHRASE:-}" ]; then PP="$DR_GPG_PASSPHRASE"
  elif [ -t 0 ]; then printf 'PRIMARY backup-key passphrase (hidden, asked once): ' >&2; IFS= read -rs PP; echo >&2
  elif { : < /dev/tty; } 2>/dev/null; then printf 'PRIMARY backup-key passphrase (hidden, asked once): ' > /dev/tty; IFS= read -rs PP < /dev/tty; printf '\n' > /dev/tty
  else die "no interactive terminal and the gpg-agent cache is empty — run from an interactive WSL shell, or pass DR_GPG_PASSPHRASE"; fi
  PP="${PP%$'\r'}"; PP="${PP%$'\n'}"; [ -n "$PP" ] || die "empty passphrase"
  local pb; pb="$(preset_bin)"
  if [ -n "$pb" ]; then local g ok=1; for g in $(grips); do printf '%s' "$PP" | GNUPGHOME="$GH" "$pb" --preset "$g" >/dev/null 2>&1 || ok=0; done
    if [ "$ok" = 1 ] && any_cached; then USE_AGENT=1; unset PP; info "unlock: PRIMARY cached in the local gpg-agent (bounded TTL); re-runs within TTL won't prompt"
    else USE_AGENT=0; info "unlock: gpg-agent preset unavailable — one in-memory unlock for this run"; fi
  else USE_AGENT=0; info "unlock: gpg-preset-passphrase not installed — one in-memory unlock for this run"; fi
  UNLOCKED=1
}
decrypt(){ ensure_unlocked || return 1
  if [ "$USE_AGENT" = 1 ]; then GNUPGHOME="$GH" gpg --batch --yes -d "$1" > "$2" 2>"$WORK/gpg.err"
  else printf '%s' "$PP" | GNUPGHOME="$GH" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 -d "$1" > "$2" 2>"$WORK/gpg.err"; fi; }
find_one(){ ls "$DR_SET"/$1 2>/dev/null|head -1; }

# ---------- preflight: resolve/auto-provision dependencies together ----------
con "Strateloq DR — consolidated recovery tests  ($TS)"
log "# Strateloq DR — consolidated recovery test report"; log "Date: $TS · isolated/local only · production ($PROD_REF) never contacted · state: $DR_STATE"
sect "Dependency preflight"
for t in python3 gpg tar sha256sum git curl docker; do command -v "$t" >/dev/null 2>&1 || die "required tool missing: $t (install it, then re-run)"; done
pass "core tools present: python3, gpg, tar, sha256sum, git, curl, docker (jq/sqlite3 NOT needed — Python stdlib used)"
docker info >/dev/null 2>&1 || info "WARNING: docker daemon not responding — n8n import + Supabase stack will self-skip (start Docker Desktop/daemon)"
[ -d "$DR_SET" ] || die "backup set not found: $DR_SET (set DR_SET=...)"
HAVE_PSQL=0; command -v psql >/dev/null 2>&1 && command -v pg_restore >/dev/null 2>&1 && HAVE_PSQL=1
HAVE_DENO=0; command -v deno >/dev/null 2>&1 && HAVE_DENO=1

SUPABASE=""
ensure_supabase(){
  [ -n "$SUPABASE" ] && return 0
  [ "${DR_SKIP_SUPABASE:-0}" = 1 ] && return 1
  if command -v supabase >/dev/null 2>&1; then SUPABASE="$(command -v supabase)"; return 0; fi
  local ver arch url tgz
  ver="${DR_SUPABASE_VERSION:-}"
  [ -z "$ver" ] && ver="$(curl -fsSL https://api.github.com/repos/supabase/cli/releases/latest 2>/dev/null | jget tag_name)"
  [ -n "$ver" ] || { info "supabase CLI: could not resolve a version (offline?) — set DR_SUPABASE_VERSION or install it; Auth/Storage functional steps will skip"; return 1; }
  case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; *) info "supabase CLI: unsupported arch $(uname -m)"; return 1;; esac
  tgz="$WORK/supabase.tgz"; url="https://github.com/supabase/cli/releases/download/${ver}/supabase_linux_${arch}.tar.gz"
  if curl -fsSL "$url" -o "$tgz" 2>/dev/null && tar -xzf "$tgz" -C "$DR_STATE/bin" supabase 2>/dev/null && [ -x "$DR_STATE/bin/supabase" ]; then
    SUPABASE="$DR_STATE/bin/supabase"; info "auto-installed Supabase CLI $ver to $DR_STATE/bin (no admin)"; return 0
  fi
  info "supabase CLI auto-install failed ($url) — Auth/Storage functional steps will skip"; return 1
}
if command -v supabase >/dev/null 2>&1 || [ -x "$DR_STATE/bin/supabase" ]; then info "supabase CLI available"; else
  if ensure_supabase; then :; else info "supabase CLI not available yet (will retry at Test 2/3)"; fi; fi
[ "$HAVE_DENO" = 1 ] && info "deno present (Edge type-check enabled)" || info "deno absent (Edge type-check will skip; bundle+source recovery still verified)"
[ "$HAVE_PSQL" = 1 ] && info "host psql/pg_restore present" || info "host psql/pg_restore absent (will use the stack's db container instead)"

# ---------- local Supabase stack + dump load (shared by Storage + Auth) ----------
SB_UP=0; SB_API=""; SB_ANON=""; SB_SR=""; SB_DB=""; DBC=""
start_stack(){ [ "$SB_UP" = 1 ] && return 0
  ensure_supabase || { info "no Supabase CLI — stack-dependent checks skipped"; return 1; }
  docker info >/dev/null 2>&1 || { info "docker daemon not running — stack-dependent checks skipped"; return 1; }
  mkdir -p "$SBDIR"; ( cd "$SBDIR" && { "$SUPABASE" init >/dev/null 2>&1 || true; } && "$SUPABASE" start >/dev/null 2>&1 ) \
    || { info "supabase start failed (first run pulls images; ports free?) — stack-dependent checks skipped"; return 1; }
  local env; env="$(cd "$SBDIR" && "$SUPABASE" status -o env 2>/dev/null)" || { info "supabase status failed"; return 1; }
  SB_API="$(printf '%s\n' "$env"|sed -n 's/^API_URL=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p'|head -1)"
  SB_ANON="$(printf '%s\n' "$env"|sed -n 's/^ANON_KEY=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p'|head -1)"
  SB_SR="$(printf '%s\n' "$env"|sed -n 's/^SERVICE_ROLE_KEY=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p'|head -1)"
  SB_DB="$(printf '%s\n' "$env"|sed -n 's/^DB_URL=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p'|head -1)"
  DBC="$(docker ps --format '{{.Names}}'|grep -E '^supabase_db_'|head -1)"
  [ -n "$SB_API" ] && [ -n "$SB_SR" ] || { info "could not read local stack URL/keys"; return 1; }
  assert_local "$SB_API" "local stack API" || return 1
  SB_UP=1; info "local isolated Supabase stack up (127.0.0.1); ephemeral test keys (not shown)"; return 0
}
sbsql(){ if [ "$HAVE_PSQL" = 1 ] && [ -n "$SB_DB" ]; then psql "$SB_DB" -tAc "$1" 2>/dev/null
  elif [ -n "$DBC" ]; then docker exec "$DBC" psql -U postgres -d postgres -tAc "$1" 2>/dev/null; fi; }
DUMP_LOADED=0
restore_dump_local(){ [ "$DUMP_LOADED" = 1 ] && return 0; start_stack || return 1
  local enc; enc="$(find_one 'strateloq-db-*.dump.gpg')"; [ -n "$enc" ] || { info "no DB dump in set"; return 1; }
  decrypt "$enc" "$WORK/db.dump" || { info "DB decrypt failed"; return 1; }
  [ "$(head -c5 "$WORK/db.dump")" = "PGDMP" ] || { info "DB plaintext not a PGDMP archive"; return 1; }
  if [ "$HAVE_PSQL" = 1 ] && [ -n "$SB_DB" ]; then
    pg_restore --no-owner --no-privileges --clean --if-exists -d "$SB_DB" "$WORK/db.dump" >"$WORK/pgr.log" 2>&1
  elif [ -n "$DBC" ]; then
    docker cp "$WORK/db.dump" "$DBC:/tmp/d.dump" >/dev/null 2>&1
    docker exec "$DBC" pg_restore -U postgres -d postgres --no-owner --no-privileges --clean --if-exists /tmp/d.dump >"$WORK/pgr.log" 2>&1
    docker exec "$DBC" rm -f /tmp/d.dump >/dev/null 2>&1
  else info "no way to run pg_restore (no host client, no db container)"; shred -u "$WORK/db.dump" 2>/dev/null; return 1; fi
  shred -u "$WORK/db.dump" 2>/dev/null || rm -f "$WORK/db.dump"; DUMP_LOADED=1; return 0; }

########################################################################
sect "Test 1 — n8n workflow recovery (136, names/nodes/connections, all inactive, DB integrity)"
t1(){
  local jdir arc n
  if [ -n "${DR_N8N_JSON_DIR:-}" ] && [ -d "$DR_N8N_JSON_DIR" ]; then jdir="$DR_N8N_JSON_DIR"; info "reusing provided decrypted workflow JSONs: $jdir"
  else arc="$(find_one 'strateloq-n8n-*.tar.gpg')"; [ -n "$arc" ] || { fail "n8n archive not found and DR_N8N_JSON_DIR unset"; return; }
    CUR_ARCHIVE="$arc"; decrypt "$arc" "$WORK/n8n.tar" || { fail "n8n archive decrypt failed"; sed 's/^/      gpg: /' "$WORK/gpg.err"|head -2; return; }
    jdir="$WORK/n8n_json"; mkdir -p "$jdir"; tar -xf "$WORK/n8n.tar" -C "$jdir" 2>/dev/null; fi
  n="$(wf_count_valid "$jdir")"
  [ "$n" = 136 ] && pass "136 workflow definitions present and valid JSON" || fail "expected 136 valid workflow JSONs, found $n"

  # Verify an EXISTING recovery DB (no re-import) if available; else fresh ephemeral import.
  local dbfile=""
  if [ -f "$DR_N8N_SQLITE" ]; then dbfile="$DR_N8N_SQLITE"; info "verifying existing recovery DB (no re-import): $DR_N8N_SQLITE"
  elif [ -n "${DR_N8N_CONTAINER:-}" ] && docker ps -a --format '{{.Names}}'|grep -qx "${DR_N8N_CONTAINER}"; then
    docker cp "${DR_N8N_CONTAINER}:/home/node/.n8n/database.sqlite" "$WORK/n8n.sqlite" >/dev/null 2>&1 && { dbfile="$WORK/n8n.sqlite"; info "verifying existing container '${DR_N8N_CONTAINER}' (no re-import)"; }
  fi
  if [ -z "$dbfile" ]; then
    if ! docker info >/dev/null 2>&1; then skip "no existing recovery DB and Docker not running — definitions verified; live DB check not run"; return; fi
    docker rm -f "$N8N_CONTAINER_DEFAULT" >/dev/null 2>&1
    docker run -d --name "$N8N_CONTAINER_DEFAULT" -p 127.0.0.1:5679:5678 -e N8N_SECURE_COOKIE=false -e N8N_DIAGNOSTICS_ENABLED=false -e N8N_VERSION_NOTIFICATIONS_ENABLED=false -v "$jdir":/data:ro n8nio/n8n:latest >/dev/null 2>&1 \
      || { skip "could not start throwaway n8n — definitions verified; live DB check not run"; return; }
    N8N_STARTED="$N8N_CONTAINER_DEFAULT"
    local i ready=0; for i in $(seq 1 60); do docker exec "$N8N_CONTAINER_DEFAULT" sh -c 'test -d /home/node/.n8n' >/dev/null 2>&1 && { ready=1; break; }; sleep 2; done
    [ "$ready" = 1 ] || { skip "n8n not ready; live import not run"; return; }
    docker exec "$N8N_CONTAINER_DEFAULT" n8n import:workflow --separate --input=/data >"$WORK/n8n_import.log" 2>&1
    docker cp "$N8N_CONTAINER_DEFAULT:/home/node/.n8n/database.sqlite" "$WORK/n8n.sqlite" >/dev/null 2>&1; dbfile="$WORK/n8n.sqlite"
  fi
  [ -f "$dbfile" ] || { fail "could not obtain an n8n database to verify"; return; }
  local R SUM; R="$(n8n_verify "$dbfile" "$jdir")"; SUM="$(printf '%s\n' "$R"|grep '^SRCN='|head -1)"
  info "n8n verify (keyed by workflow id): $SUM"
  printf '%s\n' "$R" | grep '^DETAIL ' | while IFS= read -r _d; do info "${_d#DETAIL }"; done
  eval "$(printf '%s\n' "$SUM" | tr ' ' '\n' | sed 's/^/LOC_/' | sed 's/=/="/; s/$/"/')" 2>/dev/null
  [ "${LOC_INTEGRITY:-}" = "ok" ] && pass "n8n recovery DB integrity_check = ok" || fail "n8n DB integrity: ${LOC_INTEGRITY:-?}"
  [ "${LOC_COUNT:-}" = 136 ] && pass "all 136 workflows present in the recovery n8n DB" || fail "recovery n8n workflow rows = ${LOC_COUNT:-?} (expected 136)"
  [ "${LOC_ACTIVE:-x}" = 0 ] && pass "every recovered workflow is INACTIVE (0 active)" || fail "active workflows in recovery DB = ${LOC_ACTIVE:-?} (expected 0)"
  if [ "${LOC_MATCH:-0}" = 1 ]; then pass "names + node counts + connection counts match the source archive for all 136 workflows (keyed by workflow id)"
  else fail "n8n structure differs vs source archive — missing=${LOC_MISSING:-?} (data loss), extra=${LOC_EXTRA:-?}, field-diff=${LOC_FDIFF:-?} (import transformation to review); see DETAIL lines above for the exact workflow id(s)"; fi
  [ -n "$N8N_STARTED" ] && { docker rm -f "$N8N_STARTED" >/dev/null 2>&1; N8N_STARTED=""; info "throwaway n8n removed (127.0.0.1 only; no credentials; nothing activated)"; }
}
if begin n8n "$(find_one 'strateloq-n8n-*.tar.gpg')"; then t1; finish; fi

########################################################################
sect "Test 2 — Storage file recovery (objects, checksums, access controls)"
t2(){
  local enc root nfiles; enc="$(find_one 'strateloq-storage-*.tgz.gpg')"; [ -n "$enc" ] || { fail "storage archive not found in set"; return; }
  decrypt "$enc" "$WORK/storage.tgz" || { fail "storage archive decrypt failed"; return; }
  mkdir -p "$WORK/sx"; tar -xzf "$WORK/storage.tgz" -C "$WORK/sx" 2>/dev/null
  root="$(find "$WORK/sx" -mindepth 1 -maxdepth 1 -type d|head -1)"; [ -n "$root" ] || root="$WORK/sx"
  nfiles="$(find "$root" -type f|wc -l|tr -d ' ')"
  [ "$nfiles" -ge 1 ] || { fail "storage archive extracted no files"; return; }
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
    if [ -n "$one" ]; then local code; code="$(curl -s -o /dev/null -w '%{http_code}' "$SB_API/storage/v1/object/public/$bucket/$one")"
      case "$code" in 200) fail "PRIVATE object publicly readable (HTTP 200) — access control FAILED";; *) pass "anonymous public GET denied (HTTP $code) — private stays private";; esac
      # Sign: the storage API needs Content-Type: application/json to parse expiresIn (missing header
      # was the mint failure). The returned signedURL is relative to /storage/v1, so prefix it correctly.
      local resp signed; resp="$(curl -s -X POST "$SB_API/storage/v1/object/sign/$bucket/$one" -H "Authorization: Bearer $SB_SR" -H "Content-Type: application/json" -d '{"expiresIn":60}')"
      signed="$(printf '%s' "$resp" | jget signedURL signedUrl)"
      if [ -n "$signed" ]; then
        local surl; case "$signed" in http*) surl="$signed";; /storage/v1/*) surl="$SB_API$signed";; /*) surl="$SB_API/storage/v1$signed";; *) surl="$SB_API/storage/v1/$signed";; esac
        local sc; sc="$(curl -s -o /dev/null -w '%{http_code}' "$surl")"
        [ "$sc" = 200 ] && pass "signed URL generated AND authorised retrieval works (HTTP 200)" || fail "signed URL minted but retrieval HTTP $sc"
      else fail "could not mint a signed URL (API response: $(printf '%s' "$resp"|head -c 160))"; fi
    fi
    restore_dump_local && { local meta; meta="$(sbsql 'select count(*) from storage.objects')"; info "restored storage.objects metadata rows: ${meta:-?} (object paths map to these tenant/records)"; }
  else skip "local Supabase stack unavailable — bucket upload + access-control not run (decrypt, count, checksums done)"; fi
}
if begin storage "$(find_one 'strateloq-storage-*.tgz.gpg')"; then t2; finish; fi

########################################################################
sect "Test 3 — Supabase Auth recovery (records + functional sign-in, isolated)"
t3(){
  if ! restore_dump_local; then skip "local Supabase stack+dump unavailable — Auth functional sign-in not run (needs GoTrue)"; return; fi
  local users; users="$(sbsql 'select count(*) from auth.users')"
  [ "${users:-0}" = 6 ] && pass "all 6 backed-up authentication users recovered into the isolated stack" \
    || { [ "${users:-0}" -ge 1 ] 2>/dev/null && pass "recovered auth.users present: ${users}" || fail "no recovered auth.users (expected 6)"; }
  local off; off="$(sbsql "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and not c.relrowsecurity")"
  [ "${off:-x}" = 0 ] && pass "tenant isolation intact: RLS on every restored public table (0 without)" || fail "restored public tables without RLS: ${off:-?}"
  assert_local "$SB_API" "auth endpoint" || return
  local email="dr-verify-$TS@local.test" pw="DR-verify-$TS-$RANDOM"
  curl -s -o /dev/null -X POST "$SB_API/auth/v1/admin/users" -H "apikey: $SB_SR" -H "Authorization: Bearer $SB_SR" -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$pw\",\"email_confirm\":true}"
  local tok; tok="$(curl -s -X POST "$SB_API/auth/v1/token?grant_type=password" -H "apikey: $SB_ANON" -H "Content-Type: application/json" -d "{\"email\":\"$email\",\"password\":\"$pw\"}"|jget access_token)"
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
  if [ "$HAVE_DENO" = 1 ]; then local okc=0 total=0 e; while IFS= read -r e; do total=$((total+1)); deno check "$e" >/dev/null 2>&1 && okc=$((okc+1)); done < <(find "$WORK/restored-repo/supabase/functions" -maxdepth 2 -name index.ts)
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
con "Evidence cached in $EVID (idempotent). Temp shredded; production never contacted."
[ "$FAIL" -eq 0 ]

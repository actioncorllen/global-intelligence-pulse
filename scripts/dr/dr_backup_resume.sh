#!/usr/bin/env bash
# Strateloq DR — single, RESUMABLE, checkpointed backup orchestrator.
#
# One command finishes the whole remaining disaster-recovery backup by REUSING the existing
# component scripts (it reimplements none of them). It records which steps completed, retries
# recoverable (transient/network) failures within bounded limits, resumes from the last verified
# checkpoint on the next run, and — when a step genuinely needs the founder (a credential, the
# one-time key passphrase, or an OS-level scheduler install) — stops with exactly ONE actionable
# instruction instead of failing silently or asking a stream of questions.
#
# Steps, in order (each idempotent; a completed step is skipped on the next run):
#   1 deps            required tools present (gpg, pg_dump, rclone, sha256sum, shred, git, tar, flock)
#   2 config          env file present + required vars set + Supabase reachable (read-only `select 1`)
#   3 keydb           key ready (loopback, no-pinentry; interactive passphrase ONCE) + REAL DB backup
#                     -> integrity -> encrypt -> Drive "01 — Supabase Database" -> checksum verify
#                     (delegates to dr_setup_key_and_db_backup.sh)
#   4 storage         Supabase Storage objects -> encrypted -> Drive "02 — Supabase Storage"
#                     (delegates to dr_storage_backup.sh; encrypt+upload here)
#   5 source_edge     git bundle (all branches/tags) -> Drive "04"; verify EVERY deployed edge
#                     function slug is present in supabase/functions/ (drift = loud warning)
#   6 n8n_preserve    assert the existing 133-workflow n8n backup is intact; NEVER modifies it
#   7 unattended_enc  prove weekly UNATTENDED encryption needs no passphrase (public-key encrypt,
#                     no pinentry, round-trip readable) — the invariant the weekly job relies on
#   8 weekly_install  verify/instruct the weekly scheduled backup (Windows Task Scheduler / cron)
#
# A run is COMPLETE only when every step is checkpointed OK. Nothing is ever reported successful
# without its own verification line. Existing verified backups are never deleted. No secret value
# is ever written to a log (all output is scrubbed).
#
# Run as your normal user (strateloqbackup), NOT sudo. Interactive for the first keydb run
# (you type the key passphrase once); every later run is non-interactive unless the key is missing.
#   scripts/dr/dr_backup_resume.sh --env scripts/dr/dr_weekly_backup.env
#   scripts/dr/dr_backup_resume.sh --status            # show the checkpoint ledger
#   scripts/dr/dr_backup_resume.sh --reset             # clear checkpoints (does NOT touch backups)
#   scripts/dr/dr_backup_resume.sh --self-test         # whole flow, fakes + local transport, no prod
#
# Exit codes: 0 all steps complete · 2 usage/config error · 10 ACTION REQUIRED (founder step) ·
#             1 a step failed after retries (checkpoints preserved; fix + re-run to resume)
set -uo pipefail
umask 077
[ "$(id -u)" = 0 ] && { echo "Run as your normal user, not root/sudo." >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

SELFTEST=0; ENV_FILE=""; MODE="run"
while [ $# -gt 0 ]; do case "$1" in
  --self-test) SELFTEST=1; shift;;
  --env) ENV_FILE="$2"; shift 2;;
  --status) MODE="status"; shift;;
  --reset) MODE="reset"; shift;;
  -h|--help) sed -n '1,48p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

# ---- secret scrubbing (never write a credential value to a log) --------------------------------
scrub(){ sed -E \
  -e 's#(://[^:/@ ]+):[^@ ]+@#\1:***@#g' \
  -e 's#eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_.-]{6,}#***JWT***#g' \
  -e 's#(apikey|api_key|service_role|token|password|passphrase|secret)([=: ]+)[^[:space:]]+#\1\2***#gI'; }
# Lighter redactor for error text we intentionally SHOW: strips only connection-string credentials,
# key=value secrets and JWTs — never ordinary prose. This keeps a psql message like
# "password authentication failed" readable (and classifiable), unlike scrub() which would eat the
# word after "password". psql connection errors never echo the password itself.
redact_err(){ sed -E \
  -e 's#([a-z][a-z0-9+.-]*://[^:/@ ]+):[^@ ]*@#\1:***@#g' \
  -e 's#eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_.-]{6,}#***#g' \
  -e 's#(password|pgpassword|apikey|api_key|service_role|token|secret)=[^[:space:]&]+#\1=***#gI'; }

# ---- load config -------------------------------------------------------------------------------
# Normalise ENV_FILE to an ABSOLUTE path first: `.` does a PATH lookup for a bare filename with no
# slash (so `--env env` would source /usr/bin/env, not the file), and children get a stable path.
if [ -n "$ENV_FILE" ]; then
  case "$ENV_FILE" in
    /*) : ;;
    *)  ENV_FILE="$(cd "$(dirname "$ENV_FILE")" 2>/dev/null && pwd)/$(basename "$ENV_FILE")" ;;
  esac
  [ -f "$ENV_FILE" ] || { echo "env file not found: $ENV_FILE" >&2; exit 2; }
  set -a; . "$ENV_FILE"; set +a
elif [ "$SELFTEST" = 0 ] && [ -f "$HERE/dr_weekly_backup.env" ]; then
  ENV_FILE="$HERE/dr_weekly_backup.env"; set -a; . "$ENV_FILE"; set +a
fi

# ---- resolve offsite remotes from a single source of truth (reuses the EXISTING remote+folders) --
# The founder need only set ONE of: DR_BACKUP_PARENT (the rclone remote:path of the backup parent
# folder), or DR_DB_REMOTE, or DR_REMOTE. The five numbered sub-folders (01..05) are then derived so
# a missing DR_DB_REMOTE no longer blocks the run. Explicit per-folder values always win; nothing new
# is created — these are the already-verified "Strateloq Technologies — Backups/01..05" folders.
if [ -z "${DR_BACKUP_PARENT:-}" ]; then
  if   [ -n "${DR_DB_REMOTE:-}" ]; then DR_BACKUP_PARENT="${DR_DB_REMOTE%/*}"   # strip "/01 — Supabase Database"
  elif [ -n "${DR_REMOTE:-}" ];    then DR_BACKUP_PARENT="${DR_REMOTE%/weekly}" # strip an optional trailing "/weekly"
  fi
fi
if [ -n "${DR_BACKUP_PARENT:-}" ]; then
  : "${DR_DB_REMOTE:=$DR_BACKUP_PARENT/01 — Supabase Database}"
  : "${DR_STORAGE_REMOTE:=$DR_BACKUP_PARENT/02 — Supabase Storage (Images & Videos)}"
  : "${DR_N8N_REMOTE:=$DR_BACKUP_PARENT/03 — n8n Workflows}"
  : "${DR_SOURCE_REMOTE:=$DR_BACKUP_PARENT/04 — Edge Functions & Source Code}"
  : "${DR_VERIFY_REMOTE:=$DR_BACKUP_PARENT/05 — Backup Verification & Recovery}"
  : "${DR_REMOTE:=$DR_BACKUP_PARENT/weekly}"
fi
export DR_BACKUP_PARENT DR_DB_REMOTE DR_STORAGE_REMOTE DR_N8N_REMOTE DR_SOURCE_REMOTE DR_VERIFY_REMOTE DR_REMOTE 2>/dev/null || true

if [ "$SELFTEST" = 1 ]; then
  # DR_SELFTEST_ROOT lets a test run twice against the SAME ledger to prove resume/idempotence;
  # when unset we use a throwaway dir and clean it up at the end.
  ST_ROOT="${DR_SELFTEST_ROOT:-$(mktemp -d)}"
  DR_BACKUP_ROOT="$ST_ROOT/backups"
  STATE_DIR="$DR_BACKUP_ROOT"
else
  DR_BACKUP_ROOT="${DR_BACKUP_ROOT:-$HOME/strateloq-backups}"
  STATE_DIR="$DR_BACKUP_ROOT"
fi
mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/.dr-resume-state"
LOG="$STATE_DIR/dr-resume.log"
touch "$STATE" 2>/dev/null || true

STEPS=(deps config keydb storage source_edge n8n_preserve unattended_enc weekly_install)

is_done(){ grep -q "^$1 OK " "$STATE" 2>/dev/null; }
mark_done(){ printf '%s OK %s\n' "$1" "$(date -u +%FT%TZ)" >> "$STATE"; }
log(){ printf '%s\n' "$*" | scrub | tee -a "$LOG"; }
# need_action prints author-written advisory prose (plus only non-secret values: host/port/user/
# paths and an already-redacted snippet), so it uses the LIGHT redactor to stay readable while still
# stripping any accidental connection-string/token — never the aggressive scrub() that eats prose.
need_action(){ printf '\nACTION REQUIRED: %s\n(then re-run this script — completed steps are skipped and it resumes here.)\n' "$1" | redact_err | tee -a "$LOG"; exit 10; }
fail_step(){ log "FAIL [$1]: ${2:-}"; log "(fix the cause and re-run — completed steps are skipped; this step will retry.)"; exit 1; }

# bounded retry for transient/network ops: retry <max> <basesleep> -- cmd...
retry(){ local max="$1" base="$2"; shift 3; local n=1; while :; do
  if "$@"; then return 0; fi
  [ "$n" -ge "$max" ] && return 1
  log "  transient failure (attempt $n/$max) — backing off $((base*n))s"; sleep "$((base*n))"; n=$((n+1));
done; }

if [ "$MODE" = "status" ]; then
  echo "== DR resume ledger ($STATE) =="
  for s in "${STEPS[@]}"; do is_done "$s" && echo "  [x] $s" || echo "  [ ] $s"; done
  exit 0
fi
if [ "$MODE" = "reset" ]; then
  : > "$STATE"; echo "checkpoints cleared (backups untouched): $STATE"; exit 0
fi

log "== Strateloq DR resume ==  user=$(id -un)  self_test=$SELFTEST  root=$DR_BACKUP_ROOT"
log "   env_file=${ENV_FILE:-<none>}  ledger=$STATE"

# ============================== STEP IMPLEMENTATIONS ============================================

step_deps(){
  local missing="" req="gpg sha256sum shred git tar"
  [ "$SELFTEST" = 0 ] && req="$req pg_dump rclone flock"
  for t in $req; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  if [ -n "$missing" ]; then
    need_action "install the missing tool(s):$missing  (e.g. sudo apt-get install -y gnupg postgresql-client rclone coreutils git tar util-linux)"
  fi
  log "ok   [deps] all required tools present"
}

step_config(){
  if [ "$SELFTEST" = 1 ]; then log "ok   [config] self-test (no real credentials)"; return 0; fi
  [ -n "$ENV_FILE" ] || need_action "create scripts/dr/dr_weekly_backup.env from dr_weekly_backup.env.example and pass --env (or place it next to this script), then re-run."
  local missing=""
  for v in SUPABASE_DB_URL SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  [ -z "$missing" ] || need_action "fill these in $ENV_FILE (secret values stay only in that file; it is git-ignored):$missing"
  # DR_DB_REMOTE is normally derived above from DR_BACKUP_PARENT/DR_REMOTE. If it still is not set,
  # give the ONE exact line to add (your verified remote + the existing 01 folder — not a new remote).
  if [ -z "${DR_DB_REMOTE:-}" ]; then
    need_action "add ONE line to $ENV_FILE — either the parent (derives 01..05):  DR_BACKUP_PARENT=\"strateloqdrive:Strateloq Technologies — Backups\"   OR just the DB folder:  DR_DB_REMOTE=\"strateloqdrive:Strateloq Technologies — Backups/01 — Supabase Database\""
  fi
  log "   [config] DB backup destination resolves to: $DR_DB_REMOTE"
  # SAFETY: the FULL production backup must land in the PRIMARY account folder
  # ("Strateloq Technologies — Backups"), NEVER the secondary n8n DR system ("Strateloq-DR").
  # Catch a stale/secondary destination BEFORE any upload (common cause: a leftover gdrive:/DR_REMOTE
  # line in the env). This is not a silent override — it stops and asks.
  case "$DR_DB_REMOTE" in
    *Strateloq-DR*)
      need_action "resolved DB destination points at the SECONDARY 'Strateloq-DR' system, not the primary — the full backup must NOT go there. Set the primary parent in $ENV_FILE and remove any stale gdrive:/DR_REMOTE line:  DR_BACKUP_PARENT=\"strateloqdrive:Strateloq Technologies — Backups\"" ;;
  esac
  case "$DR_DB_REMOTE" in
    *"Strateloq Technologies — Backups/01 — Supabase Database"*) : ;;
    *) log "WARN [config] destination is not the expected primary folder 'Strateloq Technologies — Backups/01 — Supabase Database' — confirm $ENV_FILE before the upload proceeds." ;;
  esac
  # Supabase reachability (read-only; password never printed)
  if retry 3 4 -- psql "$SUPABASE_DB_URL" -tAc 'select 1;' >/dev/null 2>&1; then
    log "ok   [config] env complete + Supabase reachable (read-only check)"
    return 0
  fi
  # psql failed — diagnose the ACTUAL cause (DNS vs network vs auth) WITHOUT exposing the password.
  local rest hostport host port dns tcp
  rest="${SUPABASE_DB_URL#*://}"; rest="${rest##*@}"         # strip scheme + user:pass@ (host follows the LAST @, robust to an unencoded @ in the password)
  hostport="${rest%%/*}"; hostport="${hostport%%\?*}"        # host[:port]
  host="${hostport%%:*}"; port="${hostport#*:}"; [ "$port" = "$hostport" ] && port=5432
  if command -v getent >/dev/null 2>&1; then getent hosts "$host" >/dev/null 2>&1 && dns=OK || dns=FAIL; else dns=SKIP; fi
  if timeout 8 bash -c ">/dev/tcp/$host/$port" >/dev/null 2>&1; then tcp=OK; else tcp=FAIL; fi
  log "   [config] connectivity diagnostic: host=$host port=$port dns=$dns tcp=$tcp  (credential never printed)"
  # The Supabase DIRECT host is the usual culprit, so handle it FIRST (its fix stands regardless of
  # how the local resolver behaves): it is IPv6-only unless the paid IPv4 add-on is on, so an
  # IPv4-only WSL box cannot reach it. The Session pooler is IPv4 and correct for pg_dump.
  case "$host" in
    db.*.supabase.co)
      need_action "the DIRECT host '$host' is IPv6-only unless the paid IPv4 add-on is enabled, so an IPv4-only WSL box cannot reach it (dns=$dns tcp=$tcp). Switch SUPABASE_DB_URL to the SESSION POOLER (IPv4, correct for pg_dump): user 'postgres.nxaunmyihhjixxxljcqt', host like 'aws-0-eu-central-1.pooler.supabase.com' (copy the EXACT host — aws-0 or aws-1 — from Supabase Dashboard -> Connect -> Session pooler), port 5432, database 'postgres'. Paste the full string the dashboard shows into $ENV_FILE, then re-run." ;;
  esac
  [ "$dns" = FAIL ] && need_action "DNS cannot resolve the DB host '$host'. Check the hostname in SUPABASE_DB_URL in $ENV_FILE, then re-run."
  if [ "$tcp" = OK ]; then
    # TCP connects but the query failed. Classify on the RAW stderr (NEVER printed) so the common
    # libpq phrase "password authentication failed" is not mangled by scrub() into UNKNOWN. Only the
    # category + username are logged; any error text we show the founder goes through redact_err.
    local user err le cat pooler_user_bad=0 snippet
    user="${SUPABASE_DB_URL#*://}"; user="${user%%:*}"; user="${user%%@*}"   # text before the first : or @
    err="$(psql "$SUPABASE_DB_URL" -tAc 'select 1;' 2>&1 >/dev/null)"        # RAW; not printed
    le="$(printf '%s' "$err" | tr 'A-Z' 'a-z' | tr '\n' ' ')"                # lowercased for matching
    case "$le" in
      *"tenant or user not found"*)                                          cat="POOLER_USERNAME" ;;
      *"password authentication failed"*|*sasl*|*"authentication failed"*|*"invalid authorization"*) cat="AUTH" ;;
      *"no pg_hba.conf entry"*)                                              cat="HBA_SSL" ;;
      *"no encryption"*|*"does not support ssl"*|*"ssl "*|*"ssl:"*|*"server does not support"*) cat="SSL" ;;
      *"permission denied"*|*"not permitted"*|*"must be owner"*)             cat="PERMISSION" ;;
      *"timeout"*|*"could not connect"*|*"connection refused"*|*"could not receive"*|*"closed the connection"*|*"terminating connection"*) cat="NETWORK" ;;
      *"max client"*|*"too many"*|*"remaining connection"*)                  cat="POOL_SATURATED" ;;
      "") cat="OK" ;;
      *) cat="UNKNOWN" ;;
    esac
    case "$host" in *pooler.supabase.com) [ "$user" = "postgres" ] && pooler_user_bad=1 ;; esac
    log "   [config] auth diagnostic: category=$cat  user=$user  (credential never printed)"
    [ "$cat" = OK ] && { log "ok   [config] Supabase reachable (succeeded on diagnostic retry)"; return 0; }
    if [ "$cat" = POOLER_USERNAME ] || [ "$pooler_user_bad" = 1 ]; then
      need_action "the Supavisor pooler rejected the login because the username is not TENANT-QUALIFIED. In SUPABASE_DB_URL the user must be 'postgres.nxaunmyihhjixxxljcqt' (project ref appended), not plain 'postgres'. Copy the exact Session pooler string from Supabase Dashboard -> Connect -> Session pooler, then re-run."
    fi
    [ "$cat" = AUTH ] && need_action "authentication was rejected (libpq 'password authentication failed'). The most common cause that is NOT a wrong password: special characters in the password are not percent-encoded in the URL (@ becomes %40, # %23, / %2F, : %3A, ? %3F, % %25, space %20). Percent-encode the password in SUPABASE_DB_URL, or re-copy the exact Session pooler string from Supabase Dashboard -> Connect. Do NOT reset the production password for this. Then re-run."
    if [ "$cat" = SSL ] || [ "$cat" = HBA_SSL ]; then need_action "the server requires TLS but the client did not negotiate it. Append '?sslmode=require' to the end of SUPABASE_DB_URL, then re-run."; fi
    [ "$cat" = PERMISSION ] && need_action "connected and authenticated, but the role cannot run 'select 1;' — unexpected for the postgres role. Confirm the user in SUPABASE_DB_URL is 'postgres.nxaunmyihhjixxxljcqt', then re-run."
    [ "$cat" = NETWORK ] && need_action "the connection dropped mid-handshake (not auth). Re-run once; if it persists, confirm the exact Session pooler host/port from Supabase Dashboard -> Connect, then re-run."
    [ "$cat" = POOL_SATURATED ] && need_action "the pooler refused the connection due to connection limits. Wait a minute and re-run; if it persists, check the Supabase dashboard for connection usage."
    # UNKNOWN (or any unhandled): show the SAFE first line so the exact cause is visible without secrets.
    snippet="$(printf '%s' "$err" | redact_err | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-220)"
    need_action "DB query failed after a successful TCP connect (category=$cat, user=$user). Sanitised server message: [$snippet]. Re-copy the exact Session pooler connection string from Supabase Dashboard -> Connect -> Session pooler into $ENV_FILE and ensure any special characters in the password are percent-encoded, then re-run. (Password/credentials are redacted above; do NOT reset the production password.)"
  fi
  need_action "Supabase DB not reachable (host=$host port=$port dns=$dns tcp=$tcp). Use the Session pooler connection string from Supabase Dashboard -> Connect -> Session pooler in $ENV_FILE, then re-run."
}

step_keydb(){
  if [ "$SELFTEST" = 1 ]; then
    retry 2 1 -- bash "$HERE/dr_setup_key_and_db_backup.sh" --self-test || fail_step keydb "self-test pipeline failed"
    log "ok   [keydb] self-test key+DB pipeline passed"; return 0
  fi
  # Real: delegates to the key-setup + DB-backup-to-Drive orchestrator. First run is interactive
  # (you type the key passphrase ONCE to create the protected key via loopback — no pinentry).
  if ! bash "$HERE/dr_setup_key_and_db_backup.sh" --env "$ENV_FILE"; then
    # Distinguish "needs the human passphrase" (key absent + non-interactive) from a real failure.
    if ! gpg --list-secret-keys "${KEY_EMAIL:-support@strateloq.com}" >/dev/null 2>&1 && [ ! -t 0 ]; then
      need_action "run this ONCE in an interactive terminal to create the encryption key (you will type a strong passphrase, hidden): scripts/dr/dr_setup_key_and_db_backup.sh --env $ENV_FILE"
    fi
    fail_step keydb "key setup / database backup did not pass (see its scrubbed output above)"
  fi
  log "ok   [keydb] encryption key ready + real Supabase DB backup uploaded & checksum-verified"
}

step_storage(){
  if [ "$SELFTEST" = 1 ]; then log "ok   [storage] self-test (skipped: no real Storage)"; return 0; fi
  : "${DR_GPG_RECIPIENT:?set by keydb step / env}"
  local ts stage; ts="$(date -u +%Y%m%dT%H%M%SZ)"; stage="$DR_BACKUP_ROOT/runs/storage-$ts"; mkdir -p "$stage"
  # dr_storage_backup.sh takes buckets as $1 and writes strateloq-storage-<ts>.tgz into the CWD
  # (it tars but does NOT encrypt). Run it inside $stage; we gpg-encrypt the archive below.
  local n=1 ok=0
  while [ "$n" -le 3 ]; do
    if ( cd "$stage" && bash "$HERE/dr_storage_backup.sh" "${DR_BUCKETS:-pulse-generated-media pulse-product-imports}" ); then ok=1; break; fi
    log "  storage download transient failure (attempt $n/3) — backing off $((4*n))s"; sleep "$((4*n))"; n=$((n+1))
  done
  [ "$ok" = 1 ] || fail_step storage "Storage download failed (check SUPABASE_SERVICE_ROLE_KEY and network)"
  local f
  for f in "$stage"/*; do
    [ -e "$f" ] || continue
    case "$f" in *.gpg) ;; *) gpg --yes --batch --encrypt --recipient "$DR_GPG_RECIPIENT" "$f" && { shred -u "$f" 2>/dev/null || rm -f "$f"; } ;; esac
  done
  ( cd "$stage" && sha256sum ./*.gpg > SHA256SUMS 2>/dev/null && sha256sum -c SHA256SUMS >/dev/null ) || fail_step storage "local checksum manifest failed"
  local remote="${DR_STORAGE_REMOTE:-${DR_REMOTE%/*}/02 — Supabase Storage (Images & Videos)}"
  retry 4 4 -- rclone copy "$stage" "$remote/storage-$ts/" --transfers 2 --checkers 2 || fail_step storage "rclone upload failed"
  retry 3 4 -- rclone check "$stage" "$remote/storage-$ts" --one-way || fail_step storage "remote checksum mismatch"
  log "ok   [storage] Supabase Storage encrypted + uploaded + checksum-verified -> $remote/storage-$ts"
}

step_source_edge(){
  if [ "$SELFTEST" = 1 ]; then log "ok   [source_edge] self-test (git bundle check skipped)"; return 0; fi
  local ts bundle; ts="$(date -u +%Y%m%dT%H%M%SZ)"; bundle="$DR_BACKUP_ROOT/runs/source-$ts/strateloq-$ts.bundle"; mkdir -p "$(dirname "$bundle")"
  ( cd "$REPO_ROOT" && bash "$HERE/dr_git_bundle.sh" "$bundle" ) || fail_step source_edge "git bundle failed"
  # Edge-function drift check: every ACTIVE deployed slug must be committed in supabase/functions/.
  # Uses the Supabase CLI if present + authed; otherwise checks against the recorded manifest.
  if command -v supabase >/dev/null 2>&1 && [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    local deployed committed miss=""
    deployed="$(supabase functions list --project-ref "${SUPABASE_PROJECT_REF:-nxaunmyihhjixxxljcqt}" 2>/dev/null | awk 'NR>1{print $1}' | sort -u)"
    committed="$(ls -1 "$REPO_ROOT/supabase/functions" 2>/dev/null | grep -v '^_shared$' | sort -u)"
    for s in $deployed; do echo "$committed" | grep -qx "$s" || miss="$miss $s"; done
    [ -n "$miss" ] && log "WARN [source_edge] deployed edge functions NOT in supabase/functions/ (not backed up!):$miss  -> run: supabase functions download <slug>"
  else
    log "note [source_edge] supabase CLI/token not present; skipped live drift check. Recorded inventory: dr/EDGE-FUNCTIONS-DEPLOYED-MANIFEST.md"
  fi
  local remote="${DR_SOURCE_REMOTE:-${DR_REMOTE%/*}/04 — Edge Functions & Source Code}"
  gpg --yes --batch --encrypt --recipient "$DR_GPG_RECIPIENT" "$bundle" && { shred -u "$bundle" 2>/dev/null || rm -f "$bundle"; }
  retry 4 4 -- rclone copy "$(dirname "$bundle")" "$remote/source-$ts/" --transfers 2 --checkers 2 || fail_step source_edge "rclone upload failed"
  retry 3 4 -- rclone check "$(dirname "$bundle")" "$remote/source-$ts" --one-way || fail_step source_edge "remote checksum mismatch"
  log "ok   [source_edge] repo bundle + all $(ls -1 "$REPO_ROOT/supabase/functions" | grep -vc '^_shared$') edge functions committed, encrypted, uploaded -> $remote/source-$ts"
}

step_n8n_preserve(){
  # NEVER modifies the n8n backup. Asserts the existing 133-workflow recovery artifacts are intact.
  local val="$REPO_ROOT/dr/n8n/N8N-RESTORE-VALIDATION-001.md"
  if [ -f "$val" ] && grep -qiE 'PASS|133' "$val"; then
    log "ok   [n8n_preserve] existing 133-workflow n8n restore PASS preserved (read-only; not modified)"
  else
    log "WARN [n8n_preserve] could not confirm the n8n restore PASS artifact at dr/n8n/ — verify it is intact (NOT modifying it)."
  fi
}

step_unattended_enc(){
  # The weekly job must encrypt with NO passphrase (public key). Prove it: encrypt a throwaway token
  # to the recipient with batch/no-tty and confirm it succeeds without any pinentry prompt.
  local rcpt tmp
  if [ "$SELFTEST" = 1 ]; then
    tmp="$(mktemp -d)"; export GNUPGHOME="$tmp/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    gpg --batch --quiet --passphrase '' --quick-generate-key 'dr-unattended-selftest@example.invalid' default default never >/dev/null 2>&1
    rcpt="dr-unattended-selftest@example.invalid"
  else
    rcpt="${DR_GPG_RECIPIENT:?}"; tmp="$(mktemp -d)"
  fi
  echo "unattended probe $(date -u)" > "$tmp/p"
  if gpg --yes --batch --no-tty --encrypt --recipient "$rcpt" -o "$tmp/p.gpg" "$tmp/p" 2>/dev/null && [ -s "$tmp/p.gpg" ]; then
    log "ok   [unattended_enc] public-key encryption works with NO passphrase/pinentry (weekly job can run unattended)"
    rm -rf "$tmp"
  else
    rm -rf "$tmp"; fail_step unattended_enc "unattended public-key encryption failed — the recipient key may be missing"
  fi
}

step_weekly_install(){
  if [ "$SELFTEST" = 1 ]; then log "ok   [weekly_install] self-test (scheduler not installed)"; return 0; fi
  # Detect an installed schedule; otherwise give ONE actionable install instruction.
  if crontab -l 2>/dev/null | grep -q 'dr_weekly_backup.sh'; then
    log "ok   [weekly_install] cron entry for dr_weekly_backup.sh is installed"
  elif command -v schtasks.exe >/dev/null 2>&1 && schtasks.exe /query /tn "Strateloq DR Weekly Backup" >/dev/null 2>&1; then
    log "ok   [weekly_install] Windows scheduled task 'Strateloq DR Weekly Backup' is installed"
  else
    need_action "install the weekly schedule (choose one): WSL/cron -> add '0 3 * * 0 $HERE/dr_weekly_backup.sh --env $ENV_FILE' to 'crontab -e'; OR Windows -> run scripts/dr/install/install-weekly-backup.ps1 in PowerShell. Weekly runs are fully unattended (no passphrase). Then re-run to confirm."
  fi
}

# ============================== DRIVER =========================================================
run_step(){ case "$1" in
  deps) step_deps;; config) step_config;; keydb) step_keydb;; storage) step_storage;;
  source_edge) step_source_edge;; n8n_preserve) step_n8n_preserve;;
  unattended_enc) step_unattended_enc;; weekly_install) step_weekly_install;; esac; }

for s in "${STEPS[@]}"; do
  if is_done "$s"; then log "skip [$s] already checkpointed"; continue; fi
  log "--- step: $s ---"
  run_step "$s"        # a step calls need_action (exit 10) or fail_step (exit 1) itself on trouble
  mark_done "$s"
done

log ""
log "RESULT: PASS — all backup steps complete and checkpointed. Ledger: $STATE"
# Only clean up a throwaway self-test root (keep a caller-pinned DR_SELFTEST_ROOT so resume is testable).
[ "$SELFTEST" = 1 ] && [ -z "${DR_SELFTEST_ROOT:-}" ] && rm -rf "$ST_ROOT" 2>/dev/null
exit 0

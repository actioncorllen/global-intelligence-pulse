#!/usr/bin/env bash
# Strateloq DR — weekly automated backup orchestrator (WSL/Ubuntu side).
#
# Reuses the existing component scripts (does NOT reimplement them):
#   dr_git_bundle.sh         full-repo git bundle (all branches+tags)
#   dr_db_logical_backup.sh  pg_dump -Fc of Supabase Postgres, gpg-encrypted
#   dr_storage_backup.sh     Supabase Storage objects -> tar (this script then gpg-encrypts)
#   dr_n8n_export.sh         every n8n workflow definition (active/inactive/archived) -> JSON
#
# Adds the automation layer the requirements call for:
#   * single-run lock (flock) — no overlapping runs
#   * encrypt-before-upload: every uploaded artifact is *.gpg; plaintext is shredded;
#     the staging dir is asserted plaintext-free before any upload
#   * checksum manifest (SHA256SUMS) + post-upload checksum VERIFY -> PASS/FAIL recorded
#   * a run is SUCCESS only if every component collected AND the upload verified; a partial
#     run is FAIL, is never marked success, and is never uploaded as if complete
#   * never deletes anything on failure; retention prunes only OLD *successful* sets, never
#     the newest, keeping storage growth bounded (DR_RETAIN sets)
#   * failure logging with secret scrubbing — no credential value is ever written to a log
#
# Transport is abstracted so the full pipeline is testable without touching production:
#   DR_TRANSPORT=rclone (default)  -> uploads to a configured rclone remote (e.g. Google Drive)
#   DR_TRANSPORT=local             -> copies to a local dir (used by --self-test; also a valid
#                                     on-disk secondary copy)
#
# Production run is READ-ONLY against Supabase and n8n (dumps/exports only). It never modifies
# production workflows, credentials, keys, or Supabase data, and makes no paid provider call.
#
# Config comes from the environment or an env file (see dr_weekly_backup.env.example):
#   SUPABASE_DB_URL SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY N8N_BASE_URL N8N_API_KEY
#   DR_GPG_RECIPIENT DR_REMOTE [DR_TRANSPORT] [DR_BACKUP_ROOT] [DR_RETAIN] [DR_BUCKETS]
#
# Usage:
#   dr_weekly_backup.sh [--env <file>] [--self-test]
# Exit codes: 0 success(PASS) · 2 config error · 3 another run in progress · 1 backup FAILED
set -uo pipefail
umask 077   # artifacts and logs are created private (0600/0700)

HERE="$(cd "$(dirname "$0")" && pwd)"
SELFTEST=0
ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) SELFTEST=1; shift;;
    --env) ENV_FILE="$2"; shift 2;;
    -h|--help) sed -n '1,45p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# ---- secret scrubbing for logs (never write a credential value) --------------------------
scrub() {
  sed -E \
    -e 's#(://[^:/@ ]+):[^@ ]+@#\1:***@#g' \
    -e 's#eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_.-]{6,}#***JWT-REDACTED***#g' \
    -e 's#(X-N8N-API-KEY:)[[:space:]]*[^[:space:]]+#\1 ***#gI' \
    -e 's#(apikey|api_key|key|token|password|service_role)([=:])[^[:space:]&]+#\1\2***#gI'
}

# Append an early, scrubbed diagnostic line to a persistent log, so a SCHEDULED run that fails BEFORE
# the per-run log exists (bad env path, missing config) still leaves evidence — a Task Scheduler
# "LastTaskResult 2" is otherwise opaque. Falls back to $HOME when DR_BACKUP_ROOT is not set yet.
startlog(){ local d="${DR_BACKUP_ROOT:-$HOME/strateloq-backups}"; mkdir -p "$d" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | scrub >> "$d/dr-weekly-start.log" 2>/dev/null || true; }
# Source a copy with a UTF-8 BOM / CR stripped (Windows/WSL gremlins); the founder's file is unchanged.
clean_env(){ sed -e "1s/^$(printf '\357\273\277')//" -e 's/\r$//' "$1"; }
# Encrypt LOCAL-ONLY (no network WKD) and with trust assumed (no interactive prompt) so the
# unattended scheduled run never hangs or does a surprise lookup.
gpg_encrypt(){ gpg --yes --batch --no-tty --no-auto-key-locate --trust-model always --encrypt --recipient "$@"; }
# Resolve DR_GPG_RECIPIENT to a LOCAL public key: the env value if it resolves, else the backup key's
# UID support@strateloq.com, else the env value unchanged (encrypt then fails with a clear message).
resolve_recipient(){
  local r="${DR_GPG_RECIPIENT:-}"
  if [ -n "$r" ] && gpg --list-keys --no-auto-key-locate "$r" >/dev/null 2>&1; then printf '%s' "$r"; return; fi
  if gpg --list-keys --no-auto-key-locate "support@strateloq.com" >/dev/null 2>&1; then printf '%s' "support@strateloq.com"; return; fi
  printf '%s' "$r"
}

# ---- config ------------------------------------------------------------------------------
if [ -n "$ENV_FILE" ]; then
  if [ ! -f "$ENV_FILE" ]; then echo "env file not found: $ENV_FILE" >&2; startlog "FATAL env file not found: $ENV_FILE (exit 2) — check the -RepoPath the scheduled task was installed with."; exit 2; fi
  # shellcheck disable=SC1090
  set -a; . <(clean_env "$ENV_FILE"); set +a
elif [ -f "$HERE/dr_weekly_backup.env" ] && [ "$SELFTEST" = 0 ]; then
  set -a; . <(clean_env "$HERE/dr_weekly_backup.env"); set +a
fi

DR_TRANSPORT="${DR_TRANSPORT:-rclone}"
DR_RETAIN="${DR_RETAIN:-8}"
DR_BUCKETS="${DR_BUCKETS:-pulse-generated-media}"
RCLONE_BIN="${RCLONE_BIN:-rclone}"

# ---- transport abstraction ---------------------------------------------------------------
# transport_put_dir <local_dir> <set_name>   : upload all files in local_dir to <remote>/<set>
# transport_verify  <local_dir> <set_name>   : checksum-verify remote copy against local (0=ok)
# transport_list_sets                          : print existing set names, one per line
# transport_purge_set <set_name>               : delete one set (used only for retention)
transport_put_dir() {
  local src="$1" set="$2"
  case "$DR_TRANSPORT" in
    rclone) "$RCLONE_BIN" copy "$src" "$DR_REMOTE/$set/" --transfers 2 --checkers 2 ;;
    local)  mkdir -p "$DR_REMOTE/$set" && cp -a "$src"/. "$DR_REMOTE/$set"/ ;;
    *) echo "unknown DR_TRANSPORT=$DR_TRANSPORT" >&2; return 2;;
  esac
}
transport_verify() {
  local src="$1" set="$2"
  case "$DR_TRANSPORT" in
    rclone)
      # rclone check (one-way) compares md5 of every local file against the remote copy.
      "$RCLONE_BIN" check "$src" "$DR_REMOTE/$set" --one-way ;;
    local)
      # re-read the uploaded bytes and re-verify against the local SHA256SUMS manifest.
      ( cd "$DR_REMOTE/$set" && sha256sum -c SHA256SUMS >/dev/null ) ;;
  esac
}
transport_list_sets() {
  case "$DR_TRANSPORT" in
    rclone) "$RCLONE_BIN" lsf "$DR_REMOTE" --dirs-only 2>/dev/null | sed 's#/$##' ;;
    local)  [ -d "$DR_REMOTE" ] && ls -1 "$DR_REMOTE" 2>/dev/null || true ;;
  esac
}
transport_purge_set() {
  local set="$1"
  case "$DR_TRANSPORT" in
    rclone) "$RCLONE_BIN" purge "$DR_REMOTE/$set" ;;
    local)  rm -rf "${DR_REMOTE:?}/$set" ;;
  esac
}

# ---- self-test scaffolding ---------------------------------------------------------------
# Generates a throwaway gpg key + a local transport + fake component artifacts, so the whole
# encrypt/checksum/upload/verify/retention/lock pipeline runs with zero production access.
SELFTEST_TMP=""
if [ "$SELFTEST" = 1 ]; then
  SELFTEST_TMP="$(mktemp -d)"
  export GNUPGHOME="$SELFTEST_TMP/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-generate-key 'strateloq-dr-selftest@example.invalid' \
      default default never >/dev/null 2>&1
  DR_GPG_RECIPIENT="strateloq-dr-selftest@example.invalid"
  DR_TRANSPORT="local"
  # honour pre-set paths so retention can be exercised across several runs in one root
  DR_REMOTE="${DR_REMOTE:-$SELFTEST_TMP/remote}"
  DR_BACKUP_ROOT="${DR_BACKUP_ROOT:-$SELFTEST_TMP/backups}"
  DR_RETAIN="${DR_RETAIN:-2}"
fi

DR_BACKUP_ROOT="${DR_BACKUP_ROOT:-$HOME/strateloq-backups}"

# ---- derive the destination from a single parent (same contract as dr_backup_resume.sh) ---
# An env that sets only DR_BACKUP_PARENT (the primary backup folder) is sufficient; DR_REMOTE is
# derived from it. This is why the one-time orchestrator succeeded with the same env while the old
# weekly job exited 2 on a missing DR_REMOTE.
if [ "$SELFTEST" = 0 ]; then
  if [ -z "${DR_BACKUP_PARENT:-}" ] && [ -n "${DR_REMOTE:-}" ]; then DR_BACKUP_PARENT="${DR_REMOTE%/weekly}"; fi
  [ -n "${DR_BACKUP_PARENT:-}" ] && : "${DR_REMOTE:=$DR_BACKUP_PARENT/weekly}"
  # Resolve the GPG recipient to a local key (tolerates a stale DR_GPG_RECIPIENT like dr@strateloq.com).
  DR_GPG_RECIPIENT="$(resolve_recipient)"; export DR_GPG_RECIPIENT
fi
# n8n live export is OPTIONAL: only run it when BOTH creds are present. The workflow definitions are
# independently protected (repo artifacts + the separate n8n DR workflow), so a weekly run without
# n8n creds SKIPS that one component rather than failing the whole backup.
N8N_ENABLED=0; [ -n "${N8N_BASE_URL:-}" ] && [ -n "${N8N_API_KEY:-}" ] && N8N_ENABLED=1

# ---- required config check (logged, so a scheduled exit-2 is diagnosable) -----------------
missing=""
for v in DR_GPG_RECIPIENT DR_REMOTE; do [ -n "${!v:-}" ] || missing="$missing $v"; done
if [ "$SELFTEST" = 0 ]; then
  for v in SUPABASE_DB_URL SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
fi
if [ -n "$missing" ]; then
  echo "ERROR: missing required config:$missing" >&2
  startlog "FATAL missing required config:$missing (exit 2). Set these in the env file (DR_REMOTE derives from DR_BACKUP_PARENT; n8n creds are optional)."
  exit 2
fi
# Real mode: the recipient must be a LOCAL key, or unattended encryption cannot work — fail clear.
if [ "$SELFTEST" = 0 ] && ! gpg --list-keys --no-auto-key-locate "$DR_GPG_RECIPIENT" >/dev/null 2>&1; then
  echo "ERROR: GPG recipient '$DR_GPG_RECIPIENT' is not a local public key" >&2
  startlog "FATAL GPG recipient '$DR_GPG_RECIPIENT' not a local key (exit 2) — set DR_GPG_RECIPIENT=support@strateloq.com in the env."
  exit 2
fi
startlog "weekly backup starting (self_test=$SELFTEST n8n=$N8N_ENABLED remote-parent=${DR_BACKUP_PARENT:-<unset>})"

# ---- lock: no overlapping runs -----------------------------------------------------------
mkdir -p "$DR_BACKUP_ROOT/runs"
LOCK="$DR_BACKUP_ROOT/.weekly.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another backup run is in progress (lock: $LOCK) — exiting without overlapping." >&2
  exit 3
fi

RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$DR_BACKUP_ROOT/runs/$RUN_TS"
STAGE="$RUN_DIR/stage"
LOG="$RUN_DIR/backup.log"
mkdir -p "$STAGE"

# everything after this is tee'd (scrubbed) to the run log. The logger is an ASYNC process
# substitution; without an explicit flush it can leave a 0-byte log when the script exits (the
# "silent failure" we saw). Save the console fds, capture the writer PID, and on EXIT restore the
# fds (closing the pipe) + wait for the writer so its buffered output is flushed to $LOG.
exec 3>&1 4>&2
exec > >(scrub | tee -a "$LOG") 2>&1
LOGW=$!
trap 'rc=$?; exec 1>&3 2>&4; wait "$LOGW" 2>/dev/null; exit $rc' EXIT

echo "== Strateloq weekly DR backup =="
echo "run=$RUN_TS transport=$DR_TRANSPORT remote=$DR_REMOTE retain=$DR_RETAIN self_test=$SELFTEST"

declare -A STATUS
overall_ok=1
fail() { STATUS["$1"]="FAIL"; overall_ok=0; echo "FAIL [$1]: ${2:-}"; }
ok()   { STATUS["$1"]="PASS"; echo "ok   [$1]: ${2:-}"; }

# ---- COLLECT (produce plaintext artifacts in STAGE) --------------------------------------
collect_real() {
  # git bundle
  if ( cd "$HERE/../.." && bash "$HERE/dr_git_bundle.sh" "$STAGE/strateloq-${RUN_TS}.bundle" ) ; then
    ok git-bundle; else fail git-bundle "git bundle failed"; fi
  # DB logical dump (already gpg-encrypted + plaintext shredded by the component script)
  if ( cd "$STAGE" && bash "$HERE/dr_db_logical_backup.sh" ) ; then
    ok db-dump; else fail db-dump "pg_dump/gpg failed"; fi
  # Supabase Storage objects -> tar (encrypted below)
  if ( cd "$STAGE" && bash "$HERE/dr_storage_backup.sh" "$DR_BUCKETS" ) ; then
    ok storage; else fail storage "storage download failed"; fi
  # n8n workflow definitions (active/inactive/archived) — OPTIONAL; only when both creds are present.
  if [ "${N8N_ENABLED:-0}" = 1 ]; then
    local nd="$STAGE/n8n-export-$RUN_TS"
    if bash "$HERE/dr_n8n_export.sh" "$nd" ; then
      n8n_state_counts "$nd"
      tar -cf "$STAGE/strateloq-n8n-${RUN_TS}.tar" -C "$nd" . && rm -rf "$nd"
      ok n8n-export; else fail n8n-export "n8n export failed"; fi
  else
    STATUS["n8n-export"]="SKIP"
    echo "WARN [n8n-export]: N8N_BASE_URL/N8N_API_KEY not set — skipping live n8n export (not a failure). Workflow definitions stay protected in the repo and in the separate n8n DR workflow."
  fi
}
n8n_state_counts() {
  python3 -I - "$1" <<'PY' || true
import json,os,sys
d=sys.argv[1]; a=i=ar=0
for f in os.listdir(d):
    if not f.endswith('.json'): continue
    w=json.load(open(os.path.join(d,f),encoding='utf-8'))
    if w.get('isArchived'): ar+=1
    elif w.get('active'): a+=1
    else: i+=1
print(f"n8n coverage: active={a} inactive={i} archived={ar} total={a+i+ar}")
if ar==0: print("WARN n8n: 0 archived captured — confirm the instance truly has none (export uses GET /workflows).")
PY
}
collect_selftest() {
  echo "fake db dump $(date)"   > "$STAGE/strateloq-db-${RUN_TS}.dump"
  echo "fake storage tar $(date)" > "$STAGE/strateloq-storage-${RUN_TS}.tgz"
  printf 'fake bundle\n'        > "$STAGE/strateloq-${RUN_TS}.bundle"
  printf 'fake n8n tar\n'       > "$STAGE/strateloq-n8n-${RUN_TS}.tar"
  # mimic the DB component already producing a .gpg:
  gpg_encrypt "$DR_GPG_RECIPIENT" "$STAGE/strateloq-db-${RUN_TS}.dump" \
    && { shred -u "$STAGE/strateloq-db-${RUN_TS}.dump" 2>/dev/null || rm -f "$STAGE/strateloq-db-${RUN_TS}.dump"; }
  ok git-bundle; ok db-dump; ok storage; ok n8n-export
}

if [ "$SELFTEST" = 1 ]; then collect_selftest; else collect_real; fi

# ---- ENCRYPT any remaining plaintext artifacts (DB dump is already .gpg) ------------------
encrypt_plaintext() {
  local f
  for f in "$STAGE"/*.tgz "$STAGE"/*.tar "$STAGE"/*.bundle; do
    [ -e "$f" ] || continue
    if gpg_encrypt "$DR_GPG_RECIPIENT" "$f"; then
      shred -u "$f" 2>/dev/null || rm -f "$f"
    else
      fail encrypt "could not encrypt $(basename "$f")"
    fi
  done
}
[ "$overall_ok" = 1 ] && encrypt_plaintext

# ---- SAFETY: staging must be plaintext-free before any upload ----------------------------
plain="$(find "$STAGE" -maxdepth 1 -type f ! -name '*.gpg' ! -name 'SHA256SUMS' 2>/dev/null)"
if [ -n "$plain" ]; then
  fail plaintext-guard "plaintext artifact(s) present, refusing to upload: $(echo "$plain" | tr '\n' ' ')"
fi

# ---- MANIFEST + local integrity ----------------------------------------------------------
if [ "$overall_ok" = 1 ]; then
  ( cd "$STAGE" && sha256sum ./*.gpg > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null ) \
    && ok manifest "$(wc -l < "$STAGE/SHA256SUMS") artifact(s)" || fail manifest "sha256 manifest/verify failed"
fi

# ---- UPLOAD + checksum VERIFY (only when the set is complete) -----------------------------
if [ "$overall_ok" = 1 ]; then
  if transport_put_dir "$STAGE" "$RUN_TS"; then ok upload; else fail upload "transport put failed"; fi
fi
if [ "$overall_ok" = 1 ]; then
  if transport_verify "$STAGE" "$RUN_TS"; then ok verify "checksums match remote"; else fail verify "remote checksum mismatch"; fi
fi

# ---- FINALIZE + RETENTION (success only) -------------------------------------------------
summary_line() { local s="" k; for k in "${!STATUS[@]}"; do s="$s $k=${STATUS[$k]}"; done; echo "$s"; }

if [ "$overall_ok" = 1 ]; then
  echo "SUCCESS" > "$RUN_DIR/STATUS"
  : > "$RUN_DIR/.verified"
  echo "RESULT: PASS —$(summary_line)"
  startlog "RESULT: PASS run=$RUN_TS —$(summary_line)"   # durable, synchronous record
  # Retention: keep the newest DR_RETAIN *verified* local runs; prune older ones + their remote sets.
  mapfile -t verified < <(for d in "$DR_BACKUP_ROOT"/runs/*/; do
      [ -f "${d}.verified" ] && basename "$d"; done | sort)
  n=${#verified[@]}
  if [ "$n" -gt "$DR_RETAIN" ]; then
    prune=$(( n - DR_RETAIN ))
    for ((k=0; k<prune; k++)); do
      old="${verified[$k]}"
      echo "retention: pruning old verified set $old (keeping newest $DR_RETAIN)"
      transport_purge_set "$old" || echo "WARN retention: remote purge failed for $old (local kept)"
      rm -rf "${DR_BACKUP_ROOT:?}/runs/$old"
    done
  fi
else
  echo "FAILED" > "$RUN_DIR/STATUS"
  echo "RESULT: FAIL —$(summary_line)"
  echo "Partial artifacts kept at $RUN_DIR (NOT uploaded as success, NOTHING pruned). See $LOG."
  # Durable, synchronous failure record (independent of the async run-log writer) so the reason is
  # never lost even if the per-run log is empty.
  startlog "RESULT: FAIL run=$RUN_TS —$(summary_line) (see $LOG)"
fi

[ "$SELFTEST" = 1 ] && [ -n "$SELFTEST_TMP" ] && rm -rf "$SELFTEST_TMP"
[ "$overall_ok" = 1 ] && exit 0 || exit 1

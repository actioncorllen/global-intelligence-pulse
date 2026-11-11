#!/usr/bin/env bash
# =============================================================================
# Strateloq DR — Weekly backup ORCHESTRATOR (repaired, now tracked in-repo)
# =============================================================================
# Reconstructed from the committed component scripts + the observed Google Drive
# layout (per-run folder <TS>/ holding strateloq-{bundle,n8n,storage,db}-<TS>.*.gpg).
# It GLUES the existing, tracked components — it does NOT introduce a new architecture:
#   dr_git_bundle.sh      -> strateloq-<TS>.bundle        (then gpg)
#   dr_db_logical_backup.sh -> strateloq-db-<TS>.dump.gpg  (already gpg)
#   dr_storage_backup.sh  -> strateloq-storage-<TS>.tgz    (then gpg)
#   dr_n8n_export.sh      -> <json dir>                    (then tar + gpg)
# then uploads the per-run folder to the EXISTING rclone remote/destination and
# records a sha256 manifest. Non-destructive: never deletes or overwrites existing
# archives (every run is a NEW timestamped folder); never touches production;
# never prints a secret. Reads all secrets from the operator environment / env file.
#
# Required env (operator-held; a sourced env file is the normal way to provide them):
#   SUPABASE_DB_URL        postgresql://...:6543/postgres   (DB dump; a secret)
#   DR_GPG_RECIPIENT       gpg key id/email to encrypt to
#   RCLONE_REMOTE          e.g. strateloqdrive:             (trailing colon)
#   RCLONE_DEST            existing destination path under the remote, e.g. Strateloq-DR
# Optional (enable the matching artifact when present):
#   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   -> storage backup
#   N8N_BASE_URL, N8N_API_KEY                 -> n8n export
#   DR_ENV_FILE            path to a file that `export`s the above (sourced if set/exists)
#   DR_LOG_DIR             where to write the run log (default: ~/strateloq-dr-logs)
#   DR_KEEP_LOCAL=1        keep the local per-run folder after upload (default: shred it)
# Exit code: 0 = DB backup produced, encrypted, uploaded and manifested; non-zero otherwise.
# =============================================================================
set -Eeuo pipefail

# ---- resolve this script's dir so component scripts are found regardless of CWD ----
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd -P)"

# ---- optional env file ----
if [[ -n "${DR_ENV_FILE:-}" && -f "${DR_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${DR_ENV_FILE}"
elif [[ -f "${HOME}/.strateloq-dr.env" ]]; then
  # shellcheck disable=SC1090
  source "${HOME}/.strateloq-dr.env"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${DR_LOG_DIR:-${HOME}/strateloq-dr-logs}"; mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/dr_weekly_${TS}.log"
# Mirror all output to the log; keep stdout for the Task Scheduler to capture.
exec > >(tee -a "$LOG") 2>&1

fail() { echo "[FAIL] $*"; exit 1; }
step() { echo "[STEP] $*"; }
ok()   { echo "[ OK ] $*"; }

echo "=== Strateloq DR weekly backup @ ${TS} (UTC) ==="
# ---- required config (fail loudly, never print values) ----
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL not set (provide via env or DR_ENV_FILE)}"
: "${DR_GPG_RECIPIENT:?DR_GPG_RECIPIENT not set}"
: "${RCLONE_REMOTE:?RCLONE_REMOTE not set (e.g. strateloqdrive:)}"
: "${RCLONE_DEST:?RCLONE_DEST not set (existing Drive destination path)}"
command -v pg_dump >/dev/null || fail "pg_dump not installed"
command -v gpg     >/dev/null || fail "gpg not installed"
command -v rclone  >/dev/null || fail "rclone not installed"
gpg --list-keys "$DR_GPG_RECIPIENT" >/dev/null 2>&1 || fail "gpg recipient key not in keyring: ${DR_GPG_RECIPIENT}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/strateloq-dr-${TS}.XXXXXX")"
RUN="${WORK}/${TS}"; mkdir -p "$RUN"
cleanup() {
  if [[ "${DR_KEEP_LOCAL:-0}" == "1" ]]; then
    echo "[INFO] DR_KEEP_LOCAL=1 — local copy kept at ${RUN}"
  else
    find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---- 1) DB logical backup (REQUIRED) ----
step "DB logical backup (pg_dump -Fc, gpg)"
# reuse the committed component unchanged; it emits strateloq-db-<ts>.dump.gpg into CWD
( cd "$RUN" && DR_GPG_RECIPIENT="$DR_GPG_RECIPIENT" SUPABASE_DB_URL="$SUPABASE_DB_URL" \
    bash "${SCRIPT_DIR}/dr_db_logical_backup.sh" >/dev/null )
DB_GPG="$(find "$RUN" -maxdepth 1 -name 'strateloq-db-*.dump.gpg' -print -quit)"
[[ -s "$DB_GPG" ]] || fail "DB dump not produced"
ok "DB: $(basename "$DB_GPG") ($(du -h "$DB_GPG" | cut -f1))"

# ---- 2) Git bundle (best-effort; must run from the repo root) ----
if command -v git >/dev/null && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  step "Git bundle"
  if ( cd "$REPO_ROOT" && bash "${SCRIPT_DIR}/dr_git_bundle.sh" "${RUN}/strateloq-${TS}.bundle" >/dev/null 2>&1 ); then
    gpg --yes --encrypt --recipient "$DR_GPG_RECIPIENT" "${RUN}/strateloq-${TS}.bundle" \
      && rm -f "${RUN}/strateloq-${TS}.bundle" && ok "bundle encrypted"
  else echo "[WARN] git bundle skipped (git error)"; fi
else echo "[INFO] git bundle skipped (repo root not a git checkout: ${REPO_ROOT})"; fi

# ---- 3) Storage backup (if configured) ----
if [[ -n "${SUPABASE_URL:-}" && -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  step "Storage backup"
  if ( cd "$RUN" && SUPABASE_URL="$SUPABASE_URL" SUPABASE_SERVICE_ROLE_KEY="$SUPABASE_SERVICE_ROLE_KEY" \
        bash "${SCRIPT_DIR}/dr_storage_backup.sh" >/dev/null 2>&1 ); then
    STG="$(find "$RUN" -maxdepth 1 -name 'strateloq-storage-*.tgz' -print -quit)"
    [[ -s "$STG" ]] && gpg --yes --encrypt --recipient "$DR_GPG_RECIPIENT" "$STG" && rm -f "$STG" && ok "storage encrypted"
  else echo "[WARN] storage backup skipped/failed"; fi
else echo "[INFO] storage backup skipped (SUPABASE_URL / SERVICE_ROLE_KEY not set)"; fi

# ---- 4) n8n export (if configured) ----
if [[ -n "${N8N_BASE_URL:-}" && -n "${N8N_API_KEY:-}" ]]; then
  step "n8n export"
  if ( cd "$RUN" && N8N_BASE_URL="$N8N_BASE_URL" N8N_API_KEY="$N8N_API_KEY" \
        bash "${SCRIPT_DIR}/dr_n8n_export.sh" "${RUN}/n8n-${TS}" >/dev/null 2>&1 ); then
    ( cd "$RUN" && tar -czf "strateloq-n8n-${TS}.tar" "n8n-${TS}" && rm -rf "n8n-${TS}" \
        && gpg --yes --encrypt --recipient "$DR_GPG_RECIPIENT" "strateloq-n8n-${TS}.tar" \
        && rm -f "strateloq-n8n-${TS}.tar" ) && ok "n8n encrypted"
  else echo "[WARN] n8n export skipped/failed"; fi
else echo "[INFO] n8n export skipped (N8N_BASE_URL / N8N_API_KEY not set)"; fi

# ---- 5) integrity manifest (sha256 of every encrypted artifact) ----
step "sha256 manifest"
( cd "$RUN" && sha256sum ./*.gpg > "SHA256SUMS-${TS}.txt" ) && ok "manifest written"
cat "${RUN}/SHA256SUMS-${TS}.txt"

# ---- 6) upload the per-run folder to the EXISTING destination (new folder; no overwrite) ----
step "rclone upload -> ${RCLONE_REMOTE}${RCLONE_DEST}/${TS}/"
rclone mkdir "${RCLONE_REMOTE}${RCLONE_DEST}/${TS}" >/dev/null 2>&1 || true
rclone copy "$RUN" "${RCLONE_REMOTE}${RCLONE_DEST}/${TS}" --copy-links --no-update-modtime \
  || fail "rclone upload failed"
# verify the upload byte-for-byte against the local copy (does not delete anything)
rclone check "$RUN" "${RCLONE_REMOTE}${RCLONE_DEST}/${TS}" --one-way \
  || fail "rclone post-upload verification mismatch"
ok "upload verified"

echo "=== SUCCESS: backup ${TS} uploaded to ${RCLONE_REMOTE}${RCLONE_DEST}/${TS}/ ==="
echo "    DB artifact: $(basename "$DB_GPG")"
echo "    log: ${LOG}"
exit 0

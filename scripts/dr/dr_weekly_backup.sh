#!/usr/bin/env bash
# =============================================================================
# dr_weekly_backup.sh  -  unattended weekly encrypted production backup -> Drive
#
# Invoked by the Windows scheduled task `Strateloq-DR-Weekly-Backup` via WSL as the
# operator user (strateloqbackup). It REUSES existing configuration only:
#   * the established, committed operational backup scripts/dr/dr_db_logical_backup.sh
#     (pg_dump -Fc of production, read-only -> gpg public-key encrypt -> shred plaintext),
#   * the operator credentials + GPG recipient from the scheduled-backup env file,
#   * the existing rclone remote `strateloqdrive:` and destination Strateloq-DR/backups.
# It creates/changes NO credential, GPG key, or Drive destination, modifies no production
# data (pg_dump is read-only), and PRESERVES every previous archive (rclone copy = additive,
# never sync/delete).
#
# `set -euo pipefail` ensures any failure returns a NON-ZERO exit code to Task Scheduler
# (LastTaskResult != 0); a clean run exits 0 after the upload is verified.
# =============================================================================
set -euo pipefail

REPO="${STRATELOQ_DR_REPO:-$HOME/strateloq-dr-validate}"
DRIVE_REMOTE="${STRATELOQ_DRIVE_REMOTE:-strateloqdrive:}"
DRIVE_DEST="${STRATELOQ_DRIVE_DEST:-Strateloq-DR/backups}"
BACKUP_SCRIPT="$REPO/scripts/dr/dr_db_logical_backup.sh"

log() { printf '%s dr_weekly_backup: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { log "ERROR: $1"; exit "${2:-1}"; }

# Load the scheduled-backup env file (credentials/keys/remote) if present - values never printed.
for f in "$REPO/dr_weekly_backup.env" "$REPO/scripts/dr/dr_weekly_backup.env" \
         "$HOME/dr_weekly_backup.env" "$HOME/.config/strateloq-dr/dr_weekly_backup.env" \
         "/etc/strateloq-dr/dr_weekly_backup.env" "$REPO/.env"; do
  if [ -f "$f" ]; then set +e; set -a; . "$f" >/dev/null 2>&1; set +a; set -e; log "loaded env from $f"; break; fi
done

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL not set (define it in dr_weekly_backup.env)}"
: "${DR_GPG_RECIPIENT:?DR_GPG_RECIPIENT not set (define it in dr_weekly_backup.env)}"
export SUPABASE_DB_URL DR_GPG_RECIPIENT
for t in gpg rclone sha256sum md5sum; do command -v "$t" >/dev/null 2>&1 || fail "missing tool: $t" 3; done
[ -s "$BACKUP_SCRIPT" ] || fail "operational backup script missing/empty: $BACKUP_SCRIPT" 4
rclone listremotes 2>/dev/null | grep -qx "$DRIVE_REMOTE" || fail "rclone remote not configured: $DRIVE_REMOTE" 5

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
log "start (work=$WORK; dest=$DRIVE_REMOTE$DRIVE_DEST)"

# fresh encrypted production backup via the established operational script
( cd "$WORK" && bash "$BACKUP_SCRIPT" ) || fail "backup/encrypt step failed" 8
ENC="$(ls -t "$WORK"/strateloq-db-*.dump.gpg 2>/dev/null | head -1 || true)"
[ -n "$ENC" ] && [ -s "$ENC" ] || fail "no encrypted archive produced" 8
SZ="$(wc -c < "$ENC" | tr -d ' ')"
SHA="$(sha256sum "$ENC" | awk '{print $1}')"
log "archive $(basename "$ENC") (${SZ} bytes) sha256=${SHA}"

# secret-free manifest (checksums/counts/timestamp only)
MAN="$WORK/$(basename "$ENC").manifest.json"
printf '{\n  "artifact":"%s",\n  "bytes":%s,\n  "ciphertext_sha256":"%s",\n  "created_utc":"%s",\n  "drive_dest":"%s"\n}\n' \
  "$(basename "$ENC")" "$SZ" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DRIVE_REMOTE$DRIVE_DEST" > "$MAN"

# upload (copy = additive; previous archives preserved) then verify the upload
rclone copy "$ENC" "$DRIVE_REMOTE$DRIVE_DEST" || fail "rclone upload of archive failed" 13
rclone copy "$MAN" "$DRIVE_REMOTE$DRIVE_DEST" || fail "rclone upload of manifest failed" 13
base="$(basename "$ENC")"
rsize="$(rclone ls "$DRIVE_REMOTE$DRIVE_DEST" 2>/dev/null | awk -v f="$base" '$2==f{print $1}' | head -1)"
rmd5="$(rclone md5sum "$DRIVE_REMOTE$DRIVE_DEST" 2>/dev/null | awk -v f="$base" '$2==f{print $1}' | head -1)"
lmd5="$(md5sum "$ENC" | awk '{print $1}')"
if [ "${rsize:-0}" = "$SZ" ] && { [ -z "$rmd5" ] || [ "$rmd5" = "$lmd5" ]; }; then
  log "UPLOAD_VERIFIED ${base} (remote size=${rsize} md5=${rmd5:-n/a} == local)"
else
  fail "upload verification mismatch (remote size=${rsize:-none} md5=${rmd5:-n/a} vs local size=${SZ} md5=${lmd5})" 13
fi
log "WEEKLY_BACKUP_OK ${base} -> ${DRIVE_REMOTE}${DRIVE_DEST}"
exit 0

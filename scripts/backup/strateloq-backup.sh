#!/usr/bin/env bash
# Strateloq production backup — encrypt-before-upload, authenticated, verifiable.
#
# Implements the mandatory-backup-encryption policy:
#   1. AES-256-GCM authenticated encryption (streaming, via aesgcm_stream.py).
#      (age/ChaCha20-Poly1305 is an equally valid AEAD alternative — see README —
#      but this script implements the AES-256-GCM path the policy names.)
#   2. Encryption happens LOCALLY, before any upload. Google Drive encryption is
#      never relied on alone.
#   3/4/5. The 256-bit key is read ONLY from $BACKUP_KEY (set from a secret the
#      founder controls in their password manager). It is never printed, never
#      written to disk, never uploaded. If $BACKUP_KEY is absent the run ABORTS
#      before any archive is produced (no unrecoverable archive is ever created).
#   6. SHA-256 checksums are written and verified; the GCM auth tag is verified by
#      a real test-decryption into an isolated dir, followed by a test extraction.
#   7. Plaintext temp files are shredded; production systems are only ever READ.
#   8. The script prints "BACKUP COMPLETE" only after encryption, checksum,
#      verification and (if configured) upload all succeed.
#
# IMPORTANT: this script must run where the production data AND $BACKUP_KEY are
# reachable (the founder's machine / a controlled server / a cloud session with
# egress to Supabase). It CANNOT be run from the assistant's chat container
# (egress to Supabase is policy-denied there and secrets load only in a new
# session). It makes NO changes to any production system — all operations are
# read-only dumps/exports.
#
# Required env (set from secrets / password-manager, never committed):
#   BACKUP_KEY              base64 or hex, decoding to exactly 32 bytes (256-bit)
# Optional per-source env (a source is skipped, with a notice, if its vars are unset):
#   SUPABASE_DB_URL         postgres connection string for pg_dump (read-only role preferred)
#   SUPABASE_PROJECT_REF    project ref, for storage export
#   SUPABASE_SERVICE_ROLE_KEY   service role key, for storage export (read-only use)
#   SUPABASE_URL            e.g. https://<ref>.supabase.co, for storage export
#   N8N_BASE_URL, N8N_API_KEY   to export workflows
# Upload (optional; otherwise the encrypted file is left in $BACKUP_OUT_DIR for you to upload):
#   BACKUP_RCLONE_REMOTE    e.g. "gdrive:Strateloq/backups"  (requires rclone configured)
# Output:
#   BACKUP_OUT_DIR          where the .sgcm/.age + .sha256 land (default ./backup-out)
#
# Usage: BACKUP_KEY=... SUPABASE_DB_URL=... ./strateloq-backup.sh [--dry-run]
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CIPHER="aes-256-gcm"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

OUT_DIR="${BACKUP_OUT_DIR:-$PWD/backup-out}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BASENAME="strateloq-backup-$STAMP"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/slq-backup.XXXXXX")"
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/slq-verify.XXXXXX")"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Secure cleanup of ALL plaintext temp on any exit (req 7). Production untouched.
cleanup() {
  for d in "$WORK" "$VERIFY"; do
    [ -d "$d" ] || continue
    find "$d" -type f -print0 2>/dev/null | xargs -0 -r shred -u 2>/dev/null || true
    rm -rf "$d" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# ---- Preflight: key gate (reqs 3-5). Abort BEFORE producing anything. --------
if [ -z "${BACKUP_KEY:-}" ]; then
  echo "ABORT: BACKUP_KEY is not set. Per policy req 5, refusing to create an archive" >&2
  echo "       whose key you cannot retrieve. Set BACKUP_KEY from your password-manager secret." >&2
  exit 3
fi
# Validate key shape WITHOUT printing it; this also fails fast on a malformed key.
python3 - <<'PY' || { echo "ABORT: BACKUP_KEY must decode (base64 or hex) to exactly 32 bytes." >&2; exit 3; }
import os,base64,binascii,sys
raw=os.environ["BACKUP_KEY"].strip()
for d in (lambda s:base64.b64decode(s,validate=True),
          lambda s:base64.urlsafe_b64decode(s+"="*(-len(s)%4)),
          lambda s:binascii.unhexlify(s)):
    try:
        if len(d(raw))==32: sys.exit(0)
    except Exception: pass
sys.exit(1)
PY
log "key preflight OK (32-byte key present; value never printed)"

command -v shred >/dev/null || { echo "ABORT: shred (coreutils) required for secure temp removal" >&2; exit 2; }
mkdir -p "$OUT_DIR"

# ---- Collect sources (READ-ONLY). Each is optional; skipped with a notice. ----
SRC_DIR="$WORK/$BASENAME"; mkdir -p "$SRC_DIR"
COLLECTED=0

if [ -n "${SUPABASE_DB_URL:-}" ]; then
  log "dumping production Postgres (pg_dump, read-only)…"
  # Keep the password out of argv/ps: parse into PG* env, then dump with flags.
  eval "$(python3 - <<'PY'
import os,urllib.parse as u
p=u.urlparse(os.environ["SUPABASE_DB_URL"])
def q(x): return "'"+(x or "").replace("'","'\\''")+"'"
print("export PGHOST=%s"%q(p.hostname))
print("export PGPORT=%s"%q(str(p.port or 5432)))
print("export PGUSER=%s"%q(u.unquote(p.username or "")))
print("export PGPASSWORD=%s"%q(u.unquote(p.password or "")))
print("export PGDATABASE=%s"%q((p.path or "/postgres").lstrip("/") or "postgres"))
PY
)"
  pg_dump --no-owner --no-privileges --format=custom --compress=6 \
          -f "$SRC_DIR/db.dump" 2>"$SRC_DIR/db.pg_dump.log"
  unset PGPASSWORD
  log "  db.dump: $(stat -c%s "$SRC_DIR/db.dump") bytes"
  COLLECTED=1
else
  log "SKIP db: SUPABASE_DB_URL not set"
fi

if [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  log "exporting Supabase Storage objects (read-only)…"
  python3 "$HERE/storage_export.py" "$SRC_DIR/storage" 2>"$SRC_DIR/storage.log" || {
    log "  storage export reported errors (see storage.log); continuing"; }
  COLLECTED=1
else
  log "SKIP storage: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set"
fi

if [ -n "${N8N_BASE_URL:-}" ] && [ -n "${N8N_API_KEY:-}" ]; then
  log "exporting n8n workflows (metadata/JSON; credential VALUES are not returned by the API)…"
  python3 "$HERE/n8n_export.py" "$SRC_DIR/n8n" 2>"$SRC_DIR/n8n.log" || {
    log "  n8n export reported errors (see n8n.log); continuing"; }
  COLLECTED=1
else
  log "SKIP n8n: N8N_BASE_URL / N8N_API_KEY not set"
fi

# Source code: prefer a git bundle of the repo this script lives in (self-contained,
# verifiable). Source is also mirrored on GitHub, so this is a convenience copy.
if git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
  log "bundling source (git bundle)…"
  git -C "$HERE" bundle create "$SRC_DIR/source.bundle" --all >/dev/null 2>&1 || true
  [ -f "$SRC_DIR/source.bundle" ] && COLLECTED=1
fi

if [ "$COLLECTED" -eq 0 ]; then
  echo "ABORT: no sources were collected (no source env vars set). Nothing to back up." >&2
  exit 6
fi

printf 'strateloq backup %s\ncipher=%s\nhost=%s\n' "$STAMP" "$CIPHER" "$(hostname)" > "$SRC_DIR/MANIFEST.txt"

# ---- Package -----------------------------------------------------------------
PLAIN="$WORK/$BASENAME.tar.gz"
log "packaging archive…"
tar -C "$WORK" -czf "$PLAIN" "$BASENAME"
PLAIN_SHA="$(sha256sum "$PLAIN" | awk '{print $1}')"
log "  plaintext archive: $(stat -c%s "$PLAIN") bytes  sha256=$PLAIN_SHA"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: skipping encryption/upload; shredding plaintext and exiting."
  exit 0
fi

# ---- Encrypt locally BEFORE upload (reqs 1-2) --------------------------------
# AES-256-GCM streaming; $BACKUP_KEY is read inside the helper from env, never argv.
ENC="$OUT_DIR/$BASENAME.tar.gz.sgcm"
python3 "$HERE/aesgcm_stream.py" encrypt < "$PLAIN" > "$ENC"
log "encrypted -> $ENC ($(stat -c%s "$ENC") bytes)"

# ---- Checksums (req 6) -------------------------------------------------------
( cd "$OUT_DIR" && sha256sum "$(basename "$ENC")" > "$(basename "$ENC").sha256" )
( cd "$OUT_DIR" && sha256sum -c "$(basename "$ENC").sha256" >/dev/null ) && log "ciphertext sha256 verified"

# ---- Verify: real decrypt + auth-tag check + test extraction (req 6) ---------
log "verifying: test-decrypt into isolated dir + auth-tag + extraction…"
RT="$VERIFY/roundtrip.tar.gz"
python3 "$HERE/aesgcm_stream.py" decrypt < "$ENC" > "$RT" || { echo "VERIFY FAILED: auth tag" >&2; exit 8; }
RT_SHA="$(sha256sum "$RT" | awk '{print $1}')"
[ "$RT_SHA" = "$PLAIN_SHA" ] || { echo "VERIFY FAILED: decrypted sha != original ($RT_SHA != $PLAIN_SHA)" >&2; exit 8; }
tar -C "$VERIFY" -tzf "$RT" >/dev/null || { echo "VERIFY FAILED: archive not extractable" >&2; exit 8; }
log "  verify OK: decrypted archive matches plaintext sha256 and extracts cleanly"

# ---- Upload (encryption already done; Drive never sees plaintext) ------------
UPLOADED=0
if [ -n "${BACKUP_RCLONE_REMOTE:-}" ] && command -v rclone >/dev/null; then
  log "uploading encrypted archive + checksum to $BACKUP_RCLONE_REMOTE …"
  rclone copy "$ENC" "$BACKUP_RCLONE_REMOTE/" && rclone copy "$ENC.sha256" "$BACKUP_RCLONE_REMOTE/"
  # Post-upload integrity: re-hash the remote copy.
  rclone hashsum sha256 "$BACKUP_RCLONE_REMOTE/$(basename "$ENC")" | grep -qi "$(awk '{print $1}' < "$ENC.sha256")" \
    && { log "remote sha256 matches local"; UPLOADED=1; } || echo "WARNING: could not confirm remote sha256" >&2
else
  log "no rclone remote configured: encrypted archive left in $OUT_DIR for you to upload to Google Drive."
fi

# plaintext temp is shredded by the EXIT trap. Encrypted output + checksum remain.
if [ "$UPLOADED" -eq 1 ]; then
  echo "BACKUP COMPLETE: encrypted, checksummed, verified (decrypt+extract), and uploaded. Key never left your control."
else
  echo "BACKUP READY (local): encrypted, checksummed and verified at $ENC — upload to Google Drive to finish."
  echo "  (Not reporting BACKUP COMPLETE until the encrypted archive is in Google Drive, per req 8.)"
fi

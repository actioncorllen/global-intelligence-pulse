#!/usr/bin/env bash
# Strateloq DR — one database backup to the Google Drive "Supabase Database" folder.
#
# Reuses scripts/dr/dr_db_logical_backup.sh (pg_dump -Fc -> gpg-encrypted, plaintext shredded)
# and adds: decrypt+TOC integrity check, SHA256 manifest, upload via rclone, and a post-upload
# checksum VERIFY (PASS/FAIL). Read-only against production; never deletes existing backups.
#
# Integrity is proven by DECRYPTING the encrypted dump in a pipe and listing its archive TOC
# (`pg_restore -l`) — this confirms the backup is both decryptable (key+passphrase work) and a
# well-formed, complete pg_dump, WITHOUT writing plaintext to disk and WITHOUT restoring into any
# database (fully isolated from production). It prompts once for the gpg passphrase (pinentry).
#
# Config (env or --env file; see dr_weekly_backup.env.example — same variables):
#   SUPABASE_DB_URL DR_GPG_RECIPIENT DR_DB_REMOTE [DR_TRANSPORT] [DR_BACKUP_ROOT] [RCLONE_BIN]
#   DR_DB_REMOTE   rclone remote:path of the Supabase Database folder,
#                  e.g.  gdrive:Strateloq-DR/Supabase Database
#
# Usage:  dr_db_backup_to_drive.sh [--env <file>] [--self-test]
# Exit: 0 PASS · 2 config · 1 FAIL
set -uo pipefail
umask 077
HERE="$(cd "$(dirname "$0")" && pwd)"

SELFTEST=0; ENV_FILE=""
while [ $# -gt 0 ]; do case "$1" in
  --self-test) SELFTEST=1; shift;;
  --env) ENV_FILE="$2"; shift 2;;
  -h|--help) sed -n '1,30p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

scrub() { sed -E -e 's#(://[^:/@ ]+):[^@ ]+@#\1:***@#g' \
  -e 's#eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_.-]{6,}#***JWT-REDACTED***#g' \
  -e 's#(apikey|api_key|key|token|password|service_role)([=:])[^[:space:]&]+#\1\2***#gI'; }

# Source with a UTF-8 BOM / CR stripped (Windows/WSL gremlins) so they are never fatal; file unchanged.
_cleanenv(){ sed -e "1s/^$(printf '\357\273\277')//" -e 's/\r$//' "$1"; }
if [ -n "$ENV_FILE" ]; then [ -f "$ENV_FILE" ] || { echo "env file not found: $ENV_FILE" >&2; exit 2; }
  set -a; . <(_cleanenv "$ENV_FILE"); set +a
elif [ -f "$HERE/dr_weekly_backup.env" ] && [ "$SELFTEST" = 0 ]; then set -a; . <(_cleanenv "$HERE/dr_weekly_backup.env"); set +a; fi

DR_TRANSPORT="${DR_TRANSPORT:-rclone}"; RCLONE_BIN="${RCLONE_BIN:-rclone}"
DR_DB_REMOTE="${DR_DB_REMOTE:-${DR_REMOTE:-}}"
# A recipient forced by the key-setup orchestrator (the freshly-created key's fingerprint) must win
# over any stale DR_GPG_RECIPIENT re-sourced from the env above. The env file never sets _FORCE.
DR_GPG_RECIPIENT="${DR_GPG_RECIPIENT_FORCE:-${DR_GPG_RECIPIENT:-}}"; export DR_GPG_RECIPIENT

transport_put_dir() { case "$DR_TRANSPORT" in
  rclone) "$RCLONE_BIN" copy "$1" "$DR_DB_REMOTE/$2/" --transfers 2 --checkers 2;;
  local)  mkdir -p "$DR_DB_REMOTE/$2" && cp -a "$1"/. "$DR_DB_REMOTE/$2"/;; esac; }
transport_verify() { case "$DR_TRANSPORT" in
  rclone) "$RCLONE_BIN" check "$1" "$DR_DB_REMOTE/$2" --one-way;;
  local)  ( cd "$DR_DB_REMOTE/$2" && sha256sum -c SHA256SUMS >/dev/null );; esac; }

SELFTMP=""
if [ "$SELFTEST" = 1 ]; then
  SELFTMP="$(mktemp -d)"; export GNUPGHOME="$SELFTMP/g"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-generate-key 'dbtest@example.invalid' default default never >/dev/null 2>&1
  DR_GPG_RECIPIENT="dbtest@example.invalid"; DR_TRANSPORT="local"
  DR_DB_REMOTE="${DR_DB_REMOTE:-$SELFTMP/remote}"; DR_BACKUP_ROOT="${DR_BACKUP_ROOT:-$SELFTMP/bk}"
fi
DR_BACKUP_ROOT="${DR_BACKUP_ROOT:-$HOME/strateloq-backups}"

missing=""; for v in DR_GPG_RECIPIENT DR_DB_REMOTE; do [ -n "${!v:-}" ] || missing="$missing $v"; done
[ "$SELFTEST" = 0 ] && { [ -n "${SUPABASE_DB_URL:-}" ] || missing="$missing SUPABASE_DB_URL"; }
[ -z "$missing" ] || { echo "ERROR: missing config:$missing" >&2; exit 2; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"; RUN="$DR_BACKUP_ROOT/db-$TS"; STAGE="$RUN/stage"; LOG="$RUN/backup.log"
mkdir -p "$STAGE"
exec > >(scrub | tee -a "$LOG") 2>&1
echo "== Strateloq DB backup -> Drive ==  run=$TS transport=$DR_TRANSPORT remote=$DR_DB_REMOTE self_test=$SELFTEST"
ok=1; fail(){ ok=0; echo "FAIL [$1]: ${2:-}"; }

# Recipient must be a LOCAL public key before we dump — fail closed with a precise fix, never a
# network (WKD) lookup. This turns the opaque "via WKD: No data" into an actionable message.
if [ "$SELFTEST" = 0 ]; then
  if gpg --list-keys --no-auto-key-locate "$DR_GPG_RECIPIENT" >/dev/null 2>&1; then
    echo "ok   [recipient] '$DR_GPG_RECIPIENT' resolves to a local public key"
  else
    echo "FAIL [recipient]: GPG recipient '$DR_GPG_RECIPIENT' is not a local public key (no network/WKD lookup attempted)."
    echo "     Your backup key UID is support@strateloq.com. Set DR_GPG_RECIPIENT=\"support@strateloq.com\" (or the key fingerprint from 'gpg --list-keys') in the env file."
    echo "FAILED" > "$RUN/STATUS"; echo "RESULT: FAIL — recipient not resolvable; nothing dumped, uploaded, or deleted."
    exit 1
  fi
fi

# 1) dump + encrypt (reuse the component script) — real mode only
if [ "$SELFTEST" = 1 ]; then
  printf 'fake pg_dump %s\n' "$TS" > "$STAGE/plain.tmp"
  gpg --yes --batch --encrypt --recipient "$DR_GPG_RECIPIENT" -o "$STAGE/strateloq-db-$TS.dump.gpg" "$STAGE/plain.tmp" \
    && { shred -u "$STAGE/plain.tmp" 2>/dev/null || rm -f "$STAGE/plain.tmp"; echo "ok   [dump] (self-test fake)"; } || fail dump
else
  if ( cd "$STAGE" && bash "$HERE/dr_db_logical_backup.sh" >/dev/null ); then echo "ok   [dump] encrypted dump produced"; else fail dump "pg_dump/gpg failed"; fi
fi

DUMP="$(ls "$STAGE"/strateloq-db-*.dump.gpg 2>/dev/null | head -1)"
[ -n "$DUMP" ] || fail dump "no encrypted dump found"

# 2) integrity: decrypt to a PRIVATE temp file, parse the TOC (pg_restore -l), then shred it.
#    (A -Fc archive needs a seekable file, so it cannot be checked straight from a pipe.) No
#    database is restored; nothing touches production. Proves decryptability + a complete archive.
if [ "$ok" = 1 ] && [ "$SELFTEST" = 0 ]; then
  ITMP="$(mktemp -d)"
  if gpg --decrypt -o "$ITMP/d.dump" "$DUMP" 2>/dev/null && pg_restore -l "$ITMP/d.dump" >/dev/null 2>&1; then
    echo "ok   [integrity] encrypted dump decrypts and pg_restore TOC parses ($(pg_restore -l "$ITMP/d.dump" 2>/dev/null | grep -c ';') TOC entries)"
  else fail integrity "decrypt+TOC check failed (dump unreadable, or passphrase/key wrong)"; fi
  shred -u "$ITMP/d.dump" 2>/dev/null || rm -f "$ITMP/d.dump"; rm -rf "$ITMP"
else [ "$ok" = 1 ] && echo "ok   [integrity] SKIPPED (self-test: no real pg_dump)"; fi

# 3) plaintext guard + manifest
if [ "$ok" = 1 ]; then
  plain="$(find "$STAGE" -maxdepth 1 -type f ! -name '*.gpg' ! -name 'SHA256SUMS')"
  [ -z "$plain" ] || fail plaintext-guard "plaintext present: $plain"
fi
if [ "$ok" = 1 ]; then ( cd "$STAGE" && sha256sum ./*.gpg > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null ) \
  && echo "ok   [manifest] $(wc -l < "$STAGE/SHA256SUMS") file(s)" || fail manifest; fi

# 4) upload + 5) checksum verify
if [ "$ok" = 1 ]; then transport_put_dir "$STAGE" "$TS" && echo "ok   [upload] -> $DR_DB_REMOTE/$TS" || fail upload; fi
if [ "$ok" = 1 ]; then transport_verify "$STAGE" "$TS" && echo "ok   [verify] remote checksum matches" || fail verify "remote checksum mismatch"; fi

if [ "$ok" = 1 ]; then echo "SUCCESS" > "$RUN/STATUS"; echo "RESULT: PASS — backup at $DR_DB_REMOTE/$TS (local copy kept at $RUN; nothing deleted)"
else echo "FAILED" > "$RUN/STATUS"; echo "RESULT: FAIL — see $LOG; partial kept at $RUN, NOT uploaded as success, nothing deleted"; fi
[ "$SELFTEST" = 1 ] && [ -n "$SELFTMP" ] && rm -rf "$SELFTMP"
[ "$ok" = 1 ] && exit 0 || exit 1

#!/usr/bin/env bash
# Strateloq DR — resolve the GPG key blocker WITHOUT interactive pinentry, then run the real
# Supabase database backup end-to-end. One command. Reuses the existing scripts unchanged.
#
# WHY loopback (and why this is NOT weaker): the backup encrypts with the PUBLIC key
# (`gpg --encrypt --recipient`), which needs no passphrase — so weekly unattended backups never
# touch pinentry. The ONLY thing the broken interactive pinentry blocks is creating the keypair
# once. We create it in batch/loopback mode with a STRONG passphrase you type (hidden). The key is
# fully passphrase-protected; loopback only means the passphrase is supplied over the protocol
# instead of a pinentry dialog. We never use an empty passphrase, never disable protection, and
# never put the passphrase on the command line, in Git, or in logs.
#
# Flow: ensure agent allows loopback/preset -> create RSA-4096 encrypt key (2y) if absent ->
# verify encrypt+decrypt round-trip -> preset the passphrase into the agent (so the existing
# scripts' integrity-decrypt runs without pinentry for this run) -> export protected recovery key
# + revocation cert (store OFFLINE; never uploaded) -> validate Supabase connection ->
# run scripts/dr/dr_db_backup_to_drive.sh (dump -> integrity -> encrypt -> upload -> checksum).
#
# Run as your normal user (strateloqbackup), NOT sudo:
#   scripts/dr/dr_setup_key_and_db_backup.sh --env scripts/dr/dr_weekly_backup.env
# Test the whole pipeline with no production/Drive (fake creds, local transport, random passphrase):
#   scripts/dr/dr_setup_key_and_db_backup.sh --self-test
set -uo pipefail
umask 077
[ "$(id -u)" = 0 ] && { echo "Run as your normal user, not root/sudo." >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY_UID="Strateloq Technologies Backup <support@strateloq.com>"
KEY_EMAIL="support@strateloq.com"
GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg}"; export GNUPGHOME

SELFTEST=0; ENV_FILE=""
while [ $# -gt 0 ]; do case "$1" in
  --self-test) SELFTEST=1; shift;;
  --env) ENV_FILE="$2"; shift 2;;
  -h|--help) sed -n '1,30p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

scrub(){ sed -E -e 's#(://[^:/@ ]+):[^@ ]+@#\1:***@#g' -e 's#eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_.-]{6,}#***#g' \
  -e 's#(passphrase|password|api_key|service_role|token)([=: ]+)[^[:space:]]+#\1\2***#gI'; }

# Source a copy with a UTF-8 BOM / CR stripped (Windows/WSL gremlins) so they are never fatal; the
# founder's file is not modified. dr_backup_resume.sh lints the file and names any malformed line.
[ -n "$ENV_FILE" ] && { [ -f "$ENV_FILE" ] || { echo "env not found: $ENV_FILE" >&2; exit 2; }; set -a; . <(sed -e "1s/^$(printf '\357\273\277')//" -e 's/\r$//' "$ENV_FILE"); set +a; }
PRESET="$(ls /usr/lib/gnupg/gpg-preset-passphrase /usr/lib/gnupg2/gpg-preset-passphrase /usr/libexec/gpg-preset-passphrase 2>/dev/null | head -1)"

echo "== DR key setup + database backup ==  user=$(id -un)  GNUPGHOME=$GNUPGHOME  self_test=$SELFTEST"

# 1) agent must allow loopback + preset (does NOT weaken the stored key; only how the passphrase is fed)
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"; touch "$GNUPGHOME/gpg-agent.conf"; chmod 600 "$GNUPGHOME/gpg-agent.conf"
for opt in allow-loopback-pinentry allow-preset-passphrase "default-cache-ttl 600" "max-cache-ttl 1800"; do
  key="${opt%% *}"; grep -q "^$key" "$GNUPGHOME/gpg-agent.conf" || echo "$opt" >> "$GNUPGHOME/gpg-agent.conf"
done
gpgconf --kill gpg-agent 2>/dev/null || true; gpgconf --launch gpg-agent 2>/dev/null || true

# 2) obtain the passphrase (hidden; never logged/argv). self-test uses a random strong one.
if [ "$SELFTEST" = 1 ]; then
  PASS="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' )Aa1!"
else
  PASS=""; PASS2="x"
  if gpg --list-secret-keys "$KEY_EMAIL" >/dev/null 2>&1; then
    echo "A secret key for $KEY_EMAIL already exists — skipping creation. Enter its passphrase to continue:"
    read -rs -p "Passphrase: " PASS; echo
  else
    while :; do
      read -rs -p "New STRONG passphrase for the backup key (min 12 chars): " PASS; echo
      read -rs -p "Confirm passphrase: " PASS2; echo
      [ "$PASS" = "$PASS2" ] || { echo "  mismatch, try again."; continue; }
      [ "${#PASS}" -ge 12 ] || { echo "  too short (>=12), try again."; continue; }
      break
    done
  fi
fi
feed_pass(){ printf '%s' "$PASS"; }   # pipe source; never an argv

# 3) create the key if absent (loopback, no pinentry) — RSA-4096, encrypt, 2 years, protected
if ! gpg --list-secret-keys "$KEY_EMAIL" >/dev/null 2>&1; then
  echo "--- creating RSA-4096 encryption key (2y, passphrase-protected, no pinentry) ---"
  feed_pass | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
    --quick-generate-key "$KEY_UID" rsa4096 encrypt 2y
  [ $? -eq 0 ] || { echo "RESULT: FAIL — key generation failed." >&2; exit 1; }
else echo "--- key already present; continuing ---"; fi
FPR="$(gpg --list-keys --with-colons "$KEY_EMAIL" | awk -F: '/^fpr:/{print $10; exit}')"
echo "  key fingerprint: $FPR"
# Make the key we just created authoritative. DR_GPG_RECIPIENT_FORCE is NOT present in the env file,
# so when dr_db_backup_to_drive.sh re-sources the env it cannot clobber this with a stale recipient
# (e.g. a leftover dr@strateloq.com). The backup therefore always encrypts to THIS key's fingerprint.
export DR_GPG_RECIPIENT="$FPR"
export DR_GPG_RECIPIENT_FORCE="$FPR"

# 4) verify encrypt (public key, no pass) + decrypt (loopback, with pass) round-trip
echo "--- verifying encrypt/decrypt round-trip ---"
TMPV="$(mktemp -d)"; echo "harmless $(date -u)" > "$TMPV/h"
gpg --yes --batch --encrypt --recipient "$FPR" -o "$TMPV/h.gpg" "$TMPV/h" 2>/dev/null
feed_pass | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --decrypt "$TMPV/h.gpg" > "$TMPV/h.out" 2>/dev/null
if cmp -s "$TMPV/h" "$TMPV/h.out"; then echo "  encrypt/decrypt: PASS"; else echo "RESULT: FAIL — round-trip mismatch" >&2; rm -rf "$TMPV"; exit 1; fi
rm -rf "$TMPV"

# 5) preset the passphrase into the agent so the existing scripts' integrity-decrypt needs no pinentry
if [ -n "$PRESET" ]; then
  while read -r grip; do [ -n "$grip" ] && feed_pass | "$PRESET" --preset "$grip" 2>/dev/null; done < <(
    gpg --with-keygrip --list-secret-keys "$KEY_EMAIL" 2>/dev/null | awk '/Keygrip/{print $3}')
  echo "  passphrase preset into agent (TTL-limited) for this run."
fi

# 6) export protected recovery material (passphrase-protected; store OFFLINE; never uploaded)
# IDEMPOTENT: if a prior run already exported the secret key, do NOT overwrite it (and do not re-expose
# it on disk if the founder already moved it offline). Only export when it is absent.
REC="${DR_BACKUP_ROOT:-$HOME/strateloq-backups}/recovery"; mkdir -p "$REC"; chmod 700 "$REC"
if [ -f "$REC/strateloq-backup-secret.asc" ]; then
  echo "  recovery material already present in $REC — left untouched (not overwritten)."
else
  gpg --batch --yes --export-secret-keys --armor "$FPR" > "$REC/strateloq-backup-secret.asc" 2>/dev/null
  [ -f "$GNUPGHOME/openpgp-revocs.d/$FPR.rev" ] && cp -f "$GNUPGHOME/openpgp-revocs.d/$FPR.rev" "$REC/strateloq-backup-revoke.asc"
  gpg --export --armor "$FPR" > "$REC/strateloq-backup-public.asc" 2>/dev/null
  chmod 600 "$REC"/*.asc 2>/dev/null
  echo "  recovery material written to $REC (secret key is passphrase-protected). MOVE it to OFFLINE media;"
  echo "  keep the passphrase ONLY in your password manager; never upload the secret key or passphrase."
fi
unset PASS PASS2 2>/dev/null

# 7) validate Supabase connection (no credentials printed) — real mode only
if [ "$SELFTEST" = 0 ]; then
  : "${SUPABASE_DB_URL:?set in --env}"
  echo "--- validating Supabase connection (no credentials shown) ---"
  if psql "$SUPABASE_DB_URL" -tAc 'select version();' >/dev/null 2>&1; then echo "  connection: PASS"; else echo "RESULT: FAIL — Supabase connection failed (check SUPABASE_DB_URL)." | scrub >&2; exit 1; fi
fi

# 8) run the existing DB-backup-to-Drive pipeline (dump -> integrity -> encrypt -> upload -> checksum)
echo "--- running scripts/dr/dr_db_backup_to_drive.sh ---"
if [ "$SELFTEST" = 1 ]; then
  bash "$HERE/dr_db_backup_to_drive.sh" --self-test; RC=$?
else
  bash "$HERE/dr_db_backup_to_drive.sh" --env "$ENV_FILE"; RC=$?
fi
[ $RC -eq 0 ] && echo "RESULT: PASS — key ready + database backup uploaded & checksum-verified." \
             || echo "RESULT: FAIL — database backup step failed (rc=$RC); see its log."
exit $RC

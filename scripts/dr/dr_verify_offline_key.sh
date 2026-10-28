#!/usr/bin/env bash
# Strateloq DR — VERIFY the offline private recovery key (Requirement 3).
#
# Storing strateloq-backup-secret.asc offline is not enough — you must prove the offline copy is
# complete, importable, and that its passphrase actually unlocks it, INDEPENDENTLY of your live keyring
# (otherwise a silently-corrupt export or a forgotten passphrase is only discovered during a real
# disaster). This script does a full key-recovery rehearsal in a THROWAWAY keyring:
#   import the offline .asc -> derive its fingerprint -> encrypt a fresh nonce to it -> decrypt the nonce
#   with the passphrase -> compare. PASS means the offline key can decrypt backups on a bare machine.
#
# It NEVER touches ~/.gnupg (uses a private, mode-700, temp GNUPGHOME that is shredded on exit), NEVER
# prints or logs the passphrase, and copies the key nowhere persistent.
#
# Run it against the copy ON the offline media (mount the USB / export from the password manager first),
# so you are testing the stored artifact, not the live keyring:
#   OFFLINE_KEY=/mnt/usb/strateloq-backup-secret.asc  scripts/dr/dr_verify_offline_key.sh
# Passphrase: typed at a hidden prompt (preferred) or supplied via DR_GPG_PASSPHRASE for automation.
set -euo pipefail

OFFLINE_KEY="${OFFLINE_KEY:-${1:-}}"
: "${OFFLINE_KEY:?set OFFLINE_KEY=<path to the offline strateloq-backup-secret.asc>}"
[ -f "$OFFLINE_KEY" ] || { echo "ERROR: offline key file not found: $OFFLINE_KEY" >&2; exit 2; }
command -v gpg >/dev/null 2>&1 || { echo "ERROR: gpg not found" >&2; exit 2; }

# passphrase: never on argv/env-echo; read hidden unless supplied for automation
PASS="${DR_GPG_PASSPHRASE:-}"
if [ -z "$PASS" ]; then
  printf 'Offline backup-key passphrase (hidden): ' >&2
  read -rs PASS; echo >&2
fi
[ -n "$PASS" ] || { echo "ERROR: empty passphrase" >&2; exit 2; }

# throwaway keyring; shred everything on any exit
GH="$(mktemp -d "${TMPDIR:-/tmp}/dr-keyverify.XXXXXX")"; chmod 700 "$GH"
cleanup() { rm -rf "$GH" 2>/dev/null || true; }
trap cleanup EXIT
export GNUPGHOME="$GH"

echo "== Strateloq DR — offline recovery-key verification =="
echo "Offline key file: $OFFLINE_KEY"
echo "Keyring:          throwaway ($GH), shredded on exit — your live ~/.gnupg is untouched"

# 1) import the offline secret key into the clean keyring
if ! gpg --batch --import "$OFFLINE_KEY" 2>"$GH/import.log"; then
  echo "RESULT: FAIL — the offline key file could not be imported (corrupt/incomplete export?)" >&2
  sed 's/^/   gpg: /' "$GH/import.log" >&2 || true
  exit 1
fi

# 2) derive the secret-key fingerprint that was imported (public identifier; safe to display)
FPR="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || { echo "RESULT: FAIL — no SECRET key present after import (you may have exported only the public key)" >&2; exit 1; }
UID_LINE="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^uid:/{print $10; exit}')"
echo "Imported secret key: $FPR"
echo "User id:             ${UID_LINE:-<none>}"

# 3) encrypt a fresh nonce to that key, then decrypt it back with the passphrase (loopback = no pinentry)
NONCE="dr-key-verify-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
printf '%s' "$NONCE" > "$GH/nonce.txt"
gpg --batch --yes --no-auto-key-locate --trust-model always --encrypt \
    --recipient "$FPR" -o "$GH/nonce.gpg" "$GH/nonce.txt"

DEC="$(printf '%s' "$PASS" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
         --decrypt "$GH/nonce.gpg" 2>"$GH/dec.log" || true)"

if [ "$DEC" = "$NONCE" ]; then
  echo
  echo "RESULT: PASS — offline key imports, the passphrase unlocks it, and it decrypts correctly."
  echo "Evidence to record (all non-secret): fingerprint $FPR, verified $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  exit 0
else
  echo
  echo "RESULT: FAIL — round-trip decrypt did not match. Likely a wrong passphrase or an incomplete key." >&2
  sed 's/^/   gpg: /' "$GH/dec.log" >&2 || true
  exit 1
fi

# STRATELOQ DR — Offline preservation + VERIFICATION of the private recovery key

Ref: `STRATELOQ-DR-KEY-PRESERVATION-003` · Date: 2026-10-28 · **No secrets in this file.**

The weekly backups are encrypted to the RSA-4096 backup key (`support@strateloq.com`). They can be
decrypted **only** with that key's PRIVATE half **and** its passphrase. If the machine holding the key
is lost and no verified offline copy exists, **every backup becomes unrecoverable**. This runbook makes
the offline copy, stores it safely, and — the part usually skipped — **proves it actually works**, so a
corrupt export or a forgotten passphrase is found now, not during a disaster.

> This cloud session cannot reach your machine or your offline media, so the `[YOU]` steps are done by
> you on your WSL box. What is proven in the cloud: both scripts below were self-tested end-to-end
> (throwaway keys/keyrings, no production) — the verifier PASSES a good offline copy and FAILS a wrong
> passphrase or a public-only export, and it never touches your live `~/.gnupg`.

## What must exist offline (three artifacts, none next to the passphrase)
1. `strateloq-backup-secret.asc` — the **passphrase-protected** private key (not plaintext).
2. `strateloq-backup-revoke.asc` — the revocation certificate (to retire the key if compromised).
3. The **passphrase** — in your password manager, stored **separately** from the three files above.

## [YOU] 1. Produce the export (idempotent — never overwrites/re-exposes an existing one)
`scripts/dr/dr_setup_key_and_db_backup.sh` already writes these under `~/strateloq-backups/recovery/`
on first run and SKIPS re-export on later runs. To (re)create them manually:
```bash
FPR=$(gpg --list-keys --with-colons support@strateloq.com | awk -F: '/^fpr:/{print $10; exit}')
gpg --export-secret-keys --armor "$FPR" > strateloq-backup-secret.asc   # passphrase-protected
cp "$HOME/.gnupg/openpgp-revocs.d/$FPR.rev" strateloq-backup-revoke.asc  # revocation certificate
# optional printable paper copy:
paperkey --secret-key <(gpg --export-secret-keys "$FPR") --output strateloq-backup-paperkey.txt
```
Record the **fingerprint** `$FPR` (a public identifier, safe to keep) — you will match it during
verification and recovery.

## [YOU] 2. Store it offline, with separation (the whole point of "offline")
- Copy the three `.asc`/paper artifacts to **at least two** offline locations you control, e.g. an
  **encrypted USB stick** kept physically secure, and/or a **password-manager secure-note attachment**.
- **NOT** in the same Google Drive as the backups (a single breach must not yield both the ciphertext
  and the key), and **NOT** in the repo (the recovery dir is git-ignored).
- Keep the **passphrase** only in your password manager, in a **different** entry from the key file.
- Two independent copies guard against media failure; separation from the data and the passphrase
  guards against a single compromise.

## [YOU] 3. VERIFY the offline copy actually works (produces evidence)
Do this **from the offline media**, not from your live keyring — that is what proves the stored artifact
is complete and the passphrase is correct. Mount the USB (or export the file from the password manager),
then:
```bash
OFFLINE_KEY=/mnt/usb/strateloq-backup-secret.asc  scripts/dr/dr_verify_offline_key.sh
# prompts for the passphrase at a hidden prompt; nothing is printed or logged
```
It imports the offline key into a **throwaway keyring** (your `~/.gnupg` is untouched and the throwaway
is shredded on exit), encrypts a nonce to the key, and decrypts it back. On success:
```
RESULT: PASS — offline key imports, the passphrase unlocks it, and it decrypts correctly.
Evidence to record (all non-secret): fingerprint <FPR>, verified <UTC timestamp>.
```
`RESULT: FAIL` means the export is incomplete/corrupt or the passphrase is wrong — fix it (re-export
from the live key, or correct the password-manager entry) and re-verify **before** you rely on it.

Re-run this verification whenever the key is rotated, the media is replaced, or at least once per
quarter, and keep the evidence line in the audit log.

### Evidence record (fill in and keep in the audit log — all non-secret)
| Date (UTC) | Fingerprint | Media location (described) | Verifier RESULT |
|------------|-------------|----------------------------|-----------------|
|            |             | e.g. "encrypted USB #1 + 1Password note" | PASS / FAIL |

## Recovery-time use (how the offline key is actually consumed)
On a bare machine during a real recovery, import the offline key first, then the restore drill decrypts
with it:
```bash
gpg --import /mnt/usb/strateloq-backup-secret.asc          # enter the passphrase
# then run the isolated restore drill (see FULL-RESTORE-DRILL-PLAN.md):
RESTORE_DB_URL='…isolated…' DR_DUMP=./restore/<TS>/strateloq-db-<TS>.dump.gpg \
  scripts/dr/dr_restore_drill.sh --confirm
```

## If the key is ever compromised
Publish/apply `strateloq-backup-revoke.asc`, generate a NEW backup key, re-point `DR_GPG_RECIPIENT`, and
take a fresh backup encrypted to the new key. Old ciphertext stays readable only with the old key, so
keep the old offline copy until every backup encrypted to it has aged out of retention.

# STRATELOQ DR — GPG key fix + Supabase database backup to Google Drive

Ref: `STRATELOQ-DR-GPG-AND-DB-BACKUP-001` · Date: 2026-10-27
Fixes `gpg: agent_genkey failed: Permission denied` on WSL, creates the backup key, and takes an
encrypted Supabase DB backup to Google Drive. **No secrets in this file.**

> This cloud session cannot reach your WSL computer, so nothing below is "done on your machine" until
> you run it there. What *was* done here is the diagnosis + fix + the end-to-end test of the scripts
> against a throwaway Postgres (see "Completed, with evidence"). Steps needing your machine / real
> credentials / interactive passphrase / your Google Drive are marked **[YOU]**.

## Root cause (reproduced + confirmed)
`gpg-agent` runs as your user but cannot write the new private key into
`~/.gnupg/private-keys-v1.d/` because that subdirectory (or files in it) are **owned by root** — the
residue of an earlier `sudo gpg`. The public keybox is created fine (so `~/.gnupg` "looks" OK and the
socket exists), yet key generation fails. Agent log line that proves it:
```
gpg-agent: can't open '…/private-keys-v1.d/<FPR>.key': Permission denied
gpg-agent: command 'GENKEY' failed: Permission denied
```
Do **not** work around it by running gpg under `sudo` / with root-owned keys — that deepens the same
problem. The durable fix is to return ownership to your user and set strict perms.

## Completed here, with evidence (no production touched)
- Reproduced the exact failure with a root-owned `private-keys-v1.d`; captured the agent log above.
- Applied the fix (ownership → user, `700`/`600` perms); key generation then succeeded; encrypt +
  decrypt round-trip **PASS**.
- Self-tested `fix-gpg-agent-wsl.sh` (happy path → PASS; foreign-owned + no sudo → prints the exact
  `sudo chown` and exits 3).
- Self-tested `dr_db_backup_to_drive.sh`, then ran it **real-mode** against a throwaway local Postgres:
  dump (via `dr_db_logical_backup.sh`) → integrity (`pg_restore -l`, 18 TOC entries) → SHA256 manifest
  → upload → checksum-verify, all **PASS**, with an independent `sha256sum -c` = `OK`.

---

## [YOU] Run on your WSL machine, as `strateloqbackup` (never `sudo`)

### 1. Fix the GPG agent (diagnose → fix → verify machinery)
```bash
cd /home/strateloqbackup/strateloq-backup/global-intelligence-pulse   # your repo checkout
chmod +x scripts/dr/*.sh
scripts/dr/fix-gpg-agent-wsl.sh            # add --diagnose-only first if you want to look before changing
```
If it reports root/foreign-owned files and `sudo` is unavailable in that shell, it prints one command
(`sudo chown -R strateloqbackup:strateloqbackup ~/.gnupg`); run it, then re-run the script. It ends
with `RESULT: PASS` once key-gen + encrypt + decrypt all work (verified with a throwaway key in a temp
homedir — your real keyring is untouched).

### 2. Create the dedicated backup key — INTERACTIVE passphrase (never printed or stored)
```bash
export GPG_TTY=$(tty)
gpg --quick-generate-key "Strateloq Technologies Backup <support@strateloq.com>" rsa4096 encrypt 2y
```
`pinentry-curses` prompts for a strong passphrase — you type it; it is never echoed or written
anywhere. Note the key id/fingerprint it prints (that is a public identifier, safe to keep):
```bash
gpg --list-keys "support@strateloq.com"          # shows the fingerprint; set DR_GPG_RECIPIENT to it
```
Put that fingerprint (or `support@strateloq.com`) into `scripts/dr/dr_weekly_backup.env` as
`DR_GPG_RECIPIENT`.

### 3. Verify encryption/decryption with a harmless file
```bash
echo "harmless test $(date -u)" > /tmp/dr-hello.txt
gpg --encrypt --recipient "support@strateloq.com" /tmp/dr-hello.txt
gpg --decrypt /tmp/dr-hello.txt.gpg            # prompts for the passphrase; must match the original
shred -u /tmp/dr-hello.txt /tmp/dr-hello.txt.gpg
```

### 4. Back up the PRIVATE key — independently, never unprotected, never with the passphrase
The exported secret key below is **encrypted by your passphrase** (so it is protected, not plaintext):
```bash
FPR=$(gpg --list-keys --with-colons support@strateloq.com | awk -F: '/^fpr:/{print $10; exit}')
gpg --export-secret-keys --armor "$FPR" > strateloq-backup-secret.asc     # passphrase-protected
cp "$HOME/.gnupg/openpgp-revocs.d/$FPR.rev" strateloq-backup-revoke.asc    # revocation certificate
```
Store `strateloq-backup-secret.asc` **offline and independently** — an encrypted USB stick and/or your
password manager — **not** in the same Google Drive as the backups, and **never** stored next to the
passphrase. Keep the passphrase only in your password manager. Optional printable offline copy:
`paperkey --secret-key <(gpg --export-secret-keys "$FPR") --output strateloq-backup-paperkey.txt`.
Without this key **and** its passphrase the encrypted backups cannot be recovered, so treat the key
backup as critical and keep it in a different place from the data.

### 5. Validate the Supabase connection (no credentials revealed)
`SUPABASE_DB_URL` lives only in `scripts/dr/dr_weekly_backup.env` (chmod 600, git-ignored). This prints
the server version, never the connection string:
```bash
set -a; . scripts/dr/dr_weekly_backup.env; set +a
psql "$SUPABASE_DB_URL" -tAc 'select version();'      # a version string = connection OK
```

### 6. Create + encrypt + upload the database backup, then verify the checksum
Reuses `dr_db_logical_backup.sh`; uploads to your Google Drive **Supabase Database** folder via your
existing authorised rclone remote (`DR_DB_REMOTE` in the env file):
```bash
rclone listremotes                                    # confirm the remote in DR_DB_REMOTE exists
scripts/dr/dr_db_backup_to_drive.sh --env scripts/dr/dr_weekly_backup.env
```
It runs: `pg_dump -Fc` → gpg-encrypt (plaintext shredded) → integrity (decrypt to a private temp +
`pg_restore -l`, then shred) → `SHA256SUMS` → `rclone copy` to `DR_DB_REMOTE/<timestamp>/` →
`rclone check --one-way` (remote md5 vs local) → `RESULT: PASS/FAIL`. It never deletes existing
backups and, on any failure, keeps the partial set locally and does **not** report success.
Independent re-check of the uploaded file:
```bash
rclone check "$HOME/strateloq-backups/db-<TS>/stage" "$DR_DB_REMOTE/<TS>" --one-way
```

---

## Manual recovery (restore the DB backup into an ISOLATED target — never production)
```bash
rclone lsf "$DR_DB_REMOTE" --dirs-only                 # pick newest <TS>
rclone copy "$DR_DB_REMOTE/<TS>" ./restore/<TS>
cd ./restore/<TS> && sha256sum -c SHA256SUMS           # must print OK
gpg --decrypt strateloq-db-<TS>.dump.gpg > d.dump      # prompts for passphrase
pg_restore -l d.dump | head                            # inspect TOC (optional integrity look)
pg_restore -d "$ISOLATED_DB_URL" --no-owner d.dump     # ISOLATED db, never production
shred -u d.dump
```
If the machine holding the key is lost, import the offline key backup first:
`gpg --import strateloq-backup-secret.asc` (enter the passphrase), then decrypt as above.

## Still outstanding (unchanged, tracked separately)
The two Google credential-recovery items (`httpQueryAuth` → Gemini / Google-YouTube) remain BLOCKED in
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md` + `dr/n8n/credential-blocked.txt`. They are unrelated to this
GPG/DB work.

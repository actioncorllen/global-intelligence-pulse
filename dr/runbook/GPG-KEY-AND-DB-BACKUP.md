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
the agent (running as you) cannot write the new private key into `~/.gnupg/private-keys-v1.d/`. The
public keybox is created fine (so `~/.gnupg` "looks" OK and the socket exists), yet key generation
fails. The exact errno classifies the cause (confirmed by reproduction):
```
agent_genkey failed: Permission denied        -> EACCES: private-keys-v1.d not owned/writable by you
                                                  (e.g. root-owned residue of `sudo gpg`), OR a
                                                  filesystem (DrvFs/9p, /mnt/c) where chmod/chown
                                                  silently don't take effect
agent_genkey failed: Operation not permitted   -> EPERM: immutable/append attribute (chattr +i/+a)
agent_genkey failed: Read-only file system      -> EROFS: mount is read-only
```
A throwaway/temp homedir (e.g. in `/tmp`) generates keys fine, so a temp-only test can PASS while the
real `~/.gnupg` is still broken — that is exactly the trap the previous attempt hit. Do **not** work
around it with `sudo gpg` / root-owned keys. The durable, sudo-free fix is to move the broken `~/.gnupg`
**aside** (a rename needs write on `~` only, so it works even if a subdir is root-owned) and use a
fresh homedir — then verify **in the real homedir**.

## Completed here, with evidence (no production touched)
- Reproduced both errnos: root-owned `private-keys-v1.d` → `Permission denied` (EACCES, the user's
  error); immutable bit → `Operation not permitted` (EPERM) — so immutable is ruled out by evidence.
- Proved the sudo-free durable fix: `mv ~/.gnupg ~/.gnupg.broken.<ts>` + fresh homedir → key generation
  **in the real homedir PASS**, private key written user-owned.
- Enhanced + self-tested `fix-gpg-agent-wsl.sh`: diagnoses fs type / ownership / attrs / ACL / stale
  agents, probes key-gen **in the real homedir** (capturing the exact errno), applies the fix, and
  re-verifies **in the real homedir**; idempotent (2nd run → "already WORKS"); old homedir preserved.
- Self-tested `dr_db_backup_to_drive.sh`, then ran it **real-mode** against a throwaway local Postgres:
  dump (via `dr_db_logical_backup.sh`) → integrity (`pg_restore -l`, 18 TOC entries) → SHA256 manifest
  → upload → checksum-verify, all **PASS**, with an independent `sha256sum -c` = `OK`.
- Interactive-pinentry investigation: confirmed the fix-script probe uses `--pinentry-mode loopback`
  and so **never exercised pinentry** — its PASS only means the key store is writable. Mapped the
  errors by reproduction: missing/non-exec pinentry → `No pinentry`; immutable attr → `Operation not
  permitted`; no controlling tty → `cannot open '/dev/tty'`; key-store EACCES → `Permission denied`.
- Host evidence `ERR 83886142 Timeout <Pinentry>` decoded to **source=PINENTRY, code=62=Timeout** →
  the failure is the curses passphrase UI, not the agent/permissions. The standalone `GETPIN` test is a
  known false signal (shared terminal). Smallest durable fix = line-mode **pinentry-tty**;
  `diagnose-gpg-pinentry.sh` now auto-selects it (self-tested: selected+persisted when present, curses
  fallback + install hint when absent; conf restored, debug log shredded). The interactive key-gen is a
  `[YOU]` step confirmable only on a real terminal — never claimed PASS from loopback/temp here.

---

## [YOU] Run on your WSL machine, as `strateloqbackup` (never `sudo`)

### 1. Fix the GPG agent (diagnose → fix → verify IN THE REAL homedir)
```bash
cd /home/strateloqbackup/strateloq-backup/global-intelligence-pulse   # your repo checkout
chmod +x scripts/dr/*.sh
scripts/dr/fix-gpg-agent-wsl.sh --diagnose-only     # look first: prints fs type, owners, attrs, ACL, errno
scripts/dr/fix-gpg-agent-wsl.sh                     # diagnose + fix + verify in the REAL ~/.gnupg
```
This validates that the key **store** is writable. **Important:** its probe uses
`--pinentry-mode loopback`, so it supplies the passphrase itself and **does not exercise pinentry** —
a `RESULT: PASS` here does **not** prove interactive key generation works. If step 2 below still fails
with `agent_genkey failed: Permission denied`, the cause is the pinentry/passphrase path — go to
step 1b.

### 1b. If interactive key-gen fails though step 1 "passed" — fix the pinentry/terminal path
**Confirmed root cause for this host:** the failure is in the **passphrase UI (pinentry-curses)**, not
the agent or permissions. The error `ERR 83886142 Timeout <Pinentry>` decodes to source **PINENTRY**,
code **62 = Timeout**. Note: testing by running `pinentry-curses` and typing `GETPIN` by hand is
**unreliable** — that shares one terminal for both the Assuan protocol and the curses dialog, so it
always times out; it does **not** prove pinentry is broken in real agent use. curses pinentry is simply
flaky on WSL terminals.

**Smallest durable fix — switch to line-mode `pinentry-tty` (fully secure; no loopback, no weakening):**
```bash
sudo apt-get install -y pinentry-tty        # free; the robust pinentry for WSL
scripts/dr/diagnose-gpg-pinentry.sh         # in a REAL WSL terminal (not the VS Code integrated one)
```
The script auto-selects `pinentry-tty` when present (else falls back to `pinentry-curses` with a valid
`TERM` and prints the install line), sets it in `gpg-agent.conf`, applies `GPG_TTY=$(tty)` +
`gpg-connect-agent updatestartuptty` + a fresh user-owned agent, turns on debug logging, then runs the
**real** interactive `gpg --quick-generate-key` so you enter the passphrase. On success it creates the
protected key (that is step 2, done); on failure it prints the exact agent-log line + a decision tree,
then restores `gpg-agent.conf` (keeping the pinentry-tty setting) and shreds the debug log. Other fixes
it may point to: wrong terminal → run in a native WSL terminal; a `GNUPGHOME` mismatch → `export
GNUPGHOME=<the path step 1 fixed>`. It never uses `--pinentry-mode loopback` / empty passphrase.

### 2. Create the dedicated backup key — INTERACTIVE passphrase (never printed or stored)
If step 1b already created the key, skip to step 3. Otherwise, in a real terminal:
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

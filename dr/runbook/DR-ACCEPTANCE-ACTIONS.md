# STRATELOQ DR — the three acceptance actions (founder, one command each)

Ref: `STRATELOQ-DR-ACCEPTANCE-004` · Date: 2026-10-28

Everything that can be done from the cloud is done and verified. Three acceptance requirements need the
one thing the cloud cannot have — **your Windows/WSL machine, your private key, your passphrase**. Each
is a single command that produces its own evidence. Run them as `strateloqbackup` on WSL (never `sudo`).

First, get the latest scripts:
```bash
cd /home/strateloqbackup/strateloq-dr-validate && git pull && chmod +x scripts/dr/*.sh
```

---

## Action 1 — REAL unattended weekly backup (Requirement 1)
The silent-failure defects are fixed (flush-safe run log, durable RESULT line, `--batch --no-tty`
encryption). Trigger the scheduled task itself (not the script by hand) so the *unattended* path is what
runs, then read the evidence:
```powershell
# Windows PowerShell:
Start-ScheduledTask -TaskName "Strateloq-DR-Weekly-Backup"
# wait for it to finish, then:
(Get-ScheduledTaskInfo -TaskName "Strateloq-DR-Weekly-Backup").LastTaskResult   # expect 0
```
```bash
# WSL — the run's own evidence:
cat ~/strateloq-backups/dr-weekly-start.log | tail -5         # expect a RESULT: SUCCESS line
ls -t ~/strateloq-backups/runs/*/STATUS | head -1 | xargs cat  # expect SUCCESS
```
**Evidence = `LastTaskResult 0` + `STATUS SUCCESS` + a NEW dated folder in Drive 01/02/03/04.** If the
log shows a failing component instead, it now names it — send me that line and I fix it.

## Action 2 — isolated end-to-end restore test (Requirement 2)
Restores the newest encrypted DB backup into the isolated project `strateloq-dr-restore` and validates
it. **Never touches production** (the script refuses if the URL names production). Get the isolated
project's Session-pooler connection string + password from Supabase → project `strateloq-dr-restore` →
Settings → Database → Connection string (Session pooler):
```bash
cd ~/strateloq-dr-validate
set -a; . scripts/dr/dr_weekly_backup.env; set +a          # loads DR_DB_REMOTE (the real strateloqdrive: path)
mkdir -p ~/restore && cd ~/restore
TS=$(rclone lsf "$DR_DB_REMOTE" --dirs-only | sort | tail -1)   # newest dated set
rclone copy "$DR_DB_REMOTE/$TS" "./$TS"
DUMP=$(ls ~/restore/"$TS"/strateloq-db-*.dump.gpg)         # the encrypted dump in that set
cd ~/strateloq-dr-validate
# RESTORE_DB_URL = the ISOLATED project's Session-pooler string (Supabase -> strateloq-dr-restore ->
# Connect -> Session pooler), with your password inserted. Its user is postgres.zdeedmuocbbkuwuovlbz;
# paste the exact host from the dashboard (do not guess aws-0 vs aws-1):
RESTORE_DB_URL='postgresql://postgres.zdeedmuocbbkuwuovlbz:<PASSWORD>@<paste-exact-host>.pooler.supabase.com:5432/postgres' \
DR_DUMP="$DUMP" \
DR_RESTORE_SUMS=~/restore/"$TS"/SHA256SUMS \
DR_RESET_PUBLIC=1 \
  scripts/dr/dr_restore_drill.sh --confirm      # prompts once for your backup-key passphrase
```
**Evidence = `RESULT: PASS — N checks passed, 0 failed` + the RPO/RTO lines.** Tell me when it's done
and I re-verify the restored `zdeedmuocbbkuwuovlbz` independently from the cloud (table/row/RLS counts,
advertising fail-closed) via the Supabase tools. Then pause the isolated project to avoid a 2nd data copy.

## Action 3 — verify the offline recovery key (Requirement 3)
Proves the OFFLINE copy of the private key is complete and its passphrase works — from the media, not the
live keyring. Mount the USB (or export the file from your password manager) first:
```bash
cd ~/strateloq-dr-validate
OFFLINE_KEY=/mnt/usb/strateloq-backup-secret.asc scripts/dr/dr_verify_offline_key.sh   # hidden passphrase prompt
```
**Evidence = `RESULT: PASS — offline key imports, the passphrase unlocks it, and it decrypts correctly.`**
plus the fingerprint/date line — record it in the OFFLINE-KEY-PRESERVATION.md evidence table. If you have
not yet copied the key to offline media, do that first (that runbook's step 1–2).

---

Full detail: `WEEKLY-BACKUP-AUTOMATION.md` (Action 1), `FULL-RESTORE-DRILL-PLAN.md` (Action 2),
`OFFLINE-KEY-PRESERVATION.md` (Action 3). Both scripts were self-tested end-to-end in the cloud against
throwaway Postgres/keys (no production), so the only variables left are your machine, key and credentials.

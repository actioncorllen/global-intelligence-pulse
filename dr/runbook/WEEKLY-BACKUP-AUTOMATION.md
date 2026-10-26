# STRATELOQ DR — WEEKLY AUTOMATED BACKUP (setup + manual recovery)

Ref: `STRATELOQ-DR-WEEKLY-AUTOMATION-001` · Date: 2026-10-26
Weekly Sunday backup launched by **Windows Task Scheduler → WSL**, reusing the existing
component scripts. **No secrets in this file.**

> Scheduling status: **NOT yet installed** — this was prepared in a cloud session that cannot
> reach your Windows/WSL machine. It is "installed" only after you run the PowerShell step below
> and its verify command shows the task. The scripts' own logic is fully self-tested (see §Testing).

## What it backs up (each run, gpg-encrypted before upload)
- **Supabase Postgres** — `dr_db_logical_backup.sh` (`pg_dump -Fc`, already gpg-encrypted)
- **Supabase Storage** — `dr_storage_backup.sh` (objects → tar; orchestrator gpg-encrypts)
- **All n8n workflows** — `dr_n8n_export.sh` (active + inactive + archived; per-state count logged)
- **Repo** — `dr_git_bundle.sh` (all branches + tags)

All read-only against production: dumps/exports only. No production workflow, credential, key, or
Supabase row is modified; no paid provider call is made.

## Guarantees (enforced by `dr_weekly_backup.sh`, all self-tested)
- **No overlap** — `flock` single-run lock + Task Scheduler `IgnoreNew`.
- **Encrypt before upload** — every uploaded file is `*.gpg`; plaintext is `shred`-deleted; staging
  is asserted plaintext-free before any upload.
- **Checksum verify** — `SHA256SUMS` manifest; after upload the remote copy is checksum-verified
  (`rclone check --one-way`); **PASS/FAIL recorded** per run.
- **No incomplete "success"** — a run is SUCCESS only if every component collected AND upload
  verified; otherwise it is FAIL, is not uploaded as success, and writes `STATUS=FAILED`.
- **Never delete on failure** — retention prunes only OLD *verified* sets, never the newest, and
  never runs after a failure. Keeps newest `DR_RETAIN` (default 8) sets → bounded storage growth.
- **No secret in logs** — all log output passes a scrubber that masks URL passwords, JWTs and keys.

## Install — one copyable sequence

**A. In WSL (Ubuntu)** — configure and prove one run before scheduling:
```bash
cd /home/strateloqbackup/strateloq-backup/global-intelligence-pulse   # your repo checkout
chmod +x scripts/dr/*.sh
cp -n scripts/dr/dr_weekly_backup.env.example scripts/dr/dr_weekly_backup.env
chmod 600 scripts/dr/dr_weekly_backup.env
nano scripts/dr/dr_weekly_backup.env      # <-- fill in secrets + confirm DR_REMOTE; save
rclone listremotes                         # confirm your Google Drive remote matches DR_REMOTE
# prove the full pipeline with zero production access (fake data, local transport):
bash scripts/dr/dr_weekly_backup.sh --self-test && echo "SELF-TEST PASS"
# first real backup (read-only on prod); check the result + per-state n8n counts:
bash scripts/dr/dr_weekly_backup.sh --env scripts/dr/dr_weekly_backup.env
tail -n 40 "$HOME/strateloq-backups/runs/"*/backup.log | sed -n '1,40p'
```

**B. In Windows PowerShell** — register the weekly Sunday task, then verify:
```powershell
powershell -ExecutionPolicy Bypass -File `
  \\wsl$\Ubuntu\home\strateloqbackup\strateloq-backup\global-intelligence-pulse\scripts\dr\install\install-weekly-backup.ps1 `
  -WslDistro Ubuntu -WslUser strateloqbackup `
  -RepoPath '/home/strateloqbackup/strateloq-backup/global-intelligence-pulse' -Time 03:00
# VERIFY (scheduling is real only if this prints the task + a Sunday trigger):
Get-ScheduledTask -TaskName 'Strateloq-DR-Weekly-Backup' | Format-List TaskName,State
# Optional dry run through the scheduler:
Start-ScheduledTask -TaskName 'Strateloq-DR-Weekly-Backup'
```
Adjust `-WslDistro`, `-WslUser`, `-RepoPath`, `-Time` to your machine. Re-running the installer
updates the task in place; it deletes nothing.

## Testing done (in the Claude cloud session, no production access)
`--self-test` generates a throwaway gpg key + fake artifacts + a local transport and runs the whole
pipeline. Verified: PASS run (exit 0) uploads 4 `*.gpg` + `SHA256SUMS` and checksum-verifies;
retention with 3 runs / `DR_RETAIN=2` prunes the oldest set (local **and** remote), keeps the newest
two; an upload failure yields `RESULT: FAIL` / `STATUS=FAILED` / **exit 1**, keeps the partial
encrypted artifacts, and prunes nothing; a concurrent run exits 3 without overlapping; logs contained
no secret-shaped strings. The only part not exercisable in that session is the literal `rclone` call
(the sandbox rclone is mount-only) — the WSL self-test above exercises it on your machine.

## Manual recovery procedure (restore from a backup set)
Restore into an **ISOLATED** target — never production. You need the gpg **private** key + passphrase
(operator vault) and the Supabase/n8n targets.
```bash
# 1. pull the newest verified set and check integrity
rclone lsf gdrive:Strateloq-DR/weekly --dirs-only          # pick newest <TS>
rclone copy "gdrive:Strateloq-DR/weekly/<TS>" ./restore/<TS>
cd ./restore/<TS> && sha256sum -c SHA256SUMS               # must say OK for every file
# 2. decrypt (prompts for the private-key passphrase; nothing is logged)
for f in *.gpg; do gpg -d "$f" > "${f%.gpg}"; done
# 3a. DB  -> isolated database
pg_restore -d "$ISOLATED_DB_URL" --no-owner "strateloq-db-<TS>.dump"
# 3b. Storage -> re-upload objects from the untarred tree (service role, isolated/project)
tar -xzf "strateloq-storage-<TS>.tgz"
# 3c. n8n -> import into an isolated, offline, inactive instance (reuses the verified restorer)
tar -xf "strateloq-n8n-<TS>.tar" -C ./n8n-defs
bash scripts/dr/dr_n8n_restore.sh --exports ./n8n-defs --data ./n8n-restore-data
bash scripts/dr/dr_n8n_verify_restore.py --exports ./n8n-defs --data ./n8n-restore-data
# 3d. Repo
git clone "strateloq-<TS>.bundle" ./repo
# 4. shred decrypted plaintext when done
shred -u strateloq-db-<TS>.dump 2>/dev/null || rm -f strateloq-db-<TS>.dump
```
See also `RECOVERY-RUNBOOK.md` and `FULL-RESTORE-DRILL-PLAN.md`.

## Still outstanding (tracked separately — NOT part of this backup)
Two Google credential-recovery items remain BLOCKED and are documented in
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md` + `dr/n8n/credential-blocked.txt`:
`httpQueryAuth` "Query Auth account" (→ `generativelanguage.googleapis.com`, Gemini) and
"Query Auth account 2" (→ `www.googleapis.com`). The weekly backup does **not** depend on them —
workflow *definitions* (which carry those credential references) are backed up regardless; only
re-binding live keys at restore needs the founder-supplied Google Cloud project/key.

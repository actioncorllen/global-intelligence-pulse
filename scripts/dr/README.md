# Strateloq DR scripts (€0, manual, operator-run)

All scripts are non-destructive and read secrets from the operator's environment —
**no secret is stored in this repo**. Run them from an operator machine that holds the
credentials (never commit their output if it contains data). See dr/runbook/RECOVERY-RUNBOOK.md.

| Script | Purpose | Requires (env, operator-held) |
|---|---|---|
| dr_git_bundle.sh | Independent single-file mirror of the whole repo (all branches+tags) | git |
| dr_db_logical_backup.sh | Encrypted logical DB backup (schema+data) via pg_dump | SUPABASE_DB_URL, DR_GPG_RECIPIENT |
| dr_schema_snapshot.sql | Regenerate dr/schema/*.sql (functions/policies/triggers/rls) | psql + SUPABASE_DB_URL |
| dr_storage_manifest.sql | Regenerate dr/manifests/storage_manifest.json | psql + SUPABASE_DB_URL |
| dr_storage_backup.sh | Download all Storage objects to an encrypted local copy | SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY |
| dr_n8n_export.sh | Export every n8n workflow definition to JSON (no secrets) | N8N_BASE_URL, N8N_API_KEY |
| dr_weekly_backup.sh | **Orchestrator** — composes the scripts above into one dated run-folder (`<TS>/`), gpg-encrypts each artifact, writes a `SHA256SUMS` manifest, and uploads to the existing rclone remote. Invoked by the Windows Task Scheduler weekly job. | SUPABASE_DB_URL, DR_GPG_RECIPIENT, RCLONE_REMOTE, RCLONE_DEST (+ optional storage/n8n env). Reads `~/.strateloq-dr.env` if present. |
| Repair-StrateloqDR.ps1 | **Operator repair/verify tool (Windows PowerShell).** One-shot: diagnose the installed wrapper + Task + logs → reinstall this tracked orchestrator (fix perms/LF) → verify production target (masked) → run one backup → verify upload/sha256/decrypt/`pg_restore -l` → smallest-safe isolated restore drill. Non-destructive; never prints a secret; never overwrites an existing backup. | WSL Ubuntu + user `strateloqbackup`; rclone remote configured |

### Why `dr_weekly_backup.sh` is now in the repo

The weekly orchestrator was previously an **operator-authored wrapper that lived only in the
WSL clone and was never git-tracked.** A `git checkout` / `git clean` / re-clone of the DR
validate tree therefore wiped it, leaving a missing/zero-byte script — which is why the
`Strateloq-DR-Weekly-Backup` scheduled task began exiting `1` while the (tracked) component
scripts still produced well-formed artifacts in earlier runs. Tracking it here makes a future
checkout self-healing. It **glues** the existing component scripts only — it is not a new
backup architecture, and it still reads every secret from the operator environment.

To repair a broken install, run `Repair-StrateloqDR.ps1` from Windows PowerShell (see the
header in that file for flags such as `-DiagnoseOnly` / `-NoBackup` / `-NoDrill`).

### One-command repair from Windows (no manual Git, no copying scripts)

`Invoke-StrateloqDR.ps1` is a Windows PowerShell 5.1 launcher that retrieves the committed repair
files into your existing Ubuntu-WSL repo **non-destructively** (`git fetch` + `git show <ref>:path
> file` — no branch switch, no checkout of the tree, nothing deleted), runs the diagnosis first,
reports exactly what it intends to change (derived from the evidence, not from an assumption about
the cause), **requests approval before any change to local configuration**, then repairs and
proves the fix with **real operations**: it runs the actual `Strateloq-DR-Weekly-Backup` Windows
scheduled task and reads its real `LastTaskResult`, confirms the fresh encrypted archive is in
Google Drive, verifies SHA-256 + decryptability + `pg_restore -l`, and performs an **actual
isolated restore** into a throwaway local Postgres. It prints **`RESTORE_OK` only when every one
of those real checks passes** — never from a skipped or mock drill. It preserves rclone auth, gpg
keys, Google Drive destinations, existing archives and the Task Scheduler schedule, and the
PowerShell↔WSL bridge is base64-encoded so it is robust under Windows PowerShell 5.1.

The scheduled task is pointed at the **durable** repo-tracked `dr_weekly_backup.sh` (not a
temporary repair script), so the weekly run keeps working after this procedure exits.

Paste this single command into **Windows PowerShell** (adjust the four variables only if your
distro/user/clone/branch differ):

```powershell
$ErrorActionPreference='Stop'; $D='Ubuntu'; $U='strateloqbackup'; $C='/home/strateloqbackup/strateloq-dr-validate'; $B='claude/nifty-ritchie-lwbak6'; wsl.exe -d $D -u $U -- bash -lc "cd '$C' && git fetch origin '$B' -q && for f in Invoke-StrateloqDR.ps1 Repair-StrateloqDR.ps1 dr_weekly_backup.sh README.md; do git show origin/'$B':scripts/dr/`$f > scripts/dr/.`$f.tmp 2>/dev/null && [ -s scripts/dr/.`$f.tmp ] && mv scripts/dr/.`$f.tmp scripts/dr/`$f || rm -f scripts/dr/.`$f.tmp; done && chmod +x scripts/dr/*.ps1 scripts/dr/*.sh 2>/dev/null && echo RETRIEVED_OK"; $rel=$C.TrimStart('/').Replace('/','\'); $L="\\wsl.localhost\$D\$rel\scripts\dr\Invoke-StrateloqDR.ps1"; if(!(Test-Path $L)){ $L="\\wsl`$\$D\$rel\scripts\dr\Invoke-StrateloqDR.ps1" }; powershell -NoProfile -ExecutionPolicy Bypass -File $L -Distro $D -WslUser $U -CloneDir $C -Branch $B
```

Add `-AutoApprove` (skip the confirm prompt), `-NoBackup`, or `-NoDrill` to the final
`powershell ... -File $L ...` segment if needed.

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

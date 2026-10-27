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
| dr_n8n_restore.sh | Restore workflow defs into an isolated, offline, INACTIVE n8n instance (fixes the `SQLITE_CONSTRAINT: FOREIGN KEY constraint failed` CLI-import failure); `--repair` recovers an instance left in the failing state | docker, python3 (no network, no secrets) |
| dr_n8n_sanitize.py | Rewrite exports to import-safe inactive defs (used by dr_n8n_restore.sh) | python3 |
| dr_n8n_credential_refs.py | List distinct n8n credential **references** (type/name/id, no values) across exports; `--detail` drills down to referencing workflows (id/name/active) and nodes (name/type/service-host, host-only) ; `--type`/`--name` focus one credential | python3 |
| dr_n8n_verify_restore.py | Verify a restore against source exports (count/names/nodes/connections/inactive/DB-integrity/archive) and emit a PASS/FAIL report | python3 |
| dr_n8n_credential_readiness.py | Assess credential-recovery readiness from exports — per credential: usage (active-production/inactive/archived), scope (in-scope vs out-of-scope), type hostable, documented, mechanism → READY/MANUAL/BLOCKED/FOREIGN + scope-aware PASS/PARTIAL/BLOCKED. No secrets, no network | python3 |
| **dr_weekly_backup.sh** | **Weekly orchestrator** — reuses the above to back up Supabase DB + Storage + all n8n workflows + the repo, gpg-encrypts, uploads to Google Drive via rclone, checksum-verifies (PASS/FAIL), flock no-overlap, retention, failure logging with secret scrubbing. `--self-test` runs the whole pipeline with fake data + local transport (no production). Config: `dr_weekly_backup.env` (see `.env.example`) | gpg, rclone, flock, pg_dump, git + the env file |
| install/install-weekly-backup.ps1 | Windows Task Scheduler installer (run on Windows) — weekly Sunday task that launches `dr_weekly_backup.sh` inside WSL | PowerShell + WSL |
| fix-gpg-agent-wsl.sh | Diagnose + durably fix GPG `agent_genkey failed: Permission denied` on WSL (root-owned `private-keys-v1.d`); refuses to run as root; verifies with a throwaway key; never creates/uses root keys | gpg (run as your user) |
| dr_db_backup_to_drive.sh | One DB backup to the Google Drive **Supabase Database** folder — reuses `dr_db_logical_backup.sh`, adds decrypt+`pg_restore -l` integrity, SHA256 manifest, rclone upload + checksum-verify (PASS/FAIL); never deletes existing backups | gpg, rclone, pg_dump + env file |

GPG fix + database backup runbook (with manual recovery): `dr/runbook/GPG-KEY-AND-DB-BACKUP.md`.

Weekly backup automation + manual recovery procedure: `dr/runbook/WEEKLY-BACKUP-AUTOMATION.md`.

Credential readiness report: `dr/n8n/N8N-CREDENTIAL-RECOVERY-READINESS-001.md`;
credential-type registry (n8n 2.44.7, reference): `dr/n8n/n8n-2.44.7-credential-types.txt`;
in-scope workflow-id allowlist: `dr/n8n/strateloq-workflow-ids.txt`;
BLOCKED-override list (unresolved creds kept BLOCKED pending founder): `dr/n8n/credential-blocked.txt`.

n8n restore details, root cause and PASS/FAIL evidence: `dr/n8n/N8N-RESTORE-VALIDATION-001.md`;
credential recovery (references only): `dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md`.

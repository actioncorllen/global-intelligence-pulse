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

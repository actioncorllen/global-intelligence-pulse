-- Regenerate the independent logical SCHEMA snapshot (dr/schema/*.sql).
-- Run with: psql "$SUPABASE_DB_URL" -Atqf scripts/dr/dr_schema_snapshot.sql
-- Produces the same content this DR unit committed. NO secrets, NO customer data.
-- functions:
\o dr/schema/functions.sql
SELECT string_agg(def, E'\n\n' ORDER BY nm) FROM (
  SELECT p.proname nm, pg_get_functiondef(p.oid)||';' def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.prokind IN ('f','p')) s;
\o
-- policies + rls + triggers can be regenerated with the same queries used in
-- STRATELOQ-DR-FOUNDATION-AUDIT-AND-RECOVERY-001 (see that doc). For a complete,
-- restorable dump prefer scripts/dr/dr_db_logical_backup.sh (pg_dump -Fc).

-- =====================================================================
-- provision_ci_gate_role.sql — least-privilege CI role for the security gate
-- =====================================================================
-- Project: strateloq-billing-staging (nlfkwrjmhxbubtlwepwx). Staging only.
-- NEVER run against production (nxaunmyihhjixxxljcqt).
--
-- Creates a dedicated, least-privilege, READ-ONLY login role used only by the
-- Tier-1 catalog gate (scripts/security/security_gate_catalog.sql). The role:
--   * has NO password set here (it is INERT and cannot authenticate until an
--     operator sets one — see step 2 below), so this script leaks no secret;
--   * is NOT a member of anon / authenticated / service_role (cannot SET ROLE);
--   * has NO table privileges and NO EXECUTE on billing RPCs (no business-data
--     access) — it can read only catalog metadata;
--   * is NOSUPERUSER, NOBYPASSRLS, NOCREATEROLE, NOCREATEDB.
-- A leaked credential for this role therefore exposes no customer/billing data.
--
-- Idempotent. Already applied to staging on 2026-11-10.
-- =====================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='security_gate_ro') THEN
    CREATE ROLE security_gate_ro WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
END $$;

GRANT CONNECT ON DATABASE postgres TO security_gate_ro;
GRANT USAGE   ON SCHEMA public       TO security_gate_ro;   -- USAGE only; NOT CREATE
REVOKE CREATE ON SCHEMA public       FROM security_gate_ro;

COMMENT ON ROLE security_gate_ro IS
  'Least-privilege CI role for scripts/security/security_gate_catalog.sql (read-only catalog checks). '
  'No data access, no SET ROLE, no RPC execute. Password set by operator; used only by the billing-staging security gate.';

-- -------------------------------------------------------------------------
-- OPERATOR STEPS (not performed by this script — keep the password out of source):
--   1. Set a strong password for the role (via the Supabase SQL editor, so the
--      value never passes through CI/source/logs):
--        ALTER ROLE security_gate_ro PASSWORD '<generated-strong-password>';
--   2. Build the pooler connection string (IPv4-friendly; transaction pooler):
--        postgresql://security_gate_ro.nlfkwrjmhxbubtlwepwx:<password>@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require
--      (Confirm the exact pooler host/port in Supabase → Project → Connect.)
--   3. Store it as the GitHub Actions secret BILLING_STAGING_DB_URL_RO
--      (repo → Settings → Secrets and variables → Actions → New repository secret).
-- To revoke later: DROP ROLE security_gate_ro;  (and delete the secret).
-- =====================================================================

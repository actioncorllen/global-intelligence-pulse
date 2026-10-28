-- ============================================================================
-- mig_302_harden_anon_execute_selftests.sql
-- STRATELOQ-SECURE-ANON-DB-FUNCTION-ACCESS  (Group D: self-test functions)
--
-- CONTEXT: a project-wide scan found 171 SECURITY DEFINER functions in `public`
-- executable by the `anon` (unauthenticated) role, via a default PUBLIC grant plus
-- explicit anon grants (ACL: `=X | anon=X | authenticated=X | service_role=X`).
-- SECURITY DEFINER bypasses RLS, so unauthenticated callers should not reach internal
-- functions. This migration hardens GROUP D — the self-test (`*_selftest`) functions,
-- which are development/CI harnesses never meant to be publicly or customer-executable.
--
-- ACTION: revoke EXECUTE from `anon`, `authenticated`, and `PUBLIC` on every
-- public `*_selftest` SECURITY DEFINER function. `service_role` and the owner (postgres)
-- retain EXECUTE, so internal/CI invocation is unchanged. No function body or signature
-- is modified. Fully reversible (GRANT EXECUTE ... TO <role>). Non-destructive to data.
--
-- SAFETY: internal SECURITY DEFINER callers run as the owner and are unaffected by a
-- client-role revoke; n8n/service_role retain EXECUTE. Nothing in the frontend or any
-- public edge function calls a `*_selftest` function.
-- ============================================================================
DO $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace nmsp ON nmsp.oid = p.pronamespace
    WHERE nmsp.nspname = 'public' AND p.prokind = 'f' AND p.prosecdef
      AND p.proname LIKE '%selftest'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'mig_302: hardened % self-test functions (anon/authenticated/PUBLIC revoked)', n;
END $$;

-- =====================================================================
-- security_gate_catalog.sql — TIER 1: read-only catalog security gate
-- =====================================================================
-- Project: strateloq-billing-staging (nlfkwrjmhxbubtlwepwx). Staging only.
--
-- Least-privilege, READ-ONLY gate — safe to run from CI with a dedicated
-- read-only role (see scripts/security/provision_ci_gate_role.sql). It uses
-- ONLY catalog reads: no SET ROLE, no temp objects, no table-data reads, no
-- function execution. It therefore needs no access to any business data, so a
-- leaked CI credential for the gate role exposes nothing but schema metadata.
--
-- The privileged BEHAVIOURAL checks (role simulation via SET ROLE + the
-- fn_billing_selftest suite) live in scripts/security/security_regression_test.sql
-- and must be run with an elevated connection via MCP / a protected manual job —
-- never with credentials exposed to untrusted pull requests.
--
-- Exit behaviour: prints one NOTICE per check, then RAISES (non-zero exit under
-- `psql -v ON_ERROR_STOP=1`) if ANY check fails. Read-only; makes no changes.
--
-- Checks:
--   T1 every public table has RLS enabled
--   T2 no anon / PUBLIC table grants
--   T3 no authenticated / PUBLIC table writes
--   T4 no authenticated grants on billing tables
--   T5 member has a tenant-scoped SELECT policy (auth.uid() = auth_user_id)
--   T6 no policy grants anon / PUBLIC row access
--   T7 billing RPC EXECUTE grants: anon can execute none; backend RPCs are not
--      executable by authenticated
--   T8 every fn_billing_* is SECURITY DEFINER with a locked search_path
-- =====================================================================
DO $$
DECLARE fails text[] := ARRAY[]::text[]; d text; n int;
BEGIN
  -- T1
  SELECT string_agg(relname, ', ') INTO d
  FROM pg_class k JOIN pg_namespace ns ON ns.oid=k.relnamespace
  WHERE ns.nspname='public' AND k.relkind='r' AND NOT k.relrowsecurity;
  IF d IS NOT NULL THEN fails := fails || ('T1 RLS disabled on: '||d); END IF;
  RAISE NOTICE 'T1 RLS-on-all-public-tables ............. %', CASE WHEN d IS NULL THEN 'PASS' ELSE 'FAIL ['||d||']' END;

  -- T2
  SELECT string_agg(distinct grantee||':'||table_name, ', ') INTO d
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND grantee IN ('anon','PUBLIC');
  IF d IS NOT NULL THEN fails := fails || ('T2 anon/PUBLIC table grants: '||d); END IF;
  RAISE NOTICE 'T2 no-anon/PUBLIC-table-access .......... %', CASE WHEN d IS NULL THEN 'PASS' ELSE 'FAIL ['||d||']' END;

  -- T3
  SELECT string_agg(distinct table_name||'/'||privilege_type, ', ') INTO d
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND grantee IN ('authenticated','PUBLIC')
    AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE');
  IF d IS NOT NULL THEN fails := fails || ('T3 authenticated/PUBLIC writes: '||d); END IF;
  RAISE NOTICE 'T3 no-authenticated/PUBLIC-writes ....... %', CASE WHEN d IS NULL THEN 'PASS' ELSE 'FAIL ['||d||']' END;

  -- T4
  SELECT string_agg(distinct table_name||'/'||privilege_type, ', ') INTO d
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND grantee='authenticated'
    AND table_name IN ('account_entitlement','billing_plan','billing_event');
  IF d IS NOT NULL THEN fails := fails || ('T4 authenticated billing-table grants: '||d); END IF;
  RAISE NOTICE 'T4 no-authenticated-billing-access ...... %', CASE WHEN d IS NULL THEN 'PASS' ELSE 'FAIL ['||d||']' END;

  -- T5
  SELECT count(*) INTO n FROM pg_policies
  WHERE schemaname='public' AND tablename='member' AND cmd='SELECT'
    AND 'authenticated' = ANY(roles) AND qual ILIKE '%auth.uid()%' AND qual ILIKE '%auth_user_id%';
  IF n < 1 THEN fails := fails || 'T5 member tenant-scoped SELECT policy missing'; END IF;
  RAISE NOTICE 'T5 member-tenant-scoped-SELECT-policy ... %', CASE WHEN n >= 1 THEN 'PASS' ELSE 'FAIL [count='||n||']' END;

  -- T6
  SELECT string_agg(tablename||'.'||policyname, ', ') INTO d
  FROM pg_policies
  WHERE schemaname='public' AND (('anon' = ANY(roles)) OR ('public' = ANY(roles)));
  IF d IS NOT NULL THEN fails := fails || ('T6 anon/PUBLIC policies: '||d); END IF;
  RAISE NOTICE 'T6 no-anon/PUBLIC-policies .............. %', CASE WHEN d IS NULL THEN 'PASS' ELSE 'FAIL ['||d||']' END;

  -- T7
  SELECT string_agg(proname, ', ') INTO d
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
  WHERE ns.nspname='public' AND p.proname LIKE 'fn_billing%'
    AND ( has_function_privilege('anon', p.oid, 'EXECUTE')
       OR (p.proname IN ('fn_billing_apply_event','fn_billing_reconcile_candidates','fn_billing_selftest')
           AND has_function_privilege('authenticated', p.oid, 'EXECUTE')) );
  IF d IS NOT NULL THEN fails := fails || ('T7 billing RPC exec-grant violations: '||d); END IF;
  RAISE NOTICE 'T7 billing-RPC-execute-grants ........... %', CASE WHEN d IS NULL THEN 'PASS' ELSE 'FAIL ['||d||']' END;

  -- T8
  SELECT string_agg(proname, ', ') INTO d
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
  WHERE ns.nspname='public' AND p.proname LIKE 'fn_billing%'
    AND NOT (p.prosecdef AND p.proconfig IS NOT NULL
             AND EXISTS (SELECT 1 FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%'));
  IF d IS NOT NULL THEN fails := fails || ('T8 billing fns missing definer/search_path: '||d); END IF;
  RAISE NOTICE 'T8 billing-fns-definer+search_path ...... %', CASE WHEN d IS NULL THEN 'PASS' ELSE 'FAIL ['||d||']' END;

  -- Gate
  IF array_length(fails,1) > 0 THEN
    RAISE EXCEPTION E'SECURITY GATE FAILED (% check(s)):\n  - %',
      array_length(fails,1), array_to_string(fails, E'\n  - ');
  END IF;
  RAISE NOTICE 'SECURITY GATE PASSED: all 8 catalog checks green';
END $$;

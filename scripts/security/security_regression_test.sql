-- =====================================================================
-- security_regression_test.sql — TIER 2: privileged behavioural security suite
-- =====================================================================
-- Project: strateloq-billing-staging (nlfkwrjmhxbubtlwepwx). Staging only.
--
-- PRIVILEGED: uses SET ROLE (anon/authenticated/service_role) + executes the
-- service_role-only fn_billing_selftest, so it needs an ELEVATED connection
-- (postgres / service role). Run it via the Supabase MCP or a protected manual
-- job — NOT with credentials exposed to untrusted pull requests. The least-
-- privilege, CI-safe catalog checks live in scripts/security/security_gate_catalog.sql
-- (Tier 1), which is what the GitHub Actions workflow runs.
--
-- Self-contained behavioural regression suite for the RLS remediation. Verifies:
--   * every public table has RLS enabled;
--   * anon has no table access (direct or via PUBLIC);
--   * authenticated has no unauthorized table writes, and no access to billing tables;
--   * member SELECT policy enforces tenant isolation (own row only);
--   * backend billing operations remain functional (fn_billing_selftest + RPCs).
--
-- Behavior: prints a per-check table, then RAISEs an exception if ANY check failed
-- (so `psql -v ON_ERROR_STOP=1 -f security_regression_test.sql` exits non-zero and
-- fails CI). All fixtures are seeded inside a transaction that is ROLLED BACK, so the
-- test never mutates real data. Must be run as a role that may SET ROLE to
-- anon/authenticated/service_role (e.g. the postgres/service connection).
-- =====================================================================
BEGIN;

-- ---- ephemeral fixtures (rolled back) ----
INSERT INTO public.member (id, auth_user_id, email, account_status, email_verified, welcome_seen)
VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','a@test.local','active',true,false),
       (gen_random_uuid(),'22222222-2222-2222-2222-222222222222','b@test.local','active',true,false);
INSERT INTO public.billing_plan (plan_code, display_name, provider, provider_price_id, amount_minor, currency, billing_interval, trial_days, active)
VALUES ('rt_test_monthly','RegTest Monthly','stripe','price_RT',1000,'eur','month',0,true)
ON CONFLICT (plan_code) DO NOTHING;
INSERT INTO public.account_entitlement (auth_user_id, plan_code, status, source, provider, provider_customer_id, provider_subscription_id, billing_interval, cancel_at_period_end)
VALUES ('11111111-1111-1111-1111-111111111111','rt_test_monthly','ACTIVE','PROVIDER','stripe','cus_RT','sub_RT','month',false)
ON CONFLICT (auth_user_id) DO NOTHING;

-- ---- probe: assume role (+optional jwt sub), run sql, catch, reset ----
CREATE FUNCTION pg_temp.probe(p_role text, p_sub text, p_sql text) RETURNS text
LANGUAGE plpgsql AS $pb$
DECLARE r text;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_role);
  IF p_sub IS NOT NULL THEN PERFORM set_config('request.jwt.claims', json_build_object('sub',p_sub,'role',p_role)::text, true);
  ELSE PERFORM set_config('request.jwt.claims','',true); END IF;
  BEGIN
    EXECUTE p_sql INTO r; RESET ROLE; RETURN 'ALLOWED:'||coalesce(r,'');
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; RETURN 'DENIED';
            WHEN others THEN RESET ROLE; RETURN 'ERR:'||SQLSTATE;
  END;
END $pb$;

-- ---- checks ----
CREATE FUNCTION pg_temp.sec_checks() RETURNS TABLE(check_name text, detail text, verdict text)
LANGUAGE plpgsql AS $fn$
DECLARE v text; bad text; A text := '11111111-1111-1111-1111-111111111111'; B text := '22222222-2222-2222-2222-222222222222';
BEGIN
  -- C1: RLS enabled on every public base table
  SELECT string_agg(relname, ', ') INTO bad
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity=false;
  check_name:='C1 RLS enabled on all public tables'; detail:=coalesce('EXPOSED: '||bad,'all enabled');
  verdict:=CASE WHEN bad IS NULL THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;

  -- C2: anon (or PUBLIC) has no table privileges on any public table
  SELECT string_agg(distinct grantee||':'||table_name, ', ') INTO bad
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND grantee IN ('anon','PUBLIC');
  check_name:='C2 no anon/PUBLIC table access'; detail:=coalesce('GRANTED: '||bad,'none');
  verdict:=CASE WHEN bad IS NULL THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;

  -- C3a: authenticated (or PUBLIC) has no write privileges on any public table
  SELECT string_agg(distinct table_name||'/'||privilege_type, ', ') INTO bad
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND grantee IN ('authenticated','PUBLIC')
    AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE');
  check_name:='C3a authenticated has no table writes'; detail:=coalesce('WRITABLE: '||bad,'no writes');
  verdict:=CASE WHEN bad IS NULL THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;

  -- C3b: authenticated has no privileges on the billing tables
  SELECT string_agg(distinct table_name||'/'||privilege_type, ', ') INTO bad
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND grantee='authenticated'
    AND table_name IN ('account_entitlement','billing_plan','billing_event');
  check_name:='C3b authenticated no billing-table access'; detail:=coalesce('GRANTED: '||bad,'none');
  verdict:=CASE WHEN bad IS NULL THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;

  -- C4: member has a tenant-scoped SELECT policy for authenticated
  SELECT string_agg(policyname,',') INTO bad FROM pg_policies
  WHERE schemaname='public' AND tablename='member' AND cmd='SELECT'
    AND 'authenticated' = ANY(roles) AND qual ILIKE '%auth.uid()%' AND qual ILIKE '%auth_user_id%';
  check_name:='C4 member tenant-scoped SELECT policy'; detail:=coalesce('policy='||bad,'MISSING');
  verdict:=CASE WHEN bad IS NOT NULL THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;

  -- C4b: no policy grants anon/PUBLIC any row access
  SELECT string_agg(tablename||'.'||policyname,', ') INTO bad FROM pg_policies
  WHERE schemaname='public' AND (('anon' = ANY(roles)) OR ('public' = ANY(roles)));
  check_name:='C4b no anon/PUBLIC policies'; detail:=coalesce('FOUND: '||bad,'none');
  verdict:=CASE WHEN bad IS NULL THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;

  -- C5: behavioral — anon denial + authenticated tenant isolation + write denial
  v:=pg_temp.probe('anon',NULL,$q$SELECT count(*)::text FROM public.member$q$);
  check_name:='C5a anon SELECT member denied'; detail:=v; verdict:=CASE WHEN v='DENIED' THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;
  v:=pg_temp.probe('anon',NULL,$q$INSERT INTO public.member(auth_user_id,email,account_status) VALUES(gen_random_uuid(),'z','active') RETURNING '1'$q$);
  check_name:='C5b anon INSERT member denied'; detail:=v; verdict:=CASE WHEN v='DENIED' THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;
  v:=pg_temp.probe('authenticated',A,$q$SELECT count(*)::text FROM public.member$q$);
  check_name:='C5c authenticated sees only own member row'; detail:=v; verdict:=CASE WHEN v='ALLOWED:1' THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;
  v:=pg_temp.probe('authenticated',A,$q$SELECT count(*)::text FROM public.member WHERE auth_user_id='22222222-2222-2222-2222-222222222222'$q$);
  check_name:='C5d authenticated cannot see other tenant'; detail:=v; verdict:=CASE WHEN v='ALLOWED:0' THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;
  v:=pg_temp.probe('authenticated',A,$q$UPDATE public.member SET welcome_seen=true WHERE auth_user_id='11111111-1111-1111-1111-111111111111' RETURNING '1'$q$);
  check_name:='C5e authenticated cannot UPDATE member'; detail:=v; verdict:=CASE WHEN v='DENIED' THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;
  v:=pg_temp.probe('authenticated',A,$q$SELECT count(*)::text FROM public.account_entitlement$q$);
  check_name:='C5f authenticated cannot read entitlement'; detail:=v; verdict:=CASE WHEN v='DENIED' THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;

  -- C6: backend billing operations remain functional
  v:=pg_temp.probe('authenticated',A,$q$SELECT (public.fn_billing_list_plans())::text$q$);
  check_name:='C6a authenticated list_plans works'; detail:=left(v,48); verdict:=CASE WHEN v LIKE 'ALLOWED:[%' THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;
  v:=pg_temp.probe('service_role',NULL,$q$SELECT (public.fn_billing_selftest()->>'all_pass')$q$);
  check_name:='C6b billing selftest suite all_pass'; detail:=v; verdict:=CASE WHEN v='ALLOWED:true' THEN 'PASS' ELSE 'FAIL' END; RETURN NEXT;
END $fn$;

-- Visible results (table) for logs / MCP / psql:
SELECT * FROM pg_temp.sec_checks();

-- Hard gate: fail the run (non-zero exit) if any check failed.
DO $$
DECLARE n int; names text;
BEGIN
  SELECT count(*), string_agg(check_name,'; ') INTO n, names FROM pg_temp.sec_checks() WHERE verdict <> 'PASS';
  IF n > 0 THEN
    RAISE EXCEPTION 'SECURITY REGRESSION FAILED: % check(s) failed -> %', n, names;
  END IF;
  RAISE NOTICE 'SECURITY REGRESSION PASSED: all checks green';
END $$;

ROLLBACK;

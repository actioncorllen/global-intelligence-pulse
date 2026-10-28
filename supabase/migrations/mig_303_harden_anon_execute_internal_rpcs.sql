-- ============================================================================
-- mig_303_harden_anon_execute_internal_rpcs.sql
-- STRATELOQ-SECURE-ANON-DB-FUNCTION-ACCESS  (Groups A + B: internal + authenticated)
--
-- CONTEXT: continues mig_302. The scan found SECURITY DEFINER functions in `public`
-- executable by the `anon` (unauthenticated) role. SECURITY DEFINER bypasses RLS, so
-- internal pipeline functions (ad-studio, campaign-builder, render, spend-authority,
-- discovery/ingest, media, stage1/stage2 supplier, store-management, product intelligence,
-- etc.) and authenticated-customer functions must not be reachable without signing in.
--
-- VERIFIED EXCLUSION (Group C — the ONLY genuinely public RPC): the public marketing
-- site calls exactly one anon SECURITY DEFINER function — `fn_submit_founding_application`
-- (src/lib/pulse-api.ts → supabase.rpc). It is kept anon-executable. It is safe:
-- validates email/name and writes ONLY a `founding_applications` row (idempotent per email);
-- it creates no account/member/invitation/workspace. The public storefront is served by the
-- `storefront` edge function via service_role (fn_public_storefront_render), NOT by anon RPCs,
-- so fn_public_store_home / fn_store_website_product do NOT need anon and are hardened here.
-- Other public marketing data (opportunities, demo_events, leads, roadmap_items, build_updates)
-- is accessed as anon via DIRECT TABLE grants/RLS, NOT function EXECUTE, so it is unaffected.
--
-- ACTION: revoke EXECUTE from `anon` and `PUBLIC` on every remaining anon-executable public
-- SECURITY DEFINER function EXCEPT `fn_submit_founding_application` (and the `*_selftest`
-- functions already handled in mig_302). `authenticated` and `service_role` keep their explicit
-- grants (ACL becomes `postgres | authenticated | service_role`), so signed-in customers and
-- n8n/service-role workflows are unaffected; internal SECURITY DEFINER callers run as owner.
-- No function body/signature changed. Fully reversible. Non-destructive to data.
--
-- NOTE: this does not alter the parameter-based tenant model of these functions (they scope by
-- a supplied tenant/resource id and reject cross-tenant references); removing anon closes the
-- unauthenticated surface. Tightening `authenticated` on purely-internal functions, and migrating
-- to auth.uid()-derived tenancy, are separate reviews (out of this task's scope).
-- ============================================================================
DO $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace nmsp ON nmsp.oid = p.pronamespace
    WHERE nmsp.nspname = 'public' AND p.prokind = 'f' AND p.prosecdef
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
      AND p.proname <> 'fn_submit_founding_application'
      AND p.proname NOT LIKE '%selftest'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.sig);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'mig_303: hardened % internal/authenticated functions (anon/PUBLIC revoked)', n;
END $$;

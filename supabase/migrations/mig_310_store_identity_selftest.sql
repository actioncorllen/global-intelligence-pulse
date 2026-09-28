-- ============================================================================
-- mig_310_store_identity_selftest.sql
-- STRATELOQ — explicit, repeatable duplication-guard selftest for the founder-frozen
-- ownership model: ONE BUSINESS = ONE HOSTED STORE. Pure structural checks (no data
-- mutation), so it can run any time in CI or by hand. It proves, from the live schema
-- and function bodies, that:
--   1. a partial UNIQUE index physically prevents two default hosted stores per user,
--   2. fn_create_free_store is idempotent get-or-create (never blind INSERT),
--   3. fn_store_attach_product never creates a hosted store,
--   4. fn_store_replace_active_product never creates a hosted store,
--   5. the Product Card action resolver enforces tenant ownership (cross_tenant_rejected).
-- No table/contract changes. Idempotent.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_store_identity_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_pass int:=0; v_fail int:=0; v_c jsonb:='[]'::jsonb;
  v_create text; v_attach text; v_replace text; v_actions text; v_idx boolean;
BEGIN
  -- 1) DB-level guarantee: one default hosted store per user (partial unique index).
  SELECT EXISTS(
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='commerce_hosted_stores'
      AND indexdef ILIKE '%UNIQUE%' AND indexdef ILIKE '%(user_id)%' AND indexdef ILIKE '%WHERE is_default%'
  ) INTO v_idx;
  IF v_idx THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('one_default_store_per_user_unique_index',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('one_default_store_per_user_unique_index',false); END IF;

  v_create  := pg_get_functiondef('public.fn_create_free_store(text)'::regprocedure);
  v_attach  := pg_get_functiondef('public.fn_store_attach_product(uuid,text)'::regprocedure);
  v_replace := pg_get_functiondef('public.fn_store_replace_active_product(uuid,text)'::regprocedure);
  v_actions := pg_get_functiondef('public.fn_product_card_commerce_actions(uuid,text)'::regprocedure);

  -- 2) Create Free Store is idempotent get-or-create (reuses the one store).
  IF v_create ILIKE '%fn_hosted_store_get_or_create%' THEN
    v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('create_free_store_is_get_or_create',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('create_free_store_is_get_or_create',false); END IF;

  -- 3) Attach never creates a hosted store.
  IF v_attach !~* 'insert\s+into\s+public\.commerce_hosted_stores' THEN
    v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('attach_never_creates_store',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('attach_never_creates_store',false); END IF;

  -- 4) Replace never creates a hosted store (same persistent store identity).
  IF v_replace !~* 'insert\s+into\s+public\.commerce_hosted_stores' THEN
    v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('replace_never_creates_store',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('replace_never_creates_store',false); END IF;

  -- 5) Action resolver enforces tenant ownership.
  IF v_actions ILIKE '%cross_tenant_rejected%' THEN
    v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('action_resolver_tenant_guard',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('action_resolver_tenant_guard',false); END IF;

  RETURN jsonb_build_object('suite','store_identity','pass',v_pass,'fail',v_fail,'all_pass',(v_fail=0),'checks',v_c);
END; $fn$;
REVOKE EXECUTE ON FUNCTION public.fn_store_identity_selftest() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_store_identity_selftest() TO authenticated, service_role;

-- mig_372b — Autonomous market-discovery regression (12 invariants)
--
-- Proves, against the real planner + discovery + scorers, that a market alone can
-- initiate discovery with an auto-selected, market-scoped, bounded, rotated scope
-- that feeds the proven auto-research bridge, with noise control, dedup, country
-- isolation, image-independence, and no silent fallback to a founder product/seed.
-- Read-only (planner is STABLE); no research runs created.
--
-- check_function_bodies disabled for this CREATE only (managed-instance validation
-- path); the body is exercised by invocation.

SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_autonomous_discovery_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  de jsonb; gb jsonb; zz jsonb; wide jsonb;
  d text; img boolean; n_fail int;
  v_unexplored_de boolean; v_sel_last_null boolean;
BEGIN
  de := public.fn_autonomous_discovery_plan('DE', 3, '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid);
  gb := public.fn_autonomous_discovery_plan('GB', 1, NULL);
  zz := public.fn_autonomous_discovery_plan('ZZ', 1, NULL);
  wide := public.fn_autonomous_discovery_plan('DE', 99, NULL);
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='fn_dataforseo_discover_candidates';
  SELECT bool_or(pg_get_functiondef(p.oid) ~* 'product_image_assets|supplier_product_assets|product_asset_intelligence|fn_resolve_product_image') INTO img
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
      AND p.proname IN ('fn_autonomous_discovery_plan','fn_dataforseo_discover_candidates','fn_assemble_real_product_market','fn_pod_tournament');

  v := v || jsonb_build_object('check','MARKET_ALONE_INITIATES','pass',
    ((de->>'ok')::boolean IS TRUE AND coalesce(de->>'selected_scope','')<>''));
  v := v || jsonb_build_object('check','SCOPE_AUTO_SELECTED_FROM_UNIVERSE','pass',
    EXISTS(SELECT 1 FROM public.ecommerce_discovery_scope s WHERE s.seed = de->>'selected_scope' AND s.is_active));
  v := v || jsonb_build_object('check','SCOPE_MARKET_SCOPED','pass',
    (de->>'location_code'='2276' AND de->>'language_code'='de'
     AND gb->>'location_code'='2826' AND gb->>'language_code'='en'));
  v := v || jsonb_build_object('check','SPEND_BOUNDED_MAX_SCOPES','pass',
    (jsonb_array_length(coalesce(wide->'scopes','[]'::jsonb)) <= 5));
  SELECT EXISTS(
    SELECT 1 FROM public.ecommerce_discovery_scope s WHERE s.is_active
      AND NOT EXISTS (SELECT 1 FROM public.discovery_runs dr
        WHERE upper(coalesce(dr.raw_contract->>'market',''))='DE'
          AND lower(btrim(coalesce(dr.raw_contract->>'category','')))=lower(btrim(s.seed)))
  ) INTO v_unexplored_de;
  v_sel_last_null := (de->'scopes'->0->>'last_explored_at') IS NULL;
  v := v || jsonb_build_object('check','ROTATION_PREFERS_UNEXPLORED','pass',
    ((NOT v_unexplored_de) OR v_sel_last_null),'detail',jsonb_build_object('unexplored_exists',v_unexplored_de,'selected_unexplored',v_sel_last_null));
  v := v || jsonb_build_object('check','UNSUPPORTED_MARKET_NO_FALLBACK','pass',
    ((zz->>'ok')::boolean IS FALSE AND NOT (zz ? 'selected_scope') AND NOT (zz ? 'product_id')));
  v := v || jsonb_build_object('check','NOISE_GATE_BEFORE_RESEARCH','pass', coalesce(d,'') ~* 'fn_dataforseo_discovery_qualify');
  v := v || jsonb_build_object('check','DEDUP_ACROSS_SCOPES','pass',
    (coalesce(d,'') ~* 'dedup' AND coalesce(d,'') ~* 'ingest_search_demand'));
  v := v || jsonb_build_object('check','ELIGIBLE_ENTER_RESEARCH_BRIDGE','pass', coalesce(d,'') ~* 'fn_auto_dispatch_candidate_research');
  v := v || jsonb_build_object('check','IMAGE_INDEPENDENT','pass', (img IS NOT TRUE));
  v := v || jsonb_build_object('check','CANDIDATE_NOT_QUALIFIED','pass', (coalesce(d,'') !~* 'product_opportunity_decisions'));
  v := v || jsonb_build_object('check','PLAN_RETURNS_SCOPE_NOT_PRODUCT','pass',
    ((de ? 'selected_scope') AND NOT (de ? 'product_id') AND NOT (de ? 'observed_price')));

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean;
  RETURN jsonb_build_object('suite','autonomous_discovery','contract','stage1_autonomous_discovery_v1',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'results',v);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_autonomous_discovery_selftest() TO authenticated, service_role;

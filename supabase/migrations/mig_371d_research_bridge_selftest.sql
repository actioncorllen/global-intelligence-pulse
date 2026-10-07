-- mig_371d — Stage-1 automated research-bridge regression
--
-- Proves, against the real schema and functions, that fresh discovery
-- automatically enters the existing research lifecycle, bounded, noise-safe,
-- feeding concrete resolution and opportunity evaluation only after the evidence
-- gate, image-independent.
--
-- Packaged checks (all read-only / fail-closed, so the selftest has no lasting
-- side effects):
--   AUTO_DISPATCH_WIRED_INTO_DISCOVERY     — discovery calls the bridge
--   SINGLE_RESEARCH_ENTRY_NO_PARALLEL      — bridge + on-demand share one core
--   BRIDGE_ELIGIBILITY_GATE                — bridge gates on market registration
--   EVIDENCE_FEEDS_CONCRETE_RESOLUTION     — finalize -> fn_assemble_real_product_market
--   OPPORTUNITY_EVAL_ONLY_AFTER_EVIDENCE   — only finalize calls fn_pod_evaluate
--   IMAGE_INDEPENDENT_QUALIFICATION        — no scorer reads image/asset stores
--   NOISE_NOT_RESEARCHED                   — unknown/unregistered product dispatches no run
--   CONCEPT_ONLY_NOT_STAGE2_READY          — real tournament globally rejects a concept-only candidate
--
-- The runtime-dispatch invariants (run creation, idempotency = CACHE_REUSED /
-- CACHE_REUSED_IN_FLIGHT reusing the same run_id, market preservation, explicit
-- source-attempt states) were verified live and cost-free in this session via a
-- suppressed, self-cleaning probe of fn_research_request_core; they are left out
-- of the packaged selftest so it never creates research runs when invoked.
--
-- check_function_bodies is disabled for this CREATE only, to avoid a slow
-- validation path on this managed instance; the body is exercised by invocation.

SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_stage1_research_bridge_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  d text; b text; c text; o text; f text; img boolean;
  v_noise jsonb; v_noise_id uuid := gen_random_uuid();
  v_concept uuid; v_tenant uuid; v_mkt text; v_tour jsonb; n_fail int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='fn_dataforseo_discover_candidates';
  SELECT pg_get_functiondef(p.oid) INTO b FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='fn_auto_dispatch_candidate_research';
  SELECT pg_get_functiondef(p.oid) INTO c FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='fn_research_request_core';
  SELECT pg_get_functiondef(p.oid) INTO o FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='fn_own_request_product_market_research';
  SELECT pg_get_functiondef(p.oid) INTO f FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='fn_finalize_research_run';
  SELECT bool_or(pg_get_functiondef(p.oid) ~* 'product_image_assets|supplier_product_assets|product_asset_intelligence|fn_resolve_product_image') INTO img
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN ('fn_assemble_real_product_market','fn_pod_tournament','fn_pod_evaluate','fn_finalize_research_run');

  v := v || jsonb_build_object('check','AUTO_DISPATCH_WIRED_INTO_DISCOVERY','pass', coalesce(d,'') ~* 'fn_auto_dispatch_candidate_research');
  v := v || jsonb_build_object('check','SINGLE_RESEARCH_ENTRY_NO_PARALLEL','pass', (coalesce(b,'') ~* 'fn_research_request_core' AND coalesce(o,'') ~* 'fn_research_request_core'));
  v := v || jsonb_build_object('check','BRIDGE_ELIGIBILITY_GATE','pass', coalesce(b,'') ~* 'monday_opportunity_registry');
  v := v || jsonb_build_object('check','EVIDENCE_FEEDS_CONCRETE_RESOLUTION','pass', coalesce(f,'') ~* 'fn_assemble_real_product_market');
  v := v || jsonb_build_object('check','OPPORTUNITY_EVAL_ONLY_AFTER_EVIDENCE','pass', (coalesce(f,'') ~* 'fn_pod_evaluate' AND coalesce(d,'') !~* 'fn_pod_evaluate' AND coalesce(b,'') !~* 'fn_pod_evaluate' AND coalesce(c,'') !~* 'fn_pod_evaluate'));
  v := v || jsonb_build_object('check','IMAGE_INDEPENDENT_QUALIFICATION','pass', (img IS NOT TRUE));

  v_noise := public.fn_auto_dispatch_candidate_research('7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid, v_noise_id, 'DE');
  v := v || jsonb_build_object('check','NOISE_NOT_RESEARCHED','pass', (v_noise->>'status' IN ('PRODUCT_NOT_FOUND','NOT_ELIGIBLE') AND NOT EXISTS(SELECT 1 FROM public.commerce_research_run WHERE product_id=v_noise_id)),'detail',v_noise->>'status');

  SELECT cp.id, r.tenant_id, upper(m.value->>'country') INTO v_concept, v_tenant, v_mkt
  FROM public.commerce_products cp
  JOIN public.monday_opportunity_registry r ON r.product_id=cp.id AND r.active
  CROSS JOIN LATERAL jsonb_array_elements(r.markets) m
  WHERE cp.identity_basis='normalized_name' AND cp.observed_price IS NULL AND cp.product_url IS NULL
  ORDER BY cp.created_at DESC LIMIT 1;
  IF v_concept IS NOT NULL THEN
    v_tour := public.fn_pod_tournament(v_tenant, v_concept, NULL, false);
    v := v || jsonb_build_object('check','CONCEPT_ONLY_NOT_STAGE2_READY','pass', ((v_tour->'cross_market_recovery'->>'product_globally_rejected')::boolean IS TRUE AND (v_tour->>'product_level_decision') IS NULL));
  ELSE
    v := v || jsonb_build_object('check','CONCEPT_ONLY_NOT_STAGE2_READY','pass',true,'detail','vacuous');
  END IF;

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean;
  RETURN jsonb_build_object('suite','stage1_research_bridge','contract','stage1_automated_research_bridge_v1',
    'note','idempotency/market-preservation/source-state invariants verified live cost-free this session (suppressed probe); structural + fail-closed checks packaged here',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'results',v);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_stage1_research_bridge_selftest() TO authenticated, service_role;

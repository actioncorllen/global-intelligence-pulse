-- mig_373b — Multi-lane discovery regression (16 invariants)
-- Read-only (planner/normalizer STABLE/IMMUTABLE); no research runs created.
-- check_function_bodies disabled for this CREATE (managed-instance validation path).

SET check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.fn_multi_lane_discovery_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; p jsonb; pg jsonb; pw jsonb;
  nc jsonb; ns jsonb; nm jsonb; nlow jsonb;
  d text; img boolean; core text; n_fail int;
BEGIN
  p  := public.fn_multi_lane_discovery_plan('DE',5,'7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid);
  pg := public.fn_multi_lane_discovery_plan('GB',5,NULL);
  pw := public.fn_multi_lane_discovery_plan('DE',99,NULL);
  nc := public.fn_discovery_signal_normalize('COMMERCE','wh_like','DE','{"product_identity":"Mini Neck Fan","revenue":"1000","sales_units":"50","sales_growth_rate":"180"}'::jsonb);
  ns := public.fn_discovery_signal_normalize('SEARCH','dataforseo','DE','{"product_identity":"Mini Neck Fan","search_demand":"2400"}'::jsonb);
  nm := public.fn_discovery_signal_normalize('COMMERCE','wh_like','DE','{"product_identity":"no metrics product"}'::jsonb);
  nlow := public.fn_discovery_signal_normalize('COMMERCE','wh_like','DE','{"product_identity":"early mover","sales_units":"5","sales_growth_rate":"300"}'::jsonb);
  SELECT pg_get_functiondef(x.oid) INTO d FROM pg_proc x JOIN pg_namespace n ON n.oid=x.pronamespace WHERE n.nspname='public' AND x.proname='fn_dataforseo_discover_candidates';
  SELECT pg_get_functiondef(x.oid) INTO core FROM pg_proc x JOIN pg_namespace n ON n.oid=x.pronamespace WHERE n.nspname='public' AND x.proname='fn_research_request_core';
  SELECT bool_or(pg_get_functiondef(x.oid) ~* 'product_image_assets|supplier_product_assets|product_asset_intelligence|fn_resolve_product_image') INTO img
    FROM pg_proc x JOIN pg_namespace n ON n.oid=x.pronamespace WHERE n.nspname='public'
      AND x.proname IN ('fn_multi_lane_discovery_plan','fn_discovery_signal_normalize','fn_autonomous_discovery_plan','fn_dataforseo_discover_candidates');

  v := v || jsonb_build_object('check','01_MARKET_ALONE_INITIATES','pass',((p->>'ok')::boolean AND (p->'runnable_autonomous_lanes') ? 'SEARCH'));
  v := v || jsonb_build_object('check','02_MULTIPLE_LANES_COEXIST','pass',((p->>'lane_count')::int >= 2));
  v := v || jsonb_build_object('check','03_UNAVAILABLE_LANE_EXPLICIT','pass',
    EXISTS(SELECT 1 FROM jsonb_array_elements(p->'lanes') e WHERE e->>'lane'='COMMERCE' AND e->>'status'='GAP_NO_PRODUCT_NATIVE_PROVIDER'));
  v := v || jsonb_build_object('check','04_ZERO_RESULT_LANE_NOT_FATAL','pass',
    ((p->>'lane_count')::int = 5 AND jsonb_array_length(p->'runnable_autonomous_lanes') >= 1));
  v := v || jsonb_build_object('check','05_PRODUCT_NATIVE_ENTERS_NORMALIZATION','pass',
    (nc->>'product_identity'='Mini Neck Fan' AND (nc->>'revenue')::numeric=1000 AND (nc->>'sales_units')::numeric=50));
  v := v || jsonb_build_object('check','06_KEYWORD_CANDIDATE_STILL_WORKS','pass',
    ((ns->>'search_demand')::numeric=2400 AND EXISTS(SELECT 1 FROM jsonb_array_elements(p->'lanes') e WHERE e->>'lane'='SEARCH' AND e->>'status'='READY')));
  v := v || jsonb_build_object('check','07_CROSS_LANE_DUP_COLLAPSES','pass',
    (lower(nc->>'product_identity')=lower(ns->>'product_identity') AND coalesce(d,'') ~* 'dedup'));
  v := v || jsonb_build_object('check','08_COUNTRY_ISOLATION','pass',
    (nc->>'market'='DE' AND (p->'lanes'->0->>'location_code')='2276'
     AND EXISTS(SELECT 1 FROM jsonb_array_elements(pg->'lanes') e WHERE e->>'lane'='SEARCH' AND e->>'location_code'='2826')));
  v := v || jsonb_build_object('check','09_UNAVAILABLE_METRIC_NOT_ZERO','pass',
    ((nm->'revenue') = 'null'::jsonb AND (nm->'sales_units') = 'null'::jsonb AND (nm->'creator_count') = 'null'::jsonb));
  v := v || jsonb_build_object('check','10_DISCOVERY_NOT_QUALIFIED','pass',(coalesce(d,'') !~* 'product_opportunity_decisions'));
  v := v || jsonb_build_object('check','11_HIGH_REVENUE_NO_BYPASS','pass',
    (NOT (nc ? 'decision') AND NOT (nc ? 'opportunity_band') AND NOT (nc ? 'qualified')));
  v := v || jsonb_build_object('check','12_LOW_VOLUME_KEEPS_ACCELERATION','pass',
    ((nlow->>'sales_units')::numeric=5 AND (nlow->>'sales_growth_rate')::numeric=300));
  v := v || jsonb_build_object('check','13_IMAGE_IRRELEVANT','pass',(img IS NOT TRUE));
  v := v || jsonb_build_object('check','14_ELIGIBLE_ENTERS_BRIDGE','pass',(coalesce(d,'') ~* 'fn_auto_dispatch_candidate_research'));
  v := v || jsonb_build_object('check','15_SPEND_BOUNDED','pass',((pw->>'lane_count')::int <= 10));
  v := v || jsonb_build_object('check','16_IDEMPOTENT_NO_DUP_RESEARCH','pass',(coalesce(core,'') ~* 'CACHE_REUSED_IN_FLIGHT'));

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean;
  RETURN jsonb_build_object('suite','multi_lane_discovery','contract','stage1_multi_lane_discovery_v1',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'results',v);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_multi_lane_discovery_selftest() TO authenticated, service_role;

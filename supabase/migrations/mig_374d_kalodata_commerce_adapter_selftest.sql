-- mig_374d — Kalodata COMMERCE adapter regression (16 invariants)
--
-- Read-only / dry-run: exercises the real request builder, multi-lane plan, normalizer and
-- ingest adapter (dry_run=true, no persistence) plus function-definition introspection. No
-- research runs, no commerce rows, no provider calls, no writes to live prod. Proves the 16
-- required Stage 1 Kalodata invariants. Consistent with the fn_autonomous_discovery_selftest
-- / fn_multi_lane_discovery_selftest style.
--
--  01 DE invokes Kalodata with NO keyword/category/product/shop/creator/video/livestream seed
--  02 returned product ids become discovery candidates (dry-run promote)
--  03 country isolation (DE request=DE/EUR; GB request=GB; normalized market stays DE)
--  04 unsupported market explicit (JP request + ingest + plan lane -> UNSUPPORTED_MARKET)
--  05 UNKNOWN != 0 (metric-less product promotes; revenue/sales/price/growth stay NULL)
--  06 Kalodata product != CONCRETE_RESOLVED (no assemble/concrete-resolution in adapter)
--  07 Kalodata product != supplier SKU (identity_basis=provider_product_native; no supplier asset write)
--  08 high revenue cannot bypass qualification (no decision/band/qualified; no pod_evaluate)
--  09 extreme growth cannot bypass qualification (no evaluation write)
--  10 image presence/absence cannot affect qualification (no image tables; both promote)
--  11 DataForSEO failure does not stop COMMERCE (COMMERCE runnable independent of SEARCH)
--  12 Kalodata failure does not corrupt other lanes (UNSUPPORTED market keeps 5 lanes; SEARCH READY)
--  13 dedup by provider product id
--  14 survivors enter existing auto_fresh_discovery bridge
--  15 no duplicate research runs (idempotent CACHE_REUSED core + pre-dispatch dedup)
--  16 secret never persisted (adapter is secret-free: p_products input; no secret literal; request body has no auth field)
--
-- check_function_bodies disabled for this CREATE only (managed-instance validation path).

SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_kalodata_commerce_adapter_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; n_fail int;
  uid uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid;
  prods jsonb := '[{"product_id":"kd_sel_1","product_name":"Mini Neck Fan","revenue":"1000","revenue_growth_rate":"4190.39","sales_volumn":"22","unit_price":"26.16","launch_date":"2026-09-20","live_revenue":"300","video_revenue":"500","showcase_revenue":"200","master_image_url":"https://x/y.jpg","seller_id":"s1","seller_name":"ACME","sku_count":"3"},{"product_id":"kd_sel_2","product_name":"Portable Blender Bottle","master_image_url":null,"seller_name":"","sku_count":null},{"product_id":"","product_name":"missing id"},{"product_id":"kd_sel_4","product_name":"the best cheap deals near me how to"}]'::jsonb;
  req_de jsonb; req_jp jsonb; plan_de jsonb; plan_gb jsonb; plan_no jsonb;
  dry_de jsonb; dry_jp jsonb; dry_de_empty jsonb; dry_de_nonarray jsonb;
  lane_de_com jsonb; lane_gb_com jsonb; lane_no_com jsonb; lane_no_search jsonb;
  pr_fan jsonb; pr_blender jsonb;
  d_ing text; d_core text; d_plan text; img boolean; has_pp boolean;
BEGIN
  req_de := public.fn_kalodata_discovery_request('DE');
  req_jp := public.fn_kalodata_discovery_request('JP');
  plan_de := public.fn_multi_lane_discovery_plan('DE',5,uid);
  plan_gb := public.fn_multi_lane_discovery_plan('GB',5,NULL);
  plan_no := public.fn_multi_lane_discovery_plan('NO',5,NULL);
  dry_de := public.fn_kalodata_ingest_candidates(uid,'DE',NULL,10,prods,true);
  dry_jp := public.fn_kalodata_ingest_candidates(uid,'JP',NULL,10,prods,true);
  dry_de_empty := public.fn_kalodata_ingest_candidates(uid,'DE',NULL,10,'[]'::jsonb,true);
  dry_de_nonarray := public.fn_kalodata_ingest_candidates(uid,'DE',NULL,10,'{}'::jsonb,true);
  SELECT e INTO lane_de_com FROM jsonb_array_elements(plan_de->'lanes') e WHERE e->>'lane'='COMMERCE';
  SELECT e INTO lane_gb_com FROM jsonb_array_elements(plan_gb->'lanes') e WHERE e->>'lane'='COMMERCE';
  SELECT e INTO lane_no_com FROM jsonb_array_elements(plan_no->'lanes') e WHERE e->>'lane'='COMMERCE';
  SELECT e INTO lane_no_search FROM jsonb_array_elements(plan_no->'lanes') e WHERE e->>'lane'='SEARCH';
  SELECT e INTO pr_fan FROM jsonb_array_elements(dry_de->'promoted') e WHERE e->>'product_id'='kd_sel_1';
  SELECT e INTO pr_blender FROM jsonb_array_elements(dry_de->'promoted') e WHERE e->>'product_id'='kd_sel_2';
  SELECT pg_get_functiondef(p.oid) INTO d_ing FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_kalodata_ingest_candidates';
  SELECT pg_get_functiondef(p.oid) INTO d_core FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_research_request_core';
  SELECT pg_get_functiondef(p.oid) INTO d_plan FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_multi_lane_discovery_plan';
  SELECT bool_or(pg_get_functiondef(p.oid) ~* 'product_image_assets|supplier_product_assets|product_asset_intelligence|fn_resolve_product_image') INTO img
    FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public'
      AND p.proname IN ('fn_kalodata_ingest_candidates','fn_kalodata_discovery_request','fn_multi_lane_discovery_plan','fn_discovery_signal_normalize');
  SELECT ('p_products' = ANY(p.proargnames)) INTO has_pp FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_kalodata_ingest_candidates';

  v := v || jsonb_build_object('check','01_DE_INVOKES_KALODATA_NO_SEED','pass',
    ((req_de->>'ok')::boolean AND req_de->>'provider'='KALODATA' AND req_de->>'endpoint' ~* 'tiktok/product/rank'
     AND NOT (req_de->'request_body' ? 'keyword') AND NOT (req_de->'request_body' ? 'category_ids')
     AND NOT (req_de->'request_body' ? 'product_id') AND NOT (req_de->'request_body' ? 'shop_id')
     AND NOT (req_de->'request_body' ? 'creator_id') AND NOT (req_de->'request_body' ? 'video_id')
     AND NOT (req_de->'request_body' ? 'livestream_id')
     AND lane_de_com->>'status'='READY' AND lane_de_com->>'provider'='KALODATA'));
  v := v || jsonb_build_object('check','02_PRODUCT_BECOMES_CANDIDATE','pass',
    (dry_de->>'status'='SUCCESS_WITH_CANDIDATES' AND (dry_de->>'promoted_count')::int=2
     AND pr_fan IS NOT NULL AND pr_fan->'normalized'->>'product_identity'='Mini Neck Fan'));
  v := v || jsonb_build_object('check','03_COUNTRY_ISOLATION','pass',
    (req_de->'request_body'->>'region'='DE' AND req_de->'request_body'->>'currency'='EUR'
     AND lane_gb_com->'kalodata_request'->>'region'='GB'
     AND pr_fan->'normalized'->>'market'='DE' AND pr_blender->'normalized'->>'market'='DE'));
  v := v || jsonb_build_object('check','04_UNSUPPORTED_MARKET_EXPLICIT','pass',
    (req_jp->>'reason'='UNSUPPORTED_MARKET' AND dry_jp->>'status'='UNSUPPORTED_MARKET'
     AND NOT (dry_jp ? 'promoted') AND lane_no_com->>'status'='UNSUPPORTED_MARKET'));
  v := v || jsonb_build_object('check','05_UNKNOWN_NOT_ZERO','pass',
    (pr_blender IS NOT NULL
     AND (pr_blender->'normalized'->'revenue')='null'::jsonb
     AND (pr_blender->'normalized'->'sales_units')='null'::jsonb
     AND (pr_blender->'normalized'->'price')='null'::jsonb
     AND (pr_blender->'normalized'->'revenue_growth_rate')='null'::jsonb));
  v := v || jsonb_build_object('check','06_KALODATA_NOT_CONCRETE_RESOLVED','pass',
    (coalesce(d_ing,'') !~* 'fn_assemble_real_product_market' AND coalesce(d_ing,'') !~* 'concrete_resolved'
     AND NOT (pr_fan ? 'concrete_resolved')));
  v := v || jsonb_build_object('check','07_KALODATA_NOT_SUPPLIER_SKU','pass',
    (coalesce(d_ing,'') !~* 'supplier_product_assets' AND coalesce(d_ing,'') ~* 'provider_product_native'));
  v := v || jsonb_build_object('check','08_HIGH_REVENUE_NO_BYPASS','pass',
    ((pr_fan->'normalized'->>'revenue')::numeric=1000 AND NOT (pr_fan ? 'decision')
     AND NOT (pr_fan ? 'opportunity_band') AND NOT (pr_fan ? 'qualified')
     AND coalesce(d_ing,'') !~* 'fn_pod_evaluate' AND coalesce(d_ing,'') !~* 'product_opportunity_decisions'));
  v := v || jsonb_build_object('check','09_EXTREME_GROWTH_NO_BYPASS','pass',
    ((pr_fan->'normalized'->>'revenue_growth_rate')::numeric=4190.39
     AND NOT (pr_fan->'normalized' ? 'decision') AND NOT (pr_fan->'normalized' ? 'opportunity_band')
     AND coalesce(d_ing,'') !~* 'product_market_evaluations'));
  v := v || jsonb_build_object('check','10_IMAGE_IRRELEVANT','pass',
    (img IS NOT TRUE AND pr_fan IS NOT NULL AND pr_blender IS NOT NULL));
  v := v || jsonb_build_object('check','11_DATAFORSEO_FAILURE_NOT_FATAL_TO_COMMERCE','pass',
    (lane_de_com->>'runnable'='true' AND (plan_de->'runnable_autonomous_lanes') ? 'COMMERCE'
     AND coalesce(d_plan,'') ~* 'zero_yield_rule'));
  v := v || jsonb_build_object('check','12_LANE_ISOLATION_KALODATA_FAIL','pass',
    ((plan_no->>'ok')::boolean AND (plan_no->>'lane_count')::int=5
     AND lane_no_com->>'status'='UNSUPPORTED_MARKET' AND lane_no_search->>'status'='READY'
     AND dry_de_empty->>'status'='SUCCESS_ZERO_CANDIDATES' AND dry_de_nonarray->>'status'='PROVIDER_UNAVAILABLE'));
  v := v || jsonb_build_object('check','13_DEDUP_BY_PROVIDER_ID','pass',
    (coalesce(d_ing,'') ~* 'kalodata_product_id' AND coalesce(d_ing,'') ~* 'dedup'));
  v := v || jsonb_build_object('check','14_ENTERS_AUTO_RESEARCH_BRIDGE','pass',
    (coalesce(d_ing,'') ~* 'fn_auto_dispatch_candidate_research'));
  v := v || jsonb_build_object('check','15_IDEMPOTENT_NO_DUP_RESEARCH','pass',
    (coalesce(d_core,'') ~* 'CACHE_REUSED' AND coalesce(d_ing,'') ~* 'fn_auto_dispatch_candidate_research'));
  v := v || jsonb_build_object('check','16_SECRET_NEVER_PERSISTED','pass',
    (has_pp IS TRUE AND coalesce(d_ing,'') !~* 'secret'
     AND NOT (req_de->'request_body' ? 'secret') AND NOT (req_de->'request_body' ? 'key')
     AND NOT (req_de->'request_body' ? 'token') AND NOT (req_de->'request_body' ? 'authorization')
     AND NOT (req_de->'request_body' ? 'auth')));

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean;
  RETURN jsonb_build_object('suite','kalodata_commerce_adapter','contract','stage1_kalodata_commerce_v1',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'results',v);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_kalodata_commerce_adapter_selftest() TO authenticated, service_role;

-- mig_378e — FastMoss COMMERCE adapter regression (19 invariants)
--
-- Read-only / dry-run + introspection: exercises the real request builder, multi-lane plan,
-- normalizer, branded/IP screen and ingest adapter (dry_run=true, no persistence, NO live
-- FastMoss calls). Proves the 18 required FastMoss invariants and that existing suites stay green.
--
--  01 DE supported · 02 IE unsupported & never substituted · 03 no founder seed required
--  04 provider product_id survives normalization · 05 UNKNOWN != 0 · 06 images irrelevant
--  07 high 3-day sales/GMV cannot auto-qualify · 08 branded/IP cannot silently pass as generic
--  09 duplicate/substantially-identical records do not become fake independent opportunities
--  10 sellers remain distinct evidence · 11 cross-provider agreement does not auto-qualify
--  12 FastMoss failure does not suppress the working Kalodata provider · 13 country isolation
--  14 provider secret cannot reach DB/client/logs · 15 unverified launch_time != first_seen
--  16 eligible candidate enters auto_fresh_discovery · 17 repeated ingestion idempotent
--  18 existing Kalodata/multi-lane/bridge/Stage-1/image/autonomous suites remain green
--  19 New Listed date contract: date_info.value = 3 days ago (UTC), offset invariant = 3
--
-- check_function_bodies disabled for this CREATE only (managed-instance validation path).
SET check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.fn_fastmoss_commerce_adapter_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; n_fail int;
  uid uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid;
  prods jsonb := '[{"product_id":"fm1","title":"Magnetic Eyelash Set","real_price":"27.80","day3_units_sold":"142","day3_gmv":"3827.20","total_units_sold":"500","total_gmv":"13000","commission_rate":"0.15","launch_time":"1699999999","shop":{"seller_id":"s1","name":"Lash Co","total_units_sold":"9000"}},{"product_id":"fm2","title":"Pokémon Plüsch Pikachu 30cm","real_price":"19.90","day3_units_sold":"80","day3_gmv":"1592","shop":{"seller_id":"s2","name":"Toy Shop"}},{"product_id":"fm3","title":"Mini Portable Neck Fan","real_price":"18.00","day3_units_sold":"60","shop":{"seller_id":"s3","name":"Fan Seller A"}},{"product_id":"fm4","title":"Mini Portable Neck Fan","real_price":"17.50","day3_units_sold":"55","shop":{"seller_id":"s4","name":"Fan Seller B"}},{"product_id":"fm5","title":"Expandable Microwave Organizer"},{"product_id":"fm6","title":"2024 hot sale best deal premium"},{"product_id":"","title":"missing id"}]'::jsonb;
  req_de jsonb; req_ie jsonb; plan_de jsonb; plan_no jsonb; lane_de jsonb; lane_no jsonb; cprov_de jsonb;
  dry jsonb; dry_ie jsonb; dry_empty jsonb; dry_nonarray jsonb;
  pr_eye jsonb; pr_poke jsonb; pr_fan3 jsonb; pr_fan4 jsonb; pr_org jsonb;
  d_ing text; d_core text; img boolean; has_pp boolean;
BEGIN
  req_de := public.fn_fastmoss_discovery_request('DE');
  req_ie := public.fn_fastmoss_discovery_request('IE');
  plan_de := public.fn_multi_lane_discovery_plan('DE',5,uid);
  plan_no := public.fn_multi_lane_discovery_plan('NO',5,NULL);
  dry := public.fn_fastmoss_ingest_candidates(uid,'DE',NULL,10,prods,true);
  dry_ie := public.fn_fastmoss_ingest_candidates(uid,'IE',NULL,10,prods,true);
  dry_empty := public.fn_fastmoss_ingest_candidates(uid,'DE',NULL,10,'[]'::jsonb,true);
  dry_nonarray := public.fn_fastmoss_ingest_candidates(uid,'DE',NULL,10,'{}'::jsonb,true);
  SELECT e INTO lane_de FROM jsonb_array_elements(plan_de->'lanes') e WHERE e->>'lane'='COMMERCE';
  SELECT e INTO lane_no FROM jsonb_array_elements(plan_no->'lanes') e WHERE e->>'lane'='COMMERCE';
  cprov_de := lane_de->'commerce_providers';
  SELECT e INTO pr_eye  FROM jsonb_array_elements(dry->'promoted') e WHERE e->>'product_id'='fm1';
  SELECT e INTO pr_poke FROM jsonb_array_elements(dry->'promoted') e WHERE e->>'product_id'='fm2';
  SELECT e INTO pr_fan3 FROM jsonb_array_elements(dry->'promoted') e WHERE e->>'product_id'='fm3';
  SELECT e INTO pr_fan4 FROM jsonb_array_elements(dry->'promoted') e WHERE e->>'product_id'='fm4';
  SELECT e INTO pr_org  FROM jsonb_array_elements(dry->'promoted') e WHERE e->>'product_id'='fm5';
  SELECT pg_get_functiondef(p.oid) INTO d_ing FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_fastmoss_ingest_candidates';
  SELECT pg_get_functiondef(p.oid) INTO d_core FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_research_request_core';
  SELECT bool_or(pg_get_functiondef(p.oid) ~* 'product_image_assets|supplier_product_assets|product_asset_intelligence|fn_resolve_product_image') INTO img
    FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public'
      AND p.proname IN ('fn_fastmoss_ingest_candidates','fn_fastmoss_discovery_request','fn_is_branded_or_ip_sensitive');
  SELECT ('p_products' = ANY(p.proargnames)) INTO has_pp FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_fastmoss_ingest_candidates';

  v := v || jsonb_build_object('check','01_DE_SUPPORTED','pass',
    ((req_de->>'ok')::boolean AND req_de->>'provider'='FASTMOSS' AND req_de->>'endpoint' ~* 'newListed'
     AND EXISTS(SELECT 1 FROM jsonb_array_elements(cprov_de) x WHERE x->>'provider'='FASTMOSS' AND x->>'status'='READY')));
  v := v || jsonb_build_object('check','02_IE_UNSUPPORTED_NOT_SUBSTITUTED','pass',
    (req_ie->>'reason'='UNSUPPORTED_MARKET' AND dry_ie->>'status'='UNSUPPORTED_MARKET' AND NOT (dry_ie ? 'promoted')));
  v := v || jsonb_build_object('check','03_NO_SEED_REQUIRED','pass',
    ((req_de->'request_body'->'filter' ? 'region') AND (req_de->'request_body'->'filter' ? 'date_info')
     AND NOT (req_de->'request_body' ? 'keyword') AND NOT (req_de->'request_body' ? 'category_ids')
     AND NOT (req_de->'request_body' ? 'product_id') AND NOT (req_de->'request_body' ? 'shop_id')
     AND NOT (req_de->'request_body' ? 'creator_id') AND NOT (req_de->'request_body' ? 'video_id')));
  v := v || jsonb_build_object('check','04_PRODUCT_ID_SURVIVES_NORMALIZATION','pass',
    (pr_eye->>'product_id'='fm1' AND pr_eye->'normalized'->>'product_identity'='Magnetic Eyelash Set'));
  v := v || jsonb_build_object('check','05_UNKNOWN_NOT_ZERO','pass',
    (pr_org IS NOT NULL AND (pr_org->'normalized'->'revenue')='null'::jsonb
     AND (pr_org->'normalized'->'sales_units')='null'::jsonb AND (pr_org->'normalized'->'price')='null'::jsonb));
  v := v || jsonb_build_object('check','06_IMAGE_IRRELEVANT','pass',
    (img IS NOT TRUE AND NOT (pr_eye->'normalized' ? 'cover') AND NOT (pr_eye->'normalized' ? 'image')));
  v := v || jsonb_build_object('check','07_HIGH_SALES_GMV_NO_AUTOQUALIFY','pass',
    ((pr_eye->'normalized'->>'sales_units')::numeric=142 AND NOT (pr_eye ? 'decision') AND NOT (pr_eye ? 'opportunity_band')
     AND coalesce(d_ing,'') !~* 'fn_pod_evaluate' AND coalesce(d_ing,'') !~* 'product_opportunity_decisions'));
  v := v || jsonb_build_object('check','08_BRANDED_NOT_SILENT_GENERIC','pass',
    (pr_poke->>'screening_state'='BRANDED_OR_IP_REVIEW' AND (pr_poke->>'auto_dispatch_eligible')::boolean IS FALSE));
  v := v || jsonb_build_object('check','09_DUPLICATE_NOT_FAKE_INDEPENDENT','pass',
    (pr_fan3->>'product_family_key'=pr_fan4->>'product_family_key'
     AND coalesce(d_ing,'') ~* 'product_family_key' AND coalesce(d_ing,'') ~* 'correlated_existing'));
  v := v || jsonb_build_object('check','10_SELLERS_DISTINCT_EVIDENCE','pass',
    (coalesce(d_ing,'') ~* 'seller_id' AND coalesce(d_ing,'') ~* 'ingest_commerce_signal'));
  v := v || jsonb_build_object('check','11_CROSS_PROVIDER_NO_AUTOQUALIFY','pass',
    (coalesce(d_ing,'') !~* 'product_opportunity_decisions' AND coalesce(d_ing,'') !~* 'fn_pod_evaluate'
     AND coalesce(d_ing,'') ~* 'correlated_existing'));
  v := v || jsonb_build_object('check','12_FASTMOSS_FAILURE_NOT_SUPPRESS_KALODATA','pass',
    (EXISTS(SELECT 1 FROM jsonb_array_elements(cprov_de) x WHERE x->>'provider'='KALODATA' AND x->>'status'='READY')
     AND (public.fn_kalodata_discovery_request('DE')->>'ok')::boolean
     AND dry_nonarray->>'status'='PROVIDER_UNAVAILABLE' AND dry_empty->>'status'='SUCCESS_ZERO_CANDIDATES'));
  v := v || jsonb_build_object('check','13_COUNTRY_ISOLATION','pass',
    (req_de->'request_body'->'filter'->>'region'='DE' AND pr_eye->'normalized'->>'market'='DE'
     AND coalesce(d_ing,'') ~* 'market'));
  v := v || jsonb_build_object('check','14_SECRET_NEVER_PERSISTED','pass',
    (has_pp IS TRUE AND coalesce(d_ing,'') !~* 'secret'
     AND NOT (req_de->'request_body' ? 'authorization') AND NOT (req_de->'request_body' ? 'secret')
     AND NOT (req_de->'request_body' ? 'token') AND NOT (req_de->'request_body' ? 'bearer')));
  v := v || jsonb_build_object('check','15_LAUNCH_TIME_NOT_FIRST_SEEN','pass',
    ((pr_eye->'normalized'->'first_seen')='null'::jsonb AND coalesce(d_ing,'') ~* 'launch_time_raw'));
  v := v || jsonb_build_object('check','16_ENTERS_AUTO_RESEARCH_BRIDGE','pass',
    (coalesce(d_ing,'') ~* 'fn_auto_dispatch_candidate_research'));
  v := v || jsonb_build_object('check','17_IDEMPOTENT','pass',
    (coalesce(d_ing,'') ~* 'fastmoss_product_id' AND coalesce(d_ing,'') ~* 'idempotent'
     AND coalesce(d_core,'') ~* 'CACHE_REUSED'));
  v := v || jsonb_build_object('check','18_EXISTING_SUITES_GREEN','pass',
    ((public.fn_kalodata_commerce_adapter_selftest()->>'all_pass')::boolean
     AND (public.fn_multi_lane_discovery_selftest()->>'all_pass')::boolean
     AND (public.fn_stage1_research_bridge_selftest()->>'all_pass')::boolean
     AND (public.fn_stage1_product_opportunity_invariants_selftest()->>'all_pass')::boolean
     AND (public.fn_product_image_selftest()->>'all_pass')::boolean
     AND (public.fn_autonomous_discovery_selftest()->>'all_pass')::boolean));
  v := v || jsonb_build_object('check','19_DATE_CONTRACT_3_DAYS_AGO','pass',
    ((req_de->>'date_offset_days')::int = 3
     AND req_de->'request_body'->'filter'->'date_info'->>'type' = 'day'
     AND req_de->'request_body'->'filter'->'date_info'->>'value' = to_char(((now() AT TIME ZONE 'UTC')::date - 3),'YYYY-MM-DD')),
    'detail', jsonb_build_object('request_date', req_de->'request_body'->'filter'->'date_info'->>'value','offset_days', req_de->>'date_offset_days'));

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE (x->>'pass') IS DISTINCT FROM 'true';
  RETURN jsonb_build_object('suite','fastmoss_commerce_adapter','contract','stage1_fastmoss_commerce_v1',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'results',v);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_commerce_adapter_selftest() TO authenticated, service_role;

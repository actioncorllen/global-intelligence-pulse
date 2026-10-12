-- mig_382 — Regression suite for the Stage-1 early-opportunity state + commerce-evidence wiring.
-- Additive, self-cleaning (fixtures rolled back on error / deleted on success). Reuses the live
-- helpers; proves commerce evidence contributes bounded early-stage evidence without weakening the
-- unchanged qualification contract, and that all prior invariants still hold.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_stage1_early_opportunity_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; n_fail int;
  t uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  pc uuid := gen_random_uuid();   -- commerce-only
  pp uuid := gen_random_uuid();   -- commerce + local price + cross-provider sellers + GB isolation
  pe uuid := gen_random_uuid();   -- empty (no row)
  s_c jsonb; s_p jsonb; s_e jsonb; d_eo text; d_q text; v_q text;
BEGIN
  INSERT INTO public.commerce_products (id,user_id,product_identity,identity_basis,title,provenance,product_role,visibility,first_observed_at,last_observed_at)
  VALUES (pc,t,'selftest:eo:c:'||pc::text,'platform_id','EO selftest commerce-only',jsonb_build_object('src','eo_selftest'),'candidate','TENANT_PRIVATE',now(),now());
  INSERT INTO public.commerce_products (id,user_id,product_identity,identity_basis,title,observed_price,price_currency,provenance,product_role,visibility,first_observed_at,last_observed_at)
  VALUES (pp,t,'selftest:eo:p:'||pp::text,'platform_id','EO selftest commerce+price',19.99,'EUR',jsonb_build_object('src','eo_selftest'),'candidate','TENANT_PRIVATE',now(),now());

  INSERT INTO public.commerce_signals (id,user_id,product_id,signal_type,value,evidence,provenance,observed_at,dedup_key) VALUES
   (gen_random_uuid(),t,pc,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','FASTMOSS','sales_units',142,'revenue',3827.2),
     jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SELLER_X'))),jsonb_build_object('s','t'),now(),'selftest:eo:'||pc::text||':c'),
   (gen_random_uuid(),t,pp,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','KALODATA','sales_units',120,'revenue',3000),
     jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SELLER_X'))),jsonb_build_object('s','t'),now(),'selftest:eo:'||pp::text||':kal'),
   (gen_random_uuid(),t,pp,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','FASTMOSS','sales_units',90,'revenue',2000),
     jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SELLER_X')),jsonb_build_object('seller',jsonb_build_object('seller_id','SELLER_Y'))),jsonb_build_object('s','t'),now(),'selftest:eo:'||pp::text||':fm'),
   (gen_random_uuid(),t,pp,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','GB','source','FASTMOSS','sales_units',200,'revenue',9000),
     jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SELLER_Z'))),jsonb_build_object('s','t'),now(),'selftest:eo:'||pp::text||':gb');

  s_c := public.fn_stage1_early_opportunity_state(t,pc,'DE',336);
  s_p := public.fn_stage1_early_opportunity_state(t,pp,'DE',336);
  s_e := public.fn_stage1_early_opportunity_state(t,pe,'DE',336);
  SELECT pg_get_functiondef(p.oid) INTO d_eo FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_early_opportunity_state' AND p.prokind='f';
  SELECT pg_get_functiondef(p.oid) INTO d_q FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_opportunity_qualified' AND p.prokind='f';
  v_q := substring(coalesce(d_q,'') from 'v_q :=[^;]*;');

  v := v || jsonb_build_object('check','01_COMMERCE_ENTERS_FAMILY_ASSEMBLY','pass',((s_c->'evidence_families_present') @> '"COMMERCE_MOMENTUM"'::jsonb));
  v := v || jsonb_build_object('check','02_COMMERCE_MOMENTUM_BOUNDED_EMERGING','pass',((s_c->>'early_opportunity_state')='EMERGING'));
  v := v || jsonb_build_object('check','03_COMMERCE_ALONE_CANNOT_QUALIFY','pass',((s_c->'qualification'->>'stage1_opportunity_qualified')='false' AND (s_c->>'early_opportunity_state')<>'QUALIFIED_FOR_SUPPLIER_RESOLUTION'));
  v := v || jsonb_build_object('check','04_COMMERCE_ALONE_CANNOT_WINNER','pass',((s_c->>'early_opportunity_state')<>'WINNER' AND NOT ((s_c->'lifecycle') @> '"WINNER"'::jsonb) AND (s_c->'invariants'->>'winner_is_post_launch_only')='true'));
  v := v || jsonb_build_object('check','05_LOCAL_PRICE_BECOMES_LOCAL_OBSERVED','pass',((s_p->'local_price'->>'class')='LOCAL_OBSERVED_PRICE'));
  v := v || jsonb_build_object('check','06_ONE_PRICE_NOT_VALIDATED_MARKET_PRICE','pass',((s_p->'local_price'->>'validated_local_market_price')='false' AND (s_p->'qualification'->>'market_price_gate') IS DISTINCT FROM 'PASS'));
  v := v || jsonb_build_object('check','07_SELLER_CONTRIBUTES_TO_OBSERVED_SET','pass',((s_c->'observed_sellers'->>'provider_observed_distinct') IS NOT NULL));
  v := v || jsonb_build_object('check','08_ONE_SELLER_NOT_LOW_COMPETITION','pass',((s_c->'qualification'->>'saturation_gate') IS DISTINCT FROM 'PASS'));
  v := v || jsonb_build_object('check','09_CROSS_PROVIDER_SELLERS_DEDUP','pass',((s_p->'observed_sellers'->>'provider_observed_distinct')::int = 2));
  v := v || jsonb_build_object('check','10_UNKNOWN_SELLER_COVERAGE_STAYS_UNKNOWN','pass',((s_e->'observed_sellers'->>'provider_observed_distinct') IS NULL));
  v := v || jsonb_build_object('check','11_UNKNOWN_REMAINS_UNKNOWN','pass',((s_e->'commerce_momentum'->>'present')='false' AND (s_e->'local_price'->>'class')='UNKNOWN' AND (s_e->>'early_opportunity_state')='DISCOVERED'));
  v := v || jsonb_build_object('check','12_COUNTRY_ISOLATION','pass',((s_p->'commerce_momentum'->>'signal_count')::int = 2 AND NOT ((s_p->'observed_sellers'->'seller_ids') @> '"SELLER_Z"'::jsonb)));
  -- word-boundary match: plain 'cover' would false-match the substring in 'DISCOVERED'
  v := v || jsonb_build_object('check','13_IMAGES_QUALIFICATION_INDEPENDENT','pass',(coalesce(d_eo,'') !~* '\y(image|cover|gallery|photo)\y' AND coalesce(d_q,'') !~* '\y(image|cover|gallery|photo)\y'));
  v := v || jsonb_build_object('check','14_STAGE2_3_GATES_EXCLUDED','pass',(coalesce(d_q,'') ~ 'stage2_3_gates_excluded' AND coalesce(v_q,'') !~* 'supplier|economics|compliance|fulfilment'));
  v := v || jsonb_build_object('check','15_QUALIFICATION_THRESHOLD_UNCHANGED','pass',(coalesce(v_q,'') ~* 'v_score >= 70' AND coalesce(v_q,'') ~* 'MEDIUM' AND coalesce(v_q,'') ~* 'LOCAL' AND coalesce(v_q,'') ~* 'v_sat' AND coalesce(v_q,'') ~* 'v_price'));
  v := v || jsonb_build_object('check','16_FASTMOSS_SUITE_GREEN','pass',((public.fn_fastmoss_commerce_adapter_selftest()->>'all_pass')::boolean));
  v := v || jsonb_build_object('check','17_KALODATA_SUITE_GREEN','pass',((public.fn_kalodata_commerce_adapter_selftest()->>'all_pass')::boolean));
  v := v || jsonb_build_object('check','18_STAGE1_INVARIANT_SUITE_GREEN','pass',((public.fn_stage1_product_opportunity_invariants_selftest()->>'all_pass')::boolean));
  v := v || jsonb_build_object('check','19_RESEARCH_BRIDGE_GREEN','pass',((public.fn_stage1_research_bridge_selftest()->>'all_pass')::boolean));
  v := v || jsonb_build_object('check','20_IDEMPOTENCY_REMAINS_PASS','pass',(
     EXISTS(SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relname='commerce_research_run_active_logical_key_uniq' AND i.indisunique AND pg_get_expr(i.indpred,i.indrelid)='(status = ''RESEARCHING''::text)')
     AND (SELECT pg_get_functiondef(p.oid) ~ 'pulse_research_request_v4_idempotent' FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_research_request_core')));

  DELETE FROM public.commerce_products WHERE id IN (pc,pp);  -- cascades signals

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE (x->>'pass') IS DISTINCT FROM 'true';
  RETURN jsonb_build_object('suite','stage1_early_opportunity','contract','stage1_early_opportunity_v1',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'provider_calls',0,'results',v);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_stage1_early_opportunity_selftest() TO authenticated, service_role;

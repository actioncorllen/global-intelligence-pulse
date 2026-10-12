-- mig_385 — Durable regression for Stage-1 supplier-resolution qualification + early-opportunity v2.
-- Additive, self-cleaning (fixtures rolled back on error / deleted on success). Provider-independent.
-- Proves the investigation-worthiness contract and that the strict launch bar + all prior invariants hold.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_stage1_supplier_resolution_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; n_fail int;
  t uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  p_com uuid := gen_random_uuid(); p_advonly uuid := gen_random_uuid(); p_advweak uuid := gen_random_uuid();
  p_two uuid := gen_random_uuid(); p_highsat uuid := gen_random_uuid(); p_branded uuid := gen_random_uuid();
  p_ambig uuid := gen_random_uuid(); p_price uuid := gen_random_uuid(); p_empty uuid := gen_random_uuid();
  e_com jsonb; e_advonly jsonb; e_advweak jsonb; e_two jsonb; e_highsat jsonb; e_branded jsonb; e_ambig jsonb; e_price jsonb; e_empty jsonb;
  d_sr text; d_q text; d_cv text; v_q text; adv_fam jsonb; famset text;
BEGIN
  INSERT INTO public.commerce_products (id,user_id,product_identity,identity_basis,title,observed_price,price_currency,provenance,product_role,visibility,first_observed_at,last_observed_at) VALUES
   (p_com,t,'st:com:'||p_com,'platform_id','SR selftest commerce only',NULL,NULL,'{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_advonly,t,'st:advo:'||p_advonly,'platform_id','SR selftest ads only',NULL,NULL,'{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_advweak,t,'st:advw:'||p_advweak,'platform_id','SR selftest commerce plus weak ad',NULL,NULL,'{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_two,t,'st:two:'||p_two,'platform_id','SR selftest two families',NULL,NULL,'{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_highsat,t,'st:hs:'||p_highsat,'platform_id','SR selftest high saturation',NULL,NULL,'{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_branded,t,'st:brand:'||p_branded,'platform_id','Pokemon Celebrations Booster Display',NULL,NULL,'{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_ambig,t,'st:ambig:'||p_ambig,'normalized_name','SR selftest ambiguous identity',NULL,NULL,'{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_price,t,'st:price:'||p_price,'platform_id','SR selftest commerce plus price',21.00,'EUR','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now());

  INSERT INTO public.commerce_signals (id,user_id,product_id,signal_type,value,evidence,provenance,observed_at,dedup_key) VALUES
   (gen_random_uuid(),t,p_com,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','FASTMOSS','sales_units',100,'revenue',2000),jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SX'))),'{"s":"t"}',now(),'st:'||p_com||':c'),
   (gen_random_uuid(),t,p_advweak,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','FASTMOSS','sales_units',100,'revenue',2000),jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SX'))),'{"s":"t"}',now(),'st:'||p_advweak||':c'),
   (gen_random_uuid(),t,p_two,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','FASTMOSS','sales_units',100,'revenue',2000),jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SX'))),'{"s":"t"}',now(),'st:'||p_two||':c'),
   (gen_random_uuid(),t,p_highsat,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','FASTMOSS','sales_units',100,'revenue',2000),jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SX'))),'{"s":"t"}',now(),'st:'||p_highsat||':c'),
   (gen_random_uuid(),t,p_branded,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','FASTMOSS','sales_units',100,'revenue',2000),jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SX'))),'{"s":"t"}',now(),'st:'||p_branded||':c'),
   (gen_random_uuid(),t,p_ambig,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','FASTMOSS','sales_units',100,'revenue',2000),jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SX'))),'{"s":"t"}',now(),'st:'||p_ambig||':c'),
   (gen_random_uuid(),t,p_price,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','DE','source','FASTMOSS','sales_units',100,'revenue',2000),jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SX'))),'{"s":"t"}',now(),'st:'||p_price||':de'),
   (gen_random_uuid(),t,p_price,'COMMERCE_PRODUCT_NATIVE',jsonb_build_object('market','GB','source','FASTMOSS','sales_units',500,'revenue',9000),jsonb_build_array(jsonb_build_object('seller',jsonb_build_object('seller_id','SELLER_Z'))),'{"s":"t"}',now(),'st:'||p_price||':gb');

  INSERT INTO public.commerce_signals (id,user_id,product_id,signal_type,value,evidence,provenance,observed_at,dedup_key) VALUES
   (gen_random_uuid(),t,p_advonly,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV1'),'[]','{"s":"t"}',now(),'st:'||p_advonly||':a1'),
   (gen_random_uuid(),t,p_advonly,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV2'),'[]','{"s":"t"}',now(),'st:'||p_advonly||':a2'),
   (gen_random_uuid(),t,p_advweak,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV1'),'[]','{"s":"t"}',now(),'st:'||p_advweak||':a1'),
   (gen_random_uuid(),t,p_two,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV1'),'[]','{"s":"t"}',now(),'st:'||p_two||':a1'),
   (gen_random_uuid(),t,p_two,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV2'),'[]','{"s":"t"}',now(),'st:'||p_two||':a2'),
   (gen_random_uuid(),t,p_highsat,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV1'),'[]','{"s":"t"}',now(),'st:'||p_highsat||':a1'),
   (gen_random_uuid(),t,p_highsat,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV2'),'[]','{"s":"t"}',now(),'st:'||p_highsat||':a2'),
   (gen_random_uuid(),t,p_branded,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV1'),'[]','{"s":"t"}',now(),'st:'||p_branded||':a1'),
   (gen_random_uuid(),t,p_branded,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV2'),'[]','{"s":"t"}',now(),'st:'||p_branded||':a2'),
   (gen_random_uuid(),t,p_ambig,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV1'),'[]','{"s":"t"}',now(),'st:'||p_ambig||':a1'),
   (gen_random_uuid(),t,p_ambig,'ADVERTISING_ACTIVITY',jsonb_build_object('market','DE','page_id','ADV2'),'[]','{"s":"t"}',now(),'st:'||p_ambig||':a2');

  INSERT INTO public.product_opportunity_decisions (tenant_id,product_id,country_code,saturation_state,is_fixture)
  VALUES (t,p_highsat,'DE',jsonb_build_object('level','VERY_HIGH','has_defensible_gap',false),true);

  e_com:=public.fn_stage1_early_opportunity_state(t,p_com,'DE',336);
  e_advonly:=public.fn_stage1_early_opportunity_state(t,p_advonly,'DE',336);
  e_advweak:=public.fn_stage1_early_opportunity_state(t,p_advweak,'DE',336);
  e_two:=public.fn_stage1_early_opportunity_state(t,p_two,'DE',336);
  e_highsat:=public.fn_stage1_early_opportunity_state(t,p_highsat,'DE',336);
  e_branded:=public.fn_stage1_early_opportunity_state(t,p_branded,'DE',336);
  e_ambig:=public.fn_stage1_early_opportunity_state(t,p_ambig,'DE',336);
  e_price:=public.fn_stage1_early_opportunity_state(t,p_price,'DE',336);
  e_empty:=public.fn_stage1_early_opportunity_state(t,p_empty,'DE',336);

  SELECT pg_get_functiondef(p.oid) INTO d_sr FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_supplier_resolution_qualified' AND p.prokind='f';
  SELECT pg_get_functiondef(p.oid) INTO d_q FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_opportunity_qualified' AND p.prokind='f';
  SELECT pg_get_functiondef(p.oid) INTO d_cv FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_commercially_validated' AND p.prokind='f';
  v_q := substring(coalesce(d_q,'') from 'v_q :=[^;]*;');
  SELECT x INTO adv_fam FROM jsonb_array_elements(e_advweak->'supplier_resolution'->'evidence_families') x WHERE x->>'family'='ADVERTISING_EMERGENCE';
  SELECT string_agg(x->>'family',',' ORDER BY x->>'family') INTO famset FROM jsonb_array_elements(e_two->'supplier_resolution'->'evidence_families') x;

  v := v||jsonb_build_object('check','01_commerce_alone_cannot_qualify','pass',(e_com->'supplier_resolution'->>'stage1_supplier_resolution_qualified')='false');
  v := v||jsonb_build_object('check','02_ads_alone_cannot_qualify','pass',((e_advonly->'supplier_resolution'->>'stage1_supplier_resolution_qualified')='false' AND (e_advonly->'supplier_resolution'->>'qualifying_family_count')::int=1));
  v := v||jsonb_build_object('check','03_weak_advertising_not_qualifying','pass',((adv_fam->>'present')='true' AND (adv_fam->>'qualifying')='false' AND (e_advweak->'supplier_resolution'->>'stage1_supplier_resolution_qualified')='false'));
  v := v||jsonb_build_object('check','04_two_families_qualify','pass',(e_two->'supplier_resolution'->>'stage1_supplier_resolution_qualified')='true');
  v := v||jsonb_build_object('check','05_observed_high_sat_blocks','pass',((e_highsat->'supplier_resolution'->'disqualifiers'->>'observed_high_saturation')='true' AND (e_highsat->'supplier_resolution'->>'stage1_supplier_resolution_qualified')='false'));
  v := v||jsonb_build_object('check','06_unknown_sat_not_pass','pass',((e_two->'supplier_resolution'->>'saturation_representation') IN ('UNKNOWN','LIMITED_COVERAGE') AND (e_two->'supplier_resolution'->>'stage1_supplier_resolution_qualified')='true'));
  v := v||jsonb_build_object('check','07_unknown_sat_not_observed_high','pass',(e_two->'supplier_resolution'->'disqualifiers'->>'observed_high_saturation')='false');
  v := v||jsonb_build_object('check','08_one_seller_not_low_comp','pass',((e_com->'supplier_resolution'->>'observed_sellers_distinct')::int=1 AND (e_com->'supplier_resolution'->>'saturation_representation') IN ('LIMITED_COVERAGE','UNKNOWN')));
  v := v||jsonb_build_object('check','09_one_price_not_validated','pass',((e_price->'local_price'->>'class')='LOCAL_OBSERVED_PRICE' AND (e_price->'local_price'->>'validated_local_market_price')='false'));
  v := v||jsonb_build_object('check','10_unknown_price_can_proceed','pass',((e_two->'local_price'->>'class')='UNKNOWN' AND (e_two->'supplier_resolution'->>'stage1_supplier_resolution_qualified')='true'));
  v := v||jsonb_build_object('check','11_branded_blocked','pass',((e_branded->'supplier_resolution'->'disqualifiers'->>'branded_or_ip')='true' AND (e_branded->'supplier_resolution'->>'stage1_supplier_resolution_qualified')='false'));
  v := v||jsonb_build_object('check','12_identity_ambiguity_blocked','pass',((e_ambig->'supplier_resolution'->'disqualifiers'->>'identity_ambiguous')='true' AND (e_ambig->'supplier_resolution'->>'stage1_supplier_resolution_qualified')='false'));
  v := v||jsonb_build_object('check','13_country_isolation','pass',((e_price->'commerce_momentum'->>'signal_count')::int=1 AND NOT ((e_price->'observed_sellers'->'seller_ids') @> '"SELLER_Z"'::jsonb)));
  v := v||jsonb_build_object('check','14_images_independent','pass',(coalesce(d_sr,'') !~* '\y(image|cover|gallery|photo)\y'));
  v := v||jsonb_build_object('check','15_16_supplier_economics_not_families','pass',(famset='ADVERTISING_EMERGENCE,COMMERCE_MOMENTUM,COMMUNITY_SOCIAL,MARKETPLACE_VALIDATION,SEARCH_DEMAND' AND coalesce(d_sr,'') !~* 'supplier_availability|landed_economics'));
  v := v||jsonb_build_object('check','17_launch_bar_unchanged','pass',(coalesce(v_q,'') ~* 'v_score >= 70' AND coalesce(v_q,'') ~* 'MEDIUM' AND coalesce(v_q,'') ~* 'LOCAL' AND coalesce(v_q,'') ~* 'v_sat' AND coalesce(v_q,'') ~* 'v_price' AND coalesce(d_cv,'') ~ 'fn_stage1_opportunity_qualified'));
  v := v||jsonb_build_object('check','18_fastmoss_green','pass',(public.fn_fastmoss_commerce_adapter_selftest()->>'all_pass')::boolean);
  v := v||jsonb_build_object('check','19_kalodata_green','pass',(public.fn_kalodata_commerce_adapter_selftest()->>'all_pass')::boolean);
  v := v||jsonb_build_object('check','20_research_bridge_green','pass',(public.fn_stage1_research_bridge_selftest()->>'all_pass')::boolean);
  v := v||jsonb_build_object('check','21_stage1_invariant_green','pass',(public.fn_stage1_product_opportunity_invariants_selftest()->>'all_pass')::boolean);
  v := v||jsonb_build_object('check','22_early_opportunity_v2','pass',((e_two->>'contract')='pulse_stage1_early_opportunity_v2' AND (e_two->>'early_opportunity_state')='QUALIFIED_FOR_SUPPLIER_RESOLUTION'));
  v := v||jsonb_build_object('check','23_idempotency_pass','pass',(
     EXISTS(SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relname='commerce_research_run_active_logical_key_uniq' AND i.indisunique AND pg_get_expr(i.indpred,i.indrelid)='(status = ''RESEARCHING''::text)')
     AND (SELECT pg_get_functiondef(p.oid) ~ 'pulse_research_request_v4_idempotent' FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_research_request_core')));

  DELETE FROM public.product_opportunity_decisions WHERE product_id=p_highsat;
  DELETE FROM public.commerce_products WHERE id IN (p_com,p_advonly,p_advweak,p_two,p_highsat,p_branded,p_ambig,p_price);

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE (x->>'pass') IS DISTINCT FROM 'true';
  RETURN jsonb_build_object('suite','stage1_supplier_resolution','contract','stage1_supplier_resolution_v1',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'provider_calls',0,'results',v);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_stage1_supplier_resolution_selftest() TO authenticated, service_role;

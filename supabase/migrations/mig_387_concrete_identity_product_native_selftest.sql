-- mig_387 — Durable regression for concrete product identity from product-native evidence (Stage 2).
-- Additive, self-cleaning. Proves product-native concrete identity is established safely, exact CJ
-- matching is not weakened (keyword overlap never resolves; ambiguous stays ambiguous; contradictory
-- rejects), the eBay path still works, provider independence + provenance hold, and Stage-1 / launch
-- gate are unchanged. Runs entirely on fixtures (no provider calls).
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_concrete_identity_product_native_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; n_fail int;
  t uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  p_cat uuid:=gen_random_uuid(); p_kw uuid:=gen_random_uuid(); p_metrics uuid:=gen_random_uuid();
  p_ads uuid:=gen_random_uuid(); p_con uuid:=gen_random_uuid(); p_pid uuid:=gen_random_uuid();
  p_multi uuid:=gen_random_uuid(); p_gb uuid:=gen_random_uuid(); p_kalo uuid:=gen_random_uuid(); p_ebay uuid:=gen_random_uuid();
  d_cat jsonb; d_kw jsonb; d_metrics jsonb; d_ads jsonb; d_con jsonb; d_pid jsonb; d_multi jsonb; d_gb jsonb; d_kalo jsonb; d_ebay jsonb;
  r_overlap jsonb; r_exact jsonb; r_excl jsonb; r_amb jsonb;
  d_derive text; d_oppq text; d_cv text;
BEGIN
  INSERT INTO public.commerce_products (id,user_id,product_identity,identity_basis,title,provenance,product_role,visibility,first_observed_at,last_observed_at) VALUES
   (p_cat,t,'ci:cat:'||p_cat,'platform_id','Christmas decoration','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_kw,t,'ci:kw:'||p_kw,'platform_id','night light','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_metrics,t,'ci:met:'||p_metrics,'platform_id','humidifier','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_ads,t,'ci:ads:'||p_ads,'platform_id','night light','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_con,t,'ci:con:'||p_con,'platform_id','Beleuchtete Krippen Wanddekoration Bethlehem Stern','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_pid,t,'ci:pid:'||p_pid,'platform_id','humidifier','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_multi,t,'ci:multi:'||p_multi,'platform_id','Beleuchtete Krippen Wanddekoration Bethlehem Stern','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_gb,t,'ci:gb:'||p_gb,'platform_id','Beleuchtete Krippen Wanddekoration Bethlehem Stern','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_kalo,t,'ci:kalo:'||p_kalo,'platform_id','Beleuchtete Krippen Wanddekoration Bethlehem Stern','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_ebay,t,'ci:ebay:'||p_ebay,'platform_id','Ultrasonic Humidifier','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now());
  INSERT INTO public.commerce_signals (id,user_id,product_id,signal_type,value,evidence,provenance,observed_at,dedup_key) VALUES
   (gen_random_uuid(),t,p_cat,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'ci:'||p_cat||':c'),
   (gen_random_uuid(),t,p_kw,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'ci:'||p_kw||':c'),
   (gen_random_uuid(),t,p_metrics,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":99999,"revenue":999999}','[]','{"s":"t"}',now(),'ci:'||p_metrics||':c'),
   (gen_random_uuid(),t,p_con,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'ci:'||p_con||':c'),
   (gen_random_uuid(),t,p_pid,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'ci:'||p_pid||':c'),
   (gen_random_uuid(),t,p_multi,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'ci:'||p_multi||':f'),
   (gen_random_uuid(),t,p_multi,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"kalodata","sales_units":80,"revenue":1500}','[]','{"s":"t"}',now(),'ci:'||p_multi||':k'),
   (gen_random_uuid(),t,p_gb,'COMMERCE_PRODUCT_NATIVE','{"market":"GB","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'ci:'||p_gb||':gb'),
   (gen_random_uuid(),t,p_kalo,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"kalodata","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'ci:'||p_kalo||':c');
  INSERT INTO public.commerce_signals (id,user_id,product_id,signal_type,value,evidence,provenance,observed_at,dedup_key) VALUES
   (gen_random_uuid(),t,p_ads,'ADVERTISING_ACTIVITY','{"market":"DE","page_id":"A1"}','[]','{"s":"t"}',now(),'ci:'||p_ads||':a1'),
   (gen_random_uuid(),t,p_ads,'ADVERTISING_ACTIVITY','{"market":"DE","page_id":"A2"}','[]','{"s":"t"}',now(),'ci:'||p_ads||':a2');
  INSERT INTO public.commerce_signals (id,user_id,product_id,signal_type,value,evidence,provenance,observed_at,dedup_key)
  SELECT gen_random_uuid(),t,p_ebay,'MARKETPLACE_ACTIVITY',jsonb_build_object('market','DE','title','Ultrasonic Cool Mist Humidifier 500ml model '||g),'[]','{"s":"t"}',now(),'ci:'||p_ebay||':m'||g
  FROM generate_series(1,6) g;

  d_cat:=public.fn_derive_concrete_product_identity(t,p_cat,'DE');
  d_kw:=public.fn_derive_concrete_product_identity(t,p_kw,'DE');
  d_metrics:=public.fn_derive_concrete_product_identity(t,p_metrics,'DE');
  d_ads:=public.fn_derive_concrete_product_identity(t,p_ads,'DE');
  d_con:=public.fn_derive_concrete_product_identity(t,p_con,'DE');
  d_pid:=public.fn_derive_concrete_product_identity(t,p_pid,'DE');
  d_multi:=public.fn_derive_concrete_product_identity(t,p_multi,'DE');
  d_gb:=public.fn_derive_concrete_product_identity(t,p_gb,'DE');
  d_kalo:=public.fn_derive_concrete_product_identity(t,p_kalo,'DE');
  d_ebay:=public.fn_derive_concrete_product_identity(t,p_ebay,'DE');

  r_overlap:=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','K1','title','Krippen Krippenfigur Holzfigur Set','category','x')), false);
  r_exact:=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','K2','title','Beleuchtete Krippen Wanddekoration mit Bethlehem Stern LED','category','x')), false);
  r_excl:=public.fn_resolve_concrete_supplier_identity(t,p_ebay,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','H1','title','Handheld Humidifier Portable','category','x')), false);
  r_amb:=public.fn_resolve_concrete_supplier_identity(t,p_ebay,'DE', jsonb_build_array(
     jsonb_build_object('supplier','CJ','supplier_product_id','H2','title','Ultrasonic Cool Mist Humidifier Large','category','x'),
     jsonb_build_object('supplier','CJ','supplier_product_id','H3','title','Ultrasonic Humidifier Quiet Bedroom','category','x')), false);

  SELECT pg_get_functiondef(p.oid) INTO d_derive FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_derive_concrete_product_identity' AND p.prokind='f';
  SELECT pg_get_functiondef(p.oid) INTO d_oppq FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_opportunity_qualified' AND p.prokind='f';
  SELECT pg_get_functiondef(p.oid) INTO d_cv FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_commercially_validated' AND p.prokind='f';

  v:=v||jsonb_build_object('check','01_generic_category_not_concrete','pass',(d_cat->>'concrete_state')='NO_CONCRETE_EVIDENCE');
  v:=v||jsonb_build_object('check','02_generic_keyword_not_concrete','pass',(d_kw->>'concrete_state')='NO_CONCRETE_EVIDENCE');
  v:=v||jsonb_build_object('check','03_commerce_metrics_not_concrete','pass',(d_metrics->>'concrete_state')='NO_CONCRETE_EVIDENCE');
  v:=v||jsonb_build_object('check','04_advertising_not_concrete','pass',(d_ads->>'concrete_state')='NO_CONCRETE_EVIDENCE');
  v:=v||jsonb_build_object('check','05_product_native_concrete','pass',((d_con->>'concrete_state')='CONCRETE_RESOLVED' AND (d_con->'concrete_identity'->'evidence_sources'->>'primary')='PRODUCT_NATIVE'));
  v:=v||jsonb_build_object('check','06_platform_id_alone_not_enough','pass',(d_pid->>'concrete_state')='NO_CONCRETE_EVIDENCE');
  v:=v||jsonb_build_object('check','07_product_native_provenance','pass',((d_con->'concrete_identity'->'evidence_sources'->'product_native_providers') @> '"fastmoss"'::jsonb));
  v:=v||jsonb_build_object('check','08_single_source_marked','pass',(d_con->'concrete_identity'->>'identity_confidence')='SINGLE_AUTHORITATIVE_PRODUCT_OBSERVATION');
  v:=v||jsonb_build_object('check','09_multi_source_marked','pass',(d_multi->'concrete_identity'->>'identity_confidence')='MULTI_SOURCE_CORROBORATED_IDENTITY');
  v:=v||jsonb_build_object('check','10_country_isolation','pass',(d_gb->>'concrete_state')='NO_CONCRETE_EVIDENCE');
  v:=v||jsonb_build_object('check','11_provider_independence_kalodata','pass',((d_kalo->>'concrete_state')='CONCRETE_RESOLVED' AND (d_kalo->'concrete_identity'->'evidence_sources'->'product_native_providers') @> '"kalodata"'::jsonb));
  v:=v||jsonb_build_object('check','12_images_not_a_data_source','pass',(coalesce(d_derive,'') !~* 'image_url|supplier_product_assets|asset_type|product_image|_image|gallery'));
  v:=v||jsonb_build_object('check','13_ebay_path_still_works','pass',((d_ebay->>'concrete_state')='CONCRETE_RESOLVED' AND (d_ebay->'concrete_identity'->'evidence_sources'->>'primary')='EBAY_BROWSE'));
  v:=v||jsonb_build_object('check','14_keyword_overlap_not_equivalence','pass',(r_overlap->>'identity_result')='NO_VALID_CJ_MATCH');
  v:=v||jsonb_build_object('check','15_contradictory_attr_rejects','pass',((r_excl->>'identity_result')='NO_VALID_CJ_MATCH' AND jsonb_array_length(r_excl->'contradictory_evidence')>=1));
  v:=v||jsonb_build_object('check','16_ambiguous_stays_ambiguous','pass',(r_amb->>'identity_result')='CONCRETE_PRODUCT_AMBIGUOUS');
  v:=v||jsonb_build_object('check','17_exact_requires_supplier_identity','pass',((r_exact->>'identity_result')='EXACT_SUPPLIER_IDENTITY_RESOLVED' AND (r_exact->>'bound')='true'));
  v:=v||jsonb_build_object('check','18_stage1_unchanged','pass',(coalesce(d_oppq,'') ~ 'pulse_stage1_opportunity_qualification_v1'));
  v:=v||jsonb_build_object('check','19_commercial_gate_unchanged','pass',(coalesce(d_cv,'') ~ 'fn_stage1_opportunity_qualified'));

  DELETE FROM public.commerce_products WHERE id IN (p_cat,p_kw,p_metrics,p_ads,p_con,p_pid,p_multi,p_gb,p_kalo,p_ebay);

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE (x->>'pass') IS DISTINCT FROM 'true';
  RETURN jsonb_build_object('suite','concrete_identity_product_native','contract','concrete_identity_product_native_v1',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'provider_calls',0,'results',v);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_concrete_identity_product_native_selftest() TO authenticated, service_role;

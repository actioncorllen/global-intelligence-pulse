-- mig_387 — Durable regression for concrete product identity (Stage 2B product-native + Stage 2C
-- cross-language supplier matching). Additive, self-cleaning. Runs entirely on fixtures (no provider
-- calls); all supplier resolutions run with p_persist=false so nothing is bound as a real supplier.
--
-- Proves:
--   * product-native concrete identity is established safely and generic category/keyword/metrics/ads/
--     platform-id stay NO_CONCRETE_EVIDENCE; country isolation; provider independence; eBay path intact;
--     single vs multi-source provenance; images are never a data source; Stage-1 + launch gate unchanged.
--   * cross-language equivalent attributes (EN, FR) reach identity comparison and can match a German
--     source; a generic translated keyword cannot match; translation cannot manufacture a missing
--     attribute; a conflicting FORM fails closed as a contradiction; ambiguous stays ambiguous;
--     candidate retrieval != exact supplier; the source phrase/provenance is preserved; the cross-
--     language path is gated (full source coverage AND >=2 distinguishing concepts) and otherwise
--     falls back to the conservative literal path.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_concrete_identity_product_native_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; n_fail int;
  t uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  p_cat uuid:=gen_random_uuid(); p_kw uuid:=gen_random_uuid(); p_metrics uuid:=gen_random_uuid();
  p_ads uuid:=gen_random_uuid(); p_con uuid:=gen_random_uuid(); p_pid uuid:=gen_random_uuid();
  p_multi uuid:=gen_random_uuid(); p_gb uuid:=gen_random_uuid(); p_kalo uuid:=gen_random_uuid();
  p_ebay uuid:=gen_random_uuid(); p_one uuid:=gen_random_uuid();
  d_cat jsonb; d_kw jsonb; d_metrics jsonb; d_ads jsonb; d_con jsonb; d_pid jsonb; d_multi jsonb;
  d_gb jsonb; d_kalo jsonb; d_ebay jsonb; d_one jsonb;
  r_en jsonb; r_fr jsonb; r_xmas jsonb; r_led jsonb; r_proj jsonb; r_fig jsonb; r_de jsonb; r_snow jsonb; r_amb jsonb;
  d_derive text; d_oppq text; d_cv text;
BEGIN
  INSERT INTO public.commerce_products (id,user_id,product_identity,identity_basis,title,provenance,product_role,visibility,first_observed_at,last_observed_at) VALUES
   (p_cat,t,'cx:cat:'||p_cat,'platform_id','Christmas decoration','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_kw,t,'cx:kw:'||p_kw,'platform_id','night light','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_metrics,t,'cx:met:'||p_metrics,'platform_id','humidifier','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_ads,t,'cx:ads:'||p_ads,'platform_id','night light','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_con,t,'cx:con:'||p_con,'platform_id','Beleuchtete Krippen Wanddekoration','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_pid,t,'cx:pid:'||p_pid,'platform_id','humidifier','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_multi,t,'cx:multi:'||p_multi,'platform_id','Beleuchtete Krippen Wanddekoration','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_gb,t,'cx:gb:'||p_gb,'platform_id','Beleuchtete Krippen Wanddekoration','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_kalo,t,'cx:kalo:'||p_kalo,'platform_id','Beleuchtete Krippen Wanddekoration','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_ebay,t,'cx:ebay:'||p_ebay,'platform_id','Ultrasonic Humidifier','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now()),
   (p_one,t,'cx:one:'||p_one,'platform_id','Beleuchtete Dekorative Stehlampe','{"s":"t"}','candidate','TENANT_PRIVATE',now(),now());
  INSERT INTO public.commerce_signals (id,user_id,product_id,signal_type,value,evidence,provenance,observed_at,dedup_key) VALUES
   (gen_random_uuid(),t,p_cat,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'cx:'||p_cat||':c'),
   (gen_random_uuid(),t,p_kw,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'cx:'||p_kw||':c'),
   (gen_random_uuid(),t,p_metrics,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":99999,"revenue":999999}','[]','{"s":"t"}',now(),'cx:'||p_metrics||':c'),
   (gen_random_uuid(),t,p_con,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'cx:'||p_con||':c'),
   (gen_random_uuid(),t,p_pid,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'cx:'||p_pid||':c'),
   (gen_random_uuid(),t,p_multi,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'cx:'||p_multi||':f'),
   (gen_random_uuid(),t,p_multi,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"kalodata","sales_units":80,"revenue":1500}','[]','{"s":"t"}',now(),'cx:'||p_multi||':k'),
   (gen_random_uuid(),t,p_gb,'COMMERCE_PRODUCT_NATIVE','{"market":"GB","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'cx:'||p_gb||':gb'),
   (gen_random_uuid(),t,p_kalo,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"kalodata","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'cx:'||p_kalo||':c'),
   (gen_random_uuid(),t,p_one,'COMMERCE_PRODUCT_NATIVE','{"market":"DE","source":"fastmoss","sales_units":100,"revenue":2000}','[]','{"s":"t"}',now(),'cx:'||p_one||':c');
  INSERT INTO public.commerce_signals (id,user_id,product_id,signal_type,value,evidence,provenance,observed_at,dedup_key) VALUES
   (gen_random_uuid(),t,p_ads,'ADVERTISING_ACTIVITY','{"market":"DE","page_id":"A1"}','[]','{"s":"t"}',now(),'cx:'||p_ads||':a1'),
   (gen_random_uuid(),t,p_ads,'ADVERTISING_ACTIVITY','{"market":"DE","page_id":"A2"}','[]','{"s":"t"}',now(),'cx:'||p_ads||':a2');
  INSERT INTO public.commerce_signals (id,user_id,product_id,signal_type,value,evidence,provenance,observed_at,dedup_key)
  SELECT gen_random_uuid(),t,p_ebay,'MARKETPLACE_ACTIVITY',jsonb_build_object('market','DE','title','Ultrasonic Cool Mist Humidifier 500ml model '||g),'[]','{"s":"t"}',now(),'cx:'||p_ebay||':m'||g
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
  d_one:=public.fn_derive_concrete_product_identity(t,p_one,'DE');

  r_en  :=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','E1','title','Illuminated Nativity Scene Wall Decoration with Bethlehem Star LED','category','x')), false);
  r_fr  :=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','F1','title','Decoration Murale Creche Lumineuse Noel LED','category','x')), false);
  r_xmas:=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','X1','title','Christmas Decoration Set Indoor Outdoor','category','x')), false);
  r_led :=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','L1','title','LED Wall Light RGB Dimmable','category','x')), false);
  r_proj:=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','P1','title','Nativity Scene Projector Light Outdoor','category','x')), false);
  r_fig :=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','G1','title','Krippen Krippenfigur Holzfigur Set','category','x')), false);
  r_de  :=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','D1','title','Beleuchtete Krippen Wanddekoration mit Bethlehem Stern LED','category','x')), false);
  r_snow:=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(jsonb_build_object('supplier','CJ','supplier_product_id','S1','title','Illuminated Wall Decoration Snowman Figure','category','x')), false);
  r_amb :=public.fn_resolve_concrete_supplier_identity(t,p_con,'DE', jsonb_build_array(
     jsonb_build_object('supplier','CJ','supplier_product_id','A1','title','Illuminated Nativity Scene Wall Decoration Large','category','x'),
     jsonb_build_object('supplier','CJ','supplier_product_id','A2','title','Illuminated Nativity Wall Decor Bethlehem LED','category','x')), false);

  SELECT pg_get_functiondef(p.oid) INTO d_derive FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_derive_concrete_product_identity' AND p.prokind='f';
  SELECT pg_get_functiondef(p.oid) INTO d_oppq FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_opportunity_qualified' AND p.prokind='f';
  SELECT pg_get_functiondef(p.oid) INTO d_cv FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_commercially_validated' AND p.prokind='f';

  -- Stage-2B carried forward
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
  v:=v||jsonb_build_object('check','14_keyword_overlap_not_equivalence','pass',(r_fig->>'identity_result')='NO_VALID_CJ_MATCH');
  v:=v||jsonb_build_object('check','16_ambiguous_stays_ambiguous','pass',(r_amb->>'identity_result')='CONCRETE_PRODUCT_AMBIGUOUS');
  v:=v||jsonb_build_object('check','17_exact_requires_supplier_identity','pass',((r_de->>'identity_result')='EXACT_SUPPLIER_IDENTITY_RESOLVED' AND (r_de->>'bound')='true'));
  v:=v||jsonb_build_object('check','18_stage1_unchanged','pass',(coalesce(d_oppq,'') ~ 'pulse_stage1_opportunity_qualification_v1'));
  v:=v||jsonb_build_object('check','19_commercial_gate_unchanged','pass',(coalesce(d_cv,'') ~ 'fn_stage1_opportunity_qualified'));
  -- Stage-2C cross-language
  v:=v||jsonb_build_object('check','20_source_canonical_eligible','pass',((d_con->'match_spec'->>'canonical_cross_language')='true' AND jsonb_array_length(d_con->'match_spec'->'canonical_attr_all')=3));
  v:=v||jsonb_build_object('check','21_source_phrase_provenance_preserved','pass',((d_con->'concrete_identity'->>'concrete_phrase')='beleuchtete krippen wanddekoration' AND jsonb_array_length(d_con->'concrete_identity'->'source_language_tokens')=3));
  v:=v||jsonb_build_object('check','22_en_equiv_reaches_and_qualifies','pass',((r_en->>'identity_result')='EXACT_SUPPLIER_IDENTITY_RESOLVED' AND (r_en->>'bound')='true' AND (r_en->'candidates_considered'->0->'evidence'->>'match_language')='CROSS_LANGUAGE_CANONICAL'));
  v:=v||jsonb_build_object('check','23_fr_equiv_cross_language','pass',(r_fr->>'identity_result')='EXACT_SUPPLIER_IDENTITY_RESOLVED');
  v:=v||jsonb_build_object('check','24_generic_translated_keyword_rejects','pass',(r_xmas->>'identity_result')='NO_VALID_CJ_MATCH');
  v:=v||jsonb_build_object('check','25_led_wall_light_form_conflict_rejects','pass',((r_led->>'identity_result')='NO_VALID_CJ_MATCH' AND jsonb_array_length(r_led->'contradictory_evidence')>=1));
  v:=v||jsonb_build_object('check','26_nativity_projector_rejects','pass',((r_proj->>'identity_result')='NO_VALID_CJ_MATCH' AND jsonb_array_length(r_proj->'contradictory_evidence')>=1));
  v:=v||jsonb_build_object('check','27_translation_cannot_manufacture_missing_attr','pass',(r_snow->>'identity_result')='NO_VALID_CJ_MATCH');
  v:=v||jsonb_build_object('check','28_cross_language_eligibility_guard','pass',((d_one->'match_spec'->>'canonical_cross_language')='false' AND jsonb_array_length(d_one->'match_spec'->'canonical_attr_all')=0));
  v:=v||jsonb_build_object('check','29_de_same_product_same_language','pass',((r_de->'candidates_considered'->0->'evidence'->>'match_language')='SAME_LANGUAGE'));
  v:=v||jsonb_build_object('check','30_contradictory_figurine_form_rejects','pass',((r_fig->>'identity_result')='NO_VALID_CJ_MATCH' AND jsonb_array_length(r_fig->'contradictory_evidence')>=1));

  DELETE FROM public.commerce_signals WHERE product_id IN (p_cat,p_kw,p_metrics,p_ads,p_con,p_pid,p_multi,p_gb,p_kalo,p_ebay,p_one);
  DELETE FROM public.commerce_products WHERE id IN (p_cat,p_kw,p_metrics,p_ads,p_con,p_pid,p_multi,p_gb,p_kalo,p_ebay,p_one);

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE (x->>'pass') IS DISTINCT FROM 'true';
  RETURN jsonb_build_object('suite','concrete_identity_product_native_and_cross_language','contract','concrete_identity_crosslang_v2',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'provider_calls',0,'results',v);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_concrete_identity_product_native_selftest() TO authenticated, service_role;

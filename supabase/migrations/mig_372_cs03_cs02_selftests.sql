-- mig_372 — CS.03 (fn_asset_use_eligibility) + CS.02 (fn_product_media_discovery) deterministic selftests.
-- Real founder product e453eed4 + synthetic rights fixtures (is_synthetic, rolled back). No rights-flag writes
-- persist; no paid calls. Proves per-use distinctions, fail-closed defaults, expiry/revocation, tenant isolation,
-- identity exact-match, marketplace exclusion, and "search success != commercial eligibility".

CREATE OR REPLACE FUNCTION public.fn_asset_use_eligibility_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb:='[]'::jsonb; v_pass int; v_fail int; v_prev text; v_r jsonb;
  v_founder uuid:='7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid:='e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_other uuid:='11111111-1111-4111-8111-111111111111';
BEGIN
  v_prev := current_setting('request.jwt.claims', true);

  PERFORM set_config('request.jwt.claims','{}',true);
  v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','CJ_SUPPLIER','2608250310481611400','u','{}');
  v_checks := v_checks || jsonb_build_object('check','UNAUTHENTICATED','ok',v_r->>'status'='unauthenticated','detail',v_r->>'status');

  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_other::text)::text, true);
  v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','CJ_SUPPLIER','2608250310481611400','u','{}');
  v_checks := v_checks || jsonb_build_object('check','CROSS_TENANT_REJECTED','ok',v_r->>'status'='cross_tenant_rejected','detail',v_r->>'status');

  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_founder::text)::text, true);

  v_r := public.fn_asset_use_eligibility(v_prod,'GB','CUSTOMER_OWNED','CUSTOMER_UPLOAD',NULL,NULL,'{"rights_confirmed":"true"}');
  v_checks := v_checks || jsonb_build_object('check','OWNED_ALL_USES',
    'ok', (v_r->'uses'->'research_display'->>'allowed')='true' AND (v_r->'uses'->'customer_download'->>'allowed')='true'
       AND (v_r->'uses'->'commercial_advertising'->>'allowed')='true' AND (v_r->'uses'->'derivative_creation'->>'allowed')='true'
       AND (v_r->'uses'->'ai_input'->>'allowed')='true' AND (v_r->'uses'->'video_production'->>'allowed')='true'
       AND (v_r->'uses'->'subscriber_export'->>'allowed')='true', 'detail', v_r->'uses');

  v_r := public.fn_asset_use_eligibility(v_prod,'GB','MARKETPLACE_PUBLIC_LISTING','EBAY_BROWSE',NULL,NULL,'{}');
  v_checks := v_checks || jsonb_build_object('check','MARKETPLACE_ALL_BLOCKED',
    'ok', (v_r->'uses'->'research_display'->>'allowed')='false' AND (v_r->'uses'->'customer_download'->>'allowed')='false'
       AND (v_r->'uses'->'commercial_advertising'->>'allowed')='false' AND (v_r->'uses'->'ai_input'->>'allowed')='false'
       AND (v_r->'uses'->'subscriber_export'->>'allowed')='false', 'detail', v_r->'uses');

  v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','CJ_SUPPLIER','2608250310481611400','u','{}');
  v_checks := v_checks || jsonb_build_object('check','SUPPLIER_AI_ONLY',
    'ok', (v_r->'uses'->'ai_input'->>'allowed')='true' AND (v_r->'uses'->'commercial_advertising'->>'allowed')='false'
       AND (v_r->'uses'->'research_display'->>'allowed')='false' AND (v_r->'uses'->'customer_download'->>'allowed')='false'
       AND (v_r->'uses'->'subscriber_export'->>'allowed')='false', 'detail', v_r->'uses');

  BEGIN  -- synthetic evidence; always rolled back
    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES('cjx','CS03_ADV','DISPLAY_AUTHORISED','{"research_display":true,"advertising":true}'::jsonb, now(), true);
    v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjx','CS03_ADV',NULL,'{}');
    v_checks := v_checks || jsonb_build_object('check','EVIDENCE_SCOPED_ADVERTISING_ONLY',
      'ok', (v_r->'uses'->'commercial_advertising'->>'allowed')='true'
         AND (v_r->'uses'->'research_display'->>'allowed')='true'
         AND (v_r->'uses'->'derivative_creation'->>'allowed')='false'
         AND (v_r->'uses'->'video_production'->>'allowed')='false'
         AND (v_r->'uses'->'customer_download'->>'allowed')='false'
         AND (v_r->'uses'->'subscriber_export'->>'allowed')='false', 'detail', v_r->'uses');

    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES('cjx','CS03_EXP','DISPLAY_AUTHORISED','{"research_display":true,"advertising":true,"expires_at":"2000-01-01T00:00:00Z"}'::jsonb, now(), true);
    v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjx','CS03_EXP',NULL,'{}');
    v_checks := v_checks || jsonb_build_object('check','EXPIRED_SCOPE_BLOCKS',
      'ok', (v_r->>'evidence_expired')='true' AND (v_r->'uses'->'commercial_advertising'->>'allowed')='false'
         AND (v_r->'uses'->'research_display'->>'allowed')='false',
      'detail', jsonb_build_object('expired',v_r->>'evidence_expired','adv',v_r->'uses'->'commercial_advertising'->>'allowed'));

    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,revoked_at,is_synthetic)
      VALUES('cjx','CS03_REV','DISPLAY_AUTHORISED','{"research_display":true,"advertising":true}'::jsonb, now(), true);
    v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjx','CS03_REV',NULL,'{}');
    v_checks := v_checks || jsonb_build_object('check','REVOKED_BLOCKS',
      'ok', (v_r->'uses'->'commercial_advertising'->>'allowed')='false'
         AND (v_r->'uses'->'research_display'->>'allowed')='false', 'detail', v_r->'uses'->'commercial_advertising'->>'allowed');

    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES('cjx','CS03_DL','DISPLAY_AUTHORISED','{"research_display":true,"advertising":true,"derivative":true,"video":true,"ai_input":true}'::jsonb, now(), true);
    v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjx','CS03_DL',NULL,'{}');
    v_checks := v_checks || jsonb_build_object('check','NO_DOWNLOAD_EXPORT_FOR_SUPPLIER',
      'ok', (v_r->'uses'->'customer_download'->>'allowed')='false'
         AND (v_r->'uses'->'subscriber_export'->>'allowed')='false'
         AND (v_r->'uses'->'derivative_creation'->>'allowed')='true'
         AND (v_r->'uses'->'video_production'->>'allowed')='true', 'detail', v_r->'uses');

    RAISE EXCEPTION 'cs03_selftest_rollback';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  v_checks := v_checks || jsonb_build_object('check','NO_SYNTHETIC_PERSISTED',
    'ok', NOT EXISTS(SELECT 1 FROM public.commerce_supplier_image_rights WHERE source='cjx'),
    'detail',(SELECT count(*) FROM public.commerce_supplier_image_rights WHERE source='cjx'));

  PERFORM set_config('request.jwt.claims', coalesce(v_prev,''), true);
  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass,v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok',v_fail=0,'passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,
    'checks',v_checks,'contract','pulse_asset_use_eligibility_selftest_v1','generated_at',now());
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_product_media_discovery_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb:='[]'::jsonb; v_pass int; v_fail int; v_prev text; v_r jsonb;
  v_founder uuid:='7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid:='e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_other uuid:='11111111-1111-4111-8111-111111111111';
  v_amb int; v_mp int; v_badcomm int;
BEGIN
  v_prev := current_setting('request.jwt.claims', true);

  PERFORM set_config('request.jwt.claims','{}',true);
  v_r := public.fn_product_media_discovery(v_prod,'GB');
  v_checks := v_checks || jsonb_build_object('check','UNAUTHENTICATED','ok',v_r->>'status'='unauthenticated','detail',v_r->>'status');

  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_other::text)::text, true);
  v_r := public.fn_product_media_discovery(v_prod,'GB');
  v_checks := v_checks || jsonb_build_object('check','CROSS_TENANT_REJECTED','ok',v_r->>'status'='cross_tenant_rejected','detail',v_r->>'status');

  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_founder::text)::text, true);
  v_r := public.fn_product_media_discovery(v_prod,'GB');

  v_checks := v_checks || jsonb_build_object('check','STARTS_FROM_IDENTITY_EXCLUDES_MARKETPLACE',
    'ok', v_r->>'status'='ok' AND v_r->>'started_from'='VERIFIED_PRODUCT_IDENTITY'
       AND (v_r->>'candidate_count')::int > 0 AND (v_r->>'excluded_research_reference_images')::int > 0,
    'detail', jsonb_build_object('candidates',v_r->'candidate_count','excluded',v_r->'excluded_research_reference_images'));

  SELECT count(*) INTO v_amb FROM jsonb_array_elements(v_r->'candidates') c
   WHERE c->'identity_match'->>'verdict' NOT IN ('EXACT_SUPPLIER_IDENTITY','OWNER_SUPPLIED');
  v_checks := v_checks || jsonb_build_object('check','NO_AMBIGUOUS_SUBSTITUTION','ok', v_amb=0, 'detail', v_amb);

  SELECT count(*) INTO v_mp FROM jsonb_array_elements(v_r->'candidates') c
   WHERE upper(coalesce(c->>'source','')) LIKE '%EBAY%' OR upper(coalesce(c->>'source','')) LIKE '%MARKETPLACE%'
      OR upper(coalesce(c->>'source','')) LIKE '%AMAZON%';
  v_checks := v_checks || jsonb_build_object('check','NO_MARKETPLACE_CANDIDATE','ok', v_mp=0, 'detail', v_mp);

  SELECT count(*) INTO v_badcomm FROM jsonb_array_elements(v_r->'candidates') c
   WHERE upper(coalesce(c->>'origin','')) <> 'CUSTOMER_OWNED'
     AND ((c->'permitted_use'->'commercial_advertising'->>'allowed')='true'
       OR (c->'permitted_use'->'customer_download'->>'allowed')='true');
  v_checks := v_checks || jsonb_build_object('check','SEARCH_NOT_COMMERCIAL_ELIGIBILITY','ok', v_badcomm=0, 'detail', v_badcomm);

  v_checks := v_checks || jsonb_build_object('check','EXACT_IDENTITY_MATCH',
    'ok', (v_r->'candidates'->0->'identity_match'->>'verdict')='EXACT_SUPPLIER_IDENTITY'
       AND (v_r->'candidates'->0->'identity_match'->>'candidate_source_item_id')
         = (v_r->'candidates'->0->'identity_match'->>'verified_supplier_product_id'),
    'detail', v_r->'candidates'->0->'identity_match');

  PERFORM set_config('request.jwt.claims', coalesce(v_prev,''), true);
  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass,v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok',v_fail=0,'passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,
    'checks',v_checks,'contract','pulse_product_media_discovery_selftest_v1','generated_at',now());
END; $function$;
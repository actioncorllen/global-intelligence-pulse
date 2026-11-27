-- mig_374 — Task D: end-to-end CS.02/CS.03 proof over the 8 required scenarios.
-- Real founder product e453eed4 + synthetic rights fixtures (rolled back). No paid calls; no rights-flag writes
-- persist; existing Creative Studio paths asserted intact.

CREATE OR REPLACE FUNCTION public.fn_cs_media_end_to_end_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb:='[]'::jsonb; v_pass int; v_fail int; v_prev text; v_r jsonb; v_d jsonb;
  v_founder uuid:='7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid:='e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_other uuid:='11111111-1111-4111-8111-111111111111';
  v_ef int := 0;
BEGIN
  v_prev := current_setting('request.jwt.claims', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_founder::text)::text, true);

  -- D1 correct product + variant matching (exact supplier identity)
  v_d := public.fn_product_media_discovery(v_prod,'GB');
  v_checks := v_checks || jsonb_build_object('check','D1_PRODUCT_VARIANT_MATCH',
    'ok', (v_d->'candidates'->0->'identity_match'->>'verdict')='EXACT_SUPPLIER_IDENTITY'
      AND (v_d->'candidates'->0->'identity_match'->>'candidate_source_item_id')
        = (v_d->'candidates'->0->'identity_match'->>'verified_supplier_product_id'),
    'detail', v_d->'candidates'->0->'identity_match');

  -- D2 research-only image rejected for creative generation (no ai_input; excluded from candidates)
  v_r := public.fn_asset_use_eligibility(v_prod,'GB','MARKETPLACE_PUBLIC_LISTING','EBAY_BROWSE',NULL,NULL,'{}');
  v_checks := v_checks || jsonb_build_object('check','D2_RESEARCH_IMAGE_REJECTED_FOR_GENERATION',
    'ok', (v_r->'uses'->'ai_input'->>'allowed')='false'
      AND (v_d->>'excluded_research_reference_images')::int > 0,
    'detail', jsonb_build_object('ai_input',v_r->'uses'->'ai_input'->>'allowed','excluded',v_d->'excluded_research_reference_images'));

  -- D4 unknown rights fail closed (unknown rights_state + unknown provider, no evidence => all commercial false)
  v_r := public.fn_asset_use_eligibility(v_prod,'GB','SOMETHING_UNKNOWN','MYSTERY_PROVIDER',NULL,NULL,'{}');
  v_checks := v_checks || jsonb_build_object('check','D4_UNKNOWN_FAIL_CLOSED',
    'ok', v_r->>'origin_class'='RIGHTS_UNKNOWN'
      AND (v_r->'uses'->'commercial_advertising'->>'allowed')='false'
      AND (v_r->'uses'->'ai_input'->>'allowed')='false'
      AND (v_r->'uses'->'research_display'->>'allowed')='false'
      AND (v_r->'uses'->'customer_download'->>'allowed')='false', 'detail', v_r->>'origin_class');

  -- D6 cross-tenant substitution prevented (both readers)
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_other::text)::text, true);
  v_checks := v_checks || jsonb_build_object('check','D6_CROSS_TENANT_PREVENTED',
    'ok', (public.fn_product_media_discovery(v_prod,'GB')->>'status')='cross_tenant_rejected'
      AND (public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','CJ_SUPPLIER','2608250310481611400','u','{}')->>'status')='cross_tenant_rejected',
    'detail','both readers reject non-owner');
  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_founder::text)::text, true);

  -- D7 no unauthorised download URL / export right for supplier or marketplace imagery
  v_checks := v_checks || jsonb_build_object('check','D7_NO_UNAUTHORISED_DOWNLOAD',
    'ok', (public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','CJ_SUPPLIER','2608250310481611400','u','{}')->'uses'->'customer_download'->>'allowed')='false'
      AND (public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','CJ_SUPPLIER','2608250310481611400','u','{}')->'uses'->'subscriber_export'->>'allowed')='false'
      AND (public.fn_asset_use_eligibility(v_prod,'GB','MARKETPLACE_PUBLIC_LISTING','EBAY_BROWSE',NULL,NULL,'{}')->'uses'->'customer_download'->>'allowed')='false',
    'detail','download/export never granted for third-party supplier/marketplace imagery');

  BEGIN  -- synthetic evidence, rolled back: D3 authorised-only use + D5 revoked/expired block
    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES('cjd','D3_ADV','DISPLAY_AUTHORISED','{"research_display":true,"advertising":true}'::jsonb, now(), true);
    v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjd','D3_ADV',NULL,'{}');
    v_checks := v_checks || jsonb_build_object('check','D3_RIGHTS_SAFE_ONLY_AUTHORISED_USES',
      'ok', (v_r->'uses'->'commercial_advertising'->>'allowed')='true'
        AND (v_r->'uses'->'video_production'->>'allowed')='false'
        AND (v_r->'uses'->'derivative_creation'->>'allowed')='false'
        AND (v_r->'uses'->'customer_download'->>'allowed')='false', 'detail', v_r->'uses');

    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES('cjd','D5_EXP','DISPLAY_AUTHORISED','{"advertising":true,"expires_at":"2000-01-01T00:00:00Z"}'::jsonb, now(), true);
    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,revoked_at,is_synthetic)
      VALUES('cjd','D5_REV','DISPLAY_AUTHORISED','{"advertising":true}'::jsonb, now(), true);
    v_checks := v_checks || jsonb_build_object('check','D5_REVOKED_OR_EXPIRED_BLOCK',
      'ok', (public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjd','D5_EXP',NULL,'{}')->'uses'->'commercial_advertising'->>'allowed')='false'
        AND (public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjd','D5_REV',NULL,'{}')->'uses'->'commercial_advertising'->>'allowed')='false',
      'detail','expired and revoked both blocked');

    RAISE EXCEPTION 'cs_e2e_rollback';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- no synthetic evidence persisted
  v_checks := v_checks || jsonb_build_object('check','NO_SYNTHETIC_PERSISTED',
    'ok', NOT EXISTS(SELECT 1 FROM public.commerce_supplier_image_rights WHERE source='cjd'),
    'detail',(SELECT count(*) FROM public.commerce_supplier_image_rights WHERE source='cjd'));

  -- D8 existing Creative Studio paths remain functional (sum failures across representative selftests)
  v_ef := v_ef + coalesce(nullif(public.fn_creative_production_selftest()->>'fail','')::int, nullif(public.fn_creative_production_selftest()->>'failed','')::int, 0);
  v_ef := v_ef + coalesce(nullif(public.fn_creative_studio_routing_selftest()->>'failed','')::int, 0);
  v_ef := v_ef + coalesce(nullif(public.fn_ad_static_creative_selftest()->>'fail','')::int, 0);
  v_ef := v_ef + coalesce(nullif(public.fn_ad_creative_identity_selftest()->>'fail','')::int, 0);
  v_ef := v_ef + coalesce(nullif(public.fn_product_media_auth_selftest()->>'failed','')::int, 0);
  v_ef := v_ef + coalesce(nullif(public.fn_cj_image_rights_selftest()->>'failed','')::int, 0);
  v_ef := v_ef + coalesce(nullif(public.fn_cross_supplier_identity_selftest()->>'failed','')::int, 0);
  v_ef := v_ef + coalesce(nullif(public.fn_product_image_selftest()->>'failed','')::int, 0);
  v_checks := v_checks || jsonb_build_object('check','D8_EXISTING_PATHS_INTACT','ok', v_ef=0, 'detail', jsonb_build_object('existing_selftest_failures', v_ef));

  PERFORM set_config('request.jwt.claims', coalesce(v_prev,''), true);
  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass,v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok',v_fail=0,'passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,
    'checks',v_checks,'contract','pulse_cs_media_end_to_end_selftest_v1','generated_at',now());
END; $function$;
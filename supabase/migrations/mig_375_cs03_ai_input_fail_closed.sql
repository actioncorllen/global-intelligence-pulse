-- mig_375 — CS.03 correctness fix: ai_input FAILS CLOSED for third-party supplier images.
-- RIGHTS BASIS (BE239, CJ Support written reply): CJ supplier IMAGES are NOT licensed for third-party
-- research-SaaS reuse; analyse_cleared covers DATA/text analysis, NOT generative-AI input of image pixels;
-- reuse_creative_cleared=FALSE, commercial_redistribution_cleared=FALSE. Image-analysis rights and
-- generative-AI-input rights are INDEPENDENT. Therefore a bare SUPPLIER_PROVIDED/SUPPLIER_AUTHORIZED image
-- must NOT grant ai_input. ai_input is allowed ONLY for: owned/licensed assets; an explicitly
-- AUTHORIZED_FOR_AI_REFERENCE asset (provenance.ai_reference_only=true); or per-image evidence with an
-- explicit permission_scope.ai_input grant (unrevoked, unexpired). No rights record is changed here.
--
-- NOTE: NOT APPLIED TO PRODUCTION in this change (founder control: no new production migrations). Committed
-- for an authorised apply. The currently-deployed fn_asset_use_eligibility retains the pre-fix over-grant but
-- is UNWIRED (no customer surface calls it), so there is no active production exposure.

CREATE OR REPLACE FUNCTION public.fn_asset_use_eligibility(
  p_product_id uuid,
  p_market text DEFAULT NULL::text,
  p_rights_state text DEFAULT NULL::text,
  p_source_provider text DEFAULT NULL::text,
  p_supplier_product_id text DEFAULT NULL::text,
  p_image_ref text DEFAULT NULL::text,
  p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_owner uuid; v_class text;
  v_owned boolean; v_ai_ref boolean;
  v_cls jsonb; v_scope jsonb; v_expired boolean; v_evidence_ok boolean; v_research boolean;
  v_now timestamptz := now();
  f_adv boolean; f_deriv boolean; f_ai boolean; f_vid boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF p_product_id IS NULL THEN RETURN jsonb_build_object('status','invalid_args'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_owner <> v_uid THEN RETURN jsonb_build_object('status','cross_tenant_rejected'); END IF;

  v_class := public.fn_asset_rights_class(p_rights_state, p_source_provider, coalesce(p_provenance,'{}'::jsonb));
  v_owned := v_class IN ('CUSTOMER_OWNED','EXPLICITLY_LICENSED') OR upper(coalesce(p_rights_state,''))='FIRST_PARTY_OWNED';
  v_ai_ref := v_class = 'AUTHORIZED_FOR_AI_REFERENCE';  -- explicit provenance.ai_reference_only=true

  IF NOT v_owned AND p_supplier_product_id IS NOT NULL AND p_source_provider IS NOT NULL THEN
    v_cls := public.fn_cj_image_display_classification(p_source_provider, p_supplier_product_id, p_image_ref);
  END IF;
  v_scope := coalesce(v_cls->'permission_scope','{}'::jsonb);
  v_expired := (v_scope->>'expires_at') IS NOT NULL AND (v_scope->>'expires_at')::timestamptz < v_now;
  v_evidence_ok := coalesce(v_cls->>'classification','') = 'DISPLAY_AUTHORISED' AND NOT v_expired;
  v_research := coalesce((v_cls->'rights'->>'research_display')::boolean,false) AND NOT v_expired;

  f_adv   := v_evidence_ok AND coalesce((v_scope->>'advertising')::boolean,false);
  f_deriv := v_evidence_ok AND coalesce((v_scope->>'derivative')::boolean,false);
  f_ai    := v_evidence_ok AND coalesce((v_scope->>'ai_input')::boolean,false);  -- explicit per-image AI-input grant
  f_vid   := v_evidence_ok AND coalesce((v_scope->>'video')::boolean,false);

  RETURN jsonb_build_object(
    'status','ok','product_id',p_product_id::text,'market',upper(coalesce(p_market,'')),
    'origin_class', v_class,
    'owned_lane', v_owned,
    'evidence_level', coalesce(v_cls->>'evidence_level','none'),
    'evidence_classification', coalesce(v_cls->>'classification','NONE'),
    'evidence_expired', coalesce(v_expired,false),
    'attribution', jsonb_build_object(
       'source_provider', p_source_provider, 'supplier_product_id', p_supplier_product_id,
       'rights_state', p_rights_state,
       'ownership', CASE WHEN v_owned THEN 'TENANT_OWNED_OR_LICENSED' ELSE 'THIRD_PARTY' END),
    'uses', jsonb_build_object(
      'research_display',       jsonb_build_object('allowed', (v_owned OR v_research),
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED' WHEN v_research THEN 'PER_IMAGE_EVIDENCE' ELSE 'NO_AUTHORISATION' END),
      'customer_download',      jsonb_build_object('allowed', v_owned,
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED' ELSE 'NEVER_FOR_THIRD_PARTY' END),
      'commercial_advertising', jsonb_build_object('allowed', (v_owned OR f_adv),
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED' WHEN f_adv THEN 'PER_IMAGE_EVIDENCE' ELSE 'NO_AUTHORISATION' END),
      'derivative_creation',    jsonb_build_object('allowed', (v_owned OR f_deriv),
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED' WHEN f_deriv THEN 'PER_IMAGE_EVIDENCE' ELSE 'NO_AUTHORISATION' END),
      -- FAIL-CLOSED: bare supplier (SUPPLIER_AUTHORIZED) no longer grants ai_input. Requires owned/licensed,
      -- explicit AUTHORIZED_FOR_AI_REFERENCE, or per-image ai_input evidence.
      'ai_input',               jsonb_build_object('allowed', (v_owned OR v_ai_ref OR f_ai),
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED'
                      WHEN v_ai_ref THEN 'AUTHORISED_AI_REFERENCE'
                      WHEN f_ai THEN 'PER_IMAGE_AI_INPUT_EVIDENCE' ELSE 'NO_WRITTEN_AI_INPUT_PERMISSION' END),
      'video_production',       jsonb_build_object('allowed', (v_owned OR f_vid),
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED' WHEN f_vid THEN 'PER_IMAGE_EVIDENCE' ELSE 'NO_AUTHORISATION' END),
      'subscriber_export',      jsonb_build_object('allowed', v_owned,
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED' ELSE 'RESTRICTED_RESEARCH_NEVER_EXPORTABLE' END)
    ),
    'rules', jsonb_build_array(
      'Image-analysis rights and generative-AI-input rights are INDEPENDENT; analyse-cleared never implies ai_input.',
      'A research/marketplace image, a bare supplier image, or a provider-global permission is NEVER upgraded to commercial or AI-input rights.',
      'Commercial/AI-input uses require per-image authoritative evidence (unrevoked, unexpired) OR an owned/licensed/authorised-upload asset OR an explicitly AI-reference-authorised asset.',
      'Customer download and subscriber export are permitted only for owned/licensed/uploaded assets; never third-party supplier/marketplace imagery.',
      'Revoked evidence is ignored; expired scope voids grants; tenant isolation enforced.'),
    'contract','pulse_asset_use_eligibility_v2_ai_input_failclosed');
END; $function$;

-- Selftest updated to the fail-closed contract.
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

  -- FAIL-CLOSED: bare CJ supplier image grants NOTHING (no written AI-input/commercial/display permission).
  v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','CJ_SUPPLIER','2608250310481611400','u','{}');
  v_checks := v_checks || jsonb_build_object('check','SUPPLIER_BARE_FAILS_CLOSED',
    'ok', (v_r->'uses'->'ai_input'->>'allowed')='false' AND (v_r->'uses'->'commercial_advertising'->>'allowed')='false'
       AND (v_r->'uses'->'research_display'->>'allowed')='false' AND (v_r->'uses'->'customer_download'->>'allowed')='false'
       AND (v_r->'uses'->'subscriber_export'->>'allowed')='false', 'detail', v_r->'uses');

  -- Explicitly AI-reference-authorised asset grants ai_input (but not advertising/download without evidence).
  v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','CJ_SUPPLIER','2608250310481611400','u','{"ai_reference_only":"true"}');
  v_checks := v_checks || jsonb_build_object('check','AI_REFERENCE_FLAG_ALLOWS_AI_INPUT_ONLY',
    'ok', (v_r->'uses'->'ai_input'->>'allowed')='true' AND (v_r->'uses'->'commercial_advertising'->>'allowed')='false'
       AND (v_r->'uses'->'customer_download'->>'allowed')='false', 'detail', v_r->'uses'->'ai_input');

  BEGIN
    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES('cjx','CS03_ADV','DISPLAY_AUTHORISED','{"research_display":true,"advertising":true}'::jsonb, now(), true);
    v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjx','CS03_ADV',NULL,'{}');
    v_checks := v_checks || jsonb_build_object('check','EVIDENCE_SCOPED_ADVERTISING_ONLY',
      'ok', (v_r->'uses'->'commercial_advertising'->>'allowed')='true'
         AND (v_r->'uses'->'research_display'->>'allowed')='true'
         AND (v_r->'uses'->'ai_input'->>'allowed')='false'          -- advertising scope does NOT grant ai_input
         AND (v_r->'uses'->'derivative_creation'->>'allowed')='false'
         AND (v_r->'uses'->'customer_download'->>'allowed')='false', 'detail', v_r->'uses');

    -- Explicit per-image ai_input evidence grants ai_input.
    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES('cjx','CS03_AIIN','DISPLAY_AUTHORISED','{"research_display":true,"ai_input":true}'::jsonb, now(), true);
    v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjx','CS03_AIIN',NULL,'{}');
    v_checks := v_checks || jsonb_build_object('check','PER_IMAGE_AI_INPUT_EVIDENCE_GRANTS',
      'ok', (v_r->'uses'->'ai_input'->>'allowed')='true'
         AND (v_r->'uses'->'commercial_advertising'->>'allowed')='false', 'detail', v_r->'uses'->'ai_input');

    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,verified_at,is_synthetic)
      VALUES('cjx','CS03_EXP','DISPLAY_AUTHORISED','{"research_display":true,"ai_input":true,"expires_at":"2000-01-01T00:00:00Z"}'::jsonb, now(), true);
    v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjx','CS03_EXP',NULL,'{}');
    v_checks := v_checks || jsonb_build_object('check','EXPIRED_SCOPE_BLOCKS',
      'ok', (v_r->>'evidence_expired')='true' AND (v_r->'uses'->'ai_input'->>'allowed')='false'
         AND (v_r->'uses'->'research_display'->>'allowed')='false',
      'detail', jsonb_build_object('expired',v_r->>'evidence_expired','ai',v_r->'uses'->'ai_input'->>'allowed'));

    INSERT INTO public.commerce_supplier_image_rights(source,supplier_product_id,decision,permission_scope,revoked_at,is_synthetic)
      VALUES('cjx','CS03_REV','DISPLAY_AUTHORISED','{"research_display":true,"ai_input":true}'::jsonb, now(), true);
    v_r := public.fn_asset_use_eligibility(v_prod,'GB','SUPPLIER_PROVIDED','cjx','CS03_REV',NULL,'{}');
    v_checks := v_checks || jsonb_build_object('check','REVOKED_BLOCKS',
      'ok', (v_r->'uses'->'ai_input'->>'allowed')='false'
         AND (v_r->'uses'->'research_display'->>'allowed')='false', 'detail', v_r->'uses'->'ai_input'->>'allowed');

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
    'checks',v_checks,'contract','pulse_asset_use_eligibility_selftest_v2_ai_input_failclosed','generated_at',now());
END; $function$;
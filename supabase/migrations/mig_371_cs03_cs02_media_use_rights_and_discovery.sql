-- mig_371 — CS.03 per-asset use-eligibility reader + CS.02 high-quality media discovery reader
-- Reuse-first: thin readers composed over existing primitives
--   fn_asset_rights_class (origin class), fn_cj_image_display_classification (per-image evidence + revocation
--   + specificity + granular scope), fn_ad_product_card_authority (authoritative candidate set),
--   fn_product_supplier_identity (verified identity). No rebuild of Gemini/OpenAI/media-job/storage/PAL.
-- Tenant = auth.uid() (strong isolation). Read-only; no rights-flag writes; no paid calls.

-- ============================================================================
-- CS.03 — per-asset use eligibility across 7 use-classes, fail-closed.
-- Never upgrades a research/marketplace image or a provider-global permission into commercial rights.
-- Commercial uses require per-image authoritative evidence (unrevoked, unexpired) OR an owned/licensed/
-- authorised-upload asset. Customer download & subscriber export only for owned/licensed/uploaded assets.
-- ============================================================================
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
  v_owned boolean; v_supplier_auth boolean; v_ai_ref boolean;
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
  v_supplier_auth := v_class = 'SUPPLIER_AUTHORIZED';
  v_ai_ref := v_class = 'AUTHORIZED_FOR_AI_REFERENCE';

  -- Per-image authoritative evidence lane (supplier/marketplace origin only; owned assets need no evidence).
  IF NOT v_owned AND p_supplier_product_id IS NOT NULL AND p_source_provider IS NOT NULL THEN
    v_cls := public.fn_cj_image_display_classification(p_source_provider, p_supplier_product_id, p_image_ref);
  END IF;
  v_scope := coalesce(v_cls->'permission_scope','{}'::jsonb);
  v_expired := (v_scope->>'expires_at') IS NOT NULL AND (v_scope->>'expires_at')::timestamptz < v_now;
  v_evidence_ok := coalesce(v_cls->>'classification','') = 'DISPLAY_AUTHORISED' AND NOT v_expired;
  v_research := coalesce((v_cls->'rights'->>'research_display')::boolean,false) AND NOT v_expired;

  f_adv   := v_evidence_ok AND coalesce((v_scope->>'advertising')::boolean,false);
  f_deriv := v_evidence_ok AND coalesce((v_scope->>'derivative')::boolean,false);
  f_ai    := v_evidence_ok AND coalesce((v_scope->>'ai_input')::boolean,false);
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
      'ai_input',               jsonb_build_object('allowed', (v_owned OR v_supplier_auth OR v_ai_ref OR f_ai),
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED'
                      WHEN v_supplier_auth OR v_ai_ref THEN 'AUTHORISED_SUPPLIER_REFERENCE'
                      WHEN f_ai THEN 'PER_IMAGE_EVIDENCE' ELSE 'NO_AUTHORISATION' END),
      'video_production',       jsonb_build_object('allowed', (v_owned OR f_vid),
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED' WHEN f_vid THEN 'PER_IMAGE_EVIDENCE' ELSE 'NO_AUTHORISATION' END),
      'subscriber_export',      jsonb_build_object('allowed', v_owned,
        'basis', CASE WHEN v_owned THEN 'OWNED_OR_LICENSED' ELSE 'RESTRICTED_RESEARCH_NEVER_EXPORTABLE' END)
    ),
    'rules', jsonb_build_array(
      'A research/marketplace image or a provider-global permission is NEVER upgraded to commercial asset rights.',
      'Commercial uses require per-image authoritative evidence (unrevoked, unexpired) OR an owned/licensed/authorised-upload asset.',
      'Customer download and subscriber export are permitted only for owned/licensed/uploaded assets; never third-party supplier/marketplace imagery.',
      'Revoked evidence is ignored; expired scope voids commercial grants; tenant isolation enforced.'),
    'contract','pulse_asset_use_eligibility_v1');
END; $function$;

-- ============================================================================
-- CS.02 — high-quality media discovery, started from VERIFIED IDENTITY (never the marketplace research image).
-- Reuses the authoritative candidate set and attaches per-candidate identity-match, resolution, permitted_use
-- (via CS.03) and freshness. Research/marketplace images are excluded as creative candidates.
-- A successful media match is NOT proof of commercial eligibility.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_media_discovery(
  p_product_id uuid,
  p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_owner uuid; v_identity jsonb; v_auth jsonb;
  v_candidates jsonb := '[]'::jsonb; v_excluded int := 0; e jsonb; r record; v_elig jsonb; v_res text;
  v_verdict text; v_has_sup boolean; v_sup_pid text;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF p_product_id IS NULL THEN RETURN jsonb_build_object('status','invalid_args'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_owner <> v_uid THEN RETURN jsonb_build_object('status','cross_tenant_rejected'); END IF;

  v_identity := public.fn_product_supplier_identity(p_product_id);
  v_has_sup := coalesce((v_identity->>'has_supplier')::boolean,false);
  v_sup_pid := v_identity->>'supplier_product_id';
  v_auth := public.fn_ad_product_card_authority(v_uid, p_product_id, p_market);

  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(v_auth->'authoritative_assets','[]'::jsonb))
  LOOP
    SELECT image_url, source_provider, source_entity_id, rights_state, provenance, observed_at
      INTO r FROM public.product_image_assets WHERE id = (e->>'id')::uuid LIMIT 1;

    v_res := coalesce(nullif(coalesce(r.provenance,'{}'::jsonb)->>'width',''),'?')
          || 'x' || coalesce(nullif(coalesce(r.provenance,'{}'::jsonb)->>'height',''),'?');
    IF v_res = '?x?' THEN v_res := 'UNKNOWN'; END IF;

    v_verdict := CASE
      WHEN upper(coalesce(e->>'origin',''))='CUSTOMER_OWNED' THEN 'OWNER_SUPPLIED'
      WHEN v_has_sup AND e->>'source_item_id' = v_sup_pid THEN 'EXACT_SUPPLIER_IDENTITY'
      ELSE 'AMBIGUOUS_REJECTED' END;

    -- Only exact-identity or owner-supplied candidates are actionable; ambiguous substitutions are rejected.
    IF v_verdict = 'AMBIGUOUS_REJECTED' THEN CONTINUE; END IF;

    v_elig := public.fn_asset_use_eligibility(p_product_id, p_market,
       e->>'rights_state', e->>'source_provider', e->>'source_item_id', e->>'url',
       coalesce(r.provenance,'{}'::jsonb));

    v_candidates := v_candidates || jsonb_build_object(
      'asset_id', e->>'id', 'url', e->>'url',
      'source', e->>'source_provider', 'origin', e->>'origin',
      'is_primary', coalesce((e->>'is_primary')::boolean,false),
      'identity_match', jsonb_build_object('verdict', v_verdict,
        'verified_supplier_product_id', v_sup_pid, 'candidate_source_item_id', e->>'source_item_id'),
      'resolution', v_res,
      'freshness', r.observed_at,
      'rights_evidence_level', v_elig->>'evidence_level',
      'permitted_use', v_elig->'uses');
  END LOOP;

  SELECT count(*) INTO v_excluded FROM public.product_image_assets
   WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false
     AND public.fn_asset_rights_class(rights_state, source_provider, coalesce(provenance,'{}'::jsonb)) = 'RESEARCH_REFERENCE_ONLY';

  RETURN jsonb_build_object(
    'status','ok','product_id',p_product_id::text,'market',upper(coalesce(p_market,'')),
    'started_from','VERIFIED_PRODUCT_IDENTITY',
    'verified_identity', jsonb_build_object('has_supplier',v_has_sup,
       'provider', v_identity->>'provider', 'supplier_product_id', v_sup_pid),
    'candidate_count', jsonb_array_length(v_candidates),
    'candidates', v_candidates,
    'excluded_research_reference_images', v_excluded,
    'fallback_sources', jsonb_build_array(
       'MERCHANT_UPLOAD (pulse-product-imports, rights_confirmed)','FIRST_PARTY_OWNED originals'),
    'notes', jsonb_build_array(
      'Discovery starts from the product''s verified identity, never from a marketplace research image.',
      'Marketplace/discovery research images are excluded as creative candidates (research display only).',
      'A successful media match is NOT proof of commercial eligibility — see each candidate''s permitted_use.',
      'Ambiguous or different-product substitutions are rejected (not returned as candidates).'),
    'contract','pulse_product_media_discovery_v1');
END; $function$;
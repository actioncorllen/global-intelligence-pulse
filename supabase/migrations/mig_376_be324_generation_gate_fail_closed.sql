-- mig_376 — BE324 rights-safety hotfix: FAIL-CLOSED generation authorisation (production-wired gates).
-- POLICY (founder, BE323/BE324): CJ supplier photographs are NOT authorised generative-AI references merely
-- because supplier product-DATA analysis is permitted. Image-analysis, research-display, source availability,
-- ownership assertions and Product Asset Lock identity validation are INDEPENDENT of generative-AI-input rights.
-- Generative input is permitted only when the exact image carries authoritative AI-use permission, or belongs
-- to a genuinely eligible owned / licensed / authorised merchant-upload lane.
--
-- Two production-wired generation entry points are corrected (surgically, additively):
--   (1) fn_product_commercial_asset_readiness  — the Gemini guard (commercial-image-generate edge,
--        fn_generate_storefront_runtime). ONLY the ai_generation.reference_eligible / execution_state /
--        reference_basis / requires fields change. commercial_asset_readiness, commercial_testability,
--        publishable_asset_path, images, rights, supplier_match and every other field are UNCHANGED, so the
--        workspace readiness badge and storefront publish path are not affected.
--   (2) fn_media_image_execution_context — the OpenAI/Ad-Studio guard (creative-image-execute edge). Adds a
--        single additive check: the source image must carry AI-use permission (owned/licensed), never merely
--        display/research permission.
--
-- NOT APPLIED TO PRODUCTION in this change (founder control: no production migration/deployment). Committed for
-- separate founder deployment approval. Companion to mig_375 (fn_asset_use_eligibility ai_input fail-closed).

-- ============================================================================
-- (1) Gemini guard — fail closed.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_commercial_asset_readiness(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_sup jsonb; v_resolve jsonb; v_state text; v_provider text;
  v_has_supplier_authorized boolean := false; v_has_customer_owned boolean := false;
  v_has_marketplace boolean := false; v_total_images int := 0;
  v_readiness text; v_path text; v_basis text; v_gemini_eligible boolean;
  v_provider_connected boolean; v_exec_state text; v_validated_generated int := 0;
  v_has_supplier boolean; v_resolve_available boolean; v_usable_reference boolean;
  v_rights jsonb; v_testability text; v_ref_basis text;
  v_has_ai_authorised_owned_asset boolean := false;  -- BE324
  v_has_ai_evidence boolean := false;                -- BE324
BEGIN
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  SELECT
    count(*),
    coalesce(bool_or(rights_state='SUPPLIER_PROVIDED'), false),
    coalesce(bool_or(rights_state='CUSTOMER_OWNED' AND source_provider='CUSTOMER_UPLOAD'
            AND coalesce(provenance->>'rights_confirmed','false')='true'), false),
    coalesce(bool_or(rights_state='MARKETPLACE_PUBLIC_LISTING'), false)
  INTO v_total_images, v_has_supplier_authorized, v_has_customer_owned, v_has_marketplace
  FROM public.product_image_assets
  WHERE product_id = p_product_id AND coalesce(is_fixture,false)=false;

  -- BE324: assets on this product that carry genuine AI-use authorisation (owned/licensed/first-party, or an
  -- explicit AUTHORIZED_FOR_AI_REFERENCE flag). Mere SUPPLIER_PROVIDED/MARKETPLACE presence does NOT qualify.
  SELECT coalesce(bool_or(
      upper(coalesce(rights_state,'')) IN ('FIRST_PARTY_OWNED','EXPLICITLY_LICENSED','LICENSED','OWNED')
      OR coalesce(provenance->>'ai_reference_only','false')='true'), false)
  INTO v_has_ai_authorised_owned_asset
  FROM public.product_image_assets
  WHERE product_id = p_product_id AND coalesce(is_fixture,false)=false;

  v_sup := public.fn_product_supplier_identity(p_product_id);
  v_provider := v_sup->>'provider';
  v_has_supplier := coalesce((v_sup->>'has_supplier')::boolean, false);
  IF v_has_supplier THEN
    v_resolve := public.fn_resolve_storefront_assets(v_provider, v_sup->>'supplier_product_id', p_market);
    v_state := v_resolve->>'state';
  END IF;
  v_resolve_available := coalesce(v_state = 'ASSETS_AVAILABLE', false);
  v_rights := public.fn_product_commercial_rights(p_product_id);
  v_usable_reference := v_has_customer_owned OR v_has_supplier_authorized OR v_resolve_available;

  -- BE324: explicit, unrevoked, unexpired per-image AI-INPUT permission for this product's exact supplier item.
  v_has_ai_evidence := (v_sup->>'supplier_product_id') IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.commerce_supplier_image_rights r
    WHERE r.revoked_at IS NULL
      AND coalesce((r.permission_scope->>'ai_input')::boolean,false)=true
      AND coalesce((r.permission_scope->>'expires_at')::timestamptz, 'infinity'::timestamptz) > now()
      AND r.supplier_product_id = (v_sup->>'supplier_product_id'));

  v_provider_connected := coalesce((public.fn_commercial_image_provider_status()->>'connected')::boolean, false);
  SELECT count(*) INTO v_validated_generated FROM public.commerce_generated_assets
   WHERE product_id = p_product_id AND identity_validation_status='IDENTITY_VALIDATED';

  -- UNCHANGED: readiness label / publishable path / testability (drive the workspace badge + storefront publish).
  IF v_resolve_available OR v_has_customer_owned THEN
    v_readiness := 'READY';
    v_path := CASE WHEN v_has_customer_owned AND NOT v_resolve_available THEN 'CUSTOMER_OWNED_ASSET'
                   ELSE 'SUPPLIER_AUTHORIZED_COMMERCIAL_ASSET' END;
    v_basis := CASE WHEN v_has_customer_owned AND NOT v_resolve_available
                 THEN 'A rights-confirmed customer-owned product image is available.'
                 ELSE 'Connected supplier provides a rights-cleared product image for this exact supplier product.' END;
  ELSIF v_has_supplier_authorized THEN
    v_readiness := 'GENERATABLE_FROM_AUTHORIZED_REFERENCE'; v_path := 'SUPPLIER_AUTHORIZED_REFERENCE';
    v_basis := 'An authorized supplier reference exists; a commercial image can be generated from it (identity-validated) rather than republishing a marketplace image.';
  ELSIF v_has_supplier THEN
    v_readiness := 'SUPPLIER_ASSET_REQUIRED'; v_path := 'SUPPLIER_ASSET_RECOVERY';
    v_basis := 'The product is matched to a connected supplier, but a supplier-authorized commercial asset has not yet been obtained. Supplier asset recovery is required before generation or publication.';
  ELSIF v_has_marketplace THEN
    v_readiness := 'CUSTOMER_ASSET_REQUIRED'; v_path := 'NONE';
    v_basis := 'Only marketplace/reference imagery is available. Image access is not republishing rights, so a customer-owned or supplier-authorized image is required to publish.';
  ELSIF v_total_images = 0 THEN
    v_readiness := 'UNAVAILABLE'; v_path := 'NONE';
    v_basis := 'No product imagery has been observed for this product.';
  ELSE
    v_readiness := 'UNKNOWN'; v_path := 'NONE';
    v_basis := 'Product imagery exists but its commercial rights/provenance could not be determined reliably. Rights verification is required before publication.';
  END IF;

  -- BE324 FAIL-CLOSED: generative-AI eligibility requires genuine AI-use permission, NOT mere supplier
  -- availability / research-display / data-analysis. Supplier availability no longer grants AI eligibility.
  v_gemini_eligible := v_has_customer_owned OR v_has_ai_authorised_owned_asset OR v_has_ai_evidence;
  v_ref_basis := CASE
    WHEN v_has_customer_owned THEN 'CUSTOMER_OWNED_UPLOAD'
    WHEN v_has_ai_authorised_owned_asset THEN 'OWNED_LICENSED_OR_AI_REFERENCE_AUTHORISED'
    WHEN v_has_ai_evidence THEN 'PER_IMAGE_AI_INPUT_EVIDENCE'
    ELSE 'NONE' END;

  v_exec_state := CASE
    WHEN NOT v_gemini_eligible THEN 'NOT_ELIGIBLE'
    WHEN v_provider_connected THEN 'AVAILABLE'
    ELSE 'BLOCKED_EXTERNAL_CONNECTION' END;

  v_testability := CASE v_readiness
    WHEN 'READY' THEN 'READY_TO_TEST'
    WHEN 'GENERATABLE_FROM_AUTHORIZED_REFERENCE' THEN 'ASSET_GENERATION_AVAILABLE'
    WHEN 'SUPPLIER_ASSET_REQUIRED' THEN 'ASSET_RECOVERY_REQUIRED'
    WHEN 'CUSTOMER_ASSET_REQUIRED' THEN 'CUSTOMER_ACTION_REQUIRED'
    ELSE 'NOT_CURRENTLY_LAUNCHABLE' END;

  RETURN jsonb_build_object(
    'status','ok','product_id', p_product_id, 'market', upper(coalesce(p_market,'')),
    'checked_at', now(),
    'commercial_asset_readiness', v_readiness,
    'commercial_testability', v_testability,
    'publishable_asset_path', v_path, 'basis', v_basis,
    'has_supplier_match', v_has_supplier,
    'supplier_provider', v_provider, 'supplier_product_id', v_sup->>'supplier_product_id',
    'supplier_resolution_state', coalesce(v_state,'NOT_RESOLVED'),
    'supplier_match', jsonb_build_object(
      'matched', v_has_supplier,
      'confidence', CASE WHEN v_has_supplier THEN 'EXACT' ELSE 'NO_MATCH' END,
      'provider', v_provider, 'supplier_product_id', v_sup->>'supplier_product_id',
      'basis', CASE WHEN v_has_supplier THEN 'Explicit stored supplier link (exact product/SKU).'
                    ELSE 'No connected-supplier product match established.' END),
    'rights', v_rights,
    'validated_generated_assets', v_validated_generated,
    'images', jsonb_build_object('total', v_total_images,
      'has_supplier_authorized', v_has_supplier_authorized,
      'has_customer_owned', v_has_customer_owned,
      'has_marketplace_reference', v_has_marketplace,
      'has_ai_authorised_asset', v_has_ai_authorised_owned_asset,
      'has_per_image_ai_input_evidence', v_has_ai_evidence),
    'ai_generation', jsonb_build_object(
      'reference_eligible', v_gemini_eligible,
      'reference_basis', v_ref_basis,
      'provider','GOOGLE_GEMINI', 'provider_connected', v_provider_connected,
      'execution_state', v_exec_state,
      'requires', CASE
        WHEN v_exec_state='AVAILABLE'
          THEN 'Ready: generate from an AI-authorised reference (owned/licensed/authorised-upload, or explicit per-image AI-input permission), then identity-validate before use.'
        WHEN v_exec_state='NOT_ELIGIBLE'
          THEN 'Generative AI input requires the exact image to carry authoritative AI-use permission, or an owned/licensed/authorised merchant-upload asset. Supplier availability, research-display, data-analysis permission and Product Asset Lock do NOT grant AI-generation authorisation; marketplace/competitor imagery is never eligible.'
        ELSE 'Google Gemini image-generation access is not connected.' END,
      'authorisation_policy','FAIL_CLOSED: image-analysis / research-display / source-availability / ownership-assertion / PAL identity validation are INDEPENDENT of generative-AI-input rights (BE324).',
      'product_asset_lock','Generated output must preserve exact product identity/SKU and pass identity validation (IDENTITY_VALIDATED) before it becomes a commercial asset; a materially different SKU is REJECT_GENERATED_ASSET. (PAL is an output-identity check, NOT an input AI-use authorisation.)'),
    'note','Marketplace/reference images are never a publishable or generation-eligible source. Supplier images are not generative-AI inputs without explicit AI-use permission. Rights are never fabricated.');
END; $function$;

-- ============================================================================
-- (2) OpenAI/Ad-Studio guard — fail closed on the source image's AI-use permission.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_media_image_execution_context(p_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  j public.media_image_jobs%rowtype; a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_disp jsonb; v_url text; v_fmt jsonb; v_prompt text; v_size text; v_path text;
  v_product uuid; v_name text; v_claimed boolean;
BEGIN
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('execute',false,'reason','job_not_found'); END IF;
  IF j.status <> 'GENERATING' THEN
    RETURN jsonb_build_object('execute',false,'reason','not_generating','status',j.status);
  END IF;
  UPDATE public.media_image_jobs
     SET provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('executor_claimed_at', now())
   WHERE id=p_job_id AND status='GENERATING' AND (provenance->>'executor_claimed_at') IS NULL
  RETURNING true INTO v_claimed;
  IF NOT coalesce(v_claimed,false) THEN
    RETURN jsonb_build_object('execute',false,'reason','already_claimed');
  END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  v_product := b.product_id;
  v_name := coalesce(nullif(btrim(b.product_name),''), 'the product');
  v_disp := public.fn_product_card_display_image(j.tenant_id, v_product, b.market);
  v_url := v_disp->>'url';
  IF coalesce((v_disp->>'has_image')::boolean,false) = false OR v_url IS NULL OR v_url='' THEN
    UPDATE public.media_image_jobs
       SET status='BLOCKED_EXTERNAL_PROVIDER', error_state='no_product_image', updated_at=now()
     WHERE id=p_job_id;
    RETURN jsonb_build_object('execute',false,'reason','no_product_image');
  END IF;

  -- BE324 FAIL-CLOSED: AI-generation authorisation is INDEPENDENT of display authorisation. The source image
  -- used as a generative reference must carry AI-use permission (owned / first-party / licensed), never merely
  -- display/research permission or supplier/marketplace availability. A third-party supplier or marketplace
  -- image is not an authorised generative input here.
  IF upper(coalesce(v_disp->>'rights_state','')) NOT IN ('CUSTOMER_OWNED','FIRST_PARTY_OWNED','EXPLICITLY_LICENSED','LICENSED','OWNED') THEN
    UPDATE public.media_image_jobs
       SET status='BLOCKED_EXTERNAL_PROVIDER', error_state='ai_input_not_authorised', updated_at=now()
     WHERE id=p_job_id;
    RETURN jsonb_build_object('execute',false,'reason','ai_input_not_authorised',
      'source_rights_state', v_disp->>'rights_state', 'source_provider', v_disp->>'source_provider',
      'note','Display authorisation does not grant generative-AI-input rights; an owned/licensed/authorised-upload image is required.');
  END IF;

  UPDATE public.media_image_jobs
     SET provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object(
           'creative_source', jsonb_build_object(
             'product_card_asset_id', v_disp->>'asset_id',
             'source_provider', v_disp->>'source_provider',
             'rights_state', v_disp->>'rights_state',
             'is_authoritative', coalesce((v_disp->>'is_authoritative')::boolean,false),
             'basis','exact Product Card display image (fn_product_card_display_image); AI-use permission verified (BE324)'))
   WHERE id=p_job_id;
  v_fmt := j.provenance->'creative_format';
  v_prompt := left(concat_ws(' ',
    coalesce(v_fmt->>'prompt_template', a.static_creative_brief, a.visual_concept, 'Premium commercial advertising product photo.'),
    'PRODUCT IDENTITY LOCK: the exact product (' || v_name || ') shown in the provided image must be preserved with identical shape, geometry, proportions, colours, materials, buttons, controls, visible components, branding and logo. Do NOT substitute, redraw, restyle, recolour or invent any product feature, and do NOT replace it with a similar item.',
    'The model may build background, layout zones, surfaces, lighting and supporting graphic shapes around the product.',
    'Do NOT render any text, words, letters, numbers, logos, price tags, badges, stickers, watermarks, UI overlays, captions, people or hands (advertising text is added deterministically afterward).'
  ), 3200);
  v_size := CASE coalesce(j.aspect_ratio,'1:1')
              WHEN '9:16' THEN '1024x1536' WHEN '4:5'  THEN '1024x1536'
              WHEN '16:9' THEN '1536x1024' ELSE '1024x1024' END;
  v_path := j.tenant_id::text || '/' || coalesce(v_product::text,'noproduct') || '/' || p_job_id::text
            || '/' || gen_random_uuid()::text || '.png';
  RETURN jsonb_build_object(
    'execute', true, 'job_id', p_job_id, 'tenant_id', j.tenant_id, 'product_id', v_product,
    'market', b.market, 'source_image_url', v_url, 'prompt', v_prompt, 'size', v_size,
    'storage_path', v_path, 'model', 'gpt-image-1', 'aspect_ratio', coalesce(j.aspect_ratio,'1:1'),
    'source_asset_id', v_disp->>'asset_id',
    'source_is_authoritative', coalesce((v_disp->>'is_authoritative')::boolean,false),
    'source_rights_state', v_disp->>'rights_state',
    'source_provider', v_disp->>'source_provider',
    'creative_format', v_fmt->>'format');
END; $function$;
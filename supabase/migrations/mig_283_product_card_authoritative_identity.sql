-- ============================================================================
-- mig_283_product_card_authoritative_identity.sql
-- STRATELOQ-015K.1 — PRODUCT CARD ASSET IDENTITY LOCK (permanent, all creative types).
-- Governed by docs/STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md (LOCKED).
--
-- Permanent rule: PRODUCT_CARD_ASSET_IS_AUTHORITATIVE = TRUE.
-- For CUSTOMER creatives the advertised product PIXELS must originate from the
-- workspace Product Card image asset(s). An image/video model may generate the
-- BACKGROUND/ENVIRONMENT around the product, but MUST NOT invent, redraw,
-- approximate or substitute the product itself (shape, controls, buttons, ports,
-- materials, logo, colour, dimensions, accessories, packaging, features, SKU).
--
-- Consequence: a full-frame AI redraw (gpt-image-1 IMAGE_EDIT_FROM_PRODUCT_ASSET /
-- TEXT_TO_IMAGE and equivalent video redraws) can alter the product and is
-- therefore NOT product-identity-preserving for customer product creatives. The
-- identity-safe route is: authoritative Product Card product layer + separately
-- generated/deterministic background + deterministic composition + deterministic
-- copy/CTA.
--
-- New permanent gates: PRODUCT_CARD_SOURCE_VERIFIED, PRODUCT_IDENTITY_PRESERVED.
-- A customer creative can NEVER become launch-safe unless both = PASS (in addition
-- to canonical lineage + identity cleared + Product Decision + human approval).
-- Strateloq's OWN marketing has an analogous rule: authoritative = real
-- screenshots / UI recordings / logo / approved brand assets (never fake regenerated UI).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Permanent, machine-readable identity policy (LOCKED).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_creative_identity_policy()
 RETURNS jsonb LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
  SELECT jsonb_build_object(
    'contract','product_card_authoritative_identity_v1',
    'PRODUCT_CARD_ASSET_IS_AUTHORITATIVE', true,
    'applies_to', jsonb_build_array('STATIC','CAROUSEL','VIDEO','PRODUCT_DEMO','STORY','REEL','TIKTOK','META','FUTURE_FORMATS'),
    'customer_product_rule','The advertised product pixels MUST come from the workspace Product Card image asset(s). Never generate/hallucinate/recreate/approximate/substitute the product from name, description, prompt, category, competitor image, similar SKU, marketplace search or AI interpretation.',
    'background_rule','AI MAY generate room/environment/atmosphere/lighting/decorative context. AI MUST NOT invent or regenerate the product itself. If background generation needs a product-free canvas, generate the background separately and composite the authoritative Product Card product onto it.',
    'identity_preserving_modes', jsonb_build_array('REAL_PRODUCT_LAYER_COMPOSITE'),
    'identity_unsafe_modes', jsonb_build_array('IMAGE_EDIT_FROM_PRODUCT_ASSET','TEXT_TO_IMAGE','VIDEO_IMAGE_TO_VIDEO_REDRAW','FULL_FRAME_AI_REDRAW'),
    'gallery_rule','Only images whose (source_provider, source_item_id) equal the Product Card identity are authoritative. Never pull visually-similar / marketplace-reference products to obtain more images.',
    'launch_rule','launch_safe is impossible unless PRODUCT_CARD_SOURCE_VERIFIED=PASS AND PRODUCT_IDENTITY_PRESERVED=PASS, in addition to CANONICAL lineage + IDENTITY_CLEARED + Product Decision + human approval.',
    'strateloq_brand_exception','For Strateloq''s own marketing, authoritative sources are real Strateloq screenshots / UI recordings / logo / approved brand assets; never regenerate fake UI when real assets exist.',
    'text_rule','Critical ad text (headline/CTA/price/claims) must be composited deterministically, never generated inside the image/video model.',
    'locked', true);
$fn$;

-- ---------------------------------------------------------------------------
-- 1. Authoritative Product Card image asset(s) for a canonical product.
--    Enforces the gallery identity rule (source_provider + source_item_id).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_product_card_authority(p_tenant uuid, p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_owner uuid; v_card_provider text; v_card_item text; v_auth jsonb; v_ref jsonb; v_primary jsonb;
BEGIN
  IF p_product_id IS NULL THEN RETURN jsonb_build_object('status','no_product'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('status','cross_tenant_rejected'); END IF;

  -- Product Card identity from the canonical product's supplier linkage
  SELECT upper(coalesce(extended->'supplier_ref'->>'provider', '')),
         coalesce(extended->'supplier_ref'->>'source_product_id', extended->>'cj_source_product_id')
    INTO v_card_provider, v_card_item
  FROM public.commerce_products WHERE id=p_product_id;
  -- normalize CJ -> CJ_SUPPLIER for image-asset provider comparison
  v_card_provider := CASE WHEN v_card_provider IN ('CJ','CJ_SUPPLIER') THEN 'CJ_SUPPLIER' ELSE v_card_provider END;

  -- authoritative = supplier-provided images of THIS product that match the card provider+item identity.
  -- product images are keyed by product_id (product ownership already enforced above);
  -- tenant_id on the image row may be NULL, so do NOT filter on it.
  SELECT jsonb_agg(x.j ORDER BY (x.j->>'is_primary')::boolean DESC, x.j->>'id')
  INTO v_auth
  FROM (
    SELECT jsonb_build_object('id',id::text,'url',image_url,'source_provider',source_provider,
             'source_item_id',source_entity_id,'is_primary',coalesce(is_primary,false),'rights_state',rights_state) AS j
    FROM public.product_image_assets
    WHERE product_id=p_product_id
      AND coalesce(is_fixture,false)=false
      AND rights_state='SUPPLIER_PROVIDED'
      AND source_provider = v_card_provider
      AND (v_card_item IS NULL OR source_entity_id = v_card_item)
  ) x;

  v_primary := (SELECT e FROM jsonb_array_elements(coalesce(v_auth,'[]'::jsonb)) e WHERE (e->>'is_primary')::boolean LIMIT 1);
  IF v_primary IS NULL THEN v_primary := (coalesce(v_auth,'[]'::jsonb)->0); END IF;

  RETURN jsonb_build_object('status','ok','product_id',p_product_id::text,
    'card_identity', jsonb_build_object('source_provider',v_card_provider,'source_item_id',v_card_item),
    'authoritative_assets', coalesce(v_auth,'[]'::jsonb),
    'authoritative_count', jsonb_array_length(coalesce(v_auth,'[]'::jsonb)),
    'primary_asset', v_primary,
    'note','Only these Product Card asset(s) may originate the advertised product pixels. Marketplace-reference (e.g. eBay) images are NOT authoritative product sources for customer creatives.');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 2. PRODUCT_CARD_SOURCE_VERIFIED — the generated/composed asset's source must
--    resolve to an authoritative Product Card asset of its canonical product.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_product_card_source_verified(p_asset_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE m public.media_assets%rowtype; v_auth jsonb; v_ids text[]; v_urls text[]; v_ref jsonb; v_ok boolean := false; v_match text;
BEGIN
  SELECT * INTO m FROM public.media_assets WHERE id=p_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('state','FAIL','reason','asset_not_found'); END IF;
  IF m.product_id IS NULL OR m.lineage_state <> 'CANONICAL' THEN
    RETURN jsonb_build_object('state','FAIL','reason','no_canonical_product_lineage');
  END IF;
  v_auth := public.fn_ad_product_card_authority(m.tenant_id, m.product_id, m.country_code);
  SELECT array_agg(e->>'id'), array_agg(e->>'url')
    INTO v_ids, v_urls
  FROM jsonb_array_elements(coalesce(v_auth->'authoritative_assets','[]'::jsonb)) e;

  IF v_ids IS NULL THEN
    RETURN jsonb_build_object('state','FAIL','reason','no_authoritative_product_card_asset');
  END IF;

  FOR v_ref IN SELECT * FROM jsonb_array_elements(coalesce(m.source_asset_refs,'[]'::jsonb)) LOOP
    IF (v_ref->>'product_image_asset_id') = ANY(v_ids)
       OR (v_ref->>'url') = ANY(v_urls) THEN
      v_ok := true; v_match := coalesce(v_ref->>'product_image_asset_id', v_ref->>'url'); EXIT;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('state', CASE WHEN v_ok THEN 'PASS' ELSE 'FAIL' END,
    'reason', CASE WHEN v_ok THEN 'source_is_authoritative_product_card_asset' ELSE 'source_not_traced_to_product_card_asset' END,
    'matched_source', v_match, 'card_identity', v_auth->'card_identity');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 3. PRODUCT_IDENTITY_PRESERVED — the actual product pixels must be preserved.
--    Full-frame AI redraw modes can alter the product -> not preserved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_product_identity_preserved(p_asset_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE m public.media_assets%rowtype; v_mode text; v_layer text; v_unsafe text[]; v_safe text[];
BEGIN
  SELECT * INTO m FROM public.media_assets WHERE id=p_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('state','FAIL','reason','asset_not_found'); END IF;
  v_mode := upper(coalesce(m.generation_mode, m.provenance->>'generation_mode',''));
  v_layer := m.provenance->>'product_layer_source';   -- set only by identity-safe composite route
  v_unsafe := ARRAY['IMAGE_EDIT_FROM_PRODUCT_ASSET','TEXT_TO_IMAGE','VIDEO_IMAGE_TO_VIDEO_REDRAW','FULL_FRAME_AI_REDRAW'];
  v_safe := ARRAY['REAL_PRODUCT_LAYER_COMPOSITE'];

  -- non-generated authoritative source images (not AI creatives) are trivially preserved
  IF m.source_type IN ('SUPPLIER_AUTHORIZED') THEN
    RETURN jsonb_build_object('state','PASS','reason','authoritative_non_generated_source','mode',v_mode);
  END IF;

  IF v_mode = ANY(v_unsafe) THEN
    RETURN jsonb_build_object('state','FAIL','mode',v_mode,
      'reason','full_frame_ai_redraw_can_alter_product; product pixels are AI-generated, not authoritative Product Card pixels');
  ELSIF v_mode = ANY(v_safe) THEN
    IF v_layer IS NOT NULL THEN
      RETURN jsonb_build_object('state','PASS','mode',v_mode,'product_layer_source',v_layer,
        'reason','real_product_card_pixels_composited (human review still required for overall creative)');
    ELSE
      RETURN jsonb_build_object('state','REVIEW_REQUIRED','mode',v_mode,
        'reason','composite mode but product_layer_source not recorded');
    END IF;
  END IF;
  RETURN jsonb_build_object('state','REVIEW_REQUIRED','mode',v_mode,'reason','generation_mode_unclassified');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 4. Mandated identity-safe production route (all creative types).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_product_card_safe_route(p_tenant uuid, p_product_id uuid, p_market text, p_creative_type text DEFAULT 'STATIC')
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_auth jsonb; v_ct text;
BEGIN
  v_ct := upper(coalesce(p_creative_type,'STATIC'));
  v_auth := public.fn_ad_product_card_authority(p_tenant, p_product_id, p_market);
  IF (v_auth->>'status') <> 'ok' OR coalesce((v_auth->>'authoritative_count')::int,0)=0 THEN
    RETURN jsonb_build_object('status','blocked','reason','no_authoritative_product_card_asset','authority',v_auth);
  END IF;
  RETURN jsonb_build_object('status','ok','creative_type',v_ct,'renderer','STRATELOQ_CREATIVE_STUDIO',
    'product_layer', jsonb_build_object('source','authoritative Product Card asset (exact pixels)','asset',v_auth->'primary_asset',
       'treatment','extract/mask if needed; product pixels are PROTECTED and never redrawn'),
    'background', jsonb_build_object('allowed', jsonb_build_array('AI_GENERATED_PRODUCT_FREE','DETERMINISTIC'),
       'rule','environment generated/placed AROUND the product; product-free canvas if AI-generated, then composite the real product onto it'),
    'composition','deterministic composite of protected product layer + background + shadow/lighting treatment',
    'text','deterministic headline + CTA + brand DNA where applicable (never generated inside the image/video model)',
    'video_addendum', CASE WHEN v_ct IN ('VIDEO','REEL','TIKTOK','STORY','PRODUCT_DEMO')
       THEN 'motion/scene generated AROUND the protected product layer; the product identity is preserved frame-to-frame; a video model must never replace the Product Card product with its own interpretation'
       ELSE NULL END,
    'gates','PRODUCT_CARD_SOURCE_VERIFIED + PRODUCT_IDENTITY_PRESERVED must PASS; launch-safe also needs canonical lineage + identity cleared + Product Decision + human approval',
    'policy', public.fn_ad_creative_identity_policy());
END; $fn$;

-- ---------------------------------------------------------------------------
-- 5. Extend the Creative Quality Reviewer with the two new gates (IMAGE_ASSET).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_creative_quality_review(p_kind text, p_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE g jsonb; m public.media_assets%rowtype; v_gates jsonb; v_any_fail boolean;
  v_src jsonb; v_pres jsonb;
BEGIN
  IF p_kind='VIDEO_JOB' THEN
    g := public.fn_media_quality_gates(p_id);
    IF (g->>'status') <> 'ok' THEN RETURN g; END IF;
    v_gates := g->'gates'; v_any_fail := (g->>'any_fail')::boolean;
  ELSIF p_kind='IMAGE_ASSET' THEN
    SELECT * INTO m FROM public.media_assets WHERE id=p_id AND media_type='IMAGE';
    IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
    v_src := public.fn_media_product_card_source_verified(p_id);
    v_pres := public.fn_media_product_identity_preserved(p_id);
    v_gates := jsonb_build_object(
      'PRODUCT_CARD_SOURCE_VERIFIED', v_src->>'state',
      'PRODUCT_IDENTITY_PRESERVED', v_pres->>'state',
      'PRODUCT_IDENTITY', CASE WHEN m.identity_state='IDENTITY_CLEARED' THEN 'PASS' ELSE 'REVIEW_REQUIRED' END,
      'CLAIM_SAFETY', 'REVIEW_REQUIRED',
      'PLATFORM_FORMAT', CASE WHEN coalesce(m.aspect_ratio,'')<>'' THEN 'PASS' ELSE 'NOT_EVALUATED' END,
      'BRAND_COMPLIANCE', CASE WHEN EXISTS(SELECT 1 FROM public.member_business_dna d WHERE d.user_id=m.tenant_id) THEN 'REVIEW_REQUIRED' ELSE 'NOT_APPLICABLE' END,
      'VISUAL_QUALITY','REVIEW_REQUIRED','AI_ARTIFACTS','REVIEW_REQUIRED','COMPOSITION','REVIEW_REQUIRED',
      'PRODUCT_VISIBILITY','REVIEW_REQUIRED','COMMERCIAL_USEFULNESS','REVIEW_REQUIRED');
    v_any_fail := EXISTS(SELECT 1 FROM jsonb_each_text(v_gates) x WHERE x.value='FAIL');
  ELSE
    RETURN jsonb_build_object('status','invalid_kind','note','p_kind must be VIDEO_JOB or IMAGE_ASSET');
  END IF;
  RETURN jsonb_build_object('status','ok','kind',p_kind,'id',p_id,'gates',v_gates,
    'machine_gates_any_fail', v_any_fail,
    'product_card_source', v_src, 'product_identity_preserved', v_pres,
    'aesthetic_pending', (SELECT count(*) FROM jsonb_each_text(v_gates) x WHERE x.value='REVIEW_REQUIRED'),
    'human_approval_required', true, 'launch_safe', false,
    'note','A rendered/generated asset is NOT a PASS on success. PRODUCT_CARD_SOURCE_VERIFIED and PRODUCT_IDENTITY_PRESERVED must PASS for a customer creative to be launch-eligible; a full-frame AI redraw of the product fails identity preservation. Aesthetic gates stay REVIEW_REQUIRED until a legitimate evaluator exists.');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 6. Launch eligibility now also requires the two identity gates for generated
--    customer creatives.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_launch_eligibility(p_asset_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE m public.media_assets%rowtype; v_dec_exists boolean; v_src jsonb; v_pres jsonb;
BEGIN
  SELECT * INTO m FROM public.media_assets WHERE id=p_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('eligible',false,'reason','not_found'); END IF;
  IF m.lineage_state <> 'CANONICAL' THEN
    RETURN jsonb_build_object('eligible',false,'reason','CANONICAL_PRODUCT_LINEAGE_REQUIRED','lineage_state',m.lineage_state);
  END IF;
  IF m.identity_state <> 'IDENTITY_CLEARED' THEN
    RETURN jsonb_build_object('eligible',false,'reason','IDENTITY_REVIEW_REQUIRED','identity_state',m.identity_state);
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.product_opportunity_decisions d
    WHERE d.product_id=m.product_id AND d.tenant_id=m.tenant_id
      AND upper(d.country_code)=upper(coalesce(m.country_code,'')) AND coalesce(d.is_fixture,false)=false)
    INTO v_dec_exists;
  IF NOT v_dec_exists THEN
    RETURN jsonb_build_object('eligible',false,'reason','PRODUCT_DECISION_REQUIRED');
  END IF;
  -- FINAL barrier: product-card identity gates for generated/composed customer creatives.
  IF m.source_type IN ('PULSE_GENERATED_IMAGE','PULSE_COMPOSED_IMAGE','PULSE_GENERATED_VIDEO') THEN
    v_src := public.fn_media_product_card_source_verified(p_asset_id);
    v_pres := public.fn_media_product_identity_preserved(p_asset_id);
    IF (v_src->>'state') <> 'PASS' THEN
      RETURN jsonb_build_object('eligible',false,'reason','PRODUCT_CARD_SOURCE_NOT_VERIFIED','detail',v_src);
    END IF;
    IF (v_pres->>'state') <> 'PASS' THEN
      RETURN jsonb_build_object('eligible',false,'reason','PRODUCT_IDENTITY_NOT_PRESERVED','detail',v_pres);
    END IF;
  END IF;
  RETURN jsonb_build_object('eligible',true,'reason','canonical_lineage_identity_cleared_decision_present_product_card_verified',
    'lineage_state',m.lineage_state,'identity_state',m.identity_state);
END; $function$;

-- ---------------------------------------------------------------------------
-- 7. Selftest — marker [[pci]] (product-card-identity). Self-cleaning.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_creative_identity_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_pass int:=0; v_fail int:=0; v_checks jsonb:='[]'::jsonb; v_pol jsonb;
  v_auth jsonb; v_prod uuid; v_dec uuid;
BEGIN
  -- policy locked + authoritative for all types
  v_pol := public.fn_ad_creative_identity_policy();
  IF (v_pol->>'PRODUCT_CARD_ASSET_IS_AUTHORITATIVE')='true' AND (v_pol->>'locked')='true'
     AND v_pol->'applies_to' ? 'VIDEO' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('policy_locked_all_types',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('policy_locked_all_types',false); END IF;

  -- authority resolves the exact CJ primary Product Card image for the real nightlight
  v_auth := public.fn_ad_product_card_authority('7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
              'e453eed4-3de4-4ed9-b889-1275c13c0dba'::uuid,'GB');
  IF (v_auth->'primary_asset'->>'id')='7c2f476f-acbe-499b-a015-2422e56daa50'
     AND (v_auth->'card_identity'->>'source_item_id')='2608250310481611400' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('authority_resolves_card_image',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('authority_resolves_card_image',false,'got',v_auth->'primary_asset'); END IF;

  -- redraw mode fails identity preservation
  IF (public.fn_media_product_identity_preserved('4b2ba996-e046-4f95-bdc2-5f3c48be1f0e'::uuid)->>'state')='FAIL' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('redraw_fails_identity',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('redraw_fails_identity',false); END IF;

  -- source verified PASS for the 015K.1 asset (its source WAS the Product Card asset)
  IF (public.fn_media_product_card_source_verified('4b2ba996-e046-4f95-bdc2-5f3c48be1f0e'::uuid)->>'state')='PASS' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('source_verified_pass',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('source_verified_pass',false); END IF;

  -- reviewer surfaces both new gates; redraw asset cannot be launch-eligible
  IF (public.fn_creative_quality_review('IMAGE_ASSET','4b2ba996-e046-4f95-bdc2-5f3c48be1f0e'::uuid)
        ->'gates'->>'PRODUCT_IDENTITY_PRESERVED')='FAIL'
     AND (public.fn_media_launch_eligibility('4b2ba996-e046-4f95-bdc2-5f3c48be1f0e'::uuid)->>'eligible')='false' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('reviewer_and_launch_block_redraw',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('reviewer_and_launch_block_redraw',false); END IF;

  -- safe route returns a composite plan with protected product layer
  IF (public.fn_ad_product_card_safe_route('7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
        'e453eed4-3de4-4ed9-b889-1275c13c0dba'::uuid,'GB','STATIC')->'product_layer'->>'source') LIKE '%Product Card%' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('safe_route_protected_layer',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('safe_route_protected_layer',false); END IF;

  RETURN jsonb_build_object('suite','ad_creative_product_card_identity','pass',v_pass,'fail',v_fail,
    'all_pass',(v_fail=0),'checks',v_checks);
END; $fn$;

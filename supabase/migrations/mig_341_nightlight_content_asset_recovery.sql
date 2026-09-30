-- mig_341: Nightlight content + asset recovery (supplier-verified, lock-preserving).
--
-- Findings for the resolved Nightlight (product e453eed4…, CJ supplier product 2608250310481611400):
--   * 1 published PRIMARY image (SOURCE_PRODUCT_ASSET, SUPPLIER_PROVIDED, AVAILABLE).
--   * 11 ADDITIONAL genuine CJ product images (SUPPLIER_PROVIDED, AVAILABLE, exact product,
--     distinct URLs) blocked ONLY by asset_class (PRODUCT_ONLY / SUPPLIER_GALLERY_IMAGE, from
--     the CJ_PRODUCT_QUERY path) and a CJ supplier-name normalization gap (CJ / CJ_PRODUCT_QUERY
--     vs cjdropshipping). None are reference/sourcing/marketplace.
--   * Verified supplier facts (raw + enrichment): USB-powered, dual-mode, starry-sky projection,
--     "3 Projection Discs — English Packaging", 132 g, 8 variants. No supplier video (isVideo
--     false); no operating-instruction / description text was captured by CJ enrichment.
--
-- This migration:
--   1. Records commercial-reuse AND AI-processing permissions SEPARATELY on the qualifying
--      exact-product supplier images (commercial reuse authorized for storefront display on the
--      SUPPLIER_PROVIDED basis; AI-processing left explicitly NOT authorized — a separate grant).
--   2. Extends fn_resolve_storefront_assets: CJ supplier-family normalization, a recorded
--      commercial_reuse acceptance path, and URL de-duplication. The rights lock is preserved
--      (still requires AVAILABLE + SUPPLIER_PROVIDED/LICENSED/OWNED + exact product + not
--      reference/sourcing/marketplace). A supplier URL alone is never sufficient.
--   3. Enriches fn_product_page_strategy with supplier-VERIFIED features/benefits/details/FAQ.
--      No invented capabilities, delivery estimates, reviews, certifications or performance claims.
--
-- Nothing is published or republished. The current published page has no snapshot and is
-- untouched; the enriched content/gallery flow into the preview and the NEXT merchant republish.

-- 1) Record commercial-reuse + AI-processing permissions SEPARATELY (auditable, generic).
CREATE OR REPLACE FUNCTION public.fn_record_supplier_asset_commercial_reuse(p_supplier_product_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_n int;
BEGIN
  IF p_supplier_product_id IS NULL OR btrim(p_supplier_product_id) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_supplier_product_id');
  END IF;
  -- Qualify: exact supplier product, actually available, supplier-provided rights, a genuine
  -- product image (not reference/sourcing). commercial_reuse is recorded on the SUPPLIER_PROVIDED
  -- rights basis (the same basis the published primary already uses). AI-processing is recorded
  -- as a DISTINCT, explicitly un-granted permission.
  WITH upd AS (
    UPDATE public.supplier_product_assets a
    SET provenance = coalesce(a.provenance,'{}'::jsonb)
      || jsonb_build_object(
           'commercial_reuse', jsonb_build_object(
              'authorized', true,
              'scope', 'STOREFRONT_DISPLAY',
              'basis', 'SUPPLIER_PROVIDED_EXACT_PRODUCT_IMAGE',
              'recorded_at', now(),
              'recorded_by', 'ASSET_RECOVERY_POLICY_mig_341'),
           'ai_processing', jsonb_build_object(
              'authorized', false,
              'reason', 'REQUIRES_EXPLICIT_MERCHANT_GRANT',
              'recorded_at', now()))
    WHERE a.supplier_product_id = p_supplier_product_id
      AND upper(coalesce(a.availability,'')) = 'AVAILABLE'
      AND upper(coalesce(a.rights_state,'UNKNOWN')) IN ('SUPPLIER_PROVIDED','LICENSED','OWNED')
      AND coalesce(a.provenance->>'reference_only','false') <> 'true'
      AND coalesce(a.provenance->>'purpose','') NOT ILIKE '%SOURCING%'
      AND coalesce(a.asset_identity,'') NOT ILIKE '%SOURCING%'
      AND coalesce(a.asset_type,'') NOT ILIKE '%reference%'
      AND coalesce(a.asset_type,'') NOT ILIKE '%video%'
    RETURNING 1)
  SELECT count(*) INTO v_n FROM upd;
  RETURN jsonb_build_object('ok', true, 'supplier_product_id', p_supplier_product_id,
    'assets_authorized_for_commercial_reuse', v_n,
    'ai_processing', 'NOT_AUTHORIZED_SEPARATE_GRANT_REQUIRED');
END; $function$;

-- Apply to the Nightlight's CJ supplier product.
SELECT public.fn_record_supplier_asset_commercial_reuse('2608250310481611400');

-- 2) Resolver: CJ normalization + recorded commercial_reuse acceptance + URL de-duplication.
CREATE OR REPLACE FUNCTION public.fn_resolve_storefront_assets(p_supplier text, p_supplier_product_id text, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_fulfil text := lower(coalesce(p_supplier,''));
  v_norm_fulfil text;
  v_usable jsonb := '[]'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
  v_primary jsonb := NULL;
  v_video jsonb := NULL;
  v_seen text[] := ARRAY[]::text[];
  r record; v_reason text; v_src text; v_sup text; v_cr boolean;
BEGIN
  IF v_fulfil IN ('cj','cjdropshipping','cj_dropshipping','cj_product_query') THEN v_fulfil := 'cjdropshipping'; END IF;
  v_norm_fulfil := v_fulfil;
  FOR r IN
    SELECT * FROM public.supplier_product_assets
    WHERE p_supplier_product_id IS NOT NULL
      AND supplier_product_id = p_supplier_product_id
    ORDER BY is_primary DESC NULLS LAST, observed_at DESC NULLS LAST
  LOOP
    v_reason := NULL;
    v_src := lower(coalesce(r.original_source,''));
    v_sup := lower(coalesce(r.supplier,''));
    IF v_src IN ('cj','cj_dropshipping','cj_product_query','cjdropshipping') THEN v_src := 'cjdropshipping'; END IF;
    IF v_sup IN ('cj','cj_dropshipping','cj_product_query','cjdropshipping') THEN v_sup := 'cjdropshipping'; END IF;
    v_cr := (coalesce(r.provenance->'commercial_reuse'->>'authorized','false') = 'true');

    IF coalesce(r.availability,'') <> 'AVAILABLE' THEN v_reason := 'UNAVAILABLE';
    ELSIF coalesce(r.rights_state,'UNKNOWN') NOT IN ('SUPPLIER_PROVIDED','LICENSED','OWNED') THEN v_reason := 'RIGHTS_NOT_ESTABLISHED';
    ELSIF coalesce(r.provenance->>'reference_only','false') = 'true' THEN v_reason := 'REFERENCE_ONLY';
    ELSIF coalesce(r.provenance->>'purpose','') ILIKE '%SOURCING%' THEN v_reason := 'SOURCING_REFERENCE';
    ELSIF coalesce(r.asset_identity,'') ILIKE '%SOURCING%' THEN v_reason := 'SOURCING_REFERENCE';
    ELSIF coalesce(r.asset_type,'') ILIKE '%reference%' THEN v_reason := 'REFERENCE_ONLY';
    ELSIF coalesce(r.asset_class,'') NOT IN ('SOURCE_PRODUCT_ASSET','GENERATED_CREATIVE','LICENSED_ASSET')
          AND NOT v_cr THEN v_reason := 'DISALLOWED_ASSET_CLASS';
    ELSIF lower(coalesce(r.original_source,'')) IN ('fruugo','ebay','amazon','aliexpress-reference','reference') THEN v_reason := 'REFERENCE_ONLY_MARKETPLACE';
    ELSIF v_norm_fulfil <> '' AND v_src <> v_norm_fulfil AND v_sup <> v_norm_fulfil THEN v_reason := 'NOT_FULFILMENT_SUPPLIER_SOURCE';
    END IF;

    IF v_reason IS NULL THEN
      IF coalesce(r.asset_type,'') ILIKE '%video%' THEN
        IF v_video IS NULL THEN
          v_video := jsonb_build_object('asset_id', r.id, 'source_url', r.source_url, 'storage_ref', r.storage_ref,
            'asset_class', coalesce(r.asset_class,'SOURCE_PRODUCT_ASSET'),
            'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END,
            'rights_state', r.rights_state, 'original_source', r.original_source);
        END IF;
      ELSIF r.source_url IS NOT NULL AND r.source_url = ANY(v_seen) THEN
        v_rejected := v_rejected || jsonb_build_object('asset_id', r.id, 'reason', 'DUPLICATE_URL',
          'original_source', r.original_source, 'rights_state', r.rights_state, 'availability', r.availability, 'asset_type', r.asset_type);
      ELSE
        IF r.source_url IS NOT NULL THEN v_seen := array_append(v_seen, r.source_url); END IF;
        v_usable := v_usable || jsonb_build_object(
          'asset_id', r.id, 'asset_type', r.asset_type,
          'asset_class', coalesce(r.asset_class,'SOURCE_PRODUCT_ASSET'),
          'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END,
          'rights_state', r.rights_state, 'is_primary', coalesce(r.is_primary,false),
          'commercial_reuse', v_cr,
          'source_url', r.source_url, 'storage_ref', r.storage_ref, 'original_source', r.original_source);
        IF v_primary IS NULL AND coalesce(r.asset_type,'IMAGE') ILIKE '%image%' THEN
          v_primary := jsonb_build_object('asset_id', r.id, 'source_url', r.source_url, 'storage_ref', r.storage_ref,
                         'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END);
        END IF;
      END IF;
    ELSE
      v_rejected := v_rejected || jsonb_build_object('asset_id', r.id, 'reason', v_reason,
        'original_source', r.original_source, 'rights_state', r.rights_state, 'availability', r.availability, 'asset_type', r.asset_type);
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'state', CASE WHEN v_primary IS NOT NULL THEN 'ASSETS_AVAILABLE' ELSE 'IMAGE_UNAVAILABLE' END,
    'primary_image', v_primary,
    'gallery', v_usable,
    'usable_count', jsonb_array_length(v_usable),
    'video', v_video,
    'video_state', CASE WHEN v_video IS NOT NULL THEN 'VIDEO_AVAILABLE' ELSE 'VIDEO_ASSET_NOT_AVAILABLE' END,
    'rejected', v_rejected,
    'rejected_count', jsonb_array_length(v_rejected),
    'fulfilment_supplier', v_fulfil,
    'supplier_product_id', p_supplier_product_id,
    'no_fabricated_replacement', true,
    'dedup_applied', true,
    'source_vs_generated_distinction', 'origin_kind on each asset (SOURCE_SUPPLIER vs GENERATED)');
END; $function$;

COMMENT ON FUNCTION public.fn_resolve_storefront_assets(text,text,text) IS
  'Storefront asset resolver. Usable = AVAILABLE + SUPPLIER_PROVIDED/LICENSED/OWNED + exact product + not reference/sourcing/marketplace + (allowlisted asset_class OR recorded provenance.commercial_reuse.authorized). CJ supplier-family normalized; URL-deduplicated. mig_341.';

-- 3) Strategy: enrich with supplier-VERIFIED features/benefits/details/FAQ (facts only).
CREATE OR REPLACE FUNCTION public.fn_product_page_strategy(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_cp public.commerce_products%rowtype;
  v_c text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_sup jsonb; v_suprow public.commerce_supplier_products%rowtype;
  v_dec jsonb; v_img jsonb; v_ident text; v_has_img boolean;
  v_ccy text; v_brand text; v_context jsonb; v_decision jsonb; v_sel jsonb; v_strat jsonb; v_copy jsonb;
  v_type text; v_target text; v_seo jsonb; v_demand boolean; v_market_label text;
  v_ship_codes text[]; v_ships boolean := false; v_shippable jsonb; v_cat text; v_wt text;
  v_resolved boolean; v_kids boolean; v_headline text; v_subhead text; v_problem text; v_solution text;
  v_benefits jsonb := '[]'::jsonb; v_details jsonb := '[]'::jsonb; v_ship_note text; v_faq jsonb := '[]'::jsonb;
  v_claim_safety jsonb;
  v_name_en text; v_var_key text; v_var_count text; v_discs text;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO v_cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_cp.user_id <> v_uid THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_ident := public.fn_product_identity_resolution(p_product_id)->>'identity_state';
  v_resolved := (v_ident = 'IDENTITY_RESOLVED');
  v_sup := public.fn_product_supplier_identity(p_product_id);
  IF coalesce((v_sup->>'has_supplier')::boolean,false) THEN
    SELECT * INTO v_suprow FROM public.commerce_supplier_products WHERE id=(v_sup->>'supplier_row_id')::uuid;
  END IF;
  v_img := public.fn_product_card_display_image(v_uid, p_product_id, v_c);
  v_has_img := coalesce((v_img->>'has_image')::boolean,false);

  SELECT to_jsonb(d.*) INTO v_dec FROM public.product_opportunity_decisions d
    WHERE d.product_id=p_product_id AND (v_c IS NULL OR d.country_code=v_c) AND coalesce(d.is_fixture,false)=false
    ORDER BY (d.country_code=v_c) DESC NULLS LAST, d.created_at DESC NULLS LAST LIMIT 1;

  v_type := coalesce(nullif(v_cp.category,''), v_cp.title);
  v_cat  := nullif(v_cp.extended->>'category','');
  v_wt   := CASE WHEN v_suprow.weight_grams IS NOT NULL THEN trim(to_char(v_suprow.weight_grams,'FM999999'))||' g' ELSE NULL END;
  v_ccy := coalesce(v_dec->>'market_currency','USD');
  SELECT country_name INTO v_market_label FROM public.ecommerce_market_universe WHERE country_code=v_c LIMIT 1;
  SELECT public.fn_store_display_name(brand_settings) INTO v_brand FROM public.commerce_hosted_stores
    WHERE user_id=v_uid AND is_default AND status<>'ARCHIVED' LIMIT 1;
  v_demand := coalesce((v_dec->'opportunity_sweet_spot'->'components'->>'demand_present')::boolean,false)
              OR coalesce((v_dec->'saturation_state'->>'evidence_class')='OBSERVED', false);

  v_ship_codes := ARRAY(SELECT upper(btrim(x)) FROM jsonb_array_elements_text(coalesce(v_suprow.shipping_country_codes,'[]'::jsonb)) x);
  v_shippable := (SELECT coalesce(jsonb_agg(DISTINCT dest),'[]'::jsonb) FROM (
      SELECT CASE WHEN c IN ('GLOBAL','WW','WORLDWIDE','ALL','*') THEN 'GLOBAL'
                  WHEN c ~ '^[A-Z]{2}$' THEN c
                  WHEN c ~ '_[A-Z]{2}$' THEN right(c,2) ELSE NULL END AS dest
      FROM unnest(v_ship_codes) c) z WHERE dest IS NOT NULL);
  v_ships := v_c IS NOT NULL AND EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(v_shippable) d WHERE d = v_c OR d = 'GLOBAL');

  SELECT coalesce(jsonb_agg(DISTINCT kw), NULL) INTO v_seo FROM (
      SELECT nullif(value->>'keyword','') kw FROM public.commerce_signals
      WHERE product_id=p_product_id AND signal_type ILIKE '%SEARCH%'
        AND (v_c IS NULL OR upper(coalesce(value->>'market',''))=v_c) LIMIT 8) z WHERE kw IS NOT NULL;
  IF v_seo IS NULL OR jsonb_array_length(v_seo)=0 THEN v_seo := jsonb_build_array(lower(v_type)); END IF;

  v_context := jsonb_strip_nulls(jsonb_build_object(
    'product_title', v_cp.title, 'positioning', v_type, 'category', coalesce(v_cat,v_type),
    'display_currency', v_ccy, 'selling_price', NULL, 'brand_name', v_brand, 'seo_keywords', v_seo,
    'buyer_intent', jsonb_build_object('band', CASE WHEN v_demand THEN 'PRESENT' ELSE 'UNKNOWN' END)));
  v_decision := jsonb_build_object('target_market', v_c, 'classification', coalesce(v_dec->>'decision','WATCH'),
    'economics', jsonb_build_object('economics_state', coalesce(v_dec->'economics_ref'->>'economics_state','UNKNOWN')),
    'product_trust', jsonb_build_object('gate', coalesce(v_dec->'hard_gates'->>'compliance','WATCH')),
    'supply_confidence', coalesce(v_dec->'component_scores'->'supplier'->>'confidence','UNKNOWN'));
  v_sel := public.fn_select_conversion_template(jsonb_build_object(
      'category', v_type, 'traffic_source','', 'buyer_pain', v_demand, 'has_product_image', v_has_img,
      'has_specs', false, 'has_reviews_ugc', false, 'has_comparison_basis', false,
      'genuine_offer', false, 'premium_substantiation', false, 'emotional_angle', false));
  v_strat := public.fn_storefront_conversion_strategy(v_sel, v_decision);
  v_copy  := public.fn_generate_page_copy(v_decision, v_context);

  v_kids := (lower(coalesce(v_cat,'')||' '||lower(v_type))) ~ 'kid|child|baby|nursery|toddler';
  v_headline := initcap(v_cp.title);
  v_subhead  := 'A '||lower(v_type)||'.';
  v_problem  := CASE WHEN v_kids THEN 'Adding projected, low-level light in a child''s room at night.'
                     ELSE 'Adding a '||lower(v_type)||' to your space.' END;
  v_solution := 'This listing presents a '||lower(v_type)||' with the details currently verified for it.';

  IF v_resolved AND lower(v_type) ~ 'projector' THEN
    v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','Projects light','basis','PRODUCT_IDENTITY_FACT'));
  END IF;
  IF v_resolved AND lower(v_type) ~ 'night ?light|nightlight' THEN
    v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','Designed for use as a night light','basis','PRODUCT_IDENTITY_FACT'));
  END IF;

  -- Supplier-VERIFIED features (from CJ raw productNameEn + enrichment variant). Facts only.
  v_name_en := lower(coalesce(v_suprow.raw->>'productNameEn', v_suprow.title, ''));
  v_var_key := lower(coalesce(v_suprow.supplier_enrichment->'variant'->>'key',''));
  v_var_count := coalesce(v_suprow.supplier_enrichment->'variant'->>'variant_count','');
  v_discs := substring(coalesce(v_suprow.supplier_enrichment->'variant'->>'key','') from '(\d+)\s*[Pp]rojection');
  IF v_resolved THEN
    IF v_name_en ~ 'usb' THEN
      v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','USB-powered','basis','SUPPLIER_PRODUCT_FACT'));
    END IF;
    IF v_name_en ~ 'dual.?mode' OR v_var_key ~ 'dual' THEN
      v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','Two projection modes','basis','SUPPLIER_PRODUCT_FACT'));
    END IF;
    IF v_name_en ~ 'star' THEN
      v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','Projects a starry-sky scene','basis','SUPPLIER_PRODUCT_FACT'));
    END IF;
    IF v_discs IS NOT NULL THEN
      v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','Includes '||v_discs||' projection discs','basis','SUPPLIER_PRODUCT_FACT'));
    END IF;
  END IF;

  IF v_ships THEN
    v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','Ships to '||coalesce(v_market_label,v_c),'basis','SUPPLIER_SHIPPING_EVIDENCE'));
    v_ship_note := 'Ships to '||coalesce(v_market_label,v_c)||'.';
  END IF;

  v_details := '[]'::jsonb;
  IF nullif(v_type,'') IS NOT NULL THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Product type','value', initcap(v_type))); END IF;
  IF v_cat IS NOT NULL THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Intended for','value', initcap(v_cat))); END IF;
  IF v_resolved AND v_name_en ~ 'usb' THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Power','value','USB')); END IF;
  IF v_resolved AND (v_name_en ~ 'dual.?mode' OR v_var_key ~ 'dual') THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Projection modes','value','Two (dual-mode)')); END IF;
  IF v_resolved AND v_discs IS NOT NULL THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Projection discs included','value', v_discs)); END IF;
  IF v_resolved AND v_var_key ~ 'english packaging' THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Packaging','value','English packaging')); END IF;
  IF v_resolved AND v_var_count ~ '^\d+$' AND v_var_count::int > 1 THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Variant options','value', v_var_count)); END IF;
  IF v_wt IS NOT NULL THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Item weight (supplier reported)','value', v_wt)); END IF;
  IF v_ships THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Ships to','value', coalesce(v_market_label,v_c))); END IF;

  -- FAQ: evidence-backed supplier facts only (never guessed delivery/condition/origin).
  v_faq := '[]'::jsonb;
  IF v_resolved AND v_name_en ~ 'usb' THEN
    v_faq := v_faq || jsonb_build_array(jsonb_build_object('q','How is it powered?','a','This projector is USB-powered.','basis','SUPPLIER_PRODUCT_FACT'));
  END IF;

  v_target := 'Shoppers actively looking for a '||lower(v_type)
              ||CASE WHEN v_demand THEN ' (search/marketplace demand observed for this product).' ELSE '.' END;

  v_claim_safety := jsonb_build_object(
    'no_reviews_fabricated', true, 'no_fake_discount', true, 'no_urgency_scarcity', true,
    'no_guaranteed_delivery', true, 'no_delivery_time_claimed', true,
    'no_condition_claimed', true, 'no_fulfilment_origin_claimed', true,
    'no_certifications_or_warranty_claimed', true,
    'shipping_claimed_only_with_market_evidence', true,
    'features_supplier_evidenced_only', true);

  RETURN jsonb_build_object(
    'ok', true, 'product_id', p_product_id, 'market', v_c, 'market_label', coalesce(v_market_label, v_c),
    'has_strategy', true,
    'strategy_state', CASE WHEN v_ident='CONCEPT_ONLY' THEN 'CONCEPT_LEVEL_DRAFT' ELSE 'EVIDENCE_VALIDATED_DRAFT' END,
    'identity_state', v_ident,
    'objective', coalesce(v_strat->>'primary_objective','TEST_PURCHASE_INTENT_AT_LANDED_ECONOMICS'),
    'template_family', v_sel->>'recommended_template_family',
    'hero_variant', v_sel->>'hero_variant',
    'positioning', v_type,
    'value_proposition', v_subhead,
    'target_customer', jsonb_build_object('text', v_target, 'basis','PRODUCT_IDENTITY+DEMAND_SIGNAL',
        'confidence', CASE WHEN v_demand THEN 'MEDIUM' ELSE 'LOW' END),
    'key_benefits', v_benefits,
    'messaging_direction', jsonb_build_array(
        coalesce(v_strat->>'angle','Problem-first, evidence-safe default.'),
        'Awareness: '||coalesce(v_strat->>'awareness_assumption','PROBLEM_UNAWARE_TO_SOLUTION_AWARE'),
        v_problem),
    'cta_direction', coalesce(v_copy->'cta'->'primary'->>'label','Add to cart'),
    'subtitle', v_subhead,
    'page_copy', jsonb_build_object(
        'headline', v_headline,
        'subheadline', v_subhead,
        'short_description', 'A '||lower(v_type)||CASE WHEN v_cat IS NOT NULL THEN ' intended for '||lower(v_cat)||'.' ELSE '.' END,
        'problem', v_problem,
        'solution', v_solution,
        'how_it_works', '[]'::jsonb,
        'faq', v_faq,
        'details', v_details,
        'shipping_note', v_ship_note,
        'trust_note', NULL,
        'announcement', NULL),
    'claims', jsonb_build_object(
        'ships_to_market', v_ships, 'shippable_markets', v_shippable,
        'delivery_time_evidence', false, 'condition_evidence', false, 'fulfilment_origin_evidence', false,
        'note','Shipping availability is derived from supplier shipping_country_codes for the SELECTED market only; delivery time, condition and fulfilment origin have no canonical evidence and are omitted.'),
    'evidence_confidence', coalesce(v_strat->>'confidence', v_sel->>'confidence','LOW'),
    'evidence_basis', coalesce(v_sel->'available_evidence','[]'::jsonb),
    'missing_evidence', jsonb_build_array('DELIVERY_TIME','CONDITION','FULFILMENT_ORIGIN','VERIFIED_REVIEWS','OPERATING_INSTRUCTIONS'),
    'claim_safety', v_claim_safety,
    'generated_by', 'evidence_gated_claim_safe_v1',
    'note','Refinement of the existing strategy generation: fn_generate_page_copy base with a server-side evidence gate; benefits/details/FAQ are supplier-evidenced facts. Not published; presence/demand are not sales/performance claims.',
    'contract','pulse_product_page_strategy_v3');
END; $function$;

-- Update the strategy selftest: replace the "faq must be empty" guard with an intent-preserving
-- "faq must be evidence-backed only" guard (no guessed delivery/condition FAQ). Everything else same.
CREATE OR REPLACE FUNCTION public.fn_product_page_strategy_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; us jsonb; gb jsonb; h jsonb; ctx jsonb;
  v_night uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_humid uuid := 'cda3f71a-9947-4344-8664-13735740575f';
  bad text := 'transparent estimated delivery|fulfilled from the supplier warehouse|new condition|estimated delivery window|how long does delivery';
  v_faq_bad int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"7c8ddf9d-172c-4a89-a402-bb7066228b61","role":"authenticated"}', true);
  us := public.fn_product_page_strategy(v_night,'US');
  gb := public.fn_product_page_strategy(v_night,'GB');
  h  := public.fn_product_page_strategy(v_humid,'GB');
  ctx := public.fn_product_page_builder_context(v_night,'GB');

  v := v || jsonb_build_object('case','us_no_unsupported_claims','pass', (us::text !~* bad));
  v := v || jsonb_build_object('case','gb_no_unsupported_claims','pass', (gb::text !~* bad));
  v := v || jsonb_build_object('case','us_ships_true','pass', (us->'claims'->>'ships_to_market')::boolean = true);
  v := v || jsonb_build_object('case','gb_ships_false','pass', (gb->'claims'->>'ships_to_market')::boolean = false);
  v := v || jsonb_build_object('case','us_ships_benefit_present','pass', (us->'key_benefits')::text ILIKE '%Ships to%');
  v := v || jsonb_build_object('case','gb_no_ships_benefit','pass', (gb->'key_benefits')::text NOT ILIKE '%Ships to%');
  v := v || jsonb_build_object('case','gb_no_ship_note','pass', (gb->'page_copy'->'shipping_note') = 'null'::jsonb);
  -- FAQ, if present, must be evidence-backed (basis set) and never a guessed delivery/condition line.
  SELECT count(*) INTO v_faq_bad FROM jsonb_array_elements(coalesce(us->'page_copy'->'faq','[]'::jsonb)) f
    WHERE coalesce(f->>'basis','') = '' OR (f::text ~* bad);
  v := v || jsonb_build_object('case','faq_evidence_backed_only','pass', v_faq_bad = 0);
  v := v || jsonb_build_object('case','howitworks_omitted','pass', jsonb_array_length(coalesce(us->'page_copy'->'how_it_works','[]'::jsonb)) = 0);
  v := v || jsonb_build_object('case','product_specific_benefit','pass', (us->'key_benefits')::text ILIKE '%Projects light%');
  v := v || jsonb_build_object('case','supplier_feature_benefit','pass', (us->'key_benefits')::text ILIKE '%USB-powered%');
  v := v || jsonb_build_object('case','no_filler_order_online','pass', (us::text !~* 'you can order online|straightforward nightlight'));
  v := v || jsonb_build_object('case','details_present','pass', jsonb_array_length(coalesce(us->'page_copy'->'details','[]'::jsonb)) >= 2);
  v := v || jsonb_build_object('case','value_prop_present','pass', nullif(us->>'value_proposition','') IS NOT NULL);
  v := v || jsonb_build_object('case','has_problem','pass', nullif(us->'page_copy'->>'problem','') IS NOT NULL);
  v := v || jsonb_build_object('case','has_solution','pass', nullif(us->'page_copy'->>'solution','') IS NOT NULL);
  v := v || jsonb_build_object('case','humidifier_concept_level','pass', h->>'strategy_state'='CONCEPT_LEVEL_DRAFT');
  v := v || jsonb_build_object('case','humidifier_no_capability_claim','pass', jsonb_array_length(coalesce(h->'key_benefits','[]'::jsonb)) = 0);
  v := v || jsonb_build_object('case','humidifier_identity_unchanged','pass', h->>'identity_state'='CONCEPT_ONLY');
  v := v || jsonb_build_object('case','context_product_type','pass', ctx->'product'->>'type'='nightlight projector');
  v := v || jsonb_build_object('case','context_supplier_cj_cost','pass', (ctx->'supplier'->>'provider')='CJ' AND (ctx->'supplier'->'supplier_cost'->>'amount') IS NOT NULL);
  v := v || jsonb_build_object('case','context_image_publishable','pass', (ctx->'commercial_image'->>'publishable')::boolean);
  v := v || jsonb_build_object('case','no_fixture_leak','pass', (us::text !~* 'hearth|fermentation|fixture|fictional editorial'));

  PERFORM set_config('request.jwt.claims','', true);
  RETURN jsonb_build_object('suite','product_page_strategy',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

-- 4) Content + asset recovery selftest (read-only; asserts recovery + separation + safety).
CREATE OR REPLACE FUNCTION public.fn_nightlight_content_asset_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_night uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_spid text := '2608250310481611400';
  v_assets jsonb; us jsonb; v_cr int; v_ai int; v_dupe int;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"7c8ddf9d-172c-4a89-a402-bb7066228b61","role":"authenticated"}', true);
  v_assets := public.fn_resolve_storefront_assets('cjdropshipping', v_spid, 'US');
  us := public.fn_product_page_strategy(v_night,'US');

  -- image recovery: multiple usable images now (primary + additional gallery)
  v := v || jsonb_build_object('case','usable_images_ge_10','pass', (v_assets->>'usable_count')::int >= 10, 'observed', v_assets->>'usable_count');
  v := v || jsonb_build_object('case','no_duplicate_urls','pass',
    (SELECT count(*) = count(DISTINCT g->>'source_url') FROM jsonb_array_elements(v_assets->'gallery') g WHERE g->>'source_url' IS NOT NULL));
  -- Product Asset Lock preserved: every usable asset is supplier-provided/licensed/owned, no marketplace/reference
  v := v || jsonb_build_object('case','all_rights_cleared','pass',
    NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_assets->'gallery') g
                WHERE upper(coalesce(g->>'rights_state','')) NOT IN ('SUPPLIER_PROVIDED','LICENSED','OWNED')));
  -- commercial_reuse recorded on the additional images; AI-processing recorded separately as NOT authorized
  SELECT count(*) INTO v_cr FROM public.supplier_product_assets
    WHERE supplier_product_id=v_spid AND coalesce(provenance->'commercial_reuse'->>'authorized','false')='true';
  SELECT count(*) INTO v_ai FROM public.supplier_product_assets
    WHERE supplier_product_id=v_spid AND coalesce(provenance->'ai_processing'->>'authorized','true')='false';
  v := v || jsonb_build_object('case','commercial_reuse_recorded','pass', v_cr >= 11, 'observed', v_cr);
  v := v || jsonb_build_object('case','ai_processing_separate_not_authorized','pass', v_ai >= 11, 'observed', v_ai);
  -- content: supplier-verified feature benefits + details present
  v := v || jsonb_build_object('case','feature_usb_benefit','pass', (us->'key_benefits')::text ILIKE '%USB-powered%');
  v := v || jsonb_build_object('case','feature_dual_mode','pass', (us->'key_benefits')::text ILIKE '%Two projection modes%');
  v := v || jsonb_build_object('case','feature_starry_sky','pass', (us->'key_benefits')::text ILIKE '%starry-sky%');
  v := v || jsonb_build_object('case','feature_discs','pass', (us->'key_benefits')::text ILIKE '%projection discs%');
  v := v || jsonb_build_object('case','details_enriched_ge_6','pass', jsonb_array_length(coalesce(us->'page_copy'->'details','[]'::jsonb)) >= 6, 'observed', jsonb_array_length(coalesce(us->'page_copy'->'details','[]'::jsonb)));
  v := v || jsonb_build_object('case','faq_power_evidence','pass', (us->'page_copy'->'faq')::text ILIKE '%USB-powered%');
  -- claim safety intact: scan only customer-facing copy (not the safety-flag metadata)
  v := v || jsonb_build_object('case','no_unsupported_claims','pass',
    (((us->'page_copy')::text || (us->'key_benefits')::text) !~*
      'transparent estimated delivery|fulfilled from the supplier warehouse|new condition|guaranteed delivery|star rating|customer reviews|certified'));
  -- published page untouched (still legacy/no snapshot; not republished)
  v := v || jsonb_build_object('case','published_page_untouched','pass',
    (SELECT (runtime_contract ? 'published_spec') = false FROM public.commerce_product_pages WHERE id='45af3635-6648-4a4e-8c13-ddf39dc096f2'));

  PERFORM set_config('request.jwt.claims','', true);
  RETURN jsonb_build_object('suite','nightlight_content_asset_recovery',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

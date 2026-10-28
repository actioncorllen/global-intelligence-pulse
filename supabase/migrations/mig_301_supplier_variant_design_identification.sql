-- ============================================================================
-- mig_301_supplier_variant_design_identification.sql
-- STRATELOQ-STAGE4E-SUPPLIER-VARIANT-DESIGN-IDENTIFICATION
--
-- PROBLEM (frontend symptom): the Product Card / supplier-candidate response let the
-- frontend group supplier variants that do not share the discovered design (e.g. old-man
-- face vs animal face). ROOT CAUSE is NOT missing supplier metadata and NOT an overly broad
-- matcher: the per-variant design evidence already exists and is correct.
--   * commerce_cross_supplier_identity.variant_classifications[]: each of the 35 CJ variants
--     carries {vid, sku, key, class, families, corresponds_to_concept}. corresponds_to_concept
--     is already defined (fn_cross_supplier_evidence) as "variant design family intersects the
--     concept's distinguishing character families (concept_character_families)".
--   * commerce_supplier_products.supplier_enrichment->'variant_catalog'[]: the per-variant
--     image (joined by vid/sku), so each variant's OWN image is available.
-- The gap was in the READ CONTRACT: fn_product_supplier_candidate surfaced the raw
-- class/families/corresponds flag but gave the frontend NO evidence-backed design
-- classification, leaving it to trust the bare corresponds_to_concept flag (which the Stage-4E
-- brief forbids as a sole basis) and the full mixed listing gallery (media.gallery_images,
-- all 35 variants' designs) with no curated per-design reference set.
--
-- FIX (minimal, additive, existing-contract-compatible — no matcher redesign, no new tables):
--   1. fn_variant_design_match(class, corresponds, exact_sku_confirmed, row_variant_verified)
--      — a pure, immutable helper encoding the A/B/C/D taxonomy ONCE, from existing fields only:
--        A VERIFIED_EXACT_VARIANT : exact SKU confirmed (via concrete resolution) AND the identity
--                                   layer marks a variant verified. Nothing weaker qualifies.
--        B POTENTIAL_SAME_DESIGN  : the variant's OWN design family matches the concept
--                                   distinguishing character (corresponds_to_concept = true, which
--                                   is the family-intersection evidence, NOT a generic flag);
--                                   exact-SKU verification incomplete.
--        C DIFFERENT_DESIGN       : the variant has a recognised distinct character family
--                                   (class other than MULTIPACK / OTHER_OR_AMBIGUOUS) that does
--                                   not match the concept — an identified different design.
--        D UNVERIFIED             : evidence cannot establish the design relationship
--                                   (MULTIPACK, OTHER_OR_AMBIGUOUS, or no family) — honest
--                                   "insufficient evidence", never guessed into a match.
--   2. fn_product_supplier_candidate (SAME signature) — ADD per-variant design_match,
--      design_match_basis, exact_sku_confirmed, display_recommended; ADD a variant_identification
--      block (counts by class, exact_sku_status, concept_character_families, reference_only rights,
--      and a de-duplicated reference_images set containing ONLY display-recommended (verified/
--      potential) variants with their OWN image). All pre-existing keys are preserved
--      (backward-compatible). media.gallery_images is kept but explicitly annotated
--      gallery_scope=FULL_LISTING_UNFILTERED_MIXED_DESIGNS so the frontend prefers the curated
--      reference_images for design-accurate display.
--   3. fn_cross_supplier_identity_selftest — extend with Stage-4E design-identification cases.
--
-- GUARANTEES (unchanged):
--   * EXACT-SKU MATCHING (mig_295): VERIFIED_EXACT_VARIANT requires the concrete supplier
--     resolution to bind this exact SKU. A design match (B) NEVER satisfies exact-SKU and the
--     Product Card supplier_match stays UNBOUND. This read contract does not touch
--     commerce_concrete_supplier_resolution or the card status.
--   * PRODUCT ASSET LOCK: reference images are read-only projections marked
--     SUPPLIER_PROVIDED_REFERENCE_ONLY / advertising_cleared=false. Nothing here writes to
--     product_image_assets or product_asset_intelligence, so POTENTIAL images cannot become
--     authoritative Product Card imagery or unlock storefront/advertising/publishing.
--   * IMAGE ASSOCIATION: each variant keeps its OWN variant_catalog image (joined strictly by
--     vid/sku), never a different variant's image merely from the shared listing.
--   * TENANT + COUNTRY isolation: unchanged (owner check via auth.uid(); market scoping).
--   * SUPPLIER-NEUTRAL: taxonomy is concept/supplier-agnostic (derives from class + families),
--     no AliExpress or other supplier introduced; CJ remains the current supplier.
-- No paid supplier/image-analysis provider calls are made or added.
-- ============================================================================

-- 1. Pure taxonomy helper (no data access; immutable; off the client execute surface) --------
CREATE OR REPLACE FUNCTION public.fn_variant_design_match(
  p_class text,
  p_corresponds boolean,
  p_exact_sku_confirmed boolean,
  p_row_variant_verified boolean
) RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN coalesce(p_exact_sku_confirmed, false) AND coalesce(p_row_variant_verified, false)
      THEN 'VERIFIED_EXACT_VARIANT'
    WHEN coalesce(p_corresponds, false)
      THEN 'POTENTIAL_SAME_DESIGN'
    WHEN p_class IS NOT NULL AND p_class NOT IN ('MULTIPACK', 'OTHER_OR_AMBIGUOUS')
      THEN 'DIFFERENT_DESIGN'
    ELSE 'UNVERIFIED'
  END;
$function$;

-- Keep the helper off the client execute surface. Supabase default privileges on `public`
-- grant new functions to authenticated/anon directly (not via PUBLIC), so revoke those too.
-- The SECURITY DEFINER resolver calls it as owner, so this does not affect legitimate use.
REVOKE EXECUTE ON FUNCTION public.fn_variant_design_match(text, boolean, boolean, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_variant_design_match(text, boolean, boolean, boolean) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_variant_design_match(text, boolean, boolean, boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fn_variant_design_match(text, boolean, boolean, boolean) TO service_role;

-- 2. Supplier-candidate read contract: add evidence-backed design identification -------------
CREATE OR REPLACE FUNCTION public.fn_product_supplier_candidate(p_tenant uuid, p_product uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_owns boolean; x record;
  v_catalog jsonb; v_gallery jsonb; v_variants jsonb;
  v_concept_char jsonb; v_confirmed_sku text; v_counts jsonb; v_ref_images jsonb;
BEGIN
  IF v_uid IS NULL OR p_product IS NULL THEN
    RETURN jsonb_build_object('present', false, 'status', 'unauthorized');
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product AND user_id=v_uid) INTO v_owns;
  IF NOT v_owns THEN
    RETURN jsonb_build_object('present', false, 'status', 'unauthorized');
  END IF;
  SELECT * INTO x FROM public.commerce_cross_supplier_identity
    WHERE tenant_id=v_uid AND opportunity_product_id=p_product AND market=upper(coalesce(p_market,''))
    ORDER BY CASE identity_tier WHEN 'EXACT_VARIANT_VERIFIED' THEN 0 WHEN 'SAME_PRODUCT_IDENTITY' THEN 1
             WHEN 'SIMILAR_ONLY' THEN 2 ELSE 3 END, updated_at DESC
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('present', false, 'status', 'no_candidate');
  END IF;

  v_concept_char := coalesce(x.evidence->'concept_character_families', '[]'::jsonb);

  -- Exact-SKU confirmation is authoritative ONLY via the concrete supplier resolution — the
  -- same gate as the Product Card CONFIRMED status and mig_295. Design-match evidence never
  -- substitutes for it.
  SELECT r.selected_sku INTO v_confirmed_sku
  FROM public.commerce_concrete_supplier_resolution r
  WHERE r.tenant_id=v_uid AND r.opportunity_product_id=p_product
    AND r.market=upper(coalesce(p_market,'')) AND coalesce(r.is_fixture,false)=false
    AND coalesce(r.bound,false)=true AND r.selected_sku IS NOT NULL
  ORDER BY r.created_at DESC LIMIT 1;

  SELECT supplier_enrichment->'variant_catalog', supplier_enrichment->'images'
    INTO v_catalog, v_gallery
  FROM public.commerce_supplier_products
  WHERE source = x.source AND source_product_id = x.supplier_product_id
  LIMIT 1;

  -- Per-variant objects with design_match computed once per row.
  SELECT coalesce(jsonb_agg(s.obj ORDER BY s.rank, s.key), '[]'::jsonb)
    INTO v_variants
  FROM (
    SELECT
      vc->>'key' AS key,
      CASE d.dm WHEN 'VERIFIED_EXACT_VARIANT' THEN 0 WHEN 'POTENTIAL_SAME_DESIGN' THEN 1
                WHEN 'DIFFERENT_DESIGN' THEN 2 ELSE 3 END AS rank,
      jsonb_build_object(
        'key', vc->>'key',
        'sku', vc->>'sku',
        'vid', vc->>'vid',
        'class', vc->>'class',
        'families', coalesce(vc->'families','[]'::jsonb),
        'corresponds_to_concept', coalesce((vc->>'corresponds_to_concept')::boolean, false),
        'price_usd', nullif(vc->>'price_usd','')::numeric,
        'image', (SELECT e->>'image' FROM jsonb_array_elements(coalesce(v_catalog,'[]'::jsonb)) e
                   WHERE e->>'vid' = vc->>'vid' OR e->>'sku' = vc->>'sku' LIMIT 1),
        'exact_variant_verified', false,
        'exact_sku_confirmed', d.exact_ok,
        'design_match', d.dm,
        'design_match_basis', CASE d.dm
          WHEN 'VERIFIED_EXACT_VARIANT' THEN 'Exact supplier SKU confirmed by concrete resolution and variant verified'
          WHEN 'POTENTIAL_SAME_DESIGN' THEN 'Variant design family matches the concept distinguishing character; exact SKU not verified'
          WHEN 'DIFFERENT_DESIGN'      THEN 'Variant design family identified as a different design from the concept'
          ELSE 'Insufficient evidence to establish the design relationship' END,
        'display_recommended', d.dm IN ('VERIFIED_EXACT_VARIANT','POTENTIAL_SAME_DESIGN'),
        'rights_state', 'SUPPLIER_PROVIDED_REFERENCE_ONLY',
        'advertising_cleared', false
      ) AS obj
    FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc
    CROSS JOIN LATERAL (
      SELECT
        (v_confirmed_sku IS NOT NULL AND vc->>'sku' = v_confirmed_sku) AS exact_ok,
        public.fn_variant_design_match(
          vc->>'class',
          coalesce((vc->>'corresponds_to_concept')::boolean, false),
          (v_confirmed_sku IS NOT NULL AND vc->>'sku' = v_confirmed_sku),
          coalesce(x.variant_verified, false)
        ) AS dm
    ) d
  ) s;

  -- Counts by design_match.
  SELECT jsonb_build_object(
           'verified_exact',        count(*) FILTER (WHERE v->>'design_match'='VERIFIED_EXACT_VARIANT'),
           'potential_same_design', count(*) FILTER (WHERE v->>'design_match'='POTENTIAL_SAME_DESIGN'),
           'different_design',      count(*) FILTER (WHERE v->>'design_match'='DIFFERENT_DESIGN'),
           'unverified',            count(*) FILTER (WHERE v->>'design_match'='UNVERIFIED'),
           'total',                 count(*))
    INTO v_counts
  FROM jsonb_array_elements(v_variants) v;

  -- Curated reference images: display-recommended (verified/potential) variants only, with their
  -- OWN image, de-duplicated. This is the set the frontend should show to avoid mixing designs.
  SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object(
           'vid', v->>'vid', 'sku', v->>'sku', 'class', v->>'class',
           'design_match', v->>'design_match', 'image', v->>'image',
           'rights_state', 'SUPPLIER_PROVIDED_REFERENCE_ONLY')), '[]'::jsonb)
    INTO v_ref_images
  FROM jsonb_array_elements(v_variants) v
  WHERE (v->>'display_recommended')::boolean AND coalesce(v->>'image','') <> '';

  RETURN jsonb_build_object(
    'present', true, 'status', 'ok', 'source', x.source, 'supplier_product_id', x.supplier_product_id,
    'verification_tier', x.identity_tier, 'confidence', x.confidence,
    'product_level_match', x.bound, 'exact_variant_verified', x.variant_verified,
    'corresponding_variant_count', x.corresponding_variant_count, 'total_variant_count', x.total_variant_count,
    'display_label', CASE x.identity_tier
      WHEN 'SAME_PRODUCT_IDENTITY' THEN 'Same product (supplier) — '||x.confidence||' confidence; exact variant unverified'
      WHEN 'EXACT_VARIANT_VERIFIED' THEN 'Exact variant verified (supplier)'
      WHEN 'SIMILAR_ONLY' THEN 'Similar product only — not confirmed same'
      WHEN 'DIFFERENT_PRODUCT' THEN 'Different product'
      ELSE 'Unverified — insufficient evidence' END,
    'variants', v_variants,
    'variant_identification', jsonb_build_object(
      'taxonomy_version', 'STRATELOQ_VARIANT_DESIGN_MATCH_v1',
      'concept_character_families', v_concept_char,
      'exact_sku_status', CASE WHEN v_confirmed_sku IS NOT NULL THEN 'EXACT_SKU_CONFIRMED' ELSE 'EXACT_SKU_UNVERIFIED' END,
      'confirmed_sku', v_confirmed_sku,
      'product_level_identity', x.identity_tier,
      'supplier_match_binding', 'UNBOUND_UNTIL_EXACT_SKU',
      'counts', v_counts,
      'reference_only', true,
      'rights_state', coalesce(x.media->>'rights_state','SUPPLIER_PROVIDED_REFERENCE_ONLY'),
      'advertising_cleared', false,
      'commercial_use', 'NOT_CLEARED_REFERENCE_ONLY',
      'reference_images', v_ref_images,
      'note', 'design_match is evidence-backed from each variant''s own design family vs the concept distinguishing character. POTENTIAL_SAME_DESIGN is reference-only, is NOT exact-SKU verified, and does not unlock storefront/advertising/publishing or authoritative Product Card imagery. VERIFIED_EXACT_VARIANT requires the concrete supplier resolution to bind this exact SKU. Prefer reference_images over media.gallery_images for design-accurate display.'),
    'variant_note', 'Supplier (CJ) variants at SAME_PRODUCT_IDENTITY; corresponds_to_concept marks the Old-Man-Face variants. None is exact-SKU verified; images are reference-only.',
    'media', jsonb_build_object(
      'image_count', coalesce((x.media->>'image_count')::int,0),
      'sample_images', coalesce(x.media->'sample_images','[]'::jsonb),
      'gallery_images', coalesce(v_gallery,'[]'::jsonb),
      'gallery_image_count', jsonb_array_length(coalesce(v_gallery,'[]'::jsonb)),
      'gallery_scope', 'FULL_LISTING_UNFILTERED_MIXED_DESIGNS',
      'rights_state', coalesce(x.media->>'rights_state','SUPPLIER_PROVIDED_REFERENCE_ONLY'),
      'advertising_cleared', false,
      'commercial_use', 'NOT_CLEARED_REFERENCE_ONLY',
      'rights_note', coalesce(x.media->>'rights_note','Reference-only supplier media; not an authorised advertising asset.')),
    'displayed_variant_economics', x.economics,
    'missing_evidence', x.missing_evidence);
END; $function$;

-- 3. Extend the directly-related selftest with Stage-4E design-identification cases ----------
CREATE OR REPLACE FUNCTION public.fn_cross_supplier_identity_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_t uuid; v_ski uuid := '56a6af36-68f7-4138-9d29-941245f266b2';
  v_snow uuid := '873551b0-a0d0-44f6-8792-7b2650d904cd'; v_snow_t uuid;
  v_ski_concept text; v_snow_concept text; v_ci jsonb;
  v_cases jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0; b boolean; r jsonb; e jsonb; dv jsonb;
  -- Stage-4E locals
  v_vc jsonb; v_confirmed text;
  v_a int; v_bc int; v_cc int; v_dc int;
  v_oldman_img text; v_animal_img text;
BEGIN
  SELECT user_id INTO v_t FROM public.commerce_products WHERE id=v_ski;
  SELECT user_id INTO v_snow_t FROM public.commerce_products WHERE id=v_snow;
  IF v_t IS NULL THEN RETURN jsonb_build_object('ok',false,'error','selftest_fixture_missing'); END IF;
  v_ci := public.fn_derive_concrete_product_identity(v_t, v_ski, 'GB')->'concrete_identity';
  v_ski_concept := coalesce(v_ci->>'canonical_name','') || ' ' || coalesce(v_ci->>'concrete_phrase','')
                || ' ' || coalesce((SELECT string_agg(x,' ') FROM jsonb_array_elements_text(coalesce(v_ci->'distinguishing_attributes','[]'::jsonb)) x),'');
  IF v_snow_t IS NOT NULL THEN
    v_ci := public.fn_derive_concrete_product_identity(v_snow_t, v_snow, 'GB')->'concrete_identity';
    v_snow_concept := coalesce(v_ci->>'canonical_name','') || ' ' || coalesce(v_ci->>'concrete_phrase','');
  END IF;

  -- POSITIVE: deployed resolver, read-only on the real product + supplier row
  r := public.fn_resolve_cross_supplier_identity(v_t, v_ski, 'GB','cjdropshipping','2609290358281623700', false);
  b := (r->>'identity_tier'='SAME_PRODUCT_IDENTITY') AND (r->>'bound'='true') AND ((r->>'corresponding_variant_count')::int >= 6);
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','real_skimask_same_product_identity','pass',b,'tier',r->>'identity_tier','corr',r->>'corresponding_variant_count'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  dv := (SELECT v FROM jsonb_array_elements(r->'variant_classifications') v WHERE v->>'sku'='CJMZ320782833GT' LIMIT 1);
  b := (dv->>'class'='ANIMAL_FACE') AND (dv->>'corresponds_to_concept'='false');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','displayed_variant_animal_not_oldman','pass',b,'class',dv->>'class'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- NEGATIVES: inline candidates through the pure engine (no supplier rows touched)
  e := public.fn_cross_supplier_evidence(v_ski_concept, '{"title":"Collagen Hydrating Facial Sheet Mask Skin Care","category":"Skin Care > Face Masks","variant_catalog":[{"vid":"x1","key":"30ml"},{"vid":"x2","key":"50ml"}]}'::jsonb);
  b := (e->>'identity_tier'='DIFFERENT_PRODUCT') AND (e->>'bound'='false');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','skincare_mask_rejected','pass',b,'tier',e->>'identity_tier'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  e := public.fn_cross_supplier_evidence(v_ski_concept, '{"title":"Winter Thermal Windproof Balaclava Ski Mask Neck Warmer","category":"Sports","weight_grams":"55","variant_catalog":[{"vid":"b1","key":"Black"},{"vid":"b2","key":"Grey"},{"vid":"b3","key":"Navy"}]}'::jsonb);
  b := (e->>'identity_tier'='SIMILAR_ONLY') AND (e->>'bound'='false');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','plain_balaclava_similar_only','pass',b,'tier',e->>'identity_tier'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  e := public.fn_cross_supplier_evidence(v_ski_concept, '{"title":"Vintage Ski Resort Tin Sign Wall Art Metal Poster","category":"Home Decor","variant_catalog":[]}'::jsonb);
  b := (e->>'identity_tier'='DIFFERENT_PRODUCT') AND (e->>'bound'='false');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','tin_sign_rejected','pass',b,'tier',e->>'identity_tier'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- CROSS-CONCEPT ISOLATION: snowman concept vs a ski-mask candidate -> not same product
  IF v_snow_concept IS NOT NULL THEN
    e := public.fn_cross_supplier_evidence(v_snow_concept, '{"title":"Realistic Winter Ski Face Mask Balaclava","category":"Sports","variant_catalog":[{"vid":"m1","key":"Whitebeard"}]}'::jsonb);
    b := (e->>'bound'='false') AND (e->>'identity_tier' <> 'SAME_PRODUCT_IDENTITY');
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','cross_concept_isolation','pass',b,'tier',e->>'identity_tier'));
    IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  END IF;

  -- ==== STAGE 4E: evidence-backed per-variant design identification ====

  -- helper unit logic (pure)
  b := public.fn_variant_design_match('OLD_MAN_FACE', true,  false, false) = 'POTENTIAL_SAME_DESIGN'
   AND public.fn_variant_design_match('ANIMAL_FACE',  false, false, false) = 'DIFFERENT_DESIGN'
   AND public.fn_variant_design_match('ELDERLY_FEMALE_FACE', false, false, false) = 'DIFFERENT_DESIGN'
   AND public.fn_variant_design_match('PATTERN',      false, false, false) = 'DIFFERENT_DESIGN'
   AND public.fn_variant_design_match('MULTIPACK',    false, false, false) = 'UNVERIFIED'
   AND public.fn_variant_design_match('OTHER_OR_AMBIGUOUS', false, false, false) = 'UNVERIFIED';
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','design_match_helper_logic','pass',b));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- exact-SKU strictness: potential match never becomes verified-exact without a confirmed SKU
  b := public.fn_variant_design_match('OLD_MAN_FACE', true, false, false) = 'POTENTIAL_SAME_DESIGN'
   AND public.fn_variant_design_match('OLD_MAN_FACE', true, true,  false) = 'POTENTIAL_SAME_DESIGN'  -- sku confirmed but row not verified -> still not exact
   AND public.fn_variant_design_match('OLD_MAN_FACE', true, true,  true)  = 'VERIFIED_EXACT_VARIANT';
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','exact_sku_strict_gate','pass',b));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- real stored classifications (latest cross-supplier identity row for the ski mask / GB)
  SELECT variant_classifications INTO v_vc FROM public.commerce_cross_supplier_identity
    WHERE tenant_id=v_t AND opportunity_product_id=v_ski AND market='GB'
    ORDER BY CASE identity_tier WHEN 'EXACT_VARIANT_VERIFIED' THEN 0 WHEN 'SAME_PRODUCT_IDENTITY' THEN 1
             WHEN 'SIMILAR_ONLY' THEN 2 ELSE 3 END, updated_at DESC
    LIMIT 1;
  SELECT r2.selected_sku INTO v_confirmed FROM public.commerce_concrete_supplier_resolution r2
    WHERE r2.tenant_id=v_t AND r2.opportunity_product_id=v_ski AND r2.market='GB'
      AND coalesce(r2.is_fixture,false)=false AND coalesce(r2.bound,false)=true AND r2.selected_sku IS NOT NULL
    ORDER BY r2.created_at DESC LIMIT 1;
  SELECT count(*) FILTER (WHERE dm='VERIFIED_EXACT_VARIANT'),
         count(*) FILTER (WHERE dm='POTENTIAL_SAME_DESIGN'),
         count(*) FILTER (WHERE dm='DIFFERENT_DESIGN'),
         count(*) FILTER (WHERE dm='UNVERIFIED')
    INTO v_a, v_bc, v_cc, v_dc
  FROM (
    SELECT public.fn_variant_design_match(c->>'class', coalesce((c->>'corresponds_to_concept')::boolean,false),
             (v_confirmed IS NOT NULL AND c->>'sku'=v_confirmed), false) AS dm
    FROM jsonb_array_elements(coalesce(v_vc,'[]'::jsonb)) c
  ) s;

  -- old-man variants supported as POTENTIAL; none verified-exact (exact SKU not confirmed)
  b := (v_bc = 8) AND (v_a = 0) AND (v_confirmed IS NULL);
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','oldman_potential_no_verified_exact','pass',b,
              'potential',v_bc,'verified_exact',v_a));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- non-matching designs excluded from POTENTIAL (animal etc. -> different/unverified)
  b := (v_cc + v_dc = 27) AND (v_bc = 8) AND ((v_a + v_bc + v_cc + v_dc) = jsonb_array_length(coalesce(v_vc,'[]'::jsonb)));
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','nonmatching_designs_excluded','pass',b,
              'different',v_cc,'unverified',v_dc));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- ambiguous / multipack remain UNVERIFIED (insufficient evidence, not guessed)
  b := (v_dc = 6);
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','ambiguous_multipack_unverified','pass',b,'unverified',v_dc));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- image association: an old-man variant's own image differs from an animal variant's image
  SELECT (SELECT e2->>'image' FROM public.commerce_supplier_products sp, jsonb_array_elements(sp.supplier_enrichment->'variant_catalog') e2
            WHERE sp.source='cjdropshipping' AND sp.source_product_id='2609290358281623700'
              AND e2->>'vid' = (SELECT c->>'vid' FROM jsonb_array_elements(v_vc) c WHERE c->>'class'='OLD_MAN_FACE' LIMIT 1) LIMIT 1)
    INTO v_oldman_img;
  SELECT (SELECT e2->>'image' FROM public.commerce_supplier_products sp, jsonb_array_elements(sp.supplier_enrichment->'variant_catalog') e2
            WHERE sp.source='cjdropshipping' AND sp.source_product_id='2609290358281623700'
              AND e2->>'vid' = (SELECT c->>'vid' FROM jsonb_array_elements(v_vc) c WHERE c->>'class'='ANIMAL_FACE' LIMIT 1) LIMIT 1)
    INTO v_animal_img;
  b := coalesce(v_oldman_img,'')<>'' AND coalesce(v_animal_img,'')<>'' AND v_oldman_img <> v_animal_img;
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','variant_image_association_distinct','pass',b));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- reference-only images are NOT promoted into the canonical authoritative gallery
  SELECT NOT EXISTS (
    SELECT 1 FROM public.product_image_assets a
    WHERE a.product_id=v_ski
      AND a.image_url IN (SELECT e2->>'image' FROM public.commerce_supplier_products sp,
                                 jsonb_array_elements(sp.supplier_enrichment->'variant_catalog') e2
                          WHERE sp.source='cjdropshipping' AND sp.source_product_id='2609290358281623700')
  ) INTO b;
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','reference_images_not_promoted_to_canonical','pass',b));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  RETURN jsonb_build_object('ok', v_fail=0, 'passed', v_pass, 'failed', v_fail, 'total', v_pass+v_fail,
    'contract','pulse_cross_supplier_identity_selftest_v3_variant_design','cases', v_cases, 'generated_at', now());
END; $function$;

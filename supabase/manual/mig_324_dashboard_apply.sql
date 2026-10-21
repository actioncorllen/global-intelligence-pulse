-- =====================================================================================================
-- mig_324 — DASHBOARD SQL EDITOR APPLY (manual recovery; MCP write path unavailable)
-- Generated from supabase/migrations/mig_324_cross_supplier_identity_safe_tests_card.sql (identical bodies).
-- Paste this ENTIRE script into the Supabase Dashboard -> SQL Editor and Run. It is ONE transaction:
-- if any statement or either guard fails, the whole thing rolls back and NOTHING is changed.
-- Prerequisite: mig_323 objects must already exist (they do on this project). Idempotent: safe to re-run.
-- Does NOT touch genuine supplier data — the only DELETE matches three exact, non-numeric SELFTEST ids.
-- =====================================================================================================

BEGIN;

-- ---- PRECHECK: required mig_323 dependencies must be present (else abort, change nothing) ------------
DO $pre$
BEGIN
  IF to_regprocedure('public.fn_identity_families(text)') IS NULL
     OR to_regprocedure('public.fn_resolve_cross_supplier_identity(uuid,uuid,text,text,text,boolean)') IS NULL
     OR to_regclass('public.commerce_cross_supplier_identity') IS NULL
     OR to_regclass('public.commerce_supplier_products') IS NULL THEN
    RAISE EXCEPTION 'PRECHECK FAILED: mig_323 dependencies missing. Apply mig_323 first; nothing was changed.';
  END IF;
  RAISE NOTICE 'PRECHECK OK: mig_323 dependencies present.';
END $pre$;

CREATE OR REPLACE FUNCTION public.fn_cross_supplier_evidence(
  p_concept_text text, p_candidate jsonb, p_form_conflict boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_concept_fams text[]; v_cand_fams text[]; v_all_variant_fams text[] := '{}';
  v_char_fams text[] := ARRAY['old_man_face','elderly_female_face','animal_face','pattern_abstract'];
  v_contra_fams text[] := ARRAY['skincare_mask','wall_art_sign'];
  v_concept_char text[]; vrec jsonb; vfams text[]; vclass text; vcorr boolean;
  v_vclass jsonb := '[]'::jsonb; v_corr int := 0; v_total int := 0;
  v_form_ok boolean; v_has_contra boolean; v_novelty boolean := false; v_char_corr boolean;
  v_tier text; v_conf text; v_signals int := 0; v_weight numeric;
BEGIN
  v_concept_fams := public.fn_identity_families(coalesce(p_concept_text,''));
  v_concept_char := ARRAY(SELECT unnest(v_concept_fams) INTERSECT SELECT unnest(v_char_fams));
  v_cand_fams := public.fn_identity_families(coalesce(p_candidate->>'title','') || ' ' || coalesce(p_candidate->>'category',''));
  v_weight := nullif(p_candidate->>'weight_grams','')::numeric;
  FOR vrec IN SELECT * FROM jsonb_array_elements(coalesce(p_candidate->'variant_catalog','[]'::jsonb)) LOOP
    v_total := v_total + 1;
    vfams := public.fn_identity_families(coalesce(vrec->>'key',''));
    v_all_variant_fams := ARRAY(SELECT DISTINCT unnest(v_all_variant_fams || vfams));
    vclass := CASE
      WHEN 'old_man_face' = ANY(vfams) THEN 'OLD_MAN_FACE'
      WHEN 'elderly_female_face' = ANY(vfams) THEN 'ELDERLY_FEMALE_FACE'
      WHEN 'animal_face' = ANY(vfams) THEN 'ANIMAL_FACE'
      WHEN 'pattern_abstract' = ANY(vfams) THEN 'PATTERN'
      WHEN 'multipack' = ANY(vfams) THEN 'MULTIPACK'
      ELSE 'OTHER_OR_AMBIGUOUS' END;
    vcorr := (array_length(v_concept_char,1) > 0 AND (vfams && v_concept_char));
    IF vcorr THEN v_corr := v_corr + 1; END IF;
    v_vclass := v_vclass || jsonb_build_array(jsonb_build_object(
      'vid',vrec->>'vid','sku',vrec->>'sku','key',vrec->>'key','price_usd',vrec->'price_usd',
      'families',to_jsonb(vfams),'class',vclass,'corresponds_to_concept',vcorr));
  END LOOP;
  v_novelty := ('novelty_character' = ANY(v_cand_fams)) OR ('novelty_character' = ANY(v_all_variant_fams));
  v_form_ok := ('headwear_facemask' = ANY(v_concept_fams)) AND ('headwear_facemask' = ANY(v_cand_fams));
  v_has_contra := (v_cand_fams && v_contra_fams) AND NOT ('headwear_facemask' = ANY(v_cand_fams));
  v_char_corr := (array_length(v_concept_char,1) IS NULL)
     OR NOT EXISTS (SELECT 1 FROM unnest(v_concept_char) cf
          WHERE NOT (cf = ANY(v_cand_fams)) AND NOT (cf = ANY(v_all_variant_fams)));
  IF v_has_contra OR p_form_conflict THEN v_tier := 'DIFFERENT_PRODUCT';
  ELSIF NOT v_form_ok THEN
    IF ('headwear_facemask' = ANY(v_concept_fams)) AND (v_cand_fams && v_concept_fams) THEN v_tier := 'SIMILAR_ONLY';
    ELSE v_tier := 'UNVERIFIED'; END IF;
  ELSE
    IF v_char_corr THEN v_tier := 'SAME_PRODUCT_IDENTITY'; ELSE v_tier := 'SIMILAR_ONLY'; END IF;
  END IF;
  IF v_form_ok THEN v_signals := v_signals + 2; END IF;
  IF v_char_corr AND array_length(v_concept_char,1) > 0 THEN v_signals := v_signals + 2; END IF;
  IF v_novelty THEN v_signals := v_signals + 1; END IF;
  IF v_weight IS NOT NULL THEN v_signals := v_signals + 1; END IF;
  v_conf := CASE
    WHEN v_tier = 'SAME_PRODUCT_IDENTITY' AND v_signals >= 4 THEN 'MEDIUM'
    WHEN v_tier = 'SAME_PRODUCT_IDENTITY' THEN 'LOW'
    WHEN v_tier = 'SIMILAR_ONLY' THEN 'LOW' ELSE 'NONE' END;
  RETURN jsonb_build_object(
    'identity_tier', v_tier, 'confidence', v_conf,
    'bound', v_tier IN ('SAME_PRODUCT_IDENTITY','EXACT_VARIANT_VERIFIED'), 'variant_verified', false,
    'product_form_match', v_form_ok, 'concept_corroborated', v_char_corr,
    'corresponding_variant_count', v_corr, 'total_variant_count', v_total,
    'variant_classifications', v_vclass,
    'missing_evidence', '["variant_image_vision_unavailable","no_shared_product_identifier","exact_variant_unverified"]'::jsonb,
    'evidence', jsonb_build_object('method','CROSS_SUPPLIER_COMBINED_EVIDENCE_v1',
      'concept_families',to_jsonb(v_concept_fams),'candidate_families',to_jsonb(v_cand_fams),
      'concept_character_families',to_jsonb(v_concept_char),'variant_families_union',to_jsonb(v_all_variant_fams),
      'novelty_corroborated',v_novelty,'form_conflict',p_form_conflict));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_cross_supplier_evidence(text,jsonb,boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_cross_supplier_evidence(text,jsonb,boolean) TO service_role;

-- =====================================================================================================
-- 2. TRANSACTION-SAFE SELFTEST (writes to NO supplier records)
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_cross_supplier_identity_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_t uuid; v_ski uuid := '56a6af36-68f7-4138-9d29-941245f266b2';
  v_snow uuid := '873551b0-a0d0-44f6-8792-7b2650d904cd'; v_snow_t uuid;
  v_ski_concept text; v_snow_concept text; v_ci jsonb;
  v_cases jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0; b boolean; r jsonb; e jsonb; dv jsonb;
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

  RETURN jsonb_build_object('ok', v_fail=0, 'passed', v_pass, 'failed', v_fail, 'total', v_pass+v_fail,
    'contract','pulse_cross_supplier_identity_selftest_v2_safe','cases', v_cases, 'generated_at', now());
END; $function$;
REVOKE ALL ON FUNCTION public.fn_cross_supplier_identity_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_cross_supplier_identity_selftest() TO service_role;

-- =====================================================================================================
-- 3. CUSTOMER PRODUCT-CARD COMPANION READ (verification + media-rights labelled)
-- =====================================================================================================
-- Tenant isolation: the caller's own tenant is taken from auth.uid() (NOT the p_tenant argument, which is
-- never trusted) and product ownership is verified, mirroring fn_product_media_state. A signed-in user can
-- only ever read their own tenant's candidate; service-role calls with no user context return unauthorized.
CREATE OR REPLACE FUNCTION public.fn_product_supplier_candidate(p_tenant uuid, p_product uuid, p_market text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_owns boolean; x record;
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
    'media', jsonb_build_object(
      'image_count', coalesce((x.media->>'image_count')::int,0),
      'sample_images', coalesce(x.media->'sample_images','[]'::jsonb),
      'rights_state', coalesce(x.media->>'rights_state','SUPPLIER_PROVIDED_REFERENCE_ONLY'),
      'advertising_cleared', false,
      'rights_note', coalesce(x.media->>'rights_note','Reference-only supplier media; not an authorised advertising asset.')),
    'displayed_variant_economics', x.economics,
    'missing_evidence', x.missing_evidence);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_product_supplier_candidate(uuid,uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_supplier_candidate(uuid,uuid,text) TO service_role, authenticated;

-- =====================================================================================================
-- 4. CLEANUP of the three synthetic fixtures (exact ids only; genuine CJ rows untouched)
-- =====================================================================================================
DELETE FROM public.commerce_supplier_products
WHERE source='cjdropshipping'
  AND source_product_id IN ('SELFTEST_SKINCARE','SELFTEST_BALACLAVA','SELFTEST_SIGN')
  AND source_product_id !~ '^[0-9]+$';   -- guard: genuine CJ pids are all-numeric; never match one

-- ---- POSTCHECK: the three functions exist and the synthetic fixtures are gone (else abort) -----------
DO $post$
DECLARE v_fix int;
BEGIN
  IF to_regprocedure('public.fn_cross_supplier_evidence(text,jsonb,boolean)') IS NULL
     OR to_regprocedure('public.fn_cross_supplier_identity_selftest()') IS NULL
     OR to_regprocedure('public.fn_product_supplier_candidate(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'POSTCHECK FAILED: one or more functions were not created; transaction will roll back.';
  END IF;
  SELECT count(*) INTO v_fix FROM public.commerce_supplier_products
    WHERE source_product_id IN ('SELFTEST_SKINCARE','SELFTEST_BALACLAVA','SELFTEST_SIGN');
  IF v_fix <> 0 THEN
    RAISE EXCEPTION 'POSTCHECK FAILED: % synthetic fixture row(s) still present; transaction will roll back.', v_fix;
  END IF;
  RAISE NOTICE 'POSTCHECK OK: 3 functions created; synthetic fixtures removed.';
END $post$;

COMMIT;

-- =====================================================================================================
-- AFTER a successful COMMIT, run these verification queries SEPARATELY (each on its own):
--
--   -- A) Regression suite — expect {"ok":true, "failed":0, ...} (6 cases; or 5 if the snowman fixture product is absent)
--   SELECT public.fn_cross_supplier_identity_selftest();
--
--   -- B) Real ski-mask association — expect SAME_PRODUCT_IDENTITY / MEDIUM / 8 / false
--   SELECT identity_tier, confidence, corresponding_variant_count, total_variant_count, variant_verified
--   FROM public.commerce_cross_supplier_identity
--   WHERE opportunity_product_id='56a6af36-68f7-4138-9d29-941245f266b2'
--     AND supplier_product_id='2609290358281623700';
--
--   -- C) Fixtures removed — expect 0
--   SELECT count(*) FROM public.commerce_supplier_products WHERE source_product_id LIKE 'SELFTEST_%';
--
--   -- NOTE: fn_product_supplier_candidate() enforces auth.uid() isolation, so it returns
--   -- {"present":false,"status":"unauthorized"} when run in the SQL Editor (no signed-in user). That is
--   -- expected; verify its DATA via query (B). It returns the real candidate only when called by the
--   -- signed-in owner through the app / an edge function that forwards the user JWT.
-- =====================================================================================================

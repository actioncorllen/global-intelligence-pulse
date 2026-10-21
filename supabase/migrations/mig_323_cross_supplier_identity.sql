-- mig_323_cross_supplier_identity.sql
-- Stage 4B: cross-supplier product identity. Recognise the SAME underlying product across FastMoss,
-- Kalodata, CJ and future authorised suppliers despite different titles, languages or marketing, using
-- COMBINED evidence (product form, distinguishing character attributes, variant descriptions, multilingual
-- synonyms, physical features). Tiered verdicts (EXACT_VARIANT_VERIFIED / SAME_PRODUCT_IDENTITY /
-- SIMILAR_ONLY / DIFFERENT_PRODUCT / UNVERIFIED) with confidence + provenance; per-variant classification;
-- honest UNVERIFIED with explicit missing evidence. Reuses the existing resolver pieces
-- (fn_derive_concrete_product_identity, fn_market_supplier_match) and supplier records
-- (commerce_supplier_products) — additive, no rebuild, no product duplication.
--
-- The blocker this fixes: the strict exact resolver rejected the genuine CJ ski-mask because the
-- supplier TITLE lacks the FastMoss distinguishing tokens (novelty/old/man); the old-man identity lives
-- in the CJ VARIANT descriptions. This layer evaluates variant-level + synonym evidence and separates
-- product-level identity from exact-variant verification.

-- =====================================================================================================
-- 1. IDENTITY LEXICON (synonym families; multilingual + marketing-agnostic; extensible, reusable)
-- =====================================================================================================
CREATE TABLE IF NOT EXISTS public.commerce_identity_lexicon (
  family text NOT NULL,
  token  text NOT NULL,
  lang   text NOT NULL DEFAULT 'en',
  note   text,
  PRIMARY KEY (family, token)
);
ALTER TABLE public.commerce_identity_lexicon ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commerce_identity_lexicon FROM public, anon, authenticated;

INSERT INTO public.commerce_identity_lexicon (family, token, lang) VALUES
 ('headwear_facemask','balaclava','en'),('headwear_facemask','ski mask','en'),('headwear_facemask','ski face mask','en'),
 ('headwear_facemask','full face mask','en'),('headwear_facemask','full-face','en'),('headwear_facemask','windproof mask','en'),
 ('headwear_facemask','thermal mask','en'),('headwear_facemask','winter mask','en'),('headwear_facemask','headwear','en'),
 ('headwear_facemask','ski hood','en'),('headwear_facemask','sturmhaube','de'),('headwear_facemask','cagoule','fr'),
 ('skincare_mask','sheet mask','en'),('skincare_mask','mud mask','en'),('skincare_mask','smear mask','en'),
 ('skincare_mask','clay mask','en'),('skincare_mask','facial mask','en'),('skincare_mask','collagen','en'),
 ('skincare_mask','mask stick','en'),('skincare_mask','skincare','en'),('skincare_mask','skin care','en'),
 ('wall_art_sign','tin sign','en'),('wall_art_sign','wall art','en'),('wall_art_sign','metal sign','en'),('wall_art_sign','poster','en'),
 ('old_man_face','old man','en'),('old_man_face','oldman','en'),('old_man_face','whitebeard','en'),('old_man_face','beard','en'),
 ('old_man_face','bald','en'),('old_man_face','grandpa','en'),('old_man_face','grandfather','en'),('old_man_face','gentleman','en'),
 ('old_man_face','gentlemen','en'),('old_man_face','mustache','en'),('old_man_face','moustache','en'),('old_man_face','man','en'),
 ('old_man_face','men','en'),('old_man_face','alter mann','de'),('old_man_face','vieil homme','fr'),('old_man_face','opa','de'),
 ('elderly_female_face','old lady','en'),('elderly_female_face','grandma','en'),('elderly_female_face','grandmother','en'),
 ('elderly_female_face','granny','en'),('elderly_female_face','silver haired','en'),('elderly_female_face','lady','en'),
 ('elderly_female_face','woman','en'),('elderly_female_face','oma','de'),('elderly_female_face','vieille femme','fr'),
 ('animal_face','cat','en'),('animal_face','tiger','en'),('animal_face','husky','en'),('animal_face','dog','en'),
 ('animal_face','lion','en'),('animal_face','animal','en'),('animal_face','katze','de'),
 ('pattern_abstract','pattern','en'),('pattern_abstract','print','en'),('pattern_abstract','stripe','en'),('pattern_abstract','abstract','en'),
 ('novelty_character','novelty','en'),('novelty_character','realistic','en'),('novelty_character','funny','en'),
 ('novelty_character','character','en'),('novelty_character','human face','en'),('novelty_character','scary','en'),
 ('novelty_character','cosplay','en'),('novelty_character','halloween','en'),
 ('multipack','combo','en'),('multipack','pack','en'),('multipack','3pcs','en'),('multipack','6pcs','en')
ON CONFLICT (family, token) DO NOTHING;

-- Family matcher: which synonym families appear (word-boundary, case-insensitive) in a text.
CREATE OR REPLACE FUNCTION public.fn_identity_families(p_text text)
 RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT coalesce(array_agg(DISTINCT family ORDER BY family), '{}')
  FROM public.commerce_identity_lexicon
  WHERE p_text IS NOT NULL AND p_text <> ''
    AND lower(p_text) ~ ('\y' || lower(token) || '\y');
$function$;
REVOKE ALL ON FUNCTION public.fn_identity_families(text) FROM public, anon, authenticated;

-- =====================================================================================================
-- 2. CROSS-SUPPLIER IDENTITY RESULT STORE (companion to commerce_concrete_supplier_resolution)
-- =====================================================================================================
CREATE TABLE IF NOT EXISTS public.commerce_cross_supplier_identity (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  opportunity_product_id uuid NOT NULL,
  market text NOT NULL,
  source text NOT NULL,
  supplier_product_id text NOT NULL,
  identity_tier text NOT NULL,          -- EXACT_VARIANT_VERIFIED | SAME_PRODUCT_IDENTITY | SIMILAR_ONLY | DIFFERENT_PRODUCT | UNVERIFIED
  confidence text NOT NULL,             -- HIGH | MEDIUM | LOW | NONE
  bound boolean NOT NULL DEFAULT false, -- product-level association exists
  variant_verified boolean NOT NULL DEFAULT false,
  product_form_match boolean,
  concept_corroborated boolean,
  corresponding_variant_count int,
  total_variant_count int,
  variant_classifications jsonb,
  evidence jsonb,
  media jsonb,
  economics jsonb,
  missing_evidence jsonb,
  provenance jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, opportunity_product_id, market, source, supplier_product_id)
);
ALTER TABLE public.commerce_cross_supplier_identity ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commerce_cross_supplier_identity FROM public, anon, authenticated;

-- =====================================================================================================
-- 2b. CJ PRODUCT MEDIA/DETAIL INGEST RPC (service-role; n8n posts full variant_catalog + images +
--     displayed-variant economics server-side, bypassing MCP statement-size limits). Media is stamped
--     SUPPLIER_PROVIDED_REFERENCE_ONLY — never authorised advertising assets until rights are confirmed.
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_ingest_cj_product_media(p_pid text, p_enrichment jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_n int;
BEGIN
  UPDATE public.commerce_supplier_products
     SET supplier_enrichment = coalesce(supplier_enrichment,'{}'::jsonb) || p_enrichment,
         enrichment_observed_at = now(), last_seen_at = now(),
         image_url = coalesce(nullif(btrim(p_enrichment->>'primary_image'),''), image_url)
   WHERE source='cjdropshipping' AND source_product_id = p_pid;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('status', CASE WHEN v_n>0 THEN 'ok' ELSE 'not_found' END, 'updated', v_n,
    'variant_count', jsonb_array_length(coalesce(p_enrichment->'variant_catalog','[]'::jsonb)),
    'image_count', jsonb_array_length(coalesce(p_enrichment->'images','[]'::jsonb)));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ingest_cj_product_media(text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ingest_cj_product_media(text,jsonb) TO service_role;

-- =====================================================================================================
-- 3. CROSS-SUPPLIER IDENTITY RESOLVER (combined evidence; tiered; per-variant; honest UNVERIFIED)
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_cross_supplier_identity(
  p_tenant uuid, p_product_id uuid, p_market text,
  p_source text DEFAULT 'cjdropshipping', p_supplier_product_id text DEFAULT NULL,
  p_persist boolean DEFAULT true)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_der jsonb; v_spec jsonb; v_ci jsonb; v_concept_text text; v_concept_fams text[];
  strow record; v_cand_fams text[]; v_all_variant_fams text[] := '{}';
  v_char_fams text[] := ARRAY['old_man_face','elderly_female_face','animal_face','pattern_abstract'];
  v_contra_fams text[] := ARRAY['skincare_mask','wall_art_sign'];
  v_concept_char text[]; v_variants jsonb; vrec jsonb; vfams text[]; vclass text; vcorr boolean;
  v_vclass jsonb := '[]'::jsonb; v_corr_count int := 0; v_total int := 0;
  v_form_ok boolean; v_has_contra boolean; v_novelty boolean := false;
  v_char_corroborated boolean; v_msm jsonb; v_form_conflict boolean;
  v_tier text; v_conf text; v_signals int := 0; v_bound boolean; v_missing jsonb := '[]'::jsonb;
  v_media jsonb; v_econ jsonb; v_prov jsonb; v_result jsonb;
BEGIN
  IF p_tenant IS NULL OR p_supplier_product_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','tenant_and_supplier_product_id_required');
  END IF;

  v_der := public.fn_derive_concrete_product_identity(p_tenant, p_product_id, p_market);
  IF coalesce(v_der->>'ok','false') <> 'true' THEN RETURN v_der; END IF;
  v_spec := v_der->'match_spec';
  v_ci := v_der->'concrete_identity';
  v_concept_text := coalesce(v_ci->>'canonical_name','') || ' ' || coalesce(v_ci->>'concrete_phrase','')
                 || ' ' || coalesce((SELECT string_agg(x,' ') FROM jsonb_array_elements_text(coalesce(v_ci->'distinguishing_attributes','[]'::jsonb)) x),'');
  v_concept_fams := public.fn_identity_families(v_concept_text);

  SELECT title, category, supplier_enrichment, weight_grams, supplier_cost, cost_currency, image_url
    INTO strow FROM public.commerce_supplier_products
    WHERE source = p_source AND source_product_id = p_supplier_product_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'error','supplier_row_not_found','source',p_source,'supplier_product_id',p_supplier_product_id);
  END IF;

  v_cand_fams := public.fn_identity_families(coalesce(strow.title,'') || ' ' || coalesce(strow.category,''));
  v_concept_char := ARRAY(SELECT unnest(v_concept_fams) INTERSECT SELECT unnest(v_char_fams));

  -- Per-variant classification over the stored variant catalogue
  v_variants := coalesce(strow.supplier_enrichment->'variant_catalog','[]'::jsonb);
  FOR vrec IN SELECT * FROM jsonb_array_elements(v_variants) LOOP
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
    IF vcorr THEN v_corr_count := v_corr_count + 1; END IF;
    v_vclass := v_vclass || jsonb_build_array(jsonb_build_object(
      'vid',vrec->>'vid','sku',vrec->>'sku','key',vrec->>'key','price_usd',vrec->'price_usd',
      'families',to_jsonb(vfams),'class',vclass,'corresponds_to_concept',vcorr));
  END LOOP;

  v_novelty := ('novelty_character' = ANY(v_cand_fams)) OR ('novelty_character' = ANY(v_all_variant_fams));

  -- product form + contradiction (reuse fn_market_supplier_match for an independent form-conflict signal)
  v_form_ok := ('headwear_facemask' = ANY(v_concept_fams)) AND ('headwear_facemask' = ANY(v_cand_fams));
  v_has_contra := (v_cand_fams && v_contra_fams) AND NOT ('headwear_facemask' = ANY(v_cand_fams));
  v_msm := public.fn_market_supplier_match(v_spec, strow.title, strow.category, p_supplier_product_id, false);
  v_form_conflict := coalesce((v_msm->'evidence'->>'form_conflict')::boolean, false)
                     OR coalesce((v_msm->'evidence'->>'excluded_subtype_hit')::boolean, false);

  -- distinguishing character corroboration: every concept character family present in candidate title or any variant
  v_char_corroborated := (array_length(v_concept_char,1) IS NULL)
     OR NOT EXISTS (
          SELECT 1 FROM unnest(v_concept_char) cf
          WHERE NOT (cf = ANY(v_cand_fams)) AND NOT (cf = ANY(v_all_variant_fams)));

  -- tier
  IF v_has_contra OR v_form_conflict THEN
    v_tier := 'DIFFERENT_PRODUCT';
  ELSIF NOT v_form_ok THEN
    IF ('headwear_facemask' = ANY(v_concept_fams)) AND (v_cand_fams && v_concept_fams) THEN
      v_tier := 'SIMILAR_ONLY';
    ELSE
      v_tier := 'UNVERIFIED';
    END IF;
  ELSE
    IF v_char_corroborated THEN v_tier := 'SAME_PRODUCT_IDENTITY';
    ELSE v_tier := 'SIMILAR_ONLY'; END IF;
  END IF;

  -- confidence (image/vision verification is unavailable here -> capped below HIGH)
  IF v_form_ok THEN v_signals := v_signals + 2; END IF;
  IF v_char_corroborated AND array_length(v_concept_char,1) > 0 THEN v_signals := v_signals + 2; END IF;
  IF v_novelty THEN v_signals := v_signals + 1; END IF;
  IF strow.weight_grams IS NOT NULL THEN v_signals := v_signals + 1; END IF;
  v_conf := CASE
    WHEN v_tier = 'SAME_PRODUCT_IDENTITY' AND v_signals >= 4 THEN 'MEDIUM'
    WHEN v_tier = 'SAME_PRODUCT_IDENTITY' THEN 'LOW'
    WHEN v_tier = 'SIMILAR_ONLY' THEN 'LOW'
    ELSE 'NONE' END;

  v_bound := v_tier IN ('SAME_PRODUCT_IDENTITY','EXACT_VARIANT_VERIFIED');

  -- missing evidence (why not EXACT_VARIANT_VERIFIED / not HIGH)
  v_missing := '["variant_image_vision_unavailable","no_shared_product_identifier","exact_variant_unverified"]'::jsonb;

  v_media := jsonb_build_object(
    'image_count', jsonb_array_length(coalesce(strow.supplier_enrichment->'images','[]'::jsonb)),
    'sample_images', (SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM (SELECT jsonb_array_elements(coalesce(strow.supplier_enrichment->'images','[]'::jsonb)) x LIMIT 6) s),
    'video', strow.supplier_enrichment->'product_video',
    'rights_state', coalesce(strow.supplier_enrichment->>'media_rights','SUPPLIER_PROVIDED_REFERENCE_ONLY'),
    'advertising_cleared', false,
    'rights_note', coalesce(strow.supplier_enrichment->>'media_rights_note','Reference-only supplier media; not authorised advertising assets.'));

  v_econ := coalesce(strow.supplier_enrichment->'displayed_variant_economics','{}'::jsonb);

  v_prov := jsonb_build_object(
    'method','CROSS_SUPPLIER_COMBINED_EVIDENCE_v1',
    'concept_families', to_jsonb(v_concept_fams),
    'candidate_families', to_jsonb(v_cand_fams),
    'concept_character_families', to_jsonb(v_concept_char),
    'variant_families_union', to_jsonb(v_all_variant_fams),
    'market_supplier_match_class', v_msm->>'market_supplier_match',
    'form_conflict', v_form_conflict,
    'novelty_corroborated', v_novelty,
    'claim', CASE v_tier
      WHEN 'SAME_PRODUCT_IDENTITY' THEN 'Same underlying product confirmed at product level by shared product form and corroborated distinguishing character evidence across supplier variants; exact variant not visually verified.'
      WHEN 'EXACT_VARIANT_VERIFIED' THEN 'Specific supplier variant confirmed as the exact product variant.'
      WHEN 'SIMILAR_ONLY' THEN 'Comparable product form but distinguishing identity not corroborated; not treated as the same product.'
      WHEN 'DIFFERENT_PRODUCT' THEN 'Supplier product is a different physical product form; rejected.'
      ELSE 'Insufficient evidence to confirm product identity.' END);

  v_result := jsonb_build_object(
    'ok', true, 'tenant_id', p_tenant, 'opportunity_product_id', p_product_id, 'market', upper(p_market),
    'source', p_source, 'supplier_product_id', p_supplier_product_id,
    'identity_tier', v_tier, 'confidence', v_conf, 'bound', v_bound, 'variant_verified', false,
    'product_form_match', v_form_ok, 'concept_corroborated', v_char_corroborated,
    'corresponding_variant_count', v_corr_count, 'total_variant_count', v_total,
    'variant_classifications', v_vclass, 'evidence', v_prov, 'media', v_media, 'economics', v_econ,
    'missing_evidence', v_missing);

  IF p_persist THEN
    INSERT INTO public.commerce_cross_supplier_identity AS t (
      tenant_id, opportunity_product_id, market, source, supplier_product_id, identity_tier, confidence,
      bound, variant_verified, product_form_match, concept_corroborated, corresponding_variant_count,
      total_variant_count, variant_classifications, evidence, media, economics, missing_evidence, provenance)
    VALUES (p_tenant, p_product_id, upper(p_market), p_source, p_supplier_product_id, v_tier, v_conf,
      v_bound, false, v_form_ok, v_char_corroborated, v_corr_count, v_total, v_vclass, v_prov, v_media,
      v_econ, v_missing, v_prov)
    ON CONFLICT (tenant_id, opportunity_product_id, market, source, supplier_product_id) DO UPDATE SET
      identity_tier=excluded.identity_tier, confidence=excluded.confidence, bound=excluded.bound,
      variant_verified=excluded.variant_verified, product_form_match=excluded.product_form_match,
      concept_corroborated=excluded.concept_corroborated, corresponding_variant_count=excluded.corresponding_variant_count,
      total_variant_count=excluded.total_variant_count, variant_classifications=excluded.variant_classifications,
      evidence=excluded.evidence, media=excluded.media, economics=excluded.economics,
      missing_evidence=excluded.missing_evidence, provenance=excluded.provenance, updated_at=now();
  END IF;

  RETURN v_result;
END; $function$;
REVOKE ALL ON FUNCTION public.fn_resolve_cross_supplier_identity(uuid,uuid,text,text,text,boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_resolve_cross_supplier_identity(uuid,uuid,text,text,text,boolean) TO service_role;

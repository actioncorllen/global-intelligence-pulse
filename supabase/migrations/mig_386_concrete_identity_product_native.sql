-- mig_386 — Concrete product identity from PRODUCT-NATIVE evidence (Stage 2 enabler).
--
-- ROOT CAUSE: fn_derive_concrete_product_identity derived distinguishing attributes ONLY from
-- EBAY_BROWSE marketplace listing titles (>=5 required), so an early product-native (FastMoss/
-- Kalodata/TikTok-Shop) discovery with no eBay footprint could pass Stage 1 yet be structurally
-- incapable of obtaining a concrete identity — it could never reach exact supplier resolution until
-- it matured onto eBay. This conflicts with Strateloq's early-opportunity architecture.
--
-- SMALLEST ADDITIVE FIX (provider-independent; exact matching NOT weakened):
--   * eBay path preserved byte-for-byte and PREFERRED when >=5 marketplace titles exist.
--   * When marketplace evidence is insufficient, derive the concrete identity from the authoritative
--     product-native concise identity phrase (fn_product_search_identity), gated on >=1 persisted
--     COMMERCE_PRODUCT_NATIVE observation for the selected country.
--   * CONCRETENESS requires >=3 distinct meaningful phrase tokens, so a bare generic category/keyword
--     ("night light", "humidifier", "christmas decoration") stays NO_CONCRETE_EVIDENCE.
--   * SAFETY: the product-native spec sets product_noun AND required_attr_all to the full concrete
--     phrase tokens. Because fn_market_supplier_match requires ALL required_attr_all tokens in the
--     supplier title for STRONG_SAME_PRODUCT, a supplier can never qualify on a single shared noun
--     token — keyword overlap can never resolve equivalence. Worst case is NO_VALID_CJ_MATCH, never
--     a fuzzy bind.
--   * PROVENANCE: evidence_sources.primary (EBAY_BROWSE | PRODUCT_NATIVE) + product_native_providers;
--     identity_confidence = SINGLE_AUTHORITATIVE_PRODUCT_OBSERVATION vs MULTI_SOURCE_CORROBORATED_IDENTITY
--     (>=5 eBay titles, or >=2 product-native providers).
--   * Platform product ID proves SOURCE identity only; CJ equivalence is still established separately
--     by the resolver. Metrics/ads/images/search-volume are never read here.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_derive_concrete_product_identity(p_tenant uuid, p_product_id uuid, p_market text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(coalesce(p_market,''));
  cp record; v_total int; v_noun text[]; v_subs text[]; v_attrs text[]; v_excl text[];
  v_dom_form text; v_dom_support numeric; v_state text; v_fp text; v_samples jsonb;
  v_pn_count int; v_pn_providers text[]; v_phrase text; v_pntoks text[];
  v_conf text; v_spec jsonb; v_ident jsonb;
BEGIN
  SELECT title, category, product_identity INTO cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;

  v_noun := ARRAY(SELECT tok FROM unnest(public.fn_text_tokens(lower(cp.title))) tok
                  WHERE tok NOT IN ('cool','mist','warm','ultrasonic','red','light','therapy','led',
                                    'digital','picture','photo','frame') AND length(tok)>2);
  IF cardinality(v_noun)=0 THEN v_noun := public.fn_text_tokens(lower(cp.title)); END IF;

  -- EBAY MARKETPLACE PATH (unchanged)
  WITH t AS (
    SELECT regexp_replace(lower(coalesce(value->>'title','')),'night[ -]?light','nightlight','g') AS ttl
    FROM public.commerce_signals
    WHERE product_id=p_product_id AND signal_type='MARKETPLACE_ACTIVITY'
      AND upper(coalesce(value->>'market',''))=v_mkt AND coalesce(value->>'title','')<>''
  ),
  tot AS (SELECT count(*) AS n FROM t),
  lex(term,kind) AS (VALUES
      ('ultrasonic','form'),('cool mist','form'),('warm mist','altform'),('evaporative','altform'),
      ('rain cloud','altform'),('raindrop','altform'),('flame','altform'),('ufo','altform'),('volcano','altform'),
      ('red light','form'),('infrared','form'),('photon','attr'),('near infrared','attr'),('7 color','attr'),
      ('digital','form'),('wifi','attr'),('touchscreen','attr'),('calendar','attr'),('alarm clock','attr'),('wooden','altform'),
      ('nightlight','attr'),('quiet','attr'),('aromatherapy','attr'),('essential oil','attr'),
      ('bedroom','attr'),('baby','attr'),('portable','attr'),('handheld','altform'),('rechargeable','attr')),
  sup AS (
    SELECT l.term, l.kind,
      round((SELECT count(*) FROM t WHERE position(l.term in t.ttl)>0)::numeric
            / greatest((SELECT n FROM tot),1), 3) AS support
    FROM lex l)
  SELECT
    (SELECT n FROM tot),
    ARRAY(SELECT term FROM sup WHERE kind='form'    AND support>=0.30 ORDER BY support DESC),
    ARRAY(SELECT term FROM sup WHERE kind='attr'    AND support>=0.30 ORDER BY support DESC),
    ARRAY(SELECT term FROM sup WHERE kind='altform' AND support< 0.08 ORDER BY term),
    (SELECT term FROM sup WHERE kind='form' ORDER BY support DESC LIMIT 1),
    (SELECT coalesce(max(support),0) FROM sup WHERE kind='form'),
    (SELECT coalesce(jsonb_agg(x.ttl),'[]'::jsonb) FROM (SELECT ttl FROM t LIMIT 6) x)
  INTO v_total, v_subs, v_attrs, v_excl, v_dom_form, v_dom_support, v_samples;

  -- PRODUCT-NATIVE EVIDENCE (additive; authoritative observed product; provider-independent)
  SELECT count(*) INTO v_pn_count FROM public.commerce_signals
    WHERE product_id=p_product_id AND signal_type='COMMERCE_PRODUCT_NATIVE' AND upper(coalesce(value->>'market',''))=v_mkt;
  SELECT ARRAY(SELECT DISTINCT lower(value->>'source') FROM public.commerce_signals
    WHERE product_id=p_product_id AND signal_type='COMMERCE_PRODUCT_NATIVE' AND upper(coalesce(value->>'market',''))=v_mkt
      AND coalesce(value->>'source','')<>'') INTO v_pn_providers;
  v_phrase := public.fn_product_search_identity(cp.title)->>'search_query';
  v_pntoks := public.fn_text_tokens(lower(coalesce(v_phrase,'')));

  IF v_total >= 5 THEN
    v_state := CASE WHEN coalesce(v_dom_support,0) >= 0.30 OR cardinality(v_subs) >= 1 THEN 'CONCRETE_RESOLVED' ELSE 'CONCRETE_PRODUCT_AMBIGUOUS' END;
    v_conf := 'MULTI_SOURCE_CORROBORATED_IDENTITY';
    v_fp := md5(lower(array_to_string(v_noun,' ')||'|'||array_to_string(coalesce(v_subs,'{}'),',')||'|'||array_to_string(coalesce(v_attrs,'{}'),',')));
    v_spec := jsonb_build_object('product_noun', to_jsonb(v_noun),
      'required_subtype_any', to_jsonb(coalesce(v_subs, ARRAY[]::text[])),
      'required_attr_all', '[]'::jsonb,
      'excluded_subtype', to_jsonb(coalesce(v_excl, ARRAY[]::text[])), 'category', cp.category);
    v_ident := jsonb_build_object('canonical_name', cp.title, 'category', cp.category,
      'subtype', coalesce(v_subs, ARRAY[]::text[]), 'distinguishing_attributes', coalesce(v_attrs, ARRAY[]::text[]),
      'variant_attributes', ARRAY[]::text[],
      'evidence_sources', jsonb_build_object('primary','EBAY_BROWSE','marketplace_listing_titles', v_total,'market',v_mkt,'sample_titles',v_samples,'product_native_observations',v_pn_count,'product_native_providers',to_jsonb(coalesce(v_pn_providers,ARRAY[]::text[]))),
      'identity_confidence', v_conf, 'identity_fingerprint', v_fp);
  ELSIF cardinality(v_pntoks) >= 3 AND coalesce(v_pn_count,0) >= 1 THEN
    v_state := 'CONCRETE_RESOLVED';
    v_conf := CASE WHEN cardinality(coalesce(v_pn_providers,ARRAY[]::text[])) >= 2 THEN 'MULTI_SOURCE_CORROBORATED_IDENTITY' ELSE 'SINGLE_AUTHORITATIVE_PRODUCT_OBSERVATION' END;
    v_fp := md5(lower(coalesce(v_phrase,'')));
    v_spec := jsonb_build_object('product_noun', to_jsonb(v_pntoks),
      'required_subtype_any', '[]'::jsonb,
      'required_attr_all', to_jsonb(v_pntoks),
      'excluded_subtype', '[]'::jsonb, 'category', cp.category);
    v_ident := jsonb_build_object('canonical_name', cp.title, 'category', cp.category,
      'concrete_phrase', v_phrase,
      'subtype', ARRAY[]::text[], 'distinguishing_attributes', to_jsonb(v_pntoks),
      'variant_attributes', ARRAY[]::text[],
      'evidence_sources', jsonb_build_object('primary','PRODUCT_NATIVE','product_native_observations',v_pn_count,'product_native_providers',to_jsonb(coalesce(v_pn_providers,ARRAY[]::text[])),'marketplace_listing_titles', v_total,'market',v_mkt),
      'identity_confidence', v_conf, 'identity_fingerprint', v_fp);
  ELSE
    v_state := 'NO_CONCRETE_EVIDENCE';
    v_conf := 'INSUFFICIENT';
    v_fp := md5(lower(cp.title));
    v_spec := jsonb_build_object('product_noun', to_jsonb(v_noun),
      'required_subtype_any','[]'::jsonb,'required_attr_all','[]'::jsonb,
      'excluded_subtype', to_jsonb(coalesce(v_excl, ARRAY[]::text[])), 'category', cp.category);
    v_ident := jsonb_build_object('canonical_name', cp.title, 'category', cp.category,
      'subtype', ARRAY[]::text[], 'distinguishing_attributes', ARRAY[]::text[], 'variant_attributes', ARRAY[]::text[],
      'evidence_sources', jsonb_build_object('primary',CASE WHEN v_total>0 THEN 'EBAY_BROWSE_PARTIAL' ELSE 'NONE' END,'marketplace_listing_titles', v_total,'product_native_observations',v_pn_count,'market',v_mkt,'sample_titles',v_samples),
      'identity_confidence', v_conf, 'identity_fingerprint', v_fp);
  END IF;

  RETURN jsonb_build_object('ok', true, 'concrete_state', v_state, 'concrete_identity', v_ident, 'match_spec', v_spec);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_derive_concrete_product_identity(uuid, uuid, text) TO authenticated, service_role;

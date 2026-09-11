-- PULSE-ECOM-CJ-CANONICAL-DISCOVERY-001 bugfix.
-- Defect: fn_market_supplier_match tested product_noun / subtype / attrs against
-- (title || category). Category is a taxonomy department path (e.g. "Home, Garden &
-- Furniture"), so a generic department word ("garden") could satisfy the product
-- noun and mis-promote unrelated products (a plant moss pole) to STRONG_SAME_PRODUCT.
-- Fix: the discriminating product noun, required subtype, and required attributes
-- must be found in the SUPPLIER TITLE. Excluded-subtype phrases still scan title +
-- category (so a "Cake Decorating" category still blocks a cake turntable). Match
-- taxonomy unchanged; only the text scope tightens.
CREATE OR REPLACE FUNCTION public.fn_market_supplier_match(
  p_spec jsonb,
  p_sup_title text,
  p_sup_category text,
  p_sup_ref text DEFAULT NULL,
  p_shared_identifier boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE
  traw text; ttoks text[]; fullraw text;
  noun text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'product_noun','[]'::jsonb)) x);
  sub_any text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'required_subtype_any','[]'::jsonb)) x);
  attr_all text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'required_attr_all','[]'::jsonb)) x);
  excl text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'excluded_subtype','[]'::jsonb)) x);
  brand text := lower(coalesce(p_spec->>'brand',''));
  cat text := lower(coalesce(p_spec->>'category',''));
  noun_hit boolean := false; sub_hit boolean; attr_ok boolean; excl_hit boolean := false; brand_hit boolean := false;
  cls text; ph text; a text; missing int := 0;
BEGIN
  IF p_sup_title IS NULL OR length(trim(p_sup_title)) = 0 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','NO_SUPPLIER_TITLE');
  END IF;
  IF cardinality(noun) = 0 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','SPEC_MISSING_PRODUCT_NOUN');
  END IF;

  -- TITLE-scoped normalized text (product identity lives in the title, not the category path)
  traw := lower(p_sup_title);
  traw := regexp_replace(traw, 'night[ -]?light', 'nightlight', 'g');
  traw := regexp_replace(traw, 'projection', 'projector', 'g');
  traw := regexp_replace(traw, 'wi[ -]?fi', 'wifi', 'g');
  ttoks := public.fn_text_tokens(traw);
  -- excluded-subtype scans title + category (a taxonomy word can legitimately exclude)
  fullraw := traw || ' ' || lower(coalesce(p_sup_category,''));

  IF cardinality(ttoks) < 2 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','SUPPLIER_TITLE_TOO_SPARSE');
  END IF;

  noun_hit := (SELECT bool_or(n = ANY(ttoks) OR position(n in traw) > 0) FROM unnest(noun) n);
  IF cardinality(excl) > 0 THEN
    FOREACH ph IN ARRAY excl LOOP IF position(ph in fullraw) > 0 THEN excl_hit := true; END IF; END LOOP;
  END IF;
  sub_hit := (cardinality(sub_any) = 0)
             OR (SELECT bool_or(s = ANY(ttoks) OR position(s in traw) > 0) FROM unnest(sub_any) s);
  IF cardinality(attr_all) = 0 THEN attr_ok := true;
  ELSE
    FOREACH a IN ARRAY attr_all LOOP IF NOT (a = ANY(ttoks) OR position(a in traw) > 0) THEN missing := missing + 1; END IF; END LOOP;
    attr_ok := (missing = 0);
  END IF;
  IF brand <> '' AND position(brand in traw) > 0 THEN brand_hit := true; END IF;

  IF p_shared_identifier THEN
    cls := 'EXACT_CONFIRMED';
  ELSIF NOT noun_hit THEN
    cls := CASE WHEN cat <> '' AND cat = lower(coalesce(p_sup_category,'')) THEN 'CATEGORY_ONLY' ELSE 'UNRELATED' END;
  ELSIF excl_hit THEN
    cls := 'CATEGORY_ONLY';
  ELSIF sub_hit AND attr_ok THEN
    cls := CASE WHEN brand_hit THEN 'EXACT_CONFIRMED' ELSE 'STRONG_SAME_PRODUCT' END;
  ELSE
    cls := 'CLOSE_COMPARABLE';
  END IF;

  RETURN jsonb_build_object(
    'market_supplier_match', cls,
    'reason', CASE cls
        WHEN 'EXACT_CONFIRMED' THEN CASE WHEN p_shared_identifier THEN 'SHARED_PRODUCT_IDENTIFIER' ELSE 'BRAND_PLUS_SUBTYPE_ATTRS' END
        WHEN 'STRONG_SAME_PRODUCT' THEN 'TITLE_PRODUCT_NOUN_PLUS_SUBTYPE_PLUS_ATTRS_NO_EXCLUDED'
        WHEN 'CLOSE_COMPARABLE' THEN 'TITLE_NOUN_MATCH_SUBTYPE_OR_ATTR_UNPROVEN'
        WHEN 'CATEGORY_ONLY' THEN CASE WHEN excl_hit THEN 'EXCLUDED_SUBTYPE_PRESENT' ELSE 'SAME_CATEGORY_DIFFERENT_PRODUCT' END
        ELSE 'NO_PRODUCT_NOUN_MATCH_IN_TITLE' END,
    'evidence', jsonb_build_object(
        'noun_hit', noun_hit, 'subtype_hit', sub_hit, 'attrs_ok', attr_ok,
        'excluded_subtype_hit', excl_hit, 'brand_hit', brand_hit,
        'shared_identifier', p_shared_identifier, 'supplier_ref', p_sup_ref),
    'note','Product noun/subtype/attrs matched against SUPPLIER TITLE only; category path scanned for excluded subtypes. EXACT_CONFIRMED needs shared identifier or brand+subtype+attrs; unbranded same-type match is STRONG_SAME_PRODUCT.');
END; $function$;

COMMENT ON FUNCTION public.fn_market_supplier_match(jsonb,text,text,text,boolean) IS
 'Context A (title-scoped): market<->supplier bridge. Product noun/subtype/attrs from supplier TITLE; excluded subtypes from title+category. STRONG_SAME_PRODUCT for same-type unbranded match; EXACT_CONFIRMED only with shared identifier or brand+subtype+attrs. Never fuzzy-title EXACT.';

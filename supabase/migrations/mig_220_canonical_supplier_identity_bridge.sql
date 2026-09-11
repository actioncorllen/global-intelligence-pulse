-- PULSE-ECOM-CANONICAL-SUPPLIER-IDENTITY-001
-- Two-context identity model. Removes the structural bottleneck that made EXACT
-- unreachable for demand-led sourcing, WITHOUT turning fuzzy title similarity into
-- EXACT. The pre-existing fn_resolve_supplier_identity is left UNCHANGED (still the
-- token-overlap primitive; EXACT there still requires a shared identifier).
--
-- Context B — SUPPLIER CANONICAL IDENTITY: a CJ PID re-confirmed by product/query
--   proves multiple CJ records are the same CJ product -> SUPPLIER_EXACT (for stock,
--   freight, assets, supplier economics of THAT CJ product). It does NOT prove the
--   marketplace concept is the same physical product.
-- Context A — MARKET <-> SUPPLIER IDENTITY: a defensible bridge between a demand
--   concept and a supplier product, using product noun + subtype + required/excluded
--   attributes (+ brand/identifier). Never labels a same-type-but-unbranded match
--   "EXACT".

-- ---------------------------------------------------------------------------
-- B. Supplier canonical identity (CJ PID confirmed by product/query)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_supplier_canonical_identity(
  p_pid text,                 -- CJ pid selected from product/list
  p_query_confirmed_pid text, -- pid returned by a real product/query call
  p_subtype_ok boolean        -- product/query subtype/attributes compatible with intended spec
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE st text; reason text;
BEGIN
  IF p_pid IS NULL OR length(trim(p_pid)) = 0 THEN
    st := 'SUPPLIER_UNCONFIRMED'; reason := 'NO_CJ_PID';
  ELSIF p_query_confirmed_pid IS NULL OR p_query_confirmed_pid <> p_pid THEN
    st := 'SUPPLIER_PID_UNVERIFIED'; reason := 'PRODUCT_QUERY_DID_NOT_CONFIRM_SAME_PID';
  ELSIF p_subtype_ok IS NOT TRUE THEN
    st := 'SUPPLIER_PID_UNVERIFIED'; reason := 'PID_CONFIRMED_BUT_SUBTYPE_INCOMPATIBLE';
  ELSE
    st := 'SUPPLIER_EXACT'; reason := 'CJ_PID_CONFIRMED_BY_PRODUCT_QUERY_AND_SUBTYPE';
  END IF;
  RETURN jsonb_build_object(
    'supplier_identity_state', st,
    'reason', reason,
    'cj_pid', p_pid,
    'query_confirmed_pid', p_query_confirmed_pid,
    'subtype_ok', coalesce(p_subtype_ok,false),
    'note','SUPPLIER_EXACT establishes canonical identity of the CJ product only; it never establishes market identity');
END; $function$;

-- ---------------------------------------------------------------------------
-- A. Market <-> Supplier identity bridge (defensible, conservative)
--   p_spec jsonb keys:
--     product_noun         text[]  REQUIRED  (>=1 discriminating head-noun synonym must appear)
--     required_subtype_any text[]  optional  (if present, >=1 must appear)
--     required_attr_all    text[]  optional  (if present, ALL must appear)
--     excluded_subtype     text[]  optional  (phrase substrings; any present => wrong subtype)
--     brand                text    optional  (if matched, supports EXACT_CONFIRMED)
--     category             text    optional
-- Returns MARKET_SUPPLIER_MATCH_CONFIDENCE in:
--   EXACT_CONFIRMED | STRONG_SAME_PRODUCT | CLOSE_COMPARABLE | CATEGORY_ONLY | UNRELATED | INSUFFICIENT_EVIDENCE
-- ---------------------------------------------------------------------------
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
  sraw text; stoks text[];
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

  sraw := lower(p_sup_title || ' ' || coalesce(p_sup_category,''));
  sraw := regexp_replace(sraw, 'night[ -]?light', 'nightlight', 'g');
  sraw := regexp_replace(sraw, 'projection', 'projector', 'g');
  sraw := regexp_replace(sraw, 'wi[ -]?fi', 'wifi', 'g');
  stoks := public.fn_text_tokens(sraw);

  IF cardinality(stoks) < 2 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','SUPPLIER_TITLE_TOO_SPARSE');
  END IF;

  -- noun hit: any product-noun synonym present as a token OR as a substring phrase
  noun_hit := (SELECT bool_or(n = ANY(stoks) OR position(n in sraw) > 0) FROM unnest(noun) n);
  -- excluded subtype phrase present anywhere
  IF cardinality(excl) > 0 THEN
    FOREACH ph IN ARRAY excl LOOP IF position(ph in sraw) > 0 THEN excl_hit := true; END IF; END LOOP;
  END IF;
  sub_hit := (cardinality(sub_any) = 0)
             OR (SELECT bool_or(s = ANY(stoks) OR position(s in sraw) > 0) FROM unnest(sub_any) s);
  IF cardinality(attr_all) = 0 THEN attr_ok := true;
  ELSE
    FOREACH a IN ARRAY attr_all LOOP IF NOT (a = ANY(stoks) OR position(a in sraw) > 0) THEN missing := missing + 1; END IF; END LOOP;
    attr_ok := (missing = 0);
  END IF;
  IF brand <> '' AND position(brand in sraw) > 0 THEN brand_hit := true; END IF;

  IF p_shared_identifier THEN
    cls := 'EXACT_CONFIRMED';
  ELSIF NOT noun_hit THEN
    cls := CASE WHEN cat <> '' AND cat = lower(coalesce(p_sup_category,'')) THEN 'CATEGORY_ONLY' ELSE 'UNRELATED' END;
  ELSIF excl_hit THEN
    cls := 'CATEGORY_ONLY';                    -- shares noun-space but is an explicitly excluded subtype
  ELSIF sub_hit AND attr_ok THEN
    cls := CASE WHEN brand_hit THEN 'EXACT_CONFIRMED' ELSE 'STRONG_SAME_PRODUCT' END;
  ELSE
    cls := 'CLOSE_COMPARABLE';                 -- right product noun, wrong / unproven subtype or attribute
  END IF;

  RETURN jsonb_build_object(
    'market_supplier_match', cls,
    'reason', CASE cls
        WHEN 'EXACT_CONFIRMED' THEN CASE WHEN p_shared_identifier THEN 'SHARED_PRODUCT_IDENTIFIER' ELSE 'BRAND_PLUS_SUBTYPE_ATTRS' END
        WHEN 'STRONG_SAME_PRODUCT' THEN 'PRODUCT_NOUN_PLUS_SUBTYPE_PLUS_ATTRS_NO_EXCLUDED'
        WHEN 'CLOSE_COMPARABLE' THEN 'NOUN_MATCH_SUBTYPE_OR_ATTR_UNPROVEN'
        WHEN 'CATEGORY_ONLY' THEN CASE WHEN excl_hit THEN 'EXCLUDED_SUBTYPE_PRESENT' ELSE 'SAME_CATEGORY_DIFFERENT_PRODUCT' END
        ELSE 'NO_PRODUCT_NOUN_MATCH' END,
    'evidence', jsonb_build_object(
        'noun_hit', noun_hit, 'subtype_hit', sub_hit, 'attrs_ok', attr_ok,
        'excluded_subtype_hit', excl_hit, 'brand_hit', brand_hit,
        'shared_identifier', p_shared_identifier, 'supplier_ref', p_sup_ref),
    'note','EXACT_CONFIRMED requires a shared identifier or brand+subtype+attrs; a same-type unbranded generic match is STRONG_SAME_PRODUCT, never EXACT');
END; $function$;

-- ---------------------------------------------------------------------------
-- TEST identity gate (combines both contexts). Documented rule:
--   SUPPLIER_EXACT + EXACT_CONFIRMED               -> TEST_IDENTITY_SATISFIED (exact)
--   SUPPLIER_EXACT + STRONG_SAME_PRODUCT + subtype-valid price/demand + no critical risk
--                                                  -> TEST_IDENTITY_SATISFIED (strong, subtype-matched)
--   SUPPLIER_EXACT + STRONG_SAME_PRODUCT but price/demand not subtype-valid, or risk
--                                                  -> WATCH
--   anything weaker, or supplier not canonical     -> REJECT/WATCH
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_test_identity_gate(
  p_supplier_state text,
  p_market_match text,
  p_subtype_price_valid boolean DEFAULT false,
  p_no_critical_risk boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE verdict text; basis text; reason text;
BEGIN
  IF p_supplier_state IS DISTINCT FROM 'SUPPLIER_EXACT' THEN
    verdict := 'REJECT'; basis := 'SUPPLIER_NOT_CANONICAL'; reason := 'CJ product not canonically confirmed (need PID confirmed by product/query)';
  ELSIF p_market_match = 'EXACT_CONFIRMED' THEN
    IF p_no_critical_risk THEN verdict := 'TEST_IDENTITY_SATISFIED'; basis := 'SUPPLIER_EXACT_AND_MARKET_EXACT';
    ELSE verdict := 'WATCH'; basis := 'CRITICAL_RISK'; END IF;
    reason := 'exact market<->supplier identity';
  ELSIF p_market_match = 'STRONG_SAME_PRODUCT' THEN
    IF p_subtype_price_valid AND p_no_critical_risk THEN
      verdict := 'TEST_IDENTITY_SATISFIED'; basis := 'SUPPLIER_EXACT_AND_STRONG_SAME_SUBTYPE'; reason := 'same product at same commercial subtype; price/demand evidence valid at that subtype';
    ELSE
      verdict := 'WATCH'; basis := 'STRONG_BUT_SUBTYPE_PRICE_OR_RISK';
      reason := CASE WHEN NOT p_subtype_price_valid THEN 'price/demand evidence not validated at the same commercial subtype' ELSE 'critical risk present' END;
    END IF;
  ELSE
    verdict := 'WATCH'; basis := 'IDENTITY_TOO_WEAK'; reason := 'market<->supplier identity below STRONG_SAME_PRODUCT';
  END IF;
  RETURN jsonb_build_object('test_identity', verdict, 'basis', basis, 'reason', reason,
    'supplier_identity_state', p_supplier_state, 'market_supplier_match', p_market_match,
    'subtype_price_valid', coalesce(p_subtype_price_valid,false), 'no_critical_risk', coalesce(p_no_critical_risk,true));
END; $function$;

COMMENT ON FUNCTION public.fn_supplier_canonical_identity(text,text,boolean) IS
 'Context B: CJ PID re-confirmed by product/query => SUPPLIER_EXACT (canonical CJ product identity only; not market identity).';
COMMENT ON FUNCTION public.fn_market_supplier_match(jsonb,text,text,text,boolean) IS
 'Context A: defensible market<->supplier bridge. STRONG_SAME_PRODUCT for same-type unbranded match; EXACT_CONFIRMED only with shared identifier or brand+subtype+attrs. Never fuzzy-title EXACT.';
COMMENT ON FUNCTION public.fn_test_identity_gate(text,text,boolean,boolean) IS
 'Beta TEST identity rule: SUPPLIER_EXACT + (EXACT_CONFIRMED) or (STRONG_SAME_PRODUCT at subtype-valid price & no critical risk) => TEST_IDENTITY_SATISFIED; else WATCH/REJECT.';

-- mig_388 — Cross-language supplier identity matching (Stage 2C).
--
-- ROOT CAUSE: supplier equivalence was decided on LITERAL source-language tokens. The concrete
-- identity stored the source-language phrase in product_noun / required_attr_all (e.g. the German
-- [beleuchtete, krippen, wanddekoration]) and fn_market_supplier_match compared those tokens to the
-- supplier title with position()/token-equality. A correct supplier whose title is in a DIFFERENT
-- language (e.g. an English CJ listing "Illuminated Nativity Scene Wall Decoration") shares none of
-- the literal source tokens, so noun_hit=false -> UNRELATED -> the true product is rejected. This is a
-- systemic defect that recurs for every non-English source market (DE/FR/ES/IT/...).
--
-- FIX (deterministic, language-independent, NOT fuzzy; exact matching NOT weakened):
--   * SOURCE LANGUAGE LABELS are separated from CANONICAL IDENTITY ATTRIBUTES. The literal source
--     phrase and provenance are preserved unchanged; a parallel, language-independent concept set is
--     added.
--   * fn_canonical_concepts is a deterministic, controlled, multilingual equivalence lexicon
--     (surface form -> canonical concept). It performs NO runtime LLM translation. It only RECOGNIZES
--     known surface forms; it never invents a concept the text does not contain. New languages/
--     concepts are added by extending the VALUES list (data, not special-casing). FORM:* concepts are
--     mutually-exclusive form factors (wall decoration vs projector vs figurine vs wall light ...).
--   * fn_market_supplier_match keeps the literal same-language path exactly as before, and ADDS a
--     canonical cross-language path: a supplier qualifies on attributes only when it independently
--     contains ALL distinguishing source concepts (>=2) in the concept space. A single shared concept,
--     keyword overlap, or a translated-but-missing attribute can never satisfy it. A conflicting FORM
--     concept fails closed (contradiction). Worst case stays NO_VALID_CJ_MATCH, never a fuzzy bind.
--   * fn_derive_concrete_product_identity emits canonical_noun / canonical_attr_all into match_spec and
--     canonical_attributes / source_language_tokens into the identity, for BOTH the eBay and the
--     product-native branches. Cross-language matching is enabled ONLY when (a) every meaningful source
--     token is covered by the lexicon (no silent unverifiable attribute) AND (b) >=2 distinguishing
--     concepts are recognized. Otherwise the canonical set is empty and matching falls back to the
--     conservative literal path.
--
-- SEARCH vs MATCH: this migration governs the MATCH DECISION only. Candidate RETRIEVAL (the supplier
-- search, which may use a translated / synonym-expanded query) happens upstream in the n8n CJ research
-- executor and merely produces candidates; every returned candidate is still subjected to the identity
-- comparison here. Retrieval never equals resolution.
--
-- No country/provider/product is hardcoded anywhere. Metrics, ads, images and search volume are never
-- read for identity.
SET check_function_bodies = off;

-- ===== deterministic multilingual canonical-concept lexicon =====
CREATE OR REPLACE FUNCTION public.fn_canonical_concepts(p_text text)
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  WITH lex(concept, surface, generic) AS (VALUES
    -- NATIVITY_SCENE (distinguishing noun)
    ('NATIVITY_SCENE','krippe',false),('NATIVITY_SCENE','krippen',false),('NATIVITY_SCENE','weihnachtskrippe',false),
    ('NATIVITY_SCENE','nativity',false),('NATIVITY_SCENE','nativity scene',false),('NATIVITY_SCENE','manger scene',false),
    ('NATIVITY_SCENE','creche',false),('NATIVITY_SCENE','nacimiento',false),('NATIVITY_SCENE','belen',false),
    ('NATIVITY_SCENE','presepe',false),('NATIVITY_SCENE','presepio',false),
    -- ILLUMINATED (distinguishing attribute)
    ('ILLUMINATED','beleuchtet',false),('ILLUMINATED','beleuchtete',false),('ILLUMINATED','beleuchteter',false),
    ('ILLUMINATED','beleuchtetes',false),('ILLUMINATED','beleuchtung',false),('ILLUMINATED','leuchtend',false),
    ('ILLUMINATED','illuminated',false),('ILLUMINATED','lighted',false),('ILLUMINATED','light up',false),
    ('ILLUMINATED','light-up',false),('ILLUMINATED','pre-lit',false),('ILLUMINATED','prelit',false),
    ('ILLUMINATED','lumineux',false),('ILLUMINATED','lumineuse',false),('ILLUMINATED','eclaire',false),
    ('ILLUMINATED','iluminado',false),('ILLUMINATED','iluminada',false),('ILLUMINATED','luminoso',false),
    ('ILLUMINATED','illuminato',false),('ILLUMINATED','led',false),
    -- FORM:WALL_DECORATION (distinguishing form factor)
    ('FORM:WALL_DECORATION','wanddeko',false),('FORM:WALL_DECORATION','wanddekoration',false),
    ('FORM:WALL_DECORATION','wandbehang',false),('FORM:WALL_DECORATION','wandbild',false),
    ('FORM:WALL_DECORATION','wall decoration',false),('FORM:WALL_DECORATION','wall decor',false),
    ('FORM:WALL_DECORATION','wall hanging',false),('FORM:WALL_DECORATION','wall art',false),
    ('FORM:WALL_DECORATION','decoration murale',false),('FORM:WALL_DECORATION','decoracion de pared',false),
    ('FORM:WALL_DECORATION','decorazione da parete',false),
    -- FORM:PROJECTOR (contradictory display form)
    ('FORM:PROJECTOR','projektor',false),('FORM:PROJECTOR','projector',false),('FORM:PROJECTOR','projektion',false),
    ('FORM:PROJECTOR','projection',false),('FORM:PROJECTOR','proyector',false),('FORM:PROJECTOR','proiettore',false),
    ('FORM:PROJECTOR','projecteur',false),
    -- FORM:WALL_LIGHT (contradictory lighting-fixture form)
    ('FORM:WALL_LIGHT','wall light',false),('FORM:WALL_LIGHT','wall lamp',false),('FORM:WALL_LIGHT','wandleuchte',false),
    ('FORM:WALL_LIGHT','wandlampe',false),('FORM:WALL_LIGHT','sconce',false),('FORM:WALL_LIGHT','applique murale',false),
    -- FORM:FIGURINE_SET (contradictory figurine form)
    ('FORM:FIGURINE_SET','figurine',false),('FORM:FIGURINE_SET','figuren',false),('FORM:FIGURINE_SET','krippenfigur',false),
    ('FORM:FIGURINE_SET','krippenfiguren',false),('FORM:FIGURINE_SET','holzfigur',false),('FORM:FIGURINE_SET','statue',false),
    ('FORM:FIGURINE_SET','figura',false),('FORM:FIGURINE_SET','statuina',false),
    -- FORM:TABLETOP / FORM:STRING_LIGHTS (other contradictory forms)
    ('FORM:TABLETOP','tabletop',false),('FORM:TABLETOP','tischdeko',false),
    ('FORM:STRING_LIGHTS','string lights',false),('FORM:STRING_LIGHTS','lichterkette',false),('FORM:STRING_LIGHTS','fairy lights',false),
    -- CHRISTMAS (generic season marker; NOT distinguishing)
    ('CHRISTMAS','weihnacht',true),('CHRISTMAS','weihnachten',true),('CHRISTMAS','weihnachts',true),
    ('CHRISTMAS','christmas',true),('CHRISTMAS','xmas',true),('CHRISTMAS','noel',true),('CHRISTMAS','navidad',true),
    ('CHRISTMAS','natale',true),('CHRISTMAS','holiday',true)
  ),
  m AS (
    SELECT DISTINCT concept, surface, generic FROM lex
    WHERE lower(coalesce(p_text,'')) ~ ('\y'||replace(surface,' ','\s+')||'\y')
  )
  SELECT jsonb_build_object(
    'concepts',       coalesce((SELECT jsonb_agg(DISTINCT concept) FROM m), '[]'::jsonb),
    'distinguishing', coalesce((SELECT jsonb_agg(DISTINCT concept) FROM m WHERE NOT generic), '[]'::jsonb),
    'surfaces',       coalesce((SELECT jsonb_agg(DISTINCT surface) FROM m), '[]'::jsonb),
    'contract','pulse_canonical_concepts_v1');
$function$;
GRANT EXECUTE ON FUNCTION public.fn_canonical_concepts(text) TO authenticated, service_role;

-- ===== supplier matcher: literal same-language OR canonical cross-language (all-of) =====
CREATE OR REPLACE FUNCTION public.fn_market_supplier_match(p_spec jsonb, p_sup_title text, p_sup_category text, p_sup_ref text DEFAULT NULL::text, p_shared_identifier boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE
  traw text; ttoks text[]; fullraw text;
  noun text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'product_noun','[]'::jsonb)) x);
  sub_any text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'required_subtype_any','[]'::jsonb)) x);
  attr_all text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'required_attr_all','[]'::jsonb)) x);
  excl text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'excluded_subtype','[]'::jsonb)) x);
  can_req text[] := ARRAY(SELECT x FROM jsonb_array_elements_text(coalesce(p_spec->'canonical_attr_all','[]'::jsonb)) x);
  can_noun text[] := ARRAY(SELECT x FROM jsonb_array_elements_text(coalesce(p_spec->'canonical_noun','[]'::jsonb)) x);
  brand text := lower(coalesce(p_spec->>'brand',''));
  cat text := lower(coalesce(p_spec->>'category',''));
  noun_hit boolean := false; sub_hit boolean; attr_ok boolean; excl_hit boolean := false; brand_hit boolean := false;
  noun_hit_lit boolean := false; attr_ok_lit boolean;
  sup_concepts text[]; can_attr_ok boolean := false; can_noun_hit boolean := false; form_conflict boolean := false;
  src_forms text[]; sup_forms text[]; match_lang text;
  cls text; ph text; a text; missing int := 0;
BEGIN
  IF p_sup_title IS NULL OR length(trim(p_sup_title)) = 0 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','NO_SUPPLIER_TITLE');
  END IF;
  IF cardinality(noun) = 0 AND cardinality(can_noun) = 0 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','SPEC_MISSING_PRODUCT_NOUN');
  END IF;

  traw := lower(p_sup_title);
  traw := regexp_replace(traw, 'night[ -]?light', 'nightlight', 'g');
  traw := regexp_replace(traw, 'projection', 'projector', 'g');
  traw := regexp_replace(traw, 'wi[ -]?fi', 'wifi', 'g');
  ttoks := public.fn_text_tokens(traw);
  fullraw := traw || ' ' || lower(coalesce(p_sup_category,''));

  IF cardinality(ttoks) < 2 THEN
    RETURN jsonb_build_object('market_supplier_match','INSUFFICIENT_EVIDENCE','reason','SUPPLIER_TITLE_TOO_SPARSE');
  END IF;

  -- literal (same-language) evaluation (unchanged semantics)
  noun_hit_lit := (SELECT bool_or(n = ANY(ttoks) OR position(n in traw) > 0) FROM unnest(noun) n);
  IF cardinality(excl) > 0 THEN
    FOREACH ph IN ARRAY excl LOOP IF position(ph in fullraw) > 0 THEN excl_hit := true; END IF; END LOOP;
  END IF;
  sub_hit := (cardinality(sub_any) = 0)
             OR (SELECT bool_or(s = ANY(ttoks) OR position(s in traw) > 0) FROM unnest(sub_any) s);
  IF cardinality(attr_all) = 0 THEN attr_ok_lit := true;
  ELSE
    missing := 0;
    FOREACH a IN ARRAY attr_all LOOP IF NOT (a = ANY(ttoks) OR position(a in traw) > 0) THEN missing := missing + 1; END IF; END LOOP;
    attr_ok_lit := (missing = 0);
  END IF;
  IF brand <> '' AND position(brand in traw) > 0 THEN brand_hit := true; END IF;

  -- canonical (cross-language) evaluation: additive, deterministic, never fuzzy.
  -- Qualifies on attributes ONLY when the supplier independently contains ALL (>=2) distinguishing
  -- source concepts in the language-independent concept space. A conflicting FORM fails closed.
  sup_concepts := ARRAY(SELECT x FROM jsonb_array_elements_text(coalesce(public.fn_canonical_concepts(p_sup_title)->'concepts','[]'::jsonb)) x);
  can_noun_hit := cardinality(can_noun) > 0 AND (can_noun && sup_concepts);
  can_attr_ok  := cardinality(can_req) >= 2 AND (can_req <@ sup_concepts);
  src_forms := ARRAY(SELECT x FROM unnest(can_req) x WHERE x LIKE 'FORM:%');
  sup_forms := ARRAY(SELECT x FROM unnest(sup_concepts) x WHERE x LIKE 'FORM:%');
  form_conflict := cardinality(src_forms) > 0 AND cardinality(sup_forms) > 0 AND NOT (src_forms && sup_forms);

  -- combine: literal OR canonical; exclusions fail closed from either path
  noun_hit := coalesce(noun_hit_lit,false) OR can_noun_hit;
  attr_ok  := coalesce(attr_ok_lit,false) OR can_attr_ok;
  excl_hit := excl_hit OR form_conflict;
  match_lang := CASE WHEN coalesce(attr_ok_lit,false) AND coalesce(noun_hit_lit,false) THEN 'SAME_LANGUAGE'
                     WHEN can_attr_ok THEN 'CROSS_LANGUAGE_CANONICAL'
                     ELSE 'NONE' END;

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
        WHEN 'CATEGORY_ONLY' THEN CASE WHEN excl_hit THEN 'EXCLUDED_SUBTYPE_OR_FORM_CONFLICT' ELSE 'SAME_CATEGORY_DIFFERENT_PRODUCT' END
        ELSE 'NO_PRODUCT_NOUN_MATCH_IN_TITLE' END,
    'evidence', jsonb_build_object(
        'noun_hit', noun_hit, 'subtype_hit', sub_hit, 'attrs_ok', attr_ok,
        'excluded_subtype_hit', excl_hit, 'brand_hit', brand_hit,
        'shared_identifier', p_shared_identifier, 'supplier_ref', p_sup_ref,
        'literal_noun_hit', coalesce(noun_hit_lit,false), 'literal_attrs_ok', coalesce(attr_ok_lit,false),
        'canonical_noun_hit', can_noun_hit, 'canonical_attrs_ok', can_attr_ok,
        'form_conflict', form_conflict, 'match_language', match_lang,
        'supplier_concepts', to_jsonb(sup_concepts)),
    'note','Product noun/subtype/attrs matched against SUPPLIER TITLE (literal same-language) OR against language-independent canonical concepts (cross-language, all distinguishing concepts required). Category path scanned for excluded subtypes; conflicting FORM fails closed.');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_market_supplier_match(jsonb, text, text, text, boolean) TO authenticated, service_role;

-- ===== concrete identity derivation: emit canonical identity alongside literal source labels =====
CREATE OR REPLACE FUNCTION public.fn_derive_concrete_product_identity(p_tenant uuid, p_product_id uuid, p_market text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(coalesce(p_market,''));
  cp record; v_total int; v_noun text[]; v_subs text[]; v_attrs text[]; v_excl text[];
  v_dom_form text; v_dom_support numeric; v_state text; v_fp text; v_samples jsonb;
  v_pn_count int; v_pn_providers text[]; v_phrase text; v_pntoks text[];
  v_conf text; v_spec jsonb; v_ident jsonb;
  v_idtoks text[]; v_canon jsonb; v_can_dist text[]; v_can_surfaces text[]; v_covered boolean; v_can_eligible boolean; v_canj jsonb;
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
    -- canonical cross-language fields from eBay distinguishing tokens (noun+subtype+attrs)
    v_idtoks := v_noun || coalesce(v_subs, ARRAY[]::text[]) || coalesce(v_attrs, ARRAY[]::text[]);
    v_canon := public.fn_canonical_concepts(array_to_string(v_idtoks,' '));
    v_can_dist := ARRAY(SELECT x FROM jsonb_array_elements_text(coalesce(v_canon->'distinguishing','[]'::jsonb)) x);
    v_can_surfaces := ARRAY(SELECT x FROM jsonb_array_elements_text(coalesce(v_canon->'surfaces','[]'::jsonb)) x);
    v_covered := (cardinality(coalesce(v_idtoks,ARRAY[]::text[]))=0)
      OR (SELECT bool_and(EXISTS(SELECT 1 FROM unnest(v_can_surfaces) sf WHERE position(tok in sf)>0)) FROM unnest(v_idtoks) tok);
    v_can_eligible := coalesce(v_covered,false) AND cardinality(v_can_dist) >= 2;
    v_canj := CASE WHEN v_can_eligible THEN to_jsonb(v_can_dist) ELSE '[]'::jsonb END;

    v_state := CASE WHEN coalesce(v_dom_support,0) >= 0.30 OR cardinality(v_subs) >= 1 THEN 'CONCRETE_RESOLVED' ELSE 'CONCRETE_PRODUCT_AMBIGUOUS' END;
    v_conf := 'MULTI_SOURCE_CORROBORATED_IDENTITY';
    v_fp := md5(lower(array_to_string(v_noun,' ')||'|'||array_to_string(coalesce(v_subs,'{}'),',')||'|'||array_to_string(coalesce(v_attrs,'{}'),',')));
    v_spec := jsonb_build_object('product_noun', to_jsonb(v_noun),
      'required_subtype_any', to_jsonb(coalesce(v_subs, ARRAY[]::text[])),
      'required_attr_all', '[]'::jsonb,
      'excluded_subtype', to_jsonb(coalesce(v_excl, ARRAY[]::text[])), 'category', cp.category,
      'canonical_noun', v_canj, 'canonical_attr_all', v_canj, 'canonical_cross_language', v_can_eligible);
    v_ident := jsonb_build_object('canonical_name', cp.title, 'category', cp.category,
      'subtype', coalesce(v_subs, ARRAY[]::text[]), 'distinguishing_attributes', coalesce(v_attrs, ARRAY[]::text[]),
      'variant_attributes', ARRAY[]::text[],
      'canonical_attributes', v_canj, 'source_language_tokens', to_jsonb(coalesce(v_idtoks, ARRAY[]::text[])),
      'evidence_sources', jsonb_build_object('primary','EBAY_BROWSE','marketplace_listing_titles', v_total,'market',v_mkt,'sample_titles',v_samples,'product_native_observations',v_pn_count,'product_native_providers',to_jsonb(coalesce(v_pn_providers,ARRAY[]::text[]))),
      'identity_confidence', v_conf, 'identity_fingerprint', v_fp);
  ELSIF cardinality(v_pntoks) >= 3 AND coalesce(v_pn_count,0) >= 1 THEN
    -- canonical cross-language fields from the authoritative product-native phrase tokens
    v_idtoks := v_pntoks;
    v_canon := public.fn_canonical_concepts(array_to_string(v_idtoks,' '));
    v_can_dist := ARRAY(SELECT x FROM jsonb_array_elements_text(coalesce(v_canon->'distinguishing','[]'::jsonb)) x);
    v_can_surfaces := ARRAY(SELECT x FROM jsonb_array_elements_text(coalesce(v_canon->'surfaces','[]'::jsonb)) x);
    v_covered := (cardinality(coalesce(v_idtoks,ARRAY[]::text[]))=0)
      OR (SELECT bool_and(EXISTS(SELECT 1 FROM unnest(v_can_surfaces) sf WHERE position(tok in sf)>0)) FROM unnest(v_idtoks) tok);
    v_can_eligible := coalesce(v_covered,false) AND cardinality(v_can_dist) >= 2;
    v_canj := CASE WHEN v_can_eligible THEN to_jsonb(v_can_dist) ELSE '[]'::jsonb END;

    v_state := 'CONCRETE_RESOLVED';
    v_conf := CASE WHEN cardinality(coalesce(v_pn_providers,ARRAY[]::text[])) >= 2 THEN 'MULTI_SOURCE_CORROBORATED_IDENTITY' ELSE 'SINGLE_AUTHORITATIVE_PRODUCT_OBSERVATION' END;
    v_fp := md5(lower(coalesce(v_phrase,'')));
    v_spec := jsonb_build_object('product_noun', to_jsonb(v_pntoks),
      'required_subtype_any', '[]'::jsonb,
      'required_attr_all', to_jsonb(v_pntoks),
      'excluded_subtype', '[]'::jsonb, 'category', cp.category,
      'canonical_noun', v_canj, 'canonical_attr_all', v_canj, 'canonical_cross_language', v_can_eligible);
    v_ident := jsonb_build_object('canonical_name', cp.title, 'category', cp.category,
      'concrete_phrase', v_phrase,
      'subtype', ARRAY[]::text[], 'distinguishing_attributes', to_jsonb(v_pntoks),
      'variant_attributes', ARRAY[]::text[],
      'canonical_attributes', v_canj, 'source_language_tokens', to_jsonb(coalesce(v_idtoks, ARRAY[]::text[])),
      'evidence_sources', jsonb_build_object('primary','PRODUCT_NATIVE','product_native_observations',v_pn_count,'product_native_providers',to_jsonb(coalesce(v_pn_providers,ARRAY[]::text[])),'marketplace_listing_titles', v_total,'market',v_mkt),
      'identity_confidence', v_conf, 'identity_fingerprint', v_fp);
  ELSE
    v_state := 'NO_CONCRETE_EVIDENCE';
    v_conf := 'INSUFFICIENT';
    v_fp := md5(lower(cp.title));
    v_spec := jsonb_build_object('product_noun', to_jsonb(v_noun),
      'required_subtype_any','[]'::jsonb,'required_attr_all','[]'::jsonb,
      'excluded_subtype', to_jsonb(coalesce(v_excl, ARRAY[]::text[])), 'category', cp.category,
      'canonical_noun','[]'::jsonb,'canonical_attr_all','[]'::jsonb,'canonical_cross_language', false);
    v_ident := jsonb_build_object('canonical_name', cp.title, 'category', cp.category,
      'subtype', ARRAY[]::text[], 'distinguishing_attributes', ARRAY[]::text[], 'variant_attributes', ARRAY[]::text[],
      'canonical_attributes','[]'::jsonb,
      'evidence_sources', jsonb_build_object('primary',CASE WHEN v_total>0 THEN 'EBAY_BROWSE_PARTIAL' ELSE 'NONE' END,'marketplace_listing_titles', v_total,'product_native_observations',v_pn_count,'market',v_mkt,'sample_titles',v_samples),
      'identity_confidence', v_conf, 'identity_fingerprint', v_fp);
  END IF;

  RETURN jsonb_build_object('ok', true, 'concrete_state', v_state, 'concrete_identity', v_ident, 'match_spec', v_spec);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_derive_concrete_product_identity(uuid, uuid, text) TO authenticated, service_role;

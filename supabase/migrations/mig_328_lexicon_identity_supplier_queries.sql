-- mig_328_lexicon_identity_supplier_queries.sql
-- Stage 4B: identity-aware supplier search query generation, driven by the 73-row
-- commerce_identity_lexicon (reuse — no duplicate architecture).
--
-- Problem fixed: fn_stage2_supplier_search_queries previously derived CJ search terms only from
-- fn_supplier_search_terms, whose expansion lexicon is hardcoded to the Christmas/nativity family.
-- For a lexicon-covered product (e.g. the Novelty Old Man Face Ski Mask) it fell back to
-- SOURCE_PHRASE_FALLBACK = the raw sorted tokens ("face man mask novelty old ski"), which CJ
-- product/list does not rank the real supplier product for.
--
-- This migration adds a lexicon layer: it derives the product's identity families via
-- fn_identity_families over the immutable concrete identity, then combines the product-FORM family
-- surfaces (headwear_facemask -> balaclava, full-face, ...) with the distinguishing CHARACTER /
-- novelty family surfaces (novelty_character -> realistic, novelty, funny, ...; old_man_face -> ...)
-- into bounded, de-duplicated, distinctive 2-word queries + bare-form queries, in English plus the
-- market language. novelty_character synonyms are prioritised because they carry across marketplaces
-- (FastMoss "novelty" <-> CJ "realistic"), which is exactly the cross-vocabulary recognition the unit
-- requires. Non-lexicon products keep the existing fn_supplier_search_terms fallback unchanged.
--
-- Verified live: for the ski mask the generator emits "realistic balaclava" / "novelty balaclava"
-- etc.; the Stage-2 search then rediscovers CJ pid 2609290358281623700 WITHOUT the pid being supplied
-- (found via "scary balaclava" p.3, 13 CJ calls) and the cross-supplier resolver classifies it
-- SAME_PRODUCT_IDENTITY / MEDIUM with 8 corresponding Old-Man-Face variants.
--
-- Reuses: fn_derive_concrete_product_identity, fn_supplier_search_terms, fn_identity_families,
-- commerce_identity_lexicon. Keeps the search.queries contract (consumed by fn_stage2_cj_retrieval_plan
-- -> the n8n Stage-2 paginator). Additive diagnostics. Deployed via MCP apply_migration.
CREATE OR REPLACE FUNCTION public.fn_stage2_supplier_search_queries(p_tenant uuid, p_product_id uuid, p_market text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_owns boolean; v_der jsonb; v_spec jsonb; v_ci jsonb; v_terms jsonb; v_en boolean; v_gap boolean;
  v_lang text; v_concept_text text; v_fams text[];
  v_form_fams text[] := ARRAY['headwear_facemask','skincare_mask','wall_art_sign'];
  v_char_fams text[] := ARRAY['old_man_face','elderly_female_face','animal_face','pattern_abstract','novelty_character','multipack'];
  v_present_form text[]; v_present_char text[];
  v_form_tok text[]; v_char_tok text[]; v_lex_q text[] := '{}'; v_base_q text[]; v_merged text[] := '{}';
  q text; ft text; ct text; v_cap int := 12;
BEGIN
  IF p_tenant IS NULL OR p_product_id IS NULL OR coalesce(btrim(p_market),'')='' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args'); END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product_id AND user_id=p_tenant) INTO v_owns;
  IF NOT v_owns THEN RETURN jsonb_build_object('ok',false,'reason','not_owned'); END IF;
  v_der := public.fn_derive_concrete_product_identity(p_tenant, p_product_id, p_market);
  IF coalesce(v_der->>'ok','false') <> 'true' THEN RETURN v_der; END IF;
  v_spec := v_der->'match_spec';
  v_ci := v_der->'concrete_identity';
  v_terms := public.fn_supplier_search_terms(v_spec);
  v_en := upper(p_market) = ANY (ARRAY['US','GB','UK','IE','AU','CA','NZ','SG']);
  v_lang := CASE WHEN upper(p_market)='DE' THEN 'de' WHEN upper(p_market)='FR' THEN 'fr' ELSE 'en' END;

  v_concept_text := lower(coalesce(v_ci->>'canonical_name','')||' '||coalesce(v_ci->>'concrete_phrase','')||' '||
    coalesce((SELECT string_agg(x,' ') FROM jsonb_array_elements_text(coalesce(v_ci->'distinguishing_attributes','[]'::jsonb)) x),''));
  v_fams := public.fn_identity_families(v_concept_text);
  v_present_form := ARRAY(SELECT unnest(v_fams) INTERSECT SELECT unnest(v_form_fams));
  v_present_char := ARRAY(SELECT unnest(v_fams) INTERSECT SELECT unnest(v_char_fams));

  -- Form surfaces: distinctive single-word nouns first (balaclava), English + market language.
  SELECT ARRAY(SELECT token FROM public.commerce_identity_lexicon
               WHERE family = ANY(v_present_form) AND lang IN ('en', v_lang)
               ORDER BY (position(' ' in token)=0) DESC, (lang=v_lang) DESC, length(token) DESC LIMIT 2) INTO v_form_tok;
  -- Character surfaces: novelty_character synonyms first (cross-vocabulary: realistic/novelty/funny),
  -- then specific-character families; shorter generic descriptors first.
  SELECT ARRAY(SELECT token FROM public.commerce_identity_lexicon
               WHERE family = ANY(v_present_char) AND lang IN ('en', v_lang)
               ORDER BY (family='novelty_character') DESC, (lang=v_lang) DESC, length(token) ASC LIMIT 8) INTO v_char_tok;

  IF cardinality(coalesce(v_form_tok,'{}')) > 0 THEN
    FOREACH ct IN ARRAY coalesce(v_char_tok,'{}') LOOP
      FOREACH ft IN ARRAY v_form_tok LOOP
        v_lex_q := v_lex_q || (ct||' '||ft);
      END LOOP;
    END LOOP;
    v_lex_q := v_lex_q || v_form_tok;  -- bare distinctive form tokens
  END IF;

  v_base_q := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(v_terms->'queries','[]'::jsonb)) x);

  -- merge: lexicon identity queries first (distinctive canonical terms), then base; normalise, dedup, cap, <=6 words
  FOREACH q IN ARRAY (v_lex_q || v_base_q) LOOP
    q := btrim(regexp_replace(regexp_replace(lower(coalesce(q,'')),'[[:punct:]]+',' ','g'),'\s+',' ','g'));
    IF q='' THEN CONTINUE; END IF;
    IF coalesce(array_length(string_to_array(q,' '),1),0) > 6 THEN
      q := array_to_string((string_to_array(q,' '))[1:6],' '); END IF;
    IF NOT (q = ANY(v_merged)) AND cardinality(v_merged) < v_cap THEN v_merged := v_merged || q; END IF;
  END LOOP;

  v_gap := (cardinality(v_lex_q)=0) AND (v_terms->>'source' = 'SOURCE_PHRASE_FALLBACK') AND NOT v_en;

  RETURN jsonb_build_object('ok',true,'market',upper(p_market),
    'concrete_state', v_der->>'concrete_state',
    'identity_confidence', v_ci->>'identity_confidence',
    'match_spec', v_spec,
    'search', jsonb_build_object('ok', true,
      'source', CASE WHEN cardinality(v_lex_q)>0 THEN 'LEXICON_IDENTITY_EXPANSION' ELSE v_terms->>'source' END,
      'queries', to_jsonb(v_merged), 'query_count', cardinality(v_merged),
      'primary_query', CASE WHEN cardinality(v_merged)>0 THEN v_merged[1] ELSE NULL END,
      'lexicon_queries', to_jsonb(v_lex_q), 'base_queries', to_jsonb(v_base_q),
      'present_form_families', to_jsonb(coalesce(v_present_form,'{}')),
      'present_character_families', to_jsonb(coalesce(v_present_char,'{}')),
      'form_surfaces', to_jsonb(coalesce(v_form_tok,'{}')),
      'character_surfaces', to_jsonb(coalesce(v_char_tok,'{}')),
      'language', v_lang, 'contract','pulse_supplier_search_terms_v2'),
    'language_coverage_gap', v_gap,
    'language_note', CASE WHEN v_gap THEN
      'Non-English market produced no lexicon/canonical concept; low-confidence source-language fallback.' ELSE NULL END,
    'page_num', 1, 'page_size', 20, 'contract','pulse_stage2_supplier_search_queries_v3');
END; $function$;

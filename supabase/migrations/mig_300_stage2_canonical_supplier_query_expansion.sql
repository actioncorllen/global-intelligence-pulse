-- mig_300_stage2_canonical_supplier_query_expansion.sql
-- STRATELOQ — Stage-2 B3 fix: canonical Product Identity -> CJ supplier-search query expansion.
--
-- CONFIRMED DEFECT (forensic): the resolved canonical identity (e.g. Krippen -> NATIVITY_SCENE +
-- ILLUMINATED + FORM:WALL_DECORATION, derived by fn_derive_concrete_product_identity/fn_canonical_concepts)
-- was NEVER converted into supplier-catalogue search terms. The CJ search was driven by a
-- language-preserving phrase (fn_product_search_identity -> German) or a manual external term, so the
-- distinctive NATIVITY_SCENE concept never reached CJ product/list. The matcher (fn_market_supplier_match)
-- is already cross-language; the gap is purely at retrieval/query-generation. The prior NO_VALID_CJ_MATCH
-- is therefore NOT a trustworthy "CJ lacks the product".
--
-- FIX (generic, deterministic, production-safe; no live CJ; pagination untouched):
--  1) fn_supplier_search_terms(match_spec) -> ordered, deduped, bounded supplier query set built from the
--     canonical distinguishing concepts. Defining NOUN concepts drive the query (recall-first, bare noun
--     surfaces), enriched with the primary attribute/form (precision variants). Generic season markers
--     (CHRISTMAS) are NEVER emitted standalone and can never replace the defining identity. Falls back to
--     the source-language product_noun phrase when no canonical concept is available (no regression).
--  2) fn_stage2_supplier_search_queries(tenant, product, market) -> production entry point: verifies
--     tenant ownership (fail closed), derives the concrete identity, returns the bounded query set +
--     the current (unchanged) page_num/page_size window. This is what the Stage-2 orchestrator/n8n must
--     call to obtain queries instead of a hand-supplied search_query.
--  3) fn_resolve_concrete_supplier_identity: the internal SQL candidate-fallback (p_candidates IS NULL)
--     now pre-selects from commerce_supplier_products using the EXPANDED supplier terms (cross-language)
--     UNION the raw product_noun tokens (no recall regression). Everything else in the resolver is
--     byte-for-byte unchanged: match spec, fn_market_supplier_match, qualify logic, exclusions,
--     form-conflict, thresholds, persistence, tenant scoping, provenance. Matching strictness is NOT
--     weakened; similar products are NOT promoted to exact identity.
--
-- Boundaries: no CJ/provider call; no retrieval-depth (pageNum/pageSize) change; no change to identity
-- resolution, Stage-1 qualification, supplier state, Product Asset Lock, or country/tenant isolation.

-- ---------------------------------------------------------------------------------------------------
-- (1) Deterministic canonical -> supplier query expansion (pure; reads no tables).
-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_supplier_search_terms(p_spec jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE
  v_concepts text[];
  v_known   text[] := ARRAY['NATIVITY_SCENE','ILLUMINATED','FORM:WALL_DECORATION','FORM:WALL_LIGHT',
                            'FORM:STRING_LIGHTS','FORM:FIGURINE_SET','FORM:PROJECTOR','FORM:TABLETOP'];
  v_generic text[] := ARRAY['CHRISTMAS'];
  v_nouns text[]; v_attrs text[]; v_forms text[];
  v_src_noun text[]; v_cand text[] := ARRAY[]::text[]; v_queries text[] := ARRAY[]::text[];
  v_primary_noun text; v_primary_attr text; v_primary_form text;
  v_src text; v_q text; v_cap int := 8;
BEGIN
  IF p_spec IS NULL OR jsonb_typeof(p_spec) <> 'object' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_spec');
  END IF;

  -- distinguishing canonical concepts: canonical_noun first (in order), then canonical_attr_all; dedup, stable.
  v_concepts := ARRAY(
    SELECT x FROM (
      SELECT x, min(mo) AS mo FROM (
        SELECT value AS x, ordinality AS mo
          FROM jsonb_array_elements_text(coalesce(p_spec->'canonical_noun','[]'::jsonb)) WITH ORDINALITY AS a(value,ordinality)
        UNION ALL
        SELECT value, 100+ordinality
          FROM jsonb_array_elements_text(coalesce(p_spec->'canonical_attr_all','[]'::jsonb)) WITH ORDINALITY AS b(value,ordinality)
      ) u WHERE coalesce(btrim(x),'') <> '' GROUP BY x
    ) d ORDER BY mo);

  v_src_noun := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(p_spec->'product_noun','[]'::jsonb)) x
                      WHERE coalesce(btrim(x),'') <> '');

  -- concept -> supplier surfaces (English-first, curated for CJ productNameEn keyword search).
  WITH lex(concept,surface,role,ord) AS (VALUES
      ('NATIVITY_SCENE','nativity scene','noun',1),('NATIVITY_SCENE','nativity set','noun',2),
      ('NATIVITY_SCENE','christmas crib','noun',3),('NATIVITY_SCENE','creche','noun',4),('NATIVITY_SCENE','manger scene','noun',5),
      ('ILLUMINATED','led','attr',1),('ILLUMINATED','lighted','attr',2),('ILLUMINATED','illuminated','attr',3),
      ('FORM:WALL_DECORATION','wall decoration','form',1),('FORM:WALL_DECORATION','wall hanging','form',2),('FORM:WALL_DECORATION','wall decor','form',3),
      ('FORM:WALL_LIGHT','wall light','form',1),('FORM:WALL_LIGHT','wall lamp','form',2),('FORM:WALL_LIGHT','sconce','form',3),
      ('FORM:STRING_LIGHTS','string lights','form',1),('FORM:STRING_LIGHTS','fairy lights','form',2),
      ('FORM:FIGURINE_SET','figurine set','form',1),('FORM:FIGURINE_SET','figurine','form',2),('FORM:FIGURINE_SET','statue','form',3),
      ('FORM:PROJECTOR','projector','form',1),
      ('FORM:TABLETOP','tabletop','form',1)),
  known AS (SELECT l.surface, l.role, l.ord, array_position(v_concepts, l.concept) AS cpos
            FROM lex l WHERE l.concept = ANY(v_concepts))
  SELECT ARRAY(SELECT surface FROM known WHERE role='noun' ORDER BY cpos,ord),
         ARRAY(SELECT surface FROM known WHERE role='attr' ORDER BY cpos,ord),
         ARRAY(SELECT surface FROM known WHERE role='form' ORDER BY cpos,ord)
    INTO v_nouns, v_attrs, v_forms;

  -- graceful genericity: unknown non-FORM/non-generic concept -> noun (humanized); unknown FORM:* -> form.
  v_nouns := coalesce(v_nouns,ARRAY[]::text[]) || ARRAY(
    SELECT lower(replace(x,'_',' ')) FROM unnest(v_concepts) x
    WHERE x NOT LIKE 'FORM:%' AND NOT (x = ANY(v_generic)) AND NOT (x = ANY(v_known)));
  v_forms := coalesce(v_forms,ARRAY[]::text[]) || ARRAY(
    SELECT lower(replace(replace(x,'FORM:',''),'_',' ')) FROM unnest(v_concepts) x
    WHERE x LIKE 'FORM:%' AND NOT (x = ANY(v_known)));

  IF cardinality(v_nouns) = 0 THEN
    -- No defining noun concept: never emit attr/form/generic-only queries (they retrieve generic items).
    IF cardinality(v_src_noun) > 0 THEN
      v_cand := ARRAY[ array_to_string(v_src_noun,' ') ];
      v_src := 'SOURCE_PHRASE_FALLBACK';
    ELSE
      RETURN jsonb_build_object('ok',true,'source','NO_SEARCHABLE_IDENTITY','queries','[]'::jsonb,
        'query_count',0,'primary_query',NULL,'defining_concepts',to_jsonb(v_concepts),
        'contract','pulse_supplier_search_terms_v1');
    END IF;
  ELSE
    v_src := 'CANONICAL_EXPANSION';
    v_primary_noun := v_nouns[1];
    v_primary_attr := CASE WHEN cardinality(v_attrs)>0 THEN v_attrs[1] END;
    v_primary_form := CASE WHEN cardinality(v_forms)>0 THEN v_forms[1] END;
    v_cand := v_nouns;  -- defining nouns alone (recall-first)
    IF v_primary_form IS NOT NULL THEN v_cand := v_cand || (v_primary_noun||' '||v_primary_form); END IF;
    IF v_primary_attr IS NOT NULL THEN v_cand := v_cand || (v_primary_attr||' '||v_primary_noun); END IF;
    IF v_primary_attr IS NOT NULL AND v_primary_form IS NOT NULL THEN
      v_cand := v_cand || (v_primary_attr||' '||v_primary_noun||' '||v_primary_form); END IF;
    IF cardinality(v_forms) > 1 THEN v_cand := v_cand || (v_primary_noun||' '||v_forms[2]); END IF;
  END IF;

  -- normalize (lower/punct->space/collapse), cap 6 tokens, dedup case-insensitively, cap query count.
  FOREACH v_q IN ARRAY v_cand LOOP
    v_q := btrim(regexp_replace(regexp_replace(lower(coalesce(v_q,'')), '[[:punct:]]+',' ','g'), '\s+',' ','g'));
    IF v_q = '' THEN CONTINUE; END IF;
    IF coalesce(array_length(string_to_array(v_q,' '),1),0) > 6 THEN
      v_q := array_to_string((string_to_array(v_q,' '))[1:6],' '); END IF;
    IF NOT (v_q = ANY(v_queries)) AND cardinality(v_queries) < v_cap THEN
      v_queries := v_queries || v_q; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true, 'source', v_src,
    'queries', to_jsonb(v_queries),
    'primary_query', CASE WHEN cardinality(v_queries)>0 THEN v_queries[1] ELSE NULL END,
    'query_count', cardinality(v_queries),
    'noun_surfaces', to_jsonb(coalesce(v_nouns,ARRAY[]::text[])),
    'attr_surfaces', to_jsonb(coalesce(v_attrs,ARRAY[]::text[])),
    'form_surfaces', to_jsonb(coalesce(v_forms,ARRAY[]::text[])),
    'defining_concepts', to_jsonb(v_concepts),
    'contract','pulse_supplier_search_terms_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_supplier_search_terms(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_supplier_search_terms(jsonb) TO service_role;

-- ---------------------------------------------------------------------------------------------------
-- (2) Production entry point: per-product bounded supplier query set (tenant-isolated, fail closed).
-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_stage2_supplier_search_queries(p_tenant uuid, p_product_id uuid, p_market text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_owns boolean; v_der jsonb; v_spec jsonb; v_terms jsonb;
BEGIN
  IF p_tenant IS NULL OR p_product_id IS NULL OR coalesce(btrim(p_market),'')='' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args'); END IF;
  -- Tenant isolation: only the owner's product is addressable.
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product_id AND user_id=p_tenant) INTO v_owns;
  IF NOT v_owns THEN RETURN jsonb_build_object('ok',false,'reason','not_owned'); END IF;
  v_der := public.fn_derive_concrete_product_identity(p_tenant, p_product_id, p_market);
  IF coalesce(v_der->>'ok','false') <> 'true' THEN RETURN v_der; END IF;
  v_spec := v_der->'match_spec';
  v_terms := public.fn_supplier_search_terms(v_spec);
  RETURN jsonb_build_object('ok',true,'market',upper(p_market),
    'concrete_state', v_der->>'concrete_state',
    'identity_confidence', v_der->'concrete_identity'->>'identity_confidence',
    'match_spec', v_spec, 'search', v_terms,
    -- current retrieval window is unchanged in this stage; bounded pagination is a later unit.
    'page_num', 1, 'page_size', 20,
    'contract','pulse_stage2_supplier_search_queries_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_stage2_supplier_search_queries(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_supplier_search_queries(uuid,uuid,text) TO service_role;

-- ---------------------------------------------------------------------------------------------------
-- (3) Resolver: fix ONLY the internal SQL candidate fallback to use expanded (cross-language) terms.
--     All other logic is unchanged from mig_294.
-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_concrete_supplier_identity(p_tenant uuid, p_product_id uuid, p_market text, p_candidates jsonb DEFAULT NULL::jsonb, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_der jsonb; v_spec jsonb; v_state text; cp record;
  c jsonb; m jsonb; cls text; attrs_ok boolean; excl_hit boolean;
  v_considered jsonb := '[]'::jsonb; v_contra jsonb := '[]'::jsonb; v_qualify jsonb := '[]'::jsonb;
  v_result text; v_sel jsonb; v_prov jsonb; v_qn int;
  v_sterms text[]; v_nouns_src text[];
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','tenant_required'); END IF;
  SELECT title, category INTO cp FROM public.commerce_products WHERE id=p_product_id AND user_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant'); END IF;

  v_der := public.fn_derive_concrete_product_identity(p_tenant, p_product_id, p_market);
  IF coalesce(v_der->>'ok','false')<>'true' THEN RETURN v_der; END IF;
  v_spec := v_der->'match_spec';
  v_state := v_der->>'concrete_state';

  IF v_state = 'NO_CONCRETE_EVIDENCE' THEN
    v_result := 'NO_VALID_CJ_MATCH';
  ELSE
    IF p_candidates IS NULL THEN
      -- B3 fix: pre-select catalogue candidates using EXPANDED supplier terms (cross-language) UNION the
      -- raw product_noun tokens (no recall regression vs the prior noun-token-only filter).
      v_sterms := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(public.fn_supplier_search_terms(v_spec)->'queries','[]'::jsonb)) x);
      v_nouns_src := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(v_spec->'product_noun','[]'::jsonb)) x);
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'supplier','CJDROPSHIPPING','supplier_product_id',sp.source_product_id,'sku',sp.sku,
               'title',sp.title,'category',sp.category,'variant',null)),'[]'::jsonb)
        INTO p_candidates
      FROM public.commerce_supplier_products sp
      WHERE sp.source ILIKE 'cj%'
        AND ( EXISTS (SELECT 1 FROM unnest(v_sterms) t WHERE t <> '' AND position(t in lower(sp.title))>0)
           OR EXISTS (SELECT 1 FROM unnest(v_nouns_src) t WHERE t <> '' AND position(t in lower(sp.title))>0) )
      LIMIT 40;
    END IF;

    FOR c IN SELECT * FROM jsonb_array_elements(coalesce(p_candidates,'[]'::jsonb)) LOOP
      m := public.fn_market_supplier_match(v_spec, c->>'title', c->>'category', c->>'supplier_product_id', false);
      cls := m->>'market_supplier_match';
      attrs_ok := coalesce((m->'evidence'->>'attrs_ok')::boolean, false);
      excl_hit := coalesce((m->'evidence'->>'excluded_subtype_hit')::boolean, false);
      v_considered := v_considered || jsonb_build_array(jsonb_build_object(
        'supplier_product_id', c->>'supplier_product_id','title',c->>'title',
        'match_class', cls, 'attrs_ok', attrs_ok, 'excluded_subtype_hit', excl_hit,
        'evidence', m->'evidence'));
      IF excl_hit THEN
        v_contra := v_contra || jsonb_build_array(jsonb_build_object(
          'supplier_product_id', c->>'supplier_product_id','title',c->>'title','reason','EXCLUDED_SUBTYPE_PRESENT'));
      ELSIF cls IN ('STRONG_SAME_PRODUCT','EXACT_CONFIRMED') AND attrs_ok THEN
        v_qualify := v_qualify || jsonb_build_array(c || jsonb_build_object('match_class',cls,'match_evidence',m->'evidence'));
      END IF;
    END LOOP;

    v_qn := jsonb_array_length(v_qualify);
    IF v_qn = 0 THEN v_result := 'NO_VALID_CJ_MATCH';
    ELSIF v_qn = 1 THEN v_result := 'EXACT_SUPPLIER_IDENTITY_RESOLVED'; v_sel := v_qualify->0;
    ELSE v_result := 'CONCRETE_PRODUCT_AMBIGUOUS'; END IF;
  END IF;

  v_prov := jsonb_build_object(
    'step1_opportunity_to_concrete', jsonb_build_object(
      'opportunity_concept', cp.title, 'market', upper(p_market),
      'concrete_state', v_state, 'concrete_identity', v_der->'concrete_identity',
      'claim','Market opportunity resolved to a concrete product from observed marketplace evidence.'),
    'step2_concrete_to_supplier', CASE WHEN v_sel IS NOT NULL THEN jsonb_build_object(
      'supplier','CJDROPSHIPPING','cj_product_id', v_sel->>'supplier_product_id',
      'match_class', v_sel->>'match_class',
      'claim','Concrete product is supplied by this CJ product (attribute match, explicitly bound).') ELSE NULL END,
    'identity_separation_note','This is NOT a claim that the DataForSEO concept equals a CJ SKU; the concept was first resolved to a concrete product, then a CJ product was bound to supply that concrete product.');

  IF p_persist THEN
    INSERT INTO public.commerce_concrete_supplier_resolution AS t (
      tenant_id, opportunity_product_id, market, concrete_identity, concrete_state, match_spec,
      candidates_considered, selected_supplier, selected_supplier_product_id, selected_sku, selected_variant,
      supplier_match_evidence, contradictory_evidence, identity_result, provenance, bound, bound_at)
    VALUES (p_tenant, p_product_id, upper(p_market), v_der->'concrete_identity', v_state, v_spec,
      v_considered, CASE WHEN v_sel IS NOT NULL THEN 'CJDROPSHIPPING' END,
      v_sel->>'supplier_product_id', v_sel->>'sku', v_sel->'variant',
      v_sel->'match_evidence', v_contra, v_result, v_prov,
      (v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED'),
      CASE WHEN v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED' THEN now() END)
    ON CONFLICT (tenant_id, opportunity_product_id, market) DO UPDATE SET
      concrete_identity=excluded.concrete_identity, concrete_state=excluded.concrete_state,
      match_spec=excluded.match_spec, candidates_considered=excluded.candidates_considered,
      selected_supplier=excluded.selected_supplier, selected_supplier_product_id=excluded.selected_supplier_product_id,
      selected_sku=excluded.selected_sku, selected_variant=excluded.selected_variant,
      supplier_match_evidence=excluded.supplier_match_evidence, contradictory_evidence=excluded.contradictory_evidence,
      identity_result=excluded.identity_result, provenance=excluded.provenance,
      bound=excluded.bound, bound_at=excluded.bound_at, created_at=now();
  END IF;

  RETURN jsonb_build_object('ok',true,'opportunity_product_id',p_product_id,'market',upper(p_market),
    'concrete_state',v_state,'concrete_identity',v_der->'concrete_identity','match_spec',v_spec,
    'candidates_considered',v_considered,'contradictory_evidence',v_contra,
    'qualifying_count',coalesce(v_qn,0),'identity_result',v_result,
    'selected_supplier_product_id', v_sel->>'supplier_product_id','selected_sku', v_sel->>'sku',
    'bound',(v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED'),'provenance',v_prov);
END; $function$;

-- ---------------------------------------------------------------------------------------------------
-- (4) Deterministic self-test (service_role only; mocked specs; no provider calls, no writes).
-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_stage2_query_expansion_selftest()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v jsonb; qs text[]; pass int := 0; fail int := 0; results jsonb := '[]'::jsonb;
  spec_krippen jsonb := jsonb_build_object(
     'category','tiktok_shop_product',
     'product_noun', jsonb_build_array('beleuchtete','krippen','wanddekoration'),
     'canonical_noun', jsonb_build_array('FORM:WALL_DECORATION','ILLUMINATED','NATIVITY_SCENE'),
     'canonical_attr_all', jsonb_build_array('FORM:WALL_DECORATION','ILLUMINATED','NATIVITY_SCENE'),
     'canonical_cross_language', true);
  spec_generic_only jsonb := jsonb_build_object(
     'product_noun', jsonb_build_array('festive'),
     'canonical_noun', jsonb_build_array('CHRISTMAS','ILLUMINATED'),
     'canonical_attr_all', jsonb_build_array('CHRISTMAS','ILLUMINATED'));
  spec_unknown jsonb := jsonb_build_object(
     'product_noun', jsonb_build_array('knoblauchpresse'),
     'canonical_noun', jsonb_build_array('GARLIC_PRESS'),
     'canonical_attr_all', jsonb_build_array('GARLIC_PRESS'));
  spec_noncanon jsonb := jsonb_build_object(
     'product_noun', jsonb_build_array('nitro','cold','brew','maker'),
     'canonical_noun','[]'::jsonb,'canonical_attr_all','[]'::jsonb);
  mm jsonb;
BEGIN
  -- check 1: NATIVITY_SCENE reaches query generation (CANONICAL_EXPANSION + 'nativity scene' present)
  v := public.fn_supplier_search_terms(spec_krippen);
  qs := ARRAY(SELECT x FROM jsonb_array_elements_text(v->'queries') x);
  IF v->>'source'='CANONICAL_EXPANSION' AND 'nativity scene' = ANY(qs)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','1_nativity_reaches_query','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','1_nativity_reaches_query','pass',false,'got',v); END IF;

  -- check 2: >=2 meaningful nativity noun surfaces generated
  IF (SELECT count(*) FROM unnest(qs) q WHERE q IN ('nativity scene','nativity set','christmas crib','creche','manger scene')) >= 2
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','2_nativity_terms','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','2_nativity_terms','pass',false,'queries',to_jsonb(qs)); END IF;

  -- check 3: illumination + wall-decoration attributes preserved (as combinations and/or surfaces)
  IF EXISTS(SELECT 1 FROM unnest(qs) q WHERE q LIKE '%led%')
     AND EXISTS(SELECT 1 FROM unnest(qs) q WHERE q LIKE '%wall decoration%')
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','3_illum_and_wall_preserved','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','3_illum_and_wall_preserved','pass',false,'queries',to_jsonb(qs)); END IF;

  -- check 4a: generic (CHRISTMAS) can never replace defining identity / never standalone.
  -- Every emitted query must carry a NATIVITY_SCENE surface (incl. creche / manger scene / christmas crib),
  -- and no query may be the bare generic season marker.
  IF NOT ('christmas' = ANY(qs)) AND NOT ('christmas decoration' = ANY(qs))
     AND (SELECT bool_and(q ~ '(nativity scene|nativity set|christmas crib|creche|manger scene)') FROM unnest(qs) q)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','4a_generic_never_replaces','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','4a_generic_never_replaces','pass',false,'queries',to_jsonb(qs)); END IF;

  -- check 4b: generic+attr only (no noun) must NOT emit bare generic/attr queries -> fallback to source phrase
  v := public.fn_supplier_search_terms(spec_generic_only);
  qs := ARRAY(SELECT x FROM jsonb_array_elements_text(v->'queries') x);
  IF v->>'source'='SOURCE_PHRASE_FALLBACK' AND NOT ('christmas' = ANY(qs)) AND NOT ('led' = ANY(qs))
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','4b_no_bare_generic_or_attr','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','4b_no_bare_generic_or_attr','pass',false,'got',v); END IF;

  -- check 5: bounded (<=8) and deduped and <=6 tokens each
  v := public.fn_supplier_search_terms(spec_krippen);
  qs := ARRAY(SELECT x FROM jsonb_array_elements_text(v->'queries') x);
  IF cardinality(qs) <= 8
     AND cardinality(qs) = (SELECT count(DISTINCT q) FROM unnest(qs) q)
     AND NOT EXISTS(SELECT 1 FROM unnest(qs) q WHERE coalesce(array_length(string_to_array(q,' '),1),0) > 6)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','5_bounded_deduped','pass',true,'count',cardinality(qs));
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','5_bounded_deduped','pass',false,'queries',to_jsonb(qs)); END IF;

  -- check 6a: works for an UNKNOWN canonical concept (generic humanization -> defining noun query)
  v := public.fn_supplier_search_terms(spec_unknown);
  qs := ARRAY(SELECT x FROM jsonb_array_elements_text(v->'queries') x);
  IF v->>'source'='CANONICAL_EXPANSION' AND 'garlic press' = ANY(qs)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','6a_generic_unknown_concept','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','6a_generic_unknown_concept','pass',false,'got',v); END IF;

  -- check 6b: non-canonicalizable product -> source-phrase fallback (no regression, English-source safe)
  v := public.fn_supplier_search_terms(spec_noncanon);
  qs := ARRAY(SELECT x FROM jsonb_array_elements_text(v->'queries') x);
  IF v->>'source'='SOURCE_PHRASE_FALLBACK' AND 'nitro cold brew maker' = ANY(qs)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','6b_source_phrase_fallback','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','6b_source_phrase_fallback','pass',false,'got',v); END IF;

  -- check 7a: matching safeguard intact — a genuine illuminated nativity WALL decoration qualifies (cross-language)
  mm := public.fn_market_supplier_match(spec_krippen, 'LED Lighted Nativity Scene Wall Decoration, Bethlehem Star', 'Home Decor', 'X1', false);
  IF mm->>'market_supplier_match' IN ('STRONG_SAME_PRODUCT','EXACT_CONFIRMED')
     AND coalesce((mm->'evidence'->>'attrs_ok')::boolean,false)
     AND NOT coalesce((mm->'evidence'->>'excluded_subtype_hit')::boolean,false)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','7a_true_nativity_qualifies','pass',true,'cls',mm->>'market_supplier_match');
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','7a_true_nativity_qualifies','pass',false,'got',mm); END IF;

  -- check 7b: matching safeguard intact — a wall LAMP must be rejected (form conflict), NOT promoted
  mm := public.fn_market_supplier_match(spec_krippen, 'Minimalist Round Wall Light Modern LED Fixture Wall Lamp', 'Lighting', 'X2', false);
  IF coalesce((mm->'evidence'->>'excluded_subtype_hit')::boolean,false)
     AND mm->>'market_supplier_match' NOT IN ('STRONG_SAME_PRODUCT','EXACT_CONFIRMED')
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','7b_wall_lamp_rejected','pass',true,'cls',mm->>'market_supplier_match');
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','7b_wall_lamp_rejected','pass',false,'got',mm); END IF;

  RETURN jsonb_build_object('suite','fn_stage2_query_expansion_selftest','pass',pass,'fail',fail,
    'ok',(fail=0),'results',results);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_stage2_query_expansion_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_query_expansion_selftest() TO service_role;

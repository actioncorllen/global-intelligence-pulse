-- ============================================================================
-- mig_295_confirmed_requires_exact_sku.sql
-- STRATELOQ-STAGE4B-EXACT-SKU-CONFIRMATION
--
-- DEFECT (proven by a read-only, rolled-back resolver test): a candidate with an exact
-- shared-identifier identity match but NO supplier SKU was still bound as
-- EXACT_SUPPLIER_IDENTITY_RESOLVED (bound=true, selected_sku=null). The required journey is
-- "...-> Exact SKU -> CONFIRMED", and Stage-4B requires missing SKUs to PREVENT confirmation.
-- (The authoritative Product Card already masks it — mig_293 requires bound AND sku for a
-- CONFIRMED chip — but the resolver itself should not bind a confirmed supplier match without
-- an exact SKU.)
--
-- SMALLEST SAFE FIX (strengthens, never weakens): a candidate must carry a non-null supplier
-- SKU to qualify for binding, on BOTH the shared-identifier track and the attribute track.
-- A null-SKU candidate therefore no longer produces EXACT_SUPPLIER_IDENTITY_RESOLVED; the
-- product resolves to NO_VALID_CJ_MATCH (concrete product resolved, exact SKU not established
-- -> surfaces as UNBOUND/AMBIGUOUS on the card). Identity, variant, excluded-subtype and
-- shared-identifier logic are otherwise UNCHANGED, so every real SKU-bearing match is
-- unaffected (e.g. the existing kids-nightlight CJYD3093228 record still binds). No change to
-- the matcher (fn_market_supplier_match) or the concrete-identity derivation.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_concrete_supplier_identity(p_tenant uuid, p_product_id uuid, p_market text, p_candidates jsonb DEFAULT NULL::jsonb, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_der jsonb; v_spec jsonb; v_state text; cp record;
  c jsonb; m jsonb; cls text; attrs_ok boolean; excl_hit boolean; form_conflict boolean; v_shared boolean; v_has_sku boolean;
  v_considered jsonb := '[]'::jsonb; v_contra jsonb := '[]'::jsonb; v_qualify jsonb := '[]'::jsonb; v_idqualify jsonb := '[]'::jsonb;
  v_result text; v_sel jsonb; v_prov jsonb; v_qn int; v_qn_id int; v_basis text := 'ATTRIBUTE';
  v_sterms text[]; v_nouns_src text[]; v_linked text[];
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','tenant_required'); END IF;
  SELECT title, category, extended INTO cp FROM public.commerce_products WHERE id=p_product_id AND user_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant'); END IF;

  v_linked := coalesce(ARRAY(
    SELECT DISTINCT sid FROM (
      SELECT cp.extended->'supplier_ref'->>'source_product_id' AS sid, lower(coalesce(cp.extended->'supplier_ref'->>'provider','')) AS prov
      UNION ALL SELECT cp.extended->>'cj_source_product_id', 'cj'
      UNION ALL SELECT e->>'source_product_id', lower(coalesce(e->>'provider',''))
                 FROM jsonb_array_elements(coalesce(cp.extended->'supplier_refs','[]'::jsonb)) e
    ) z WHERE sid IS NOT NULL AND sid <> '' AND prov LIKE 'cj%'
  ), '{}'::text[]);

  v_der := public.fn_derive_concrete_product_identity(p_tenant, p_product_id, p_market);
  IF coalesce(v_der->>'ok','false')<>'true' THEN RETURN v_der; END IF;
  v_spec := v_der->'match_spec';
  v_state := v_der->>'concrete_state';

  IF v_state = 'NO_CONCRETE_EVIDENCE' THEN
    v_result := 'NO_VALID_CJ_MATCH';
  ELSE
    IF p_candidates IS NULL THEN
      v_sterms := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(public.fn_supplier_search_terms(v_spec)->'queries','[]'::jsonb)) x);
      v_nouns_src := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(v_spec->'product_noun','[]'::jsonb)) x);
      WITH termed AS (
        SELECT sp.source, sp.source_product_id, sp.sku, sp.title, sp.category, sp.supplier_enrichment->'variant' AS variant
        FROM public.commerce_supplier_products sp
        WHERE sp.source ILIKE 'cj%'
          AND ( EXISTS (SELECT 1 FROM unnest(v_sterms) t WHERE t<>'' AND position(t in lower(sp.title))>0)
             OR EXISTS (SELECT 1 FROM unnest(v_nouns_src) t WHERE t<>'' AND position(t in lower(sp.title))>0) )
        LIMIT 40
      ),
      linked AS (
        SELECT sp.source, sp.source_product_id, sp.sku, sp.title, sp.category, sp.supplier_enrichment->'variant' AS variant
        FROM public.commerce_supplier_products sp
        WHERE array_length(v_linked,1) > 0 AND sp.source_product_id = ANY(v_linked)
      ),
      allc AS (SELECT * FROM termed UNION SELECT * FROM linked)
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'supplier',upper(source),'supplier_product_id',source_product_id,'sku',sku,
               'title',title,'category',category,'variant',variant)),'[]'::jsonb)
        INTO p_candidates FROM allc;
    END IF;

    FOR c IN SELECT * FROM jsonb_array_elements(coalesce(p_candidates,'[]'::jsonb)) LOOP
      v_shared := (array_length(v_linked,1) > 0 AND lower(coalesce(c->>'supplier_product_id','')) = ANY (SELECT lower(u) FROM unnest(v_linked) u));
      -- STAGE4B: an exact CJ SKU is mandatory for a CONFIRMED supplier binding.
      v_has_sku := nullif(btrim(coalesce(c->>'sku','')),'') IS NOT NULL;
      m := public.fn_market_supplier_match(v_spec, c->>'title', c->>'category', c->>'supplier_product_id', v_shared);
      cls := m->>'market_supplier_match';
      attrs_ok := coalesce((m->'evidence'->>'attrs_ok')::boolean, false);
      excl_hit := coalesce((m->'evidence'->>'excluded_subtype_hit')::boolean, false);
      form_conflict := coalesce((m->'evidence'->>'form_conflict')::boolean, false);
      v_considered := v_considered || jsonb_build_array(jsonb_build_object(
        'supplier_product_id', c->>'supplier_product_id','title',c->>'title',
        'match_class', cls, 'attrs_ok', attrs_ok, 'excluded_subtype_hit', excl_hit,
        'shared_identifier', v_shared, 'has_sku', v_has_sku, 'evidence', m->'evidence'));
      IF excl_hit THEN
        v_contra := v_contra || jsonb_build_array(jsonb_build_object(
          'supplier_product_id', c->>'supplier_product_id','title',c->>'title','reason','EXCLUDED_SUBTYPE_PRESENT'));
      ELSE
        IF v_shared AND cls = 'EXACT_CONFIRMED' AND NOT form_conflict AND v_has_sku THEN
          v_idqualify := v_idqualify || jsonb_build_array(c || jsonb_build_object('match_class',cls,'match_evidence',m->'evidence'));
        END IF;
        IF cls IN ('STRONG_SAME_PRODUCT','EXACT_CONFIRMED') AND attrs_ok AND v_has_sku THEN
          v_qualify := v_qualify || jsonb_build_array(c || jsonb_build_object('match_class',cls,'match_evidence',m->'evidence'));
        END IF;
      END IF;
    END LOOP;

    v_qn_id := jsonb_array_length(v_idqualify);
    v_qn := jsonb_array_length(v_qualify);
    IF v_qn_id = 1 THEN
      v_result := 'EXACT_SUPPLIER_IDENTITY_RESOLVED'; v_sel := v_idqualify->0; v_basis := 'SHARED_PRODUCT_IDENTIFIER';
    ELSIF v_qn_id > 1 THEN
      v_result := 'CONCRETE_PRODUCT_AMBIGUOUS'; v_basis := 'SHARED_PRODUCT_IDENTIFIER';
    ELSE
      IF v_qn = 0 THEN v_result := 'NO_VALID_CJ_MATCH';
      ELSIF v_qn = 1 THEN v_result := 'EXACT_SUPPLIER_IDENTITY_RESOLVED'; v_sel := v_qualify->0;
      ELSE v_result := 'CONCRETE_PRODUCT_AMBIGUOUS'; END IF;
    END IF;
  END IF;

  v_prov := jsonb_build_object(
    'step1_opportunity_to_concrete', jsonb_build_object(
      'opportunity_concept', cp.title, 'market', upper(p_market),
      'concrete_state', v_state, 'concrete_identity', v_der->'concrete_identity',
      'claim','Market opportunity resolved to a concrete product from observed marketplace evidence.'),
    'step2_concrete_to_supplier', CASE WHEN v_sel IS NOT NULL THEN jsonb_build_object(
      'supplier', upper(coalesce(v_sel->>'supplier','CJDROPSHIPPING')),'cj_product_id', v_sel->>'supplier_product_id',
      'match_class', v_sel->>'match_class', 'match_basis', v_basis,
      'claim', CASE WHEN v_basis='SHARED_PRODUCT_IDENTIFIER'
                    THEN 'Concrete product is supplied by this CJ product (RECORDED shared supplier identifier; identifier precedence over attribute matches).'
                    ELSE 'Concrete product is supplied by this CJ product (attribute match, explicitly bound).' END) ELSE NULL END,
    'identity_separation_note','This is NOT a claim that the DataForSEO concept equals a CJ SKU; the concept was first resolved to a concrete product, then a CJ product was bound to supply that concrete product.');

  IF p_persist THEN
    INSERT INTO public.commerce_concrete_supplier_resolution AS t (
      tenant_id, opportunity_product_id, market, concrete_identity, concrete_state, match_spec,
      candidates_considered, selected_supplier, selected_supplier_product_id, selected_sku, selected_variant,
      supplier_match_evidence, contradictory_evidence, identity_result, provenance, bound, bound_at)
    VALUES (p_tenant, p_product_id, upper(p_market), v_der->'concrete_identity', v_state, v_spec,
      v_considered, CASE WHEN v_sel IS NOT NULL THEN upper(coalesce(v_sel->>'supplier','CJDROPSHIPPING')) END,
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
    'qualifying_count', CASE WHEN v_qn_id >= 1 THEN v_qn_id ELSE coalesce(v_qn,0) END,
    'match_basis', v_basis, 'identity_result',v_result,
    'selected_supplier_product_id', v_sel->>'supplier_product_id','selected_sku', v_sel->>'sku',
    'selected_variant', v_sel->'variant',
    'bound',(v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED'),'provenance',v_prov);
END; $function$;

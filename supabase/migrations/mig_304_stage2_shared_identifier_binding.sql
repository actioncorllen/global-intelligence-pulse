-- mig_304_stage2_shared_identifier_binding.sql
--
-- STAGE 2 FIX — honor a product's RECORDED supplier identifier so a genuine exact binding is reachable.
--
-- DEFECT (mig_300 fn_resolve_concrete_supplier_identity line ~222):
--   fn_market_supplier_match was ALWAYS called with p_shared_identifier=false. The matcher already
--   supports a deterministic EXACT_CONFIRMED (reason SHARED_PRODUCT_IDENTIFIER) when the opportunity and a
--   CJ candidate share a product identifier, but the resolver never fed it the opportunity's recorded CJ
--   linkage (commerce_products.extended.supplier_ref / supplier_refs[] / cj_source_product_id — written by
--   the earlier supplier-linking step). So a product already linked to a specific CJ product could only be
--   matched by fuzzy title/attribute logic, which is AMBIGUOUS for commodity products (many near-identical
--   CJ listings) — blocking the first real binding even though a genuine 1:1 linkage existed.
--
-- FIX (surgical, strictness NOT weakened; no fabrication):
--   1) Read the opportunity's RECORDED CJ identifier(s) from extended (provider CJ only).
--   2) Always include the linked catalogue row(s) in the candidate set (so an identifier match never
--      depends on the LIMIT-40 term window), carrying sku + variant from supplier_enrichment.
--   3) Pass p_shared_identifier=true ONLY for a candidate whose supplier_product_id equals a recorded
--      linked id. A shared-identifier candidate binds EXACT with PRECEDENCE over fuzzy attribute matches,
--      BUT still fails closed on excluded_subtype_hit or form_conflict (a bad link never binds).
--   4) When NO recorded identifier matches, behaviour is byte-for-byte the mig_300 attribute path.
--   The identifier is REAL recorded evidence; honoring it is not fabrication. EXACT_CONFIRMED on a shared
--   identifier is the matcher's own designed semantics.
--
-- Preserves: concrete-identity derivation, match spec, matcher, exclusions, form-conflict, thresholds,
-- persistence, tenant scoping (user_id ownership), 18-market isolation (market passed through unchanged),
-- Product Asset Lock (untouched). Ships fn_stage2_shared_identifier_selftest (deterministic).

CREATE OR REPLACE FUNCTION public.fn_resolve_concrete_supplier_identity(p_tenant uuid, p_product_id uuid, p_market text, p_candidates jsonb DEFAULT NULL::jsonb, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_der jsonb; v_spec jsonb; v_state text; cp record;
  c jsonb; m jsonb; cls text; attrs_ok boolean; excl_hit boolean; form_conflict boolean; v_shared boolean;
  v_considered jsonb := '[]'::jsonb; v_contra jsonb := '[]'::jsonb; v_qualify jsonb := '[]'::jsonb; v_idqualify jsonb := '[]'::jsonb;
  v_result text; v_sel jsonb; v_prov jsonb; v_qn int; v_qn_id int; v_basis text := 'ATTRIBUTE';
  v_sterms text[]; v_nouns_src text[]; v_linked text[];
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','tenant_required'); END IF;
  SELECT title, category, extended INTO cp FROM public.commerce_products WHERE id=p_product_id AND user_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant'); END IF;

  -- Recorded CJ supplier identifier(s) for this opportunity (provider CJ only).
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
      -- B3 fix (mig_300): expanded supplier terms UNION product_noun tokens; PLUS (mig_304) always
      -- include the recorded linked row(s) so an identifier match never depends on the term window.
      v_sterms := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(public.fn_supplier_search_terms(v_spec)->'queries','[]'::jsonb)) x);
      v_nouns_src := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(v_spec->'product_noun','[]'::jsonb)) x);
      WITH termed AS (
        SELECT sp.source_product_id, sp.sku, sp.title, sp.category, sp.supplier_enrichment->'variant' AS variant
        FROM public.commerce_supplier_products sp
        WHERE sp.source ILIKE 'cj%'
          AND ( EXISTS (SELECT 1 FROM unnest(v_sterms) t WHERE t<>'' AND position(t in lower(sp.title))>0)
             OR EXISTS (SELECT 1 FROM unnest(v_nouns_src) t WHERE t<>'' AND position(t in lower(sp.title))>0) )
        LIMIT 40
      ),
      linked AS (
        SELECT sp.source_product_id, sp.sku, sp.title, sp.category, sp.supplier_enrichment->'variant' AS variant
        FROM public.commerce_supplier_products sp
        WHERE array_length(v_linked,1) > 0 AND sp.source_product_id = ANY(v_linked)
      ),
      allc AS (SELECT * FROM termed UNION SELECT * FROM linked)
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'supplier','CJDROPSHIPPING','supplier_product_id',source_product_id,'sku',sku,
               'title',title,'category',category,'variant',variant)),'[]'::jsonb)
        INTO p_candidates FROM allc;
    END IF;

    FOR c IN SELECT * FROM jsonb_array_elements(coalesce(p_candidates,'[]'::jsonb)) LOOP
      v_shared := (array_length(v_linked,1) > 0 AND lower(coalesce(c->>'supplier_product_id','')) = ANY (SELECT lower(u) FROM unnest(v_linked) u));
      m := public.fn_market_supplier_match(v_spec, c->>'title', c->>'category', c->>'supplier_product_id', v_shared);
      cls := m->>'market_supplier_match';
      attrs_ok := coalesce((m->'evidence'->>'attrs_ok')::boolean, false);
      excl_hit := coalesce((m->'evidence'->>'excluded_subtype_hit')::boolean, false);
      form_conflict := coalesce((m->'evidence'->>'form_conflict')::boolean, false);
      v_considered := v_considered || jsonb_build_array(jsonb_build_object(
        'supplier_product_id', c->>'supplier_product_id','title',c->>'title',
        'match_class', cls, 'attrs_ok', attrs_ok, 'excluded_subtype_hit', excl_hit,
        'shared_identifier', v_shared, 'evidence', m->'evidence'));
      IF excl_hit THEN
        v_contra := v_contra || jsonb_build_array(jsonb_build_object(
          'supplier_product_id', c->>'supplier_product_id','title',c->>'title','reason','EXCLUDED_SUBTYPE_PRESENT'));
      ELSE
        -- Identifier precedence: a recorded shared identifier binds EXACT, but still fails closed on form conflict.
        IF v_shared AND cls = 'EXACT_CONFIRMED' AND NOT form_conflict THEN
          v_idqualify := v_idqualify || jsonb_build_array(c || jsonb_build_object('match_class',cls,'match_evidence',m->'evidence'));
        END IF;
        -- Attribute path (unchanged from mig_300).
        IF cls IN ('STRONG_SAME_PRODUCT','EXACT_CONFIRMED') AND attrs_ok THEN
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
      'supplier','CJDROPSHIPPING','cj_product_id', v_sel->>'supplier_product_id',
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
    'qualifying_count', CASE WHEN v_qn_id >= 1 THEN v_qn_id ELSE coalesce(v_qn,0) END,
    'match_basis', v_basis, 'identity_result',v_result,
    'selected_supplier_product_id', v_sel->>'supplier_product_id','selected_sku', v_sel->>'sku',
    'selected_variant', v_sel->'variant',
    'bound',(v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED'),'provenance',v_prov);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_resolve_concrete_supplier_identity(uuid,uuid,text,jsonb,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_resolve_concrete_supplier_identity(uuid,uuid,text,jsonb,boolean) TO service_role;

-- Deterministic matcher-level selftest for the shared-identifier semantics the resolver now relies on.
CREATE OR REPLACE FUNCTION public.fn_stage2_shared_identifier_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  results jsonb := '[]'::jsonb; pass int := 0; fail int := 0; m jsonb;
  -- generic spec (no distinguishing canonical attrs) + a humidifier-style excluded subtype to prove the guard
  spec jsonb := jsonb_build_object('category','night_light','product_noun',jsonb_build_array('projector'),
     'canonical_noun',jsonb_build_array(),'canonical_attr_all',jsonb_build_array(),
     'required_attr_all',jsonb_build_array(),'excluded_subtype',jsonb_build_array('wooden'),
     'required_subtype_any',jsonb_build_array(),'canonical_cross_language',true);
BEGIN
  -- T1: shared identifier -> EXACT_CONFIRMED (SHARED_PRODUCT_IDENTIFIER), not excluded
  m := public.fn_market_supplier_match(spec,'Starry Sky Projector Night Light For Children','Night Lights','CJX1', true);
  IF m->>'market_supplier_match'='EXACT_CONFIRMED' AND m->>'reason'='SHARED_PRODUCT_IDENTIFIER'
       AND coalesce((m->'evidence'->>'excluded_subtype_hit')::boolean,false)=false
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','T1_identifier_exact','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','T1_identifier_exact','ok',false,'got',m)); END IF;

  -- T2: without identifier, same generic title is NOT EXACT_CONFIRMED (strictness unchanged)
  m := public.fn_market_supplier_match(spec,'Starry Sky Projector Night Light For Children','Night Lights','CJX1', false);
  IF m->>'market_supplier_match' <> 'EXACT_CONFIRMED'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','T2_no_identifier_not_exact','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','T2_no_identifier_not_exact','ok',false,'got',m->>'market_supplier_match')); END IF;

  -- T3: identifier but EXCLUDED subtype present -> excluded_subtype_hit true (resolver fails closed, never binds)
  m := public.fn_market_supplier_match(spec,'Wooden Star Projector Night Light','Night Lights','CJX2', true);
  IF coalesce((m->'evidence'->>'excluded_subtype_hit')::boolean,false)=true
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','T3_identifier_excluded_guard','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','T3_identifier_excluded_guard','ok',false,'got',m->'evidence')); END IF;

  RETURN jsonb_build_object('suite','stage2_shared_identifier','pass',pass,'fail',fail,'ok',(fail=0),'results',results);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage2_shared_identifier_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_shared_identifier_selftest() TO service_role;

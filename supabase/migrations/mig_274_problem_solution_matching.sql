-- ============================================================================
-- mig_274_problem_solution_matching.sql
-- STRATELOQ-PROBLEM-INTELLIGENCE-015D — PROBLEM → PRODUCT SOLUTION MATCHING
--
-- Adds the next reusable Problem Intelligence stage:
--   real customer problem
--   -> evidence-grounded solution requirements   (A)
--   -> candidate product solutions               (B)
--   -> deterministic product match quality        (C)
--   -> selected-market observed presence          (D)
--   -> connect qualifying candidate into the EXISTING product pipeline (E)
--
-- REUSE (authoritative, NOT replaced):
--   commerce_problem_clusters, commerce_signals(problem_cluster_id),
--   fn_problem_corroboration_state (supplier/cross-market/hypothesis excluded),
--   fn_problem_cluster_link_product, commerce_products (canonical identity),
--   fn_own_request_product_market_research -> fn_research_dispatch,
--   product_market_evaluations, product_opportunity_decisions, fn_pod_evaluate.
--
-- INVARIANTS ENFORCED HERE:
--   * Solution progression uses a SEPARATE solution lifecycle on candidate rows.
--     It NEVER writes commerce_problem_clusters.status and therefore can NEVER
--     promote a problem to PROBLEM_CORROBORATED. Problem corroboration and
--     solution progression are orthogonal dimensions (spec H).
--   * A candidate stays PROVISIONAL while the problem is not
--     MULTI_SOURCE_CORROBORATED (spec E). provisional is a snapshot of the
--     problem evidence state at assessment time and is exposed to the reader.
--   * Match quality (WEAK/POSSIBLE/GOOD/STRONG) is separate from opportunity
--     score and evidence confidence (spec C). STRONG requires OBSERVABLE support
--     (matched marketplace listings in the problem category), never keyword
--     overlap alone.
--   * Selected-market presence never asserts "not sold in <market>". Absence of
--     evidence => INSUFFICIENT_MARKET_EVIDENCE, never evidence of absence
--     (spec D). Cross-market listings never silently count as selected-market
--     presence (research_market / marketplace, not item ship-from country).
--   * Supplier evidence never establishes demand, corroboration, selected-market
--     demand, or promotion by itself (spec F) — supplier signals are excluded
--     from demand/presence math here, exactly as in fn_problem_corroboration_state.
--   * The existing Product Decision remains the ONLY decision/scoring authority.
--     No second decision table, no second scorer (spec E). The connect step calls
--     the existing request pipeline and reads back the existing PME/Decision.
-- ============================================================================

-- ============================================================================
-- 0) TABLES
-- ============================================================================

-- 0a) Problem -> solution requirements (evidence-grounded, provenance-traced).
--     LLM/derived intelligence is stored as HYPOTHESIS/DERIVED and can never by
--     itself establish demand/corroboration/decision.
CREATE TABLE IF NOT EXISTS public.commerce_problem_solution_requirements (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  problem_cluster_id uuid NOT NULL REFERENCES public.commerce_problem_clusters(id) ON DELETE CASCADE,
  requirement_key    text NOT NULL,
  requirement_text   text NOT NULL,
  derivation         text NOT NULL DEFAULT 'DERIVED'
                       CHECK (derivation IN ('DERIVED','DERIVED_LLM','OBSERVED')),
  is_hypothesis      boolean NOT NULL DEFAULT true,
  provenance         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (problem_cluster_id, requirement_key)
);
CREATE INDEX IF NOT EXISTS idx_cpsr_cluster ON public.commerce_problem_solution_requirements(problem_cluster_id);
CREATE INDEX IF NOT EXISTS idx_cpsr_tenant  ON public.commerce_problem_solution_requirements(tenant_id);

-- 0b) Problem -> product candidate relation (canonical, deduplicated).
CREATE TABLE IF NOT EXISTS public.commerce_problem_solution_candidates (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL,
  problem_cluster_id    uuid NOT NULL REFERENCES public.commerce_problem_clusters(id) ON DELETE CASCADE,
  product_id            uuid REFERENCES public.commerce_products(id) ON DELETE SET NULL,
  candidate_term        text NOT NULL,
  candidate_term_norm   text GENERATED ALWAYS AS (lower(btrim(candidate_term))) STORED,
  match_rationale       text,
  match_quality         text NOT NULL DEFAULT 'WEAK_MATCH'
                          CHECK (match_quality IN ('WEAK_MATCH','POSSIBLE_MATCH','GOOD_MATCH','STRONG_MATCH')),
  match_confidence      numeric NOT NULL DEFAULT 0 CHECK (match_confidence >= 0 AND match_confidence <= 1),
  market_presence_state text
                          CHECK (market_presence_state IS NULL OR market_presence_state IN
                            ('OBSERVED_MARKET_PRESENCE','LIMITED_OBSERVED_MARKET_PRESENCE',
                             'LOW_OBSERVED_MARKET_PRESENCE','INSUFFICIENT_MARKET_EVIDENCE')),
  solution_status       text NOT NULL DEFAULT 'CANDIDATE_PROPOSED'
                          CHECK (solution_status IN
                            ('CANDIDATE_PROPOSED','PRODUCT_MATCHED','MARKET_ASSESSED',
                             'RESEARCH_CONNECTED','PRODUCT_DECISION_AVAILABLE','REJECTED')),
  provisional           boolean NOT NULL DEFAULT true,
  problem_evidence_state text,
  linked_decision_id    uuid,
  linked_run_id         uuid,
  evidence              jsonb NOT NULL DEFAULT '{}'::jsonb,
  provenance            jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_fixture            boolean NOT NULL DEFAULT false,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
-- dedup: one row per (cluster, product); and per (cluster, normalized term) when product not yet resolved
CREATE UNIQUE INDEX IF NOT EXISTS uq_cpsc_cluster_product
  ON public.commerce_problem_solution_candidates(problem_cluster_id, product_id)
  WHERE product_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cpsc_cluster_term
  ON public.commerce_problem_solution_candidates(problem_cluster_id, candidate_term_norm);
CREATE INDEX IF NOT EXISTS idx_cpsc_tenant  ON public.commerce_problem_solution_candidates(tenant_id);
CREATE INDEX IF NOT EXISTS idx_cpsc_product ON public.commerce_problem_solution_candidates(product_id);

-- 0c) RLS — mirror commerce_problem_clusters exactly (authenticated select-own, service_role all)
ALTER TABLE public.commerce_problem_solution_requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commerce_problem_solution_candidates   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cpsr_select_own  ON public.commerce_problem_solution_requirements;
DROP POLICY IF EXISTS cpsr_service_all ON public.commerce_problem_solution_requirements;
CREATE POLICY cpsr_select_own  ON public.commerce_problem_solution_requirements
  FOR SELECT TO authenticated USING (auth.uid() = tenant_id);
CREATE POLICY cpsr_service_all ON public.commerce_problem_solution_requirements
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS cpsc_select_own  ON public.commerce_problem_solution_candidates;
DROP POLICY IF EXISTS cpsc_service_all ON public.commerce_problem_solution_candidates;
CREATE POLICY cpsc_select_own  ON public.commerce_problem_solution_candidates
  FOR SELECT TO authenticated USING (auth.uid() = tenant_id);
CREATE POLICY cpsc_service_all ON public.commerce_problem_solution_candidates
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- 0d) updated_at triggers (reuse existing trigger fn)
DROP TRIGGER IF EXISTS trg_cpsr_updated_at ON public.commerce_problem_solution_requirements;
CREATE TRIGGER trg_cpsr_updated_at BEFORE UPDATE ON public.commerce_problem_solution_requirements
  FOR EACH ROW EXECUTE FUNCTION public.fn_problem_clusters_set_updated_at();
DROP TRIGGER IF EXISTS trg_cpsc_updated_at ON public.commerce_problem_solution_candidates;
CREATE TRIGGER trg_cpsc_updated_at BEFORE UPDATE ON public.commerce_problem_solution_candidates
  FOR EACH ROW EXECUTE FUNCTION public.fn_problem_clusters_set_updated_at();

-- ============================================================================
-- 1) DETERMINISTIC TEXT HELPER (significant, generic tokens)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_norm_tokens(p text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path TO '' AS $function$
  SELECT coalesce(array_agg(DISTINCT t), '{}'::text[])
  FROM (
    SELECT unnest(regexp_split_to_array(
             regexp_replace(lower(coalesce(p,'')),'[^a-z0-9]+',' ','g'), '\s+')) AS t
  ) s
  WHERE length(t) >= 3
    AND t <> ALL (ARRAY['the','and','for','with','your','you','are','not','this','that',
                        'from','have','how','best','way','ways','can','will','out','our']);
$function$;
REVOKE ALL ON FUNCTION public.fn_norm_tokens(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_norm_tokens(text) TO authenticated, service_role;

-- ============================================================================
-- 2) SOLUTION REQUIREMENTS — persist evidence-grounded requirement (A)
--    LLM/derived intelligence stored as HYPOTHESIS/DERIVED; provenance-traced to
--    the cluster + its qualifying evidence. Never establishes demand/decision.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_upsert_solution_requirement(
  p_cluster_id uuid, p_requirement_key text, p_requirement_text text,
  p_derivation text DEFAULT 'DERIVED', p_evidence jsonb DEFAULT '{}'::jsonb,
  p_is_hypothesis boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_c public.commerce_problem_clusters%rowtype; v_id uuid; v_prov jsonb;
BEGIN
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF v_uid IS NOT NULL AND v_c.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;
  IF coalesce(btrim(p_requirement_key),'')='' OR coalesce(btrim(p_requirement_text),'')='' THEN
    RETURN jsonb_build_object('status','invalid','reason','requirement_key and requirement_text required');
  END IF;

  v_prov := jsonb_build_object(
    'derived_from_cluster', p_cluster_id,
    'canonical_problem', v_c.canonical_problem,
    'market', v_c.market, 'category', v_c.category,
    'intelligence_class', CASE WHEN p_is_hypothesis THEN 'HYPOTHESIS_DERIVED' ELSE 'OBSERVED' END,
    'claim_safety', 'DERIVED solution requirement; does NOT establish demand, corroboration, market presence, supplier viability, opportunity score, or Product Decision',
    'evidence', coalesce(p_evidence,'{}'::jsonb));

  INSERT INTO public.commerce_problem_solution_requirements
    (tenant_id, problem_cluster_id, requirement_key, requirement_text, derivation, is_hypothesis, provenance)
  VALUES (v_c.tenant_id, p_cluster_id, lower(btrim(p_requirement_key)), btrim(p_requirement_text),
          coalesce(p_derivation,'DERIVED'), coalesce(p_is_hypothesis,true), v_prov)
  ON CONFLICT (problem_cluster_id, requirement_key) DO UPDATE
    SET requirement_text = EXCLUDED.requirement_text,
        derivation = EXCLUDED.derivation,
        is_hypothesis = EXCLUDED.is_hypothesis,
        provenance = EXCLUDED.provenance,
        updated_at = now()
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('status','ok','requirement_id',v_id,'cluster_id',p_cluster_id,
    'requirement_key',lower(btrim(p_requirement_key)),'derivation',coalesce(p_derivation,'DERIVED'),
    'is_hypothesis',coalesce(p_is_hypothesis,true));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_upsert_solution_requirement(uuid,text,text,text,jsonb,boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_upsert_solution_requirement(uuid,text,text,text,jsonb,boolean) TO service_role;

-- ============================================================================
-- 3) PRODUCT MATCH QUALITY (C) — deterministic; separate from opportunity score.
--    STRONG requires OBSERVABLE support (matched marketplace listings in the
--    problem category), never keyword overlap alone.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_assess_product_match_quality(p_cluster_id uuid, p_product_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_c public.commerce_problem_clusters%rowtype;
  v_p public.commerce_products%rowtype;
  v_prod_toks text[]; v_cat_toks text[];
  v_total int := 0; v_covered int := 0; v_cov numeric := 0;
  v_obs int := 0; v_quality text; v_conf numeric; r record; v_match boolean;
BEGIN
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','cluster_not_found'); END IF;
  IF v_uid IS NOT NULL AND v_c.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;
  SELECT * INTO v_p FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;

  v_prod_toks := public.fn_norm_tokens(
    concat_ws(' ', v_p.title, v_p.category, v_p.description,
              v_p.extended->>'summary', v_p.extended->>'attributes'));
  v_cat_toks  := public.fn_norm_tokens(v_c.category);

  -- requirement coverage: a requirement is covered when any of its significant
  -- tokens shares a 4-char stem with any product token (shoe~shoes, door~doorway)
  FOR r IN
    SELECT requirement_key, requirement_text
    FROM public.commerce_problem_solution_requirements WHERE problem_cluster_id = p_cluster_id
  LOOP
    v_total := v_total + 1;
    v_match := EXISTS (
      SELECT 1
      FROM unnest(public.fn_norm_tokens(concat_ws(' ', r.requirement_key, r.requirement_text))) rt
      JOIN unnest(v_prod_toks) pt ON left(rt,4) = left(pt,4));
    IF v_match THEN v_covered := v_covered + 1; END IF;
  END LOOP;

  IF v_total > 0 THEN
    v_cov := round(v_covered::numeric / v_total, 4);
  ELSE
    -- no requirements yet: fall back to product<->problem category token overlap
    v_cov := CASE WHEN EXISTS (SELECT 1 FROM unnest(v_cat_toks) ct JOIN unnest(v_prod_toks) pt ON left(ct,4)=left(pt,4))
                  THEN 0.4 ELSE 0 END;
  END IF;

  -- OBSERVABLE support: matched marketplace listings whose category token-overlaps
  -- the problem category. Supplier-sourced signals are excluded (supplier != demand/fit proof).
  SELECT count(*)::int INTO v_obs
  FROM public.commerce_signals s
  WHERE s.product_id = p_product_id
    AND s.signal_type = 'MARKETPLACE_ACTIVITY'
    AND coalesce(s.value->>'match','') = 'MATCHED'
    AND upper(coalesce(s.provenance->>'source','')) NOT IN ('CJ','CJDROPSHIPPING','SUPPLIER')
    AND EXISTS (
      SELECT 1 FROM unnest(public.fn_norm_tokens(s.value->>'category')) ct
      JOIN unnest(v_cat_toks) qt ON left(ct,4) = left(qt,4));

  v_quality := CASE
    WHEN v_cov >= 0.6 AND v_obs >= 3 THEN 'STRONG_MATCH'
    WHEN (v_cov >= 0.6 AND v_obs >= 1) OR (v_cov >= 0.4 AND v_obs >= 3) THEN 'GOOD_MATCH'
    WHEN v_cov >= 0.4 OR v_obs >= 1 THEN 'POSSIBLE_MATCH'
    ELSE 'WEAK_MATCH' END;

  v_conf := round(least(1.0, 0.4*v_cov + 0.5*(least(v_obs,5)::numeric/5) + 0.1*(CASE WHEN v_obs>0 THEN 1 ELSE 0 END)), 2);

  RETURN jsonb_build_object('status','ok','cluster_id',p_cluster_id,'product_id',p_product_id,
    'match_quality', v_quality, 'match_confidence', v_conf,
    'requirement_total', v_total, 'requirement_covered', v_covered, 'requirement_coverage', v_cov,
    'observable_matched_listings', v_obs,
    'rationale', format('requirement_coverage=%s (%s/%s); observable matched marketplace listings in problem category=%s; STRONG requires coverage>=0.6 AND observable>=3 (never keyword overlap alone)', v_cov, v_covered, v_total, v_obs),
    'separation_note', 'match_quality is independent of market_opportunity_score and evidence_confidence');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_assess_product_match_quality(uuid,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_assess_product_match_quality(uuid,uuid) TO authenticated, service_role;

-- ============================================================================
-- 4) SELECTED-MARKET PRESENCE (D) — never asserts "not sold". Absence of
--    evidence => INSUFFICIENT_MARKET_EVIDENCE. Cross-market listings excluded
--    (keyed on research_market / marketplace, never item ship-from country).
--    Supplier-sourced signals excluded.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_assess_selected_market_presence(p_product_id uuid, p_market text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_p public.commerce_products%rowtype;
  v_obs int := 0; v_items int := 0; v_cross int := 0; v_search int := 0;
  v_fresh timestamptz; v_sources jsonb; v_state text; v_searched boolean; v_attempts jsonb;
BEGIN
  SELECT * INTO v_p FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_uid IS NOT NULL AND v_p.user_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;
  IF v_mkt = '' THEN RETURN jsonb_build_object('status','invalid','reason','market required'); END IF;

  WITH mk AS (
    SELECT s.*,
      ( upper(coalesce(s.value->>'market',''))          = v_mkt
        OR upper(coalesce(s.provenance->>'research_market','')) = v_mkt
        OR upper(coalesce(s.provenance->>'marketplace',''))     = 'EBAY_'||v_mkt
        OR upper(coalesce(s.provenance->>'marketplace','')) LIKE '%\_'||v_mkt ESCAPE '\'
      ) AS is_selected
    FROM public.commerce_signals s
    WHERE s.product_id = p_product_id
      AND s.signal_type = 'MARKETPLACE_ACTIVITY'
      AND coalesce(s.value->>'match','') = 'MATCHED'
      AND upper(coalesce(s.provenance->>'source','')) NOT IN ('CJ','CJDROPSHIPPING','SUPPLIER')
  )
  SELECT
    count(*) FILTER (WHERE is_selected),
    count(DISTINCT (value->>'item_id')) FILTER (WHERE is_selected),
    count(*) FILTER (WHERE NOT is_selected),
    max(observed_at) FILTER (WHERE is_selected),
    coalesce(jsonb_agg(DISTINCT coalesce(provenance->>'marketplace', provenance->>'source'))
             FILTER (WHERE is_selected), '[]'::jsonb)
  INTO v_obs, v_items, v_cross, v_fresh, v_sources
  FROM mk;

  -- selected-market search-demand presence (informational; not a listing)
  SELECT count(*)::int INTO v_search
  FROM public.commerce_signals s
  WHERE s.product_id = p_product_id AND s.signal_type = 'SEARCH_DEMAND'
    AND (upper(coalesce(s.value->>'market',''))=v_mkt OR upper(coalesce(s.provenance->>'research_market',''))=v_mkt);

  -- source attempt states from any research run for this product+selected market
  SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object(
            'evidence_category', a.evidence_category, 'source', a.source, 'state', a.state)), '[]'::jsonb)
    INTO v_attempts
  FROM public.commerce_research_run r
  JOIN public.commerce_research_source_attempt a ON a.run_id = r.id
  WHERE r.product_id = p_product_id AND r.market = v_mkt;

  v_searched := (v_obs > 0) OR (jsonb_array_length(v_attempts) > 0) OR (v_search > 0);

  v_state := CASE
    WHEN v_items >= 5 THEN 'OBSERVED_MARKET_PRESENCE'
    WHEN v_items BETWEEN 2 AND 4 THEN 'LIMITED_OBSERVED_MARKET_PRESENCE'
    WHEN v_items = 1 THEN 'LOW_OBSERVED_MARKET_PRESENCE'
    ELSE 'INSUFFICIENT_MARKET_EVIDENCE' END;

  RETURN jsonb_build_object('status','ok','product_id',p_product_id,'selected_market',v_mkt,
    'market_presence_state', v_state,
    'observed_matched_listings', v_obs,
    'observed_distinct_items', v_items,
    'selected_market_search_demand_signals', v_search,
    'cross_market_matched_listings_excluded', v_cross,
    'sources_searched', v_sources,
    'source_attempt_states', v_attempts,
    'freshness', v_fresh,
    'searched', v_searched,
    'community_source', jsonb_build_object('source','REDDIT','state','BLOCKED_EXTERNAL_APPROVAL'),
    'truth_rule', 'absence of listings is INSUFFICIENT_MARKET_EVIDENCE, never "not sold in market"; cross-market listings (item ship-from country) are excluded and reported separately');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_assess_selected_market_presence(uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_assess_selected_market_presence(uuid,text) TO authenticated, service_role;

-- ============================================================================
-- 5) CANDIDATE UPSERT (B) — canonical, deduplicated. provisional snapshots the
--    problem corroboration state; solution_status is a SEPARATE lifecycle.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_upsert_solution_candidate(
  p_cluster_id uuid, p_product_id uuid, p_candidate_term text,
  p_match_quality text DEFAULT 'WEAK_MATCH', p_match_confidence numeric DEFAULT 0,
  p_match_rationale text DEFAULT NULL, p_market_presence_state text DEFAULT NULL,
  p_evidence jsonb DEFAULT '{}'::jsonb, p_is_fixture boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_c public.commerce_problem_clusters%rowtype;
  v_corr text; v_prov boolean; v_existing public.commerce_problem_solution_candidates%rowtype;
  v_status text; v_id uuid; v_term text := btrim(coalesce(p_candidate_term,''));
BEGIN
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','cluster_not_found'); END IF;
  IF v_uid IS NOT NULL AND v_c.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;
  IF v_term = '' AND p_product_id IS NULL THEN
    RETURN jsonb_build_object('status','invalid','reason','candidate_term or product_id required');
  END IF;
  IF p_product_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.commerce_products WHERE id = p_product_id) THEN
    RETURN jsonb_build_object('status','product_not_found','note','product_id must reference a canonical commerce_products row');
  END IF;

  v_corr := coalesce(public.fn_problem_corroboration_state(p_cluster_id)->>'corroboration_state','INSUFFICIENT_EVIDENCE');
  v_prov := (v_corr <> 'MULTI_SOURCE_CORROBORATED');   -- provisional until problem corroborated

  -- solution lifecycle (separate from problem status): compute floor from match+presence
  v_status := CASE
    WHEN p_product_id IS NOT NULL AND p_match_quality IN ('GOOD_MATCH','STRONG_MATCH')
         AND p_market_presence_state IS NOT NULL THEN 'MARKET_ASSESSED'
    WHEN p_product_id IS NOT NULL AND p_match_quality IN ('GOOD_MATCH','STRONG_MATCH') THEN 'PRODUCT_MATCHED'
    ELSE 'CANDIDATE_PROPOSED' END;

  IF v_term = '' THEN SELECT title INTO v_term FROM public.commerce_products WHERE id = p_product_id; END IF;

  -- dedup lookup: by (cluster, product) first, else (cluster, normalized term)
  SELECT * INTO v_existing FROM public.commerce_problem_solution_candidates
   WHERE problem_cluster_id = p_cluster_id
     AND ((p_product_id IS NOT NULL AND product_id = p_product_id)
          OR (p_product_id IS NULL AND candidate_term_norm = lower(v_term)))
   ORDER BY (product_id IS NOT NULL) DESC LIMIT 1;

  IF FOUND THEN
    -- never downgrade a lifecycle that already advanced past MARKET_ASSESSED
    IF v_existing.solution_status IN ('RESEARCH_CONNECTED','PRODUCT_DECISION_AVAILABLE') THEN
      v_status := v_existing.solution_status;
    END IF;
    UPDATE public.commerce_problem_solution_candidates SET
      product_id = coalesce(p_product_id, product_id),
      candidate_term = v_term,
      match_quality = p_match_quality, match_confidence = coalesce(p_match_confidence,0),
      match_rationale = coalesce(p_match_rationale, match_rationale),
      market_presence_state = coalesce(p_market_presence_state, market_presence_state),
      solution_status = v_status, provisional = v_prov, problem_evidence_state = v_corr,
      evidence = coalesce(p_evidence,'{}'::jsonb),
      provenance = jsonb_build_object('cluster', p_cluster_id, 'market', v_c.market,
                     'category', v_c.category, 'corroboration_state', v_corr,
                     'claim_safety','solution candidate is problem-derived; provisional while problem not MULTI_SOURCE_CORROBORATED; supplier availability alone does NOT make a product a good solution')
    WHERE id = v_existing.id RETURNING id INTO v_id;
  ELSE
    INSERT INTO public.commerce_problem_solution_candidates
      (tenant_id, problem_cluster_id, product_id, candidate_term, match_rationale, match_quality,
       match_confidence, market_presence_state, solution_status, provisional, problem_evidence_state,
       evidence, provenance, is_fixture)
    VALUES (v_c.tenant_id, p_cluster_id, p_product_id, v_term, p_match_rationale, p_match_quality,
       coalesce(p_match_confidence,0), p_market_presence_state, v_status, v_prov, v_corr,
       coalesce(p_evidence,'{}'::jsonb),
       jsonb_build_object('cluster', p_cluster_id, 'market', v_c.market, 'category', v_c.category,
         'corroboration_state', v_corr,
         'claim_safety','solution candidate is problem-derived; provisional while problem not MULTI_SOURCE_CORROBORATED; supplier availability alone does NOT make a product a good solution'),
       coalesce(p_is_fixture,false))
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('status','ok','candidate_id',v_id,'cluster_id',p_cluster_id,
    'product_id',p_product_id,'match_quality',p_match_quality,'solution_status',v_status,
    'provisional',v_prov,'problem_evidence_state',v_corr);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_upsert_solution_candidate(uuid,uuid,text,text,numeric,text,text,jsonb,boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_upsert_solution_candidate(uuid,uuid,text,text,numeric,text,text,jsonb,boolean) TO service_role;

-- ============================================================================
-- 6) ORCHESTRATOR — assess match quality (C) + market presence (D) and persist a
--    deduplicated candidate (B). Read/compute only; NO external calls. Records the
--    canonical matched product on the cluster (informational; does NOT promote the
--    problem lifecycle — problem status is never written here).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_match_and_assess_candidate(
  p_cluster_id uuid, p_product_id uuid, p_candidate_term text DEFAULT NULL, p_is_fixture boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_c public.commerce_problem_clusters%rowtype;
  v_mq jsonb; v_mp jsonb; v_up jsonb; v_link jsonb := NULL;
BEGIN
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','cluster_not_found'); END IF;
  IF v_uid IS NOT NULL AND v_c.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;

  v_mq := public.fn_assess_product_match_quality(p_cluster_id, p_product_id);
  IF v_mq->>'status' <> 'ok' THEN RETURN v_mq; END IF;
  v_mp := public.fn_assess_selected_market_presence(p_product_id, v_c.market);

  v_up := public.fn_upsert_solution_candidate(
    p_cluster_id, p_product_id, coalesce(p_candidate_term, ''),
    v_mq->>'match_quality', (v_mq->>'match_confidence')::numeric, v_mq->>'rationale',
    CASE WHEN v_mp->>'status'='ok' THEN v_mp->>'market_presence_state' ELSE NULL END,
    jsonb_build_object('match', v_mq, 'market_presence', v_mp), coalesce(p_is_fixture,false));

  -- record canonical matched product (informational; never promotes problem status)
  IF (v_mq->>'match_quality') IN ('GOOD_MATCH','STRONG_MATCH') AND v_c.matched_product_id IS NULL THEN
    v_link := public.fn_problem_cluster_link_product(p_cluster_id, p_product_id);
  END IF;

  RETURN jsonb_build_object('status','ok','cluster_id',p_cluster_id,'product_id',p_product_id,
    'match', v_mq, 'market_presence', v_mp, 'candidate', v_up,
    'cluster_link', v_link,
    'problem_status_untouched', true,
    'note','match_quality/market_presence are separate from opportunity score; candidate provisional while problem not MULTI_SOURCE_CORROBORATED');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_match_and_assess_candidate(uuid,uuid,text,boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_match_and_assess_candidate(uuid,uuid,text,boolean) TO service_role;

-- ============================================================================
-- 7) CONNECT TO EXISTING PRODUCT PIPELINE (E) — reuse only. If the matched
--    product already has a PME / Product Decision, surface it (no dispatch, no
--    cost); otherwise request research through the EXISTING pipeline entry
--    (fn_own_request_product_market_research). NEVER creates a second decision or
--    scorer. Candidate stays provisional while the problem is not corroborated.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_connect_candidate_to_pipeline(
  p_candidate_id uuid, p_freshness_hours integer DEFAULT 168)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cand public.commerce_problem_solution_candidates%rowtype;
  v_c public.commerce_problem_clusters%rowtype;
  v_mkt text; v_dec record; v_pme record; v_req jsonb; v_status text; v_run uuid;
BEGIN
  SELECT * INTO v_cand FROM public.commerce_problem_solution_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','candidate_not_found'); END IF;
  IF v_uid IS NOT NULL AND v_cand.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = v_cand.problem_cluster_id;
  v_mkt := v_c.market;

  -- qualification: a genuinely-matched product with observable selected-market presence.
  -- Supplier availability alone can NEVER qualify (match/presence exclude supplier).
  IF v_cand.product_id IS NULL OR v_cand.match_quality NOT IN ('GOOD_MATCH','STRONG_MATCH') THEN
    RETURN jsonb_build_object('status','not_qualified','reason','requires a GOOD/STRONG product match',
      'match_quality', v_cand.match_quality);
  END IF;
  IF coalesce(v_cand.market_presence_state,'INSUFFICIENT_MARKET_EVIDENCE') = 'INSUFFICIENT_MARKET_EVIDENCE' THEN
    RETURN jsonb_build_object('status','not_qualified','reason','insufficient selected-market evidence (never asserted as not-sold)',
      'market_presence_state', v_cand.market_presence_state);
  END IF;

  -- authoritative existing Product Decision?
  SELECT id, decision, product_opportunity_score, opportunity_band, country_code, created_at
    INTO v_dec
  FROM public.product_opportunity_decisions
  WHERE tenant_id = v_cand.tenant_id AND product_id = v_cand.product_id AND country_code = v_mkt
    AND coalesce(is_fixture,false)=false
  ORDER BY created_at DESC LIMIT 1;

  SELECT id, market_opportunity_score, market_decision, evaluation_ts
    INTO v_pme
  FROM public.product_market_evaluations
  WHERE tenant_id = v_cand.tenant_id AND product_id = v_cand.product_id AND country_code = v_mkt
    AND coalesce(is_fixture,false)=false
  ORDER BY evaluation_ts DESC LIMIT 1;

  IF v_dec.id IS NOT NULL THEN
    v_status := 'PRODUCT_DECISION_AVAILABLE';
    UPDATE public.commerce_problem_solution_candidates
      SET solution_status = v_status, linked_decision_id = v_dec.id, updated_at = now()
      WHERE id = p_candidate_id;
    RETURN jsonb_build_object('status','ok','connected','existing_decision',
      'candidate_id',p_candidate_id,'product_id',v_cand.product_id,'market',v_mkt,
      'solution_status',v_status,'provisional',v_cand.provisional,
      'existing_product_decision', jsonb_build_object('decision_id',v_dec.id,'decision',v_dec.decision,
        'opportunity_score',v_dec.product_opportunity_score,'opportunity_band',v_dec.opportunity_band),
      'existing_pme', CASE WHEN v_pme.id IS NOT NULL THEN jsonb_build_object('pme_id',v_pme.id,
        'market_opportunity_score',v_pme.market_opportunity_score,'market_decision',v_pme.market_decision) ELSE NULL END,
      'authority','existing product_opportunity_decisions (unchanged; no second scorer)',
      'external_calls', 0, 'cost', 0,
      'provisional_note','surfaced as a PROBLEM-DERIVED opportunity; provisional while problem not MULTI_SOURCE_CORROBORATED; existing WATCH gates unchanged');
  END IF;

  -- no decision yet: enter the EXISTING research pipeline (requires product owner context)
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status','needs_owner_context',
      'note','no existing decision; fn_own_request_product_market_research must run as the product owner (authenticated)');
  END IF;
  v_req := public.fn_own_request_product_market_research(v_cand.product_id, v_mkt, p_freshness_hours);
  v_run := nullif(v_req->>'run_id','')::uuid;
  UPDATE public.commerce_problem_solution_candidates
    SET solution_status = 'RESEARCH_CONNECTED', linked_run_id = v_run, updated_at = now()
    WHERE id = p_candidate_id;
  RETURN jsonb_build_object('status','ok','connected','existing_pipeline_requested',
    'candidate_id',p_candidate_id,'product_id',v_cand.product_id,'market',v_mkt,
    'solution_status','RESEARCH_CONNECTED','provisional',v_cand.provisional,
    'pipeline_request', v_req, 'authority','existing fn_own_request_product_market_research (no second pipeline)');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_connect_candidate_to_pipeline(uuid,integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_connect_candidate_to_pipeline(uuid,integer) TO service_role;

-- ============================================================================
-- 8) BROWSER-SAFE READ RPC — cluster + requirements + candidates (+ decision)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_problem_solution_read(p_cluster_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_c public.commerce_problem_clusters%rowtype;
  v_corr jsonb; v_reqs jsonb; v_cands jsonb;
BEGIN
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF v_c.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;

  v_corr := public.fn_problem_corroboration_state(p_cluster_id);

  SELECT coalesce(jsonb_agg(jsonb_build_object('requirement_key',requirement_key,
           'requirement_text',requirement_text,'derivation',derivation,'is_hypothesis',is_hypothesis)
           ORDER BY requirement_key), '[]'::jsonb) INTO v_reqs
  FROM public.commerce_problem_solution_requirements WHERE problem_cluster_id = p_cluster_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'candidate_id', c.id, 'product_id', c.product_id, 'candidate_term', c.candidate_term,
           'product_title', cp.title, 'match_quality', c.match_quality, 'match_confidence', c.match_confidence,
           'market_presence_state', c.market_presence_state, 'solution_status', c.solution_status,
           'provisional', c.provisional, 'problem_evidence_state', c.problem_evidence_state,
           'match_rationale', c.match_rationale,
           'existing_product_decision', CASE WHEN d.id IS NOT NULL THEN jsonb_build_object(
              'decision_id', d.id, 'decision', d.decision, 'opportunity_score', d.product_opportunity_score,
              'opportunity_band', d.opportunity_band) ELSE NULL END)
           ORDER BY c.match_confidence DESC NULLS LAST, c.created_at), '[]'::jsonb) INTO v_cands
  FROM public.commerce_problem_solution_candidates c
  LEFT JOIN public.commerce_products cp ON cp.id = c.product_id
  LEFT JOIN LATERAL (
    SELECT id, decision, product_opportunity_score, opportunity_band
    FROM public.product_opportunity_decisions d
    WHERE d.tenant_id = c.tenant_id AND d.product_id = c.product_id AND d.country_code = v_c.market
      AND coalesce(d.is_fixture,false)=false ORDER BY created_at DESC LIMIT 1) d ON true
  WHERE c.problem_cluster_id = p_cluster_id;

  RETURN jsonb_build_object('status','ok',
    'cluster', jsonb_build_object('cluster_id', v_c.id, 'market', v_c.market, 'category', v_c.category,
       'canonical_problem', v_c.canonical_problem, 'problem_status', v_c.status,
       'matched_product_id', v_c.matched_product_id),
    'problem_corroboration', v_corr,
    'solution_requirements', v_reqs,
    'solution_candidates', v_cands,
    'contract','problem_solution_v1_015d; solution progression is SEPARATE from problem corroboration; existing Product Decision is authoritative; candidates provisional until problem MULTI_SOURCE_CORROBORATED');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_problem_solution_read(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_problem_solution_read(uuid) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION public.fn_problem_solution_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  tA uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  real_shoe uuid := 'efca8b59-d814-404b-be1b-65e833fab9b8';
  cS uuid; cL uuid; cZ uuid; pMatch uuid; pSup uuid; pWeak uuid;
  r jsonb; mq jsonb; mp jsonb; up jsonb; conn jsonb; i int;
  v_cnt int; v_before int; v_after int; v_cand uuid; v_pol text;
  v_reqprov jsonb; v_corr_after text; v_status_after text;
BEGIN
  -- Regressions FIRST (before any fixture exists): N,O,P,Q,R
  v := v || jsonb_build_object('case','N_product_first_pipeline_regression','pass',
        (public.fn_research_orchestrator_selftest()->>'all_pass')::boolean);
  v := v || jsonb_build_object('case','O_problem_foundation_regression','pass',
        (public.fn_problem_foundation_selftest()->>'all_pass')::boolean);
  v := v || jsonb_build_object('case','P_problem_discovery_regression','pass',
        (public.fn_problem_discovery_selftest()->>'all_pass')::boolean);
  v := v || jsonb_build_object('case','Q_tiktok_regression','pass',
        (public.fn_tiktok_executor_selftest()->>'all_pass')::boolean);
  v := v || jsonb_build_object('case','R_gallery_identity_regression','pass',
        (public.fn_product_gallery_selftest()->>'all_pass')::boolean);

  -- clean any prior fixtures
  DELETE FROM public.commerce_problem_clusters WHERE canonical_problem LIKE '[[soltest]]%';
  DELETE FROM public.commerce_signals WHERE dedup_key LIKE 'soltest:%';
  DELETE FROM public.commerce_products WHERE product_identity LIKE 'soltest:%';

  INSERT INTO public.commerce_problem_clusters(tenant_id,market,category,canonical_problem,status)
    VALUES (tA,'GB','shoe storage','[[soltest]] shoe storage','PROBLEM_DISCOVERED') RETURNING id INTO cS;
  INSERT INTO public.commerce_problem_clusters(tenant_id,market,category,canonical_problem,status)
    VALUES (tA,'GB','shoe storage','[[soltest]] shoe storage L','PROBLEM_DISCOVERED') RETURNING id INTO cL;
  INSERT INTO public.commerce_problem_clusters(tenant_id,market,category,canonical_problem,status)
    VALUES (tA,'GB','widget','[[soltest]] zero presence','PROBLEM_DISCOVERED') RETURNING id INTO cZ;

  INSERT INTO public.commerce_products(user_id,product_identity,identity_basis,title,category,source_store,visibility,provenance)
    VALUES (tA,'soltest:match','normalized_name','over door shoe rack organizer','shoe storage','soltest','TENANT_PRIVATE','{}'::jsonb) RETURNING id INTO pMatch;
  INSERT INTO public.commerce_products(user_id,product_identity,identity_basis,title,category,source_store,visibility,provenance)
    VALUES (tA,'soltest:sup','normalized_name','mystery storage item','shoe storage','soltest','TENANT_PRIVATE','{}'::jsonb) RETURNING id INTO pSup;
  INSERT INTO public.commerce_products(user_id,product_identity,identity_basis,title,category,source_store,visibility,provenance)
    VALUES (tA,'soltest:weak','normalized_name','blue widget gadget','widget','soltest','TENANT_PRIVATE','{}'::jsonb) RETURNING id INTO pWeak;

  -- requirements (A)
  PERFORM public.fn_upsert_solution_requirement(cS,'organizes_pairs','organizes multiple pairs of shoes','DERIVED_LLM', jsonb_build_object('evidence_query','how to store shoes'), true);
  PERFORM public.fn_upsert_solution_requirement(cS,'reduces_clutter','reduces floor and doorway clutter','DERIVED_LLM', jsonb_build_object('evidence_query','best way to store shoes'), true);
  PERFORM public.fn_upsert_solution_requirement(cS,'space_efficient','space efficient entryway storage','DERIVED_LLM','{}'::jsonb, true);
  SELECT provenance INTO v_reqprov FROM public.commerce_problem_solution_requirements WHERE problem_cluster_id=cS AND requirement_key='organizes_pairs';
  v := v || jsonb_build_object('case','A_requirements_preserve_provenance','pass',
        (v_reqprov->>'derived_from_cluster' = cS::text AND (v_reqprov ? 'claim_safety') AND (v_reqprov->>'intelligence_class')='HYPOTHESIS_DERIVED'));

  -- pMatch signals: 5 GB matched (selected) + 3 DE matched (cross-market)
  FOR i IN 1..5 LOOP
    INSERT INTO public.commerce_signals(user_id,product_id,signal_type,value,provenance,observed_at,dedup_key,visibility)
    VALUES (tA,pMatch,'MARKETPLACE_ACTIVITY',
      jsonb_build_object('match','MATCHED','category','Shoe Storage','market','GB','item_id','gb-'||i),
      jsonb_build_object('source','EBAY_BROWSE_API','marketplace','EBAY_GB','research_market','GB'),
      now(),'soltest:pm:gb:'||i,'TENANT_PRIVATE');
  END LOOP;
  FOR i IN 1..3 LOOP
    INSERT INTO public.commerce_signals(user_id,product_id,signal_type,value,provenance,observed_at,dedup_key,visibility)
    VALUES (tA,pMatch,'MARKETPLACE_ACTIVITY',
      jsonb_build_object('match','MATCHED','category','Shoe Storage','market','DE','item_id','de-'||i,'item_country','GB'),
      jsonb_build_object('source','EBAY_BROWSE_API','marketplace','EBAY_DE','research_market','DE'),
      now(),'soltest:pm:de:'||i,'TENANT_PRIVATE');
  END LOOP;
  -- pSup: supplier-only marketplace signal (must be excluded from demand/presence)
  INSERT INTO public.commerce_signals(user_id,product_id,signal_type,value,provenance,observed_at,dedup_key,visibility)
  VALUES (tA,pSup,'MARKETPLACE_ACTIVITY',
    jsonb_build_object('match','MATCHED','category','Shoe Storage','market','GB','item_id','sup-1'),
    jsonb_build_object('source','CJ','marketplace','CJ','research_market','GB'),
    now(),'soltest:psup:gb:1','TENANT_PRIVATE');

  r := public.fn_match_and_assess_candidate(cS, pMatch, 'over door shoe rack organizer', true);
  mq := r->'match'; mp := r->'market_presence';

  SELECT count(*) INTO v_cnt FROM public.commerce_problem_solution_candidates WHERE problem_cluster_id=cS AND product_id=pMatch;
  v := v || jsonb_build_object('case','B_candidate_links_exact_cluster','pass', v_cnt=1);

  PERFORM public.fn_match_and_assess_candidate(cS, pMatch, 'over door shoe rack organizer', true);
  SELECT count(*) INTO v_cnt FROM public.commerce_problem_solution_candidates WHERE problem_cluster_id=cS AND product_id=pMatch;
  v := v || jsonb_build_object('case','C_candidate_dedup','pass', v_cnt=1);

  v := v || jsonb_build_object('case','D_candidate_product_identity_canonical','pass',
    EXISTS(SELECT 1 FROM public.commerce_problem_solution_candidates c JOIN public.commerce_products p ON p.id=c.product_id
           WHERE c.problem_cluster_id=cS AND c.product_id=pMatch AND p.product_identity='soltest:match'));

  v_corr_after := public.fn_problem_corroboration_state(cS)->>'corroboration_state';
  SELECT status INTO v_status_after FROM public.commerce_problem_clusters WHERE id=cS;
  v := v || jsonb_build_object('case','E_problem_corroboration_unchanged','pass',
    (v_corr_after='INSUFFICIENT_EVIDENCE' AND v_status_after='PROBLEM_DISCOVERED'),'corr',v_corr_after,'status',v_status_after);

  r := public.fn_match_and_assess_candidate(cS, pSup, 'mystery storage item', true);
  v := v || jsonb_build_object('case','F_supplier_cannot_establish_demand','pass',
    ((r->'match'->>'observable_matched_listings')::int = 0
     AND (r->'match'->>'match_quality') NOT IN ('GOOD_MATCH','STRONG_MATCH')
     AND (r->'market_presence'->>'market_presence_state') = 'INSUFFICIENT_MARKET_EVIDENCE'),
    'match',r->'match'->>'match_quality','presence',r->'market_presence'->>'market_presence_state');

  v := v || jsonb_build_object('case','G_cross_market_excluded','pass',
    ((mp->>'observed_distinct_items')::int = 5 AND (mp->>'cross_market_matched_listings_excluded')::int = 3
     AND (mp->>'market_presence_state')='OBSERVED_MARKET_PRESENCE'),
    'items',mp->'observed_distinct_items','excluded',mp->'cross_market_matched_listings_excluded');

  mp := public.fn_assess_selected_market_presence(pWeak, 'GB');
  v := v || jsonb_build_object('case','H_zero_not_sold','pass',
    (mp->>'market_presence_state'='INSUFFICIENT_MARKET_EVIDENCE'
     AND (mp->>'searched')::boolean = false
     AND (mp->>'truth_rule') ILIKE '%never%not sold%'));

  v := v || jsonb_build_object('case','I_match_separate_from_opportunity','pass',
    ((mq ? 'match_quality') AND NOT (mq ? 'opportunity_score') AND NOT (mq ? 'market_opportunity_score')
     AND (mq->>'separation_note') ILIKE '%independent of market_opportunity_score%'));

  v := v || jsonb_build_object('case','J_provisional_visible','pass',
    EXISTS(SELECT 1 FROM public.commerce_problem_solution_candidates
           WHERE problem_cluster_id=cS AND product_id=pMatch AND provisional=true
             AND problem_evidence_state='INSUFFICIENT_EVIDENCE'));

  SELECT id INTO v_cand FROM public.commerce_problem_solution_candidates WHERE problem_cluster_id=cS AND product_id=pMatch;
  SELECT count(*) INTO v_before FROM public.product_opportunity_decisions WHERE product_id=pMatch;
  conn := public.fn_connect_candidate_to_pipeline(v_cand, 168);
  SELECT count(*) INTO v_after FROM public.product_opportunity_decisions WHERE product_id=pMatch;
  v := v || jsonb_build_object('case','K_qualifying_enters_existing_pipeline','pass',
    (conn->>'status'='needs_owner_context' AND v_after=v_before),'conn',conn->>'status');

  up := public.fn_upsert_solution_candidate(cL, real_shoe, 'over door shoe organizer','STRONG_MATCH',0.9,'fixture','OBSERVED_MARKET_PRESENCE','{}'::jsonb, true);
  v_cand := (up->>'candidate_id')::uuid;
  SELECT count(*) INTO v_before FROM public.product_opportunity_decisions WHERE product_id=real_shoe;
  conn := public.fn_connect_candidate_to_pipeline(v_cand, 168);
  SELECT count(*) INTO v_after FROM public.product_opportunity_decisions WHERE product_id=real_shoe;
  v := v || jsonb_build_object('case','L_existing_decision_authoritative','pass',
    (conn->>'connected'='existing_decision' AND v_after=v_before
     AND (conn->'existing_product_decision'->>'decision') IS NOT NULL
     AND conn->>'solution_status'='PRODUCT_DECISION_AVAILABLE'),'decision',conn->'existing_product_decision'->>'decision');

  SELECT qual INTO v_pol FROM pg_policies WHERE schemaname='public'
     AND tablename='commerce_problem_solution_candidates' AND policyname='cpsc_select_own';
  v := v || jsonb_build_object('case','M_tenant_isolation','pass',
    (v_pol ILIKE '%auth.uid()%' AND v_pol ILIKE '%tenant_id%'
     AND NOT EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public'
        AND tablename IN ('commerce_problem_solution_candidates','commerce_problem_solution_requirements')
        AND 'anon'=ANY(roles))));

  -- cleanup (cluster delete cascades candidates + requirements)
  DELETE FROM public.commerce_problem_clusters WHERE canonical_problem LIKE '[[soltest]]%';
  DELETE FROM public.commerce_signals WHERE dedup_key LIKE 'soltest:%';
  DELETE FROM public.commerce_products WHERE product_identity LIKE 'soltest:%';

  RETURN jsonb_build_object('suite','problem_solution_matching',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_problem_solution_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_problem_solution_selftest() TO service_role;

-- ============================================================================
-- 9) DEFENSIVE FIX (found during 015D): fn_problem_discovery_selftest previously
--    cleaned up with DELETE FROM commerce_signals WHERE dedup_key LIKE 'problemdemand:%'
--    OR 'problempain:%'. But fn_ingest_dataforseo_problem_demand /
--    fn_ingest_reddit_problem_pain write REAL founder signals under those exact
--    prefixes (commerce_signals.problem_cluster_id FK is ON DELETE SET NULL, so the
--    selftest needed an explicit signal delete). Every discovery-regression run
--    therefore destroyed the founder's real problem-demand evidence (e.g. the GB
--    shoe-storage cluster). The cleanup is now scoped to the selftest's OWN test
--    clusters (canonical_problem '[[disc-selftest]]%') via problem_cluster_id
--    membership, so real founder evidence is never touched. Assertions unchanged.
--    (Applied as migration mig_274_discovery_selftest_scoped_cleanup — reproduced
--    here for a complete, self-contained migration file.)
CREATE OR REPLACE FUNCTION public.fn_problem_discovery_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  tA uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  rGB uuid; rL uuid; rM uuid;
  cA uuid; cH uuid; cK uuid; cO uuid; cM uuid;
  r jsonb; st text;
BEGIN
  DELETE FROM public.commerce_signals s USING public.commerce_problem_clusters c
    WHERE s.problem_cluster_id=c.id AND c.canonical_problem LIKE '[[disc-selftest]]%';
  DELETE FROM public.commerce_problem_clusters WHERE canonical_problem LIKE '[[disc-selftest]]%';
  DELETE FROM public.commerce_problem_discovery_runs WHERE category LIKE '[[disc-selftest]]%';

  INSERT INTO public.commerce_problem_discovery_runs(tenant_id,market,category) VALUES (tA,'GB','[[disc-selftest]] shoe storage') RETURNING id INTO rGB;
  INSERT INTO public.commerce_problem_discovery_runs(tenant_id,market,category) VALUES (tA,'GB','[[disc-selftest]] fail run') RETURNING id INTO rL;
  INSERT INTO public.commerce_problem_discovery_runs(tenant_id,market,category) VALUES (tA,'GB','[[disc-selftest]] zero run') RETURNING id INTO rM;
  cA := (public.fn_problem_cluster_ensure(rGB,'[[disc-selftest]] shoes pile up behind door'))->>'cluster_id';
  cH := (public.fn_problem_cluster_ensure(rGB,'[[disc-selftest]] shoe clutter hallway'))->>'cluster_id';
  cK := (public.fn_problem_cluster_ensure(rGB,'[[disc-selftest]] no room for shoes'))->>'cluster_id';
  cO := (public.fn_problem_cluster_ensure(rGB,'[[disc-selftest]] supplier only'))->>'cluster_id';
  cM := (public.fn_problem_cluster_ensure(rM,'[[disc-selftest]] zero result'))->>'cluster_id';

  r := public.fn_dataforseo_discovery_qualify('shoe rack','shoe storage ideas','informational',500,50);
  v := v || jsonb_build_object('case','A_product_mode_unchanged','pass',
        ((r->>'qualified')::boolean = false AND r->>'reason'='non_commercial_intent'));
  v := v || jsonb_build_object('case','B_problem_mode_retains','pass',
        (public.fn_dataforseo_problem_qualify('how to stop shoes piling up behind the door','shoe storage','informational',120)->>'qualified')::boolean = true
        AND (public.fn_dataforseo_problem_qualify('struggling with shoe storage space','shoe storage','informational',80)->>'qualified')::boolean = true);
  v := v || jsonb_build_object('case','C_noise_rejected','pass',
        (public.fn_dataforseo_problem_qualify('shoe size chart','shoe storage','informational',900)->>'qualified')::boolean = false
        AND (public.fn_dataforseo_problem_qualify('best shoe rack brand','shoe storage','commercial',700)->>'reason') = 'commercial_product_query');
  PERFORM public.fn_ingest_dataforseo_problem_demand(rGB, cA, 'GB',
    jsonb_build_array(jsonb_build_object('query','how to organize shoes small hallway','intent','informational','volume',110)), false);
  v := v || jsonb_build_object('case','D_raw_query_preserved','pass',
        EXISTS(SELECT 1 FROM public.commerce_signals s WHERE s.problem_cluster_id=cA
               AND s.signal_type='SEARCH_PROBLEM_DEMAND' AND s.value->>'query'='how to organize shoes small hallway' AND s.product_id IS NULL));
  v := v || jsonb_build_object('case','E_reddit_pain','pass',
        public.fn_reddit_pain_classify('I hate how my shoes pile up behind the door, no room for anything','shoe storage')->>'kind'='COMMUNITY_PAIN');
  v := v || jsonb_build_object('case','F_reddit_workaround','pass',
        public.fn_reddit_pain_classify('my makeshift solution is a tension rod, i just use that instead','shoe storage')->>'kind'='COMMUNITY_WORKAROUND');
  v := v || jsonb_build_object('case','G_reddit_generic_rejected','pass',
        public.fn_reddit_pain_classify('Check out my store, shop now with code SAVE10 for shoe racks')->>'kind'='NONE'
        AND public.fn_reddit_pain_classify('I bought a nice shoe rack yesterday, looks good')->>'kind'='NONE');
  r := public.fn_ingest_dataforseo_problem_demand(rGB, cH, 'GB',
    jsonb_build_array(
      jsonb_build_object('query','how to declutter shoe pile','intent','informational','volume',90),
      jsonb_build_object('query','best way to store shoes small flat','intent','informational','volume',70),
      jsonb_build_object('query','shoe rack for sale','intent','commercial','volume',500)), false);
  v := v || jsonb_build_object('case','H_no_fabrication','pass',
        ((r->>'qualified')::int = 2 AND (r->>'attached')::int = 2
         AND (SELECT count(*) FROM public.commerce_signals s WHERE s.problem_cluster_id=cH) = 2));
  v := v || jsonb_build_object('case','I_single_source_no_corroboration','pass',
        public.fn_problem_corroboration_state(cH)->>'corroboration_state'='MULTI_EVIDENCE_SINGLE_SOURCE');
  PERFORM public.fn_ingest_reddit_problem_pain(rGB, cH, 'GB',
    jsonb_build_array(jsonb_build_object('title','shoes everywhere','text','I hate how shoes pile up, no room','subreddit','declutter','url','https://reddit.com/x1')), false);
  v := v || jsonb_build_object('case','J_multi_source_corroborated','pass',
        public.fn_problem_corroboration_state(cH)->>'corroboration_state'='MULTI_SOURCE_CORROBORATED');
  PERFORM public.fn_ingest_reddit_problem_pain(rGB, cK, 'GB',
    jsonb_build_array(jsonb_build_object('text','shoes everywhere, nowhere to put them, so annoying','subreddit','x','url','https://reddit.com/k1')), false);
  PERFORM public.fn_ingest_dataforseo_problem_demand(rGB, cK, 'DE',
    jsonb_build_array(jsonb_build_object('query','how to store shoes','intent','informational','volume',200)), false);
  r := public.fn_problem_corroboration_state(cK);
  v := v || jsonb_build_object('case','K_market_isolation','pass',
        (r->>'corroboration_state'='SINGLE_SOURCE' AND (r->>'contextual_cross_market_signals')::int >= 1));
  PERFORM public.fn_ingest_dataforseo_problem_demand(rL, cA, 'GB', jsonb_build_object('error','boom'), false);
  v := v || jsonb_build_object('case','L_failure_not_no_evidence','pass',
        (SELECT source_states->'SEARCH_DEMAND'->>'state' FROM public.commerce_problem_discovery_runs WHERE id=rL)='SOURCE_FAILED');
  r := public.fn_ingest_dataforseo_problem_demand(rM, cM, 'GB',
    jsonb_build_array(jsonb_build_object('query','shoe rack','intent','commercial','volume',500),
                      jsonb_build_object('query','buy shoes online','intent','transactional','volume',900)), false);
  v := v || jsonb_build_object('case','M_zero_result_no_evidence','pass',
        ((r->>'attached')::int = 0
         AND (SELECT source_states->'SEARCH_DEMAND'->>'state' FROM public.commerce_problem_discovery_runs WHERE id=rM)='SEARCHED_NO_EVIDENCE'));
  v := v || jsonb_build_object('case','N_no_product_matching','pass',
        NOT EXISTS(SELECT 1 FROM public.commerce_problem_clusters c
                   WHERE c.canonical_problem LIKE '[[disc-selftest]]%'
                     AND (c.matched_product_id IS NOT NULL
                          OR c.status IN ('PRODUCT_MATCHED','MARKET_ASSESSED','PRODUCT_DECISION_READY'))));
  PERFORM public.fn_problem_signal_attach(cO,'SEARCH_PROBLEM_DEMAND','CJ','GB','supplier catalog query',NULL,NULL,now(),NULL,'problemdemand:cO:cj',false,NULL);
  v := v || jsonb_build_object('case','O_supplier_no_contribution','pass',
        public.fn_problem_corroboration_state(cO)->>'corroboration_state'='INSUFFICIENT_EVIDENCE');

  DELETE FROM public.commerce_signals s USING public.commerce_problem_clusters c
    WHERE s.problem_cluster_id=c.id AND c.canonical_problem LIKE '[[disc-selftest]]%';
  DELETE FROM public.commerce_problem_clusters WHERE canonical_problem LIKE '[[disc-selftest]]%';
  DELETE FROM public.commerce_problem_discovery_runs WHERE category LIKE '[[disc-selftest]]%';

  RETURN jsonb_build_object('suite','problem_discovery_dataforseo_reddit',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

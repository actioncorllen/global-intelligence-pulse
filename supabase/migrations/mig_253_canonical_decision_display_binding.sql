-- ============================================================================
-- mig_253_canonical_decision_display_binding.sql
-- STRATELOQ-ECOM-CANONICAL-MARKET-DECISION-BINDING-013O3
--
-- DEFECT: the Product Decision card showed the same stale opportunity_score
-- (75.5) / coverage (0.70) / band (STRONG_TEST) / confidence (LOW) for every
-- market, even though the canonical per-market evaluation diverges
-- (GB 68.2 / DE 73.2, both HIGH, coverage 0.78).
--
-- ROOT CAUSE (backend, not frontend): fn_ecommerce_workspace_intelligence and
-- fn_ecommerce_research_coverage read the numeric decision fields straight from
-- product_opportunity_decisions — a decision snapshot last written by the
-- discovery evaluator (fn_pod_evaluate) on 09-14. The research recompute path
-- (fn_finalize_research_run -> fn_assemble_real_product_market ->
-- fn_evaluate_product_market) writes product_market_evaluations (PME) only; it
-- never refreshes the decision snapshot. So PME is current while the decision
-- cache is frozen, and both read-RPCs surfaced the frozen cache.
--
-- FIX (smallest additive READ-contract correction; no recompute, no number
-- copying, no history rewrite): both RPCs now source the current authoritative
-- opportunity_score / coverage / evidence_confidence / decision / band /
-- evaluation timestamp+version from the canonical current PME row for the
-- (product_id, country_code), via a LEFT JOIN LATERAL that always picks the
-- most-recent non-fixture PME (so no row multiplication). When a decision has
-- no PME row yet, its own snapshot value is kept (coalesce). The band is
-- derived from the CURRENT score using the system's own existing ladder
-- (extracted verbatim from fn_pod_evaluate) — not a new scoring system.
--
-- product_opportunity_decisions is left completely intact (historical decision
-- context / provenance preserved). Nothing is deleted or rewritten. No WPS
-- scoring change. No provider calls.
-- ============================================================================

-- Canonical opportunity band ladder — verbatim from fn_pod_evaluate (score->band).
-- Pure/immutable; a read-side label over the already-computed canonical score.
CREATE OR REPLACE FUNCTION public.fn_ecommerce_opportunity_band(p_score numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO '' AS $function$
  SELECT CASE
    WHEN p_score IS NULL THEN 'INSUFFICIENT'
    WHEN p_score < 40 THEN 'AVOID'
    WHEN p_score < 55 THEN 'WATCH'
    WHEN p_score < 70 THEN 'TRENDING_WATCH'
    WHEN p_score < 80 THEN 'STRONG_TEST'
    WHEN p_score < 90 THEN 'HIGH_CONFIDENCE_TEST'
    ELSE 'EXCEPTIONAL' END;
$function$;
REVOKE ALL ON FUNCTION public.fn_ecommerce_opportunity_band(numeric) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_ecommerce_opportunity_band(numeric) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- fn_ecommerce_research_coverage: numeric decision fields now from canonical PME
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_research_coverage()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT coalesce(jsonb_agg(row ORDER BY (row->>'opportunity_score')::numeric DESC NULLS LAST), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'decision_id', d.id, 'product_id', d.product_id, 'product_title', cp.title, 'market', d.country_code,
      'opportunity_score', coalesce(pme.market_opportunity_score, d.product_opportunity_score),
      'coverage', coalesce(pme.coverage, d.coverage),
      'opportunity_band', CASE WHEN pme.market_opportunity_score IS NOT NULL
                               THEN public.fn_ecommerce_opportunity_band(pme.market_opportunity_score)
                               ELSE d.opportunity_band END,
      'evidence_confidence', coalesce(pme.evidence_confidence, d.overall_evidence_confidence),
      'decision', coalesce(pme.market_decision, d.decision),
      'evaluated_at', pme.evaluation_ts,
      'score_version', coalesce(pme.score_version, d.score_version),
      'evaluation_source', CASE WHEN pme.market_opportunity_score IS NOT NULL
                                THEN 'product_market_evaluations' ELSE 'product_opportunity_decisions' END,
      'labels', public.fn_ecommerce_opportunity_labels(
                  CASE WHEN pme.market_opportunity_score IS NOT NULL
                       THEN public.fn_ecommerce_opportunity_band(pme.market_opportunity_score)
                       ELSE d.opportunity_band END,
                  coalesce(pme.evidence_confidence, d.overall_evidence_confidence)),
      'sources', ss.s, 'sources_expected', 6, 'sources_with_evidence', agg.found,
      'sources_not_searched', agg.not_searched, 'sources_blocked_or_unsupported', agg.blocked,
      'independent_categories', agg.found, 'launch_critical_gap', agg.launch_gap,
      'research_status', CASE WHEN agg.not_searched > 0 THEN 'PARTIAL'
          WHEN agg.blocked > 0 THEN 'PARTIAL_SOURCE_UNAVAILABLE' ELSE 'COMPLETE' END,
      'grade', public.fn_ecommerce_evidence_grade(agg.found, coalesce(pme.evidence_confidence, d.overall_evidence_confidence), agg.launch_gap)
    ) AS row
    FROM public.product_opportunity_decisions d
    JOIN public.commerce_products cp ON cp.id = d.product_id
    LEFT JOIN LATERAL (
      SELECT e.market_opportunity_score, e.coverage, e.evidence_confidence, e.market_decision, e.evaluation_ts, e.score_version
      FROM public.product_market_evaluations e
      WHERE e.tenant_id = d.tenant_id AND e.product_id = d.product_id AND e.country_code = d.country_code
        AND coalesce(e.is_fixture,false) = false
      ORDER BY e.evaluation_ts DESC NULLS LAST LIMIT 1
    ) pme ON true
    CROSS JOIN LATERAL (SELECT public.fn_ecommerce_research_source_states(v_uid, d.product_id, d.country_code) AS s) ss
    CROSS JOIN LATERAL (
      SELECT
        (SELECT count(*) FROM jsonb_array_elements(ss.s) e WHERE e->>'state'='SEARCHED_EVIDENCE_FOUND')::int AS found,
        (SELECT count(*) FROM jsonb_array_elements(ss.s) e WHERE e->>'state'='NOT_SEARCHED')::int AS not_searched,
        (SELECT count(*) FROM jsonb_array_elements(ss.s) e WHERE e->>'state' IN ('BLOCKED_EXTERNAL_ACCESS','UNSUPPORTED_MARKET','SOURCE_UNAVAILABLE'))::int AS blocked,
        coalesce((SELECT bool_or(e->>'evidence_category' IN ('ADVERTISING','SOCIAL_VIDEO') AND e->>'state' <> 'SEARCHED_EVIDENCE_FOUND') FROM jsonb_array_elements(ss.s) e), true) AS launch_gap
    ) agg
    WHERE d.tenant_id = v_uid AND coalesce(d.is_fixture,false) = false
  ) z;
  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'coverage', v_rows,
    'source_contract','product_market_evaluations (current WPS) overlaid on product_opportunity_decisions; source states live from evidence',
    'note','opportunity_score/coverage/evidence_confidence/decision/band are the CURRENT canonical per-market evaluation (product_market_evaluations); decision context is historical. Source states derived live; NOT_SEARCHED != SEARCHED_NO_EVIDENCE. No provider was called.');
END; $function$;

-- ---------------------------------------------------------------------------
-- fn_ecommerce_workspace_intelligence: product_decisions[] numeric fields from PME
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_workspace_intelligence()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_member_count integer; v_member_id uuid; v_app uuid;
    v_bp public.business_profiles%ROWTYPE; v_found boolean := false;
    v_decisions jsonb; v_storefronts jsonb; v_evidence jsonb; v_products int;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;

    SELECT count(*), min(m.id::text)::uuid, min(m.application_ref::text)::uuid
      INTO v_member_count, v_member_id, v_app
    FROM public.member AS m WHERE m.auth_user_id = v_uid;
    IF v_member_count = 0 THEN RETURN jsonb_build_object('status','no_member'); END IF;
    IF v_member_count > 1 THEN RAISE EXCEPTION 'member cardinality violation' USING ERRCODE='P0001'; END IF;

    SELECT * INTO v_bp FROM public.business_profiles WHERE application_id = v_app;
    IF FOUND THEN v_found := true; END IF;
    IF NOT v_found THEN
        SELECT * INTO v_bp FROM public.business_profiles WHERE user_id = v_uid
        ORDER BY updated_at DESC NULLS LAST LIMIT 1;
        IF FOUND THEN v_found := true; END IF;
    END IF;
    IF v_found AND v_bp.user_id IS NOT NULL AND v_bp.user_id <> v_uid THEN
        RAISE EXCEPTION 'business profile ownership violation' USING ERRCODE='P0001';
    END IF;

    SELECT coalesce(jsonb_agg(row ORDER BY (row->>'opportunity_score')::numeric DESC NULLS LAST), '[]'::jsonb) INTO v_decisions FROM (
        SELECT jsonb_build_object(
            'decision_id', d.id,
            'product_id', d.product_id,
            'product_title', cp.title,
            'product_category', cp.category,
            'product_url', cp.product_url,
            'source_store', cp.source_store,
            'observed_price', cp.observed_price,
            'currency', cp.price_currency,
            'availability', cp.availability,
            'decision', coalesce(pme.market_decision, d.decision),
            'opportunity_band', CASE WHEN pme.market_opportunity_score IS NOT NULL
                                     THEN public.fn_ecommerce_opportunity_band(pme.market_opportunity_score)
                                     ELSE d.opportunity_band END,
            'opportunity_score', coalesce(pme.market_opportunity_score, d.product_opportunity_score),
            'coverage', coalesce(pme.coverage, d.coverage),
            'product_confidence', d.product_confidence,
            'evidence_confidence', coalesce(pme.evidence_confidence, d.overall_evidence_confidence),
            'evaluated_at', pme.evaluation_ts,
            'score_version', coalesce(pme.score_version, d.score_version),
            'evaluation_source', CASE WHEN pme.market_opportunity_score IS NOT NULL
                                      THEN 'product_market_evaluations' ELSE 'product_opportunity_decisions' END,
            'country_code', d.country_code,
            'primary_platform', d.primary_platform,
            'lifecycle_state', d.lifecycle_state,
            'action_gating', d.action_gating,
            'decision_reasons', coalesce(d.decision_reasons, '[]'::jsonb),
            'saturation_state', coalesce(d.saturation_state, 'null'::jsonb),
            'advertising_headroom', coalesce(d.advertising_headroom, 'null'::jsonb),
            'opportunity_sweet_spot', coalesce(d.opportunity_sweet_spot, 'null'::jsonb),
            'storefront', (
                SELECT jsonb_build_object('page_id', pg.id, 'status', pg.status,
                                          'publication_state', pg.publication_state)
                FROM public.commerce_product_pages pg
                WHERE pg.user_id = v_uid AND pg.product_id = d.product_id
                ORDER BY pg.updated_at DESC NULLS LAST LIMIT 1)
        ) AS row
        FROM public.product_opportunity_decisions d
        JOIN public.commerce_products cp ON cp.id = d.product_id
        LEFT JOIN LATERAL (
          SELECT e.market_opportunity_score, e.coverage, e.evidence_confidence, e.market_decision, e.evaluation_ts, e.score_version
          FROM public.product_market_evaluations e
          WHERE e.tenant_id = d.tenant_id AND e.product_id = d.product_id AND e.country_code = d.country_code
            AND coalesce(e.is_fixture,false) = false
          ORDER BY e.evaluation_ts DESC NULLS LAST LIMIT 1
        ) pme ON true
        WHERE d.tenant_id = v_uid AND coalesce(d.is_fixture, false) = false
    ) z;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'signal_type', s.signal_type, 'count', s.n, 'last_observed', s.last_obs)
            ORDER BY s.n DESC), '[]'::jsonb) INTO v_evidence
    FROM (SELECT signal_type, count(*) n, max(observed_at) last_obs
          FROM public.commerce_signals WHERE user_id = v_uid GROUP BY signal_type) s;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'page_id', pg.id, 'product_id', pg.product_id, 'product_title', cp2.title,
                'status', pg.status, 'publication_state', pg.publication_state,
                'market', pg.market, 'country_code', pg.country_code,
                'opportunity_decision_id', pg.opportunity_decision_id)), '[]'::jsonb)
      INTO v_storefronts
    FROM public.commerce_product_pages pg
    LEFT JOIN public.commerce_products cp2 ON cp2.id = pg.product_id
    WHERE pg.user_id = v_uid;

    SELECT count(*) INTO v_products FROM public.commerce_products WHERE user_id = v_uid;

    RETURN jsonb_build_object(
        'status', 'ok',
        'category', CASE WHEN v_found THEN v_bp.business_category ELSE NULL END,
        'is_ecommerce', coalesce(v_found AND v_bp.business_category = 'ecommerce', false),
        'business', CASE WHEN v_found THEN jsonb_build_object(
              'business_name', v_bp.business_name, 'industry', v_bp.industry,
              'country', v_bp.country, 'business_category', v_bp.business_category)
            ELSE 'null'::jsonb END,
        'product_decisions', v_decisions,
        'product_decision_count', jsonb_array_length(v_decisions),
        'products_tracked', v_products,
        'evidence_summary', v_evidence,
        'storefronts', v_storefronts,
        'source_contract', 'product_opportunity_decisions overlaid with current product_market_evaluations (canonical per-market WPS)+commerce_products+commerce_signals+commerce_product_pages',
        'provenance_vocabulary', jsonb_build_array('OBSERVED','INFERRED','RESEARCHED')
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('status','temporary_failure');
END;
$function$;

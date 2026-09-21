-- ============================================================================
-- mig_260_workspace_provisional_decision_flag.sql
-- STRATELOQ-ECOM-DECISION-WATCH-AUDIT-013V
--
-- AUDIT FINDING (proven, not assumed):
--  * Every founder product's top-level decision is WATCH. This is TRUTHFUL and
--    canonical: fn_pod_evaluate returns WATCH because each product has one or more
--    mandatory hard gates in WATCH state (supplier stock / economics / compliance /
--    fulfilment are UNKNOWN -> fail-closed), reason CANNOT_TEST_UNTIL_GATES_RESOLVE.
--    Bands vary materially (EXCEPTIONAL / HIGH_CONFIDENCE_TEST / STRONG_TEST /
--    TRENDING_WATCH / INSUFFICIENT) — band != decision by design. The decision is
--    read from the canonical stored evaluation (pme.market_decision == pod decision),
--    is NOT stale (pme_ts == pod_ts on every row), NOT a hardcoded default.
--  * NARROW LIFECYCLE-REPRESENTATION DEFECT: two DataForSEO-discovered candidates
--    that never underwent deep research (no commerce_research_run; PME score IS NULL,
--    coverage 0, evidence_confidence NONE, band INSUFFICIENT) were materialised as
--    Product Decisions by the weekly Monday orchestrator and surface with the SAME
--    top-level "WATCH" chip as completed deep-research decisions. Their values are
--    truthful (INSUFFICIENT / NONE / null), but the contract carried no explicit
--    machine-readable "this decision is provisional / research incomplete" marker,
--    so a customer could mistake a preliminary decision for a completed one.
--
-- SMALLEST SAFE CORRECTION (source-agnostic; additive; read-time only):
--  expose two derived fields on each product_decision so incomplete research is
--  clearly represented WITHOUT changing any decision, score, band, threshold, gate,
--  or stored record, and without frontend inference:
--    decision_provisional     boolean  -- true when the canonical PME has no usable
--                                          score (score IS NULL) => not yet evaluable
--    research_evidence_state  text     -- 'INSUFFICIENT_EVIDENCE' | 'EVALUATED'
--  Derived purely from the canonical latest product+market evaluation (authoritative).
--  No source_store special-casing, GB/DE isolation preserved (per product+market),
--  historical records untouched, no WPS scoring change, no provider call.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ecommerce_workspace_intelligence()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
            'product_image_url', img.img_url,
            'product_image_source', img.img_source,
            'product_image_source_url', img.img_source_url,
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
            -- 013V: truthful provisional/lifecycle marker so a preliminary (not-yet-
            -- evaluable) decision is never mistaken for a completed deep-research one.
            'decision_provisional', (pme.market_opportunity_score IS NULL),
            'research_evidence_state', CASE WHEN pme.market_opportunity_score IS NULL
                                            THEN 'INSUFFICIENT_EVIDENCE' ELSE 'EVALUATED' END,
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
        LEFT JOIN LATERAL (
          SELECT
            coalesce(spa.source_url, nullif(sp.image_url,'')) AS img_url,
            CASE WHEN coalesce(spa.source_url, nullif(sp.image_url,'')) IS NOT NULL
                 THEN 'SUPPLIER_PROVIDED' END AS img_source,
            coalesce(spa.source_url, nullif(sp.image_url,'')) AS img_source_url
          FROM public.commerce_supplier_products sp
          LEFT JOIN LATERAL (
            SELECT a.source_url
            FROM public.supplier_product_assets a
            WHERE a.supplier_product_id = sp.source_product_id
              AND a.availability = 'AVAILABLE'
              AND a.rights_state = 'SUPPLIER_PROVIDED'
              AND a.asset_type IN ('PRIMARY_IMAGE','IMAGE')
              AND coalesce(a.source_url,'') <> ''
            ORDER BY a.is_primary DESC, (a.asset_type='PRIMARY_IMAGE') DESC
            LIMIT 1
          ) spa ON true
          WHERE sp.id = coalesce(nullif(cp.extended->'supplier_ref'->>'supplier_row_id',''),
                                 nullif(cp.extended->'supplier_refs'->0->>'supplier_row_id',''))::uuid
          LIMIT 1
        ) img ON true
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
        'source_contract', 'product_opportunity_decisions overlaid with current product_market_evaluations (canonical per-market WPS)+commerce_products+commerce_signals+commerce_product_pages; product image via canonical supplier link (supplier_product_assets primary, rights-honoured); decision_provisional/research_evidence_state derived from canonical PME',
        'provenance_vocabulary', jsonb_build_array('OBSERVED','INFERRED','RESEARCHED')
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('status','temporary_failure');
END;
$function$;

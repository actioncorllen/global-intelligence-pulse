-- ============================================================================
-- mig_292_workspace_supplier_match_exposure.sql
-- STRATELOQ-STAGE4-DISCOVERY-TO-VERIFIED-SUPPLIER
--
-- GAP (proven, not assumed): the authoritative Ecommerce workspace Product Card
-- contract fn_ecommerce_workspace_intelligence() (mig_260) surfaces the per-market
-- decision, evidence and a rights-honoured supplier IMAGE, but it never exposes the
-- CONCRETE SUPPLIER MATCH that the (out-of-repo) matching engine already resolves
-- into public.commerce_concrete_supplier_resolution — so the Stage-4 journey
-- "...-> Match CJ Supplier -> Verify Exact SKU -> Product Card" stops short of the
-- card: the customer cannot see the CJ product id / exact SKU / match state.
--
-- Verified in production before this change (founder tenant):
--   kids nightlight projector/GB -> CJDROPSHIPPING product 2608250310481611400,
--     SKU CJYD3093228, state CONCRETE_PRODUCT_AMBIGUOUS, offer cost 5.73 USD stock 3.
--   cool mist humidifier/GB -> CONCRETE_RESOLVED, unbound (no sku).
--   coaxial cable/US -> no resolution row.
--
-- SMALLEST SAFE CORRECTION (additive, read-time only; mirrors the mig_257/mig_260
-- pattern): add ONE derived key `supplier_match` to each product_decision, read from
-- the canonical commerce_concrete_supplier_resolution for (tenant, product, market=
-- country_code) and the supplier offer from commerce_supplier_products. No decision,
-- score, band, gate, threshold or stored record changes; no provider call.
--
-- Rules honoured:
--  * COUNTRY ISOLATION: joined on market = d.country_code (per product+country).
--  * SUPPLIER-NEUTRAL (§7): reads selected_supplier generically (CJ today, another
--    approved provider tomorrow); never hardcodes CJ; canonical product identity
--    (opportunity_product_id) stays the key, independent of supplier identity.
--  * HONEST STATES (§6/§8): AMBIGUOUS is reported as AMBIGUOUS (never as a confident
--    match) even when the engine bound it; an unmatched product still returns its
--    decision row (opportunity NOT hidden) with supplier_match.status='UNMATCHED'.
--  * ASSET LOCK (§9): unchanged — the rights-honoured image path (SUPPLIER_PROVIDED
--    only) is preserved; supplier_match adds a product_url link + economics/stock,
--    never new image rights.
--  * Supplier-offer join is on source_product_id (unique per supplier product), so
--    the known supplier-name casing variance (CJ / cjdropshipping / CJDROPSHIPPING)
--    cannot drop the offer.
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
            -- STAGE4: concrete CJ (supplier-neutral) match for THIS product+country.
            -- Never hides the opportunity when unmatched; never presents AMBIGUOUS as
            -- confident; country-isolated (market=country_code); offer joined by
            -- source_product_id so supplier-name casing cannot drop it.
            'supplier_match', coalesce((
                SELECT jsonb_build_object(
                    'status', CASE
                        WHEN r.concrete_state = 'CONCRETE_PRODUCT_AMBIGUOUS' THEN 'AMBIGUOUS'
                        WHEN r.concrete_state = 'NO_CONCRETE_EVIDENCE'        THEN 'NO_SUPPLIER_EVIDENCE'
                        WHEN coalesce(r.bound,false) AND r.selected_sku IS NOT NULL THEN 'MATCHED'
                        WHEN r.id IS NOT NULL THEN 'RESOLVED_UNBOUND'
                        ELSE 'UNMATCHED' END,
                    'provider', r.selected_supplier,
                    'supplier_product_id', r.selected_supplier_product_id,
                    'sku', r.selected_sku,
                    'variant', r.selected_variant,
                    'bound', coalesce(r.bound,false),
                    'concrete_state', r.concrete_state,
                    'has_contradiction', (r.contradictory_evidence IS NOT NULL
                                          AND r.contradictory_evidence::text <> 'null'),
                    'matched_at', r.bound_at,
                    'offer', (
                        SELECT jsonb_build_object(
                            'supplier_cost', sp.supplier_cost, 'cost_currency', sp.cost_currency,
                            'stock_state', sp.sale_status, 'is_free_shipping', sp.is_free_shipping,
                            'ships_to', sp.shipping_country_codes, 'product_url', sp.product_url,
                            'sku', sp.sku, 'observed_at', sp.last_seen_at)
                        FROM public.commerce_supplier_products sp
                        WHERE sp.source_product_id = r.selected_supplier_product_id
                        ORDER BY sp.last_seen_at DESC NULLS LAST LIMIT 1)
                )
                FROM public.commerce_concrete_supplier_resolution r
                WHERE r.tenant_id = d.tenant_id AND r.opportunity_product_id = d.product_id
                  AND r.market = d.country_code AND coalesce(r.is_fixture,false) = false
                ORDER BY r.created_at DESC LIMIT 1
            ), jsonb_build_object('status','UNMATCHED','bound',false)),
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
        'source_contract', 'product_opportunity_decisions overlaid with current product_market_evaluations (canonical per-market WPS)+commerce_products+commerce_signals+commerce_product_pages; product image via canonical supplier link (supplier_product_assets primary, rights-honoured); supplier_match via commerce_concrete_supplier_resolution (per product+country, supplier-neutral, rights-preserving)+commerce_supplier_products offer; decision_provisional/research_evidence_state derived from canonical PME',
        'provenance_vocabulary', jsonb_build_array('OBSERVED','INFERRED','RESEARCHED')
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('status','temporary_failure');
END;
$function$;

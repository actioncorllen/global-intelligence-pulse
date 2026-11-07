-- mig_335_recommendations_quality.sql
-- Recommendations quality fix (founder directive 2026-11-07). Refinement of fn_monday_top_opportunities only;
-- no re-score, no decision change, no new table, no new paid provider call. Builds on mig_334 (v3_tiers).
--
-- STATUS: PREPARED FOR FOUNDER REVIEW — *** NOT YET APPLIED TO PROD nxaunmyihhjixxxljcqt ***.
--
-- Changes (all card-level, display-honesty + showcase gating):
--  1. Evidence-gated `why`: say "Real demand" ONLY when demand is corroborated (overall_evidence_confidence>=MEDIUM)
--     AND has a named source; otherwise "Demand not sufficiently verified". (Fixes "Real demand" without evidence.)
--  2. `evidence_fresh` gated on sourced demand: a product with no corroborated/sourced demand never reports fresh
--     (frontend then shows "Evidence unavailable — freshness cannot be established"). (Fixes "Evidence: None · fresh".)
--  3. Marketplace-reference image fallback (founder approved "show matched marketplace imgs as Reference"): when no
--     supplier-authoritative hero asset exists, surface the best MATCHED marketplace image from product_image_assets,
--     clearly flagged reference:true, hero_eligible:false, rights_state=MARKETPLACE_PUBLIC_LISTING, with a research-only
--     note. This is DISPLAY-ONLY for recommendations research; it never sets is_launch_safe, never unlocks Product Asset
--     Lock, and fn_media_launch_eligibility is unchanged (still rejects these). No fabrication/substitution: only images
--     whose provenance match='MATCHED' for THIS product are used.
--  4. Showcase gating: expose has_authentic_image, authentic_image_count, showcase_eligible
--     (tier IN (PREMIUM,GOLD,PLATINUM) AND has_authentic_image) so the frontend separates the premium showcase from
--     weak/untiered research candidates (which are retained, not deleted).
--
-- Rollback: restore the mig_334 body of fn_monday_top_opportunities (captured in git history / mig_334 file).

CREATE OR REPLACE FUNCTION public.fn_monday_top_opportunities(p_tenant uuid, p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE ready jsonb; watch jsonb; platinum jsonb; scanned int; tier_counts jsonb; showcase_count int;
BEGIN
  WITH best AS (
    SELECT DISTINCT ON (d.product_id) d.*, cp.title AS product_name, cp.category,
      pme.evidence->'observed_market_price' AS price_obj,
      coalesce(pme.evidence->'supplier_identity'->>'match_class','UNKNOWN') AS sup_match,
      coalesce(pme.evidence->'observed_market_price'->>'source_class','UNKNOWN') AS price_src_class,
      coalesce((pme.economics->>'known')::boolean,false) AS econ_known,
      (pme.landed_cost IS NOT NULL) AS has_landed,
      coalesce(pme.stock_state,'UNKNOWN') AS stock_st,
      ((pme.evidence->'buyer_search_intent'->>'source') IS NOT NULL
        OR (pme.evidence->'marketplace_validation'->>'source') IS NOT NULL
        OR (pme.evidence->'demand_momentum'->>'source') IS NOT NULL) AS has_sourced_demand,
      (public.fn_evidence_window_fresh(pme.evidence_window)
        OR (pme.created_at IS NOT NULL AND pme.created_at > now() - interval '45 days')) AS ev_fresh,
      -- corroborated demand = engine confidence >= MEDIUM AND a named demand source exists
      (d.overall_evidence_confidence IN ('MEDIUM','HIGH')
        AND ((pme.evidence->'buyer_search_intent'->>'source') IS NOT NULL
          OR (pme.evidence->'marketplace_validation'->>'source') IS NOT NULL
          OR (pme.evidence->'demand_momentum'->>'source') IS NOT NULL)) AS corroborated_sourced
    FROM public.product_opportunity_decisions d
    JOIN public.commerce_products cp ON cp.id=d.product_id
    LEFT JOIN public.product_market_evaluations pme
      ON pme.tenant_id=d.tenant_id AND pme.product_id=d.product_id AND pme.country_code=d.country_code
    WHERE d.tenant_id=p_tenant AND d.is_fixture=false AND d.decision<>'AVOID' AND d.product_opportunity_score IS NOT NULL
      AND NOT public.fn_discovery_product_hidden(d.tenant_id, d.product_id)
    ORDER BY d.product_id,
      CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END,
      CASE d.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END,
      CASE d.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END,
      d.product_opportunity_score DESC
  ),
  ranked AS (
    SELECT b.*, CASE WHEN b.metric_scope='LOCAL' THEN 0 ELSE 1 END AS price_rank,
      (SELECT to_jsonb(pai) FROM public.product_asset_intelligence pai
        WHERE pai.tenant_id=b.tenant_id AND pai.product_id=b.product_id AND pai.is_primary
        ORDER BY pai.created_at DESC LIMIT 1) AS asset,
      -- Best MATCHED marketplace reference image for this exact product (research-only; never launch-safe).
      (SELECT jsonb_build_object('url', pia.image_url, 'source', pia.source_provider,
                'source_url', pia.source_url, 'rights_state', pia.rights_state)
         FROM public.product_image_assets pia
         WHERE pia.product_id=b.product_id AND pia.image_url IS NOT NULL
           AND coalesce(pia.availability,'') = 'AVAILABLE'
           AND coalesce(pia.provenance->>'match','') = 'MATCHED'
         ORDER BY pia.is_primary DESC NULLS LAST,
                  (pia.provenance->>'gallery_rank')::int NULLS LAST, pia.observed_at DESC NULLS LAST
         LIMIT 1) AS market_ref_img,
      (SELECT count(*) FROM public.product_image_assets pia
         WHERE pia.product_id=b.product_id AND pia.image_url IS NOT NULL
           AND coalesce(pia.availability,'') = 'AVAILABLE'
           AND coalesce(pia.provenance->>'match','') = 'MATCHED') AS market_img_count
    FROM best b
  ),
  ord AS (
    SELECT r.*, row_number() OVER (ORDER BY
      CASE r.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END, r.price_rank,
      CASE r.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END,
      CASE r.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END,
      r.product_opportunity_score DESC) AS rk
    FROM ranked r
  ),
  capped AS (SELECT * FROM ord WHERE rk <= p_limit),
  tiered AS (
    SELECT c.*, public.fn_opportunity_tier(jsonb_build_object(
      'decision', c.decision, 'band', c.opportunity_band, 'score', c.product_opportunity_score,
      'overall_evid', c.overall_evidence_confidence, 'product_conf', c.product_confidence,
      'gates', c.hard_gates,
      'n_critical_blockers', jsonb_array_length(coalesce(c.decision_blockers,'[]'::jsonb)),
      'n_exec_blockers', jsonb_array_length(coalesce(c.execution_blockers,'[]'::jsonb)),
      'saturation_level', c.saturation_state->>'level',
      'metric_scope', c.metric_scope,
      'supplier_match', c.sup_match,
      'price_source_class', c.price_src_class,
      'econ_known', c.econ_known,
      'has_landed', c.has_landed,
      'stock_state', c.stock_st,
      'has_sourced_demand', c.has_sourced_demand,
      'fresh', c.ev_fresh
    )) AS tier_obj
    FROM capped c
  ),
  enriched AS (
    SELECT t.*,
      (t.tier_obj->>'tier') AS tier,
      (t.asset IS NOT NULL OR t.market_ref_img IS NOT NULL) AS has_authentic_image,
      ((t.tier_obj->>'tier') IN ('PREMIUM','GOLD','PLATINUM')
        AND (t.asset IS NOT NULL OR t.market_ref_img IS NOT NULL)) AS showcase_eligible
    FROM tiered t
  ),
  cards AS (
    SELECT decision, tier, showcase_eligible, jsonb_build_object(
      'product_id', product_id, 'product', product_name, 'category', category,
      'best_market', country_code, 'decision', decision, 'lifecycle', lifecycle_state,
      'tier', tier, 'tier_reasons', coalesce(tier_obj->'reasons','[]'::jsonb),
      'showcase_eligible', showcase_eligible,
      'has_authentic_image', has_authentic_image, 'authentic_image_count',
        (CASE WHEN asset IS NOT NULL THEN 1 ELSE 0 END) + coalesce(market_img_count,0),
      'product_confidence', product_confidence, 'product_opportunity_score', product_opportunity_score,
      'evidence_confidence', overall_evidence_confidence,
      -- A product never reads "fresh" unless its demand is CORROBORATED (confidence>=MEDIUM) AND sourced — so a
      -- NONE/LOW-confidence product never shows "fresh" (fixes "Evidence: None · fresh").
      'evidence_fresh', (ev_fresh AND corroborated_sourced),
      'saturation', saturation_state->>'level',
      'market_price', CASE WHEN price_obj->>'amount' IS NOT NULL
          THEN (price_obj->>'amount')||' '||coalesce(price_obj->>'currency','') ELSE 'UNKNOWN (no local price observed)' END,
      'market_price_scope', metric_scope,
      'supplier_match', CASE WHEN sup_match='EXACT_PRODUCT' THEN 'EXACT' ELSE coalesce(nullif(sup_match,'UNKNOWN'),'unresolved') END,
      'economics_known', econ_known, 'landed_cost_known', has_landed, 'stock_state', stock_st,
      'advertising_headroom', advertising_headroom->>'state', 'opportunity_sweet_spot', opportunity_sweet_spot->>'state',
      'roi_basis', jsonb_build_object(
        'measured_roi','none','basis','No measured ROI yet — tier reflects evidence quality & commercial-readiness, not profit',
        'observed_sales', false, 'economics_estimated', econ_known),
      'image', CASE
        WHEN asset IS NOT NULL THEN jsonb_build_object(
                   'available',true,'url',asset->>'source_url','identity_state',asset->>'identity_state',
                   'rights_state',asset->>'rights_state','hero_eligible',(asset->>'hero_eligible')::boolean,
                   'source',asset->>'source','asset_type',asset->>'asset_type','reference', NOT coalesce((asset->>'hero_eligible')::boolean,false),
                   'note', CASE WHEN (asset->>'hero_eligible')::boolean THEN 'exact-product supplier image'
                           ELSE 'comparable supplier image ('||(asset->>'identity_state')||') — NOT the exact candidate; shown as reference' END)
        WHEN market_ref_img IS NOT NULL THEN jsonb_build_object(
                   'available',true,'url',market_ref_img->>'url','identity_state','MARKETPLACE_MATCHED',
                   'rights_state',coalesce(market_ref_img->>'rights_state','MARKETPLACE_PUBLIC_LISTING'),
                   'hero_eligible',false,'reference',true,'source',market_ref_img->>'source',
                   'source_url',market_ref_img->>'source_url','asset_type','IMAGE',
                   'note','Reference — marketplace listing, not supplier-authorised (research only; not for publishing)')
        ELSE jsonb_build_object('available',false,'reason','IMAGE_UNAVAILABLE — no supplier-authorised or matched marketplace image resolved') END,
      'commercial_assets', public.fn_product_commercial_readiness_badge(product_id, country_code),
      'why', (CASE WHEN corroborated_sourced
                   THEN 'Real demand'||CASE WHEN metric_scope='LOCAL' THEN ' + validated local price' ELSE '' END
                   ELSE 'Demand not sufficiently verified' END)
             ||'; held for '||coalesce((SELECT string_agg(x,', ') FROM (SELECT jsonb_array_elements_text(decision_blockers) x LIMIT 2) z),'—'),
      'action', CASE WHEN decision='TEST' AND tier='PLATINUM'
                     THEN 'View Opportunity (Platinum — Build Product Page eligible)'
                     WHEN decision='TEST' THEN 'View Opportunity (Build Product Page eligible)'
                     ELSE 'View Opportunity (launch actions locked)' END
    ) AS card, rk
    FROM enriched
  )
  SELECT coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='TEST'),'[]'::jsonb),
         coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='WATCH'),'[]'::jsonb),
         coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='TEST' AND tier='PLATINUM'),'[]'::jsonb),
         (SELECT jsonb_build_object(
            'PLATINUM', count(*) FILTER (WHERE tier='PLATINUM'),
            'GOLD',     count(*) FILTER (WHERE tier='GOLD'),
            'PREMIUM',  count(*) FILTER (WHERE tier='PREMIUM'),
            'UNTIERED', count(*) FILTER (WHERE tier IS NULL)) FROM cards),
         (SELECT count(*) FROM cards WHERE showcase_eligible)
  INTO ready, watch, platinum, tier_counts, showcase_count;
  SELECT count(*) INTO scanned FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND is_fixture=false
      AND NOT public.fn_discovery_product_hidden(tenant_id, product_id);
  RETURN jsonb_build_object('tenant_id', p_tenant, 'generated_at', now(),
    'ready_to_test', ready, 'watchlist', watch,
    'ready_to_test_platinum', platinum,
    'ready_to_test_count', jsonb_array_length(ready), 'watchlist_count', jsonb_array_length(watch),
    'ready_to_test_platinum_count', jsonb_array_length(platinum),
    'tier_counts', tier_counts, 'showcase_eligible_count', showcase_count,
    'total_opportunities', jsonb_array_length(ready)+jsonb_array_length(watch),
    'limit', p_limit, 'product_market_rows_scanned', scanned,
    'discovery_policy', jsonb_build_object('max_portfolio', p_limit,
      'stop_conditions', jsonb_build_array('source_candidate_exhaustion','configured_max_candidate_scan','sufficient_qualified_portfolio'),
      'min_evidence_quality','real Product x Market decision, non-AVOID, real demand evidence; no gate lowered to fill slots',
      'note','fewer than the limit is expected when few candidates meet evidence quality; AVOID never enters the portfolio'),
    'tier_policy', jsonb_build_object(
      'tiers', jsonb_build_array('PREMIUM','GOLD','PLATINUM'),
      'ready_to_test_platinum_rule','tier=PLATINUM AND decision=TEST',
      'showcase_rule','tier IN (PREMIUM,GOLD,PLATINUM) AND has_authentic_image; weak/untiered stay in research, not deleted',
      'premium_floor','corroborated demand (overall_evidence_confidence>=MEDIUM) AND named source provenance AND sufficient freshness; a high score or opportunity_band alone never earns a tier; evidence_confidence=NONE or no sourced demand => UNTIERED',
      'image_policy','supplier-authoritative hero preferred; else MATCHED marketplace image shown as REFERENCE (research only, never launch-safe, never unlocks Product Asset Lock); no fabrication/substitution',
      'note','tier is derived from existing evidence contracts; orthogonal to the gate-gated TEST/WATCH/AVOID decision (opportunity_band is a pure score bucket); never re-scores or promotes to fill a section'),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','READY_TO_TEST are launch-eligible only after downstream gates; WATCHLIST are emerging, not launch-ready; WINNER is post-performance only. tier reflects evidence quality & commercial-readiness, not a profit guarantee; measured ROI only with real attributable outcome data; "Real demand" is shown only when corroborated+sourced; reference marketplace images are research-only and never unlock publishing. Legacy research-concept products excluded.',
    'contract','pulse_monday_top_opportunities_v4_recs_quality');
END; $function$;

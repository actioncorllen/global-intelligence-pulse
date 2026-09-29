-- ============================================================================
-- mig_325_opportunity_cards_expose_commercial_readiness.sql
-- Surface Commercial Asset Readiness as a standard Product Opportunity signal.
-- Each opportunity card now carries `commercial_assets` (the canonical badge),
-- computed WITHOUT the user first adding the product to My Store. Opportunity
-- quality remains independent from asset readiness; this only adds the
-- launch-readiness asset dimension. Backward compatible: only one field added.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_monday_top_opportunities(p_tenant uuid, p_limit integer DEFAULT 5)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE ready jsonb; watch jsonb; scanned int;
BEGIN
  WITH best AS (
    SELECT DISTINCT ON (d.product_id) d.*, cp.title AS product_name, cp.category,
      pme.evidence->'observed_market_price' AS price_obj,
      coalesce(pme.evidence->'supplier_identity'->>'match_class','UNKNOWN') AS sup_match
    FROM public.product_opportunity_decisions d
    JOIN public.commerce_products cp ON cp.id=d.product_id
    LEFT JOIN public.product_market_evaluations pme
      ON pme.tenant_id=d.tenant_id AND pme.product_id=d.product_id AND pme.country_code=d.country_code
    WHERE d.tenant_id=p_tenant AND d.is_fixture=false AND d.decision<>'AVOID' AND d.product_opportunity_score IS NOT NULL
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
        ORDER BY pai.created_at DESC LIMIT 1) AS asset
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
  cards AS (
    SELECT decision, jsonb_build_object(
      'product_id', product_id, 'product', product_name, 'category', category,
      'best_market', country_code, 'decision', decision, 'lifecycle', lifecycle_state,
      'product_confidence', product_confidence, 'product_opportunity_score', product_opportunity_score,
      'saturation', saturation_state->>'level',
      'market_price', CASE WHEN price_obj->>'amount' IS NOT NULL
          THEN (price_obj->>'amount')||' '||coalesce(price_obj->>'currency','') ELSE 'UNKNOWN (no local price observed)' END,
      'market_price_scope', metric_scope,
      'supplier_match', CASE WHEN sup_match='EXACT_PRODUCT' THEN 'EXACT' ELSE coalesce(nullif(sup_match,'UNKNOWN'),'unresolved') END,
      'advertising_headroom', advertising_headroom->>'state', 'opportunity_sweet_spot', opportunity_sweet_spot->>'state',
      'image', CASE WHEN asset IS NOT NULL THEN jsonb_build_object(
                   'available',true,'url',asset->>'source_url','identity_state',asset->>'identity_state',
                   'rights_state',asset->>'rights_state','hero_eligible',(asset->>'hero_eligible')::boolean,
                   'source',asset->>'source','asset_type',asset->>'asset_type',
                   'note', CASE WHEN (asset->>'hero_eligible')::boolean THEN 'exact-product supplier image'
                           ELSE 'comparable supplier image ('||(asset->>'identity_state')||') — NOT the exact candidate; shown as reference' END)
                 ELSE jsonb_build_object('available',false,'reason','IMAGE_UNAVAILABLE — no legitimate exact/comparable supplier image resolved') END,
      -- Commercial Asset Readiness as a standard opportunity signal (research
      -- imagery is separate from publication rights; determined in the background).
      'commercial_assets', public.fn_product_commercial_readiness_badge(product_id, country_code),
      'why', 'Real demand'||CASE WHEN metric_scope='LOCAL' THEN ' + validated local price' ELSE '' END||
             '; held for '||coalesce((SELECT string_agg(x,', ') FROM (SELECT jsonb_array_elements_text(decision_blockers) x LIMIT 2) z),'—'),
      'action', CASE WHEN decision='TEST' THEN 'View Opportunity (Build Product Page eligible)' ELSE 'View Opportunity (launch actions locked)' END
    ) AS card, rk
    FROM capped
  )
  SELECT coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='TEST'),'[]'::jsonb),
         coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='WATCH'),'[]'::jsonb)
  INTO ready, watch;
  SELECT count(*) INTO scanned FROM public.product_opportunity_decisions WHERE tenant_id=p_tenant AND is_fixture=false;
  RETURN jsonb_build_object('tenant_id', p_tenant, 'generated_at', now(),
    'ready_to_test', ready, 'watchlist', watch,
    'ready_to_test_count', jsonb_array_length(ready), 'watchlist_count', jsonb_array_length(watch),
    'total_opportunities', jsonb_array_length(ready)+jsonb_array_length(watch),
    'limit', p_limit, 'product_market_rows_scanned', scanned,
    'discovery_policy', jsonb_build_object('max_portfolio', p_limit,
      'stop_conditions', jsonb_build_array('source_candidate_exhaustion','configured_max_candidate_scan','sufficient_qualified_portfolio'),
      'min_evidence_quality','real Product x Market decision, non-AVOID, real demand evidence; no gate lowered to fill slots',
      'note','fewer than the limit is expected when few candidates meet evidence quality; AVOID never enters the portfolio'),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','READY_TO_TEST are launch-eligible only after downstream gates; WATCHLIST are emerging, not launch-ready; WINNER is post-performance only. commercial_assets is an independent launch-readiness dimension: opportunity quality does not depend on it.',
    'contract','pulse_monday_top_opportunities_v1');
END; $function$;

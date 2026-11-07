-- mig_334_opportunity_tiers.sql
-- Product Opportunity Tier Refinement: add an evidence-derived PREMIUM / GOLD / PLATINUM tier to each opportunity
-- card, computed ENTIRELY from fields the engine already produces (hard_gates, decision_blockers, supplier identity
-- match_class, economics.known, landed_cost, stock_state, metric_scope/observed_market_price, saturation_state,
-- overall_evidence_confidence, evidence_window, opportunity_band). No re-score, no decision change, no new table,
-- no new paid provider call. A REFINEMENT of fn_monday_top_opportunities, not a rebuild.
--
-- STATUS: PREPARED FOR FOUNDER REVIEW — *** NOT YET APPLIED TO PROD nxaunmyihhjixxxljcqt ***.
--
-- Tier eligibility is documented in docs/PULSE-ECOM-OPPORTUNITY-TIERS-REFINEMENT.md. The decision (TEST/WATCH/AVOID)
-- is unchanged. "Ready to Test — Platinum" = tier=PLATINUM AND decision=TEST (server-enforced here).
--
-- Idempotency: CREATE OR REPLACE FUNCTION x3. Rollback: restore the prior bodies of
-- fn_monday_top_opportunities(uuid,integer) (captured in git history) and DROP the two new helpers.

-- ---------------------------------------------------------------------------
-- 1. Freshness helper: is an evidence_window within the freshness horizon? Pure, fail-safe (STABLE for now()).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_evidence_window_fresh(p_window jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
DECLARE v_ts timestamptz;
BEGIN
  IF p_window IS NULL OR p_window = '{}'::jsonb THEN RETURN false; END IF;
  BEGIN
    v_ts := coalesce(
      nullif(p_window->>'as_of','')::timestamptz,
      nullif(p_window->>'observed_at','')::timestamptz,
      nullif(p_window->>'window_end','')::timestamptz,
      nullif(p_window->>'end','')::timestamptz);
  EXCEPTION WHEN others THEN
    RETURN false;  -- non-empty window but no parseable timestamp → conservatively not fresh enough
  END;
  IF v_ts IS NULL THEN RETURN false; END IF;
  RETURN v_ts > (now() - interval '45 days');
END; $function$;

-- ---------------------------------------------------------------------------
-- 2. Tier derivation: pure function over already-extracted signals. Returns {tier, reasons[]}.
--    tier ∈ 'PLATINUM' | 'GOLD' | 'PREMIUM' | null (untiered). No table access → IMMUTABLE, no SECURITY DEFINER.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_opportunity_tier(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_decision        text := p->>'decision';
  v_band            text := p->>'band';
  v_score           numeric := nullif(p->>'score','')::numeric;
  v_overall         text := coalesce(p->>'overall_evid','NONE');
  v_prodconf        text := coalesce(p->>'product_conf','LOW');
  v_gates           jsonb := coalesce(p->'gates','{}'::jsonb);
  v_ncrit           int  := coalesce((p->>'n_critical_blockers')::int,99);
  v_nexec           int  := coalesce((p->>'n_exec_blockers')::int,99);
  v_sat_level       text := coalesce(p->>'saturation_level','UNKNOWN');
  v_metric_scope    text := coalesce(p->>'metric_scope','');
  v_supplier_match  text := coalesce(p->>'supplier_match','UNKNOWN');
  v_price_src       text := coalesce(p->>'price_source_class','UNKNOWN');
  v_econ_known      boolean := coalesce((p->>'econ_known')::boolean,false);
  v_has_landed      boolean := coalesce((p->>'has_landed')::boolean,false);
  v_stock           text := coalesce(p->>'stock_state','UNKNOWN');
  v_fresh           boolean := coalesce((p->>'fresh')::boolean,false);
  -- derived predicates
  all_gates_pass        boolean;
  no_critical_blocker   boolean;
  supplier_exact        boolean;
  econ_credible         boolean;
  stock_known           boolean;
  price_local_validated boolean;
  saturation_ok         boolean;
  conf_high             boolean;
  prodconf_ok           boolean;
  no_gate_fail          boolean;
  supplier_resolved     boolean;
  demand_signal         boolean;
  reasons               text[] := ARRAY[]::text[];
  v_tier                text := null;
BEGIN
  -- Never tier an AVOID decision or an unscored row (defence-in-depth; feed already excludes these).
  IF v_decision = 'AVOID' OR v_score IS NULL THEN
    RETURN jsonb_build_object('tier', null, 'reasons', to_jsonb(ARRAY['avoid_or_unscored']));
  END IF;

  all_gates_pass := (v_gates->>'supplier'='PASS' AND v_gates->>'economics'='PASS'
                 AND v_gates->>'compliance'='PASS' AND v_gates->>'fulfilment'='PASS'
                 AND v_gates->>'saturation'='PASS' AND v_gates->>'market_price'='PASS');
  no_gate_fail  := NOT (v_gates->>'supplier'='FAIL' OR v_gates->>'economics'='FAIL'
                 OR v_gates->>'compliance'='FAIL' OR v_gates->>'fulfilment'='FAIL'
                 OR v_gates->>'saturation'='FAIL' OR v_gates->>'market_price'='FAIL');
  no_critical_blocker   := (v_ncrit = 0 AND v_nexec = 0);
  supplier_exact        := (v_supplier_match = 'EXACT_PRODUCT');
  supplier_resolved     := (v_supplier_match IN ('EXACT_PRODUCT','STRONG','CLOSE'));
  econ_credible         := (v_econ_known AND v_has_landed);
  stock_known           := (v_stock IS NOT NULL AND v_stock <> 'UNKNOWN' AND v_gates->>'fulfilment'='PASS');
  price_local_validated := (v_metric_scope = 'LOCAL' AND v_price_src <> 'UNKNOWN' AND v_gates->>'market_price'='PASS');
  saturation_ok         := (v_gates->>'saturation'='PASS' AND v_sat_level IN ('LOW','MODERATE'));
  conf_high             := (v_overall = 'HIGH');
  prodconf_ok           := (v_prodconf IN ('MEDIUM','HIGH'));
  demand_signal         := (v_band IN ('EXCEPTIONAL','HIGH_CONFIDENCE','HIGH_CONFIDENCE_TEST','STRONG_TEST','TRENDING_WATCH')
                            OR v_overall IN ('MEDIUM','HIGH'));

  -- Record the reasons any Platinum condition fails (used for card explanation + downgrade transparency).
  IF NOT all_gates_pass        THEN reasons := reasons || 'not_all_gates_pass'; END IF;
  IF NOT no_critical_blocker   THEN reasons := reasons || 'open_blockers'; END IF;
  IF NOT supplier_exact        THEN reasons := reasons || 'supplier_not_exact'; END IF;
  IF NOT stock_known           THEN reasons := reasons || 'stock_or_shipping_unconfirmed'; END IF;
  IF NOT econ_credible         THEN reasons := reasons || 'landed_cost_or_margin_unknown'; END IF;
  IF NOT price_local_validated THEN reasons := reasons || 'local_price_unvalidated'; END IF;
  IF NOT saturation_ok         THEN reasons := reasons || 'saturation_unsuitable_or_unknown'; END IF;
  IF NOT conf_high             THEN reasons := reasons || 'evidence_confidence_below_high'; END IF;
  IF NOT v_fresh               THEN reasons := reasons || 'evidence_provenance_stale_or_absent'; END IF;

  IF all_gates_pass AND no_critical_blocker AND supplier_exact AND stock_known AND econ_credible
     AND price_local_validated AND saturation_ok AND conf_high AND prodconf_ok AND v_fresh THEN
    v_tier := 'PLATINUM';
  ELSIF v_overall IN ('MEDIUM','HIGH') AND price_local_validated AND saturation_ok AND econ_credible
     AND v_gates->>'supplier'='PASS' AND supplier_resolved AND no_gate_fail AND v_nexec = 0 THEN
    v_tier := 'GOLD';
  ELSIF v_band <> 'AVOID' AND demand_signal THEN
    v_tier := 'PREMIUM';
  ELSE
    v_tier := null;  -- untiered: emerging signal, insufficient evidence to tier
  END IF;

  RETURN jsonb_build_object('tier', v_tier, 'reasons', to_jsonb(reasons));
END; $function$;

-- ---------------------------------------------------------------------------
-- 3. Refine fn_monday_top_opportunities: add tier + tier_reasons to each card; expose ready_to_test_platinum.
--    Everything else (ordering, identity scoping, image/commercial-asset contract, blockers 'why', AVOID exclusion,
--    counts) is PRESERVED from the prior body.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_monday_top_opportunities(p_tenant uuid, p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE ready jsonb; watch jsonb; platinum jsonb; scanned int; tier_counts jsonb;
BEGIN
  WITH best AS (
    SELECT DISTINCT ON (d.product_id) d.*, cp.title AS product_name, cp.category,
      pme.evidence->'observed_market_price' AS price_obj,
      coalesce(pme.evidence->'supplier_identity'->>'match_class','UNKNOWN') AS sup_match,
      coalesce(pme.evidence->'observed_market_price'->>'source_class','UNKNOWN') AS price_src_class,
      coalesce((pme.economics->>'known')::boolean,false) AS econ_known,
      (pme.landed_cost IS NOT NULL) AS has_landed,
      coalesce(pme.stock_state,'UNKNOWN') AS stock_st,
      public.fn_evidence_window_fresh(pme.evidence_window) AS ev_fresh
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
      'fresh', c.ev_fresh
    )) AS tier_obj
    FROM capped c
  ),
  cards AS (
    SELECT decision, (tier_obj->>'tier') AS tier, jsonb_build_object(
      'product_id', product_id, 'product', product_name, 'category', category,
      'best_market', country_code, 'decision', decision, 'lifecycle', lifecycle_state,
      'tier', tier_obj->>'tier', 'tier_reasons', coalesce(tier_obj->'reasons','[]'::jsonb),
      'product_confidence', product_confidence, 'product_opportunity_score', product_opportunity_score,
      'evidence_confidence', overall_evidence_confidence,
      'evidence_fresh', ev_fresh,
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
      'image', CASE WHEN asset IS NOT NULL THEN jsonb_build_object(
                   'available',true,'url',asset->>'source_url','identity_state',asset->>'identity_state',
                   'rights_state',asset->>'rights_state','hero_eligible',(asset->>'hero_eligible')::boolean,
                   'source',asset->>'source','asset_type',asset->>'asset_type',
                   'note', CASE WHEN (asset->>'hero_eligible')::boolean THEN 'exact-product supplier image'
                           ELSE 'comparable supplier image ('||(asset->>'identity_state')||') — NOT the exact candidate; shown as reference' END)
                 ELSE jsonb_build_object('available',false,'reason','IMAGE_UNAVAILABLE — no legitimate exact/comparable supplier image resolved') END,
      'commercial_assets', public.fn_product_commercial_readiness_badge(product_id, country_code),
      'why', 'Real demand'||CASE WHEN metric_scope='LOCAL' THEN ' + validated local price' ELSE '' END||
             '; held for '||coalesce((SELECT string_agg(x,', ') FROM (SELECT jsonb_array_elements_text(decision_blockers) x LIMIT 2) z),'—'),
      'action', CASE WHEN decision='TEST' AND (tier_obj->>'tier')='PLATINUM'
                     THEN 'View Opportunity (Platinum — Build Product Page eligible)'
                     WHEN decision='TEST' THEN 'View Opportunity (Build Product Page eligible)'
                     ELSE 'View Opportunity (launch actions locked)' END
    ) AS card, rk
    FROM tiered
  )
  SELECT coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='TEST'),'[]'::jsonb),
         coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='WATCH'),'[]'::jsonb),
         coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='TEST' AND tier='PLATINUM'),'[]'::jsonb),
         (SELECT jsonb_build_object(
            'PLATINUM', count(*) FILTER (WHERE tier='PLATINUM'),
            'GOLD',     count(*) FILTER (WHERE tier='GOLD'),
            'PREMIUM',  count(*) FILTER (WHERE tier='PREMIUM'),
            'UNTIERED', count(*) FILTER (WHERE tier IS NULL)) FROM cards)
  INTO ready, watch, platinum, tier_counts;
  SELECT count(*) INTO scanned FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND is_fixture=false
      AND NOT public.fn_discovery_product_hidden(tenant_id, product_id);
  RETURN jsonb_build_object('tenant_id', p_tenant, 'generated_at', now(),
    'ready_to_test', ready, 'watchlist', watch,
    'ready_to_test_platinum', platinum,
    'ready_to_test_count', jsonb_array_length(ready), 'watchlist_count', jsonb_array_length(watch),
    'ready_to_test_platinum_count', jsonb_array_length(platinum),
    'tier_counts', tier_counts,
    'total_opportunities', jsonb_array_length(ready)+jsonb_array_length(watch),
    'limit', p_limit, 'product_market_rows_scanned', scanned,
    'discovery_policy', jsonb_build_object('max_portfolio', p_limit,
      'stop_conditions', jsonb_build_array('source_candidate_exhaustion','configured_max_candidate_scan','sufficient_qualified_portfolio'),
      'min_evidence_quality','real Product x Market decision, non-AVOID, real demand evidence; no gate lowered to fill slots',
      'note','fewer than the limit is expected when few candidates meet evidence quality; AVOID never enters the portfolio'),
    'tier_policy', jsonb_build_object(
      'tiers', jsonb_build_array('PREMIUM','GOLD','PLATINUM'),
      'ready_to_test_platinum_rule','tier=PLATINUM AND decision=TEST',
      'note','tier is derived from existing evidence contracts (hard_gates, supplier identity, economics, landed_cost, stock_state, local price, saturation, evidence confidence+freshness); it is orthogonal to the TEST/WATCH/AVOID decision and never re-scores or promotes to fill a section'),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','READY_TO_TEST are launch-eligible only after downstream gates; WATCHLIST are emerging, not launch-ready; WINNER is post-performance only. commercial_assets is an independent launch-readiness dimension. tier reflects evidence quality & commercial-readiness, not a profit guarantee; measured ROI is only shown with real attributable outcome data. Legacy research-concept products are excluded.',
    'contract','pulse_monday_top_opportunities_v3_tiers');
END; $function$;

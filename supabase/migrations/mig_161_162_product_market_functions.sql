-- PULSE-ECOM-CROSS-MARKET-PRODUCT-INTELLIGENCE-001
-- Applied to Supabase as mig_161 (fn_pm_score, fn_pm_decision, fn_evaluate_product_market)
-- and mig_162 (fn_rank_product_markets, fn_pm_monday_block). Final deployed bodies.

CREATE OR REPLACE FUNCTION public.fn_pm_score(p_components jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
DECLARE
  k text; v jsonb; w numeric; s numeric;
  wknown numeric := 0; acc numeric := 0; total_w numeric := 0; coverage numeric; conf text;
BEGIN
  FOR k, v IN SELECT * FROM jsonb_each(p_components) LOOP
    w := coalesce(nullif(v->>'weight','')::numeric,0); total_w := total_w + w;
    s := nullif(v->>'subscore','')::numeric;
    IF s IS NOT NULL THEN wknown := wknown + w; acc := acc + w * s; END IF;
  END LOOP;
  coverage := CASE WHEN total_w = 0 THEN 0 ELSE round(wknown/total_w, 4) END;
  conf := CASE WHEN coverage >= 0.75 THEN 'HIGH' WHEN coverage >= 0.5 THEN 'MEDIUM'
               WHEN coverage >= 0.35 THEN 'LOW' ELSE 'NONE' END;
  RETURN jsonb_build_object(
    'market_opportunity_score', CASE WHEN wknown = 0 THEN NULL ELSE round(acc/wknown, 1) END,
    'coverage', coverage, 'evidence_confidence', conf, 'known_weight', wknown, 'total_weight', total_w);
END; $$;
REVOKE ALL ON FUNCTION public.fn_pm_score(jsonb) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.fn_pm_decision(p_score numeric, p_confidence text, p_gates jsonb, p_policy jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
DECLARE
  test_min numeric := coalesce(nullif(p_policy->>'test_min','')::numeric,70);
  watch_min numeric := coalesce(nullif(p_policy->>'watch_min','')::numeric,45);
  gk text; gv text; has_fail boolean := false; has_watch boolean := false; reasons text[] := '{}'; decision text;
BEGIN
  FOR gk, gv IN SELECT key, value::text FROM jsonb_each_text(p_gates) LOOP
    IF gv = 'FAIL' THEN has_fail := true; reasons := array_append(reasons, 'GATE_FAIL_'||upper(gk)); END IF;
    IF gv = 'WATCH' THEN has_watch := true; reasons := array_append(reasons, 'GATE_WATCH_'||upper(gk)); END IF;
  END LOOP;
  IF has_fail THEN decision := 'AVOID';
  ELSIF has_watch THEN decision := 'WATCH'; reasons := array_append(reasons,'CANNOT_TEST_UNTIL_GATES_RESOLVE');
  ELSIF p_score IS NULL THEN decision := 'WATCH'; reasons := array_append(reasons,'NO_SCORE_INSUFFICIENT_EVIDENCE');
  ELSIF p_score >= test_min AND p_confidence IN ('MEDIUM','HIGH') THEN decision := 'TEST'; reasons := array_append(reasons,'SCORE_AND_GATES_AND_CONFIDENCE_PASS');
  ELSIF p_score >= watch_min THEN decision := 'WATCH'; reasons := array_append(reasons, CASE WHEN p_confidence NOT IN ('MEDIUM','HIGH') THEN 'SCORE_OK_BUT_LOW_CONFIDENCE' ELSE 'SCORE_BELOW_TEST_THRESHOLD' END);
  ELSE decision := 'AVOID'; reasons := array_append(reasons,'SCORE_BELOW_WATCH_THRESHOLD'); END IF;
  RETURN jsonb_build_object('market_decision', decision, 'decision_reasons', to_jsonb(reasons),
    'policy', jsonb_build_object('test_min',test_min,'watch_min',watch_min));
END; $$;
REVOKE ALL ON FUNCTION public.fn_pm_decision(numeric,text,jsonb,jsonb) FROM PUBLIC, anon;

-- fn_evaluate_product_market(p_tenant, p_product, p_country, p_market_currency, p_evidence,
--   p_economics_inputs, p_policy, p_is_fixture, p_persist): assembles market-specific component
-- subscores (null=UNKNOWN, excluded), derives landed_economics from fn_economics_breakeven vs the
-- ad reserve, applies fail-closed gates (stock/economics/price/compliance/fulfilment), computes the
-- decision, and optionally upserts a product_market_evaluations row. Full body deployed as mig_161.
-- fn_rank_product_markets(p_tenant, p_product, p_score_version): deterministic ranking
--   (decision-eligibility > score > confidence > contribution > country) + recommended_market +
--   comparison contract 'pulse_product_market_ranking_v1'. Does NOT set campaign_target_market.
-- fn_pm_monday_block(p_tenant, p_product): Monday Product Opportunity market block
--   (best_market_to_test / score / why / alternatives / confidence / risks). Monday cadence unchanged.
-- All functions REVOKE'd from PUBLIC and anon; SECURITY DEFINER with SET search_path=''.
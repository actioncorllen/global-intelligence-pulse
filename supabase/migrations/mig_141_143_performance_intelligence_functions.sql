-- PULSE-ECOM-P14-PERFORMANCE-INTELLIGENCE-001
-- Applied to DB as mig_141 (derive+decision), mig_142 (join+evaluate),
-- mig_143 (decision break-even-band ordering fix). This file mirrors the FINAL state.

-- Derived metrics with safe zero/null denominators.
CREATE OR REPLACE FUNCTION public.fn_perf_derive_metrics(p jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
DECLARE
  spend numeric := nullif(p->>'spend','')::numeric;
  impressions numeric := nullif(p->>'impressions','')::numeric;
  clicks numeric := nullif(p->>'clicks','')::numeric;
  purchases numeric := nullif(p->>'purchases','')::numeric;
  revenue numeric := nullif(p->>'revenue','')::numeric;
  eng numeric := coalesce(nullif(p->>'link_clicks','')::numeric, nullif(p->>'clicks','')::numeric);
BEGIN
  RETURN jsonb_build_object(
    'ctr',  CASE WHEN impressions IS NULL OR impressions = 0 OR clicks IS NULL THEN NULL ELSE round(clicks/impressions,6) END,
    'cpc',  CASE WHEN clicks IS NULL OR clicks = 0 OR spend IS NULL THEN NULL ELSE round(spend/clicks,4) END,
    'cpm',  CASE WHEN impressions IS NULL OR impressions = 0 OR spend IS NULL THEN NULL ELSE round(spend/impressions*1000,4) END,
    'purchase_conversion_rate', CASE WHEN eng IS NULL OR eng = 0 OR purchases IS NULL THEN NULL ELSE round(purchases/eng,6) END,
    'cpa',  CASE WHEN purchases IS NULL OR purchases = 0 OR spend IS NULL THEN NULL ELSE round(spend/purchases,4) END,
    'roas', CASE WHEN spend IS NULL OR spend = 0 OR revenue IS NULL THEN NULL ELSE round(revenue/spend,4) END,
    'denominators_note','all ratios return NULL on zero/unknown denominators (never divide-by-zero, never 0-filled)');
END; $$;
REVOKE ALL ON FUNCTION public.fn_perf_derive_metrics(jsonb) FROM PUBLIC, anon;

-- Decision engine (break-even band evaluated BEFORE negative branches).
CREATE OR REPLACE FUNCTION public.fn_perf_decision(
  p_metrics jsonb, p_derived jsonb, p_economics jsonb, p_context jsonb, p_policy jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $$
DECLARE
  spend numeric := nullif(p_metrics->>'spend','')::numeric;
  impressions numeric := nullif(p_metrics->>'impressions','')::numeric;
  clicks numeric := coalesce(nullif(p_metrics->>'clicks','')::numeric,0);
  purchases numeric := coalesce(nullif(p_metrics->>'purchases','')::numeric,0);
  be_cpa numeric := nullif(p_economics->>'break_even_cpa','')::numeric;
  sell numeric := nullif(p_economics->>'selling_price','')::numeric;
  econ_state text := coalesce(p_economics->>'economics_state','UNKNOWN');
  is_fixture boolean := coalesce((p_context->>'is_fixture')::boolean,false);
  src text := coalesce(p_context->>'source_class','UNKNOWN');
  psv boolean := coalesce((p_context->>'purchase_source_verified')::boolean,false);
  supplier text := coalesce(p_context->>'supplier_status','UNKNOWN');
  attr_known boolean := coalesce((p_context->>'attribution_known')::boolean,false);
  min_impr numeric := coalesce(nullif(p_policy->>'min_impressions','')::numeric,1000);
  min_clicks numeric := coalesce(nullif(p_policy->>'min_clicks_conversion','')::numeric,50);
  min_pur numeric := coalesce(nullif(p_policy->>'min_purchases_decision','')::numeric,5);
  decision text; reasons text[] := '{}'; risks text[] := '{}';
  caa numeric; be_roas numeric; fixture_only boolean; executable boolean; winner_eligible boolean;
  confidence text; roas_verified boolean;
BEGIN
  fixture_only := is_fixture OR src = 'FIXTURE';
  be_roas := CASE WHEN be_cpa IS NULL OR be_cpa <= 0 OR sell IS NULL THEN NULL ELSE round(sell/be_cpa,4) END;
  roas_verified := psv AND NOT fixture_only AND src = 'REAL_OBSERVED';
  IF spend IS NULL OR impressions IS NULL OR (coalesce(spend,0) <= 0 AND coalesce(impressions,0) <= 0) THEN
    decision := 'INSUFFICIENT_DATA'; reasons := array_append(reasons,'NO_DELIVERY');
  ELSIF impressions > 0 AND clicks = 0 THEN
    decision := 'INSUFFICIENT_DATA'; reasons := array_append(reasons,'DELIVERY_BUT_NO_ENGAGEMENT');
  ELSIF purchases = 0 THEN
    IF clicks >= min_clicks THEN decision := 'IMPROVE'; reasons := array_append(reasons,'TRAFFIC_NO_CONVERSION');
    ELSE decision := 'CONTINUE_TEST'; reasons := array_append(reasons,'INSUFFICIENT_TRAFFIC_FOR_CONVERSION_READ'); END IF;
  ELSIF purchases < min_pur THEN
    decision := 'CONTINUE_TEST'; reasons := array_append(reasons,'PURCHASES_BELOW_SAMPLE_THRESHOLD');
  ELSE
    IF econ_state = 'UNKNOWN' OR be_cpa IS NULL THEN
      decision := 'IMPROVE'; reasons := array_append(reasons,'UNKNOWN_ECONOMICS_CANNOT_VERIFY_CONTRIBUTION');
      risks := array_append(risks,'UNKNOWN_ECONOMICS');
    ELSE
      caa := round(purchases * be_cpa - coalesce(spend,0), 2);
      IF abs(caa) <= 0.10 * coalesce(spend,0) THEN
        decision := 'CONTINUE_TEST'; reasons := array_append(reasons,'BREAK_EVEN_BAND');
      ELSIF caa < 0 AND coalesce(spend,0) > 2 * purchases * be_cpa THEN
        decision := 'STOP'; reasons := array_append(reasons,'NEGATIVE_CONTRIBUTION_STRUCTURAL');
        risks := array_append(risks,'NEGATIVE_CONTRIBUTION');
      ELSIF caa < 0 THEN
        decision := 'IMPROVE'; reasons := array_append(reasons,'NEGATIVE_CONTRIBUTION_SALVAGEABLE');
        risks := array_append(risks,'NEGATIVE_CONTRIBUTION');
      ELSE
        IF supplier = 'CRITICAL' THEN
          decision := 'IMPROVE'; reasons := array_append(reasons,'POSITIVE_CONTRIBUTION_BUT_SUPPLIER_CRITICAL');
          risks := array_append(risks,'SUPPLIER_CRITICAL_BLOCKS_SCALE');
        ELSE decision := 'SCALE_CANDIDATE'; reasons := array_append(reasons,'POSITIVE_CONTRIBUTION_SUFFICIENT_EVIDENCE'); END IF;
      END IF;
    END IF;
  END IF;
  IF fixture_only THEN risks := array_append(risks,'FIXTURE_ONLY_NON_EXECUTABLE'); END IF;
  IF NOT psv THEN risks := array_append(risks,'PURCHASE_SOURCE_UNVERIFIED'); END IF;
  IF (p_derived->>'roas') IS NOT NULL AND NOT roas_verified THEN risks := array_append(risks,'ROAS_UNVERIFIED'); END IF;
  IF NOT attr_known THEN risks := array_append(risks,'ATTRIBUTION_UNKNOWN'); END IF;
  executable := (decision = 'SCALE_CANDIDATE') AND NOT fixture_only AND psv
                AND src = 'REAL_OBSERVED' AND supplier = 'OK' AND attr_known;
  winner_eligible := false;
  confidence := CASE WHEN fixture_only THEN 'FIXTURE_NONE'
    WHEN decision = 'INSUFFICIENT_DATA' THEN 'NONE'
    WHEN purchases >= min_pur AND psv AND src='REAL_OBSERVED' THEN 'MEDIUM'
    WHEN purchases > 0 THEN 'LOW' ELSE 'LOW' END;
  RETURN jsonb_build_object('decision', decision, 'decision_reasons', to_jsonb(reasons),
    'risk_flags', to_jsonb(risks), 'contribution_after_ads', caa, 'break_even_roas', be_roas,
    'roas_verified', roas_verified, 'fixture_only', fixture_only, 'executable', executable,
    'winner_eligible', winner_eligible, 'confidence', confidence,
    'policy_applied', jsonb_build_object('min_impressions',min_impr,'min_clicks_conversion',min_clicks,'min_purchases_decision',min_pur));
END; $$;
REVOKE ALL ON FUNCTION public.fn_perf_decision(jsonb,jsonb,jsonb,jsonb,jsonb) FROM PUBLIC, anon;

-- Commerce join (real observed purchases/revenue) + evaluator: see mig_142 (applied).
-- fn_perf_commerce_join(uuid,uuid) and fn_perf_evaluate(uuid,uuid,jsonb) are defined there.

-- PULSE-ECOM-P14-PERFORMANCE-INTELLIGENCE-001
-- Commerce join (real observed purchases/revenue) + full evaluator/handoff.
CREATE OR REPLACE FUNCTION public.fn_perf_commerce_join(p_tenant uuid, p_execution_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT jsonb_build_object(
    'observed_purchases', COALESCE(count(*) FILTER (WHERE ce.event_name IN ('PURCHASE','Purchase')), 0),
    'observed_revenue', COALESCE(sum(ce.value) FILTER (WHERE ce.event_name IN ('PURCHASE','Purchase')), NULL),
    'observed_revenue_currency', max(ce.currency) FILTER (WHERE ce.event_name IN ('PURCHASE','Purchase')),
    'attribution_known', bool_or(ce.attribution_class IS NOT NULL AND ce.attribution_class NOT IN ('UNATTRIBUTED','UNKNOWN')),
    'source_class', CASE WHEN count(*) FILTER (WHERE ce.event_name IN ('PURCHASE','Purchase')) > 0
                         THEN 'REAL_OBSERVED' ELSE 'UNKNOWN' END)
  FROM public.commerce_events ce
  WHERE ce.tenant_id = p_tenant AND ce.campaign_execution_id = p_execution_id AND ce.is_test_fixture = false;
$$;
REVOKE ALL ON FUNCTION public.fn_perf_commerce_join(uuid,uuid) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.fn_perf_evaluate(p_tenant uuid, p_snapshot_id uuid, p_policy jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  s public.campaign_performance_snapshots%ROWTYPE;
  ei jsonb; econ jsonb; metrics jsonb; derived jsonb; ctx jsonb; decision jsonb; joinj jsonb;
  actions jsonb; obs_pur numeric; obs_rev numeric;
BEGIN
  SELECT * INTO s FROM public.campaign_performance_snapshots WHERE id = p_snapshot_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','snapshot_not_found'); END IF;
  IF s.tenant_id <> p_tenant THEN RETURN jsonb_build_object('error','cross_tenant_denied'); END IF;
  ei := s.provenance->'economics_inputs';
  IF ei IS NULL THEN econ := jsonb_build_object('economics_state','UNKNOWN','known',false,'reason','no_economics_inputs');
  ELSE econ := public.fn_economics_breakeven(nullif(ei->>'selling_price','')::numeric, nullif(ei->>'landed_cost','')::numeric,
      ei->>'landed_currency', coalesce(ei->>'display_currency','GBP'), ei->'fees'); END IF;
  obs_pur := s.purchases; obs_rev := s.revenue;
  IF NOT s.is_fixture AND s.campaign_execution_id IS NOT NULL THEN
    joinj := public.fn_perf_commerce_join(p_tenant, s.campaign_execution_id);
    obs_pur := nullif(joinj->>'observed_purchases','')::numeric;
    obs_rev := nullif(joinj->>'observed_revenue','')::numeric;
  END IF;
  metrics := jsonb_build_object('spend', s.spend, 'impressions', s.impressions, 'reach', s.reach, 'frequency', s.frequency,
    'clicks', s.clicks, 'link_clicks', s.link_clicks, 'landing_page_views', s.landing_page_views,
    'add_to_cart', s.add_to_cart, 'initiate_checkout', s.initiate_checkout, 'purchases', obs_pur, 'revenue', obs_rev,
    'spend_currency', s.spend_currency, 'revenue_currency', s.revenue_currency);
  derived := public.fn_perf_derive_metrics(metrics);
  ctx := jsonb_build_object('is_fixture', s.is_fixture, 'source_class', s.source_class,
    'purchase_source_verified', s.purchase_source_verified, 'supplier_status', coalesce(s.provenance->>'supplier_status','UNKNOWN'),
    'attribution_known', coalesce((joinj->>'attribution_known')::boolean, coalesce((s.provenance->>'attribution_known')::boolean,false)));
  decision := public.fn_perf_decision(metrics, derived, econ, ctx, p_policy);
  actions := CASE decision->>'decision'
    WHEN 'INSUFFICIENT_DATA' THEN jsonb_build_array('AWAIT_DELIVERY_OR_EXTEND_OBSERVATION_WINDOW')
    WHEN 'CONTINUE_TEST'     THEN jsonb_build_array('CONTINUE_GATHERING_EVIDENCE')
    WHEN 'IMPROVE'           THEN jsonb_build_array('ITERATE_CREATIVE_TARGETING_OR_OFFER')
    WHEN 'STOP'              THEN jsonb_build_array('STOP_PENDING_REVIEW_requires_separate_authority_gate')
    WHEN 'SCALE_CANDIDATE'   THEN jsonb_build_array('REVIEW_FOR_SCALE_AUTHORIZATION_requires_separate_spend_activation_gate')
    ELSE jsonb_build_array('NO_ACTION') END;
  RETURN jsonb_build_object('snapshot_id', s.id, 'tenant_id', s.tenant_id, 'campaign_execution_id', s.campaign_execution_id,
    'level', s.level, 'performance_snapshot', metrics || derived, 'economics', econ, 'commerce_join', joinj,
    'evidence_quality', jsonb_build_object('source_class', s.source_class, 'is_fixture', s.is_fixture,
      'purchase_source_verified', s.purchase_source_verified, 'sample_purchases', obs_pur, 'attribution_known', ctx->'attribution_known'),
    'decision', decision->>'decision', 'decision_reasons', decision->'decision_reasons', 'risk_flags', decision->'risk_flags',
    'confidence', decision->>'confidence', 'contribution_after_ads', decision->'contribution_after_ads',
    'break_even_roas', decision->'break_even_roas', 'roas_verified', decision->'roas_verified',
    'fixture_only', decision->'fixture_only', 'winner_eligible', decision->'winner_eligible',
    'recommended_actions', actions, 'executable', decision->'executable',
    'provenance', jsonb_build_object('source_class', s.source_class, 'platform', s.platform,
      'window_start', s.window_start, 'window_end', s.window_end, 'inputs', s.provenance),
    'contract', 'pulse_perf_intel_v1');
END; $$;
REVOKE ALL ON FUNCTION public.fn_perf_evaluate(uuid,uuid,jsonb) FROM PUBLIC, anon;

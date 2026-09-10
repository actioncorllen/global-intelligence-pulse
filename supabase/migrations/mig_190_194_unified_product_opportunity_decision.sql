-- PULSE-ECOM-UNIFIED-PRODUCT-OPPORTUNITY-DECISION-001 + FOUNDER ADDENDUM
-- Deployed to Supabase project nxaunmyihhjixxxljcqt as:
--   mig_190  product_opportunity_decisions (canonical unified Product x Market decision table)
--   mig_191  fn_pod_evaluate (orchestration + decision; superseded body deployed as mig_194)
--   mig_192  fn_pod_tournament + fn_pod_monday_block (Product x Market tournament, product rollup, Monday block)
--   mig_193  dedicated unified fixtures (built through the real engines; is_fixture=true)
--   mig_194  fn_pod_evaluate price-provenance fix (INFERRED foreign price -> CROSS_MARKET_REFERENCE)
-- This mirror carries the FINAL deployed bodies. Evidence stays BY REFERENCE (pme_id / platform_eval_id /
-- competitor rows); component numbers stored on a decision are an explicit point-in-time SNAPSHOT whose
-- authoritative source is the referenced row. The tournament unit is PRODUCT x MARKET, never product alone
-- and never global. Hard gates (supplier / market-price / economics) can override the score. DECISION
-- blockers are kept separate from EXECUTION blockers (opportunity != execution). WINNER is never emitted:
-- the strongest pre-launch state is HIGH_CONFIDENCE_TEST. campaign_activation=FALSE; advertising_spend=0.

-- ─────────────────────────────────────────────────────────────────────────────
-- mig_190 — canonical table
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.product_opportunity_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  country_code text NOT NULL,                         -- market identity (mandatory; never global)
  market_currency text,
  score_version text NOT NULL DEFAULT 'pod_v1',
  -- evidence by reference (authoritative sources; not re-derived here)
  product_market_evaluation_id uuid,
  primary_platform text,
  primary_platform_evaluation_id uuid,
  lineage jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- component scores preserved SEPARATELY (product/market/platform/competitor/supplier)
  component_scores jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- unified output
  product_opportunity_score numeric,
  coverage numeric,
  opportunity_band text,                              -- AVOID/WATCH/TRENDING_WATCH/STRONG_TEST/HIGH_CONFIDENCE_TEST/EXCEPTIONAL
  overall_evidence_confidence text,                   -- HIGH/MEDIUM/LOW/NONE — weakest-tier, NEVER averaged
  decision text,                                      -- TEST / WATCH / AVOID
  lifecycle_state text,                               -- pre-launch ceiling = HIGH_CONFIDENCE_TEST; WINNER is post-launch only
  -- country / metric provenance (Founder Addendum)
  metric_scope text,                                  -- LOCAL / CROSS_MARKET_REFERENCE / LOCAL_UNVALIDATED
  -- hard gates + blockers (decision vs execution kept separate)
  hard_gates jsonb NOT NULL DEFAULT '{}'::jsonb,
  decision_blockers jsonb NOT NULL DEFAULT '[]'::jsonb,
  execution_blockers jsonb NOT NULL DEFAULT '[]'::jsonb,
  action_gating text,
  -- economics by reference + CPA scenarios
  economics_ref jsonb NOT NULL DEFAULT '{}'::jsonb,
  cpa_scenarios jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {cpa_10, cpa_15, cpa_20} each {contribution, state}
  decision_reasons jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_fixture boolean NOT NULL DEFAULT false,
  provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_opportunity_decisions_uq UNIQUE (tenant_id, product_id, country_code, score_version)
);
CREATE INDEX IF NOT EXISTS idx_pod_tenant_product ON public.product_opportunity_decisions (tenant_id, product_id);
CREATE INDEX IF NOT EXISTS idx_pod_pme ON public.product_opportunity_decisions (product_market_evaluation_id);
-- Tenant-isolation backstop: RLS on, NO permissive policy (service-role / SECURITY DEFINER only).
ALTER TABLE public.product_opportunity_decisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_opportunity_decisions FROM PUBLIC, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- mig_191 + mig_194 — fn_pod_evaluate (FINAL body: price-provenance fix included)
--   Orchestrates market/economics/gates (product_market_evaluations), the best eligible acquisition
--   channel (product_market_platform_evaluations), and competitor signals (already folded into the market
--   score) into one explainable per-market decision. Component scores are preserved separately; the
--   composite blends market(70) + platform-channel(30) over KNOWN dimensions only (no double counting).
--   overall_evidence_confidence is the WEAKEST tier (never averaged), capped when the local price is
--   unvalidated/foreign or when no acquisition channel is known. Hard gates override the score. DECISION
--   blockers != EXECUTION blockers. Lifecycle ceiling is HIGH_CONFIDENCE_TEST (never WINNER).
--   Signature: fn_pod_evaluate(p_tenant uuid, p_product uuid, p_country text,
--                              p_score_version text DEFAULT 'pod_v1', p_persist boolean DEFAULT false)
--   Full deployed body is authoritative in the database (mig_194). Provenance rule:
--     price_src := coalesce(evidence.observed_market_price.source_class,
--                           component_scores.market_price_support.source_class)
--     OBSERVED/PLATFORM_REPORTED -> LOCAL ; INFERRED -> CROSS_MARKET_REFERENCE ;
--     ESTIMATED/other -> LOCAL_UNVALIDATED. A CROSS_MARKET_REFERENCE can never satisfy the local price gate.

-- ─────────────────────────────────────────────────────────────────────────────
-- mig_192 — fn_pod_tournament + fn_pod_monday_block
--   fn_pod_tournament(p_tenant, p_product, p_score_version, p_persist): refreshes a unified decision for
--     EVERY country the product has a market evaluation in, then ranks the PRODUCT x MARKET combinations
--     deterministically (TEST>WATCH>AVOID -> score -> confidence -> contribution -> country). Product
--     rollup identifies BEST MARKET (never auto home/selling/campaign). Cross-market recovery: a product
--     that fails in one market survives via other markets and is never globally rejected.
--   fn_pod_monday_block(p_tenant, p_product): Monday Product Opportunity block (BEST_MARKET / DECISION /
--     LIFECYCLE / SCORE / BAND / CONFIDENCE / WHY / BEST_AD_PLATFORM / METRIC_SCOPE / DECISION_BLOCKERS /
--     EXECUTION_BLOCKERS / CPA_SCENARIOS / ACTION_GATING / CROSS_MARKET_ALTERNATIVES). Contract only; not
--     wired to any recurring schedule. Monday cadence unchanged.

-- ─────────────────────────────────────────────────────────────────────────────
-- mig_193 — dedicated unified fixtures (is_fixture=true), produced through the real engines:
--   f7 (FR HIGH_CONFIDENCE_TEST + ES EXCEPTIONAL-capped), f8 (DE execution-blocked TEST + GB
--   CROSS_MARKET_REFERENCE). Fixtures prove engineering only; they never satisfy real acceptance.

-- All fn_pod_* functions are SECURITY DEFINER, SET search_path='', REVOKE'd from PUBLIC and anon.

-- ═════════════════════════════════════════════════════════════════════════════
-- FULL DEPLOYED FUNCTION BODIES (authoritative; as running in the database)
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_pod_evaluate(
  p_tenant uuid, p_product uuid, p_country text,
  p_score_version text DEFAULT 'pod_v1', p_persist boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  pme record; plat record;
  market_score numeric; platform_score numeric; product_score numeric;
  competitor_score numeric; supplier_score numeric;
  market_conf text; platform_conf text := NULL;
  g_stock text; g_price text; g_econ text; g_comp text; g_fulf text;
  price_src text; metric_scope text;
  comp_input jsonb; comp jsonb; score numeric; coverage numeric;
  band text; decision text; lifecycle text; action_gate text;
  has_fail boolean := false; has_watch boolean := false;
  dblock text[] := '{}'; eblock text[] := '{}'; reasons text[] := '{}';
  bec numeric; econ_state text; contrib_reserve numeric;
  cpa jsonb; overall_conf text; component_scores jsonb; hard_gates jsonb;
  exec_ready text := NULL; tier_of int;
BEGIN
  SELECT * INTO pme FROM public.product_market_evaluations
  WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country
  ORDER BY evaluation_ts DESC NULLS LAST, created_at DESC LIMIT 1;

  IF pme.id IS NULL THEN
    RETURN jsonb_build_object(
      'tenant_id',p_tenant,'product_id',p_product,'country_code',p_country,
      'score_version',p_score_version,'decision','INSUFFICIENT_EVIDENCE',
      'opportunity_band','INSUFFICIENT','product_opportunity_score',NULL,
      'reason','NO_PRODUCT_MARKET_EVALUATION_FOR_COUNTRY',
      'note','A unified decision requires a country-specific market evaluation; global evaluation is never used.',
      'contract','pulse_product_opportunity_decision_v1');
  END IF;

  market_score := pme.market_opportunity_score;
  market_conf  := pme.evidence_confidence;
  g_stock := coalesce(pme.gate_state->>'stock','UNKNOWN');
  g_price := coalesce(pme.gate_state->>'price','UNKNOWN');
  g_econ  := coalesce(pme.gate_state->>'economics','UNKNOWN');
  g_comp  := coalesce(pme.gate_state->>'compliance','UNKNOWN');
  g_fulf  := coalesce(pme.gate_state->>'fulfilment','UNKNOWN');

  price_src := coalesce(pme.evidence->'observed_market_price'->>'source_class',
                        pme.component_scores->'market_price_support'->>'source_class');
  metric_scope := CASE
    WHEN price_src IN ('OBSERVED','PLATFORM_REPORTED') THEN 'LOCAL'
    WHEN price_src = 'INFERRED' THEN 'CROSS_MARKET_REFERENCE'
    WHEN price_src = 'ESTIMATED' THEN 'LOCAL_UNVALIDATED'
    WHEN g_price = 'PASS' THEN 'LOCAL'
    ELSE 'LOCAL_UNVALIDATED' END;

  SELECT * INTO plat FROM public.product_market_platform_evaluations
  WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country
    AND recommendation NOT IN ('INSUFFICIENT_EVIDENCE','AVOID')
  ORDER BY CASE evidence_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW' THEN 2 ELSE 3 END,
           platform_fit_score DESC NULLS LAST, platform ASC
  LIMIT 1;
  IF plat.id IS NOT NULL THEN
    platform_score := plat.platform_fit_score;
    platform_conf  := plat.evidence_confidence;
    exec_ready     := plat.execution_readiness;
  END IF;

  product_score := (SELECT avg(x) FROM (VALUES
      ((pme.component_scores->'marketplace_validation'->>'subscore')::numeric),
      ((pme.component_scores->'demand_momentum'->>'subscore')::numeric),
      ((pme.component_scores->'buyer_search_intent'->>'subscore')::numeric)) v(x));
  competitor_score := (pme.component_scores->'competition_saturation_gap'->>'subscore')::numeric;
  supplier_score := (SELECT avg(x) FROM (VALUES
      ((pme.component_scores->'supplier_availability_stock'->>'subscore')::numeric),
      ((pme.component_scores->'landed_economics'->>'subscore')::numeric)) v(x));

  component_scores := jsonb_build_object(
    'product',   jsonb_build_object('subscore', product_score, 'confidence', market_conf,
                   'source_ref', pme.id, 'scope','LOCAL',
                   'note','product-intrinsic demand/validation signals (diagnostic)'),
    'market',    jsonb_build_object('subscore', market_score, 'confidence', market_conf,
                   'source_ref', pme.id, 'scope', metric_scope,
                   'note','authoritative product x market composite'),
    'platform',  CASE WHEN platform_score IS NULL
                   THEN jsonb_build_object('subscore', NULL, 'confidence','NONE','source_ref',NULL,'scope','LOCAL',
                          'note','no eligible acquisition-channel evidence for this market')
                   ELSE jsonb_build_object('subscore', platform_score, 'confidence', platform_conf,
                          'source_ref', plat.id, 'scope','LOCAL', 'platform', plat.platform) END,
    'competitor',jsonb_build_object('subscore', competitor_score, 'confidence', market_conf,
                   'source_ref', pme.id, 'scope','LOCAL',
                   'note','competitor saturation/gap signal (folded into market score)'),
    'supplier',  jsonb_build_object('subscore', supplier_score, 'confidence', market_conf,
                   'source_ref', pme.id, 'scope','LOCAL',
                   'note','supplier availability + landed economics (folded into market score)'));

  comp_input := jsonb_build_object(
    'market_dimension', jsonb_build_object('weight',70,'subscore', market_score),
    'platform_dimension', CASE WHEN platform_score IS NULL
        THEN jsonb_build_object('weight',30)
        ELSE jsonb_build_object('weight',30,'subscore', platform_score) END);
  comp := public.fn_pm_score(comp_input);
  score := nullif(comp->>'market_opportunity_score','')::numeric;
  coverage := nullif(comp->>'coverage','')::numeric;

  tier_of := CASE market_conf WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END;
  IF platform_conf IS NOT NULL THEN
    tier_of := least(tier_of, CASE platform_conf WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END);
  END IF;
  IF metric_scope <> 'LOCAL' THEN tier_of := least(tier_of, 2); END IF;
  IF platform_score IS NULL THEN tier_of := least(tier_of, 2); END IF;
  overall_conf := CASE tier_of WHEN 3 THEN 'HIGH' WHEN 2 THEN 'MEDIUM' WHEN 1 THEN 'LOW' ELSE 'NONE' END;

  hard_gates := jsonb_build_object('supplier',g_stock,'market_price',g_price,'economics',g_econ,
                                   'compliance',g_comp,'fulfilment',g_fulf);
  IF g_stock='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'SUPPLIER_OUT_OF_STOCK');
  ELSIF g_stock='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'SUPPLIER_STOCK_UNKNOWN'); END IF;
  IF g_econ='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'ECONOMICS_NEGATIVE_CONTRIBUTION');
  ELSIF g_econ='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'ECONOMICS_UNKNOWN'); END IF;
  IF g_price='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'MARKET_PRICE_INVALID');
  ELSIF g_price='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'MARKET_PRICE_NOT_LOCALLY_VALIDATED'); END IF;
  IF g_comp='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'COMPLIANCE_CRITICAL');
  ELSIF g_comp='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'COMPLIANCE_UNVERIFIED'); END IF;
  IF g_fulf='FAIL' THEN has_fail:=true; dblock:=array_append(dblock,'FULFILMENT_ROUTE_MISSING');
  ELSIF g_fulf='WATCH' THEN has_watch:=true; dblock:=array_append(dblock,'FULFILMENT_ROUTE_UNCONFIRMED'); END IF;

  IF exec_ready = 'BLOCKED' THEN eblock:=array_append(eblock,'EXECUTION_PLATFORM_API_BLOCKED');
  ELSIF exec_ready = 'NOT_CONNECTED' THEN eblock:=array_append(eblock,'EXECUTION_PLATFORM_NOT_CONNECTED'); END IF;
  IF platform_score IS NULL THEN eblock:=array_append(eblock,'NO_EXECUTABLE_PLATFORM_IDENTIFIED'); END IF;

  band := CASE
    WHEN score IS NULL THEN 'INSUFFICIENT'
    WHEN score < 40 THEN 'AVOID'
    WHEN score < 55 THEN 'WATCH'
    WHEN score < 70 THEN 'TRENDING_WATCH'
    WHEN score < 80 THEN 'STRONG_TEST'
    WHEN score < 90 THEN 'HIGH_CONFIDENCE_TEST'
    ELSE 'EXCEPTIONAL' END;

  IF has_fail THEN decision:='AVOID'; reasons:=array_append(reasons,'HARD_GATE_FAIL_OVERRIDES_SCORE');
  ELSIF has_watch THEN decision:='WATCH'; reasons:=array_append(reasons,'CANNOT_TEST_UNTIL_GATES_RESOLVE');
  ELSIF score IS NULL THEN decision:='WATCH'; reasons:=array_append(reasons,'NO_SCORE_INSUFFICIENT_EVIDENCE');
  ELSIF score >= 70 AND overall_conf IN ('MEDIUM','HIGH') THEN decision:='TEST'; reasons:=array_append(reasons,'SCORE_GATES_CONFIDENCE_PASS');
  ELSIF score >= 40 THEN decision:='WATCH'; reasons:=array_append(reasons,
          CASE WHEN score>=70 THEN 'SCORE_OK_BUT_LOW_CONFIDENCE' ELSE 'SCORE_BELOW_TEST_THRESHOLD' END);
  ELSE decision:='AVOID'; reasons:=array_append(reasons,'SCORE_BELOW_WATCH_THRESHOLD'); END IF;

  lifecycle := CASE
    WHEN decision='AVOID' THEN 'AVOID'
    WHEN decision='WATCH' THEN CASE WHEN band IN ('TRENDING_WATCH','STRONG_TEST','HIGH_CONFIDENCE_TEST','EXCEPTIONAL')
                                    THEN 'TRENDING_WATCH' ELSE 'WATCH' END
    WHEN decision='TEST' AND band IN ('HIGH_CONFIDENCE_TEST','EXCEPTIONAL')
         AND overall_conf='HIGH' AND platform_score IS NOT NULL THEN 'HIGH_CONFIDENCE_TEST'
    ELSE 'STRONG_TEST_CANDIDATE' END;

  action_gate := CASE
    WHEN decision='AVOID' THEN 'NO_ACTION'
    WHEN decision='WATCH' THEN 'MONITOR_GATHER_EVIDENCE'
    WHEN array_length(eblock,1) IS NOT NULL THEN 'DECISION_TEST_EXECUTION_BLOCKED'
    ELSE 'ELIGIBLE_FOR_LAUNCH_PREP' END;

  bec := nullif(pme.economics->>'break_even_cpa','')::numeric;
  econ_state := pme.economics->>'economics_state';
  contrib_reserve := nullif(pme.economics->>'contribution_after_reserve','')::numeric;
  cpa := (SELECT jsonb_object_agg(k, v) FROM (
      SELECT 'cpa_'||c::text AS k,
             CASE WHEN bec IS NULL THEN jsonb_build_object('contribution',NULL,'state','UNKNOWN')
                  ELSE jsonb_build_object('contribution', round(bec-c,2),
                        'state', CASE WHEN bec-c >= 15 THEN 'VIABLE' WHEN bec-c >= 0 THEN 'THIN' ELSE 'NEGATIVE' END) END AS v
      FROM (VALUES (10),(15),(20)) t(c)) s);

  reasons := array_append(reasons, 'BAND_'||band);
  reasons := array_append(reasons, 'METRIC_SCOPE_'||metric_scope);
  IF metric_scope <> 'LOCAL' THEN reasons:=array_append(reasons,'PRICE_IS_CROSS_MARKET_REFERENCE_NOT_LOCAL_VALIDATION'); END IF;

  IF p_persist THEN
    INSERT INTO public.product_opportunity_decisions AS d (
      tenant_id, product_id, country_code, market_currency, score_version,
      product_market_evaluation_id, primary_platform, primary_platform_evaluation_id, lineage,
      component_scores, product_opportunity_score, coverage, opportunity_band,
      overall_evidence_confidence, decision, lifecycle_state, metric_scope,
      hard_gates, decision_blockers, execution_blockers, action_gating,
      economics_ref, cpa_scenarios, decision_reasons, is_fixture, provenance)
    VALUES (
      p_tenant, p_product, p_country, pme.market_currency, p_score_version,
      pme.id, plat.platform, plat.id,
      jsonb_build_object('pme_id',pme.id,'platform_eval_id',plat.id,
        'competitor_rows',(SELECT count(*) FROM public.product_market_competitors
          WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country),
        'evaluated_at', now(), 'snapshot', true),
      component_scores, score, coverage, band, overall_conf, decision, lifecycle, metric_scope,
      hard_gates, to_jsonb(dblock), to_jsonb(eblock), action_gate,
      jsonb_build_object('pme_id',pme.id,'economics_state',econ_state,'break_even_cpa',bec,
        'contribution_after_reserve',contrib_reserve),
      cpa, to_jsonb(reasons), pme.is_fixture,
      jsonb_build_object('engine','pod_v1','built_from',jsonb_build_array('product_market_evaluations',
        'product_market_platform_evaluations','product_market_competitors')))
    ON CONFLICT (tenant_id, product_id, country_code, score_version) DO UPDATE SET
      market_currency=excluded.market_currency, product_market_evaluation_id=excluded.product_market_evaluation_id,
      primary_platform=excluded.primary_platform, primary_platform_evaluation_id=excluded.primary_platform_evaluation_id,
      lineage=excluded.lineage, component_scores=excluded.component_scores,
      product_opportunity_score=excluded.product_opportunity_score, coverage=excluded.coverage,
      opportunity_band=excluded.opportunity_band, overall_evidence_confidence=excluded.overall_evidence_confidence,
      decision=excluded.decision, lifecycle_state=excluded.lifecycle_state, metric_scope=excluded.metric_scope,
      hard_gates=excluded.hard_gates, decision_blockers=excluded.decision_blockers,
      execution_blockers=excluded.execution_blockers, action_gating=excluded.action_gating,
      economics_ref=excluded.economics_ref, cpa_scenarios=excluded.cpa_scenarios,
      decision_reasons=excluded.decision_reasons, is_fixture=excluded.is_fixture,
      provenance=excluded.provenance, created_at=now();
  END IF;

  RETURN jsonb_build_object(
    'tenant_id',p_tenant,'product_id',p_product,'country_code',p_country,
    'market_currency',pme.market_currency,'score_version',p_score_version,
    'product_opportunity_score',score,'coverage',coverage,'opportunity_band',band,
    'overall_evidence_confidence',overall_conf,'decision',decision,'lifecycle_state',lifecycle,
    'metric_scope',metric_scope,'component_scores',component_scores,
    'primary_platform',plat.platform,'primary_execution_readiness',exec_ready,
    'hard_gates',hard_gates,'decision_blockers',to_jsonb(dblock),'execution_blockers',to_jsonb(eblock),
    'action_gating',action_gate,'economics_ref',jsonb_build_object('economics_state',econ_state,
      'break_even_cpa',bec,'contribution_after_reserve',contrib_reserve),
    'cpa_scenarios',cpa,'decision_reasons',to_jsonb(reasons),
    'lineage',jsonb_build_object('pme_id',pme.id,'platform_eval_id',plat.id),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','Unified per-market decision. WINNER is reserved for post-launch real evidence; the strongest pre-launch state is HIGH_CONFIDENCE_TEST. Execution readiness gates ACTION, never the opportunity decision.',
    'contract','pulse_product_opportunity_decision_v1');
END; $$;
REVOKE ALL ON FUNCTION public.fn_pod_evaluate(uuid,uuid,text,text,boolean) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.fn_pod_tournament(
  p_tenant uuid, p_product uuid, p_score_version text DEFAULT 'pod_v1', p_persist boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE c record; combos jsonb; best record; avoid_markets text[]; live_markets text[];
BEGIN
  FOR c IN SELECT DISTINCT country_code FROM public.product_market_evaluations
           WHERE tenant_id=p_tenant AND product_id=p_product LOOP
    PERFORM public.fn_pod_evaluate(p_tenant, p_product, c.country_code, p_score_version, p_persist);
  END LOOP;

  WITH ranked AS (
    SELECT d.*,
      row_number() OVER (ORDER BY
        CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END ASC,
        d.product_opportunity_score DESC NULLS LAST,
        CASE d.overall_evidence_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW' THEN 2 ELSE 3 END ASC,
        nullif(d.economics_ref->>'contribution_after_reserve','')::numeric DESC NULLS LAST,
        d.country_code ASC) AS rnk
    FROM public.product_opportunity_decisions d
    WHERE d.tenant_id=p_tenant AND d.product_id=p_product AND d.score_version=p_score_version
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'rank',rnk,'country',country_code,'market_currency',market_currency,
      'product_opportunity_score',product_opportunity_score,'band',opportunity_band,
      'decision',decision,'lifecycle_state',lifecycle_state,'confidence',overall_evidence_confidence,
      'metric_scope',metric_scope,'primary_platform',primary_platform,
      'decision_blockers',decision_blockers,'execution_blockers',execution_blockers,
      'contribution_after_reserve', economics_ref->>'contribution_after_reserve') ORDER BY rnk),'[]'::jsonb)
  INTO combos FROM ranked;

  SELECT * INTO best FROM public.product_opportunity_decisions d
  WHERE d.tenant_id=p_tenant AND d.product_id=p_product AND d.score_version=p_score_version
  ORDER BY CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END ASC,
           d.product_opportunity_score DESC NULLS LAST,
           CASE d.overall_evidence_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW' THEN 2 ELSE 3 END ASC,
           nullif(d.economics_ref->>'contribution_after_reserve','')::numeric DESC NULLS LAST,
           d.country_code ASC LIMIT 1;

  SELECT array_agg(country_code) INTO avoid_markets FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND score_version=p_score_version AND decision='AVOID';
  SELECT array_agg(country_code ORDER BY country_code) INTO live_markets FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND score_version=p_score_version AND decision<>'AVOID';

  RETURN jsonb_build_object(
    'tenant_id',p_tenant,'product_id',p_product,'score_version',p_score_version,
    'evaluated_combinations',(SELECT count(*) FROM public.product_opportunity_decisions
       WHERE tenant_id=p_tenant AND product_id=p_product AND score_version=p_score_version),
    'product_market_tournament', combos,
    'best_market', best.country_code,
    'best_market_decision', best.decision,
    'best_market_score', best.product_opportunity_score,
    'best_market_lifecycle', best.lifecycle_state,
    'product_level_decision', best.decision,
    'cross_market_recovery', jsonb_build_object(
      'recovered_markets', COALESCE(to_jsonb(live_markets),'[]'::jsonb),
      'failed_markets', COALESCE(to_jsonb(avoid_markets),'[]'::jsonb),
      'product_globally_rejected', (live_markets IS NULL),
      'note','A product is never globally rejected on one market''s failure; each market is judged on its own local evidence.'),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','Ranks PRODUCT x MARKET combinations; best_market does NOT set campaign_target_market (separate founder approval).',
    'contract','pulse_product_opportunity_tournament_v1');
END; $$;
REVOKE ALL ON FUNCTION public.fn_pod_tournament(uuid,uuid,text,boolean) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.fn_pod_monday_block(p_tenant uuid, p_product uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE t jsonb; best record;
BEGIN
  SELECT * INTO best FROM public.product_opportunity_decisions d
  WHERE d.tenant_id=p_tenant AND d.product_id=p_product AND d.score_version='pod_v1'
  ORDER BY CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END ASC,
           d.product_opportunity_score DESC NULLS LAST,
           CASE d.overall_evidence_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW' THEN 2 ELSE 3 END ASC,
           d.country_code ASC LIMIT 1;
  IF best.id IS NULL THEN
    RETURN jsonb_build_object('product_id',p_product,'status','NO_UNIFIED_DECISION',
      'note','Run fn_pod_tournament first.','contract','pulse_product_opportunity_monday_v1');
  END IF;
  SELECT jsonb_agg(jsonb_build_object('country',country_code,'decision',decision,
           'score',product_opportunity_score,'band',opportunity_band,'confidence',overall_evidence_confidence)
           ORDER BY product_opportunity_score DESC NULLS LAST)
    INTO t FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND score_version='pod_v1' AND country_code<>best.country_code;
  RETURN jsonb_build_object(
    'product_id',p_product,
    'BEST_MARKET', best.country_code, 'DECISION', best.decision, 'LIFECYCLE_STATE', best.lifecycle_state,
    'PRODUCT_OPPORTUNITY_SCORE', best.product_opportunity_score, 'OPPORTUNITY_BAND', best.opportunity_band,
    'EVIDENCE_CONFIDENCE', best.overall_evidence_confidence, 'WHY', best.decision_reasons,
    'BEST_AD_PLATFORM', best.primary_platform, 'METRIC_SCOPE', best.metric_scope,
    'DECISION_BLOCKERS', best.decision_blockers, 'EXECUTION_BLOCKERS', best.execution_blockers,
    'CPA_SCENARIOS', best.cpa_scenarios, 'ACTION_GATING', best.action_gating,
    'CROSS_MARKET_ALTERNATIVES', COALESCE(t,'[]'::jsonb),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','Monday cadence unchanged; no new recurring workflow. WINNER is post-launch only.',
    'contract','pulse_product_opportunity_monday_v1');
END; $$;
REVOKE ALL ON FUNCTION public.fn_pod_monday_block(uuid,uuid) FROM PUBLIC, anon;

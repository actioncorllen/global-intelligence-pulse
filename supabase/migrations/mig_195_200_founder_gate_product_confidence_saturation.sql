-- PULSE-ECOM-UNIFIED-PRODUCT-OPPORTUNITY-DECISION-001 — FINAL FOUNDER-GATE additions
-- Deployed to Supabase project nxaunmyihhjixxxljcqt as:
--   mig_195  product_opportunity_decisions: + product_confidence, saturation_state, advertising_headroom, opportunity_sweet_spot
--   mig_196  fn_pod_evaluate rewrite (Product Confidence + saturation gate + Advertising Headroom + Opportunity Sweet Spot)
--   mig_197  fn_pod_tournament (opportunity-quality ranking) + fn_pod_monday_block (exposes the new fields, per-country)
--   mig_198  competitor/saturation fixtures + critical tournament (A vs B) + same-product cross-market + HIGH gap/no-gap
--   mig_199  fn_pod_evaluate: price compression downgrades headroom ONE tier (FINAL body below)
--   mig_200  Score-83/Confidence-MEDIUM/WATCH proof fixture + price-compression fixture
-- Founder-gate semantics (all fail-closed, evidence-only):
--   PRODUCT CONFIDENCE ∈ {HIGH,MEDIUM,LOW} only — separate from product_opportunity_score /
--     market/platform scores / overall_evidence_confidence / decision. A high numeric score never
--     auto-creates HIGH confidence; capped by weak local price provenance, UNKNOWN saturation, or
--     unverified stock/economics.
--   SATURATION GATE (same product × country, from the competitor engine): VERY_HIGH → WATCH; HIGH →
--     WATCH unless an evidence-backed defensible gap AND STRONG/PROMISING headroom (bounded exception);
--     MODERATE/LOW → eligible; UNKNOWN → fail closed to WATCH and never read as LOW. Demand never
--     overrides saturation.
--   ADVERTISING HEADROOM ∈ {STRONG,PROMISING,WEAK,INSUFFICIENT_EVIDENCE} from EUR 10/15/20 economic
--     STRESS scenarios (never CPA forecasts) + saturation context; competition is NEVER converted to
--     bid/CPC/CPA cost; price compression (evidence-backed PRICE_POSITIONING_GAP) downgrades one tier.
--   OPPORTUNITY SWEET SPOT ∈ {STRONG,PROMISING,WEAK,INSUFFICIENT_EVIDENCE} — a COMBINATION (demand +
--     manageable saturation + usable supplier/verified stock + defensible local price + viable economics
--     + headroom + confidence), not another score.
--   TOURNAMENT ranks PRODUCT × MARKET by opportunity quality (decision → sweet-spot → saturation penalty
--     → score → product confidence → headroom → contribution → country): an OPPORTUNITY finder, not a
--     popularity finder. Every market metric identifies its Product × Country (× Platform where relevant).
-- All fn_pod_* functions are SECURITY DEFINER, SET search_path='', REVOKE'd from PUBLIC and anon.
-- campaign_activation=FALSE; advertising_spend=0.

ALTER TABLE public.product_opportunity_decisions
  ADD COLUMN IF NOT EXISTS product_confidence text,               -- HIGH / MEDIUM / LOW only
  ADD COLUMN IF NOT EXISTS saturation_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS advertising_headroom jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS opportunity_sweet_spot jsonb NOT NULL DEFAULT '{}'::jsonb;

-- ═════════════════════════════════════════════════════════════════════════════
-- FINAL DEPLOYED FUNCTION BODIES (authoritative)
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
  sat jsonb; sat_level text; sat_conf text; sat_points numeric; sat_gaps jsonb; has_gap boolean;
  sat_gate text; pc_tier int; product_confidence text;
  c10 numeric; c15 numeric; c20 numeric; ah_state text; compression boolean := false;
  ss_state text; demand_present boolean;
  saturation_state jsonb; advertising_headroom jsonb; opportunity_sweet_spot jsonb;
BEGIN
  SELECT * INTO pme FROM public.product_market_evaluations
  WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country
  ORDER BY evaluation_ts DESC NULLS LAST, created_at DESC LIMIT 1;
  IF pme.id IS NULL THEN
    RETURN jsonb_build_object('tenant_id',p_tenant,'product_id',p_product,'country_code',p_country,
      'score_version',p_score_version,'decision','INSUFFICIENT_EVIDENCE','opportunity_band','INSUFFICIENT',
      'product_opportunity_score',NULL,'reason','NO_PRODUCT_MARKET_EVALUATION_FOR_COUNTRY',
      'note','A unified decision requires a country-specific market evaluation; global evaluation is never used.',
      'contract','pulse_product_opportunity_decision_v1');
  END IF;
  market_score := pme.market_opportunity_score; market_conf := pme.evidence_confidence;
  g_stock := coalesce(pme.gate_state->>'stock','UNKNOWN'); g_price := coalesce(pme.gate_state->>'price','UNKNOWN');
  g_econ := coalesce(pme.gate_state->>'economics','UNKNOWN'); g_comp := coalesce(pme.gate_state->>'compliance','UNKNOWN');
  g_fulf := coalesce(pme.gate_state->>'fulfilment','UNKNOWN');
  price_src := coalesce(pme.evidence->'observed_market_price'->>'source_class', pme.component_scores->'market_price_support'->>'source_class');
  metric_scope := CASE WHEN price_src IN ('OBSERVED','PLATFORM_REPORTED') THEN 'LOCAL'
    WHEN price_src='INFERRED' THEN 'CROSS_MARKET_REFERENCE' WHEN price_src='ESTIMATED' THEN 'LOCAL_UNVALIDATED'
    WHEN g_price='PASS' THEN 'LOCAL' ELSE 'LOCAL_UNVALIDATED' END;
  SELECT * INTO plat FROM public.product_market_platform_evaluations
  WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country AND recommendation NOT IN ('INSUFFICIENT_EVIDENCE','AVOID')
  ORDER BY CASE evidence_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 WHEN 'LOW' THEN 2 ELSE 3 END, platform_fit_score DESC NULLS LAST, platform ASC LIMIT 1;
  IF plat.id IS NOT NULL THEN platform_score := plat.platform_fit_score; platform_conf := plat.evidence_confidence; exec_ready := plat.execution_readiness; END IF;

  sat := public.fn_pmc_summary(p_tenant, p_product, p_country, coalesce(pme.market_currency,'EUR'));
  sat_level := coalesce(sat->'competition'->>'level','UNKNOWN'); sat_conf := sat->'competition'->>'confidence';
  sat_points := nullif(sat->'competition'->>'saturation_points','')::numeric;
  sat_gaps := coalesce(sat->'opportunity_gaps','[]'::jsonb); has_gap := jsonb_array_length(sat_gaps) > 0;

  product_score := (SELECT avg(x) FROM (VALUES ((pme.component_scores->'marketplace_validation'->>'subscore')::numeric),
      ((pme.component_scores->'demand_momentum'->>'subscore')::numeric),((pme.component_scores->'buyer_search_intent'->>'subscore')::numeric)) v(x));
  competitor_score := (pme.component_scores->'competition_saturation_gap'->>'subscore')::numeric;
  supplier_score := (SELECT avg(x) FROM (VALUES ((pme.component_scores->'supplier_availability_stock'->>'subscore')::numeric),
      ((pme.component_scores->'landed_economics'->>'subscore')::numeric)) v(x));
  demand_present := (pme.component_scores->'buyer_search_intent'->>'subscore') IS NOT NULL OR (pme.component_scores->'demand_momentum'->>'subscore') IS NOT NULL;

  component_scores := jsonb_build_object(
    'product', jsonb_build_object('subscore',product_score,'confidence',market_conf,'source_ref',pme.id,'scope','LOCAL','note','product-intrinsic demand/validation signals (diagnostic)'),
    'market', jsonb_build_object('subscore',market_score,'confidence',market_conf,'source_ref',pme.id,'scope',metric_scope,'note','authoritative product x market composite'),
    'platform', CASE WHEN platform_score IS NULL THEN jsonb_build_object('subscore',NULL,'confidence','NONE','source_ref',NULL,'scope','LOCAL','note','no eligible acquisition-channel evidence for this market')
      ELSE jsonb_build_object('subscore',platform_score,'confidence',platform_conf,'source_ref',plat.id,'scope','LOCAL','platform',plat.platform) END,
    'competitor', jsonb_build_object('subscore',competitor_score,'confidence',market_conf,'source_ref',pme.id,'scope','LOCAL','saturation_level',sat_level,'note','competitor saturation/gap signal (folded into market score)'),
    'supplier', jsonb_build_object('subscore',supplier_score,'confidence',market_conf,'source_ref',pme.id,'scope','LOCAL','note','supplier availability + landed economics (folded into market score)'));

  comp_input := jsonb_build_object('market_dimension',jsonb_build_object('weight',70,'subscore',market_score),
    'platform_dimension', CASE WHEN platform_score IS NULL THEN jsonb_build_object('weight',30) ELSE jsonb_build_object('weight',30,'subscore',platform_score) END);
  comp := public.fn_pm_score(comp_input);
  score := nullif(comp->>'market_opportunity_score','')::numeric; coverage := nullif(comp->>'coverage','')::numeric;

  tier_of := CASE market_conf WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END;
  IF platform_conf IS NOT NULL THEN tier_of := least(tier_of, CASE platform_conf WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END); END IF;
  IF metric_scope <> 'LOCAL' THEN tier_of := least(tier_of,2); END IF;
  IF platform_score IS NULL THEN tier_of := least(tier_of,2); END IF;
  overall_conf := CASE tier_of WHEN 3 THEN 'HIGH' WHEN 2 THEN 'MEDIUM' WHEN 1 THEN 'LOW' ELSE 'NONE' END;

  pc_tier := CASE WHEN coalesce(pme.coverage,0)>=0.75 THEN 3 WHEN coalesce(pme.coverage,0)>=0.5 THEN 2 ELSE 1 END;
  IF metric_scope <> 'LOCAL' THEN pc_tier := least(pc_tier,2); END IF;
  IF sat_level='UNKNOWN' THEN pc_tier := least(pc_tier,2); END IF;
  IF g_stock<>'PASS' THEN pc_tier := least(pc_tier,1); END IF;
  IF g_econ<>'PASS' THEN pc_tier := least(pc_tier,1); END IF;
  IF market_conf IN ('NONE','LOW') THEN pc_tier := least(pc_tier,1); END IF;
  product_confidence := CASE pc_tier WHEN 3 THEN 'HIGH' WHEN 2 THEN 'MEDIUM' ELSE 'LOW' END;

  bec := nullif(pme.economics->>'break_even_cpa','')::numeric; econ_state := pme.economics->>'economics_state';
  contrib_reserve := nullif(pme.economics->>'contribution_after_reserve','')::numeric;
  IF bec IS NOT NULL THEN c10:=round(bec-10,2); c15:=round(bec-15,2); c20:=round(bec-20,2); END IF;
  IF bec IS NULL OR metric_scope<>'LOCAL' OR sat_level='UNKNOWN' THEN ah_state:='INSUFFICIENT_EVIDENCE';
  ELSIF c20>=10 AND sat_level IN ('LOW','MODERATE') THEN ah_state:='STRONG';
  ELSIF c15>=5 AND sat_level<>'VERY_HIGH' THEN ah_state:='PROMISING';
  ELSE ah_state:='WEAK'; END IF;
  IF sat_gaps @> '[{"gap_type":"PRICE_POSITIONING_GAP"}]'::jsonb THEN
    ah_state := CASE ah_state WHEN 'STRONG' THEN 'PROMISING' WHEN 'PROMISING' THEN 'WEAK' ELSE ah_state END;
    compression := true; END IF;

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

  sat_gate := CASE WHEN sat_level='VERY_HIGH' THEN 'WATCH'
    WHEN sat_level='HIGH' AND has_gap AND ah_state IN ('STRONG','PROMISING') THEN 'PASS'
    WHEN sat_level='HIGH' THEN 'WATCH' WHEN sat_level='UNKNOWN' THEN 'WATCH' ELSE 'PASS' END;
  IF sat_gate='WATCH' THEN has_watch:=true;
    dblock := array_append(dblock, CASE WHEN sat_level='VERY_HIGH' THEN 'MARKET_SATURATION_VERY_HIGH'
      WHEN sat_level='HIGH' THEN 'MARKET_SATURATION_HIGH_NO_DEFENSIBLE_GAP' ELSE 'MARKET_SATURATION_UNKNOWN_FAIL_CLOSED' END);
  ELSIF sat_level='HIGH' THEN reasons := array_append(reasons,'HIGH_SATURATION_BOUNDED_EXCEPTION_GAP_AND_HEADROOM'); END IF;

  hard_gates := jsonb_build_object('supplier',g_stock,'market_price',g_price,'economics',g_econ,'compliance',g_comp,'fulfilment',g_fulf,'saturation',sat_gate);

  IF exec_ready='BLOCKED' THEN eblock:=array_append(eblock,'EXECUTION_PLATFORM_API_BLOCKED');
  ELSIF exec_ready='NOT_CONNECTED' THEN eblock:=array_append(eblock,'EXECUTION_PLATFORM_NOT_CONNECTED'); END IF;
  IF platform_score IS NULL THEN eblock:=array_append(eblock,'NO_EXECUTABLE_PLATFORM_IDENTIFIED'); END IF;

  band := CASE WHEN score IS NULL THEN 'INSUFFICIENT' WHEN score<40 THEN 'AVOID' WHEN score<55 THEN 'WATCH'
    WHEN score<70 THEN 'TRENDING_WATCH' WHEN score<80 THEN 'STRONG_TEST' WHEN score<90 THEN 'HIGH_CONFIDENCE_TEST' ELSE 'EXCEPTIONAL' END;

  IF has_fail THEN decision:='AVOID'; reasons:=array_append(reasons,'HARD_GATE_FAIL_OVERRIDES_SCORE');
  ELSIF has_watch THEN decision:='WATCH'; reasons:=array_append(reasons,'CANNOT_TEST_UNTIL_GATES_RESOLVE');
  ELSIF score IS NULL THEN decision:='WATCH'; reasons:=array_append(reasons,'NO_SCORE_INSUFFICIENT_EVIDENCE');
  ELSIF score>=70 AND overall_conf IN ('MEDIUM','HIGH') THEN decision:='TEST'; reasons:=array_append(reasons,'SCORE_GATES_CONFIDENCE_PASS');
  ELSIF score>=40 THEN decision:='WATCH'; reasons:=array_append(reasons, CASE WHEN score>=70 THEN 'SCORE_OK_BUT_LOW_CONFIDENCE' ELSE 'SCORE_BELOW_TEST_THRESHOLD' END);
  ELSE decision:='AVOID'; reasons:=array_append(reasons,'SCORE_BELOW_WATCH_THRESHOLD'); END IF;

  lifecycle := CASE WHEN decision='AVOID' THEN 'AVOID'
    WHEN decision='WATCH' THEN CASE WHEN band IN ('TRENDING_WATCH','STRONG_TEST','HIGH_CONFIDENCE_TEST','EXCEPTIONAL') THEN 'TRENDING_WATCH' ELSE 'WATCH' END
    WHEN decision='TEST' AND band IN ('HIGH_CONFIDENCE_TEST','EXCEPTIONAL') AND overall_conf='HIGH' AND platform_score IS NOT NULL THEN 'HIGH_CONFIDENCE_TEST'
    ELSE 'STRONG_TEST_CANDIDATE' END;
  action_gate := CASE WHEN decision='AVOID' THEN 'NO_ACTION' WHEN decision='WATCH' THEN 'MONITOR_GATHER_EVIDENCE'
    WHEN array_length(eblock,1) IS NOT NULL THEN 'DECISION_TEST_EXECUTION_BLOCKED' ELSE 'ELIGIBLE_FOR_LAUNCH_PREP' END;

  cpa := (SELECT jsonb_object_agg(k,v) FROM (SELECT 'cpa_'||c::text AS k,
      CASE WHEN bec IS NULL THEN jsonb_build_object('contribution',NULL,'state','UNKNOWN')
           ELSE jsonb_build_object('contribution',round(bec-c,2),'state',CASE WHEN bec-c>=15 THEN 'VIABLE' WHEN bec-c>=0 THEN 'THIN' ELSE 'NEGATIVE' END) END AS v
      FROM (VALUES (10),(15),(20)) t(c)) s);

  IF sat_level='UNKNOWN' OR metric_scope<>'LOCAL' OR bec IS NULL OR score IS NULL THEN ss_state:='INSUFFICIENT_EVIDENCE';
  ELSIF sat_level IN ('LOW','MODERATE') AND g_stock='PASS' AND g_price='PASS' AND g_econ='PASS' AND ah_state IN ('STRONG','PROMISING') AND product_confidence='HIGH' AND score>=70 AND demand_present THEN ss_state:='STRONG';
  ELSIF sat_level IN ('LOW','MODERATE','HIGH') AND g_stock='PASS' AND g_econ='PASS' AND ah_state<>'WEAK' AND product_confidence IN ('HIGH','MEDIUM') AND score>=55 THEN ss_state:='PROMISING';
  ELSE ss_state:='WEAK'; END IF;

  saturation_state := jsonb_build_object('level',sat_level,'confidence',sat_conf,'saturation_points',sat_points,'has_defensible_gap',has_gap,
    'source','product_market_competitors','evidence_class','OBSERVED','product',p_product,'country',p_country,
    'note','competition state for THIS product x country; demand never overrides saturation; counts are not CPC/CPA/ROAS');
  advertising_headroom := jsonb_build_object('state',ah_state,'price_compression',compression,
    'cpa_stress',jsonb_build_object('cpa_10',c10,'cpa_15',c15,'cpa_20',c20),'break_even_cpa',bec,'saturation_context',sat_level,
    'product',p_product,'country',p_country,'note','EUR 10/15/20 are stress scenarios, not CPA forecasts; competition is NOT converted to bid/CPC/CPA cost');
  opportunity_sweet_spot := jsonb_build_object('state',ss_state,'product',p_product,'country',p_country,
    'components',jsonb_build_object('demand_present',demand_present,'saturation',sat_level,'supplier_stock',g_stock,'local_price',metric_scope,
      'economics',econ_state,'advertising_headroom',ah_state,'product_confidence',product_confidence,'opportunity_score',score),
    'note','combination of demand + manageable saturation + usable supplier/stock + defensible local price + viable economics + headroom + confidence; not a single score');

  reasons := array_append(reasons,'BAND_'||band); reasons := array_append(reasons,'METRIC_SCOPE_'||metric_scope);
  reasons := array_append(reasons,'PRODUCT_CONFIDENCE_'||product_confidence); reasons := array_append(reasons,'SATURATION_'||sat_level);
  reasons := array_append(reasons,'HEADROOM_'||ah_state); reasons := array_append(reasons,'SWEET_SPOT_'||ss_state);
  IF compression THEN reasons := array_append(reasons,'PRICE_COMPRESSION_DOWNGRADED_HEADROOM'); END IF;
  IF metric_scope<>'LOCAL' THEN reasons := array_append(reasons,'PRICE_IS_CROSS_MARKET_REFERENCE_NOT_LOCAL_VALIDATION'); END IF;

  IF p_persist THEN
    INSERT INTO public.product_opportunity_decisions AS d (
      tenant_id, product_id, country_code, market_currency, score_version, product_market_evaluation_id, primary_platform, primary_platform_evaluation_id, lineage,
      component_scores, product_opportunity_score, coverage, opportunity_band, overall_evidence_confidence, product_confidence, decision, lifecycle_state, metric_scope,
      saturation_state, advertising_headroom, opportunity_sweet_spot, hard_gates, decision_blockers, execution_blockers, action_gating,
      economics_ref, cpa_scenarios, decision_reasons, is_fixture, provenance)
    VALUES (p_tenant, p_product, p_country, pme.market_currency, p_score_version, pme.id, plat.platform, plat.id,
      jsonb_build_object('pme_id',pme.id,'platform_eval_id',plat.id,'competitor_rows',(SELECT count(*) FROM public.product_market_competitors WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=p_country),'evaluated_at',now(),'snapshot',true),
      component_scores, score, coverage, band, overall_conf, product_confidence, decision, lifecycle, metric_scope,
      saturation_state, advertising_headroom, opportunity_sweet_spot, hard_gates, to_jsonb(dblock), to_jsonb(eblock), action_gate,
      jsonb_build_object('pme_id',pme.id,'economics_state',econ_state,'break_even_cpa',bec,'contribution_after_reserve',contrib_reserve),
      cpa, to_jsonb(reasons), pme.is_fixture,
      jsonb_build_object('engine','pod_v1','built_from',jsonb_build_array('product_market_evaluations','product_market_platform_evaluations','product_market_competitors')))
    ON CONFLICT (tenant_id, product_id, country_code, score_version) DO UPDATE SET
      market_currency=excluded.market_currency, product_market_evaluation_id=excluded.product_market_evaluation_id, primary_platform=excluded.primary_platform,
      primary_platform_evaluation_id=excluded.primary_platform_evaluation_id, lineage=excluded.lineage, component_scores=excluded.component_scores,
      product_opportunity_score=excluded.product_opportunity_score, coverage=excluded.coverage, opportunity_band=excluded.opportunity_band,
      overall_evidence_confidence=excluded.overall_evidence_confidence, product_confidence=excluded.product_confidence, decision=excluded.decision,
      lifecycle_state=excluded.lifecycle_state, metric_scope=excluded.metric_scope, saturation_state=excluded.saturation_state,
      advertising_headroom=excluded.advertising_headroom, opportunity_sweet_spot=excluded.opportunity_sweet_spot, hard_gates=excluded.hard_gates,
      decision_blockers=excluded.decision_blockers, execution_blockers=excluded.execution_blockers, action_gating=excluded.action_gating,
      economics_ref=excluded.economics_ref, cpa_scenarios=excluded.cpa_scenarios, decision_reasons=excluded.decision_reasons,
      is_fixture=excluded.is_fixture, provenance=excluded.provenance, created_at=now();
  END IF;

  RETURN jsonb_build_object('tenant_id',p_tenant,'product_id',p_product,'country_code',p_country,'market_currency',pme.market_currency,'score_version',p_score_version,
    'product_opportunity_score',score,'coverage',coverage,'opportunity_band',band,'overall_evidence_confidence',overall_conf,'product_confidence',product_confidence,
    'decision',decision,'lifecycle_state',lifecycle,'metric_scope',metric_scope,'component_scores',component_scores,
    'saturation_state',saturation_state,'advertising_headroom',advertising_headroom,'opportunity_sweet_spot',opportunity_sweet_spot,
    'primary_platform',plat.platform,'primary_execution_readiness',exec_ready,'hard_gates',hard_gates,'decision_blockers',to_jsonb(dblock),'execution_blockers',to_jsonb(eblock),
    'action_gating',action_gate,'economics_ref',jsonb_build_object('economics_state',econ_state,'break_even_cpa',bec,'contribution_after_reserve',contrib_reserve),
    'cpa_scenarios',cpa,'decision_reasons',to_jsonb(reasons),'lineage',jsonb_build_object('pme_id',pme.id,'platform_eval_id',plat.id),
    'campaign_activation',false,'advertising_spend',0,
    'note','Unified per-market decision. WINNER is post-launch only; strongest pre-launch is HIGH_CONFIDENCE_TEST. Execution readiness gates ACTION, never the opportunity decision. Saturation gates TEST eligibility; demand never overrides it.',
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
        CASE d.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
        CASE d.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END ASC,
        d.product_opportunity_score DESC NULLS LAST,
        CASE d.product_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 ELSE 2 END ASC,
        CASE d.advertising_headroom->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
        nullif(d.economics_ref->>'contribution_after_reserve','')::numeric DESC NULLS LAST,
        d.country_code ASC) AS rnk
    FROM public.product_opportunity_decisions d
    WHERE d.tenant_id=p_tenant AND d.product_id=p_product AND d.score_version=p_score_version)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'rank',rnk,'country',country_code,'market_currency',market_currency,
      'product_opportunity_score',product_opportunity_score,'band',opportunity_band,
      'decision',decision,'lifecycle_state',lifecycle_state,'confidence',overall_evidence_confidence,
      'product_confidence',product_confidence,'saturation',saturation_state->>'level',
      'advertising_headroom',advertising_headroom->>'state','opportunity_sweet_spot',opportunity_sweet_spot->>'state',
      'metric_scope',metric_scope,'primary_platform',primary_platform,
      'decision_blockers',decision_blockers,'execution_blockers',execution_blockers,
      'contribution_after_reserve', economics_ref->>'contribution_after_reserve') ORDER BY rnk),'[]'::jsonb)
  INTO combos FROM ranked;
  SELECT * INTO best FROM public.product_opportunity_decisions d
  WHERE d.tenant_id=p_tenant AND d.product_id=p_product AND d.score_version=p_score_version
  ORDER BY CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END ASC,
           CASE d.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
           CASE d.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END ASC,
           d.product_opportunity_score DESC NULLS LAST,
           CASE d.product_confidence WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 ELSE 2 END ASC,
           CASE d.advertising_headroom->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
           nullif(d.economics_ref->>'contribution_after_reserve','')::numeric DESC NULLS LAST, d.country_code ASC LIMIT 1;
  SELECT array_agg(country_code) INTO avoid_markets FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND score_version=p_score_version AND decision='AVOID';
  SELECT array_agg(country_code ORDER BY country_code) INTO live_markets FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND score_version=p_score_version AND decision<>'AVOID';
  RETURN jsonb_build_object(
    'tenant_id',p_tenant,'product_id',p_product,'score_version',p_score_version,
    'evaluated_combinations',(SELECT count(*) FROM public.product_opportunity_decisions WHERE tenant_id=p_tenant AND product_id=p_product AND score_version=p_score_version),
    'product_market_tournament', combos,
    'best_market', best.country_code, 'best_market_decision', best.decision,
    'best_market_score', best.product_opportunity_score, 'best_market_lifecycle', best.lifecycle_state,
    'best_market_sweet_spot', best.opportunity_sweet_spot->>'state', 'best_market_saturation', best.saturation_state->>'level',
    'product_level_decision', best.decision,
    'cross_market_recovery', jsonb_build_object(
      'recovered_markets', COALESCE(to_jsonb(live_markets),'[]'::jsonb),
      'failed_markets', COALESCE(to_jsonb(avoid_markets),'[]'::jsonb),
      'product_globally_rejected', (live_markets IS NULL),
      'note','A product is never globally rejected on one market''s failure; each market is judged on its own local evidence.'),
    'campaign_activation', false, 'advertising_spend', 0,
    'ranking_note','Ranks PRODUCT x MARKET by opportunity quality (sweet-spot, saturation, headroom, confidence), not popularity; best_market does NOT set campaign_target_market.',
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
           CASE d.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END ASC,
           CASE d.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END ASC,
           d.product_opportunity_score DESC NULLS LAST, d.country_code ASC LIMIT 1;
  IF best.id IS NULL THEN
    RETURN jsonb_build_object('product_id',p_product,'status','NO_UNIFIED_DECISION','note','Run fn_pod_tournament first.','contract','pulse_product_opportunity_monday_v1');
  END IF;
  SELECT jsonb_agg(jsonb_build_object('country',country_code,'decision',decision,'score',product_opportunity_score,'band',opportunity_band,
           'confidence',overall_evidence_confidence,'product_confidence',product_confidence,'saturation',saturation_state->>'level',
           'advertising_headroom',advertising_headroom->>'state','opportunity_sweet_spot',opportunity_sweet_spot->>'state')
           ORDER BY product_opportunity_score DESC NULLS LAST)
    INTO t FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND score_version='pod_v1' AND country_code<>best.country_code;
  RETURN jsonb_build_object('product_id',p_product,
    'BEST_MARKET', best.country_code, 'DECISION', best.decision, 'LIFECYCLE_STATE', best.lifecycle_state,
    'PRODUCT_OPPORTUNITY_SCORE', best.product_opportunity_score, 'OPPORTUNITY_BAND', best.opportunity_band,
    'PRODUCT_CONFIDENCE', best.product_confidence, 'EVIDENCE_CONFIDENCE', best.overall_evidence_confidence,
    'SATURATION', jsonb_build_object('country',best.country_code,'level',best.saturation_state->>'level','confidence',best.saturation_state->>'confidence'),
    'ADVERTISING_HEADROOM', jsonb_build_object('country',best.country_code,'state',best.advertising_headroom->>'state'),
    'OPPORTUNITY_SWEET_SPOT', jsonb_build_object('country',best.country_code,'state',best.opportunity_sweet_spot->>'state'),
    'WHY', best.decision_reasons, 'BEST_AD_PLATFORM', best.primary_platform, 'METRIC_SCOPE', best.metric_scope,
    'DECISION_BLOCKERS', best.decision_blockers, 'EXECUTION_BLOCKERS', best.execution_blockers,
    'CPA_SCENARIOS', best.cpa_scenarios, 'ACTION_GATING', best.action_gating,
    'CROSS_MARKET_ALTERNATIVES', COALESCE(t,'[]'::jsonb),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','Every market metric identifies its country. Monday cadence unchanged; no new recurring workflow. WINNER is post-launch only.',
    'contract','pulse_product_opportunity_monday_v1');
END; $$;
REVOKE ALL ON FUNCTION public.fn_pod_monday_block(uuid,uuid) FROM PUBLIC, anon;

-- =====================================================================================
-- PULSE-ECOM-MARKET-EXPLORER-SECURITY-002 — tenant-isolation fix (repo mirror of mig_217)
-- Applied to Supabase project nxaunmyihhjixxxljcqt.
--
-- DEFECT (launch-critical): market-explorer RPCs accepted a client-supplied p_tenant from
-- the authenticated browser (user could choose which tenant's Product x Country evaluations
-- to read); the core also leaked is_fixture rows into any tenant's result.
-- FIX: harden core to strict per-tenant filtering + definer-only; add auth-derived "own"
-- wrappers (the only authenticated surface) resolving tenant via member.application_ref.
-- Grants verified least-privilege; cross-tenant + unauth negative tests pass.
-- =====================================================================================

-- Canonical tenant resolver: auth.uid() -> member.application_ref (mirrors get_own_*).
CREATE OR REPLACE FUNCTION public.fn__own_tenant()
 RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_count int; v_app uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN NULL; END IF;
  SELECT count(*), min(m.application_ref::text)::uuid INTO v_count, v_app
  FROM public.member AS m WHERE m.auth_user_id = v_uid;
  IF v_count <> 1 THEN RETURN NULL; END IF;   -- 0 = no member, >1 = ambiguous -> fail closed
  RETURN v_app;                                -- may be NULL if member has no application yet
END; $function$;
REVOKE ALL ON FUNCTION public.fn__own_tenant() FROM PUBLIC, anon, authenticated;

-- Hardened CORE (definer-only; strict tenant filter; NO fixture leak).
CREATE OR REPLACE FUNCTION public.fn_product_country_explorer(
  p_tenant uuid, p_product_id uuid, p_selling_markets text[] DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
  WITH ev AS (
    SELECT DISTINCT ON (e.country_code) e.country_code, e.market_currency, e.market_opportunity_score,
      e.evidence_confidence, e.market_decision, e.component_scores, e.economics, e.gate_state,
      e.stock_state, e.compliance_risk, e.evidence, e.risk_flags, e.evaluation_ts
    FROM public.product_market_evaluations e
    WHERE e.product_id=p_product_id AND e.tenant_id=p_tenant          -- strict tenant scope (no is_fixture)
    ORDER BY e.country_code, e.evaluation_ts DESC
  ),
  plat AS (
    SELECT DISTINCT ON (country_code) country_code, platform, platform_fit_score, recommendation
    FROM public.product_market_platform_evaluations
    WHERE product_id=p_product_id AND tenant_id=p_tenant             -- strict tenant scope
    ORDER BY country_code, platform_fit_score DESC NULLS LAST
  ),
  cards AS (
    SELECT u.country_code, u.country_name, u.region, u.default_currency, u.status AS universe_status,
      ev.country_code IS NOT NULL AS evaluated,
      ev.market_decision, ev.market_opportunity_score, ev.evidence_confidence, ev.market_currency,
      ev.component_scores, ev.economics, ev.gate_state, ev.stock_state, ev.compliance_risk, ev.evidence, ev.risk_flags,
      plat.platform AS primary_platform, plat.platform_fit_score,
      (p_selling_markets IS NULL OR u.country_code = ANY(p_selling_markets)) AS within_selling,
      CASE ev.market_decision WHEN 'TEST' THEN 3 WHEN 'WATCH' THEN 2 WHEN 'AVOID' THEN 1 ELSE 0 END AS drank,
      public.fn_eur_to_local(ev.market_currency) AS eur2loc
    FROM public.ecommerce_market_universe u
    LEFT JOIN ev ON ev.country_code=u.country_code
    LEFT JOIN plat ON plat.country_code=u.country_code
    WHERE u.status IN ('ELIGIBLE','LIMITED_EVIDENCE') OR ev.country_code IS NOT NULL
  ),
  best AS (
    SELECT country_code FROM cards WHERE evaluated AND universe_status='ELIGIBLE' AND market_decision IN ('TEST','WATCH')
    ORDER BY drank DESC, market_opportunity_score DESC NULLS LAST, country_code LIMIT 1
  ),
  best_sell AS (
    SELECT country_code FROM cards WHERE evaluated AND universe_status='ELIGIBLE' AND within_selling AND market_decision IN ('TEST','WATCH')
    ORDER BY drank DESC, market_opportunity_score DESC NULLS LAST, country_code LIMIT 1
  ),
  built AS (
    SELECT c.*, (c.country_code = (SELECT country_code FROM best)) AS is_recommended,
      CASE WHEN c.evaluated THEN 'EVALUATED' WHEN c.universe_status='ELIGIBLE' THEN 'ANALYSIS_REQUIRED'
        WHEN c.universe_status='LIMITED_EVIDENCE' THEN 'LIMITED_EVIDENCE' ELSE 'UNSUPPORTED' END AS evaluation_state
    FROM cards c
  )
  SELECT jsonb_build_object('contract','pulse_country_opportunity_explorer_v1','product_id', p_product_id,
    'recommended_best_market', (SELECT to_jsonb(x) FROM (
        SELECT country_code AS country, country_name AS name, region, market_decision AS decision,
          market_opportunity_score AS score, evidence_confidence AS confidence, primary_platform,
          'strongest legitimate evaluated market: highest decision tier then market opportunity score; not biased by country size' AS why
        FROM built WHERE country_code=(SELECT country_code FROM best)) x),
    'global_opportunity', (SELECT country_code FROM best),
    'best_available_within_selling_markets', (SELECT country_code FROM best_sell),
    'selling_market_constraint', to_jsonb(p_selling_markets),
    'markets', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'country', country_code,'name',country_name,'region',region,'currency',default_currency,
        'evaluation_state', evaluation_state,'is_recommended', is_recommended,'universe_status', universe_status,'within_selling_markets', within_selling,
        'decision', market_decision,'score', market_opportunity_score,'confidence', evidence_confidence,
        'buyer_intent', component_scores->'buyer_search_intent'->'subscore','demand_momentum', component_scores->'demand_momentum'->'subscore',
        'marketplace_validation', component_scores->'marketplace_validation'->'subscore','advertising_activity', component_scores->'advertising_activity'->'subscore',
        'competition_saturation_gap', component_scores->'competition_saturation_gap'->'subscore',
        'local_price', evidence->'observed_market_price','stock_state', stock_state,'compliance_risk', compliance_risk,'gate_state', gate_state,
        'economics', CASE WHEN economics IS NULL THEN NULL ELSE jsonb_build_object(
            'currency', economics->'money'->>'display_currency','selling_price', economics->'selling_price','landed_cost', economics->'landed_cost_display',
            'break_even_cpa', economics->'break_even_cpa','contribution_before_ads', economics->'contribution_before_ads',
            'contribution_after_reserve', economics->'contribution_after_reserve','economics_state', economics->>'economics_state') END,
        'cpa_scenarios_local', CASE WHEN economics->'contribution_before_ads' IS NULL THEN NULL ELSE jsonb_build_object(
            'currency', market_currency,'eur_reserve_equiv', true,
            'cpa_eur10', round((economics->>'contribution_before_ads')::numeric - 10*eur2loc, 2),
            'cpa_eur15', round((economics->>'contribution_before_ads')::numeric - 15*eur2loc, 2),
            'cpa_eur20', round((economics->>'contribution_before_ads')::numeric - 20*eur2loc, 2)) END,
        'primary_platform', coalesce(primary_platform, CASE WHEN evaluated THEN 'ANALYSIS_REQUIRED' ELSE NULL END),
        'risks', coalesce(risk_flags,'[]'::jsonb))
        ORDER BY is_recommended DESC, drank DESC, market_opportunity_score DESC NULLS LAST, universe_status, country_code)
      FROM built),'[]'::jsonb),
    'evaluated_count', (SELECT count(*) FROM built WHERE evaluated),
    'analysis_required_count', (SELECT count(*) FROM built WHERE evaluation_state='ANALYSIS_REQUIRED'),
    'safety', jsonb_build_object('campaign_target_market','UNCHANGED','spend_authorized', false,
      'note','selecting a country in the explorer never sets campaign target and never authorizes campaign creation, activation or spend'),
    'country_isolation','each market card is that country''s own evaluation; USA evidence cannot satisfy Germany; UNKNOWN/unevaluated is never treated as favorable',
    'policy','Product x Country canonical; local price stays in local currency; supplier/saturation/economics/platform are country-specific')
  INTO result; RETURN result;
END; $function$;
REVOKE ALL ON FUNCTION public.fn_product_country_explorer(uuid,uuid,text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_market_comparison(p_tenant uuid, p_product_id uuid, p_countries text[])
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE result jsonb;
BEGIN
  WITH ev AS (
    SELECT DISTINCT ON (e.country_code) e.country_code, e.market_currency, e.market_opportunity_score,
      e.evidence_confidence, e.market_decision, e.component_scores, e.economics, e.evidence, e.stock_state
    FROM public.product_market_evaluations e
    WHERE e.product_id=p_product_id AND e.country_code = ANY(p_countries) AND e.tenant_id=p_tenant
    ORDER BY e.country_code, e.evaluation_ts DESC
  )
  SELECT jsonb_build_object('contract','pulse_market_comparison_v1','product_id',p_product_id,'countries',to_jsonb(p_countries),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('country', c,
        'evaluation_state', CASE WHEN ev.country_code IS NOT NULL THEN 'EVALUATED'
             WHEN EXISTS(SELECT 1 FROM public.ecommerce_market_universe u WHERE u.country_code=c AND u.status='ELIGIBLE') THEN 'ANALYSIS_REQUIRED'
             WHEN EXISTS(SELECT 1 FROM public.ecommerce_market_universe u WHERE u.country_code=c AND u.status='LIMITED_EVIDENCE') THEN 'LIMITED_EVIDENCE' ELSE 'UNSUPPORTED' END,
        'decision', ev.market_decision,'score', ev.market_opportunity_score,'confidence', ev.evidence_confidence,
        'buyer_intent', ev.component_scores->'buyer_search_intent'->'subscore',
        'competition_saturation_gap', ev.component_scores->'competition_saturation_gap'->'subscore',
        'local_price', ev.evidence->'observed_market_price','currency', ev.market_currency,'stock_state', ev.stock_state,
        'contribution_after_reserve', ev.economics->'contribution_after_reserve','break_even_cpa', ev.economics->'break_even_cpa')
        ORDER BY c) FROM unnest(p_countries) c LEFT JOIN ev ON ev.country_code=c),'[]'::jsonb),
    'note','same product, independent per-country evaluations; evidence never transferred across markets')
  INTO result; RETURN result;
END; $function$;
REVOKE ALL ON FUNCTION public.fn_market_comparison(uuid,uuid,text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_country_evaluation_state(p_tenant uuid, p_product_id uuid, p_country text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE u record; has_eval boolean;
BEGIN
  SELECT * INTO u FROM public.ecommerce_market_universe WHERE country_code=p_country;
  SELECT EXISTS(SELECT 1 FROM public.product_market_evaluations e
     WHERE e.product_id=p_product_id AND e.country_code=p_country AND e.tenant_id=p_tenant) INTO has_eval;
  IF u.country_code IS NULL THEN
    RETURN jsonb_build_object('country',p_country,'state','UNSUPPORTED','reason','country not in ecommerce market universe');
  ELSIF has_eval THEN
    RETURN jsonb_build_object('country',p_country,'state','EVALUATED','universe_status',u.status,'action','read fn_own_product_country_explorer for full intelligence');
  ELSIF u.status='ELIGIBLE' THEN
    RETURN jsonb_build_object('country',p_country,'state','ANALYSIS_REQUIRED','universe_status',u.status,
      'action','run Product x Country deep validation pipeline for this market, then persist','note','missing evidence is NOT low saturation and NOT favorable');
  ELSE
    RETURN jsonb_build_object('country',p_country,'state',u.status,'universe_status',u.status,
      'reason','insufficient legitimate source coverage to evaluate this market','note','missing evidence is never interpreted as favorable');
  END IF;
END; $function$;
REVOKE ALL ON FUNCTION public.fn_country_evaluation_state(uuid,uuid,text) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.fn_market_candidacy_screen(uuid,uuid,text[],numeric) FROM PUBLIC, anon, authenticated;

-- OWN wrappers (authenticated-only; tenant derived server-side; fail closed).
CREATE OR REPLACE FUNCTION public.fn_own_product_country_explorer(
  p_product_id uuid, p_selling_markets text[] DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_app uuid; v_core jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  v_app := public.fn__own_tenant();
  IF v_app IS NULL THEN RETURN jsonb_build_object('status','not_found','reason','no_authorized_tenant'); END IF;
  v_core := public.fn_product_country_explorer(v_app, p_product_id, p_selling_markets);
  RETURN v_core || jsonb_build_object('status','ok');
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_own_product_country_explorer(uuid,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_own_product_country_explorer(uuid,text[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_own_country_evaluation_state(p_product_id uuid, p_country text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_app uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  v_app := public.fn__own_tenant();
  IF v_app IS NULL THEN RETURN jsonb_build_object('status','not_found','reason','no_authorized_tenant'); END IF;
  RETURN public.fn_country_evaluation_state(v_app, p_product_id, p_country) || jsonb_build_object('status','ok');
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_own_country_evaluation_state(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_own_country_evaluation_state(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_own_market_comparison(p_product_id uuid, p_countries text[])
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_app uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  v_app := public.fn__own_tenant();
  IF v_app IS NULL THEN RETURN jsonb_build_object('status','not_found','reason','no_authorized_tenant'); END IF;
  RETURN public.fn_market_comparison(v_app, p_product_id, p_countries) || jsonb_build_object('status','ok');
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_own_market_comparison(uuid,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_own_market_comparison(uuid,text[]) TO authenticated;

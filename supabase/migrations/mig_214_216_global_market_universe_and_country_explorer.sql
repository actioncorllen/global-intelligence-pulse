-- =====================================================================================
-- PULSE-ECOM: GLOBAL ECOMMERCE MARKET UNIVERSE + INTERACTIVE COUNTRY OPPORTUNITY EXPLORER
-- Repo mirror of migrations applied to Supabase project nxaunmyihhjixxxljcqt:
--   mig_214  ecommerce_market_universe + eBay marketplace coverage + fn_market_universe_sync
--   mig_215  fn_market_candidacy_screen        (Stage A lightweight global screen)
--   mig_216  fn_eur_to_local + fn_product_country_explorer + fn_market_comparison
--            + fn_country_evaluation_state       (same-product Country Opportunity Explorer)
--
-- Founder addenda (permanent): Pulse is a GLOBAL opportunity intelligence platform.
-- No hardcoded DE/GB/FR/US universe. Two-stage market selection (lightweight global screen
-- -> dynamic deep-validation shortlist). Country isolation preserved; local price stays
-- local; saturation/economics/platform/supplier are country-specific; currencies dynamic.
-- The universe is CAPABILITY-DERIVED from Pulse's real provider coverage (never fabricated).
-- DEPENDENCY (reported): Pulse holds no authoritative global ecommerce-eligibility dataset;
-- the universe is limited to verified-coverage markets and is configurable to ingest one later.
-- Reuses: provider_capability_registry, product_market_evaluations,
-- product_market_platform_evaluations, fx_rates, marketing_spend_authority (read-only).
-- Explorer never sets campaign_target_market and never authorizes spend.
-- =====================================================================================

-- ---- mig_214 ------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ecommerce_market_universe (
  country_code text PRIMARY KEY,
  country_name text NOT NULL,
  region text NOT NULL,
  default_currency text NOT NULL,
  currency_supported boolean NOT NULL DEFAULT false,
  supplier_supported text NOT NULL DEFAULT 'UNKNOWN',
  search_intelligence_supported text NOT NULL DEFAULT 'UNKNOWN',
  marketplace_intelligence_supported text NOT NULL DEFAULT 'UNKNOWN',
  advertising_intelligence_supported text NOT NULL DEFAULT 'UNKNOWN',
  campaign_execution_supported text NOT NULL DEFAULT 'UNKNOWN',
  ecommerce_eligible boolean NOT NULL DEFAULT false,
  evidence_coverage numeric NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'UNKNOWN',
  is_operator_config boolean NOT NULL DEFAULT false,
  authoritative_dataset text,
  basis jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.ecommerce_market_universe ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ecommerce_market_universe FROM PUBLIC, anon;

DELETE FROM public.provider_capability_registry WHERE source='EBAY' AND evidence_category='MARKETPLACE' AND market<>'*';
INSERT INTO public.provider_capability_registry (source, evidence_category, market, availability, coverage_type, capability, limitations, last_verified_at, updated_at)
SELECT 'EBAY','MARKETPLACE', m, 'AVAILABLE','MARKET_SPECIFIC',
  jsonb_build_object('api','browse','note','documented eBay Browse marketplace'), NULL, now(), now()
FROM unnest(ARRAY['US','CA','GB','DE','FR','IT','ES','NL','IE','AT','BE','CH','PL','AU','HK','SG','MY','PH']) m;

INSERT INTO public.ecommerce_market_universe (country_code, country_name, region, default_currency) VALUES
  ('GB','United Kingdom','EUROPE','GBP'),('DE','Germany','EUROPE','EUR'),('FR','France','EUROPE','EUR'),
  ('IT','Italy','EUROPE','EUR'),('ES','Spain','EUROPE','EUR'),('NL','Netherlands','EUROPE','EUR'),
  ('IE','Ireland','EUROPE','EUR'),('AT','Austria','EUROPE','EUR'),('BE','Belgium','EUROPE','EUR'),
  ('CH','Switzerland','EUROPE','CHF'),('PL','Poland','EUROPE','PLN'),('SE','Sweden','EUROPE','SEK'),
  ('DK','Denmark','EUROPE','DKK'),('NO','Norway','EUROPE','NOK'),('CZ','Czechia','EUROPE','CZK'),
  ('RO','Romania','EUROPE','RON'),('HU','Hungary','EUROPE','HUF'),
  ('US','United States','NORTH_AMERICA','USD'),('CA','Canada','NORTH_AMERICA','CAD'),
  ('MX','Mexico','LATAM','MXN'),('BR','Brazil','LATAM','BRL'),
  ('AU','Australia','APAC','AUD'),('NZ','New Zealand','APAC','NZD'),('SG','Singapore','APAC','SGD'),
  ('HK','Hong Kong','APAC','HKD'),('JP','Japan','APAC','JPY'),('KR','South Korea','APAC','KRW'),
  ('IN','India','APAC','INR'),('MY','Malaysia','APAC','MYR'),('PH','Philippines','APAC','PHP'),
  ('TH','Thailand','APAC','THB'),('ID','Indonesia','APAC','IDR'),
  ('IL','Israel','MEA','ILS'),('TR','Turkey','MEA','TRY'),('ZA','South Africa','MEA','ZAR')
ON CONFLICT (country_code) DO NOTHING;

CREATE OR REPLACE FUNCTION public.fn_market_universe_sync()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE affected int; result jsonb;
BEGIN
  WITH cap AS (
    SELECT u.country_code,
      (SELECT availability FROM public.provider_capability_registry r
        WHERE r.source='DATAFORSEO' AND r.evidence_category='SEARCH_DEMAND' AND r.market IN (u.country_code,'*')
        ORDER BY (r.market=u.country_code) DESC LIMIT 1) AS search_av,
      (SELECT count(*) FROM public.provider_capability_registry r
        WHERE r.source='EBAY' AND r.evidence_category='MARKETPLACE' AND r.market=u.country_code AND r.availability='AVAILABLE') AS mkt_specific_rows,
      (SELECT availability FROM public.provider_capability_registry r
        WHERE r.source='CJ' AND r.evidence_category='SUPPLIER' AND r.market IN (u.country_code,'*')
        ORDER BY (r.market=u.country_code) DESC LIMIT 1) AS sup_av,
      (SELECT count(*) FROM public.provider_capability_registry r
        WHERE r.source='META_AD_LIBRARY' AND r.evidence_category='ADVERTISING' AND r.market=u.country_code AND r.availability='AVAILABLE') AS meta_rows,
      (u.default_currency='USD' OR EXISTS(SELECT 1 FROM public.fx_rates f WHERE f.quote_currency=u.default_currency)) AS cur_ok
    FROM public.ecommerce_market_universe u WHERE NOT u.is_operator_config
  ),
  derived AS (
    SELECT country_code,
      CASE WHEN search_av='AVAILABLE' THEN 'AVAILABLE' WHEN search_av='SOURCE_BLOCKED' THEN 'BLOCKED' ELSE 'UNSUPPORTED' END AS search_s,
      CASE WHEN mkt_specific_rows>0 THEN 'AVAILABLE' ELSE 'UNSUPPORTED' END AS mkt_s,
      CASE WHEN sup_av='AVAILABLE' THEN 'AVAILABLE' ELSE 'UNKNOWN' END AS sup_s,
      CASE WHEN meta_rows>0 THEN 'AVAILABLE' ELSE 'UNSUPPORTED' END AS adv_s,
      CASE WHEN meta_rows>0 THEN 'AVAILABLE' ELSE 'UNSUPPORTED' END AS exec_s, cur_ok
    FROM cap
  ),
  scored AS (
    SELECT country_code, search_s, mkt_s, sup_s, adv_s, exec_s, cur_ok,
      round( (CASE WHEN search_s='AVAILABLE' THEN 0.30 ELSE 0 END
            + CASE WHEN mkt_s='AVAILABLE' THEN 0.30 ELSE 0 END
            + CASE WHEN sup_s='AVAILABLE' THEN 0.20 ELSE 0 END
            + CASE WHEN adv_s='AVAILABLE' THEN 0.20 ELSE 0 END)::numeric, 2) AS cov,
      (search_s='AVAILABLE' AND mkt_s='AVAILABLE' AND sup_s='AVAILABLE' AND cur_ok) AS eligible
    FROM derived
  )
  UPDATE public.ecommerce_market_universe u SET
    currency_supported = s.cur_ok, supplier_supported = s.sup_s,
    search_intelligence_supported = s.search_s, marketplace_intelligence_supported = s.mkt_s,
    advertising_intelligence_supported = s.adv_s, campaign_execution_supported = s.exec_s,
    ecommerce_eligible = s.eligible, evidence_coverage = s.cov,
    status = CASE WHEN s.eligible THEN 'ELIGIBLE'
               WHEN s.search_s='AVAILABLE' AND s.sup_s='AVAILABLE' AND s.cur_ok THEN 'LIMITED_EVIDENCE'
               WHEN s.search_s='UNSUPPORTED' AND s.mkt_s='UNSUPPORTED' THEN 'UNSUPPORTED' ELSE 'UNKNOWN' END,
    basis = jsonb_build_object('derived_from','provider_capability_registry+fx_rates',
      'weights', jsonb_build_object('search',0.30,'marketplace',0.30,'supplier',0.20,'advertising',0.20),
      'note','capability-derived eligibility (Pulse can evaluate) NOT demand; demand is product-specific (Stage B)',
      'dependency','authoritative global ecommerce-eligibility dataset not held by Pulse; universe limited to verified-coverage markets'),
    updated_at = now()
  FROM scored s WHERE s.country_code=u.country_code;
  GET DIAGNOSTICS affected = ROW_COUNT;
  SELECT jsonb_build_object('synced', affected,
    'eligible', (SELECT count(*) FROM public.ecommerce_market_universe WHERE status='ELIGIBLE'),
    'limited_evidence', (SELECT count(*) FROM public.ecommerce_market_universe WHERE status='LIMITED_EVIDENCE'),
    'unsupported', (SELECT count(*) FROM public.ecommerce_market_universe WHERE status='UNSUPPORTED'),
    'unknown', (SELECT count(*) FROM public.ecommerce_market_universe WHERE status='UNKNOWN'),
    'universe_size', (SELECT count(*) FROM public.ecommerce_market_universe),
    'external_dependency','AUTHORITATIVE_GLOBAL_ECOMMERCE_ELIGIBILITY_DATASET (not held; universe is capability-derived + configurable)'
  ) INTO result;
  RETURN result;
END; $function$;
REVOKE ALL ON FUNCTION public.fn_market_universe_sync() FROM PUBLIC, anon;

-- ---- mig_215 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_market_candidacy_screen(
  p_tenant uuid, p_product_id uuid, p_selling_markets text[] DEFAULT NULL, p_shortlist_threshold numeric DEFAULT 55)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE result jsonb; has_demand boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM public.commerce_signals s WHERE s.product_id=p_product_id) INTO has_demand;
  WITH scored AS (
    SELECT u.country_code, u.country_name, u.region, u.default_currency, u.status,
      u.evidence_coverage, u.advertising_intelligence_supported,
      EXISTS(SELECT 1 FROM public.market_price_observations mpo WHERE mpo.product_id=p_product_id AND mpo.market=u.country_code) AS has_local_price,
      EXISTS(SELECT 1 FROM public.product_market_evaluations e WHERE e.product_id=p_product_id AND e.country_code=u.country_code AND (e.tenant_id=p_tenant OR e.is_fixture)) AS already_evaluated,
      (p_selling_markets IS NULL OR u.country_code = ANY(p_selling_markets)) AS within_selling
    FROM public.ecommerce_market_universe u WHERE u.status IN ('ELIGIBLE','LIMITED_EVIDENCE')
  ),
  cand AS (
    SELECT *, least(100, round(
        CASE status WHEN 'ELIGIBLE' THEN 40 WHEN 'LIMITED_EVIDENCE' THEN 20 ELSE 0 END
      + evidence_coverage*25 + CASE WHEN advertising_intelligence_supported='AVAILABLE' THEN 10 ELSE 0 END
      + CASE WHEN has_local_price THEN 15 ELSE 0 END + CASE WHEN has_demand THEN 10 ELSE 0 END,1)) AS candidacy
    FROM scored
  )
  SELECT jsonb_build_object('contract','pulse_market_candidacy_screen_v1','product_id', p_product_id,
    'universe_screened', (SELECT count(*) FROM cand),'selling_market_constraint', to_jsonb(p_selling_markets),
    'shortlist', coalesce((SELECT jsonb_agg(jsonb_build_object('country',country_code,'name',country_name,'region',region,'currency',default_currency,
        'candidacy',candidacy,'status',status,'coverage',evidence_coverage,'advertising',advertising_intelligence_supported,
        'has_local_price',has_local_price,'already_evaluated',already_evaluated,'within_selling_markets',within_selling)
        ORDER BY candidacy DESC, country_code) FROM cand WHERE candidacy >= p_shortlist_threshold AND status='ELIGIBLE'),'[]'::jsonb),
    'shortlist_size', (SELECT count(*) FROM cand WHERE candidacy >= p_shortlist_threshold AND status='ELIGIBLE'),
    'ranked_all', coalesce((SELECT jsonb_agg(jsonb_build_object('country',country_code,'candidacy',candidacy,'status',status)
        ORDER BY candidacy DESC, country_code) FROM cand),'[]'::jsonb),
    'weighting', jsonb_build_object('base_eligible',40,'base_limited',20,'coverage_x',25,'advertising',10,'local_price',15,'demand_signal',10,'cap',100),
    'cost', jsonb_build_object('external_api_calls',0,'note','Stage A uses only already-held signals; deep validation (Stage B) is where external calls are spent'),
    'policy','screen is candidacy only; never replaces Product Opportunity Score/Confidence/Sweet Spot/Headroom; UNKNOWN evidence is never treated as favorable')
  INTO result; RETURN result;
END; $function$;
REVOKE ALL ON FUNCTION public.fn_market_candidacy_screen(uuid,uuid,text[],numeric) FROM PUBLIC, anon;

-- ---- mig_216 ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_eur_to_local(p_ccy text)
 RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT CASE
    WHEN p_ccy='EUR' THEN 1::numeric
    WHEN p_ccy='USD' THEN round(1/(SELECT rate FROM public.fx_rates WHERE base_currency='USD' AND quote_currency='EUR' ORDER BY as_of DESC LIMIT 1),5)
    ELSE round((SELECT rate FROM public.fx_rates WHERE base_currency='USD' AND quote_currency=p_ccy ORDER BY as_of DESC LIMIT 1)
      / (SELECT rate FROM public.fx_rates WHERE base_currency='USD' AND quote_currency='EUR' ORDER BY as_of DESC LIMIT 1), 5)
  END;
$$;
REVOKE ALL ON FUNCTION public.fn_eur_to_local(text) FROM PUBLIC, anon;

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
    WHERE e.product_id=p_product_id AND (e.tenant_id=p_tenant OR e.is_fixture)
    ORDER BY e.country_code, e.evaluation_ts DESC
  ),
  plat AS (
    SELECT DISTINCT ON (country_code) country_code, platform, platform_fit_score, recommendation
    FROM public.product_market_platform_evaluations
    WHERE product_id=p_product_id AND (tenant_id=p_tenant OR is_fixture)
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
REVOKE ALL ON FUNCTION public.fn_product_country_explorer(uuid,uuid,text[]) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.fn_market_comparison(p_tenant uuid, p_product_id uuid, p_countries text[])
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE result jsonb;
BEGIN
  WITH ev AS (
    SELECT DISTINCT ON (e.country_code) e.country_code, e.market_currency, e.market_opportunity_score,
      e.evidence_confidence, e.market_decision, e.component_scores, e.economics, e.evidence, e.stock_state
    FROM public.product_market_evaluations e
    WHERE e.product_id=p_product_id AND e.country_code = ANY(p_countries) AND (e.tenant_id=p_tenant OR e.is_fixture)
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
REVOKE ALL ON FUNCTION public.fn_market_comparison(uuid,uuid,text[]) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.fn_country_evaluation_state(p_tenant uuid, p_product_id uuid, p_country text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE u record; has_eval boolean;
BEGIN
  SELECT * INTO u FROM public.ecommerce_market_universe WHERE country_code=p_country;
  SELECT EXISTS(SELECT 1 FROM public.product_market_evaluations e
     WHERE e.product_id=p_product_id AND e.country_code=p_country AND (e.tenant_id=p_tenant OR e.is_fixture)) INTO has_eval;
  IF u.country_code IS NULL THEN
    RETURN jsonb_build_object('country',p_country,'state','UNSUPPORTED','reason','country not in ecommerce market universe');
  ELSIF has_eval THEN
    RETURN jsonb_build_object('country',p_country,'state','EVALUATED','universe_status',u.status,'action','read fn_product_country_explorer for full intelligence');
  ELSIF u.status='ELIGIBLE' THEN
    RETURN jsonb_build_object('country',p_country,'state','ANALYSIS_REQUIRED','universe_status',u.status,
      'action','run Product x Country deep validation pipeline for this market, then persist','note','missing evidence is NOT low saturation and NOT favorable');
  ELSE
    RETURN jsonb_build_object('country',p_country,'state',u.status,'universe_status',u.status,
      'reason','insufficient legitimate source coverage to evaluate this market','note','missing evidence is never interpreted as favorable');
  END IF;
END; $function$;
REVOKE ALL ON FUNCTION public.fn_country_evaluation_state(uuid,uuid,text) FROM PUBLIC, anon;

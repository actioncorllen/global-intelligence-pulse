-- mig_368b — Authoritative market -> provider config resolver + discovery request builder
--
-- DURABLE CONTRACT: given a selected country, production resolves, from the one
-- authoritative supported-market config (ecommerce_market_universe), the provider
-- location id, a VALID provider language, currency, ecommerce eligibility and the
-- per-channel evidence scope — automatically, with no market hardcoded anywhere.
-- fn_dataforseo_discovery_request turns that into the exact DataForSEO
-- keyword_ideas request the discovery relay (013Q) must send, so the relay never
-- re-derives or hardcodes location/language.
--
-- Fail-closed: an unknown market returns ok=false/UNKNOWN_MARKET; a market missing
-- a location or language returns ok=false/NO_PROVIDER_LOCATION|NO_PROVIDER_LANGUAGE;
-- a market whose search intelligence is unavailable returns
-- SEARCH_INTELLIGENCE_UNAVAILABLE. Callers must check ok before using the config.

CREATE OR REPLACE FUNCTION public.fn_market_provider_config(p_country text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.ecommerce_market_universe%ROWTYPE; v_ok boolean;
BEGIN
  SELECT * INTO r FROM public.ecommerce_market_universe WHERE upper(country_code)=upper(btrim(coalesce(p_country,'')));
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'supported',false,'country',upper(coalesce(p_country,'')),'reason','UNKNOWN_MARKET');
  END IF;
  v_ok := (r.dataforseo_location_code IS NOT NULL
           AND coalesce(nullif(btrim(r.dataforseo_language_code),''),NULL) IS NOT NULL
           AND coalesce(r.search_intelligence_supported,'')='AVAILABLE');
  RETURN jsonb_build_object(
    'ok', v_ok, 'supported', v_ok, 'country', r.country_code,
    'dataforseo_location_code', r.dataforseo_location_code,
    'dataforseo_language_code', r.dataforseo_language_code,
    'currency', r.default_currency,
    'ecommerce_eligible', r.ecommerce_eligible,
    'search_intelligence_supported', r.search_intelligence_supported,
    'evidence_scope', jsonb_build_object('search',r.search_intelligence_supported,
      'marketplace',r.marketplace_intelligence_supported,'advertising',r.advertising_intelligence_supported),
    'reason', CASE WHEN v_ok THEN 'OK'
      WHEN r.dataforseo_location_code IS NULL THEN 'NO_PROVIDER_LOCATION'
      WHEN coalesce(nullif(btrim(r.dataforseo_language_code),''),NULL) IS NULL THEN 'NO_PROVIDER_LANGUAGE'
      ELSE 'SEARCH_INTELLIGENCE_UNAVAILABLE' END);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_market_provider_config(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_dataforseo_discovery_request(p_market text, p_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE cfg jsonb;
BEGIN
  cfg := public.fn_market_provider_config(p_market);
  IF coalesce((cfg->>'ok')::boolean,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok',false,'reason',cfg->>'reason','market',upper(coalesce(p_market,'')));
  END IF;
  RETURN jsonb_build_object('ok',true,'market',cfg->>'country',
    'location_code',(cfg->>'dataforseo_location_code')::int,
    'language_code',cfg->>'dataforseo_language_code',
    'currency',cfg->>'currency',
    'keyword_ideas_request', jsonb_build_array(jsonb_build_object(
       'keywords', jsonb_build_array(p_category),
       'location_code',(cfg->>'dataforseo_location_code')::int,
       'language_code',cfg->>'dataforseo_language_code',
       'limit',30,'include_serp_info',false)));
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_dataforseo_discovery_request(text, text) TO authenticated, service_role;

-- TARGETED REGRESSION: proves multiple markets resolve correctly (DE->de NOT en,
-- GB/US->en, IT->it, BE->nl), that an unknown market is unsupported, that no
-- ecommerce-eligible+search-available market is missing provider config, and that
-- the request builder resolves language from the authoritative config.
CREATE OR REPLACE FUNCTION public.fn_market_provider_config_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; de jsonb; gb jsonb; it jsonb; be jsonb; us jsonb; zz jsonb; n_gap int;
BEGIN
  de := public.fn_market_provider_config('DE');
  gb := public.fn_market_provider_config('GB');
  it := public.fn_market_provider_config('IT');
  be := public.fn_market_provider_config('BE');
  us := public.fn_market_provider_config('US');
  zz := public.fn_market_provider_config('ZZ');

  v := v || jsonb_build_object('check','DE_resolves_de_not_en',
    'pass', (de->>'dataforseo_location_code'='2276' AND de->>'dataforseo_language_code'='de' AND (de->>'ok')::boolean), 'detail', de->>'dataforseo_language_code');
  v := v || jsonb_build_object('check','GB_resolves_en','pass',(gb->>'dataforseo_language_code'='en' AND gb->>'dataforseo_location_code'='2826'));
  v := v || jsonb_build_object('check','IT_resolves_it','pass',(it->>'dataforseo_language_code'='it'));
  v := v || jsonb_build_object('check','BE_resolves_nl','pass',(be->>'dataforseo_language_code'='nl'));
  v := v || jsonb_build_object('check','US_resolves_en','pass',(us->>'dataforseo_language_code'='en' AND us->>'dataforseo_location_code'='2840'));
  v := v || jsonb_build_object('check','unknown_market_unsupported','pass',((zz->>'supported')::boolean IS FALSE AND zz->>'reason'='UNKNOWN_MARKET'));
  SELECT count(*) INTO n_gap FROM public.ecommerce_market_universe
    WHERE ecommerce_eligible AND coalesce(search_intelligence_supported,'')='AVAILABLE'
      AND (dataforseo_location_code IS NULL OR coalesce(nullif(btrim(dataforseo_language_code),''),NULL) IS NULL);
  v := v || jsonb_build_object('check','no_eligible_market_missing_provider_config','pass',(n_gap=0),'detail',n_gap);
  v := v || jsonb_build_object('check','discovery_request_builder_resolves_language',
    'pass',((public.fn_dataforseo_discovery_request('DE','posture corrector'))->>'language_code'='de'));

  RETURN jsonb_build_object('suite','market_provider_config','total',jsonb_array_length(v),
    'failed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_market_provider_config_selftest() TO authenticated, service_role;

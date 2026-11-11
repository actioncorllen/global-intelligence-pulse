-- ============================================================================
-- mig_293_kalodata_provider_registry.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A (Phase 2 — provider registration)
--
-- PURPOSE (additive, verified-only, NO live API call, NO credentials, NO fabricated
-- endpoints or response fields): register Kalodata in the EXISTING provider registry
-- (provider_capability_registry) so Strateloq's country-specific intelligence knows,
-- per market, whether Kalodata product intelligence is a real option — without
-- assuming Kalodata covers all of Strateloq's markets.
--
-- WHAT IS VERIFIED (from Kalodata's own public sources, researched 2026-11-11):
--   * Kalodata operates an official Open API with 6 modules: Category, Shop, Creator,
--     Product, Video, Livestream. Calls are HTTP POST + JSON + API-key auth.
--   * Base host: https://www.kalodata.com/openapi/v1/tiktok/... . Two product endpoints
--     are named in Kalodata's own material: POST /openapi/v1/tiktok/product/rank and
--     POST /openapi/v1/tiktok/product/detail.
--   * Kalodata's knowledge base states data coverage of 15 countries:
--     US, GB, DE, FR, ES, IT, MX, BR, ID, MY, TH, VN, PH, SG, JP.
--   * Access is Enterprise-gated; API keys are issued via Kalodata's "Open Center";
--     usage is credit-metered (billable).
--
-- WHAT IS NOT VERIFIED (therefore NOT encoded as a callable contract here):
--   * Exact request parameter names, response field names, per-endpoint credit cost,
--     and rate limits. These live in Kalodata's gated partner documentation and need
--     an Enterprise account + API credentials. No endpoint parser is written here.
--
-- CONNECTION STATE: availability = 'SOURCE_UNSUPPORTED' for every Kalodata row — we
-- cannot source Kalodata yet (no credentials), mirroring how TIKTOK was staged
-- (mig_259/267/268) before its token broker was connected. The *provider coverage*
-- fact (which 15 markets Kalodata serves) is recorded in the capability jsonb so the
-- "don't assume all markets" gate is correct now; a later phase flips availability to
-- 'AVAILABLE' once credentials + the verified field schema exist.
--
-- SAFETY: the market-eligibility recompute (mig_214_216) reads ONLY (DATAFORSEO,
-- SEARCH_DEMAND), (EBAY, MARKETPLACE), (CJ, SUPPLIER), (META_AD_LIBRARY, ADVERTISING).
-- A KALODATA/PRODUCT_INTELLIGENCE row is read by none of them, so NO existing market's
-- eligibility, score or decision changes. Research images stay in the mig_292 lane.
-- ============================================================================

-- idempotent: clear any prior Kalodata capability rows, then re-register.
DELETE FROM public.provider_capability_registry
 WHERE source = 'KALODATA' AND evidence_category = 'PRODUCT_INTELLIGENCE';

INSERT INTO public.provider_capability_registry
  (source, evidence_category, market, availability, coverage_type, capability, limitations, last_verified_at, updated_at)
SELECT
  'KALODATA', 'PRODUCT_INTELLIGENCE', m, 'SOURCE_UNSUPPORTED', 'PRODUCT_PERFORMANCE',
  jsonb_build_object(
    'provider', 'Kalodata',
    'provider_market_covered', true,
    'metric_families', jsonb_build_array('sales','revenue','growth','price','rank','market_coverage'),
    'modules', jsonb_build_array('Category','Shop','Creator','Product','Video','Livestream'),
    'documented_endpoints', jsonb_build_array(
        'POST /openapi/v1/tiktok/product/rank','POST /openapi/v1/tiktok/product/detail'),
    'api_base', 'https://www.kalodata.com/openapi/v1/tiktok',
    'auth', 'API_KEY_POST_JSON',
    'billing', 'CREDIT_METERED',
    'access', 'ENTERPRISE_OPEN_CENTER',
    'images', 'RESEARCH_LICENSED_ONLY',               -- see mig_292; not ad/storefront eligible
    'field_schema_state', 'PENDING_PARTNER_DOCS_AND_CREDENTIALS',
    'verified_source', 'kalodata.com open API announcement + blog + knowledge base (web research 2026-11-11)',
    'connection_state', 'PENDING_CREDENTIAL'
  ),
  'Research intelligence for authenticated Product Discovery only; NOT advertising or storefront rights. '
  || 'Credit-metered (billable); Enterprise-gated (Open Center). Exact request params + response field '
  || 'names + per-endpoint credit cost + rate limits require Kalodata partner documentation and API '
  || 'credentials (not available in this environment). Live fetch to run server-side (n8n) like other '
  || 'providers once connected. Does NOT cover every Strateloq market (verified 15-country coverage).',
  '2026-11-11T00:00:00Z'::timestamptz, now()
FROM unnest(ARRAY[
  'US','GB','DE','FR','ES','IT','MX','BR','ID','MY','TH','VN','PH','SG','JP'
]) AS m;

-- market-coverage gate: answers "does Kalodata cover this market, and can we source it
-- yet?" so a future ingestion NEVER requests a market Kalodata does not serve and never
-- assumes a live connection. Reads the registry only; no external call.
CREATE OR REPLACE FUNCTION public.fn_kalodata_market_supported(p_country_code text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT CASE
    WHEN r.source IS NULL THEN
      jsonb_build_object('country_code', upper(coalesce(p_country_code,'')),
        'provider_covered', false, 'availability', 'NOT_COVERED', 'sourceable_now', false,
        'note', 'Kalodata does not cover this market (verified 15-country coverage)')
    ELSE
      jsonb_build_object('country_code', upper(p_country_code),
        'provider_covered', true, 'availability', r.availability,
        'sourceable_now', (r.availability = 'AVAILABLE'),
        'connection_state', r.capability->>'connection_state',
        'note', CASE WHEN r.availability = 'AVAILABLE' THEN 'Kalodata covered and connected'
                     ELSE 'Kalodata covers this market; Strateloq activation pending credentials + verified field schema' END)
  END
  FROM (SELECT NULL::text AS source) z
  LEFT JOIN public.provider_capability_registry r
    ON r.source = 'KALODATA' AND r.evidence_category = 'PRODUCT_INTELLIGENCE'
   AND r.market = upper(coalesce(p_country_code,''));
$function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_market_supported(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_market_supported(text) TO authenticated, service_role;

-- selftest: verified coverage set + no-interference + honest connection state.
CREATE OR REPLACE FUNCTION public.fn_kalodata_provider_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_covered text[] := ARRAY['US','GB','DE','FR','ES','IT','MX','BR','ID','MY','TH','VN','PH','SG','JP'];
  -- Strateloq active-registry markets that Kalodata does NOT cover (must stay unsupported)
  v_uncovered text[] := ARRAY['CA','NL','IE','AT','BE','CH','PL','AU','HK'];
  v_reg_markets text[];
  v_other_before int;
BEGIN
  SELECT array_agg(market ORDER BY market) INTO v_reg_markets
  FROM public.provider_capability_registry
  WHERE source='KALODATA' AND evidence_category='PRODUCT_INTELLIGENCE';

  -- 1) exactly the 15 verified markets are registered
  v := v || jsonb_build_object('case','verified_15_markets_registered','pass',
        (SELECT array_agg(x ORDER BY x) FROM unnest(v_reg_markets) x)
          = (SELECT array_agg(x ORDER BY x) FROM unnest(v_covered) x));
  -- 2) every covered market reports provider_covered=true, not sourceable yet (no creds)
  v := v || jsonb_build_object('case','covered_markets_pending_credential','pass',
        NOT EXISTS (SELECT 1 FROM unnest(v_covered) c
                    WHERE (public.fn_kalodata_market_supported(c)->>'provider_covered')::boolean IS DISTINCT FROM true
                       OR (public.fn_kalodata_market_supported(c)->>'sourceable_now')::boolean IS DISTINCT FROM false));
  -- 3) uncovered Strateloq markets are reported NOT covered (don't assume full coverage)
  v := v || jsonb_build_object('case','uncovered_markets_not_claimed','pass',
        NOT EXISTS (SELECT 1 FROM unnest(v_uncovered) u
                    WHERE (public.fn_kalodata_market_supported(u)->>'provider_covered')::boolean IS DISTINCT FROM false));
  -- 4) no Kalodata row is AVAILABLE (we have no credentials; nothing sourceable yet)
  v := v || jsonb_build_object('case','no_kalodata_available_without_credentials','pass',
        NOT EXISTS (SELECT 1 FROM public.provider_capability_registry
                    WHERE source='KALODATA' AND availability='AVAILABLE'));
  -- 5) existing providers are untouched (DATAFORSEO/EBAY/CJ/META still registered)
  SELECT count(*) INTO v_other_before FROM public.provider_capability_registry
  WHERE source IN ('DATAFORSEO','EBAY','CJ','META_AD_LIBRARY');
  v := v || jsonb_build_object('case','existing_providers_untouched','pass', (v_other_before > 0));
  -- 6) Kalodata registered as research intelligence, not advertising/supplier/storefront
  v := v || jsonb_build_object('case','registered_as_product_intelligence','pass',
        NOT EXISTS (SELECT 1 FROM public.provider_capability_registry
                    WHERE source='KALODATA' AND evidence_category <> 'PRODUCT_INTELLIGENCE'));
  -- 7) no fabricated field schema asserted (field_schema_state is explicitly pending)
  v := v || jsonb_build_object('case','field_schema_marked_pending','pass',
        NOT EXISTS (SELECT 1 FROM public.provider_capability_registry
                    WHERE source='KALODATA'
                      AND coalesce(capability->>'field_schema_state','') <> 'PENDING_PARTNER_DOCS_AND_CREDENTIALS'));

  RETURN jsonb_build_object('suite','kalodata_provider_registry',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_provider_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_provider_selftest() TO service_role;

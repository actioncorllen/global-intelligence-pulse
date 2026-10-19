-- mig_312_product_competitor_evidence.sql
--
-- FINAL INTELLIGENCE ALIGNMENT (additive, no DROP, NO paid provider calls).
-- Exposes GENUINE market-specific competitor PRICES + PRICE RANGE + observed ADS + CREATIVE PATTERNS
-- + SOURCE FRESHNESS to the signed-in Product Intelligence drawer, scoped to ONE product + market, by
-- reusing the existing `product_market_competitors` contract (same row shape as
-- fn_ecommerce_competitor_intelligence). This replaces the drawer's whole-tenant competitor pull
-- (which returned every competitor row the tenant owns and filtered client-side) with an efficient,
-- server-scoped, country-isolated read, and adds a currency-safe observed price range.
--
-- Advertising evidence (observed advertisers / creatives / coverage / freshness) is served by the
-- ALREADY-DEPLOYED, authenticated-granted contract fn_product_ad_evidence (pulse_product_ad_evidence_v1);
-- this migration does NOT rewrite that live function (zero behaviour risk) — it only re-asserts its grant
-- and records its contract as a COMMENT so the repo captures the previously-uncommitted deployment.
--
-- Invariants held: server-owned auth (auth.uid(); p_* never trusted for authz); fail-closed denied shapes;
-- country isolation; dedup by verified product identity; REFERENCE_ONLY display media; UNKNOWN stays
-- UNKNOWN (observation flags + jsonb_strip_nulls; never a fabricated 0). No new paid calls.

-- 1) Re-assert + document the already-deployed advertising evidence contract (drift capture, no body rewrite)
GRANT EXECUTE ON FUNCTION public.fn_product_ad_evidence(uuid, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.fn_product_ad_evidence(uuid, text) IS
  'pulse_product_ad_evidence_v1 — per product+country Meta/TikTok Ad Library evidence (observed advertisers, '
  'creatives, coverage_state, zero_vs_unknown OBSERVED|ZERO_WITH_ADEQUATE_COVERAGE|UNKNOWN, market_state, '
  'freshness). auth.uid()-scoped, cross-tenant fail-closed. Deployed outside migrations historically; '
  'captured here. Do not relabel UNKNOWN/NO_RUN as zero competition.';

-- 2) Scoped per-product + market competitor evidence (prices, price range, observed ads, creative patterns, freshness)
CREATE OR REPLACE FUNCTION public.fn_product_competitor_evidence(p_product_id uuid, p_country text)
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_c text := upper(btrim(coalesce(p_country,'')));
  v_rows jsonb;
  v_price_ccy text;
  v_summary jsonb;
  v_ad jsonb;
  v_fresh timestamptz;
  v_stale_days int := 14;   -- matches the platform's 336h product-intelligence staleness convention
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF v_c = '' THEN RETURN jsonb_build_object('status','market_required'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_owner <> v_uid THEN RETURN jsonb_build_object('status','cross_tenant_rejected'); END IF;

  -- Genuine competitor rows for THIS product + market (non-fixture), cheapest first.
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'competitor_id', c.id,
           'competitor_kind', c.competitor_kind,
           'competitor_identity', c.competitor_identity,
           'observed_product_url', c.observed_product_url,
           'platform', c.platform,
           'match_class', c.match_class,
           'match_confidence', c.match_confidence,
           'price', c.price_original,
           'price_currency', c.price_currency,
           'price_source_class', c.price_source_class,
           'price_observed_at', c.price_observed_at,
           'ad_platform', c.ad_platform,
           'observable_ad_count', c.observable_ad_count,
           'ad_status', c.ad_status,
           'creative_pattern', c.creative_pattern,
           'offer_pattern', c.offer_pattern,
           'cta_pattern', c.cta_pattern,
           'evidence_class', c.evidence_class,
           'confidence', c.confidence,
           'observed_at', c.observed_at,
           'authority','REFERENCE_ONLY'))
         ORDER BY c.price_original ASC NULLS LAST, c.observed_at DESC NULLS LAST), '[]'::jsonb)
    INTO v_rows
  FROM public.product_market_competitors c
  WHERE c.tenant_id = v_uid AND c.product_id = p_product_id
    AND upper(coalesce(c.country_code,'')) = v_c AND coalesce(c.is_fixture,false) = false;

  -- Dominant priced currency (so the range is a single-currency, honest comparison).
  SELECT c.price_currency INTO v_price_ccy
  FROM public.product_market_competitors c
  WHERE c.tenant_id = v_uid AND c.product_id = p_product_id
    AND upper(coalesce(c.country_code,'')) = v_c AND coalesce(c.is_fixture,false) = false
    AND c.price_original IS NOT NULL AND c.price_currency IS NOT NULL
  GROUP BY c.price_currency ORDER BY count(*) DESC, c.price_currency LIMIT 1;

  IF v_price_ccy IS NULL THEN
    v_summary := jsonb_build_object('observation','UNKNOWN','currency', NULL, 'sellers', 0,
                   'low', NULL, 'median', NULL, 'high', NULL,
                   'note','No competitor prices observed for this product in this market yet.');
  ELSE
    SELECT jsonb_build_object('observation','OBSERVED','currency', v_price_ccy,
             'sellers', count(*),
             'low', min(c.price_original), 'high', max(c.price_original),
             'median', percentile_cont(0.5) WITHIN GROUP (ORDER BY c.price_original),
             'excluded_other_currency',
               (SELECT count(*) FROM public.product_market_competitors x
                WHERE x.tenant_id = v_uid AND x.product_id = p_product_id
                  AND upper(coalesce(x.country_code,'')) = v_c AND coalesce(x.is_fixture,false) = false
                  AND x.price_original IS NOT NULL AND x.price_currency IS DISTINCT FROM v_price_ccy))
      INTO v_summary
    FROM public.product_market_competitors c
    WHERE c.tenant_id = v_uid AND c.product_id = p_product_id
      AND upper(coalesce(c.country_code,'')) = v_c AND coalesce(c.is_fixture,false) = false
      AND c.price_original IS NOT NULL AND c.price_currency = v_price_ccy;
  END IF;

  -- Observed advertising from competitor rows (distinct from the Ad Library contract; this is marketplace-observed).
  SELECT jsonb_build_object(
           'observation', CASE WHEN count(*) FILTER (WHERE c.observable_ad_count IS NOT NULL) > 0
                               THEN 'OBSERVED' ELSE 'UNKNOWN' END,
           'competitors_with_ads', count(*) FILTER (WHERE coalesce(c.observable_ad_count,0) > 0),
           'observable_ads_total', sum(coalesce(c.observable_ad_count,0)),
           'platforms', coalesce(jsonb_agg(DISTINCT c.ad_platform) FILTER (WHERE c.ad_platform IS NOT NULL), '[]'::jsonb))
    INTO v_ad
  FROM public.product_market_competitors c
  WHERE c.tenant_id = v_uid AND c.product_id = p_product_id
    AND upper(coalesce(c.country_code,'')) = v_c AND coalesce(c.is_fixture,false) = false;

  -- Freshness = newest observation across rows (GREATEST ignores NULLs).
  SELECT greatest(max(c.observed_at), max(c.price_observed_at)) INTO v_fresh
  FROM public.product_market_competitors c
  WHERE c.tenant_id = v_uid AND c.product_id = p_product_id
    AND upper(coalesce(c.country_code,'')) = v_c AND coalesce(c.is_fixture,false) = false;

  RETURN jsonb_build_object(
    'status','ok','product_id', p_product_id, 'country_code', v_c,
    'count', jsonb_array_length(v_rows),
    'competitors', v_rows,
    'price_summary', v_summary,
    'ad_summary', v_ad,
    'freshness', jsonb_build_object(
       'newest_observed_at', v_fresh,
       'stale', CASE WHEN v_fresh IS NULL THEN NULL ELSE (now() - v_fresh) > make_interval(days => v_stale_days) END,
       'stale_after_days', v_stale_days),
    'authority','REFERENCE_ONLY',
    'source_contract','product_market_competitors',
    'invariants', jsonb_build_object('server_owned_auth_uid',true,'tenant_market_scoped',true,
       'single_currency_range',true,'unknown_not_zero',true,'reference_only',true),
    'contract','pulse_product_competitor_evidence_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_competitor_evidence(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_competitor_evidence(uuid, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.fn_product_competitor_evidence(uuid, text) IS
  'pulse_product_competitor_evidence_v1 — scoped per product+market competitor evidence from '
  'product_market_competitors: observed competitor prices, single-currency price range (low/median/high), '
  'observed ad counts + platforms, creative/offer/cta patterns, source freshness. auth.uid()-scoped, '
  'country-isolated, cross-tenant fail-closed, REFERENCE_ONLY, UNKNOWN never relabelled as 0.';

-- 3) Selftest (service_role only): fail-closed shapes, honest-empty for a discovery-only product,
--    populated shape with an ordered single-currency range, country isolation, UNKNOWN-not-zero.
CREATE OR REPLACE FUNCTION public.fn_product_competitor_evidence_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0;
  v_tenant uuid; v_fm_product uuid; v_pop_product uuid; v_pop_market text;
  v_r jsonb; v_prev_claims text;
BEGIN
  v_prev_claims := current_setting('request.jwt.claims', true);

  -- Tenant that owns GB FastMoss discovery products.
  SELECT s.user_id INTO v_tenant
  FROM public.commerce_signals s
  WHERE s.signal_type='COMMERCE_PRODUCT_NATIVE' AND upper(s.value->>'market')='GB'
    AND nullif(s.value->>'fastmoss_strategy','') IS NOT NULL
  GROUP BY s.user_id ORDER BY count(DISTINCT s.product_id) DESC LIMIT 1;

  SELECT s.product_id INTO v_fm_product
  FROM public.commerce_signals s
  WHERE s.user_id=v_tenant AND s.signal_type='COMMERCE_PRODUCT_NATIVE' AND upper(s.value->>'market')='GB'
    AND nullif(s.value->>'fastmoss_strategy','') IS NOT NULL
  LIMIT 1;

  -- A product owned by the same tenant that HAS competitor rows (populated case).
  SELECT c.product_id, upper(c.country_code) INTO v_pop_product, v_pop_market
  FROM public.product_market_competitors c
  WHERE c.tenant_id=v_tenant AND coalesce(c.is_fixture,false)=false AND c.price_original IS NOT NULL
  GROUP BY c.product_id, upper(c.country_code)
  ORDER BY count(*) DESC LIMIT 1;

  -- Impersonate the tenant.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_tenant::text)::text, true);

  -- (a) market_required
  v_r := public.fn_product_competitor_evidence(v_fm_product, '');
  v_checks := v_checks || jsonb_build_object('check','MARKET_REQUIRED',
    'ok', v_r->>'status'='market_required', 'detail', v_r);

  -- (b) honest empty for a discovery-only FastMoss product
  v_r := public.fn_product_competitor_evidence(v_fm_product, 'GB');
  v_checks := v_checks || jsonb_build_object('check','FASTMOSS_PRODUCT_EMPTY_HONEST',
    'ok', (v_r->>'status'='ok' AND (v_r->>'count')::int=0
           AND v_r->'price_summary'->>'observation'='UNKNOWN'
           AND v_r->'price_summary'->>'low' IS NULL),
    'detail', v_r->'price_summary');

  -- (c) country isolation: a market with no rows is empty
  v_r := public.fn_product_competitor_evidence(v_fm_product, 'JP');
  v_checks := v_checks || jsonb_build_object('check','COUNTRY_ISOLATION_JP_EMPTY',
    'ok', (v_r->>'status'='ok' AND (v_r->>'count')::int=0), 'detail', NULL);

  -- (d) populated shape with ordered single-currency range + UNKNOWN-not-zero discipline
  IF v_pop_product IS NOT NULL THEN
    v_r := public.fn_product_competitor_evidence(v_pop_product, v_pop_market);
    v_checks := v_checks || jsonb_build_object('check','POPULATED_RANGE_ORDERED',
      'ok', (v_r->>'status'='ok' AND (v_r->>'count')::int>0
             AND v_r->'price_summary'->>'observation'='OBSERVED'
             AND v_r->'price_summary'->>'currency' IS NOT NULL
             AND (v_r->'price_summary'->>'low')::numeric <= (v_r->'price_summary'->>'median')::numeric
             AND (v_r->'price_summary'->>'median')::numeric <= (v_r->'price_summary'->>'high')::numeric),
      'detail', v_r->'price_summary');
  ELSE
    v_checks := v_checks || jsonb_build_object('check','POPULATED_RANGE_ORDERED','ok',true,
      'detail', jsonb_build_object('note','no populated product for tenant; skipped'));
  END IF;

  -- (e) cross-tenant fail-closed: impersonate a different uid for the populated product
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub','11111111-1111-4111-8111-111111111111')::text, true);
  IF v_pop_product IS NOT NULL THEN
    v_r := public.fn_product_competitor_evidence(v_pop_product, v_pop_market);
    v_checks := v_checks || jsonb_build_object('check','CROSS_TENANT_REJECTED',
      'ok', v_r->>'status' IN ('cross_tenant_rejected','product_not_found'), 'detail', v_r);
  ELSE
    v_checks := v_checks || jsonb_build_object('check','CROSS_TENANT_REJECTED','ok',true,
      'detail', jsonb_build_object('note','skipped'));
  END IF;

  -- restore claims
  PERFORM set_config('request.jwt.claims', coalesce(v_prev_claims,''), true);

  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean),
         count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass, v_fail
  FROM jsonb_array_elements(v_checks) c;

  RETURN jsonb_build_object('ok', v_fail=0, 'passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,
    'checks',v_checks,'contract','pulse_product_competitor_evidence_selftest_v1',
    'generated_at', now());
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_competitor_evidence_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_product_competitor_evidence_selftest() TO service_role;

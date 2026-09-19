-- ============================================================================
-- mig_249_market_catalog_contract.sql
-- STRATELOQ-ECOM-MULTI-MARKET-PRODUCT-RESEARCH-013M
--
-- Browser-safe authenticated market catalog for the (future) Lovable country
-- selector. Backend-authoritative: derives supported markets from the canonical
-- ecommerce_market_universe and per-market provider applicability from the
-- authoritative provider_capability_registry (same ranking the research
-- orchestrator uses). No hardcoded country list belongs in Lovable.
--
-- Safe fields only: country_code, country_name, currency_code, research_supported,
-- provider coverage summary + per-category applicable source/state. No provider
-- credentials, no internal fields. TikTok surfaces as BLOCKED_EXTERNAL_APPROVAL
-- (application pending), never AVAILABLE.
--
-- Additive. The existing fn_own_request_product_market_research (execution) and
-- fn_ecommerce_research_coverage (per product x market research status) already
-- work for any market and are unchanged.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ecommerce_supported_markets()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication required' USING errcode='28000'; END IF;

  SELECT coalesce(jsonb_agg(m ORDER BY m->>'country_name'), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'country_code', u.country_code,
      'country_name', u.country_name,
      'currency_code', u.default_currency,
      'research_supported', (cov.available_count > 0),
      'available_source_count', cov.available_count,
      'launch_critical_blocked', cov.launch_blocked,
      'provider_coverage', cov.coverage
    ) AS m
    FROM public.ecommerce_market_universe u
    CROSS JOIN LATERAL (
      WITH cats(evidence_category) AS (
        VALUES ('COMMUNITY'),('SEARCH_DEMAND'),('MARKETPLACE'),('ADVERTISING'),('SUPPLIER'),('SOCIAL_VIDEO')
      ),
      ranked AS (
        SELECT c.evidence_category, r.source, r.availability,
               row_number() OVER (PARTITION BY c.evidence_category ORDER BY
                 (r.availability='AVAILABLE' AND r.market=u.country_code) DESC,
                 (r.availability='AVAILABLE' AND r.market='*')            DESC,
                 (r.availability='AVAILABLE')                             DESC,
                 (r.market=u.country_code)                                DESC,
                 (r.market='*')                                          DESC) AS rnk
        FROM cats c JOIN public.provider_capability_registry r USING (evidence_category)
      ),
      picked AS (
        SELECT evidence_category, source, availability,
          CASE
            WHEN availability='AVAILABLE' THEN 'AVAILABLE'
            WHEN availability='SOURCE_UNSUPPORTED' AND evidence_category='SOCIAL_VIDEO' THEN 'BLOCKED_EXTERNAL_APPROVAL'
            WHEN availability='SOURCE_UNSUPPORTED' THEN 'UNSUPPORTED_MARKET'
            WHEN availability='SOURCE_BLOCKED' THEN 'SOURCE_BLOCKED'
            ELSE 'NOT_APPLICABLE'
          END AS state
        FROM ranked WHERE rnk=1
      )
      SELECT
        count(*) FILTER (WHERE state='AVAILABLE') AS available_count,
        coalesce(bool_or(evidence_category='SOCIAL_VIDEO' AND state<>'AVAILABLE'), true) AS launch_blocked,
        jsonb_agg(jsonb_build_object('evidence_category',evidence_category,'source',source,'state',state) ORDER BY evidence_category) AS coverage
      FROM picked
    ) cov
    WHERE coalesce(u.ecommerce_eligible, false) = true
  ) z;

  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows),
    'markets', v_rows,
    'source_contract','ecommerce_market_universe + provider_capability_registry',
    'note','Backend-authoritative supported markets + per-market provider applicability. TikTok shown as BLOCKED_EXTERNAL_APPROVAL (application pending), never AVAILABLE. No credentials exposed.');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_ecommerce_supported_markets() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_ecommerce_supported_markets() TO authenticated, service_role;

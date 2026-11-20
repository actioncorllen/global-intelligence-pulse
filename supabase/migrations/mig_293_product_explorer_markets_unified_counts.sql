-- mig_293 (2026-11-20, two production migrations combined for the repo record):
--   product_explorer_markets_kalodata_counts + product_explorer_markets_display_gate
-- DEFECT: fn_product_explorer_markets counted only FastMoss-era COMMERCE_PRODUCT_NATIVE
-- signals (fastmoss_strategy present), so markets whose discovery products came from
-- Kalodata (e.g. US) returned products=0 / has_data=false and the workspace market
-- selector showed "no data yet" while fn_product_explorer listed 10 US products.
-- FIX: count the explorer's exact population — same base predicate (fastmoss_strategy OR
-- source='kalodata', market-tagged, non-hidden) AND the same customer display-image gate —
-- so the dropdown count equals the explorer ALL facet in every market
-- (verified live: US 10=10, GB 28=28, DE 9=9).
CREATE OR REPLACE FUNCTION public.fn_product_explorer_markets()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthorized','markets','[]'::jsonb); END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'market',   u.country_code,
            'currency', u.default_currency,
            'products', coalesce(c.n,0),
            'has_data', (coalesce(c.n,0) > 0))
          ORDER BY coalesce(c.n,0) DESC, u.country_code), '[]'::jsonb) INTO v
  FROM public.ecommerce_market_universe u
  LEFT JOIN (
    SELECT q.mkt, count(*) AS n FROM (
      SELECT upper(s.value->>'market') AS mkt, s.product_id
        FROM public.commerce_signals s
       WHERE s.user_id = v_uid AND s.signal_type='COMMERCE_PRODUCT_NATIVE'
         AND nullif(s.value->>'market','') IS NOT NULL
         AND (nullif(s.value->>'fastmoss_strategy','') IS NOT NULL
              OR lower(coalesce(s.value->>'source','')) = 'kalodata')
         AND NOT public.fn_discovery_product_hidden(v_uid, s.product_id)
       GROUP BY 1, 2
    ) q
    WHERE EXISTS (SELECT 1 FROM public.product_image_assets i
            WHERE i.product_id=q.product_id AND i.tenant_id=v_uid AND (i.market IS NULL OR i.market=q.mkt)
              AND i.rights_state IN ('SUPPLIER_PROVIDED','PROVIDER_DISCOVERY_REFERENCE')
              AND coalesce(upper(i.availability),'AVAILABLE') <> 'UNAVAILABLE'
              AND (i.image_url ILIKE 'http%'
                   OR (i.cache_state='CACHED' AND i.storage_ref IS NOT NULL AND i.storage_ref !~* '^https?://')))
    GROUP BY q.mkt
  ) c ON c.mkt = u.country_code
  WHERE coalesce(u.ecommerce_eligible,true) = true;
  RETURN jsonb_build_object('status','ok','markets',v,'contract','pulse_product_explorer_markets_v3_discovery_sources');
END; $function$

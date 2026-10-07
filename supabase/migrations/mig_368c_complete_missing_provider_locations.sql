-- mig_368c — Complete provider location codes for ecommerce-eligible APAC markets
--
-- ROOT CAUSE (config-completeness gap, surfaced by the mig_368b regression's
-- no_eligible_market_missing_provider_config check): HK, MY, PH and SG were marked
-- ecommerce_eligible with search intelligence AVAILABLE, but had no
-- dataforseo_location_code. Any discovery run for those markets would have failed
-- the resolver's NO_PROVIDER_LOCATION gate — an eligible market that production
-- could not actually serve.
--
-- FIX: populate the authoritative DataForSEO location codes (2000 + ISO-3166
-- numeric) for exactly those four markets, only where currently NULL. With
-- mig_368a's languages (all four -> en) this closes the config gap so every
-- eligible+available market resolves a complete provider config.
--
-- Idempotent: only sets codes where NULL for the four named markets.

UPDATE public.ecommerce_market_universe
   SET dataforseo_location_code = CASE upper(country_code)
         WHEN 'HK' THEN 2344
         WHEN 'MY' THEN 2458
         WHEN 'PH' THEN 2608
         WHEN 'SG' THEN 2702
       END
 WHERE upper(country_code) IN ('HK','MY','PH','SG')
   AND dataforseo_location_code IS NULL;

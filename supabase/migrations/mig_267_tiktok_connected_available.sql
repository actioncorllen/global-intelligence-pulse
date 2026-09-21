-- ============================================================================
-- mig_267_tiktok_connected_available.sql
-- STRATELOQ-TIKTOK-FINAL-DATE-BOUNDARY-014F.10
--
-- TikTok Commercial Content connectivity is now PROVEN by a real, authenticated,
-- bounded live request (the earned flip deferred in mig_261 / mig_259 is now due):
--
--   * Token: minted server-side via the tiktok-commercial-token Edge Function broker
--     (HTTP 200, Bearer, expires_in 7200). Secrets live ONLY as Edge Function secrets.
--   * Ad Query: POST https://open.tiktokapis.com/v2/research/adlib/ad/query/
--     returned HTTP 200, error.code "ok", 10 real ads (search "kids nightlight
--     projector", country GB, ad_published_date_range 20260622..20260920, max_count 20).
--   * Canonical relevance layer (fn_ingest_tiktok_commercial_content -> fn_meta_ad_relevance)
--     classified all 10 ads NO_MATCH (generic "Shopify (USA) Inc." advertiser ads,
--     not the researched product) -> advertising_activity_state NO_PRODUCT_MATCH ->
--     attempt_state SEARCHED_NO_EVIDENCE, ingested_signals 0.
--
-- Connectivity is therefore proven while NO product-relevant evidence exists yet:
-- this is the "SUCCESS WITH ZERO RELEVANT ADS" outcome. No signal is fabricated.
--
-- This migration performs ONLY the canonical provider transition on the
-- provider_capability_registry row for (TIKTOK, SOCIAL_VIDEO):
--   availability : SOURCE_UNSUPPORTED  ->  AVAILABLE
-- and truthfully records the live verification metadata. It does NOT:
--   * insert any commerce_signals (0 product-relevant ads -> 0 evidence),
--   * change any WPS score / coverage / product decision (nightlight GB stays
--     68.2 / 0.78 / WATCH / TRENDING_WATCH — PME is untouched),
--   * store any credential value (secrets remain only in the Edge Function store),
--   * alter any other provider row.
--
-- No WPS scoring change, no synthetic evidence, no Lovable change, no publish.
-- ============================================================================
UPDATE public.provider_capability_registry
SET
  availability = 'AVAILABLE',
  capability = jsonb_build_object(
    'commercial_content_api', jsonb_build_object(
      'client_status', 'CONNECTED',
      'approved_scope', 'research.adlib.basic',
      'scope_description', 'Access to public commercial data for research purposes',
      'credentials_location', 'supabase_edge_function_secrets',
      'credentials_installed', true,
      'runtime_executor_implemented', true,
      'ingestion_contract_implemented', true,
      'token_mechanism', 'server_side_edge_function_broker(tiktok-commercial-token)',
      'live_verification', jsonb_build_object(
        'verified', true,
        'token_http_status', 200,
        'ad_query_http_status', 200,
        'ad_query_error_code', 'ok',
        'ads_returned', 10,
        'product_relevant_matches', 0,
        'attempt_state', 'SEARCHED_NO_EVIDENCE',
        'search_term', 'kids nightlight projector',
        'country_code', 'GB',
        'ad_published_date_range', '20260622..20260920',
        'note', 'connectivity proven; returned ads were generic advertiser ads with no product match -> no evidence, no fabrication'
      )
    ),
    'project_state', 'CONNECTED_RUNTIME_AVAILABLE'
  ),
  limitations = 'CONNECTED_RUNTIME_AVAILABLE: TikTok Commercial Content API live-verified via a real authenticated bounded request (token broker -> research/adlib/ad/query HTTP 200, 10 ads). Provider is now AVAILABLE and dispatchable. The bounded GB "kids nightlight projector" verification returned only generic (non-product-relevant) advertiser ads -> SEARCHED_NO_EVIDENCE (0 signals ingested; NO fabrication). Product-relevant SOCIAL_VIDEO evidence is recorded only when real matching ads are returned by a future search. Credentials live solely as Supabase Edge Function secrets; no credential value in the DB.',
  last_verified_at = now(),
  updated_at = now()
WHERE source = 'TIKTOK' AND evidence_category = 'SOCIAL_VIDEO';

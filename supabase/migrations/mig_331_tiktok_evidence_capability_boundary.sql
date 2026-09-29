-- ============================================================================
-- mig_331_tiktok_evidence_capability_boundary.sql
-- STRATELOQ-TIKTOK-REAL-PRODUCT-EVIDENCE-CONNECTION
--
-- Records the HONEST TikTok evidence capability boundary on the canonical
-- provider_capability_registry row (TIKTOK, SOCIAL_VIDEO), after a real,
-- authenticated, bounded live re-verification on 2026-09-29:
--   * Token: tiktok-commercial-token Edge Function broker -> HTTP 200, Bearer,
--     expires_in 7200 (secrets live ONLY as Edge Function secrets).
--   * Ad Query: POST https://open.tiktokapis.com/v2/research/adlib/ad/query/
--     -> HTTP 200, error.code "ok", 10 real ads (search "kids nightlight
--     projector", country GB) returning ONLY:
--       ad.id, ad.first_shown_date, ad.last_shown_date, advertiser.business_name.
--   * Ingest: fn_research_ingest_source(TIKTOK) -> all 10 NO_MATCH (generic
--     "Shopify (USA) Inc." advertiser aggregator ads) -> NO_PRODUCT_MATCH ->
--     SEARCHED_NO_EVIDENCE -> 0 signals ingested. NO fabrication.
--
-- THE CAPABILITY TRUTH THIS MIGRATION MAKES EXPLICIT:
--   The connected TikTok surface is the COMMERCIAL CONTENT AD LIBRARY only
--   (scope research.adlib.basic) -> ADVERTISER-PRESENCE / creative-flight
--   evidence (advertiser business name + first/last shown dates). It does NOT
--   expose organic engagement (views/likes/comments/shares/saves), engagement
--   or view velocity, buyer-intent comments, creator/account info, per-market
--   organic geo attribution, or keyword/hashtag trend discovery. Those belong
--   to a DIFFERENT TikTok developer product -- the TikTok Research API
--   (research.data.*) -- which requires a SEPARATE developer application and
--   approval and is therefore EXTERNAL_APPROVAL_REQUIRED here.
--
-- This migration ONLY refreshes capability metadata + last_verified_at on the
-- one registry row. It does NOT:
--   * change availability (stays AVAILABLE -- the ad-library surface is really
--     usable), nor imply organic engagement is connected;
--   * insert any commerce_signals (0 product-relevant ads -> 0 evidence);
--   * change any WPS score / coverage / product decision / country isolation;
--   * store any credential value (secrets remain only in Edge Function store);
--   * touch Product Identity, Commercial Asset Rights, Product Asset Lock, RLS,
--     or any other provider row.
-- ============================================================================
UPDATE public.provider_capability_registry
SET
  capability = jsonb_build_object(
    'project_state', 'CONNECTED_RUNTIME_AVAILABLE',
    -- Surface 1: the ONLY connected TikTok surface today.
    'commercial_content_adlib', jsonb_build_object(
      'source_state', 'CONNECTED_AND_INGESTING_REAL_DATA',
      'client_status', 'CONNECTED',
      'approved_scope', 'research.adlib.basic',
      'scope_description', 'Access to public commercial (advertising) data for research purposes',
      'credentials_location', 'supabase_edge_function_secrets',
      'token_mechanism', 'server_side_edge_function_broker(tiktok-commercial-token)',
      'endpoint', 'POST https://open.tiktokapis.com/v2/research/adlib/ad/query/',
      'evidence_family', jsonb_build_array('ADVERTISING_VALIDATION','CREATIVE_PATTERN'),
      'fields_actually_returned', jsonb_build_array(
        'ad.id','ad.first_shown_date','ad.last_shown_date','advertiser.business_name'),
      'capability_kind', 'VALIDATION_AND_DISCOVERY_OF_ADVERTISED_PRODUCTS',
      'geo_attribution', 'QUERY_SCOPED_COUNTRY (country_code_list filter) -> the observation is scoped to the country queried; never relabelled as another market',
      'live_reverification', jsonb_build_object(
        'verified_at', '2026-09-29',
        'token_http_status', 200,
        'ad_query_http_status', 200,
        'ad_query_error_code', 'ok',
        'ads_returned', 10,
        'product_relevant_matches', 0,
        'attempt_state', 'SEARCHED_NO_EVIDENCE',
        'signals_ingested', 0,
        'search_term', 'kids nightlight projector',
        'country_code', 'GB',
        'note', 'connectivity re-proven live today; returned ads were generic advertiser-aggregator ads with no product match -> no evidence, no fabrication')
    ),
    -- Surface 2: the deep organic evidence the product-intelligence engine wants
    -- -- NOT connected; a distinct developer product requiring separate approval.
    'organic_research_api', jsonb_build_object(
      'source_state', 'EXTERNAL_APPROVAL_REQUIRED',
      'developer_product', 'TikTok Research API',
      'required_scopes', jsonb_build_array('research.data.basic'),
      'endpoints_needed', jsonb_build_array(
        'POST /v2/research/video/query/','POST /v2/research/video/comment/list/','POST /v2/research/user/info/'),
      'would_enable', jsonb_build_object(
        'engagement_metrics', jsonb_build_array('view_count','like_count','comment_count','share_count'),
        'buyer_intent', 'comment access (research/video/comment/list) -> reuse existing buyer-intent classifier',
        'velocity', 'derivable ONLY from >=2 timestamped observations of the same video (never from one snapshot)',
        'creator_info', 'research/user/info',
        'geo', 'video.region_code (creator/upload region; NOT necessarily audience-market)',
        'discovery', 'keyword/hashtag video.query filters -> emerging-product discovery'),
      'likely_unsupported_even_after_approval', jsonb_build_array(
        'saves/favourites','watch/completion rate','repeat views','audience-market (viewer-country) attribution'),
      'note', 'Research API is a separate TikTok developer application + approval, gated on eligibility review; exact field availability must be confirmed against live docs during the build unit. No scraping substitute is permitted.')
  ),
  limitations = 'CONNECTED (AD LIBRARY ONLY): TikTok Commercial Content Ad Library (research.adlib.basic) is live-connected and dispatchable (re-verified 2026-09-29: token 200, adlib 200, 10 ads, SEARCHED_NO_EVIDENCE, 0 signals -- no fabrication). It yields ADVERTISER-PRESENCE evidence only (advertiser business name + ad flight dates), suitable for advertising-validation / creative-pattern signals. It does NOT provide organic engagement (views/likes/comments/shares/saves), engagement/view velocity, buyer-intent comments, creator info, audience-market geo, or keyword/hashtag trend discovery -- those require the separate TikTok Research API (research.data.*), which is EXTERNAL_APPROVAL_REQUIRED. Credentials live solely as Edge Function secrets; no credential value in the DB. Ad-library country filter scopes each observation to the queried country and is never relabelled as another market (country isolation preserved).',
  last_verified_at = now(),
  updated_at = now()
WHERE source = 'TIKTOK' AND evidence_category = 'SOCIAL_VIDEO';

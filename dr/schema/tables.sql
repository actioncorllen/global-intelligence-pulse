-- STRATELOQ DR: production public table DDL (schema baseline; columns+defaults+identity+generated). NO data, NO secrets.

CREATE TABLE IF NOT EXISTS public.activation_authorizations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  platform text NOT NULL,
  ad_account text,
  campaign_id uuid NOT NULL,
  authority_id uuid,
  token_hash text NOT NULL,
  bound_campaign_fp text,
  bound_authority_fp text,
  bound_budget_minor numeric,
  bound_currency text,
  bound_market text,
  status text DEFAULT 'ISSUED'::text NOT NULL,
  single_use boolean DEFAULT true NOT NULL,
  expires_at timestamp with time zone NOT NULL,
  idempotency_key text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.ad_studio_angles (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  brief_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  angle_index integer NOT NULL,
  angle_name text NOT NULL,
  angle_type text,
  customer_problem text,
  desired_outcome text,
  evidence_basis jsonb DEFAULT '{}'::jsonb NOT NULL,
  evidence_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
  audience_segment jsonb DEFAULT '{}'::jsonb NOT NULL,
  hook text,
  headline text,
  primary_copy text,
  supporting_copy text,
  cta text,
  visual_concept text,
  static_creative_brief text,
  video_hook text,
  video_script text,
  storyboard jsonb DEFAULT '[]'::jsonb NOT NULL,
  platform_notes jsonb DEFAULT '{}'::jsonb NOT NULL,
  claim_risk text DEFAULT 'UNKNOWN'::text NOT NULL,
  claim_violations jsonb DEFAULT '[]'::jsonb NOT NULL,
  review_state text DEFAULT 'DRAFT'::text NOT NULL,
  content_fingerprint text,
  approved_fingerprint text,
  approved_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.ad_studio_assets (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  brief_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  source_type text NOT NULL,
  asset_ref text,
  rights_state text DEFAULT 'UNKNOWN'::text NOT NULL,
  is_competitor_source boolean DEFAULT false NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.ad_studio_briefs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  business_id uuid,
  product_id uuid,
  opportunity_id uuid,
  decision_id uuid,
  evidence_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
  supplier_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
  market text,
  market_currency text,
  campaign_target_market text,
  product_name text,
  product_description text,
  product_features jsonb DEFAULT '[]'::jsonb NOT NULL,
  problem_solved text,
  audience jsonb DEFAULT '{}'::jsonb NOT NULL,
  buyer_intent jsonb DEFAULT '{}'::jsonb NOT NULL,
  keyword_intelligence jsonb DEFAULT '{}'::jsonb NOT NULL,
  competitor_intelligence jsonb DEFAULT '{}'::jsonb NOT NULL,
  advertising_evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
  market_price jsonb DEFAULT '{}'::jsonb NOT NULL,
  offer jsonb DEFAULT '{}'::jsonb NOT NULL,
  product_assets jsonb DEFAULT '[]'::jsonb NOT NULL,
  destination_url text,
  platform_targets jsonb DEFAULT '["META", "TIKTOK"]'::jsonb NOT NULL,
  evidence_completeness jsonb DEFAULT '{}'::jsonb NOT NULL,
  is_fixture boolean DEFAULT false NOT NULL,
  status text DEFAULT 'DRAFT'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.ad_studio_offers (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  brief_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  element text NOT NULL,
  value jsonb DEFAULT '{}'::jsonb NOT NULL,
  tier text NOT NULL,
  evidence_state text DEFAULT 'UNKNOWN'::text NOT NULL,
  note text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.ad_studio_platform_variants (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  angle_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  platform text NOT NULL,
  placement text,
  hook text,
  copy_structure jsonb DEFAULT '{}'::jsonb NOT NULL,
  primary_copy text,
  cta text,
  aspect_ratio text,
  visual_composition text,
  script_pacing text,
  opening_seconds text,
  caption_approach text,
  claim_violations jsonb DEFAULT '[]'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.ad_studio_static_creatives (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  angle_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  platform text NOT NULL,
  product_asset_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
  headline text,
  supporting_text text,
  cta text,
  visual_hierarchy jsonb DEFAULT '[]'::jsonb NOT NULL,
  layout text,
  aspect_ratio text,
  safe_area text,
  brand_context jsonb DEFAULT '{}'::jsonb NOT NULL,
  generation_provider text,
  generation_status text DEFAULT 'PENDING'::text NOT NULL,
  asset_url text,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.analytics_events (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  event_type text NOT NULL,
  opportunity_id uuid,
  platform text,
  score_at_time numeric,
  outcome text,
  metadata jsonb DEFAULT '{}'::jsonb,
  occurred_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.auth_event (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  member_id uuid NOT NULL,
  event_type text NOT NULL,
  occurred_at timestamp with time zone DEFAULT now() NOT NULL,
  metadata jsonb
);

CREATE TABLE IF NOT EXISTS public.build_updates (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  summary text,
  body text,
  release_version text,
  category text,
  published boolean DEFAULT false NOT NULL,
  published_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.business_profiles (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  application_id uuid NOT NULL,
  user_id uuid,
  business_name text,
  website text,
  country text,
  industry text,
  business_type text,
  company_size text,
  target_audience text,
  primary_goal text,
  preferred_platforms jsonb DEFAULT '[]'::jsonb,
  competitors jsonb DEFAULT '[]'::jsonb,
  ai_experience_level text,
  brief_frequency text DEFAULT 'daily'::text,
  brand_voice text,
  business_summary text,
  positioning_summary text,
  opportunity_preferences jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.campaign_builder_drafts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  brief_id uuid,
  product_id uuid,
  opportunity_id uuid,
  decision_id uuid,
  platform text DEFAULT 'META'::text NOT NULL,
  objective text,
  business_home_market text,
  selling_market text,
  opportunity_market text,
  campaign_target_market text,
  market_currency text,
  audience jsonb DEFAULT '{}'::jsonb NOT NULL,
  placements jsonb DEFAULT '[]'::jsonb NOT NULL,
  creative_selection jsonb DEFAULT '[]'::jsonb NOT NULL,
  offer jsonb DEFAULT '[]'::jsonb NOT NULL,
  destination_url text,
  destination_state text DEFAULT 'UNKNOWN'::text NOT NULL,
  budget jsonb DEFAULT '{}'::jsonb NOT NULL,
  schedule jsonb DEFAULT '{}'::jsonb NOT NULL,
  currency_display text,
  currency_market text,
  currency_execution text,
  fx_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
  optimization_intent text,
  tracking_state text DEFAULT 'NOT_CONFIGURED'::text NOT NULL,
  media_asset_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
  media_gate jsonb DEFAULT '{}'::jsonb NOT NULL,
  canonical_campaign jsonb DEFAULT '{}'::jsonb NOT NULL,
  meta_payload_preview jsonb DEFAULT '{}'::jsonb NOT NULL,
  tiktok_preview jsonb DEFAULT '{}'::jsonb NOT NULL,
  completeness jsonb DEFAULT '{}'::jsonb NOT NULL,
  non_executable_fixture boolean DEFAULT false NOT NULL,
  status text DEFAULT 'DRAFT'::text NOT NULL,
  cb_fingerprint text,
  cb_approved_fingerprint text,
  cb_approved_at timestamp with time zone,
  spend_authorization numeric DEFAULT 0 NOT NULL,
  activation_authorization boolean DEFAULT false NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.campaign_performance_snapshots (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  campaign_execution_id uuid,
  campaign_draft_id uuid,
  platform text DEFAULT 'META'::text NOT NULL,
  level text DEFAULT 'CAMPAIGN'::text NOT NULL,
  platform_campaign_id text,
  platform_object_id text,
  spend numeric,
  impressions bigint,
  reach bigint,
  frequency numeric,
  clicks bigint,
  link_clicks bigint,
  landing_page_views bigint,
  add_to_cart bigint,
  initiate_checkout bigint,
  purchases bigint,
  revenue numeric,
  spend_currency text,
  revenue_currency text,
  source_class text DEFAULT 'UNKNOWN'::text NOT NULL,
  is_fixture boolean DEFAULT false NOT NULL,
  purchase_source_verified boolean DEFAULT false NOT NULL,
  window_start timestamp with time zone,
  window_end timestamp with time zone,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.cj_sourcing_requests (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  provider text DEFAULT 'CJ'::text NOT NULL,
  source_id text,
  product_concept text NOT NULL,
  target_market text NOT NULL,
  specification jsonb NOT NULL,
  economic_ceiling_eur numeric,
  status text DEFAULT 'SUBMITTED'::text NOT NULL,
  provider_status text,
  founder_authorization text,
  requested_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  provenance jsonb
);

CREATE TABLE IF NOT EXISTS public.commerce_destination_choice (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  destination text NOT NULL,
  store_connection_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.commerce_events (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  event_id text NOT NULL,
  tenant_id uuid NOT NULL,
  business_id uuid,
  campaign_id uuid,
  campaign_execution_id uuid,
  creative_id uuid,
  product_id uuid,
  opportunity_id uuid,
  decision_id uuid,
  pulse_tid text,
  event_name text NOT NULL,
  event_time timestamp with time zone DEFAULT now() NOT NULL,
  event_source text DEFAULT 'BROWSER'::text NOT NULL,
  page_url text,
  destination_id text,
  market text,
  currency text,
  value numeric,
  order_id text,
  session_id text,
  anon_id text,
  click_ids jsonb DEFAULT '{}'::jsonb NOT NULL,
  source_platform text,
  source_adapter text,
  attribution jsonb DEFAULT '{}'::jsonb NOT NULL,
  attribution_class text,
  raw_provider_ref text,
  original_amount numeric,
  original_currency text,
  converted_amount numeric,
  display_currency text,
  fx_rate numeric,
  fx_rate_source text,
  fx_rate_timestamp timestamp with time zone,
  is_test_fixture boolean DEFAULT false NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.commerce_prediction_snapshots (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  product_id uuid NOT NULL,
  target_market text NOT NULL,
  snapshot_version text DEFAULT 'wps_v2'::text NOT NULL,
  evidence_version text NOT NULL,
  evaluated_at timestamp with time zone DEFAULT now() NOT NULL,
  opportunity_score integer,
  market_advantage_score integer,
  customer_experience_score integer,
  evidence_confidence integer,
  classification text NOT NULL,
  recommendation text,
  market_timing text,
  break_even_cpa numeric,
  economics_state text,
  supply_confidence text,
  product_trust_gate text,
  cx_gate text,
  risks jsonb DEFAULT '[]'::jsonb NOT NULL,
  unknowns jsonb DEFAULT '[]'::jsonb NOT NULL,
  blocked_sources jsonb DEFAULT '[]'::jsonb NOT NULL,
  decision jsonb NOT NULL,
  provenance jsonb NOT NULL,
  visibility text DEFAULT 'TENANT_PRIVATE'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.commerce_product_opportunities (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  product_id uuid NOT NULL,
  source_run_id uuid,
  member_opportunity_id uuid,
  overall_score integer,
  confidence numeric,
  opportunity_class text NOT NULL,
  factor_scores jsonb DEFAULT '{}'::jsonb NOT NULL,
  positive_factors jsonb DEFAULT '[]'::jsonb NOT NULL,
  risk_factors jsonb DEFAULT '[]'::jsonb NOT NULL,
  evidence_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
  signal_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
  why_this_product text,
  why_now text,
  recommended_decision text,
  recommended_actions jsonb DEFAULT '[]'::jsonb NOT NULL,
  content_context jsonb,
  provenance jsonb NOT NULL,
  rank integer,
  scoring_version text NOT NULL,
  last_evidence_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  target_market text
);

CREATE TABLE IF NOT EXISTS public.commerce_product_pages (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  product_id uuid,
  market text NOT NULL,
  destination text,
  store_connection_id uuid,
  decision_classification text,
  page_model jsonb NOT NULL,
  status text DEFAULT 'DRAFT'::text NOT NULL,
  published_url text,
  claim_safety jsonb DEFAULT '{}'::jsonb NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  source_kind text DEFAULT 'REAL'::text NOT NULL,
  product_ref jsonb DEFAULT '{}'::jsonb NOT NULL,
  selling_price numeric,
  display_currency text,
  source_currency text,
  landed_cost_display numeric,
  economics_state text,
  country_code text,
  opportunity_decision_id uuid,
  template_family text,
  template_version text,
  ad_match_ref jsonb,
  supplier_asset_refs jsonb,
  generation_state text DEFAULT 'GENERATED'::text,
  review_state text DEFAULT 'DRAFT'::text,
  publication_state text DEFAULT 'UNPUBLISHED'::text,
  runtime_contract jsonb
);

CREATE TABLE IF NOT EXISTS public.commerce_products (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  source_run_id uuid,
  product_identity text NOT NULL,
  identity_basis text NOT NULL,
  title text,
  product_url text,
  source_store text,
  category text,
  description text,
  observed_price numeric,
  price_currency text,
  availability text,
  provenance jsonb NOT NULL,
  extended jsonb,
  first_observed_at timestamp with time zone DEFAULT now() NOT NULL,
  last_observed_at timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  product_role text DEFAULT 'own'::text NOT NULL,
  competitor_source text,
  visibility text DEFAULT 'TENANT_PRIVATE'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS public.commerce_signals (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  product_id uuid,
  source_run_id uuid,
  signal_type text NOT NULL,
  value jsonb,
  evidence jsonb DEFAULT '[]'::jsonb NOT NULL,
  provenance jsonb NOT NULL,
  confidence numeric,
  observed_at timestamp with time zone DEFAULT now() NOT NULL,
  source_event_at timestamp with time zone,
  dedup_key text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  visibility text DEFAULT 'TENANT_PRIVATE'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS public.commerce_store_connections (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  provider text NOT NULL,
  store_domain text,
  store_identifier text,
  connection_state text DEFAULT 'NOT_CONNECTED'::text NOT NULL,
  granted_scopes jsonb DEFAULT '[]'::jsonb NOT NULL,
  provider_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
  oauth_state text,
  secret_ref text,
  connected_at timestamp with time zone,
  last_sync_at timestamp with time zone,
  error_detail text,
  visibility text DEFAULT 'TENANT_PRIVATE'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.commerce_store_projects (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  product_page_id uuid,
  project_state text DEFAULT 'DRAFT'::text NOT NULL,
  slug text,
  public_route text,
  settings jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  source_kind text DEFAULT 'REAL'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS public.commerce_supplier_products (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  source text DEFAULT 'cjdropshipping'::text NOT NULL,
  source_product_id text NOT NULL,
  sku text,
  title text,
  title_original text,
  image_url text,
  category text,
  supplier_cost numeric,
  cost_currency text DEFAULT 'USD'::text,
  weight_grams numeric,
  is_free_shipping boolean,
  shipping_country_codes jsonb DEFAULT '[]'::jsonb,
  listing_count integer,
  listed_num integer,
  sale_status text,
  supplier_id text,
  supplier_name text,
  product_url text,
  source_created_at timestamp with time zone,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  raw jsonb,
  first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
  last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  supplier_enrichment jsonb,
  enrichment_observed_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.commerce_tracking_identities (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  pulse_tid text NOT NULL,
  campaign_id uuid,
  creative_id uuid,
  product_id uuid,
  opportunity_id uuid,
  decision_id uuid,
  destination_url text,
  decorated_url text,
  utm jsonb DEFAULT '{}'::jsonb NOT NULL,
  identity jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.communication_logs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  application_id uuid,
  user_id uuid,
  channel text NOT NULL,
  subject text,
  message text,
  status text DEFAULT 'sent'::text,
  sent_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.competitor_content (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  competitor_id uuid,
  title text NOT NULL,
  url text,
  views integer DEFAULT 0,
  likes integer DEFAULT 0,
  published_at timestamp with time zone,
  topic_cluster text,
  hook text,
  detected_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.competitors (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  name text NOT NULL,
  platform text NOT NULL,
  channel_url text NOT NULL,
  channel_id text,
  subscriber_count integer,
  last_checked timestamp with time zone,
  active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  last_post_at timestamp with time zone,
  days_since_post integer DEFAULT 0,
  gap_topics jsonb DEFAULT '[]'::jsonb,
  avg_views integer DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.conversion_dispatch_ledger (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  provider text DEFAULT 'META'::text NOT NULL,
  event_id text NOT NULL,
  commerce_event_uuid uuid,
  event_name text NOT NULL,
  order_id text,
  state text DEFAULT 'RECEIVED'::text NOT NULL,
  consent_state text DEFAULT 'UNKNOWN'::text NOT NULL,
  attempt_count integer DEFAULT 0 NOT NULL,
  max_attempts integer DEFAULT 5 NOT NULL,
  last_attempt_at timestamp with time zone,
  provider_ref text,
  provider_response jsonb DEFAULT '{}'::jsonb NOT NULL,
  event_fingerprint text,
  error_class text,
  is_test boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.conversion_hero_variants (
  variant text NOT NULL,
  media_kind text NOT NULL,
  required_evidence text[] DEFAULT '{}'::text[] NOT NULL,
  description text,
  version text DEFAULT 'v1'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS public.conversion_section_types (
  section_type text NOT NULL,
  default_conversion_role text NOT NULL,
  required_evidence text[] DEFAULT '{}'::text[] NOT NULL,
  structural boolean DEFAULT false NOT NULL,
  mobile_defaults jsonb DEFAULT '{}'::jsonb NOT NULL,
  description text,
  version text DEFAULT 'v1'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS public.conversion_template_families (
  family text NOT NULL,
  use_case text NOT NULL,
  categories text[] DEFAULT '{}'::text[] NOT NULL,
  traffic_fit text[] DEFAULT '{}'::text[] NOT NULL,
  required_sections text[] DEFAULT '{}'::text[] NOT NULL,
  optional_sections text[] DEFAULT '{}'::text[] NOT NULL,
  excluded_sections text[] DEFAULT '{}'::text[] NOT NULL,
  hero_variant text NOT NULL,
  ordering_strategy text[] DEFAULT '{}'::text[] NOT NULL,
  evidence_requirements text[] DEFAULT '{}'::text[] NOT NULL,
  disqualifiers text[] DEFAULT '{}'::text[] NOT NULL,
  cta_structure jsonb DEFAULT '{}'::jsonb NOT NULL,
  selection_priority integer DEFAULT 100 NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  version text DEFAULT 'v1'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS public.daily_briefs (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  date date NOT NULL,
  top_opportunities jsonb DEFAULT '[]'::jsonb,
  brief_json jsonb DEFAULT '{}'::jsonb,
  generated_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.demo_events (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  session_id text NOT NULL,
  selected_industry text,
  step integer,
  event_type text NOT NULL,
  opportunity_id uuid,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.discovery_runs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  member_id uuid NOT NULL,
  website text,
  run_status text DEFAULT 'queued'::text NOT NULL,
  contract_version integer DEFAULT 1 NOT NULL,
  raw_contract jsonb,
  error jsonb,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  completed_at timestamp with time zone,
  entry_mode text,
  commerce_inputs jsonb
);

CREATE TABLE IF NOT EXISTS public.discovery_state (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  member_id uuid NOT NULL,
  status text DEFAULT 'not_started'::text NOT NULL,
  entry_viewed_at timestamp with time zone,
  started_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  analysis_status text DEFAULT 'not_started'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS public.ecommerce_market_universe (
  country_code text NOT NULL,
  country_name text NOT NULL,
  region text NOT NULL,
  default_currency text NOT NULL,
  currency_supported boolean DEFAULT false NOT NULL,
  supplier_supported text DEFAULT 'UNKNOWN'::text NOT NULL,
  search_intelligence_supported text DEFAULT 'UNKNOWN'::text NOT NULL,
  marketplace_intelligence_supported text DEFAULT 'UNKNOWN'::text NOT NULL,
  advertising_intelligence_supported text DEFAULT 'UNKNOWN'::text NOT NULL,
  campaign_execution_supported text DEFAULT 'UNKNOWN'::text NOT NULL,
  ecommerce_eligible boolean DEFAULT false NOT NULL,
  evidence_coverage numeric DEFAULT 0 NOT NULL,
  status text DEFAULT 'UNKNOWN'::text NOT NULL,
  is_operator_config boolean DEFAULT false NOT NULL,
  authoritative_dataset text,
  basis jsonb DEFAULT '{}'::jsonb NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.engagement_patterns (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  platform text NOT NULL,
  best_day text,
  best_time_utc time without time zone,
  avg_score numeric DEFAULT 0,
  top_topics jsonb DEFAULT '[]'::jsonb,
  total_posts integer DEFAULT 0,
  calculated_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.founder_ecom_test_config (
  id boolean DEFAULT true NOT NULL,
  business_home_market text NOT NULL,
  founder_display_currency text NOT NULL,
  ecommerce_selling_market text NOT NULL,
  opportunity_target_market text NOT NULL,
  market_currency text NOT NULL,
  campaign_target_market text,
  rationale text NOT NULL,
  selected_at timestamp with time zone DEFAULT now() NOT NULL,
  sourcing_status text,
  sourcing_status_note text,
  sourcing_status_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.founding_applications (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  first_name text NOT NULL,
  last_name text NOT NULL,
  work_email text NOT NULL,
  company text,
  country text,
  industry text,
  role text,
  company_size text,
  primary_goal text,
  use_case text,
  current_workflow text,
  status text DEFAULT 'new'::text NOT NULL,
  source text DEFAULT 'website'::text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.fx_rates (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  base_currency text NOT NULL,
  quote_currency text NOT NULL,
  rate numeric NOT NULL,
  source text NOT NULL,
  as_of date NOT NULL,
  fetched_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.generated_content (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  opportunity_id uuid,
  user_id uuid,
  script text,
  caption text,
  hashtags jsonb DEFAULT '[]'::jsonb,
  thumbnail_ideas jsonb DEFAULT '[]'::jsonb,
  image_prompts jsonb DEFAULT '[]'::jsonb,
  seo_title text,
  seo_description text,
  seo_keywords jsonb DEFAULT '[]'::jsonb,
  b_roll_ideas jsonb DEFAULT '[]'::jsonb,
  cta_variations jsonb DEFAULT '[]'::jsonb,
  platform text,
  language text DEFAULT 'en'::text,
  generated_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.growth_messages (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  agent text NOT NULL,
  message_type text NOT NULL,
  trigger_reason text NOT NULL,
  channel text,
  content_summary text,
  llm_generated boolean DEFAULT false,
  sent_at timestamp with time zone DEFAULT now(),
  opened_at timestamp with time zone,
  clicked_at timestamp with time zone,
  dismissed_at timestamp with time zone,
  outcome text
);

CREATE TABLE IF NOT EXISTS public.invitation (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  token_hash text NOT NULL,
  bound_email text NOT NULL,
  application_ref uuid,
  issued_at timestamp with time zone DEFAULT now() NOT NULL,
  expires_at timestamp with time zone NOT NULL,
  status text DEFAULT 'issued'::text NOT NULL,
  consumed_at timestamp with time zone,
  superseded_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.leads (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  email text NOT NULL,
  name text,
  market text,
  company text,
  clients_count text,
  source text DEFAULT 'landing_page'::text,
  created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.market_price_observations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  product_query text NOT NULL,
  product_id uuid,
  market text NOT NULL,
  source text NOT NULL,
  sample_size integer,
  total_listings integer,
  price_min numeric,
  price_median numeric,
  price_max numeric,
  currency text NOT NULL,
  observed_at timestamp with time zone DEFAULT now() NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.marketing_authority_audit (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  event text NOT NULL,
  actor uuid,
  authority_id uuid,
  campaign_id uuid,
  before_state jsonb,
  after_state jsonb,
  reason text,
  correlation_key text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.marketing_campaign_drafts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid,
  source_run_id uuid,
  website text,
  business_context jsonb DEFAULT '{}'::jsonb NOT NULL,
  report jsonb DEFAULT '{}'::jsonb NOT NULL,
  canonical_campaign jsonb,
  platform_payloads jsonb,
  creative_specs jsonb,
  brand_assets jsonb,
  preview_payload jsonb,
  review_payload jsonb,
  performance_schema jsonb,
  lifecycle jsonb DEFAULT jsonb_build_object('status', 'DRAFT') NOT NULL,
  status text DEFAULT 'DRAFT'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.marketing_campaign_executions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  draft_id uuid NOT NULL,
  user_id uuid,
  platform text DEFAULT 'meta'::text NOT NULL,
  status text DEFAULT 'PENDING'::text NOT NULL,
  meta_account_ref text,
  meta_page_ref text,
  meta_campaign_id text,
  meta_adset_id text,
  meta_creative_id text,
  meta_ad_id text,
  effective_status jsonb DEFAULT '{}'::jsonb NOT NULL,
  notes jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.marketing_spend_authority (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  platform text NOT NULL,
  ad_account text,
  execution_currency text NOT NULL,
  authorized_total numeric DEFAULT 0 NOT NULL,
  max_daily numeric DEFAULT 0 NOT NULL,
  max_campaign numeric DEFAULT 0 NOT NULL,
  max_product_test numeric DEFAULT 0 NOT NULL,
  allowed_markets jsonb DEFAULT '[]'::jsonb NOT NULL,
  allowed_actions jsonb DEFAULT '[]'::jsonb NOT NULL,
  start_at timestamp with time zone,
  end_at timestamp with time zone,
  spent numeric DEFAULT 0 NOT NULL,
  status text DEFAULT 'INACTIVE'::text NOT NULL,
  is_synthetic boolean DEFAULT true NOT NULL,
  executable boolean DEFAULT false NOT NULL,
  hard_ceiling_mechanism text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  mode text DEFAULT 'MANUAL'::text NOT NULL,
  reserved numeric DEFAULT 0 NOT NULL,
  allowed_campaign_types jsonb DEFAULT '[]'::jsonb NOT NULL,
  created_by uuid,
  approved_by uuid,
  approved_at timestamp with time zone,
  authority_fingerprint text,
  revoked_at timestamp with time zone,
  remaining numeric GENERATED ALWAYS AS (((authorized_total - spent) - reserved)) STORED
);

CREATE TABLE IF NOT EXISTS public.media_assets (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  product_id uuid,
  creative_id uuid,
  source_asset_id uuid,
  media_type text NOT NULL,
  source_type text NOT NULL,
  provider text,
  provider_job_id text,
  rights_state text DEFAULT 'UNKNOWN'::text NOT NULL,
  generation_status text DEFAULT 'PENDING'::text NOT NULL,
  approval_state text DEFAULT 'DRAFT'::text NOT NULL,
  mime_type text,
  width integer,
  height integer,
  duration numeric,
  aspect_ratio text,
  storage_ref text,
  spec_ref jsonb DEFAULT '{}'::jsonb NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  is_launch_safe boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  country_code text,
  generation_mode text,
  usage_permission text,
  cost_amount numeric,
  cost_currency text,
  failure_reason text,
  source_asset_refs jsonb,
  creative_strategy_ref uuid,
  ad_variant_ref uuid
);

CREATE TABLE IF NOT EXISTS public.media_image_jobs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  angle_id uuid,
  static_creative_id uuid,
  input_asset_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
  product_facts jsonb DEFAULT '{}'::jsonb NOT NULL,
  visual_concept text,
  static_creative_spec jsonb DEFAULT '{}'::jsonb NOT NULL,
  brand_context jsonb DEFAULT '{}'::jsonb NOT NULL,
  platform text,
  aspect_ratio text,
  safe_area text,
  generation_instructions text,
  provider text,
  provider_job_id text,
  status text DEFAULT 'DRAFT'::text NOT NULL,
  output_asset_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
  estimated_cost numeric,
  actual_cost numeric,
  cost_currency text,
  error_state text,
  retry_count integer DEFAULT 0 NOT NULL,
  max_retries integer DEFAULT 3 NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.media_job_costs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  job_id uuid NOT NULL,
  operation_type text NOT NULL,
  provider text,
  estimated_cost numeric,
  actual_cost numeric,
  currency text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.media_providers (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  media_type text NOT NULL,
  enabled boolean DEFAULT false NOT NULL,
  config jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.media_video_jobs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  angle_id uuid,
  source_image_asset_id uuid,
  product_facts jsonb DEFAULT '{}'::jsonb NOT NULL,
  video_hook text,
  script text,
  storyboard jsonb DEFAULT '[]'::jsonb NOT NULL,
  platform text,
  duration_target numeric,
  aspect_ratio text,
  motion_instructions text,
  text_overlays jsonb DEFAULT '[]'::jsonb NOT NULL,
  cta text,
  brand_context jsonb DEFAULT '{}'::jsonb NOT NULL,
  provider text,
  provider_job_id text,
  status text DEFAULT 'DRAFT'::text NOT NULL,
  video_asset_ref uuid,
  estimated_cost numeric,
  actual_cost numeric,
  cost_currency text,
  error_state text,
  retry_count integer DEFAULT 0 NOT NULL,
  max_retries integer DEFAULT 3 NOT NULL,
  claim_violations jsonb DEFAULT '[]'::jsonb NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.media_video_scenes (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  video_job_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  scene_number integer NOT NULL,
  duration_target numeric,
  source_asset_ref uuid,
  visual_action text,
  motion_instruction text,
  text_overlay text,
  voiceover text,
  transition text,
  claim_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
  claim_violations jsonb DEFAULT '[]'::jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS public.member (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  auth_user_id uuid NOT NULL,
  email text NOT NULL,
  display_name text,
  business_name text,
  email_verified boolean DEFAULT false NOT NULL,
  welcome_seen boolean DEFAULT false NOT NULL,
  account_status text DEFAULT 'active'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  application_ref uuid
);

CREATE TABLE IF NOT EXISTS public.member_actions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  member_opportunity_id uuid,
  opportunity_id uuid,
  action_type text NOT NULL,
  title text,
  detail text,
  rank integer,
  status text DEFAULT 'open'::text NOT NULL,
  provenance jsonb NOT NULL,
  extended jsonb,
  source_run_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.member_business_dna (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  business_model text,
  unique_value_prop text,
  brand_positioning text,
  growth_stage text,
  brand_voice text,
  goals jsonb,
  icp jsonb,
  dna_extended jsonb,
  provenance jsonb NOT NULL,
  source_run_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.member_feedback (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  subject_type text NOT NULL,
  source_run_id uuid,
  rank integer,
  content_id uuid,
  useful boolean,
  acted boolean,
  comment text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.member_generated_content (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  member_opportunity_id uuid,
  source_run_id uuid,
  rank integer,
  content_type text NOT NULL,
  platform text,
  request jsonb DEFAULT '{}'::jsonb NOT NULL,
  status text DEFAULT 'queued'::text NOT NULL,
  content jsonb,
  error jsonb,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  completed_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.member_opportunities (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  opportunity_id uuid,
  rank integer,
  business_relevance numeric,
  personalized_opportunity_score numeric,
  confidence numeric,
  urgency text,
  why_matters text,
  why_now text,
  recommended_decision text,
  evidence jsonb,
  content_reco jsonb,
  status text DEFAULT 'suggested'::text NOT NULL,
  extended jsonb,
  provenance jsonb NOT NULL,
  source_run_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  title text,
  summary text
);

CREATE TABLE IF NOT EXISTS public.meta_platform_config (
  id integer DEFAULT 1 NOT NULL,
  account_id text NOT NULL,
  page_id text NOT NULL,
  graph_version text DEFAULT 'v26.0'::text NOT NULL,
  currency text DEFAULT 'USD'::text NOT NULL,
  notes jsonb DEFAULT '{}'::jsonb NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.meta_tracking_config (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  pixel_id text,
  dataset_id text,
  capi_token_ref text,
  domain_verified boolean DEFAULT false NOT NULL,
  state text DEFAULT 'NOT_CONFIGURED'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  capi_enabled boolean DEFAULT false NOT NULL,
  tracking_adapter text,
  integration_method text,
  verification_state text DEFAULT 'UNVERIFIED'::text NOT NULL,
  last_verified_at timestamp with time zone,
  last_verification_result jsonb DEFAULT '{}'::jsonb NOT NULL,
  dataset_quality_state text,
  pixel_state text,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.monday_opportunity_registry (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  supplier_id uuid,
  markets jsonb DEFAULT '[]'::jsonb NOT NULL,
  active boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.monday_opportunity_runs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  run_at timestamp with time zone DEFAULT now() NOT NULL,
  trigger_source text NOT NULL,
  candidates integer,
  combinations integer,
  delivered integer,
  excluded_avoid integer,
  source_states jsonb DEFAULT '{}'::jsonb NOT NULL,
  payload jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS public.opportunities (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  trend_cluster_id uuid,
  title text NOT NULL,
  opportunity_score numeric DEFAULT 0 NOT NULL,
  confidence_score numeric DEFAULT 0 NOT NULL,
  competition_level text DEFAULT 'medium'::text,
  search_demand_score numeric DEFAULT 0,
  recency_score numeric DEFAULT 0,
  novelty_score numeric DEFAULT 0,
  business_relevance numeric DEFAULT 0,
  best_platform text DEFAULT 'YouTube'::text,
  recommended_audience text,
  difficulty text DEFAULT 'Medium'::text,
  first_mover_advantage boolean DEFAULT false,
  competitor_gap boolean DEFAULT false,
  expected_lifespan_days integer DEFAULT 7,
  potential_risks jsonb DEFAULT '[]'::jsonb,
  evidence jsonb DEFAULT '{}'::jsonb,
  status text DEFAULT 'active'::text,
  created_at timestamp with time zone DEFAULT now(),
  expires_at timestamp with time zone,
  why_now text,
  content_angle text,
  best_posting_time jsonb DEFAULT '{"best": [], "avoid": []}'::jsonb,
  ignore_reason text,
  regions jsonb DEFAULT '[]'::jsonb,
  audience_fit_score numeric DEFAULT 0,
  why_ignore text
);

CREATE TABLE IF NOT EXISTS public.pending_in_app_messages (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  agent text NOT NULL,
  message_id uuid,
  title text,
  body text,
  cta_label text,
  cta_action text,
  priority text DEFAULT 'normal'::text,
  created_at timestamp with time zone DEFAULT now(),
  seen_at timestamp with time zone,
  dismissed_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.performance_experiments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  product_id uuid,
  objective text NOT NULL,
  dimension text,
  baseline jsonb DEFAULT '{}'::jsonb NOT NULL,
  variant jsonb DEFAULT '{}'::jsonb NOT NULL,
  hypothesis text,
  metric text,
  min_evidence_policy jsonb DEFAULT '{}'::jsonb NOT NULL,
  start_at timestamp with time zone,
  end_at timestamp with time zone,
  status text DEFAULT 'DRAFT'::text NOT NULL,
  result jsonb,
  confidence text,
  learning text,
  is_fixture boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.performance_learning_memory (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  product_id uuid,
  market text,
  platform text,
  statement text NOT NULL,
  learning_type text DEFAULT 'OBSERVATION'::text NOT NULL,
  sample jsonb DEFAULT '{}'::jsonb NOT NULL,
  confidence text DEFAULT 'LOW'::text NOT NULL,
  source_class text DEFAULT 'UNKNOWN'::text NOT NULL,
  window_start timestamp with time zone,
  window_end timestamp with time zone,
  is_fixture boolean DEFAULT false NOT NULL,
  superseded boolean DEFAULT false NOT NULL,
  stale_after timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.performance_learnings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  business_id uuid,
  opportunity_id uuid,
  product_id uuid,
  decision_id uuid,
  campaign_draft_id uuid,
  campaign_execution_id uuid,
  performance_snapshot_id uuid,
  creative_id uuid,
  angle_id uuid,
  offer_id uuid,
  audience_ref text,
  keyword_ref text,
  learning_type text NOT NULL,
  code text,
  observation text,
  hypothesis text,
  recommended_action text,
  action_scope text,
  evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
  evidence_quality text,
  confidence text DEFAULT 'LOW'::text NOT NULL,
  execution_authorization_required boolean DEFAULT true NOT NULL,
  executable boolean DEFAULT false NOT NULL,
  is_fixture boolean DEFAULT false NOT NULL,
  market text,
  platform text,
  time_window jsonb,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.product_acquisitions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  source_run_id uuid NOT NULL,
  state text DEFAULT 'DISCOVERED'::text NOT NULL,
  state_reason text,
  winning_product_snapshot jsonb NOT NULL,
  selected_supplier_snapshot jsonb,
  sourcing_spec_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
  prepared_package jsonb,
  generated_content_id uuid,
  missing_information jsonb DEFAULT '[]'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  approved_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.product_asset_intelligence (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  supplier_product_id text,
  source text NOT NULL,
  source_url text,
  source_ref text,
  asset_type text DEFAULT 'SOURCE_PRODUCT_IMAGE'::text NOT NULL,
  rights_state text DEFAULT 'UNKNOWN'::text NOT NULL,
  identity_state text DEFAULT 'UNKNOWN'::text NOT NULL,
  match_class text,
  match_confidence text,
  hero_eligible boolean DEFAULT false NOT NULL,
  is_primary boolean DEFAULT false NOT NULL,
  observed_at timestamp with time zone,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  is_fixture boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.product_market_competitors (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  product_market_evaluation_id uuid,
  country_code text NOT NULL,
  competitor_kind text,
  competitor_identity text,
  competitor_ref text,
  competitor_product_ref text,
  observed_product_url text,
  match_class text DEFAULT 'UNRELATED'::text NOT NULL,
  match_confidence text,
  match_evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
  platform text,
  price_original numeric,
  price_currency text,
  price_source_class text,
  price_normalized jsonb,
  price_observed_at timestamp with time zone,
  ad_platform text,
  observable_ad_count integer,
  ad_status text,
  ad_window jsonb,
  creative_pattern text,
  offer_pattern text,
  cta_pattern text,
  marketplace_presence jsonb,
  source text,
  source_reference text,
  evidence_class text,
  observed_at timestamp with time zone,
  confidence text,
  is_fixture boolean DEFAULT false NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.product_market_evaluations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  country_code text NOT NULL,
  market_currency text,
  evaluation_ts timestamp with time zone DEFAULT now() NOT NULL,
  evidence_window jsonb DEFAULT '{}'::jsonb NOT NULL,
  component_scores jsonb DEFAULT '{}'::jsonb NOT NULL,
  market_opportunity_score numeric,
  coverage numeric,
  evidence_confidence text DEFAULT 'NONE'::text NOT NULL,
  score_version text DEFAULT 'pm_score_v1'::text NOT NULL,
  gate_state jsonb DEFAULT '{}'::jsonb NOT NULL,
  market_decision text DEFAULT 'WATCH'::text NOT NULL,
  decision_reasons jsonb DEFAULT '[]'::jsonb NOT NULL,
  risk_flags jsonb DEFAULT '[]'::jsonb NOT NULL,
  evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
  stock_state text,
  compliance_risk text,
  economics jsonb DEFAULT '{}'::jsonb NOT NULL,
  landed_cost jsonb,
  is_fixture boolean DEFAULT false NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.product_market_platform_evaluations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  product_market_evaluation_id uuid,
  country_code text NOT NULL,
  platform text NOT NULL,
  acquisition_mode text,
  component_scores jsonb DEFAULT '{}'::jsonb NOT NULL,
  platform_fit_score numeric,
  coverage numeric,
  evidence_confidence text DEFAULT 'NONE'::text NOT NULL,
  evidence_state text DEFAULT 'INSUFFICIENT'::text NOT NULL,
  competition_level text,
  saturation_points numeric,
  observable_advertiser_count integer,
  observable_ad_count integer,
  platform_gaps jsonb DEFAULT '[]'::jsonb NOT NULL,
  recommendation text DEFAULT 'INSUFFICIENT_EVIDENCE'::text NOT NULL,
  execution_capability text,
  execution_readiness text,
  risks jsonb DEFAULT '[]'::jsonb NOT NULL,
  reasons jsonb DEFAULT '[]'::jsonb NOT NULL,
  evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
  score_version text DEFAULT 'ppf_score_v1'::text NOT NULL,
  is_fixture boolean DEFAULT false NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.product_opportunity_decisions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tenant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  country_code text NOT NULL,
  market_currency text,
  score_version text DEFAULT 'pod_v1'::text NOT NULL,
  product_market_evaluation_id uuid,
  primary_platform text,
  primary_platform_evaluation_id uuid,
  lineage jsonb DEFAULT '{}'::jsonb NOT NULL,
  component_scores jsonb DEFAULT '{}'::jsonb NOT NULL,
  product_opportunity_score numeric,
  coverage numeric,
  opportunity_band text,
  overall_evidence_confidence text,
  decision text,
  lifecycle_state text,
  metric_scope text,
  hard_gates jsonb DEFAULT '{}'::jsonb NOT NULL,
  decision_blockers jsonb DEFAULT '[]'::jsonb NOT NULL,
  execution_blockers jsonb DEFAULT '[]'::jsonb NOT NULL,
  action_gating text,
  economics_ref jsonb DEFAULT '{}'::jsonb NOT NULL,
  cpa_scenarios jsonb DEFAULT '{}'::jsonb NOT NULL,
  decision_reasons jsonb DEFAULT '[]'::jsonb NOT NULL,
  is_fixture boolean DEFAULT false NOT NULL,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  product_confidence text,
  saturation_state jsonb DEFAULT '{}'::jsonb NOT NULL,
  advertising_headroom jsonb DEFAULT '{}'::jsonb NOT NULL,
  opportunity_sweet_spot jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS public.provider_capability_registry (
  source text NOT NULL,
  evidence_category text NOT NULL,
  market text DEFAULT '*'::text NOT NULL,
  availability text NOT NULL,
  coverage_type text,
  capability jsonb DEFAULT '{}'::jsonb NOT NULL,
  limitations text,
  last_verified_at timestamp with time zone,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.pulse_guide_events (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  session_id text NOT NULL,
  screen integer,
  question text,
  selected_industry text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.rejected_ideas (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  opportunity_id uuid,
  topic text NOT NULL,
  reason text,
  rejected_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.roadmap_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  description text,
  category text,
  status text DEFAULT 'planned'::text NOT NULL,
  priority integer DEFAULT 0,
  planned_quarter text,
  public_visible boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.saved_opportunities (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  opportunity_id uuid,
  notes text,
  saved_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.spend_reservations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  authority_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  campaign_id uuid,
  amount numeric NOT NULL,
  currency text NOT NULL,
  status text DEFAULT 'RESERVED'::text NOT NULL,
  idempotency_key text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  released_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS public.successful_opportunities (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  opportunity_id uuid,
  platform text,
  published_at timestamp with time zone,
  views integer,
  engagement_rate numeric,
  outcome_notes text,
  recorded_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.supplier_product_assets (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  supplier text NOT NULL,
  supplier_product_id text NOT NULL,
  supplier_variant_id text,
  product_title text,
  asset_type text NOT NULL,
  asset_class text DEFAULT 'SOURCE_PRODUCT_ASSET'::text NOT NULL,
  asset_identity text DEFAULT 'SUPPLIER_OWN'::text NOT NULL,
  rights_state text DEFAULT 'UNKNOWN'::text NOT NULL,
  availability text DEFAULT 'AVAILABLE'::text NOT NULL,
  unavailable_reason text,
  source_url text,
  original_source text,
  is_primary boolean DEFAULT false NOT NULL,
  cache_state text DEFAULT 'ORIGIN_HOTLINK'::text NOT NULL,
  storage_ref text,
  observed_at timestamp with time zone,
  provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
  is_fixture boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.trend_clusters (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  canonical_topic text NOT NULL,
  native_topic text,
  related_terms jsonb DEFAULT '[]'::jsonb,
  growth_pct numeric DEFAULT 0,
  velocity_score numeric DEFAULT 0,
  competition_score numeric DEFAULT 50,
  freshness_hours integer DEFAULT 24,
  regional_popularity jsonb DEFAULT '{}'::jsonb,
  audience_fit_score numeric DEFAULT 50,
  trend_score numeric DEFAULT 0,
  source_count integer DEFAULT 1,
  is_global boolean DEFAULT false,
  primary_language text DEFAULT 'en'::text,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  is_emerging boolean DEFAULT false,
  peak_predicted_at timestamp with time zone,
  signals_count integer DEFAULT 0,
  top_regions jsonb DEFAULT '[]'::jsonb,
  why_trending text,
  first_mover_potential boolean DEFAULT false
);

CREATE TABLE IF NOT EXISTS public.trend_signals (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  source text NOT NULL,
  raw_topic text NOT NULL,
  raw_data jsonb,
  region text DEFAULT 'US'::text,
  language text DEFAULT 'en'::text,
  collected_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_consent (
  user_id uuid NOT NULL,
  behavioral_tracking boolean DEFAULT true,
  marketing_emails boolean DEFAULT true,
  in_app_messages boolean DEFAULT true,
  consent_updated_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_events (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  event_type text NOT NULL,
  event_category text NOT NULL,
  metadata jsonb DEFAULT '{}'::jsonb,
  session_id text,
  platform text DEFAULT 'web'::text,
  occurred_at timestamp with time zone DEFAULT now(),
  retention_until timestamp with time zone DEFAULT (now() + '180 days'::interval)
);

CREATE TABLE IF NOT EXISTS public.user_growth_profile (
  user_id uuid NOT NULL,
  engagement_score numeric DEFAULT 0,
  activation_score numeric DEFAULT 0,
  activation_status text DEFAULT 'new'::text,
  feature_adoption jsonb DEFAULT '{}'::jsonb,
  last_active_at timestamp with time zone,
  session_count_14d integer DEFAULT 0,
  days_since_signup integer DEFAULT 0,
  upgrade_propensity_score numeric DEFAULT 0,
  upgrade_propensity_tier text DEFAULT 'low'::text,
  hit_plan_limits_count integer DEFAULT 0,
  pro_feature_previews integer DEFAULT 0,
  last_upgrade_prompt_at timestamp with time zone,
  upgrade_prompts_sent_30d integer DEFAULT 0,
  churn_risk_score numeric DEFAULT 0,
  churn_risk_tier text DEFAULT 'healthy'::text,
  last_churn_action_at timestamp with time zone,
  churn_signals jsonb DEFAULT '[]'::jsonb,
  onboarding_stage text DEFAULT 'signup'::text,
  success_milestones jsonb DEFAULT '[]'::jsonb,
  last_success_nudge_at timestamp with time zone,
  updated_at timestamp with time zone DEFAULT now(),
  updated_by_agent text
);

CREATE TABLE IF NOT EXISTS public.user_memory (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  user_id uuid,
  memory_type text NOT NULL,
  content text NOT NULL,
  embedding vector(1536),
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.users (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  email text NOT NULL,
  name text,
  plan text DEFAULT 'free'::text,
  locale text DEFAULT 'en'::text,
  country_code text DEFAULT 'US'::text,
  timezone text DEFAULT 'America/New_York'::text,
  active boolean DEFAULT true,
  notifications_enabled boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  industry text,
  brand_tone text DEFAULT 'professional'::text,
  audience_type text,
  preferred_platforms jsonb DEFAULT '["YouTube", "LinkedIn"]'::jsonb,
  notification_time time without time zone DEFAULT '05:30:00'::time without time zone,
  subscription_plan text DEFAULT 'free'::text,
  subscription_status text DEFAULT 'active'::text,
  subscription_renews_at timestamp with time zone,
  stripe_customer_id text,
  onboarding_complete boolean DEFAULT false,
  updated_at timestamp with time zone DEFAULT now(),
  preferred_display_currency text
);

CREATE TABLE IF NOT EXISTS public.workflow_logs (
  id uuid DEFAULT uuid_generate_v4() NOT NULL,
  workflow_name text NOT NULL,
  agent text NOT NULL,
  status text,
  input_summary jsonb,
  output_summary jsonb,
  duration_ms integer,
  error_message text,
  created_at timestamp with time zone DEFAULT now()
);

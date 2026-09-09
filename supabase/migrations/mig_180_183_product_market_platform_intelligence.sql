-- PULSE-ECOM-PRODUCT-MARKET-AD-PLATFORM-INTELLIGENCE-001
-- Applied to Supabase as mig_180 (table + fn_ppf_execution_readiness), mig_181
-- (fn_ppf_acquisition_mode, fn_ppf_evaluate), mig_182 (fn_ppf_rank, fn_ppf_monday_block),
-- mig_183 (fn_ppf_rank confidence-tier-first fix). Final deployed state.

CREATE TABLE IF NOT EXISTS public.product_market_platform_evaluations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL, product_id uuid NOT NULL, product_market_evaluation_id uuid,
  country_code text NOT NULL, platform text NOT NULL, acquisition_mode text,
  component_scores jsonb NOT NULL DEFAULT '{}'::jsonb, platform_fit_score numeric,
  coverage numeric, evidence_confidence text NOT NULL DEFAULT 'NONE',
  evidence_state text NOT NULL DEFAULT 'INSUFFICIENT',
  competition_level text, saturation_points numeric,
  observable_advertiser_count integer, observable_ad_count integer,
  platform_gaps jsonb NOT NULL DEFAULT '[]'::jsonb,
  recommendation text NOT NULL DEFAULT 'INSUFFICIENT_EVIDENCE',
  execution_capability text, execution_readiness text,
  risks jsonb NOT NULL DEFAULT '[]'::jsonb, reasons jsonb NOT NULL DEFAULT '[]'::jsonb,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb, score_version text NOT NULL DEFAULT 'ppf_score_v1',
  is_fixture boolean NOT NULL DEFAULT false, provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ppf_country_chk CHECK (country_code ~ '^[A-Z]{2}$'),
  CONSTRAINT ppf_platform_chk CHECK (platform IN ('FACEBOOK','INSTAGRAM','TIKTOK','GOOGLE_SEARCH')),
  CONSTRAINT ppf_rec_chk CHECK (recommendation IN ('PRIMARY_TEST','SECONDARY_TEST','ALTERNATIVE','WATCH','INSUFFICIENT_EVIDENCE','AVOID')),
  CONSTRAINT ppf_unique UNIQUE (tenant_id, product_id, country_code, platform, score_version));
CREATE INDEX IF NOT EXISTS ppf_pm_idx ON public.product_market_platform_evaluations (tenant_id, product_id, country_code);
ALTER TABLE public.product_market_platform_evaluations ENABLE ROW LEVEL SECURITY;
-- RLS on, no permissive policy: service role / SECURITY DEFINER only.
--
-- fn_ppf_execution_readiness(platform): REAL current state, separate from opportunity/score.
--   FACEBOOK/INSTAGRAM -> META_ADAPTER / CONNECTED; TIKTOK -> NONE / NOT_CONNECTED;
--   GOOGLE_SEARCH -> NONE / BLOCKED (Google Ads API rejected; intelligence-only, never bypassed).
-- fn_ppf_acquisition_mode(evidence): SEARCH_LED / DISCOVERY_LED / HYBRID / UNKNOWN from evidence
--   (search buyer-intent+transactional volume vs discovery social+demonstrability), not LLM knowledge.
-- fn_ppf_evaluate(tenant,product,country,platform,evidence,pme_id,policy,is_fixture,persist):
--   8 weighted components (buyer_intent_fit 18, observable_competitor_activity 12, audience_fit 14,
--   product_demonstrability 12, creative_format_fit 12, price_consideration_fit 8,
--   competition_saturation 12, platform_opportunity_gap 12) scored via fn_pm_score (UNKNOWN excluded,
--   never zero). Eligibility gate: coverage<0.4 or evidence_state INSUFFICIENT -> INSUFFICIENT_EVIDENCE;
--   fit<35 -> AVOID; else WATCH (candidate). Execution readiness stored but NEVER affects score/rec.
-- fn_ppf_rank(tenant,product,country,score_version,persist): deterministic ranking of eligible
--   candidates by confidence-tier FIRST, then fit, then platform; #1 PRIMARY_TEST, #2 SECONDARY_TEST,
--   rest ALTERNATIVE; INSUFFICIENT/AVOID unchanged; ignores execution readiness; does not set campaign market.
-- fn_ppf_monday_block(tenant,product,country): Monday platform block (best platform / fit / why /
--   search-vs-discovery / competitor activity / saturation / alternative / confidence / execution readiness).
-- All functions REVOKE'd from PUBLIC and anon; SECURITY DEFINER with SET search_path=''.

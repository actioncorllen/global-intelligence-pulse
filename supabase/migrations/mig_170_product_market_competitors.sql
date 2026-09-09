-- PULSE-ECOM-PRODUCT-MARKET-COMPETITOR-INTELLIGENCE-001
-- Canonical PRODUCT x MARKET x COMPETITOR observation. Intelligence/reference only.
-- No sales/revenue/ROAS/conversion columns exist by design (metrics-safety at schema level).
CREATE TABLE IF NOT EXISTS public.product_market_competitors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL, product_id uuid NOT NULL,
  product_market_evaluation_id uuid, country_code text NOT NULL,
  competitor_kind text, competitor_identity text, competitor_ref text,
  competitor_product_ref text, observed_product_url text,
  match_class text NOT NULL DEFAULT 'UNRELATED', match_confidence text,
  match_evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  platform text, price_original numeric, price_currency text, price_source_class text,
  price_normalized jsonb, price_observed_at timestamptz,
  ad_platform text, observable_ad_count integer, ad_status text, ad_window jsonb,
  creative_pattern text, offer_pattern text, cta_pattern text, marketplace_presence jsonb,
  source text, source_reference text, evidence_class text, observed_at timestamptz, confidence text,
  is_fixture boolean NOT NULL DEFAULT false, provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pmcomp_country_chk CHECK (country_code ~ '^[A-Z]{2}$'),
  CONSTRAINT pmcomp_match_chk CHECK (match_class IN ('EXACT_PRODUCT','CLOSE_COMPARABLE','CATEGORY_COMPETITOR','UNRELATED')));
CREATE INDEX IF NOT EXISTS pmcomp_pm_idx ON public.product_market_competitors (tenant_id, product_id, country_code);
CREATE INDEX IF NOT EXISTS pmcomp_pme_idx ON public.product_market_competitors (product_market_evaluation_id);
ALTER TABLE public.product_market_competitors ENABLE ROW LEVEL SECURITY;
-- RLS on, no permissive policy: service role / SECURITY DEFINER only.
-- Functions applied as mig_171 (fn_pmc_evaluate) and mig_172 (fn_pmc_summary, fn_pmc_monday_block)
-- in Supabase migration history for project nxaunmyihhjixxxljcqt.
--   fn_pmc_evaluate(tenant,product,country,market_currency,competitors,pme_id,policy,is_fixture,persist):
--     classifies match_class (EXACT/CLOSE/CATEGORY/UNRELATED; direct = EXACT+CLOSE only), persists
--     competitor rows, computes local price median/range/sample (local country + currency +
--     OBSERVED/PLATFORM_REPORTED only; converted foreign excluded), observable advertising
--     (counts only; never sales/revenue/ROAS/winning-ad), deterministic saturation
--     (LOW/MODERATE/HIGH/VERY_HIGH/UNKNOWN), evidence-backed gaps, and a score-component adapter
--     (competition_saturation_gap, advertising_activity, market_price_support, evidence_confidence)
--     that pm_score_v1 consumes WITHOUT weight changes. eBay seller identity never persisted.
--   fn_pmc_summary / fn_pmc_monday_block: non-mutating reads for the Monday competitor block.
-- All functions REVOKE'd from PUBLIC and anon; SECURITY DEFINER with SET search_path=''.

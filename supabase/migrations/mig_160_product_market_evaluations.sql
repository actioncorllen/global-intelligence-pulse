-- PULSE-ECOM-CROSS-MARKET-PRODUCT-INTELLIGENCE-001
-- Canonical PRODUCT x MARKET evaluation. A product is independently evaluable per country.
-- Provenance-first: source_class travels with every measurable field; UNKNOWN stays UNKNOWN.
CREATE TABLE IF NOT EXISTS public.product_market_evaluations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL, product_id uuid NOT NULL, country_code text NOT NULL,
  market_currency text, evaluation_ts timestamptz NOT NULL DEFAULT now(),
  evidence_window jsonb NOT NULL DEFAULT '{}'::jsonb,
  component_scores jsonb NOT NULL DEFAULT '{}'::jsonb,
  market_opportunity_score numeric, coverage numeric,
  evidence_confidence text NOT NULL DEFAULT 'NONE',
  score_version text NOT NULL DEFAULT 'pm_score_v1',
  gate_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  market_decision text NOT NULL DEFAULT 'WATCH',
  decision_reasons jsonb NOT NULL DEFAULT '[]'::jsonb,
  risk_flags jsonb NOT NULL DEFAULT '[]'::jsonb,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  stock_state text, compliance_risk text,
  economics jsonb NOT NULL DEFAULT '{}'::jsonb, landed_cost jsonb,
  is_fixture boolean NOT NULL DEFAULT false, provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pme_country_chk CHECK (country_code ~ '^[A-Z]{2}$'),
  CONSTRAINT pme_decision_chk CHECK (market_decision IN ('TEST','WATCH','AVOID')),
  CONSTRAINT pme_conf_chk CHECK (evidence_confidence IN ('NONE','LOW','MEDIUM','HIGH')),
  CONSTRAINT pme_unique UNIQUE (tenant_id, product_id, country_code, score_version));
CREATE INDEX IF NOT EXISTS pme_tenant_product_idx ON public.product_market_evaluations (tenant_id, product_id);
CREATE INDEX IF NOT EXISTS pme_rank_idx ON public.product_market_evaluations (tenant_id, product_id, market_opportunity_score DESC);
ALTER TABLE public.product_market_evaluations ENABLE ROW LEVEL SECURITY;
-- RLS on, no permissive policy: service role / SECURITY DEFINER only.
-- Functions applied as mig_161 (fn_pm_score, fn_pm_decision, fn_evaluate_product_market)
-- and mig_162 (fn_rank_product_markets, fn_pm_monday_block) in Supabase migration history
-- for project nxaunmyihhjixxxljcqt. Scoring contract summarised in the roadmap doc.

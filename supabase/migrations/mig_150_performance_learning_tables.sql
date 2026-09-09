-- PULSE-ECOM-P15-PERFORMANCE-LEARNING-OPTIMIZATION-001
-- Learn + recommend only. No execution. Tenant-scoped, provenance-first, fixture-isolated.
CREATE TABLE IF NOT EXISTS public.performance_learnings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
  business_id uuid, opportunity_id uuid, product_id uuid, decision_id uuid,
  campaign_draft_id uuid, campaign_execution_id uuid, performance_snapshot_id uuid,
  creative_id uuid, angle_id uuid, offer_id uuid, audience_ref text, keyword_ref text,
  learning_type text NOT NULL, code text, observation text, hypothesis text,
  recommended_action text, action_scope text, evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_quality text, confidence text NOT NULL DEFAULT 'LOW',
  execution_authorization_required boolean NOT NULL DEFAULT true, executable boolean NOT NULL DEFAULT false,
  is_fixture boolean NOT NULL DEFAULT false, market text, platform text, time_window jsonb,
  provenance jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT perf_learn_type_chk CHECK (learning_type IN ('OBSERVATION','DERIVED_FINDING','HYPOTHESIS','RECOMMENDATION')),
  CONSTRAINT perf_learn_conf_chk CHECK (confidence IN ('NONE','LOW','MEDIUM','HIGH','FIXTURE_NONE')));
CREATE INDEX IF NOT EXISTS perf_learn_tenant_idx ON public.performance_learnings (tenant_id, is_fixture, learning_type);
CREATE INDEX IF NOT EXISTS perf_learn_snapshot_idx ON public.performance_learnings (performance_snapshot_id);
ALTER TABLE public.performance_learnings ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.performance_experiments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, product_id uuid,
  objective text NOT NULL, dimension text, baseline jsonb NOT NULL DEFAULT '{}'::jsonb,
  variant jsonb NOT NULL DEFAULT '{}'::jsonb, hypothesis text, metric text,
  min_evidence_policy jsonb NOT NULL DEFAULT '{}'::jsonb, start_at timestamptz, end_at timestamptz,
  status text NOT NULL DEFAULT 'DRAFT', result jsonb, confidence text, learning text,
  is_fixture boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT perf_exp_status_chk CHECK (status IN ('DRAFT','RUNNING','COMPLETED','ABANDONED','INSUFFICIENT_EVIDENCE')));
CREATE INDEX IF NOT EXISTS perf_exp_tenant_idx ON public.performance_experiments (tenant_id, is_fixture, status);
ALTER TABLE public.performance_experiments ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.performance_learning_memory (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, product_id uuid,
  market text, platform text, statement text NOT NULL, learning_type text NOT NULL DEFAULT 'OBSERVATION',
  sample jsonb NOT NULL DEFAULT '{}'::jsonb, confidence text NOT NULL DEFAULT 'LOW',
  source_class text NOT NULL DEFAULT 'UNKNOWN', window_start timestamptz, window_end timestamptz,
  is_fixture boolean NOT NULL DEFAULT false, superseded boolean NOT NULL DEFAULT false,
  stale_after timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS perf_mem_tenant_idx ON public.performance_learning_memory (tenant_id, product_id, is_fixture);
ALTER TABLE public.performance_learning_memory ENABLE ROW LEVEL SECURITY;
-- All three: RLS on, no permissive policy -> service role / SECURITY DEFINER only.

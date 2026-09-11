-- PULSE-ECOM-CJ-SOURCING-LIVE-001
-- CJ-adapter-scoped provenance for CJ product-sourcing requests. NOT part of the
-- universal supplier contract (sourcing is a CJ-specific capability). Service-role
-- only (RLS on, no policies -> no anon/authenticated access). Idempotency: unique
-- source_id, plus a partial unique index preventing duplicate OPEN requests for the
-- same concept+market.
CREATE TABLE IF NOT EXISTS public.cj_sourcing_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL DEFAULT 'CJ',
  source_id text UNIQUE,                       -- CJ sourceId (null until create returns it)
  product_concept text NOT NULL,
  target_market text NOT NULL,
  specification jsonb NOT NULL,
  economic_ceiling_eur numeric,
  status text NOT NULL DEFAULT 'SUBMITTED',    -- Pulse lifecycle: SUBMITTED/PENDING/SOURCED/REJECTED/FAILED/EXPIRED (+ AWAITING_* pre-submit)
  provider_status text,                        -- raw CJ status/code/message
  founder_authorization text,                  -- authorization reference (no secrets)
  requested_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  provenance jsonb
);
ALTER TABLE public.cj_sourcing_requests ENABLE ROW LEVEL SECURITY;
-- No policies: only service_role (which bypasses RLS) may read/write. No anon/authenticated exposure.
-- Prevent duplicate OPEN requests for the same concept+market (idempotency guard).
CREATE UNIQUE INDEX IF NOT EXISTS uq_cj_sourcing_open_concept_market
  ON public.cj_sourcing_requests (lower(product_concept), target_market)
  WHERE status IN ('SUBMITTED','PENDING','SOURCED');
COMMENT ON TABLE public.cj_sourcing_requests IS
 'CJ provider-adapter-scoped sourcing-request provenance (not universal supplier contract). Service-role only.';

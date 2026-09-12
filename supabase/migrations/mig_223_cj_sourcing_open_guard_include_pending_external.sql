-- PULSE-ECOM-CJ-SOURCING-REQUEST-RECOVERY-002
-- Extend the CJ sourcing open-request idempotency guard to include the
-- PENDING_EXTERNAL_CJ_SOURCING lifecycle status, so a manually-submitted CJ
-- request that is pending externally still blocks a duplicate open request for
-- the same concept+market. This STRENGTHENS the guard (never weakens it).
DROP INDEX IF EXISTS public.uq_cj_sourcing_open_concept_market;
CREATE UNIQUE INDEX IF NOT EXISTS uq_cj_sourcing_open_concept_market
  ON public.cj_sourcing_requests (lower(product_concept), target_market)
  WHERE status IN ('SUBMITTED','PENDING','PENDING_EXTERNAL_CJ_SOURCING','SOURCED');

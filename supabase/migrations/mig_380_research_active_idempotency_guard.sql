-- mig_380 — Durable DB-LEVEL idempotency boundary for research-run creation
--
-- ROOT CAUSE (duplicate paid research executions, e.g. the 12-vs-6 replay):
-- The same logical research request (tenant + product + market) could create more than one ACTIVE
-- research execution. fn_research_request_core only performed in-flight dedup when
-- freshness_hours > 0, so freshness=0 replay / duplicate RPC evaluation / frontend double-invoke /
-- webhook retry / n8n retry / concurrent workers could each insert a second RESEARCHING run and
-- trigger a second paid provider dispatch. Nothing in the DATABASE prevented it — it relied on
-- caller/function discipline.
--
-- PERMANENT FIX (two parts):
--   1. Function-level (mig_379a, fn_research_request_core v4): a transaction advisory lock on the
--      logical key + ALWAYS-ON in-flight reuse (moved out of the `freshness>0` block) so sequential
--      and concurrent callers reuse the existing run and return CACHE_REUSED_IN_FLIGHT /
--      already_dispatched=true instead of dispatching again.
--   2. DB-level (THIS migration): a PARTIAL UNIQUE INDEX that makes "at most one ACTIVE (RESEARCHING)
--      research execution per logical key" a hard database invariant, enforced for ANY code path
--      (including direct inserts that bypass the function). A duplicate active insert is rejected by
--      the database, so a second paid execution cannot be created regardless of caller discipline.
--
-- Once a run leaves RESEARCHING (COMPLETE / PARTIAL / PARTIAL_SOURCE_FAILURE /
-- PARTIAL_SOURCE_UNAVAILABLE / INSUFFICIENT_EVIDENCE) the partial predicate no longer matches it,
-- so a legitimate LATER research request for the same logical key can still create a new run.
--
-- Safe to apply: verified 0 existing duplicate RESEARCHING rows per (tenant_id, product_id, market)
-- at authoring time, so the unique index builds without conflict.

-- Remove diagnostic/stub artifacts left by an interrupted deployment session (no-op elsewhere).
DROP FUNCTION IF EXISTS public.fn_s1ec_diag();
DROP FUNCTION IF EXISTS public.fn_s1ec_introspect();
DROP FUNCTION IF EXISTS public.fn_s1ec_behaviour();
DROP FUNCTION IF EXISTS public.fn_stage1_evidence_contract_selftest();

-- At most ONE active (RESEARCHING) research execution per logical research key.
CREATE UNIQUE INDEX IF NOT EXISTS commerce_research_run_active_logical_key_uniq
  ON public.commerce_research_run (tenant_id, product_id, market)
  WHERE status = 'RESEARCHING';

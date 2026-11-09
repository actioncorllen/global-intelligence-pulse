-- mig_341b — Scheduled reconciliation for Refresh Discovery (PREPARED; Stage B only; NOT applied)
-- 2026-11-09
--
-- Apply ONLY in Stage B, AFTER mig_341 (which defines fn_discovery_refresh_reconcile). Requires the pg_cron
-- extension (available on this project: pg_cron 1.6.4, not yet installed). The sweep recovers stuck requests
-- WITHOUT ever re-dispatching a (possibly chargeable) provider call:
--   * RESERVED past TTL  -> refund, provider_outcome CANCELLED_PRE_CHARGE (no chargeable call occurred)
--   * EXECUTING past TTL -> refund, provider_outcome UNRESOLVED_POST_DISPATCH (auditable; a paid call MAY have
--     occurred — the provider budget stays consumed, the customer is refunded per the founding-member beta)
-- fn_discovery_refresh_reconcile is idempotent (terminal requests are skipped) and service-role only, so a
-- missed or overlapping run is safe. Default TTL 30 minutes; the schedule runs every 15 minutes.
--
-- INERT WHILE REFRESH IS OFF: with no pricing/budget configured, no request ever reaches RESERVED/EXECUTING,
-- so the sweep simply finds nothing. It becomes meaningful only once Stage B activation (D1-D4) lets requests
-- be created.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Idempotent (re-)scheduling: drop any prior job of this name, then schedule it.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'discovery-refresh-reconcile';

SELECT cron.schedule(
  'discovery-refresh-reconcile',
  '*/15 * * * *',
  $$SELECT public.fn_discovery_refresh_reconcile(30)$$
);

-- Subscription-credit allowance sweep (mig_341c): grants each active subscriber its configured allowance once
-- per period, idempotent. Hourly is ample (it no-ops within a period and while the allowance is empty). Apply
-- only AFTER mig_341c. INERT until the founder configures discovery_credit_allowance (D2).
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'discovery-subscription-credit-sweep';
SELECT cron.schedule(
  'discovery-subscription-credit-sweep',
  '7 * * * *',
  $$SELECT public.fn_discovery_grant_subscription_credits_sweep()$$
);

-- Rollback: SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('discovery-refresh-reconcile','discovery-subscription-credit-sweep');

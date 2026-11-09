-- mig_341c — Subscription-included customer credit allowance (PREPARED; Stage B; NOT applied; INERT)
-- 2026-11-09
--
-- Beta credit model (founder-approved policy): credits are INCLUDED WITH A SUBSCRIPTION — there are NO credit
-- packs initially. This file is the mechanism by which an ACTIVE subscription grants a customer their
-- per-period Refresh Discovery credits. It invents NO amounts: discovery_credit_allowance starts EMPTY, so with
-- nothing configured the grant is a no-op (fail-closed). The founder sets the allowance (credits per period, per
-- plan) to activate (commercial decision D2).
--
-- Depends on mig_341 (discovery_credit_ledger + fn_discovery_credit_balance). Apply AFTER mig_341 in Stage B.
-- Nothing here can charge a customer, run a provider call, or activate billing.

-- ---------- allowance config (EMPTY = no invented values) ----------
CREATE TABLE IF NOT EXISTS public.discovery_credit_allowance (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_code           text,                -- NULL = applies to any active plan; else matches account_entitlement.plan_code
  credits_per_period  integer NOT NULL CHECK (credits_per_period >= 0),
  source              text NOT NULL DEFAULT 'SUBSCRIPTION' CHECK (source = 'SUBSCRIPTION'),  -- beta: subscription-only, no packs
  active              boolean NOT NULL DEFAULT false,
  note                text,
  created_at          timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.discovery_credit_allowance ENABLE ROW LEVEL SECURITY;  -- founder/service-role config only; no tenant access
-- intentionally EMPTY: no allowance is invented. Founder inserts an active row to activate (D2).

-- GRANT idempotency: a given subscription period grants at most one allowance per tenant (no double-credit on
-- re-invocation or concurrent calls).
CREATE UNIQUE INDEX IF NOT EXISTS uq_dcl_grant_idem
  ON public.discovery_credit_ledger(tenant_id, idempotency_key)
  WHERE entry_type='GRANT' AND idempotency_key IS NOT NULL;

-- ---------- grant (idempotent per subscription period; fail-closed) ----------
-- Self-service: an authenticated customer claims the credits their ACTIVE subscription includes for the CURRENT
-- period. Idempotent per (tenant, plan, period) via the ledger idempotency_key, so repeated calls (e.g. each
-- time the Refresh modal opens) never double-grant. No active subscription OR no configured allowance => grants
-- nothing (fail-closed). Reuses the existing entitlement contract (fn_entitlement_active); invents no amounts.
CREATE OR REPLACE FUNCTION public.fn_discovery_grant_subscription_credits()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_ent public.account_entitlement;
  v_credits int;
  v_period text;
  v_idem text;
  v_rows int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','UNAUTHENTICATED','contract','pulse_discovery_credit_grant_v1');
  END IF;
  -- the customer's active subscription (most recent active row)
  SELECT * INTO v_ent FROM public.account_entitlement e
   WHERE e.auth_user_id = v_uid AND public.fn_entitlement_active(e.status, e.current_period_end)
   ORDER BY e.current_period_end DESC NULLS LAST, e.updated_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','ok','granted',false,'reason','NO_ACTIVE_SUBSCRIPTION',
      'balance',public.fn_discovery_credit_balance(),'contract','pulse_discovery_credit_grant_v1');
  END IF;
  -- configured allowance for this plan (plan-specific wins over the NULL default); none => fail-closed no-op
  SELECT credits_per_period INTO v_credits FROM public.discovery_credit_allowance
   WHERE active AND (plan_code = v_ent.plan_code OR plan_code IS NULL)
   ORDER BY (plan_code = v_ent.plan_code) DESC LIMIT 1;
  IF v_credits IS NULL THEN
    RETURN jsonb_build_object('status','ok','granted',false,'reason','ALLOWANCE_NOT_CONFIGURED',
      'balance',public.fn_discovery_credit_balance(),'contract','pulse_discovery_credit_grant_v1');
  END IF;
  -- one grant per subscription PERIOD (resets each period); perpetual entitlements grant once
  v_period := coalesce(to_char(v_ent.current_period_end,'YYYYMMDD"T"HH24MISS'), 'perpetual:'||v_ent.id::text);
  v_idem := 'subscription:'||coalesce(v_ent.plan_code,'_')||':'||v_period;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text,42));
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,idempotency_key,reason)
    VALUES (v_uid,'GRANT',v_credits,v_idem,'subscription_allowance '||coalesce(v_ent.plan_code,'_')||' '||v_period)
  ON CONFLICT (tenant_id, idempotency_key) WHERE (entry_type='GRANT' AND idempotency_key IS NOT NULL) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;   -- 1 = newly granted this period, 0 = already granted (idempotent)
  RETURN jsonb_build_object('status','ok','granted',(v_rows > 0),'credits_per_period',v_credits,'plan',v_ent.plan_code,
    'period',v_period,'balance',public.fn_discovery_credit_balance(),'contract','pulse_discovery_credit_grant_v1');
END; $fn$;

GRANT EXECUTE ON FUNCTION public.fn_discovery_grant_subscription_credits() TO authenticated;

-- Rollback: see mig_341c_ROLLBACK.sql

-- =====================================================================
-- phase08_billing_rls_lockdown_remediation
-- =====================================================================
-- TARGET PROJECT: strateloq-billing-staging  (ref: nlfkwrjmhxbubtlwepwx)  ONLY.
-- DO NOT apply to production (Strateloq Technologies, ref: nxaunmyihhjixxxljcqt).
--
-- Remediates Supabase Security Advisor finding:
--   * rls_disabled_in_public (ERROR) on public.member  -- the P0
-- and closes grant drift on public.account_entitlement (Supabase default
-- broad anon/authenticated DML grants that contradict the entitlement
-- contract), and reasserts deny-all on public.billing_plan / public.billing_event.
--
-- Root cause: public.member was created without ENABLE ROW LEVEL SECURITY and
-- retained PostgREST's default broad grants to anon + authenticated, so anyone
-- holding the anon key could read/insert/update/delete/truncate member PII.
-- public.account_entitlement kept the same default broad grants (dormant only
-- because RLS-with-no-policy currently denies them). billing_event / billing_plan
-- were already correctly locked to service_role.
--
-- Security model REUSED from established Strateloq conventions (no invention):
--   * public.member            -> production convention
--       (dr/schema/rls_enable.sql + dr/schema/policies.sql):
--       RLS enabled; authenticated may SELECT ONLY their own row
--       (auth.uid() = auth_user_id) via policy member_select_own; all writes
--       performed by service_role / edge functions (service_role bypasses RLS).
--   * billing tables           -> mig_239_paid_entitlement_foundation convention:
--       RLS "deny-all" to clients; read/write ONLY via service_role and the
--       SECURITY DEFINER billing RPCs (fn_billing_list_plans / _create_checkout_intent
--       / _portal_intent / _apply_event). No direct client table grants, no policy.
--
-- The 3 authenticated-executable SECURITY DEFINER billing RPCs are intentionally
-- left callable by `authenticated` (they are self-scoped via auth.uid() and are the
-- designed customer billing API, per the mig_229 "execute grants lockdown" pattern).
--
-- Properties: idempotent, reversible, additive. No data deleted, no columns/types
-- changed. service_role and backend operations preserved (rolbypassrls = true).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. public.member  (fixes rls_disabled_in_public ERROR) -- production parity
-- ---------------------------------------------------------------------
ALTER TABLE public.member ENABLE ROW LEVEL SECURITY;

-- Least privilege: strip Supabase default broad grants; re-grant ONLY SELECT to
-- authenticated (row scope enforced by member_select_own below). anon gets nothing.
REVOKE ALL ON public.member FROM anon, authenticated, PUBLIC;
GRANT  SELECT ON public.member TO authenticated;

-- Narrowly scoped: an authenticated user may read ONLY their own member row.
DROP POLICY IF EXISTS member_select_own ON public.member;
CREATE POLICY member_select_own ON public.member
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (auth.uid() = auth_user_id);

COMMENT ON TABLE public.member IS
  'Member identity/profile (PII). RLS enabled. authenticated may SELECT only their own '
  'row (auth.uid()=auth_user_id) via policy member_select_own; all writes performed by '
  'service_role / edge functions (bypasses RLS). anon has no access. Mirrors production '
  'member RLS convention (dr/schema/policies.sql: member_select_own).';

-- ---------------------------------------------------------------------
-- 2. public.account_entitlement  (close grant drift) -- mig_239 parity
-- ---------------------------------------------------------------------
ALTER TABLE public.account_entitlement ENABLE ROW LEVEL SECURITY;  -- already on; idempotent
-- Remove Supabase default anon/authenticated DML grants that contradict the
-- entitlement contract. No policy => deny-all to clients. Access via SECURITY
-- DEFINER billing RPCs + service_role only.
REVOKE ALL ON public.account_entitlement FROM anon, authenticated, PUBLIC;

COMMENT ON TABLE public.account_entitlement IS
  'Authoritative paid-access entitlement (one row per auth_user_id). RLS deny-all to '
  'clients; read/written only by service_role / SECURITY DEFINER billing RPCs (never the '
  'browser). Provider-neutral. Reinstated per mig_239_paid_entitlement_foundation convention.';

-- ---------------------------------------------------------------------
-- 3. public.billing_plan / public.billing_event  (reassert deny-all; idempotent)
-- ---------------------------------------------------------------------
ALTER TABLE public.billing_plan  ENABLE ROW LEVEL SECURITY;  -- already on; idempotent
ALTER TABLE public.billing_event ENABLE ROW LEVEL SECURITY;  -- already on; idempotent
REVOKE ALL ON public.billing_plan  FROM anon, authenticated, PUBLIC;  -- defense in depth
REVOKE ALL ON public.billing_event FROM anon, authenticated, PUBLIC;  -- defense in depth

COMMENT ON TABLE public.billing_plan IS
  'Plan catalog. RLS deny-all to clients; exposed to authenticated only through the '
  'SECURITY DEFINER fn_billing_list_plans(). No direct client table access.';
COMMENT ON TABLE public.billing_event IS
  'Provider webhook event ledger (idempotency + audit). RLS deny-all to clients; written '
  'only by service_role via SECURITY DEFINER fn_billing_apply_event(). No client table access.';

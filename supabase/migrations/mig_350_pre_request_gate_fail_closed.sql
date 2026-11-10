-- mig_350_pre_request_gate_fail_closed.sql
-- SECURITY FIX: fn_pre_request_gate previously failed OPEN on any internal error.
-- For a protected authorization gate that is wrong: an unexpected authorization-state
-- error must not grant access to protected workspace operations.
--
-- New policy — fail CLOSED for protected operations, never for legitimate non-workspace flows:
--   1. Classify the always-allowed cases FIRST, using only cheap/NULL-safe reads that cannot
--      depend on onboarding state: non-/rpc/ paths (tables → RLS), the onboarding/recovery/
--      status allowlist, and the anon / service_role principals. These can never be locked out.
--   2. Anything else is a PROTECTED workspace RPC by an authenticated (or unknown-role) caller.
--      It is allowed ONLY on a DEFINITE "enforcement is off" OR a DEFINITE "onboarding complete".
--      Any uncertainty — unreadable policy, missing/malformed claims, null uid, or an errored
--      onboarding lookup — DENIES (42501). The gate therefore cannot be bypassed by inducing an error.
-- This is not a blanket deny: public endpoints, onboarding/recovery, auth (a separate service) and
-- service-role operations are allowed before any failure-prone lookup, so existing users and jobs
-- are never locked out. The gate remains a no-op while enforcement_active = FALSE.

CREATE OR REPLACE FUNCTION public.fn_pre_request_gate()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_path     text;
  v_fname    text;
  v_role     text;
  v_uid      uuid;
  v_enf      boolean;
  v_complete boolean;
  c_allow constant text[] := ARRAY[
    'fn_workspace_access','fn_entitlement_status',
    'fn_ensure_member_business_profile','get_own_business_profile','save_business_profile',
    'get_own_billing_profile','save_billing_profile','confirm_membership',
    'get_own_notifications','mark_notification_read','mark_all_notifications_read',
    'fn_global_intelligence_uid'
  ];
BEGIN
  -- ---- 1. ALWAYS-ALLOWED classification (cheap, NULL-safe, no onboarding-state dependency) ----
  v_path := current_setting('request.path', true);          -- NULL-safe; no throw
  IF v_path IS NULL OR position('/rpc/' in v_path) = 0 THEN
    RETURN;                                                  -- not an RPC (tables → RLS)
  END IF;
  v_fname := regexp_replace(regexp_replace(v_path, '^.*/rpc/', ''), '[?/].*$', '');
  IF v_fname = ANY (c_allow) THEN
    RETURN;                                                  -- onboarding / recovery / status → allow
  END IF;

  -- Role: positively-public / privileged principals are allowed. Defensive: on any error the
  -- role is unknown and the request is treated as protected (fail closed), never allowed.
  BEGIN
    v_role := coalesce(
      nullif(current_setting('request.jwt.claim.role', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'));
  EXCEPTION WHEN OTHERS THEN
    v_role := NULL;
  END;
  IF v_role IN ('anon','service_role') THEN
    RETURN;                                                  -- not an end-user member → allow
  END IF;

  -- ---- 2. PROTECTED: non-allowlisted /rpc/ by an authenticated (or unknown-role) caller. ----
  -- Allowed ONLY on a definite "disarmed" or a definite "onboarding complete".
  BEGIN
    SELECT enforcement_active INTO v_enf FROM public.onboarding_policy WHERE id;
  EXCEPTION WHEN OTHERS THEN
    v_enf := NULL;                                           -- unreadable → treat as enforcing
  END;
  IF v_enf IS FALSE THEN
    RETURN;                                                  -- gate definitely disarmed → allow
  END IF;

  -- Enforcement is ON (or its state is unreadable): require a DEFINITE onboarding-complete.
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    v_uid := NULL;
  END;
  IF v_uid IS NOT NULL THEN
    BEGIN
      v_complete := public.fn_onboarding_complete(v_uid);
    EXCEPTION WHEN OTHERS THEN
      v_complete := NULL;
    END;
    IF v_complete IS TRUE THEN
      RETURN;                                                -- definitely onboarded → allow
    END IF;
  END IF;

  -- Fail CLOSED: protected op, and onboarding could not be positively confirmed.
  RAISE EXCEPTION 'onboarding_incomplete'
    USING ERRCODE = '42501',
          HINT = 'Complete member onboarding (business profile, billing profile, membership confirmation) to access the workspace.';
END; $function$;

REVOKE ALL ON FUNCTION public.fn_pre_request_gate() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_pre_request_gate() TO authenticated, anon, service_role;

COMMENT ON FUNCTION public.fn_pre_request_gate() IS
  'PostgREST db-pre-request onboarding gate. No-op unless onboarding_policy.enforcement_active. '
  'Allows public/onboarding/recovery/status + anon/service_role before any state lookup; for any '
  'other /rpc/ call it FAILS CLOSED — allowed only on a definite disarmed flag or definite '
  'onboarding-complete. Protects the PostgREST Data API only (RPC via this gate, tables via RLS); '
  'Supabase Auth and Edge Functions are separate entry paths it does not cover.';

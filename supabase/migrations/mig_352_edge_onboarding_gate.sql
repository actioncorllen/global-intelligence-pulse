-- mig_352_edge_onboarding_gate.sql
-- SECURITY: single decision authority for Edge Function onboarding enforcement.
--
-- Edge Functions perform protected customer workspace operations with the SERVICE ROLE
-- internally, so neither RLS nor the PostgREST pre-request gate (fn_pre_request_gate)
-- covers their database work. Each protected edge now asks THIS function whether the
-- authenticated caller may proceed, instead of trusting frontend routing.
--
-- Decision (mirrors the fail-closed semantics approved in mig_350/351):
--   * enforcement_active definitely FALSE  -> TRUE  (strict no-op: behaviour today unchanged)
--   * else: only a DEFINITE fn_onboarding_complete(uid) = true -> TRUE
--   * NULL uid, unreadable policy, or any internal error        -> FALSE (fail closed)
--
-- service_role-only EXECUTE: this is for server-side (edge) callers; end-user requests
-- are governed by fn_pre_request_gate. anon/authenticated can neither call nor probe it.
-- Deployed while enforcement_active = FALSE, it changes nothing in production.

CREATE OR REPLACE FUNCTION public.fn_edge_onboarding_allowed(p_auth_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_enf      boolean;
  v_complete boolean;
BEGIN
  BEGIN
    SELECT enforcement_active INTO v_enf FROM public.onboarding_policy WHERE id;
  EXCEPTION WHEN OTHERS THEN
    v_enf := NULL;                             -- unreadable -> treat as enforcing
  END;
  IF v_enf IS FALSE THEN
    RETURN true;                               -- definitely disarmed -> allow (no-op parity)
  END IF;
  IF p_auth_user_id IS NULL THEN
    RETURN false;                              -- protected op, unknown member -> deny
  END IF;
  BEGIN
    v_complete := public.fn_onboarding_complete(p_auth_user_id);
  EXCEPTION WHEN OTHERS THEN
    v_complete := NULL;                        -- errored lookup -> deny
  END;
  RETURN v_complete IS TRUE;
END; $function$;

REVOKE ALL ON FUNCTION public.fn_edge_onboarding_allowed(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_edge_onboarding_allowed(uuid) TO service_role;

COMMENT ON FUNCTION public.fn_edge_onboarding_allowed(uuid) IS
  'Edge Function onboarding gate (service_role only). TRUE only when onboarding enforcement is '
  'definitely OFF (onboarding_policy.enforcement_active = FALSE) or the member''s onboarding is '
  'definitely complete (fn_onboarding_complete). Fails CLOSED (FALSE) on NULL uid, unreadable '
  'policy, or any error. Protected customer-workspace Edge Functions call this after resolving '
  'the caller''s JWT; it is a strict no-op (always TRUE) while enforcement is OFF.';

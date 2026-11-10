-- mig_346_ROLLBACK.sql
-- Reverts mig_346_mandatory_onboarding_gate.sql.
-- Restores fn_workspace_access to its pre-mig_346 behaviour (the original 5-signal
-- state machine), drops the new onboarding functions/tables, and the member column.
-- Billing profiles / policy rows are dropped with their tables (no other table depends on them).

-- Restore the original fn_workspace_access (pre-mig_346).
CREATE OR REPLACE FUNCTION public.fn_workspace_access()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_member_id uuid; v_verified boolean := false;
  v_has boolean := false; v_active boolean := false; v_ready boolean := false;
  v_plan text; v_estatus text; v_state text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('access_state', public.fn_access_state(false,false,false,false,false),
                              'authenticated', false);
  END IF;
  SELECT m.id, (coalesce((SELECT au.email_confirmed_at IS NOT NULL FROM auth.users au WHERE au.id=v_uid), false)
                OR coalesce(m.email_verified,false))
    INTO v_member_id, v_verified
  FROM public.member m WHERE m.auth_user_id = v_uid;
  IF v_member_id IS NULL THEN
    RETURN jsonb_build_object('access_state', public.fn_access_state(true, v_verified, false, false, false),
                              'authenticated', true, 'note','no member record');
  END IF;
  SELECT true, public.fn_entitlement_active(e.status, e.current_period_end), e.plan_code, e.status
    INTO v_has, v_active, v_plan, v_estatus
  FROM public.account_entitlement e WHERE e.auth_user_id = v_uid;
  v_has := coalesce(v_has, false); v_active := coalesce(v_active, false);
  SELECT (ds.analysis_status = 'ready') INTO v_ready
  FROM public.discovery_state ds WHERE ds.member_id = v_member_id;
  v_ready := coalesce(v_ready, false);
  v_state := public.fn_access_state(true, v_verified, v_has, v_active, v_ready);
  RETURN jsonb_build_object('access_state', v_state,'authenticated', true,'email_verified', v_verified,
    'has_entitlement', v_has,'entitlement_active', v_active,'plan_code', v_plan,
    'entitlement_status', v_estatus,'workspace_ready', v_ready);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_workspace_access() TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.confirm_membership();
DROP FUNCTION IF EXISTS public.save_billing_profile(jsonb,boolean);
DROP FUNCTION IF EXISTS public.get_own_billing_profile();
DROP FUNCTION IF EXISTS public.fn_workspace_entry_allowed(uuid);
DROP FUNCTION IF EXISTS public.fn_member_onboarding_state(uuid);
ALTER TABLE public.member DROP COLUMN IF EXISTS membership_confirmed_at;
DROP TABLE IF EXISTS public.billing_profile;
DROP TABLE IF EXISTS public.onboarding_policy;

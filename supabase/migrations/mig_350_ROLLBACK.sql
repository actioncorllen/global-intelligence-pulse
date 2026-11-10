-- mig_350_ROLLBACK.sql
-- Restores the mig_348 version of fn_pre_request_gate (which FAILS OPEN on error).
-- WARNING: that version is the security-weaker behaviour mig_350 corrected; only roll back
-- if mig_350 itself is faulty, and prefer fixing forward.
CREATE OR REPLACE FUNCTION public.fn_pre_request_gate()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_block boolean := false; v_enf boolean; v_role text; v_uid uuid; v_path text; v_fname text;
  c_allow constant text[] := ARRAY[
    'fn_workspace_access','fn_entitlement_status',
    'fn_ensure_member_business_profile','get_own_business_profile','save_business_profile',
    'get_own_billing_profile','save_billing_profile','confirm_membership',
    'get_own_notifications','mark_notification_read','mark_all_notifications_read',
    'fn_global_intelligence_uid'];
BEGIN
  BEGIN
    SELECT enforcement_active INTO v_enf FROM public.onboarding_policy WHERE id;
    IF NOT coalesce(v_enf,false) THEN RETURN; END IF;
    v_role := coalesce(nullif(current_setting('request.jwt.claim.role', true),''),
                       (nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role'));
    IF v_role IS DISTINCT FROM 'authenticated' THEN RETURN; END IF;
    v_uid := auth.uid();
    IF v_uid IS NULL THEN RETURN; END IF;
    v_path := coalesce(current_setting('request.path', true), '');
    IF position('/rpc/' in v_path) = 0 THEN RETURN; END IF;
    v_fname := regexp_replace(v_path, '^.*/rpc/', '');
    v_fname := regexp_replace(v_fname, '[?/].*$', '');
    IF v_fname = ANY (c_allow) THEN RETURN; END IF;
    IF public.fn_onboarding_complete(v_uid) THEN RETURN; END IF;
    v_block := true;
  EXCEPTION WHEN OTHERS THEN
    v_block := false;
  END;
  IF v_block THEN
    RAISE EXCEPTION 'onboarding_incomplete' USING ERRCODE = '42501',
      HINT = 'Complete member onboarding (business profile, billing profile, membership confirmation) to access the workspace.';
  END IF;
END; $function$;

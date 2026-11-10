-- mig_351_ROLLBACK.sql — restores the mig_350 gate (RPC-only; tables left to RLS).
-- WARNING: that version does NOT enforce onboarding on direct table access (the bypass mig_351
-- closed). Prefer fixing forward. Unwire first if needed:
--   ALTER ROLE authenticator RESET pgrst.db_pre_request; NOTIFY pgrst, 'reload config';
CREATE OR REPLACE FUNCTION public.fn_pre_request_gate()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_path text; v_fname text; v_role text; v_uid uuid; v_enf boolean; v_complete boolean;
  c_allow constant text[] := ARRAY[
    'fn_workspace_access','fn_entitlement_status',
    'fn_ensure_member_business_profile','get_own_business_profile','save_business_profile',
    'get_own_billing_profile','save_billing_profile','confirm_membership',
    'get_own_notifications','mark_notification_read','mark_all_notifications_read',
    'fn_global_intelligence_uid'];
BEGIN
  v_path := current_setting('request.path', true);
  IF v_path IS NULL OR position('/rpc/' in v_path) = 0 THEN RETURN; END IF;
  v_fname := regexp_replace(regexp_replace(v_path, '^.*/rpc/', ''), '[?/].*$', '');
  IF v_fname = ANY (c_allow) THEN RETURN; END IF;
  BEGIN
    v_role := coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'));
  EXCEPTION WHEN OTHERS THEN v_role := NULL; END;
  IF v_role IN ('anon','service_role') THEN RETURN; END IF;
  BEGIN SELECT enforcement_active INTO v_enf FROM public.onboarding_policy WHERE id;
  EXCEPTION WHEN OTHERS THEN v_enf := NULL; END;
  IF v_enf IS FALSE THEN RETURN; END IF;
  BEGIN v_uid := auth.uid(); EXCEPTION WHEN OTHERS THEN v_uid := NULL; END;
  IF v_uid IS NOT NULL THEN
    BEGIN v_complete := public.fn_onboarding_complete(v_uid); EXCEPTION WHEN OTHERS THEN v_complete := NULL; END;
    IF v_complete IS TRUE THEN RETURN; END IF;
  END IF;
  RAISE EXCEPTION 'onboarding_incomplete' USING ERRCODE = '42501',
    HINT = 'Complete member onboarding (business profile, billing profile, membership confirmation) to access the workspace.';
END; $function$;

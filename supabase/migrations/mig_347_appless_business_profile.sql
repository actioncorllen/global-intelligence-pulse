-- mig_347_appless_business_profile.sql
-- Stage 1 of mandatory onboarding completion: let application-less members
-- (open/direct-invite members with member.application_ref = NULL, e.g. the pilot
-- account) complete the EXISTING business-profile flow.
--
-- Approach (reuses the established architecture with ZERO change to the 200-line
-- save_business_profile / get_own_business_profile): a new idempotent RPC lazily
-- links an application-less member to a clearly-marked backfill founding_application
-- + an owned business_profiles row. After it runs the member is application-linked,
-- so the unchanged save/get flow works. Applicant (application-linked) members are
-- untouched. The frontend BUSINESS PROFILE step calls this once before get/save.

CREATE OR REPLACE FUNCTION public.fn_ensure_member_business_profile()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid     uuid := auth.uid();
  v_member  public.member%ROWTYPE;
  v_app     uuid;
  v_app_new uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;

  SELECT * INTO v_member FROM public.member WHERE auth_user_id = v_uid;   -- identity from auth.uid()
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_member'); END IF;

  -- Serialize per member so concurrent calls cannot create duplicate backfills.
  PERFORM 1 FROM public.member WHERE id = v_member.id FOR UPDATE;
  SELECT application_ref INTO v_app FROM public.member WHERE id = v_member.id;

  IF v_app IS NOT NULL THEN
    -- Already application-linked (normal applicant). The approval step created the
    -- business profile; never touch an existing application-linked profile.
    RETURN jsonb_build_object('status','ok','mode','application_linked','application_ref',v_app);
  END IF;

  -- Application-less member: create a clearly-marked backfill application (status
  -- 'accepted' so it never appears in the issuable 'new' queue) + an owned business
  -- profile, then link the member. Cross-tenant safe (keyed to this auth.uid()).
  INSERT INTO public.founding_applications (first_name, last_name, work_email, status, source)
  VALUES ('Direct', 'Member', coalesce(v_member.email,'unknown@direct.invalid'),
          'accepted', 'direct_invite_backfill')
  RETURNING id INTO v_app_new;

  INSERT INTO public.business_profiles (application_id, user_id, country)
  VALUES (v_app_new, v_uid, NULL);

  UPDATE public.member SET application_ref = v_app_new, updated_at = now() WHERE id = v_member.id;

  RETURN jsonb_build_object('status','ok','mode','backfilled','application_ref',v_app_new);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status','temporary_failure');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_ensure_member_business_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_ensure_member_business_profile() TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_ensure_member_business_profile() IS
  'Stage 1 onboarding: idempotently links an application-less member to a backfill '
  'founding_application + owned business_profiles row so the existing save/get '
  'business-profile flow works. No-op for application-linked members.';

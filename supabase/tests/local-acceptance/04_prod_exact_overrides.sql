-- 04_prod_exact_overrides.sql — replaces 10 functions with the EXACT production
-- pg_get_functiondef text (2026-11-10 read-only fetch), so md5(pg_get_functiondef)
-- matches production byte-for-byte. Semantics were already equivalent; this removes
-- comment/whitespace drift between repo files and prod-applied text.

CREATE OR REPLACE FUNCTION public.confirm_membership()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_member public.member%ROWTYPE; v_bp_done boolean; v_bill_done boolean; v_active boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO v_member FROM public.member WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_member'); END IF;
  IF v_member.membership_confirmed_at IS NOT NULL THEN RETURN jsonb_build_object('status','ok','outcome','already_confirmed'); END IF;
  v_bp_done := EXISTS (SELECT 1 FROM public.discovery_state ds WHERE ds.member_id=v_member.id AND ds.status='complete');
  v_bill_done := EXISTS (SELECT 1 FROM public.billing_profile b WHERE b.auth_user_id=v_uid AND b.completed_at IS NOT NULL);
  v_active := coalesce((SELECT public.fn_entitlement_active(e.status,e.current_period_end) FROM public.account_entitlement e WHERE e.auth_user_id=v_uid), false);
  IF NOT v_active THEN RETURN jsonb_build_object('status','blocked','reason','no_active_membership'); END IF;
  IF NOT v_bp_done THEN RETURN jsonb_build_object('status','blocked','reason','business_profile_incomplete'); END IF;
  IF NOT v_bill_done THEN RETURN jsonb_build_object('status','blocked','reason','billing_profile_incomplete'); END IF;
  UPDATE public.member SET membership_confirmed_at = now(), updated_at = now() WHERE id = v_member.id;
  RETURN jsonb_build_object('status','ok','outcome','confirmed','confirmed_at', now());
END; $function$;

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
  SELECT * INTO v_member FROM public.member WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_member'); END IF;
  PERFORM 1 FROM public.member WHERE id = v_member.id FOR UPDATE;
  SELECT application_ref INTO v_app FROM public.member WHERE id = v_member.id;
  IF v_app IS NOT NULL THEN
    RETURN jsonb_build_object('status','ok','mode','application_linked','application_ref',v_app);
  END IF;
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

CREATE OR REPLACE FUNCTION public.fn_member_onboarding_state(p_auth_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  p public.onboarding_policy%ROWTYPE; v_member public.member%ROWTYPE;
  v_verified boolean := false; v_bp_done boolean := false; v_bill_done boolean := false;
  v_has boolean := false; v_active boolean := false; v_confirmed boolean := false; v_ready boolean := false;
  v_plan text; v_estatus text; v_state text;
BEGIN
  SELECT * INTO p FROM public.onboarding_policy WHERE id;
  IF p_auth_user_id IS NULL THEN
    RETURN jsonb_build_object('access_state','AUTH_REQUIRED','authenticated',false,
      'onboarding_enforced', coalesce(p.enforcement_active,false));
  END IF;
  SELECT * INTO v_member FROM public.member WHERE auth_user_id = p_auth_user_id;
  IF NOT FOUND THEN
    v_verified := coalesce((SELECT au.email_confirmed_at IS NOT NULL FROM auth.users au WHERE au.id=p_auth_user_id), false);
    RETURN jsonb_build_object(
      'access_state', CASE WHEN NOT v_verified THEN 'EMAIL_VERIFICATION_REQUIRED' ELSE 'ENTITLEMENT_REQUIRED' END,
      'authenticated', true, 'email_verified', v_verified, 'note','no member record',
      'onboarding_enforced', coalesce(p.enforcement_active,false));
  END IF;
  v_verified := coalesce((SELECT au.email_confirmed_at IS NOT NULL FROM auth.users au WHERE au.id=p_auth_user_id), false)
                OR coalesce(v_member.email_verified,false);
  v_bp_done := EXISTS (SELECT 1 FROM public.discovery_state ds WHERE ds.member_id = v_member.id AND ds.status = 'complete');
  v_bill_done := EXISTS (SELECT 1 FROM public.billing_profile b WHERE b.auth_user_id = p_auth_user_id AND b.completed_at IS NOT NULL);
  SELECT true, public.fn_entitlement_active(e.status, e.current_period_end), e.plan_code, e.status
    INTO v_has, v_active, v_plan, v_estatus
  FROM public.account_entitlement e WHERE e.auth_user_id = p_auth_user_id;
  v_has := coalesce(v_has,false); v_active := coalesce(v_active,false);
  v_confirmed := v_member.membership_confirmed_at IS NOT NULL;
  v_ready := coalesce((SELECT ds.analysis_status='ready' FROM public.discovery_state ds WHERE ds.member_id=v_member.id), false);
  v_state := CASE
    WHEN NOT v_verified THEN 'EMAIL_VERIFICATION_REQUIRED'
    WHEN p.enforcement_active AND p.require_business_profile       AND NOT v_bp_done   THEN 'BUSINESS_PROFILE_REQUIRED'
    WHEN p.enforcement_active AND p.require_billing_profile        AND NOT v_bill_done THEN 'BILLING_PROFILE_REQUIRED'
    WHEN NOT v_has    THEN 'ENTITLEMENT_REQUIRED'
    WHEN NOT v_active THEN 'ENTITLEMENT_INACTIVE'
    WHEN p.enforcement_active AND p.require_membership_confirmation AND NOT v_confirmed THEN 'MEMBERSHIP_CONFIRMATION_REQUIRED'
    WHEN NOT v_ready  THEN 'WORKSPACE_PREPARING'
    ELSE 'READY'
  END;
  RETURN jsonb_build_object('access_state', v_state,'authenticated', true,'email_verified', v_verified,
    'business_profile_complete', v_bp_done,'billing_profile_complete', v_bill_done,
    'has_entitlement', v_has,'entitlement_active', v_active,'plan_code', v_plan,
    'entitlement_status', v_estatus,'membership_confirmed', v_confirmed,'workspace_ready', v_ready,
    'onboarding_enforced', coalesce(p.enforcement_active,false));
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_pre_request_gate()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_enf boolean; v_role text; v_path text; v_p text; v_first text; v_fname text;
  v_is_rpc boolean := false; v_allowed boolean := false; v_uid uuid; v_complete boolean;
  c_rpc_allow constant text[] := ARRAY[
    'fn_workspace_access','fn_entitlement_status',
    'fn_ensure_member_business_profile','get_own_business_profile','save_business_profile',
    'get_own_billing_profile','save_billing_profile','confirm_membership',
    'get_own_notifications','mark_notification_read','mark_all_notifications_read',
    'fn_global_intelligence_uid'];
  c_tbl_allow constant text[] := ARRAY[
    'member','users','business_profiles','billing_profile','discovery_state','pulse_notifications',
    'business_category','build_updates','roadmap_items','opportunities',
    'conversion_hero_variants','conversion_section_types','conversion_template_families',
    'creative_format_registry','provider_capability_registry',
    'analytics_events','engagement_patterns','demo_events','pulse_guide_events'];
BEGIN
  BEGIN SELECT enforcement_active INTO v_enf FROM public.onboarding_policy WHERE id;
  EXCEPTION WHEN OTHERS THEN v_enf := NULL; END;
  IF v_enf IS FALSE THEN RETURN; END IF;

  BEGIN
    v_role := coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'));
  EXCEPTION WHEN OTHERS THEN v_role := NULL; END;
  IF v_role IN ('anon','service_role') THEN RETURN; END IF;

  v_path := coalesce(current_setting('request.path', true), '');
  v_p := regexp_replace(v_path, '^/+', '');
  v_p := regexp_replace(v_p, '^rest/v1/', '');
  v_first := regexp_replace(v_p, '[/?].*$', '');
  IF v_first = 'rpc' THEN
    v_is_rpc := true;
    v_fname := regexp_replace(regexp_replace(v_p, '^rpc/', ''), '[?/].*$', '');
  END IF;

  IF v_is_rpc THEN v_allowed := (v_fname = ANY (c_rpc_allow));
  ELSE v_allowed := (v_first = ANY (c_tbl_allow)); END IF;
  IF v_allowed THEN RETURN; END IF;

  BEGIN v_uid := auth.uid(); EXCEPTION WHEN OTHERS THEN v_uid := NULL; END;
  IF v_uid IS NOT NULL THEN
    BEGIN v_complete := public.fn_onboarding_complete(v_uid); EXCEPTION WHEN OTHERS THEN v_complete := NULL; END;
    IF v_complete IS TRUE THEN RETURN; END IF;
  END IF;

  RAISE EXCEPTION 'onboarding_incomplete'
    USING ERRCODE = '42501',
          HINT = 'Complete member onboarding (business profile, billing profile, membership confirmation) to access the workspace.';
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_workspace_access()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ SELECT public.fn_member_onboarding_state(auth.uid()); $function$;

CREATE OR REPLACE FUNCTION public.fn_workspace_entry_allowed(p_auth_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ SELECT (public.fn_member_onboarding_state(p_auth_user_id) ->> 'access_state') = 'READY'; $function$;

CREATE OR REPLACE FUNCTION public.get_own_billing_profile()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); b public.billing_profile%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO b FROM public.billing_profile WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','ok','completed',false,'profile',NULL); END IF;
  RETURN jsonb_build_object('status','ok','completed', b.completed_at IS NOT NULL,
    'profile', jsonb_build_object('legal_name',b.legal_name,'billing_email',b.billing_email,'country',b.country,
      'address_line1',b.address_line1,'address_line2',b.address_line2,'city',b.city,'region',b.region,
      'postal_code',b.postal_code,'tax_id',b.tax_id,'is_business',b.is_business,
      'billing_kind',b.billing_kind,'currency',b.currency,'amount_minor',b.amount_minor));
END; $function$;

CREATE OR REPLACE FUNCTION public.mark_notification_read(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_n integer;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  UPDATE public.pulse_notifications SET read_at=now()
    WHERE id=p_id AND user_id=v_uid AND read_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('status','ok','updated',v_n);
END; $function$;

CREATE OR REPLACE FUNCTION public.save_billing_profile(p_content jsonb, p_complete boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_member public.member%ROWTYPE; v_kind text := 'COMP'; v_currency text;
  v_invalid text[] := ARRAY[]::text[]; k text;
  c_allowed constant text[] := ARRAY['legal_name','billing_email','country','address_line1','address_line2','city','region','postal_code','tax_id','is_business'];
  eff_name text; eff_email text; eff_country text;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF jsonb_typeof(p_content) IS DISTINCT FROM 'object' THEN RETURN jsonb_build_object('status','invalid','fields',jsonb_build_array('content')); END IF;
  FOR k IN SELECT jsonb_object_keys(p_content) LOOP
    IF k ~* '(card|cvv|cvc|pan|number|sort_code|iban|account_number|routing|secret|cvn)' THEN
      RETURN jsonb_build_object('status','rejected','reason','payment_credentials_not_accepted'); END IF;
    IF NOT (k = ANY(c_allowed)) THEN v_invalid := array_append(v_invalid,k); END IF;
  END LOOP;
  IF cardinality(v_invalid) > 0 THEN RETURN jsonb_build_object('status','invalid','fields',to_jsonb(v_invalid)); END IF;
  SELECT * INTO v_member FROM public.member WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_member'); END IF;
  SELECT CASE WHEN e.source='PROVIDER' THEN 'PAID' ELSE 'COMP' END, e.currency INTO v_kind, v_currency
    FROM public.account_entitlement e WHERE e.auth_user_id = v_uid;
  v_kind := coalesce(v_kind,'COMP');
  INSERT INTO public.billing_profile
    (auth_user_id, member_id, legal_name, billing_email, country, address_line1, address_line2, city, region, postal_code, tax_id, is_business, billing_plan_code, billing_kind, currency, amount_minor)
  VALUES (v_uid, v_member.id, nullif(btrim(p_content->>'legal_name'),''), nullif(btrim(p_content->>'billing_email'),''),
     nullif(btrim(p_content->>'country'),''), nullif(btrim(p_content->>'address_line1'),''), nullif(btrim(p_content->>'address_line2'),''),
     nullif(btrim(p_content->>'city'),''), nullif(btrim(p_content->>'region'),''), nullif(btrim(p_content->>'postal_code'),''),
     nullif(btrim(p_content->>'tax_id'),''), coalesce((p_content->>'is_business')::boolean, true),
     'ecommerce_monthly', v_kind, v_currency, 0)
  ON CONFLICT (auth_user_id) DO UPDATE SET
     member_id=EXCLUDED.member_id,
     legal_name=coalesce(EXCLUDED.legal_name, public.billing_profile.legal_name),
     billing_email=coalesce(EXCLUDED.billing_email, public.billing_profile.billing_email),
     country=coalesce(EXCLUDED.country, public.billing_profile.country),
     address_line1=coalesce(EXCLUDED.address_line1, public.billing_profile.address_line1),
     address_line2=coalesce(EXCLUDED.address_line2, public.billing_profile.address_line2),
     city=coalesce(EXCLUDED.city, public.billing_profile.city),
     region=coalesce(EXCLUDED.region, public.billing_profile.region),
     postal_code=coalesce(EXCLUDED.postal_code, public.billing_profile.postal_code),
     tax_id=coalesce(EXCLUDED.tax_id, public.billing_profile.tax_id),
     is_business=EXCLUDED.is_business, billing_kind=EXCLUDED.billing_kind, currency=EXCLUDED.currency,
     amount_minor=0, updated_at=now();
  IF p_complete THEN
    SELECT legal_name, billing_email, country INTO eff_name, eff_email, eff_country FROM public.billing_profile WHERE auth_user_id = v_uid;
    IF eff_name IS NULL THEN v_invalid := array_append(v_invalid,'legal_name'); END IF;
    IF eff_email IS NULL THEN v_invalid := array_append(v_invalid,'billing_email'); END IF;
    IF eff_country IS NULL THEN v_invalid := array_append(v_invalid,'country'); END IF;
    IF cardinality(v_invalid) > 0 THEN RETURN jsonb_build_object('status','invalid','fields',to_jsonb(v_invalid)); END IF;
    UPDATE public.billing_profile SET completed_at = coalesce(completed_at, now()), updated_at = now() WHERE auth_user_id = v_uid;
  END IF;
  RETURN jsonb_build_object('status','saved','completed',
    (SELECT completed_at IS NOT NULL FROM public.billing_profile WHERE auth_user_id=v_uid), 'billing_kind', v_kind, 'amount_minor', 0);
END; $function$;

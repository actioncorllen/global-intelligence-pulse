-- mig_359 — test/live payment-method separation + controlled live-card requirement
-- ----------------------------------------------------------------------------
-- Prepares (does NOT activate) genuine live-card acceptance. Stripe LIVE mode is not yet
-- configured on this account (details_submitted=false, charges_enabled=false, only a test
-- key, no live webhook) — collecting a real card is an external founder dependency. This
-- migration makes the registry distinguish TEST from LIVE cards and lets a future policy
-- REQUIRE a live card, so a sandbox test card can never satisfy a live-card requirement.
--
-- SAFETY: require_live_card defaults FALSE, so NOTHING changes today — the founder's existing
-- TEST card still satisfies card_enforcement (no lockout). Enabling require_live_card is a
-- SEPARATE founder decision that must come AFTER live mode is configured AND the founder has
-- registered a LIVE card (otherwise the founder would be locked out — proven in tests).
------------------------------------------------------------------------------

-- 1. Registry records whether a stored card is a LIVE or TEST payment method.
ALTER TABLE public.payment_method_registry
  ADD COLUMN IF NOT EXISTS livemode boolean NOT NULL DEFAULT false;
-- Existing rows (the founder's sandbox card) are correctly livemode=false (test).

-- 2. Policy flag: require a LIVE card to satisfy card enforcement (default OFF).
ALTER TABLE public.onboarding_policy
  ADD COLUMN IF NOT EXISTS require_live_card boolean NOT NULL DEFAULT false;

-- 3. Card-registration RPC captures livemode (the webhook passes event.livemode). Default
--    false keeps the currently-deployed webhook working until it is redeployed.
CREATE OR REPLACE FUNCTION public.fn_psp_card_registered(
  p_auth_user_id uuid, p_customer_ref text, p_pm_ref text,
  p_brand text, p_last4 text, p_exp_month integer, p_exp_year integer,
  p_livemode boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  IF p_auth_user_id IS NULL OR nullif(btrim(coalesce(p_pm_ref,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_customer_ref,'')),'') IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','BAD_ARGS');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.member m WHERE m.auth_user_id = p_auth_user_id) THEN
    RETURN jsonb_build_object('status','error','reason','NO_MEMBER');
  END IF;
  INSERT INTO public.payment_method_registry
    (auth_user_id, provider, provider_customer_ref, provider_payment_method_ref,
     brand, last4, exp_month, exp_year, status, livemode)
  VALUES (p_auth_user_id, 'STRIPE', btrim(p_customer_ref), btrim(p_pm_ref),
     nullif(btrim(coalesce(p_brand,'')),''), nullif(btrim(coalesce(p_last4,'')),''),
     p_exp_month, p_exp_year, 'ACTIVE', coalesce(p_livemode,false))
  ON CONFLICT (provider, provider_payment_method_ref) DO UPDATE SET
     auth_user_id = EXCLUDED.auth_user_id,
     provider_customer_ref = EXCLUDED.provider_customer_ref,
     brand = EXCLUDED.brand, last4 = EXCLUDED.last4,
     exp_month = EXCLUDED.exp_month, exp_year = EXCLUDED.exp_year,
     status = 'ACTIVE', livemode = EXCLUDED.livemode, updated_at = now();
  RETURN jsonb_build_object('status','ok','livemode', coalesce(p_livemode,false));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_psp_card_registered(uuid,text,text,text,text,integer,integer,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_psp_card_registered(uuid,text,text,text,text,integer,integer,boolean) TO service_role;

-- 4. State machine: the card gate counts a card only if (a) card enforcement wants one and
--    (b) it is a LIVE card when require_live_card is on. Byte-identical otherwise.
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
  v_card boolean := false;
  v_plan text; v_estatus text; v_state text;
  v_astatus text;
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
  v_card := EXISTS (SELECT 1 FROM public.payment_method_registry pm
                    WHERE pm.auth_user_id = p_auth_user_id AND pm.status = 'ACTIVE'
                      AND (NOT coalesce(p.require_live_card,false) OR pm.livemode = true));
  SELECT true, public.fn_entitlement_active(e.status, e.current_period_end), e.plan_code, e.status
    INTO v_has, v_active, v_plan, v_estatus
  FROM public.account_entitlement e WHERE e.auth_user_id = p_auth_user_id;
  v_has := coalesce(v_has,false); v_active := coalesce(v_active,false);
  v_confirmed := v_member.membership_confirmed_at IS NOT NULL;
  SELECT ds.analysis_status INTO v_astatus FROM public.discovery_state ds WHERE ds.member_id=v_member.id;
  v_ready := coalesce(v_astatus = 'ready', false);
  v_state := CASE
    WHEN NOT v_verified THEN 'EMAIL_VERIFICATION_REQUIRED'
    WHEN p.enforcement_active AND p.require_business_profile       AND NOT v_bp_done   THEN 'BUSINESS_PROFILE_REQUIRED'
    WHEN p.enforcement_active AND p.require_billing_profile        AND NOT v_bill_done THEN 'BILLING_PROFILE_REQUIRED'
    WHEN p.enforcement_active AND p.card_enforcement_active        AND NOT v_card      THEN 'CARD_SETUP_REQUIRED'
    WHEN NOT v_has    THEN 'ENTITLEMENT_REQUIRED'
    WHEN NOT v_active THEN 'ENTITLEMENT_INACTIVE'
    WHEN p.enforcement_active AND p.require_membership_confirmation AND NOT v_confirmed THEN 'MEMBERSHIP_CONFIRMATION_REQUIRED'
    ELSE 'READY'
  END;
  RETURN jsonb_build_object('access_state', v_state,'authenticated', true,'email_verified', v_verified,
    'business_profile_complete', v_bp_done,'billing_profile_complete', v_bill_done,
    'has_entitlement', v_has,'entitlement_active', v_active,'plan_code', v_plan,
    'entitlement_status', v_estatus,'membership_confirmed', v_confirmed,'workspace_ready', v_ready,
    'workspace_analysis_status', coalesce(v_astatus, 'none'),
    'onboarding_enforced', coalesce(p.enforcement_active,false))
    || CASE WHEN coalesce(p.card_enforcement_active,false)
            THEN jsonb_build_object('card_on_file', v_card, 'require_live_card', coalesce(p.require_live_card,false))
            ELSE '{}'::jsonb END;
END; $function$;

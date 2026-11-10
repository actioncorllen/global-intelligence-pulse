-- mig_346_mandatory_onboarding_gate.sql
-- Mandatory founding-member onboarding journey, enforced server-side:
--   LOGIN -> ACCOUNT VERIFICATION -> BUSINESS PROFILE -> BILLING PROFILE
--   -> MEMBERSHIP CONFIRMATION -> WORKSPACE.
--
-- SAFETY: the hard gate is armed by a founder-controlled flag
-- (onboarding_policy.enforcement_active, DEFAULT FALSE). With it OFF — the state
-- deployed here — fn_workspace_access returns EXACTLY the pre-existing states, so
-- deploying this migration changes NOTHING in production and cannot lock existing
-- members out. The founder flips the flag ON only once the onboarding UI and the
-- application-less business-profile path exist (see docs), at which point the new
-- steps are enforced for new AND existing members.
--
-- No billing architecture is created beyond a business billing profile. NO card
-- number, CVV, or payment credential is ever collected or stored here. Complimentary
-- (COMP) members are shown amount 0 and are never charged.

------------------------------------------------------------------------------
-- 1. Onboarding policy (singleton) + complimentary-allowance defaults
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.onboarding_policy (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  enforcement_active boolean NOT NULL DEFAULT false,         -- hard gate armed? DEFAULT OFF (safe)
  require_business_profile boolean NOT NULL DEFAULT true,
  require_billing_profile boolean NOT NULL DEFAULT true,
  require_membership_confirmation boolean NOT NULL DEFAULT true,
  comp_refresh_credits_per_period integer NOT NULL DEFAULT 10, -- founder-configurable complimentary cap
  comp_refresh_period text NOT NULL DEFAULT 'month',
  comp_provider_max_calls integer NOT NULL DEFAULT 10,         -- fail-closed provider-call cap default
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text
);
INSERT INTO public.onboarding_policy (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.onboarding_policy ENABLE ROW LEVEL SECURITY;  -- deny-all; read via SECURITY DEFINER fns, write via service role

------------------------------------------------------------------------------
-- 2. Billing profile (business billing info only; NEVER card/CVV/credentials)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_profile (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL UNIQUE,
  member_id uuid,
  legal_name text,
  billing_email text,
  country text,
  address_line1 text,
  address_line2 text,
  city text,
  region text,
  postal_code text,
  tax_id text,                                   -- VAT/tax id (business), optional
  is_business boolean NOT NULL DEFAULT true,
  billing_plan_code text NOT NULL DEFAULT 'ecommerce_monthly',
  billing_kind text NOT NULL DEFAULT 'COMP' CHECK (billing_kind IN ('COMP','PAID')),
  currency text,
  amount_minor integer NOT NULL DEFAULT 0,       -- 0 for COMP; paid amount set only by the payment provider path
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.billing_profile ENABLE ROW LEVEL SECURITY;  -- deny-all; access only via SECURITY DEFINER RPCs
COMMENT ON TABLE public.billing_profile IS
  'Business billing profile for membership. NEVER stores card numbers, CVV, or payment credentials; '
  'those belong only to the external payment provider hosted checkout. COMP members: amount_minor=0.';

------------------------------------------------------------------------------
-- 3. Membership confirmation marker on member
------------------------------------------------------------------------------
ALTER TABLE public.member ADD COLUMN IF NOT EXISTS membership_confirmed_at timestamptz;

------------------------------------------------------------------------------
-- 4. Authoritative onboarding state machine (single source of truth)
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_member_onboarding_state(p_auth_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  p            public.onboarding_policy%ROWTYPE;
  v_member     public.member%ROWTYPE;
  v_verified   boolean := false;
  v_bp_done    boolean := false;   -- business profile complete
  v_bill_done  boolean := false;   -- billing profile complete
  v_has        boolean := false;   -- has entitlement
  v_active     boolean := false;   -- entitlement active
  v_confirmed  boolean := false;   -- membership confirmed
  v_ready      boolean := false;   -- workspace (discovery) ready
  v_plan       text;
  v_estatus    text;
  v_state      text;
BEGIN
  SELECT * INTO p FROM public.onboarding_policy WHERE id;

  IF p_auth_user_id IS NULL THEN
    RETURN jsonb_build_object('access_state','AUTH_REQUIRED','authenticated',false,
      'onboarding_enforced', coalesce(p.enforcement_active,false));
  END IF;

  SELECT * INTO v_member FROM public.member WHERE auth_user_id = p_auth_user_id;
  IF NOT FOUND THEN
    -- authenticated but not provisioned: cannot enter workspace
    v_verified := coalesce((SELECT au.email_confirmed_at IS NOT NULL FROM auth.users au WHERE au.id=p_auth_user_id), false);
    RETURN jsonb_build_object(
      'access_state', CASE WHEN NOT v_verified THEN 'EMAIL_VERIFICATION_REQUIRED' ELSE 'ENTITLEMENT_REQUIRED' END,
      'authenticated', true, 'email_verified', v_verified, 'note','no member record',
      'onboarding_enforced', coalesce(p.enforcement_active,false));
  END IF;

  v_verified := coalesce((SELECT au.email_confirmed_at IS NOT NULL FROM auth.users au WHERE au.id=p_auth_user_id), false)
                OR coalesce(v_member.email_verified,false);

  v_bp_done := EXISTS (SELECT 1 FROM public.discovery_state ds
                       WHERE ds.member_id = v_member.id AND ds.status = 'complete');

  v_bill_done := EXISTS (SELECT 1 FROM public.billing_profile b
                         WHERE b.auth_user_id = p_auth_user_id AND b.completed_at IS NOT NULL);

  SELECT true, public.fn_entitlement_active(e.status, e.current_period_end), e.plan_code, e.status
    INTO v_has, v_active, v_plan, v_estatus
  FROM public.account_entitlement e WHERE e.auth_user_id = p_auth_user_id;
  v_has := coalesce(v_has,false); v_active := coalesce(v_active,false);

  v_confirmed := v_member.membership_confirmed_at IS NOT NULL;

  v_ready := coalesce((SELECT ds.analysis_status='ready' FROM public.discovery_state ds WHERE ds.member_id=v_member.id), false);

  -- Ordered gate. The three enforced steps apply ONLY when enforcement_active.
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

  RETURN jsonb_build_object(
    'access_state', v_state,
    'authenticated', true,
    'email_verified', v_verified,
    'business_profile_complete', v_bp_done,
    'billing_profile_complete', v_bill_done,
    'has_entitlement', v_has,
    'entitlement_active', v_active,
    'plan_code', v_plan,
    'entitlement_status', v_estatus,
    'membership_confirmed', v_confirmed,
    'workspace_ready', v_ready,
    'onboarding_enforced', coalesce(p.enforcement_active,false));
END; $function$;

REVOKE ALL ON FUNCTION public.fn_member_onboarding_state(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_member_onboarding_state(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.fn_member_onboarding_state(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_member_onboarding_state(uuid) TO service_role;

------------------------------------------------------------------------------
-- 5. fn_workspace_access delegates to the state machine (backward compatible
--    when enforcement is OFF — identical access_state to before this migration).
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_workspace_access()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT public.fn_member_onboarding_state(auth.uid());
$function$;
-- preserve existing caller access
REVOKE ALL ON FUNCTION public.fn_workspace_access() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_workspace_access() TO authenticated, service_role;

-- Reusable server-side guard primitive for data RPCs (wired when enforcement is armed).
CREATE OR REPLACE FUNCTION public.fn_workspace_entry_allowed(p_auth_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT (public.fn_member_onboarding_state(p_auth_user_id) ->> 'access_state') = 'READY';
$function$;
REVOKE ALL ON FUNCTION public.fn_workspace_entry_allowed(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_workspace_entry_allowed(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.fn_workspace_entry_allowed(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_workspace_entry_allowed(uuid) TO service_role;

------------------------------------------------------------------------------
-- 6. Billing profile RPCs (self-service; auth.uid()-scoped; no card data accepted)
------------------------------------------------------------------------------
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
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','ok','completed',false,'profile',NULL);
  END IF;
  RETURN jsonb_build_object('status','ok','completed', b.completed_at IS NOT NULL,
    'profile', jsonb_build_object(
      'legal_name',b.legal_name,'billing_email',b.billing_email,'country',b.country,
      'address_line1',b.address_line1,'address_line2',b.address_line2,'city',b.city,
      'region',b.region,'postal_code',b.postal_code,'tax_id',b.tax_id,'is_business',b.is_business,
      'billing_kind',b.billing_kind,'currency',b.currency,'amount_minor',b.amount_minor));
END; $function$;

CREATE OR REPLACE FUNCTION public.save_billing_profile(p_content jsonb, p_complete boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_member public.member%ROWTYPE;
  v_kind text := 'COMP';
  v_currency text;
  v_invalid text[] := ARRAY[]::text[];
  k text;
  c_allowed constant text[] := ARRAY['legal_name','billing_email','country','address_line1',
    'address_line2','city','region','postal_code','tax_id','is_business'];
  eff_name text; eff_email text; eff_country text;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF jsonb_typeof(p_content) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('status','invalid','fields',jsonb_build_array('content')); END IF;

  -- reject any unknown key, and hard-reject any card/payment-credential-looking key
  FOR k IN SELECT jsonb_object_keys(p_content) LOOP
    IF k ~* '(card|cvv|cvc|pan|number|sort_code|iban|account_number|routing|secret|cvn)' THEN
      RETURN jsonb_build_object('status','rejected','reason','payment_credentials_not_accepted');
    END IF;
    IF NOT (k = ANY(c_allowed)) THEN v_invalid := array_append(v_invalid,k); END IF;
  END LOOP;
  IF cardinality(v_invalid) > 0 THEN
    RETURN jsonb_build_object('status','invalid','fields',to_jsonb(v_invalid)); END IF;

  SELECT * INTO v_member FROM public.member WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_member'); END IF;

  -- COMP vs PAID follows the member's entitlement source (COMP => €0, no charge)
  SELECT CASE WHEN e.source='PROVIDER' THEN 'PAID' ELSE 'COMP' END, e.currency
    INTO v_kind, v_currency
  FROM public.account_entitlement e WHERE e.auth_user_id = v_uid;
  v_kind := coalesce(v_kind,'COMP');

  INSERT INTO public.billing_profile
    (auth_user_id, member_id, legal_name, billing_email, country, address_line1, address_line2,
     city, region, postal_code, tax_id, is_business, billing_plan_code, billing_kind, currency, amount_minor)
  VALUES (v_uid, v_member.id,
     nullif(btrim(p_content->>'legal_name'),''), nullif(btrim(p_content->>'billing_email'),''),
     nullif(btrim(p_content->>'country'),''), nullif(btrim(p_content->>'address_line1'),''),
     nullif(btrim(p_content->>'address_line2'),''), nullif(btrim(p_content->>'city'),''),
     nullif(btrim(p_content->>'region'),''), nullif(btrim(p_content->>'postal_code'),''),
     nullif(btrim(p_content->>'tax_id'),''),
     coalesce((p_content->>'is_business')::boolean, true),
     'ecommerce_monthly', v_kind, v_currency, 0)
  ON CONFLICT (auth_user_id) DO UPDATE SET
     member_id = EXCLUDED.member_id,
     legal_name = coalesce(EXCLUDED.legal_name, public.billing_profile.legal_name),
     billing_email = coalesce(EXCLUDED.billing_email, public.billing_profile.billing_email),
     country = coalesce(EXCLUDED.country, public.billing_profile.country),
     address_line1 = coalesce(EXCLUDED.address_line1, public.billing_profile.address_line1),
     address_line2 = coalesce(EXCLUDED.address_line2, public.billing_profile.address_line2),
     city = coalesce(EXCLUDED.city, public.billing_profile.city),
     region = coalesce(EXCLUDED.region, public.billing_profile.region),
     postal_code = coalesce(EXCLUDED.postal_code, public.billing_profile.postal_code),
     tax_id = coalesce(EXCLUDED.tax_id, public.billing_profile.tax_id),
     is_business = EXCLUDED.is_business,
     billing_kind = EXCLUDED.billing_kind,
     currency = EXCLUDED.currency,
     amount_minor = 0,
     updated_at = now();

  IF p_complete THEN
    SELECT legal_name, billing_email, country INTO eff_name, eff_email, eff_country
      FROM public.billing_profile WHERE auth_user_id = v_uid;
    IF eff_name IS NULL THEN v_invalid := array_append(v_invalid,'legal_name'); END IF;
    IF eff_email IS NULL THEN v_invalid := array_append(v_invalid,'billing_email'); END IF;
    IF eff_country IS NULL THEN v_invalid := array_append(v_invalid,'country'); END IF;
    IF cardinality(v_invalid) > 0 THEN
      RETURN jsonb_build_object('status','invalid','fields',to_jsonb(v_invalid)); END IF;
    UPDATE public.billing_profile SET completed_at = coalesce(completed_at, now()), updated_at = now()
      WHERE auth_user_id = v_uid;
  END IF;

  RETURN jsonb_build_object('status','saved','completed',
    (SELECT completed_at IS NOT NULL FROM public.billing_profile WHERE auth_user_id=v_uid),
    'billing_kind', v_kind, 'amount_minor', 0);
END; $function$;

------------------------------------------------------------------------------
-- 7. Membership confirmation (final self-service step; requires prior steps)
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_membership()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_member public.member%ROWTYPE;
  v_bp_done boolean; v_bill_done boolean; v_active boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO v_member FROM public.member WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_member'); END IF;

  IF v_member.membership_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('status','ok','outcome','already_confirmed'); END IF;

  v_bp_done := EXISTS (SELECT 1 FROM public.discovery_state ds WHERE ds.member_id=v_member.id AND ds.status='complete');
  v_bill_done := EXISTS (SELECT 1 FROM public.billing_profile b WHERE b.auth_user_id=v_uid AND b.completed_at IS NOT NULL);
  v_active := coalesce((SELECT public.fn_entitlement_active(e.status,e.current_period_end)
                        FROM public.account_entitlement e WHERE e.auth_user_id=v_uid), false);

  IF NOT v_active THEN RETURN jsonb_build_object('status','blocked','reason','no_active_membership'); END IF;
  IF NOT v_bp_done THEN RETURN jsonb_build_object('status','blocked','reason','business_profile_incomplete'); END IF;
  IF NOT v_bill_done THEN RETURN jsonb_build_object('status','blocked','reason','billing_profile_incomplete'); END IF;

  UPDATE public.member SET membership_confirmed_at = now(), updated_at = now() WHERE id = v_member.id;
  RETURN jsonb_build_object('status','ok','outcome','confirmed','confirmed_at', now());
END; $function$;

------------------------------------------------------------------------------
-- 8. Grants for self-service RPCs
------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.get_own_billing_profile() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_billing_profile(jsonb,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.confirm_membership() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_own_billing_profile() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_billing_profile(jsonb,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_membership() TO authenticated, service_role;

-- mig_358 — narrow exception: let a CARD_SETUP_REQUIRED member read their own card status
-- ----------------------------------------------------------------------------
-- For the founder-approved mandatory card registration (card_enforcement_active=TRUE), a
-- member without a card is CARD_SETUP_REQUIRED -> fn_onboarding_complete=false -> the
-- PostgREST gate (fn_pre_request_gate) blocks ALL workspace data (server-side enforcement).
-- The card-registration step must still function: it reads the member's own card status via
-- get_own_payment_methods() (owner-only, SECURITY DEFINER on auth.uid()) and invokes the
-- stripe-card-setup EDGE function (not a PostgREST path, and not onboarding-gated). This adds
-- get_own_payment_methods to the gate's RPC allow-list — the "narrow exception allowing
-- authenticated eligible members to complete Stripe card setup". No other resource is opened;
-- workspace data stays denied until a card is on file. No-op while enforcement_active=FALSE.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_pre_request_gate()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_enf      boolean;
  v_role     text;
  v_path     text;
  v_p        text;
  v_first    text;
  v_fname    text;
  v_is_rpc   boolean := false;
  v_allowed  boolean := false;
  v_uid      uuid;
  v_complete boolean;
  -- RPCs an incomplete member may call (onboarding / status / recovery / own card status).
  c_rpc_allow constant text[] := ARRAY[
    'fn_workspace_access','fn_entitlement_status',
    'fn_ensure_member_business_profile','get_own_business_profile','save_business_profile',
    'get_own_billing_profile','save_billing_profile','confirm_membership',
    'get_own_notifications','mark_notification_read','mark_all_notifications_read',
    'fn_global_intelligence_uid',
    'get_own_payment_methods'   -- mig_358: card-setup step reads own card status (owner-only)
  ];
  c_tbl_allow constant text[] := ARRAY[
    'member','users','business_profiles','billing_profile','discovery_state','pulse_notifications',
    'business_category','build_updates','roadmap_items','opportunities',
    'conversion_hero_variants','conversion_section_types','conversion_template_families',
    'creative_format_registry','provider_capability_registry',
    'analytics_events','engagement_patterns','demo_events','pulse_guide_events'
  ];
BEGIN
  BEGIN
    SELECT enforcement_active INTO v_enf FROM public.onboarding_policy WHERE id;
  EXCEPTION WHEN OTHERS THEN
    v_enf := NULL;
  END;
  IF v_enf IS FALSE THEN
    RETURN;
  END IF;

  BEGIN
    v_role := coalesce(
      nullif(current_setting('request.jwt.claim.role', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'));
  EXCEPTION WHEN OTHERS THEN
    v_role := NULL;
  END;
  IF v_role IN ('anon','service_role') THEN
    RETURN;
  END IF;

  v_path := coalesce(current_setting('request.path', true), '');
  v_p := regexp_replace(v_path, '^/+', '');
  v_p := regexp_replace(v_p, '^rest/v1/', '');
  v_first := regexp_replace(v_p, '[/?].*$', '');
  IF v_first = 'rpc' THEN
    v_is_rpc := true;
    v_fname := regexp_replace(regexp_replace(v_p, '^rpc/', ''), '[?/].*$', '');
  END IF;

  IF v_is_rpc THEN
    v_allowed := (v_fname = ANY (c_rpc_allow));
  ELSE
    v_allowed := (v_first = ANY (c_tbl_allow));
  END IF;
  IF v_allowed THEN
    RETURN;
  END IF;

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
      RETURN;
    END IF;
  END IF;

  RAISE EXCEPTION 'onboarding_incomplete'
    USING ERRCODE = '42501',
          HINT = 'Complete member onboarding (business profile, billing profile, card registration, membership confirmation) to access the workspace.';
END; $function$;

REVOKE ALL ON FUNCTION public.fn_pre_request_gate() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_pre_request_gate() TO authenticated, anon, service_role;

-- mig_351_gate_covers_direct_tables.sql
-- SECURITY: close the direct-table onboarding bypass.
--
-- Finding: RLS on customer workspace tables enforces TENANT scoping (auth.uid()/tenant_id),
-- NOT onboarding completion. The previous gate allowed every non-/rpc/ path (tables → RLS),
-- so an incomplete authenticated member could read workspace data (e.g. the shared GLOBAL_SAFE
-- product catalog in commerce_products, plus product_opportunities, saved products, campaigns,
-- stores) directly via PostgREST table endpoints, bypassing fn_pre_request_gate.
--
-- Fix: the gate now enforces onboarding across the whole PostgREST Data API — both /rpc/ and
-- direct table paths — denying-by-default for incomplete members, with a tight allow-list of the
-- onboarding / session / recovery / public-reference resources an incomplete member legitimately
-- needs. Still a strict no-op while enforcement_active = FALSE (enforcement is read first and
-- returns immediately when definitely false), so this changes nothing in production today and the
-- current wired-but-OFF behaviour is unchanged. Fails CLOSED for protected resources on any
-- uncertainty. anon / service_role and onboarded members are always allowed. Tables are still
-- additionally governed by RLS (tenant isolation) exactly as before.

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
  -- RPCs an incomplete member may call (onboarding / status / recovery).
  c_rpc_allow constant text[] := ARRAY[
    'fn_workspace_access','fn_entitlement_status',
    'fn_ensure_member_business_profile','get_own_business_profile','save_business_profile',
    'get_own_billing_profile','save_billing_profile','confirm_membership',
    'get_own_notifications','mark_notification_read','mark_all_notifications_read',
    'fn_global_intelligence_uid'
  ];
  -- Table endpoints an incomplete member may reach: own identity/session, onboarding data,
  -- notifications, public reference / marketing, and own telemetry. Everything else (workspace
  -- data: commerce_*, product_acquisitions, saved_opportunities, marketing_*, creative_*,
  -- discovery_runs, member_* data, social_*, store/page tables, …) is denied until onboarded.
  c_tbl_allow constant text[] := ARRAY[
    'member','users','business_profiles','billing_profile','discovery_state','pulse_notifications',
    'business_category','build_updates','roadmap_items','opportunities',
    'conversion_hero_variants','conversion_section_types','conversion_template_families',
    'creative_format_registry','provider_capability_registry',
    'analytics_events','engagement_patterns','demo_events','pulse_guide_events'
  ];
BEGIN
  -- 1. Enforcement state FIRST: definite OFF → no-op for the entire Data API (unchanged behaviour).
  BEGIN
    SELECT enforcement_active INTO v_enf FROM public.onboarding_policy WHERE id;
  EXCEPTION WHEN OTHERS THEN
    v_enf := NULL;                                           -- unreadable → treat as enforcing
  END;
  IF v_enf IS FALSE THEN
    RETURN;
  END IF;

  -- 2. anon / service_role are never gated (public access + privileged/operational jobs).
  BEGIN
    v_role := coalesce(
      nullif(current_setting('request.jwt.claim.role', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'));
  EXCEPTION WHEN OTHERS THEN
    v_role := NULL;                                          -- unknown → treated as protected end-user
  END;
  IF v_role IN ('anon','service_role') THEN
    RETURN;
  END IF;

  -- 3. Classify the request resource (robust to '/x', '/rest/v1/x', '/rpc/fn', '/rest/v1/rpc/fn').
  v_path := coalesce(current_setting('request.path', true), '');
  v_p := regexp_replace(v_path, '^/+', '');
  v_p := regexp_replace(v_p, '^rest/v1/', '');
  v_first := regexp_replace(v_p, '[/?].*$', '');
  IF v_first = 'rpc' THEN
    v_is_rpc := true;
    v_fname := regexp_replace(regexp_replace(v_p, '^rpc/', ''), '[?/].*$', '');
  END IF;

  -- 4. Allow-list (onboarding/recovery/status RPCs, or onboarding/session/reference tables).
  IF v_is_rpc THEN
    v_allowed := (v_fname = ANY (c_rpc_allow));
  ELSE
    v_allowed := (v_first = ANY (c_tbl_allow));
  END IF;
  IF v_allowed THEN
    RETURN;
  END IF;

  -- 5. Protected resource. Allow ONLY a member whose onboarding is definitely complete.
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

  -- 6. Fail CLOSED: incomplete onboarding, or completeness could not be positively determined.
  RAISE EXCEPTION 'onboarding_incomplete'
    USING ERRCODE = '42501',
          HINT = 'Complete member onboarding (business profile, billing profile, membership confirmation) to access the workspace.';
END; $function$;

REVOKE ALL ON FUNCTION public.fn_pre_request_gate() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_pre_request_gate() TO authenticated, anon, service_role;

COMMENT ON FUNCTION public.fn_pre_request_gate() IS
  'PostgREST db-pre-request onboarding gate. No-op unless onboarding_policy.enforcement_active. '
  'Enforces onboarding across the whole Data API: for an incomplete authenticated member, only an '
  'allow-list of onboarding/recovery/status RPCs and onboarding/session/reference TABLES is '
  'permitted; all other RPC and table resources are refused (42501). anon/service_role and '
  'onboarded members always pass. Fails closed for protected resources on error. Tables remain '
  'governed by RLS (tenant isolation); Supabase Auth and Edge Functions are separate paths.';

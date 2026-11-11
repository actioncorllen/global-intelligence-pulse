-- mig_357 — decouple workspace access from product-research (APPROVED onboarding rules)
-- ----------------------------------------------------------------------------
-- Founder-approved correction: the initial discovery analysis is NOT a prerequisite
-- for workspace access. Workspace provisioning is separate from product research.
--
-- Previously fn_member_onboarding_state emitted 'WORKSPACE_PREPARING' whenever
-- discovery_state.analysis_status <> 'ready', trapping members who never ran research
-- (e.g. a member with no website) at Step 4/5 forever. This removes that clause: a
-- member is READY once the APPROVED prerequisites pass — email verified, business
-- profile, billing profile, card (only when card_enforcement_active), entitlement and
-- membership confirmation. Discovery readiness becomes informational only.
--
-- This does NOT weaken enforcement: every real prerequisite is still enforced, and the
-- card gate (CARD_SETUP_REQUIRED) stays exactly as-is — active only when
-- card_enforcement_active=TRUE (currently FALSE; global activation is a separate founder
-- decision). No fake discovery data is written; no readiness flag is forced. The
-- informational fields workspace_ready + workspace_analysis_status are retained so the
-- Product Discovery UI can show an honest empty state for members with no research.
------------------------------------------------------------------------------
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
                    WHERE pm.auth_user_id = p_auth_user_id AND pm.status = 'ACTIVE');
  SELECT true, public.fn_entitlement_active(e.status, e.current_period_end), e.plan_code, e.status
    INTO v_has, v_active, v_plan, v_estatus
  FROM public.account_entitlement e WHERE e.auth_user_id = p_auth_user_id;
  v_has := coalesce(v_has,false); v_active := coalesce(v_active,false);
  v_confirmed := v_member.membership_confirmed_at IS NOT NULL;
  SELECT ds.analysis_status INTO v_astatus FROM public.discovery_state ds WHERE ds.member_id=v_member.id;
  v_ready := coalesce(v_astatus = 'ready', false);  -- informational only; NOT an access gate
  v_state := CASE
    WHEN NOT v_verified THEN 'EMAIL_VERIFICATION_REQUIRED'
    WHEN p.enforcement_active AND p.require_business_profile       AND NOT v_bp_done   THEN 'BUSINESS_PROFILE_REQUIRED'
    WHEN p.enforcement_active AND p.require_billing_profile        AND NOT v_bill_done THEN 'BILLING_PROFILE_REQUIRED'
    WHEN p.enforcement_active AND p.card_enforcement_active        AND NOT v_card      THEN 'CARD_SETUP_REQUIRED'
    WHEN NOT v_has    THEN 'ENTITLEMENT_REQUIRED'
    WHEN NOT v_active THEN 'ENTITLEMENT_INACTIVE'
    WHEN p.enforcement_active AND p.require_membership_confirmation AND NOT v_confirmed THEN 'MEMBERSHIP_CONFIRMATION_REQUIRED'
    -- (discovery analysis is NOT a workspace-access prerequisite; no WORKSPACE_PREPARING gate)
    ELSE 'READY'
  END;
  RETURN jsonb_build_object('access_state', v_state,'authenticated', true,'email_verified', v_verified,
    'business_profile_complete', v_bp_done,'billing_profile_complete', v_bill_done,
    'has_entitlement', v_has,'entitlement_active', v_active,'plan_code', v_plan,
    'entitlement_status', v_estatus,'membership_confirmed', v_confirmed,'workspace_ready', v_ready,
    'workspace_analysis_status', coalesce(v_astatus, 'none'),
    'onboarding_enforced', coalesce(p.enforcement_active,false))
    || CASE WHEN coalesce(p.card_enforcement_active,false)
            THEN jsonb_build_object('card_on_file', v_card) ELSE '{}'::jsonb END;
END; $function$;

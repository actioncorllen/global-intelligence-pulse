-- mig_362_ecommerce_category_from_plan.sql
-- PREPARED — NOT YET APPLIED (awaiting founder approval).
--
-- Durable fix for direct-invite / backfilled Ecommerce & Dropshipping founding members
-- receiving business_profiles.business_category = NULL.
--
-- Root cause: business_category is written ONLY by the public marketing category journey
-- (localStorage handoff -> save_business_profile). A direct-invite founding member skips
-- that journey, so fn_ensure_member_business_profile() created their profile row with no
-- category, and the frontend (which keys the Ecommerce Product Discovery workspace on the
-- server-owned business_category) could not recognise them as ecommerce.
--
-- Fix: derive business_category = 'ecommerce' from the member's AUTHORISED entitlement
-- plan (plan_code 'ecommerce_monthly', set by the founder-admin COMP grant), at BOTH points
-- of the existing onboarding lifecycle where the gap can occur:
--   (A) fn_ensure_member_business_profile — when the backfill profile is first created;
--   (B) fn_grant_founding_member_entitlement — when the founder grants the ecommerce plan,
--       in case the profile already exists with a NULL category.
-- Together they cover both orderings (grant-before-onboarding and onboarding-before-grant).
--
-- SAFETY / SCOPE (strictly Ecommerce & Dropshipping):
--   * Only ever sets business_category when it IS NULL — never overwrites a chosen category
--     (preserves valid existing categories, incl. the public-journey path which is untouched
--     because fn_ensure returns early for application_linked members).
--   * Only the 'ecommerce_monthly' plan maps to 'ecommerce'; any other/future plan leaves the
--     category NULL (no accidental mis-categorisation of other merchant categories).
--   * No change to COMP entitlement logic, PROVIDER preservation, member/tenant isolation,
--     founding-member restrictions, card setup, or any Stripe object. No website is required
--     and no paid product research is initiated.
--   * Idempotent: for an already-correct member (e.g. surpyjabu, already 'ecommerce') both
--     paths are no-ops.
--
-- Rolled-back SIM (zero residue) confirmed the category-set statement: rows=1, before=NULL,
-- after=ecommerce for an ecommerce_monthly member whose category was NULL.

-- (A) Seed category when the direct-invite backfill profile is created ------------------
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
  -- NEW: derive the canonical category from the member's authorised plan (ecommerce only).
  INSERT INTO public.business_profiles (application_id, user_id, country, business_category)
  VALUES (v_app_new, v_uid, NULL, (
    SELECT CASE WHEN e.plan_code = 'ecommerce_monthly' THEN 'ecommerce' ELSE NULL END
    FROM public.account_entitlement e WHERE e.auth_user_id = v_uid
  ));
  UPDATE public.member SET application_ref = v_app_new, updated_at = now() WHERE id = v_member.id;
  RETURN jsonb_build_object('status','ok','mode','backfilled','application_ref',v_app_new);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status','temporary_failure');
END; $function$;

-- (B) Seed category when the founder grants the ecommerce plan (profile may already exist) --
CREATE OR REPLACE FUNCTION public.fn_grant_founding_member_entitlement(
    p_auth_user_id uuid,
    p_granted_by   text DEFAULT NULL,
    p_notes        text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_member       public.member%ROWTYPE;
    v_ds_count     integer;
    v_existing     public.account_entitlement%ROWTYPE;
    v_has_existing boolean := false;
    v_granted_by   text := COALESCE(NULLIF(btrim(COALESCE(p_granted_by, '')), ''),
                                    'founding-member COMP grant');
    v_prior_state  text;
    v_outcome      text;
BEGIN
    IF p_auth_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'reason', 'null_auth_user_id');
    END IF;

    SELECT * INTO v_member FROM public.member WHERE auth_user_id = p_auth_user_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'rejected', 'reason', 'no_member',
            'detail', 'no provisioned member for this auth user; complete onboarding first');
    END IF;
    IF v_member.account_status <> 'active' THEN
        RETURN jsonb_build_object('status', 'rejected', 'reason', 'member_not_active',
            'account_status', v_member.account_status);
    END IF;

    SELECT count(*) INTO v_ds_count
    FROM public.discovery_state WHERE member_id = v_member.id;
    IF v_ds_count <> 1 THEN
        RETURN jsonb_build_object('status', 'rejected', 'reason', 'workspace_not_provisioned',
            'discovery_state_rows', v_ds_count);
    END IF;

    SELECT * INTO v_existing
    FROM public.account_entitlement WHERE auth_user_id = p_auth_user_id;
    v_has_existing := FOUND;

    IF v_has_existing
       AND (v_existing.source = 'PROVIDER' OR v_existing.provider_subscription_id IS NOT NULL) THEN
        RETURN jsonb_build_object('status', 'preserved',
            'reason', 'existing_provider_entitlement',
            'member_id', v_member.id,
            'plan_code', v_existing.plan_code,
            'entitlement_status', v_existing.status,
            'source', v_existing.source,
            'no_payment_provider_call', true);
    END IF;

    v_prior_state := CASE
        WHEN NOT v_has_existing THEN 'none'
        WHEN v_existing.source = 'COMP'
             AND public.fn_entitlement_active(v_existing.status, v_existing.current_period_end)
             THEN 'comp_active'
        ELSE 'inactive_or_other'
    END;

    INSERT INTO public.account_entitlement
        (auth_user_id, member_id, plan_code, status, source, billing_interval,
         current_period_end, cancel_at_period_end, granted_by, notes)
    VALUES
        (p_auth_user_id, v_member.id, 'ecommerce_monthly', 'COMP', 'COMP', 'month',
         NULL, false, v_granted_by, p_notes)
    ON CONFLICT (auth_user_id) DO UPDATE
        SET member_id          = EXCLUDED.member_id,
            plan_code          = 'ecommerce_monthly',
            status             = 'COMP',
            source             = 'COMP',
            current_period_end = NULL,
            cancel_at_period_end = false,
            granted_by         = EXCLUDED.granted_by,
            notes              = COALESCE(EXCLUDED.notes, public.account_entitlement.notes),
            updated_at         = now()
        WHERE public.account_entitlement.source <> 'PROVIDER'
          AND public.account_entitlement.provider_subscription_id IS NULL;

    v_outcome := CASE v_prior_state
        WHEN 'none'        THEN 'granted'
        WHEN 'comp_active' THEN 'already_granted'
        ELSE 'updated'
    END;

    SELECT * INTO v_existing
    FROM public.account_entitlement WHERE auth_user_id = p_auth_user_id;

    -- NEW: a granted ecommerce membership implies the ecommerce Product Discovery workspace.
    -- Set business_category only when NULL (never overwrite), only for the ecommerce plan.
    -- No-op when the member has not created their business_profile yet (fn_ensure covers that).
    IF v_existing.plan_code = 'ecommerce_monthly' THEN
        UPDATE public.business_profiles bp
        SET business_category = 'ecommerce', updated_at = now()
        FROM public.member m
        WHERE m.id = v_member.id
          AND bp.application_id = m.application_ref
          AND bp.business_category IS NULL;
    END IF;

    RETURN jsonb_build_object(
        'status', 'ok',
        'outcome', v_outcome,
        'auth_user_id', p_auth_user_id,
        'member_id', v_member.id,
        'plan_code', v_existing.plan_code,
        'entitlement_status', v_existing.status,
        'source', v_existing.source,
        'active', public.fn_entitlement_active(v_existing.status, v_existing.current_period_end),
        'granted_by', v_existing.granted_by,
        'no_payment_provider_call', true);
END;
$function$;

-- Grants unchanged (service_role only; no self-grant). Re-assert for safety.
REVOKE ALL ON FUNCTION public.fn_grant_founding_member_entitlement(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_grant_founding_member_entitlement(uuid, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.fn_grant_founding_member_entitlement(uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_grant_founding_member_entitlement(uuid, text, text) TO service_role;

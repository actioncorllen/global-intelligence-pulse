-- mig_345_founding_member_comp_grant.sql
-- Founding-member onboarding: reliable, secure, idempotent COMP entitlement grant.
--
-- Context: founding-member activation (accept_invitation) provisions member +
-- discovery_state (the workspace shell) but does NOT create the ecommerce_monthly
-- entitlement. The two existing live members were comped by a hand-written backfill
-- (granted_by '012A internal COMP backfill'). There was no reusable, verified grant
-- path. This migration replaces the ad-hoc backfill with a controlled founder-admin
-- grant RPC that is:
--   * service_role / founder-admin only (no self-grant: not granted to authenticated/anon),
--   * gated on a genuinely activated member (active member row + exactly one
--     discovery_state) so failed/incomplete onboarding cannot create access,
--   * idempotent (one row per auth_user_id; re-running is a no-op),
--   * preserving of any pre-existing legitimate PROVIDER (paid) subscription,
--   * free of any payment-provider call (writes a COMP row only).
--
-- This function is INERT until invoked by the founder/service-role for a specific,
-- already-activated member. It activates no billing and adds no paid obligation.
-- Automatic COMP-on-activation is deliberately NOT implemented here: comping every
-- member who activates any invitation is a commercial/policy decision reserved to
-- the founder. This keeps the grant a controlled per-member founder step.

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
    -- ---- Guard: target identifier ----------------------------------------
    IF p_auth_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'reason', 'null_auth_user_id');
    END IF;

    -- ---- Req 1 & 4: must be a real, founder-approved, ACTIVATED member -----
    -- A provisioned member row only exists after accept_invitation consumed a
    -- founder-issued invitation; we additionally require it to be active and to
    -- have its workspace shell (exactly one discovery_state).
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

    -- ---- Req 7: preserve a pre-existing legitimate paid (PROVIDER) sub -----
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

    -- ---- Req 3: idempotent COMP grant (one row per auth_user_id) -----------
    -- The ON CONFLICT WHERE guard is a second, race-safe barrier against ever
    -- overwriting a PROVIDER row even if one appears between the check above and
    -- this write.
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

    -- Re-read authoritative state for the response.
    SELECT * INTO v_existing
    FROM public.account_entitlement WHERE auth_user_id = p_auth_user_id;

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

-- ---- Req 5: no self-grant. Mirror the invitation RPC lockdown exactly:
-- executable only by the founder-admin service role (and the owning postgres role),
-- never by authenticated or anon end users.
REVOKE ALL ON FUNCTION
    public.fn_grant_founding_member_entitlement(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION
    public.fn_grant_founding_member_entitlement(uuid, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION
    public.fn_grant_founding_member_entitlement(uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION
    public.fn_grant_founding_member_entitlement(uuid, text, text) TO service_role;

COMMENT ON FUNCTION public.fn_grant_founding_member_entitlement(uuid, text, text) IS
    'Founder-admin (service_role only) idempotent COMP ecommerce_monthly grant for an '
    'activated founding member. Verifies active member + provisioned workspace, preserves '
    'any existing PROVIDER subscription, triggers no payment provider. See '
    'docs/PULSE-ECOM-FOUNDING-MEMBER-ONBOARDING.md.';

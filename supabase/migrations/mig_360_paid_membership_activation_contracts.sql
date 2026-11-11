-- mig_360 — paid-membership activation contracts (INERT service-only writers)
-- ----------------------------------------------------------------------------
-- Adds the MISSING data-layer contract for real paid-customer membership: two service-only
-- RPCs that a (future, founder-approved) stripe-webhook subscription handler will call to
-- activate / update a Stripe subscription-backed entitlement. The account_entitlement table
-- ALREADY carries every field these need (provider, provider_customer_id,
-- provider_subscription_id, billing_interval, currency, amount_minor, current_period_end,
-- cancel_at_period_end, trial_end) — no schema change.
--
-- INERT TODAY: nothing calls these functions. They fire only when the stripe-webhook receives
-- a real Stripe subscription event, which is impossible until BOTH (a) a membership-checkout
-- initiation edge is deployed AND (b) the founder configures a Stripe recurring price. Neither
-- exists. Deploying the webhook handler + checkout edge + configuring a price is a SEPARATE
-- founder-approved activation step (see docs/BILLING-READINESS.md). These functions grant
-- NOTHING on their own and are callable ONLY by service_role (the signed webhook).
--
-- NO INVENTED PRICING: every commercial value (plan_code, interval, currency, amount, period,
-- trial) is a PARAMETER supplied by the caller from the live Stripe objects. This migration
-- hardcodes no price, no interval and no recurring term.
--
-- COMP PRESERVED: fn_grant_founding_member_entitlement already refuses to overwrite a row whose
-- source='PROVIDER' or provider_subscription_id IS NOT NULL (guard + ON CONFLICT WHERE), so a
-- paid subscription can never be clobbered by the COMP grant. COMP members have no exposed path
-- to subscribe, so their €0 entitlement is untouched.
------------------------------------------------------------------------------

-- Stripe subscription.status -> entitlement status. Only ACTIVE/TRIALING (+COMP) are treated as
-- active by fn_entitlement_active; everything else fails closed (no access). Dunning / grace
-- handling is deliberately NOT invented here — past_due/unpaid map to inactive until the founder
-- defines any grace term.
CREATE OR REPLACE FUNCTION public.fn_map_stripe_sub_status(p_stripe_status text)
RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT CASE lower(coalesce(p_stripe_status,''))
    WHEN 'active'              THEN 'ACTIVE'
    WHEN 'trialing'            THEN 'TRIALING'
    WHEN 'past_due'            THEN 'PAST_DUE'
    WHEN 'unpaid'              THEN 'UNPAID'
    WHEN 'canceled'            THEN 'CANCELED'
    WHEN 'incomplete'          THEN 'INCOMPLETE'
    WHEN 'incomplete_expired'  THEN 'INCOMPLETE_EXPIRED'
    WHEN 'paused'              THEN 'PAUSED'
    ELSE 'UNKNOWN'
  END;
$function$;
REVOKE ALL ON FUNCTION public.fn_map_stripe_sub_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_map_stripe_sub_status(text) TO service_role;

-- 1. ACTIVATION: bind/activate a Stripe subscription onto the member's entitlement.
--    Called on checkout.session.completed (mode=subscription) and customer.subscription.created/
--    updated. Idempotent (ON CONFLICT (auth_user_id) DO UPDATE; the webhook is also event-idempotent).
CREATE OR REPLACE FUNCTION public.fn_psp_membership_activated(
  p_auth_user_id uuid,
  p_provider_customer_ref text,
  p_provider_subscription_id text,
  p_stripe_status text,
  p_plan_code text,
  p_billing_interval text,
  p_currency text,
  p_amount_minor integer,
  p_current_period_end timestamptz,
  p_cancel_at_period_end boolean DEFAULT false,
  p_trial_end timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_member public.member%ROWTYPE;
  v_status text := public.fn_map_stripe_sub_status(p_stripe_status);
  v_plan   text;
BEGIN
  IF p_auth_user_id IS NULL
     OR nullif(btrim(coalesce(p_provider_subscription_id,'')),'') IS NULL
     OR nullif(btrim(coalesce(p_provider_customer_ref,'')),'') IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','BAD_ARGS','contract','pulse_membership_activate_v1');
  END IF;
  SELECT * INTO v_member FROM public.member m WHERE m.auth_user_id = p_auth_user_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','error','reason','NO_MEMBER','contract','pulse_membership_activate_v1');
  END IF;

  -- plan_code: use the Stripe-supplied code; else keep the existing one; else the table default.
  v_plan := nullif(btrim(coalesce(p_plan_code,'')),'');

  INSERT INTO public.account_entitlement
    (auth_user_id, member_id, plan_code, status, source, provider,
     provider_customer_id, provider_subscription_id, billing_interval, currency, amount_minor,
     current_period_end, cancel_at_period_end, trial_end, granted_by, notes)
  VALUES
    (p_auth_user_id, v_member.id, coalesce(v_plan,'ecommerce_monthly'), v_status, 'PROVIDER', 'STRIPE',
     btrim(p_provider_customer_ref), btrim(p_provider_subscription_id),
     nullif(btrim(coalesce(p_billing_interval,'')),''), lower(nullif(btrim(coalesce(p_currency,'')),'')), p_amount_minor,
     p_current_period_end, coalesce(p_cancel_at_period_end,false), p_trial_end,
     'stripe-webhook subscription', 'paid membership via Stripe subscription')
  ON CONFLICT (auth_user_id) DO UPDATE SET
     member_id                = EXCLUDED.member_id,
     plan_code                = coalesce(v_plan, public.account_entitlement.plan_code),
     status                   = EXCLUDED.status,
     source                   = 'PROVIDER',
     provider                 = 'STRIPE',
     provider_customer_id     = EXCLUDED.provider_customer_id,
     provider_subscription_id = EXCLUDED.provider_subscription_id,
     billing_interval         = coalesce(EXCLUDED.billing_interval, public.account_entitlement.billing_interval),
     currency                 = coalesce(EXCLUDED.currency, public.account_entitlement.currency),
     amount_minor             = coalesce(EXCLUDED.amount_minor, public.account_entitlement.amount_minor),
     current_period_end       = EXCLUDED.current_period_end,
     cancel_at_period_end     = EXCLUDED.cancel_at_period_end,
     trial_end                = EXCLUDED.trial_end,
     granted_by               = EXCLUDED.granted_by,
     updated_at               = now();

  RETURN jsonb_build_object('status','ok','outcome','activated',
     'entitlement_status', v_status,
     'active', public.fn_entitlement_active(v_status, p_current_period_end),
     'subscription', btrim(p_provider_subscription_id),
     'contract','pulse_membership_activate_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_psp_membership_activated(uuid,text,text,text,text,text,text,integer,timestamptz,boolean,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_psp_membership_activated(uuid,text,text,text,text,text,text,integer,timestamptz,boolean,timestamptz) TO service_role;

-- 2. STATUS CHANGE: update an existing subscription-backed entitlement (renewal, cancel, dunning).
--    Called on customer.subscription.updated/deleted and invoice.payment_failed/paid. Targets the
--    row by provider_subscription_id; never touches a COMP row (those have no subscription id).
CREATE OR REPLACE FUNCTION public.fn_psp_membership_status(
  p_provider_subscription_id text,
  p_stripe_status text,
  p_current_period_end timestamptz DEFAULT NULL,
  p_cancel_at_period_end boolean DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_status text := public.fn_map_stripe_sub_status(p_stripe_status);
  v_rows int := 0;
BEGIN
  IF nullif(btrim(coalesce(p_provider_subscription_id,'')),'') IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','BAD_ARGS','contract','pulse_membership_status_v1');
  END IF;
  UPDATE public.account_entitlement e SET
     status               = v_status,
     current_period_end   = coalesce(p_current_period_end, e.current_period_end),
     cancel_at_period_end = coalesce(p_cancel_at_period_end, e.cancel_at_period_end),
     updated_at           = now()
   WHERE e.provider = 'STRIPE'
     AND e.provider_subscription_id = btrim(p_provider_subscription_id);
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('status','ok','matched',(v_rows > 0),
     'entitlement_status', v_status,
     'contract','pulse_membership_status_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_psp_membership_status(text,text,timestamptz,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_psp_membership_status(text,text,timestamptz,boolean) TO service_role;

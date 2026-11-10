-- mig_354_monetisation_foundation.sql
-- FOUNDER BUSINESS DECISION (2026-11-10): founding-member promotion, card-on-file and
-- prepaid research revenue — INERT foundation. Every behaviour change is gated:
--   * card_enforcement_active  DEFAULT FALSE  (card step not enforced; no card collection exists yet)
--   * trial_autogrant_active   DEFAULT FALSE  (no trials granted automatically)
--   * wallet_price_point.active DEFAULT FALSE (no purchase amount is live; amounts PROVISIONAL)
-- No existing entitlement, member, budget or billing row is modified. No payment provider is
-- integrated here (external dependency: PSP credentials + hosted checkout + webhook edge).
-- Customer-facing Strateloq research credits = the EXISTING discovery_credit_ledger (quote /
-- atomic reserve / settle / refund already live from mig_341); this migration adds the PREPAID
-- FUNDING path, the 14-day trial lifecycle, and the card-on-file registry.
-- (Applied to production together with mig_354b, which adds the PURCHASE entry_type to the
-- customer credit ledger CHECK constraint.)

------------------------------------------------------------------------------
-- 1. Policy flags
------------------------------------------------------------------------------
ALTER TABLE public.onboarding_policy
  ADD COLUMN IF NOT EXISTS trial_days integer NOT NULL DEFAULT 14,
  ADD COLUMN IF NOT EXISTS trial_autogrant_active boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS card_enforcement_active boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.onboarding_policy.card_enforcement_active IS
  'FALSE until the PCI-compliant hosted card setup (PSP), its webhook edge and the onboarding '
  'card step UI are deployed, tested and separately founder-approved. While FALSE the state '
  'machine never emits CARD_SETUP_REQUIRED.';
COMMENT ON COLUMN public.onboarding_policy.trial_autogrant_active IS
  'FALSE until founder approves automatic 14-day trials at invitation acceptance.';

------------------------------------------------------------------------------
-- 2. Card-on-file registry (SAFE REFERENCES ONLY — no PAN/CVV columns exist)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payment_method_registry (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL,
  provider text NOT NULL DEFAULT 'STRIPE' CHECK (provider IN ('STRIPE')),
  provider_customer_ref text NOT NULL,
  provider_payment_method_ref text NOT NULL,
  brand text,
  last4 text CHECK (last4 ~ '^[0-9]{4}$'),
  exp_month integer CHECK (exp_month BETWEEN 1 AND 12),
  exp_year integer CHECK (exp_year BETWEEN 2024 AND 2100),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DETACHED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_payment_method_ref)
);
ALTER TABLE public.payment_method_registry ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_method_registry FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.payment_method_registry TO authenticated;  -- RLS: own rows only
GRANT ALL ON public.payment_method_registry TO service_role;      -- writes via verified webhook path only
DROP POLICY IF EXISTS pmr_select_own ON public.payment_method_registry;
CREATE POLICY pmr_select_own ON public.payment_method_registry
  FOR SELECT TO authenticated USING (auth_user_id = auth.uid());
COMMENT ON TABLE public.payment_method_registry IS
  'Card-on-file SAFE references only (PSP customer/payment-method ids, brand, last4, expiry). '
  'The schema has no column that can hold a card number or CVV. Rows are written exclusively by '
  'the server-side verified PSP webhook/setup path (service_role). A stored card NEVER authorises '
  'any unspecified charge.';

------------------------------------------------------------------------------
-- 3. Prepaid wallet price points (PROVISIONAL, INACTIVE — pricing evaluation only)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.wallet_price_point (
  code text PRIMARY KEY,
  amount_eur_cents integer NOT NULL CHECK (amount_eur_cents > 0),
  credits numeric NOT NULL CHECK (credits > 0),
  active boolean NOT NULL DEFAULT false,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.wallet_price_point ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wallet_price_point FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.wallet_price_point TO anon, authenticated;
GRANT ALL ON public.wallet_price_point TO service_role;
DROP POLICY IF EXISTS wpp_read_active ON public.wallet_price_point;
CREATE POLICY wpp_read_active ON public.wallet_price_point
  FOR SELECT TO anon, authenticated USING (active);
INSERT INTO public.wallet_price_point (code, amount_eur_cents, credits, active, note) VALUES
  ('WALLET_EUR_5',  500,  5,  false, 'PROVISIONAL NOT APPROVED: 5 credits (1 credit = 1 refresh = 10 products today)'),
  ('WALLET_EUR_10', 1000, 11, false, 'PROVISIONAL NOT APPROVED: 11 credits (+10% volume bonus)'),
  ('WALLET_EUR_25', 2500, 30, false, 'PROVISIONAL NOT APPROVED: 30 credits (+20% volume bonus)')
ON CONFLICT (code) DO NOTHING;

-- duplicate-payment guard at the ledger level (additive partial unique index)
CREATE UNIQUE INDEX IF NOT EXISTS dcl_purchase_idem_uniq
  ON public.discovery_credit_ledger (idempotency_key)
  WHERE entry_type = 'PURCHASE';

------------------------------------------------------------------------------
-- 4. Prepaid purchase -> customer credits (service_role only; verified server-side
--    by the FUTURE PSP webhook edge BEFORE this is called). Idempotent per payment_ref.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_wallet_credit_purchase(
  p_auth_user_id uuid, p_price_code text, p_payment_ref text, p_evidence jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_pp public.wallet_price_point%ROWTYPE;
  v_ref text := nullif(btrim(coalesce(p_payment_ref,'')),'');
  v_key text;
  v_existing public.discovery_credit_ledger%ROWTYPE;
  v_bal numeric;
BEGIN
  IF p_auth_user_id IS NULL OR v_ref IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','BAD_ARGS');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.member m WHERE m.auth_user_id = p_auth_user_id) THEN
    RETURN jsonb_build_object('status','error','reason','NO_MEMBER');
  END IF;
  SELECT * INTO v_pp FROM public.wallet_price_point WHERE code = p_price_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','error','reason','UNKNOWN_PRICE_POINT'); END IF;
  IF NOT v_pp.active THEN RETURN jsonb_build_object('status','denied','reason','PRICE_POINT_NOT_ACTIVE'); END IF;

  v_key := 'PURCHASE:' || v_ref;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_key, 54));
  SELECT * INTO v_existing FROM public.discovery_credit_ledger
    WHERE entry_type='PURCHASE' AND idempotency_key = v_key;
  IF FOUND THEN
    RETURN jsonb_build_object('status','ok','idempotent_replay',true,
      'credited', v_existing.credits, 'tenant_match', v_existing.tenant_id = p_auth_user_id);
  END IF;

  INSERT INTO public.discovery_credit_ledger (tenant_id, entry_type, credits, idempotency_key, reason)
    VALUES (p_auth_user_id, 'PURCHASE', v_pp.credits, v_key,
            'wallet purchase '||v_pp.code||' ('||(v_pp.amount_eur_cents/100.0)||' EUR) '||coalesce(p_evidence->>'summary',''));
  SELECT coalesce(sum(credits),0) INTO v_bal FROM public.discovery_credit_ledger WHERE tenant_id = p_auth_user_id;
  RETURN jsonb_build_object('status','ok','credited', v_pp.credits, 'price_code', v_pp.code,
    'amount_eur_cents', v_pp.amount_eur_cents, 'balance_after', v_bal);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_wallet_credit_purchase(uuid,text,text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_wallet_credit_purchase(uuid,text,text,jsonb) TO service_role;

------------------------------------------------------------------------------
-- 5. 14-day founding-member trial (service_role only; deterministic, non-resettable)
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_grant_founding_member_trial(
  p_auth_user_id uuid, p_granted_by text, p_notes text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_member public.member%ROWTYPE;
  v_days integer;
  v_end timestamptz;
BEGIN
  IF p_auth_user_id IS NULL OR nullif(btrim(coalesce(p_granted_by,'')),'') IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','BAD_ARGS');
  END IF;
  SELECT * INTO v_member FROM public.member WHERE auth_user_id = p_auth_user_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','error','reason','NO_MEMBER'); END IF;
  -- Non-resettable: ANY existing entitlement row (COMP, TRIALING, expired, cancelled ...)
  -- permanently refuses a new trial. Logging out or re-inviting can never reset the clock.
  IF EXISTS (SELECT 1 FROM public.account_entitlement e WHERE e.auth_user_id = p_auth_user_id) THEN
    RETURN jsonb_build_object('status','refused','reason','ENTITLEMENT_ALREADY_EXISTS');
  END IF;
  SELECT trial_days INTO v_days FROM public.onboarding_policy WHERE id;
  v_end := now() + make_interval(days => greatest(coalesce(v_days,14),1));
  INSERT INTO public.account_entitlement
    (auth_user_id, member_id, plan_code, status, source, billing_interval,
     current_period_end, trial_end, cancel_at_period_end, granted_by, notes)
  VALUES
    (p_auth_user_id, v_member.id, 'ecommerce_monthly', 'TRIALING', 'MANUAL', 'trial',
     v_end, v_end, true,                -- cancel_at_period_end=TRUE: NO automatic charge at expiry
     p_granted_by, coalesce(p_notes,'14-day founding-member promotional membership'));
  RETURN jsonb_build_object('status','ok','trial_end', v_end, 'days', greatest(coalesce(v_days,14),1));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_grant_founding_member_trial(uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_grant_founding_member_trial(uuid,text,text) TO service_role;

-- Auto-grant at account activation (member row creation via the invitation-acceptance
-- path — the ONLY way member rows are created). INERT until trial_autogrant_active=TRUE.
CREATE OR REPLACE FUNCTION public.fn_member_trial_autogrant()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  BEGIN
    IF NEW.auth_user_id IS NOT NULL
       AND (SELECT trial_autogrant_active FROM public.onboarding_policy WHERE id) THEN
      PERFORM public.fn_grant_founding_member_trial(NEW.auth_user_id, 'trial_autogrant',
        '14-day founding-member trial (auto at acceptance)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- a trial-grant fault must never block account activation
  END;
  RETURN NEW;
END; $function$;
DROP TRIGGER IF EXISTS trg_member_trial_autogrant ON public.member;
CREATE TRIGGER trg_member_trial_autogrant
  AFTER INSERT ON public.member
  FOR EACH ROW EXECUTE FUNCTION public.fn_member_trial_autogrant();

------------------------------------------------------------------------------
-- 6. Onboarding state machine v3: CARD_SETUP_REQUIRED (inert while card flag FALSE)
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
  v_ready := coalesce((SELECT ds.analysis_status='ready' FROM public.discovery_state ds WHERE ds.member_id=v_member.id), false);
  v_state := CASE
    WHEN NOT v_verified THEN 'EMAIL_VERIFICATION_REQUIRED'
    WHEN p.enforcement_active AND p.require_business_profile       AND NOT v_bp_done   THEN 'BUSINESS_PROFILE_REQUIRED'
    WHEN p.enforcement_active AND p.require_billing_profile        AND NOT v_bill_done THEN 'BILLING_PROFILE_REQUIRED'
    WHEN p.enforcement_active AND p.card_enforcement_active        AND NOT v_card      THEN 'CARD_SETUP_REQUIRED'
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
    'onboarding_enforced', coalesce(p.enforcement_active,false))
    || CASE WHEN coalesce(p.card_enforcement_active,false)
            THEN jsonb_build_object('card_on_file', v_card) ELSE '{}'::jsonb END;
END; $function$;

------------------------------------------------------------------------------
-- 7. Own card status (safe fields; for the future card-step UI). NOT yet on the
--    PostgREST gate allowlist — added together with the card step activation mig.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_own_payment_methods()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT jsonb_build_object('status','ok','methods', coalesce((
    SELECT jsonb_agg(jsonb_build_object('brand',pm.brand,'last4',pm.last4,
      'exp_month',pm.exp_month,'exp_year',pm.exp_year,'status',pm.status)
      ORDER BY pm.created_at DESC)
    FROM public.payment_method_registry pm
    WHERE pm.auth_user_id = auth.uid() AND pm.status='ACTIVE'), '[]'::jsonb));
$function$;
REVOKE ALL ON FUNCTION public.get_own_payment_methods() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_payment_methods() TO authenticated, service_role;

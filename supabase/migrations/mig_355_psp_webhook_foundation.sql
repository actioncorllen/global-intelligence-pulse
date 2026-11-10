-- mig_355_psp_webhook_foundation.sql
-- P0 payment integration (test-mode first), INERT without PSP credentials.
-- 1. Trial-trigger hardening: the 14-day promotion may begin ONLY at successful
--    invitation acceptance. accept_invitation is today the only INSERT into public.member
--    and stamps application_ref + account_status='active'; the trigger now requires that
--    acceptance signature, so any FUTURE administrative/placeholder member insert can
--    never start a trial. (trial_autogrant_active remains FALSE regardless.)
-- 2. PSP webhook event dedupe (duplicate webhooks can never duplicate effects).
-- 3. Card-registration RPCs (service_role only; called ONLY by the signature-verified
--    stripe-webhook edge). Safe references only — the registry has no PAN/CVV columns.
-- 4. Owner wallet read (balance + history) for the workspace Billing/Wallet UI.

------------------------------------------------------------------------------
-- 1. Trial autogrant: acceptance-signature only
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_member_trial_autogrant()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  BEGIN
    IF NEW.auth_user_id IS NOT NULL
       AND NEW.application_ref IS NOT NULL            -- invitation-acceptance signature:
       AND NEW.account_status = 'active'              -- placeholder/admin inserts never qualify
       AND (SELECT trial_autogrant_active FROM public.onboarding_policy WHERE id) THEN
      PERFORM public.fn_grant_founding_member_trial(NEW.auth_user_id, 'trial_autogrant',
        '14-day founding-member trial (auto at invitation acceptance)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- a trial-grant fault must never block account activation
  END;
  RETURN NEW;
END; $function$;

------------------------------------------------------------------------------
-- 2. PSP webhook event dedupe (idempotent event processing)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.psp_webhook_event (
  id text PRIMARY KEY,                       -- PSP event id (e.g. evt_...)
  provider text NOT NULL DEFAULT 'STRIPE' CHECK (provider IN ('STRIPE')),
  event_type text NOT NULL,
  livemode boolean NOT NULL DEFAULT false,
  received_at timestamptz NOT NULL DEFAULT now(),
  outcome text
);
ALTER TABLE public.psp_webhook_event ENABLE ROW LEVEL SECURITY;  -- deny-all; service only
REVOKE ALL ON public.psp_webhook_event FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.psp_webhook_event TO service_role;

CREATE OR REPLACE FUNCTION public.fn_psp_webhook_begin(p_event_id text, p_event_type text, p_livemode boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_id text := nullif(btrim(coalesce(p_event_id,'')),''); v_inserted boolean;
BEGIN
  IF v_id IS NULL THEN RETURN jsonb_build_object('status','error','reason','BAD_EVENT_ID'); END IF;
  INSERT INTO public.psp_webhook_event (id, event_type, livemode)
    VALUES (v_id, coalesce(p_event_type,'unknown'), coalesce(p_livemode,false))
    ON CONFLICT (id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN jsonb_build_object('status','ok','duplicate', NOT v_inserted);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_psp_webhook_begin(text,text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_psp_webhook_begin(text,text,boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.fn_psp_webhook_finish(p_event_id text, p_outcome text)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path TO ''
AS $function$
  UPDATE public.psp_webhook_event SET outcome = left(coalesce(p_outcome,''),200) WHERE id = p_event_id;
$function$;
REVOKE ALL ON FUNCTION public.fn_psp_webhook_finish(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_psp_webhook_finish(text,text) TO service_role;

------------------------------------------------------------------------------
-- 3. Card registration (service_role only; caller = verified webhook edge)
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_psp_card_registered(
  p_auth_user_id uuid, p_customer_ref text, p_pm_ref text,
  p_brand text, p_last4 text, p_exp_month integer, p_exp_year integer)
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
     brand, last4, exp_month, exp_year, status)
  VALUES (p_auth_user_id, 'STRIPE', btrim(p_customer_ref), btrim(p_pm_ref),
     nullif(btrim(coalesce(p_brand,'')),''), nullif(btrim(coalesce(p_last4,'')),''),
     p_exp_month, p_exp_year, 'ACTIVE')
  ON CONFLICT (provider, provider_payment_method_ref) DO UPDATE SET
     auth_user_id = EXCLUDED.auth_user_id,
     provider_customer_ref = EXCLUDED.provider_customer_ref,
     brand = EXCLUDED.brand, last4 = EXCLUDED.last4,
     exp_month = EXCLUDED.exp_month, exp_year = EXCLUDED.exp_year,
     status = 'ACTIVE', updated_at = now();
  RETURN jsonb_build_object('status','ok');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_psp_card_registered(uuid,text,text,text,text,integer,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_psp_card_registered(uuid,text,text,text,text,integer,integer) TO service_role;

CREATE OR REPLACE FUNCTION public.fn_psp_card_detached(p_pm_ref text)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO ''
AS $function$
  WITH upd AS (
    UPDATE public.payment_method_registry
       SET status='DETACHED', updated_at=now()
     WHERE provider='STRIPE' AND provider_payment_method_ref = btrim(coalesce(p_pm_ref,''))
    RETURNING 1)
  SELECT jsonb_build_object('status','ok','detached',(SELECT count(*) FROM upd));
$function$;
REVOKE ALL ON FUNCTION public.fn_psp_card_detached(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_psp_card_detached(text) TO service_role;

------------------------------------------------------------------------------
-- 4. Owner wallet read (workspace Billing/Wallet UI; tenant-isolated via auth.uid())
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_own_credit_wallet(p_limit integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_limit integer := greatest(1, least(coalesce(p_limit,20), 100));
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  RETURN jsonb_build_object(
    'status','ok',
    'balance', (SELECT coalesce(sum(credits),0) FROM public.discovery_credit_ledger WHERE tenant_id = v_uid),
    'history', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'entry_type', s.entry_type, 'credits', s.credits, 'reason', s.reason, 'created_at', s.created_at))
      FROM (SELECT * FROM public.discovery_credit_ledger WHERE tenant_id = v_uid
            ORDER BY created_at DESC LIMIT v_limit) s), '[]'::jsonb),
    'price_points', coalesce((
      SELECT jsonb_agg(jsonb_build_object('code',w.code,'amount_eur_cents',w.amount_eur_cents,'credits',w.credits)
             ORDER BY w.amount_eur_cents)
      FROM public.wallet_price_point w WHERE w.active), '[]'::jsonb));
END; $function$;
REVOKE ALL ON FUNCTION public.get_own_credit_wallet(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_credit_wallet(integer) TO authenticated, service_role;

-- mig_361 — live-card pilot allowlist (scopes genuine LIVE card setup to approved members)
-- ----------------------------------------------------------------------------
-- The live card-setup pilot must be restricted to the approved founding member (surpyjabu),
-- NOT exposed to all members, and must NOT require enabling require_live_card globally (which
-- would risk locking out the founder's sandbox card). This allowlist is how stripe-card-setup
-- decides a member may use LIVE Stripe mode. It is INERT until the founder also provides the live
-- credentials (STRIPE_SECRET_KEY_LIVE / STRIPE_WEBHOOK_SECRET_LIVE) AND a separate approval sets
-- STRIPE_LIVE_ALLOWED='true'. With any of those absent, every member stays on TEST mode exactly
-- as today (proven by non-charging tests).
--
-- Security: service-only. RLS on, NO anon/authenticated policies (deny all); only the service role
-- (the edge functions) reads it. No workspace access, RLS, or onboarding flag is touched.
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.live_card_pilot (
  auth_user_id uuid PRIMARY KEY,
  enabled      boolean NOT NULL DEFAULT true,
  note         text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.live_card_pilot ENABLE ROW LEVEL SECURITY;
-- No policies => deny-all for anon/authenticated; service_role bypasses RLS.
REVOKE ALL ON TABLE public.live_card_pilot FROM PUBLIC, anon, authenticated;

-- Owner-safe check used by the edge (service role). Returns true only for an enabled pilot member.
CREATE OR REPLACE FUNCTION public.fn_live_card_pilot(p_uid uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.live_card_pilot p
                 WHERE p.auth_user_id = p_uid AND p.enabled = true);
$function$;
REVOKE ALL ON FUNCTION public.fn_live_card_pilot(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_live_card_pilot(uuid) TO service_role;

-- Seed the approved pilot (inert until live credentials + STRIPE_LIVE_ALLOWED are set).
INSERT INTO public.live_card_pilot (auth_user_id, enabled, note)
SELECT au.id, true, 'approved founding-member live-card pilot (surpyjabu)'
FROM auth.users au WHERE au.email = 'surpyjabu@gmail.com'
ON CONFLICT (auth_user_id) DO NOTHING;

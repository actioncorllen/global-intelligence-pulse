-- STRATELOQ-ECOM-PAID-ENTITLEMENT-FOUNDATION-012A
-- Provider-independent paid-access entitlement foundation. NO payment provider,
-- NO checkout, NO webhook, €0. Additive only; preserves all existing data.
--
-- Audit conclusion (from 012): the existing invitation model is eligibility, not
-- paid entitlement, and overloading it would create ambiguous authorization. So a
-- dedicated, server-authoritative entitlement primitive is added, bound to the
-- durable identity (auth_user_id), with provider-neutral fields so Stripe/Paddle/
-- etc can attach later without a redesign.
--
-- entitlement_event (webhook idempotency) is DEFERRED to the webhook unit (012C):
-- it is only needed to de-duplicate provider events, which do not exist yet. Adding
-- it now would be dead surface. Documented here for traceability.

-- ---------------------------------------------------------------------------
-- Authoritative entitlement store. RLS deny-all to clients; only service_role /
-- SECURITY DEFINER functions read it. No FK to auth.users (provider-first rows and
-- user-deletion resilience; a dangling row simply never matches a login).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.account_entitlement (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL,
  member_id uuid,
  plan_code text NOT NULL DEFAULT 'ecommerce_monthly',
  status text NOT NULL DEFAULT 'INACTIVE'
    CHECK (status IN ('ACTIVE','INACTIVE','EXPIRED','COMP','TRIALING','PAST_DUE','CANCELED')),
  source text NOT NULL DEFAULT 'MANUAL'
    CHECK (source IN ('COMP','MANUAL','PROVIDER')),
  provider text,                          -- null until a provider is connected
  provider_customer_id text,
  provider_subscription_id text,
  billing_interval text NOT NULL DEFAULT 'month',
  currency text,
  amount_minor integer,                   -- provider-neutral price (minor units), optional
  current_period_end timestamptz,         -- NULL for COMP = perpetual
  cancel_at_period_end boolean NOT NULL DEFAULT false,
  trial_end timestamptz,
  granted_by text,                        -- audit trail
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT account_entitlement_user_uk UNIQUE (auth_user_id)   -- one entitlement per user (V1 single plan)
);

CREATE INDEX IF NOT EXISTS account_entitlement_member_idx ON public.account_entitlement(member_id);

ALTER TABLE public.account_entitlement ENABLE ROW LEVEL SECURITY;
-- No RLS policy => deny-all to anon/authenticated. Clients never read/write directly;
-- access is via the SECURITY DEFINER projection RPCs. service_role (webhook, backend) bypasses RLS.
REVOKE ALL ON public.account_entitlement FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.account_entitlement IS
 'Authoritative paid-access entitlement, one row per auth_user_id. Provider-neutral (Stripe/Paddle/etc attach later). RLS deny-all to clients; written only by service_role / SECURITY DEFINER (never by the browser). Inactive entitlement never deletes customer data.';

-- ---------------------------------------------------------------------------
-- Pure helpers (deterministic, testable).
-- ---------------------------------------------------------------------------
-- Is an entitlement row currently active?
CREATE OR REPLACE FUNCTION public.fn_entitlement_active(p_status text, p_current_period_end timestamptz)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $function$
  SELECT upper(coalesce(p_status,'')) IN ('ACTIVE','COMP','TRIALING')
         AND (p_current_period_end IS NULL OR p_current_period_end > now());
$function$;

-- Compose the authoritative access state from the four launch-critical signals.
CREATE OR REPLACE FUNCTION public.fn_access_state(
  p_authenticated boolean, p_email_verified boolean,
  p_has_entitlement boolean, p_entitlement_active boolean, p_workspace_ready boolean)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN NOT coalesce(p_authenticated,false)     THEN 'AUTH_REQUIRED'
    WHEN NOT coalesce(p_email_verified,false)    THEN 'EMAIL_VERIFICATION_REQUIRED'
    WHEN NOT coalesce(p_has_entitlement,false)   THEN 'ENTITLEMENT_REQUIRED'
    WHEN NOT coalesce(p_entitlement_active,false)THEN 'ENTITLEMENT_INACTIVE'
    WHEN NOT coalesce(p_workspace_ready,false)   THEN 'WORKSPACE_PREPARING'
    ELSE 'READY' END;
$function$;

-- ---------------------------------------------------------------------------
-- Authenticated entitlement projection (non-sensitive; no provider ids/secrets).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_entitlement_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); e public.account_entitlement%rowtype;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO e FROM public.account_entitlement WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','ok','has_entitlement',false,'active',false,'plan_code',null,'entitlement_status',null,'source',null);
  END IF;
  RETURN jsonb_build_object(
    'status','ok',
    'has_entitlement', true,
    'active', public.fn_entitlement_active(e.status, e.current_period_end),
    'plan_code', e.plan_code,
    'entitlement_status', e.status,
    'source', e.source,
    'billing_interval', e.billing_interval,
    'current_period_end', e.current_period_end,
    'cancel_at_period_end', e.cancel_at_period_end,
    'trial_end', e.trial_end);
END; $function$;

COMMENT ON FUNCTION public.fn_entitlement_status() IS
 'Authenticated, tenant-scoped (auth.uid()) entitlement projection. Never exposes provider customer/subscription ids or secrets. Read-only.';

-- ---------------------------------------------------------------------------
-- Authoritative workspace-access contract: authenticated AND email verified AND
-- valid entitlement AND workspace readiness. Returns an explicit non-sensitive
-- state only (no frontend routing decisions in the DB).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_workspace_access()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_member_id uuid; v_verified boolean := false;
  v_has boolean := false; v_active boolean := false; v_ready boolean := false;
  v_plan text; v_estatus text; v_state text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('access_state', public.fn_access_state(false,false,false,false,false),
                              'authenticated', false);
  END IF;

  SELECT m.id, (coalesce((SELECT au.email_confirmed_at IS NOT NULL FROM auth.users au WHERE au.id=v_uid), false)
                OR coalesce(m.email_verified,false))
    INTO v_member_id, v_verified
  FROM public.member m WHERE m.auth_user_id = v_uid;

  IF v_member_id IS NULL THEN
    -- authenticated but no provisioned member yet: treat as not-yet-ready to enter workspace
    RETURN jsonb_build_object('access_state', public.fn_access_state(true, v_verified, false, false, false),
                              'authenticated', true, 'note','no member record');
  END IF;

  SELECT true, public.fn_entitlement_active(e.status, e.current_period_end), e.plan_code, e.status
    INTO v_has, v_active, v_plan, v_estatus
  FROM public.account_entitlement e WHERE e.auth_user_id = v_uid;
  v_has := coalesce(v_has, false);
  v_active := coalesce(v_active, false);

  SELECT (ds.analysis_status = 'ready') INTO v_ready
  FROM public.discovery_state ds WHERE ds.member_id = v_member_id;
  v_ready := coalesce(v_ready, false);

  v_state := public.fn_access_state(true, v_verified, v_has, v_active, v_ready);
  RETURN jsonb_build_object(
    'access_state', v_state,
    'authenticated', true,
    'email_verified', v_verified,
    'has_entitlement', v_has,
    'entitlement_active', v_active,
    'plan_code', v_plan,
    'entitlement_status', v_estatus,
    'workspace_ready', v_ready);
END; $function$;

COMMENT ON FUNCTION public.fn_workspace_access() IS
 'Authoritative Ecommerce workspace-access state: composes authenticated AND email-verified AND active-entitlement AND workspace-ready into one of AUTH_REQUIRED / EMAIL_VERIFICATION_REQUIRED / ENTITLEMENT_REQUIRED / ENTITLEMENT_INACTIVE / WORKSPACE_PREPARING / READY. State only; no routing, no sensitive fields. Never trusts browser-supplied entitlement.';

-- ---------------------------------------------------------------------------
-- Grants: entitlement table is never client-accessible. Projection RPCs are
-- authenticated (fn_workspace_access also anon, to return AUTH_REQUIRED). No RPC
-- lets a client write entitlement.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fn_entitlement_active(text,timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_entitlement_active(text,timestamptz) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_access_state(boolean,boolean,boolean,boolean,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_access_state(boolean,boolean,boolean,boolean,boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_entitlement_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_entitlement_status() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_workspace_access() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_workspace_access() TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- COMP entitlement for the minimum internal accounts requiring continued dev
-- access, verified strictly by auth.users (NOT by stale member.email aliases):
--   - actioncorllen@gmail.com          -> 7c8ddf9d... (founder / internal Ecommerce test tenant)
--   - support@globalintelligenceactions.com -> 80f4875a... (internal demo/support, company domain)
-- Explicit, auditable, perpetual (current_period_end NULL). Not granted to any
-- ambiguous/real customer account.
-- ---------------------------------------------------------------------------
INSERT INTO public.account_entitlement
  (auth_user_id, member_id, plan_code, status, source, granted_by, notes)
VALUES
  ('7c8ddf9d-172c-4a89-a402-bb7066228b61','4bc6b405-2e6a-4fd0-a0cf-b2c409fd4177',
   'ecommerce_monthly','COMP','COMP','012A internal COMP backfill',
   'Founder / internal Ecommerce test tenant (auth.users email actioncorllen@gmail.com)'),
  ('80f4875a-4e5d-4fd9-aa22-ea37fe59d15d','dae30000-0000-4000-8000-000000000a02',
   'ecommerce_monthly','COMP','COMP','012A internal COMP backfill',
   'Internal demo/support account (auth.users email support@globalintelligenceactions.com)')
ON CONFLICT (auth_user_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Self-cleaning selftest (service_role only): composer states, active predicate,
-- projection, cross-row isolation. Role-based denials (anon, self-grant) are
-- proven live in the unit report.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_paid_access_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid();
BEGIN
  -- A-G: composer
  v := v || jsonb_build_object('case','A_auth_required','pass', public.fn_access_state(false,false,false,false,false)='AUTH_REQUIRED');
  v := v || jsonb_build_object('case','B_email_required','pass', public.fn_access_state(true,false,false,false,false)='EMAIL_VERIFICATION_REQUIRED');
  v := v || jsonb_build_object('case','C_entitlement_required','pass', public.fn_access_state(true,true,false,false,false)='ENTITLEMENT_REQUIRED');
  v := v || jsonb_build_object('case','D_entitlement_inactive','pass', public.fn_access_state(true,true,true,false,false)='ENTITLEMENT_INACTIVE');
  v := v || jsonb_build_object('case','G_workspace_preparing','pass', public.fn_access_state(true,true,true,true,false)='WORKSPACE_PREPARING');
  v := v || jsonb_build_object('case','EF_ready','pass', public.fn_access_state(true,true,true,true,true)='READY');
  -- active predicate
  v := v || jsonb_build_object('case','comp_perpetual_active','pass', public.fn_entitlement_active('COMP',NULL)=true);
  v := v || jsonb_build_object('case','active_future_active','pass', public.fn_entitlement_active('ACTIVE', now()+interval '30 days')=true);
  v := v || jsonb_build_object('case','active_past_inactive','pass', public.fn_entitlement_active('ACTIVE', now()-interval '1 day')=false);
  v := v || jsonb_build_object('case','expired_inactive','pass', public.fn_entitlement_active('EXPIRED',NULL)=false);
  v := v || jsonb_build_object('case','inactive_inactive','pass', public.fn_entitlement_active('INACTIVE',NULL)=false);
  v := v || jsonb_build_object('case','canceled_inactive','pass', public.fn_entitlement_active('CANCELED', now()+interval '30 days')=false);
  -- synthetic rows: cross-row isolation of the projection logic
  INSERT INTO public.account_entitlement(auth_user_id,plan_code,status,source,granted_by)
    VALUES (ua,'ecommerce_monthly','ACTIVE','MANUAL','selftest'),
           (ub,'ecommerce_monthly','EXPIRED','MANUAL','selftest');
  v := v || jsonb_build_object('case','row_a_active','pass',
        (SELECT public.fn_entitlement_active(status,current_period_end) FROM public.account_entitlement WHERE auth_user_id=ua)=true);
  v := v || jsonb_build_object('case','row_b_inactive','pass',
        (SELECT public.fn_entitlement_active(status,current_period_end) FROM public.account_entitlement WHERE auth_user_id=ub)=false);
  v := v || jsonb_build_object('case','one_row_per_user','pass',
        (SELECT count(*) FROM public.account_entitlement WHERE auth_user_id=ua)=1);
  DELETE FROM public.account_entitlement WHERE auth_user_id IN (ua,ub);
  -- real COMP tenants active
  v := v || jsonb_build_object('case','founder_comp_active','pass',
        (SELECT public.fn_entitlement_active(status,current_period_end) FROM public.account_entitlement WHERE auth_user_id='7c8ddf9d-172c-4a89-a402-bb7066228b61')=true);
  v := v || jsonb_build_object('case','demo_comp_active','pass',
        (SELECT public.fn_entitlement_active(status,current_period_end) FROM public.account_entitlement WHERE auth_user_id='80f4875a-4e5d-4fd9-aa22-ea37fe59d15d')=true);

  RETURN jsonb_build_object('suite','paid_access_entitlement',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_paid_access_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_paid_access_selftest() TO service_role;
COMMENT ON FUNCTION public.fn_paid_access_selftest() IS
 'Paid-access entitlement regression (self-cleaning, service_role only): access-state composer, active predicate, cross-row isolation, one-row-per-user, and internal COMP tenants active.';

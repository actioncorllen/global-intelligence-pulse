-- =====================================================================
-- phase08_staging_dependencies  (version 20261104000847) — SECURE-BY-CONSTRUCTION
-- Project: strateloq-billing-staging (nlfkwrjmhxbubtlwepwx). Staging only.
-- =====================================================================
-- Authoritative, version-controlled copy of the billing-staging bootstrap
-- migration, hardened so that recreating the environment CANNOT leave public
-- tables exposed.
--
-- ROOT CAUSE this file fixes: the originally-applied 20261104000847 created
-- public.member WITHOUT row level security and left Supabase's default broad
-- grants (anon + authenticated: SELECT/INSERT/UPDATE/DELETE/TRUNCATE) on BOTH
-- public.member and public.account_entitlement. public.member therefore
-- tripped the `rls_disabled_in_public` (ERROR) advisory and was fully
-- reachable/writable with the anon key; account_entitlement kept broad grants
-- (dormant only because RLS-with-no-policy denied clients).
--
-- This version creates the identical schema AND applies the approved access
-- model inline, in the same migration, so the tables are never created in an
-- exposed state. It is idempotent and matches the live end-state produced by
-- the separately-applied remediation migration 20261110182057
-- (scripts/security/phase08_billing_staging_rls_lockdown_remediation.sql),
-- which remains the backstop for already-deployed databases.
--
-- Approved access model (reused conventions — not invented):
--   * member             -> production parity (dr/schema/policies.sql):
--                           RLS on; authenticated SELECTs only its own row;
--                           writes via service_role only.
--   * account_entitlement-> mig_239_paid_entitlement_foundation:
--                           RLS deny-all to clients; service_role / SECURITY
--                           DEFINER RPC access only.
-- =====================================================================

-- ---------------------------------------------------------------------
-- public.member  (identity / profile — PII)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.member (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id    uuid NOT NULL,
  email           text NOT NULL,
  display_name    text,
  business_name   text,
  email_verified  boolean NOT NULL DEFAULT false,
  welcome_seen    boolean NOT NULL DEFAULT false,
  account_status  text NOT NULL DEFAULT 'active',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  application_ref uuid
);

-- SECURITY (inline, secure-by-construction):
ALTER TABLE public.member ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.member FROM PUBLIC, anon, authenticated;
GRANT  SELECT ON public.member TO authenticated;
DROP POLICY IF EXISTS member_select_own ON public.member;
CREATE POLICY member_select_own ON public.member
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (auth.uid() = auth_user_id);
COMMENT ON TABLE public.member IS
  'Member identity/profile (PII). RLS enabled. authenticated may SELECT only their own '
  'row (auth.uid()=auth_user_id) via policy member_select_own; all writes performed by '
  'service_role / edge functions (bypasses RLS). anon has no access.';

-- ---------------------------------------------------------------------
-- public.account_entitlement  (authoritative paid-access entitlement)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.account_entitlement (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id             uuid NOT NULL,
  member_id                uuid,
  plan_code                text NOT NULL DEFAULT 'ecommerce_monthly',
  status                   text NOT NULL DEFAULT 'INACTIVE',
  source                   text NOT NULL DEFAULT 'MANUAL',
  provider                 text,
  provider_customer_id     text,
  provider_subscription_id text,
  billing_interval         text NOT NULL DEFAULT 'month',
  currency                 text,
  amount_minor             int4,
  current_period_end       timestamptz,
  cancel_at_period_end     boolean NOT NULL DEFAULT false,
  trial_end                timestamptz,
  granted_by               text,
  notes                    text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT account_entitlement_user_uk UNIQUE (auth_user_id),
  CONSTRAINT account_entitlement_source_check CHECK (source = ANY (ARRAY['COMP','MANUAL','PROVIDER'])),
  CONSTRAINT account_entitlement_status_check CHECK (status = ANY (ARRAY['ACTIVE','INACTIVE','EXPIRED','COMP','TRIALING','PAST_DUE','CANCELED']))
);

-- SECURITY (inline, secure-by-construction):
ALTER TABLE public.account_entitlement ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_entitlement FROM PUBLIC, anon, authenticated;  -- deny-all to clients
COMMENT ON TABLE public.account_entitlement IS
  'Authoritative paid-access entitlement (one row per auth_user_id). RLS deny-all to '
  'clients; read/written only by service_role / SECURITY DEFINER billing RPCs (never the browser).';

-- ---------------------------------------------------------------------
-- Pure helpers (deterministic; non-sensitive; faithful to original).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_entitlement_active(p_status text, p_current_period_end timestamp with time zone)
 RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT upper(coalesce(p_status,'')) IN ('ACTIVE','COMP','TRIALING')
         AND (p_current_period_end IS NULL OR p_current_period_end > now());
$function$;

CREATE OR REPLACE FUNCTION public.fn_access_state(p_authenticated boolean, p_email_verified boolean, p_has_entitlement boolean, p_entitlement_active boolean, p_workspace_ready boolean)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN NOT coalesce(p_authenticated,false)      THEN 'AUTH_REQUIRED'
    WHEN NOT coalesce(p_email_verified,false)     THEN 'EMAIL_VERIFICATION_REQUIRED'
    WHEN NOT coalesce(p_has_entitlement,false)    THEN 'ENTITLEMENT_REQUIRED'
    WHEN NOT coalesce(p_entitlement_active,false) THEN 'ENTITLEMENT_INACTIVE'
    WHEN NOT coalesce(p_workspace_ready,false)    THEN 'WORKSPACE_PREPARING'
    ELSE 'READY' END;
$function$;

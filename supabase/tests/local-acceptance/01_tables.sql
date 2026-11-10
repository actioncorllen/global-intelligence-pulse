-- 01_tables.sql — LOCAL ACCEPTANCE ENVIRONMENT ONLY (127.0.0.1). Synthetic data only.
-- Support tables carrying the columns the real security functions and RLS policies read.
-- onboarding_policy and billing_profile are verbatim from mig_346 (the migration applied to prod).
-- RLS policies and grants below are verbatim / mirrored from the production pg_policies +
-- role_table_grants fetch of 2026-11-10.

------------------------------------------------------------------------------
-- Reference: business_category (from mig_240, applied to prod)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.business_category (
  code text PRIMARY KEY,
  label text NOT NULL,
  sort integer NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT true
);
INSERT INTO public.business_category (code, label, sort) VALUES
  ('ecommerce_dropshipping','E-commerce / Dropshipping',10)
ON CONFLICT (code) DO NOTHING;
ALTER TABLE public.business_category ENABLE ROW LEVEL SECURITY;

------------------------------------------------------------------------------
-- founding_applications
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.founding_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name text NOT NULL,
  last_name text NOT NULL,
  work_email text NOT NULL,
  company text, country text, industry text, role text, company_size text,
  primary_goal text, use_case text, current_workflow text,
  status text NOT NULL DEFAULT 'new' CHECK (status IN ('new','reviewing','accepted','rejected','contacted')),
  source text NOT NULL DEFAULT 'website',
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.founding_applications ENABLE ROW LEVEL SECURITY;

------------------------------------------------------------------------------
-- member
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.member (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid UNIQUE REFERENCES auth.users(id),
  email text UNIQUE NOT NULL,
  display_name text,
  business_name text,
  email_verified boolean NOT NULL DEFAULT false,
  welcome_seen boolean NOT NULL DEFAULT false,
  account_status text NOT NULL DEFAULT 'active' CHECK (account_status IN ('active','disabled')),
  application_ref uuid UNIQUE REFERENCES public.founding_applications(id),
  membership_confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.member ENABLE ROW LEVEL SECURITY;

------------------------------------------------------------------------------
-- discovery_state
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.discovery_state (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL REFERENCES public.member(id),
  status text NOT NULL DEFAULT 'not_started',
  analysis_status text NOT NULL DEFAULT 'not_started',
  entry_viewed_at timestamptz,
  started_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.discovery_state ENABLE ROW LEVEL SECURITY;

------------------------------------------------------------------------------
-- account_entitlement
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.account_entitlement (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL UNIQUE,
  member_id uuid,
  plan_code text NOT NULL DEFAULT 'ecommerce_monthly',
  status text NOT NULL CHECK (status IN ('ACTIVE','INACTIVE','EXPIRED','COMP','TRIALING','PAST_DUE','CANCELED')),
  source text NOT NULL CHECK (source IN ('COMP','MANUAL','PROVIDER')),
  provider text, provider_customer_id text, provider_subscription_id text,
  currency text,
  billing_interval text,
  current_period_end timestamptz,
  cancel_at_period_end boolean NOT NULL DEFAULT false,
  trial_end timestamptz,
  granted_by text, notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.account_entitlement ENABLE ROW LEVEL SECURITY;  -- deny-all, as prod

------------------------------------------------------------------------------
-- business_profiles
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.business_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL UNIQUE REFERENCES public.founding_applications(id),
  user_id uuid,
  business_name text, website text, country text, industry text, business_type text,
  company_size text, target_audience text, primary_goal text,
  preferred_platforms jsonb NOT NULL DEFAULT '[]'::jsonb,
  competitors jsonb NOT NULL DEFAULT '[]'::jsonb,
  ai_experience_level text,
  brief_frequency text DEFAULT 'daily',
  brand_voice text, business_summary text, positioning_summary text,
  opportunity_preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
  business_category text REFERENCES public.business_category(code),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.business_profiles ENABLE ROW LEVEL SECURITY;

------------------------------------------------------------------------------
-- pulse_notifications
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pulse_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  kind text NOT NULL DEFAULT 'info',
  title text, body text, link text,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pulse_notifications ENABLE ROW LEVEL SECURITY;

------------------------------------------------------------------------------
-- commerce_products (protected workspace table; tenant + GLOBAL_SAFE catalog)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.commerce_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  product_name text,
  visibility text NOT NULL DEFAULT 'PRIVATE',
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.commerce_products ENABLE ROW LEVEL SECURITY;

------------------------------------------------------------------------------
-- onboarding_policy + billing_profile — verbatim from mig_346 (+ mig_349 column)
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.onboarding_policy (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  enforcement_active boolean NOT NULL DEFAULT false,
  require_business_profile boolean NOT NULL DEFAULT true,
  require_billing_profile boolean NOT NULL DEFAULT true,
  require_membership_confirmation boolean NOT NULL DEFAULT true,
  comp_refresh_credits_per_period integer NOT NULL DEFAULT 10,
  comp_refresh_period text NOT NULL DEFAULT 'month',
  comp_provider_max_calls integer NOT NULL DEFAULT 10,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text
);
INSERT INTO public.onboarding_policy (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.onboarding_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.onboarding_policy
  ADD COLUMN IF NOT EXISTS comp_refresh_allowance_approved boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.billing_profile (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL UNIQUE,
  member_id uuid,
  legal_name text,
  billing_email text,
  country text,
  address_line1 text,
  address_line2 text,
  city text,
  region text,
  postal_code text,
  tax_id text,
  is_business boolean NOT NULL DEFAULT true,
  billing_plan_code text NOT NULL DEFAULT 'ecommerce_monthly',
  billing_kind text NOT NULL DEFAULT 'COMP' CHECK (billing_kind IN ('COMP','PAID')),
  currency text,
  amount_minor integer NOT NULL DEFAULT 0,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.billing_profile ENABLE ROW LEVEL SECURITY;

------------------------------------------------------------------------------
-- RLS POLICIES — verbatim from production pg_policies (2026-11-10)
------------------------------------------------------------------------------
CREATE POLICY "anyone reads business_category" ON public.business_category AS permissive FOR SELECT TO public USING (true);
CREATE POLICY "service role full access on business_profiles" ON public.business_profiles AS permissive FOR ALL TO service_role USING (true);
CREATE POLICY "user reads own business_profile" ON public.business_profiles AS permissive FOR SELECT TO authenticated USING ((auth.uid() = user_id));
CREATE POLICY commerce_products_service_all ON public.commerce_products AS permissive FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY commerce_products_select_own ON public.commerce_products AS permissive FOR SELECT TO authenticated USING ((auth.uid() = user_id));
CREATE POLICY commerce_products_global_read ON public.commerce_products AS permissive FOR SELECT TO authenticated USING (((user_id = public.fn_global_intelligence_uid()) AND (visibility = 'GLOBAL_SAFE'::text)));
CREATE POLICY discovery_state_select_own ON public.discovery_state AS permissive FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.member m
  WHERE ((m.id = discovery_state.member_id) AND (m.auth_user_id = auth.uid())))));
CREATE POLICY "service role full access on founding_applications" ON public.founding_applications AS permissive FOR ALL TO service_role USING (true);
CREATE POLICY member_select_own ON public.member AS permissive FOR SELECT TO authenticated USING ((auth.uid() = auth_user_id));
CREATE POLICY pulse_notifications_owner_select ON public.pulse_notifications AS permissive FOR SELECT TO authenticated USING ((user_id = auth.uid()));

------------------------------------------------------------------------------
-- TABLE GRANTS — mirrored from production role_table_grants (2026-11-10)
------------------------------------------------------------------------------
REVOKE ALL ON public.member, public.discovery_state, public.account_entitlement,
  public.founding_applications, public.business_profiles, public.business_category,
  public.pulse_notifications, public.commerce_products, public.onboarding_policy,
  public.billing_profile FROM PUBLIC, anon, authenticated, service_role;

GRANT ALL ON public.account_entitlement TO service_role;
GRANT ALL ON public.billing_profile TO anon, authenticated, service_role;
GRANT ALL ON public.business_category TO anon, authenticated, service_role;
GRANT ALL ON public.business_profiles TO service_role;
GRANT REFERENCES, SELECT, TRIGGER ON public.business_profiles TO anon, authenticated;
GRANT ALL ON public.commerce_products TO anon, authenticated, service_role;
GRANT SELECT ON public.discovery_state TO authenticated;
GRANT ALL ON public.discovery_state TO service_role;
GRANT REFERENCES, TRIGGER ON public.founding_applications TO anon, authenticated;
GRANT ALL ON public.founding_applications TO service_role;
GRANT SELECT ON public.member TO authenticated;
GRANT ALL ON public.member TO service_role;
GRANT ALL ON public.onboarding_policy TO anon, authenticated, service_role;
GRANT SELECT ON public.pulse_notifications TO authenticated;
GRANT ALL ON public.pulse_notifications TO service_role;

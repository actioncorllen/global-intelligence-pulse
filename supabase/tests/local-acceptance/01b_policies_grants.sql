DROP POLICY IF EXISTS "anyone reads business_category" ON public.business_category;
DROP POLICY IF EXISTS "service role full access on business_profiles" ON public.business_profiles;
DROP POLICY IF EXISTS "user reads own business_profile" ON public.business_profiles;
DROP POLICY IF EXISTS commerce_products_service_all ON public.commerce_products;
DROP POLICY IF EXISTS commerce_products_select_own ON public.commerce_products;
DROP POLICY IF EXISTS commerce_products_global_read ON public.commerce_products;
DROP POLICY IF EXISTS discovery_state_select_own ON public.discovery_state;
DROP POLICY IF EXISTS "service role full access on founding_applications" ON public.founding_applications;
DROP POLICY IF EXISTS member_select_own ON public.member;
DROP POLICY IF EXISTS pulse_notifications_owner_select ON public.pulse_notifications;

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

-- 03_grants_standin_seed.sql — LOCAL ONLY.
-- Function grants mirrored from production pg_proc.proacl (2026-11-10), plus ONE clearly
-- marked data-RPC stand-in (fn_product_explorer) representing a protected workspace RPC.
-- The stand-in is NOT a security function: every security function in this environment is
-- the verbatim production definition.

-- ---- Function grants (mirror prod ACLs) ----
REVOKE ALL ON FUNCTION public.fn_pre_request_gate() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_pre_request_gate() TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.fn_member_onboarding_state(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_member_onboarding_state(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.fn_onboarding_complete(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_onboarding_complete(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.fn_workspace_entry_allowed(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_workspace_entry_allowed(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.fn_workspace_access() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_workspace_access() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_entitlement_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_entitlement_status() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_entitlement_active(text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_entitlement_active(text, timestamptz) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_own_business_profile() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_business_profile() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.save_business_profile(jsonb, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_business_profile(jsonb, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_own_notifications(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_own_notifications(integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_notification_read(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_all_notifications_read() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.confirm_membership() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_membership() TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ensure_member_business_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_ensure_member_business_profile() TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_own_billing_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_own_billing_profile() TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.save_billing_profile(jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_billing_profile(jsonb, boolean) TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.fn_global_intelligence_uid() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_global_intelligence_uid() TO anon, authenticated, service_role;

-- ---- STAND-IN protected workspace data RPC (NOT a security function) ----
-- Represents prod workspace RPCs such as fn_product_explorer: NOT on the gate's
-- c_rpc_allow list, SECURITY DEFINER, callable by authenticated — so the ONLY thing
-- standing between an incomplete member and it over HTTP is fn_pre_request_gate.
CREATE OR REPLACE FUNCTION public.fn_product_explorer(p_page integer DEFAULT 1)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $$ SELECT jsonb_build_object('status','ok','standin',true,'page',p_page); $$;
REVOKE ALL ON FUNCTION public.fn_product_explorer(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_explorer(integer) TO authenticated, service_role;

-- ---- Synthetic workspace data (NO production/customer data) ----
-- GLOBAL_SAFE shared catalog row owned by the global intelligence tenant,
-- used to reproduce the mig_351 finding (incomplete member could read it pre-fix).
INSERT INTO public.commerce_products (user_id, product_name, visibility)
VALUES (public.fn_global_intelligence_uid(), 'SYNTH GLOBAL CATALOG ITEM', 'GLOBAL_SAFE')
ON CONFLICT DO NOTHING;

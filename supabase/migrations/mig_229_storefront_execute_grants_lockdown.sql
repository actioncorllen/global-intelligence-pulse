-- PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001
-- Security lockdown of the storefront-runtime functions' EXECUTE grants.
-- SECURITY DEFINER functions are executable by anon/PUBLIC by default; for an
-- anon caller auth.uid() is NULL, which would bypass the (auth.uid()-based)
-- tenant guard on the mutating functions. Revoke anon/PUBLIC everywhere;
-- restrict backend/persistence/selftest to service_role; keep the
-- tenant-guarded review/edit functions on authenticated (guard enforced there).

-- Revoke from PUBLIC + anon on all runtime functions.
REVOKE ALL ON FUNCTION public.fn_storefront_test_eligibility(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_select_conversion_template(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_resolve_storefront_assets(text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_generate_storefront_runtime(uuid,jsonb,jsonb,jsonb,jsonb,text,text,uuid,text,uuid,boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_storefront_transition_state(uuid,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_storefront_set_destination(uuid,text,uuid,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_storefront_ad_addressable(uuid,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_storefront_change_country(uuid,text,uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_storefront_runtime_selftest() FROM PUBLIC, anon, authenticated;

-- service_role may execute everything (backend orchestration).
GRANT EXECUTE ON FUNCTION public.fn_storefront_test_eligibility(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_select_conversion_template(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_resolve_storefront_assets(text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_generate_storefront_runtime(uuid,jsonb,jsonb,jsonb,jsonb,text,text,uuid,text,uuid,boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_storefront_transition_state(uuid,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_storefront_set_destination(uuid,text,uuid,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_storefront_ad_addressable(uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_storefront_change_country(uuid,text,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_storefront_runtime_selftest() TO service_role;

-- authenticated tenants may call the tenant-guarded review/edit + read functions
-- and the pure (non-definer) helpers. auth.uid() is non-null for these callers,
-- so the ownership guard is enforced. They may NOT call the persistence/backend
-- generator, the asset resolver, or the selftest directly.
GRANT EXECUTE ON FUNCTION public.fn_storefront_test_eligibility(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_select_conversion_template(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_storefront_transition_state(uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_storefront_set_destination(uuid,text,uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_storefront_ad_addressable(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_storefront_change_country(uuid,text,uuid) TO authenticated;

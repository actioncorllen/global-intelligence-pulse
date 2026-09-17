-- STRATELOQ-ECOM-P8-CONVERSION-RUNTIME-INTEGRATION-002
-- Security lockdown of the mig_234 additions' EXECUTE grants, mirroring mig_229.
-- The SECURITY DEFINER selftest must be service_role-only (like
-- fn_storefront_runtime_selftest). The pure helpers are non-definer and safe,
-- but we still revoke anon/PUBLIC and grant authenticated + service_role to keep
-- the same posture as the rest of the storefront runtime surface.

-- Pure (non-definer) helpers: revoke anon/PUBLIC; allow authenticated + service_role.
REVOKE ALL ON FUNCTION public.fn_resolve_merchant_theme(jsonb,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_storefront_conversion_strategy(jsonb,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_storefront_why_this_page(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_resolve_merchant_theme(jsonb,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_storefront_conversion_strategy(jsonb,jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_storefront_why_this_page(jsonb) TO authenticated, service_role;

-- SECURITY DEFINER selftest: backend-only (service_role), never anon/authenticated.
REVOKE ALL ON FUNCTION public.fn_storefront_branding_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_storefront_branding_selftest() TO service_role;

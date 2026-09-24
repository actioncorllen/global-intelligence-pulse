-- STRATELOQ — grant hardening for tenant-WRITE creative RPCs
-- Supabase grants EXECUTE to anon/authenticated explicitly (default privileges),
-- so REVOKE ... FROM PUBLIC does not remove anon. Remove anon explicitly from the
-- tenant-write creative functions. fn_creative_studio_generate and
-- fn_creative_format_apply already require auth.uid() internally; the critical fix
-- is fn_creative_production_request, which trusts p_tenant and inserts a request
-- row — anon must not be able to write cross-tenant. authenticated/service_role keep access.
REVOKE EXECUTE ON FUNCTION public.fn_creative_studio_generate(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.fn_creative_format_apply(uuid,uuid,text,text,text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.fn_creative_production_request(uuid, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.fn_creative_production_request(uuid,text,uuid,uuid,text,text,text,text,jsonb,jsonb,jsonb,jsonb,boolean,boolean,boolean) FROM anon;

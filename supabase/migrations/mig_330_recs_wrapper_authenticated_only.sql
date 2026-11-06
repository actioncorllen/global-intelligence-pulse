-- mig_330_recs_wrapper_authenticated_only.sql
-- APPLIED to prod nxaunmyihhjixxxljcqt (founder-approved Phase 03 hardening follow-up).
-- Supabase default privileges auto-grant EXECUTE to anon on new public functions. The recommendations
-- wrapper is signed-in only (anon already receives only an 'unauthenticated' response and no data), so
-- remove the anon grant to match intent. authenticated keeps EXECUTE.
-- Rollback: GRANT EXECUTE ON FUNCTION public.get_own_opportunity_recommendations(integer) TO anon;
REVOKE EXECUTE ON FUNCTION public.get_own_opportunity_recommendations(integer) FROM anon;

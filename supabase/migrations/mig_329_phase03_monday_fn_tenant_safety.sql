-- mig_329_phase03_monday_fn_tenant_safety.sql
-- Phase 03 security hardening (tenant isolation). APPLIED to prod nxaunmyihhjixxxljcqt (founder-approved).
--
-- Finding: fn_monday_top_opportunities(uuid,integer) and fn_run_monday_product_opportunity(text,boolean)
-- are SECURITY DEFINER, do NOT reference auth.uid(), have no role guard, and carried the default
-- `authenticated` EXECUTE grant. Via PostgREST a signed-in user could therefore read ANOTHER tenant's
-- recommendations feed (spoof p_tenant) or trigger the Monday opportunity pipeline — a cross-tenant /
-- unauthorized-execution gap (RLS-bypassing because SECURITY DEFINER).
--
-- Legitimate callers verified (read-only) before change:
--   * n8n "Monday Ecom Product Opportunity Orchestrator" calls fn_run_monday_product_opportunity via the
--     supabaseApi credential = service_role (NOT an authenticated JWT) -> preserved by keeping service_role.
--   * Frontend does not call either (not in AGENTS.md; no wrapper existed).
--   * No pg_cron; fn_run_monday_product_opportunity referenced in-DB only by a selftest (runs as definer).
--
-- Fix (smallest durable, reversible, touches NO data):
--   1. Lock both service-side functions to service_role/postgres (revoke authenticated/anon/PUBLIC).
--   2. Expose the feed to the browser via a tenant-safe wrapper that derives the tenant from auth.uid().
--
-- Rollback:
--   GRANT EXECUTE ON FUNCTION public.fn_monday_top_opportunities(uuid,integer) TO authenticated;
--   GRANT EXECUTE ON FUNCTION public.fn_run_monday_product_opportunity(text,boolean) TO authenticated;
--   DROP FUNCTION public.get_own_opportunity_recommendations(integer);

REVOKE EXECUTE ON FUNCTION public.fn_monday_top_opportunities(uuid, integer) FROM authenticated, anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_run_monday_product_opportunity(text, boolean) FROM authenticated, anon, PUBLIC;

CREATE OR REPLACE FUNCTION public.get_own_opportunity_recommendations(p_limit integer DEFAULT 5)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 5), 50));
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object(
      'status','unauthenticated',
      'ready_to_test', jsonb_build_array(),
      'watchlist', jsonb_build_array(),
      'ready_to_test_count', 0,
      'watchlist_count', 0,
      'total_opportunities', 0
    );
  END IF;
  -- Server-owned identity: the browser can never choose the tenant.
  RETURN public.fn_monday_top_opportunities(v_uid, v_limit);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_own_opportunity_recommendations(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_own_opportunity_recommendations(integer) TO authenticated;

COMMENT ON FUNCTION public.get_own_opportunity_recommendations(integer) IS
'Phase 03.08 tenant-safe recommendations read: returns fn_monday_top_opportunities for auth.uid() only (no caller-supplied tenant). Frontend contract. The underlying fn_monday_top_opportunities is service_role/postgres-only.';

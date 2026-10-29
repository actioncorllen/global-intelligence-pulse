-- ============================================================================
-- mig_307_commercial_readiness_badge_tenant_guard.sql
-- STRATELOQ-STAGE5G-PDP-INTEGRATION — tenant-isolation hardening for the
-- commercial-readiness read contract that the Product Detail Page will call.
--
-- WHY: fn_product_commercial_readiness_badge and fn_product_commercial_asset_readiness
-- are SECURITY DEFINER (search_path='') and EXECUTE-granted to `authenticated`, but
-- neither verified auth.uid() against the product owner. They look up a product's
-- owner purely to read its commercial-readiness, so ANY authenticated user could read
-- ANOTHER tenant's product readiness by passing a foreign product_id. Stage 5G wires
-- the badge into the PDP (client-side), so it must be tenant-safe first.
--
-- MINIMAL, NON-WEAKENING FIX (no logic/contract change to the readiness resolver):
--   1. Owner-gate the BADGE (the PDP's entry point): when auth.uid() is a non-owner,
--      return a safe unauthorized badge. A NULL auth.uid() (service_role / internal
--      SECURITY DEFINER callers running as owner, and selftests) is allowed through,
--      so fn_monday_top_opportunities / fn_product_page_builder_context /
--      fn_store_website_product and the page-builder selftest are unaffected.
--   2. REVOKE direct `authenticated` EXECUTE on fn_product_commercial_asset_readiness
--      so it is no longer client-callable with an arbitrary product_id. Internal
--      SECURITY DEFINER callers (run as owner) and the gated badge still invoke it;
--      service_role retains EXECUTE. Its body is unchanged (lowest regression risk).
--
-- Preserves: Product Asset Lock, exact-SKU verification, media-rights classification,
-- economics/identity contracts, and all internal/service callers. Fully reversible.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_commercial_readiness_badge(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r jsonb; st text; v_uid uuid := auth.uid(); v_owner uuid;
BEGIN
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('readiness','PRODUCT_NOT_FOUND','testability','NOT_CURRENTLY_LAUNCHABLE',
      'label','Commercial assets: unavailable','reason','product_not_found'); END IF;
  IF v_uid IS NOT NULL AND v_uid <> v_owner THEN
    RETURN jsonb_build_object('readiness','UNAUTHORIZED','testability','NOT_CURRENTLY_LAUNCHABLE',
      'label','Commercial assets: unavailable','reason','unauthorized'); END IF;

  r := public.fn_product_commercial_asset_readiness(p_product_id, p_market);
  st := coalesce(r->>'commercial_asset_readiness', 'UNKNOWN');
  RETURN jsonb_build_object(
    'readiness', st,
    'testability', coalesce(r->>'commercial_testability','NOT_CURRENTLY_LAUNCHABLE'),
    'label', CASE st
      WHEN 'READY' THEN 'Commercial assets: Ready'
      WHEN 'GENERATABLE_FROM_AUTHORIZED_REFERENCE' THEN 'Commercial assets: Generatable from authorized supplier reference'
      WHEN 'SUPPLIER_ASSET_REQUIRED' THEN 'Commercial assets: Supplier asset required'
      WHEN 'CUSTOMER_ASSET_REQUIRED' THEN 'Commercial assets: Customer image required'
      WHEN 'UNAVAILABLE' THEN 'Commercial assets: Unavailable'
      ELSE 'Commercial assets: Rights verification pending' END,
    'reason', coalesce(r->>'basis','Rights verification pending.'));
END; $function$;

REVOKE EXECUTE ON FUNCTION public.fn_product_commercial_readiness_badge(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_product_commercial_readiness_badge(uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fn_product_commercial_readiness_badge(uuid, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_product_commercial_readiness_badge(uuid, text) TO service_role;

-- Underlying resolver: no longer directly client-callable (internal SECURITY DEFINER
-- callers run as owner; service_role retained; the gated badge is the client entry point).
REVOKE EXECUTE ON FUNCTION public.fn_product_commercial_asset_readiness(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.fn_product_commercial_asset_readiness(uuid, text) FROM authenticated;

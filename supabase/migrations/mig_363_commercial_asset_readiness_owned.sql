-- mig_363_commercial_asset_readiness_owned.sql
-- PREPARED — NOT YET APPLIED (awaiting founder approval).
--
-- Fixes the 42501 "permission denied for function fn_product_commercial_asset_readiness"
-- raised when the Product commerce-actions panel reads commercial-asset readiness.
--
-- Root cause (verified in frontend source at commit 309aaee):
--   src/lib/commerce/commerce-actions-api.ts  fetchCommercialAssetReadiness()  calls the
--   service-role-ONLY helper fn_product_commercial_asset_readiness DIRECTLY as the browser
--   (authenticated) role (reached from product-commerce-actions.tsx). The helper is
--   correctly service-only and is NOT auth.uid()-scoped, so the direct call fails CLOSED
--   (42501) — tenant isolation stays intact, but the panel's commercial-readiness line and
--   the AI product-image-generation UI lose their data.
--
-- Why not the existing slim wrapper: fn_product_commercial_readiness_badge returns only
--   {readiness,testability,label,reason}. The commerce-actions panel needs the FULL object
--   (ai_generation.execution_state, validated_generated_assets, basis, supplier match,
--   images, …). A frontend swap to the slim badge wrapper would BREAK the AI-generation UI.
--
-- Fix: a NEW tenant-scoped wrapper that returns the full helper output AFTER an ownership
--   check — mirroring fn_product_commercial_readiness_badge's security pattern. The unscoped
--   helper's service-role-only grant is UNCHANGED (never granted to authenticated).
--
-- SECURITY: authenticated may call this wrapper; it enforces auth.uid() = product owner
--   (else 'unauthorized') before returning the helper output (called in definer context).
--   Zero-residue SIM confirmed: owner -> full object (status ok, ai_generation present);
--   cross-tenant -> 'unauthorized'; missing product -> 'product_not_found'.

CREATE OR REPLACE FUNCTION public.fn_product_commercial_asset_readiness_owned(
    p_product_id uuid,
    p_market text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_owner uuid;
BEGIN
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('status','product_not_found',
      'commercial_asset_readiness','UNAVAILABLE','commercial_testability','NOT_CURRENTLY_LAUNCHABLE');
  END IF;
  IF v_uid IS NULL OR v_uid <> v_owner THEN
    RETURN jsonb_build_object('status','unauthorized',
      'commercial_asset_readiness','UNAVAILABLE','commercial_testability','NOT_CURRENTLY_LAUNCHABLE');
  END IF;
  -- Owner confirmed: return the full readiness object (helper runs in definer context;
  -- the unscoped helper itself is NOT exposed to authenticated).
  RETURN public.fn_product_commercial_asset_readiness(p_product_id, p_market);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_commercial_asset_readiness_owned(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_product_commercial_asset_readiness_owned(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_product_commercial_asset_readiness_owned(uuid, text) TO authenticated, service_role;

-- NOTE: fn_product_commercial_asset_readiness (the unscoped helper) is intentionally left
-- untouched and MUST remain service-role-only. Do NOT grant it to authenticated.

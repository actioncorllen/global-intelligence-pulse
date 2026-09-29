-- ============================================================================
-- mig_327_readiness_resolve_available_coalesce.sql
-- Authoritative, NULL-safe body of fn_product_commercial_asset_readiness for the
-- Commercial Asset Rights & Recovery Engine (mig_324).
--
-- Canonical readiness states: READY / GENERATABLE_FROM_AUTHORIZED_REFERENCE /
-- SUPPLIER_ASSET_REQUIRED / CUSTOMER_ASSET_REQUIRED / UNAVAILABLE / UNKNOWN.
-- Gemini eligibility requires an ACTUAL usable authorized reference (customer-
-- owned, supplier-authorized asset, or a resolvable supplier primary) — never a
-- mere supplier identity match and never marketplace/competitor/social imagery.
-- Adds rights (from fn_product_commercial_rights), supplier_match confidence,
-- commercial_testability, checked_at. Every prior key preserved (backward
-- compatible with Product Card, My Store, and the commercial-image-generate
-- edge function).
--
-- NULL-safety: image aggregates and v_resolve_available are coalesced to false
-- so reference_eligible/execution_state are always proper booleans/states.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_commercial_asset_readiness(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_sup jsonb; v_resolve jsonb; v_state text; v_provider text;
  v_has_supplier_authorized boolean := false; v_has_customer_owned boolean := false;
  v_has_marketplace boolean := false; v_total_images int := 0;
  v_readiness text; v_path text; v_basis text; v_gemini_eligible boolean;
  v_provider_connected boolean; v_exec_state text; v_validated_generated int := 0;
  v_has_supplier boolean; v_resolve_available boolean; v_usable_reference boolean;
  v_rights jsonb; v_testability text; v_ref_basis text;
BEGIN
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  SELECT
    count(*),
    coalesce(bool_or(rights_state='SUPPLIER_PROVIDED'), false),
    coalesce(bool_or(rights_state='CUSTOMER_OWNED' AND source_provider='CUSTOMER_UPLOAD'
            AND coalesce(provenance->>'rights_confirmed','false')='true'), false),
    coalesce(bool_or(rights_state='MARKETPLACE_PUBLIC_LISTING'), false)
  INTO v_total_images, v_has_supplier_authorized, v_has_customer_owned, v_has_marketplace
  FROM public.product_image_assets
  WHERE product_id = p_product_id AND coalesce(is_fixture,false)=false;

  v_sup := public.fn_product_supplier_identity(p_product_id);
  v_provider := v_sup->>'provider';
  v_has_supplier := coalesce((v_sup->>'has_supplier')::boolean, false);
  IF v_has_supplier THEN
    v_resolve := public.fn_resolve_storefront_assets(v_provider, v_sup->>'supplier_product_id', p_market);
    v_state := v_resolve->>'state';
  END IF;
  v_resolve_available := coalesce(v_state = 'ASSETS_AVAILABLE', false);
  v_rights := public.fn_product_commercial_rights(p_product_id);
  v_usable_reference := v_has_customer_owned OR v_has_supplier_authorized OR v_resolve_available;

  v_provider_connected := coalesce((public.fn_commercial_image_provider_status()->>'connected')::boolean, false);
  SELECT count(*) INTO v_validated_generated FROM public.commerce_generated_assets
   WHERE product_id = p_product_id AND identity_validation_status='IDENTITY_VALIDATED';

  IF v_resolve_available OR v_has_customer_owned THEN
    v_readiness := 'READY';
    v_path := CASE WHEN v_has_customer_owned AND NOT v_resolve_available THEN 'CUSTOMER_OWNED_ASSET'
                   ELSE 'SUPPLIER_AUTHORIZED_COMMERCIAL_ASSET' END;
    v_basis := CASE WHEN v_has_customer_owned AND NOT v_resolve_available
                 THEN 'A rights-confirmed customer-owned product image is available.'
                 ELSE 'Connected supplier provides a rights-cleared product image for this exact supplier product.' END;
  ELSIF v_has_supplier_authorized THEN
    v_readiness := 'GENERATABLE_FROM_AUTHORIZED_REFERENCE'; v_path := 'SUPPLIER_AUTHORIZED_REFERENCE';
    v_basis := 'An authorized supplier reference exists; a commercial image can be generated from it (identity-validated) rather than republishing a marketplace image.';
  ELSIF v_has_supplier THEN
    v_readiness := 'SUPPLIER_ASSET_REQUIRED'; v_path := 'SUPPLIER_ASSET_RECOVERY';
    v_basis := 'The product is matched to a connected supplier, but a supplier-authorized commercial asset has not yet been obtained. Supplier asset recovery is required before generation or publication.';
  ELSIF v_has_marketplace THEN
    v_readiness := 'CUSTOMER_ASSET_REQUIRED'; v_path := 'NONE';
    v_basis := 'Only marketplace/reference imagery is available. Image access is not republishing rights, so a customer-owned or supplier-authorized image is required to publish.';
  ELSIF v_total_images = 0 THEN
    v_readiness := 'UNAVAILABLE'; v_path := 'NONE';
    v_basis := 'No product imagery has been observed for this product.';
  ELSE
    v_readiness := 'UNKNOWN'; v_path := 'NONE';
    v_basis := 'Product imagery exists but its commercial rights/provenance could not be determined reliably. Rights verification is required before publication.';
  END IF;

  v_gemini_eligible := v_usable_reference;
  v_ref_basis := CASE
    WHEN v_has_customer_owned THEN 'CUSTOMER_OWNED'
    WHEN v_has_supplier_authorized OR v_resolve_available THEN 'SUPPLIER_AUTHORIZED'
    ELSE 'NONE' END;

  v_exec_state := CASE
    WHEN NOT v_gemini_eligible THEN 'NOT_ELIGIBLE'
    WHEN v_provider_connected THEN 'AVAILABLE'
    ELSE 'BLOCKED_EXTERNAL_CONNECTION' END;

  v_testability := CASE v_readiness
    WHEN 'READY' THEN 'READY_TO_TEST'
    WHEN 'GENERATABLE_FROM_AUTHORIZED_REFERENCE' THEN 'ASSET_GENERATION_AVAILABLE'
    WHEN 'SUPPLIER_ASSET_REQUIRED' THEN 'ASSET_RECOVERY_REQUIRED'
    WHEN 'CUSTOMER_ASSET_REQUIRED' THEN 'CUSTOMER_ACTION_REQUIRED'
    ELSE 'NOT_CURRENTLY_LAUNCHABLE' END;

  RETURN jsonb_build_object(
    'status','ok','product_id', p_product_id, 'market', upper(coalesce(p_market,'')),
    'checked_at', now(),
    'commercial_asset_readiness', v_readiness,
    'commercial_testability', v_testability,
    'publishable_asset_path', v_path, 'basis', v_basis,
    'has_supplier_match', v_has_supplier,
    'supplier_provider', v_provider, 'supplier_product_id', v_sup->>'supplier_product_id',
    'supplier_resolution_state', coalesce(v_state,'NOT_RESOLVED'),
    'supplier_match', jsonb_build_object(
      'matched', v_has_supplier,
      'confidence', CASE WHEN v_has_supplier THEN 'EXACT' ELSE 'NO_MATCH' END,
      'provider', v_provider, 'supplier_product_id', v_sup->>'supplier_product_id',
      'basis', CASE WHEN v_has_supplier THEN 'Explicit stored supplier link (exact product/SKU).'
                    ELSE 'No connected-supplier product match established.' END),
    'rights', v_rights,
    'validated_generated_assets', v_validated_generated,
    'images', jsonb_build_object('total', v_total_images,
      'has_supplier_authorized', v_has_supplier_authorized,
      'has_customer_owned', v_has_customer_owned,
      'has_marketplace_reference', v_has_marketplace),
    'ai_generation', jsonb_build_object(
      'reference_eligible', v_gemini_eligible,
      'reference_basis', v_ref_basis,
      'provider','GOOGLE_GEMINI', 'provider_connected', v_provider_connected,
      'execution_state', v_exec_state,
      'requires', CASE
        WHEN v_exec_state='AVAILABLE'
          THEN 'Ready: a publishable image can be generated from the authorized reference, then identity-validated before use.'
        WHEN v_exec_state='NOT_ELIGIBLE' AND v_readiness='SUPPLIER_ASSET_REQUIRED'
          THEN 'Supplier matched but no authorized asset obtained yet. Recover the supplier-authorized asset before generation; marketplace/competitor imagery is never an eligible reference.'
        WHEN v_exec_state='NOT_ELIGIBLE'
          THEN 'No eligible authorized reference. Marketplace/competitor imagery is never an eligible reference; a customer-owned or supplier-authorized image is required.'
        ELSE 'Google Gemini image-generation access is not connected.' END,
      'product_asset_lock','Generated output must preserve exact product identity/SKU and pass identity validation (IDENTITY_VALIDATED) before it becomes a commercial asset; a materially different SKU is REJECT_GENERATED_ASSET.'),
    'note','Marketplace/reference images are never a publishable or generation-eligible source. Rights are never fabricated.');
END; $function$;

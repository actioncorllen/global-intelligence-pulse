-- ============================================================================
-- mig_323_generated_asset_selection_and_list.sql
-- STRATELOQ — Generated commercial asset selection + listing for the secure
-- one-click Gemini flow (review -> Use This Image).
--
--   * selected / selected_at columns on commerce_generated_assets.
--   * fn_product_generated_assets(product): lists a caller-owned product's
--     generated candidates for in-app review (tenant-scoped).
--   * fn_commercial_generated_asset_use(id): "Use This Image" — selects an
--     IDENTITY_VALIDATED candidate as the product's chosen commercial image.
--     Non-destructive, never auto-publishes, and a REJECT_GENERATED_ASSET can
--     never be selected. Original supplier/reference asset unchanged.
-- Idempotent. RLS/tenant isolation preserved.
-- ============================================================================
ALTER TABLE public.commerce_generated_assets
  ADD COLUMN IF NOT EXISTS selected boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS selected_at timestamptz;

CREATE OR REPLACE FUNCTION public.fn_product_generated_assets(p_product_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_owner uuid;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  RETURN jsonb_build_object('ok',true,'product_id',p_product_id,
    'generated_assets', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'generated_asset_id', id, 'generation_provider', generation_provider, 'generation_model', generation_model,
        'reference_provider', reference_provider, 'reference_rights_state', reference_rights_state,
        'identity_validation_status', identity_validation_status,
        'commercial_asset_status', commercial_asset_status, 'selected', selected,
        'storage_bucket', storage_bucket, 'storage_ref', storage_ref,
        'created_at', created_at) ORDER BY created_at DESC)
      FROM public.commerce_generated_assets WHERE product_id=p_product_id AND tenant_id=v_tenant),'[]'::jsonb));
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_commercial_generated_asset_use(p_generated_asset_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); ga record;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO ga FROM public.commerce_generated_assets WHERE id=p_generated_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','generated_asset_not_found'); END IF;
  IF ga.tenant_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  IF ga.identity_validation_status <> 'IDENTITY_VALIDATED' THEN
    RETURN jsonb_build_object('ok',false,'error','not_identity_validated',
      'identity_validation_status', ga.identity_validation_status,
      'message','Only an identity-validated generated image can be selected.');
  END IF;
  UPDATE public.commerce_generated_assets SET selected=false, updated_at=now()
    WHERE product_id=ga.product_id AND tenant_id=v_tenant AND id<>p_generated_asset_id AND selected;
  UPDATE public.commerce_generated_assets
    SET selected=true, selected_at=now(), commercial_asset_status='GENERATED_VALIDATED', updated_at=now()
    WHERE id=p_generated_asset_id;
  RETURN jsonb_build_object('ok',true,'status','SELECTED','generated_asset_id',p_generated_asset_id,
    'product_id', ga.product_id, 'selected', true, 'auto_published', false,
    'note','Selected as this product''s commercial image candidate. Publishing still runs through the normal review/publish gates; nothing is auto-published, and the original supplier/reference asset is unchanged.');
END; $function$;

-- ============================================================================
-- mig_318_attach_defaults_storefront_visible.sql
-- STRATELOQ — Create Free Store / Add Product must auto-build the website: a product
-- attached to the hosted store defaults to website-visible so it appears in the
-- storefront catalog immediately (the merchant can hide it later via
-- fn_store_set_product_visibility). Only the visibility default changes; the attach
-- contract, runtime generation (mig_315) and one-store invariant are unchanged.
-- Idempotent (CREATE OR REPLACE).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_store_attach_product(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); cp record; s public.commerce_hosted_stores%rowtype;
  sp record; v_img jsonb; v_has_image boolean; v_build jsonb; v_page_id uuid; v_market text := upper(nullif(btrim(coalesce(p_market,'')),''));
  v_is_new boolean := false; v_reactivated boolean := false; v_mode_action text;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF cp.user_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  v_img := public.fn_product_card_display_image(v_tenant, p_product_id, v_market);
  v_has_image := (v_img->>'has_image')::boolean;
  IF NOT v_has_image THEN
    RETURN jsonb_build_object('ok',false,'status','IMPORT_REQUIRED','gate','AUTHORITATIVE_ASSET_REQUIRED',
      'error','no_product_image','action','IMPORT_PRODUCT_IMAGES',
      'message','Add your product images so Strateloq can create ads and product pages using the correct product.');
  END IF;
  s := public.fn_hosted_store_get_or_create(v_tenant, NULL);
  SELECT * INTO sp FROM public.commerce_store_products WHERE hosted_store_id=s.id AND product_id=p_product_id;
  IF s.store_mode='ONE_PRODUCT' AND s.active_product_id IS NOT NULL AND s.active_product_id <> p_product_id THEN
    RETURN jsonb_build_object('ok',false,'status','REPLACE_REQUIRED','hosted_store_id',s.id,
      'active_product_id',s.active_product_id,'action','REPLACE_CURRENT_PRODUCT',
      'message','This store already features a different product. Choose Add Product (keep both) or Replace Current Product.');
  END IF;
  IF sp.id IS NULL THEN
    INSERT INTO public.commerce_store_products(hosted_store_id, user_id, product_id, lifecycle_state, market, storefront_visible, provenance)
    VALUES (s.id, v_tenant, p_product_id, 'UNPUBLISHED', v_market, true, jsonb_build_object('attached_by','fn_store_attach_product'))
    ON CONFLICT (hosted_store_id, product_id) DO NOTHING
    RETURNING * INTO sp;
    IF sp.id IS NULL THEN SELECT * INTO sp FROM public.commerce_store_products WHERE hosted_store_id=s.id AND product_id=p_product_id; END IF;
    v_is_new := true;
  END IF;
  IF sp.product_page_id IS NULL THEN
    v_build := public.fn_product_card_create_store(p_product_id, coalesce(v_market, sp.market));
    v_page_id := coalesce(nullif(v_build->>'product_page_id',''), v_build->'storefront'->>'product_page_id')::uuid;
    IF v_page_id IS NOT NULL THEN
      UPDATE public.commerce_store_products
         SET product_page_id=v_page_id, lifecycle_state='ACTIVE', market=coalesce(v_market,market),
             storefront_visible=true, updated_at=now()
       WHERE id=sp.id;
    END IF;
  ELSE
    v_build := jsonb_build_object('reused_existing_page', true, 'product_page_id', sp.product_page_id);
    v_page_id := sp.product_page_id;
    IF coalesce(sp.lifecycle_state,'') NOT IN ('ACTIVE','SOLD_OUT','PAUSED') THEN
      UPDATE public.commerce_store_products
         SET lifecycle_state='ACTIVE', market=coalesce(v_market,market), storefront_visible=true, updated_at=now()
       WHERE id=sp.id;
      v_reactivated := true;
    END IF;
  END IF;
  IF s.store_mode='ONE_PRODUCT' AND s.active_product_id IS NULL THEN
    UPDATE public.commerce_hosted_stores SET active_product_id=p_product_id, updated_at=now() WHERE id=s.id;
  END IF;
  v_mode_action := CASE WHEN v_is_new OR v_reactivated THEN 'ADDED' ELSE 'UPDATED' END;
  RETURN jsonb_build_object('ok',true,'status',v_mode_action,'hosted_store_id',s.id,'store_mode',s.store_mode,
    'store_product_id',sp.id,'product_id',p_product_id,'product_page_id',v_page_id,
    'storefront_visible',true,'reactivated',v_reactivated,'duplicate_prevented',(NOT v_is_new AND NOT v_reactivated),
    'display_image_used',v_img->>'url','build', v_build);
END; $function$;

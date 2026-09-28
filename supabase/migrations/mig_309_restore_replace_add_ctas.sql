-- ============================================================================
-- mig_309_restore_replace_add_ctas.sql
-- STRATELOQ — restore the founder-locked explicit STATE 3 CTAs.
-- ----------------------------------------------------------------------------
-- mig_308 correctly made STATE 2 (this product IN the store) show MANAGE_STORE only
-- (no redundant Publish), but it also replaced the STATE 3 action with a generic
-- "Publish to Store" that hid a required replacement behind a later dialog. Founder
-- override: a ONE_PRODUCT store that already holds a DIFFERENT active product must
-- show REPLACE CURRENT PRODUCT up-front (the customer understands before clicking
-- that the current store product will be replaced). Only STATE 3 changes here.
--
-- Deterministic machine (unchanged except STATE 3):
--   STATE 1 no store                         -> CREATE_FREE_STORE (+ CONNECT_STORE)
--   STATE 2 this product IN store            -> MANAGE_STORE only
--   STATE 3 store exists, this product NOT in store:
--     ONE_PRODUCT + a different active product -> REPLACE_CURRENT_PRODUCT
--     otherwise (MULTI_PRODUCT / empty store)  -> ADD_TO_STORE
--   external store connected (no hosted)     -> PUBLISH_TO_STORE / Update Store Product
-- CREATE_AD always present; IMPORT only when the card has zero images. Replacement
-- still uses fn_store_replace_active_product (same persistent store, prior product
-- -> REPLACED). No duplicate store, no renamed contracts. Idempotent.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_card_commerce_actions(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_owner uuid; v_auth jsonb; v_has_auth boolean;
  v_has_display boolean; v_display_count int;
  hs public.commerce_hosted_stores%rowtype; v_has_hosted boolean := false; spr record; v_attached boolean := false;
  v_conn record; v_pushable boolean := false; v_ext boolean := false;
  v_page record; v_page_state text; v_pub_state text := 'UNPUBLISHED'; v_published_url text; v_page_id uuid;
  v_market text := nullif(btrim(coalesce(p_market,'')),''); v_actions jsonb := '[]'::jsonb; v_readiness text;
  v_ent jsonb; v_is_active boolean := false; v_this_lifecycle text; v_in_store boolean := false;
  c_gate constant text := 'An approved product image is required before Strateloq can continue.';
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_auth := public.fn_ad_product_card_authority(v_tenant, p_product_id, v_market);
  v_has_auth := coalesce((v_auth->>'authoritative_count')::int,0) > 0;
  SELECT count(*) INTO v_display_count FROM public.product_image_assets
    WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false;
  v_has_display := v_display_count > 0;

  SELECT * INTO hs FROM public.commerce_hosted_stores
    WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  v_has_hosted := FOUND;
  IF v_has_hosted THEN
    SELECT * INTO spr FROM public.commerce_store_products WHERE hosted_store_id=hs.id AND product_id=p_product_id;
    v_attached := FOUND; v_this_lifecycle := spr.lifecycle_state; v_is_active := (hs.active_product_id = p_product_id);
    v_in_store := v_attached AND coalesce(v_this_lifecycle,'ACTIVE') IN ('ACTIVE','SOLD_OUT','PAUSED');
  END IF;

  SELECT * INTO v_conn FROM public.commerce_store_connections
    WHERE user_id=v_tenant AND connection_state='CONNECTED' AND provider IN ('SHOPIFY','WOOCOMMERCE')
    ORDER BY connected_at DESC NULLS LAST LIMIT 1;
  v_pushable := FOUND;
  v_ext := EXISTS(SELECT 1 FROM public.commerce_store_connections
     WHERE user_id=v_tenant AND connection_state='CONNECTED' AND provider='EXTERNAL_STORE');

  SELECT * INTO v_page FROM public.commerce_product_pages
    WHERE user_id=v_tenant AND product_id=p_product_id
      AND (v_market IS NULL OR market=v_market OR country_code=v_market)
    ORDER BY updated_at DESC LIMIT 1;
  IF FOUND THEN v_page_id:=v_page.id; v_page_state:=v_page.status;
    v_pub_state:=coalesce(v_page.publication_state,'UNPUBLISHED'); v_published_url:=v_page.published_url; END IF;

  v_readiness := CASE WHEN v_has_display THEN 'READY' ELSE 'NO_IMAGE' END;

  v_actions := jsonb_build_array(jsonb_build_object('key','CREATE_AD','label','Create Ad','enabled',v_has_display,
    'reason', CASE WHEN v_has_display THEN 'product_image_available' ELSE 'product_image_required' END,
    'route','creative_studio')
    || CASE WHEN v_has_display THEN '{}'::jsonb
            ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END);

  IF v_has_hosted THEN
    IF v_in_store THEN
      -- STATE 2: this product is currently in the persistent store -> Manage Store only.
      v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','MANAGE_STORE','label','Manage Store',
        'enabled',true,'reason','this_product_in_store','route','store_manager','hosted_store_id',hs.id,
        'store_mode',hs.store_mode,'slug',hs.slug,'public_route',hs.public_route,
        'this_product_is_active',v_is_active,'product_page_id',coalesce(spr.product_page_id,v_page_id),
        'publication_state',v_pub_state));
    ELSIF hs.store_mode='ONE_PRODUCT' AND hs.active_product_id IS NOT NULL AND hs.active_product_id <> p_product_id THEN
      -- STATE 3a: one-product store already holds a different active product -> explicit Replace.
      v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','REPLACE_CURRENT_PRODUCT','label','Replace Current Product',
        'enabled', v_has_display,
        'reason', CASE WHEN v_has_display THEN 'one_product_store_swap' ELSE 'product_image_required' END,
        'route','create_free_store','hosted_store_id',hs.id,'store_mode',hs.store_mode,
        'current_active_product_id', hs.active_product_id,
        'product_page_id', coalesce(spr.product_page_id, v_page_id))
        || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
    ELSE
      -- STATE 3b: multi-product store (or empty one-product store), this product not attached -> Add.
      v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','ADD_TO_STORE','label','Add to Store',
        'enabled', v_has_display,
        'reason', CASE WHEN v_has_display THEN 'ready' ELSE 'product_image_required' END,
        'route','create_free_store','hosted_store_id',hs.id,'store_mode',hs.store_mode,
        'product_page_id', coalesce(spr.product_page_id, v_page_id))
        || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
    END IF;
  ELSIF v_pushable THEN
    -- Existing-store pathway (Shopify/WooCommerce).
    v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','PUBLISH_TO_STORE',
      'label', CASE WHEN v_pub_state='PUBLISHED' THEN 'Update Store Product' ELSE 'Publish to Store' END,
      'enabled', (v_has_display AND v_page_id IS NOT NULL),
      'reason', CASE WHEN NOT v_has_display THEN 'product_image_required'
                     WHEN v_page_id IS NULL THEN 'create_store_page_first' ELSE 'ready' END,
      'provider',v_conn.provider,'store_connection_id',v_conn.id,'product_page_id',v_page_id)
      || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
  ELSE
    -- STATE 1: no Strateloq store yet.
    v_ent := public.fn_hosted_store_entitlement(v_tenant);
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','CREATE_FREE_STORE','label','Create Free Store',
      'enabled', (v_ent->>'eligible')::boolean,
      'reason', CASE WHEN (v_ent->>'eligible')::boolean THEN 'entitled' ELSE 'subscription_required' END,
      'route','create_free_store',
      'message','No setup fee — hosting included in your Strateloq subscription.','entitlement', v_ent));
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','CONNECT_STORE',
      'label','Connect Your Store','enabled',true,'reason','no_store_connected','route','store_connection'));
  END IF;

  IF NOT v_has_display THEN
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','IMPORT_PRODUCT_IMAGES',
      'label','Import Product Images','enabled',true,'reason','no_product_image','route','image_import',
      'message','Add your product images so Strateloq can create ads and product pages using the correct product.'));
  END IF;

  RETURN jsonb_build_object('ok',true,'product_id',p_product_id,'market',v_market,'readiness',v_readiness,
    'image_authority', jsonb_build_object(
       'has_display_image', v_has_display, 'display_image_count', v_display_count,
       'has_authoritative_image', v_has_auth, 'authoritative_count', coalesce((v_auth->>'authoritative_count')::int,0),
       'needs_authoritative_image', (NOT v_has_auth), 'needs_import', (NOT v_has_display),
       'primary_asset', v_auth->'primary_asset'),
    'hosted_store', CASE WHEN v_has_hosted THEN jsonb_build_object('exists',true,'hosted_store_id',hs.id,
        'store_mode',hs.store_mode,'status',hs.status,'slug',hs.slug,'public_route',hs.public_route,
        'active_product_id',hs.active_product_id,
        'this_product_attached',v_attached,'this_product_is_active',v_is_active,
        'this_product_in_store',v_in_store,'this_product_lifecycle',v_this_lifecycle)
      ELSE jsonb_build_object('exists',false) END,
    'store_connection', jsonb_build_object('pushable_connected',v_pushable,
       'provider', CASE WHEN v_pushable THEN v_conn.provider ELSE NULL END,
       'connection_id', CASE WHEN v_pushable THEN v_conn.id ELSE NULL END,
       'external_link_present',v_ext),
    'product_page', jsonb_build_object('page_id',v_page_id,'status',v_page_state,
       'publication_state',v_pub_state,'published_url',v_published_url),
    'actions', v_actions);
END; $function$;

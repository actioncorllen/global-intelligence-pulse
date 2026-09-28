-- ============================================================================
-- mig_311_add_product_multi_store_and_store_name.sql
-- STRATELOQ — "My Store access" + ADD PRODUCT without forced replacement.
-- ----------------------------------------------------------------------------
-- Founder refinement: a customer must NOT be forced to Replace Current Product.
-- For a product that is not in the (ONE_PRODUCT) store they must be offered a
-- choice — ADD PRODUCT (keep the current product, convert the SAME store to
-- MULTI_PRODUCT) or REPLACE CURRENT PRODUCT (swap in the same store). This
-- extends the existing persistent hosted-store architecture; it does not rebuild
-- hosted stores, the ProductPageBuilder, Product Cards, storefront publishing,
-- Product Asset Lock or Creative Studio.
--
-- Changes (all idempotent, CREATE OR REPLACE / additive):
--   1. fn_store_display_name(jsonb)          — resolve a customer-facing store name
--                                              (display_name -> store_name ->
--                                               "{Business Name} Store" -> "My Store").
--   2. fn_store_set_display_name(text)        — edit the store name later WITHOUT
--                                              changing hosted_store_id, slug,
--                                              product history, published URLs or
--                                              ownership (writes brand_settings.display_name).
--   3. fn_store_convert_to_multi_product()    — SAME store, ONE_PRODUCT -> MULTI_PRODUCT
--                                              only, idempotent, non-destructive,
--                                              preserves products/history/pages/active.
--   4. fn_hosted_store_get()                  — now returns hosted_store.display_name.
--   5. fn_product_card_commerce_actions()     — STATE 3 now offers BOTH Add Product
--                                              and Replace Current Product for a
--                                              ONE_PRODUCT store holding a different
--                                              active product; MULTI_PRODUCT (or empty)
--                                              offers Add Product directly. Backend key
--                                              stays ADD_TO_STORE; customer label is
--                                              "Add Product". Carries requires_mode_conversion
--                                              so the client can confirm + convert.
-- No table/enum renames. anon cannot execute the new mutating RPCs. Browsers must
-- never write commerce_hosted_stores directly — the conversion goes through the RPC.
-- ============================================================================

-- 1) Customer-facing store-name resolver (no new column needed; uses brand_settings jsonb).
CREATE OR REPLACE FUNCTION public.fn_store_display_name(p_brand jsonb)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $fn$
  SELECT coalesce(
    nullif(btrim(coalesce(p_brand->>'display_name','')),''),
    nullif(btrim(coalesce(p_brand->>'store_name','')),''),
    CASE WHEN nullif(btrim(coalesce(p_brand->>'business_name','')),'') IS NOT NULL
         THEN btrim(p_brand->>'business_name') || ' Store' END,
    'My Store');
$fn$;

-- 2) Editable store name (persistent identity preserved). Writes brand_settings.display_name only.
CREATE OR REPLACE FUNCTION public.fn_store_set_display_name(p_name text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype; v_name text := btrim(coalesce(p_name,''));
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  IF v_name = '' THEN RETURN jsonb_build_object('ok',false,'error','name_required'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores
    WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_hosted_store'); END IF;
  UPDATE public.commerce_hosted_stores
     SET brand_settings = coalesce(brand_settings,'{}'::jsonb) || jsonb_build_object('display_name', v_name),
         updated_at = now()
   WHERE id = s.id;
  RETURN jsonb_build_object('ok',true,'hosted_store_id',s.id,'display_name',v_name,
    'note','store name updated; hosted_store_id, slug, product history, published URLs and ownership unchanged');
END; $fn$;

-- 3) Same-store mode conversion ONE_PRODUCT -> MULTI_PRODUCT (idempotent, non-destructive).
CREATE OR REPLACE FUNCTION public.fn_store_convert_to_multi_product()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores
    WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_hosted_store'); END IF;

  IF s.store_mode = 'MULTI_PRODUCT' THEN
    -- idempotent no-op: already multi-product, nothing to change.
    RETURN jsonb_build_object('ok',true,'idempotent',true,'hosted_store_id',s.id,'store_mode','MULTI_PRODUCT',
      'active_product_id',s.active_product_id,'converted',false);
  END IF;
  IF s.store_mode <> 'ONE_PRODUCT' THEN
    RETURN jsonb_build_object('ok',false,'error','unsupported_mode','store_mode',s.store_mode);
  END IF;

  -- ONE_PRODUCT -> MULTI_PRODUCT on the SAME store. Products, lifecycle rows, product
  -- pages and the current active product are all preserved (only store_mode changes).
  UPDATE public.commerce_hosted_stores
     SET store_mode='MULTI_PRODUCT', updated_at=now()
   WHERE id=s.id AND user_id=v_tenant AND store_mode='ONE_PRODUCT';

  RETURN jsonb_build_object('ok',true,'idempotent',false,'hosted_store_id',s.id,'store_mode','MULTI_PRODUCT',
    'active_product_id',s.active_product_id,'converted',true,
    'note','same store; ONE_PRODUCT -> MULTI_PRODUCT; current product preserved; no duplicate store');
END; $fn$;

-- Lock down: authenticated + service_role only; never anon/PUBLIC.
REVOKE EXECUTE ON FUNCTION public.fn_store_set_display_name(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fn_store_convert_to_multi_product() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_store_set_display_name(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_store_convert_to_multi_product() TO authenticated, service_role;

-- 4) fn_hosted_store_get: surface the resolved customer-facing display name.
CREATE OR REPLACE FUNCTION public.fn_hosted_store_get()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores
    WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',true,'has_hosted_store',false); END IF;
  RETURN jsonb_build_object('ok',true,'has_hosted_store',true,
    'hosted_store', jsonb_build_object('hosted_store_id',s.id,'store_mode',s.store_mode,'status',s.status,
       'slug',s.slug,'public_route',s.public_route,'custom_domain',s.custom_domain,
       'display_name', public.fn_store_display_name(s.brand_settings),
       'active_product_id',s.active_product_id,'brand_settings',s.brand_settings,'theme_settings',s.theme_settings),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'store_product_id',sp.id,'product_id',sp.product_id,'product_page_id',sp.product_page_id,
        'lifecycle_state',sp.lifecycle_state,'market',sp.market,'remote_url',sp.remote_url,
        'is_active',(sp.product_id = s.active_product_id)) ORDER BY sp.updated_at DESC)
      FROM public.commerce_store_products sp WHERE sp.hosted_store_id=s.id),'[]'::jsonb));
END; $function$;

-- 5) fn_product_card_commerce_actions: STATE 3 offers Add Product (choice) alongside Replace.
--    Deterministic machine:
--      STATE 1 no store                          -> CREATE_FREE_STORE (+ CONNECT_STORE)
--      STATE 2 this product IN store             -> MANAGE_STORE only
--      STATE 3 store exists, this product NOT in store:
--        ONE_PRODUCT + a different active product -> ADD_TO_STORE (Add Product, requires_mode_conversion)
--                                                    + REPLACE_CURRENT_PRODUCT   (the choice)
--        otherwise (MULTI_PRODUCT / empty store)  -> ADD_TO_STORE (Add Product, direct)
--      external store connected (no hosted)      -> PUBLISH_TO_STORE / Update Store Product
--    CREATE_AD always present; IMPORT only when the card has zero images.
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
  v_needs_convert boolean := false;
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
    ELSE
      -- STATE 3: store exists but this product is not in it.
      -- A ONE_PRODUCT store already holding a DIFFERENT active product requires a mode
      -- conversion before Add Product; the client confirms then converts + attaches.
      v_needs_convert := (hs.store_mode='ONE_PRODUCT' AND hs.active_product_id IS NOT NULL
                          AND hs.active_product_id <> p_product_id);

      -- ADD PRODUCT (choice #1) — never a forced path. Backend key ADD_TO_STORE, label "Add Product".
      v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','ADD_TO_STORE','label','Add Product',
        'enabled', v_has_display,
        'reason', CASE WHEN v_has_display THEN 'ready' ELSE 'product_image_required' END,
        'route','create_free_store','hosted_store_id',hs.id,'store_mode',hs.store_mode,
        'requires_mode_conversion', v_needs_convert,
        'current_active_product_id', hs.active_product_id,
        'product_page_id', coalesce(spr.product_page_id, v_page_id))
        || CASE WHEN v_needs_convert THEN jsonb_build_object(
             'confirm_title','Add this product to your store?',
             'confirm_message','Your current product will stay in the store. Your store will switch to multi-product mode.',
             'convert_call', jsonb_build_object('rpc','fn_store_convert_to_multi_product','args', jsonb_build_object()))
           ELSE '{}'::jsonb END
        || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));

      -- REPLACE CURRENT PRODUCT (choice #2) — only when a ONE_PRODUCT store holds a different active product.
      IF v_needs_convert THEN
        v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','REPLACE_CURRENT_PRODUCT','label','Replace Current Product',
          'enabled', v_has_display,
          'reason', CASE WHEN v_has_display THEN 'one_product_store_swap' ELSE 'product_image_required' END,
          'route','create_free_store','hosted_store_id',hs.id,'store_mode',hs.store_mode,
          'current_active_product_id', hs.active_product_id,
          'product_page_id', coalesce(spr.product_page_id, v_page_id))
          || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
      END IF;
    END IF;
  ELSIF v_pushable THEN
    -- Existing-store pathway (Shopify/WooCommerce). Preserved unchanged.
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
        'display_name', public.fn_store_display_name(hs.brand_settings),
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

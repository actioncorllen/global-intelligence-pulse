-- ============================================================================
-- mig_308_commerce_actions_state_machine.sql
-- STRATELOQ — deterministic Product Card commerce-action state machine.
-- ----------------------------------------------------------------------------
-- Founder-observed defect: Product Cards exposed contradictory primary actions
--   (MANAGE STORE + PUBLISH TO STORE for the SAME already-attached product; and
--    REPLACE CURRENT PRODUCT as a permanent primary action on arbitrary cards).
--
-- One deterministic machine, keyed on USER/BUSINESS store state + this product's
-- relationship to that ONE persistent store (never per Product Card):
--   STATE 1  no hosted store              -> CREATE_FREE_STORE (+ CONNECT_STORE)
--   STATE 2  store + this product IN store -> MANAGE_STORE only
--            (publishing/lifecycle happen inside the builder / Manage Store)
--   STATE 3  store + this product NOT in store -> PUBLISH_TO_STORE only
--            (carries requires_replace_confirmation for a ONE_PRODUCT store that
--             already holds a different active product; REPLACE is a CONFIRMATION
--             inside that flow, never a standalone card action)
--   (external store connected, no hosted store) -> PUBLISH_TO_STORE (existing pathway)
--
-- CREATE_AD is always present. IMPORT_PRODUCT_IMAGES only when the card has ZERO
-- images. Image gating stays on has_display (mig_305). No duplicate store, no
-- renamed contracts, all returned metadata preserved.
-- Idempotent (CREATE OR REPLACE).
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
  v_requires_replace boolean := false;
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
    -- "currently in the store" = attached with a live lifecycle (not replaced/unpublished/archived)
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

  -- CREATE_AD is always available (image-gated).
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
      -- STATE 3: store exists but this product is not in it -> Publish to Store (add/replace).
      v_requires_replace := (hs.store_mode='ONE_PRODUCT' AND hs.active_product_id IS NOT NULL AND hs.active_product_id <> p_product_id);
      v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','PUBLISH_TO_STORE','label','Publish to Store',
        'enabled', v_has_display,
        'reason', CASE WHEN v_has_display THEN 'ready' ELSE 'product_image_required' END,
        'route','create_free_store','hosted_store_id',hs.id,'store_mode',hs.store_mode,
        'requires_replace_confirmation', v_requires_replace,
        'current_active_product_id', hs.active_product_id,
        'product_page_id', coalesce(spr.product_page_id, v_page_id))
        || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
    END IF;
  ELSIF v_pushable THEN
    -- Existing-store pathway (Shopify/WooCommerce). Publish this product's page to the connected store.
    v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','PUBLISH_TO_STORE',
      'label', CASE WHEN v_pub_state='PUBLISHED' THEN 'Update Store Product' ELSE 'Publish to Store' END,
      'enabled', (v_has_display AND v_page_id IS NOT NULL),
      'reason', CASE WHEN NOT v_has_display THEN 'product_image_required'
                     WHEN v_page_id IS NULL THEN 'create_store_page_first' ELSE 'ready' END,
      'provider',v_conn.provider,'store_connection_id',v_conn.id,'product_page_id',v_page_id)
      || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
  ELSE
    -- STATE 1: no Strateloq store yet -> Create Free Store (primary) + Connect Your Store (secondary pathway).
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
       'needs_authoritative_image', (NOT v_has_auth),
       'needs_import', (NOT v_has_display),
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

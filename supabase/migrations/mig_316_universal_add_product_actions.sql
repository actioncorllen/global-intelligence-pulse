-- ============================================================================
-- mig_316_universal_add_product_actions.sql
-- STRATELOQ — canonical Product Card -> Store actions. Founder refinement:
--   • EVERY Product Card exposes CREATE_AD + ADD_TO_STORE ("Add Product"), always.
--   • A NEW USER (no hosted store, no connected external store) also gets
--     CREATE_FREE_STORE + CONNECT_STORE ("Connect Existing Store"), and ADD_TO_STORE
--     opens a destination chooser.
--   • CREATE_FREE_STORE appears ONLY when there is no hosted Strateloq store
--     (1 business -> 1 persistent store).
--   • When a product is already in the hosted store, ADD_TO_STORE stays visible but is
--     idempotent (already_in_store -> "Already in My Store" / View in My Store) and
--     MANAGE_STORE is offered too.
--   • With BOTH a hosted store and a connected external store, ADD_TO_STORE offers a
--     destination choice (My Store vs connected store).
-- Backend stays authoritative and the sole source of which actions appear; the client
-- renders actions[] + the carried state, never re-deriving store state. Backend keys are
-- unchanged (ADD_TO_STORE, CREATE_FREE_STORE, CONNECT_STORE, MANAGE_STORE,
-- REPLACE_CURRENT_PRODUCT, PUBLISH_TO_STORE). No store/page/generator rebuild. Idempotent.
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
  v_conn record; v_pushable boolean := false; v_ext boolean := false; v_has_external boolean := false;
  v_page record; v_page_state text; v_pub_state text := 'UNPUBLISHED'; v_published_url text; v_page_id uuid;
  v_market text := nullif(btrim(coalesce(p_market,'')),''); v_actions jsonb := '[]'::jsonb; v_readiness text;
  v_ent jsonb; v_is_active boolean := false; v_this_lifecycle text; v_in_store boolean := false;
  v_needs_convert boolean := false; v_store_state text; v_needs_choice boolean := false;
  v_spr_page uuid; v_destinations jsonb; v_add jsonb;
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
    v_spr_page := spr.product_page_id;
    v_in_store := v_attached AND coalesce(v_this_lifecycle,'ACTIVE') IN ('ACTIVE','SOLD_OUT','PAUSED');
  END IF;

  SELECT * INTO v_conn FROM public.commerce_store_connections
    WHERE user_id=v_tenant AND connection_state='CONNECTED' AND provider IN ('SHOPIFY','WOOCOMMERCE')
    ORDER BY connected_at DESC NULLS LAST LIMIT 1;
  v_pushable := FOUND;
  v_ext := EXISTS(SELECT 1 FROM public.commerce_store_connections
     WHERE user_id=v_tenant AND connection_state='CONNECTED' AND provider='EXTERNAL_STORE');
  v_has_external := v_pushable OR v_ext;

  SELECT * INTO v_page FROM public.commerce_product_pages
    WHERE user_id=v_tenant AND product_id=p_product_id
      AND (v_market IS NULL OR market=v_market OR country_code=v_market)
    ORDER BY updated_at DESC LIMIT 1;
  IF FOUND THEN v_page_id:=v_page.id; v_page_state:=v_page.status;
    v_pub_state:=coalesce(v_page.publication_state,'UNPUBLISHED'); v_published_url:=v_page.published_url; END IF;

  v_readiness := CASE WHEN v_has_display THEN 'READY' ELSE 'NO_IMAGE' END;
  v_store_state := CASE
     WHEN v_has_hosted AND v_has_external THEN 'HOSTED_AND_EXTERNAL'
     WHEN v_has_hosted THEN 'HOSTED'
     WHEN v_has_external THEN 'EXTERNAL'
     ELSE 'NO_STORE' END;
  v_needs_convert := (v_has_hosted AND hs.store_mode='ONE_PRODUCT'
                      AND hs.active_product_id IS NOT NULL AND hs.active_product_id <> p_product_id);
  -- A destination choice is required when there is nowhere-yet (choose Create Free Store /
  -- Connect Existing Store) OR when both a hosted store and an external store exist.
  v_needs_choice := (v_store_state='NO_STORE') OR (v_store_state='HOSTED_AND_EXTERNAL' AND NOT v_in_store);

  -- CREATE_AD (image-gated) — unchanged.
  v_actions := jsonb_build_array(jsonb_build_object('key','CREATE_AD','label','Create Ad','enabled',v_has_display,
    'reason', CASE WHEN v_has_display THEN 'product_image_available' ELSE 'product_image_required' END,
    'route','creative_studio')
    || CASE WHEN v_has_display THEN '{}'::jsonb
            ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END);

  -- Destination options for the chooser (client renders these when requires_destination_choice).
  v_destinations := CASE
    WHEN v_store_state='NO_STORE' THEN jsonb_build_array(
        jsonb_build_object('key','CREATE_FREE_STORE','label','Create Free Store'),
        jsonb_build_object('key','CONNECT_STORE','label','Connect Existing Store'))
    WHEN v_store_state='HOSTED_AND_EXTERNAL' THEN jsonb_build_array(
        jsonb_build_object('key','ADD_TO_MY_STORE','label','My Store','hosted_store_id',hs.id),
        jsonb_build_object('key','PUBLISH_TO_STORE','label',coalesce(v_conn.provider,'Connected store'),
                           'store_connection_id',v_conn.id,'provider',v_conn.provider))
    ELSE '[]'::jsonb END;

  -- UNIVERSAL ADD_TO_STORE ("Add Product") — present on EVERY card, behaviour is state-aware.
  v_add := jsonb_build_object('key','ADD_TO_STORE','label','Add Product',
      'enabled', v_has_display,
      'reason', CASE WHEN NOT v_has_display THEN 'product_image_required'
                     WHEN v_in_store THEN 'already_in_store'
                     WHEN v_needs_choice THEN 'choose_destination'
                     ELSE 'ready' END,
      'route','create_free_store',
      'store_state', v_store_state,
      'already_in_store', v_in_store,
      'requires_destination_choice', v_needs_choice,
      'requires_mode_conversion', v_needs_convert,
      'hosted_store_id', CASE WHEN v_has_hosted THEN hs.id ELSE NULL END,
      'store_mode', CASE WHEN v_has_hosted THEN hs.store_mode ELSE NULL END,
      'current_active_product_id', CASE WHEN v_has_hosted THEN hs.active_product_id ELSE NULL END,
      'product_page_id', coalesce(v_spr_page, v_page_id),
      'external_provider', CASE WHEN v_pushable THEN v_conn.provider ELSE NULL END,
      'external_connection_id', CASE WHEN v_pushable THEN v_conn.id ELSE NULL END,
      'destinations', v_destinations);
  IF v_in_store THEN
    v_add := v_add || jsonb_build_object('view_in_store', jsonb_build_object(
       'hosted_store_id', hs.id, 'product_page_id', coalesce(v_spr_page, v_page_id),
       'message','Already in My Store'));
  END IF;
  IF v_needs_convert THEN
    v_add := v_add || jsonb_build_object(
       'confirm_title','Add this product to your store?',
       'confirm_message','Your current product will stay in the store. Your store will switch to multi-product mode.',
       'convert_call', jsonb_build_object('rpc','fn_store_convert_to_multi_product','args', jsonb_build_object()));
  END IF;
  IF NOT v_has_display THEN
    v_add := v_add || jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate);
  END IF;
  v_actions := v_actions || jsonb_build_array(v_add);

  -- Conditional store-setup / management actions.
  IF NOT v_has_hosted THEN
    -- New user (no hosted store): Create Free Store + Connect Existing Store, directly on the card.
    v_ent := public.fn_hosted_store_entitlement(v_tenant);
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','CREATE_FREE_STORE','label','Create Free Store',
      'enabled', (v_ent->>'eligible')::boolean AND v_has_display,
      'reason', CASE WHEN NOT v_has_display THEN 'product_image_required'
                     WHEN (v_ent->>'eligible')::boolean THEN 'entitled' ELSE 'subscription_required' END,
      'route','create_free_store',
      'message','No setup fee — hosting included in your Strateloq subscription.','entitlement', v_ent)
      || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END);
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','CONNECT_STORE',
      'label','Connect Existing Store','enabled',true,'reason','no_store_connected','route','store_connection'));
  ELSE
    IF v_in_store THEN
      -- Already in the persistent store -> Manage Store (Add Product stays as "Already in My Store").
      v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','MANAGE_STORE','label','Manage Store',
        'enabled',true,'reason','this_product_in_store','route','store_manager','hosted_store_id',hs.id,
        'store_mode',hs.store_mode,'slug',hs.slug,'public_route',hs.public_route,
        'this_product_is_active',v_is_active,'product_page_id',coalesce(v_spr_page,v_page_id),
        'publication_state',v_pub_state));
    ELSIF v_needs_convert THEN
      -- ONE_PRODUCT store holding a different active product -> keep the explicit Replace choice.
      v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','REPLACE_CURRENT_PRODUCT','label','Replace Current Product',
        'enabled', v_has_display,
        'reason', CASE WHEN v_has_display THEN 'one_product_store_swap' ELSE 'product_image_required' END,
        'route','create_free_store','hosted_store_id',hs.id,'store_mode',hs.store_mode,
        'current_active_product_id', hs.active_product_id,
        'product_page_id', coalesce(v_spr_page, v_page_id))
        || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
    END IF;
  END IF;

  -- Existing external store pathway (Shopify/WooCommerce) preserved.
  IF v_pushable THEN
    v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','PUBLISH_TO_STORE',
      'label', CASE WHEN v_pub_state='PUBLISHED' THEN 'Update Store Product' ELSE 'Publish to Store' END,
      'enabled', (v_has_display AND coalesce(v_spr_page, v_page_id) IS NOT NULL),
      'reason', CASE WHEN NOT v_has_display THEN 'product_image_required'
                     WHEN coalesce(v_spr_page, v_page_id) IS NULL THEN 'create_store_page_first' ELSE 'ready' END,
      'provider',v_conn.provider,'store_connection_id',v_conn.id,'product_page_id',coalesce(v_spr_page, v_page_id))
      || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
  END IF;

  IF NOT v_has_display THEN
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','IMPORT_PRODUCT_IMAGES',
      'label','Import Product Images','enabled',true,'reason','no_product_image','route','image_import',
      'message','Add your product images so Strateloq can create ads and product pages using the correct product.'));
  END IF;

  RETURN jsonb_build_object('ok',true,'product_id',p_product_id,'market',v_market,'readiness',v_readiness,
    'store_state', v_store_state,
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

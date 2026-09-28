-- STRATELOQ — Product Card actions gate on DISPLAY image (not authoritative) +
--             Create Free Store builds a real page for the customer's own product.
-- ============================================================================
-- Founder rule change (supersedes the mig_304 authoritative gate at the ACTION layer):
--   Product Card has >= 1 product image (any provenance, incl. marketplace/reference)
--     -> Create Ad / Create Free Store / Add / Replace / Publish may proceed; NO upload
--        modal merely because authoritative_count = 0.
--   Product Card has 0 images -> Import Product Images (upload first).
--
-- Product Asset Lock / provenance are NOT weakened: marketplace images are never
-- relabelled CUSTOMER_OWNED, and the storefront builder still refuses to present a
-- non-legitimate image (it flags PRODUCT_ASSET_REQUIRED honestly). This migration only
-- stops the ACTION layer from blocking a card that already displays imagery, and it
-- reconnects Create Free Store to the existing builder so a product is actually attached
-- and a Product Page is created (no empty store shell).
--
-- Create Free Store page creation: a customer building THEIR OWN store is not gated by
-- Strateloq's opportunity TEST decision. When a TEST/HIGH_CONFIDENCE_TEST decision exists
-- we keep the opportunity path (fn_generate_storefront_runtime); otherwise we build a
-- customer-authorized draft via the EXISTING fn_create_pulse_store_draft (same builder,
-- same publish lifecycle, same page table). No new builder, no new page table.
-- ============================================================================

-- ── resolve the EXACT Product Card display image (authoritative preferred) ───
CREATE OR REPLACE FUNCTION public.fn_product_card_display_image(p_tenant uuid, p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_auth jsonb; r record;
BEGIN
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('has_image',false,'reason','product_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('has_image',false,'reason','cross_tenant_rejected'); END IF;

  -- prefer an authoritative asset (Product Asset Lock) when present
  v_auth := public.fn_ad_product_card_authority(p_tenant, p_product_id, p_market);
  IF coalesce((v_auth->>'authoritative_count')::int,0) > 0 THEN
    RETURN jsonb_build_object('has_image',true,'is_authoritative',true,
      'url', v_auth->'primary_asset'->>'url', 'asset_id', v_auth->'primary_asset'->>'id',
      'source_provider', v_auth->'primary_asset'->>'source_provider',
      'rights_state', v_auth->'primary_asset'->>'rights_state');
  END IF;

  -- else the EXACT primary display image (any provenance; provenance kept honest)
  SELECT id, image_url, source_provider, rights_state INTO r
  FROM public.product_image_assets
  WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false
  ORDER BY coalesce(is_primary,false) DESC, observed_at DESC NULLS LAST, id
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('has_image',false,'reason','no_product_image'); END IF;

  RETURN jsonb_build_object('has_image',true,'is_authoritative',false,
    'url', r.image_url, 'asset_id', r.id::text, 'source_provider', r.source_provider, 'rights_state', r.rights_state);
END; $function$;

-- ── Create Store / product page for the current product (display-image gated) ─
CREATE OR REPLACE FUNCTION public.fn_product_card_create_store(p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); cp record; v_img jsonb; v_has_image boolean; d record;
  v_market text := upper(nullif(btrim(coalesce(p_market,'')),'')); v_rec text;
  v_gate jsonb; v_decision jsonb; v_context jsonb; v_sel jsonb; v_primary_url text; v_res jsonb; v_page_id uuid;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF cp.user_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  -- GATE: a usable Product Card image (any provenance). 0 images -> import first.
  v_img := public.fn_product_card_display_image(v_tenant, p_product_id, v_market);
  v_has_image := (v_img->>'has_image')::boolean;
  IF NOT v_has_image THEN
    RETURN jsonb_build_object('ok',false,'status','IMPORT_REQUIRED','gate','AUTHORITATIVE_ASSET_REQUIRED',
      'error','no_product_image','action','IMPORT_PRODUCT_IMAGES',
      'message','Add your product images so Strateloq can create ads and product pages using the correct product.');
  END IF;
  v_primary_url := v_img->>'url';

  SELECT * INTO d FROM public.product_opportunity_decisions
    WHERE product_id=p_product_id AND (v_market IS NULL OR upper(country_code)=v_market)
    ORDER BY created_at DESC LIMIT 1;

  IF FOUND AND d.decision IN ('TEST','HIGH_CONFIDENCE_TEST') THEN
    -- Opportunity-driven path (unchanged): reuse fn_generate_storefront_runtime.
    v_market := coalesce(v_market, upper(d.country_code));
    v_rec := 'TEST';
    v_gate := jsonb_build_object(
      'recommendation', v_rec, 'decision_tier', d.opportunity_band,
      'supplier_identity_state', CASE WHEN d.hard_gates->>'supplier'='PASS' THEN 'SUPPLIER_EXACT' ELSE 'WEAK' END,
      'market_supplier_match', CASE WHEN d.hard_gates->>'market_price'='PASS' THEN 'MATCH' ELSE 'NO_MATCH' END,
      'subtype_price_valid', (d.hard_gates->>'market_price'='PASS'),
      'stock_state', CASE WHEN d.hard_gates->>'supplier'='PASS' AND d.hard_gates->>'fulfilment'='PASS' THEN 'IN_STOCK' ELSE 'UNKNOWN' END,
      'economics_state', upper(coalesce(d.economics_ref->>'economics_state','UNKNOWN')),
      'product_confidence', upper(coalesce(d.product_confidence,'UNKNOWN')),
      'fulfilment_evidence', (d.hard_gates->>'fulfilment'='PASS'),
      'no_critical_risk', (d.hard_gates->>'compliance'='PASS' AND coalesce(jsonb_array_length(coalesce(d.decision_blockers,'[]'::jsonb)),0)=0),
      'sourcing_status', '');
    v_decision := jsonb_build_object('recommendation', v_rec, 'classification', d.opportunity_band, 'target_market', v_market,
      'economics', jsonb_build_object('economics_state', upper(coalesce(d.economics_ref->>'economics_state','UNKNOWN')),
          'landed_cost_display', d.economics_ref->>'landed_cost_display'),
      'supplier_execution', jsonb_build_object('economics', jsonb_build_object(
          'landed_cost_original', d.economics_ref->>'landed_cost_original', 'landed_cost_currency', d.market_currency)));
    v_context := jsonb_build_object('product_title', cp.title, 'positioning', coalesce(cp.description,''),
      'display_currency', d.market_currency, 'source_currency', d.market_currency,
      'supplier','CUSTOMER_UPLOAD','supplier_product_id', p_product_id::text,
      'authoritative_primary_image', CASE WHEN (v_img->>'is_authoritative')::boolean THEN v_primary_url ELSE NULL END,
      'supplier_reference', jsonb_build_object('provider', v_img->>'source_provider'));
    v_sel := jsonb_build_object('product_id', p_product_id::text, 'country_code', v_market,
       'ad_match', jsonb_build_object('state','NO_AD_MATCH_YET'));
    v_res := public.fn_generate_storefront_runtime(v_tenant, v_gate, v_sel, v_context, v_decision,
       'PULSE_HOSTED', 'REAL', p_product_id, v_market, d.id, true);
    v_page_id := nullif(v_res->>'product_page_id','')::uuid;
    RETURN jsonb_build_object('ok', ((v_res->>'status') IN ('ok','ok_preview')),
       'product_id',p_product_id,'market',v_market,'opportunity_decision_id',d.id,
       'authorization','OPPORTUNITY_TEST','decision_verdict', d.decision,
       'product_page_id', v_page_id, 'authoritative_primary_image', v_primary_url, 'storefront', v_res);
  END IF;

  -- Customer-authorized path: the customer is building THEIR OWN store for a product
  -- they have chosen to sell. Reuse the EXISTING fn_create_pulse_store_draft builder.
  -- No opportunity TEST decision is required (that gate is for Strateloq's recommendations,
  -- not for a customer's own store). The builder honestly refuses to fabricate an image.
  v_market := coalesce(v_market, '');
  v_decision := jsonb_build_object('recommendation','TEST','classification','CUSTOMER_STORE','target_market',v_market,
     'economics', jsonb_build_object('economics_state','UNKNOWN'),
     'supplier_execution', jsonb_build_object('economics', jsonb_build_object()));
  v_context := jsonb_build_object('product_title', cp.title, 'positioning', coalesce(cp.description,''),
     'authoritative_primary_image', CASE WHEN (v_img->>'is_authoritative')::boolean THEN v_primary_url ELSE NULL END,
     'store_authorization','CUSTOMER_STORE_AUTHORIZED',
     'supplier_reference', jsonb_build_object('provider', v_img->>'source_provider'));
  v_res := public.fn_create_pulse_store_draft(v_tenant, v_decision, v_context, 'REAL', p_product_id);
  v_page_id := nullif(v_res->>'product_page_id','')::uuid;
  RETURN jsonb_build_object('ok', coalesce((v_res->>'created')::boolean,false),
     'product_id',p_product_id,'market',v_market,'authorization','CUSTOMER_STORE',
     'product_page_id', v_page_id,
     'authoritative_primary_image', CASE WHEN (v_img->>'is_authoritative')::boolean THEN v_primary_url ELSE NULL END,
     'display_image_used', v_primary_url, 'display_image_is_authoritative', (v_img->>'is_authoritative')::boolean,
     'storefront', v_res);
END; $function$;

-- ── attach product to the persistent store (display-image gated) ─────────────
CREATE OR REPLACE FUNCTION public.fn_store_attach_product(p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); cp record; s public.commerce_hosted_stores%rowtype;
  sp record; v_img jsonb; v_has_image boolean; v_build jsonb; v_page_id uuid; v_market text := upper(nullif(btrim(coalesce(p_market,'')),''));
  v_is_new boolean := false; v_mode_action text;
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
      'message','This store already features a different product. Use Replace Current Product to swap it in the same store.');
  END IF;

  IF sp.id IS NULL THEN
    INSERT INTO public.commerce_store_products(hosted_store_id, user_id, product_id, lifecycle_state, market, provenance)
    VALUES (s.id, v_tenant, p_product_id, 'UNPUBLISHED', v_market, jsonb_build_object('attached_by','fn_store_attach_product'))
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
         SET product_page_id=v_page_id, lifecycle_state='ACTIVE', market=coalesce(v_market,market), updated_at=now()
       WHERE id=sp.id;
    END IF;
  ELSE
    v_build := jsonb_build_object('reused_existing_page', true, 'product_page_id', sp.product_page_id);
    v_page_id := sp.product_page_id;
  END IF;

  IF s.store_mode='ONE_PRODUCT' AND s.active_product_id IS NULL THEN
    UPDATE public.commerce_hosted_stores SET active_product_id=p_product_id, updated_at=now() WHERE id=s.id;
  END IF;

  v_mode_action := CASE WHEN v_is_new THEN 'ADDED' ELSE 'UPDATED' END;
  RETURN jsonb_build_object('ok',true,'status',v_mode_action,'hosted_store_id',s.id,'store_mode',s.store_mode,
    'store_product_id',sp.id,'product_id',p_product_id,'product_page_id',v_page_id,
    'duplicate_prevented',(NOT v_is_new),'display_image_used',v_img->>'url','build', v_build);
END; $function$;

-- ── replace active product (display-image gated) ─────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_store_replace_active_product(p_new_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); cp record; s public.commerce_hosted_stores%rowtype; oldp uuid;
  v_img jsonb; v_has_image boolean; v_attach jsonb; v_market text := upper(nullif(btrim(coalesce(p_market,'')),''));
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_new_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF cp.user_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores
    WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_hosted_store'); END IF;

  v_img := public.fn_product_card_display_image(v_tenant, p_new_product_id, v_market);
  v_has_image := (v_img->>'has_image')::boolean;
  IF NOT v_has_image THEN
    RETURN jsonb_build_object('ok',false,'status','IMPORT_REQUIRED','gate','AUTHORITATIVE_ASSET_REQUIRED',
      'error','no_product_image','action','IMPORT_PRODUCT_IMAGES',
      'message','Add your product images so Strateloq can create ads and product pages using the correct product.'); END IF;

  oldp := s.active_product_id;
  IF oldp IS NOT NULL AND oldp <> p_new_product_id THEN
    UPDATE public.commerce_store_products
       SET lifecycle_state='REPLACED', updated_at=now(),
           provenance = provenance || jsonb_build_object('replaced_at',now(),'replaced_by',p_new_product_id)
     WHERE hosted_store_id=s.id AND product_id=oldp;
    UPDATE public.commerce_product_pages
       SET status='ARCHIVED', publication_state='UNPUBLISHED', updated_at=now()
     WHERE id IN (SELECT product_page_id FROM public.commerce_store_products
                   WHERE hosted_store_id=s.id AND product_id=oldp AND product_page_id IS NOT NULL);
  END IF;
  UPDATE public.commerce_hosted_stores SET active_product_id=NULL, updated_at=now() WHERE id=s.id;
  v_attach := public.fn_store_attach_product(p_new_product_id, v_market);
  UPDATE public.commerce_hosted_stores SET active_product_id=p_new_product_id, updated_at=now() WHERE id=s.id;
  RETURN jsonb_build_object('ok', coalesce((v_attach->>'ok')::boolean,false),'status','REPLACED',
    'hosted_store_id',s.id,'previous_product_id',oldp,'new_active_product_id',p_new_product_id,
    'history_preserved',true,'attach',v_attach);
END; $function$;

-- ── Product Card actions: gate on DISPLAY image, not authoritative ───────────
CREATE OR REPLACE FUNCTION public.fn_product_card_commerce_actions(p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_owner uuid; v_auth jsonb; v_has_auth boolean;
  v_has_display boolean; v_display_count int;
  hs public.commerce_hosted_stores%rowtype; v_has_hosted boolean := false; spr record; v_attached boolean := false;
  v_conn record; v_pushable boolean := false; v_ext boolean := false;
  v_page record; v_page_state text; v_pub_state text := 'UNPUBLISHED'; v_published_url text; v_page_id uuid;
  v_market text := nullif(btrim(coalesce(p_market,'')),''); v_actions jsonb := '[]'::jsonb; v_readiness text;
  v_ent jsonb; v_is_active boolean := false; v_this_lifecycle text;
  c_gate constant text := 'An approved product image is required before Strateloq can continue.';
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_auth := public.fn_ad_product_card_authority(v_tenant, p_product_id, v_market);
  v_has_auth := coalesce((v_auth->>'authoritative_count')::int,0) > 0;

  -- has_display_image: ANY product image (incl. marketplace). Drives the ACTION gate.
  SELECT count(*) INTO v_display_count FROM public.product_image_assets
    WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false;
  v_has_display := v_display_count > 0;

  SELECT * INTO hs FROM public.commerce_hosted_stores
    WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  v_has_hosted := FOUND;
  IF v_has_hosted THEN
    SELECT * INTO spr FROM public.commerce_store_products WHERE hosted_store_id=hs.id AND product_id=p_product_id;
    v_attached := FOUND; v_this_lifecycle := spr.lifecycle_state; v_is_active := (hs.active_product_id = p_product_id);
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

  -- READY when a usable display image exists; NO_IMAGE only when the card has none.
  v_readiness := CASE WHEN v_has_display THEN 'READY' ELSE 'NO_IMAGE' END;

  -- CREATE_AD: present always. Gated ONLY when there is no image at all.
  v_actions := jsonb_build_array(jsonb_build_object('key','CREATE_AD','label','Create Ad','enabled',v_has_display,
    'reason', CASE WHEN v_has_display THEN 'product_image_available' ELSE 'product_image_required' END,
    'route','creative_studio')
    || CASE WHEN v_has_display THEN '{}'::jsonb
            ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END);

  IF v_has_hosted THEN
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','MANAGE_STORE','label','Manage Store',
      'enabled',true,'reason','hosted_store_exists','route','store_manager','hosted_store_id',hs.id,
      'store_mode',hs.store_mode,'slug',hs.slug,'public_route',hs.public_route));
    IF v_attached OR v_is_active THEN
      v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','PUBLISH_TO_STORE',
        'label', CASE WHEN v_pub_state='PUBLISHED' THEN 'Update Store Product' ELSE 'Publish to Store' END,
        'enabled', (v_has_display AND coalesce(spr.product_page_id, v_page_id) IS NOT NULL),
        'reason', CASE WHEN NOT v_has_display THEN 'product_image_required'
                       WHEN coalesce(spr.product_page_id, v_page_id) IS NULL THEN 'build_store_page_first' ELSE 'ready' END,
        'hosted_store_id',hs.id,'store_product_id',spr.id,'product_page_id',coalesce(spr.product_page_id,v_page_id),
        'lifecycle_state',v_this_lifecycle)
        || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
    ELSIF hs.store_mode='ONE_PRODUCT' AND hs.active_product_id IS NOT NULL AND hs.active_product_id <> p_product_id THEN
      v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','REPLACE_CURRENT_PRODUCT',
        'label','Replace Current Product','enabled',v_has_display,
        'reason', CASE WHEN v_has_display THEN 'one_product_store_swap' ELSE 'product_image_required' END,
        'hosted_store_id',hs.id,'current_active_product_id',hs.active_product_id)
        || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
    ELSE
      v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','ADD_TO_STORE',
        'label','Add to Store','enabled',v_has_display,
        'reason', CASE WHEN v_has_display THEN 'ready' ELSE 'product_image_required' END,
        'hosted_store_id',hs.id,'store_mode',hs.store_mode)
        || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
    END IF;
  ELSIF v_pushable THEN
    v_actions := v_actions || jsonb_build_array((jsonb_build_object('key','PUBLISH_TO_STORE',
      'label', CASE WHEN v_pub_state='PUBLISHED' THEN 'Update Store Product' ELSE 'Publish to Store' END,
      'enabled', (v_has_display AND v_page_id IS NOT NULL),
      'reason', CASE WHEN NOT v_has_display THEN 'product_image_required'
                     WHEN v_page_id IS NULL THEN 'create_store_page_first' ELSE 'ready' END,
      'provider',v_conn.provider,'store_connection_id',v_conn.id)
      || CASE WHEN v_has_display THEN '{}'::jsonb ELSE jsonb_build_object('gate','AUTHORITATIVE_ASSET_REQUIRED','message',c_gate) END));
  ELSE
    v_ent := public.fn_hosted_store_entitlement(v_tenant);
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','CREATE_FREE_STORE','label','Create Free Store',
      'enabled', (v_ent->>'eligible')::boolean,
      'reason', CASE WHEN (v_ent->>'eligible')::boolean THEN 'entitled' ELSE 'subscription_required' END,
      'route','create_free_store',
      'message','No setup fee — hosting included in your Strateloq subscription.','entitlement', v_ent));
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','CONNECT_STORE',
      'label','Connect Your Store','enabled',true,'reason','no_store_connected','route','store_connection'));
  END IF;

  -- IMPORT_PRODUCT_IMAGES ONLY when the card has NO image at all.
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
        'this_product_attached',v_attached,'this_product_is_active',v_is_active,'this_product_lifecycle',v_this_lifecycle)
      ELSE jsonb_build_object('exists',false) END,
    'store_connection', jsonb_build_object('pushable_connected',v_pushable,
       'provider', CASE WHEN v_pushable THEN v_conn.provider ELSE NULL END,
       'connection_id', CASE WHEN v_pushable THEN v_conn.id ELSE NULL END,
       'external_link_present',v_ext),
    'product_page', jsonb_build_object('page_id',v_page_id,'status',v_page_state,
       'publication_state',v_pub_state,'published_url',v_published_url),
    'actions', v_actions);
END; $function$;

-- ── grants ───────────────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.fn_product_card_display_image(uuid,uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_product_card_display_image(uuid,uuid,text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_product_card_create_store(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_product_card_create_store(uuid,text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_store_attach_product(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_store_attach_product(uuid,text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_store_replace_active_product(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_store_replace_active_product(uuid,text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_product_card_commerce_actions(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_product_card_commerce_actions(uuid,text) TO authenticated, service_role;

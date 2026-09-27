-- STRATELOQ — Product Card commerce actions: image import (authoritative fallback),
-- state-aware Product Card actions, Create Store bridge, store-connection lifecycle.
-- ============================================================================
-- Founder requirement: every eligible ecommerce Product Card exposes Create Ad,
-- Create Store, Connect Your Store (or Publish to Store when connected), and —
-- when Strateloq cannot obtain a lawful authoritative image — Import Product Images.
--
-- REUSE, do not rebuild: Create Ad uses the existing Creative Studio; Create Store
-- reuses fn_generate_storefront_runtime -> fn_create_pulse_store_draft (the approved
-- publish lifecycle); image authority stays governed by fn_ad_product_card_authority.
--
-- PRODUCT ASSET LOCK stays mandatory. This migration ADDS a lawful authoritative
-- source: customer-owned imagery that the customer confirms rights to. Marketplace/
-- competitor/reference images remain non-authoritative. Nothing here weakens the lock.
-- Tenant is always auth.uid() (or, for the service-role import register, a JWT-verified
-- tenant passed by the import edge and re-checked against product ownership).
-- ============================================================================

-- ── new private bucket for customer-imported product source images ──────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('pulse-product-imports','pulse-product-imports', false, 15728640,
        ARRAY['image/png','image/jpeg','image/webp'])
ON CONFLICT (id) DO NOTHING;

-- ── (1) Authority resolver: recognise rights-confirmed customer-owned imagery ─
-- Authoritative = canonical supplier-provided (existing behaviour, unchanged) OR
-- customer-owned imports whose rights the customer explicitly confirmed. Marketplace
-- images are still excluded. Product ownership (tenant) is enforced up front.
CREATE OR REPLACE FUNCTION public.fn_ad_product_card_authority(p_tenant uuid, p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_card_provider text; v_card_item text; v_auth jsonb; v_primary jsonb;
BEGIN
  IF p_product_id IS NULL THEN RETURN jsonb_build_object('status','no_product'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('status','cross_tenant_rejected'); END IF;

  SELECT upper(coalesce(extended->'supplier_ref'->>'provider', '')),
         coalesce(extended->'supplier_ref'->>'source_product_id', extended->>'cj_source_product_id')
    INTO v_card_provider, v_card_item
  FROM public.commerce_products WHERE id=p_product_id;
  v_card_provider := CASE WHEN v_card_provider IN ('CJ','CJ_SUPPLIER') THEN 'CJ_SUPPLIER' ELSE v_card_provider END;

  -- product images are keyed by product_id (product ownership already enforced above).
  SELECT jsonb_agg(x.j ORDER BY (x.j->>'is_primary')::boolean DESC, (x.j->>'origin_rank')::int, x.j->>'id')
  INTO v_auth
  FROM (
    -- canonical supplier-provided assets matching the product's supplier identity
    SELECT jsonb_build_object('id',id::text,'url',image_url,'source_provider',source_provider,
             'source_item_id',source_entity_id,'is_primary',coalesce(is_primary,false),
             'rights_state',rights_state,'origin','SUPPLIER_PROVIDED','origin_rank',1) AS j
    FROM public.product_image_assets
    WHERE product_id=p_product_id
      AND coalesce(is_fixture,false)=false
      AND rights_state='SUPPLIER_PROVIDED'
      AND source_provider = v_card_provider
      AND (v_card_item IS NULL OR source_entity_id = v_card_item)
    UNION ALL
    -- customer-owned imports with explicit rights confirmation (lawful fallback path)
    SELECT jsonb_build_object('id',id::text,'url',image_url,'source_provider',source_provider,
             'source_item_id',source_entity_id,'is_primary',coalesce(is_primary,false),
             'rights_state',rights_state,'origin','CUSTOMER_OWNED','origin_rank',2) AS j
    FROM public.product_image_assets
    WHERE product_id=p_product_id
      AND coalesce(is_fixture,false)=false
      AND rights_state='CUSTOMER_OWNED'
      AND source_provider='CUSTOMER_UPLOAD'
      AND coalesce(provenance->>'rights_confirmed','false')='true'
  ) x;

  v_primary := (SELECT e FROM jsonb_array_elements(coalesce(v_auth,'[]'::jsonb)) e WHERE (e->>'is_primary')::boolean LIMIT 1);
  IF v_primary IS NULL THEN v_primary := (coalesce(v_auth,'[]'::jsonb)->0); END IF;

  RETURN jsonb_build_object('status','ok','product_id',p_product_id::text,
    'card_identity', jsonb_build_object('source_provider',v_card_provider,'source_item_id',v_card_item),
    'authoritative_assets', coalesce(v_auth,'[]'::jsonb),
    'authoritative_count', jsonb_array_length(coalesce(v_auth,'[]'::jsonb)),
    'primary_asset', v_primary,
    'note','Authoritative = canonical supplier-provided OR rights-confirmed customer-owned product imagery. Marketplace/competitor/reference images are NOT authoritative product sources for customer creatives.');
END; $function$;

-- ── (2) Register a customer-imported image (service-role; called by import edge) ─
-- The import edge authenticates the caller via their JWT, uploads to the private
-- bucket with the service role, mints a durable signed URL, then calls this to
-- register the asset. Tenant is re-verified against product ownership here.
CREATE OR REPLACE FUNCTION public.fn_product_image_import_register(
  p_tenant uuid, p_product_id uuid, p_storage_ref text, p_display_url text, p_mime text,
  p_market text DEFAULT NULL, p_rights_confirmed boolean DEFAULT false,
  p_original_filename text DEFAULT NULL, p_byte_size bigint DEFAULT NULL,
  p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_asset uuid; v_has_primary boolean; v_prov jsonb;
  v_market text := nullif(btrim(coalesce(p_market,'')),'');
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('status','error','error','unauthenticated'); END IF;
  IF p_product_id IS NULL OR coalesce(btrim(p_storage_ref),'')='' OR coalesce(btrim(p_display_url),'')='' THEN
    RETURN jsonb_build_object('status','error','error','missing_inputs'); END IF;
  IF coalesce(p_rights_confirmed,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('status','error','error','rights_confirmation_required'); END IF;
  IF lower(coalesce(p_mime,'')) NOT IN ('image/png','image/jpeg','image/webp') THEN
    RETURN jsonb_build_object('status','error','error','unsupported_mime','mime',p_mime); END IF;
  IF p_byte_size IS NOT NULL AND (p_byte_size <= 0 OR p_byte_size > 15728640) THEN
    RETURN jsonb_build_object('status','error','error','invalid_file_size'); END IF;

  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','error','error','product_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('status','error','error','cross_tenant_rejected'); END IF;

  -- idempotency: the same storage object never registers twice
  SELECT id INTO v_asset FROM public.product_image_assets
    WHERE product_id=p_product_id AND provenance->>'storage_ref'=p_storage_ref LIMIT 1;
  IF v_asset IS NOT NULL THEN
    RETURN jsonb_build_object('status','exists','asset_id',v_asset,
      'authority', public.fn_ad_product_card_authority(p_tenant,p_product_id,v_market)); END IF;

  SELECT EXISTS(SELECT 1 FROM public.product_image_assets
     WHERE product_id=p_product_id AND rights_state='CUSTOMER_OWNED' AND source_provider='CUSTOMER_UPLOAD'
       AND coalesce(is_primary,false)=true) INTO v_has_primary;

  v_prov := coalesce(p_provenance,'{}'::jsonb) || jsonb_build_object(
     'source','CUSTOMER_UPLOAD','uploaded_by',p_tenant,'uploaded_at',now(),
     'storage_ref',p_storage_ref,'bucket','pulse-product-imports',
     'original_filename',p_original_filename,'byte_size',p_byte_size,'mime',lower(p_mime),
     'rights_confirmed',true,
     'rights_statement','I confirm that I own this image or have permission to use it for this product and advertising.',
     'rights_confirmed_at',now());

  INSERT INTO public.product_image_assets(tenant_id, product_id, market, image_url, source_provider,
     source_url, source_entity_id, rights_state, availability, is_primary, observed_at, provenance, is_fixture)
  VALUES (p_tenant, p_product_id, v_market, p_display_url, 'CUSTOMER_UPLOAD',
     p_storage_ref, NULL, 'CUSTOMER_OWNED', 'AVAILABLE', (NOT v_has_primary), now(), v_prov, false)
  RETURNING id INTO v_asset;

  -- mirror into supplier_product_assets as an OWNED source asset so the EXISTING
  -- storefront / product-page builder (fn_resolve_storefront_assets) can use it too.
  INSERT INTO public.supplier_product_assets(supplier, supplier_product_id, product_title, asset_type,
     asset_class, asset_identity, rights_state, availability, source_url, original_source, is_primary,
     cache_state, storage_ref, observed_at, provenance, is_fixture, created_at)
  SELECT 'CUSTOMER_UPLOAD', p_product_id::text, cp.title, 'IMAGE',
     'SOURCE_PRODUCT_ASSET', 'CUSTOMER_OWNED_PRODUCT', 'OWNED', 'AVAILABLE', p_display_url, 'customer_upload',
     (NOT v_has_primary), 'REMOTE', p_storage_ref, now(),
     jsonb_build_object('source','CUSTOMER_UPLOAD','tenant',p_tenant,'product_id',p_product_id::text,
        'product_image_asset_id',v_asset::text,'rights_confirmed',true), false, now()
  FROM public.commerce_products cp WHERE cp.id=p_product_id;

  RETURN jsonb_build_object('status','registered','asset_id',v_asset,'is_primary',(NOT v_has_primary),
    'rights_state','CUSTOMER_OWNED','source_provider','CUSTOMER_UPLOAD',
    'authority', public.fn_ad_product_card_authority(p_tenant,p_product_id,v_market));
END; $function$;

-- ── (3) Product Card commerce actions (state-aware; tenant = auth.uid()) ─────
CREATE OR REPLACE FUNCTION public.fn_product_card_commerce_actions(p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_owner uuid; v_auth jsonb; v_has_auth boolean;
  v_conn record; v_conn_state text := 'NOT_CONNECTED'; v_conn_provider text; v_conn_id uuid;
  v_page record; v_page_state text; v_pub_state text := 'UNPUBLISHED'; v_published_url text; v_page_id uuid;
  v_market text := nullif(btrim(coalesce(p_market,'')),''); v_actions jsonb; v_readiness text;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_auth := public.fn_ad_product_card_authority(v_tenant, p_product_id, v_market);
  v_has_auth := coalesce((v_auth->>'authoritative_count')::int,0) > 0;

  -- Only a pushable store (Shopify/WooCommerce) enables Publish to Store; a manually
  -- linked EXTERNAL_STORE is a reference and is surfaced separately (no push API).
  SELECT * INTO v_conn FROM public.commerce_store_connections
    WHERE user_id=v_tenant AND connection_state='CONNECTED' AND provider IN ('SHOPIFY','WOOCOMMERCE')
    ORDER BY connected_at DESC NULLS LAST LIMIT 1;
  IF FOUND THEN v_conn_state:='CONNECTED'; v_conn_provider:=v_conn.provider; v_conn_id:=v_conn.id; END IF;

  SELECT * INTO v_page FROM public.commerce_product_pages
    WHERE user_id=v_tenant AND product_id=p_product_id
      AND (v_market IS NULL OR market=v_market OR country_code=v_market)
    ORDER BY updated_at DESC LIMIT 1;
  IF FOUND THEN v_page_id:=v_page.id; v_page_state:=v_page.status;
    v_pub_state:=coalesce(v_page.publication_state,'UNPUBLISHED'); v_published_url:=v_page.published_url; END IF;

  v_readiness := CASE WHEN v_has_auth THEN 'READY' ELSE 'IMPORT_REQUIRED' END;

  v_actions := jsonb_build_array(
    jsonb_build_object('key','CREATE_AD','label','Create Ad','enabled',v_has_auth,
      'reason', CASE WHEN v_has_auth THEN 'authoritative_image_available' ELSE 'import_product_images_first' END,
      'route','creative_studio'),
    jsonb_build_object('key','CREATE_STORE','label','Create Store','enabled',v_has_auth,
      'reason', CASE WHEN v_has_auth THEN 'ready' ELSE 'import_product_images_first' END,
      'route','product_page_builder'));

  IF v_conn_state='CONNECTED' THEN
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','PUBLISH_TO_STORE',
      'label', CASE WHEN v_pub_state='PUBLISHED' THEN 'Update Store Product' ELSE 'Publish to Store' END,
      'enabled', (v_has_auth AND v_page_id IS NOT NULL),
      'reason', CASE WHEN NOT v_has_auth THEN 'import_product_images_first'
                     WHEN v_page_id IS NULL THEN 'create_store_page_first' ELSE 'ready' END,
      'provider',v_conn_provider,'store_connection_id',v_conn_id));
  ELSE
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','CONNECT_STORE',
      'label','Connect Your Store','enabled',true,'reason','no_store_connected','route','store_connection'));
  END IF;

  IF NOT v_has_auth THEN
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','IMPORT_PRODUCT_IMAGES',
      'label','Import Product Images','enabled',true,'reason','no_authoritative_image','route','image_import',
      'message','Add your product images so Strateloq can create ads and product pages using the correct product.'));
  END IF;

  RETURN jsonb_build_object('ok',true,'product_id',p_product_id,'market',v_market,'readiness',v_readiness,
    'image_authority', jsonb_build_object('has_authoritative',v_has_auth,
       'authoritative_count',coalesce((v_auth->>'authoritative_count')::int,0),
       'primary_asset', v_auth->'primary_asset', 'needs_import', (NOT v_has_auth)),
    'store_connection', jsonb_build_object('state',v_conn_state,'provider',v_conn_provider,'connection_id',v_conn_id,
       'pushable', (v_conn_state='CONNECTED'),
       'external_link_present', EXISTS(SELECT 1 FROM public.commerce_store_connections
          WHERE user_id=v_tenant AND connection_state='CONNECTED' AND provider='EXTERNAL_STORE')),
    'product_page', jsonb_build_object('page_id',v_page_id,'status',v_page_state,
       'publication_state',v_pub_state,'published_url',v_published_url),
    'actions', v_actions);
END; $function$;

-- ── (4) Create Store bridge — reuses fn_generate_storefront_runtime ──────────
-- Product Asset Lock first (authoritative image required), then delegates to the
-- existing fail-closed storefront orchestrator using the product's own opportunity
-- decision. The decision's authoritative hard-gate verdicts are mapped into the
-- storefront eligibility inputs (no new judgement is invented). No fake stores.
CREATE OR REPLACE FUNCTION public.fn_product_card_create_store(p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); cp record; v_auth jsonb; v_has_auth boolean; d record;
  v_market text := upper(nullif(btrim(coalesce(p_market,'')),'')); v_rec text;
  v_gate jsonb; v_decision jsonb; v_context jsonb; v_sel jsonb; v_primary_url text; v_res jsonb;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF cp.user_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_auth := public.fn_ad_product_card_authority(v_tenant, p_product_id, v_market);
  v_has_auth := coalesce((v_auth->>'authoritative_count')::int,0) > 0;
  IF NOT v_has_auth THEN
    RETURN jsonb_build_object('ok',false,'status','IMPORT_REQUIRED','error','no_authoritative_product_asset',
      'message','Import your product images before creating a store page.','action','IMPORT_PRODUCT_IMAGES');
  END IF;
  v_primary_url := v_auth->'primary_asset'->>'url';

  SELECT * INTO d FROM public.product_opportunity_decisions
    WHERE product_id=p_product_id AND (v_market IS NULL OR upper(country_code)=v_market)
    ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'status','STORE_REQUIRES_TEST_DECISION','error','no_opportunity_decision',
      'product_asset_lock','SATISFIED',
      'message','This product has no completed opportunity decision yet; run Product Intelligence to produce a TEST decision before creating a store.');
  END IF;

  v_market := coalesce(v_market, upper(d.country_code));
  v_rec := CASE WHEN d.decision IN ('TEST','HIGH_CONFIDENCE_TEST') THEN 'TEST' ELSE upper(coalesce(d.decision,'')) END;

  v_gate := jsonb_build_object(
    'recommendation', v_rec,
    'decision_tier', d.opportunity_band,
    'supplier_identity_state', CASE WHEN d.hard_gates->>'supplier'='PASS' THEN 'SUPPLIER_EXACT' ELSE 'WEAK' END,
    'market_supplier_match', CASE WHEN d.hard_gates->>'market_price'='PASS' THEN 'MATCH' ELSE 'NO_MATCH' END,
    'subtype_price_valid', (d.hard_gates->>'market_price'='PASS'),
    'stock_state', CASE WHEN d.hard_gates->>'supplier'='PASS' AND d.hard_gates->>'fulfilment'='PASS' THEN 'IN_STOCK' ELSE 'UNKNOWN' END,
    'economics_state', upper(coalesce(d.economics_ref->>'economics_state','UNKNOWN')),
    'product_confidence', upper(coalesce(d.product_confidence,'UNKNOWN')),
    'fulfilment_evidence', (d.hard_gates->>'fulfilment'='PASS'),
    'no_critical_risk', (d.hard_gates->>'compliance'='PASS' AND coalesce(jsonb_array_length(coalesce(d.decision_blockers,'[]'::jsonb)),0)=0),
    'sourcing_status', '');

  v_decision := jsonb_build_object(
    'recommendation', v_rec, 'classification', d.opportunity_band, 'target_market', v_market,
    'economics', jsonb_build_object('economics_state', upper(coalesce(d.economics_ref->>'economics_state','UNKNOWN')),
        'landed_cost_display', d.economics_ref->>'landed_cost_display'),
    'supplier_execution', jsonb_build_object('economics', jsonb_build_object(
        'landed_cost_original', d.economics_ref->>'landed_cost_original',
        'landed_cost_currency', d.market_currency)));

  v_context := jsonb_build_object(
    'product_title', cp.title, 'positioning', coalesce(cp.description,''),
    'display_currency', d.market_currency, 'source_currency', d.market_currency,
    'supplier','CUSTOMER_UPLOAD','supplier_product_id', p_product_id::text,
    'authoritative_primary_image', v_primary_url,
    'supplier_reference', jsonb_build_object('provider', v_auth->'card_identity'->>'source_provider'));

  v_sel := jsonb_build_object('product_id', p_product_id::text, 'country_code', v_market,
     'ad_match', jsonb_build_object('state','NO_AD_MATCH_YET'));

  v_res := public.fn_generate_storefront_runtime(
     v_tenant, v_gate, v_sel, v_context, v_decision,
     'PULSE_HOSTED', 'REAL', p_product_id, v_market, d.id, true);

  RETURN jsonb_build_object('ok', ((v_res->>'status') IN ('ok','ok_preview')),
     'product_id',p_product_id,'market',v_market,'opportunity_decision_id',d.id,
     'decision_verdict', d.decision, 'product_asset_lock','SATISFIED',
     'authoritative_primary_image', v_primary_url, 'storefront', v_res);
END; $function$;

-- ── (5) Store connection lifecycle (tenant = auth.uid()) ─────────────────────
-- Real Shopify/WooCommerce OAuth requires founder-provided app credentials
-- (client id/secret + redirect) stored server-side. This lifecycle never fabricates
-- a CONNECTED state: it reports whether the platform is configured, and only the
-- OAuth callback (edge, with real credentials) may set CONNECTED.
CREATE OR REPLACE FUNCTION public.fn_store_connection_initiate(
  p_provider text, p_store_domain text DEFAULT NULL, p_external_url text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_provider text := upper(btrim(coalesce(p_provider,'')));
  v_state text; v_id uuid; v_configured boolean; v_key text;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  IF v_provider NOT IN ('SHOPIFY','WOOCOMMERCE','EXTERNAL_STORE') THEN
    RETURN jsonb_build_object('ok',false,'error','unsupported_provider',
      'supported', jsonb_build_array('SHOPIFY','WOOCOMMERCE','EXTERNAL_STORE')); END IF;

  v_key := lower(v_provider)||'_oauth';
  SELECT (url IS NOT NULL AND btrim(coalesce(secret,''))<>'') INTO v_configured
    FROM public.server_integration_config WHERE key=v_key;
  v_configured := coalesce(v_configured,false);

  v_state := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');

  INSERT INTO public.commerce_store_connections(user_id, provider, store_domain, store_identifier,
     connection_state, oauth_state, visibility, created_at, updated_at)
  VALUES (v_tenant, v_provider, nullif(btrim(coalesce(p_store_domain,'')),''), nullif(btrim(coalesce(p_external_url,'')),''),
     CASE WHEN v_provider='EXTERNAL_STORE' THEN 'CONNECTED' ELSE 'CONNECTING' END,
     v_state, 'TENANT_PRIVATE', now(), now())
  RETURNING id INTO v_id;

  IF v_provider='EXTERNAL_STORE' THEN
    -- a manually-linked external store: no push API, customer manages it. Recorded as a real link.
    UPDATE public.commerce_store_connections SET connected_at=now() WHERE id=v_id;
    RETURN jsonb_build_object('ok',true,'connection_id',v_id,'provider',v_provider,'connection_state','CONNECTED',
      'next','MANUAL_LINK','note','External store linked as a reference; Strateloq does not push products to a manually-linked external store.');
  END IF;

  RETURN jsonb_build_object('ok',true,'connection_id',v_id,'provider',v_provider,'connection_state','CONNECTING',
    'oauth_state',v_state, 'oauth_provider_configured', v_configured,
    'next', CASE WHEN v_configured THEN 'AUTHORIZE_VIA_EDGE' ELSE 'PROVIDER_NOT_CONFIGURED' END,
    'note', CASE WHEN v_configured
      THEN 'Begin OAuth via the store-oauth edge function; the callback stores the token server-side and sets CONNECTED.'
      ELSE 'This store platform is not yet configured: an app client id/secret + redirect must be provisioned server-side before OAuth can complete.' END);
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_store_connection_status()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid();
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  RETURN jsonb_build_object('ok',true,'connections', coalesce((
    SELECT jsonb_agg(jsonb_build_object('connection_id',id,'provider',provider,'state',connection_state,
       'store_domain',store_domain,'connected_at',connected_at,'last_sync_at',last_sync_at,'error_detail',error_detail)
       ORDER BY updated_at DESC)
    FROM public.commerce_store_connections WHERE user_id=v_tenant),'[]'::jsonb),
    'has_connected', EXISTS(SELECT 1 FROM public.commerce_store_connections WHERE user_id=v_tenant AND connection_state='CONNECTED'));
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_store_connection_disconnect(p_connection_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_ok boolean;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  UPDATE public.commerce_store_connections
     SET connection_state='DISCONNECTED', updated_at=now()
   WHERE id=p_connection_id AND user_id=v_tenant
  RETURNING true INTO v_ok;
  RETURN jsonb_build_object('ok',coalesce(v_ok,false),'connection_id',p_connection_id,
    'state', CASE WHEN coalesce(v_ok,false) THEN 'DISCONNECTED' ELSE 'not_found_for_tenant' END);
END; $function$;

-- ── (6) Publish-to-store preflight (reuses the storefront publish context) ───
CREATE OR REPLACE FUNCTION public.fn_store_publish_preflight(p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_owner uuid; v_auth jsonb; v_has_auth boolean;
  v_page record; v_conn record; v_market text := nullif(btrim(coalesce(p_market,'')),'');
  v_reasons text[] := '{}';
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_auth := public.fn_ad_product_card_authority(v_tenant, p_product_id, v_market);
  v_has_auth := coalesce((v_auth->>'authoritative_count')::int,0) > 0;
  IF NOT v_has_auth THEN v_reasons := array_append(v_reasons,'NO_AUTHORITATIVE_IMAGE'); END IF;

  SELECT * INTO v_page FROM public.commerce_product_pages
    WHERE user_id=v_tenant AND product_id=p_product_id
      AND (v_market IS NULL OR market=v_market OR country_code=v_market)
    ORDER BY updated_at DESC LIMIT 1;
  IF NOT FOUND THEN v_reasons := array_append(v_reasons,'NO_PRODUCT_PAGE'); END IF;

  SELECT * INTO v_conn FROM public.commerce_store_connections
    WHERE user_id=v_tenant AND connection_state='CONNECTED' AND provider IN ('SHOPIFY','WOOCOMMERCE')
    ORDER BY connected_at DESC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN v_reasons := array_append(v_reasons,'NO_PUSHABLE_STORE_CONNECTED'); END IF;

  RETURN jsonb_build_object('ok', (array_length(v_reasons,1) IS NULL),
    'publishable', (array_length(v_reasons,1) IS NULL),
    'blocking_reasons', to_jsonb(v_reasons),
    'authoritative_image', v_has_auth,
    'product_page_id', (SELECT v_page.id),
    'store_connection', CASE WHEN v_conn.id IS NOT NULL
        THEN jsonb_build_object('connection_id',v_conn.id,'provider',v_conn.provider) ELSE NULL END,
    'authoritative_primary_image', v_auth->'primary_asset'->>'url',
    'note','Preflight only. Real remote publish requires a connected store with server-side OAuth credentials; provider push is performed by the store-publish edge, and provider failure remains failure.');
END; $function$;

-- ── grants ───────────────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.fn_product_image_import_register(uuid,uuid,text,text,text,text,boolean,text,bigint,jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_product_image_import_register(uuid,uuid,text,text,text,text,boolean,text,bigint,jsonb) TO service_role;

REVOKE EXECUTE ON FUNCTION public.fn_product_card_commerce_actions(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_product_card_commerce_actions(uuid,text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.fn_product_card_create_store(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_product_card_create_store(uuid,text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.fn_store_connection_initiate(text,text,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_store_connection_initiate(text,text,text) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.fn_store_connection_status() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_store_connection_status() TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.fn_store_connection_disconnect(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_store_connection_disconnect(uuid) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.fn_store_publish_preflight(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_store_publish_preflight(uuid,text) TO authenticated, service_role;

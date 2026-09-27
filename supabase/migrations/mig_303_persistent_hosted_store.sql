-- STRATELOQ — Persistent hosted store + product lifecycle
-- ============================================================================
-- Default model: 1 BUSINESS -> 1 PERSISTENT STRATELOQ STORE -> MANY PRODUCT LIFECYCLES.
-- A store is a durable business asset. Changing products must NOT create another store.
--
-- Additive layer over the EXISTING machinery (not a rebuild):
--   * commerce_hosted_stores    — the durable per-tenant store (identity, domain/slug,
--                                 brand/theme, mode, active product, entitlement).
--   * commerce_store_products   — store<->product lifecycle relationship (MANY per store).
-- Page building still reuses fn_product_card_create_store -> fn_generate_storefront_runtime
-- -> fn_create_pulse_store_draft (the approved builder + publish lifecycle). The Product
-- Asset Lock (fn_ad_product_card_authority) still governs imagery. Creative Studio is
-- untouched and independent of store lifecycle.
--
-- Hosting entitlement is read from the EXISTING source of truth (account_entitlement);
-- no second billing system is created.
-- ============================================================================

-- ── durable per-tenant hosted store ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.commerce_hosted_stores (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL,
  business_profile_id uuid,
  store_mode          text NOT NULL DEFAULT 'ONE_PRODUCT'
                        CHECK (store_mode IN ('ONE_PRODUCT','MULTI_PRODUCT')),
  status              text NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','SUSPENDED','ARCHIVED')),
  is_default          boolean NOT NULL DEFAULT true,
  slug                text NOT NULL,
  custom_domain       text,
  public_route        text,
  brand_settings      jsonb NOT NULL DEFAULT '{}'::jsonb,
  theme_settings      jsonb NOT NULL DEFAULT '{}'::jsonb,
  active_product_id   uuid REFERENCES public.commerce_products(id) ON DELETE SET NULL,
  entitlement_plan    text,
  entitlement_state   text,
  provenance          jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
-- one DEFAULT hosted store per tenant (anti-duplication); future non-default stores allowed.
CREATE UNIQUE INDEX IF NOT EXISTS commerce_hosted_stores_one_default_per_tenant
  ON public.commerce_hosted_stores(user_id) WHERE is_default;
CREATE UNIQUE INDEX IF NOT EXISTS commerce_hosted_stores_slug_key
  ON public.commerce_hosted_stores(slug);
ALTER TABLE public.commerce_hosted_stores ENABLE ROW LEVEL SECURITY; -- reached only via SECURITY DEFINER fns

-- ── store <-> product lifecycle relationship ────────────────────────────────
CREATE TABLE IF NOT EXISTS public.commerce_store_products (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hosted_store_id  uuid NOT NULL REFERENCES public.commerce_hosted_stores(id) ON DELETE CASCADE,
  user_id          uuid NOT NULL,
  product_id       uuid NOT NULL REFERENCES public.commerce_products(id) ON DELETE CASCADE,
  product_page_id  uuid REFERENCES public.commerce_product_pages(id) ON DELETE SET NULL,
  lifecycle_state  text NOT NULL DEFAULT 'UNPUBLISHED'
                     CHECK (lifecycle_state IN ('ACTIVE','SOLD_OUT','PAUSED','UNPUBLISHED','ARCHIVED','REPLACED')),
  market           text,
  remote_product_id text,
  remote_url       text,
  provenance       jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
-- idempotency: a product attaches at most once per store.
CREATE UNIQUE INDEX IF NOT EXISTS commerce_store_products_store_product_key
  ON public.commerce_store_products(hosted_store_id, product_id);
ALTER TABLE public.commerce_store_products ENABLE ROW LEVEL SECURITY;

-- ── entitlement (reuse account_entitlement; no second billing system) ────────
CREATE OR REPLACE FUNCTION public.fn_hosted_store_entitlement(p_tenant uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE e record;
BEGIN
  SELECT plan_code, status, current_period_end, trial_end, cancel_at_period_end
    INTO e FROM public.account_entitlement
   WHERE auth_user_id=p_tenant
     AND upper(status) IN ('ACTIVE','TRIALING','TRIAL','COMP','COMPED')
     AND (current_period_end IS NULL OR current_period_end > now())
   ORDER BY updated_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('eligible',false,'reason','no_active_subscription',
      'message','A hosted Strateloq store is included with an active Strateloq subscription.');
  END IF;
  RETURN jsonb_build_object('eligible',true,'plan_code',e.plan_code,'status',e.status,
    'current_period_end',e.current_period_end,
    'message','No setup fee — hosting included in your Strateloq subscription.');
END; $function$;

-- ── get-or-create the tenant's default hosted store (idempotent) ─────────────
CREATE OR REPLACE FUNCTION public.fn_hosted_store_get_or_create(p_tenant uuid, p_store_mode text DEFAULT NULL)
 RETURNS public.commerce_hosted_stores LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE s public.commerce_hosted_stores%rowtype; v_bp uuid; v_bn text; v_bv text;
  v_slug text; v_mode text := upper(coalesce(p_store_mode,'ONE_PRODUCT'));
BEGIN
  SELECT * INTO s FROM public.commerce_hosted_stores
    WHERE user_id=p_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF FOUND THEN RETURN s; END IF;

  IF v_mode NOT IN ('ONE_PRODUCT','MULTI_PRODUCT') THEN v_mode := 'ONE_PRODUCT'; END IF;
  SELECT id, business_name, brand_voice INTO v_bp, v_bn, v_bv
    FROM public.business_profiles WHERE user_id=p_tenant ORDER BY updated_at DESC NULLS LAST LIMIT 1;
  v_slug := 'store-' || substr(md5(p_tenant::text || clock_timestamp()::text), 1, 12);

  INSERT INTO public.commerce_hosted_stores(user_id, business_profile_id, store_mode, status, is_default,
     slug, public_route, brand_settings, theme_settings, provenance)
  VALUES (p_tenant, v_bp, v_mode, 'ACTIVE', true, v_slug, '/s/'||v_slug,
     jsonb_build_object('business_name', v_bn, 'brand_voice', v_bv),
     jsonb_build_object('template_family', 'DEFAULT'),
     jsonb_build_object('created_by','fn_hosted_store_get_or_create'))
  ON CONFLICT (user_id) WHERE is_default DO NOTHING
  RETURNING * INTO s;

  IF s.id IS NULL THEN
    SELECT * INTO s FROM public.commerce_hosted_stores
      WHERE user_id=p_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  END IF;
  RETURN s;
END; $function$;

-- ── CREATE FREE STORE (entitlement-gated, idempotent) ────────────────────────
CREATE OR REPLACE FUNCTION public.fn_create_free_store(p_store_mode text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_ent jsonb; s public.commerce_hosted_stores%rowtype; v_existed boolean;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  v_ent := public.fn_hosted_store_entitlement(v_tenant);
  IF NOT (v_ent->>'eligible')::boolean THEN
    RETURN jsonb_build_object('ok',false,'status','NOT_ENTITLED','entitlement',v_ent,
      'message', v_ent->>'message'); END IF;

  SELECT EXISTS(SELECT 1 FROM public.commerce_hosted_stores WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED') INTO v_existed;
  s := public.fn_hosted_store_get_or_create(v_tenant, p_store_mode);
  UPDATE public.commerce_hosted_stores
     SET entitlement_plan=v_ent->>'plan_code', entitlement_state=v_ent->>'status', updated_at=now()
   WHERE id=s.id;

  RETURN jsonb_build_object('ok',true, 'created', (NOT v_existed), 'already_existed', v_existed,
    'hosted_store_id', s.id, 'store_mode', s.store_mode, 'status', s.status, 'slug', s.slug,
    'public_route', s.public_route, 'entitlement', v_ent,
    'message','No setup fee — hosting included in your Strateloq subscription.');
END; $function$;

-- ── read the tenant's hosted store + its product lifecycles ──────────────────
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
       'active_product_id',s.active_product_id,'brand_settings',s.brand_settings,'theme_settings',s.theme_settings),
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'store_product_id',sp.id,'product_id',sp.product_id,'product_page_id',sp.product_page_id,
        'lifecycle_state',sp.lifecycle_state,'market',sp.market,'remote_url',sp.remote_url,
        'is_active',(sp.product_id = s.active_product_id)) ORDER BY sp.updated_at DESC)
      FROM public.commerce_store_products sp WHERE sp.hosted_store_id=s.id),'[]'::jsonb));
END; $function$;

-- ── attach / add a product to the persistent store (idempotent) ──────────────
-- ONE_PRODUCT: first product becomes active; a different product when one is active
--   returns REPLACE_REQUIRED (use fn_store_replace_active_product) — never silently replaces.
-- MULTI_PRODUCT: adds another product lifecycle to the SAME store.
-- Reuses fn_product_card_create_store for page building (Product Asset Lock enforced there).
CREATE OR REPLACE FUNCTION public.fn_store_attach_product(p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); cp record; s public.commerce_hosted_stores%rowtype;
  sp record; v_auth jsonb; v_has_auth boolean; v_build jsonb; v_page_id uuid; v_market text := upper(nullif(btrim(coalesce(p_market,'')),''));
  v_is_new boolean := false; v_mode_action text;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF cp.user_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  -- Product Asset Lock: authoritative image required before attaching
  v_auth := public.fn_ad_product_card_authority(v_tenant, p_product_id, v_market);
  v_has_auth := coalesce((v_auth->>'authoritative_count')::int,0) > 0;
  IF NOT v_has_auth THEN
    RETURN jsonb_build_object('ok',false,'status','IMPORT_REQUIRED','error','no_authoritative_product_asset',
      'action','IMPORT_PRODUCT_IMAGES','message','Import your product images before adding this product to the store.');
  END IF;

  s := public.fn_hosted_store_get_or_create(v_tenant, NULL);

  SELECT * INTO sp FROM public.commerce_store_products WHERE hosted_store_id=s.id AND product_id=p_product_id;

  -- ONE_PRODUCT guard: a different active product must be replaced explicitly
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

  -- build the product page only if not already built (idempotent: no duplicate pages)
  IF sp.product_page_id IS NULL THEN
    v_build := public.fn_product_card_create_store(p_product_id, coalesce(v_market, sp.market));
    v_page_id := nullif(v_build->'storefront'->>'product_page_id','')::uuid;
    IF v_page_id IS NOT NULL THEN
      UPDATE public.commerce_store_products
         SET product_page_id=v_page_id, lifecycle_state='ACTIVE', market=coalesce(v_market,market), updated_at=now()
       WHERE id=sp.id;
    END IF;
  ELSE
    v_build := jsonb_build_object('reused_existing_page', true, 'product_page_id', sp.product_page_id);
    v_page_id := sp.product_page_id;
  END IF;

  -- ONE_PRODUCT: first attached product becomes the active product
  IF s.store_mode='ONE_PRODUCT' AND s.active_product_id IS NULL THEN
    UPDATE public.commerce_hosted_stores SET active_product_id=p_product_id, updated_at=now() WHERE id=s.id;
  END IF;

  v_mode_action := CASE WHEN v_is_new THEN 'ADDED' ELSE 'UPDATED' END;
  RETURN jsonb_build_object('ok',true,'status',v_mode_action,'hosted_store_id',s.id,'store_mode',s.store_mode,
    'store_product_id',sp.id,'product_id',p_product_id,'product_page_id',v_page_id,
    'duplicate_prevented',(NOT v_is_new),'authoritative_primary_image',v_auth->'primary_asset'->>'url',
    'build', v_build);
END; $function$;

-- ── replace the active product in a ONE_PRODUCT store (preserve history) ─────
CREATE OR REPLACE FUNCTION public.fn_store_replace_active_product(p_new_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); cp record; s public.commerce_hosted_stores%rowtype; oldp uuid;
  v_auth jsonb; v_has_auth boolean; v_attach jsonb; v_market text := upper(nullif(btrim(coalesce(p_market,'')),''));
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_new_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF cp.user_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  SELECT * INTO s FROM public.commerce_hosted_stores
    WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_hosted_store'); END IF;

  v_auth := public.fn_ad_product_card_authority(v_tenant, p_new_product_id, v_market);
  v_has_auth := coalesce((v_auth->>'authoritative_count')::int,0) > 0;
  IF NOT v_has_auth THEN
    RETURN jsonb_build_object('ok',false,'status','IMPORT_REQUIRED','error','no_authoritative_product_asset',
      'action','IMPORT_PRODUCT_IMAGES','message','Import the new product''s images before replacing.'); END IF;

  oldp := s.active_product_id;
  IF oldp IS NOT NULL AND oldp <> p_new_product_id THEN
    -- preserve history: mark old relationship REPLACED and archive its page (never delete)
    UPDATE public.commerce_store_products
       SET lifecycle_state='REPLACED', updated_at=now(),
           provenance = provenance || jsonb_build_object('replaced_at',now(),'replaced_by',p_new_product_id)
     WHERE hosted_store_id=s.id AND product_id=oldp;
    UPDATE public.commerce_product_pages
       SET status='ARCHIVED', publication_state='UNPUBLISHED', updated_at=now()
     WHERE id IN (SELECT product_page_id FROM public.commerce_store_products
                   WHERE hosted_store_id=s.id AND product_id=oldp AND product_page_id IS NOT NULL);
  END IF;

  -- clear active so attach can set the new product active in the SAME store
  UPDATE public.commerce_hosted_stores SET active_product_id=NULL, updated_at=now() WHERE id=s.id;
  v_attach := public.fn_store_attach_product(p_new_product_id, v_market);
  -- ensure the new product is the active one
  UPDATE public.commerce_hosted_stores SET active_product_id=p_new_product_id, updated_at=now() WHERE id=s.id;

  RETURN jsonb_build_object('ok', coalesce((v_attach->>'ok')::boolean,false),'status','REPLACED',
    'hosted_store_id',s.id,'previous_product_id',oldp,'new_active_product_id',p_new_product_id,
    'history_preserved',true,'attach',v_attach);
END; $function$;

-- ── product lifecycle within the store (store stays alive; no hard delete) ───
CREATE OR REPLACE FUNCTION public.fn_store_product_set_lifecycle(p_product_id uuid, p_state text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype; sp record;
  v_state text := upper(btrim(coalesce(p_state,'')));
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  IF v_state NOT IN ('ACTIVE','SOLD_OUT','PAUSED','UNPUBLISHED','ARCHIVED') THEN
    RETURN jsonb_build_object('ok',false,'error','invalid_lifecycle_state',
      'allowed',jsonb_build_array('ACTIVE','SOLD_OUT','PAUSED','UNPUBLISHED','ARCHIVED')); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_hosted_store'); END IF;
  SELECT * INTO sp FROM public.commerce_store_products WHERE hosted_store_id=s.id AND product_id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_in_store'); END IF;

  UPDATE public.commerce_store_products SET lifecycle_state=v_state, updated_at=now() WHERE id=sp.id;
  -- reflect on the page where meaningful; store itself remains ACTIVE
  IF sp.product_page_id IS NOT NULL AND v_state IN ('UNPUBLISHED','ARCHIVED') THEN
    UPDATE public.commerce_product_pages
       SET publication_state='UNPUBLISHED',
           status = CASE WHEN v_state='ARCHIVED' THEN 'ARCHIVED' ELSE status END, updated_at=now()
     WHERE id=sp.product_page_id;
  END IF;
  -- if the active product is paused/sold-out/unpublished/archived, it stays the featured slot
  -- (store remains alive); clearing the slot is an explicit replace, not a lifecycle change.
  RETURN jsonb_build_object('ok',true,'hosted_store_id',s.id,'product_id',p_product_id,
    'lifecycle_state',v_state,'store_status',s.status,'store_remains_alive',true);
END; $function$;

-- ── grants ───────────────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.fn_hosted_store_entitlement(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_hosted_store_entitlement(uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.fn_hosted_store_get_or_create(uuid,text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_hosted_store_get_or_create(uuid,text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.fn_create_free_store(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_create_free_store(text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_hosted_store_get() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_hosted_store_get() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_store_attach_product(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_store_attach_product(uuid,text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_store_replace_active_product(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_store_replace_active_product(uuid,text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_store_product_set_lifecycle(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_store_product_set_lifecycle(uuid,text) TO authenticated, service_role;

-- ── (extend) Product Card actions reflect the PERSISTENT store state ─────────
CREATE OR REPLACE FUNCTION public.fn_product_card_commerce_actions(p_product_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_owner uuid; v_auth jsonb; v_has_auth boolean;
  hs public.commerce_hosted_stores%rowtype; v_has_hosted boolean := false; spr record; v_attached boolean := false;
  v_conn record; v_pushable boolean := false; v_ext boolean := false;
  v_page record; v_page_state text; v_pub_state text := 'UNPUBLISHED'; v_published_url text; v_page_id uuid;
  v_market text := nullif(btrim(coalesce(p_market,'')),''); v_actions jsonb := '[]'::jsonb; v_readiness text;
  v_ent jsonb; v_is_active boolean := false; v_this_lifecycle text;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_auth := public.fn_ad_product_card_authority(v_tenant, p_product_id, v_market);
  v_has_auth := coalesce((v_auth->>'authoritative_count')::int,0) > 0;

  SELECT * INTO hs FROM public.commerce_hosted_stores
    WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  v_has_hosted := FOUND;
  IF v_has_hosted THEN
    SELECT * INTO spr FROM public.commerce_store_products WHERE hosted_store_id=hs.id AND product_id=p_product_id;
    v_attached := FOUND;
    v_this_lifecycle := spr.lifecycle_state;
    v_is_active := (hs.active_product_id = p_product_id);
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

  v_readiness := CASE WHEN v_has_auth THEN 'READY' ELSE 'IMPORT_REQUIRED' END;

  -- CREATE_AD is always present, independent of store lifecycle
  v_actions := jsonb_build_array(jsonb_build_object('key','CREATE_AD','label','Create Ad','enabled',v_has_auth,
    'reason', CASE WHEN v_has_auth THEN 'authoritative_image_available' ELSE 'import_product_images_first' END,
    'route','creative_studio'));

  IF v_has_hosted THEN
    -- persistent hosted store exists: NEVER offer CREATE_FREE_STORE again
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','MANAGE_STORE','label','Manage Store',
      'enabled',true,'reason','hosted_store_exists','route','store_manager','hosted_store_id',hs.id,
      'store_mode',hs.store_mode,'slug',hs.slug,'public_route',hs.public_route));

    IF v_attached OR v_is_active THEN
      v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','PUBLISH_TO_STORE',
        'label', CASE WHEN v_pub_state='PUBLISHED' THEN 'Update Store Product' ELSE 'Publish to Store' END,
        'enabled', (v_has_auth AND coalesce(spr.product_page_id, v_page_id) IS NOT NULL),
        'reason', CASE WHEN NOT v_has_auth THEN 'import_product_images_first'
                       WHEN coalesce(spr.product_page_id, v_page_id) IS NULL THEN 'build_store_page_first' ELSE 'ready' END,
        'hosted_store_id',hs.id,'store_product_id',spr.id,'product_page_id',coalesce(spr.product_page_id,v_page_id),
        'lifecycle_state',v_this_lifecycle));
    ELSIF hs.store_mode='ONE_PRODUCT' AND hs.active_product_id IS NOT NULL AND hs.active_product_id <> p_product_id THEN
      v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','REPLACE_CURRENT_PRODUCT',
        'label','Replace Current Product','enabled',v_has_auth,
        'reason', CASE WHEN v_has_auth THEN 'one_product_store_swap' ELSE 'import_product_images_first' END,
        'hosted_store_id',hs.id,'current_active_product_id',hs.active_product_id));
    ELSE
      v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','ADD_TO_STORE',
        'label','Add to Store','enabled',v_has_auth,
        'reason', CASE WHEN v_has_auth THEN 'ready' ELSE 'import_product_images_first' END,
        'hosted_store_id',hs.id,'store_mode',hs.store_mode));
    END IF;

  ELSIF v_pushable THEN
    -- connected pushable external store, no hosted store: use it; do NOT auto-offer a hosted store
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','PUBLISH_TO_STORE',
      'label', CASE WHEN v_pub_state='PUBLISHED' THEN 'Update Store Product' ELSE 'Publish to Store' END,
      'enabled', (v_has_auth AND v_page_id IS NOT NULL),
      'reason', CASE WHEN NOT v_has_auth THEN 'import_product_images_first'
                     WHEN v_page_id IS NULL THEN 'create_store_page_first' ELSE 'ready' END,
      'provider',v_conn.provider,'store_connection_id',v_conn.id));

  ELSE
    -- no hosted store, no pushable external store: offer free hosted store + connect
    v_ent := public.fn_hosted_store_entitlement(v_tenant);
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('key','CREATE_FREE_STORE','label','Create Free Store',
      'enabled', (v_ent->>'eligible')::boolean,
      'reason', CASE WHEN (v_ent->>'eligible')::boolean THEN 'entitled' ELSE 'subscription_required' END,
      'route','create_free_store',
      'message','No setup fee — hosting included in your Strateloq subscription.',
      'entitlement', v_ent));
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

REVOKE EXECUTE ON FUNCTION public.fn_product_card_commerce_actions(uuid,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fn_product_card_commerce_actions(uuid,text) TO authenticated, service_role;

-- ============================================================================
-- mig_317_store_website_visibility_and_home.sql
-- STRATELOQ — the actual multi-product hosted-store WEBSITE contract.
-- ----------------------------------------------------------------------------
-- The public renderer (fn_public_storefront_render) is PAGE-level only; there is no
-- store-level homepage/catalog contract, and commerce_store_products has no
-- website-visibility control (store membership != website visibility). This adds the
-- smallest tenant-safe additions to model an actual storefront website WITHOUT
-- rebuilding storefront/renderer/publish:
--   1. commerce_store_products.storefront_visible (bool) — website visibility, separate
--      from lifecycle/membership. Rows are never deleted; hidden products stay for
--      history/intelligence.
--   2. fn_store_set_product_visibility(product_id, visible) — tenant-safe toggle.
--   3. fn_store_set_website_hero(product_id) — store hero product (brand_settings).
--   4. fn_store_website() — authenticated store website model: store header, hero,
--      website catalog (visible products with image/name/benefit/price/page state/
--      video state/publish readiness) + hidden[] (internal-only). Feeds Preview Website
--      and My Store website controls. Images come from the Product Card display image
--      (fn_product_card_display_image), never fabricated.
--   5. fn_public_store_home(slug) — public homepage: store + PUBLISHED visible products
--      only (no auth); nothing shows publicly until its page is published.
--   6. fn_store_website_publish_context() — aggregate publish readiness across the
--      visible product pages, reusing the per-page blocker vocabulary.
-- No fabricated reviews/prices/discounts/scarcity. Idempotent.
-- ============================================================================

-- 1) Website visibility (separate from lifecycle / store membership).
ALTER TABLE public.commerce_store_products
  ADD COLUMN IF NOT EXISTS storefront_visible boolean NOT NULL DEFAULT false;

-- 2) Toggle a product's website visibility (tenant-owned only; row preserved either way).
CREATE OR REPLACE FUNCTION public.fn_store_set_product_visibility(p_product_id uuid, p_visible boolean)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype; n int;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_hosted_store'); END IF;
  UPDATE public.commerce_store_products SET storefront_visible=coalesce(p_visible,false), updated_at=now()
    WHERE hosted_store_id=s.id AND product_id=p_product_id AND user_id=v_tenant;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n=0 THEN RETURN jsonb_build_object('ok',false,'error','product_not_in_store'); END IF;
  RETURN jsonb_build_object('ok',true,'product_id',p_product_id,'storefront_visible',coalesce(p_visible,false),'hosted_store_id',s.id);
END; $fn$;

-- 3) Set the store's website hero product (must be a visible store product).
CREATE OR REPLACE FUNCTION public.fn_store_set_website_hero(p_product_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype; v_ok boolean;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_hosted_store'); END IF;
  SELECT storefront_visible INTO v_ok FROM public.commerce_store_products
    WHERE hosted_store_id=s.id AND product_id=p_product_id;
  IF NOT coalesce(v_ok,false) THEN RETURN jsonb_build_object('ok',false,'error','hero_must_be_visible_product'); END IF;
  UPDATE public.commerce_hosted_stores
    SET brand_settings = coalesce(brand_settings,'{}'::jsonb) || jsonb_build_object('website_hero_product_id', p_product_id::text),
        updated_at=now()
    WHERE id=s.id;
  RETURN jsonb_build_object('ok',true,'hosted_store_id',s.id,'website_hero_product_id',p_product_id);
END; $fn$;

REVOKE EXECUTE ON FUNCTION public.fn_store_set_product_visibility(uuid,boolean) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fn_store_set_website_hero(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_store_set_product_visibility(uuid,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_store_set_website_hero(uuid) TO authenticated, service_role;

-- Internal helper: build a website product summary row from a store product + its page.
CREATE OR REPLACE FUNCTION public.fn_store_website_product(p_tenant uuid, p_hosted_store_id uuid, p_product_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE sp record; cp record; pp record; v_img jsonb; rc jsonb; pm jsonb; v_blockers text[]; v_ready boolean;
BEGIN
  SELECT * INTO sp FROM public.commerce_store_products WHERE hosted_store_id=p_hosted_store_id AND product_id=p_product_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product_id;
  SELECT * INTO pp FROM public.commerce_product_pages WHERE id=sp.product_page_id;
  v_img := public.fn_product_card_display_image(p_tenant, p_product_id, sp.market);
  rc := coalesce(pp.runtime_contract,'{}'::jsonb); pm := coalesce(pp.page_model,'{}'::jsonb);
  v_blockers := ARRAY[]::text[];
  IF upper(coalesce(pp.review_state,'')) NOT IN ('APPROVED','PUBLISHED') THEN v_blockers := array_append(v_blockers,'NOT_APPROVED'); END IF;
  IF coalesce(rc->>'generation_state','') <> 'GENERATED' THEN v_blockers := array_append(v_blockers,'NOT_GENERATED'); END IF;
  IF upper(coalesce(rc->>'economics_state','')) NOT IN ('VIABLE','POSITIVE') THEN v_blockers := array_append(v_blockers,'ECONOMICS_NOT_VIABLE'); END IF;
  IF NOT coalesce((rc->'claim_safety'->>'claim_scan_clean')::boolean,false) THEN v_blockers := array_append(v_blockers,'CLAIMS_NOT_CLEAN'); END IF;
  IF coalesce(rc->>'assets_state','') <> 'ASSETS_AVAILABLE' THEN v_blockers := array_append(v_blockers,'ASSETS_UNAVAILABLE'); END IF;
  v_ready := (array_length(v_blockers,1) IS NULL);
  RETURN jsonb_build_object(
    'product_id', p_product_id, 'product_name', cp.title,
    'store_product_id', sp.id, 'product_page_id', sp.product_page_id, 'market', sp.market,
    'lifecycle_state', sp.lifecycle_state, 'storefront_visible', sp.storefront_visible,
    'image_url', v_img->>'url', 'image_rights_state', v_img->>'rights_state',
    'price', pp.selling_price, 'currency', pp.display_currency,
    'headline', coalesce(pm->'hero'->>'headline', rc->'selection'->>'product_title'),
    'short_description', pm->>'short_description',
    'benefits', pm->'benefits',
    'generation_state', rc->>'generation_state',
    'page_status', pp.status, 'review_state', pp.review_state, 'publication_state', pp.publication_state,
    'published_url', CASE WHEN upper(coalesce(pp.publication_state,''))='PUBLISHED' THEN pp.published_url ELSE NULL END,
    'video_state', coalesce(rc->'supplier_asset_refs'->>'video_state','VIDEO_ASSET_NOT_AVAILABLE'),
    'publish_ready', v_ready,
    'publish_blockers', to_jsonb(v_blockers),
    'publish_blocker_details', coalesce((SELECT jsonb_agg(public.fn_storefront_publish_blocker_detail(b) ORDER BY (public.fn_storefront_publish_blocker_detail(b)->>'priority')::int) FROM unnest(v_blockers) b),'[]'::jsonb));
END; $fn$;

-- 4) Authenticated store website model (Preview Website + My Store website controls).
CREATE OR REPLACE FUNCTION public.fn_store_website()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype;
  v_hero_id uuid; v_catalog jsonb; v_hidden jsonb; v_hero jsonb;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',true,'has_website',false); END IF;

  v_hero_id := nullif(s.brand_settings->>'website_hero_product_id','')::uuid;
  v_catalog := coalesce((SELECT jsonb_agg(public.fn_store_website_product(v_tenant, s.id, sp.product_id) ORDER BY sp.updated_at)
      FROM public.commerce_store_products sp WHERE sp.hosted_store_id=s.id AND sp.storefront_visible),'[]'::jsonb);
  v_hidden := coalesce((SELECT jsonb_agg(jsonb_build_object(
        'product_id', sp.product_id, 'product_name', cp.title, 'lifecycle_state', sp.lifecycle_state,
        'product_page_id', sp.product_page_id, 'not_shown_on_website', true) ORDER BY sp.updated_at)
      FROM public.commerce_store_products sp LEFT JOIN public.commerce_products cp ON cp.id=sp.product_id
      WHERE sp.hosted_store_id=s.id AND NOT sp.storefront_visible),'[]'::jsonb);
  -- Hero: explicit hero if visible, else first visible catalog entry.
  v_hero := CASE WHEN v_hero_id IS NOT NULL AND EXISTS(SELECT 1 FROM jsonb_array_elements(v_catalog) c WHERE (c->>'product_id')::uuid=v_hero_id)
                 THEN (SELECT c FROM jsonb_array_elements(v_catalog) c WHERE (c->>'product_id')::uuid=v_hero_id LIMIT 1)
                 WHEN jsonb_array_length(v_catalog)>0 THEN v_catalog->0 ELSE NULL END;

  RETURN jsonb_build_object('ok',true,'has_website',true,
    'store', jsonb_build_object('hosted_store_id',s.id,'display_name',public.fn_store_display_name(s.brand_settings),
       'status',s.status,'store_mode',s.store_mode,'slug',s.slug,'public_route',s.public_route,
       'brand_settings',s.brand_settings),
    'hero_product', v_hero,
    'catalog', v_catalog,
    'catalog_count', jsonb_array_length(v_catalog),
    'hidden', v_hidden,
    'claim_safety', jsonb_build_object('no_fabricated_reviews',true,'no_fake_discount',true,
       'no_urgency_scarcity',true,'no_guarantees',true));
END; $fn$;

-- 5) Public homepage: store + PUBLISHED visible products only (nothing until published).
CREATE OR REPLACE FUNCTION public.fn_public_store_home(p_slug text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE s public.commerce_hosted_stores%rowtype; v_products jsonb; v_hero_id uuid; v_hero jsonb;
BEGIN
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE (slug=p_slug OR public_route=p_slug) AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  v_hero_id := nullif(s.brand_settings->>'website_hero_product_id','')::uuid;
  v_products := coalesce((SELECT jsonb_agg(public.fn_store_website_product(s.user_id, s.id, sp.product_id) ORDER BY sp.updated_at)
      FROM public.commerce_store_products sp
      JOIN public.commerce_product_pages pp ON pp.id=sp.product_page_id
      WHERE sp.hosted_store_id=s.id AND sp.storefront_visible AND upper(coalesce(pp.publication_state,''))='PUBLISHED'),'[]'::jsonb);
  IF jsonb_array_length(v_products)=0 THEN
    RETURN jsonb_build_object('status','NO_PUBLISHED_PRODUCTS','store_name',public.fn_store_display_name(s.brand_settings));
  END IF;
  v_hero := CASE WHEN v_hero_id IS NOT NULL AND EXISTS(SELECT 1 FROM jsonb_array_elements(v_products) c WHERE (c->>'product_id')::uuid=v_hero_id)
                 THEN (SELECT c FROM jsonb_array_elements(v_products) c WHERE (c->>'product_id')::uuid=v_hero_id LIMIT 1)
                 ELSE v_products->0 END;
  RETURN jsonb_build_object('status','OK',
    'store', jsonb_build_object('name',public.fn_store_display_name(s.brand_settings),'slug',s.slug,'public_route',s.public_route),
    'hero_product', v_hero, 'catalog', v_products, 'catalog_count', jsonb_array_length(v_products),
    'checkout', jsonb_build_object('state','CHECKOUT_NOT_CONFIGURED','functional',false),
    'claim_safety', jsonb_build_object('no_fabricated_reviews',true,'no_fake_discount',true,'no_urgency_scarcity',true));
END; $fn$;
GRANT EXECUTE ON FUNCTION public.fn_public_store_home(text) TO anon, authenticated, service_role;

-- 6) Store-level publish readiness aggregated across the visible product pages.
CREATE OR REPLACE FUNCTION public.fn_store_website_publish_context()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype; v_rows jsonb; v_ready boolean; v_count int;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_hosted_store'); END IF;
  v_rows := coalesce((SELECT jsonb_agg(public.fn_store_website_product(v_tenant, s.id, sp.product_id) ORDER BY sp.updated_at)
      FROM public.commerce_store_products sp WHERE sp.hosted_store_id=s.id AND sp.storefront_visible),'[]'::jsonb);
  v_count := jsonb_array_length(v_rows);
  v_ready := (v_count > 0) AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE (r->>'publish_ready')::boolean IS DISTINCT FROM true);
  RETURN jsonb_build_object('status','ok','hosted_store_id',s.id,'catalog_count',v_count,
    'website_publish_ready', v_ready,
    'products', v_rows,
    'note','store website is publishable when every website-visible product page is publish-ready; page-level gates are never bypassed');
END; $fn$;

REVOKE EXECUTE ON FUNCTION public.fn_store_website() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.fn_store_website_publish_context() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_store_website() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_store_website_publish_context() TO authenticated, service_role;

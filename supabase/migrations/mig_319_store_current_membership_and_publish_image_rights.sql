-- ============================================================================
-- mig_319_store_current_membership_and_publish_image_rights.sql
-- STRATELOQ — CURRENT STORE MEMBERSHIP vs HISTORY vs WEBSITE VISIBILITY.
--
-- Problem this fixes:
--   "My Store" (and the storefront website) were sourcing products from EVERY
--   historical commerce_store_products row, so any product that was ever
--   researched, page-built or auto-attached leaked into the merchant's current
--   store catalogue / "Not shown on website" list — even though the merchant
--   never selected it. Three distinct concepts were being conflated:
--     (A) STORE HISTORY        — a commerce_store_products row exists at all
--     (B) CURRENT MEMBERSHIP   — the product is one the merchant currently sells
--     (C) WEBSITE VISIBILITY   — a current member shown on the public storefront
--
-- Model (reuses the EXISTING lifecycle_state axis — no new membership field):
--   CURRENT MEMBER  := lifecycle_state IN ('ACTIVE','SOLD_OUT','PAUSED')
--                      (identical to the long-standing v_in_store predicate
--                       already used by fn_product_card_commerce_actions).
--   HISTORY / NOT A MEMBER := any other lifecycle_state
--                      ('UNPUBLISHED','REPLACED','ARCHIVED','REMOVED', …).
--                      Rows are PRESERVED — history/audit is never deleted.
--   WEBSITE-VISIBLE := CURRENT MEMBER *and* storefront_visible = true.
--                      storefront_visible alone NEVER implies membership.
--
-- This migration only changes the READ/derivation surfaces + adds a
-- non-destructive "Remove from Store" action + refines the publish
-- image-rights copy. It contains NO tenant-specific data repair (that is
-- applied out-of-band to the founder test store so no generated IDs are
-- baked into version control). Idempotent (CREATE OR REPLACE). RLS, tenant
-- isolation, Product Asset Lock and the one-store invariant are unchanged.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Single source of truth for the membership predicate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_store_is_member(p_lifecycle text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT upper(btrim(coalesce(p_lifecycle,''))) IN ('ACTIVE','SOLD_OUT','PAUSED');
$function$;

COMMENT ON FUNCTION public.fn_store_is_member(text) IS
  'Canonical CURRENT STORE MEMBERSHIP predicate. A commerce_store_products row is a current member iff lifecycle_state is in-store (ACTIVE/SOLD_OUT/PAUSED). Any other state is preserved history, not a current member. storefront_visible is a separate axis (website visibility) and never implies membership.';

-- ---------------------------------------------------------------------------
-- 1. My Store (fn_hosted_store_get): products = CURRENT MEMBERS only.
--    Non-members are preserved and returned separately under `history`
--    purely for audit — the merchant's store catalogue / product management
--    UI must render only `products`.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_hosted_store_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype; v_active_name text;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores
    WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',true,'has_hosted_store',false); END IF;

  SELECT title INTO v_active_name FROM public.commerce_products WHERE id = s.active_product_id;

  RETURN jsonb_build_object('ok',true,'has_hosted_store',true,
    'hosted_store', jsonb_build_object('hosted_store_id',s.id,'store_mode',s.store_mode,'status',s.status,
       'slug',s.slug,'public_route',s.public_route,'custom_domain',s.custom_domain,
       'display_name', public.fn_store_display_name(s.brand_settings),
       'active_product_id',s.active_product_id,'active_product_name',v_active_name,
       'brand_settings',s.brand_settings,'theme_settings',s.theme_settings),
    -- CURRENT MEMBERS only — this is the store catalogue the merchant manages
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'store_product_id',sp.id,'product_id',sp.product_id,'product_page_id',sp.product_page_id,
        'product_name', cp.title,
        'lifecycle_state',sp.lifecycle_state,'market',sp.market,'remote_url',sp.remote_url,
        'storefront_visible', sp.storefront_visible,
        'is_member', true,
        'page_status', pp.status,
        'page_publication_state', coalesce(pp.publication_state,'UNPUBLISHED'),
        'is_active',(sp.product_id = s.active_product_id)) ORDER BY sp.updated_at DESC)
      FROM public.commerce_store_products sp
      LEFT JOIN public.commerce_products cp ON cp.id = sp.product_id
      LEFT JOIN public.commerce_product_pages pp ON pp.id = sp.product_page_id
      WHERE sp.hosted_store_id=s.id AND public.fn_store_is_member(sp.lifecycle_state)),'[]'::jsonb),
    'member_count', (SELECT count(*) FROM public.commerce_store_products sp
        WHERE sp.hosted_store_id=s.id AND public.fn_store_is_member(sp.lifecycle_state)),
    -- Preserved history (NOT current members) — for audit only; never rendered
    -- as store products / "not shown on website".
    'history', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'store_product_id',sp.id,'product_id',sp.product_id,'product_name',cp.title,
        'lifecycle_state',sp.lifecycle_state,'is_member',false) ORDER BY sp.updated_at DESC)
      FROM public.commerce_store_products sp
      LEFT JOIN public.commerce_products cp ON cp.id = sp.product_id
      WHERE sp.hosted_store_id=s.id AND NOT public.fn_store_is_member(sp.lifecycle_state)),'[]'::jsonb));
END; $function$;

-- ---------------------------------------------------------------------------
-- 2. Storefront website (fn_store_website): catalogue and the "Not shown on
--    website" (hidden) list are BOTH scoped to current members. A non-member
--    can never appear in either list.
--      catalog := member AND storefront_visible
--      hidden  := member AND NOT storefront_visible   (member you chose to hide)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_store_website()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype;
  v_hero_id uuid; v_catalog jsonb; v_hidden jsonb; v_hero jsonb;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',true,'has_website',false); END IF;

  v_hero_id := nullif(s.brand_settings->>'website_hero_product_id','')::uuid;
  v_catalog := coalesce((SELECT jsonb_agg(public.fn_store_website_product(v_tenant, s.id, sp.product_id) ORDER BY sp.updated_at)
      FROM public.commerce_store_products sp
      WHERE sp.hosted_store_id=s.id AND public.fn_store_is_member(sp.lifecycle_state) AND sp.storefront_visible),'[]'::jsonb);
  v_hidden := coalesce((SELECT jsonb_agg(jsonb_build_object(
        'product_id', sp.product_id, 'product_name', cp.title, 'lifecycle_state', sp.lifecycle_state,
        'product_page_id', sp.product_page_id, 'not_shown_on_website', true) ORDER BY sp.updated_at)
      FROM public.commerce_store_products sp LEFT JOIN public.commerce_products cp ON cp.id=sp.product_id
      WHERE sp.hosted_store_id=s.id AND public.fn_store_is_member(sp.lifecycle_state) AND NOT sp.storefront_visible),'[]'::jsonb);
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
END; $function$;

-- ---------------------------------------------------------------------------
-- 3. fn_store_website_product: surface honest image provenance so the UI can
--    show a marketplace preview image with correct labelling, and can tell a
--    preview-available image apart from a publish-cleared image.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_store_website_product(p_tenant uuid, p_hosted_store_id uuid, p_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    'is_member', public.fn_store_is_member(sp.lifecycle_state),
    'image_url', v_img->>'url', 'image_rights_state', v_img->>'rights_state',
    -- honest provenance: a preview image may exist without publish rights
    'has_preview_image', coalesce((v_img->>'has_image')::boolean,false),
    'image_is_authoritative', coalesce((v_img->>'is_authoritative')::boolean,false),
    'image_source_provider', v_img->>'source_provider',
    'image_publishable', (coalesce(rc->>'assets_state','') = 'ASSETS_AVAILABLE'),
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
END; $function$;

-- ---------------------------------------------------------------------------
-- 4. Website publish aggregation: only current + website-visible members count.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_store_website_publish_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype; v_rows jsonb; v_ready boolean; v_count int;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_hosted_store'); END IF;
  v_rows := coalesce((SELECT jsonb_agg(public.fn_store_website_product(v_tenant, s.id, sp.product_id) ORDER BY sp.updated_at)
      FROM public.commerce_store_products sp
      WHERE sp.hosted_store_id=s.id AND public.fn_store_is_member(sp.lifecycle_state) AND sp.storefront_visible),'[]'::jsonb);
  v_count := jsonb_array_length(v_rows);
  v_ready := (v_count > 0) AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE (r->>'publish_ready')::boolean IS DISTINCT FROM true);
  RETURN jsonb_build_object('status','ok','hosted_store_id',s.id,'catalog_count',v_count,
    'website_publish_ready', v_ready,
    'products', v_rows,
    'note','store website is publishable when every website-visible member page is publish-ready; page-level gates are never bypassed');
END; $function$;

-- ---------------------------------------------------------------------------
-- 5. Public storefront homepage: current + visible + PUBLISHED members only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_public_store_home(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE s public.commerce_hosted_stores%rowtype; v_products jsonb; v_hero_id uuid; v_hero jsonb;
BEGIN
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE (slug=p_slug OR public_route=p_slug) AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  v_hero_id := nullif(s.brand_settings->>'website_hero_product_id','')::uuid;
  v_products := coalesce((SELECT jsonb_agg(public.fn_store_website_product(s.user_id, s.id, sp.product_id) ORDER BY sp.updated_at)
      FROM public.commerce_store_products sp
      JOIN public.commerce_product_pages pp ON pp.id=sp.product_page_id
      WHERE sp.hosted_store_id=s.id AND public.fn_store_is_member(sp.lifecycle_state)
        AND sp.storefront_visible AND upper(coalesce(pp.publication_state,''))='PUBLISHED'),'[]'::jsonb);
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
END; $function$;

-- ---------------------------------------------------------------------------
-- 6. Non-destructive "Remove from Store": drops a product from CURRENT
--    membership and the website, preserving the row, its product page and all
--    provenance/history. Never deletes; never touches other tenants.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_store_remove_product(p_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); s public.commerce_hosted_stores%rowtype; sp record; v_new_active uuid;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO s FROM public.commerce_hosted_stores WHERE user_id=v_tenant AND is_default AND status<>'ARCHIVED' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_hosted_store'); END IF;
  SELECT * INTO sp FROM public.commerce_store_products
    WHERE hosted_store_id=s.id AND product_id=p_product_id AND user_id=v_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_in_store'); END IF;

  IF NOT public.fn_store_is_member(sp.lifecycle_state) THEN
    RETURN jsonb_build_object('ok',true,'status','ALREADY_NOT_A_MEMBER','product_id',p_product_id,
      'hosted_store_id',s.id,'lifecycle_state',sp.lifecycle_state,'non_destructive',true);
  END IF;

  -- Non-destructive: preserve row + product page + provenance; only drop the
  -- product from the merchant's current store membership and public website.
  -- ARCHIVED is the existing lifecycle state for "preserved history, not a
  -- current member" (lifecycle_state check constraint allows no 'REMOVED').
  UPDATE public.commerce_store_products
     SET lifecycle_state='ARCHIVED', storefront_visible=false, updated_at=now(),
         provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object(
           'removed_from_membership_at', now(),
           'removed_from_membership_by', 'fn_store_remove_product',
           'prior_lifecycle_state', sp.lifecycle_state)
   WHERE id=sp.id;

  -- Keep the legacy active pointer valid: if it referenced the removed product,
  -- repoint it at another current member (or NULL if none remain).
  IF s.active_product_id = p_product_id THEN
    SELECT sp2.product_id INTO v_new_active FROM public.commerce_store_products sp2
      WHERE sp2.hosted_store_id=s.id AND sp2.product_id<>p_product_id
        AND public.fn_store_is_member(sp2.lifecycle_state)
      ORDER BY sp2.updated_at DESC LIMIT 1;
    UPDATE public.commerce_hosted_stores SET active_product_id=v_new_active, updated_at=now() WHERE id=s.id;
  END IF;

  RETURN jsonb_build_object('ok',true,'status','REMOVED_FROM_STORE','product_id',p_product_id,
    'hosted_store_id',s.id,'non_destructive',true,
    'removed_from', jsonb_build_array('current_membership','website_catalog'),
    'preserved','commerce_store_products row, product page, provenance and research history retained',
    'store_product_id', sp.id);
END; $function$;

-- ---------------------------------------------------------------------------
-- 7. Publish image blocker copy: distinguish a PREVIEW/DISPLAY image (which a
--    product may already have, e.g. a marketplace listing image) from a
--    RIGHTS-CLEARED image required for PUBLIC PUBLICATION. Same structured
--    contract; only the customer-facing wording + action key change.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_publish_blocker_detail(p_code text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE upper(btrim(coalesce(p_code,'')))
    WHEN 'NOT_GENERATED' THEN jsonb_build_object('code','NOT_GENERATED','priority',10,'retryable',false,
      'title','Finish building this page',
      'message','This page''s storefront content has not been generated yet. Complete the builder steps to prepare it for publishing.',
      'action_key','OPEN_BUILDER','action_label','Review page')
    WHEN 'ASSETS_UNAVAILABLE' THEN jsonb_build_object('code','ASSETS_UNAVAILABLE','priority',20,'retryable',false,
      'title','Publishable image required',
      'message','A rights-cleared product image is required before this product can be published publicly. Any preview image shown comes from a marketplace listing and can be used for previews only, not for public publication.',
      'action_key','ADD_PUBLISHABLE_IMAGE','action_label','Add publishable image')
    WHEN 'CLAIMS_NOT_CLEAN' THEN jsonb_build_object('code','CLAIMS_NOT_CLEAN','priority',30,'retryable',false,
      'title','Content review needed',
      'message','Some wording on this page needs review before it can be published.',
      'action_key','REVIEW_CONTENT','action_label','Review content')
    WHEN 'ECONOMICS_NOT_VIABLE' THEN jsonb_build_object('code','ECONOMICS_NOT_VIABLE','priority',40,'retryable',false,
      'title','Complete required details',
      'message','Complete the required pricing and margin details before publishing.',
      'action_key','FIX_DETAILS','action_label','Complete details')
    WHEN 'NOT_APPROVED' THEN jsonb_build_object('code','NOT_APPROVED','priority',50,'retryable',false,
      'title','Review approval needed',
      'message','This page still needs review approval before it can be published.',
      'action_key','COMPLETE_REVIEW','action_label','Complete review')
    WHEN 'DESTINATION_NOT_PULSE_HOSTED' THEN jsonb_build_object('code','DESTINATION_NOT_PULSE_HOSTED','priority',60,'retryable',false,
      'title','Set publishing destination',
      'message','Set this page''s destination to your Strateloq store before publishing.',
      'action_key','SET_DESTINATION','action_label','Choose destination')
    ELSE jsonb_build_object('code', upper(btrim(coalesce(p_code,'UNKNOWN'))),'priority',900,'retryable',false,
      'title','Not ready to publish',
      'message','This page is not ready to publish yet. Complete the remaining steps in the builder.',
      'action_key','OPEN_BUILDER','action_label','Review page')
  END;
$function$;

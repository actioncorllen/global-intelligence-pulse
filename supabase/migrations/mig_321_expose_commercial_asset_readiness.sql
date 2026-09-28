-- ============================================================================
-- mig_321_expose_commercial_asset_readiness.sql
-- STRATELOQ — Surface the commercial-asset-readiness signal on each store /
-- website product so My Store and the storefront can show, per product,
-- whether a legitimate publishable commercial-image path exists:
--   commercial_asset_readiness : READY | GENERATABLE_FROM_AUTHORIZED_REFERENCE
--                                | CUSTOMER_ASSET_REQUIRED | UNAVAILABLE
--   publishable_asset_path     : the winning path (or NONE)
--   commercial_asset_basis     : plain-language, honest reason
--   ai_generation_state        : BLOCKED_EXTERNAL_CONNECTION | NOT_ELIGIBLE
--
-- Pure additive read; publish gates, membership and rights model unchanged.
-- Reuses fn_product_commercial_asset_readiness (mig_320). Idempotent.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_store_website_product(p_tenant uuid, p_hosted_store_id uuid, p_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE sp record; cp record; pp record; v_img jsonb; rc jsonb; pm jsonb; v_blockers text[]; v_ready boolean; v_car jsonb;
BEGIN
  SELECT * INTO sp FROM public.commerce_store_products WHERE hosted_store_id=p_hosted_store_id AND product_id=p_product_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product_id;
  SELECT * INTO pp FROM public.commerce_product_pages WHERE id=sp.product_page_id;
  v_img := public.fn_product_card_display_image(p_tenant, p_product_id, sp.market);
  v_car := public.fn_product_commercial_asset_readiness(p_product_id, sp.market);
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
    'has_preview_image', coalesce((v_img->>'has_image')::boolean,false),
    'image_is_authoritative', coalesce((v_img->>'is_authoritative')::boolean,false),
    'image_source_provider', v_img->>'source_provider',
    'image_publishable', (coalesce(rc->>'assets_state','') = 'ASSETS_AVAILABLE'),
    'commercial_asset_readiness', v_car->>'commercial_asset_readiness',
    'publishable_asset_path', v_car->>'publishable_asset_path',
    'commercial_asset_basis', v_car->>'basis',
    'ai_generation_state', v_car->'ai_generation'->>'execution_state',
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

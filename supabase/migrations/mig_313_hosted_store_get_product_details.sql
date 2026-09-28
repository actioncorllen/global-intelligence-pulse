-- ============================================================================
-- mig_313_hosted_store_get_product_details.sql
-- STRATELOQ — enrich fn_hosted_store_get so the permanent "My Store" Store Manager
-- can render real per-product state without extra client round-trips:
--   • hosted_store.active_product_name
--   • each product: product_name (title), page_status, page_publication_state
-- Additive only (same contract keys plus new ones). Still SECURITY DEFINER,
-- tenant = auth.uid(); no new store, no schema change. Idempotent.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_hosted_store_get()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
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
    'products', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'store_product_id',sp.id,'product_id',sp.product_id,'product_page_id',sp.product_page_id,
        'product_name', cp.title,
        'lifecycle_state',sp.lifecycle_state,'market',sp.market,'remote_url',sp.remote_url,
        'page_status', pp.status,
        'page_publication_state', coalesce(pp.publication_state,'UNPUBLISHED'),
        'is_active',(sp.product_id = s.active_product_id)) ORDER BY sp.updated_at DESC)
      FROM public.commerce_store_products sp
      LEFT JOIN public.commerce_products cp ON cp.id = sp.product_id
      LEFT JOIN public.commerce_product_pages pp ON pp.id = sp.product_page_id
      WHERE sp.hosted_store_id=s.id),'[]'::jsonb));
END; $function$;

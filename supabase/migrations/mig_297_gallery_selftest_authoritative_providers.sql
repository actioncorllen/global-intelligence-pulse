-- ============================================================================
-- mig_297_gallery_selftest_authoritative_providers.sql
-- STRATELOQ-STAGE4C-PRODUCT-IMAGE-VARIANT-SKU
--
-- The product-gallery self-test's `no_ai_or_web_sources` guard asserts that every
-- product_image_assets row comes from an authoritative provider (never AI-generated or
-- web-scraped). Its allow-list was stale — only ('CJ_SUPPLIER','EBAY_BROWSE') — written
-- before the FastMoss/Kalodata discovery lanes began storing PROVIDER_DISCOVERY_REFERENCE
-- images. Production now legitimately holds FASTMOSS discovery-reference images (rights-
-- locked, reference-only), so the guard failed on real, authoritative, rights-correct data
-- (verified: providers present are CJ_SUPPLIER/SUPPLIER_PROVIDED, EBAY_BROWSE/
-- MARKETPLACE_PUBLIC_LISTING, FASTMOSS/PROVIDER_DISCOVERY_REFERENCE — no AI/web source).
--
-- Fix (test-only, smallest change): add the authoritative TikTok-Shop discovery providers
-- FASTMOSS and KALODATA to the allow-list. The guard still rejects any other (AI/web/
-- unknown) provider, so Product Asset Lock provenance is preserved, not weakened. No gallery
-- behaviour, contract, table, or rights change — the gallery composer already serves these
-- correctly; only the self-test's provider allow-list is corrected.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_gallery_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_owner uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_nl uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_hu uuid := 'cda3f71a-9947-4344-8664-13735740575f';
  v_ca uuid := (SELECT id FROM public.commerce_products WHERE user_id=v_owner AND title='cool air humidifier' LIMIT 1);
  g_hu jsonb; g_gb jsonb; g_de jsonb; g_ca jsonb;
BEGIN
  g_hu := public.fn_resolve_product_gallery(v_hu,5);
  g_gb := public.fn_resolve_product_gallery(v_nl,5);
  g_de := public.fn_resolve_product_gallery(v_nl,5);
  g_ca := public.fn_resolve_product_gallery(v_ca,5);

  v := v || jsonb_build_object('case','gallery_identity_equals_card_identity','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND (g->>'gallery_source_item_id') IS DISTINCT FROM (
                 SELECT a.source_entity_id FROM public.product_image_assets a
                 WHERE a.product_id=cp.id AND a.image_url=(public.fn_resolve_product_image(cp.id,'GB')->>'image_url')
                 LIMIT 1)));
  v := v || jsonb_build_object('case','hero_image_in_gallery','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(g->'images') im
                            WHERE im->>'image_url' = (public.fn_resolve_product_image(cp.id,'GB')->>'image_url'))));
  v := v || jsonb_build_object('case','card_equals_gallery_field','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
                    WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
                      AND (g->>'card_source_item_id') IS DISTINCT FROM (g->>'gallery_source_item_id')));
  v := v || jsonb_build_object('case','single_identity_per_gallery','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND (SELECT count(DISTINCT a.source_entity_id)
                 FROM jsonb_array_elements(g->'images') im
                 JOIN public.product_image_assets a
                   ON a.product_id=cp.id AND a.image_url = im->>'image_url') <> 1));
  v := v || jsonb_build_object('case','gallery_identity_matches_images','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
               jsonb_array_elements(g->'images') im
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND im->>'source_item_id' IS DISTINCT FROM g->>'gallery_source_item_id'));
  v := v || jsonb_build_object('case','images_trace_to_identity','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
               jsonb_array_elements(g->'images') im
          WHERE cp.user_id=v_owner
            AND NOT EXISTS (SELECT 1 FROM public.product_image_assets a
                            WHERE a.product_id=cp.id AND a.image_url=im->>'image_url'
                              AND a.source_entity_id=g->>'gallery_source_item_id')));
  v := v || jsonb_build_object('case','max_5_images','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
                    WHERE cp.user_id=v_owner AND (g->>'count')::int > 5));
  v := v || jsonb_build_object('case','no_duplicate_urls','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
                      jsonb_array_elements(g->'images') im
                    WHERE cp.user_id=v_owner GROUP BY cp.id, im->>'image_url' HAVING count(*) > 1));
  v := v || jsonb_build_object('case','exactly_one_primary','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
                    WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
                      AND (SELECT count(*) FROM jsonb_array_elements(g->'images') im WHERE (im->>'is_primary')::boolean) <> 1));
  v := v || jsonb_build_object('case','no_cross_product_leakage','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
                      jsonb_array_elements(g->'images') im
                    WHERE cp.user_id=v_owner
                      AND NOT EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.product_id=cp.id AND a.image_url=im->>'image_url')));
  v := v || jsonb_build_object('case','gb_de_same_gallery','pass', (g_gb->'images' = g_de->'images'));
  v := v || jsonb_build_object('case','deterministic_order','pass', (g_hu->'images' = public.fn_resolve_product_gallery(v_hu,5)->'images'));
  v := v || jsonb_build_object('case','gallery_state_truthful','pass',
        (g_ca->>'gallery_state' IN ('PENDING_RESEARCH','UNAVAILABLE_NO_SOURCE') AND (g_ca->>'count')::int=0));
  v := v || jsonb_build_object('case','pending_no_fabrication','pass', jsonb_array_length(g_ca->'images')=0);
  v := v || jsonb_build_object('case','no_ai_or_web_sources','pass',
        NOT EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.source_provider NOT IN ('CJ_SUPPLIER','EBAY_BROWSE','FASTMOSS','KALODATA')));

  RETURN jsonb_build_object('suite','product_gallery',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

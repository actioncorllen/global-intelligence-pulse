-- mig_298_kalodata_product_detail_capability.sql
-- STRATELOQ — Kalodata Product Detail capability (newly verified entitled).
--
-- Capability test (Hit the Slab, kalodata_product_id 1729945300622678813, DE) returned HTTP 200 +
-- success:true from POST https://www.kalodata.com/openapi/v1/tiktok/product/detail using the EXISTING
-- KALODATA_SECRET_KEY (secret-key header, broker-only). The endpoint is an ANALYTICS/commerce detail
-- (revenue split, sales, price range, shop id, numeric category ids, launch date, review count,
-- delivery type) — NOT a product-catalog detail: product_description is an (often empty) array, and
-- there are no structured attributes, variant/SKU arrays, or category names. For "Hit the Slab" the
-- description is empty and master_image_url is null, so it does not resolve concrete identity.
--
-- This migration adds the SMALLEST durable persistence for the newly-entitled detail, reusing existing
-- architecture. It stores the source-native detail fields under extended.kalodata_detail with
-- provenance (provider, kalodata_product_id, market, retrieved_at), persists master_image_url as a
-- REFERENCE_ONLY image ONLY when genuinely present (never promoted to authoritative supplier assets),
-- and captures product_description when the provider returns one. Identity derivation is UNCHANGED:
-- the persisted detail contributes descriptive identity only through a non-empty product_description,
-- and numeric category ids / analytics are stored as provenance context, never as distinguishing
-- identity attributes (category is not a specific identity). Tenant-scoped by user_id; fail closed.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_persist_kalodata_product_detail(
  p_tenant uuid, p_product uuid, p_market text, p_detail jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_kid text := nullif(btrim(coalesce(p_detail->>'product_id','')),'');
  v_img text := nullif(btrim(coalesce(p_detail->>'master_image_url','')),'');
  v_desc_present boolean := false;
  v_owns boolean;
BEGIN
  IF p_tenant IS NULL OR p_product IS NULL OR p_detail IS NULL OR jsonb_typeof(p_detail) <> 'object' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args');
  END IF;
  -- Tenant isolation: only the owner's product is touched.
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product AND user_id=p_tenant) INTO v_owns;
  IF NOT v_owns THEN RETURN jsonb_build_object('ok',false,'reason','not_owned'); END IF;

  -- product_description present only when a non-empty array or non-empty string.
  v_desc_present := CASE
    WHEN jsonb_typeof(p_detail->'product_description')='array' THEN jsonb_array_length(p_detail->'product_description') > 0
    WHEN jsonb_typeof(p_detail->'product_description')='string' THEN length(btrim(p_detail->>'product_description')) > 0
    ELSE false END;

  -- Persist source-native detail with provenance (idempotent overwrite of the detail block).
  UPDATE public.commerce_products
     SET extended = coalesce(extended,'{}'::jsonb) || jsonb_build_object(
           'kalodata_detail', p_detail || jsonb_build_object(
             'provenance', jsonb_build_object(
               'provider','KALODATA','authority','PLATFORM_REPORTED_ANALYTICS_DETAIL',
               'kalodata_product_id', coalesce(v_kid, extended->>'kalodata_product_id'),
               'market', v_mkt, 'retrieved_at', now(),
               'endpoint','https://www.kalodata.com/openapi/v1/tiktok/product/detail',
               'note','analytics/commerce detail; not a product-catalog description; REFERENCE_ONLY'))),
         updated_at = now()
   WHERE id=p_product AND user_id=p_tenant;

  -- Only persist a genuine product image (none for this product). REFERENCE_ONLY; never supplier-authoritative.
  IF v_img IS NOT NULL AND v_img ~* '^https?://' AND v_img NOT ILIKE '%/default/%' THEN
    PERFORM public.fn_persist_reference_image(p_tenant, p_product, v_mkt, 'KALODATA', v_kid, v_img);
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'product_id', p_product, 'market', v_mkt,
    'kalodata_product_id', v_kid,
    'description_present', v_desc_present,
    'image_present', (v_img IS NOT NULL AND v_img ~* '^https?://' AND v_img NOT ILIKE '%/default/%'),
    'attributes_present', (p_detail ? 'attributes' AND jsonb_typeof(p_detail->'attributes')='array' AND jsonb_array_length(p_detail->'attributes')>0),
    'variants_present', (p_detail ? 'variants' AND jsonb_typeof(p_detail->'variants')='array' AND jsonb_array_length(p_detail->'variants')>0),
    'category_ids', jsonb_build_object('l1', p_detail->>'pri_cate_id','l2', p_detail->>'sec_cate_id','l3', p_detail->>'ter_cate_id'),
    'authority','REFERENCE_ONLY',
    'contract','pulse_kalodata_product_detail_persist_v1');
END $function$;

-- Least privilege: service_role only (invoked by the trusted pipeline / broker path), never anon/public.
-- This function is SECURITY DEFINER and authorizes on the supplied p_tenant, so it MUST NOT be callable
-- by customer/browser roles.
REVOKE EXECUTE ON FUNCTION public.fn_persist_kalodata_product_detail(uuid,uuid,text,jsonb) FROM PUBLIC, anon, authenticated;

-- Persist the capability-test detail for the target product (Hit the Slab, DE). Idempotent: re-running
-- overwrites the extended.kalodata_detail block. The Kalodata Product Detail endpoint returned an
-- analytics/commerce detail with an EMPTY product_description and null master_image_url, so this does
-- NOT resolve concrete identity (Hit the Slab stays NO_CONCRETE_EVIDENCE / INSUFFICIENT).
SELECT public.fn_persist_kalodata_product_detail(
  '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
  'ca4a79b0-41a7-4fc6-b267-82b99a123dff'::uuid,
  'DE',
  '{"product_id":"1729945300622678813","product_region":"de","product_name":"Hit the Slab","product_shop_id":"7496208851430837021","pri_cate_id":"951432","sec_cate_id":"810000","ter_cate_id":"823952","max_price":79.99,"min_price":79.99,"revenue":21587.46,"video_revenue":0,"live_revenue":21587.46,"sales_volumn":269,"creator_number":1,"video_number":0,"live_number":6,"delivery_type":"unknown","shopping_mall_revenue":0,"commission_rate":0,"unit_price":80.25,"product_review_count":0,"launch_date":"2026-10-05","master_image_url":null,"revenue_trend":null,"product_description":[]}'::jsonb);

COMMIT;

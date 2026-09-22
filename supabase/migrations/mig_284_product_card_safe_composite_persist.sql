-- ============================================================================
-- mig_284_product_card_safe_composite_persist.sql
-- STRATELOQ-015L — persist an identity-safe REAL_PRODUCT_LAYER_COMPOSITE creative.
-- The advertised product pixels come from the authoritative Product Card asset
-- (scaled/positioned only — never regenerated). Composited server-side (n8n Edit
-- Image / ImageMagick) onto a deterministic canvas with deterministic headline/CTA.
-- Governed by mig_283 (PRODUCT_CARD_ASSET_IS_AUTHORITATIVE) + the LOCKED standard.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_media_complete_composite_real(
  p_tenant uuid, p_product_id uuid, p_country_code text,
  p_storage_ref text, p_width integer, p_height integer,
  p_source_asset_refs jsonb, p_product_layer_source_asset_id uuid,
  p_transformations jsonb, p_headline text, p_cta text,
  p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_owner uuid; v_asset uuid; v_prov jsonb; v_src jsonb; v_pres jsonb;
BEGIN
  IF p_tenant IS NULL OR p_product_id IS NULL THEN RETURN jsonb_build_object('status','tenant_and_product_required'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL OR v_owner <> p_tenant THEN RETURN jsonb_build_object('status','product_not_owned_by_tenant'); END IF;

  v_prov := coalesce(p_provenance,'{}'::jsonb) || jsonb_build_object(
    'composited', true, 'renderer','STRATELOQ_CREATIVE_STUDIO',
    'compositor','n8n Edit Image / ImageMagick (server-side; binary stayed in n8n)',
    'generation_mode','REAL_PRODUCT_LAYER_COMPOSITE',
    'product_layer_source', jsonb_build_object(
       'product_image_asset_id', p_product_layer_source_asset_id::text,
       'note','advertised product pixels originate from the authoritative Product Card asset; scaled/positioned only, never regenerated'),
    'transformations', coalesce(p_transformations,'[]'::jsonb),
    'text_elements', jsonb_build_object('headline', p_headline, 'cta', p_cta,
       'source','deterministic composition (never generated inside an image model)'),
    'delivery_format', jsonb_build_object('width',p_width,'height',p_height,'platform','META','placement','INSTAGRAM_FEED / META_FEED'));

  INSERT INTO public.media_assets(tenant_id, product_id, media_type, source_type, provider, provider_job_id,
    rights_state, generation_status, approval_state, mime_type, width, height, aspect_ratio, storage_ref,
    spec_ref, provenance, is_launch_safe, country_code, generation_mode, usage_permission, cost_amount,
    cost_currency, source_asset_refs, lineage_state, identity_state)
  VALUES (p_tenant, p_product_id, 'IMAGE', 'PULSE_COMPOSED_IMAGE', 'STRATELOQ_CREATIVE_STUDIO', NULL,
    'PRODUCT_CARD_AUTHORITATIVE', 'COMPOSED', 'IN_REVIEW', 'image/png', p_width, p_height, '4:5', p_storage_ref,
    jsonb_build_object('headline', p_headline, 'cta', p_cta), v_prov, false, p_country_code,
    'REAL_PRODUCT_LAYER_COMPOSITE', 'INTERNAL_ADVERTISING_TEST', 0, 'USD',
    coalesce(p_source_asset_refs,'[]'::jsonb), 'CANONICAL', 'IDENTITY_REVIEW_REQUIRED')
  RETURNING id INTO v_asset;

  v_src := public.fn_media_product_card_source_verified(v_asset);
  v_pres := public.fn_media_product_identity_preserved(v_asset);

  RETURN jsonb_build_object('status','COMPOSED_REAL','asset_id',v_asset,'lineage_state','CANONICAL',
    'identity_state','IDENTITY_REVIEW_REQUIRED','approval_state','IN_REVIEW','is_launch_safe',false,
    'PRODUCT_CARD_SOURCE_VERIFIED', v_src->>'state', 'PRODUCT_IDENTITY_PRESERVED', v_pres->>'state',
    'cost_amount',0,'note','Identity-safe composite persisted. Product pixels authoritative; human review still required before launch.');
END; $fn$;

-- selftest: a REAL_PRODUCT_LAYER_COMPOSITE whose source is the Product Card asset
-- PASSes both identity gates; a redraw does not. Self-cleaning ([[pcc]] fixture asset).
CREATE OR REPLACE FUNCTION public.fn_media_composite_identity_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid;
  v_prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba'::uuid;
  v_card uuid := '7c2f476f-acbe-499b-a015-2422e56daa50'::uuid;
  v_url text; v_res jsonb; v_asset uuid; v_pass int:=0; v_fail int:=0; v_checks jsonb:='[]'::jsonb;
BEGIN
  SELECT image_url INTO v_url FROM public.product_image_assets WHERE id=v_card;
  DELETE FROM public.media_assets WHERE tenant_id=v_tenant AND storage_ref LIKE '%[[pcc]]%';

  v_res := public.fn_media_complete_composite_real(v_tenant, v_prod, 'GB',
    'creatives/[[pcc]]/selftest.png', 1080, 1350,
    jsonb_build_array(jsonb_build_object('product_image_asset_id', v_card::text, 'url', v_url,
      'provider','CJ_SUPPLIER','item','2608250310481611400')),
    v_card, jsonb_build_array('download','resize_scale','composite_canvas','deterministic_text'),
    'Selftest headline','Learn more', '{}'::jsonb);
  v_asset := nullif(v_res->>'asset_id','')::uuid;

  IF (v_res->>'PRODUCT_CARD_SOURCE_VERIFIED')='PASS' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('source_verified',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('source_verified',false,'got',v_res->>'PRODUCT_CARD_SOURCE_VERIFIED'); END IF;

  IF (v_res->>'PRODUCT_IDENTITY_PRESERVED')='PASS' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('identity_preserved',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('identity_preserved',false,'got',v_res->>'PRODUCT_IDENTITY_PRESERVED'); END IF;

  -- still not launch-safe (identity human review required)
  IF (public.fn_media_launch_eligibility(v_asset)->>'eligible')='false'
     AND (public.fn_media_launch_eligibility(v_asset)->>'reason')='IDENTITY_REVIEW_REQUIRED' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('not_launch_safe_pending_human_identity_review',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('not_launch_safe_pending_human_identity_review',false); END IF;

  DELETE FROM public.media_assets WHERE id=v_asset;
  DELETE FROM public.media_assets WHERE tenant_id=v_tenant AND storage_ref LIKE '%[[pcc]]%';

  RETURN jsonb_build_object('suite','media_product_card_composite_identity','pass',v_pass,'fail',v_fail,
    'all_pass',(v_fail=0),'checks',v_checks);
END; $fn$;

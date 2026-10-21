-- mig_325_supplier_reference_video_ingest.sql
-- Stage 4B: supplier / reference VIDEO ingestion, reusing the existing media architecture
-- (media_assets + fn_product_media_state card read + Product Asset Lock). No new media architecture.
--
-- Context / findings (see docs/PULSE-ECOM-STAGE4B-SUPPLIER-VIDEO-001.md):
--   * CJ authorised product/query for pid 2609290358281623700 returns productVideo = null, has NO
--     variant-level video and NO nested media/video array (only image + fabric-material fields). So CJ
--     exposes no video for this product -> VIDEO_NOT_EXPOSED_BY_PROVIDER. The prior "zero videos" was
--     correct, not a parsing miss.
--   * The founder-supplied 10.7s video is INDEPENDENT reference evidence; its source/rights are not
--     established and it must never be treated as supplier-owned or launch-safe.
--
-- Existing path already present: fn_persist_reference_video is FastMoss-discovery-specific (provider
-- hardcoded FASTMOSS, expects tiktok_url/fastmoss_url + video_id). These two helpers generalise video
-- ingestion through the SAME media_assets store with honest provenance + rights, idempotent.
--
-- NOTE: authored while the Supabase MCP write path was unavailable; apply via the authorised route
-- (Supabase Dashboard SQL Editor / CLI). See supabase/manual/mig_325_dashboard_apply.sql.

-- =====================================================================================================
-- 1. GENERIC INDEPENDENTLY-SUPPLIED REFERENCE VIDEO (e.g. founder-supplied clip)
--    Stored REFERENCE_ONLY; source is RECORDED, never assumed supplier-owned; never launch-safe.
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_ingest_reference_video(
  p_tenant uuid, p_product uuid, p_market text, p_url text,
  p_source_label text DEFAULT 'FOUNDER_SUPPLIED', p_duration numeric DEFAULT NULL,
  p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_id uuid; v_owns boolean; v_src text := upper(nullif(btrim(coalesce(p_source_label,'')),''));
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
BEGIN
  IF p_tenant IS NULL OR p_product IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','tenant_and_product_required'); END IF;
  IF p_url IS NULL OR p_url !~* '^https?://' THEN
    RETURN jsonb_build_object('ok',false,'error','invalid_or_missing_https_url'); END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product AND user_id=p_tenant) INTO v_owns;
  IF NOT v_owns THEN RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant'); END IF;

  SELECT id INTO v_id FROM public.media_assets
   WHERE tenant_id=p_tenant AND product_id=p_product
     AND source_type='INDEPENDENT_REFERENCE_VIDEO' AND storage_ref=p_url LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok',true,'media_asset_id',v_id,'status','already_present',
      'rights_state','REFERENCE_UNVERIFIED','usage_permission','REFERENCE_ONLY'); END IF;

  INSERT INTO public.media_assets
    (tenant_id, product_id, media_type, source_type, provider, rights_state, generation_status,
     approval_state, duration, storage_ref, provenance, is_launch_safe, country_code, usage_permission, lineage_state)
  VALUES (
     p_tenant, p_product, 'VIDEO', 'INDEPENDENT_REFERENCE_VIDEO', coalesce(v_src,'UNSPECIFIED'),
     'REFERENCE_UNVERIFIED', 'EXTERNAL_REFERENCE', 'DRAFT', p_duration, p_url,
     jsonb_strip_nulls(jsonb_build_object(
       'authority','REFERENCE_ONLY','source_label',coalesce(v_src,'UNSPECIFIED'),
       'rights_basis','UNVERIFIED','market',v_mkt,'observed_at',now(),
       'note','Independently supplied reference video. Source and usage rights NOT established; NOT supplier-authoritative; shows the product but ownership is unproven; never unlocks store/ad/creative/publishing until rights are verified.')
       || coalesce(p_provenance,'{}'::jsonb)),
     false, v_mkt, 'REFERENCE_ONLY', 'UNRESOLVED')
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok',true,'media_asset_id',v_id,'status','ingested',
    'media_type','VIDEO','rights_state','REFERENCE_UNVERIFIED','usage_permission','REFERENCE_ONLY',
    'is_launch_safe',false,'source_label',coalesce(v_src,'UNSPECIFIED'));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ingest_reference_video(uuid,uuid,text,text,text,numeric,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ingest_reference_video(uuid,uuid,text,text,text,numeric,jsonb) TO service_role;

-- =====================================================================================================
-- 2. CJ SUPPLIER CATALOG VIDEO (only when CJ product/query productVideo is non-null; future-ready)
--    Supplier-provided catalog video; advertising rights NOT auto-granted -> usage REFERENCE_ONLY,
--    not launch-safe, until commercial media rights are confirmed.
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_ingest_cj_product_video(
  p_tenant uuid, p_product uuid, p_market text, p_cj_pid text, p_url text, p_duration numeric DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_id uuid; v_owns boolean; v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
BEGIN
  IF p_tenant IS NULL OR p_product IS NULL THEN RETURN jsonb_build_object('ok',false,'error','tenant_and_product_required'); END IF;
  IF p_url IS NULL OR p_url !~* '^https?://' THEN RETURN jsonb_build_object('ok',false,'error','invalid_or_missing_https_url'); END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product AND user_id=p_tenant) INTO v_owns;
  IF NOT v_owns THEN RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant'); END IF;

  SELECT id INTO v_id FROM public.media_assets
   WHERE tenant_id=p_tenant AND product_id=p_product
     AND source_type='SUPPLIER_CATALOG_VIDEO' AND storage_ref=p_url LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN jsonb_build_object('ok',true,'media_asset_id',v_id,'status','already_present'); END IF;

  INSERT INTO public.media_assets
    (tenant_id, product_id, media_type, source_type, provider, rights_state, generation_status,
     approval_state, duration, storage_ref, provenance, is_launch_safe, country_code, usage_permission, lineage_state)
  VALUES (
     p_tenant, p_product, 'VIDEO', 'SUPPLIER_CATALOG_VIDEO', 'CJDROPSHIPPING',
     'SUPPLIER_PROVIDED', 'EXTERNAL_REFERENCE', 'DRAFT', p_duration, p_url,
     jsonb_build_object('authority','SUPPLIER_PROVIDED','provider','CJDROPSHIPPING','cj_pid',p_cj_pid,
       'market',v_mkt,'observed_at',now(),
       'note','CJ catalog product video (productVideo). Supplier-provided; advertising/commercial media rights NOT confirmed; REFERENCE_ONLY and not launch-safe until approved.'),
     false, v_mkt, 'REFERENCE_ONLY', 'UNRESOLVED')
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok',true,'media_asset_id',v_id,'status','ingested','media_type','VIDEO',
    'rights_state','SUPPLIER_PROVIDED','usage_permission','REFERENCE_ONLY','is_launch_safe',false);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ingest_cj_product_video(uuid,uuid,text,text,text,numeric) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ingest_cj_product_video(uuid,uuid,text,text,text,numeric) TO service_role;

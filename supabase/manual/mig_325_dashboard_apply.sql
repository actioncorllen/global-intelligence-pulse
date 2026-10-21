-- =====================================================================================================
-- mig_325 — DASHBOARD SQL EDITOR APPLY (manual; MCP write path unavailable)
-- Generated from supabase/migrations/mig_325_supplier_reference_video_ingest.sql (identical bodies).
-- Paste ALL of this into Supabase Dashboard -> SQL Editor -> Run. One transaction: any failure rolls back.
-- Reuses the existing media_assets store + fn_product_media_state card read; adds NO new media architecture.
-- Idempotent; safe to re-run. Changes no existing rows (only defines two ingest functions).
-- =====================================================================================================

BEGIN;

DO $pre$
BEGIN
  IF to_regclass('public.media_assets') IS NULL
     OR to_regprocedure('public.fn_product_media_state(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'PRECHECK FAILED: media_assets / fn_product_media_state missing; nothing changed.';
  END IF;
  RAISE NOTICE 'PRECHECK OK: media architecture present.';
END $pre$;

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

DO $post$
BEGIN
  IF to_regprocedure('public.fn_ingest_reference_video(uuid,uuid,text,text,text,numeric,jsonb)') IS NULL
     OR to_regprocedure('public.fn_ingest_cj_product_video(uuid,uuid,text,text,text,numeric)') IS NULL THEN
    RAISE EXCEPTION 'POSTCHECK FAILED: ingest functions not created; transaction will roll back.';
  END IF;
  RAISE NOTICE 'POSTCHECK OK: fn_ingest_reference_video + fn_ingest_cj_product_video created.';
END $post$;

COMMIT;

-- =====================================================================================================
-- AFTER COMMIT — to ingest the founder's 10.7s video (run once the URL is known), REFERENCE_ONLY:
--   SELECT public.fn_ingest_reference_video(
--     '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,          -- tenant
--     '56a6af36-68f7-4138-9d29-941245f266b2'::uuid,          -- FastMoss ski-mask product
--     'GB',
--     'https://REPLACE_WITH_REAL_HTTPS_URL/old-man-ski-mask.mp4',
--     'FOUNDER_SUPPLIED',                                    -- declared source (NOT assumed supplier-owned)
--     10.7,                                                  -- duration seconds
--     '{"rights_basis":"pending_founder_confirmation"}'::jsonb);
--   -- expect {"ok":true,"status":"ingested","usage_permission":"REFERENCE_ONLY","is_launch_safe":false,...}
--
-- Then confirm the signed-in card surfaces it (runs as the signed-in owner, not the SQL editor):
--   SELECT public.fn_product_media_state(
--     '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,'56a6af36-68f7-4138-9d29-941245f266b2'::uuid,'GB');
--   -- expect video_state VIDEO_AVAILABLE, video_count >= 1, videos[] carrying the REFERENCE_ONLY clip.
--
-- Invalid-URL / isolation tests (expected to REJECT):
--   SELECT public.fn_ingest_reference_video('7c8ddf9d-…'::uuid,'56a6af36-…'::uuid,'GB','not-a-url');      -- ok:false invalid_or_missing_https_url
--   SELECT public.fn_ingest_reference_video('00000000-0000-0000-0000-000000000000'::uuid,'56a6af36-…'::uuid,'GB','https://x/y.mp4'); -- ok:false product_not_found_for_tenant
-- =====================================================================================================

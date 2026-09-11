-- =====================================================================================
-- PULSE-ECOM-CJ-LIVE-DETAIL-RECOVERY-001 — defect fix (repo mirror of mig_218)
-- Applied to Supabase project nxaunmyihhjixxxljcqt.
--
-- CONTEXT: recovering the CJ live product-detail capability, a real product/query response
-- with a genuine productImageSet gallery array was fed through fn_ingest_supplier_product_assets
-- (mig_209) for the first time. That exposed a LATENT defect: the GALLERY loop declared the
-- loop variable as `g jsonb` while jsonb_array_elements_text() yields text; assigning a bare
-- URL string to a jsonb variable forced a text->jsonb cast that fails with
-- "invalid input syntax for type json: Token \"https\" is invalid". It never triggered before
-- because earlier products had no gallery array (the loop was skipped and gallery recorded as
-- honestly UNAVAILABLE). Fix: iterate the gallery as text and store the URL directly.
--
-- Verified after fix (real CJ pid 2609070153091625100 "High-end Accessory Jewelry Box"):
--   PRIMARY_IMAGE AVAILABLE (SUPPLIER_OWN, SUPPLIER_PROVIDED) + 2 GALLERY_IMAGE AVAILABLE
--   + VARIANT_IMAGE honestly UNAVAILABLE (requires detail fetch) + no VIDEO (none present).
--   Flags: PRODUCT_HAS_IMAGE / IMAGE_RESOLVED_BY_PULSE / IMAGE_RENDERABLE_IN_PULSE /
--          IMAGE_RENDER_BLOCKED_ONLY_IN_CLAUDE = all true. No other change to the contract.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.fn_ingest_supplier_product_assets(p_supplier_row uuid, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  r record; prov text; spid text; primary_url text; gallery jsonb; gcount int := 0;
  vid text; has_video boolean; obs timestamptz; g text; inserted int := 0;   -- g is text (was jsonb: the bug)
  product_has_image boolean; resolved boolean; renderable boolean;
BEGIN
  SELECT * INTO r FROM public.commerce_supplier_products WHERE id=p_supplier_row;
  IF r.id IS NULL THEN RETURN jsonb_build_object('error','SUPPLIER_ROW_NOT_FOUND'); END IF;
  prov := upper(coalesce(r.source,'UNKNOWN'));
  spid := coalesce(r.source_product_id, r.raw->>'pid', r.id::text);
  primary_url := coalesce(nullif(r.image_url,''), r.raw->>'productImage');
  gallery := CASE WHEN jsonb_typeof(r.raw->'productImageSet')='array' THEN r.raw->'productImageSet' ELSE NULL END;
  vid := coalesce(r.supplier_enrichment->'variant'->>'vid', NULL);
  has_video := coalesce((r.raw->>'isVideo')::boolean, false);
  obs := coalesce(r.enrichment_observed_at, r.last_seen_at, r.updated_at, now());

  IF p_persist THEN
    DELETE FROM public.supplier_product_assets WHERE supplier=prov AND supplier_product_id=spid;

    IF primary_url IS NOT NULL THEN
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,asset_identity,
        rights_state,availability,source_url,original_source,is_primary,cache_state,observed_at,provenance)
      VALUES (prov,spid,r.title,'PRIMARY_IMAGE','SUPPLIER_OWN',
        CASE WHEN prov='CJDROPSHIPPING' THEN 'SUPPLIER_PROVIDED' ELSE 'UNKNOWN' END,'AVAILABLE',primary_url,
        r.source,true,'ORIGIN_HOTLINK',obs,
        jsonb_build_object('supplier_product_id',spid,'field','productImage','note','supplier-owned primary image; production caches to Pulse object storage'));
      inserted := inserted+1;
    ELSE
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,availability,unavailable_reason,original_source,observed_at)
      VALUES (prov,spid,r.title,'IMAGE_UNAVAILABLE','UNAVAILABLE','NO_PRIMARY_IMAGE_IN_SUPPLIER_FEED',r.source,obs);
    END IF;

    -- GALLERY (where the supplier exposes it; else honest unavailable)
    IF gallery IS NOT NULL THEN
      FOR g IN SELECT * FROM jsonb_array_elements_text(gallery) LOOP
        INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,asset_identity,rights_state,availability,source_url,original_source,observed_at,provenance)
        VALUES (prov,spid,r.title,'GALLERY_IMAGE','SUPPLIER_OWN',CASE WHEN prov='CJDROPSHIPPING' THEN 'SUPPLIER_PROVIDED' ELSE 'UNKNOWN' END,'AVAILABLE',g,r.source,obs,jsonb_build_object('field','productImageSet'));
        gcount := gcount+1;
      END LOOP;
    ELSE
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,availability,unavailable_reason,original_source,observed_at)
      VALUES (prov,spid,r.title,'GALLERY_IMAGE','UNAVAILABLE','GALLERY_NOT_IN_SOURCE_CACHE_REQUIRES_SUPPLIER_DETAIL_FETCH',r.source,obs);
    END IF;

    IF vid IS NOT NULL THEN
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,supplier_variant_id,product_title,asset_type,availability,unavailable_reason,original_source,observed_at,provenance)
      VALUES (prov,spid,vid,r.title,'VARIANT_IMAGE','UNAVAILABLE','VARIANT_IMAGE_NOT_IN_SOURCE_CACHE_REQUIRES_SUPPLIER_DETAIL_FETCH',r.source,obs,
        jsonb_build_object('variant', r.supplier_enrichment->'variant'));
    END IF;

    IF has_video THEN
      INSERT INTO public.supplier_product_assets (supplier,supplier_product_id,product_title,asset_type,availability,unavailable_reason,original_source,observed_at)
      VALUES (prov,spid,r.title,'VIDEO','UNAVAILABLE','VIDEO_FLAGGED_BUT_URL_NOT_IN_SOURCE_CACHE',r.source,obs);
    END IF;
  END IF;

  product_has_image := (primary_url IS NOT NULL);
  resolved := product_has_image;
  renderable := product_has_image;
  RETURN jsonb_build_object(
    'supplier',prov,'supplier_product_id',spid,'title',r.title,
    'primary_image', primary_url, 'gallery_count', gcount, 'variant_id', vid, 'video_flagged', has_video,
    'assets_written', inserted,
    'flags', jsonb_build_object(
      'PRODUCT_HAS_IMAGE', product_has_image,
      'IMAGE_RESOLVED_BY_PULSE', resolved,
      'IMAGE_RENDERABLE_IN_PULSE', renderable,
      'IMAGE_RENDER_BLOCKED_ONLY_IN_CLAUDE', (product_has_image AND prov='CJDROPSHIPPING')),
    'note','SOURCE product assets only; separate from generated creative and competitor reference. Original supplier URL + rights preserved for Pulse object-storage caching.',
    'contract','pulse_supplier_product_asset_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ingest_supplier_product_assets(uuid,boolean) FROM PUBLIC, anon;

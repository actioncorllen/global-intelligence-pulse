-- mig_327_candidate_variants_and_media_rights.sql
-- Stage 4B: COMPLETE supplier media display — backend data the Product Intelligence Card needs.
--
-- Two additive, backward-compatible CREATE OR REPLACEs (no data change; no behaviour change to auth,
-- tenant isolation, country scoping, rights or the Asset Lock):
--
-- 1. fn_product_supplier_candidate — now also returns:
--      * variants[]  — ALL supplier (CJ) variants with their class, families, price, per-variant IMAGE
--        (joined from supplier_enrichment.variant_catalog) and corresponds_to_concept flag. The eight
--        Old-Man-Face variants are corresponds_to_concept=true; EVERY variant carries
--        exact_variant_verified=false and advertising_cleared=false, so the card can show the 8 clearly
--        marked as NOT exact-SKU verified, with correct image associations.
--      * media.gallery_images — the full de-duplicated supplier gallery (reference-only), plus the
--        existing sample_images and image_count.
--    Identity tier/confidence/economics/missing_evidence are unchanged (still SAME_PRODUCT_IDENTITY /
--    MEDIUM / exact_variant_verified=false). Reference-only; advertising_cleared stays false.
--
-- 2. fn_product_media_state — primary_video and videos[] now also carry per-asset copyright +
--    commercial-use status (copyright, is_free, commercial_use='NOT_CLEARED_REFERENCE_ONLY') on top of
--    the mig_326 self-hosted playback handles. The video lane only ever contains is_launch_safe=false
--    reference media, so commercial_use is never "cleared" here. Everything else is byte-for-byte mig_326.
--
-- NOTE: deployed via the authorised route (MCP write path recovered this session; also safe to run in the
-- Supabase Dashboard SQL Editor). Idempotent (CREATE OR REPLACE). See supabase/manual/mig_327_dashboard_apply.sql.

-- =====================================================================================================
-- 1. CANDIDATE READ — add variants[] (with per-variant image) + full gallery
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_product_supplier_candidate(p_tenant uuid, p_product uuid, p_market text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_owns boolean; x record;
  v_catalog jsonb; v_gallery jsonb; v_variants jsonb;
BEGIN
  IF v_uid IS NULL OR p_product IS NULL THEN
    RETURN jsonb_build_object('present', false, 'status', 'unauthorized');
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product AND user_id=v_uid) INTO v_owns;
  IF NOT v_owns THEN
    RETURN jsonb_build_object('present', false, 'status', 'unauthorized');
  END IF;
  SELECT * INTO x FROM public.commerce_cross_supplier_identity
    WHERE tenant_id=v_uid AND opportunity_product_id=p_product AND market=upper(coalesce(p_market,''))
    ORDER BY CASE identity_tier WHEN 'EXACT_VARIANT_VERIFIED' THEN 0 WHEN 'SAME_PRODUCT_IDENTITY' THEN 1
             WHEN 'SIMILAR_ONLY' THEN 2 ELSE 3 END, updated_at DESC
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('present', false, 'status', 'no_candidate');
  END IF;

  -- supplier gallery + per-variant catalog (reference-only; tenant already authorised above)
  SELECT supplier_enrichment->'variant_catalog', supplier_enrichment->'images'
    INTO v_catalog, v_gallery
  FROM public.commerce_supplier_products
  WHERE source = x.source AND source_product_id = x.supplier_product_id
  LIMIT 1;

  SELECT coalesce(jsonb_agg(
           jsonb_build_object(
             'key', vc->>'key',
             'sku', vc->>'sku',
             'vid', vc->>'vid',
             'class', vc->>'class',
             'families', coalesce(vc->'families','[]'::jsonb),
             'corresponds_to_concept', coalesce((vc->>'corresponds_to_concept')::boolean, false),
             'price_usd', nullif(vc->>'price_usd','')::numeric,
             'image', (SELECT e->>'image' FROM jsonb_array_elements(coalesce(v_catalog,'[]'::jsonb)) e
                        WHERE e->>'vid' = vc->>'vid' OR e->>'sku' = vc->>'sku' LIMIT 1),
             'exact_variant_verified', false,
             'rights_state', 'SUPPLIER_PROVIDED_REFERENCE_ONLY',
             'advertising_cleared', false
           )
           ORDER BY coalesce((vc->>'corresponds_to_concept')::boolean, false) DESC, vc->>'key')
         , '[]'::jsonb)
    INTO v_variants
  FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc;

  RETURN jsonb_build_object(
    'present', true, 'status', 'ok', 'source', x.source, 'supplier_product_id', x.supplier_product_id,
    'verification_tier', x.identity_tier, 'confidence', x.confidence,
    'product_level_match', x.bound, 'exact_variant_verified', x.variant_verified,
    'corresponding_variant_count', x.corresponding_variant_count, 'total_variant_count', x.total_variant_count,
    'display_label', CASE x.identity_tier
      WHEN 'SAME_PRODUCT_IDENTITY' THEN 'Same product (supplier) — '||x.confidence||' confidence; exact variant unverified'
      WHEN 'EXACT_VARIANT_VERIFIED' THEN 'Exact variant verified (supplier)'
      WHEN 'SIMILAR_ONLY' THEN 'Similar product only — not confirmed same'
      WHEN 'DIFFERENT_PRODUCT' THEN 'Different product'
      ELSE 'Unverified — insufficient evidence' END,
    'variants', v_variants,
    'variant_note', 'Supplier (CJ) variants at SAME_PRODUCT_IDENTITY; corresponds_to_concept marks the Old-Man-Face variants. None is exact-SKU verified; images are reference-only.',
    'media', jsonb_build_object(
      'image_count', coalesce((x.media->>'image_count')::int,0),
      'sample_images', coalesce(x.media->'sample_images','[]'::jsonb),
      'gallery_images', coalesce(v_gallery,'[]'::jsonb),
      'gallery_image_count', jsonb_array_length(coalesce(v_gallery,'[]'::jsonb)),
      'rights_state', coalesce(x.media->>'rights_state','SUPPLIER_PROVIDED_REFERENCE_ONLY'),
      'advertising_cleared', false,
      'commercial_use', 'NOT_CLEARED_REFERENCE_ONLY',
      'rights_note', coalesce(x.media->>'rights_note','Reference-only supplier media; not an authorised advertising asset.')),
    'displayed_variant_economics', x.economics,
    'missing_evidence', x.missing_evidence);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_product_supplier_candidate(uuid,uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_supplier_candidate(uuid,uuid,text) TO service_role, authenticated;

-- =====================================================================================================
-- 2. CARD MEDIA READ — add per-asset copyright + commercial-use to the video lane (on top of mig_326)
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_product_media_state(p_tenant uuid, p_product uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_primary record; v_gallery int; v_video record; v_is_fastmoss boolean; v_video_count int;
  v_image_state text; v_video_state text; v_supplier_state text; v_card text;
  v_bound boolean; v_supplier_assets int; v_owns boolean; v_videos jsonb;
  v_denied jsonb := jsonb_build_object(
    'status','unauthorized',
    'image_state','IMAGE_UNAVAILABLE','video_state','VIDEO_UNAVAILABLE',
    'supplier_media_state','SUPPLIER_MEDIA_PENDING','card_media_state','MEDIA_INCOMPLETE',
    'primary_image', NULL, 'gallery_count', 0, 'primary_video', NULL, 'video_count', 0,
    'videos', '[]'::jsonb,
    'authority','REFERENCE_ONLY',
    'contract','pulse_product_media_state_v1');
BEGIN
  IF v_uid IS NULL OR p_product IS NULL THEN
    RETURN v_denied;
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product AND user_id=v_uid) INTO v_owns;
  IF NOT v_owns THEN
    RETURN v_denied;
  END IF;

  SELECT image_url, source_provider, source_entity_id, observed_at, rights_state INTO v_primary
  FROM public.product_image_assets
  WHERE product_id=p_product AND tenant_id=v_uid AND (v_mkt IS NULL OR market IS NULL OR market=v_mkt)
  ORDER BY is_primary DESC, (lower(coalesce(image_url,'')) NOT LIKE '%/default/%') DESC, observed_at DESC NULLS LAST
  LIMIT 1;

  SELECT count(*) INTO v_gallery FROM public.product_image_assets
    WHERE product_id=p_product AND tenant_id=v_uid AND (v_mkt IS NULL OR market IS NULL OR market=v_mkt);

  v_image_state := CASE WHEN v_primary.image_url IS NOT NULL THEN 'IMAGE_AVAILABLE' ELSE 'IMAGE_UNAVAILABLE' END;

  SELECT id, media_type, storage_ref, provider, duration, spec_ref, provenance, rights_state, country_code,
         source_asset_refs
    INTO v_video
  FROM public.media_assets
  WHERE product_id=p_product AND tenant_id=v_uid AND upper(coalesce(media_type,''))='VIDEO'
    AND coalesce(is_launch_safe,false)=false
    AND (v_mkt IS NULL OR country_code IS NULL OR upper(country_code)=v_mkt)
  ORDER BY created_at DESC LIMIT 1;

  SELECT count(*) INTO v_video_count FROM public.media_assets
    WHERE product_id=p_product AND tenant_id=v_uid AND upper(coalesce(media_type,''))='VIDEO'
      AND coalesce(is_launch_safe,false)=false
      AND (v_mkt IS NULL OR country_code IS NULL OR upper(country_code)=v_mkt);

  SELECT coalesce(jsonb_agg(elem ORDER BY ord_play DESC NULLS LAST, ord_created DESC), '[]'::jsonb)
    INTO v_videos
  FROM (
    SELECT
      jsonb_strip_nulls(jsonb_build_object(
        'video_id', ma.provenance->>'source_entity_id',
        'media_asset_id', ma.id,
        'tiktok_url', ma.spec_ref->>'tiktok_url',
        'fastmoss_url', ma.spec_ref->>'fastmoss_url',
        'cover', ma.spec_ref->>'cover',
        'url', CASE WHEN coalesce(ma.storage_ref,'') ~* '^https?://' THEN ma.storage_ref ELSE NULL END,
        'playback_mode', CASE WHEN coalesce(ma.storage_ref,'') ~* '^https?://' THEN 'EXTERNAL_URL' ELSE 'SELF_HOSTED_SIGNED' END,
        'storage_bucket', CASE WHEN coalesce(ma.storage_ref,'') ~* '^https?://' THEN NULL ELSE 'pulse-generated-media' END,
        'storage_object', CASE WHEN coalesce(ma.storage_ref,'') ~* '^https?://' THEN NULL ELSE ma.storage_ref END,
        'creator', CASE WHEN ma.spec_ref->>'tiktok_url' ~ 'tiktok\.com/@'
                        THEN '@' || substring(ma.spec_ref->>'tiktok_url' from 'tiktok\.com/@([^/?]+)') END,
        'description', ma.spec_ref->>'video_desc',
        'duration', ma.duration,
        'market', ma.country_code,
        'provider', ma.provider,
        'source_provider', coalesce(ma.provenance->>'source_provider', ma.provider),
        'copyright', CASE WHEN ma.provenance->>'copyright' IN ('1','true') THEN true
                          WHEN ma.provenance->>'copyright' IN ('0','false') THEN false ELSE NULL END,
        'is_free', CASE WHEN ma.provenance->>'is_free' IN ('1','true') THEN true
                        WHEN ma.provenance->>'is_free' IN ('0','false') THEN false ELSE NULL END,
        'commercial_use', 'NOT_CLEARED_REFERENCE_ONLY',
        'views', nullif(ma.provenance->'provider_raw'->>'play_count','')::numeric,
        'likes', nullif(ma.provenance->'provider_raw'->>'digg_count','')::numeric,
        'comments', nullif(ma.provenance->'provider_raw'->>'comment_count','')::numeric,
        'shares', nullif(ma.provenance->'provider_raw'->>'share_count','')::numeric,
        'units_sold', nullif(ma.provenance->'provider_raw'->>'units_sold','')::numeric,
        'is_ad', CASE WHEN ma.provenance->'provider_raw'->>'is_ad' IN ('1','true') THEN true
                      WHEN ma.provenance->'provider_raw'->>'is_ad' IN ('0','false') THEN false END,
        'published_at', CASE WHEN ma.spec_ref->>'create_time' ~ '^[0-9]+$'
                             THEN to_timestamp((ma.spec_ref->>'create_time')::bigint) END,
        'observed_at', ma.provenance->>'observed_at',
        'rights_state', ma.rights_state,
        'authority', 'REFERENCE_ONLY'
      )) AS elem,
      nullif(ma.provenance->'provider_raw'->>'play_count','')::numeric AS ord_play,
      ma.created_at AS ord_created
    FROM public.media_assets ma
    WHERE ma.product_id=p_product AND ma.tenant_id=v_uid AND upper(coalesce(ma.media_type,''))='VIDEO'
      AND coalesce(ma.is_launch_safe,false)=false
      AND (v_mkt IS NULL OR ma.country_code IS NULL OR upper(ma.country_code)=v_mkt)
  ) sub;

  SELECT (source_store='fastmoss' OR extended->>'provider_product_native'='FASTMOSS')
    INTO v_is_fastmoss FROM public.commerce_products WHERE id=p_product AND user_id=v_uid;

  v_video_state := CASE
    WHEN v_video.media_type IS NOT NULL THEN 'VIDEO_AVAILABLE'
    WHEN coalesce(v_is_fastmoss,false) THEN 'VIDEO_ACCESS_BLOCKED'
    ELSE 'VIDEO_UNAVAILABLE' END;

  SELECT (r.bound = true), coalesce((
     SELECT count(*) FROM public.supplier_product_assets spa
      WHERE spa.supplier = r.selected_supplier AND spa.supplier_product_id = r.selected_supplier_product_id), 0)
    INTO v_bound, v_supplier_assets
  FROM public.commerce_concrete_supplier_resolution r
  WHERE r.tenant_id=v_uid AND r.opportunity_product_id=p_product AND (v_mkt IS NULL OR r.market=v_mkt)
  ORDER BY r.created_at DESC LIMIT 1;

  v_supplier_state := CASE
    WHEN coalesce(v_bound,false) AND coalesce(v_supplier_assets,0) > 0 THEN 'SUPPLIER_MEDIA_AVAILABLE'
    ELSE 'SUPPLIER_MEDIA_PENDING' END;

  v_card := CASE WHEN v_image_state='IMAGE_AVAILABLE' THEN 'MEDIA_COMPLETE' ELSE 'MEDIA_INCOMPLETE' END;

  RETURN jsonb_build_object(
    'status','ok',
    'product_id', p_product, 'market', v_mkt,
    'image_state', v_image_state,
    'primary_image', CASE WHEN v_primary.image_url IS NULL THEN NULL ELSE jsonb_build_object(
       'url', v_primary.image_url, 'provider', v_primary.source_provider, 'source_entity_id', v_primary.source_entity_id,
       'observed_at', v_primary.observed_at, 'rights_state', v_primary.rights_state, 'authority','REFERENCE_ONLY') END,
    'gallery_count', coalesce(v_gallery,0),
    'video_state', v_video_state,
    'video_count', coalesce(v_video_count,0),
    'primary_video', CASE WHEN v_video.media_type IS NULL THEN NULL ELSE jsonb_build_object(
       'media_asset_id', v_video.id,
       'url', CASE WHEN coalesce(v_video.storage_ref,'') ~* '^https?://' THEN v_video.storage_ref ELSE NULL END,
       'playback_mode', CASE WHEN coalesce(v_video.storage_ref,'') ~* '^https?://' THEN 'EXTERNAL_URL' ELSE 'SELF_HOSTED_SIGNED' END,
       'storage_bucket', CASE WHEN coalesce(v_video.storage_ref,'') ~* '^https?://' THEN NULL ELSE 'pulse-generated-media' END,
       'storage_object', CASE WHEN coalesce(v_video.storage_ref,'') ~* '^https?://' THEN NULL ELSE v_video.storage_ref END,
       'cover', v_video.spec_ref ->> 'cover',
       'tiktok_url', v_video.spec_ref ->> 'tiktok_url',
       'fastmoss_url', v_video.spec_ref ->> 'fastmoss_url',
       'video_desc', v_video.spec_ref ->> 'video_desc',
       'duration', v_video.duration,
       'provider', v_video.provider,
       'source_entity_id', v_video.provenance ->> 'source_entity_id',
       'market', v_video.country_code,
       'copyright', CASE WHEN v_video.provenance->>'copyright' IN ('1','true') THEN true
                         WHEN v_video.provenance->>'copyright' IN ('0','false') THEN false ELSE NULL END,
       'is_free', CASE WHEN v_video.provenance->>'is_free' IN ('1','true') THEN true
                       WHEN v_video.provenance->>'is_free' IN ('0','false') THEN false ELSE NULL END,
       'commercial_use', 'NOT_CLEARED_REFERENCE_ONLY',
       'play_count', (v_video.provenance -> 'provider_raw' ->> 'play_count'),
       'digg_count', (v_video.provenance -> 'provider_raw' ->> 'digg_count'),
       'units_sold', (v_video.provenance -> 'provider_raw' ->> 'units_sold'),
       'rights_state', v_video.rights_state, 'authority','REFERENCE_ONLY') END,
    'videos', coalesce(v_videos, '[]'::jsonb),
    'supplier_media_state', v_supplier_state,
    'card_media_state', v_card,
    'authority', 'REFERENCE_ONLY',
    'invariants', jsonb_build_object(
      'identity_server_owned_auth_uid', true,
      'caller_tenant_arg_ignored_for_authorization', true,
      'reference_media_never_unlocks_store_ad_creative_publishing', true,
      'supplier_authoritative_media_is_separate_table', 'supplier_product_assets',
      'video_lane_market_isolated', true,
      'self_hosted_video_playback_requires_signed_url', true,
      'completed_card_requires_genuine_primary_image', true,
      'no_fabricated_media', true),
    'contract','pulse_product_media_state_v1');
END $function$;

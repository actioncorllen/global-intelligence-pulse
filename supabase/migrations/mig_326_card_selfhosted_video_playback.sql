-- mig_326_card_selfhosted_video_playback.sql
-- Stage 4B: Product Intelligence Card — surface SELF-HOSTED supplier video playback.
--
-- Why: fn_product_media_state already renders the product video lane from media_assets, but it only
-- exposed the raw storage_ref as `url`. For externally-hosted reference videos (FastMoss/TikTok) that
-- storage_ref is a public https URL and plays directly. For the newly imported CJ supplier video the
-- storage_ref is a Supabase Storage OBJECT PATH in the PRIVATE bucket `pulse-generated-media`, which is
-- NOT directly playable — the client must mint a short-lived signed URL (via the existing
-- fn_media_asset_signed_ref(asset_id) + storage createSignedUrl(bucket, storage_ref)).
--
-- This migration makes the card self-describing so the frontend knows which playback path to take,
-- WITHOUT changing any rights/isolation behaviour:
--   * playback_mode = 'EXTERNAL_URL'      -> storage_ref is an https URL; play `url` directly.
--   * playback_mode = 'SELF_HOSTED_SIGNED'-> storage_ref is a private Storage object; call
--     fn_media_asset_signed_ref(media_asset_id) to obtain {bucket, storage_ref}, then sign + play.
-- Added fields on primary_video and each videos[] element: media_asset_id, storage_bucket,
-- storage_object, playback_mode. `url` is now null for self-hosted assets (so a client never tries to
-- play a bare object path). Everything else — auth.uid() tenant isolation, country scoping, the
-- is_launch_safe=false reference-only filter, REFERENCE_ONLY authority, no-fabrication invariants —
-- is byte-for-byte unchanged. Reference media STILL never unlocks store/ad/creative/publishing.
--
-- NOTE: authored while the Supabase MCP write path (execute_sql / apply_migration) was timing out.
-- Apply via the authorised route (Supabase Dashboard SQL Editor / CLI) — see
-- supabase/manual/mig_326_dashboard_apply.sql. Idempotent (CREATE OR REPLACE); changes no data.

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

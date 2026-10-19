-- mig_306_product_media_state_video_evidence.sql
--
-- Expose the GENUINE REFERENCE_ONLY product videos (integrated by mig_305) to the
-- Product Intelligence workspace, by extending the existing card-safe contract
-- fn_product_media_state with a market-isolated `videos` array alongside the
-- `primary_video`/`video_count` it already returns. Display-only evidence.
--
-- Each `videos` element carries only genuine provider fields (never fabricated):
--   video_id, tiktok_url, fastmoss_url, cover (thumbnail), creator (parsed from the
--   TikTok URL handle), description (original source copy, for market-language
--   localization on the client), duration, market, provider/source_provider,
--   views (play_count), likes (digg_count), comments, shares, units_sold, is_ad,
--   published_at (from create_time), observed_at (when fetched), rights_state,
--   authority='REFERENCE_ONLY'. jsonb_strip_nulls drops any field the provider did
--   not return, so the client renders "unknown" honestly rather than a zero.
--
-- Invariants unchanged from mig_305: auth model (auth.uid() ownership; p_tenant
-- ignored), denied shape (now also carries videos:[]), country isolation on the
-- video lane (a DE video never surfaces under another market), image/supplier lanes,
-- Product Asset Lock (REFERENCE_ONLY, never launch-safe, never supplier_product_assets).
-- No provider call. CREATE OR REPLACE preserves existing grants.

CREATE OR REPLACE FUNCTION public.fn_product_media_state(p_tenant uuid, p_product uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();   -- SERVER-OWNED identity. p_tenant is NEVER used for authorization.
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

  -- Video lane: tenant + product + (optional) market-isolated. A video carrying a country_code is
  -- confined to its market so e.g. DE reference evidence never surfaces under another market; legacy
  -- videos with no country_code keep their prior (market-agnostic) behaviour.
  SELECT media_type, storage_ref, provider, duration, spec_ref, provenance, rights_state, country_code,
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

  -- Full market-isolated REFERENCE_ONLY video list for the gallery (genuine fields only).
  SELECT coalesce(jsonb_agg(elem ORDER BY ord_play DESC NULLS LAST, ord_created DESC), '[]'::jsonb)
    INTO v_videos
  FROM (
    SELECT
      jsonb_strip_nulls(jsonb_build_object(
        'video_id', ma.provenance->>'source_entity_id',
        'tiktok_url', ma.spec_ref->>'tiktok_url',
        'fastmoss_url', ma.spec_ref->>'fastmoss_url',
        'cover', ma.spec_ref->>'cover',
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
       'url', v_video.storage_ref,
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
      'completed_card_requires_genuine_primary_image', true,
      'no_fabricated_media', true),
    'contract','pulse_product_media_state_v1');
END $function$;

GRANT EXECUTE ON FUNCTION public.fn_product_media_state(uuid,uuid,text) TO anon, authenticated, service_role;

-- Extend the mig_305 selftest with `videos` array assertions (genuine list, isolation).
CREATE OR REPLACE FUNCTION public.fn_fastmoss_product_video_reference_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  OWNER_T uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  OTHER_T uuid := '2f000000-0000-4000-a000-000000002999';
  PROD uuid := '5bc29d0a-b8e0-4fa9-bb80-d77197d770c4';
  checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0; ok boolean;
  v_cnt int; v_bad int; v_lock int; r_owner jsonb; r_jp jsonb; r_cross jsonb; v_reint jsonb; v_el jsonb;
BEGIN
  SELECT count(*) INTO v_cnt FROM public.media_assets
   WHERE product_id=PROD AND tenant_id=OWNER_T AND media_type='VIDEO'
     AND source_type='PROVIDER_DISCOVERY_REFERENCE_VIDEO' AND provider='FASTMOSS';
  ok := (v_cnt = 7);
  checks := checks || jsonb_build_object('check','SEVEN_REFERENCE_VIDEOS','ok',ok,'count',v_cnt);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  SELECT count(*) INTO v_bad FROM public.media_assets
   WHERE product_id=PROD AND tenant_id=OWNER_T AND source_type='PROVIDER_DISCOVERY_REFERENCE_VIDEO'
     AND NOT (
        coalesce(is_launch_safe,true)=false
        AND rights_state='PROVIDER_DISCOVERY_REFERENCE'
        AND usage_permission='REFERENCE_ONLY'
        AND provenance->>'authority'='REFERENCE_ONLY'
        AND upper(coalesce(country_code,''))='DE'
        AND nullif(provenance->>'source_entity_id','') IS NOT NULL
        AND storage_ref ~* '^https?://'
        AND provenance ? 'provider_raw');
  ok := (v_bad = 0);
  checks := checks || jsonb_build_object('check','ALL_REFERENCE_ONLY_NOT_LAUNCH_SAFE','ok',ok,'violations',v_bad);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  SELECT count(*) INTO v_lock FROM public.supplier_product_assets spa
   WHERE spa.source_url IN (SELECT storage_ref FROM public.media_assets
                              WHERE product_id=PROD AND tenant_id=OWNER_T
                                AND source_type='PROVIDER_DISCOVERY_REFERENCE_VIDEO')
      OR spa.storage_ref IN (SELECT storage_ref FROM public.media_assets
                              WHERE product_id=PROD AND tenant_id=OWNER_T
                                AND source_type='PROVIDER_DISCOVERY_REFERENCE_VIDEO');
  ok := (v_lock = 0);
  checks := checks || jsonb_build_object('check','ASSET_LOCK_NO_SUPPLIER_LEAK','ok',ok,'leaks',v_lock);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER_T)::text, true);
  r_owner := public.fn_product_media_state(NULL, PROD, 'DE');
  ok := (r_owner->>'status'='ok') AND (r_owner->>'video_state'='VIDEO_AVAILABLE')
        AND ((r_owner->>'video_count')::int = 7)
        AND (r_owner->'primary_video'->>'authority'='REFERENCE_ONLY')
        AND (r_owner->'primary_video'->>'tiktok_url' ~* '^https?://');
  checks := checks || jsonb_build_object('check','OWNER_DE_VIDEO_AVAILABLE','ok',ok,
     'video_state',r_owner->>'video_state','video_count',r_owner->>'video_count');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- videos[] array present, 7 genuine entries, each with tiktok link + creator + views + REFERENCE_ONLY.
  v_el := r_owner->'videos'->0;
  ok := (jsonb_typeof(r_owner->'videos')='array')
        AND (jsonb_array_length(r_owner->'videos') = 7)
        AND (v_el->>'tiktok_url' ~* '^https?://')
        AND (v_el->>'creator' ~ '^@')
        AND (v_el ? 'views')
        AND (v_el->>'authority'='REFERENCE_ONLY')
        AND (upper(coalesce(v_el->>'market',''))='DE');
  checks := checks || jsonb_build_object('check','VIDEOS_ARRAY_GENUINE','ok',ok,
     'len', jsonb_array_length(r_owner->'videos'), 'first_creator', v_el->>'creator');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  r_jp := public.fn_product_media_state(NULL, PROD, 'JP');
  ok := (r_jp->>'status'='ok') AND ((r_jp->>'video_count')::int = 0)
        AND (r_jp->'primary_video'='null'::jsonb) AND (r_jp->>'video_state' <> 'VIDEO_AVAILABLE')
        AND (jsonb_array_length(r_jp->'videos') = 0);
  checks := checks || jsonb_build_object('check','COUNTRY_ISOLATION_JP_EMPTY','ok',ok,
     'video_state',r_jp->>'video_state','videos_len',jsonb_array_length(r_jp->'videos'));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub',OTHER_T)::text, true);
  r_cross := public.fn_product_media_state(NULL, PROD, 'DE');
  ok := (r_cross->>'status'='unauthorized') AND (r_cross->'primary_video'='null'::jsonb)
        AND ((r_cross->>'video_count')::int = 0) AND (jsonb_array_length(r_cross->'videos') = 0);
  checks := checks || jsonb_build_object('check','CROSS_TENANT_VIDEO_DENIED','ok',ok,'status',r_cross->>'status');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  PERFORM set_config('request.jwt.claims', '', true);

  v_reint := public.fn_fastmoss_integrate_reference_videos(159);
  SELECT count(*) INTO v_cnt FROM public.media_assets
   WHERE product_id=PROD AND tenant_id=OWNER_T AND source_type='PROVIDER_DISCOVERY_REFERENCE_VIDEO';
  ok := (coalesce(v_reint->>'ok','')='true') AND (v_cnt = 7);
  checks := checks || jsonb_build_object('check','IDEMPOTENT_REINTEGRATION','ok',ok,'count_after',v_cnt);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  RETURN jsonb_build_object('contract','pulse_fastmoss_product_video_reference_selftest_v1',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),
    'checks',checks,'generated_at',now());
END $function$;

REVOKE ALL ON FUNCTION public.fn_fastmoss_product_video_reference_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_product_video_reference_selftest() TO service_role;

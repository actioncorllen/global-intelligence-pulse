-- mig_305_fastmoss_product_video_reference.sql
--
-- Integrate the GENUINE product-associated videos returned by the one authorised
-- FastMoss /product/v1/videoList call (net._http_response id 159: code 0 "success",
-- data.total=7, 7 video objects for FastMoss product 1729937925462923841 / region DE)
-- into the EXISTING discovery-media contract (PULSE-ECOM-DISCOVERY-MEDIA-001) as
-- REFERENCE_ONLY research evidence.
--
-- Invariants preserved (no exceptions):
--   * REFERENCE_ONLY authority. Persisted ONLY into public.media_assets, NEVER into
--     public.supplier_product_assets (Product Asset Lock). is_launch_safe=false always;
--     these rows never unlock store / ad / creative / publishing.
--   * Tenant isolation: tenant_id = the product owner's user_id (auth.uid() boundary,
--     same as fn_product_media_state). Country isolation: country_code = the returned
--     region (DE); the media-state video lane is now market-filtered so DE evidence
--     never surfaces under another market.
--   * Source provenance: the exact provider object is stored verbatim under
--     provenance.provider_raw plus net_response_id=159; NO video is invented. Only
--     fields actually present in the provider response are mapped.
--
-- No provider API call is made here (the one-call cap is already spent). These
-- functions only read the already-stored net._http_response row.

-- ---------------------------------------------------------------------------
-- 1. Idempotency integrity: one discovery reference video per (tenant, product, source id)
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_media_assets_discovery_reference_video
  ON public.media_assets (tenant_id, product_id, ((provenance ->> 'source_entity_id')))
  WHERE source_type = 'PROVIDER_DISCOVERY_REFERENCE_VIDEO';

-- ---------------------------------------------------------------------------
-- 2. Persist ONE genuine provider video element as REFERENCE_ONLY (idempotent)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_persist_reference_video(
  p_tenant uuid, p_product uuid, p_market text, p_video jsonb, p_response_id bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_id uuid;
  v_sid text := nullif(btrim(coalesce(p_video ->> 'video_id', p_video -> 'video' ->> 'uid', '')), '');
  v_desc jsonb := CASE WHEN jsonb_typeof(p_video -> 'video') = 'object' THEN p_video -> 'video' ELSE '{}'::jsonb END;
  v_url text := nullif(btrim(coalesce(v_desc ->> 'tiktok_url', v_desc ->> 'fastmoss_url', '')), '');
  v_mkt text := nullif(upper(btrim(coalesce(nullif(v_desc ->> 'region',''), p_market, ''))), '');
  v_dur numeric;
BEGIN
  -- No genuine identifier or url -> persist nothing (no fabrication).
  IF p_product IS NULL OR v_sid IS NULL OR v_url IS NULL OR v_url !~* '^https?://' THEN
    RETURN NULL;
  END IF;

  -- Idempotent: the same provider video for the same tenant/product is returned, not duplicated.
  SELECT id INTO v_id FROM public.media_assets
   WHERE tenant_id = p_tenant AND product_id = p_product
     AND source_type = 'PROVIDER_DISCOVERY_REFERENCE_VIDEO'
     AND provenance ->> 'source_entity_id' = v_sid
   LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  BEGIN
    v_dur := nullif(v_desc ->> 'duration', '')::numeric;
  EXCEPTION WHEN others THEN v_dur := NULL; END;

  INSERT INTO public.media_assets
    (tenant_id, product_id, media_type, source_type, provider,
     rights_state, generation_status, approval_state,
     duration, storage_ref, spec_ref, provenance,
     is_launch_safe, country_code, usage_permission, lineage_state)
  VALUES (
     p_tenant, p_product, 'VIDEO', 'PROVIDER_DISCOVERY_REFERENCE_VIDEO', 'FASTMOSS',
     'PROVIDER_DISCOVERY_REFERENCE', 'EXTERNAL_REFERENCE', 'DRAFT',
     v_dur, v_url,
     -- genuine provider descriptor (exact), used for display of the reference
     jsonb_strip_nulls(v_desc || jsonb_build_object('video_id', v_sid)),
     jsonb_build_object(
       'authority', 'REFERENCE_ONLY',
       'lane', 'DISCOVERY',
       'provider', 'FASTMOSS',
       'source_provider', 'FASTMOSS',
       'source_entity_id', v_sid,
       'product_native_id', nullif(p_video ->> 'product_id',''),
       'seller_id', nullif(p_video ->> 'seller_id',''),
       'market', nullif(upper(btrim(coalesce(p_market,''))),''),
       'region', nullif(v_desc ->> 'region',''),
       'net_response_id', p_response_id,
       'observed_at', now(),
       'note', 'product-native discovery video; REFERENCE_ONLY research media; NOT supplier-authoritative; never unlocks store/ad/creative/publishing',
       -- exact provider object, verbatim: no invented fields
       'provider_raw', p_video),
     false, v_mkt, 'REFERENCE_ONLY', 'UNRESOLVED')
  RETURNING id INTO v_id;

  RETURN v_id;
END $function$;

-- ---------------------------------------------------------------------------
-- 3. Integrate every genuine video from a stored videoList response (idempotent)
--    Resolves our product+tenant from the provider product id carried in the response;
--    no hardcoded ids, no provider call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_fastmoss_integrate_reference_videos(p_response_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_c jsonb; v_raw jsonb; v_fm_pid text; v_region text;
  v_product uuid; v_tenant uuid; v_elem jsonb; v_persisted uuid;
  v_seen int := 0; v_stored int := 0; v_ids jsonb := '[]'::jsonb;
BEGIN
  SELECT content::jsonb INTO v_c FROM net._http_response WHERE id = p_response_id;
  IF v_c IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'RESPONSE_NOT_FOUND', 'response_id', p_response_id);
  END IF;

  IF upper(coalesce(v_c ->> 'provider','')) <> 'FASTMOSS'
     OR coalesce(v_c ->> 'video_lane_status','') <> 'OK' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NOT_A_SUCCESSFUL_FASTMOSS_VIDEO_RESPONSE',
      'provider', v_c ->> 'provider', 'video_lane_status', v_c ->> 'video_lane_status');
  END IF;

  v_raw := v_c -> 'video_raw';
  IF coalesce(v_raw ->> 'code','') <> '0' OR jsonb_typeof(v_raw -> 'data' -> 'list') <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PROVIDER_BODY_NOT_SUCCESS',
      'code', v_raw ->> 'code', 'message', v_raw ->> 'message');
  END IF;

  v_fm_pid := nullif(btrim(coalesce(v_c ->> 'product_id', v_raw -> 'data' ->> 'product_id', '')), '');
  v_region := nullif(upper(btrim(coalesce(v_c ->> 'region', v_c ->> 'market', ''))), '');
  IF v_fm_pid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_PROVIDER_PRODUCT_ID');
  END IF;

  -- Resolve OUR product + owner (tenant) from the provider-native id. Country from the response.
  SELECT id, user_id INTO v_product, v_tenant
  FROM public.commerce_products
  WHERE source_store = 'fastmoss' AND extended ->> 'fastmoss_product_id' = v_fm_pid
  LIMIT 1;
  IF v_product IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_MATCHING_LOCAL_PRODUCT', 'provider_product_id', v_fm_pid);
  END IF;

  FOR v_elem IN SELECT jsonb_array_elements(v_raw -> 'data' -> 'list') LOOP
    v_seen := v_seen + 1;
    v_persisted := public.fn_persist_reference_video(v_tenant, v_product, v_region, v_elem, p_response_id);
    IF v_persisted IS NOT NULL THEN
      v_stored := v_stored + 1;
      v_ids := v_ids || to_jsonb(v_persisted);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true, 'response_id', p_response_id, 'provider', 'FASTMOSS',
    'provider_product_id', v_fm_pid, 'market', v_region,
    'product_id', v_product, 'tenant_id', v_tenant,
    'provider_total', (v_raw -> 'data' ->> 'total'),
    'videos_seen', v_seen, 'videos_present_as_reference', v_stored, 'media_ids', v_ids,
    'authority', 'REFERENCE_ONLY', 'contract', 'pulse_fastmoss_reference_video_v1');
END $function$;

-- ---------------------------------------------------------------------------
-- 4. Discovery-media state: surface the genuine REFERENCE_ONLY video + enforce
--    country isolation on the video lane. Auth model, denied shape, image lane,
--    supplier lane and all invariants are UNCHANGED.
-- ---------------------------------------------------------------------------
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
  v_bound boolean; v_supplier_assets int; v_owns boolean;
  v_denied jsonb := jsonb_build_object(
    'status','unauthorized',
    'image_state','IMAGE_UNAVAILABLE','video_state','VIDEO_UNAVAILABLE',
    'supplier_media_state','SUPPLIER_MEDIA_PENDING','card_media_state','MEDIA_INCOMPLETE',
    'primary_image', NULL, 'gallery_count', 0, 'primary_video', NULL, 'video_count', 0,
    'authority','REFERENCE_ONLY',
    'contract','pulse_product_media_state_v1');
BEGIN
  -- Fail closed: no authenticated session, or missing product.
  IF v_uid IS NULL OR p_product IS NULL THEN
    RETURN v_denied;
  END IF;

  -- Ownership is the authorization boundary (auth.uid() owns the product). Same denied shape whether
  -- unauthenticated or not-owned, so existence is never disclosed. p_tenant is ignored entirely.
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product AND user_id=v_uid) INTO v_owns;
  IF NOT v_owns THEN
    RETURN v_denied;
  END IF;

  -- Primary + gallery: scoped to the authenticated tenant AND product AND (optional) market.
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
    -- REFERENCE_ONLY discovery video; genuine provider fields only, never launch-safe.
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

-- ---------------------------------------------------------------------------
-- 5. Grants (definer-only for writers; read wrapper stays broadly executable,
--    it fails closed internally via auth.uid()).
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fn_persist_reference_video(uuid,uuid,text,jsonb,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_persist_reference_video(uuid,uuid,text,jsonb,bigint) TO service_role;

REVOKE ALL ON FUNCTION public.fn_fastmoss_integrate_reference_videos(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_integrate_reference_videos(bigint) TO service_role;

GRANT EXECUTE ON FUNCTION public.fn_product_media_state(uuid,uuid,text) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. One-time, idempotent backfill from the stored authorised response (id 159).
--    Tolerates a purged response row (pg_net may reap it): the already-persisted
--    reference videos remain; re-apply is a no-op.
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE v_res jsonb;
BEGIN
  v_res := public.fn_fastmoss_integrate_reference_videos(159);
  RAISE NOTICE 'mig_305 backfill: %', v_res;
END $backfill$;

-- ---------------------------------------------------------------------------
-- 7. Selftest: proves genuine integration + all invariants, with no provider call.
-- ---------------------------------------------------------------------------
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
  v_cnt int; v_bad int; v_lock int; r_owner jsonb; r_jp jsonb; r_cross jsonb; v_reint jsonb;
BEGIN
  -- S1: exactly 7 genuine reference videos persisted for the Krippen product (DE), FastMoss.
  SELECT count(*) INTO v_cnt FROM public.media_assets
   WHERE product_id=PROD AND tenant_id=OWNER_T AND media_type='VIDEO'
     AND source_type='PROVIDER_DISCOVERY_REFERENCE_VIDEO' AND provider='FASTMOSS';
  ok := (v_cnt = 7);
  checks := checks || jsonb_build_object('check','SEVEN_REFERENCE_VIDEOS','ok',ok,'count',v_cnt);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- S2: every reference row is REFERENCE_ONLY, not launch-safe, DE-scoped, genuine source id + url.
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

  -- S3: Product Asset Lock — none of the reference video URLs leaked into supplier_product_assets.
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

  -- S4: owner, DE -> VIDEO_AVAILABLE, count 7, genuine primary_video surfaced REFERENCE_ONLY.
  PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER_T)::text, true);
  r_owner := public.fn_product_media_state(NULL, PROD, 'DE');
  ok := (r_owner->>'status'='ok') AND (r_owner->>'video_state'='VIDEO_AVAILABLE')
        AND ((r_owner->>'video_count')::int = 7)
        AND (r_owner->'primary_video'->>'authority'='REFERENCE_ONLY')
        AND (r_owner->'primary_video'->>'tiktok_url' ~* '^https?://');
  checks := checks || jsonb_build_object('check','OWNER_DE_VIDEO_AVAILABLE','ok',ok,
     'video_state',r_owner->>'video_state','video_count',r_owner->>'video_count');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- S5: country isolation — owner, JP -> DE reference videos do NOT surface.
  r_jp := public.fn_product_media_state(NULL, PROD, 'JP');
  ok := (r_jp->>'status'='ok') AND ((r_jp->>'video_count')::int = 0)
        AND (r_jp->'primary_video'='null'::jsonb) AND (r_jp->>'video_state' <> 'VIDEO_AVAILABLE');
  checks := checks || jsonb_build_object('check','COUNTRY_ISOLATION_JP_EMPTY','ok',ok,
     'video_state',r_jp->>'video_state','video_count',r_jp->>'video_count');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- S6: cross-tenant denied, no video leak.
  PERFORM set_config('request.jwt.claims', json_build_object('sub',OTHER_T)::text, true);
  r_cross := public.fn_product_media_state(NULL, PROD, 'DE');
  ok := (r_cross->>'status'='unauthorized') AND (r_cross->'primary_video'='null'::jsonb)
        AND ((r_cross->>'video_count')::int = 0);
  checks := checks || jsonb_build_object('check','CROSS_TENANT_VIDEO_DENIED','ok',ok,'status',r_cross->>'status');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  PERFORM set_config('request.jwt.claims', '', true);

  -- S7: idempotency — re-integrating the same response persists no duplicates.
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

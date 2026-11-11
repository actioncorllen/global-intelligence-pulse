-- ============================================================================
-- 20261111010000_kalodata_product_images.sql
-- PROPOSED production migration (NOT executed from this repo). Apply via the
-- canonical Supabase pipeline (supabase db push / Management API apply_migration)
-- AFTER 20261111000000_kalodata_detail_video_caller.sql (it depends on the
-- Phase 9 caller wiring: fn_kalodata_op_reserve / op_fire / op_complete_from_edge).
--
-- Kalodata Product Images (multi-image research gallery). Reuses product_image_assets +
-- the PROVIDER_DISCOVERY_REFERENCE rights model + the discovery credit workflow. Additive
-- cache columns; durable private-bucket caching of the 5-minute signed URLs; content-hash
-- dedup; tenant-authorised delivery via the existing auth.uid()+ownership display gates.
--
-- REQUIREMENT 10: fn_asset_rights_class now maps PROVIDER_DISCOVERY_REFERENCE + providers
-- KALODATA/FASTMOSS to RESEARCH_REFERENCE_ONLY. VERIFIED FAIL-CLOSED before the change
-- (publishable/ai-reference gates exclude both research & unknown classes; the only other
-- consumer, fn_product_commercial_asset_readiness, gates on RAW rights_state, not the class).
--
-- Self-tests after apply (no paid calls):
--   select public.fn_kalodata_product_images_selftest();     -> 8/8 all_pass
--   select public.fn_kalodata_caller_lifecycle_selftest();   -> 12/12 (regression; op_reserve widened)
-- Generated 2026-11-11 from supabase/drafts/kalodata_product_images.sql; diff before apply.
-- ============================================================================
BEGIN;

-- ============================================================================
-- DRAFT (PROPOSED, NOT DEPLOYED): kalodata_product_images.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A (Phase 13 — Product Images multi-image)
--
-- Documented contract (official Kalodata Open API, confirmed by the account owner 2026-11-11):
--   POST https://www.kalodata.com/openapi/v1/tiktok/product/images
--   Header: secret-key: <KALODATA_SECRET_KEY>
--   Request:  { "product_id": "<kalodata product id>" }
--   Response data: { product_id: string, images: string[] (signed URLs), expires_at: UTC timestamp }
--   Rate limit: 10 requests / 10 seconds. Signed image URLs EXPIRE after ~5 minutes.
--
-- Design (reuses existing architecture — NO new image store, NO new billing):
--   * product_image_assets + fn_persist_reference_image rights model are REUSED. Kalodata research
--     images stay rights_state='PROVIDER_DISCOVERY_REFERENCE', provenance authority='REFERENCE_ONLY'
--     (never publishable / never ad / storefront / commercial-creative eligible).
--   * The 5-minute signed URL cannot be a durable display source, so the edge DOWNLOADS the bytes
--     server-side (before expiry) and stores them in a PRIVATE Supabase Storage bucket, then mints a
--     durable signed URL stored as image_url — exactly the pattern product-image-import already uses
--     for customer uploads (service role never leaves the edge; tenant-authorised delivery is enforced
--     by the existing auth.uid()+ownership display gates fn_product_media_state / fn_resolve_product_image).
--   * Credits: REUSES fn_kalodata_op_reserve / fn_discovery_refresh_authorize / fn_kalodata_op_fire /
--     fn_kalodata_op_complete_from_edge (discovery_credit_ledger + provider_call_budget). Only addition:
--     'PRODUCT_IMAGES' is accepted as an operation. Already-cached products short-circuit BEFORE reserve
--     (no credit spent) — dedup minimises Kalodata credits.
--   * Dedup: content sha256 (signed URLs rotate per call, so URL is not a stable key). A per-product
--     content_hash guard makes re-caching idempotent at the row level.
--
-- Requirement 10 (rights classifier): fn_asset_rights_class now maps PROVIDER_DISCOVERY_REFERENCE and
--   providers KALODATA/FASTMOSS to 'RESEARCH_REFERENCE_ONLY' (was the catch-all 'RIGHTS_UNKNOWN').
--   VERIFIED FAIL-CLOSED against every consumer before the change (see the block above that function).
--
-- APPLY ONLY via the canonical Supabase migration pipeline. Requires the Phase 9 caller-wiring bundle
-- (fn_kalodata_op_reserve/op_fire/op_complete_from_edge) to be present. No chargeable call / deploy here.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) Additive cache columns on product_image_assets (existing rows unaffected:
--    new columns default to NULL / 'EXTERNAL'; display of hotlinked rows is unchanged).
-- ---------------------------------------------------------------------------
ALTER TABLE public.product_image_assets
  ADD COLUMN IF NOT EXISTS storage_ref           text,        -- '<bucket>/<object path>' of the cached copy (NULL = external hotlink)
  ADD COLUMN IF NOT EXISTS source_url_expires_at  timestamptz, -- provider signed-URL expiry (provenance only; our copy is durable)
  ADD COLUMN IF NOT EXISTS cache_state            text,        -- NULL/'EXTERNAL' | 'CACHED' | 'CACHE_FAILED'
  ADD COLUMN IF NOT EXISTS content_hash           text;        -- sha256 of the image bytes (stable dedup key)

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='product_image_assets_cache_state_chk') THEN
    ALTER TABLE public.product_image_assets
      ADD CONSTRAINT product_image_assets_cache_state_chk
      CHECK (cache_state IS NULL OR cache_state IN ('EXTERNAL','CACHED','CACHE_FAILED'));
  END IF;
END $$;

-- Content-level dedup guard (per product). Partial so existing NULL-hash rows never collide.
CREATE UNIQUE INDEX IF NOT EXISTS product_image_assets_content_hash_uniq
  ON public.product_image_assets (product_id, content_hash)
  WHERE content_hash IS NOT NULL;

-- Storage-object dedup guard (one asset row per cached object).
CREATE UNIQUE INDEX IF NOT EXISTS product_image_assets_storage_ref_uniq
  ON public.product_image_assets (storage_ref)
  WHERE storage_ref IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2) REQUIREMENT 10 — rights classifier: PROVIDER_DISCOVERY_REFERENCE -> RESEARCH_REFERENCE_ONLY.
--
--    FAIL-CLOSED VERIFICATION (performed read-only against production before this change):
--    Consumers of the class / rights-summary across public schema are exactly:
--      - fn_product_commercial_rights: publishable_present  = cls IN (CUSTOMER_OWNED,SUPPLIER_AUTHORIZED,EXPLICITLY_LICENSED)
--                                      ai_reference_present = publishable set + AUTHORIZED_FOR_AI_REFERENCE
--        Neither RESEARCH_REFERENCE_ONLY nor RIGHTS_UNKNOWN is in either allow-list -> both booleans
--        are UNCHANGED by the reclass. Only research_only_count/unknown_count (informational counters)
--        shift, and NO gate branches on those counters.
--      - fn_product_commercial_asset_readiness: gates on the RAW rights_state column (SUPPLIER_PROVIDED /
--        CUSTOMER_OWNED+rights_confirmed / MARKETPLACE_PUBLIC_LISTING), NOT on the derived class, and this
--        change does NOT alter stored rights_state -> entirely unaffected (research images still land in the
--        terminal UNKNOWN/NONE branch; v_gemini_eligible stays false).
--      - fn_product_identity_resolution: references the class name only inside a note string. No gate.
--    Net effect: Kalodata/FastMoss research imagery is classified HONESTLY as research reference (not
--    "unknown"), WITHOUT unlocking publishing, AI-reference, storefront, ads or commercial creatives.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_asset_rights_class(p_rights_state text, p_source_provider text, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN upper(coalesce(p_rights_state,'')) = 'RESTRICTED' THEN 'RESTRICTED'
    WHEN upper(coalesce(p_rights_state,'')) IN ('CUSTOMER_OWNED','CUSTOMER_UPLOAD')
         AND coalesce(p_provenance->>'rights_confirmed','false') = 'true' THEN 'CUSTOMER_OWNED'
    WHEN upper(coalesce(p_rights_state,'')) IN ('CUSTOMER_OWNED','CUSTOMER_UPLOAD') THEN 'RIGHTS_UNKNOWN'
    WHEN upper(coalesce(p_rights_state,'')) IN ('EXPLICITLY_LICENSED','LICENSED','COMMERCIAL_LICENSE') THEN 'EXPLICITLY_LICENSED'
    WHEN upper(coalesce(p_rights_state,'')) IN ('SUPPLIER_PROVIDED','SUPPLIER_AUTHORIZED')
         AND coalesce(p_provenance->>'ai_reference_only','false') = 'true' THEN 'AUTHORIZED_FOR_AI_REFERENCE'
    WHEN upper(coalesce(p_rights_state,'')) IN ('SUPPLIER_PROVIDED','SUPPLIER_AUTHORIZED') THEN 'SUPPLIER_AUTHORIZED'
    -- research / marketplace / discovery-reference imagery: non-publishable, non-AI-eligible reference only.
    WHEN upper(coalesce(p_rights_state,'')) IN ('MARKETPLACE_PUBLIC_LISTING','RESEARCH_REFERENCE_ONLY',
           'PROVIDER_DISCOVERY_REFERENCE','COMPETITOR','SOCIAL')
      OR upper(coalesce(p_source_provider,'')) IN ('EBAY_BROWSE','EBAY','AMAZON','META','FACEBOOK','INSTAGRAM',
           'TIKTOK','GOOGLE','COMPETITOR','COMPETITOR_STORE','KALODATA','FASTMOSS')
      THEN 'RESEARCH_REFERENCE_ONLY'
    ELSE 'RIGHTS_UNKNOWN'
  END;
$function$;

-- ---------------------------------------------------------------------------
-- 3) Accept PRODUCT_IMAGES as a billable operation in the generic reserve
--    (identical body to Phase 9 fn_kalodata_op_reserve, only the operation allow-list is widened).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_kalodata_op_reserve(
  p_operation text, p_market text, p_idempotency_key text, p_page_number integer DEFAULT 1)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_op  text := upper(btrim(coalesce(p_operation,'')));
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_idem text := nullif(btrim(coalesce(p_idempotency_key,'')),'');
  v_q jsonb; v_price int; v_req public.discovery_refresh_request; v_page int := greatest(0, coalesce(p_page_number,1));
BEGIN
  IF v_uid IS NULL OR v_mkt IS NULL OR v_idem IS NULL
     OR v_op NOT IN ('PRODUCT_DETAIL','VIDEO_RANK','VIDEO_DETAIL','PRODUCT_IMAGES') THEN
    RETURN jsonb_build_object('status','error','reason','UNAUTHENTICATED_OR_BAD_ARGS','contract','pulse_kalodata_op_reserve_v1');
  END IF;
  SELECT * INTO v_req FROM public.discovery_refresh_request WHERE tenant_id=v_uid AND idempotency_key=v_idem;
  IF FOUND THEN
    RETURN jsonb_build_object('status','ok','idempotent_replay',true,'request_id',v_req.id,'state',v_req.status,
      'operation',v_req.operation,'credits_cost',v_req.credits_cost,'market',v_req.market,'contract','pulse_kalodata_op_reserve_v1');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.discovery_provider_market_config
                 WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled) THEN
    RETURN jsonb_build_object('status','denied','reason','UNSUPPORTED_MARKET','market',v_mkt,'contract','pulse_kalodata_op_reserve_v1');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text,42));
  v_q := public.fn_discovery_refresh_quote(v_mkt);
  IF (v_q->>'can_refresh') <> 'true' THEN
    RETURN jsonb_build_object('status','denied','reason',v_q->>'reason','quote',v_q,'contract','pulse_kalodata_op_reserve_v1');
  END IF;
  v_price := (v_q->>'required_credits')::int;
  INSERT INTO public.discovery_refresh_request(tenant_id,market,idempotency_key,status,provider,credits_cost,page_number,operation)
    VALUES (v_uid,v_mkt,v_idem,'RESERVED','KALODATA',v_price,v_page,v_op)
  RETURNING * INTO v_req;
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,idempotency_key,reason)
    VALUES (v_uid,'RESERVE',-v_price,v_req.id,v_idem,lower(v_op)||' '||v_mkt);
  RETURN jsonb_build_object('status','ok','reserved',true,'request_id',v_req.id,'operation',v_op,'credits_cost',v_price,
    'balance_after',public.fn_discovery_credit_balance(),'market',v_mkt,'contract','pulse_kalodata_op_reserve_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_op_reserve(text,text,text,integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_op_reserve(text,text,text,integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) Request builder (market-gated). The documented request body is ONLY {product_id}.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_kalodata_images_request(p_market text, p_kalodata_product_id text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
        v_pid text := nullif(btrim(coalesce(p_kalodata_product_id,'')),'');
BEGIN
  IF v_pid IS NULL THEN
    RETURN jsonb_build_object('ok',false,'reason','MISSING_PRODUCT_ID','contract','pulse_kalodata_images_request_v1');
  END IF;
  IF v_mkt IS NULL OR NOT EXISTS (SELECT 1 FROM public.discovery_provider_market_config
       WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled) THEN
    RETURN jsonb_build_object('ok',false,'reason','UNSUPPORTED_MARKET','market',v_mkt,'contract','pulse_kalodata_images_request_v1');
  END IF;
  RETURN jsonb_build_object('ok',true,'operation','tiktok/product/images','market',v_mkt,
    'request_body', jsonb_build_object('product_id', v_pid),
    'contract','pulse_kalodata_images_request_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_images_request(text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_images_request(text,text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5) Cache-aware persister. Reuses the fn_persist_reference_image RIGHTS MODEL
--    (PROVIDER_DISCOVERY_REFERENCE + REFERENCE_ONLY provenance + is_primary logic) and the SAME table,
--    adding the durable-cache columns. Pure DB registration — the edge has already downloaded the bytes,
--    stored them in the private bucket, and minted the durable signed URL (p_image_url). Ownership-checked.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_persist_kalodata_research_image(
  p_tenant uuid, p_product uuid, p_market text, p_kalodata_product_id text, p_gallery_position integer,
  p_image_url text, p_source_url text, p_source_url_expires_at timestamptz,
  p_storage_ref text, p_content_hash text, p_mime text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_owner uuid; v_id uuid; v_has_primary boolean; v_market text := nullif(upper(btrim(coalesce(p_market,''))),'');
        v_hash text := nullif(btrim(coalesce(p_content_hash,'')),''); v_sref text := nullif(btrim(coalesce(p_storage_ref,'')),'');
BEGIN
  IF p_tenant IS NULL OR p_product IS NULL THEN
    RETURN jsonb_build_object('status','error','error','missing_tenant_or_product'); END IF;
  -- durable cached copy is MANDATORY: never register a row whose only reference is an expiring source URL.
  IF p_image_url IS NULL OR p_image_url !~* '^https?://' OR position('/default/' in lower(p_image_url)) > 0 THEN
    RETURN jsonb_build_object('status','error','error','invalid_durable_image_url'); END IF;
  IF v_sref IS NULL OR v_hash IS NULL THEN
    RETURN jsonb_build_object('status','error','error','missing_storage_ref_or_hash'); END IF;
  IF lower(coalesce(p_mime,'')) NOT IN ('image/png','image/jpeg','image/webp') THEN
    RETURN jsonb_build_object('status','error','error','unsupported_mime','mime',p_mime); END IF;

  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','error','error','product_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('status','error','error','cross_tenant_rejected'); END IF;

  -- dedup on stable content hash (signed URLs rotate per call; hash does not). Reuse cached copy.
  SELECT id INTO v_id FROM public.product_image_assets
    WHERE product_id=p_product AND content_hash=v_hash LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('status','exists','deduped',true,'asset_id',v_id); END IF;

  SELECT EXISTS(SELECT 1 FROM public.product_image_assets WHERE product_id=p_product AND is_primary=true)
    INTO v_has_primary;

  INSERT INTO public.product_image_assets
    (tenant_id, product_id, market, image_url, source_provider, source_url, source_entity_id,
     rights_state, availability, is_primary, observed_at, provenance,
     storage_ref, source_url_expires_at, cache_state, content_hash)
  VALUES (p_tenant, p_product, v_market, p_image_url, 'KALODATA', p_source_url,
          nullif(btrim(coalesce(p_kalodata_product_id,'')),''),
          'PROVIDER_DISCOVERY_REFERENCE', 'AVAILABLE', NOT v_has_primary, now(),
          jsonb_build_object('authority','REFERENCE_ONLY','lane','DISCOVERY','provider','KALODATA',
            'source_entity_id', p_kalodata_product_id, 'gallery_position', p_gallery_position,
            'cache_bucket', split_part(v_sref,'/',1), 'content_hash', v_hash, 'mime', lower(p_mime),
            'source_signed_url_expires_at', p_source_url_expires_at,
            'note','kalodata product/images research gallery; REFERENCE_ONLY research media; durable private-bucket cache of an expiring provider signed URL; NOT supplier-authoritative; never unlocks store/ad/creative/publishing'),
          v_sref, p_source_url_expires_at, 'CACHED', v_hash)
  ON CONFLICT (product_id, content_hash) WHERE content_hash IS NOT NULL DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN  -- lost a race; return the existing row
    SELECT id INTO v_id FROM public.product_image_assets WHERE product_id=p_product AND content_hash=v_hash LIMIT 1;
    RETURN jsonb_build_object('status','exists','deduped',true,'asset_id',v_id);
  END IF;

  RETURN jsonb_build_object('status','registered','asset_id',v_id,'is_primary',(NOT v_has_primary),
    'rights_state','PROVIDER_DISCOVERY_REFERENCE','authority','REFERENCE_ONLY','cache_state','CACHED');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_persist_kalodata_research_image(uuid,uuid,text,text,integer,text,text,timestamptz,text,text,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_persist_kalodata_research_image(uuid,uuid,text,text,integer,text,text,timestamptz,text,text,text) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) Fast existence check (lets the edge skip a redundant byte upload for an already-cached hash).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_kalodata_research_image_exists(p_tenant uuid, p_product uuid, p_content_hash text)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.product_image_assets a
    JOIN public.commerce_products cp ON cp.id=a.product_id AND cp.user_id=p_tenant
    WHERE a.product_id=p_product AND a.content_hash=nullif(btrim(coalesce(p_content_hash,'')),''));
$function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_research_image_exists(uuid,uuid,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_research_image_exists(uuid,uuid,text) TO service_role;

-- ---------------------------------------------------------------------------
-- 7) Tenant-authorised cached gallery (durable signed URLs only ever returned to the owner).
--    Used both for credit-saving cache reuse and for the research-gallery display surface.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_kalodata_product_images_cached(p_tenant uuid, p_product uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_owner uuid; v_imgs jsonb;
BEGIN
  IF p_tenant IS NULL OR p_product IS NULL THEN
    RETURN jsonb_build_object('status','error','error','missing_args'); END IF;
  -- authenticated callers may only read their own tenant; service_role (auth.uid() null) uses p_tenant.
  IF v_uid IS NOT NULL AND v_uid <> p_tenant THEN
    RETURN jsonb_build_object('status','forbidden'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product;
  IF v_owner IS NULL OR v_owner <> p_tenant THEN
    RETURN jsonb_build_object('status','forbidden'); END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'asset_id', a.id, 'image_url', a.image_url, 'is_primary', a.is_primary,
      'gallery_position', coalesce((a.provenance->>'gallery_position')::int, 999),
      'source_provider', a.source_provider, 'kalodata_product_id', a.source_entity_id,
      'rights_state', a.rights_state, 'authority','REFERENCE_ONLY',
      'cache_state', a.cache_state, 'source_url_expires_at', a.source_url_expires_at,
      'commercial_use','NOT_CLEARED_REFERENCE_ONLY', 'observed_at', a.observed_at)
      ORDER BY a.is_primary DESC, coalesce((a.provenance->>'gallery_position')::int, 999), a.observed_at), '[]'::jsonb)
    INTO v_imgs
  FROM public.product_image_assets a
  WHERE a.product_id=p_product AND a.tenant_id=p_tenant
    AND a.source_provider='KALODATA' AND a.cache_state='CACHED'
    AND coalesce(a.is_fixture,false)=false AND a.availability='AVAILABLE';

  RETURN jsonb_build_object('status','ok','product_id',p_product,
    'cached_count', jsonb_array_length(v_imgs), 'images', v_imgs,
    'authority','REFERENCE_ONLY', 'contract','pulse_kalodata_product_images_cached_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_product_images_cached(uuid,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_product_images_cached(uuid,uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8) Run caller: cache reuse (no credit) -> else reserve -> authorize -> fire.
--    p_force_refresh re-fetches even when cached (rare; our cache is durable so reuse is normally safe).
--    p_dry_run stops after authorize (used by self-tests / no-cost readiness).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_kalodata_run_product_images(
  p_market text, p_product_id uuid, p_kalodata_product_id text, p_idempotency_key text,
  p_anon_key text DEFAULT NULL, p_dry_run boolean DEFAULT false, p_force_refresh boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_owner uuid; v_cached jsonb; v_res jsonb; v_auth jsonb; v_req uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','error','reason','UNAUTHENTICATED'); END IF;
  IF nullif(btrim(coalesce(p_kalodata_product_id,'')),'') IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','MISSING_KALODATA_PRODUCT_ID'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL OR v_owner <> v_uid THEN
    RETURN jsonb_build_object('status','error','reason','PRODUCT_NOT_FOUND_OR_FORBIDDEN'); END IF;

  -- REQUIREMENT 7: reuse the durable cache; no reserve, no provider call, no credit spent.
  IF NOT coalesce(p_force_refresh,false) THEN
    v_cached := public.fn_kalodata_product_images_cached(v_uid, p_product_id);
    IF (v_cached->>'status')='ok' AND (v_cached->>'cached_count')::int > 0 THEN
      RETURN jsonb_build_object('status','ok','stage','cache_reuse','credit_spent',false,
        'cached_count',(v_cached->>'cached_count')::int,'images',v_cached->'images',
        'note','served from durable private-bucket cache; no Kalodata credit consumed');
    END IF;
  END IF;

  v_res := public.fn_kalodata_op_reserve('PRODUCT_IMAGES', p_market, p_idempotency_key, 1);
  IF (v_res->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_res->>'status','stage','reserve','detail',v_res); END IF;
  v_req := (v_res->>'request_id')::uuid;
  v_auth := public.fn_discovery_refresh_authorize(v_req);
  IF (v_auth->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_auth->>'status','stage','authorize','request_id',v_req,'detail',v_auth); END IF;
  IF coalesce(p_dry_run,false) THEN
    RETURN jsonb_build_object('status','ok','stage','authorized_dry_run','request_id',v_req,'note','reserve+authorize ok; fire skipped'); END IF;
  RETURN public.fn_kalodata_op_fire(v_req, p_anon_key, 'kalodata-product-images',
    jsonb_build_object('product_id', p_product_id, 'kalodata_product_id', p_kalodata_product_id));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_run_product_images(text,uuid,text,text,text,boolean,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_run_product_images(text,uuid,text,text,text,boolean,boolean) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9) Self-test: contract, caching, dedup, tenant isolation, expiry, Product Asset Lock,
--    rights-class fail-closed, and the credit-reuse short-circuit. Self-seeding + self-cleaning.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_kalodata_product_images_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_a uuid := 'ca11ab00-0000-4000-8000-0000000000a1';  -- tenant A
  v_b uuid := 'ca11ab00-0000-4000-8000-0000000000b2';  -- tenant B (isolation)
  v_p uuid := 'ca11ab00-0000-4000-8000-0000000000cc';  -- product owned by A
  v_pb uuid := 'ca11ab00-0000-4000-8000-0000000000dd'; -- product owned by B
  url1 text := 'https://nxaunmyihhjixxxljcqt.supabase.co/storage/v1/object/sign/pulse-research-reference/kalodata/a/p/h1.jpg?token=aaa';
  url2 text := 'https://nxaunmyihhjixxxljcqt.supabase.co/storage/v1/object/sign/pulse-research-reference/kalodata/a/p/h2.jpg?token=bbb';
  src1 text := 'https://cdn.kalodata.com/img/one.jpg?e=123&sig=zzz';  -- expiring provider URL
  exp  timestamptz := now() + interval '5 minutes';
  r_req jsonb; r_bad jsonb; r1 jsonb; r1b jsonb; r2 jsonb; r_x jsonb; r_cached jsonb; r_reuse jsonb;
  cls_kd text; rights jsonb; v_cnt int; v_primary_url text;
BEGIN
  -- clean + seed two tenants / products
  DELETE FROM public.product_image_assets WHERE product_id IN (v_p,v_pb);
  DELETE FROM public.commerce_products WHERE id IN (v_p,v_pb);
  INSERT INTO public.commerce_products(id,user_id,title,category) VALUES (v_p,v_a,'SELFTEST images A','gadgets');
  INSERT INTO public.commerce_products(id,user_id,title,category) VALUES (v_pb,v_b,'SELFTEST images B','gadgets');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a::text)::text, true);  -- act as tenant A

  -- 1) CONTRACT: builder returns {product_id} for a supported market, denies unsupported + missing id
  r_req := public.fn_kalodata_images_request('US','1729508370969629931');
  r_bad := public.fn_kalodata_images_request('IE','1729508370969629931');  -- IE present but disabled
  v := v || jsonb_build_object('case','contract_request_builder','pass',
        ((r_req->>'ok')::boolean=true AND r_req->'request_body'->>'product_id'='1729508370969629931'
         AND r_req->>'operation'='tiktok/product/images'
         AND (r_bad->>'ok')::boolean=false AND r_bad->>'reason'='UNSUPPORTED_MARKET'
         AND (public.fn_kalodata_images_request('US',NULL)->>'reason')='MISSING_PRODUCT_ID'));

  -- 2) CACHING: persist a cached research image -> durable row with REFERENCE_ONLY rights + cache metadata
  r1 := public.fn_persist_kalodata_research_image(v_a,v_p,'US','kd_prod_1',0,url1,src1,exp,
          'pulse-research-reference/kalodata/a/p/h1.jpg','hash_one','image/jpeg');
  v := v || jsonb_build_object('case','caching_persist_durable','pass',
        (r1->>'status'='registered' AND (r1->>'is_primary')::boolean=true
         AND EXISTS(SELECT 1 FROM public.product_image_assets WHERE id=(r1->>'asset_id')::uuid
             AND rights_state='PROVIDER_DISCOVERY_REFERENCE' AND source_provider='KALODATA'
             AND cache_state='CACHED' AND content_hash='hash_one' AND image_url=url1 AND source_url=src1
             AND source_url_expires_at=exp AND provenance->>'authority'='REFERENCE_ONLY'
             AND storage_ref='pulse-research-reference/kalodata/a/p/h1.jpg')));

  -- 3) DEDUP: same content_hash again -> no new row, returns existing (credit/storage saving)
  r1b := public.fn_persist_kalodata_research_image(v_a,v_p,'US','kd_prod_1',0,
          'https://nxaunmyihhjixxxljcqt.supabase.co/storage/v1/object/sign/pulse-research-reference/kalodata/a/p/h1b.jpg?token=ccc',
          src1,exp,'pulse-research-reference/kalodata/a/p/h1b.jpg','hash_one','image/jpeg');
  SELECT count(*) INTO v_cnt FROM public.product_image_assets WHERE product_id=v_p AND content_hash='hash_one';
  v := v || jsonb_build_object('case','dedup_content_hash','pass',
        (r1b->>'status'='exists' AND (r1b->>'deduped')::boolean=true AND v_cnt=1
         AND (r1b->>'asset_id')::uuid=(r1->>'asset_id')::uuid));

  -- add a genuine second image (different hash) so the gallery is multi-image
  r2 := public.fn_persist_kalodata_research_image(v_a,v_p,'US','kd_prod_1',1,url2,
          'https://cdn.kalodata.com/img/two.jpg?e=123&sig=yyy',exp,
          'pulse-research-reference/kalodata/a/p/h2.jpg','hash_two','image/jpeg');

  -- 4) TENANT ISOLATION: cannot attach A's product image under tenant B; B cannot read A's gallery
  r_x := public.fn_persist_kalodata_research_image(v_b,v_p,'US','kd_prod_1',2,
          'https://nxaunmyihhjixxxljcqt.supabase.co/storage/v1/object/sign/pulse-research-reference/x/h3.jpg?token=d',
          src1,exp,'pulse-research-reference/x/h3.jpg','hash_three','image/jpeg');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_b::text)::text, true);
  r_cached := public.fn_kalodata_product_images_cached(v_a, v_p);  -- B asking for A's tenant -> forbidden
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a::text)::text, true);
  v := v || jsonb_build_object('case','tenant_isolation','pass',
        (r_x->>'status'='error' AND r_x->>'error'='cross_tenant_rejected'
         AND r_cached->>'status'='forbidden'
         AND NOT EXISTS(SELECT 1 FROM public.product_image_assets WHERE content_hash='hash_three')));

  -- 5) EXPIRY: the provider signed URL is expired, but the durable cached copy stays available
  UPDATE public.product_image_assets SET source_url_expires_at = now() - interval '1 minute'
    WHERE product_id=v_p AND content_hash='hash_one';
  r_cached := public.fn_kalodata_product_images_cached(v_a, v_p);
  SELECT (r_cached->'images'->0->>'image_url') INTO v_primary_url;
  v := v || jsonb_build_object('case','expiry_durable_copy_survives','pass',
        ((r_cached->>'cached_count')::int=2 AND v_primary_url=url1  -- still served from our durable URL
         AND (r_cached->'images'->0->>'authority')='REFERENCE_ONLY'
         AND (r_cached->'images'->0->>'commercial_use')='NOT_CLEARED_REFERENCE_ONLY'));

  -- 6) RIGHTS-CLASS FAIL-CLOSED: PROVIDER_DISCOVERY_REFERENCE -> RESEARCH_REFERENCE_ONLY, still non-publishable
  cls_kd := public.fn_asset_rights_class('PROVIDER_DISCOVERY_REFERENCE','KALODATA','{}'::jsonb);
  v := v || jsonb_build_object('case','rights_class_research_reference_only','pass',
        (cls_kd='RESEARCH_REFERENCE_ONLY'
         AND public.fn_asset_rights_class('MARKETPLACE_PUBLIC_LISTING','EBAY_BROWSE','{}'::jsonb)='RESEARCH_REFERENCE_ONLY'
         -- publishable classes unchanged / fail-closed:
         AND public.fn_asset_rights_class('CUSTOMER_OWNED','CUSTOMER_UPLOAD',jsonb_build_object('rights_confirmed','true'))='CUSTOMER_OWNED'
         AND public.fn_asset_rights_class('SUPPLIER_PROVIDED','CJ_SUPPLIER','{}'::jsonb)='SUPPLIER_AUTHORIZED'));

  -- 7) PRODUCT ASSET LOCK: a product with ONLY Kalodata research images is NOT publishable / NOT AI-eligible
  rights := public.fn_product_commercial_rights(v_p);
  v := v || jsonb_build_object('case','product_asset_lock_non_publishable','pass',
        ((rights->>'publishable_present')::boolean=false
         AND (rights->>'ai_reference_present')::boolean=false
         AND (rights->>'research_only_count')::int >= 2
         AND (rights->>'unknown_count')::int = 0));  -- research images no longer count as "unknown"

  -- 8) CREDIT REUSE: run caller short-circuits to cache_reuse with NO credit spent (no reserve row created)
  r_reuse := public.fn_kalodata_run_product_images('US', v_p, 'kd_prod_1', 'img_idem_1', NULL, false, false);
  v := v || jsonb_build_object('case','credit_reuse_short_circuit','pass',
        (r_reuse->>'stage'='cache_reuse' AND (r_reuse->>'credit_spent')::boolean=false
         AND (r_reuse->>'cached_count')::int=2
         AND NOT EXISTS(SELECT 1 FROM public.discovery_refresh_request WHERE tenant_id=v_a AND idempotency_key='img_idem_1')));

  -- cleanup
  DELETE FROM public.product_image_assets WHERE product_id IN (v_p,v_pb);
  DELETE FROM public.commerce_products WHERE id IN (v_p,v_pb);
  PERFORM set_config('request.jwt.claims','',true);

  RETURN jsonb_build_object('suite','kalodata_product_images',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'note','reuses product_image_assets + PROVIDER_DISCOVERY_REFERENCE rights + credit workflow; durable private-bucket cache; research images never publishable.',
    'results', v);
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.product_image_assets WHERE product_id IN (v_p,v_pb);
  DELETE FROM public.commerce_products WHERE id IN (v_p,v_pb);
  RETURN jsonb_build_object('suite','kalodata_product_images','status','error','error',SQLERRM);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_product_images_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_product_images_selftest() TO service_role;

COMMIT;

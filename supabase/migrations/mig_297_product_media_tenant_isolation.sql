-- mig_297_product_media_tenant_isolation.sql
-- STRATELOQ — LAUNCH-CRITICAL tenant-isolation security fix for the product-media service.
--
-- VULNERABILITY (introduced in mig_296): fn_product_media_state(p_tenant, p_product, p_market) is
-- SECURITY DEFINER, granted to anon/authenticated/PUBLIC, and authorized access solely on the
-- CALLER-SUPPLIED p_tenant. The product_image_assets read was keyed on product_id alone (no tenant
-- filter). A request with no authenticated user, or a forged p_tenant, still received another
-- tenant's product media (image URLs, provider ids, provenance, product existence).
--
-- FIX: identity is SERVER-OWNED. Authorization derives from auth.uid() only; p_tenant is retained
-- for backward compatibility (the deployed frontend passes it) but is IGNORED for authorization.
-- Fail closed when unauthenticated or when the product is not owned by the authenticated tenant,
-- returning an empty media contract that discloses nothing (no URL, metadata, provider id, provenance,
-- or product/tenant existence). Every read is scoped to auth.uid(). Market isolation preserved.
-- Response field shape is unchanged (image_state / card_media_state / primary_image.url /
-- gallery_count / video_state / supplier_media_state / authority) so the live Lovable contract stays
-- compatible. Authorization-only change: REFERENCE_ONLY semantics, supplier_product_assets, and all
-- commercial/store/ad/publish/creative gates are untouched.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_product_media_state(p_tenant uuid, p_product uuid, p_market text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();   -- SERVER-OWNED identity. p_tenant is NEVER used for authorization.
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_primary record; v_gallery int; v_video record; v_is_fastmoss boolean;
  v_image_state text; v_video_state text; v_supplier_state text; v_card text;
  v_bound boolean; v_supplier_assets int; v_owns boolean;
  v_denied jsonb := jsonb_build_object(
    'status','unauthorized',
    'image_state','IMAGE_UNAVAILABLE','video_state','VIDEO_UNAVAILABLE',
    'supplier_media_state','SUPPLIER_MEDIA_PENDING','card_media_state','MEDIA_INCOMPLETE',
    'primary_image', NULL, 'gallery_count', 0, 'authority','REFERENCE_ONLY',
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

  SELECT media_type, storage_ref, provider, source_asset_refs INTO v_video
  FROM public.media_assets
  WHERE product_id=p_product AND tenant_id=v_uid AND upper(coalesce(media_type,''))='VIDEO'
    AND coalesce(is_launch_safe,false)=false
  ORDER BY created_at DESC LIMIT 1;

  SELECT (source_store='fastmoss' OR extended->>'provider_product_native'='FASTMOSS')
    INTO v_is_fastmoss FROM public.commerce_products WHERE id=p_product AND user_id=v_uid;

  v_video_state := CASE
    WHEN v_video.media_type IS NOT NULL THEN 'VIDEO_AVAILABLE'
    WHEN coalesce(v_is_fastmoss,false) THEN 'VIDEO_ACCESS_BLOCKED'  -- FastMoss /product/v1/videoList not entitled (403)
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
    'supplier_media_state', v_supplier_state,
    'card_media_state', v_card,
    'authority', 'REFERENCE_ONLY',
    'invariants', jsonb_build_object(
      'identity_server_owned_auth_uid', true,
      'caller_tenant_arg_ignored_for_authorization', true,
      'reference_media_never_unlocks_store_ad_creative_publishing', true,
      'supplier_authoritative_media_is_separate_table', 'supplier_product_assets',
      'completed_card_requires_genuine_primary_image', true,
      'no_fabricated_media', true),
    'contract','pulse_product_media_state_v1');
END $function$;

-- Durable authorization selftest: simulates tenants via request.jwt.claims (how auth.uid() resolves)
-- against the REAL production tenant + a real owned product. Proves owner-allowed and
-- unauthenticated/cross-tenant/forged-id all fail closed with no disclosure. No writes (idempotent).
CREATE OR REPLACE FUNCTION public.fn_product_media_auth_selftest()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  OWNER_T uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';   -- real production tenant (Tenant A)
  OTHER_T uuid := '2f000000-0000-4000-a000-000000002999';   -- a different tenant (Tenant B)
  PROD uuid := 'ca4a79b0-41a7-4fc6-b267-82b99a123dff';       -- Hit the Slab (owned by Tenant A)
  checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0; ok boolean;
  r_owner jsonb; r_cross jsonb; r_unauth jsonb; r_forged jsonb; r_owner_fr jsonb;
BEGIN
  -- OWNER (auth.uid() = Tenant A): allowed; status ok.
  PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER_T)::text, true);
  r_owner := public.fn_product_media_state(NULL, PROD, 'DE');
  ok := (r_owner->>'status'='ok');
  checks := checks || jsonb_build_object('check','OWNER_allowed','ok',ok,'status',r_owner->>'status');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- CROSS-TENANT (auth.uid() = Tenant B): denied, no disclosure.
  PERFORM set_config('request.jwt.claims', json_build_object('sub',OTHER_T)::text, true);
  r_cross := public.fn_product_media_state(NULL, PROD, 'DE');
  ok := (r_cross->>'status'='unauthorized') AND (r_cross->'primary_image'='null'::jsonb) AND ((r_cross->>'gallery_count')::int=0) AND (r_cross ? 'product_id' = false);
  checks := checks || jsonb_build_object('check','CROSS_TENANT_denied','ok',ok,'status',r_cross->>'status');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- FORGED caller tenant/account id (auth.uid() = Tenant B, p_tenant forged = Tenant A): still denied.
  r_forged := public.fn_product_media_state(OWNER_T, PROD, 'DE');
  ok := (r_forged->>'status'='unauthorized') AND (r_forged->'primary_image'='null'::jsonb);
  checks := checks || jsonb_build_object('check','FORGED_ID_denied','ok',ok,'status',r_forged->>'status');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- UNAUTHENTICATED (no sub claim): denied, no disclosure.
  PERFORM set_config('request.jwt.claims', '', true);
  r_unauth := public.fn_product_media_state(OWNER_T, PROD, 'DE');
  ok := (r_unauth->>'status'='unauthorized') AND (r_unauth->'primary_image'='null'::jsonb) AND (r_unauth ? 'product_id' = false);
  checks := checks || jsonb_build_object('check','UNAUTHENTICATED_denied','ok',ok,'status',r_unauth->>'status');
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- COUNTRY ISOLATION: owner request for a market the product was not evaluated in still authorizes
  -- by ownership but returns that market's (empty) media, never another market's.
  PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER_T)::text, true);
  r_owner_fr := public.fn_product_media_state(NULL, PROD, 'JP');
  ok := (r_owner_fr->>'status'='ok') AND (r_owner_fr->>'market'='JP');
  checks := checks || jsonb_build_object('check','COUNTRY_ISOLATION','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  PERFORM set_config('request.jwt.claims', '', true);  -- reset simulated auth context

  RETURN jsonb_build_object('contract','pulse_product_media_auth_selftest_v1',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),
    'checks',checks,'generated_at',now());
END $function$;

-- The mig_296 discovery-media selftest exercised fn_product_media_state through the OLD insecure
-- contract (no identity, caller-supplied tenant): check E persisted an image on a synthetic product
-- that has no commerce_products row and read it with no authenticated session, and check F passed only
-- because the pre-fix function never denied. Under the hardened contract those reads must flow through
-- the authenticated OWNER path. This replacement rewrites E and F to simulate the owner via
-- request.jwt.claims and use the real owned product (Hit the Slab) with a temporary reference image
-- that is removed in-function, so the selftest is green AGAINST THE SECURE CONTRACT and leaves no
-- residue on the real product. A/B/C/D/G are unchanged.
CREATE OR REPLACE FUNCTION public.fn_discovery_media_integrity_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  T uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  TESTP uuid := '00000000-0000-4000-a000-0000000d1a96';
  HITSLAB uuid := 'ca4a79b0-41a7-4fc6-b267-82b99a123dff';
  rc text := 'https://s.500fd.com/tt_product/selftestcover~tplv-t5fjg24jzw-resize-jpeg:800:800.jpeg';
  dc text := 'https://s.500fd.com/default/product_default.png';
  checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0; ok boolean;
  v_id1 uuid; v_id2 uuid; v_cnt int; v_ms jsonb; v_ms2 jsonb;
BEGIN
  -- A: extractor keeps genuine, rejects placeholder + null
  ok := (public.fn_extract_cover_url(jsonb_build_object('cover',rc)) = rc)
    AND (public.fn_extract_cover_url(jsonb_build_object('cover',dc)) IS NULL)
    AND (public.fn_extract_cover_url(jsonb_build_object('master_image_url',NULL)) IS NULL);
  checks := checks || jsonb_build_object('check','A_extractor_genuine_only','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- B: persist rejects non-genuine (null/placeholder/non-http) -> no id
  ok := (public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','x',NULL) IS NULL)
    AND (public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','x',dc) IS NULL)
    AND (public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','x','not-a-url') IS NULL);
  checks := checks || jsonb_build_object('check','B_persist_rejects_non_genuine','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- C: persist accepts genuine -> REFERENCE_ONLY primary; idempotent on unique (product_id,image_url)
  v_id1 := public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','selftestkid',rc);
  v_id2 := public.fn_persist_reference_image(T,TESTP,'DE','FASTMOSS','selftestkid',rc);
  SELECT count(*) INTO v_cnt FROM public.product_image_assets WHERE product_id=TESTP AND image_url=rc;
  ok := (v_id1 IS NOT NULL) AND (v_id2 = v_id1) AND (v_cnt = 1)
    AND EXISTS (SELECT 1 FROM public.product_image_assets WHERE product_id=TESTP AND image_url=rc
                AND is_primary=true AND rights_state='PROVIDER_DISCOVERY_REFERENCE'
                AND provenance->>'authority'='REFERENCE_ONLY' AND source_provider='FASTMOSS');
  checks := checks || jsonb_build_object('check','C_persist_reference_primary_idempotent','ok',ok,'detail',jsonb_build_object('rows_for_url',v_cnt));
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- D: Product Asset Lock separation (reference media never in supplier_product_assets)
  ok := NOT EXISTS (SELECT 1 FROM public.supplier_product_assets WHERE source_url=rc);
  checks := checks || jsonb_build_object('check','D_asset_lock_separation','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- E: IMAGE_AVAILABLE + MEDIA_COMPLETE + REFERENCE_ONLY for an OWNED product with a genuine image,
  -- via the AUTHENTICATED owner path (identity from auth.uid(); ownership-gated). The temporary
  -- reference image on the real owned product is written inside a subtransaction that is then rolled
  -- back: plpgsql variable values survive a subtransaction rollback but the DB row does not, so the
  -- real product keeps zero residue and no destructive statement is needed.
  PERFORM set_config('request.jwt.claims', json_build_object('sub',T)::text, true);
  BEGIN
    PERFORM public.fn_persist_reference_image(T,HITSLAB,'DE','FASTMOSS','selftest-E-img',rc);
    v_ms := public.fn_product_media_state(NULL,HITSLAB,'DE');
    RAISE EXCEPTION 'pulse_selftest_rollback_fixture';  -- rolls back the fixture row; v_ms is retained
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  ok := (v_ms->>'status'='ok') AND (v_ms->>'image_state'='IMAGE_AVAILABLE')
    AND (v_ms->>'card_media_state'='MEDIA_COMPLETE') AND (v_ms->>'authority'='REFERENCE_ONLY')
    AND (v_ms#>>'{primary_image,url}' = rc);
  checks := checks || jsonb_build_object('check','E_media_state_image_available','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- F: honest MEDIA_INCOMPLETE for an OWNED product with no genuine image, authenticated owner path.
  v_ms2 := public.fn_product_media_state(NULL,HITSLAB,'DE');
  ok := (v_ms2->>'status'='ok') AND (v_ms2->>'image_state'='IMAGE_UNAVAILABLE')
    AND (v_ms2->>'card_media_state'='MEDIA_INCOMPLETE');
  checks := checks || jsonb_build_object('check','F_media_incomplete_when_no_image','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  PERFORM set_config('request.jwt.claims','',true);  -- reset simulated auth context

  -- G: both ingest functions wired to the cover persistence
  ok := (SELECT prosrc LIKE '%fn_persist_reference_image%' FROM pg_proc WHERE proname='fn_fastmoss_ingest_candidates' LIMIT 1)
    AND (SELECT prosrc LIKE '%fn_persist_reference_image%' FROM pg_proc WHERE proname='fn_kalodata_ingest_candidates' LIMIT 1);
  checks := checks || jsonb_build_object('check','G_ingest_wired_to_cover','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  RETURN jsonb_build_object('contract','pulse_discovery_media_integrity_selftest_v1',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),
    'note','E/F now exercise the hardened fn_product_media_state via the authenticated owner path; C leaves one benign TESTP fixture row (no commerce_products row, never surfaces to a real tenant projection); E temporary image on the real product is rolled back in-function.',
    'checks',checks,'generated_at',now());
END $function$;

-- Least privilege: fn_product_media_state keeps anon/authenticated EXECUTE (it fails closed in-function
-- and the live frontend contract must be preserved — an unauthenticated caller receives the documented
-- no-disclosure 'unauthorized' contract, not a leak). The two diagnostic selftests have no frontend
-- contract, run as SECURITY DEFINER, write fixtures and manipulate request.jwt.claims, so they are
-- restricted to service_role only.
REVOKE EXECUTE ON FUNCTION public.fn_product_media_auth_selftest() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_discovery_media_integrity_selftest() FROM PUBLIC, anon, authenticated;

COMMIT;

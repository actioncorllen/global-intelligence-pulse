-- ============================================================================
-- mig_347_website_asset_capture.sql
-- STRATELOQ-WEBSITE-ASSET-CAPTURE-001
--
-- Registration + approval contract for REAL public-website screenshots captured
-- by the reusable Website Asset Capture worker (services/website-asset-capture).
--
-- Reuses existing infrastructure — NO new media library:
--   * media_assets               (stores the capture as source_type=WEBSITE_CAPTURE)
--   * creative_brand_assets       (Brand Asset Lock: asset_class=UI_SCREENSHOT, PENDING)
--   * fn_ci_brand_asset_put        (existing Brand Asset Lock writer)
--   * pulse-generated-media bucket (private; storage_ref only)
--
-- Invariants:
--   * A capture is NEVER authoritative on registration (authoritative=false, PENDING).
--   * Founder approval is required to flip authoritative=true / APPROVED.
--   * Strict domain allowlist (defense-in-depth; the worker also enforces SSRF).
--   * Idempotent on (tenant_id, asset_hash) for WEBSITE_CAPTURE — a changed page
--     produces a new hash => a new version row; historical rows are never overwritten.
--   * Does NOT touch Growth Agent, Product Asset Lock, social publishing, the paid
--     lane, or the Monday research schedule.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Idempotency: one WEBSITE_CAPTURE media_asset per (tenant, image hash).
-- Identical bytes = identical capture => dedupe. Different viewport / full-page /
-- changed page => different bytes => different hash => a new version row.
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_media_assets_website_capture_hash
  ON public.media_assets (tenant_id, (provenance->>'asset_hash'))
  WHERE source_type = 'WEBSITE_CAPTURE' AND provenance ? 'asset_hash';

-- ---------------------------------------------------------------------------
-- Domain allowlist (defense-in-depth). Only the approved public Pulse domain.
-- Rejects non-https schemes (file:/data:/javascript:/http:), userinfo spoofs,
-- subdomain/suffix spoofs, private IPs, localhost and metadata hosts — none of
-- which equal an allowlisted host.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn__wac_host_allowed(p_url text)
 RETURNS boolean LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_host text;
BEGIN
  IF p_url IS NULL THEN RETURN false; END IF;
  -- host is only extracted when the scheme is exactly https://
  v_host := lower(substring(p_url from '^https://([^/:?#]+)'));
  IF v_host IS NULL THEN RETURN false; END IF;
  RETURN v_host IN ('globalintelligenceactions.com', 'www.globalintelligenceactions.com');
END; $function$;
REVOKE ALL ON FUNCTION public.fn__wac_host_allowed(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn__wac_host_allowed(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Register a capture: media_assets row + Brand Asset Lock row (UI_SCREENSHOT,
-- authoritative=false, approval_state=PENDING). Idempotent on (tenant, hash).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_website_capture_register(
  p_tenant       uuid,
  p_source_url   text,
  p_canonical_url text,
  p_route        text,
  p_capture_type text,          -- VIEWPORT | FULL_PAGE | ELEMENT
  p_viewport_w   int,
  p_viewport_h   int,
  p_storage_ref  text,          -- pulse-generated-media/website-captures/<tenant>/<date>/<hash>.png
  p_width        int,
  p_height       int,
  p_mime         text,          -- image/png
  p_asset_hash   text,          -- sha256 of the PNG bytes
  p_provenance   jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_media uuid; v_brand jsonb; v_prov jsonb; v_existing uuid;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','tenant_required'); END IF;
  IF NOT public.fn__wac_host_allowed(p_source_url) THEN
    RETURN jsonb_build_object('ok',false,'error','domain_not_allowed','source_url',p_source_url);
  END IF;
  IF p_capture_type NOT IN ('VIEWPORT','FULL_PAGE','ELEMENT') THEN
    RETURN jsonb_build_object('ok',false,'error','bad_capture_type','capture_type',p_capture_type);
  END IF;
  IF coalesce(p_viewport_w,0) <= 0 OR coalesce(p_viewport_h,0) <= 0 THEN
    RETURN jsonb_build_object('ok',false,'error','bad_viewport');
  END IF;
  IF coalesce(p_asset_hash,'') = '' THEN
    RETURN jsonb_build_object('ok',false,'error','asset_hash_required');
  END IF;
  IF coalesce(p_mime,'') <> 'image/png' THEN
    RETURN jsonb_build_object('ok',false,'error','mime_must_be_png');
  END IF;

  -- Idempotency: identical bytes for this tenant => return the existing registration.
  SELECT id INTO v_existing FROM public.media_assets
   WHERE tenant_id = p_tenant AND source_type = 'WEBSITE_CAPTURE'
     AND provenance->>'asset_hash' = p_asset_hash
   LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok',true,'deduped',true,'media_asset_id',v_existing,
      'note','identical capture already registered (idempotent)');
  END IF;

  -- Canonical, secret-free provenance (never store tokens/cookies/passwords).
  v_prov := coalesce(p_provenance,'{}'::jsonb) || jsonb_build_object(
    'tenant_id',        p_tenant,
    'source_url',       p_source_url,
    'canonical_url',    p_canonical_url,
    'route',            p_route,
    'domain',           lower(substring(p_source_url from '^https://([^/:?#]+)')),
    'capture_type',     p_capture_type,
    'capture_method',   coalesce(p_provenance->>'capture_method','playwright_chromium_headless'),
    'viewport_width',   p_viewport_w,
    'viewport_height',  p_viewport_h,
    'width',            p_width,
    'height',           p_height,
    'mime_type',        p_mime,
    'asset_hash',       p_asset_hash
  );

  INSERT INTO public.media_assets(
     tenant_id, media_type, mime_type, source_type, storage_ref,
     width, height, rights_state, generation_status, approval_state,
     identity_state, is_launch_safe, provenance)
  VALUES (
     p_tenant, 'IMAGE', p_mime, 'WEBSITE_CAPTURE', p_storage_ref,
     p_width, p_height, 'FIRST_PARTY_OWNED', 'CAPTURED', 'DRAFT',
     'NOT_APPLICABLE', false, v_prov)
  RETURNING id INTO v_media;

  -- Brand Asset Lock row via the EXISTING writer: UI_SCREENSHOT, non-authoritative => PENDING.
  v_brand := public.fn_ci_brand_asset_put(
     p_tenant, 'UI_SCREENSHOT', NULL, NULL, v_media, false, v_prov);

  RETURN jsonb_build_object('ok',true,'deduped',false,
    'media_asset_id', v_media,
    'brand_asset_id', v_brand->>'brand_asset_id',
    'asset_class','UI_SCREENSHOT',
    'authoritative', false,
    'approval_state','PENDING',
    'capture_type', p_capture_type,
    'storage_ref', p_storage_ref);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_website_capture_register(uuid,text,text,text,text,int,int,text,int,int,text,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_website_capture_register(uuid,text,text,text,text,int,int,text,int,int,text,text,jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- Founder approval: flip a PENDING UI_SCREENSHOT capture to APPROVED/authoritative
-- or REJECTED. Never auto-approves. Tenant-scoped.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_website_capture_set_approval(
  p_tenant uuid, p_brand_asset_id uuid, p_decision text
) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_media uuid; v_auth boolean; v_state text;
BEGIN
  IF p_decision NOT IN ('APPROVE','REJECT') THEN
    RETURN jsonb_build_object('ok',false,'error','bad_decision');
  END IF;
  v_auth  := (p_decision = 'APPROVE');
  v_state := CASE WHEN v_auth THEN 'APPROVED' ELSE 'REJECTED' END;

  UPDATE public.creative_brand_assets
     SET authoritative = v_auth, approval_state = v_state
   WHERE id = p_brand_asset_id AND tenant_id = p_tenant AND asset_class = 'UI_SCREENSHOT'
  RETURNING media_asset_id INTO v_media;

  IF v_media IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','not_found_or_wrong_tenant');
  END IF;

  UPDATE public.media_assets
     SET approval_state = v_state, is_launch_safe = v_auth, updated_at = now()
   WHERE id = v_media AND tenant_id = p_tenant;

  RETURN jsonb_build_object('ok',true,'brand_asset_id',p_brand_asset_id,'media_asset_id',v_media,
    'authoritative',v_auth,'approval_state',v_state);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_website_capture_set_approval(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_website_capture_set_approval(uuid,uuid,text) TO service_role;

-- ---------------------------------------------------------------------------
-- Self-test (rolled back). Proves the registration/approval contract + security.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_website_capture_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  c_tenant uuid := '5351ad83-5ce8-47b1-aef6-23f64daf415f';
  c_other  uuid := '95bb5658-5182-43af-add0-3d2ebc93393f';
  r1 jsonb; r2 jsonb; r3 jsonb; rbad jsonb; rapp jsonb; rrej jsonb;
  v_brand uuid; v_media uuid; v_auth boolean; v_state text; v_pre jsonb; v_asset uuid; v_cnt int;
  u text := 'https://www.globalintelligenceactions.com/';
BEGIN
  BEGIN
    -- 1. domain allowlist: good vs bad
    v := v || jsonb_build_object('case','allow_good_domain','pass', public.fn__wac_host_allowed('https://www.globalintelligenceactions.com/'));
    v := v || jsonb_build_object('case','reject_external_domain','pass', NOT public.fn__wac_host_allowed('https://evil.example.com/'));
    v := v || jsonb_build_object('case','reject_subdomain_suffix_spoof','pass', NOT public.fn__wac_host_allowed('https://www.globalintelligenceactions.com.evil.com/'));
    v := v || jsonb_build_object('case','reject_userinfo_spoof','pass', NOT public.fn__wac_host_allowed('https://www.globalintelligenceactions.com@evil.com/'));
    v := v || jsonb_build_object('case','reject_private_ip','pass', NOT public.fn__wac_host_allowed('https://169.254.169.254/'));
    v := v || jsonb_build_object('case','reject_localhost','pass', NOT public.fn__wac_host_allowed('https://localhost/'));
    v := v || jsonb_build_object('case','reject_file_scheme','pass', NOT public.fn__wac_host_allowed('file:///etc/passwd'));
    v := v || jsonb_build_object('case','reject_data_scheme','pass', NOT public.fn__wac_host_allowed('data:text/html,<h1>x</h1>'));
    v := v || jsonb_build_object('case','reject_javascript_scheme','pass', NOT public.fn__wac_host_allowed('javascript:alert(1)'));
    v := v || jsonb_build_object('case','reject_plain_http','pass', NOT public.fn__wac_host_allowed('http://www.globalintelligenceactions.com/'));

    -- 2. register a desktop viewport capture -> PENDING, non-authoritative
    r1 := public.fn_website_capture_register(c_tenant, u, u, '/', 'VIEWPORT', 1440,1200,
      'pulse-generated-media/website-captures/'||c_tenant||'/2026-10-05/hashAAA.png', 1440,1200,'image/png','hashAAA',
      jsonb_build_object('page_title','Pulse'));
    v := v || jsonb_build_object('case','register_ok','pass',(r1->>'ok')='true');
    v := v || jsonb_build_object('case','register_pending_non_authoritative','pass',(r1->>'approval_state')='PENDING' AND (r1->>'authoritative')='false');
    v_brand := (r1->>'brand_asset_id')::uuid; v_media := (r1->>'media_asset_id')::uuid;

    -- media_assets row shaped correctly
    SELECT media_type, source_type INTO v_state, u FROM public.media_assets WHERE id=v_media;  -- reuse vars
    v := v || jsonb_build_object('case','media_asset_image_website_capture','pass',
      EXISTS(SELECT 1 FROM public.media_assets WHERE id=v_media AND media_type='IMAGE' AND source_type='WEBSITE_CAPTURE' AND mime_type='image/png'));
    u := 'https://www.globalintelligenceactions.com/';

    -- brand asset PENDING + UI_SCREENSHOT + not authoritative
    v := v || jsonb_build_object('case','brand_asset_ui_screenshot_pending','pass',
      EXISTS(SELECT 1 FROM public.creative_brand_assets WHERE id=v_brand AND asset_class='UI_SCREENSHOT' AND authoritative=false AND approval_state='PENDING' AND media_asset_id=v_media));

    -- 3. idempotency: same hash -> deduped, no second media row
    r2 := public.fn_website_capture_register(c_tenant, u, u, '/', 'VIEWPORT', 1440,1200,
      'pulse-generated-media/website-captures/'||c_tenant||'/2026-10-05/hashAAA.png', 1440,1200,'image/png','hashAAA','{}'::jsonb);
    v := v || jsonb_build_object('case','idempotent_dedupe_same_hash','pass',(r2->>'deduped')='true' AND (r2->>'media_asset_id')=(r1->>'media_asset_id'));
    SELECT count(*) INTO v_cnt FROM public.media_assets WHERE tenant_id=c_tenant AND source_type='WEBSITE_CAPTURE' AND provenance->>'asset_hash'='hashAAA';
    v := v || jsonb_build_object('case','idempotent_no_duplicate_row','pass', v_cnt=1);

    -- 4. changed page -> new hash -> new version row (not overwrite)
    r3 := public.fn_website_capture_register(c_tenant, u, u, '/', 'FULL_PAGE', 1440,1200,
      'pulse-generated-media/website-captures/'||c_tenant||'/2026-10-05/hashBBB.png', 1440,5200,'image/png','hashBBB','{}'::jsonb);
    v := v || jsonb_build_object('case','new_hash_new_version','pass',(r3->>'deduped')='false' AND (r3->>'media_asset_id')<>(r1->>'media_asset_id'));

    -- 5. register rejects bad domain / bad type
    rbad := public.fn_website_capture_register(c_tenant, 'https://evil.example.com/', 'x','/','VIEWPORT',1440,1200,'x',10,10,'image/png','hashX','{}'::jsonb);
    v := v || jsonb_build_object('case','register_rejects_bad_domain','pass',(rbad->>'ok')='false' AND (rbad->>'error')='domain_not_allowed');
    rbad := public.fn_website_capture_register(c_tenant, u, u,'/','PANORAMA',1440,1200,'x',10,10,'image/png','hashY','{}'::jsonb);
    v := v || jsonb_build_object('case','register_rejects_bad_type','pass',(rbad->>'ok')='false' AND (rbad->>'error')='bad_capture_type');

    -- 6. approval flips; no auto-approve (still PENDING before approval)
    v := v || jsonb_build_object('case','no_auto_approve','pass',
      EXISTS(SELECT 1 FROM public.creative_brand_assets WHERE id=v_brand AND approval_state='PENDING' AND authoritative=false));
    rapp := public.fn_website_capture_set_approval(c_tenant, v_brand, 'APPROVE');
    v := v || jsonb_build_object('case','approve_flips_authoritative','pass',(rapp->>'ok')='true' AND (rapp->>'authoritative')='true' AND (rapp->>'approval_state')='APPROVED'
      AND EXISTS(SELECT 1 FROM public.creative_brand_assets WHERE id=v_brand AND authoritative=true AND approval_state='APPROVED'));
    rrej := public.fn_website_capture_set_approval(c_tenant, v_brand, 'REJECT');
    v := v || jsonb_build_object('case','reject_flips_back','pass',(rrej->>'authoritative')='false' AND (rrej->>'approval_state')='REJECTED');

    -- 7. cross-tenant approval rejected
    rrej := public.fn_website_capture_set_approval(c_other, v_brand, 'APPROVE');
    v := v || jsonb_build_object('case','cross_tenant_approval_rejected','pass',(rrej->>'ok')='false');

    -- 8. tenant isolation on read: the SELECT-own RLS policy is present on
    -- creative_brand_assets, scoped to authenticated and keyed to fn__own_tenant()
    -- (role-switching cannot run inside a SECURITY DEFINER function, so the policy
    -- is asserted structurally; the function-layer cross-tenant block is tested above).
    v := v || jsonb_build_object('case','rls_select_own_policy_present','pass',
      EXISTS(SELECT 1 FROM pg_catalog.pg_policies
               WHERE schemaname='public' AND tablename='creative_brand_assets'
                 AND cmd='SELECT' AND 'authenticated' = ANY(roles)
                 AND qual ILIKE '%fn__own_tenant()%'));

    -- 9. no secrets in provenance
    v := v || jsonb_build_object('case','no_secrets_in_provenance','pass',
      NOT EXISTS(SELECT 1 FROM public.media_assets WHERE id=v_media AND (provenance::text ~* 'password|cookie|authorization|bearer|secret|token')));

    -- 10. Product Asset Lock regression intact (unchanged machine gates)
    SELECT id INTO v_asset FROM public.media_assets WHERE tenant_id=c_tenant AND media_type='IMAGE' AND source_type <> 'WEBSITE_CAPTURE' LIMIT 1;
    IF v_asset IS NOT NULL THEN
      v_pre := public.fn_creative_quality_review('IMAGE_ASSET', v_asset);
      v := v || jsonb_build_object('case','product_asset_lock_regression_intact','pass',(v_pre->>'status')='ok' AND (v_pre->>'launch_safe')='false');
    ELSE
      v := v || jsonb_build_object('case','product_asset_lock_regression_intact','pass',true,'note','no product image asset present to probe');
    END IF;

    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN v := v || jsonb_build_object('case','UNEXPECTED_ERROR','pass',false,'err',SQLERRM); END IF;
  END;

  RETURN jsonb_build_object('suite','website_asset_capture',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_website_capture_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_website_capture_selftest() TO postgres, service_role;

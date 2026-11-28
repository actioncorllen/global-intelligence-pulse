-- mig_382 — BE346 Ad Creative Studio FOUNDER-ONLY enforcement (prepared, NOT applied).
-- DIRECTIVE: the entire Ad Creative Studio stays founder-only until the founder
-- explicitly authorises subscriber access. Enforce server-side (RPCs + edges + storage +
-- job execution), not merely by hiding frontend buttons. Reuse the EXISTING authoritative
-- founder check (fn_is_founder / founder_principals); do not invent a new role system.
--
-- ALREADY founder-gated (verified, unchanged here): store creation + management
-- (fn_create_free_store, fn_store_*, fn_storefront_*), advertising campaigns
-- (fn_cb_build_campaign, fn_creative_campaign_handoff, approve_marketing_campaign_draft),
-- and ad-studio creative (fn_creative_studio_generate, fn_creative_production_request,
-- fn_ad_product_card_select_creative_asset). This migration closes the remaining CS.05
-- image/concept/video + generated-asset + import-for-creative gaps.
--
-- KEPT OPEN to appropriately-entitled subscribers (NOT touched): Product Discovery,
-- product research, Save, Compare, Monitoring, and CS.02 media discovery/verification.
--
-- STORAGE: the pulse-generated-media bucket is PRIVATE with no permissive policy, so
-- subscribers already cannot read it directly; generated-asset URLs are edge-minted
-- (service role) only to founders via the gated generation edges. (An explicit
-- founder-only storage.objects SELECT policy is a safe deploy-time hardening; it is not
-- added here to avoid shipping storage RLS that cannot be exercised on a throwaway DB.)
--
-- Preserves Product Asset Lock, commercial permissions and budget approval. Additive +
-- reversible (CREATE OR REPLACE back to the pre-BE346 bodies). NOT APPLIED TO PRODUCTION.

-- ============================================================================
-- 1) Canonical edge-side founder check (explicit uid; no service-role bypass).
--    fn_is_founder() returns TRUE for service_role (auth.uid() NULL, role<>'anon'),
--    so an edge calling it via service role would ALWAYS pass. Edges must instead
--    check the RESOLVED signed-in user with this uid-keyed check.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_is_founder_uid(p_auth_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT p_auth_user_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.founder_principals fp
    WHERE fp.auth_user_id = p_auth_user_id AND fp.active);
$function$;

GRANT EXECUTE ON FUNCTION public.fn_is_founder_uid(uuid) TO service_role;

-- ============================================================================
-- 2) Founder-gate the generated-asset READ path (user-JWT RPC).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_generated_assets(p_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_owner uuid;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  -- BE346: the Ad Creative Studio (generated creative assets) is founder-only.
  IF NOT public.fn_is_founder() THEN
    RETURN jsonb_build_object('ok',false,'error','founder_only',
      'message','The Ad Creative Studio is available to the founder only.'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_owner <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  RETURN jsonb_build_object('ok',true,'product_id',p_product_id,
    'generated_assets', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'generated_asset_id', id, 'generation_provider', generation_provider, 'generation_model', generation_model,
        'reference_provider', reference_provider, 'reference_rights_state', reference_rights_state,
        'identity_validation_status', identity_validation_status,
        'commercial_asset_status', commercial_asset_status, 'selected', selected,
        'storage_bucket', storage_bucket, 'storage_ref', storage_ref,
        'created_at', created_at) ORDER BY created_at DESC)
      FROM public.commerce_generated_assets WHERE product_id=p_product_id AND tenant_id=v_tenant),'[]'::jsonb));
END; $function$;

-- ============================================================================
-- 3) Founder-gate the generated-asset SELECT/USE path (user-JWT RPC).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_commercial_generated_asset_use(p_generated_asset_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); ga record;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  -- BE346: selecting/using a generated creative asset is founder-only.
  IF NOT public.fn_is_founder() THEN
    RETURN jsonb_build_object('ok',false,'error','founder_only',
      'message','The Ad Creative Studio is available to the founder only.'); END IF;
  SELECT * INTO ga FROM public.commerce_generated_assets WHERE id=p_generated_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','generated_asset_not_found'); END IF;
  IF ga.tenant_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  IF coalesce((ga.provenance->>'rights_quarantine_active'),'false')='true'
     OR ga.commercial_asset_status='QUARANTINED_RIGHTS_UNVERIFIED' THEN
    RETURN jsonb_build_object('ok',false,'error','rights_quarantined',
      'message','This generated image is quarantined pending verified commercial/AI-input rights for its reference image.');
  END IF;
  IF ga.identity_validation_status <> 'IDENTITY_VALIDATED' THEN
    RETURN jsonb_build_object('ok',false,'error','not_identity_validated',
      'identity_validation_status', ga.identity_validation_status,
      'message','Only an identity-validated generated image can be selected.');
  END IF;
  UPDATE public.commerce_generated_assets SET selected=false, updated_at=now()
    WHERE product_id=ga.product_id AND tenant_id=v_tenant AND id<>p_generated_asset_id AND selected;
  UPDATE public.commerce_generated_assets
    SET selected=true, selected_at=now(), commercial_asset_status='GENERATED_VALIDATED', updated_at=now()
    WHERE id=p_generated_asset_id;
  RETURN jsonb_build_object('ok',true,'status','SELECTED','generated_asset_id',p_generated_asset_id,
    'product_id', ga.product_id, 'selected', true, 'auto_published', false,
    'note','Selected as this product''s commercial image candidate. Publishing still runs through the normal review/publish gates; nothing is auto-published, and the original supplier/reference asset is unchanged.');
END; $function$;

-- ============================================================================
-- 4) Founder-gate product-image import FOR CREATIVE GENERATION (service-role RPC,
--    takes p_tenant explicitly -> check the tenant, not auth.uid()/service role).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_image_import_register(p_tenant uuid, p_product_id uuid, p_storage_ref text, p_display_url text, p_mime text, p_market text DEFAULT NULL::text, p_rights_confirmed boolean DEFAULT false, p_original_filename text DEFAULT NULL::text, p_byte_size bigint DEFAULT NULL::bigint, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_asset uuid; v_has_primary boolean; v_prov jsonb;
  v_market text := nullif(btrim(coalesce(p_market,'')),'');
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('status','error','error','unauthenticated'); END IF;
  -- BE346: product-image import for creative generation is founder-only.
  IF NOT public.fn_is_founder_uid(p_tenant) THEN
    RETURN jsonb_build_object('status','error','error','founder_only',
      'message','Importing a product image for the Ad Creative Studio is available to the founder only.'); END IF;
  IF p_product_id IS NULL OR coalesce(btrim(p_storage_ref),'')='' OR coalesce(btrim(p_display_url),'')='' THEN
    RETURN jsonb_build_object('status','error','error','missing_inputs'); END IF;
  IF coalesce(p_rights_confirmed,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('status','error','error','rights_confirmation_required'); END IF;
  IF lower(coalesce(p_mime,'')) NOT IN ('image/png','image/jpeg','image/webp') THEN
    RETURN jsonb_build_object('status','error','error','unsupported_mime','mime',p_mime); END IF;
  IF p_byte_size IS NOT NULL AND (p_byte_size <= 0 OR p_byte_size > 15728640) THEN
    RETURN jsonb_build_object('status','error','error','invalid_file_size'); END IF;

  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','error','error','product_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('status','error','error','cross_tenant_rejected'); END IF;

  SELECT id INTO v_asset FROM public.product_image_assets
    WHERE product_id=p_product_id AND provenance->>'storage_ref'=p_storage_ref LIMIT 1;
  IF v_asset IS NOT NULL THEN
    RETURN jsonb_build_object('status','exists','asset_id',v_asset,
      'authority', public.fn_ad_product_card_authority(p_tenant,p_product_id,v_market)); END IF;

  SELECT EXISTS(SELECT 1 FROM public.product_image_assets
     WHERE product_id=p_product_id AND rights_state='CUSTOMER_OWNED' AND source_provider='CUSTOMER_UPLOAD'
       AND coalesce(is_primary,false)=true) INTO v_has_primary;

  v_prov := coalesce(p_provenance,'{}'::jsonb) || jsonb_build_object(
     'source','CUSTOMER_UPLOAD','uploaded_by',p_tenant,'uploaded_at',now(),
     'storage_ref',p_storage_ref,'bucket','pulse-product-imports',
     'original_filename',p_original_filename,'byte_size',p_byte_size,'mime',lower(p_mime),
     'rights_confirmed',true,
     'rights_statement','I confirm that I own this image or have permission to use it for this product and advertising.',
     'rights_confirmed_at',now());

  INSERT INTO public.product_image_assets(tenant_id, product_id, market, image_url, source_provider,
     source_url, source_entity_id, rights_state, availability, is_primary, observed_at, provenance, is_fixture)
  VALUES (p_tenant, p_product_id, v_market, p_display_url, 'CUSTOMER_UPLOAD',
     p_storage_ref, NULL, 'CUSTOMER_OWNED', 'AVAILABLE', (NOT v_has_primary), now(), v_prov, false)
  RETURNING id INTO v_asset;

  INSERT INTO public.supplier_product_assets(supplier, supplier_product_id, product_title, asset_type,
     asset_class, asset_identity, rights_state, availability, source_url, original_source, is_primary,
     cache_state, storage_ref, observed_at, provenance, is_fixture, created_at)
  SELECT 'CUSTOMER_UPLOAD', p_product_id::text, cp.title, 'IMAGE',
     'SOURCE_PRODUCT_ASSET', 'CUSTOMER_OWNED_PRODUCT', 'OWNED', 'AVAILABLE', p_display_url, 'customer_upload',
     (NOT v_has_primary), 'REMOTE', p_storage_ref, now(),
     jsonb_build_object('source','CUSTOMER_UPLOAD','tenant',p_tenant,'product_id',p_product_id::text,
        'product_image_asset_id',v_asset::text,'rights_confirmed',true), false, now()
  FROM public.commerce_products cp WHERE cp.id=p_product_id;

  RETURN jsonb_build_object('status','registered','asset_id',v_asset,'is_primary',(NOT v_has_primary),
    'rights_state','CUSTOMER_OWNED','source_provider','CUSTOMER_UPLOAD',
    'authority', public.fn_ad_product_card_authority(p_tenant,p_product_id,v_market));
END; $function$;

-- ============================================================================
-- 5) Selftest (rolled back). Proves the founder check + the gates behave.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_creative_studio_founder_only_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb := '[]'::jsonb; v_pass int; v_fail int; v_prev text; v_r jsonb;
  v_founder uuid; v_sub uuid := '11111111-1111-4111-8111-111111111111';
  v_prod uuid;
BEGIN
  SELECT auth_user_id INTO v_founder FROM public.founder_principals WHERE active ORDER BY created_at ASC LIMIT 1;
  v_prev := current_setting('request.jwt.claims', true);

  -- fn_is_founder_uid: founder true, subscriber false, null false.
  v_checks := v_checks || jsonb_build_object('check','UID_FOUNDER_TRUE',
    'ok', coalesce(public.fn_is_founder_uid(v_founder),false)=true, 'detail', v_founder);
  v_checks := v_checks || jsonb_build_object('check','UID_SUBSCRIBER_FALSE',
    'ok', coalesce(public.fn_is_founder_uid(v_sub),false)=false);
  v_checks := v_checks || jsonb_build_object('check','UID_NULL_FALSE',
    'ok', coalesce(public.fn_is_founder_uid(null),false)=false);

  -- import-for-creative: subscriber tenant rejected founder_only; (founder would pass this gate).
  v_r := public.fn_product_image_import_register(v_sub,'00000000-0000-4000-8000-000000000000','r','u','image/png',null,true,null,null,'{}'::jsonb);
  v_checks := v_checks || jsonb_build_object('check','IMPORT_SUBSCRIBER_FOUNDER_ONLY',
    'ok', v_r->>'error'='founder_only', 'detail', v_r->>'error');

  -- generated-asset read: unauthenticated -> unauthenticated; subscriber -> founder_only; founder -> past the gate.
  PERFORM set_config('request.jwt.claims','{}',true);
  v_r := public.fn_product_generated_assets('00000000-0000-4000-8000-000000000000');
  v_checks := v_checks || jsonb_build_object('check','READ_UNAUTH', 'ok', v_r->>'error'='unauthenticated', 'detail', v_r->>'error');

  PERFORM set_config('request.jwt.claims', json_build_object('sub',v_sub::text)::text, true);
  v_r := public.fn_product_generated_assets('00000000-0000-4000-8000-000000000000');
  v_checks := v_checks || jsonb_build_object('check','READ_SUBSCRIBER_FOUNDER_ONLY', 'ok', v_r->>'error'='founder_only', 'detail', v_r->>'error');
  v_r := public.fn_commercial_generated_asset_use('00000000-0000-4000-8000-000000000000');
  v_checks := v_checks || jsonb_build_object('check','USE_SUBSCRIBER_FOUNDER_ONLY', 'ok', v_r->>'error'='founder_only', 'detail', v_r->>'error');

  IF v_founder IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub',v_founder::text)::text, true);
    v_r := public.fn_product_generated_assets('00000000-0000-4000-8000-000000000000');
    -- founder passes the founder gate and reaches the next check (product_not_found), NOT founder_only.
    v_checks := v_checks || jsonb_build_object('check','READ_FOUNDER_PASSES_GATE',
      'ok', v_r->>'error' IS DISTINCT FROM 'founder_only', 'detail', v_r->>'error');
  END IF;

  PERFORM set_config('request.jwt.claims', coalesce(v_prev,''), true);
  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass, v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok', v_fail=0, 'passed', v_pass, 'failed', v_fail, 'total', v_pass+v_fail,
    'checks', v_checks, 'contract','pulse_creative_studio_founder_only_selftest_v1','generated_at', now());
END; $function$;

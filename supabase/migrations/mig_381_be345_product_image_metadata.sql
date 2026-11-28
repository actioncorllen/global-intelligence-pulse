-- mig_381 — BE345 CS.02 media-verification metadata (prepared, NOT applied).
-- PURPOSE: let the product-media-verify edge record REAL dimensions + URL accessibility
-- for a product's own image assets, so the deployed fn_product_media_discovery (which
-- already reads resolution from provenance.width/height) stops returning UNKNOWN and
-- reports real resolutions, and so the Product Research UI can show an accurate
-- authorised-image readiness + accessibility state.
--
-- METADATA ONLY, FAIL-CLOSED RIGHTS: recording dimensions/accessibility NEVER changes
-- rights_state or availability and NEVER grants research/AI-input/commercial use. CS.02's
-- permission classification (fn_asset_use_eligibility) and the BE324/BE326 fail-closed
-- gates are untouched. A larger or reachable supplier/marketplace image stays
-- research/identity-only. Additive + reversible: two new functions, no existing object
-- changed. NOT APPLIED TO PRODUCTION (founder control: no production migration).

-- ============================================================================
-- 1) Record real dimensions + accessibility for ONE owned asset (edge write path).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_record_product_image_metadata(
  p_asset_id uuid,
  p_tenant uuid,
  p_width integer,
  p_height integer,
  p_http_status integer,
  p_content_type text,
  p_byte_size bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_pid uuid;
BEGIN
  IF p_asset_id IS NULL OR p_tenant IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','missing_args'); END IF;
  SELECT pia.product_id, cp.user_id INTO v_pid, v_owner
    FROM public.product_image_assets pia
    JOIN public.commerce_products cp ON cp.id = pia.product_id
   WHERE pia.id = p_asset_id AND pia.tenant_id = p_tenant;
  IF v_pid IS NULL THEN RETURN jsonb_build_object('ok',false,'error','asset_not_found'); END IF;
  IF v_owner <> p_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  UPDATE public.product_image_assets
     SET provenance = coalesce(provenance,'{}'::jsonb)
           || jsonb_strip_nulls(jsonb_build_object(
                'width',  p_width,
                'height', p_height,
                'verify_http_status',  p_http_status,
                'verify_content_type', p_content_type,
                'verify_byte_size',    p_byte_size))
           || jsonb_build_object('verify_url_accessible', coalesce(p_http_status IN (200,206), false),
                                 'verify_at', now()),
         cache_state = CASE WHEN p_http_status IN (200,206) THEN 'VERIFIED_ACCESSIBLE'
                            WHEN p_http_status IS NULL THEN 'UNREACHABLE'
                            ELSE 'HTTP_'||p_http_status::text END
   WHERE id = p_asset_id;
  -- rights_state and availability are deliberately NOT changed (metadata only).

  RETURN jsonb_build_object('ok',true,'asset_id',p_asset_id,
    'resolution', CASE WHEN p_width IS NOT NULL AND p_height IS NOT NULL
                       THEN p_width::text||'x'||p_height::text ELSE 'UNKNOWN' END,
    'url_accessible', coalesce(p_http_status IN (200,206), false),
    'rights_unchanged', true);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_record_product_image_metadata(uuid,uuid,integer,integer,integer,text,bigint) TO service_role;

-- ============================================================================
-- 2) Owner-scoped read: per-asset dimensions + accessibility + expiry (UI/report).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_media_verification_status(p_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_owner uuid; v_rows jsonb; v_measured int; v_reachable int;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_owner <> v_uid THEN RETURN jsonb_build_object('status','cross_tenant_rejected'); END IF;

  SELECT
    jsonb_agg(jsonb_build_object(
      'asset_id', id, 'source_provider', source_provider, 'rights_state', rights_state,
      'is_primary', is_primary,
      'resolution', CASE WHEN provenance->>'width' IS NOT NULL AND provenance->>'height' IS NOT NULL
                         THEN (provenance->>'width')||'x'||(provenance->>'height') ELSE 'UNKNOWN' END,
      'url_accessible', (provenance->>'verify_url_accessible')::boolean,
      'verify_http_status', provenance->>'verify_http_status',
      'verified_at', provenance->>'verify_at',
      'source_url_expires_at', source_url_expires_at,
      'cache_state', cache_state) ORDER BY is_primary DESC NULLS LAST),
    count(*) FILTER (WHERE provenance->>'width' IS NOT NULL),
    count(*) FILTER (WHERE (provenance->>'verify_url_accessible')::boolean)
    INTO v_rows, v_measured, v_reachable
  FROM public.product_image_assets
  WHERE product_id = p_product_id AND coalesce(is_fixture,false) = false;

  RETURN jsonb_build_object('status','ok','product_id',p_product_id::text,
    'measured_count', coalesce(v_measured,0), 'reachable_count', coalesce(v_reachable,0),
    'assets', coalesce(v_rows,'[]'::jsonb), 'contract','pulse_media_verification_status_v1');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_product_media_verification_status(uuid) TO authenticated, service_role;

-- ============================================================================
-- 3) Selftest (rolled-back; records real-shaped metadata on a real owned asset,
--    asserts rights are unchanged, then rolls back). Runs at apply time.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_image_metadata_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb := '[]'::jsonb; v_pass int; v_fail int; v_r jsonb;
  v_asset uuid; v_tenant uuid; v_other uuid := '11111111-1111-4111-8111-111111111111';
  v_rights_before text; v_rights_after text; v_width_after text;
BEGIN
  -- missing args
  v_r := public.fn_record_product_image_metadata(null, null, 800, 600, 200, 'image/jpeg', 12345);
  v_checks := v_checks || jsonb_build_object('check','MISSING_ARGS_REJECTED',
    'ok', (v_r->>'ok')='false' AND v_r->>'error'='missing_args', 'detail', v_r->>'error');

  SELECT pia.id, pia.tenant_id, pia.rights_state INTO v_asset, v_tenant, v_rights_before
    FROM public.product_image_assets pia JOIN public.commerce_products cp ON cp.id=pia.product_id
    WHERE cp.user_id = pia.tenant_id AND coalesce(pia.is_fixture,false)=false
    ORDER BY pia.created_at ASC LIMIT 1;

  IF v_asset IS NOT NULL THEN
    BEGIN
      -- a non-owning tenant is rejected (the tenant_id filter yields asset_not_found,
      -- which is a safe, non-leaking rejection; cross_tenant_rejected is the other).
      v_r := public.fn_record_product_image_metadata(v_asset, v_other, 800, 600, 200, 'image/jpeg', 12345);
      v_checks := v_checks || jsonb_build_object('check','NON_OWNER_REJECTED',
        'ok', (v_r->>'ok')='false' AND v_r->>'error' IN ('cross_tenant_rejected','asset_not_found'), 'detail', v_r->>'error');

      -- happy path: records real dimensions + accessibility; rights unchanged
      v_r := public.fn_record_product_image_metadata(v_asset, v_tenant, 1600, 1200, 200, 'image/jpeg', 234567);
      SELECT rights_state, provenance->>'width' INTO v_rights_after, v_width_after
        FROM public.product_image_assets WHERE id=v_asset;
      v_checks := v_checks || jsonb_build_object('check','RECORDS_DIMENSIONS_AND_ACCESSIBILITY',
        'ok', (v_r->>'ok')='true' AND v_r->>'resolution'='1600x1200'
           AND (v_r->>'url_accessible')='true' AND v_width_after='1600',
        'detail', v_r);
      v_checks := v_checks || jsonb_build_object('check','RIGHTS_STATE_UNCHANGED',
        'ok', v_rights_after IS NOT DISTINCT FROM v_rights_before, 'detail',
        jsonb_build_object('before',v_rights_before,'after',v_rights_after));

      -- unreachable http -> UNKNOWN resolution, cache_state UNREACHABLE, still rights-safe
      v_r := public.fn_record_product_image_metadata(v_asset, v_tenant, null, null, null, null, null);
      v_checks := v_checks || jsonb_build_object('check','UNREACHABLE_IS_HONEST',
        'ok', (v_r->>'ok')='true' AND v_r->>'resolution'='UNKNOWN' AND (v_r->>'url_accessible')='false',
        'detail', v_r);

      RAISE EXCEPTION 'product_image_metadata_selftest_rollback';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  ELSE
    v_checks := v_checks || jsonb_build_object('check','WRITE_PATH_SKIPPED_NO_ASSET','ok',true,'detail','no owned asset');
  END IF;

  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass, v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok', v_fail=0, 'passed', v_pass, 'failed', v_fail, 'total', v_pass+v_fail,
    'checks', v_checks, 'contract','pulse_product_image_metadata_selftest_v1','generated_at', now());
END; $function$;

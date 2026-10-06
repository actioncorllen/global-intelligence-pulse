-- STRATELOQ post-P0 integrity #2a: Product Card identity selftest -> invariant-based.
-- The authoritative Product Card primary is legitimately re-resolved when the supplier gallery is
-- re-ingested (same product / same source_item_id, new asset UUID). The old check hard-coded a
-- stale asset UUID. Replaced with the launch-critical invariant: the image DISPLAYED on the
-- Product Card IS the authoritative primary used by creative generation; authoritative
-- (non-marketplace) origin; consistent product identity. Strengthens, does not weaken, the lock.

CREATE OR REPLACE FUNCTION public.fn_ad_creative_identity_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_pass int:=0; v_fail int:=0; v_checks jsonb:='[]'::jsonb; v_pol jsonb; v_auth jsonb; v_disp jsonb;
BEGIN
  v_pol := public.fn_ad_creative_identity_policy();
  IF (v_pol->>'PRODUCT_CARD_ASSET_IS_AUTHORITATIVE')='true' AND (v_pol->>'locked')='true'
     AND v_pol->'applies_to' ? 'VIDEO' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('policy_locked_all_types',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('policy_locked_all_types',false); END IF;

  v_auth := public.fn_ad_product_card_authority('7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
              'e453eed4-3de4-4ed9-b889-1275c13c0dba'::uuid,'GB');
  v_disp := public.fn_product_card_display_image('7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
              'e453eed4-3de4-4ed9-b889-1275c13c0dba'::uuid,'GB');
  IF (v_auth->>'status')='ok'
     AND coalesce((v_auth->'primary_asset'->>'is_primary')::boolean,false)
     AND (v_disp->>'is_authoritative')='true'
     AND (v_auth->'primary_asset'->>'id') = (v_disp->>'asset_id')
     AND (v_auth->'primary_asset'->>'rights_state') <> 'MARKETPLACE_PUBLIC_LISTING'
     AND coalesce(v_auth->'card_identity'->>'source_item_id','') <> ''
     AND (v_auth->'card_identity'->>'source_item_id') = (v_auth->'primary_asset'->>'source_item_id') THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('authority_resolves_card_image',true,
      'invariant','display==authority_primary; authoritative origin; consistent identity',
      'asset_id', v_auth->'primary_asset'->>'id','source_item_id',v_auth->'card_identity'->>'source_item_id');
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('authority_resolves_card_image',false,
      'got_primary',v_auth->'primary_asset','got_display',v_disp); END IF;

  IF (public.fn_media_product_identity_preserved('4b2ba996-e046-4f95-bdc2-5f3c48be1f0e'::uuid)->>'state')='FAIL' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('redraw_fails_identity',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('redraw_fails_identity',false); END IF;

  IF (public.fn_media_product_card_source_verified('4b2ba996-e046-4f95-bdc2-5f3c48be1f0e'::uuid)->>'state')='PASS' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('source_verified_pass',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('source_verified_pass',false); END IF;

  IF (public.fn_creative_quality_review('IMAGE_ASSET','4b2ba996-e046-4f95-bdc2-5f3c48be1f0e'::uuid)
        ->'gates'->>'PRODUCT_IDENTITY_PRESERVED')='FAIL'
     AND (public.fn_media_launch_eligibility('4b2ba996-e046-4f95-bdc2-5f3c48be1f0e'::uuid)->>'eligible')='false' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('reviewer_and_launch_block_redraw',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('reviewer_and_launch_block_redraw',false); END IF;

  IF (public.fn_ad_product_card_safe_route('7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
        'e453eed4-3de4-4ed9-b889-1275c13c0dba'::uuid,'GB','STATIC')->'product_layer'->>'source') LIKE '%Product Card%' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('safe_route_protected_layer',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('safe_route_protected_layer',false); END IF;

  RETURN jsonb_build_object('suite','ad_creative_product_card_identity','pass',v_pass,'fail',v_fail,
    'all_pass',(v_fail=0),'checks',v_checks);
END; $function$;

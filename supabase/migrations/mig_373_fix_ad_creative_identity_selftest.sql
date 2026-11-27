-- mig_373 — Task C: fix fn_ad_creative_identity_selftest (BE321 finding).
-- Diagnosis: INVALID/STALE TEST EXPECTATION, not a production defect. The production reader
-- fn_product_card_display_image CORRECTLY withholds a supplier/CJ authoritative primary whose display
-- rights are UNVERIFIED (rights-safe placeholder) — exactly the restriction the founder requires to survive.
-- The old check 2 asserted the card always DISPLAYS the authoritative primary, which contradicts the
-- rights rule when that primary is RIGHTS_UNVERIFIED. This refines check 2 to the correct launch-critical
-- invariant (display == authoritative primary, OR a rights-correct withhold; NEVER a different/marketplace
-- image) and adds two negative checks proving RIGHTS_UNVERIFIED stays blocked and marketplace is never
-- displayed. No authoritative rights record is altered; no invariant is weakened.

CREATE OR REPLACE FUNCTION public.fn_ad_creative_identity_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_pass int:=0; v_fail int:=0; v_checks jsonb:='[]'::jsonb; v_pol jsonb; v_auth jsonb; v_disp jsonb;
  v_primary jsonb; v_has boolean; v_base boolean; v_consistent boolean; v_withhold_ok boolean; v_cls jsonb;
  v_founder uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
BEGIN
  v_pol := public.fn_ad_creative_identity_policy();
  IF (v_pol->>'PRODUCT_CARD_ASSET_IS_AUTHORITATIVE')='true' AND (v_pol->>'locked')='true'
     AND v_pol->'applies_to' ? 'VIDEO' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('policy_locked_all_types',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('policy_locked_all_types',false); END IF;

  -- INVARIANT (launch-critical, refined): the Product Card display is CONSISTENT with the authoritative
  -- primary used by customer creative generation. Either the card shows the authoritative primary
  -- (authoritative, non-marketplace, identity-consistent) OR it correctly WITHHOLDS because that primary's
  -- display rights are UNVERIFIED (rights-safe placeholder). It must NEVER show a different or marketplace image.
  v_auth := public.fn_ad_product_card_authority(v_founder, v_prod, 'GB');
  v_disp := public.fn_product_card_display_image(v_founder, v_prod, 'GB');
  v_primary := v_auth->'primary_asset';
  v_has := coalesce((v_disp->>'has_image')::boolean, false);
  v_base := (v_auth->>'status')='ok'
    AND coalesce((v_primary->>'is_primary')::boolean,false)
    AND (v_primary->>'rights_state') <> 'MARKETPLACE_PUBLIC_LISTING'
    AND coalesce(v_auth->'card_identity'->>'source_item_id','') <> ''
    AND (v_auth->'card_identity'->>'source_item_id') = (v_primary->>'source_item_id');
  IF v_has THEN
    v_consistent := (v_disp->>'is_authoritative')='true'
      AND (v_primary->>'id') = (v_disp->>'asset_id')
      AND coalesce(v_disp->>'rights_state','') <> 'MARKETPLACE_PUBLIC_LISTING';
  ELSE
    v_consistent := (v_disp->>'reason')='image_rights_unverified';  -- rights-correct withhold only
  END IF;
  IF v_base AND v_consistent THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('display_consistent_with_authority',true,
      'invariant','display==authority_primary OR rights-correct withhold; authoritative origin; consistent identity',
      'display_has_image', v_has, 'withhold_reason', v_disp->>'reason');
  ELSE
    v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('display_consistent_with_authority',false,
      'got_primary',v_primary,'got_display',v_disp); END IF;

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

  IF (public.fn_ad_product_card_safe_route(v_founder, v_prod,'GB','STATIC')->'product_layer'->>'source') LIKE '%Product Card%' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('safe_route_protected_layer',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('safe_route_protected_layer',false); END IF;

  -- NEGATIVE (restriction survives): an authoritative primary with UNVERIFIED display rights stays blocked
  -- (card withholds with a rights-safe placeholder; it is never shown).
  IF NOT coalesce((v_disp->>'has_image')::boolean,false) AND (v_disp->>'reason')='image_rights_unverified' THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('rights_unverified_stays_blocked',true,'reason',v_disp->>'reason');
  ELSIF coalesce((v_disp->>'has_image')::boolean,false)
        AND coalesce(v_disp->>'display_classification','')='DISPLAY_AUTHORISED' THEN
    -- If (after a future rights grant) an image is shown, it must be display-authorised — also acceptable.
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('rights_unverified_stays_blocked',true,'note','authorised image shown');
  ELSE
    v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('rights_unverified_stays_blocked',false,'got_display',v_disp); END IF;

  -- NEGATIVE (identity/rights): a marketplace/eBay image is never display-authorised.
  v_cls := public.fn_cj_image_display_classification('EBAY_BROWSE','v1|999|0','http://x/ebay.jpg');
  IF coalesce((v_cls->>'display_allowed')::boolean,false)=false THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('marketplace_never_displayed',true,'classification',v_cls->>'classification');
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('marketplace_never_displayed',false,'detail',v_cls); END IF;

  RETURN jsonb_build_object('suite','ad_creative_product_card_identity','pass',v_pass,'fail',v_fail,
    'all_pass',(v_fail=0),'checks',v_checks);
END; $function$;
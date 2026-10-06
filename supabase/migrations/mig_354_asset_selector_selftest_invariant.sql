-- STRATELOQ post-P0 integrity #2b: asset-selector selftest -> invariant-based.
-- Asserts the selector selects the authoritative Product Card PRIMARY (the displayed image used by
-- creative generation), instead of a brittle hard-coded asset UUID.

CREATE OR REPLACE FUNCTION public.fn_ad_creative_asset_selector_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_res jsonb; v_auth jsonb; v_pass int:=0; v_fail int:=0; v_checks jsonb:='[]'::jsonb;
BEGIN
  v_res := public.fn_ad_product_card_select_creative_asset(
    '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
    'e453eed4-3de4-4ed9-b889-1275c13c0dba'::uuid,'GB','{}'::jsonb, false);
  v_auth := public.fn_ad_product_card_authority(
    '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
    'e453eed4-3de4-4ed9-b889-1275c13c0dba'::uuid,'GB');

  IF (v_res->>'candidate_count')::int >= 1 THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('exact_identity_candidates_present',true,'n',v_res->>'candidate_count');
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('exact_identity_candidates_present',false,'n',v_res->>'candidate_count'); END IF;

  IF (v_res->>'selected_product_card_asset_id') = (v_auth->'primary_asset'->>'id')
     AND (v_res->>'is_primary')='true' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('selected_is_card_primary',true,'selected',v_res->>'selected_product_card_asset_id');
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('selected_is_card_primary',false,'got',v_res->>'selected_product_card_asset_id','authority_primary',v_auth->'primary_asset'->>'id'); END IF;

  IF (v_res->>'external_image_used')='false' AND (v_res->>'product_pixels_generated')='false' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('no_external_no_generation',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('no_external_no_generation',false); END IF;

  IF (public.fn_ad_product_card_select_creative_asset('7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid, gen_random_uuid(), 'GB','{}'::jsonb, false)->>'verdict')='PRODUCT_CARD_ASSET_SELECTION_BLOCKED'
     THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('blocked_when_no_card',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('blocked_when_no_card',false); END IF;

  RETURN jsonb_build_object('suite','ad_creative_asset_selector','pass',v_pass,'fail',v_fail,'all_pass',(v_fail=0),'checks',v_checks);
END; $function$;

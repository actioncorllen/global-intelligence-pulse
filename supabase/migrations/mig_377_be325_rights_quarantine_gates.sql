-- mig_377 — BE325 reversible rights-quarantine gates (production-wired use/launch gates).
-- Adds a single fail-closed check to the two gates that decide whether a generated/commercial asset may be
-- SELECTED or LAUNCHED: an asset carrying `provenance.rights_quarantine_active = true` (or the quarantine
-- status/approval value) is refused. The quarantine itself is applied as reversible DATA in mig_378; this gate
-- enforces it and is itself reversible (CREATE OR REPLACE back to the pre-BE325 definitions). No deletes.
-- NOT APPLIED (founder control: no production migration/deployment). Companion to mig_375/mig_376.

-- Generated-asset selection gate: refuse a rights-quarantined generated image.
CREATE OR REPLACE FUNCTION public.fn_commercial_generated_asset_use(p_generated_asset_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); ga record;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO ga FROM public.commerce_generated_assets WHERE id=p_generated_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','generated_asset_not_found'); END IF;
  IF ga.tenant_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  -- BE325 reversible rights quarantine: refuse selection of a generated image whose reference rights are unverified.
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

-- Media launch-eligibility gate: refuse a rights-quarantined media asset.
CREATE OR REPLACE FUNCTION public.fn_media_launch_eligibility(p_asset_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE m public.media_assets%rowtype; v_dec_exists boolean; v_src jsonb; v_pres jsonb;
BEGIN
  SELECT * INTO m FROM public.media_assets WHERE id=p_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('eligible',false,'reason','not_found'); END IF;
  -- BE325 reversible rights quarantine: a quarantined media asset is never launch-eligible.
  IF coalesce((m.provenance->>'rights_quarantine_active'),'false')='true'
     OR m.approval_state='QUARANTINED_RIGHTS_UNVERIFIED' THEN
    RETURN jsonb_build_object('eligible',false,'reason','RIGHTS_QUARANTINED',
      'detail','Generated from a supplier/marketplace source without verified commercial/AI-input rights (BE325).');
  END IF;
  IF m.lineage_state <> 'CANONICAL' THEN
    RETURN jsonb_build_object('eligible',false,'reason','CANONICAL_PRODUCT_LINEAGE_REQUIRED','lineage_state',m.lineage_state);
  END IF;
  IF m.identity_state <> 'IDENTITY_CLEARED' THEN
    RETURN jsonb_build_object('eligible',false,'reason','IDENTITY_REVIEW_REQUIRED','identity_state',m.identity_state);
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.product_opportunity_decisions d
    WHERE d.product_id=m.product_id AND d.tenant_id=m.tenant_id
      AND upper(d.country_code)=upper(coalesce(m.country_code,'')) AND coalesce(d.is_fixture,false)=false)
    INTO v_dec_exists;
  IF NOT v_dec_exists THEN
    RETURN jsonb_build_object('eligible',false,'reason','PRODUCT_DECISION_REQUIRED');
  END IF;
  IF m.source_type IN ('PULSE_GENERATED_IMAGE','PULSE_COMPOSED_IMAGE','PULSE_GENERATED_VIDEO') THEN
    v_src := public.fn_media_product_card_source_verified(p_asset_id);
    v_pres := public.fn_media_product_identity_preserved(p_asset_id);
    IF (v_src->>'state') <> 'PASS' THEN
      RETURN jsonb_build_object('eligible',false,'reason','PRODUCT_CARD_SOURCE_NOT_VERIFIED','detail',v_src);
    END IF;
    IF (v_pres->>'state') <> 'PASS' THEN
      RETURN jsonb_build_object('eligible',false,'reason','PRODUCT_IDENTITY_NOT_PRESERVED','detail',v_pres);
    END IF;
  END IF;
  RETURN jsonb_build_object('eligible',true,'reason','canonical_lineage_identity_cleared_decision_present_product_card_verified',
    'lineage_state',m.lineage_state,'identity_state',m.identity_state);
END; $function$;
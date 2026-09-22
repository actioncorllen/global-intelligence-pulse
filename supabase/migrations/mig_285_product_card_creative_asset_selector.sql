-- ============================================================================
-- mig_285_product_card_creative_asset_selector.sql
-- STRATELOQ-015M — select the strongest EXACT-SKU Product Card image for creative
-- production, deterministically, without weakening identity. Provenance stored
-- separately; source records never modified. No pixel fetch, no paid model.
-- Governed by mig_283 (PRODUCT_CARD_ASSET_IS_AUTHORITATIVE) + the LOCKED standard.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.ad_creative_asset_selections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  product_id uuid NOT NULL,
  market text,
  selected_product_card_asset_id uuid NOT NULL,
  source_provider text,
  source_item_id text,
  asset_class text,
  selection_reason text,
  candidate_count int,
  creative_suitability_metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);
-- deny-by-default: RLS on, no client policy — only SECURITY DEFINER fns access it.
ALTER TABLE public.ad_creative_asset_selections ENABLE ROW LEVEL SECURITY;

-- Selects an ASSET for creative production from the SAME-SKU Product Card gallery.
-- It does NOT rank products. Deterministic; no paid model; no pixel fetch; no external
-- image search. Where pixels cannot be assessed here, classification stays REVIEW_REQUIRED.
CREATE OR REPLACE FUNCTION public.fn_ad_product_card_select_creative_asset(
  p_tenant uuid, p_product_id uuid, p_market text DEFAULT NULL,
  p_observed jsonb DEFAULT '{}'::jsonb, p_persist boolean DEFAULT true)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_auth jsonb; v_assets jsonb; v_n int; v_sel jsonb; v_sel_id uuid;
  v_class text; v_reason text; v_meta jsonb;
BEGIN
  v_auth := public.fn_ad_product_card_authority(p_tenant, p_product_id, p_market);
  IF (v_auth->>'status') <> 'ok' THEN
    RETURN jsonb_build_object('status','blocked','verdict','PRODUCT_CARD_ASSET_SELECTION_BLOCKED','reason',v_auth->>'status');
  END IF;
  v_assets := coalesce(v_auth->'authoritative_assets','[]'::jsonb);
  v_n := jsonb_array_length(v_assets);
  IF v_n = 0 THEN
    RETURN jsonb_build_object('status','blocked','verdict','PRODUCT_CARD_ASSET_SELECTION_BLOCKED','reason','no_exact_identity_image');
  END IF;

  SELECT e INTO v_sel
  FROM jsonb_array_elements(v_assets) e
  ORDER BY coalesce((p_observed->(e->>'id')->>'score')::int, -1) DESC,
           (e->>'is_primary')::boolean DESC,
           e->>'id'
  LIMIT 1;
  v_sel_id := (v_sel->>'id')::uuid;

  v_class := coalesce(p_observed->(v_sel->>'id')->>'asset_class', 'UNASSESSED_PIXELS_REVIEW_REQUIRED');
  v_meta := coalesce(p_observed->(v_sel->>'id'),'{}'::jsonb) || jsonb_build_object(
    'is_primary', v_sel->>'is_primary', 'rights_state', v_sel->>'rights_state',
    'suitability_basis', CASE WHEN p_observed ? (v_sel->>'id')
       THEN 'agent_visual_observation (from an existing free render; no paid call)'
       ELSE 'no deterministic pixel signal available in this environment; REVIEW_REQUIRED' END);

  v_reason := CASE WHEN v_n = 1
    THEN 'Only one exact-Product-Card-identity image exists; selected by default. Marketplace-reference images (different provider/item) are excluded by the strict identity rule.'
    ELSE 'Selected from '||v_n||' exact-identity candidates by deterministic rule (observed suitability, then primary, then id). This selects an ASSET for creative production; it does NOT rank products.' END;

  IF p_persist THEN
    INSERT INTO public.ad_creative_asset_selections(tenant_id, product_id, market, selected_product_card_asset_id,
      source_provider, source_item_id, asset_class, selection_reason, candidate_count, creative_suitability_metadata)
    VALUES (p_tenant, p_product_id, p_market, v_sel_id,
      v_auth->'card_identity'->>'source_provider', v_auth->'card_identity'->>'source_item_id',
      v_class, v_reason, v_n, v_meta);
  END IF;

  RETURN jsonb_build_object('status','ok',
    'verdict', CASE WHEN v_n=1 THEN 'SINGLE_EXACT_IDENTITY_ASSET' ELSE 'CREATIVE_ASSET_SELECTED' END,
    'candidate_count', v_n, 'candidates', v_assets, 'card_identity', v_auth->'card_identity',
    'selected_product_card_asset_id', v_sel_id, 'asset_class', v_class, 'selection_reason', v_reason,
    'is_primary', (v_sel->>'is_primary')::boolean,
    'external_image_used', false, 'product_pixels_generated', false,
    'creative_suitability_metadata', v_meta);
END; $fn$;

CREATE OR REPLACE FUNCTION public.fn_ad_creative_asset_selector_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_res jsonb; v_pass int:=0; v_fail int:=0; v_checks jsonb:='[]'::jsonb;
BEGIN
  v_res := public.fn_ad_product_card_select_creative_asset(
    '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,
    'e453eed4-3de4-4ed9-b889-1275c13c0dba'::uuid,'GB','{}'::jsonb, false);

  IF (v_res->>'candidate_count')::int >= 1 THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('exact_identity_candidates_present',true,'n',v_res->>'candidate_count');
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('exact_identity_candidates_present',false,'n',v_res->>'candidate_count'); END IF;

  IF (v_res->>'selected_product_card_asset_id')='7c2f476f-acbe-499b-a015-2422e56daa50' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('selected_is_card_primary',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('selected_is_card_primary',false); END IF;

  IF (v_res->>'external_image_used')='false' AND (v_res->>'product_pixels_generated')='false' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('no_external_no_generation',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('no_external_no_generation',false); END IF;

  IF (public.fn_ad_product_card_select_creative_asset('7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid, gen_random_uuid(), 'GB','{}'::jsonb, false)->>'verdict')='PRODUCT_CARD_ASSET_SELECTION_BLOCKED'
     THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('blocked_when_no_card',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('blocked_when_no_card',false); END IF;

  RETURN jsonb_build_object('suite','ad_creative_asset_selector','pass',v_pass,'fail',v_fail,'all_pass',(v_fail=0),'checks',v_checks);
END; $fn$;

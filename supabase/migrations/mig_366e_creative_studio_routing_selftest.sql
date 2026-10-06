-- mig_366e — Creative Studio one-click routing selftest
--
-- Deterministic, free (no provider calls, no auth needed) proof of the corrected
-- routing contract:
--   * SAAS_SOCIAL_SQUARE routes to the CI design-family system (not product-image).
--   * GRID_MULTI_CARD stays on the product-static path.
--   * Video formats stay VIDEO (cost-gated).
--   * AUTO selects the format AND, for design-family formats, resolves a family.
--   * Design-family routing is adaptive: different contexts -> different families.
--   * Format vs design-family separation is preserved.

CREATE OR REPLACE FUNCTION public.fn_creative_studio_routing_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  checks jsonb := '[]'::jsonb; v_n int;
  v_saas jsonb; v_grid jsonb; v_ugc jsonb;
  v_auto_biz jsonb; v_auto_prod jsonb;
  v_sig jsonb; v_edu jsonb; v_li jsonb; v_ev jsonb; v_cap jsonb;
BEGIN
  -- Route contract
  v_saas := public.fn_creative_format_route('SAAS_SOCIAL_SQUARE');
  v_grid := public.fn_creative_format_route('GRID_MULTI_CARD');
  v_ugc  := public.fn_creative_format_route('LOW_FI_UGC');

  checks := checks || jsonb_build_object('check','SAAS_ROUTES_TO_DESIGN_FAMILY',
    'pass',(v_saas->>'generation_system'='CI_DESIGN_FAMILY'
            AND (v_saas->>'requires_design_family')::boolean
            AND v_saas->>'output_type'='STATIC'),'detail',v_saas);
  checks := checks || jsonb_build_object('check','GRID_STAYS_PRODUCT_STATIC',
    'pass',(v_grid->>'generation_system'='PRODUCT_STATIC'
            AND (v_grid->>'requires_design_family')::boolean IS FALSE
            AND v_grid->>'output_type'='STATIC'
            AND v_grid->>'generator_route'='IMAGE'),'detail',v_grid);
  checks := checks || jsonb_build_object('check','VIDEO_STAYS_COST_GATED',
    'pass',(v_ugc->>'generation_system'='VIDEO'
            AND (v_ugc->>'video_generation_paid_gated')::boolean),'detail',v_ugc);

  -- AUTO orchestration: business/brand context -> SAAS + a design family
  v_auto_biz := public.fn_creative_format_select(
    jsonb_build_object('business_self',true,'brand_awareness',true,'platform_meta',true,
      'business_objective','MARKET_SIGNAL_AWARENESS','audience','ecommerce founders',
      'platform','META_FACEBOOK','intelligence_type','MARKET_SIGNAL'),'AUTO');
  checks := checks || jsonb_build_object('check','AUTO_BUSINESS_SELECTS_SAAS_WITH_FAMILY',
    'pass',(v_auto_biz->>'format'='SAAS_SOCIAL_SQUARE'
            AND (v_auto_biz->>'requires_design_family')::boolean
            AND coalesce(v_auto_biz->>'design_family','') <> ''),'detail',v_auto_biz);

  -- AUTO on a product context -> GRID, no design family (separation preserved)
  v_auto_prod := public.fn_creative_format_select(
    jsonb_build_object('multiple_benefits',true,'static_preferred',true,'proof_points',true),'AUTO');
  checks := checks || jsonb_build_object('check','AUTO_PRODUCT_SELECTS_GRID_NO_FAMILY',
    'pass',(v_auto_prod->>'format'='GRID_MULTI_CARD'
            AND (v_auto_prod->>'requires_design_family')::boolean IS FALSE
            AND v_auto_prod->'design_family' IS NULL),'detail',v_auto_prod);

  -- Adaptive design-family routing: five distinct contexts -> their families
  v_sig := public.fn_ci_route_design_family('signal awareness launch','founders','META_FACEBOOK','MARKET_SIGNAL',NULL);
  v_edu := public.fn_ci_route_design_family('educate how-to','smb','META_FACEBOOK','EDUCATIONAL',NULL);
  v_li  := public.fn_ci_route_design_family('thought leadership','executives','LINKEDIN','FOUNDER_INSIGHT','founder insight');
  v_ev  := public.fn_ci_route_design_family('share one stat','analysts','META_FACEBOOK','EVIDENCE','single insight');
  v_cap := public.fn_ci_route_design_family('show the product','founders','META_FACEBOOK','CAPABILITY','product ui demo');

  checks := checks || jsonb_build_object('check','ROUTE_SIGNAL_BOLD','pass',(v_sig->>'design_family'='BOLD_SIGNAL'),'detail',v_sig->>'design_family');
  checks := checks || jsonb_build_object('check','ROUTE_EDU_EDITORIAL','pass',(v_edu->>'design_family'='EDITORIAL_INTELLIGENCE'),'detail',v_edu->>'design_family');
  checks := checks || jsonb_build_object('check','ROUTE_INSIGHT_THOUGHT','pass',(v_li->>'design_family'='THOUGHT_LEADERSHIP'),'detail',v_li->>'design_family');
  checks := checks || jsonb_build_object('check','ROUTE_EVIDENCE_INSIGHT_CARD','pass',(v_ev->>'design_family'='INSIGHT_CARD'),'detail',v_ev->>'design_family');
  checks := checks || jsonb_build_object('check','ROUTE_CAPABILITY_PRODUCT_UI','pass',(v_cap->>'design_family'='PRODUCT_UI_STORY'),'detail',v_cap->>'design_family');

  -- Adaptive (not a fixed mapping): the five contexts yield >=3 distinct families
  checks := checks || jsonb_build_object('check','DESIGN_FAMILY_ROUTING_IS_ADAPTIVE',
    'pass',( (SELECT count(DISTINCT f) FROM unnest(ARRAY[
              v_sig->>'design_family',v_edu->>'design_family',v_li->>'design_family',
              v_ev->>'design_family',v_cap->>'design_family']) f) >= 3 ));

  SELECT count(*) INTO v_n FROM jsonb_array_elements(checks) c WHERE (c->>'pass')::boolean IS NOT TRUE;
  RETURN jsonb_build_object('ok',(v_n=0),'contract','creative_studio_one_click_design_family_v1',
    'failed',v_n,'total',jsonb_array_length(checks),'checks',checks);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_creative_studio_routing_selftest() TO authenticated, service_role;

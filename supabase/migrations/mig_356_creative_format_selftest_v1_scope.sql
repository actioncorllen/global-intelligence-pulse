-- STRATELOQ post-P0 integrity #3b: scope the creative_format_expansion_v1 structural checks to the
-- v1 format family, so additional enabled format families (e.g. the SaaS brand square) do not make
-- the v1 contract test red. No check removed.

CREATE OR REPLACE FUNCTION public.fn_creative_format_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE checks jsonb := '[]'::jsonb; v_n int; v_distinct int;
  v_ugc jsonb; v_grid jsonb; v_obj jsonb; v_route_static jsonb; v_route_video jsonb;
  v_manual jsonb; v_qa_ugc jsonb; v_qa_grid jsonb; f record;
  v_id_gen jsonb; v_id_real jsonb; v_all_identity boolean := true;
  v1 text[] := ARRAY['LOW_FI_UGC','GRID_MULTI_CARD','BROLL_TEXT_OVERLAY','CASUAL_PODCAST','OBJECTION_POV'];
BEGIN
  SELECT count(*) INTO v_n FROM public.creative_format_registry WHERE enabled AND format_key = ANY(v1);
  checks := checks || jsonb_build_object('check','FIVE_V1_FORMATS_EXIST','pass',(v_n=5),'detail',v_n);

  SELECT count(DISTINCT storyboard_logic::text) INTO v_distinct FROM public.creative_format_registry
   WHERE enabled AND format_key = ANY(v1);
  checks := checks || jsonb_build_object('check','DISTINCT_STORYBOARD_LOGIC','pass',(v_distinct=5),'detail',v_distinct);

  SELECT count(*) INTO v_n FROM public.creative_format_registry WHERE enabled AND format_key = ANY(v1)
    AND (length(prompt_template)>40 AND jsonb_array_length(qa_criteria)>=4
         AND shot_rules<>'{}'::jsonb AND pacing_rules<>'{}'::jsonb
         AND text_treatment<>'{}'::jsonb AND cta_treatment<>'{}'::jsonb);
  checks := checks || jsonb_build_object('check','EACH_FORMAT_HAS_DISTINCT_RULES','pass',(v_n=5),'detail',v_n);

  v_route_static := public.fn_creative_format_route('GRID_MULTI_CARD');
  v_route_video  := public.fn_creative_format_route('LOW_FI_UGC');
  checks := checks || jsonb_build_object('check','STATIC_ROUTES_TO_IMAGE',
    'pass',(v_route_static->>'output_type'='STATIC' AND v_route_static->>'generator_route'='IMAGE'),'detail',v_route_static);
  checks := checks || jsonb_build_object('check','VIDEO_ROUTES_TO_VIDEO',
    'pass',(v_route_video->>'output_type'='VIDEO' AND v_route_video->>'generator_route'='VIDEO'),'detail',v_route_video);

  v_manual := public.fn_creative_format_select(jsonb_build_object('format','BROLL_TEXT_OVERLAY'),'MANUAL');
  checks := checks || jsonb_build_object('check','MANUAL_SELECTION',
    'pass',(v_manual->>'ok'='true' AND v_manual->>'format'='BROLL_TEXT_OVERLAY'),'detail',v_manual);

  v_obj  := public.fn_creative_format_select(jsonb_build_object('objection_present',true),'AUTO');
  v_grid := public.fn_creative_format_select(jsonb_build_object('multiple_benefits',true,'static_preferred',true),'AUTO');
  v_ugc  := public.fn_creative_format_select(jsonb_build_object('ugc_preferred',true),'AUTO');
  checks := checks || jsonb_build_object('check','AUTO_OBJECTION','pass',(v_obj->>'format'='OBJECTION_POV'),'detail',v_obj->>'format');
  checks := checks || jsonb_build_object('check','AUTO_GRID','pass',(v_grid->>'format'='GRID_MULTI_CARD'),'detail',v_grid->>'format');
  checks := checks || jsonb_build_object('check','AUTO_UGC','pass',(v_ugc->>'format'='LOW_FI_UGC'),'detail',v_ugc->>'format');
  checks := checks || jsonb_build_object('check','AUTO_RETURNS_REASON','pass',(length(coalesce(v_obj->>'reason',''))>0),'detail',v_obj->>'reason');
  checks := checks || jsonb_build_object('check','AUTO_DEFAULT_HAS_WINNER',
    'pass',(public.fn_creative_format_select('{}'::jsonb,'AUTO')->>'ok'='true'),'detail',public.fn_creative_format_select('{}'::jsonb,'AUTO')->>'format');

  FOR f IN SELECT format_key FROM public.creative_format_registry WHERE enabled LOOP
    v_id_gen  := public.fn_creative_scene_identity_policy('CUSTOMER_PRODUCT','PRODUCT',true,true);
    v_id_real := public.fn_creative_scene_identity_policy('CUSTOMER_PRODUCT','PRODUCT',true,false);
    IF v_id_gen->>'identity_state' <> 'IDENTITY_REVIEW_REQUIRED'
       OR v_id_real->>'identity_state' <> 'AUTHORITATIVE_PRODUCT_CARD_PIXELS' THEN
      v_all_identity := false;
    END IF;
  END LOOP;
  checks := checks || jsonb_build_object('check','PRODUCT_IDENTITY_LOCK_ALL_FORMATS','pass',v_all_identity);

  v_qa_ugc  := public.fn_creative_format_qa_criteria('LOW_FI_UGC');
  v_qa_grid := public.fn_creative_format_qa_criteria('GRID_MULTI_CARD');
  checks := checks || jsonb_build_object('check','QA_FORMAT_AWARE',
    'pass',(v_qa_ugc->'format_gates' <> v_qa_grid->'format_gates'
            AND v_qa_ugc->'universal_gates' ? 'PRODUCT_IDENTITY'
            AND v_qa_ugc->'universal_gates' ? 'CLAIM_SAFETY'),'detail',jsonb_build_object('ugc',v_qa_ugc->'format_gates','grid',v_qa_grid->'format_gates'));

  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='creative_production_requests' AND column_name='creative_format';
  checks := checks || jsonb_build_object('check','FORMAT_PERSISTENCE_COLUMN','pass',(v_n=1));

  SELECT count(*) INTO v_n FROM jsonb_array_elements(checks) c WHERE (c->>'pass')::boolean IS NOT TRUE;
  RETURN jsonb_build_object('ok',(v_n=0),'contract','creative_format_expansion_v1',
    'failed',v_n,'total',jsonb_array_length(checks),'checks',checks);
END; $function$;

-- mig_366d — Creative Studio one-click design-family routing (generate entry point)
--
-- fn_creative_studio_generate is the real "Generate Creative" entry point. Previously
-- it branched only on output_type (STATIC -> generic product-image job; VIDEO ->
-- cost-gated video job). SAAS_SOCIAL_SQUARE, being STATIC, fell through to the generic
-- product-image path (OpenAI gpt-image-1 edits), which is why the audit's live SAAS
-- request produced a GRID_MULTI_CARD-provenance image job that FAILED.
--
-- Now it branches on generation_system (from fn_creative_format_route):
--   VIDEO            -> existing cost-gated video path (unchanged)
--   PRODUCT_STATIC   -> existing product-static image path (unchanged; GRID etc.)
--   CI_DESIGN_FAMILY -> NEW: Creative Intelligence Design Director -> adaptive design
--                       family -> dispatch-ready generation contract -> Creative Studio
--                       review. Real premium image generation stays paid-gated.
--
-- Orchestration hierarchy: Creative Format -> Creative Director -> Design Family ->
-- Creative Candidate. Product Asset Lock is preserved end-to-end (the Design Director
-- embeds the Product Asset Lock rule whenever source_mode=CUSTOMER_PRODUCT).

-- Helper: shared result shape for a design-family request (fresh or reused). Surfaces
-- the adaptive family, the per-variant concepts, their dispatch-ready contracts and the
-- deterministic quality/safety gates. No paid provider call.
CREATE OR REPLACE FUNCTION public.fn_creative_studio_design_family_result(
  p_request_id uuid, p_set_id uuid, p_reused boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := auth.uid();
  r public.creative_production_requests%rowtype;
  v_variants jsonb;
BEGIN
  SELECT * INTO r FROM public.creative_production_requests WHERE id=p_request_id AND tenant_id=v_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','request_not_found_for_tenant'); END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'concept_id', c.id, 'label', c.concept_label, 'design_family', c.design_family,
      'design_family_label', c.concept_name, 'platform_target', c.platform_target,
      'review_state', c.review_state, 'headline', c.headline, 'cta_text', c.cta_text,
      'declares_real_assets', c.declares_real_assets,
      'product_asset_lock', c.generation_contract->'product_asset_lock',
      'quality_gate', public.fn_ci_design_family_gate(c.id),
      'truth_safety', public.fn_ci_concept_truth_gate(c.id),
      'dispatch', jsonb_build_object('webhook_path','pulse-saas-text-to-image',
                    'body', jsonb_build_object('job_id',c.id,'prompt',c.generation_contract->>'prompt')),
      'generation_contract', c.generation_contract
    ) ORDER BY c.concept_label), '[]'::jsonb)
    INTO v_variants
  FROM public.creative_concepts c
  WHERE c.set_id=p_set_id AND c.tenant_id=v_tenant;

  RETURN jsonb_build_object('ok',true,'reused',p_reused,'request_id',p_request_id,
    'creative_format', r.creative_format, 'output_type','STATIC',
    'generation_system','CI_DESIGN_FAMILY', 'job_kind','DESIGN_CONCEPT_SET',
    'concept_set_id', p_set_id, 'design_family', r.resolved_design_family,
    'design_family_variants', v_variants, 'generation_state', r.generation_state,
    'video_generation_paid_gated', false, 'image_generation_paid_gated', true, 'dispatched', false,
    'note','SAAS / business creative routed through the Creative Intelligence Design Director; the design family was selected adaptively and dispatch-ready generation contracts were produced. Real premium image generation is paid and held at the dispatch boundary (no spend). Concepts await Creative Studio review.');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_creative_studio_design_family_result(uuid,uuid,boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_creative_studio_generate(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := auth.uid();
  r public.creative_production_requests%rowtype;
  v_fmt public.creative_format_registry%rowtype;
  v_route jsonb; v_output text; v_system text;
  v_brief uuid; v_angle uuid; v_sel jsonb;
  cp record; v_input jsonb;
  v_card jsonb; v_asset_id uuid; v_url text; v_src_media uuid;
  v_job jsonb; v_job_id uuid; v_prep jsonb; v_disp jsonb; v_kind text; v_state text; v_cur text;
  v_fmt_ctx jsonb;
  -- design-family locals
  v_hyp jsonb; v_ptarget text; v_subject text; v_pname text; v_brief_ci jsonb; v_plan jsonb; v_set uuid; v_fam text;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO r FROM public.creative_production_requests WHERE id=p_request_id AND tenant_id=v_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','request_not_found_for_tenant'); END IF;
  IF r.creative_format IS NULL THEN RETURN jsonb_build_object('ok',false,'error','format_not_selected'); END IF;
  SELECT * INTO v_fmt FROM public.creative_format_registry WHERE format_key=r.creative_format AND enabled;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','unknown_format'); END IF;

  v_route := public.fn_creative_format_route(r.creative_format);
  v_output := v_route->>'output_type';
  v_system := v_route->>'generation_system';
  v_fmt_ctx := jsonb_build_object('format',v_fmt.format_key,'output_type',v_fmt.output_type,
    'generator_route',v_fmt.generator_route,'generation_system',v_system,
    'prompt_template',v_fmt.prompt_template,'storyboard_logic',v_fmt.storyboard_logic,'qa_criteria',v_fmt.qa_criteria);

  --------------------------------------------------------------------------
  -- CI DESIGN-FAMILY STATIC (e.g. SAAS_SOCIAL_SQUARE)
  --------------------------------------------------------------------------
  IF v_system = 'CI_DESIGN_FAMILY' THEN
    IF r.generated_concept_set_id IS NOT NULL THEN
      RETURN public.fn_creative_studio_design_family_result(p_request_id, r.generated_concept_set_id, true);
    END IF;

    v_hyp := coalesce(r.hypothesis,'{}'::jsonb);
    v_ptarget := CASE upper(coalesce(r.platform,'META'))
       WHEN 'META'           THEN 'META_FACEBOOK'
       WHEN 'FACEBOOK'       THEN 'META_FACEBOOK'
       WHEN 'META_FACEBOOK'  THEN 'META_FACEBOOK'
       WHEN 'INSTAGRAM'      THEN 'META_INSTAGRAM'
       WHEN 'META_INSTAGRAM' THEN 'META_INSTAGRAM'
       WHEN 'TIKTOK'         THEN 'TIKTOK'
       WHEN 'LINKEDIN'       THEN 'LINKEDIN'
       ELSE 'META_FACEBOOK' END;

    v_subject := 'Strateloq';
    IF upper(coalesce(r.source_mode,'BUSINESS_SELF'))='CUSTOMER_PRODUCT' AND r.product_id IS NOT NULL THEN
      SELECT title INTO v_pname FROM public.commerce_products WHERE id=r.product_id AND user_id=v_tenant;
      v_subject := coalesce(v_pname, v_subject);
    END IF;

    v_brief_ci := jsonb_strip_nulls(jsonb_build_object(
      'source_mode',        upper(coalesce(r.source_mode,'BUSINESS_SELF')),
      'subject',            v_subject,
      'business_objective', coalesce(r.objective, v_hyp->>'objective', v_hyp->>'business_objective', 'BRAND_AWARENESS'),
      'audience',           coalesce(v_hyp->>'audience', 'founders and growth teams'),
      'platform',           v_ptarget,
      'platform_target',    v_ptarget,
      'creative_format',    r.creative_format,
      'intelligence_type',  v_hyp->>'intelligence_type',
      'message_intent',     v_hyp->>'message_intent',
      'core_message',       v_hyp->>'core_message',
      'headline',           v_hyp->>'headline',
      'body_copy',          v_hyp->>'body_copy',
      'cta_text',           v_hyp->>'cta_text'));

    v_plan := public.fn_ci_design_director_plan(v_tenant, v_brief_ci, 2, v_tenant);
    IF coalesce(v_plan->>'ok','false') <> 'true' THEN
      UPDATE public.creative_production_requests SET generation_state='BLOCKED_DESIGN_FAMILY' WHERE id=p_request_id;
      RETURN jsonb_build_object('ok',false,'error','design_family_plan_failed','detail',v_plan,
        'creative_format',r.creative_format,'generation_system','CI_DESIGN_FAMILY');
    END IF;

    v_set := nullif(v_plan->>'set_id','')::uuid;
    v_fam := coalesce(v_plan->'variants'->0->>'design_family', v_plan->'design_families'->>0);
    UPDATE public.creative_production_requests
       SET generated_concept_set_id = v_set,
           resolved_design_family   = v_fam,
           generated_image_job_id   = NULL,   -- correct any prior mis-route to the product-image path
           generation_state         = 'GENERATED_REVIEW_REQUIRED'
     WHERE id=p_request_id;

    RETURN public.fn_creative_studio_design_family_result(p_request_id, v_set, false);
  END IF;

  --------------------------------------------------------------------------
  -- VIDEO reuse (unchanged, cost-gated)
  --------------------------------------------------------------------------
  IF v_output='VIDEO' AND r.generated_video_job_id IS NOT NULL THEN
    SELECT status INTO v_cur FROM public.media_video_jobs WHERE id=r.generated_video_job_id AND tenant_id=v_tenant;
    IF v_cur IN ('GENERATING','GENERATED_REVIEW_REQUIRED','BLOCKED_CLAIM_REVIEW','BLOCKED_RIGHTS','BLOCKED_ASPECT','BLOCKED_EXTERNAL_PROVIDER') THEN
      v_state := v_cur;
    ELSE
      v_prep := public.fn_media_prepare_video_job(r.generated_video_job_id, v_tenant);
      v_state := v_prep->>'status';
    END IF;
    UPDATE public.creative_production_requests SET generation_state=v_state WHERE id=p_request_id;
    RETURN jsonb_build_object('ok',true,'reused',true,'request_id',p_request_id,'creative_format',r.creative_format,
      'output_type','VIDEO','generation_system','VIDEO','job_kind','VIDEO','job_id',r.generated_video_job_id,'brief_id',r.brief_id,
      'angle_id',r.angle_id,'generation_state',v_state,'prepare',v_prep,'video_generation_paid_gated',true);
  END IF;

  --------------------------------------------------------------------------
  -- PRODUCT STATIC reuse (unchanged)
  --------------------------------------------------------------------------
  IF v_output='STATIC' AND r.generated_image_job_id IS NOT NULL THEN
    SELECT status INTO v_cur FROM public.media_image_jobs WHERE id=r.generated_image_job_id AND tenant_id=v_tenant;
    IF v_cur IN ('GENERATING','GENERATED_REVIEW_REQUIRED','GENERATED_REAL','REVIEW_REQUIRED',
                 'BLOCKED_CLAIM_REVIEW','BLOCKED_EXTERNAL_PROVIDER','FAILED') THEN
      v_state := v_cur;
    ELSIF v_cur = 'READY_TO_DISPATCH' THEN
      v_disp := public.fn_media_dispatch_image_job(r.generated_image_job_id, v_tenant);
      v_state := v_disp->>'status';
      IF v_state='GENERATING' THEN PERFORM public.fn_creative_fire_image_executor(r.generated_image_job_id); END IF;
    ELSE
      v_prep := public.fn_media_prepare_image_job(r.generated_image_job_id, v_tenant);
      IF v_prep->>'status' = 'READY_TO_DISPATCH' THEN
        v_disp := public.fn_media_dispatch_image_job(r.generated_image_job_id, v_tenant);
        v_state := v_disp->>'status';
        IF v_state='GENERATING' THEN PERFORM public.fn_creative_fire_image_executor(r.generated_image_job_id); END IF;
      ELSE v_state := v_prep->>'status'; END IF;
    END IF;
    UPDATE public.creative_production_requests SET generation_state=v_state WHERE id=p_request_id;
    RETURN jsonb_build_object('ok',true,'reused',true,'request_id',p_request_id,'creative_format',r.creative_format,
      'output_type','STATIC','generation_system','PRODUCT_STATIC','job_kind','IMAGE','job_id',r.generated_image_job_id,'brief_id',r.brief_id,
      'angle_id',r.angle_id,'generation_state',v_state,'dispatch',v_disp,'video_generation_paid_gated',false);
  END IF;

  --------------------------------------------------------------------------
  -- Brief + angle (product static / video paths)
  --------------------------------------------------------------------------
  v_brief := r.brief_id; v_angle := r.angle_id;
  IF v_angle IS NULL THEN
    IF v_brief IS NULL THEN
      SELECT id,user_id,title,category,description,extended INTO cp
        FROM public.commerce_products WHERE id=r.product_id AND user_id=v_tenant;
      IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant'); END IF;
      v_input := jsonb_build_object(
        'product_id', r.product_id::text, 'decision_id', coalesce(r.decision_id::text,''),
        'market', r.market, 'product_name', cp.title,
        'product_description', coalesce(cp.description,''), 'destination_url', '');
      v_brief := public.fn_ad_studio_build_brief(v_tenant, v_input, false);
    END IF;
    PERFORM public.fn_ad_studio_generate_angles(v_brief);
    v_sel := public.fn_ad_studio_select_test_angle(v_brief);
    v_angle := nullif(v_sel->>'selected_angle_id','')::uuid;
    IF v_angle IS NULL THEN RETURN jsonb_build_object('ok',false,'error','angle_generation_failed','detail',v_sel); END IF;
    UPDATE public.creative_production_requests SET brief_id=v_brief, angle_id=v_angle WHERE id=p_request_id;
  END IF;

  IF v_output='STATIC' THEN
    v_job := public.fn_media_create_image_job(v_tenant, v_angle);
    v_job_id := nullif(v_job->>'job_id','')::uuid;
    IF v_job_id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','image_job_create_failed','detail',v_job); END IF;
    UPDATE public.media_image_jobs
      SET provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('creative_format', v_fmt_ctx)
      WHERE id=v_job_id;
    v_prep := public.fn_media_prepare_image_job(v_job_id, v_tenant);
    IF v_prep->>'status' = 'READY_TO_DISPATCH' THEN
      v_disp := public.fn_media_dispatch_image_job(v_job_id, v_tenant);
      v_state := v_disp->>'status';
      IF v_state='GENERATING' THEN PERFORM public.fn_creative_fire_image_executor(v_job_id); END IF;
    ELSE
      v_state := v_prep->>'status';
    END IF;
    v_kind := 'IMAGE';
    UPDATE public.creative_production_requests SET generated_image_job_id=v_job_id, generation_state=v_state WHERE id=p_request_id;
  ELSE
    v_card := public.fn_ad_product_card_select_creative_asset(v_tenant, r.product_id, r.market, '{}'::jsonb, false);
    IF (v_card->>'status') <> 'ok' THEN
      UPDATE public.creative_production_requests SET generation_state='BLOCKED_NO_PRODUCT_ASSET' WHERE id=p_request_id;
      RETURN jsonb_build_object('ok',false,'error','no_authoritative_product_asset','detail',v_card);
    END IF;
    v_asset_id := nullif(v_card->>'selected_product_card_asset_id','')::uuid;
    SELECT image_url INTO v_url FROM public.product_image_assets WHERE id=v_asset_id;
    v_src_media := public.fn_media_register_source_asset(
      v_tenant, r.product_id, NULL, 'PRODUCT_CARD', 'SUPPLIER_PROVIDED', v_url, NULL, NULL,
      jsonb_build_object('product_card_asset_id', v_asset_id::text, 'source','fn_creative_studio_generate',
                         'identity','AUTHORITATIVE_PRODUCT_CARD', 'card_identity', v_card->'card_identity'));
    v_job := public.fn_media_create_video_job(v_tenant, v_angle, v_src_media,
      CASE WHEN r.platform='TIKTOK' THEN 'TIKTOK_FEED' ELSE coalesce(r.platform,'META') END);
    v_job_id := nullif(v_job->>'video_job_id','')::uuid;
    IF v_job_id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','video_job_create_failed','detail',v_job); END IF;
    UPDATE public.media_video_jobs
      SET provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('creative_format', v_fmt_ctx)
      WHERE id=v_job_id;
    v_prep := public.fn_media_prepare_video_job(v_job_id, v_tenant);
    v_kind := 'VIDEO'; v_state := v_prep->>'status';
    UPDATE public.creative_production_requests SET generated_video_job_id=v_job_id, generation_state=v_state WHERE id=p_request_id;
  END IF;

  RETURN jsonb_build_object('ok',true,'request_id',p_request_id,'creative_format',r.creative_format,
    'output_type',v_output,'generation_system',v_system,'job_kind',v_kind,'job_id',v_job_id,'brief_id',v_brief,'angle_id',v_angle,
    'generation_state',v_state,'prepare',v_prep,'dispatch',v_disp,'video_generation_paid_gated',(v_output='VIDEO'),
    'note', CASE WHEN v_output='STATIC'
      THEN 'Static product creative dispatched and the executor was triggered automatically; job is GENERATING and completes via the Creative Image Executor.'
      ELSE 'Video creative prepared up to the paid dispatch boundary; real Gemini Omni/Veo generation remains founder cost-gated (BLOCKED_EXTERNAL_DEPENDENCY).' END);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_creative_studio_generate(uuid) TO authenticated, service_role;

-- STRATELOQ — Creative Studio STATIC auto-dispatch (fix "stuck at Preparing product assets")
-- ============================================================================
-- Root cause: fn_creative_studio_generate prepared STATIC image jobs to
-- READY_TO_DISPATCH but never dispatched them, so the job never entered the
-- executor queue and the frontend stayed on "Preparing product assets".
--
-- Fix: for STATIC (IMAGE) output the bridge now continues automatically through
-- the EXISTING dispatch path (fn_media_dispatch_image_job), moving the job to
-- GENERATING (an async in-progress state the executor picks up). No new image
-- generator is created. The SECURITY DEFINER bridge (owned by postgres) may call
-- the service_role-only dispatch internally; the browser never gains service_role.
--
-- Idempotency: a job already GENERATING or completed is never re-prepared/reset and
-- never re-dispatched (dispatch itself returns ALREADY_GENERATING/ALREADY_COMPLETE).
--
-- VIDEO is deliberately unchanged: it stays at READY_TO_DISPATCH (paid Gemini/Veo
-- dispatch remains founder cost-gated, BLOCKED_EXTERNAL_DEPENDENCY).
--
-- The actual OpenAI (gpt-image-1) execution + upload + fn_media_complete_image_real
-- runs in the existing "Creative Image Generation" n8n executor (edge->n8n webhook
-- pattern, like prepare-product). This migration takes the job to GENERATING; the
-- executor auto-trigger is handled by the accompanying edge function + env config.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_creative_studio_generate(p_request_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := auth.uid();
  r public.creative_production_requests%rowtype;
  v_fmt public.creative_format_registry%rowtype;
  v_route jsonb; v_output text;
  v_brief uuid; v_angle uuid; v_sel jsonb;
  cp record; v_input jsonb;
  v_card jsonb; v_asset_id uuid; v_url text; v_src_media uuid;
  v_job jsonb; v_job_id uuid; v_prep jsonb; v_disp jsonb; v_kind text; v_state text; v_cur text;
  v_fmt_ctx jsonb;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO r FROM public.creative_production_requests WHERE id=p_request_id AND tenant_id=v_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','request_not_found_for_tenant'); END IF;
  IF r.creative_format IS NULL THEN RETURN jsonb_build_object('ok',false,'error','format_not_selected'); END IF;
  SELECT * INTO v_fmt FROM public.creative_format_registry WHERE format_key=r.creative_format AND enabled;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','unknown_format'); END IF;

  v_route := public.fn_creative_format_route(r.creative_format);
  v_output := v_route->>'output_type';
  v_fmt_ctx := jsonb_build_object('format',v_fmt.format_key,'output_type',v_fmt.output_type,
    'prompt_template',v_fmt.prompt_template,'storyboard_logic',v_fmt.storyboard_logic,'qa_criteria',v_fmt.qa_criteria);

  -- Idempotent reuse: VIDEO (stays at pre-paid boundary) ----
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
      'output_type','VIDEO','job_kind','VIDEO','job_id',r.generated_video_job_id,'brief_id',r.brief_id,
      'angle_id',r.angle_id,'generation_state',v_state,'prepare',v_prep,'video_generation_paid_gated',true);
  END IF;

  -- Idempotent reuse: STATIC (never reset a GENERATING/complete job; dispatch only when READY) ----
  IF v_output='STATIC' AND r.generated_image_job_id IS NOT NULL THEN
    SELECT status INTO v_cur FROM public.media_image_jobs WHERE id=r.generated_image_job_id AND tenant_id=v_tenant;
    IF v_cur IN ('GENERATING','GENERATED_REVIEW_REQUIRED','GENERATED_REAL','REVIEW_REQUIRED',
                 'BLOCKED_CLAIM_REVIEW','BLOCKED_EXTERNAL_PROVIDER','FAILED') THEN
      v_state := v_cur;
    ELSIF v_cur = 'READY_TO_DISPATCH' THEN
      v_disp := public.fn_media_dispatch_image_job(r.generated_image_job_id, v_tenant);
      v_state := v_disp->>'status';
    ELSE
      v_prep := public.fn_media_prepare_image_job(r.generated_image_job_id, v_tenant);
      IF v_prep->>'status' = 'READY_TO_DISPATCH' THEN
        v_disp := public.fn_media_dispatch_image_job(r.generated_image_job_id, v_tenant);
        v_state := v_disp->>'status';
      ELSE v_state := v_prep->>'status'; END IF;
    END IF;
    UPDATE public.creative_production_requests SET generation_state=v_state WHERE id=p_request_id;
    RETURN jsonb_build_object('ok',true,'reused',true,'request_id',p_request_id,'creative_format',r.creative_format,
      'output_type','STATIC','job_kind','IMAGE','job_id',r.generated_image_job_id,'brief_id',r.brief_id,
      'angle_id',r.angle_id,'generation_state',v_state,'dispatch',v_disp,'video_generation_paid_gated',false);
  END IF;

  -- request -> brief -> angle linkage (idempotent via stored ids) ----
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
    -- AUTO-DISPATCH: continue automatically to the real dispatch path (READY_TO_DISPATCH -> GENERATING)
    IF v_prep->>'status' = 'READY_TO_DISPATCH' THEN
      v_disp := public.fn_media_dispatch_image_job(v_job_id, v_tenant);
      v_state := v_disp->>'status';
    ELSE
      v_state := v_prep->>'status';
    END IF;
    v_kind := 'IMAGE';
    UPDATE public.creative_production_requests SET generated_image_job_id=v_job_id, generation_state=v_state WHERE id=p_request_id;
  ELSE
    -- VIDEO: authoritative Product Card asset -> media source asset -> video job (NO auto-dispatch; paid boundary)
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
    'output_type',v_output,'job_kind',v_kind,'job_id',v_job_id,'brief_id',v_brief,'angle_id',v_angle,
    'generation_state',v_state,'prepare',v_prep,'dispatch',v_disp,'video_generation_paid_gated',(v_output='VIDEO'),
    'note', CASE WHEN v_output='STATIC'
      THEN 'Static creative dispatched automatically; job is GENERATING and will complete via the Creative Image executor.'
      ELSE 'Video creative prepared up to the paid dispatch boundary; real Gemini Omni/Veo generation remains founder cost-gated (BLOCKED_EXTERNAL_DEPENDENCY).' END);
END; $function$;

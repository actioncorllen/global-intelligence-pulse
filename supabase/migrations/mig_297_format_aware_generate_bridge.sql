-- STRATELOQ — FORMAT-AWARE GENERATE CREATIVE BRIDGE
-- ============================================================================
-- Connects the (previously decoupled) creative_format selection to the actual
-- angle-based generation pipeline, up to — but never crossing — the paid
-- Gemini Omni / Veo dispatch boundary. Reuses the existing (founder-locked)
-- functions as black boxes; no frozen function's behaviour is reimplemented.
--
-- Fixes wired in this unit (all required for the requested end-to-end workflow):
--   * request -> brief -> angle linkage (was missing)
--   * creative_format -> job linkage (format carried into job provenance)
--   * AUTO/MANUAL provenance persistence (mode + reason columns)
--   * authoritative Product Card asset -> media source asset -> video job
--   * generation status/lifecycle linkage on the request
--   * idempotency (reuse brief/angle/job on re-run; never duplicates)
--   * grant hardening (tenant-write RPCs revoked from anon/public)
--   * tenant safety (bridge + apply derive tenant from auth.uid(), never trust caller)
--
-- Tenant model note: the creative/ecom subsystem keys tenant by auth.uid()
-- (commerce_products.user_id, media_video_jobs.tenant_id, fn_ad_product_card_authority),
-- NOT by member.application_ref (which is the social-OAuth tenant). The bridge
-- therefore derives tenant = auth.uid().
--
-- Paid boundary: fn_media_prepare_*_job DO NOT call a provider (they gate/estimate
-- and set READY_TO_DISPATCH). The paid call happens only at fn_media_dispatch_*_job
-- (n8n). This bridge stops at READY_TO_DISPATCH; video real generation stays
-- BLOCKED_EXTERNAL_DEPENDENCY (founder cost approval).
--
-- Reversible: drop fn_creative_studio_generate, restore the 3-arg
-- fn_creative_format_apply, and drop the added creative_production_requests columns.
-- ============================================================================

-- 1) Additive linkage + provenance columns on the request ----
ALTER TABLE public.creative_production_requests
  ADD COLUMN IF NOT EXISTS creative_format_mode   text,
  ADD COLUMN IF NOT EXISTS creative_format_reason text,
  ADD COLUMN IF NOT EXISTS brief_id               uuid REFERENCES public.ad_studio_briefs(id)   ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS angle_id               uuid REFERENCES public.ad_studio_angles(id)   ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS generated_video_job_id uuid REFERENCES public.media_video_jobs(id)   ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS generated_image_job_id uuid REFERENCES public.media_image_jobs(id)   ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS generation_state       text;

-- 2) Harden the format setter: derive tenant from auth.uid(); persist AUTO mode/reason ----
DROP FUNCTION IF EXISTS public.fn_creative_format_apply(uuid, uuid, text);
CREATE OR REPLACE FUNCTION public.fn_creative_format_apply(
  p_tenant uuid, p_request_id uuid, p_format text, p_mode text DEFAULT NULL, p_reason text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); v_valid boolean; v_exists boolean;
BEGIN
  -- p_tenant is accepted for call-site compatibility but IGNORED: authority is auth.uid().
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT exists(SELECT 1 FROM public.creative_format_registry WHERE format_key=p_format AND enabled) INTO v_valid;
  IF NOT v_valid THEN RETURN jsonb_build_object('ok',false,'error','unknown_format'); END IF;
  UPDATE public.creative_production_requests
     SET creative_format=p_format,
         creative_format_mode=coalesce(p_mode, creative_format_mode),
         creative_format_reason=coalesce(p_reason, creative_format_reason)
   WHERE id=p_request_id AND tenant_id=v_tenant
  RETURNING true INTO v_exists;
  IF NOT coalesce(v_exists,false) THEN RETURN jsonb_build_object('ok',false,'error','request_not_found_for_tenant'); END IF;
  RETURN jsonb_build_object('ok',true,'request_id',p_request_id,'creative_format',p_format,'mode',p_mode);
END; $function$;

-- 3) THE BRIDGE: format-aware generate up to the paid dispatch boundary ----
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
  v_job jsonb; v_job_id uuid; v_prep jsonb; v_kind text; v_state text;
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

  -- Idempotency: reuse an existing job (re-prepare is itself idempotent) ----
  IF v_output='VIDEO' AND r.generated_video_job_id IS NOT NULL THEN
    v_prep := public.fn_media_prepare_video_job(r.generated_video_job_id, v_tenant);
    UPDATE public.creative_production_requests SET generation_state=v_prep->>'status' WHERE id=p_request_id;
    RETURN jsonb_build_object('ok',true,'reused',true,'request_id',p_request_id,'creative_format',r.creative_format,
      'output_type','VIDEO','job_kind','VIDEO','job_id',r.generated_video_job_id,'brief_id',r.brief_id,
      'angle_id',r.angle_id,'generation_state',v_prep->>'status','prepare',v_prep,'video_generation_paid_gated',true);
  END IF;
  IF v_output='STATIC' AND r.generated_image_job_id IS NOT NULL THEN
    v_prep := public.fn_media_prepare_image_job(r.generated_image_job_id, v_tenant);
    UPDATE public.creative_production_requests SET generation_state=v_prep->>'status' WHERE id=p_request_id;
    RETURN jsonb_build_object('ok',true,'reused',true,'request_id',p_request_id,'creative_format',r.creative_format,
      'output_type','STATIC','job_kind','IMAGE','job_id',r.generated_image_job_id,'brief_id',r.brief_id,
      'angle_id',r.angle_id,'generation_state',v_prep->>'status','prepare',v_prep,'video_generation_paid_gated',false);
  END IF;

  -- request -> brief -> angle linkage (idempotent via stored ids) ----
  v_brief := r.brief_id; v_angle := r.angle_id;
  IF v_angle IS NULL THEN
    IF v_brief IS NULL THEN
      SELECT id,user_id,title,category,description,extended INTO cp
        FROM public.commerce_products WHERE id=r.product_id AND user_id=v_tenant;
      IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant'); END IF;
      v_input := jsonb_build_object(
        'product_id', r.product_id::text,
        'decision_id', coalesce(r.decision_id::text,''),
        'market', r.market,
        'product_name', cp.title,
        'product_description', coalesce(cp.description,''),
        'destination_url', '');
      v_brief := public.fn_ad_studio_build_brief(v_tenant, v_input, false);
    END IF;
    PERFORM public.fn_ad_studio_generate_angles(v_brief);
    v_sel := public.fn_ad_studio_select_test_angle(v_brief);
    v_angle := nullif(v_sel->>'selected_angle_id','')::uuid;
    IF v_angle IS NULL THEN RETURN jsonb_build_object('ok',false,'error','angle_generation_failed','detail',v_sel); END IF;
    UPDATE public.creative_production_requests SET brief_id=v_brief, angle_id=v_angle WHERE id=p_request_id;
  END IF;

  IF v_output='STATIC' THEN
    -- STATIC routes to the entitled image pipeline (available now) ----
    v_job := public.fn_media_create_image_job(v_tenant, v_angle);
    v_job_id := nullif(v_job->>'job_id','')::uuid;
    IF v_job_id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','image_job_create_failed','detail',v_job); END IF;
    UPDATE public.media_image_jobs
      SET provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('creative_format', v_fmt_ctx)
      WHERE id=v_job_id;
    v_prep := public.fn_media_prepare_image_job(v_job_id, v_tenant);
    v_kind := 'IMAGE'; v_state := v_prep->>'status';
    UPDATE public.creative_production_requests SET generated_image_job_id=v_job_id, generation_state=v_state WHERE id=p_request_id;
  ELSE
    -- VIDEO: authoritative Product Card asset -> media source asset -> video job ----
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
    'generation_state',v_state,'prepare',v_prep,'video_generation_paid_gated',(v_output='VIDEO'),
    'note', CASE WHEN v_output='STATIC'
      THEN 'Static creative prepared to READY_TO_DISPATCH (a single paid image call happens only at dispatch).'
      ELSE 'Video creative prepared up to the paid dispatch boundary; real Gemini Omni/Veo generation remains founder cost-gated (BLOCKED_EXTERNAL_DEPENDENCY).' END);
END; $function$;

-- 4) Grants + hardening (tenant-write RPCs must not be anon-callable) ----
GRANT EXECUTE ON FUNCTION public.fn_creative_studio_generate(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_creative_studio_generate(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_creative_format_apply(uuid,uuid,text,text,text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_creative_format_apply(uuid,uuid,text,text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_creative_production_request(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_creative_production_request(uuid, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_creative_production_request(uuid,text,uuid,uuid,text,text,text,text,jsonb,jsonb,jsonb,jsonb,boolean,boolean,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_creative_production_request(uuid,text,uuid,uuid,text,text,text,text,jsonb,jsonb,jsonb,jsonb,boolean,boolean,boolean) TO authenticated, service_role;

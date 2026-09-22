-- ============================================================================
-- mig_278_provider_invisible_creative_read.sql
-- STRATELOQ-AI-AD-CREATIVE-STUDIO-015G.2
-- Provider-invisible customer contract (tiny, additive).
--
-- Product principle: customers never connect or see a generation provider.
-- The Creative Studio browser-safe read must expose generation TYPE / STATE /
-- review / cost — never the internal provider name. Runtime provider SELECTION
-- was already capability-based (fn_media_provider_for('VIDEO'), never a
-- hardcoded provider), so this only masks the leaked provider name in
-- fn_ad_studio_creative_read behind a generic renderer label.
--
-- No selection logic changed. No paid call. No new provider.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_ad_studio_creative_read(p_angle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE v_uid uuid := auth.uid(); a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_variants jsonb; v_job public.media_image_jobs%rowtype; v_asset jsonb;
  v_vjob public.media_video_jobs%rowtype; v_scenes jsonb; v_vasset jsonb; v_video jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF a.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object('platform',platform,'placement',placement,'hook',hook,
           'cta',cta,'aspect_ratio',aspect_ratio,'opening_seconds',opening_seconds,
           'claim_violations',claim_violations) ORDER BY platform),'[]'::jsonb) INTO v_variants
  FROM public.ad_studio_platform_variants WHERE angle_id=p_angle_id;

  SELECT * INTO v_job FROM public.media_image_jobs WHERE angle_id=p_angle_id ORDER BY created_at DESC LIMIT 1;
  IF v_job.id IS NOT NULL AND jsonb_array_length(coalesce(v_job.output_asset_refs,'[]'::jsonb)) > 0 THEN
    v_asset := public.fn_media_generation_result((v_job.output_asset_refs->>0)::uuid);
  END IF;

  -- VIDEO section (provider name masked behind a generic Strateloq renderer)
  SELECT * INTO v_vjob FROM public.media_video_jobs WHERE angle_id=p_angle_id ORDER BY created_at DESC LIMIT 1;
  IF v_vjob.id IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('scene_number',scene_number,'duration_target',duration_target,
             'visual_action',visual_action,'motion_instruction',motion_instruction,'text_overlay',text_overlay,
             'voiceover',voiceover,'transition',transition,'claim_violations',claim_violations) ORDER BY scene_number),'[]'::jsonb)
      INTO v_scenes FROM public.media_video_scenes WHERE video_job_id=v_vjob.id;
    IF v_vjob.video_asset_ref IS NOT NULL THEN
      v_vasset := public.fn_media_generation_result(v_vjob.video_asset_ref);
    END IF;
    v_video := jsonb_build_object('job_id',v_vjob.id,'state',v_vjob.status,
      'renderer','STRATELOQ_CREATIVE_STUDIO','generation_type','IMAGE_TO_VIDEO',
      'platform',v_vjob.platform,'duration_s',v_vjob.duration_target,'aspect_ratio',v_vjob.aspect_ratio,
      'estimated_cost',v_vjob.estimated_cost,'actual_cost',v_vjob.actual_cost,'cost_currency',v_vjob.cost_currency,
      'lineage_state',v_vjob.lineage_state,'failure_reason',v_vjob.error_state,
      'claim_gate', v_vjob.provenance->'claim_gate','product_identity', v_vjob.provenance->'product_identity',
      'storyboard', v_scenes, 'asset', coalesce(v_vasset,'null'::jsonb));
  ELSE
    v_video := jsonb_build_object('state','NONE');
  END IF;

  RETURN jsonb_build_object('status','ok',
    'brief', jsonb_build_object('brief_id',b.id,'product_name',b.product_name,'market',b.market,
        'problem_solved',b.problem_solved,'platform_targets',b.platform_targets,'evidence_completeness',b.evidence_completeness,
        'lineage_state',b.lineage_state),
    'concept', jsonb_build_object('angle_id',a.id,'angle_type',a.angle_type,'hook',a.hook,'headline',a.headline,
        'primary_copy',a.primary_copy,'cta',a.cta,'visual_concept',a.visual_concept,'video_hook',a.video_hook,
        'claim_risk',a.claim_risk,'claim_violations',a.claim_violations,'review_state',a.review_state),
    'platform_variants', v_variants,
    'generation', CASE WHEN v_job.id IS NULL THEN jsonb_build_object('state','NONE')
      ELSE jsonb_build_object('job_id',v_job.id,'state',v_job.status,
        'renderer','STRATELOQ_CREATIVE_STUDIO','generation_type','IMAGE_EDIT_FROM_PRODUCT_ASSET',
        'estimated_cost',v_job.estimated_cost,'actual_cost',v_job.actual_cost,'cost_currency',v_job.cost_currency,
        'failure_reason',v_job.error_state,
        'claim_gate', v_job.provenance->'claim_gate',
        'product_identity', v_job.provenance->'product_identity') END,
    'asset', coalesce(v_asset, 'null'::jsonb),
    'video', v_video,
    'contract','ad_creative_read_v3_015g2; provider-invisible (renderer=STRATELOQ_CREATIVE_STUDIO); generation type/state/cost/identity/claim/lineage surfaced; internal provider name never exposed to customers');
END; $fn$;

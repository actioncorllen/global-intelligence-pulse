-- ============================================================================
-- mig_288_native_video_compositor.sql
-- STRATELOQ-015S — Strateloq-OWNED native automated video composition engine.
-- Founder decision changed: NATIVE_AUTOMATED_VIDEO_COMPOSITION = BETA_REQUIRED
-- (was BETA_COMPOSITION_DEFERRED_BY_FOUNDER). This records that the composition
-- provider is now IMPLEMENTED with an open-source FFmpeg renderer that runs in
-- the controlled runtime (no external editing/composition SaaS, no subscription),
-- and captures the scene contract, motion ops, transitions, typography and the
-- GENERATION_COST vs COMPOSITION_COST separation. Idempotent. Preserves the
-- static system and all identity/claim gates.
-- ============================================================================

UPDATE public.media_providers
SET enabled = true,
    media_type = 'VIDEO',
    config = jsonb_build_object(
      'role', 'RENDERER',
      'renderer', 'FFMPEG (open-source; static build via imageio-ffmpeg; local/server-side; scriptable)',
      'ownership', 'STRATELOQ_OWNED',
      'external_subscription', 'NONE',
      'automation', 'NATIVE_AUTOMATED_VIDEO_COMPOSITION',
      'beta_status', 'BETA_REQUIRED',
      'implemented', true,
      'engine_path', 'scripts/compositor/pulse_compositor.py',
      'not_a_manual_editor', 'This is an automated ad-production compositor, NOT a Filmora/CapCut/Premiere/timeline editor and NOT a paid editing SaaS (Shotstack/Creatomate/Zeely/Remotion excluded).',
      'scene_types', jsonb_build_array('IMAGE_SCENE','VIDEO_SCENE','TEXT_SCENE','CTA_SCENE'),
      'motion_ops', jsonb_build_array('ken_burns_push_in','pull_out','parallax_star_drift','fade','crossfade','scale_transition','warm_glow_treatment','deterministic_product_placement'),
      'transitions', jsonb_build_array('crossfade(xfade)'),
      'typography', jsonb_build_object('deterministic', true, 'fonts', jsonb_build_array('LiberationSans-Bold','LiberationSans-Regular'),
         'supports', jsonb_build_array('headline','supporting','kicker','caption','cta_pill'), 'safe_margins', true),
      'audio', jsonb_build_object('future_supported', true, 'tracks', jsonb_build_array('voice','music'), 'first_proof', 'none (optional, zero-cost)'),
      'output', jsonb_build_object('container','mp4','codec','h264','pix_fmt','yuv420p','aspect','9:16','resolution','1080x1920','fps',30,'audio_codec_when_present','aac'),
      'product_identity', jsonb_build_object(
         'image_scenes', 'exact Product Card pixels; deterministic scale/crop/position/mask/alpha/shadow/pan/zoom only; NO redraw',
         'video_scenes', 'reused generative clip (e.g. 015R Veo) stays IDENTITY_REVIEW_REQUIRED; not treated as authoritative product pixels'),
      'cost_model', jsonb_build_object(
         'generation_cost', 'tracked SEPARATELY (external media generation, e.g. Veo); reused assets add $0',
         'composition_cost', '$0 external API; local/server compute only; MUST NOT be represented as a paid editing-service charge'),
      'security', 'server-side/authenticated asset retrieval; never requires public Product Card media; no service-role/provider/storage secrets exposed; tenant isolation mandatory',
      'runtime_host', 'controlled runtime with bundled static FFmpeg 7.0.2 (johnvansickle build via imageio-ffmpeg); no new infrastructure, no subscription',
      'runtime_status', 'NATIVE_COMPOSITOR_IMPLEMENTED (2026-09-23) — renders locally/server-side; first 015S native-composited ad produced at USD 0.00 composition cost, reusing the 015R Veo clip + Product Card stills.',
      'secret_storage', 'server_side_only'
    )
WHERE name = 'STRATELOQ_VIDEO_COMPOSITION';

-- Lightweight, non-mutating selftest for the native compositor contract.
CREATE OR REPLACE FUNCTION public.fn_media_native_composition_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE c jsonb; v_pass int:=0; v_fail int:=0; v_checks jsonb:='[]'::jsonb;
BEGIN
  SELECT config INTO c FROM public.media_providers WHERE name='STRATELOQ_VIDEO_COMPOSITION';

  IF c IS NOT NULL THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('provider_registered',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('provider_registered',false); END IF;

  IF (c->>'ownership')='STRATELOQ_OWNED' AND (c->>'external_subscription')='NONE'
     AND (c->>'renderer') LIKE 'FFMPEG%' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('owned_open_source_no_saas',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('owned_open_source_no_saas',false); END IF;

  IF (c->'scene_types') @> '["IMAGE_SCENE","VIDEO_SCENE","TEXT_SCENE","CTA_SCENE"]'::jsonb
     THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('scene_contract_present',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('scene_contract_present',false); END IF;

  IF (c->'cost_model' ? 'generation_cost') AND (c->'cost_model' ? 'composition_cost')
     THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('cost_model_separated',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('cost_model_separated',false); END IF;

  IF (c->'product_identity'->>'video_scenes') ILIKE '%IDENTITY_REVIEW_REQUIRED%'
     AND (c->'product_identity'->>'image_scenes') ILIKE '%NO redraw%'
     THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('identity_rules_intact',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('identity_rules_intact',false); END IF;

  RETURN jsonb_build_object('suite','media_native_composition','pass',v_pass,'fail',v_fail,'all_pass',(v_fail=0),'checks',v_checks);
END; $fn$;

-- ============================================================================
-- mig_279_ad_production_engine_foundation.sql
-- STRATELOQ-AI-AD-CREATIVE-STUDIO-015H — Ad Production Engine foundation.
-- Governed by docs/STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md (LOCKED).
--
-- Provider-independent, server-authoritative CREATIVE PRODUCTION PLAN + quality-
-- gate contracts. ADDITIVE extension of existing ad_studio_* / media_video_*
-- structures — NO parallel architecture, NO provider connected, NO generation.
--
-- Scope (buildable now): the production-PLAN data model (scene types, per-scene
-- generation requirement, deterministic treatment/caption/CTA/brand/audio intent,
-- provider-independent capability request) + the 14-gate quality contract +
-- browser-safe read + selftest. The actual VIDEO composition/render backend
-- (multi-scene assembly, motion, transitions, audio mux, mp4 encode) is NOT built
-- here — no FFmpeg runtime exists in Supabase edge (Deno) or n8n Cloud; that
-- render executor is a future execution surface. Deterministic IMAGE composition
-- (captions, 9:16 canvas, CTA cards, overlays) is available via n8n Edit Image.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Additive production fields on media_video_scenes (the scene = the plan unit)
-- ---------------------------------------------------------------------------
ALTER TABLE public.media_video_scenes
  ADD COLUMN IF NOT EXISTS scene_type text NOT NULL DEFAULT 'SOURCE_ASSET_MOTION',
  ADD COLUMN IF NOT EXISTS generation_requirement text NOT NULL DEFAULT 'NO_GENERATION',
  ADD COLUMN IF NOT EXISTS required_capability text,
  ADD COLUMN IF NOT EXISTS treatment jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS caption jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS cta text,
  ADD COLUMN IF NOT EXISTS brand_treatment jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS audio_intent text NOT NULL DEFAULT 'VISUAL_ONLY',
  ADD COLUMN IF NOT EXISTS render_state text NOT NULL DEFAULT 'PLANNED';

DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='media_video_scenes_scene_type_chk') THEN
    ALTER TABLE public.media_video_scenes ADD CONSTRAINT media_video_scenes_scene_type_chk
      CHECK (scene_type = ANY (ARRAY['SOURCE_ASSET_MOTION','GENERATIVE_IMAGE_TO_VIDEO','STATIC_PRODUCT_SCENE',
        'UI_SCREENSHOT_MOTION','SCREEN_RECORDING','TEXT_HOOK','PRODUCT_DEMO','TRANSFORMATION','CTA_END_CARD']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='media_video_scenes_genreq_chk') THEN
    ALTER TABLE public.media_video_scenes ADD CONSTRAINT media_video_scenes_genreq_chk
      CHECK (generation_requirement = ANY (ARRAY['NO_GENERATION','IMAGE_GENERATION','VIDEO_GENERATION']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='media_video_scenes_audio_chk') THEN
    ALTER TABLE public.media_video_scenes ADD CONSTRAINT media_video_scenes_audio_chk
      CHECK (audio_intent = ANY (ARRAY['VOICEOVER','MUSIC','SFX','VISUAL_ONLY']));
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- 2. fn_ad_build_production_plan: deterministically populate the per-scene
--    production plan on the latest video job for an angle. Additive; reuses the
--    existing storyboard. Provider-INDEPENDENT (generative scenes request a
--    capability, never a provider name). No generation, no provider call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_build_production_plan(p_tenant uuid, p_angle_id uuid, p_platform text)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype; j public.media_video_jobs%rowtype;
  s public.media_video_scenes%rowtype; v_has_brand boolean; v_stype text; v_genreq text; v_cap text;
  v_treat jsonb; v_cap_spec jsonb; n int; v_total int;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  SELECT * INTO j FROM public.media_video_jobs WHERE angle_id=p_angle_id AND tenant_id=p_tenant ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_video_job','note','create a video job (storyboard/scenes) first via fn_media_create_video_job'); END IF;

  SELECT EXISTS(SELECT 1 FROM public.member_business_dna d WHERE d.user_id=p_tenant) INTO v_has_brand;
  SELECT count(*) INTO v_total FROM public.media_video_scenes WHERE video_job_id=j.id;

  FOR s IN SELECT * FROM public.media_video_scenes WHERE video_job_id=j.id ORDER BY scene_number LOOP
    n := s.scene_number;
    -- deterministic scene-type + generation-requirement mapping (generation is OPTIONAL, standard §10)
    IF n = 1 THEN
      v_stype := 'TEXT_HOOK'; v_genreq := 'NO_GENERATION'; v_cap := NULL;
      v_treat := jsonb_build_object('motion','ken_burns_zoom_in','frame','9x16_contain','background','blurred_product','source','product_still');
    ELSIF n = v_total THEN
      v_stype := 'CTA_END_CARD'; v_genreq := 'NO_GENERATION'; v_cap := NULL;
      v_treat := jsonb_build_object('motion','hold','frame','9x16_contain','background','brand_or_neutral','source','product_still');
    ELSIF lower(coalesce(s.visual_action,'')) ~ '(use|using|demo|address|being used|product being)' THEN
      v_stype := 'PRODUCT_DEMO'; v_genreq := 'VIDEO_GENERATION'; v_cap := 'VIDEO_IMAGE_TO_VIDEO';
      v_treat := jsonb_build_object('motion','generative_subtle','frame','9x16','source','product_frame','note','generative video optional; real-asset motion fallback is SOURCE_ASSET_MOTION');
    ELSE
      v_stype := 'SOURCE_ASSET_MOTION'; v_genreq := 'NO_GENERATION'; v_cap := NULL;
      v_treat := jsonb_build_object('motion','slow_pan','frame','9x16_contain','background','blurred_product','source','product_still');
    END IF;

    -- deterministic caption spec (NEVER rely on a generative model to draw text)
    v_cap_spec := CASE WHEN coalesce(nullif(btrim(s.text_overlay),''),'') = '' THEN '{}'::jsonb
      ELSE jsonb_build_object(
        'text', s.text_overlay,
        'role', CASE WHEN n=1 THEN 'HOOK' WHEN n=v_total THEN 'CTA' ELSE 'CAPTION' END,
        'render','DETERMINISTIC_COMPOSITION','engine','image_text_overlay (n8n Edit Image / server compositor)',
        'safe_area','vertical_center_lower_third','max_lines',2,'timing',jsonb_build_object('scene',n,'duration_s',s.duration_target)) END;

    UPDATE public.media_video_scenes
      SET scene_type=v_stype, generation_requirement=v_genreq, required_capability=v_cap,
          treatment=v_treat, caption=v_cap_spec,
          cta = CASE WHEN v_stype='CTA_END_CARD' THEN a.cta ELSE NULL END,
          brand_treatment = CASE WHEN v_has_brand
             THEN jsonb_build_object('source','member_business_dna','placement','safe','state','BRAND_DNA_PRESENT')
             ELSE jsonb_build_object('source','neutral','placement','safe','state','BRAND_DNA_ABSENT_NEUTRAL_SAFE') END,
          audio_intent='VISUAL_ONLY',
          render_state='RENDER_BACKEND_PENDING'
      WHERE id=s.id;
  END LOOP;

  RETURN public.fn_ad_production_plan_internal(j.id);
END; $fn$;

-- internal assembler (no auth; used by builder + read)
CREATE OR REPLACE FUNCTION public.fn_ad_production_plan_internal(p_video_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype; v_scenes jsonb;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_video_job_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'scene_number',scene_number,'scene_type',scene_type,'generation_requirement',generation_requirement,
      'required_capability',required_capability,'duration_s',duration_target,'treatment',treatment,
      'caption',caption,'cta',cta,'brand_treatment',brand_treatment,'audio_intent',audio_intent,
      'transition',transition,'render_state',render_state,'claim_violations',claim_violations) ORDER BY scene_number),'[]'::jsonb)
    INTO v_scenes FROM public.media_video_scenes WHERE video_job_id=p_video_job_id;
  RETURN jsonb_build_object('status','ok','video_job_id',j.id,
    'creative_hypothesis',a.angle_type,'platform',j.platform,'aspect_ratio',j.aspect_ratio,
    'target_duration_s',j.duration_target,'hook',coalesce(a.video_hook,a.hook),
    'lineage_state',j.lineage_state,'product_name',b.product_name,'market',b.market,
    'renderer','STRATELOQ_CREATIVE_STUDIO','render_backend','FFMPEG_OR_RENDER_SAAS_PENDING (no runtime in current infra)',
    'scene_count',jsonb_array_length(v_scenes),'scenes',v_scenes,
    'requires_video_generation', EXISTS(SELECT 1 FROM public.media_video_scenes WHERE video_job_id=p_video_job_id AND generation_requirement='VIDEO_GENERATION'),
    'deterministic_scene_count', (SELECT count(*) FROM public.media_video_scenes WHERE video_job_id=p_video_job_id AND generation_requirement='NO_GENERATION'),
    'contract','ad_production_plan_v1_015h; provider-independent (capability VIDEO_IMAGE_TO_VIDEO for generative scenes, never a provider name); deterministic captions/CTA; render backend not yet wired');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 3. Quality-gate contract (standard §16). Deterministic gates are evaluated
--    from real signals; aesthetic gates stay REVIEW_REQUIRED (no automated
--    evaluator exists — never fabricate an aesthetic PASS). Operates on a video
--    job (the production unit) so it works before any render exists.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_quality_gates(p_video_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; src public.media_assets%rowtype; v_claim jsonb; v_gates jsonb;
  v_has_cta boolean; v_has_caption boolean; v_has_brand boolean; v_identity text; v_aspect_ok boolean;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_video_job_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO src FROM public.media_assets WHERE id=j.source_image_asset_id;
  v_claim := public.fn_media_video_claim_gate(p_video_job_id);
  v_identity := coalesce(src.identity_state,'IDENTITY_REVIEW_REQUIRED');
  v_aspect_ok := coalesce(j.aspect_ratio,'')='9:16';
  SELECT EXISTS(SELECT 1 FROM public.media_video_scenes WHERE video_job_id=p_video_job_id AND coalesce(cta,'')<>'') INTO v_has_cta;
  SELECT EXISTS(SELECT 1 FROM public.media_video_scenes WHERE video_job_id=p_video_job_id AND caption <> '{}'::jsonb) INTO v_has_caption;
  SELECT EXISTS(SELECT 1 FROM public.member_business_dna d WHERE d.user_id=j.tenant_id) INTO v_has_brand;

  v_gates := jsonb_build_object(
    -- deterministic gates
    'PRODUCT_IDENTITY', CASE WHEN v_identity='IDENTITY_CLEARED' THEN 'PASS' ELSE 'REVIEW_REQUIRED' END,
    'CLAIM_SAFETY', CASE WHEN (v_claim->>'blocked')::boolean THEN 'FAIL' ELSE 'PASS' END,
    'PLATFORM_FORMAT', CASE WHEN v_aspect_ok THEN 'PASS' ELSE 'FAIL' END,
    'CAPTION_READABILITY', CASE WHEN v_has_caption THEN 'PASS' ELSE 'NOT_EVALUATED' END,
    'CTA_CLARITY', CASE WHEN v_has_cta THEN 'PASS' ELSE 'REVIEW_REQUIRED' END,
    'BRAND_COMPLIANCE', CASE WHEN v_has_brand THEN 'REVIEW_REQUIRED' ELSE 'NOT_APPLICABLE' END,
    -- aesthetic gates: no automated evaluator yet — honest REVIEW_REQUIRED (standard §16)
    'VISUAL_QUALITY','REVIEW_REQUIRED',
    'AI_ARTIFACTS','REVIEW_REQUIRED',
    'HOOK_QUALITY','REVIEW_REQUIRED',
    'STORY_COHERENCE','REVIEW_REQUIRED',
    'PRODUCT_VISIBILITY','REVIEW_REQUIRED',
    'PACING','REVIEW_REQUIRED',
    'COMPOSITION','REVIEW_REQUIRED',
    'COMMERCIAL_USEFULNESS','REVIEW_REQUIRED');

  RETURN jsonb_build_object('status','ok','video_job_id',p_video_job_id,'gates',v_gates,
    'any_fail', EXISTS(SELECT 1 FROM jsonb_each_text(v_gates) g WHERE g.value='FAIL'),
    'deterministic_critical_pass', ((v_claim->>'blocked')::boolean IS FALSE AND v_aspect_ok),
    'human_review_required', true,
    'note','A generated video is NOT a PASS on provider success (standard §2/§23). Aesthetic gates require human review until a legitimate automated evaluator exists; launch-safe additionally requires canonical lineage + identity cleared + Product Decision + human approval.');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 4. fn_media_production_ready: hard-approval helper. Never sets launch-safe.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_production_ready(p_video_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE q jsonb; j public.media_video_jobs%rowtype;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_video_job_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  q := public.fn_media_quality_gates(p_video_job_id);
  RETURN jsonb_build_object('status','ok','video_job_id',p_video_job_id,
    'critical_gates_ok', (q->>'deterministic_critical_pass')::boolean AND NOT (q->>'any_fail')::boolean,
    'render_backend_ready', false,
    'launch_safe', false,
    'blocking', jsonb_build_object(
      'render_backend','no FFmpeg/render runtime wired (composition/motion/encode) — production output cannot be composed yet',
      'aesthetic_gates','REVIEW_REQUIRED (human)',
      'human_approval','required',
      'lineage_identity_decision','enforced by fn_media_launch_eligibility'),
    'note','foundation/plan is ready; launch-safe remains FALSE until required gates + human approval + a render backend exist (standard §17/§23)');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 5. Browser-safe production-plan read (provider-invisible)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_production_plan_read(p_angle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_uid uuid := auth.uid(); a public.ad_studio_angles%rowtype; j public.media_video_jobs%rowtype;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF a.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;
  SELECT * INTO j FROM public.media_video_jobs WHERE angle_id=p_angle_id AND tenant_id=v_uid ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_plan'); END IF;
  RETURN public.fn_ad_production_plan_internal(j.id) || jsonb_build_object('quality_gates', public.fn_media_quality_gates(j.id)->'gates');
END; $fn$;

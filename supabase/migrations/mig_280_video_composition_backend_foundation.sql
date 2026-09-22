-- ============================================================================
-- mig_280_video_composition_backend_foundation.sql
-- STRATELOQ-AI-AD-CREATIVE-STUDIO-015I — Video composition + render backend.
-- Governed by docs/STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md (LOCKED).
--
-- Provider-NEUTRAL composition contracts: a renderer-agnostic composition SPEC
-- compiler + render-job lifecycle + dispatch BOUNDARY + completion + the
-- composition-backend abstraction in media_providers. Strateloq owns the
-- production plan; the renderer is a dumb execution engine that receives a
-- deterministic spec. NO render backend is connected, NO account/secret created,
-- NO generative-video provider touched, NO paid render. The actual render
-- requires an external backend (a render-API key OR a self-hosted FFmpeg/Remotion
-- worker) which is left for founder-provisioned external setup — dispatch stops
-- at that boundary with BLOCKED_RENDER_BACKEND. No FFmpeg runtime exists locally,
-- so no COMPOSITOR_TECHNICAL_FIXTURE is produced.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Render lifecycle fields on media_video_jobs (reuse the job; no parallel system)
-- ---------------------------------------------------------------------------
ALTER TABLE public.media_video_jobs
  ADD COLUMN IF NOT EXISTS render_state text NOT NULL DEFAULT 'PRODUCTION_PLAN_READY',
  ADD COLUMN IF NOT EXISTS render_spec jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS render_asset_ref uuid;

DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='media_video_jobs_render_state_chk') THEN
    ALTER TABLE public.media_video_jobs ADD CONSTRAINT media_video_jobs_render_state_chk
      CHECK (render_state = ANY (ARRAY['PRODUCTION_PLAN_READY','COMPOSITION_READY','RENDERING',
        'RENDERED_REVIEW_REQUIRED','RENDER_FAILED','BLOCKED_RENDER_BACKEND']));
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- 1. Register the composition-backend ABSTRACTION (capability, not a provider).
--    enabled=false -> no backend is wired; documents the external-setup options.
--    Secret never stored (server_side_only). This is a renderer, not a generator.
-- ---------------------------------------------------------------------------
INSERT INTO public.media_providers(name, media_type, enabled, config)
VALUES ('STRATELOQ_VIDEO_COMPOSITION','VIDEO', false, jsonb_build_object(
    'role','RENDERER','capability','VIDEO_COMPOSITION',
    'runtime_status','EXTERNAL_SETUP_REQUIRED — no render backend is connected. Live composition is blocked until a render backend is provisioned as an own server-side credential (a render-API key) or a self-hosted worker URL.',
    'candidate_backends', jsonb_build_array(
      jsonb_build_object('name','render_api_shotstack','kind','PROGRAMMABLE_VIDEO_API','fit','primary (beta): JSON edit spec, server render, motion/transitions/captions/audio, async+webhook, mp4, no infra'),
      jsonb_build_object('name','render_api_creatomate','kind','PROGRAMMABLE_VIDEO_API','fit','alt: template + modifications API'),
      jsonb_build_object('name','remotion_lambda','kind','SELF_HOSTED_REACT_RENDER','fit','scale/control: React compositions on AWS Lambda'),
      jsonb_build_object('name','ffmpeg_worker','kind','SELF_HOSTED_FFMPEG','fit','scale/cost: dedicated FFmpeg render worker (Cloud Run/container)')),
    'secret_storage','server_side_only: the render backend key/URL lives in the worker/edge env, never in this row',
    'contract','the backend receives a renderer-agnostic composition spec (fn_ad_compile_render_spec) and returns an mp4 to pulse-generated-media'))
ON CONFLICT (name) DO UPDATE SET config=excluded.config, enabled=excluded.enabled;

-- helper: the enabled composition backend, or NULL (renderer capability, provider-invisible)
CREATE OR REPLACE FUNCTION public.fn_media_composition_backend()
 RETURNS text LANGUAGE sql STABLE SET search_path TO ''
AS $fn$
  SELECT name FROM public.media_providers
   WHERE enabled AND config->>'capability'='VIDEO_COMPOSITION' ORDER BY created_at LIMIT 1;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. fn_ad_compile_render_spec: production plan -> renderer-agnostic composition
--    spec (1080x1920 mp4 timeline). Deterministic, provider-independent. Any
--    backend adapter (Shotstack JSON / Creatomate mods / FFmpeg filtergraph /
--    Remotion props) maps this spec. No backend call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_compile_render_spec(p_video_job_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; a public.ad_studio_angles%rowtype; s public.media_video_scenes%rowtype;
  v_clips jsonb := '[]'::jsonb; v_start numeric := 0; v_motion text; v_srckind text; v_trans text; v_cap jsonb; v_total numeric := 0;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_video_job_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;

  FOR s IN SELECT * FROM public.media_video_scenes WHERE video_job_id=p_video_job_id ORDER BY scene_number LOOP
    v_motion := CASE lower(coalesce(s.treatment->>'motion',''))
      WHEN 'ken_burns_zoom_in' THEN 'PUSH_IN' WHEN 'slow_pan' THEN 'PAN_RIGHT'
      WHEN 'hold' THEN 'STATIC' WHEN 'generative_subtle' THEN 'STATIC' ELSE 'STATIC' END;
    v_srckind := CASE s.scene_type
      WHEN 'GENERATIVE_IMAGE_TO_VIDEO' THEN 'generated_clip'
      WHEN 'UI_SCREENSHOT_MOTION' THEN 'ui_screenshot'
      WHEN 'SCREEN_RECORDING' THEN 'screen_recording'
      WHEN 'PRODUCT_DEMO' THEN CASE WHEN s.generation_requirement='VIDEO_GENERATION' THEN 'generated_clip' ELSE 'product_image' END
      ELSE 'product_image' END;
    v_trans := CASE lower(coalesce(s.transition,'')) WHEN 'hard cut' THEN 'CUT' WHEN 'cut' THEN 'CUT'
      WHEN 'end' THEN 'FADE' WHEN 'fade' THEN 'FADE' WHEN 'crossfade' THEN 'CROSSFADE' ELSE 'CUT' END;
    v_cap := CASE WHEN s.caption = '{}'::jsonb THEN 'null'::jsonb
      ELSE jsonb_build_object('text', s.caption->>'text','role', s.caption->>'role',
        'render','DETERMINISTIC','font_family','Inter/SemiBold','max_lines',2,
        'safe_zone','lower_third','position','center_lower','contrast_treatment','scrim_or_stroke',
        'start_s', v_start, 'duration_s', s.duration_target) END;

    v_clips := v_clips || jsonb_build_object(
      'index', s.scene_number, 'scene_type', s.scene_type, 'start_s', v_start, 'duration_s', s.duration_target,
      'source', jsonb_build_object('kind', v_srckind, 'ref', s.source_asset_ref,
                  'required_capability', s.required_capability, 'generation_requirement', s.generation_requirement),
      'motion', jsonb_build_object('type', v_motion, 'easing','ease_in_out','preserve_aspect', true, 'no_distortion', true),
      'frame', coalesce(s.treatment->>'frame','9x16_contain'),
      'transition_in', v_trans,
      'caption', v_cap,
      'cta', s.cta,
      'branding', s.brand_treatment,
      'audio', jsonb_build_object('intent', s.audio_intent));
    v_start := v_start + coalesce(s.duration_target,0);
  END LOOP;
  v_total := v_start;

  RETURN jsonb_build_object('status','ok','spec_version','ad_render_spec_v1_015i',
    'renderer','STRATELOQ_CREATIVE_STUDIO','backend_capability','VIDEO_COMPOSITION','provider_independent', true,
    'output', jsonb_build_object('width',1080,'height',1920,'aspect','9:16','fps',30,'container','mp4','video_codec','h264','audio_codec','aac','color','bt709'),
    'total_duration_s', v_total, 'creative_hypothesis', a.angle_type, 'platform', j.platform,
    'motion_system', jsonb_build_array('STATIC','PUSH_IN','PULL_OUT','PAN_LEFT','PAN_RIGHT','PAN_UP','PAN_DOWN','ZOOM_TO_REGION'),
    'transition_system', jsonb_build_array('CUT','FADE','CROSSFADE'),
    'audio_system', jsonb_build_array('VOICEOVER','MUSIC','SFX','VISUAL_ONLY'),
    'timeline', v_clips, 'scene_count', jsonb_array_length(v_clips),
    'note','deterministic, provider-independent composition spec; an internal render-backend adapter maps this spec (backend is internal Strateloq infrastructure, never named to customers). Critical text is composed deterministically, never drawn by a generative model.');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 3. fn_ad_render_compose: attach the compiled spec to the job (COMPOSITION_READY)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_render_compose(p_video_job_id uuid, p_tenant uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; v_spec jsonb;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_video_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  v_spec := public.fn_ad_compile_render_spec(p_video_job_id);
  IF (v_spec->>'status') <> 'ok' THEN RETURN v_spec; END IF;
  UPDATE public.media_video_jobs SET render_spec=v_spec, render_state='COMPOSITION_READY', updated_at=now()
    WHERE id=p_video_job_id;
  RETURN jsonb_build_object('status','COMPOSITION_READY','video_job_id',p_video_job_id,
    'output', v_spec->'output','total_duration_s', v_spec->'total_duration_s','scene_count', v_spec->'scene_count',
    'provider_independent', true);
END; $fn$;

-- ---------------------------------------------------------------------------
-- 4. fn_ad_render_dispatch: the BOUNDARY. Requires a wired composition backend;
--    none is connected -> BLOCKED_RENDER_BACKEND with the exact external setup.
--    No backend call, no secret, provider-invisible.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_render_dispatch(p_video_job_id uuid, p_tenant uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; v_backend text; v_cfg jsonb;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_video_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF j.render_state NOT IN ('COMPOSITION_READY','BLOCKED_RENDER_BACKEND') THEN
    PERFORM public.fn_ad_render_compose(p_video_job_id, p_tenant);
    SELECT * INTO j FROM public.media_video_jobs WHERE id=p_video_job_id;
  END IF;
  v_backend := public.fn_media_composition_backend();
  IF v_backend IS NULL THEN
    UPDATE public.media_video_jobs SET render_state='BLOCKED_RENDER_BACKEND', updated_at=now() WHERE id=p_video_job_id;
    SELECT config INTO v_cfg FROM public.media_providers WHERE name='STRATELOQ_VIDEO_COMPOSITION';
    RETURN jsonb_build_object('status','BLOCKED_RENDER_BACKEND','video_job_id',p_video_job_id,
      'reason','no VIDEO_COMPOSITION render backend is connected',
      'external_setup_required', v_cfg->>'runtime_status',
      'candidate_backends', v_cfg->'candidate_backends',
      'note','composition spec is ready and provider-independent; crossing this boundary needs a founder-provisioned render backend (a render-API key OR a self-hosted FFmpeg/Remotion worker) as a server-side credential. No account was created.');
  END IF;
  -- (reached only once a backend is wired) hand the spec to the executor
  UPDATE public.media_video_jobs SET render_state='RENDERING', updated_at=now() WHERE id=p_video_job_id;
  RETURN jsonb_build_object('status','RENDERING','video_job_id',p_video_job_id,'backend',v_backend,
    'render_spec', j.render_spec,
    'completion_contract','executor renders the spec, uploads the mp4 to pulse-generated-media, then calls fn_ad_render_complete',
    'secrets','NONE — render backend credential is server-side only');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 5. fn_ad_render_complete: persist the composed mp4 as a VIDEO asset (for when a
--    backend exists). MOCK/empty rejected. IN_REVIEW / not launch-safe /
--    identity-review. Reuses lineage + private storage. No auto-PASS.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_render_complete(
  p_video_job_id uuid, p_tenant uuid, p_backend text, p_backend_job_id text, p_storage_ref text,
  p_mime text, p_width integer, p_height integer, p_duration numeric, p_actual_cost numeric,
  p_cost_currency text, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_asset uuid; v_lineage text; v_product uuid;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_video_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF p_backend IS NULL OR p_backend='' OR p_backend='MOCK' THEN
    RETURN jsonb_build_object('status','REAL_BACKEND_REQUIRED','note','a real render backend is required; MOCK cannot complete a real composed asset');
  END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  v_lineage := coalesce(j.lineage_state,'UNRESOLVED');
  v_product := CASE WHEN v_lineage='CANONICAL' THEN b.product_id ELSE NULL END;

  INSERT INTO public.media_assets(tenant_id, product_id, creative_id, source_asset_id, media_type, source_type,
    provider, provider_job_id, rights_state, generation_status, approval_state, mime_type, width, height, duration,
    aspect_ratio, storage_ref, spec_ref, provenance, is_launch_safe, country_code, generation_mode, usage_permission,
    cost_amount, cost_currency, creative_strategy_ref, ad_variant_ref, lineage_state, identity_state)
  VALUES (p_tenant, v_product, NULL, j.source_image_asset_id, 'VIDEO', 'PULSE_COMPOSED_VIDEO',
    p_backend, p_backend_job_id, 'GENERATED','GENERATED','IN_REVIEW', coalesce(p_mime,'video/mp4'),
    coalesce(p_width,1080), coalesce(p_height,1920), coalesce(p_duration,j.duration_target), '9:16', p_storage_ref,
    jsonb_build_object('render_spec', j.render_spec, 'platform', j.platform),
    coalesce(p_provenance,'{}'::jsonb) || jsonb_build_object('composed', true, 'backend', p_backend,
      'generation_mode','COMPOSITION_RENDER','note','deterministically composed advertisement; requires human identity + quality review before any launch'),
    false, b.market, 'COMPOSITION_RENDER','INTERNAL_ADVERTISING_TEST', p_actual_cost, coalesce(p_cost_currency,'USD'),
    a.brief_id, a.id, v_lineage, 'IDENTITY_REVIEW_REQUIRED')
  RETURNING id INTO v_asset;

  UPDATE public.media_video_jobs SET render_state='RENDERED_REVIEW_REQUIRED', render_asset_ref=v_asset, updated_at=now()
    WHERE id=p_video_job_id;
  INSERT INTO public.media_job_costs(tenant_id, job_id, operation_type, provider, actual_cost, currency)
  VALUES (p_tenant, p_video_job_id, 'VIDEO_COMPOSITION_RENDER', p_backend, p_actual_cost, coalesce(p_cost_currency,'USD'));

  RETURN jsonb_build_object('status','RENDERED_REVIEW_REQUIRED','asset_id',v_asset,'media_type','VIDEO',
    'is_launch_safe',false,'approval_state','IN_REVIEW','identity_state','IDENTITY_REVIEW_REQUIRED',
    'lineage_state',v_lineage,'aspect_ratio','9:16','note','composed mp4 persisted; NOT launch-safe — quality gates + human approval still required (standard §21)');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 6. Selftest (self-contained, self-cleaning; distinct [[rnd]] fixture marker so
--    nested [[vid]]/[[lin]] suites cannot collide). Composed test asset uses the
--    unique storage_ref rndtest:// so cleanup is robust.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_render_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v jsonb := '[]'::jsonb;
  tA uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  tB uuid := '3d0eb793-685a-4ec2-aea7-8b95fda7112a';
  real_shoe uuid := 'efca8b59-d814-404b-be1b-65e833fab9b8';
  v_realdec uuid; brC uuid; angC uuid; srcOk uuid; v_job uuid; spec jsonb; r jsonb; comp jsonb; q jsonb; v_asset uuid; v_txt text;
BEGIN
  DELETE FROM public.media_assets WHERE storage_ref LIKE 'rndtest://%' OR (tenant_id=tA AND storage_ref LIKE 'rndsrc://%');
  DELETE FROM public.media_video_scenes WHERE video_job_id IN (SELECT jb.id FROM public.media_video_jobs jb JOIN public.ad_studio_angles a ON a.id=jb.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[rnd]]%');
  DELETE FROM public.media_job_costs WHERE job_id IN (SELECT jb.id FROM public.media_video_jobs jb JOIN public.ad_studio_angles a ON a.id=jb.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[rnd]]%');
  DELETE FROM public.media_video_jobs WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[rnd]]%');
  DELETE FROM public.ad_studio_angles WHERE brief_id IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[rnd]]%');
  DELETE FROM public.ad_studio_briefs WHERE product_name LIKE '[[rnd]]%';

  v := v || jsonb_build_object('case','A_no_backend_wired','pass', public.fn_media_composition_backend() IS NULL);

  SELECT id INTO v_realdec FROM public.product_opportunity_decisions WHERE product_id=real_shoe AND country_code='GB' AND coalesce(is_fixture,false)=false LIMIT 1;
  brC := public.fn_ad_studio_build_brief(tA, jsonb_build_object('product_name','[[rnd]] Render','market','GB','market_currency','GBP',
      'problem_solved','keeping things tidy','product_id',real_shoe::text,'decision_id',v_realdec::text,
      'product_assets',jsonb_build_array('https://cf.cjdropshipping.com/vid.jpg')), true);
  INSERT INTO public.ad_studio_angles(brief_id,tenant_id,angle_index,angle_type,angle_name,customer_problem,desired_outcome,
      hook,headline,primary_copy,supporting_copy,cta,visual_concept,static_creative_brief,video_hook,video_script,claim_risk,claim_violations,review_state)
    VALUES (brC,tA,0,'PROBLEM_SOLUTION','R','keeping things tidy','a tidier space',
      'Looking for a simpler way?','A tidier space, made easy','See how it works and decide for yourself.','Made for everyday use.','Learn more',
      'Show the product in use','Show the product in use','Ever struggle to keep tidy?','Open. Show product. CTA: Learn more.','LOW','[]'::jsonb,'REVIEW_REQUIRED')
    RETURNING id INTO angC;
  srcOk := public.fn_media_register_source_asset(tA, real_shoe, NULL, 'SUPPLIER_AUTHORIZED','SUPPLIER_PROVIDED','rndsrc://ok.jpg','image/jpeg','9:16', jsonb_build_object('source_asset_url','https://cf.cjdropshipping.com/vid.jpg'));
  v_job := (public.fn_media_create_video_job(tA, angC, srcOk, 'TIKTOK_FEED'))->>'video_job_id';
  PERFORM public.fn_ad_build_production_plan(tA, angC, 'TIKTOK_FEED');

  spec := public.fn_ad_compile_render_spec(v_job::uuid);
  v := v || jsonb_build_object('case','B_spec_compiled','pass',
    (spec->>'status'='ok' AND (spec->'output'->>'width')::int=1080 AND (spec->'output'->>'height')::int=1920
     AND spec->'output'->>'container'='mp4' AND (spec->>'scene_count')::int=4
     AND (spec->>'provider_independent')::boolean=true AND (spec->>'total_duration_s')::numeric=10));

  v := v || jsonb_build_object('case','C_timeline_mapping','pass',
    (EXISTS(SELECT 1 FROM jsonb_array_elements(spec->'timeline') c WHERE c->'motion'->>'type'='PUSH_IN')
     AND EXISTS(SELECT 1 FROM jsonb_array_elements(spec->'timeline') c WHERE c->'source'->>'kind'='generated_clip' AND c->'source'->>'required_capability'='VIDEO_IMAGE_TO_VIDEO')
     AND EXISTS(SELECT 1 FROM jsonb_array_elements(spec->'timeline') c WHERE c->'source'->>'kind'='product_image')
     AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(spec->'timeline') c WHERE (c->'caption')<>'null'::jsonb AND (c->'caption'->>'render') IS DISTINCT FROM 'DETERMINISTIC')
     AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(spec->'timeline') c WHERE (c->>'transition_in') NOT IN ('CUT','FADE','CROSSFADE'))));

  v_txt := lower(spec::text);
  v := v || jsonb_build_object('case','D_provider_invisible','pass',
    (position('alibaba' in v_txt)=0 AND position('qwen' in v_txt)=0 AND position('_wan' in v_txt)=0 AND position('shotstack' in v_txt)=0 AND position('veo' in v_txt)=0));

  r := public.fn_ad_render_compose(v_job::uuid, tA);
  v := v || jsonb_build_object('case','E_composition_ready','pass',
    (r->>'status'='COMPOSITION_READY' AND (SELECT render_state FROM public.media_video_jobs WHERE id=v_job::uuid)='COMPOSITION_READY'
     AND (SELECT render_spec FROM public.media_video_jobs WHERE id=v_job::uuid) <> '{}'::jsonb));

  r := public.fn_ad_render_dispatch(v_job::uuid, tA);
  v := v || jsonb_build_object('case','F_blocked_render_backend','pass',
    (r->>'status'='BLOCKED_RENDER_BACKEND' AND coalesce(r->>'external_setup_required','')<>'' AND jsonb_array_length(r->'candidate_backends')>=2
     AND (SELECT render_state FROM public.media_video_jobs WHERE id=v_job::uuid)='BLOCKED_RENDER_BACKEND'));

  r := public.fn_ad_render_complete(v_job::uuid, tA, 'MOCK','x','n/x.mp4','video/mp4',1080,1920,10,0,'USD','{}'::jsonb);
  v := v || jsonb_build_object('case','G_mock_rejected','pass', r->>'status'='REAL_BACKEND_REQUIRED');

  comp := public.fn_ad_render_complete(v_job::uuid, tA, 'FFMPEG_WORKER','rj-1','rndtest://composed.mp4','video/mp4',1080,1920,10,0.02,'USD','{}'::jsonb);
  v_asset := (comp->>'asset_id')::uuid;
  q := public.fn_media_quality_gates(v_job::uuid);
  v := v || jsonb_build_object('case','H_composed_asset','pass',
    (comp->>'status'='RENDERED_REVIEW_REQUIRED' AND comp->>'media_type'='VIDEO' AND (comp->>'is_launch_safe')::boolean=false
     AND comp->>'identity_state'='IDENTITY_REVIEW_REQUIRED' AND comp->>'aspect_ratio'='9:16'
     AND (SELECT render_state FROM public.media_video_jobs WHERE id=v_job::uuid)='RENDERED_REVIEW_REQUIRED'
     AND (SELECT media_type FROM public.media_assets WHERE id=v_asset)='VIDEO'
     AND (SELECT count(*) FROM jsonb_object_keys(q->'gates'))=14
     AND q->'gates'->>'PLATFORM_FORMAT'='PASS' AND q->'gates'->>'VISUAL_QUALITY'='REVIEW_REQUIRED'));

  v := v || jsonb_build_object('case','I_tenant_isolation','pass',
    ((public.fn_ad_render_compose(v_job::uuid, tB))->>'status'='not_found_or_forbidden'
     AND (public.fn_ad_render_dispatch(v_job::uuid, tB))->>'status'='not_found_or_forbidden'
     AND (public.fn_ad_render_complete(v_job::uuid, tB,'FFMPEG_WORKER','x','y.mp4','video/mp4',1080,1920,10,0,'USD','{}'::jsonb))->>'status'='not_found_or_forbidden'));

  v := v || jsonb_build_object('case','J_regressions','pass',
    ((public.fn_ad_production_engine_selftest()->>'all_pass')::boolean=true
     AND (public.fn_media_video_runtime_selftest()->>'all_pass')::boolean=true
     AND (public.fn_ad_studio_lineage_selftest()->>'all_pass')::boolean=true));

  DELETE FROM public.media_assets WHERE storage_ref LIKE 'rndtest://%' OR (tenant_id=tA AND storage_ref LIKE 'rndsrc://%');
  DELETE FROM public.media_job_costs WHERE provider='FFMPEG_WORKER' AND operation_type='VIDEO_COMPOSITION_RENDER'
     AND job_id IN (SELECT jb.id FROM public.media_video_jobs jb JOIN public.ad_studio_angles a ON a.id=jb.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[rnd]]%');
  DELETE FROM public.media_video_scenes WHERE video_job_id IN (SELECT jb.id FROM public.media_video_jobs jb JOIN public.ad_studio_angles a ON a.id=jb.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[rnd]]%');
  DELETE FROM public.media_video_jobs WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[rnd]]%');
  DELETE FROM public.ad_studio_angles WHERE brief_id IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[rnd]]%');
  DELETE FROM public.ad_studio_briefs WHERE product_name LIKE '[[rnd]]%';

  RETURN jsonb_build_object('suite','ad_video_composition',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $fn$;

-- ============================================================================
-- mig_277_ad_creative_video_runtime.sql
-- STRATELOQ-AI-AD-CREATIVE-STUDIO-015G
-- Short-form (9:16, 10-15s) image->video ad generation RUNTIME.
--
-- Extends the EXISTING media runtime (015F mig_275 image lifecycle, 015F.2
-- mig_276 canonical lineage gate). Provider-neutral, tenant-scoped, cost-aware,
-- claim-safe, canonical-lineage-gated, private-storage, human-review lifecycle.
-- NO second media architecture: reuses media_video_jobs / media_video_scenes /
-- media_assets / media_providers / media_job_costs / pulse-generated-media and
-- the shared fn_ad_studio_resolve_lineage + fn_media_launch_eligibility gates.
--
-- Registers ONE authorized image->video provider (Alibaba Qwen/Wan via the n8n
-- Gateway managed credential alibabaCloudApi). Provider secret is NEVER stored
-- in the DB (server_side_only). This migration performs NO paid provider call.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Additive lineage column on media_video_jobs (same contract as image jobs)
-- ---------------------------------------------------------------------------
ALTER TABLE public.media_video_jobs
  ADD COLUMN IF NOT EXISTS lineage_state text NOT NULL DEFAULT 'UNRESOLVED';

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname='media_video_jobs_lineage_chk'
  ) THEN
    ALTER TABLE public.media_video_jobs
      ADD CONSTRAINT media_video_jobs_lineage_chk
      CHECK (lineage_state = ANY (ARRAY['CANONICAL','INLINE_ONLY','UNRESOLVED']));
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- 1. Register the single authorized image->video provider (config only).
--    capability + config are sanitized by fn_media_register_provider, which
--    strips any secret-looking key and records secret_storage=server_side_only.
-- ---------------------------------------------------------------------------
SELECT public.fn_media_register_provider(
  'ALIBABA_QWEN_WAN_VIDEO',
  'VIDEO',
  jsonb_build_object(
    'mode','IMAGE_TO_VIDEO',
    'n8n_node','@n8n/n8n-nodes-langchain.alibabaCloud',
    'operation','imageToVideo',
    'model_family','wan',
    'min_duration_s',2,'max_duration_s',15,
    'resolutions', jsonb_build_array('720P','1080P'),
    'aspect_from_source', true,
    'prompt_steerable', true,
    'gateway_credential','alibabaCloudApi (n8n Gateway managed credential; usage-based billing)',
    'capability_verified','n8n list_n8n_gateway_services -> video: [textToVideo, imageToVideo]; node imageToVideo duration 2-15s, resolution 720P/1080P, prompt-steerable'
  ),
  jsonb_build_object(
    'model_family','wan',
    'resolution','720P',
    'default_duration_s',12,
    'aspect','9:16',
    'audio', false,
    'est_cost_usd_per_second', 0.03,
    'est_basis','INDICATIVE ONLY: Alibaba Wan image-to-video is billed usage-based by the n8n Gateway; the real charge is metered at run time. Per-second figure is an order-of-magnitude estimate for the founder cost gate, not a quoted price.',
    'delivery','executor prepares a 9:16 source frame, runs imageToVideo, uploads the mp4 to the private pulse-generated-media bucket, then calls fn_media_complete_video_real'
  )
);

-- ---------------------------------------------------------------------------
-- 2. Video claim gate: concept-level (angle) + per-scene overlay violations.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_video_claim_gate(p_video_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; v_angle_gate jsonb; v_scene_viol jsonb; v_blocked boolean;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_video_job_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','video_job_not_found'); END IF;
  v_angle_gate := public.fn_media_claim_gate(j.angle_id);
  v_scene_viol := coalesce(j.claim_violations,'[]'::jsonb);
  v_blocked := coalesce((v_angle_gate->>'blocked')::boolean,false) OR (jsonb_array_length(v_scene_viol) > 0);
  RETURN jsonb_build_object('status','ok','video_job_id',p_video_job_id,
    'blocked', v_blocked,
    'angle_violations', v_angle_gate->'violations',
    'scene_violations', v_scene_viol,
    'gate','angle concept gate (hook+headline+copy+cta+visual+brief) + per-scene overlay/voiceover claim-scan',
    'rule','any advertising claim in the concept OR any storyboard scene blocks dispatch until removed or evidenced');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 3. fn_media_create_video_job (UPDATED): canonical lineage + duration clamp
--    (10-15s) + 9:16 + provider-neutral status + per-scene claim scan.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_create_video_job(p_tenant uuid, p_angle_id uuid, p_source_image_asset_id uuid, p_platform text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype; src public.media_assets%rowtype;
  v_provider text; v_status text; v_id uuid; v_dur numeric; v_lin jsonb; v_lstate text;
  v_sb jsonb; v_scene jsonb; v_scan jsonb; v_all_scan jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  SELECT * INTO src FROM public.media_assets WHERE id=p_source_image_asset_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','source_asset_not_found'); END IF;
  IF src.rights_state IN ('UNKNOWN','PROHIBITED') THEN
    RETURN jsonb_build_object('status','blocked_rights','rights_state',src.rights_state,
      'note','source image rights UNKNOWN/PROHIBITED cannot seed a video creative');
  END IF;

  -- canonical lineage from the brief (FK-only; never name/text)
  v_lin := public.fn_ad_studio_resolve_lineage(p_tenant, b.product_id, b.decision_id, b.market);
  v_lstate := v_lin->>'lineage_state';

  -- short-form duration clamped to [10,15]s; TikTok-style feed favours ~12s
  v_dur := CASE WHEN p_platform='TIKTOK_FEED' THEN 12 ELSE 15 END;
  v_dur := least(15, greatest(10, v_dur));

  v_sb := public.fn_media_build_storyboard(p_angle_id,p_platform);
  v_provider := public.fn_media_provider_for('VIDEO');
  v_status := CASE WHEN v_provider IS NULL THEN 'BLOCKED_EXTERNAL_PROVIDER' ELSE 'READY' END;

  INSERT INTO public.media_video_jobs(tenant_id,angle_id,source_image_asset_id,product_facts,video_hook,script,storyboard,
    platform,duration_target,aspect_ratio,motion_instructions,text_overlays,cta,provider,status,
    estimated_cost,cost_currency,retry_count,max_retries,lineage_state,provenance)
  VALUES (p_tenant,p_angle_id,p_source_image_asset_id,'{}'::jsonb,a.video_hook,a.video_script,v_sb,
    p_platform, v_dur, '9:16',
    'derived from storyboard scenes', jsonb_build_array(a.hook,a.headline,a.cta), a.cta, v_provider, v_status,
    0,'USD',0,2,v_lstate,
    jsonb_build_object('angle_id',a.id,'brief_id',b.id,'source_image_asset_id',p_source_image_asset_id,
      'source_lineage',src.provenance,'source_rights',src.rights_state,'source_identity',src.identity_state,
      'lineage',v_lin,'lineage_state',v_lstate))
  RETURNING id INTO v_id;

  -- persist scenes + per-scene claim-scan
  FOR v_scene IN SELECT * FROM jsonb_array_elements(v_sb) LOOP
    v_scan := public.fn_ad_studio_claim_scan(concat_ws(' ', v_scene->>'text_overlay', v_scene->>'voiceover'));
    v_all_scan := v_all_scan || v_scan;
    INSERT INTO public.media_video_scenes(video_job_id,tenant_id,scene_number,duration_target,source_asset_ref,visual_action,motion_instruction,text_overlay,voiceover,transition,claim_violations)
    VALUES (v_id,p_tenant,(v_scene->>'scene_number')::int,(v_scene->>'duration_target')::numeric,p_source_image_asset_id,
      v_scene->>'visual_action',v_scene->>'motion_instruction',v_scene->>'text_overlay',v_scene->>'voiceover',v_scene->>'transition',v_scan);
  END LOOP;

  UPDATE public.media_video_jobs SET claim_violations=v_all_scan WHERE id=v_id;
  INSERT INTO public.media_job_costs(tenant_id,job_id,operation_type,provider,estimated_cost,currency)
  VALUES (p_tenant,v_id,'IMAGE_TO_VIDEO',v_provider,0,'USD');

  RETURN jsonb_build_object('status',v_status,'video_job_id',v_id,'provider',coalesce(v_provider,'NONE_CONFIGURED'),
    'platform',p_platform,'duration_s',v_dur,'aspect_ratio','9:16','scenes',jsonb_array_length(v_sb),
    'lineage_state',v_lstate,'lineage_reason',v_lin->>'reason',
    'source_lineage_preserved',(src.provenance IS NOT NULL),'claim_violations',v_all_scan);
END; $fn$;

-- ---------------------------------------------------------------------------
-- 4. fn_media_prepare_video_job: pre-flight (provider + claim + rights +
--    lineage + 9:16 + cost). No provider call. Mirrors fn_media_prepare_image_job.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_prepare_video_job(p_job_id uuid, p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  src public.media_assets%rowtype; v_provider text; v_cfg jsonb; v_gate jsonb; v_lin jsonb; v_lstate text;
  v_dur numeric; v_res text; v_persec numeric; v_est numeric; v_identity jsonb; v_prompt text;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF j.status='GENERATING' THEN RETURN jsonb_build_object('status','ALREADY_GENERATING','job_id',p_job_id); END IF;
  IF j.status IN ('GENERATED_REVIEW_REQUIRED') THEN RETURN jsonb_build_object('status','ALREADY_COMPLETE','job_id',p_job_id,'video_asset_ref',j.video_asset_ref); END IF;

  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  SELECT * INTO src FROM public.media_assets WHERE id=j.source_image_asset_id;

  v_provider := public.fn_media_provider_for('VIDEO');
  IF v_provider IS NULL THEN
    UPDATE public.media_video_jobs SET status='BLOCKED_EXTERNAL_PROVIDER', updated_at=now() WHERE id=p_job_id;
    RETURN jsonb_build_object('status','BLOCKED_EXTERNAL_PROVIDER','note','no enabled VIDEO provider registered');
  END IF;
  SELECT config INTO v_cfg FROM public.media_providers WHERE name=v_provider;

  -- source rights (never regenerate video from UNKNOWN/PROHIBITED source)
  IF src.rights_state IN ('UNKNOWN','PROHIBITED') THEN
    UPDATE public.media_video_jobs SET status='BLOCKED_RIGHTS', error_state='source_rights_'||src.rights_state, updated_at=now() WHERE id=p_job_id;
    RETURN jsonb_build_object('status','BLOCKED_RIGHTS','rights_state',src.rights_state);
  END IF;

  -- claim gate (concept + scenes)
  v_gate := public.fn_media_video_claim_gate(p_job_id);
  IF (v_gate->>'blocked')::boolean THEN
    UPDATE public.media_video_jobs SET status='BLOCKED_CLAIM_REVIEW', error_state='claim_violation',
      provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('claim_gate', v_gate), updated_at=now()
      WHERE id=p_job_id;
    RETURN jsonb_build_object('status','BLOCKED_CLAIM_REVIEW','violations', v_gate,
      'note','unsafe advertising claim(s) in concept or storyboard; dispatch blocked until removed/evidenced');
  END IF;

  -- 9:16 hard requirement
  IF coalesce(j.aspect_ratio,'') <> '9:16' THEN
    UPDATE public.media_video_jobs SET status='BLOCKED_ASPECT', error_state='not_9_16', updated_at=now() WHERE id=p_job_id;
    RETURN jsonb_build_object('status','BLOCKED_ASPECT','aspect_ratio',j.aspect_ratio,'required','9:16');
  END IF;

  -- canonical lineage (FK-only; deterministic)
  v_lin := public.fn_ad_studio_resolve_lineage(p_tenant, b.product_id, b.decision_id, b.market);
  v_lstate := v_lin->>'lineage_state';

  -- cost estimate (indicative; real charge is metered by the n8n Gateway)
  v_dur := least(15, greatest(10, coalesce(j.duration_target,12)));
  v_res := coalesce(v_cfg->>'resolution','720P');
  v_persec := coalesce((v_cfg->>'est_cost_usd_per_second')::numeric, 0.03);
  v_est := round(v_dur * v_persec, 4);

  v_identity := jsonb_build_object(
    'canonical_product_id', v_lin->>'canonical_product_id',
    'product_name', b.product_name, 'brief_id', b.id, 'angle_id', a.id,
    'source_image_asset_id', j.source_image_asset_id,
    'source_rights', src.rights_state, 'source_identity', src.identity_state,
    'lineage_state', v_lstate, 'lineage_reason', v_lin->>'reason',
    'identity_state','IDENTITY_REVIEW_REQUIRED',
    'identity_rule','image-to-video animates the rights-clear supplier source frame but cannot GUARANTEE pixel-exact product identity; human identity review mandatory before any campaign use; never substitute another SKU/model/brand and never clear identity on generation success alone');

  -- claim-safe motion prompt assembled deterministically from the storyboard
  v_prompt := (SELECT string_agg(
      'Scene '||(s->>'scene_number')||': '||coalesce(s->>'visual_action','')||' — '||coalesce(s->>'motion_instruction',''),
      ' | ' ORDER BY (s->>'scene_number')::int)
    FROM jsonb_array_elements(coalesce(j.storyboard,'[]'::jsonb)) s);
  v_prompt := left(coalesce(v_prompt,''), 1900);

  UPDATE public.media_video_jobs
    SET status='READY_TO_DISPATCH', lineage_state=v_lstate, duration_target=v_dur,
        estimated_cost=v_est, cost_currency='USD',
        motion_instructions = v_prompt,
        provenance = coalesce(provenance,'{}'::jsonb)
          || jsonb_build_object('claim_gate', v_gate, 'product_identity', v_identity, 'lineage', v_lin,
                'prepared_at', now(), 'provider', v_provider, 'model_family', v_cfg->>'model_family',
                'resolution', v_res, 'aspect','9:16', 'audio', coalesce((v_cfg->>'audio')::boolean,false),
                'mode','IMAGE_TO_VIDEO', 'i2v_prompt', v_prompt)
    WHERE id=p_job_id;
  UPDATE public.media_job_costs SET estimated_cost=v_est, currency='USD' WHERE job_id=p_job_id AND actual_cost IS NULL;

  RETURN jsonb_build_object('status','READY_TO_DISPATCH','job_id',p_job_id,
    'provider',v_provider,'model_family',v_cfg->>'model_family','mode','IMAGE_TO_VIDEO',
    'resolution',v_res,'aspect_ratio','9:16','duration_s',v_dur,'audio',coalesce((v_cfg->>'audio')::boolean,false),
    'provider_call_count',1,'estimated_cost_usd',v_est,'cost_basis',v_cfg->>'est_basis',
    'claim_gate','PASS','product_identity',v_identity,'scenes',jsonb_array_length(coalesce(j.storyboard,'[]'::jsonb)),
    'lineage_state', v_lstate, 'lineage_reason', v_lin->>'reason',
    'production_launch_eligible', (v_lstate='CANONICAL'),
    'production_gate_reason', CASE WHEN v_lstate='CANONICAL' THEN NULL ELSE 'CANONICAL_PRODUCT_LINEAGE_REQUIRED' END,
    'note', CASE WHEN v_lstate='CANONICAL'
      THEN 'pre-flight complete; canonical lineage + valid Product Decision; awaiting founder cost approval then a single paid video call.'
      ELSE 'pre-flight complete; INLINE_ONLY/UNRESOLVED lineage — video may be generated for experimentation but can NEVER become launch-safe until canonical product + Product Decision are linked.' END);
END; $fn$;

-- ---------------------------------------------------------------------------
-- 5. fn_media_dispatch_video_job: idempotent READY_TO_DISPATCH -> GENERATING.
--    Returns the executor contract. No secret is ever returned. No paid call
--    happens here — the executor makes the single provider call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_dispatch_video_job(p_job_id uuid, p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; src public.media_assets%rowtype; v_cfg jsonb; v_gate jsonb; v_src_url text;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF j.status='GENERATING' THEN
    RETURN jsonb_build_object('status','ALREADY_GENERATING','job_id',p_job_id,
      'provider',j.provider,'prompt',j.motion_instructions,'duration_s',j.duration_target,'aspect_ratio',j.aspect_ratio);
  END IF;
  IF j.status='GENERATED_REVIEW_REQUIRED' THEN
    RETURN jsonb_build_object('status','ALREADY_COMPLETE','job_id',p_job_id,'video_asset_ref',j.video_asset_ref);
  END IF;
  IF j.status <> 'READY_TO_DISPATCH' THEN
    RETURN jsonb_build_object('status','NOT_PREPARED','current',j.status,'note','run fn_media_prepare_video_job first (provider + claim + rights + lineage + 9:16 + cost)');
  END IF;

  v_gate := public.fn_media_video_claim_gate(p_job_id);
  IF (v_gate->>'blocked')::boolean THEN
    UPDATE public.media_video_jobs SET status='BLOCKED_CLAIM_REVIEW', error_state='claim_violation', updated_at=now() WHERE id=p_job_id;
    RETURN jsonb_build_object('status','BLOCKED_CLAIM_REVIEW','violations',v_gate);
  END IF;

  SELECT * INTO src FROM public.media_assets WHERE id=j.source_image_asset_id;
  v_src_url := coalesce(src.storage_ref, src.provenance->>'source_asset_url');
  SELECT config INTO v_cfg FROM public.media_providers WHERE name=j.provider;

  UPDATE public.media_video_jobs SET status='GENERATING',
     provenance = coalesce(provenance,'{}'::jsonb) || jsonb_build_object('dispatched_at', now()), updated_at=now()
   WHERE id=p_job_id;

  RETURN jsonb_build_object('status','GENERATING','job_id',p_job_id,
    'provider', j.provider, 'mode','IMAGE_TO_VIDEO',
    'n8n_node', v_cfg->>'n8n_node', 'operation', v_cfg->>'operation',
    'model_family', v_cfg->>'model_family', 'resolution', coalesce(v_cfg->>'resolution','720P'),
    'source_image_url', v_src_url, 'prompt', j.motion_instructions,
    'duration_s', j.duration_target, 'aspect_ratio','9:16', 'audio', coalesce((v_cfg->>'audio')::boolean,false),
    'scenes', jsonb_array_length(coalesce(j.storyboard,'[]'::jsonb)),
    'source_frame_prep','Center the product on a 1080x1920 (9:16) canvas — pad/crop, no baked text — before the imageToVideo call so the delivered clip is natively 9:16.',
    'caption_strategy','Deterministic post-generation text overlays from the storyboard (scene text_overlay fields); do NOT bake claims into the pixels.',
    'completion_contract','executor uploads the mp4 to the private pulse-generated-media bucket, then calls fn_media_complete_video_real(job,tenant,provider,provider_job_id,storage_ref,mime,width,height,duration,cost,currency,product_id,country,source_refs,prompt,provenance)',
    'secrets','NONE — the Alibaba/Wan key lives only in the n8n Gateway managed credential (alibabaCloudApi); it is never in this row or this response');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 6. fn_media_complete_video_real: persist a REAL video asset. Mirrors
--    fn_media_complete_image_real. MOCK/empty provider rejected. Canonical
--    product_id backfills from the brief ONLY when lineage is CANONICAL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_complete_video_real(
  p_job_id uuid, p_tenant uuid, p_provider text, p_provider_job_id text, p_storage_ref text,
  p_mime text, p_width integer, p_height integer, p_duration numeric, p_actual_cost numeric,
  p_cost_currency text, p_product_id uuid, p_country_code text, p_source_asset_refs jsonb,
  p_prompt text, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype; a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_asset uuid; v_prov jsonb; v_lineage text; v_product uuid;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF p_provider IS NULL OR p_provider='' OR p_provider='MOCK' THEN
    RETURN jsonb_build_object('status','REAL_PROVIDER_REQUIRED','note','a real provider is required; MOCK cannot complete a real video asset');
  END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  v_lineage := coalesce(j.lineage_state,'UNRESOLVED');
  v_product := coalesce(p_product_id, CASE WHEN v_lineage='CANONICAL' THEN b.product_id ELSE NULL END);

  v_prov := coalesce(p_provenance,'{}'::jsonb)
    || jsonb_build_object('generated', true, 'provider', p_provider, 'provider_job_id', p_provider_job_id,
         'prompt', p_prompt, 'source_asset_refs', coalesce(p_source_asset_refs,'[]'::jsonb),
         'source_image_asset_id', j.source_image_asset_id, 'storyboard', j.storyboard,
         'generation_mode','IMAGE_TO_VIDEO', 'lineage_state', v_lineage,
         'note','REAL provider-generated 9:16 short-form video; animation of a rights-clear supplier source frame. Requires human identity + approval review before any launch.');

  INSERT INTO public.media_assets(tenant_id, product_id, creative_id, source_asset_id, media_type, source_type,
    provider, provider_job_id, rights_state, generation_status, approval_state, mime_type, width, height, duration,
    aspect_ratio, storage_ref, spec_ref, provenance, is_launch_safe,
    country_code, generation_mode, usage_permission, cost_amount, cost_currency, source_asset_refs,
    creative_strategy_ref, ad_variant_ref, lineage_state, identity_state)
  VALUES (p_tenant, v_product, NULL, j.source_image_asset_id, 'VIDEO', 'PULSE_GENERATED_VIDEO',
    p_provider, p_provider_job_id, 'GENERATED', 'GENERATED', 'IN_REVIEW', coalesce(p_mime,'video/mp4'),
    p_width, p_height, coalesce(p_duration, j.duration_target), coalesce(j.aspect_ratio,'9:16'), p_storage_ref,
    jsonb_build_object('prompt', p_prompt, 'storyboard', j.storyboard, 'platform', j.platform), v_prov, false,
    p_country_code, 'IMAGE_TO_VIDEO', 'INTERNAL_ADVERTISING_TEST', p_actual_cost,
    coalesce(p_cost_currency,'USD'), coalesce(p_source_asset_refs,'[]'::jsonb),
    a.brief_id, a.id, v_lineage, 'IDENTITY_REVIEW_REQUIRED')
  RETURNING id INTO v_asset;

  UPDATE public.media_video_jobs
     SET status='GENERATED_REVIEW_REQUIRED', provider=p_provider, provider_job_id=p_provider_job_id,
         video_asset_ref=v_asset, actual_cost=p_actual_cost,
         cost_currency=coalesce(p_cost_currency,'USD'), updated_at=now()
   WHERE id=p_job_id;

  INSERT INTO public.media_job_costs(tenant_id, job_id, operation_type, provider, estimated_cost, actual_cost, currency)
  VALUES (p_tenant, p_job_id, 'VIDEO_GENERATION_REAL', p_provider, coalesce(j.estimated_cost,0), p_actual_cost, coalesce(p_cost_currency,'USD'));

  RETURN jsonb_build_object('status','GENERATED_REAL','asset_id',v_asset,'job_id',p_job_id,'media_type','VIDEO',
    'is_launch_safe',false,'approval_state','IN_REVIEW','lineage_state',v_lineage,
    'identity_state','IDENTITY_REVIEW_REQUIRED','product_id',v_product,'aspect_ratio',coalesce(j.aspect_ratio,'9:16'),
    'duration_s',coalesce(p_duration,j.duration_target),'provider',p_provider,'actual_cost',p_actual_cost,'cost_currency',coalesce(p_cost_currency,'USD'));
END; $fn$;

-- ---------------------------------------------------------------------------
-- 7. fn_media_retry_video_job: bounded retry (no infinite loop). Mirrors image.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_retry_video_job(p_job_id uuid, p_tenant uuid, p_error text DEFAULT 'provider_unavailable'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE j public.media_video_jobs%rowtype;
BEGIN
  SELECT * INTO j FROM public.media_video_jobs WHERE id=p_job_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  IF p_error NOT IN ('rate_limit','provider_unavailable','invalid_asset','unsupported_format','content_policy_failure','timeout','unknown_provider_error') THEN
    p_error := 'unknown_provider_error';
  END IF;
  IF coalesce(j.retry_count,0) >= coalesce(j.max_retries,2) THEN
    UPDATE public.media_video_jobs SET status='FAILED', error_state=p_error||' (max_retries_exhausted)', updated_at=now() WHERE id=p_job_id;
    RETURN jsonb_build_object('status','FAILED','retry_count',j.retry_count,'note','max retries exhausted; will not retry again (no infinite loop)');
  END IF;
  UPDATE public.media_video_jobs SET retry_count=coalesce(retry_count,0)+1, error_state=p_error,
    status=CASE WHEN public.fn_media_provider_for('VIDEO') IS NULL THEN 'BLOCKED_EXTERNAL_PROVIDER' ELSE 'QUEUED' END, updated_at=now()
    WHERE id=p_job_id;
  RETURN jsonb_build_object('status','RETRY_SCHEDULED','retry_count',coalesce(j.retry_count,0)+1,'max_retries',coalesce(j.max_retries,2),'error',p_error);
END; $fn$;

-- ---------------------------------------------------------------------------
-- 8. fn_ad_studio_creative_read (UPDATED): add a browser-safe VIDEO section
--    (latest video job + scenes + video asset). Provider secrets never exposed.
-- ---------------------------------------------------------------------------
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

  -- VIDEO section
  SELECT * INTO v_vjob FROM public.media_video_jobs WHERE angle_id=p_angle_id ORDER BY created_at DESC LIMIT 1;
  IF v_vjob.id IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('scene_number',scene_number,'duration_target',duration_target,
             'visual_action',visual_action,'motion_instruction',motion_instruction,'text_overlay',text_overlay,
             'voiceover',voiceover,'transition',transition,'claim_violations',claim_violations) ORDER BY scene_number),'[]'::jsonb)
      INTO v_scenes FROM public.media_video_scenes WHERE video_job_id=v_vjob.id;
    IF v_vjob.video_asset_ref IS NOT NULL THEN
      v_vasset := public.fn_media_generation_result(v_vjob.video_asset_ref);
    END IF;
    v_video := jsonb_build_object('job_id',v_vjob.id,'state',v_vjob.status,'provider',v_vjob.provider,
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
      ELSE jsonb_build_object('job_id',v_job.id,'state',v_job.status,'provider',v_job.provider,
        'estimated_cost',v_job.estimated_cost,'actual_cost',v_job.actual_cost,'cost_currency',v_job.cost_currency,
        'failure_reason',v_job.error_state,
        'claim_gate', v_job.provenance->'claim_gate',
        'product_identity', v_job.provenance->'product_identity') END,
    'asset', coalesce(v_asset, 'null'::jsonb),
    'video', v_video,
    'contract','ad_creative_read_v2_015g; image + video surfaced; provider secrets never exposed; identity + claim + lineage + approval states surfaced');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 9. fn_media_video_runtime_selftest: self-contained; self-cleans; asserts the
--    provider-neutral video lifecycle + all gates. Fixtures marked [[vid]].
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_video_runtime_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE
  v jsonb := '[]'::jsonb;
  tA uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  tB uuid := '3d0eb793-685a-4ec2-aea7-8b95fda7112a';
  real_shoe uuid := 'efca8b59-d814-404b-be1b-65e833fab9b8';
  v_realdec uuid;
  brC uuid; brI uuid; angC uuid; angI uuid; angBad uuid;
  srcOk uuid; srcBad uuid;
  r jsonb; comp jsonb; v_vjobC uuid; v_vjobI uuid; v_vjobBad uuid; v_vjobRights uuid;
  v_assetC uuid; v_assetI uuid; v_cfg jsonb; i int;
BEGIN
  -- cleanup any prior fixtures
  DELETE FROM public.media_job_costs WHERE job_id IN (SELECT j.id FROM public.media_video_jobs j JOIN public.ad_studio_angles a ON a.id=j.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[vid]]%');
  DELETE FROM public.media_assets WHERE creative_strategy_ref IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[vid]]%');
  DELETE FROM public.media_video_scenes WHERE video_job_id IN (SELECT j.id FROM public.media_video_jobs j JOIN public.ad_studio_angles a ON a.id=j.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[vid]]%');
  DELETE FROM public.media_video_jobs WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[vid]]%');
  DELETE FROM public.media_assets WHERE tenant_id=tA AND storage_ref LIKE 'vidsrc://%';
  DELETE FROM public.ad_studio_angles WHERE brief_id IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[vid]]%');
  DELETE FROM public.ad_studio_briefs WHERE product_name LIKE '[[vid]]%';

  -- A: VIDEO provider registered + no secret leakage in config
  SELECT config INTO v_cfg FROM public.media_providers WHERE name=public.fn_media_provider_for('VIDEO');
  -- no REAL secret key stored (the documented 'secret_storage' marker is the provenance note, not a secret)
  v := v || jsonb_build_object('case','A_video_provider_registered','pass',
    (public.fn_media_provider_for('VIDEO')='ALIBABA_QWEN_WAN_VIDEO'
     AND NOT EXISTS(SELECT 1 FROM jsonb_object_keys(v_cfg) k WHERE k <> 'secret_storage' AND lower(k) ~ '(api[_-]?key|apikey|token|password|bearer)')
     AND v_cfg ? 'secret_storage'
     AND (v_cfg->>'secret_storage') LIKE 'server_side_only%'));

  -- fixtures: canonical brief on the real shoe (GB, valid decision) + inline brief
  SELECT id INTO v_realdec FROM public.product_opportunity_decisions
    WHERE product_id=real_shoe AND country_code='GB' AND coalesce(is_fixture,false)=false LIMIT 1;

  brC := public.fn_ad_studio_build_brief(tA, jsonb_build_object('product_name','[[vid]] Canon','market','GB','market_currency','GBP',
      'problem_solved','keeping things tidy','product_id',real_shoe::text,'decision_id',v_realdec::text,
      'product_assets',jsonb_build_array('https://cf.cjdropshipping.com/vid.jpg')), true);
  INSERT INTO public.ad_studio_angles(brief_id,tenant_id,angle_index,angle_type,angle_name,customer_problem,desired_outcome,
      hook,headline,primary_copy,supporting_copy,cta,visual_concept,static_creative_brief,video_hook,video_script,claim_risk,claim_violations,review_state)
    VALUES (brC,tA,0,'PROBLEM_SOLUTION','Canon','keeping things tidy','a tidier space',
      'Looking for a simpler way?','A tidier space, made easy','See how it works and decide for yourself.','Made for everyday use.','Learn more',
      'Show the product in use','Show the product in use','Ever struggle to keep tidy?','Open on the mess. Show the product. End calmer. CTA: Learn more.','LOW','[]'::jsonb,'REVIEW_REQUIRED')
    RETURNING id INTO angC;

  brI := public.fn_ad_studio_build_brief(tA, jsonb_build_object('product_name','[[vid]] Inline','market','GB','market_currency','GBP',
      'problem_solved','keeping things tidy','product_id',gen_random_uuid()::text,
      'product_assets',jsonb_build_array('https://cf.cjdropshipping.com/vid2.jpg')), true);
  INSERT INTO public.ad_studio_angles(brief_id,tenant_id,angle_index,angle_type,angle_name,customer_problem,desired_outcome,
      hook,headline,primary_copy,supporting_copy,cta,visual_concept,static_creative_brief,video_hook,video_script,claim_risk,claim_violations,review_state)
    VALUES (brI,tA,0,'PROBLEM_SOLUTION','Inline','keeping things tidy','a tidier space',
      'Looking for a simpler way?','A tidier space, made easy','See how it works.','Everyday use.','Learn more',
      'Show the product in use','Show the product in use','Ever struggle to keep tidy?','Open on the mess. Show the product. CTA: Learn more.','LOW','[]'::jsonb,'REVIEW_REQUIRED')
    RETURNING id INTO angI;

  -- claim-violating angle for the block test
  INSERT INTO public.ad_studio_angles(brief_id,tenant_id,angle_index,angle_type,angle_name,customer_problem,desired_outcome,
      hook,headline,primary_copy,supporting_copy,cta,visual_concept,static_creative_brief,video_hook,video_script,claim_risk,claim_violations,review_state)
    VALUES (brC,tA,1,'PROBLEM_SOLUTION','Bad','tidy','tidy',
      '#1 best seller guaranteed to cure clutter','Clinically proven best on the market','Save 90% today only, limited stock!','Doctors recommend it','Buy now',
      'hero','hero','best seller','best seller script','FLAGGED','[]'::jsonb,'REVIEW_REQUIRED')
    RETURNING id INTO angBad;

  -- source assets: rights-clear + prohibited
  srcOk := public.fn_media_register_source_asset(tA, real_shoe, NULL, 'SUPPLIER_AUTHORIZED','SUPPLIER_PROVIDED','vidsrc://ok.jpg','image/jpeg','9:16',
    jsonb_build_object('source_asset_url','https://cf.cjdropshipping.com/vid.jpg','supplier','CJ'));
  srcBad := public.fn_media_register_source_asset(tA, real_shoe, NULL, 'STORE_IMPORT','PROHIBITED','vidsrc://bad.jpg','image/jpeg','9:16','{}'::jsonb);

  -- B: create_video_job canonical -> READY, lineage CANONICAL, 9:16, 4 scenes, dur in [10,15]
  r := public.fn_media_create_video_job(tA, angC, srcOk, 'TIKTOK_FEED');
  v_vjobC := (r->>'video_job_id')::uuid;
  v := v || jsonb_build_object('case','B_create_canonical_ready','pass',
    (r->>'status'='READY' AND r->>'lineage_state'='CANONICAL' AND r->>'aspect_ratio'='9:16'
     AND (r->>'scenes')::int=4 AND (r->>'duration_s')::numeric BETWEEN 10 AND 15),'got',r->>'status');

  -- C: rights block on PROHIBITED source
  r := public.fn_media_create_video_job(tA, angC, srcBad, 'TIKTOK_FEED');
  v := v || jsonb_build_object('case','C_rights_block','pass', r->>'status'='blocked_rights');

  -- D: prepare -> READY_TO_DISPATCH, claim PASS, cost>0, launch-eligible (canonical), no secret in preflight
  r := public.fn_media_prepare_video_job(v_vjobC, tA);
  v := v || jsonb_build_object('case','D_prepare_ready_to_dispatch','pass',
    (r->>'status'='READY_TO_DISPATCH' AND r->>'claim_gate'='PASS' AND (r->>'estimated_cost_usd')::numeric > 0
     AND (r->>'production_launch_eligible')::boolean=true AND r->>'aspect_ratio'='9:16'
     AND (r->>'duration_s')::numeric BETWEEN 10 AND 15 AND r->>'provider'='ALIBABA_QWEN_WAN_VIDEO'),'got',r);

  -- E: claim gate blocks a video job built on the unsafe angle
  r := public.fn_media_create_video_job(tA, angBad, srcOk, 'TIKTOK_FEED');
  v_vjobBad := (r->>'video_job_id')::uuid;
  r := public.fn_media_prepare_video_job(v_vjobBad, tA);
  v := v || jsonb_build_object('case','E_claim_gate_blocks','pass', r->>'status'='BLOCKED_CLAIM_REVIEW');

  -- F: dispatch idempotent READY_TO_DISPATCH -> GENERATING -> ALREADY_GENERATING; source url + prompt; no secret
  r := public.fn_media_dispatch_video_job(v_vjobC, tA);
  v := v || jsonb_build_object('case','F_dispatch_idempotent','pass',
    (r->>'status'='GENERATING' AND coalesce(r->>'source_image_url','')<>'' AND coalesce(r->>'prompt','')<>''
     AND r->>'secrets' LIKE 'NONE%'
     AND (public.fn_media_dispatch_video_job(v_vjobC, tA))->>'status'='ALREADY_GENERATING'));

  -- G: complete real -> VIDEO asset IN_REVIEW / not launch safe / identity review / CANONICAL / 9:16 / product backfilled
  comp := public.fn_media_complete_video_real(v_vjobC, tA, 'ALIBABA_QWEN_WAN_VIDEO','vid-exec-1','dashcam/vid-1.mp4','video/mp4',1080,1920,12,0.36,'USD',NULL,'GB',
    jsonb_build_array('https://cf.cjdropshipping.com/vid.jpg'),'p','{}'::jsonb);
  v_assetC := (comp->>'asset_id')::uuid;
  v := v || jsonb_build_object('case','G_complete_video_asset','pass',
    (comp->>'status'='GENERATED_REAL' AND comp->>'media_type'='VIDEO' AND (comp->>'is_launch_safe')::boolean=false
     AND comp->>'approval_state'='IN_REVIEW' AND comp->>'identity_state'='IDENTITY_REVIEW_REQUIRED'
     AND comp->>'lineage_state'='CANONICAL' AND comp->>'aspect_ratio'='9:16'
     AND (SELECT product_id FROM public.media_assets WHERE id=v_assetC)=real_shoe
     AND (SELECT media_type FROM public.media_assets WHERE id=v_assetC)='VIDEO'),'got',comp);

  -- H: MOCK/empty provider rejected
  r := public.fn_media_complete_video_real(v_vjobC, tA, 'MOCK','x','y.mp4','video/mp4',1080,1920,12,0,'USD',NULL,'GB','[]'::jsonb,'p','{}'::jsonb);
  v := v || jsonb_build_object('case','H_mock_rejected','pass', r->>'status'='REAL_PROVIDER_REQUIRED');

  -- I: launch eligibility blocked by identity (canonical but identity not cleared)
  r := public.fn_media_launch_eligibility(v_assetC);
  v := v || jsonb_build_object('case','I_launch_blocked_identity','pass',
    ((r->>'eligible')::boolean=false AND r->>'reason'='IDENTITY_REVIEW_REQUIRED'));

  -- J: INLINE video never launch-safe (lineage gate)
  r := public.fn_media_create_video_job(tA, angI, srcOk, 'TIKTOK_FEED');
  v_vjobI := (r->>'video_job_id')::uuid;
  PERFORM public.fn_media_prepare_video_job(v_vjobI, tA);
  PERFORM public.fn_media_dispatch_video_job(v_vjobI, tA);
  comp := public.fn_media_complete_video_real(v_vjobI, tA, 'ALIBABA_QWEN_WAN_VIDEO','vid-exec-2','dashcam/vid-2.mp4','video/mp4',1080,1920,12,0.36,'USD',NULL,'GB',
    jsonb_build_array('https://cf.cjdropshipping.com/vid2.jpg'),'p','{}'::jsonb);
  v_assetI := (comp->>'asset_id')::uuid;
  r := public.fn_media_launch_eligibility(v_assetI);
  v := v || jsonb_build_object('case','J_inline_never_launch_safe','pass',
    (comp->>'lineage_state'='INLINE_ONLY' AND (r->>'eligible')::boolean=false AND r->>'reason'='CANONICAL_PRODUCT_LINEAGE_REQUIRED'));

  -- K: bounded retry -> FAILED at max, no infinite loop
  r := public.fn_media_create_video_job(tA, angI, srcOk, 'TIKTOK_FEED');
  v_vjobRights := (r->>'video_job_id')::uuid;  -- reuse as a retry victim
  FOR i IN 1..5 LOOP r := public.fn_media_retry_video_job(v_vjobRights, tA, 'provider_unavailable'); END LOOP;
  v := v || jsonb_build_object('case','K_bounded_retry','pass',
    (r->>'status'='FAILED' AND (SELECT status FROM public.media_video_jobs WHERE id=v_vjobRights)='FAILED'),'got',r->>'status');

  -- L: tenant isolation
  v := v || jsonb_build_object('case','L_tenant_isolation','pass',
    ((public.fn_media_prepare_video_job(v_vjobC, tB))->>'status'='not_found_or_forbidden'
     AND (public.fn_media_dispatch_video_job(v_vjobC, tB))->>'status'='not_found_or_forbidden'
     AND (public.fn_media_complete_video_real(v_vjobC, tB,'ALIBABA_QWEN_WAN_VIDEO','x','z.mp4','video/mp4',1080,1920,12,0.1,'USD',NULL,'GB','[]'::jsonb,'p','{}'::jsonb))->>'status'='not_found_or_forbidden'));

  -- M: 9:16 on job + asset; scenes persisted with per-scene claim scan present
  v := v || jsonb_build_object('case','M_aspect_9_16_and_scenes','pass',
    ((SELECT aspect_ratio FROM public.media_video_jobs WHERE id=v_vjobC)='9:16'
     AND (SELECT aspect_ratio FROM public.media_assets WHERE id=v_assetC)='9:16'
     AND (SELECT count(*) FROM public.media_video_scenes WHERE video_job_id=v_vjobC)=4));

  -- N: video asset carries duration + is a genuine VIDEO row referencing the job
  v := v || jsonb_build_object('case','N_video_asset_duration','pass',
    ((SELECT duration FROM public.media_assets WHERE id=v_assetC)=12
     AND (SELECT video_asset_ref FROM public.media_video_jobs WHERE id=v_vjobC)=v_assetC));

  -- O: regressions — canonical lineage suite + image runtime suite still green
  v := v || jsonb_build_object('case','O_image_lineage_regressions','pass',
    ((public.fn_ad_studio_lineage_selftest()->>'all_pass')::boolean=true
     AND (public.fn_media_runtime_selftest()->>'all_pass')::boolean=true));

  -- cleanup
  DELETE FROM public.media_job_costs WHERE job_id IN (SELECT j.id FROM public.media_video_jobs j JOIN public.ad_studio_angles a ON a.id=j.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[vid]]%');
  DELETE FROM public.media_assets WHERE creative_strategy_ref IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[vid]]%');
  DELETE FROM public.media_video_scenes WHERE video_job_id IN (SELECT j.id FROM public.media_video_jobs j JOIN public.ad_studio_angles a ON a.id=j.angle_id JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[vid]]%');
  DELETE FROM public.media_video_jobs WHERE angle_id IN (SELECT a.id FROM public.ad_studio_angles a JOIN public.ad_studio_briefs b ON b.id=a.brief_id WHERE b.product_name LIKE '[[vid]]%');
  DELETE FROM public.media_assets WHERE tenant_id=tA AND storage_ref LIKE 'vidsrc://%';
  DELETE FROM public.ad_studio_angles WHERE brief_id IN (SELECT id FROM public.ad_studio_briefs WHERE product_name LIKE '[[vid]]%');
  DELETE FROM public.ad_studio_briefs WHERE product_name LIKE '[[vid]]%';

  RETURN jsonb_build_object('suite','ad_creative_video_runtime',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $fn$;

-- ---------------------------------------------------------------------------
-- 10. Update fn_media_creative_live_selftest: the pre-015G invariant asserted
--     NO VIDEO provider existed (video generation was correctly blocked). 015G
--     legitimately registers ONE authorized, capability-verified image->video
--     provider, so the invariant flips: a VIDEO provider MAY exist, but it must
--     be the vetted one AND must store NO secret (server_side_only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_media_creative_live_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE v_pass int:=0; v_fail int:=0; v_fails jsonb:='[]'::jsonb; v_reg jsonb; v_provider text;
BEGIN
  v_provider := public.fn_media_provider_for('VIDEO');
  -- 015G: a VIDEO provider is now registered; it must be the vetted one and hold no secret
  IF v_provider IS NULL
     OR (v_provider='ALIBABA_QWEN_WAN_VIDEO'
         AND NOT EXISTS (SELECT 1 FROM public.media_providers mp, jsonb_object_keys(mp.config) k
               WHERE mp.name=v_provider AND k <> 'secret_storage'
                 AND lower(k) ~ '(api[_-]?key|apikey|token|password|bearer)'))
  THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('video_provider_unexpected_or_secretful'::text); END IF;

  v_reg := public.fn_media_register_provider('SELFTEST_PROVIDER','IMAGE','{"modes":["edit"]}'::jsonb,
             '{"model":"x","api_key":"SHOULD_BE_STRIPPED","endpoint":"https://e"}'::jsonb);
  IF (v_reg->>'status')='REGISTERED' AND (v_reg->>'stored_secret')='false'
     AND NOT EXISTS (SELECT 1 FROM public.media_providers WHERE name='SELFTEST_PROVIDER' AND (config ? 'api_key'))
  THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('register_did_not_strip_secret'::text); END IF;

  IF (SELECT (public.fn_media_complete_image_real(gen_random_uuid(),'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'MOCK',NULL,NULL,NULL,NULL,NULL,0,'USD',NULL,'US','[]'::jsonb,'p'))->>'status') IN ('REAL_PROVIDER_REQUIRED','not_found_or_forbidden')
  THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('real_completion_accepted_mock'::text); END IF;

  IF NOT EXISTS (SELECT 1 FROM public.media_assets WHERE generation_status='MOCK_FIXTURE' AND is_launch_safe) THEN
    v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_fails:=v_fails||to_jsonb('mock_fixture_marked_launch_safe'::text); END IF;

  DELETE FROM public.media_providers WHERE name='SELFTEST_PROVIDER';

  RETURN jsonb_build_object('passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,
    'all_pass',(v_fail=0),'failures',v_fails);
END; $fn$;

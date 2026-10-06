-- STRATELOQ Premium Video — Phase 1: Veo 3.1 Fast per-scene executor CONTRACT + hard cost gate.
--
-- Extends the existing media_video_* architecture (no parallel system). PURE/DETERMINISTIC:
-- NO paid provider call is made or fired anywhere in this migration. The dispatch guard is
-- designed to REFUSE until the founder authorizes one bounded run, so these functions can be
-- exercised and tested with zero spend.
--
-- Hybrid Product Asset Lock is preserved end-to-end:
--   * GENERATED_PLATE_COMPOSITE  → Veo generates the environment/lifestyle PLATE with NO product
--                                   in frame (t2v, no product seed); the authoritative Product Card
--                                   is composited on top later; generated plate → IDENTITY_REVIEW_REQUIRED.
--   * NO_PRODUCT                 → Veo generates atmosphere only (t2v); no identity risk.
--   * REFERENCE_CONDITIONED_VALIDATE → Veo i2v seeded from the Product Card (product regenerated in
--                                   motion); identity NOT guaranteed → always IDENTITY_REVIEW_REQUIRED
--                                   + launch-unsafe (supported but not used by the default plans).
--   * DETERMINISTIC_PRODUCT      → NO Veo call: exact Product Card pixels composited deterministically.

-- 1) Compile ONE shot into a concrete Veo generation request (or mark it non-generative).
CREATE OR REPLACE FUNCTION public.fn_video_compile_scene_generation_request(
  p_shot jsonb, p_product_name text DEFAULT 'the product', p_model text DEFAULT 'veo-3.1-fast-generate-preview')
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE v_mode text := upper(coalesce(p_shot->>'identity_mode',''));
  v_gen text := coalesce(p_shot->>'generation_mode','');
  v_prompt text; v_i2v boolean := false; v_seed text := 'NONE';
  v_product_in_frame boolean; v_identity_state text; v_base text;
BEGIN
  -- Non-generative shots never touch Veo.
  IF v_gen NOT LIKE 'VEO_%' THEN
    RETURN jsonb_build_object(
      'generation','NONE_DETERMINISTIC_COMPOSITE','billable',false,'provider',NULL,
      'identity_mode',v_mode,'identity_state','AUTHORITATIVE_PRODUCT_CARD_PIXELS',
      'note','Exact Product Card pixels composited deterministically; no generative call.');
  END IF;

  v_base := concat_ws('. ',
    nullif(btrim(coalesce(p_shot->>'visual_description','')),''),
    nullif('Environment: '||btrim(coalesce(p_shot->>'environment','')),'Environment: '),
    nullif('Camera: '||btrim(coalesce(p_shot->>'camera','')),'Camera: '),
    nullif('Action: '||btrim(coalesce(p_shot->>'subject_action','')),'Action: '));

  IF v_mode = 'GENERATED_PLATE_COMPOSITE' THEN
    v_i2v := false; v_seed := 'NONE'; v_product_in_frame := false;
    v_identity_state := 'IDENTITY_REVIEW_REQUIRED';
    v_prompt := v_base
      || '. IMPORTANT: Do NOT render any product, device, package or branded object in frame. '
      || 'Generate ONLY the environment / lifestyle plate (people, space, light, atmosphere) with a '
      || 'clear, unobstructed area where a product will be composited afterwards. Vertical 9:16, premium, photoreal.';
  ELSIF v_mode = 'NO_PRODUCT' THEN
    v_i2v := false; v_seed := 'NONE'; v_product_in_frame := false;
    v_identity_state := 'NOT_APPLICABLE';
    v_prompt := v_base || '. No product in frame. Vertical 9:16, photoreal, premium.';
  ELSIF v_mode = 'REFERENCE_CONDITIONED_VALIDATE' THEN
    v_i2v := true; v_seed := 'PRODUCT_CARD_FIRST_FRAME'; v_product_in_frame := true;
    v_identity_state := 'IDENTITY_REVIEW_REQUIRED';
    v_prompt := v_base || '. Keep the product identical to the seed image; do not restyle it. Vertical 9:16, photoreal.';
  ELSE
    RETURN jsonb_build_object('generation','INVALID','error','unsupported_identity_mode_for_generation','identity_mode',v_mode);
  END IF;

  RETURN jsonb_build_object(
    'generation','VEO', 'billable', true, 'provider','GEMINI_VEO_VIDEO', 'model', p_model,
    'mode', CASE WHEN v_i2v THEN 'IMAGE_TO_VIDEO' ELSE 'TEXT_TO_VIDEO' END,
    'generation_method','predictLongRunning',
    'aspect_ratio','9:16', 'resolution','720p',
    'duration_s', coalesce((p_shot->>'duration_s')::numeric, 4),
    'prompt', v_prompt,
    'seed_image', v_seed, 'product_in_frame', v_product_in_frame,
    'identity_mode', v_mode, 'identity_state', v_identity_state,
    'overlay_policy','DETERMINISTIC_POST_GENERATION — overlays/claims are NOT baked into generated pixels',
    'retry_policy','NO_AUTOMATIC_RETRY',
    'secrets','NONE — the Gemini key lives only server-side (n8n credential / edge env)');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_video_compile_scene_generation_request(jsonb,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_compile_scene_generation_request(jsonb,text,text) TO authenticated, service_role;

-- 2) The HARD generation cost/authorization gate. Reads the GEMINI_VEO_VIDEO provider and returns
--    whether a dispatch may cross to a paid call. dispatch_allowed is TRUE only when ALL hold:
--      (a) the provider is ENABLED,
--      (b) a bounded founder generation authorization object is present on the provider config
--          (config.founder_generation_authorization = {max_usd, authorized_at, authorized_by, single_run}),
--      (c) the estimate is within BOTH the per-run cap and the authorized max.
--    With the provider disabled and no authorization present (current state) it always refuses.
CREATE OR REPLACE FUNCTION public.fn_video_generation_authorization_state(
  p_estimated_usd numeric, p_cap_usd numeric DEFAULT 5.00, p_model text DEFAULT 'veo-3.1-fast-generate-preview')
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_enabled boolean; v_cfg jsonb; v_auth jsonb; v_auth_max numeric; v_allowed boolean; v_reason text;
BEGIN
  SELECT enabled, config INTO v_enabled, v_cfg FROM public.media_providers WHERE name='GEMINI_VEO_VIDEO';
  v_auth := v_cfg->'founder_generation_authorization';
  v_auth_max := CASE WHEN jsonb_typeof(v_auth)='object' THEN (v_auth->>'max_usd')::numeric ELSE NULL END;

  v_allowed := coalesce(v_enabled,false)
    AND jsonb_typeof(v_auth)='object'
    AND v_auth_max IS NOT NULL
    AND p_estimated_usd IS NOT NULL
    AND p_estimated_usd <= LEAST(coalesce(p_cap_usd,0), v_auth_max);

  v_reason := CASE
    WHEN NOT coalesce(v_enabled,false) THEN 'PROVIDER_DISABLED — GEMINI_VEO_VIDEO is disabled; no paid call possible'
    WHEN jsonb_typeof(v_auth) IS DISTINCT FROM 'object' THEN 'NO_FOUNDER_AUTHORIZATION — no bounded generation authorization on the provider'
    WHEN v_auth_max IS NULL THEN 'AUTHORIZATION_MISSING_MAX — founder authorization has no max_usd'
    WHEN p_estimated_usd > v_auth_max THEN 'OVER_AUTHORIZED_MAX — estimate exceeds the founder-authorized max'
    WHEN p_estimated_usd > coalesce(p_cap_usd,0) THEN 'OVER_RUN_CAP — estimate exceeds the per-run cap'
    ELSE 'AUTHORIZED' END;

  RETURN jsonb_build_object(
    'dispatch_allowed', v_allowed,
    'provider_enabled', coalesce(v_enabled,false),
    'authorization_present', (jsonb_typeof(v_auth)='object'),
    'authorized_max_usd', v_auth_max,
    'estimated_usd', p_estimated_usd, 'cap_usd', p_cap_usd, 'model', p_model,
    'block_reason', CASE WHEN v_allowed THEN NULL ELSE v_reason END,
    'state', CASE WHEN v_allowed THEN 'AUTHORIZED' ELSE 'BLOCKED_PENDING_FOUNDER_AUTHORIZATION' END);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_video_generation_authorization_state(numeric,numeric,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_generation_authorization_state(numeric,numeric,text) TO authenticated, service_role;

-- 3) Build the full per-scene generation BATCH from a Creative Director plan. Compiles every shot,
--    totals the cost, evaluates the gate, and returns a staged plan. NEVER dispatches / fires anything.
CREATE OR REPLACE FUNCTION public.fn_video_build_generation_batch(
  p_tenant uuid, p_angle_id uuid, p_platform text DEFAULT 'TIKTOK',
  p_quality_family text DEFAULT 'CINEMATIC_PRODUCT_EXPERIENCE',
  p_model text DEFAULT 'veo-3.1-fast-generate-preview', p_cap_usd numeric DEFAULT 5.00)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_plan jsonb; v_scenes jsonb; v_cost jsonb; v_gate jsonb; v_est numeric; s jsonb;
BEGIN
  v_plan := public.fn_video_creative_director_plan(p_tenant, p_angle_id, p_platform, p_quality_family);
  IF v_plan->>'status' <> 'ok' THEN RETURN v_plan; END IF;

  v_scenes := (SELECT jsonb_agg(
      jsonb_build_object('index',(s->>'index')::int,'purpose',s->>'purpose',
        'request', public.fn_video_compile_scene_generation_request(s, v_plan->>'product_name', p_model))
      ORDER BY (s->>'index')::int)
    FROM jsonb_array_elements(v_plan->'shots') s);

  v_cost := public.fn_video_generation_cost_estimate(v_plan, p_model, p_cap_usd);
  v_est := (v_cost->>'estimated_total_usd')::numeric;
  v_gate := public.fn_video_generation_authorization_state(v_est, p_cap_usd, p_model);

  RETURN jsonb_build_object(
    'status', CASE WHEN (v_gate->>'dispatch_allowed')::boolean THEN 'AUTHORIZED_READY_TO_DISPATCH'
                   ELSE 'STAGED_PENDING_FOUNDER_APPROVAL' END,
    'quality_family', v_plan->>'quality_family', 'platform', v_plan->>'platform',
    'angle_id', p_angle_id, 'product_name', v_plan->>'product_name',
    'model', p_model, 'aspect_ratio','9:16',
    'veo_scene_count', v_cost->'veo_scene_count',
    'deterministic_scene_count', (SELECT count(*) FROM jsonb_array_elements(v_scenes) x WHERE x->'request'->>'generation'='NONE_DETERMINISTIC_COMPOSITE'),
    'cost', v_cost, 'authorization', v_gate,
    'scenes', v_scenes,
    'dispatch', 'NOT_DISPATCHED — this is a staged plan only; no paid call is made until the gate returns dispatch_allowed=true after a founder authorization.');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_video_build_generation_batch(uuid,uuid,text,text,text,numeric) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_build_generation_batch(uuid,uuid,text,text,text,numeric) TO authenticated, service_role;

-- 4) Static executor CONTRACT (documentation of the edge + n8n interface, no live paid workflow).
CREATE OR REPLACE FUNCTION public.fn_video_scene_executor_contract()
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'executor','video-scene-execute (edge) → n8n Veo scene workflow → Gemini Veo 3.1 Fast',
    'provider','GEMINI_VEO_VIDEO','model','veo-3.1-fast-generate-preview',
    'api','Gemini API predictLongRunning (generativelanguage.googleapis.com) on the EXISTING Gemini credential; no new account',
    'request', jsonb_build_object(
      'scene_id','uuid','video_job_id','uuid','mode','TEXT_TO_VIDEO|IMAGE_TO_VIDEO',
      'prompt','string','aspect_ratio','9:16','duration_s','numeric',
      'seed_image','NONE for plate/no-product; authoritative Product Card ONLY for reference-motion mode'),
    'poll','predictLongRunning returns an operation name; poll until done, then fetch the generated clip',
    'completion_contract','executor uploads the clip to the private pulse-generated-media bucket, then calls a completion function that records the scene asset with identity_state=IDENTITY_REVIEW_REQUIRED (generated) — a generated clip is NEVER auto-launch-safe',
    'cost_gate','fn_video_generation_authorization_state must return dispatch_allowed=true (provider enabled + founder authorization + within cap) BEFORE the edge fires; otherwise the edge must refuse',
    'secrets','NONE — the Gemini key lives only in the n8n credential / edge env; never in DB rows or responses',
    'status','CONTRACT_ONLY — not activated; no paid workflow is live until founder approval');
$function$;
REVOKE ALL ON FUNCTION public.fn_video_scene_executor_contract() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_scene_executor_contract() TO authenticated, service_role;

-- 5) Deterministic selftest (NO paid call). Proves scene compilation per identity mode, the
--    Product-Asset-Lock invariant that NO scene ever generates the product in frame (default plans),
--    and that the cost/authorization gate categorically refuses dispatch in the current state.
CREATE OR REPLACE FUNCTION public.fn_video_generation_executor_selftest(p_tenant uuid DEFAULT NULL, p_angle_id uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; v_n int; v_t uuid := p_tenant; v_a uuid := p_angle_id;
  v_plate jsonb; v_nop jsonb; v_det jsonb; v_ref jsonb; v_gate jsonb; v_batch jsonb; v_contract jsonb;
  shot_plate jsonb; shot_nop jsonb; shot_det jsonb; shot_ref jsonb;
BEGIN
  shot_plate := jsonb_build_object('index',2,'identity_mode','GENERATED_PLATE_COMPOSITE','generation_mode','VEO_T2V_PLATE_PLUS_PRODUCT_COMPOSITE',
    'duration_s',3.0,'visual_description','product on a surface','environment','lifestyle room','camera','orbit','subject_action','reveal','product_visibility','REQUIRED');
  shot_nop := jsonb_build_object('index',1,'identity_mode','NO_PRODUCT','generation_mode','VEO_T2V',
    'duration_s',2.5,'visual_description','dark room transforms','environment','room at night','camera','push-in','subject_action','atmosphere','product_visibility','OPTIONAL');
  shot_det := jsonb_build_object('index',5,'identity_mode','DETERMINISTIC_PRODUCT','generation_mode','DETERMINISTIC_PRODUCT_COMPOSITE',
    'duration_s',2.4,'visual_description','end card','environment','brand end-card','camera','locked','subject_action','hero','product_visibility','REQUIRED');
  shot_ref := jsonb_build_object('index',9,'identity_mode','REFERENCE_CONDITIONED_VALIDATE','generation_mode','VEO_I2V',
    'duration_s',3.0,'visual_description','product rotates','environment','studio','camera','orbit','subject_action','spin','product_visibility','REQUIRED');

  v_plate := public.fn_video_compile_scene_generation_request(shot_plate,'kids nightlight projector');
  v := v || jsonb_build_object('case','PLATE_IS_T2V_NO_PRODUCT_SEED_NONE','pass',
    (v_plate->>'generation'='VEO' AND v_plate->>'mode'='TEXT_TO_VIDEO'
     AND (v_plate->>'product_in_frame')::boolean=false AND v_plate->>'seed_image'='NONE'
     AND v_plate->>'identity_state'='IDENTITY_REVIEW_REQUIRED' AND (v_plate->>'billable')::boolean=true
     AND position('Do NOT render any product' in (v_plate->>'prompt'))>0),'detail',v_plate->>'mode');

  v_nop := public.fn_video_compile_scene_generation_request(shot_nop,'kids nightlight projector');
  v := v || jsonb_build_object('case','NO_PRODUCT_IS_T2V_NOT_APPLICABLE','pass',
    (v_nop->>'generation'='VEO' AND v_nop->>'mode'='TEXT_TO_VIDEO'
     AND (v_nop->>'product_in_frame')::boolean=false AND v_nop->>'identity_state'='NOT_APPLICABLE'));

  v_det := public.fn_video_compile_scene_generation_request(shot_det,'kids nightlight projector');
  v := v || jsonb_build_object('case','DETERMINISTIC_IS_NON_GENERATIVE','pass',
    (v_det->>'generation'='NONE_DETERMINISTIC_COMPOSITE' AND (v_det->>'billable')::boolean=false
     AND v_det->>'identity_state'='AUTHORITATIVE_PRODUCT_CARD_PIXELS'));

  v_ref := public.fn_video_compile_scene_generation_request(shot_ref,'kids nightlight projector');
  v := v || jsonb_build_object('case','REFERENCE_MOTION_IS_I2V_SEEDED_REVIEW_REQUIRED','pass',
    (v_ref->>'generation'='VEO' AND v_ref->>'mode'='IMAGE_TO_VIDEO'
     AND v_ref->>'seed_image'='PRODUCT_CARD_FIRST_FRAME' AND (v_ref->>'product_in_frame')::boolean=true
     AND v_ref->>'identity_state'='IDENTITY_REVIEW_REQUIRED'));

  -- Cost/authorization gate must categorically refuse in the current state (provider disabled, no auth).
  v_gate := public.fn_video_generation_authorization_state(1.97, 5.00, 'veo-3.1-fast-generate-preview');
  v := v || jsonb_build_object('case','GATE_REFUSES_WHILE_PROVIDER_DISABLED','pass',
    ((v_gate->>'dispatch_allowed')::boolean=false AND (v_gate->>'provider_enabled')::boolean=false
     AND (v_gate->>'authorization_present')::boolean=false
     AND v_gate->>'state'='BLOCKED_PENDING_FOUNDER_AUTHORIZATION'),'detail',v_gate->>'block_reason');
  -- Even a $0 estimate cannot cross while the provider is disabled (no accidental free pass).
  v := v || jsonb_build_object('case','GATE_REFUSES_EVEN_AT_ZERO_EST','pass',
    ((public.fn_video_generation_authorization_state(0,5.00)->>'dispatch_allowed')::boolean=false));

  v_contract := public.fn_video_scene_executor_contract();
  v := v || jsonb_build_object('case','EXECUTOR_CONTRACT_IS_NOT_ACTIVATED','pass',
    (v_contract->>'status' LIKE 'CONTRACT_ONLY%' AND v_contract->>'provider'='GEMINI_VEO_VIDEO'
     AND v_contract->>'secrets' LIKE 'NONE%'));

  -- Full batch on a real angle: staged (not dispatchable), within cap, and NO billable scene
  -- ever renders the product in frame (Product Asset Lock holds end-to-end).
  IF v_a IS NULL OR v_t IS NULL THEN
    SELECT a.id, a.tenant_id INTO v_a, v_t FROM public.ad_studio_angles a
      JOIN public.ad_studio_briefs b ON b.id=a.brief_id ORDER BY a.created_at DESC LIMIT 1;
  END IF;
  IF v_a IS NOT NULL THEN
    v_batch := public.fn_video_build_generation_batch(v_t, v_a, 'TIKTOK','CINEMATIC_PRODUCT_EXPERIENCE','veo-3.1-fast-generate-preview',5.00);
    v := v || jsonb_build_object('case','BATCH_STAGED_NOT_DISPATCHABLE','pass',
      (v_batch->>'status'='STAGED_PENDING_FOUNDER_APPROVAL'
       AND (v_batch->'authorization'->>'dispatch_allowed')::boolean=false
       AND (v_batch->'cost'->>'within_cap')::boolean=true));
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_batch->'scenes') s
      WHERE (s->'request'->>'billable')::boolean=true AND (s->'request'->>'product_in_frame')::boolean=true;
    v := v || jsonb_build_object('case','NO_BILLABLE_SCENE_RENDERS_PRODUCT','pass',(v_n=0),'detail',v_n);
    v := v || jsonb_build_object('case','BATCH_HAS_DETERMINISTIC_PRODUCT_CLOSE','pass',
      ((v_batch->>'deterministic_scene_count')::int>=1));
  END IF;

  SELECT count(*) INTO v_n FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean;
  RETURN jsonb_build_object('suite','veo_scene_executor_phase1',
    'total', jsonb_array_length(v), 'failed', v_n,
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'all_pass', (v_n=0), 'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_video_generation_executor_selftest(uuid,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_generation_executor_selftest(uuid,uuid) TO authenticated, service_role;

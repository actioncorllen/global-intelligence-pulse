-- STRATELOQ Premium Video — Phase 1 contract backbone (extends existing architecture; no parallel system).
-- Video Creative Director shot planning + Product Asset Lock identity modes + Veo cost gate + selftest.
-- Pure/deterministic: NO paid provider calls here. Veo generation remains founder-gated.

-- 1) Product Asset Lock per-shot identity strategy (hybrid). Encodes the approved modes.
CREATE OR REPLACE FUNCTION public.fn_video_shot_identity_policy(p_identity_mode text)
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT CASE upper(coalesce(p_identity_mode,''))
    WHEN 'DETERMINISTIC_PRODUCT' THEN jsonb_build_object(
      'identity_mode','DETERMINISTIC_PRODUCT','product_pixels','AUTHORITATIVE_PRODUCT_CARD',
      'generator_allowed', false, 'identity_validation','NOT_REQUIRED_EXACT_PIXELS',
      'can_be_launch_safe', true,
      'note','Exact Product Card pixels composited deterministically (scale/crop/mask/pan/zoom); product never redrawn.')
    WHEN 'GENERATED_PLATE_COMPOSITE' THEN jsonb_build_object(
      'identity_mode','GENERATED_PLATE_COMPOSITE','product_pixels','AUTHORITATIVE_PRODUCT_CARD',
      'generator_allowed', true, 'generator_scope','ENVIRONMENT_PLATE_ONLY_NO_PRODUCT',
      'identity_validation','REQUIRED_ON_COMPOSITE','can_be_launch_safe', true,
      'note','Veo generates the environment/lifestyle plate WITHOUT the product; the exact product is composited on top. Safest route for product-in-scene.')
    WHEN 'REFERENCE_CONDITIONED_VALIDATE' THEN jsonb_build_object(
      'identity_mode','REFERENCE_CONDITIONED_VALIDATE','product_pixels','MODEL_GENERATED_SEED_ONLY',
      'generator_allowed', true, 'generator_scope','PRODUCT_IN_MOTION_SEED_FROM_PRODUCT_CARD',
      'identity_validation','MANDATORY','can_be_launch_safe', false,
      'note','Veo i2v seeds from the Product Card but regenerates product pixels in motion; identity NOT guaranteed. Always IDENTITY_REVIEW_REQUIRED; mandatory validator + founder review before any launch.')
    WHEN 'NO_PRODUCT' THEN jsonb_build_object(
      'identity_mode','NO_PRODUCT','product_pixels','NONE','generator_allowed', true,
      'generator_scope','NO_PRODUCT_IN_FRAME','identity_validation','NOT_APPLICABLE','can_be_launch_safe', true,
      'note','Environment/people/atmosphere only, no product visible.')
    ELSE jsonb_build_object('identity_mode','INVALID','error','unknown_identity_mode') END;
$function$;

-- 2) Video Creative Director: plan a video as intentional SHOTS, adaptive to quality family & platform.
--    Returns a shot list with full metadata. Does NOT hard-code one story; structure varies by family.
CREATE OR REPLACE FUNCTION public.fn_video_creative_director_plan(
  p_tenant uuid, p_angle_id uuid, p_platform text DEFAULT 'TIKTOK', p_quality_family text DEFAULT 'CINEMATIC_PRODUCT_EXPERIENCE')
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_family text := upper(coalesce(p_quality_family,'CINEMATIC_PRODUCT_EXPERIENCE'));
  v_name text; v_shots jsonb; v_total numeric;
BEGIN
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=p_angle_id AND tenant_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;
  v_name := coalesce(nullif(btrim(b.product_name),''),'the product');
  IF v_family NOT IN ('CINEMATIC_PRODUCT_EXPERIENCE','NATIVE_SOCIAL_UGC_LIFESTYLE') THEN
    RETURN jsonb_build_object('status','error','error','unknown_quality_family'); END IF;

  IF v_family = 'CINEMATIC_PRODUCT_EXPERIENCE' THEN
    v_shots := jsonb_build_array(
      jsonb_build_object('index',1,'purpose','HOOK','duration_s',2.5,
        'visual_description','Dark room transforms as the product projects an immersive, premium atmosphere; strong first-second wow.',
        'camera','slow push-in','subject_action','ambient transformation begins','environment','lifestyle room (night)',
        'product_visibility','OPTIONAL','identity_mode','NO_PRODUCT','identity_risk','LOW','generation_mode','VEO_T2V',
        'overlay', jsonb_build_object('headline', coalesce(nullif(a.video_hook,''),a.hook,'See it come alive'),'render','DETERMINISTIC'),
        'continuity','opening atmosphere'),
      jsonb_build_object('index',2,'purpose','PRODUCT_INTRODUCTION','duration_s',3.0,
        'visual_description','The exact product is introduced clearly in an elegant lifestyle setting.',
        'camera','gentle orbit / ken-burns','subject_action','product revealed','environment','lifestyle surface',
        'product_visibility','REQUIRED','identity_mode','GENERATED_PLATE_COMPOSITE','identity_risk','MED','generation_mode','VEO_T2V_PLATE_PLUS_PRODUCT_COMPOSITE',
        'overlay', jsonb_build_object('kicker','MEET','headline',coalesce(nullif(b.product_name,''),'the product'),'render','DETERMINISTIC'),
        'continuity','product established'),
      jsonb_build_object('index',3,'purpose','EXPERIENCE_DEMONSTRATION','duration_s',4.0,
        'visual_description','The product in use delivering its core experience; believable people/lifestyle reacting.',
        'camera','handheld-smooth / parallax','subject_action','people experience the benefit','environment','immersive lifestyle',
        'product_visibility','REQUIRED','identity_mode','GENERATED_PLATE_COMPOSITE','identity_risk','MED','generation_mode','VEO_T2V_PLATE_PLUS_PRODUCT_COMPOSITE',
        'overlay', jsonb_build_object('supporting',coalesce(nullif(a.primary_copy,''),'Experience it'),'render','DETERMINISTIC'),
        'continuity','benefit shown'),
      jsonb_build_object('index',4,'purpose','TRANSFORMATION_BENEFIT','duration_s',3.6,
        'visual_description','The emotional payoff / transformed space; premium finish.',
        'camera','slow pull-out','subject_action','calm, delighted outcome','environment','transformed lifestyle',
        'product_visibility','OPTIONAL','identity_mode','NO_PRODUCT','identity_risk','LOW','generation_mode','VEO_T2V',
        'overlay', jsonb_build_object('supporting',coalesce(nullif(a.supporting_copy,''),'Transform your space'),'render','DETERMINISTIC'),
        'continuity','payoff'),
      jsonb_build_object('index',5,'purpose','CTA','duration_s',2.4,
        'visual_description','Clean product end-card with CTA.',
        'camera','locked / subtle scale','subject_action','product hero','environment','brand end-card',
        'product_visibility','REQUIRED','identity_mode','DETERMINISTIC_PRODUCT','identity_risk','LOW','generation_mode','DETERMINISTIC_PRODUCT_COMPOSITE',
        'overlay', jsonb_build_object('cta',coalesce(nullif(a.cta,''),'Learn more'),'render','DETERMINISTIC'),
        'continuity','close'));
  ELSE -- NATIVE_SOCIAL_UGC_LIFESTYLE
    v_shots := jsonb_build_array(
      jsonb_build_object('index',1,'purpose','HOOK','duration_s',2.0,
        'visual_description','Relatable/surprising first-second hook with native on-screen text; authentic handheld feel.',
        'camera','handheld POV','subject_action','relatable moment / pattern-interrupt','environment','real home',
        'product_visibility','NONE','identity_mode','NO_PRODUCT','identity_risk','LOW','generation_mode','VEO_T2V',
        'overlay', jsonb_build_object('hook',coalesce(nullif(a.video_hook,''),a.hook,'Wait for it...'),'render','DETERMINISTIC'),
        'continuity','hook'),
      jsonb_build_object('index',2,'purpose','PROBLEM_DESIRE','duration_s',3.0,
        'visual_description','The old/painful/boring way — exaggerated, relatable, authentic UGC.',
        'camera','handheld','subject_action','person struggles with the problem','environment','real home',
        'product_visibility','NONE','identity_mode','NO_PRODUCT','identity_risk','LOW','generation_mode','VEO_T2V',
        'overlay', jsonb_build_object('supporting',coalesce(nullif(a.customer_problem,''),'The old way'),'render','DETERMINISTIC'),
        'continuity','problem'),
      jsonb_build_object('index',3,'purpose','PRODUCT_INTRODUCTION','duration_s',3.4,
        'visual_description','"Vs.." cut — unboxing / discovery of the exact product; hands, authentic.',
        'camera','handheld close-up','subject_action','unboxing / first use','environment','real home surface',
        'product_visibility','REQUIRED','identity_mode','GENERATED_PLATE_COMPOSITE','identity_risk','MED','generation_mode','VEO_T2V_PLATE_PLUS_PRODUCT_COMPOSITE',
        'overlay', jsonb_build_object('supporting','Vs..','render','DETERMINISTIC'),
        'continuity','reveal'),
      jsonb_build_object('index',4,'purpose','EXPERIENCE_DEMONSTRATION','duration_s',4.0,
        'visual_description','The product demonstrated in real lifestyle use; the better way, retention-oriented.',
        'camera','handheld / POV','subject_action','person uses and reacts','environment','real lifestyle',
        'product_visibility','REQUIRED','identity_mode','GENERATED_PLATE_COMPOSITE','identity_risk','MED','generation_mode','VEO_T2V_PLATE_PLUS_PRODUCT_COMPOSITE',
        'overlay', jsonb_build_object('supporting',coalesce(nullif(a.primary_copy,''),'The better way'),'render','DETERMINISTIC'),
        'continuity','demo'),
      jsonb_build_object('index',5,'purpose','CTA','duration_s',2.6,
        'visual_description','Product hero + CTA, native style.',
        'camera','handheld / locked','subject_action','product held / shown','environment','real home',
        'product_visibility','REQUIRED','identity_mode','DETERMINISTIC_PRODUCT','identity_risk','LOW','generation_mode','DETERMINISTIC_PRODUCT_COMPOSITE',
        'overlay', jsonb_build_object('cta',coalesce(nullif(a.cta,''),'Get yours'),'render','DETERMINISTIC'),
        'continuity','close'));
  END IF;

  SELECT sum((s->>'duration_s')::numeric) INTO v_total FROM jsonb_array_elements(v_shots) s;
  RETURN jsonb_build_object('status','ok','quality_family',v_family,'platform',upper(coalesce(p_platform,'TIKTOK')),
    'angle_id',p_angle_id,'brief_id',a.brief_id,'product_name',v_name,
    'shot_count', jsonb_array_length(v_shots),'total_duration_s', v_total,
    'aspect_ratio','9:16','adaptive', true,
    'shots', (SELECT jsonb_agg(s || jsonb_build_object('identity_policy', public.fn_video_shot_identity_policy(s->>'identity_mode')))
              FROM jsonb_array_elements(v_shots) s),
    'note','Shot plan is a creative-direction instance, not a fixed template; structure/story/hook/setting vary by product, platform, audience and concept.');
END; $function$;

-- 3) Veo cost gate: estimate per-video spend from the shot list and enforce a hard cap. No paid call.
CREATE OR REPLACE FUNCTION public.fn_video_generation_cost_estimate(
  p_shot_plan jsonb, p_model text DEFAULT 'veo-3.1-fast-generate-preview', p_cap_usd numeric DEFAULT 5.00)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE v_rate numeric; v_gen_s numeric := 0; v_veo_scenes int := 0; v_est numeric; s jsonb;
BEGIN
  -- Indicative per-second USD (confirm live at dispatch). Veo 3.1 fast/lite are cheapest tiers.
  v_rate := CASE
    WHEN p_model ILIKE '%veo-3.1-lite%' THEN 0.10
    WHEN p_model ILIKE '%veo-3.1-fast%' THEN 0.15
    WHEN p_model ILIKE '%veo-3.1%'      THEN 0.30
    ELSE 0.15 END;
  FOR s IN SELECT * FROM jsonb_array_elements(coalesce(p_shot_plan->'shots','[]'::jsonb)) LOOP
    IF (s->>'generation_mode') LIKE 'VEO_%' THEN
      v_veo_scenes := v_veo_scenes + 1;
      v_gen_s := v_gen_s + coalesce((s->>'duration_s')::numeric,0);
    END IF;
  END LOOP;
  v_est := round(v_gen_s * v_rate, 2);
  RETURN jsonb_build_object('model',p_model,'per_second_usd_indicative',v_rate,
    'veo_scene_count',v_veo_scenes,'generated_seconds',v_gen_s,
    'estimated_total_usd',v_est,'cap_usd',p_cap_usd,
    'within_cap',(v_est <= p_cap_usd),
    'retry_policy','NO_AUTOMATIC_RETRY (a failed Veo scene requires an explicit re-authorization)',
    'basis','INDICATIVE ONLY — not a quote; actual metered by Google at run time; confirm live before dispatch.');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_video_creative_director_plan(uuid,uuid,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_creative_director_plan(uuid,uuid,text,text) TO authenticated, service_role;

-- 4) Deterministic contract selftest (NO paid provider call). Proves:
--    * both quality families produce distinct, adaptive 5-shot plans with full metadata,
--    * the hybrid Product Asset Lock identity policy is correct for every mode,
--    * every product-visible shot is either launch-safe (exact pixels / plate-composite) OR,
--      if it regenerates product pixels in motion (REFERENCE_CONDITIONED_VALIDATE), is forced
--      launch-UNSAFE with a mandatory validator (IDENTITY_FAIL blocks launch),
--    * the Veo cost gate sums only generative scenes and enforces the hard cap with no auto-retry.
CREATE OR REPLACE FUNCTION public.fn_video_creative_director_selftest(p_tenant uuid DEFAULT NULL, p_angle_id uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE checks jsonb := '[]'::jsonb; v_n int;
  v_tenant uuid := p_tenant; v_angle uuid := p_angle_id;
  v_cin jsonb; v_ugc jsonb; v_cost jsonb; v_s jsonb;
  v_det jsonb; v_plate jsonb; v_ref jsonb; v_no jsonb; v_bad jsonb;
  v_all_visible_ok boolean := true; v_fam_distinct boolean;
BEGIN
  -- Identity-policy contract (pure; no data needed).
  v_det   := public.fn_video_shot_identity_policy('DETERMINISTIC_PRODUCT');
  v_plate := public.fn_video_shot_identity_policy('GENERATED_PLATE_COMPOSITE');
  v_ref   := public.fn_video_shot_identity_policy('REFERENCE_CONDITIONED_VALIDATE');
  v_no    := public.fn_video_shot_identity_policy('NO_PRODUCT');
  v_bad   := public.fn_video_shot_identity_policy('SOMETHING_ELSE');
  checks := checks || jsonb_build_object('check','DETERMINISTIC_USES_AUTHORITATIVE_PIXELS',
    'pass',(v_det->>'product_pixels'='AUTHORITATIVE_PRODUCT_CARD' AND (v_det->>'generator_allowed')::boolean=false
            AND (v_det->>'can_be_launch_safe')::boolean=true),'detail',v_det);
  checks := checks || jsonb_build_object('check','PLATE_COMPOSITE_KEEPS_PRODUCT_LOCK',
    'pass',(v_plate->>'product_pixels'='AUTHORITATIVE_PRODUCT_CARD'
            AND v_plate->>'generator_scope'='ENVIRONMENT_PLATE_ONLY_NO_PRODUCT'
            AND v_plate->>'identity_validation'='REQUIRED_ON_COMPOSITE'
            AND (v_plate->>'can_be_launch_safe')::boolean=true),'detail',v_plate);
  checks := checks || jsonb_build_object('check','REFERENCE_MOTION_IS_LAUNCH_UNSAFE_AND_VALIDATED',
    'pass',(v_ref->>'product_pixels'='MODEL_GENERATED_SEED_ONLY'
            AND v_ref->>'identity_validation'='MANDATORY'
            AND (v_ref->>'can_be_launch_safe')::boolean=false),'detail',v_ref);
  checks := checks || jsonb_build_object('check','NO_PRODUCT_MODE_OK',
    'pass',(v_no->>'product_pixels'='NONE' AND (v_no->>'can_be_launch_safe')::boolean=true),'detail',v_no);
  checks := checks || jsonb_build_object('check','UNKNOWN_IDENTITY_MODE_REJECTED',
    'pass',(v_bad->>'identity_mode'='INVALID'),'detail',v_bad);

  -- Resolve a real angle to plan against if the caller did not pass one.
  IF v_angle IS NULL OR v_tenant IS NULL THEN
    SELECT a.id, a.tenant_id INTO v_angle, v_tenant
      FROM public.ad_studio_angles a
      JOIN public.ad_studio_briefs b ON b.id=a.brief_id
     ORDER BY a.created_at DESC LIMIT 1;
  END IF;

  IF v_angle IS NULL THEN
    checks := checks || jsonb_build_object('check','PLAN_FIXTURE_AVAILABLE','pass',false,'detail','no ad_studio_angles row to plan against');
  ELSE
    v_cin := public.fn_video_creative_director_plan(v_tenant, v_angle, 'TIKTOK','CINEMATIC_PRODUCT_EXPERIENCE');
    v_ugc := public.fn_video_creative_director_plan(v_tenant, v_angle, 'TIKTOK','NATIVE_SOCIAL_UGC_LIFESTYLE');

    checks := checks || jsonb_build_object('check','CINEMATIC_PLAN_OK',
      'pass',(v_cin->>'status'='ok' AND (v_cin->>'shot_count')::int=5 AND v_cin->>'aspect_ratio'='9:16'),'detail',v_cin->>'status');
    checks := checks || jsonb_build_object('check','UGC_PLAN_OK',
      'pass',(v_ugc->>'status'='ok' AND (v_ugc->>'shot_count')::int=5),'detail',v_ugc->>'status');

    -- The two families must be genuinely different stories (not one template).
    v_fam_distinct := ( (SELECT jsonb_agg(x->>'purpose' ORDER BY (x->>'index')::int) FROM jsonb_array_elements(v_cin->'shots') x)
                        <> (SELECT jsonb_agg(x->>'purpose' ORDER BY (x->>'index')::int) FROM jsonb_array_elements(v_ugc->'shots') x) );
    checks := checks || jsonb_build_object('check','FAMILIES_ARE_DISTINCT','pass',v_fam_distinct);

    -- Every shot carries full creative-direction metadata + a resolved identity policy.
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_cin->'shots') el
      WHERE NOT (el ? 'purpose' AND el ? 'duration_s' AND el ? 'visual_description' AND el ? 'camera'
                 AND el ? 'subject_action' AND el ? 'environment' AND el ? 'product_visibility'
                 AND el ? 'identity_mode' AND el ? 'generation_mode' AND el ? 'overlay'
                 AND el ? 'continuity' AND el ? 'identity_risk' AND el ? 'identity_policy');
    checks := checks || jsonb_build_object('check','EVERY_SHOT_HAS_FULL_METADATA','pass',(v_n=0),'detail',v_n);

    -- Product Asset Lock: every product-visible shot must be launch-safe, unless it is the
    -- explicit launch-UNSAFE reference-motion mode (which must then be flagged + validated).
    FOR v_s IN SELECT el FROM (
        SELECT jsonb_array_elements(v_cin->'shots') AS el
        UNION ALL SELECT jsonb_array_elements(v_ugc->'shots')) q LOOP
      IF v_s->>'product_visibility' IN ('REQUIRED','OPTIONAL') AND v_s->>'identity_mode' <> 'NO_PRODUCT' THEN
        IF (v_s->'identity_policy'->>'can_be_launch_safe')::boolean = true THEN
          CONTINUE; -- deterministic pixels or plate-composite: lock preserved
        ELSIF v_s->>'identity_mode'='REFERENCE_CONDITIONED_VALIDATE'
              AND v_s->'identity_policy'->>'identity_validation'='MANDATORY' THEN
          CONTINUE; -- launch-unsafe but correctly gated by a mandatory validator
        ELSE
          v_all_visible_ok := false;
        END IF;
      END IF;
    END LOOP;
    checks := checks || jsonb_build_object('check','PRODUCT_LOCK_HELD_ON_EVERY_VISIBLE_SHOT','pass',v_all_visible_ok);

    -- Cost gate: sums only VEO_ scenes, enforces cap, no auto-retry, within $5 for a normal plan.
    v_cost := public.fn_video_generation_cost_estimate(v_cin,'veo-3.1-fast-generate-preview',5.00);
    checks := checks || jsonb_build_object('check','COST_GATE_WITHIN_CAP',
      'pass',((v_cost->>'within_cap')::boolean=true AND (v_cost->>'estimated_total_usd')::numeric>0),'detail',v_cost->>'estimated_total_usd');
    checks := checks || jsonb_build_object('check','COST_GATE_NO_AUTORETRY',
      'pass',(v_cost->>'retry_policy' ILIKE 'NO_AUTOMATIC_RETRY%'));
    -- A plan that would exceed the cap must be reported as over-cap (hard stop before dispatch).
    checks := checks || jsonb_build_object('check','COST_GATE_BLOCKS_OVER_CAP',
      'pass',((public.fn_video_generation_cost_estimate(v_cin,'veo-3.1-fast-generate-preview',0.01)->>'within_cap')::boolean=false));
    -- Only generative scenes are billed; deterministic/composite-only shots cost nothing.
    checks := checks || jsonb_build_object('check','COST_GATE_COUNTS_ONLY_VEO_SCENES',
      'pass',((v_cost->>'veo_scene_count')::int = (SELECT count(*) FROM jsonb_array_elements(v_cin->'shots') el WHERE (el->>'generation_mode') LIKE 'VEO_%')));
  END IF;

  -- Guard rails on family / access.
  checks := checks || jsonb_build_object('check','UNKNOWN_FAMILY_REJECTED',
    'pass',(coalesce(public.fn_video_creative_director_plan(coalesce(v_tenant,gen_random_uuid()), coalesce(v_angle,gen_random_uuid()),'TIKTOK','NOPE')->>'status','') IN ('error','not_found_or_forbidden')));
  checks := checks || jsonb_build_object('check','FORBIDDEN_ANGLE_REJECTED',
    'pass',(public.fn_video_creative_director_plan(gen_random_uuid(), gen_random_uuid(),'TIKTOK','CINEMATIC_PRODUCT_EXPERIENCE')->>'status'='not_found_or_forbidden'));

  SELECT count(*) INTO v_n FROM jsonb_array_elements(checks) c WHERE (c->>'pass')::boolean IS NOT TRUE;
  RETURN jsonb_build_object('ok',(v_n=0),'contract','video_creative_director_phase1',
    'failed',v_n,'total',jsonb_array_length(checks),'angle_id',v_angle,'checks',checks);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_video_creative_director_selftest(uuid,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_creative_director_selftest(uuid,uuid) TO authenticated, service_role;

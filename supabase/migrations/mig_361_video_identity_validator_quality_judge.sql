-- STRATELOQ Premium Video — Phase 1: identity validator + rendered-video quality judge.
--
-- PURE/DETERMINISTIC decision logic (no model call here). The actual Gemini-vision assessment is a
-- CONTRACT only (fn_video_identity_quality_contract); these functions turn a structured assessment
-- into a decision, so the whole judging pipeline is unit-testable with zero spend.
--
-- Product Asset Lock, non-negotiable:
--   * IDENTITY_FAIL anywhere => the scene can NEVER be launch-safe (hard block).
--   * A generated/seeded scene is launch-safe ONLY on IDENTITY_PASS.
--   * REFERENCE_CONDITIONED_VALIDATE (product regenerated in motion) can at best reach
--     IDENTITY_REVIEW_REQUIRED — it is NEVER auto-PASS and never auto-launch-safe.
--   * DETERMINISTIC_PRODUCT is authoritative pixels => PASS by construction.
--   * NO_PRODUCT has no product identity at stake => NOT_APPLICABLE.

-- 1) Identity validator decision from a structured vision assessment.
--    p_vision = {product_match (0..1), shape_match bool, color_match bool, logo_legible bool, severe_artifacts bool}
CREATE OR REPLACE FUNCTION public.fn_video_identity_validate_decision(
  p_identity_mode text, p_vision jsonb DEFAULT NULL, p_logo_required boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE m text := upper(coalesce(p_identity_mode,''));
  pm numeric; shp boolean; col boolean; logo boolean; art boolean;
  v_state text; v_reason text; v_has boolean;
BEGIN
  IF m = 'NO_PRODUCT' THEN
    RETURN jsonb_build_object('identity_state','IDENTITY_NOT_APPLICABLE','launch_blocking',false,
      'reason','No product in frame; no identity to validate.');
  END IF;
  IF m = 'DETERMINISTIC_PRODUCT' THEN
    RETURN jsonb_build_object('identity_state','AUTHORITATIVE_PRODUCT_CARD_PIXELS','launch_blocking',false,
      'reason','Exact Product Card pixels composited; identity authoritative by construction.');
  END IF;
  IF m NOT IN ('GENERATED_PLATE_COMPOSITE','REFERENCE_CONDITIONED_VALIDATE') THEN
    RETURN jsonb_build_object('identity_state','INVALID','launch_blocking',true,'reason','unknown_identity_mode');
  END IF;

  v_has := (p_vision IS NOT NULL AND jsonb_typeof(p_vision)='object');
  IF NOT v_has THEN
    RETURN jsonb_build_object('identity_state','IDENTITY_REVIEW_REQUIRED','launch_blocking',true,
      'reason','No vision assessment supplied; a generated/seeded scene cannot auto-pass without evidence.');
  END IF;

  pm  := (p_vision->>'product_match')::numeric;
  shp := coalesce((p_vision->>'shape_match')::boolean, false);
  col := coalesce((p_vision->>'color_match')::boolean, false);
  logo:= coalesce((p_vision->>'logo_legible')::boolean, false);
  art := coalesce((p_vision->>'severe_artifacts')::boolean, false);

  -- Hard FAIL (launch-blocking): any clear identity break or a severe artifact.
  IF art OR shp = false OR col = false OR pm IS NULL OR pm < 0.75
     OR (p_logo_required AND logo = false AND coalesce(pm,0) < 0.90) THEN
    v_state := 'IDENTITY_FAIL';
    v_reason := 'Identity break: ' || concat_ws(', ',
      CASE WHEN art THEN 'severe_artifacts' END,
      CASE WHEN shp=false THEN 'shape_mismatch' END,
      CASE WHEN col=false THEN 'color_mismatch' END,
      CASE WHEN pm IS NULL THEN 'no_product_match_score' WHEN pm<0.75 THEN 'low_product_match('||pm||')' END,
      CASE WHEN p_logo_required AND logo=false AND coalesce(pm,0)<0.90 THEN 'logo_illegible' END);
    RETURN jsonb_build_object('identity_state',v_state,'launch_blocking',true,'reason',v_reason,'product_match',pm);
  END IF;

  -- Strong signal.
  IF pm >= 0.92 AND shp AND col AND NOT art AND (NOT p_logo_required OR logo) THEN
    IF m = 'REFERENCE_CONDITIONED_VALIDATE' THEN
      -- Product regenerated in motion: never auto-PASS; founder must review.
      RETURN jsonb_build_object('identity_state','IDENTITY_REVIEW_REQUIRED','launch_blocking',true,
        'reason','Reference-conditioned motion regenerates product pixels; strong match but founder review is mandatory.','product_match',pm);
    END IF;
    RETURN jsonb_build_object('identity_state','IDENTITY_PASS','launch_blocking',false,
      'reason','Composited product matches the authoritative Product Card.','product_match',pm);
  END IF;

  -- Everything else: human/founder review.
  RETURN jsonb_build_object('identity_state','IDENTITY_REVIEW_REQUIRED','launch_blocking',true,
    'reason','Borderline identity match; founder review required before launch.','product_match',pm);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_video_identity_validate_decision(text,jsonb,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_identity_validate_decision(text,jsonb,boolean) TO authenticated, service_role;

-- 2) Launch-safety rule for a scene given its identity mode + resolved identity state.
CREATE OR REPLACE FUNCTION public.fn_video_scene_launch_safety(p_identity_mode text, p_identity_state text)
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN upper(coalesce(p_identity_state,'')) = 'IDENTITY_FAIL'
      THEN jsonb_build_object('launch_safe',false,'reason','IDENTITY_FAIL — hard block')
    WHEN upper(coalesce(p_identity_mode,'')) = 'NO_PRODUCT'
      THEN jsonb_build_object('launch_safe',true,'reason','no product at stake')
    WHEN upper(coalesce(p_identity_mode,'')) = 'DETERMINISTIC_PRODUCT'
      THEN jsonb_build_object('launch_safe',true,'reason','authoritative product pixels')
    WHEN upper(coalesce(p_identity_mode,'')) = 'GENERATED_PLATE_COMPOSITE'
         AND upper(coalesce(p_identity_state,'')) = 'IDENTITY_PASS'
      THEN jsonb_build_object('launch_safe',true,'reason','plate-composite validated IDENTITY_PASS')
    WHEN upper(coalesce(p_identity_mode,'')) = 'REFERENCE_CONDITIONED_VALIDATE'
      THEN jsonb_build_object('launch_safe',false,'reason','reference-motion is never auto-launch-safe; founder review required')
    ELSE jsonb_build_object('launch_safe',false,'reason','not yet validated / review required')
  END;
$function$;
REVOKE ALL ON FUNCTION public.fn_video_scene_launch_safety(text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_scene_launch_safety(text,text) TO authenticated, service_role;

-- 3) Rendered-video quality judge decision, scored against the quality family. Dimensions are 0..1;
--    missing dimensions default to 0 (an incomplete assessment scores low — safe default).
--    Returns a 0..100 weighted score and a band PASS(>=75)/REVIEW(55..74)/FAIL(<55).
CREATE OR REPLACE FUNCTION public.fn_video_quality_judge_decision(p_quality_family text, p_scores jsonb)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE fam text := upper(coalesce(p_quality_family,'')); w jsonb; v_total numeric := 0; v_band text; k text; v_breakdown jsonb := '{}'::jsonb; sc numeric;
BEGIN
  IF jsonb_typeof(p_scores) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('status','error','error','scores_must_be_object'); END IF;
  w := CASE fam
    WHEN 'CINEMATIC_PRODUCT_EXPERIENCE' THEN jsonb_build_object(
      'hook_strength',0.20,'motion_realism',0.20,'product_clarity',0.20,'pacing',0.15,'premium_finish',0.15,'story_coherence',0.10)
    WHEN 'NATIVE_SOCIAL_UGC_LIFESTYLE' THEN jsonb_build_object(
      'hook_strength',0.25,'authenticity',0.25,'product_clarity',0.15,'pacing',0.15,'retention',0.10,'story_coherence',0.10)
    ELSE NULL END;
  IF w IS NULL THEN RETURN jsonb_build_object('status','error','error','unknown_quality_family'); END IF;

  FOR k IN SELECT jsonb_object_keys(w) LOOP
    sc := greatest(0, least(1, coalesce((p_scores->>k)::numeric, 0)));
    v_total := v_total + sc * (w->>k)::numeric;
    v_breakdown := v_breakdown || jsonb_build_object(k, jsonb_build_object('score',sc,'weight',(w->>k)::numeric));
  END LOOP;

  v_total := round(v_total * 100, 1);
  v_band := CASE WHEN v_total >= 75 THEN 'PASS' WHEN v_total >= 55 THEN 'REVIEW' ELSE 'FAIL' END;
  RETURN jsonb_build_object('status','ok','quality_family',fam,'overall_score',v_total,'band',v_band,
    'launch_quality_ok', (v_band='PASS'),
    'dimensions', v_breakdown,
    'note','Quality band judges craft vs the family benchmark; it does NOT override identity. A video needs BOTH identity (all product-visible scenes launch-safe) AND quality PASS to be launch-ready.');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_video_quality_judge_decision(text,jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_quality_judge_decision(text,jsonb) TO authenticated, service_role;

-- 4) Static Gemini-vision validator + judge interface (contract only; no live paid workflow).
CREATE OR REPLACE FUNCTION public.fn_video_identity_quality_contract()
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'identity_validator', jsonb_build_object(
      'executor','video-identity-validate (edge) -> n8n Gemini-vision workflow',
      'model','Gemini vision (existing Gemini credential; no new account)',
      'input','the authoritative Product Card image + a frame/clip of the composited or seeded scene',
      'output','{product_match 0..1, shape_match, color_match, logo_legible, severe_artifacts}',
      'decision','fn_video_identity_validate_decision turns that into IDENTITY_PASS/REVIEW/FAIL',
      'rule','IDENTITY_FAIL hard-blocks launch; generated/seeded scenes need IDENTITY_PASS to be launch-safe; reference-motion is never auto-PASS'),
    'quality_judge', jsonb_build_object(
      'executor','video-quality-judge (edge) -> n8n Gemini-vision workflow',
      'model','Gemini vision (existing Gemini credential)',
      'input','the rendered 9:16 mp4 (sampled frames) + the quality_family + the shot plan',
      'output','per-dimension 0..1 scores',
      'decision','fn_video_quality_judge_decision -> 0..100 score + PASS/REVIEW/FAIL vs the family benchmark'),
    'cost_note','These are downstream of generation and run only after a founder authorizes a bounded run; they are PAID vision calls, so they stay CONTRACT_ONLY until then.',
    'secrets','NONE — Gemini key lives only in the n8n credential / edge env',
    'status','CONTRACT_ONLY — not activated');
$function$;
REVOKE ALL ON FUNCTION public.fn_video_identity_quality_contract() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_identity_quality_contract() TO authenticated, service_role;

-- 5) Deterministic selftest (no model call).
CREATE OR REPLACE FUNCTION public.fn_video_identity_quality_selftest()
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; v_n int;
  good jsonb := jsonb_build_object('product_match',0.96,'shape_match',true,'color_match',true,'logo_legible',true,'severe_artifacts',false);
  bad  jsonb := jsonb_build_object('product_match',0.40,'shape_match',false,'color_match',true,'logo_legible',false,'severe_artifacts',true);
  mid  jsonb := jsonb_build_object('product_match',0.85,'shape_match',true,'color_match',true,'logo_legible',true,'severe_artifacts',false);
  d jsonb;
BEGIN
  -- Identity: plate-composite strong => PASS + launch-safe.
  d := public.fn_video_identity_validate_decision('GENERATED_PLATE_COMPOSITE', good);
  v := v || jsonb_build_object('case','PLATE_STRONG_IS_PASS','pass',
    (d->>'identity_state'='IDENTITY_PASS' AND (d->>'launch_blocking')::boolean=false
     AND (public.fn_video_scene_launch_safety('GENERATED_PLATE_COMPOSITE','IDENTITY_PASS')->>'launch_safe')::boolean=true));

  -- Identity: clear break => FAIL + hard block, never launch-safe.
  d := public.fn_video_identity_validate_decision('GENERATED_PLATE_COMPOSITE', bad);
  v := v || jsonb_build_object('case','IDENTITY_BREAK_IS_FAIL_AND_BLOCKS','pass',
    (d->>'identity_state'='IDENTITY_FAIL' AND (d->>'launch_blocking')::boolean=true
     AND (public.fn_video_scene_launch_safety('GENERATED_PLATE_COMPOSITE','IDENTITY_FAIL')->>'launch_safe')::boolean=false));

  -- Identity: borderline => REVIEW (not launch-safe).
  d := public.fn_video_identity_validate_decision('GENERATED_PLATE_COMPOSITE', mid);
  v := v || jsonb_build_object('case','BORDERLINE_IS_REVIEW','pass',
    (d->>'identity_state'='IDENTITY_REVIEW_REQUIRED' AND (d->>'launch_blocking')::boolean=true));

  -- Identity: missing vision => cannot auto-pass.
  v := v || jsonb_build_object('case','NO_VISION_CANNOT_PASS','pass',
    (public.fn_video_identity_validate_decision('GENERATED_PLATE_COMPOSITE', NULL)->>'identity_state'='IDENTITY_REVIEW_REQUIRED'));

  -- Reference-motion: even a strong match is NEVER auto-PASS.
  d := public.fn_video_identity_validate_decision('REFERENCE_CONDITIONED_VALIDATE', good);
  v := v || jsonb_build_object('case','REFERENCE_MOTION_NEVER_AUTO_PASS','pass',
    (d->>'identity_state'='IDENTITY_REVIEW_REQUIRED'
     AND (public.fn_video_scene_launch_safety('REFERENCE_CONDITIONED_VALIDATE','IDENTITY_REVIEW_REQUIRED')->>'launch_safe')::boolean=false));

  -- Deterministic + no-product are launch-safe by construction.
  v := v || jsonb_build_object('case','DETERMINISTIC_AND_NOPRODUCT_SAFE','pass',
    ((public.fn_video_scene_launch_safety('DETERMINISTIC_PRODUCT','AUTHORITATIVE_PRODUCT_CARD_PIXELS')->>'launch_safe')::boolean=true
     AND (public.fn_video_scene_launch_safety('NO_PRODUCT','IDENTITY_NOT_APPLICABLE')->>'launch_safe')::boolean=true));

  -- Quality judge: strong cinematic => PASS band >=75.
  d := public.fn_video_quality_judge_decision('CINEMATIC_PRODUCT_EXPERIENCE',
       jsonb_build_object('hook_strength',0.9,'motion_realism',0.85,'product_clarity',0.9,'pacing',0.8,'premium_finish',0.85,'story_coherence',0.8));
  v := v || jsonb_build_object('case','QUALITY_STRONG_CINEMATIC_PASS','pass',
    (d->>'band'='PASS' AND (d->>'overall_score')::numeric>=75),'detail',d->>'overall_score');

  -- Quality judge: weak => FAIL band <55; incomplete assessment scores low.
  d := public.fn_video_quality_judge_decision('NATIVE_SOCIAL_UGC_LIFESTYLE',
       jsonb_build_object('hook_strength',0.3,'authenticity',0.2));
  v := v || jsonb_build_object('case','QUALITY_WEAK_UGC_FAIL','pass',
    (d->>'band'='FAIL' AND (d->>'overall_score')::numeric<55),'detail',d->>'overall_score');

  -- Families weight differently (same scores -> different overall).
  v := v || jsonb_build_object('case','FAMILIES_WEIGHT_DIFFERENTLY','pass',
    ((public.fn_video_quality_judge_decision('CINEMATIC_PRODUCT_EXPERIENCE',
        jsonb_build_object('hook_strength',0.9,'authenticity',0.9,'motion_realism',0.4,'product_clarity',0.4,'premium_finish',0.4,'pacing',0.4,'retention',0.9,'story_coherence',0.4))->>'overall_score')
     <> (public.fn_video_quality_judge_decision('NATIVE_SOCIAL_UGC_LIFESTYLE',
        jsonb_build_object('hook_strength',0.9,'authenticity',0.9,'motion_realism',0.4,'product_clarity',0.4,'premium_finish',0.4,'pacing',0.4,'retention',0.9,'story_coherence',0.4))->>'overall_score')));

  -- Unknown family rejected.
  v := v || jsonb_build_object('case','UNKNOWN_FAMILY_REJECTED','pass',
    (public.fn_video_quality_judge_decision('NOPE', jsonb_build_object('hook_strength',0.9))->>'status'='error'));

  -- Contract is not activated.
  v := v || jsonb_build_object('case','CONTRACT_ONLY','pass',
    (public.fn_video_identity_quality_contract()->>'status' LIKE 'CONTRACT_ONLY%'));

  SELECT count(*) INTO v_n FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean;
  RETURN jsonb_build_object('suite','video_identity_quality_phase1',
    'total', jsonb_array_length(v), 'failed', v_n,
    'passed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'all_pass',(v_n=0),'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_video_identity_quality_selftest() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_video_identity_quality_selftest() TO authenticated, service_role;

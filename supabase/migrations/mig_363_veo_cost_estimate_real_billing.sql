-- STRATELOQ premium video — correct the Veo cost estimate to Veo's REAL billing units.
--
-- Live verification before the first benchmark dispatch (Gemini API, 2026-10) established:
--   * Veo 3.1 Fast @ 720p (video+audio) = USD 0.10 / second.
--   * The API only generates clips of 4, 6, or 8 seconds — NOT arbitrary durations.
-- The original estimator summed raw planned seconds at an indicative 0.15/s, which both
-- under-counted (no 4s-minimum rounding) and used the wrong rate. This replaces it so the
-- programmatic cap gate reflects true metered cost: each Veo scene is billed at its planned
-- duration rounded UP to the next allowed unit {4,6,8}, times the tier rate.

CREATE OR REPLACE FUNCTION public.fn_video_generation_cost_estimate(
  p_shot_plan jsonb, p_model text DEFAULT 'veo-3.1-fast-generate-preview', p_cap_usd numeric DEFAULT 5.00)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE v_rate numeric; v_billed_s numeric := 0; v_planned_s numeric := 0; v_veo_scenes int := 0;
  v_est numeric; s jsonb; d numeric; b numeric;
BEGIN
  -- Per-second USD by tier (720p, video+audio), verified live 2026-10. Confirm again at dispatch.
  v_rate := CASE
    WHEN p_model ILIKE '%veo-3.1-lite%' THEN 0.08
    WHEN p_model ILIKE '%veo-3.1-fast%' THEN 0.10
    WHEN p_model ILIKE '%veo-3.1%'      THEN 0.40
    ELSE 0.10 END;
  FOR s IN SELECT * FROM jsonb_array_elements(coalesce(p_shot_plan->'shots','[]'::jsonb)) LOOP
    IF (s->>'generation_mode') LIKE 'VEO_%' THEN
      v_veo_scenes := v_veo_scenes + 1;
      d := coalesce((s->>'duration_s')::numeric, 4);
      v_planned_s := v_planned_s + d;
      -- Veo generates only 4 / 6 / 8 second clips; round the planned duration UP to the next unit.
      b := CASE WHEN d <= 4 THEN 4 WHEN d <= 6 THEN 6 ELSE 8 END;
      v_billed_s := v_billed_s + b;
    END IF;
  END LOOP;
  v_est := round(v_billed_s * v_rate, 2);
  RETURN jsonb_build_object('model',p_model,'per_second_usd',v_rate,
    'veo_scene_count',v_veo_scenes,'planned_seconds',v_planned_s,'billed_seconds',v_billed_s,
    'clip_units','Veo bills 4/6/8s clips; planned durations round up and are trimmed in composition',
    'estimated_total_usd',v_est,'cap_usd',p_cap_usd,
    'within_cap',(v_est <= p_cap_usd),
    'retry_policy','NO_AUTOMATIC_RETRY (a failed Veo scene requires an explicit re-authorization)',
    'basis','720p video+audio tier rate verified live 2026-10; actual metered by Google at run time; confirm live before dispatch.');
END; $function$;

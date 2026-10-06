-- STRATELOQ post-P0 integrity #3a: fn_creative_format_select robustness.
-- A newer format family (e.g. SAAS_SOCIAL_SQUARE) stores auto_select_signals as an ARRAY of match
-- tokens rather than the {signal: weight} OBJECT the v1 formats use. The AUTO loop called
-- jsonb_each_text on every enabled format and raised "cannot call jsonb_each_text on a non-object",
-- breaking ALL AUTO selection (production, not just the selftest). Non-object signal rows now
-- contribute base_weight only and never crash the loop.

CREATE OR REPLACE FUNCTION public.fn_creative_format_select(p_input jsonb, p_mode text DEFAULT 'AUTO'::text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mode text := upper(coalesce(p_mode,'AUTO'));
  v_fmt  text;
  r public.creative_format_registry%ROWTYPE;
  v_best_key text; v_best_score numeric := -1; v_best_sort int;
  v_score numeric; k text; w numeric;
BEGIN
  IF v_mode = 'MANUAL' THEN
    v_fmt := upper(coalesce(p_input->>'format',''));
    SELECT * INTO r FROM public.creative_format_registry WHERE format_key=v_fmt AND enabled;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','unknown_format'); END IF;
    RETURN jsonb_build_object('ok',true,'mode','MANUAL','format',r.format_key,'label',r.display_label,
      'output_type',r.output_type,'reason','Selected by you.');
  END IF;

  FOR r IN SELECT * FROM public.creative_format_registry WHERE enabled LOOP
    v_score := coalesce(r.base_weight,0);
    IF jsonb_typeof(r.auto_select_signals) = 'object' THEN
      FOR k, w IN SELECT key, value::numeric FROM jsonb_each_text(r.auto_select_signals) LOOP
        IF coalesce((p_input->>k),'') IN ('true','t','1','yes') THEN
          v_score := v_score + w;
        END IF;
      END LOOP;
    END IF;
    IF v_score > v_best_score OR (v_score = v_best_score AND r.sort_order < v_best_sort) THEN
      v_best_score := v_score; v_best_key := r.format_key; v_best_sort := r.sort_order;
    END IF;
  END LOOP;

  SELECT * INTO r FROM public.creative_format_registry WHERE format_key=v_best_key;
  RETURN jsonb_build_object('ok',true,'mode','AUTO','format',r.format_key,'label',r.display_label,
    'output_type',r.output_type,'reason',r.auto_reason);
END; $function$;

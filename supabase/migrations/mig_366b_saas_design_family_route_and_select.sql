-- mig_366b — Creative Studio one-click design-family routing (format registry + route + select)
--
-- ROOT CAUSE: SAAS_SOCIAL_SQUARE shared generator_route='IMAGE' with the product
-- static format (GRID_MULTI_CARD), so it was indistinguishable from a product
-- creative and fell through to the generic product-image path. Its AUTO signals
-- were also array-form, so the weighted AUTO scorer could never select it on
-- business context. AUTO itself resolved only a format, never a design family.
--
-- FIX (config + routing, no new architecture):
--   1. Mark SAAS_SOCIAL_SQUARE as a design-family format via generator_route='DESIGN_FAMILY'.
--   2. Give it object-form AUTO signals so a genuine business/brand context can select it.
--   3. fn_creative_format_route now reports generation_system + requires_design_family.
--   4. fn_creative_format_select (AUTO & MANUAL) resolves the adaptive design family
--      (via fn_ci_route_design_family) when the selected format requires one.
--
-- Format vs design family separation is preserved: SAAS_SOCIAL_SQUARE stays the FORMAT;
-- BOLD_SIGNAL / EDITORIAL_INTELLIGENCE / PRODUCT_UI_STORY / INSIGHT_CARD /
-- THOUGHT_LEADERSHIP remain design FAMILIES chosen beneath it by the Creative Director.

-- 0. Allow the new design-family generator route value (constraint previously
--    restricted to VIDEO/IMAGE only).
ALTER TABLE public.creative_format_registry
  DROP CONSTRAINT IF EXISTS creative_format_registry_generator_route_check;
ALTER TABLE public.creative_format_registry
  ADD CONSTRAINT creative_format_registry_generator_route_check
  CHECK (generator_route = ANY (ARRAY['VIDEO'::text,'IMAGE'::text,'DESIGN_FAMILY'::text]));

-- 1 + 2. Re-home SAAS to the design-family route with scorable business signals.
--    base_weight 0 so an ordinary/empty context never drifts into the brand design
--    system; it is selected only when genuine business/brand signals are present.
UPDATE public.creative_format_registry
   SET generator_route    = 'DESIGN_FAMILY',
       base_weight        = 0,
       auto_select_signals = jsonb_build_object(
         'business_self',       3,
         'brand_awareness',     3,
         'thought_leadership',  2,
         'market_intelligence', 2,
         'founder_insight',     2,
         'educational_brand',   2,
         'platform_meta',       1,
         'platform_linkedin',   1)
 WHERE format_key = 'SAAS_SOCIAL_SQUARE';

-- 3. Route now exposes generation_system + requires_design_family (and keeps the
--    exact output_type / generator_route the v1 format contract asserts).
CREATE OR REPLACE FUNCTION public.fn_creative_format_route(p_format text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE r public.creative_format_registry%ROWTYPE; v_provider text; v_system text; v_requires boolean;
BEGIN
  SELECT * INTO r FROM public.creative_format_registry WHERE format_key=p_format AND enabled;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','unknown_format'); END IF;
  v_requires := (r.generator_route = 'DESIGN_FAMILY');
  v_system := CASE
     WHEN r.output_type='VIDEO' THEN 'VIDEO'
     WHEN v_requires            THEN 'CI_DESIGN_FAMILY'
     ELSE 'PRODUCT_STATIC' END;
  v_provider := CASE WHEN v_requires THEN public.fn_media_provider_for('IMAGE')
                     ELSE public.fn_media_provider_for(r.generator_route) END;
  RETURN jsonb_build_object(
    'ok', true, 'format', r.format_key, 'output_type', r.output_type,
    'generator_route', r.generator_route, 'generation_system', v_system,
    'requires_design_family', v_requires, 'provider', v_provider,
    'video_generation_paid_gated', (r.output_type='VIDEO'),
    'image_generation_paid_gated', v_requires,
    'note', CASE
       WHEN r.output_type='VIDEO' THEN 'Routes to the generative-video provider; real generation is founder cost-gated (BLOCKED_EXTERNAL_DEPENDENCY until authorized).'
       WHEN v_requires THEN 'Routes through the Creative Intelligence design-family system (Design Director -> adaptive design family -> dispatch-ready contract). Real premium image generation is paid and held at the dispatch boundary.'
       ELSE 'Routes to the existing product-static / image pipeline (available now).' END);
END; $function$;

-- 4. Select now completes the design-family decision for design-family formats.
--    Format-selection scoring is byte-for-byte the v1 behaviour; the design-family
--    resolution is additive and only fires when the chosen format requires it.
CREATE OR REPLACE FUNCTION public.fn_creative_format_select(p_input jsonb, p_mode text DEFAULT 'AUTO'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mode text := upper(coalesce(p_mode,'AUTO'));
  v_fmt  text;
  r public.creative_format_registry%ROWTYPE;
  v_best_key text; v_best_score numeric := -1; v_best_sort int;
  v_score numeric; k text; w numeric;
  v_requires boolean; v_fam jsonb; v_result jsonb; v_system text;
BEGIN
  IF v_mode = 'MANUAL' THEN
    v_fmt := upper(coalesce(p_input->>'format',''));
    SELECT * INTO r FROM public.creative_format_registry WHERE format_key=v_fmt AND enabled;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','unknown_format'); END IF;
  ELSE
    FOR r IN SELECT * FROM public.creative_format_registry WHERE enabled LOOP
      v_score := coalesce(r.base_weight,0);
      -- Only object-form auto_select_signals participate in the weighted score; any
      -- other schema contributes base_weight only and never crashes this loop.
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
  END IF;

  v_requires := (r.generator_route = 'DESIGN_FAMILY');
  v_system   := CASE WHEN r.output_type='VIDEO' THEN 'VIDEO'
                     WHEN v_requires            THEN 'CI_DESIGN_FAMILY'
                     ELSE 'PRODUCT_STATIC' END;

  v_result := jsonb_build_object('ok',true,
    'mode', CASE WHEN v_mode='MANUAL' THEN 'MANUAL' ELSE 'AUTO' END,
    'format', r.format_key, 'label', r.display_label, 'output_type', r.output_type,
    'generation_system', v_system, 'requires_design_family', v_requires,
    'reason', CASE WHEN v_mode='MANUAL' THEN 'Selected by you.' ELSE r.auto_reason END);

  -- AUTO (and MANUAL) orchestration continues into the design family when the chosen
  -- format requires one. The Creative Director chooses adaptively from the context
  -- signals; it is never a fixed mapping.
  IF v_requires THEN
    v_fam := public.fn_ci_route_design_family(
      coalesce(p_input->>'business_objective', p_input->>'objective'),
      p_input->>'audience',
      coalesce(p_input->>'platform_target', p_input->>'platform'),
      p_input->>'intelligence_type',
      p_input->>'message_intent');
    v_result := v_result || jsonb_build_object(
      'design_family', v_fam->>'design_family',
      'design_family_rationale', v_fam->>'rationale',
      'design_family_note', 'Preliminary from selector signals; the Design Director re-resolves the family at generation time from full request context.');
  END IF;

  RETURN v_result;
END; $function$;

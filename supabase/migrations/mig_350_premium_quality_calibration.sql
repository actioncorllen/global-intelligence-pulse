-- mig_350: Premium creative-quality calibration (founder recalibration after rejecting both
-- 89/90-scored candidates as not premium). ADDITIVE — extends the mig_346/348/349 quality engine;
-- does NOT redesign it and does NOT touch the base fn_ci_quality_judge / fn_ci_design_quality_evaluate
-- (so all existing suites stay intact).
--
-- Adds a strict ART-DIRECTION PREMIUM GATE that sits ON TOP of the base judge. A base PASS can only
-- reach PENDING_FOUNDER_REVIEW if it ALSO clears the premium gate. Work of the quality the founder
-- rejected scores ~37-55 on the premium scale (it can no longer earn ~89/90).
--
-- New premium dimensions (0..100, higher is better) + one risk dimension:
--   ART_DIRECTION_SOPHISTICATION, VISUAL_ORIGINALITY, GRAPHIC_SOPHISTICATION,
--   COMPOSITION_INTENTIONALITY, MESSAGE_VISUAL_RELATIONSHIP, WHITESPACE_BALANCE,
--   PREMIUM_BENCHMARK_SIMILARITY (principle-level, not copy), SUPPORTING_VISUAL_QUALITY,
--   TEMPLATE_GENERIC_RISK (HIGH = more templated/generic = penalised).
--
-- Founder REJECT overrides any AI PASS: it is recorded on the learning record
-- (calibration_label=AI_PASS_OVERRIDDEN_BY_FOUNDER_REJECT) and is the ground-truth label.
-- No publishing, scheduling, ads, spend, or auto-approval.

ALTER TABLE public.creative_quality_evaluations
  ADD COLUMN IF NOT EXISTS premium_scores  jsonb,
  ADD COLUMN IF NOT EXISTS premium_overall numeric,
  ADD COLUMN IF NOT EXISTS premium_pass    boolean;

-- ---------------------------------------------------------------------------
-- Pure premium policy over the 8 positive dims + TEMPLATE_GENERIC_RISK penalty.
-- PASS iff premium_overall>=85 AND the four craft dims>=80 AND originality>=75 AND
-- benchmark-similarity>=78 AND template risk<=35.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ci_premium_quality_gate(p jsonb)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  dims text[] := ARRAY['ART_DIRECTION_SOPHISTICATION','VISUAL_ORIGINALITY','GRAPHIC_SOPHISTICATION',
    'COMPOSITION_INTENTIONALITY','MESSAGE_VISUAL_RELATIONSHIP','WHITESPACE_BALANCE',
    'PREMIUM_BENCHMARK_SIMILARITY','SUPPORTING_VISUAL_QUALITY'];
  w jsonb := '{"ART_DIRECTION_SOPHISTICATION":0.18,"GRAPHIC_SOPHISTICATION":0.16,"MESSAGE_VISUAL_RELATIONSHIP":0.14,"COMPOSITION_INTENTIONALITY":0.13,"VISUAL_ORIGINALITY":0.12,"SUPPORTING_VISUAL_QUALITY":0.10,"PREMIUM_BENCHMARK_SIMILARITY":0.09,"WHITESPACE_BALANCE":0.08}'::jsonb;
  d text; val numeric; raw numeric := 0; missing text[] := ARRAY[]::text[];
  risk numeric; penalty numeric; overall numeric; fails text[] := ARRAY[]::text[]; passed boolean;
BEGIN
  IF p IS NULL THEN RETURN jsonb_build_object('ok',false,'error','no_premium_scores'); END IF;
  FOREACH d IN ARRAY dims LOOP
    IF NOT (p ? d) THEN missing := array_append(missing,d); CONTINUE; END IF;
    val := (p->>d)::numeric; IF val<0 OR val>100 THEN RETURN jsonb_build_object('ok',false,'error','score_out_of_range','dimension',d); END IF;
    raw := raw + val*(w->>d)::numeric;
  END LOOP;
  IF NOT (p ? 'TEMPLATE_GENERIC_RISK') THEN missing := array_append(missing,'TEMPLATE_GENERIC_RISK'); END IF;
  IF array_length(missing,1) IS NOT NULL THEN RETURN jsonb_build_object('ok',false,'error','missing_dimensions','missing',to_jsonb(missing)); END IF;
  risk := (p->>'TEMPLATE_GENERIC_RISK')::numeric;
  penalty := greatest(0, risk - 30) * 0.4;
  overall := round(raw - penalty, 2);
  IF overall < 85 THEN fails := array_append(fails,'premium_overall_below_85'); END IF;
  IF least((p->>'ART_DIRECTION_SOPHISTICATION')::numeric,(p->>'GRAPHIC_SOPHISTICATION')::numeric,
           (p->>'MESSAGE_VISUAL_RELATIONSHIP')::numeric,(p->>'COMPOSITION_INTENTIONALITY')::numeric) < 80
     THEN fails := array_append(fails,'craft_dimension_below_80'); END IF;
  IF (p->>'VISUAL_ORIGINALITY')::numeric < 75 THEN fails := array_append(fails,'originality_below_75'); END IF;
  IF (p->>'PREMIUM_BENCHMARK_SIMILARITY')::numeric < 78 THEN fails := array_append(fails,'benchmark_similarity_below_78'); END IF;
  IF risk > 35 THEN fails := array_append(fails,'template_generic_risk_above_35'); END IF;
  passed := (array_length(fails,1) IS NULL);
  RETURN jsonb_build_object('ok',true,'premium_overall',overall,'premium_pass',passed,
    'template_generic_risk',risk,'template_penalty',penalty,'failed_gates',to_jsonb(fails),
    'policy','premium_overall>=85 AND craft dims>=80 AND originality>=75 AND benchmark>=78 AND template_risk<=35');
END; $function$;

-- ---------------------------------------------------------------------------
-- Premium evaluator: base judge (truth/fabrication/asset/platform/11-dim) + premium gate.
-- A base PASS only survives if the premium gate also passes; otherwise it is downgraded
-- (REVISE while regenerations remain, else REJECT). Never auto-approves.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ci_premium_quality_evaluate(
  p_generation_id uuid, p_base_scores jsonb, p_premium_scores jsonb,
  p_provider text, p_model text, p_image_ref text,
  p_visible_weaknesses jsonb DEFAULT '[]'::jsonb, p_recommended_corrections jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  g public.creative_concept_generations%ROWTYPE; c public.creative_concepts%ROWTYPE;
  v_base jsonb; v_gate jsonb; v_base_verdict text; v_verdict text; v_review text; v_eval uuid;
BEGIN
  SELECT * INTO g FROM public.creative_concept_generations WHERE id=p_generation_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','generation_not_found'); END IF;
  SELECT * INTO c FROM public.creative_concepts WHERE id=g.concept_id;

  v_base := public.fn_ci_design_quality_evaluate(p_generation_id, p_base_scores, p_provider, p_model, p_image_ref, p_visible_weaknesses, p_recommended_corrections);
  IF NOT coalesce((v_base->>'ok')::boolean,false) THEN
    RETURN jsonb_build_object('ok',false,'stage','base_evaluate','base',v_base);
  END IF;
  v_gate := public.fn_ci_premium_quality_gate(p_premium_scores);
  IF NOT coalesce((v_gate->>'ok')::boolean,false) THEN
    RETURN jsonb_build_object('ok',false,'stage','premium_gate','premium_gate',v_gate,'base',v_base);
  END IF;

  v_base_verdict := v_base->>'verdict';
  IF v_base_verdict = 'PASS' AND NOT (v_gate->>'premium_pass')::boolean THEN
    v_verdict := CASE WHEN g.attempt_no < 3 THEN 'REVISE' ELSE 'REJECT' END;
  ELSE
    v_verdict := v_base_verdict;  -- base already REVISE/REJECT, or PASS that also cleared premium
  END IF;

  -- persist premium scores onto the (latest) evaluation row for this generation
  SELECT id INTO v_eval FROM public.creative_quality_evaluations WHERE generation_id=p_generation_id ORDER BY evaluated_at DESC LIMIT 1;
  UPDATE public.creative_quality_evaluations
     SET premium_scores=p_premium_scores, premium_overall=(v_gate->>'premium_overall')::numeric, premium_pass=(v_gate->>'premium_pass')::boolean
   WHERE id=v_eval;

  v_review := CASE v_verdict WHEN 'PASS' THEN 'PENDING_FOUNDER_REVIEW' WHEN 'REVISE' THEN 'QUALITY_CHECKED' ELSE 'REJECTED' END;
  UPDATE public.creative_concepts
     SET review_state=v_review, final_verdict = CASE WHEN v_verdict IN ('PASS','REJECT') THEN v_verdict ELSE final_verdict END
   WHERE id=c.id;

  RETURN jsonb_build_object('ok',true,'verdict',v_verdict,'review_state',v_review,
    'base_verdict',v_base_verdict,'base_overall',v_base->>'overall_score',
    'premium_overall',v_gate->>'premium_overall','premium_pass',(v_gate->>'premium_pass')::boolean,
    'template_generic_risk',v_gate->>'template_generic_risk','failed_premium_gates',v_gate->'failed_gates',
    'note','A base PASS reaches founder review ONLY if the premium gate also passes; founder review is still mandatory (no auto-approval).');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_ci_premium_quality_gate(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_premium_quality_gate(jsonb) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_premium_quality_evaluate(uuid,jsonb,jsonb,text,text,text,jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_premium_quality_evaluate(uuid,jsonb,jsonb,text,text,text,jsonb,jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Self-test (rolled back; no external calls, no publishing, no spend).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ci_premium_calibration_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb; c_tenant uuid := '5351ad83-5ce8-47b1-aef6-23f64daf415f';
  v_set uuid; v_c uuid; v_gen jsonb; v_r jsonb;
  base_good jsonb := '{"VISUAL_HIERARCHY":88,"COMPOSITION":86,"TYPOGRAPHY":84,"READABILITY":90,"BRAND_FIDELITY":85,"ASSET_FIDELITY":92,"MESSAGE_CLARITY":86,"PLATFORM_FIT":88,"ORIGINALITY":82,"CONVERSION_COMMUNICATION":83,"TRUTH_SAFETY":95}'::jsonb;
  -- the quality the founder rejected (generic/templated): fails premium
  prem_rejected jsonb := '{"ART_DIRECTION_SOPHISTICATION":58,"VISUAL_ORIGINALITY":48,"GRAPHIC_SOPHISTICATION":50,"COMPOSITION_INTENTIONALITY":62,"MESSAGE_VISUAL_RELATIONSHIP":52,"WHITESPACE_BALANCE":55,"PREMIUM_BENCHMARK_SIMILARITY":58,"SUPPORTING_VISUAL_QUALITY":50,"TEMPLATE_GENERIC_RISK":72}'::jsonb;
  -- genuinely premium craft: passes
  prem_premium jsonb := '{"ART_DIRECTION_SOPHISTICATION":88,"VISUAL_ORIGINALITY":84,"GRAPHIC_SOPHISTICATION":88,"COMPOSITION_INTENTIONALITY":88,"MESSAGE_VISUAL_RELATIONSHIP":87,"WHITESPACE_BALANCE":86,"PREMIUM_BENCHMARK_SIMILARITY":86,"SUPPORTING_VISUAL_QUALITY":86,"TEMPLATE_GENERIC_RISK":16}'::jsonb;
  -- decent dims but high template risk: must still fail
  prem_templated jsonb := '{"ART_DIRECTION_SOPHISTICATION":82,"VISUAL_ORIGINALITY":80,"GRAPHIC_SOPHISTICATION":82,"COMPOSITION_INTENTIONALITY":82,"MESSAGE_VISUAL_RELATIONSHIP":82,"WHITESPACE_BALANCE":82,"PREMIUM_BENCHMARK_SIMILARITY":82,"SUPPORTING_VISUAL_QUALITY":82,"TEMPLATE_GENERIC_RISK":70}'::jsonb;
BEGIN
  BEGIN
    -- regression FIRST (before writes) — base engine untouched
    v := v || jsonb_build_object('case','design_system_regression_intact','pass',(public.fn_ci_design_system_selftest()->>'all_pass')='true');

    -- pure gate: rejected-quality cannot reach premium and cannot score ~89
    v_r := public.fn_ci_premium_quality_gate(prem_rejected);
    v := v || jsonb_build_object('case','rejected_quality_fails_premium_gate','pass',(v_r->>'premium_pass')='false' AND (v_r->>'premium_overall')::numeric < 60, 'observed_overall', v_r->>'premium_overall');
    v_r := public.fn_ci_premium_quality_gate(prem_premium);
    v := v || jsonb_build_object('case','premium_craft_passes_gate','pass',(v_r->>'premium_pass')='true' AND (v_r->>'premium_overall')::numeric >= 85);
    v_r := public.fn_ci_premium_quality_gate(prem_templated);
    v := v || jsonb_build_object('case','template_risk_blocks_despite_decent_dims','pass',(v_r->>'premium_pass')='false' AND (v_r->'failed_gates')::text ILIKE '%template_generic_risk_above_35%');

    -- end-to-end: a base PASS with rejected-quality premium is DOWNGRADED (not founder review)
    INSERT INTO public.creative_concept_sets(tenant_id,source_mode,subject,business_objective,audience,core_message,platform,creative_format)
    VALUES (c_tenant,'BUSINESS_SELF','Strateloq','BRAND_AWARENESS','founders','Turn market signals into action','META_FACEBOOK','SAAS_SOCIAL_SQUARE') RETURNING id INTO v_set;
    INSERT INTO public.creative_concepts(set_id,tenant_id,concept_label,concept_name,message_angle,visual_concept,visual_hierarchy,composition_direction,colour_direction,imagery_direction,copy_density,typography_treatment,cta_strategy,platform_format,headline,body_copy,cta_text,declares_real_assets,design_rationale,distinctness_key,design_family,platform_target)
    VALUES (v_set,c_tenant,'A','Signal','PROBLEM_SOLUTION','dark','headline-dominant','centered','dark+cyan','abstract','low','grotesque','clear','1080x1080','Turn market signals into action','Decide and move','Learn more','[]'::jsonb,'r','FAM_BOLD_SIGNAL','BOLD_SIGNAL','META_FACEBOOK') RETURNING id INTO v_c;
    v_gen := public.fn_ci_design_director_record_generation(c_tenant, v_c, 'STRATELOQ_FREE_COMPOSER','html_chromium','pulse-generated-media/ci/p1.png', NULL);
    v_r := public.fn_ci_premium_quality_evaluate((v_gen->>'generation_id')::uuid, base_good, prem_rejected, 'CLAUDE_VISION','claude-actual-image','pulse-generated-media/ci/p1.png');
    v := v || jsonb_build_object('case','base_pass_with_weak_premium_is_downgraded','pass',
      v_r->>'base_verdict'='PASS' AND v_r->>'verdict'<>'PASS' AND v_r->>'review_state'<>'PENDING_FOUNDER_REVIEW', 'observed', v_r->>'verdict');
    v := v || jsonb_build_object('case','premium_score_persisted','pass',
      EXISTS(SELECT 1 FROM public.creative_quality_evaluations e JOIN public.creative_concept_generations gg ON gg.id=e.generation_id WHERE gg.concept_id=v_c AND e.premium_pass=false AND e.premium_overall<60));

    -- end-to-end: base PASS + premium craft -> PASS -> PENDING_FOUNDER_REVIEW (still no auto-approve)
    v_gen := public.fn_ci_design_director_record_generation(c_tenant, v_c, 'STRATELOQ_FREE_COMPOSER','html_chromium','pulse-generated-media/ci/p2.png', NULL);
    v_r := public.fn_ci_premium_quality_evaluate((v_gen->>'generation_id')::uuid, base_good, prem_premium, 'CLAUDE_VISION','claude-actual-image','pulse-generated-media/ci/p2.png');
    v := v || jsonb_build_object('case','base_pass_with_premium_reaches_founder_review','pass', v_r->>'verdict'='PASS' AND v_r->>'review_state'='PENDING_FOUNDER_REVIEW');
    v := v || jsonb_build_object('case','no_auto_approve_after_premium_pass','pass',(SELECT review_state FROM public.creative_concepts WHERE id=v_c)='PENDING_FOUNDER_REVIEW');

    -- founder override recorded on the two real rejected candidates
    v := v || jsonb_build_object('case','founder_override_recorded','pass',
      (SELECT count(*) FROM public.creative_learning_records WHERE tenant_id=c_tenant
        AND performance_metrics->>'calibration_label'='AI_PASS_OVERRIDDEN_BY_FOUNDER_REJECT')>=2);

    -- no publishing request created
    v := v || jsonb_build_object('case','no_publishing_request_created','pass',
      (SELECT count(*) FROM public.social_publishing_requests WHERE tenant_id=c_tenant AND created_at>now()-interval '2 minutes' AND content->>'subject'='PREMIUM_CALIB_SELFTEST')=0);

    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN v := v || jsonb_build_object('case','UNEXPECTED_ERROR','pass',false,'err',SQLERRM); END IF;
  END;
  RETURN jsonb_build_object('suite','premium_quality_calibration','total',jsonb_array_length(v),
    'passed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),'results',v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ci_premium_calibration_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ci_premium_calibration_selftest() TO postgres, service_role;

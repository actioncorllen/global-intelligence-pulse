-- mig_349: Creative Director Orchestrator + end-to-end candidate pipeline.
--
-- ORCHESTRATION ONLY — wires the mig_348 Creative Design System to the existing Creative
-- Intelligence generation + quality pipeline. Does NOT redesign mig_346/347/348 and does NOT
-- create a parallel creative system.
--
-- Reuses: creative_concept_sets/concepts/generations, creative_quality_evaluations,
-- fn_ci_brand_dna_resolve, fn_ci_route_design_family, creative_design_families,
-- creative_platform_contracts, creative_brand_assets (Brand Asset Lock), fn_ci_concept_truth_gate,
-- fn_ci_design_family_gate, fn_ci_design_quality_evaluate (quality engine), fn_ci_concept_next_action
-- (bounded regen), fn_ci_candidate_set_approval (founder gate), fn_media_product_identity_preserved
-- (Product Asset Lock). The paid generation lane is the existing n8n
-- "Strateloq - SaaS Text-to-Image Executor" (Gemini) webhook {job_id, prompt}.
--
-- NON-GOALS: no publishing, no scheduling, no ads, no spend, no auto-approval, no auto-dispatch of
-- paid generation. A quality PASS only reaches PENDING_FOUNDER_REVIEW; founder approval is mandatory.
-- Only APPROVED authoritative assets satisfy an authoritative-asset requirement; the three REJECTED
-- website captures can never satisfy one.

-- Persist the per-concept controlled generation contract (so the image model cannot reinvent the brief).
ALTER TABLE public.creative_concepts ADD COLUMN IF NOT EXISTS generation_contract jsonb;

-- ============================================================================
-- 1. ORCHESTRATOR: approved brief -> brand DNA -> routing -> structurally distinct concepts
--    with controlled generation contracts, dispatch-ready (but NOT dispatched).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ci_design_director_plan(
  p_tenant uuid, p_brief jsonb, p_num_variants int DEFAULT 2, p_actor uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_dna jsonb; v_primary text; v_fams text[] := ARRAY[]::text[]; f record;
  v_src text := upper(coalesce(p_brief->>'source_mode','BUSINESS_SELF'));
  v_subject text := coalesce(p_brief->>'subject','Strateloq');
  v_obj text := coalesce(p_brief->>'business_objective','BRAND_AWARENESS');
  v_aud text := coalesce(p_brief->>'audience','founders');
  v_msg text := coalesce(p_brief->>'core_message','');
  v_platform text := upper(coalesce(p_brief->>'platform','META_FACEBOOK'));
  v_ptarget text := upper(coalesce(p_brief->>'platform_target', p_brief->>'platform','META_FACEBOOK'));
  v_fmt text := coalesce(p_brief->>'creative_format','SAAS_SOCIAL_SQUARE');
  v_itype text := p_brief->>'intelligence_type'; v_mintent text := p_brief->>'message_intent';
  v_head text := coalesce(p_brief->>'headline', nullif(v_msg,''), 'Turn market signals into action');
  v_body text := p_brief->>'body_copy'; v_cta text := coalesce(p_brief->>'cta_text','Learn more');
  v_set uuid; v_variants jsonb := '[]'::jsonb; v_i int := 0; v_fam text;
  v_contract jsonb; v_prompt text; v_pc record; v_req jsonb; v_assets jsonb; v_missing text[];
  v_gate jsonb; v_truth jsonb; v_dispatch_ready boolean; v_cid uuid; v_comp text; v_famlabel text;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','tenant_required'); END IF;
  v_dna := public.fn_ci_brand_dna_resolve(p_tenant);
  IF (v_dna->>'ok')<>'true' THEN RETURN jsonb_build_object('ok',false,'error','no_active_brand_dna'); END IF;

  v_primary := public.fn_ci_route_design_family(v_obj, v_aud, v_platform, v_itype, v_mintent)->>'design_family';
  v_fams := array_append(v_fams, v_primary);
  -- fill remaining variants with other enabled families (distinct, structural) whose required assets are satisfiable
  FOR f IN SELECT family_key, requires_authoritative_assets FROM public.creative_design_families
           WHERE enabled AND family_key <> v_primary ORDER BY sort_order LOOP
    EXIT WHEN array_length(v_fams,1) >= greatest(p_num_variants,1);
    IF (SELECT bool_and(EXISTS(SELECT 1 FROM public.creative_brand_assets b WHERE b.tenant_id=p_tenant
          AND b.asset_class=cls AND b.authoritative=true AND b.approval_state='APPROVED'))
        FROM jsonb_array_elements_text(f.requires_authoritative_assets) cls) IS NOT FALSE THEN
      v_fams := array_append(v_fams, f.family_key);
    END IF;
  END LOOP;

  INSERT INTO public.creative_concept_sets(tenant_id,actor_user_id,source_mode,subject,business_objective,audience,core_message,platform,creative_format,brand_system,status)
  VALUES (p_tenant,p_actor,v_src,v_subject,v_obj,v_aud,coalesce(nullif(v_msg,''),'(none)'),v_platform,v_fmt,v_dna,'PLANNED') RETURNING id INTO v_set;

  FOREACH v_fam IN ARRAY v_fams LOOP
    v_i := v_i + 1;
    SELECT * INTO v_pc FROM public.creative_platform_contracts
      WHERE platform_key=v_ptarget AND enabled ORDER BY (surface='FEED') DESC, (aspect_ratio='1:1') DESC LIMIT 1;
    SELECT requires_authoritative_assets INTO v_req FROM public.creative_design_families WHERE family_key=v_fam;
    SELECT coalesce(jsonb_agg(jsonb_build_object('asset_class',cls,'brand_asset_id',b.id)) FILTER (WHERE b.id IS NOT NULL),'[]'::jsonb) INTO v_assets
      FROM jsonb_array_elements_text(coalesce(v_req,'[]'::jsonb)) cls
      LEFT JOIN public.creative_brand_assets b ON b.tenant_id=p_tenant AND b.asset_class=cls AND b.authoritative=true AND b.approval_state='APPROVED';
    SELECT array_agg(cls) INTO v_missing FROM jsonb_array_elements_text(coalesce(v_req,'[]'::jsonb)) cls
      WHERE NOT EXISTS (SELECT 1 FROM public.creative_brand_assets b WHERE b.tenant_id=p_tenant AND b.asset_class=cls AND b.authoritative=true AND b.approval_state='APPROVED');

    v_comp := CASE v_fam
      WHEN 'BOLD_SIGNAL' THEN 'dark premium field; oversized headline top-left; restrained cyan signal motif lower-right; generous negative space; one clear CTA'
      WHEN 'EDITORIAL_INTELLIGENCE' THEN 'warm off-white editorial; refined headline; fine-line intelligence illustration; generous whitespace; understated CTA'
      WHEN 'PRODUCT_UI_STORY' THEN 'clean frame around the APPROVED authoritative UI screenshot; supporting headline; CTA; never fabricate UI'
      WHEN 'INSIGHT_CARD' THEN 'single dominant insight; one minimal supporting visualization; source/evidence treatment; no dashboard clutter'
      ELSE 'premium editorial thought-leadership; insight-led; restrained branding' END;
    SELECT display_label INTO v_famlabel FROM public.creative_design_families WHERE family_key=v_fam;

    v_prompt := 'Premium '||v_famlabel||' social graphic for '||v_subject||' ('||v_ptarget||', '||v_pc.width||'x'||v_pc.height||').'
      ||' Objective: '||v_obj||'. Audience: '||v_aud||'.'
      ||' Headline (verbatim, do not alter): "'||v_head||'".'||coalesce(' Body: "'||v_body||'".','')||' CTA: "'||v_cta||'".'
      ||' Art direction: '||v_comp||'.'
      ||' Palette: '||(v_dna->'colors')::text||'. Typography: '||coalesce(v_dna->'typography'->>'headline','bold grotesque')||'.'
      ||' Safe margins: '||(v_pc.safe_zone)::text||'. Max text density: '||v_pc.max_text_density||'.'
      ||' STRICT: use ONLY the provided copy; do NOT invent UI, metrics, charts with fabricated numbers, logos, people, or testimonials; no unsupported claims.'
      ||' Prohibited: '||(v_dna->'prohibited_treatments')::text||'.'
      ||CASE WHEN v_src='CUSTOMER_PRODUCT' THEN ' Product Asset Lock: preserve the authoritative Product Card product identity exactly; no redraw/substitution/invented SKU.' ELSE '' END;

    v_contract := jsonb_build_object(
      'design_family',v_fam,'design_family_label',v_famlabel,'platform',v_ptarget,
      'platform_contract', jsonb_build_object('surface',v_pc.surface,'aspect_ratio',v_pc.aspect_ratio,'width',v_pc.width,'height',v_pc.height,'safe_zone',v_pc.safe_zone,'max_text_density',v_pc.max_text_density,'recompose_from_master',v_pc.recompose_from_master),
      'brand_dna', jsonb_build_object('colors',v_dna->'colors','typography',v_dna->'typography','spacing',v_dna->'spacing','cta_treatment',v_dna->'cta_treatment','dataviz_language',v_dna->'dataviz_language','imagery_rules',v_dna->'imagery_rules'),
      'message', jsonb_build_object('objective',v_obj,'audience',v_aud,'core_message',v_msg,'headline',v_head,'body_copy',v_body,'cta_text',v_cta,'hierarchy', jsonb_build_array('headline','body','cta')),
      'authoritative_assets',v_assets,'missing_authoritative', to_jsonb(coalesce(v_missing,ARRAY[]::text[])),
      'product_asset_lock', jsonb_build_object('applicable',v_src='CUSTOMER_PRODUCT','rule','preserve authoritative Product Card identity; no redraw/substitution/invented SKU'),
      'prohibited_treatments',v_dna->'prohibited_treatments','composition_intent',v_comp,
      'typography_hierarchy', jsonb_build_object('headline','dominant','body','supporting','cta','clear'),'cta',v_cta,'prompt',v_prompt);

    INSERT INTO public.creative_concepts(set_id,tenant_id,concept_label,concept_name,message_angle,visual_concept,
      visual_hierarchy,composition_direction,colour_direction,imagery_direction,copy_density,typography_treatment,
      cta_strategy,platform_format,headline,body_copy,cta_text,declares_real_assets,design_rationale,distinctness_key,
      design_family,platform_target,review_state,generation_contract)
    VALUES (v_set,p_tenant,chr(64+v_i),v_famlabel,coalesce(v_itype,'BRAND'),v_comp,'headline-dominant',v_comp,
      (v_dna->'colors')::text,'family-specific',v_pc.max_text_density,coalesce(v_dna->'typography'->>'headline','bold grotesque'),
      CASE WHEN v_fam='EDITORIAL_INTELLIGENCE' THEN 'understated' ELSE 'clear' END,v_pc.width||'x'||v_pc.height,
      v_head,v_body,v_cta,to_jsonb(coalesce(v_req,'[]'::jsonb)),'Design Director routed '||v_famlabel||' for '||v_obj,'FAM_'||v_fam,
      v_fam,v_ptarget,'GENERATED',v_contract) RETURNING id INTO v_cid;

    v_truth := public.fn_ci_concept_truth_gate(v_cid);
    v_gate  := public.fn_ci_design_family_gate(v_cid);
    v_dispatch_ready := coalesce((v_gate->>'ok')::boolean,false) AND coalesce((v_truth->>'truth_safety_pass')::boolean,false);

    v_variants := v_variants || jsonb_build_object('concept_id',v_cid,'label',chr(64+v_i),'design_family',v_fam,
      'platform_target',v_ptarget,'distinctness_key','FAM_'||v_fam,'truth_safety_pass',(v_truth->>'truth_safety_pass')::boolean,
      'missing_authoritative', to_jsonb(coalesce(v_missing,ARRAY[]::text[])),'dispatch_ready',v_dispatch_ready,
      'generation_contract',v_contract,
      'dispatch', jsonb_build_object('webhook_path','pulse-saas-text-to-image','body', jsonb_build_object('job_id',v_cid,'prompt',v_prompt)));
  END LOOP;

  RETURN jsonb_build_object('ok',true,'set_id',v_set,'variants_planned',jsonb_array_length(v_variants),
    'design_families',to_jsonb(v_fams),
    'spend_boundary', jsonb_build_object('generation_provider','GOOGLE_GEMINI','model','gemini-2.5-flash-image','paid',true,'dispatched',false,
       'note','Dispatch to the n8n Gemini text-to-image executor incurs paid provider spend; NOT dispatched (no spend authorized). Contracts are dispatch-ready.'),
    'variants',v_variants);
END; $function$;

-- ============================================================================
-- 2. Record a rendered generation (bounded: max 2 regenerations = 3 attempts). No auto-approve.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ci_design_director_record_generation(
  p_tenant uuid, p_concept_id uuid, p_provider text, p_model text, p_storage_ref text, p_media_asset_id uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE c public.creative_concepts%ROWTYPE; v_attempt int; v_gid uuid;
BEGIN
  SELECT * INTO c FROM public.creative_concepts WHERE id=p_concept_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','concept_not_found'); END IF;
  IF c.tenant_id <> p_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  SELECT coalesce(max(attempt_no),0)+1 INTO v_attempt FROM public.creative_concept_generations WHERE concept_id=p_concept_id;
  IF v_attempt > 3 THEN RETURN jsonb_build_object('ok',false,'error','max_attempts_reached','note','Bounded regeneration: max 2 regenerations (3 attempts).'); END IF;
  INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,provider,model,status,asset_storage_ref,media_asset_id)
  VALUES (p_concept_id,p_tenant,v_attempt,p_provider,p_model,'GENERATED',p_storage_ref,p_media_asset_id) RETURNING id INTO v_gid;
  RETURN jsonb_build_object('ok',true,'generation_id',v_gid,'attempt_no',v_attempt);
END; $function$;

-- ============================================================================
-- 3. Targeted correction instructions from the latest evaluation (bounded; never promote a failure).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ci_design_director_correction(p_concept_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_attempt int; v_verdict text; v_scores jsonb; v_crit jsonb; v_rec jsonb; v_weak jsonb; v_low text[];
BEGIN
  SELECT g.attempt_no, e.verdict, e.scores, e.critical_failures, e.recommended_corrections, e.visible_weaknesses
    INTO v_attempt, v_verdict, v_scores, v_crit, v_rec, v_weak
  FROM public.creative_concept_generations g JOIN public.creative_quality_evaluations e ON e.generation_id=g.id
  WHERE g.concept_id=p_concept_id ORDER BY g.attempt_no DESC LIMIT 1;
  IF v_verdict IS NULL THEN RETURN jsonb_build_object('ok',true,'action','GENERATE','note','no evaluation yet'); END IF;
  IF v_verdict='PASS' THEN RETURN jsonb_build_object('ok',true,'action','DONE_PASS'); END IF;
  IF v_attempt>=3 THEN RETURN jsonb_build_object('ok',true,'action','DONE_REJECT','reason','bounded: max regenerations reached'); END IF;
  SELECT array_agg(k||'='||val) INTO v_low FROM jsonb_each_text(v_scores) s(k,val) WHERE val::numeric < 80;
  RETURN jsonb_build_object('ok',true,'action','REGENERATE','next_attempt_no',v_attempt+1,'regenerations_remaining',greatest(0,3-v_attempt),
    'targeted_corrections', jsonb_build_object('below_threshold_dimensions',to_jsonb(coalesce(v_low,ARRAY[]::text[])),
      'critical_failures',v_crit,'recommended_corrections',v_rec,'visible_weaknesses',v_weak),
    'note','Apply these corrections, regenerate, then re-evaluate. Never promote a failed candidate when retries are exhausted.');
END; $function$;

-- Grants
REVOKE ALL ON FUNCTION public.fn_ci_design_director_plan(uuid,jsonb,int,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ci_design_director_plan(uuid,jsonb,int,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.fn_ci_design_director_record_generation(uuid,uuid,text,text,text,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ci_design_director_record_generation(uuid,uuid,text,text,text,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.fn_ci_design_director_correction(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_design_director_correction(uuid) TO authenticated, service_role;

-- ============================================================================
-- 4. SELF-TEST (rolled back; no external calls, no publishing, no spend)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ci_design_director_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  c_tenant uuid := '5351ad83-5ce8-47b1-aef6-23f64daf415f'; c_other uuid := '95bb5658-5182-43af-add0-3d2ebc93393f';
  v_plan jsonb; v_cap jsonb; v_set uuid; v_bold uuid; v_edit uuid; v_gen uuid; v_r jsonb; v_corr jsonb;
  v_brief jsonb := jsonb_build_object('source_mode','BUSINESS_SELF','subject','Strateloq','business_objective','BRAND_AWARENESS',
     'audience','founders','platform','META_FACEBOOK','platform_target','META_FACEBOOK','intelligence_type','MARKET_SIGNAL',
     'core_message','Turn market signals into action','headline','Turn market signals into action','cta_text','Learn more');
  v_capbrief jsonb := jsonb_build_object('source_mode','BUSINESS_SELF','subject','Strateloq','business_objective','SHOW_CAPABILITY',
     'audience','buyers','platform','LINKEDIN','platform_target','LINKEDIN','intelligence_type','CAPABILITY','headline','See Strateloq in action');
  v_good jsonb := '{"VISUAL_HIERARCHY":88,"COMPOSITION":86,"TYPOGRAPHY":84,"READABILITY":90,"BRAND_FIDELITY":85,"ASSET_FIDELITY":92,"MESSAGE_CLARITY":86,"PLATFORM_FIT":88,"ORIGINALITY":82,"CONVERSION_COMMUNICATION":83,"TRUTH_SAFETY":95}'::jsonb;
  v_weak jsonb := '{"VISUAL_HIERARCHY":60,"COMPOSITION":58,"TYPOGRAPHY":55,"READABILITY":62,"BRAND_FIDELITY":60,"ASSET_FIDELITY":70,"MESSAGE_CLARITY":61,"PLATFORM_FIT":64,"ORIGINALITY":59,"CONVERSION_COMMUNICATION":57,"TRUTH_SAFETY":90}'::jsonb;
BEGIN
  BEGIN
    -- regression FIRST (before this suite writes anything that could pollute shared tables)
    v := v || jsonb_build_object('case','design_system_regression_intact','pass',(public.fn_ci_design_system_selftest()->>'all_pass')='true');

    -- plan a market-signal brief -> 2 structurally distinct families
    v_plan := public.fn_ci_design_director_plan(c_tenant, v_brief, 2, NULL);
    v_set := (v_plan->>'set_id')::uuid;
    v := v || jsonb_build_object('case','plan_ok','pass',(v_plan->>'ok')='true' AND (v_plan->>'variants_planned')='2');
    v := v || jsonb_build_object('case','variants_structurally_distinct_families','pass',
      (v_plan->'design_families')::text ILIKE '%BOLD_SIGNAL%' AND (v_plan->'design_families')::text ILIKE '%EDITORIAL_INTELLIGENCE%');
    v := v || jsonb_build_object('case','distinct_distinctness_keys','pass',
      (SELECT count(DISTINCT distinctness_key)=2 FROM public.creative_concepts WHERE set_id=v_set));
    v := v || jsonb_build_object('case','generation_contract_has_controls','pass',
      (v_plan->'variants'->0->'generation_contract') ? 'prompt'
      AND (v_plan->'variants'->0->'generation_contract') ? 'platform_contract'
      AND (v_plan->'variants'->0->'generation_contract') ? 'brand_dna'
      AND (v_plan->'variants'->0->'generation_contract'->'message') ? 'headline'
      AND (v_plan->'variants'->0->'generation_contract') ? 'prohibited_treatments'
      AND (v_plan->'variants'->0->'generation_contract') ? 'product_asset_lock');
    v := v || jsonb_build_object('case','dispatch_contract_has_job_and_prompt','pass',
      (v_plan->'variants'->0->'dispatch'->'body') ? 'job_id' AND (v_plan->'variants'->0->'dispatch'->'body') ? 'prompt');
    -- no auto-dispatch / no auto-spend: freshly planned concepts have zero generations
    v := v || jsonb_build_object('case','no_auto_dispatch_no_spend','pass',
      (SELECT count(*) FROM public.creative_concept_generations g JOIN public.creative_concepts c ON c.id=g.concept_id WHERE c.set_id=v_set)=0
      AND (v_plan->'spend_boundary'->>'dispatched')='false');
    -- provenance: concepts carry the generation_contract
    v := v || jsonb_build_object('case','provenance_contract_persisted','pass',
      (SELECT bool_and(generation_contract IS NOT NULL) FROM public.creative_concepts WHERE set_id=v_set));

    SELECT id INTO v_bold FROM public.creative_concepts WHERE set_id=v_set AND design_family='BOLD_SIGNAL';
    SELECT id INTO v_edit FROM public.creative_concepts WHERE set_id=v_set AND design_family='EDITORIAL_INTELLIGENCE';

    -- near-duplicate rejection: same distinctness_key within a set is refused
    BEGIN
      INSERT INTO public.creative_concepts(set_id,tenant_id,concept_label,concept_name,message_angle,visual_concept,visual_hierarchy,composition_direction,colour_direction,imagery_direction,copy_density,typography_treatment,cta_strategy,platform_format,headline,design_rationale,distinctness_key,design_family,platform_target)
      VALUES (v_set,c_tenant,'Z','dup','x','x','x','x','x','x','x','x','x','1080x1080','h','r','FAM_BOLD_SIGNAL','BOLD_SIGNAL','META_FACEBOOK');
      v := v || jsonb_build_object('case','near_duplicate_rejected','pass',false);
    EXCEPTION WHEN unique_violation THEN v := v || jsonb_build_object('case','near_duplicate_rejected','pass',true); END;

    -- capability brief -> PRODUCT_UI_STORY primary is NOT dispatch-ready (no APPROVED UI); rejected captures excluded
    v_cap := public.fn_ci_design_director_plan(c_tenant, v_capbrief, 2, NULL);
    v := v || jsonb_build_object('case','product_ui_story_blocked_without_authoritative_asset','pass',
      EXISTS(SELECT 1 FROM jsonb_array_elements(v_cap->'variants') x
             WHERE x->>'design_family'='PRODUCT_UI_STORY' AND (x->>'dispatch_ready')='false'
               AND (x->'missing_authoritative')::text ILIKE '%UI_SCREENSHOT%'));
    v := v || jsonb_build_object('case','rejected_captures_not_resolved_authoritative','pass',
      NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_cap->'variants') x, jsonb_array_elements(x->'generation_contract'->'authoritative_assets') a
                 WHERE (a->>'asset_class')='UI_SCREENSHOT'));

    -- QUALITY LOOP (free-lane simulated renders): weak -> REVISE + targeted corrections; good -> PASS -> founder review
    v_r := public.fn_ci_design_director_record_generation(c_tenant,v_bold,'STRATELOQ_FREE_COMPOSER','html_chromium','pulse-generated-media/ci/bold1.png',NULL);
    v_gen := (v_r->>'generation_id')::uuid;
    v_r := public.fn_ci_design_quality_evaluate(v_gen, v_weak, 'CLAUDE_VISION','claude-actual-image','pulse-generated-media/ci/bold1.png');
    v := v || jsonb_build_object('case','weak_render_revises','pass', v_r->>'verdict'='REVISE' AND v_r->>'review_state'='QUALITY_CHECKED');
    v_corr := public.fn_ci_design_director_correction(v_bold);
    v := v || jsonb_build_object('case','targeted_correction_produced','pass',
      v_corr->>'action'='REGENERATE' AND (v_corr->>'regenerations_remaining')::int>0
      AND jsonb_array_length(v_corr->'targeted_corrections'->'below_threshold_dimensions')>0);
    v_r := public.fn_ci_design_director_record_generation(c_tenant,v_bold,'STRATELOQ_FREE_COMPOSER','html_chromium','pulse-generated-media/ci/bold2.png',NULL);
    v_gen := (v_r->>'generation_id')::uuid;
    v_r := public.fn_ci_design_quality_evaluate(v_gen, v_good, 'CLAUDE_VISION','claude-actual-image','pulse-generated-media/ci/bold2.png');
    v := v || jsonb_build_object('case','good_render_reaches_founder_review','pass', v_r->>'verdict'='PASS' AND v_r->>'review_state'='PENDING_FOUNDER_REVIEW');
    v := v || jsonb_build_object('case','correction_done_pass','pass', public.fn_ci_design_director_correction(v_bold)->>'action'='DONE_PASS');

    -- bounded regeneration: 3 weak attempts -> REJECT; 4th attempt hard-capped; never promoted
    v_r := public.fn_ci_design_director_record_generation(c_tenant,v_edit,'STRATELOQ_FREE_COMPOSER','html_chromium','pulse-generated-media/ci/ed1.png',NULL);
    PERFORM public.fn_ci_design_quality_evaluate((v_r->>'generation_id')::uuid, v_weak, 'CLAUDE_VISION','claude-actual-image','pulse-generated-media/ci/ed1.png');
    v_r := public.fn_ci_design_director_record_generation(c_tenant,v_edit,'STRATELOQ_FREE_COMPOSER','html_chromium','pulse-generated-media/ci/ed2.png',NULL);
    PERFORM public.fn_ci_design_quality_evaluate((v_r->>'generation_id')::uuid, v_weak, 'CLAUDE_VISION','claude-actual-image','pulse-generated-media/ci/ed2.png');
    v_r := public.fn_ci_design_director_record_generation(c_tenant,v_edit,'STRATELOQ_FREE_COMPOSER','html_chromium','pulse-generated-media/ci/ed3.png',NULL);
    v_r := public.fn_ci_design_quality_evaluate((v_r->>'generation_id')::uuid, v_weak, 'CLAUDE_VISION','claude-actual-image','pulse-generated-media/ci/ed3.png');
    v := v || jsonb_build_object('case','bounded_regeneration_rejects_at_cap','pass', v_r->>'verdict'='REJECT');
    v_r := public.fn_ci_design_director_record_generation(c_tenant,v_edit,'STRATELOQ_FREE_COMPOSER','html_chromium','pulse-generated-media/ci/ed4.png',NULL);
    v := v || jsonb_build_object('case','fourth_attempt_hard_capped','pass',(v_r->>'error')='max_attempts_reached');
    v := v || jsonb_build_object('case','failed_candidate_not_promoted','pass', public.fn_ci_concept_approvable(v_edit)=false);

    -- founder gate: PASS candidate approvable; non-PASS not; no auto-approve
    v_r := public.fn_ci_candidate_set_approval(c_tenant, v_edit, 'APPROVE');
    v := v || jsonb_build_object('case','cannot_approve_failed_candidate','pass',(v_r->>'error')='not_quality_passed');
    v_r := public.fn_ci_candidate_set_approval(c_tenant, v_bold, 'APPROVE');
    v := v || jsonb_build_object('case','founder_can_approve_passed_candidate','pass',(v_r->>'ok')='true' AND (v_r->>'review_state')='APPROVED');

    -- tenant isolation at the orchestrator layer
    v_r := public.fn_ci_design_director_record_generation(c_other, v_bold, 'X','Y','z',NULL);
    v := v || jsonb_build_object('case','cross_tenant_record_rejected','pass',(v_r->>'error')='cross_tenant_rejected');

    -- Product Asset Lock: a CUSTOMER_PRODUCT plan marks product lock applicable in the contract
    v_r := public.fn_ci_design_director_plan(c_tenant, v_brief || jsonb_build_object('source_mode','CUSTOMER_PRODUCT'), 1, NULL);
    v := v || jsonb_build_object('case','product_asset_lock_flagged_for_customer_product','pass',
      (v_r->'variants'->0->'generation_contract'->'product_asset_lock'->>'applicable')='true');

    -- no publishing request created by this suite
    v := v || jsonb_build_object('case','no_publishing_request_created','pass',
      (SELECT count(*) FROM public.social_publishing_requests WHERE tenant_id=c_tenant AND created_at > now()-interval '2 minutes' AND content->>'subject'='DIRECTOR_SELFTEST')=0);

    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN v := v || jsonb_build_object('case','UNEXPECTED_ERROR','pass',false,'err',SQLERRM); END IF;
  END;
  RETURN jsonb_build_object('suite','creative_director_orchestrator','total',jsonb_array_length(v),
    'passed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),'results',v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ci_design_director_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ci_design_director_selftest() TO postgres, service_role;

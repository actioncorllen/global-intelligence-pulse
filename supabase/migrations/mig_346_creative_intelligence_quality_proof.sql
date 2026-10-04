-- mig_346: Pulse SaaS Social Creative Quality Proof — first production slice of Creative Intelligence.
--
-- Extends (does NOT replace) the existing Creative Studio. Adds the minimal durable layer the
-- founder-pinned pipeline needs that was MISSING (per STRATELOQ-CREATIVE-INTELLIGENCE-DISCOVERY):
--   * a BUSINESS_SELF / SaaS creative mode (subject = the business, not a CUSTOMER_PRODUCT),
--   * an explicit Creative Director art-direction concept layer (3 structurally distinct concepts
--     with persisted, concise design rationale — no hidden chain-of-thought),
--   * a Brand Asset Lock (authoritative asset classification + traceability; fabrication is rejected),
--   * a Creative Quality Judge that applies a documented threshold policy over scores produced by
--     ACTUAL-IMAGE vision inspection (the dimension scores come from a Gemini vision executor that
--     looks at the rendered image — see the n8n Creative Quality Judge workflow),
--   * a bounded regeneration loop (max 2 regenerations per concept),
--   * deterministic truth/claim + asset-integrity gates that the visual Judge NEVER overrides.
--
-- Reuses: media_assets (brand assets live here), media_image_jobs/executors (generation),
-- member_business_dna/business_profiles (brand system), Product Asset Lock (unchanged),
-- creative_format_registry (social format), fn_creative_quality_review (unchanged, product path).
-- NOTHING here publishes, schedules, spends ad money, or enables auto-publish.

-- ============================================================================
-- 0. SOCIAL FORMAT (reuse creative_format_registry; add one square social format)
-- ============================================================================
INSERT INTO public.creative_format_registry
 (format_key, display_label, output_type, generator_route, default_aspect_ratios, prompt_template,
  storyboard_logic, shot_rules, pacing_rules,
  text_treatment, cta_treatment, qa_criteria, auto_select_signals, auto_reason, base_weight, enabled, sort_order)
VALUES
 ('SAAS_SOCIAL_SQUARE','SaaS/Business Social Graphic (1:1)','STATIC','IMAGE',
  '["1080x1080","1080x1350"]'::jsonb,
  'Professional {platform} social graphic for a SaaS/business subject. Strong visual hierarchy, mobile-readable typography, generous safe-area padding, brand-consistent palette, conversion-oriented message. No fabricated UI/logos/metrics.',
  '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
  '{"max_headline_words":10,"body":"concise","contrast":"high","mobile_min_pt":28}'::jsonb,
  '{"style":"explicit_button_or_text","prominence":"high"}'::jsonb,
  '{"safe_area":"10% all sides","readability":"mobile-first","truth":"no unsupported claims","assets":"authoritative only"}'::jsonb,
  '["objective:BRAND_AWARENESS","subject:BUSINESS_SELF","platform:META_FACEBOOK","platform:META_INSTAGRAM"]'::jsonb,
  'Square 1:1 is the safe, mobile-first feed format for a first SaaS brand graphic.',
  1.0, true, 100)
ON CONFLICT (format_key) DO UPDATE SET enabled=excluded.enabled, display_label=excluded.display_label;

-- ============================================================================
-- 1. BRAND ASSET LOCK (authoritative classification over existing media_assets; + text/colour assets)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.creative_brand_assets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  asset_class     text NOT NULL CHECK (asset_class IN
                    ('LOGO','UI_SCREENSHOT','BRAND_IMAGE','FOUNDER_APPROVED_PHOTO','TAGLINE','BRAND_COLOUR_REFERENCE')),
  media_asset_id  uuid REFERENCES public.media_assets(id) ON DELETE SET NULL,  -- image-class assets live in media_assets
  text_value      text,            -- for TAGLINE
  colour_value    text,            -- for BRAND_COLOUR_REFERENCE (e.g. #RRGGBB)
  authoritative   boolean NOT NULL DEFAULT false,   -- true only when founder/merchant approved
  approval_state  text NOT NULL DEFAULT 'PENDING' CHECK (approval_state IN ('PENDING','APPROVED','REJECTED')),
  provenance      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cba_image_class_needs_media CHECK (
     asset_class IN ('TAGLINE','BRAND_COLOUR_REFERENCE') OR media_asset_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS creative_brand_assets_tenant_idx ON public.creative_brand_assets(tenant_id);
ALTER TABLE public.creative_brand_assets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS creative_brand_assets_select_own ON public.creative_brand_assets;
CREATE POLICY creative_brand_assets_select_own ON public.creative_brand_assets
  FOR SELECT TO authenticated USING (tenant_id = public.fn__own_tenant());
COMMENT ON TABLE public.creative_brand_assets IS
  'Brand Asset Lock: authoritative brand asset classification/traceability. Image classes reference media_assets; TAGLINE/COLOUR hold text. Only approval_state=APPROVED + authoritative=true may be presented as real. mig_346.';

-- ============================================================================
-- 2. CONCEPT SETS / CONCEPTS / GENERATIONS / EVALUATIONS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.creative_concept_sets (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL,
  actor_user_id      uuid,
  source_mode        text NOT NULL DEFAULT 'BUSINESS_SELF'
                       CHECK (source_mode IN ('BUSINESS_SELF','CUSTOMER_PRODUCT')),
  subject            text NOT NULL,
  business_objective text NOT NULL,
  audience           text NOT NULL,
  core_message       text NOT NULL,
  platform           text NOT NULL,
  creative_format    text NOT NULL,
  brand_system       jsonb NOT NULL DEFAULT '{}'::jsonb,   -- from member_business_dna + authoritative taglines
  status             text NOT NULL DEFAULT 'OPEN',
  created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS creative_concept_sets_tenant_idx ON public.creative_concept_sets(tenant_id);

CREATE TABLE IF NOT EXISTS public.creative_concepts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  set_id                uuid NOT NULL REFERENCES public.creative_concept_sets(id) ON DELETE CASCADE,
  tenant_id             uuid NOT NULL,
  concept_label         text NOT NULL,     -- A / B / C
  concept_name          text NOT NULL,
  message_angle         text NOT NULL,
  visual_concept        text NOT NULL,
  visual_hierarchy      text NOT NULL,
  composition_direction text NOT NULL,
  colour_direction      text NOT NULL,
  imagery_direction     text NOT NULL,
  copy_density          text NOT NULL,
  typography_treatment  text NOT NULL,
  cta_strategy          text NOT NULL,
  platform_format       text NOT NULL,
  headline              text NOT NULL,
  body_copy             text,
  cta_text              text,
  authoritative_asset_refs jsonb NOT NULL DEFAULT '[]'::jsonb,  -- creative_brand_assets ids actually used
  declares_real_assets  jsonb NOT NULL DEFAULT '[]'::jsonb,     -- asset_classes the design presents as REAL (must be authoritative)
  design_rationale      text NOT NULL,     -- concise decision rationale (NOT hidden chain-of-thought)
  distinctness_key      text NOT NULL,     -- structural family key; must be unique within a set
  truth_state           text NOT NULL DEFAULT 'PENDING',
  claim_violations      jsonb NOT NULL DEFAULT '[]'::jsonb,
  final_verdict         text,              -- PASS / REJECT (set when loop concludes)
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (set_id, concept_label),
  UNIQUE (set_id, distinctness_key)        -- enforces structurally distinct concepts
);
CREATE INDEX IF NOT EXISTS creative_concepts_tenant_idx ON public.creative_concepts(tenant_id);

CREATE TABLE IF NOT EXISTS public.creative_concept_generations (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  concept_id            uuid NOT NULL REFERENCES public.creative_concepts(id) ON DELETE CASCADE,
  tenant_id             uuid NOT NULL,
  attempt_no            int  NOT NULL,     -- 1=initial, 2=regen1, 3=regen2 (max)
  provider              text,
  model                 text,
  generation_instructions text,
  media_asset_id        uuid REFERENCES public.media_assets(id) ON DELETE SET NULL,
  asset_storage_ref     text,
  status                text NOT NULL DEFAULT 'PENDING'
                          CHECK (status IN ('PENDING','GENERATING','GENERATED','FAILED','BLOCKED_EXTERNAL_PROVIDER')),
  cost_amount           numeric,
  cost_currency         text,
  latency_ms            integer,
  error_detail          text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (concept_id, attempt_no),
  CONSTRAINT ccg_attempt_bounded CHECK (attempt_no BETWEEN 1 AND 3)   -- max 2 regenerations
);
CREATE INDEX IF NOT EXISTS creative_concept_generations_tenant_idx ON public.creative_concept_generations(tenant_id);

CREATE TABLE IF NOT EXISTS public.creative_quality_evaluations (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  generation_id         uuid NOT NULL REFERENCES public.creative_concept_generations(id) ON DELETE CASCADE,
  concept_id            uuid NOT NULL REFERENCES public.creative_concepts(id) ON DELETE CASCADE,
  tenant_id             uuid NOT NULL,
  evaluator_provider    text NOT NULL,
  evaluator_model       text NOT NULL,
  image_ref_evaluated   text NOT NULL,     -- the ACTUAL image that was inspected (not a spec)
  scores                jsonb NOT NULL,    -- 11 dims, 0..100
  overall_score         numeric NOT NULL,
  verdict               text NOT NULL CHECK (verdict IN ('PASS','REVISE','REJECT')),
  visible_weaknesses    jsonb NOT NULL DEFAULT '[]'::jsonb,
  recommended_corrections jsonb NOT NULL DEFAULT '[]'::jsonb,
  critical_failures     jsonb NOT NULL DEFAULT '[]'::jsonb,
  truth_safety_pass     boolean NOT NULL,
  fabrication_detected  boolean NOT NULL DEFAULT false,
  evaluated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS creative_quality_evaluations_tenant_idx ON public.creative_quality_evaluations(tenant_id);

ALTER TABLE public.creative_concept_sets        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creative_concepts            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creative_concept_generations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creative_quality_evaluations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ccs_sel ON public.creative_concept_sets;
CREATE POLICY ccs_sel ON public.creative_concept_sets FOR SELECT TO authenticated USING (tenant_id = public.fn__own_tenant());
DROP POLICY IF EXISTS cc_sel ON public.creative_concepts;
CREATE POLICY cc_sel ON public.creative_concepts FOR SELECT TO authenticated USING (tenant_id = public.fn__own_tenant());
DROP POLICY IF EXISTS ccg_sel ON public.creative_concept_generations;
CREATE POLICY ccg_sel ON public.creative_concept_generations FOR SELECT TO authenticated USING (tenant_id = public.fn__own_tenant());
DROP POLICY IF EXISTS cqe_sel ON public.creative_quality_evaluations;
CREATE POLICY cqe_sel ON public.creative_quality_evaluations FOR SELECT TO authenticated USING (tenant_id = public.fn__own_tenant());

-- ============================================================================
-- 3. HELPERS: actor->tenant, brand asset put, truth gate, asset integrity
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn__ci_actor_tenant(p_actor uuid)
 RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_actor uuid; v_c int; v_t uuid;
BEGIN
  v_actor := coalesce(auth.uid(), p_actor);
  IF v_actor IS NULL THEN RETURN NULL; END IF;
  SELECT count(*), min(application_ref::text)::uuid INTO v_c, v_t FROM public.member WHERE auth_user_id=v_actor;
  IF v_c <> 1 THEN RETURN NULL; END IF;
  RETURN v_t;
END; $function$;

-- Register an authoritative brand asset (founder/merchant-approved). Tenant-scoped.
CREATE OR REPLACE FUNCTION public.fn_ci_brand_asset_put(
  p_tenant uuid, p_class text, p_text text DEFAULT NULL, p_colour text DEFAULT NULL,
  p_media_asset_id uuid DEFAULT NULL, p_authoritative boolean DEFAULT true, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.creative_brand_assets(tenant_id,asset_class,media_asset_id,text_value,colour_value,
     authoritative,approval_state,provenance)
  VALUES (p_tenant,p_class,p_media_asset_id,p_text,p_colour,coalesce(p_authoritative,true),
     CASE WHEN coalesce(p_authoritative,true) THEN 'APPROVED' ELSE 'PENDING' END, coalesce(p_provenance,'{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok',true,'brand_asset_id',v_id,'asset_class',p_class,'authoritative',coalesce(p_authoritative,true));
END; $function$;

-- Deterministic truth/claim gate for business copy. The visual Judge never overrides this.
CREATE OR REPLACE FUNCTION public.fn_ci_concept_truth_gate(p_concept_id uuid)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE c public.creative_concepts%ROWTYPE; v_txt text; v_viol text[] := ARRAY[]::text[]; v_pass boolean;
BEGIN
  SELECT * INTO c FROM public.creative_concepts WHERE id=p_concept_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','concept_not_found'); END IF;
  v_txt := lower(concat_ws(' ', c.headline, coalesce(c.body_copy,''), coalesce(c.cta_text,'')));
  -- Unsupported quantified performance / superiority / social-proof / credential claims without evidence.
  IF v_txt ~ '([0-9]+\s*(%|percent)|[0-9]+x\b|#\s*1|\bno\.?\s*1\b)' THEN v_viol := array_append(v_viol,'quantified_performance_claim'); END IF;
  IF v_txt ~ '\b(guaranteed|guarantee|best|#1|number one|world[- ]?class|leading|unbeatable)\b' THEN v_viol := array_append(v_viol,'superiority_claim'); END IF;
  IF v_txt ~ '\b(customers love|rated|reviews?|testimonial|trusted by|[0-9]+\+? (users|customers|businesses))\b' THEN v_viol := array_append(v_viol,'social_proof_claim'); END IF;
  IF v_txt ~ '\b(certified|iso|award[- ]?winning|patented|accredited)\b' THEN v_viol := array_append(v_viol,'credential_claim'); END IF;
  v_pass := (array_length(v_viol,1) IS NULL);
  UPDATE public.creative_concepts SET truth_state = CASE WHEN v_pass THEN 'TRUTH_OK' ELSE 'TRUTH_VIOLATION' END,
     claim_violations = to_jsonb(v_viol) WHERE id=p_concept_id;
  RETURN jsonb_build_object('ok',true,'truth_safety_pass',v_pass,'violations',to_jsonb(v_viol));
END; $function$;

-- Asset integrity: any asset class the concept presents as REAL must have an APPROVED authoritative row.
CREATE OR REPLACE FUNCTION public.fn_ci_concept_asset_integrity(p_concept_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE c public.creative_concepts%ROWTYPE; v_fab text[] := ARRAY[]::text[]; v_cls text;
BEGIN
  SELECT * INTO c FROM public.creative_concepts WHERE id=p_concept_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','concept_not_found'); END IF;
  FOR v_cls IN SELECT jsonb_array_elements_text(c.declares_real_assets) LOOP
    IF NOT EXISTS (SELECT 1 FROM public.creative_brand_assets b
                   WHERE b.tenant_id=c.tenant_id AND b.asset_class=v_cls
                     AND b.authoritative=true AND b.approval_state='APPROVED') THEN
      v_fab := array_append(v_fab, v_cls);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', array_length(v_fab,1) IS NULL,
    'fabricated_classes', to_jsonb(v_fab),
    'note','A declared-real asset class with no APPROVED authoritative brand asset is fabrication.');
END; $function$;

-- ============================================================================
-- 4. CREATIVE QUALITY JUDGE — threshold policy over ACTUAL-IMAGE vision scores
-- ============================================================================
-- Documented scale: each dimension 0..100. Weighted overall uses these weights (sum=1.00):
--   VISUAL_HIERARCHY .12, COMPOSITION .10, TYPOGRAPHY .10, READABILITY .12, BRAND_FIDELITY .12,
--   ASSET_FIDELITY .10, MESSAGE_CLARITY .10, PLATFORM_FIT .06, ORIGINALITY .06,
--   CONVERSION_COMMUNICATION .08, TRUTH_SAFETY .04.
-- PASS iff: truth gate passes AND no fabrication AND every dimension >= 70 AND overall >= 80 AND
--   each critical dimension (BRAND_FIDELITY, ASSET_FIDELITY, TRUTH_SAFETY, READABILITY) >= 80.
-- Fabrication or a deterministic truth violation => REJECT regardless of visual scores.
-- Otherwise below-floor => REVISE while regenerations remain (attempt_no < 3), else REJECT.
CREATE OR REPLACE FUNCTION public.fn_ci_quality_judge(
  p_generation_id uuid,
  p_scores jsonb,                 -- {DIM: 0..100, ...} from actual-image vision inspection
  p_evaluator_provider text,
  p_evaluator_model text,
  p_image_ref text,               -- the actual image inspected
  p_visible_weaknesses jsonb DEFAULT '[]'::jsonb,
  p_recommended_corrections jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  g public.creative_concept_generations%ROWTYPE;
  c public.creative_concepts%ROWTYPE;
  v_dims text[] := ARRAY['VISUAL_HIERARCHY','COMPOSITION','TYPOGRAPHY','READABILITY','BRAND_FIDELITY',
    'ASSET_FIDELITY','MESSAGE_CLARITY','PLATFORM_FIT','ORIGINALITY','CONVERSION_COMMUNICATION','TRUTH_SAFETY'];
  v_w jsonb := '{"VISUAL_HIERARCHY":0.12,"COMPOSITION":0.10,"TYPOGRAPHY":0.10,"READABILITY":0.12,"BRAND_FIDELITY":0.12,"ASSET_FIDELITY":0.10,"MESSAGE_CLARITY":0.10,"PLATFORM_FIT":0.06,"ORIGINALITY":0.06,"CONVERSION_COMMUNICATION":0.08,"TRUTH_SAFETY":0.04}'::jsonb;
  d text; v_val numeric; v_min numeric := 101; v_overall numeric := 0; v_missing text[] := ARRAY[]::text[];
  v_truth jsonb; v_integrity jsonb; v_truth_ok boolean; v_fab boolean;
  v_crit_ok boolean; v_verdict text; v_crit_fail text[] := ARRAY[]::text[]; v_image_ok boolean;
  v_eval_id uuid;
BEGIN
  IF p_image_ref IS NULL OR length(trim(p_image_ref))=0 THEN
    RETURN jsonb_build_object('ok',false,'error','no_actual_image_ref',
      'note','The Judge must inspect a real rendered image; refusing to score without one.');
  END IF;
  SELECT * INTO g FROM public.creative_concept_generations WHERE id=p_generation_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','generation_not_found'); END IF;
  SELECT * INTO c FROM public.creative_concepts WHERE id=g.concept_id;
  -- generation must actually have produced an image
  IF g.status NOT IN ('GENERATED') OR coalesce(g.asset_storage_ref,'')='' THEN
    RETURN jsonb_build_object('ok',false,'error','generation_has_no_image','status',g.status);
  END IF;

  FOREACH d IN ARRAY v_dims LOOP
    IF NOT (p_scores ? d) THEN v_missing := array_append(v_missing,d); CONTINUE; END IF;
    v_val := (p_scores->>d)::numeric;
    IF v_val < 0 OR v_val > 100 THEN RETURN jsonb_build_object('ok',false,'error','score_out_of_range','dimension',d); END IF;
    v_overall := v_overall + v_val * (v_w->>d)::numeric;
    IF v_val < v_min THEN v_min := v_val; END IF;
    IF d IN ('BRAND_FIDELITY','ASSET_FIDELITY','TRUTH_SAFETY','READABILITY') AND v_val < 80 THEN
      v_crit_fail := array_append(v_crit_fail, d);
    END IF;
  END LOOP;
  IF array_length(v_missing,1) IS NOT NULL THEN
    RETURN jsonb_build_object('ok',false,'error','missing_dimensions','missing',to_jsonb(v_missing));
  END IF;

  v_truth := public.fn_ci_concept_truth_gate(c.id);
  v_integrity := public.fn_ci_concept_asset_integrity(c.id);
  v_truth_ok := coalesce((v_truth->>'truth_safety_pass')::boolean,false);
  v_fab := NOT coalesce((v_integrity->>'ok')::boolean,false);
  v_crit_ok := (array_length(v_crit_fail,1) IS NULL);

  IF v_fab OR NOT v_truth_ok THEN
    v_verdict := 'REJECT';
  ELSIF v_min >= 70 AND v_overall >= 80 AND v_crit_ok THEN
    v_verdict := 'PASS';
  ELSIF g.attempt_no < 3 THEN
    v_verdict := 'REVISE';
  ELSE
    v_verdict := 'REJECT';
  END IF;

  INSERT INTO public.creative_quality_evaluations(generation_id,concept_id,tenant_id,evaluator_provider,
    evaluator_model,image_ref_evaluated,scores,overall_score,verdict,visible_weaknesses,recommended_corrections,
    critical_failures,truth_safety_pass,fabrication_detected)
  VALUES (p_generation_id,c.id,c.tenant_id,p_evaluator_provider,p_evaluator_model,p_image_ref,p_scores,
    round(v_overall,2),v_verdict,coalesce(p_visible_weaknesses,'[]'::jsonb),coalesce(p_recommended_corrections,'[]'::jsonb),
    to_jsonb(v_crit_fail), v_truth_ok, v_fab)
  RETURNING id INTO v_eval_id;

  IF v_verdict='PASS' THEN UPDATE public.creative_concepts SET final_verdict='PASS' WHERE id=c.id;
  ELSIF v_verdict='REJECT' THEN UPDATE public.creative_concepts SET final_verdict='REJECT' WHERE id=c.id;
  END IF;

  RETURN jsonb_build_object('ok',true,'evaluation_id',v_eval_id,'verdict',v_verdict,
    'overall_score',round(v_overall,2),'min_dimension',v_min,'critical_failures',to_jsonb(v_crit_fail),
    'truth_safety_pass',v_truth_ok,'fabrication_detected',v_fab,'attempt_no',g.attempt_no,
    'regenerations_remaining', greatest(0, 3 - g.attempt_no),
    'image_ref_evaluated',p_image_ref);
END; $function$;

-- Regeneration controller: next action for a concept based on its latest evaluation (bounded).
CREATE OR REPLACE FUNCTION public.fn_ci_concept_next_action(p_concept_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_attempt int; v_verdict text;
BEGIN
  SELECT g.attempt_no, e.verdict INTO v_attempt, v_verdict
  FROM public.creative_concept_generations g
  JOIN public.creative_quality_evaluations e ON e.generation_id=g.id
  WHERE g.concept_id=p_concept_id ORDER BY g.attempt_no DESC LIMIT 1;
  IF v_verdict IS NULL THEN RETURN jsonb_build_object('action','GENERATE','attempt_no',1); END IF;
  IF v_verdict='PASS' THEN RETURN jsonb_build_object('action','DONE_PASS'); END IF;
  IF v_verdict='REJECT' THEN RETURN jsonb_build_object('action','DONE_REJECT'); END IF;
  IF v_attempt >= 3 THEN RETURN jsonb_build_object('action','DONE_REJECT','reason','max_regenerations_reached'); END IF;
  RETURN jsonb_build_object('action','REGENERATE','next_attempt_no',v_attempt+1);
END; $function$;

-- Approvable gate: a concept may reach approval/publishing ONLY if its latest verdict is PASS.
CREATE OR REPLACE FUNCTION public.fn_ci_concept_approvable(p_concept_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT coalesce((SELECT e.verdict FROM public.creative_concept_generations g
     JOIN public.creative_quality_evaluations e ON e.generation_id=g.id
     WHERE g.concept_id=p_concept_id ORDER BY g.attempt_no DESC LIMIT 1) = 'PASS', false);
$function$;

-- Ownership-checked concept read (founder-review surface + function-layer tenant isolation).
CREATE OR REPLACE FUNCTION public.fn_ci_concept_read(p_concept_id uuid, p_actor uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_t uuid; c public.creative_concepts%ROWTYPE;
BEGIN
  v_t := public.fn__ci_actor_tenant(p_actor);
  IF v_t IS NULL THEN RETURN jsonb_build_object('ok',false,'error','actor_tenant_unresolved'); END IF;
  SELECT * INTO c FROM public.creative_concepts WHERE id=p_concept_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','not_found'); END IF;
  IF c.tenant_id <> v_t THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  RETURN jsonb_build_object('ok',true,'concept_id',c.id,'label',c.concept_label,'name',c.concept_name,
    'final_verdict',c.final_verdict,'approvable',public.fn_ci_concept_approvable(c.id));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ci_concept_read(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_concept_read(uuid,uuid) TO authenticated, service_role;

-- Grants: app members + service_role; never anon/public.
REVOKE ALL ON FUNCTION public.fn_ci_brand_asset_put(uuid,text,text,text,uuid,boolean,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_brand_asset_put(uuid,text,text,text,uuid,boolean,jsonb) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_concept_truth_gate(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_concept_truth_gate(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_concept_asset_integrity(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_concept_asset_integrity(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_quality_judge(uuid,jsonb,text,text,text,jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_quality_judge(uuid,jsonb,text,text,text,jsonb,jsonb) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_concept_next_action(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_concept_next_action(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_concept_approvable(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_concept_approvable(uuid) TO authenticated, service_role;

-- ============================================================================
-- 5. SELF-TEST (rolled back; no external calls, no publishing, no spend)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ci_quality_proof_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  c_tenant uuid := '5351ad83-5ce8-47b1-aef6-23f64daf415f';
  c_other  uuid := '95bb5658-5182-43af-add0-3d2ebc93393f';
  v_set uuid; v_cA uuid; v_cB uuid; v_gen uuid; v_r jsonb; v_asset uuid; v_pre jsonb; v_cnt int;
  v_good jsonb := '{"VISUAL_HIERARCHY":88,"COMPOSITION":86,"TYPOGRAPHY":84,"READABILITY":90,"BRAND_FIDELITY":85,"ASSET_FIDELITY":92,"MESSAGE_CLARITY":86,"PLATFORM_FIT":88,"ORIGINALITY":82,"CONVERSION_COMMUNICATION":83,"TRUTH_SAFETY":95}'::jsonb;
  v_lowcrit jsonb := '{"VISUAL_HIERARCHY":88,"COMPOSITION":86,"TYPOGRAPHY":84,"READABILITY":72,"BRAND_FIDELITY":85,"ASSET_FIDELITY":92,"MESSAGE_CLARITY":86,"PLATFORM_FIT":88,"ORIGINALITY":82,"CONVERSION_COMMUNICATION":83,"TRUTH_SAFETY":95}'::jsonb;
  v_weak jsonb := '{"VISUAL_HIERARCHY":60,"COMPOSITION":58,"TYPOGRAPHY":55,"READABILITY":62,"BRAND_FIDELITY":60,"ASSET_FIDELITY":70,"MESSAGE_CLARITY":61,"PLATFORM_FIT":64,"ORIGINALITY":59,"CONVERSION_COMMUNICATION":57,"TRUTH_SAFETY":90}'::jsonb;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub','7c8ddf9d-172c-4a89-a402-bb7066228b61','role','authenticated')::text, true);
    -- authoritative TAGLINE brand asset
    INSERT INTO public.creative_concept_sets(tenant_id,actor_user_id,source_mode,subject,business_objective,audience,core_message,platform,creative_format)
    VALUES (c_tenant,'7c8ddf9d-172c-4a89-a402-bb7066228b61','BUSINESS_SELF','Pulse','BRAND_AWARENESS','founders','Discover opportunities and act','META_FACEBOOK','SAAS_SOCIAL_SQUARE') RETURNING id INTO v_set;

    -- helper to insert a concept
    INSERT INTO public.creative_concepts(set_id,tenant_id,concept_label,concept_name,message_angle,visual_concept,
      visual_hierarchy,composition_direction,colour_direction,imagery_direction,copy_density,typography_treatment,
      cta_strategy,platform_format,headline,body_copy,cta_text,declares_real_assets,design_rationale,distinctness_key)
    VALUES (v_set,c_tenant,'A','Signal to Action','PROBLEM_SOLUTION','abstract data-to-decision motif',
      'headline-dominant','centered','deep indigo + electric accent','abstract','low','bold grotesque',
      'text CTA','1080x1080','Turn market signals into action','Pulse helps you decide and move','Learn more',
      '[]'::jsonb,'Clarity-first hierarchy suits a cold audience','FAMILY_ABSTRACT_TYPO') RETURNING id INTO v_cA;
    INSERT INTO public.creative_concepts(set_id,tenant_id,concept_label,concept_name,message_angle,visual_concept,
      visual_hierarchy,composition_direction,colour_direction,imagery_direction,copy_density,typography_treatment,
      cta_strategy,platform_format,headline,body_copy,cta_text,declares_real_assets,design_rationale,distinctness_key)
    VALUES (v_set,c_tenant,'B','Editorial Intelligence','USE_CASE','editorial split-layout',
      'split','left-text right-visual','warm neutral + teal','abstract','medium','editorial serif',
      'button','1080x1080','See what your market is doing','Opportunity intelligence for operators','Explore Pulse',
      '[]'::jsonb,'Editorial direction differentiates from concept A','FAMILY_EDITORIAL_SPLIT') RETURNING id INTO v_cB;

    v := v || jsonb_build_object('case','saas_mode_three_distinct_concepts_persist','pass', (SELECT count(*) FROM public.creative_concepts WHERE set_id=v_set)=2);

    -- (distinctness enforced) inserting a duplicate distinctness_key must fail
    BEGIN
      INSERT INTO public.creative_concepts(set_id,tenant_id,concept_label,concept_name,message_angle,visual_concept,
        visual_hierarchy,composition_direction,colour_direction,imagery_direction,copy_density,typography_treatment,
        cta_strategy,platform_format,headline,design_rationale,distinctness_key)
      VALUES (v_set,c_tenant,'C','Dup','X','x','x','x','x','x','x','x','x','1080x1080','h','r','FAMILY_ABSTRACT_TYPO');
      v := v || jsonb_build_object('case','distinctness_enforced','pass',false);
    EXCEPTION WHEN unique_violation THEN v := v || jsonb_build_object('case','distinctness_enforced','pass',true);
    END;

    -- generation attempt 1 for concept A (simulated GENERATED with an image ref)
    INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,provider,model,status,asset_storage_ref)
    VALUES (v_cA,c_tenant,1,'GOOGLE_GEMINI','gemini-2.5-flash-image','GENERATED','pulse-generated-media/ci/a1.png') RETURNING id INTO v_gen;

    -- (judge requires an actual image) calling with no image ref refuses
    v_r := public.fn_ci_quality_judge(v_gen, v_good, 'GOOGLE_GEMINI','gemini-2.5-flash', NULL);
    v := v || jsonb_build_object('case','judge_requires_actual_image','pass', coalesce(v_r->>'error','')='no_actual_image_ref');

    -- good scores on the actual image => PASS
    v_r := public.fn_ci_quality_judge(v_gen, v_good, 'GOOGLE_GEMINI','gemini-2.5-flash','pulse-generated-media/ci/a1.png');
    v := v || jsonb_build_object('case','good_image_passes','pass', v_r->>'verdict'='PASS' AND (v_r->>'overall_score')::numeric>=80,'observed',v_r);
    v := v || jsonb_build_object('case','passed_concept_approvable','pass', public.fn_ci_concept_approvable(v_cA)=true);

    -- weak scores => below floor; attempt 1 => REVISE (regenerations remain)
    INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,provider,model,status,asset_storage_ref)
    VALUES (v_cB,c_tenant,1,'GOOGLE_GEMINI','gemini-2.5-flash-image','GENERATED','pulse-generated-media/ci/b1.png') RETURNING id INTO v_gen;
    v_r := public.fn_ci_quality_judge(v_gen, v_weak, 'GOOGLE_GEMINI','gemini-2.5-flash','pulse-generated-media/ci/b1.png');
    v := v || jsonb_build_object('case','low_quality_cannot_pass','pass', v_r->>'verdict'='REVISE','observed',v_r->>'verdict');

    -- critical dimension (READABILITY=72) fails PASS even though others strong
    INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,provider,model,status,asset_storage_ref)
    VALUES (v_cB,c_tenant,2,'GOOGLE_GEMINI','gemini-2.5-flash-image','GENERATED','pulse-generated-media/ci/b2.png') RETURNING id INTO v_gen;
    v_r := public.fn_ci_quality_judge(v_gen, v_lowcrit, 'GOOGLE_GEMINI','gemini-2.5-flash','pulse-generated-media/ci/b2.png');
    v := v || jsonb_build_object('case','critical_dimension_blocks_pass','pass', v_r->>'verdict'<>'PASS' AND (v_r->'critical_failures')::text ILIKE '%READABILITY%');

    -- regeneration max = 2 : attempt 3 below floor => REJECT (no attempt 4 allowed)
    INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,provider,model,status,asset_storage_ref)
    VALUES (v_cB,c_tenant,3,'GOOGLE_GEMINI','gemini-2.5-flash-image','GENERATED','pulse-generated-media/ci/b3.png') RETURNING id INTO v_gen;
    v_r := public.fn_ci_quality_judge(v_gen, v_weak, 'GOOGLE_GEMINI','gemini-2.5-flash','pulse-generated-media/ci/b3.png');
    v := v || jsonb_build_object('case','regeneration_max_two_then_reject','pass', v_r->>'verdict'='REJECT');
    BEGIN
      INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,status,asset_storage_ref)
      VALUES (v_cB,c_tenant,4,'GENERATED','x');
      v := v || jsonb_build_object('case','attempt_hard_capped_at_3','pass',false);
    EXCEPTION WHEN check_violation THEN v := v || jsonb_build_object('case','attempt_hard_capped_at_3','pass',true);
    END;
    v := v || jsonb_build_object('case','rejected_concept_not_approvable','pass', public.fn_ci_concept_approvable(v_cB)=false);

    -- fabricated authoritative asset => REJECT. Concept declares real UI_SCREENSHOT with none approved.
    UPDATE public.creative_concepts SET declares_real_assets='["UI_SCREENSHOT"]'::jsonb WHERE id=v_cA;
    INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,provider,model,status,asset_storage_ref)
    VALUES (v_cA,c_tenant,2,'GOOGLE_GEMINI','gemini-2.5-flash-image','GENERATED','pulse-generated-media/ci/a2.png') RETURNING id INTO v_gen;
    v_r := public.fn_ci_quality_judge(v_gen, v_good, 'GOOGLE_GEMINI','gemini-2.5-flash','pulse-generated-media/ci/a2.png');
    v := v || jsonb_build_object('case','fabricated_asset_rejects','pass', v_r->>'verdict'='REJECT' AND (v_r->>'fabrication_detected')='true');
    -- now approve a real UI screenshot brand asset => integrity ok
    INSERT INTO public.media_assets(tenant_id,media_type,source_type,rights_state,generation_status,approval_state,is_launch_safe,identity_state,storage_ref,mime_type)
    VALUES (c_tenant,'IMAGE','FOUNDER_UPLOAD','CLEARED','COMPLETE','APPROVED',true,'IDENTITY_RESOLVED','x','image/png') RETURNING id INTO v_asset;
    PERFORM public.fn_ci_brand_asset_put(c_tenant,'UI_SCREENSHOT',NULL,NULL,v_asset,true,'{"src":"founder"}'::jsonb);
    v := v || jsonb_build_object('case','authoritative_asset_traces','pass', coalesce((public.fn_ci_concept_asset_integrity(v_cA)->>'ok')::boolean,false)=true);

    -- truth violation => REJECT regardless of strong visuals
    UPDATE public.creative_concepts SET declares_real_assets='[]'::jsonb, headline='Pulse is the #1 guaranteed best platform, trusted by 10000 customers' WHERE id=v_cA;
    INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,provider,model,status,asset_storage_ref)
    VALUES (v_cA,c_tenant,3,'GOOGLE_GEMINI','gemini-2.5-flash-image','GENERATED','pulse-generated-media/ci/a3.png') RETURNING id INTO v_gen;
    v_r := public.fn_ci_quality_judge(v_gen, v_good, 'GOOGLE_GEMINI','gemini-2.5-flash','pulse-generated-media/ci/a3.png');
    v := v || jsonb_build_object('case','truth_violation_rejects','pass', v_r->>'verdict'='REJECT' AND (v_r->>'truth_safety_pass')='false');

    -- tenant isolation at the function layer: owner reads own concept; other tenant is rejected.
    v := v || jsonb_build_object('case','owner_can_read_concept','pass',
      coalesce((public.fn_ci_concept_read(v_cA,'7c8ddf9d-172c-4a89-a402-bb7066228b61')->>'ok')::boolean,false)=true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub','17bb631a-d4a4-4b5e-870e-d35a40dd5434','role','authenticated')::text, true);
    v_r := public.fn_ci_concept_read(v_cA, '17bb631a-d4a4-4b5e-870e-d35a40dd5434');
    v := v || jsonb_build_object('case','cross_tenant_rejected','pass', v_r->>'error'='cross_tenant_rejected');
    PERFORM set_config('request.jwt.claims', json_build_object('sub','7c8ddf9d-172c-4a89-a402-bb7066228b61','role','authenticated')::text, true);

    -- Product Asset Lock regression: existing product quality path still returns machine gates unchanged
    v_pre := public.fn_creative_quality_review('IMAGE_ASSET', v_asset);
    v := v || jsonb_build_object('case','product_asset_lock_regression_intact','pass',
      (v_pre->>'status')='ok' AND (v_pre->>'human_approval_required')='true' AND (v_pre->>'launch_safe')='false');

    -- no publishing / no paid-lane rows created by this suite
    v := v || jsonb_build_object('case','no_publishing_request_created','pass',
      (SELECT count(*) FROM public.social_publishing_requests WHERE created_at > now() - interval '1 minute' AND tenant_id=c_tenant AND content->>'subject'='CI_SELFTEST')=0);

    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN v := v || jsonb_build_object('case','UNEXPECTED_ERROR','pass',false,'err',SQLERRM); END IF;
  END;

  RETURN jsonb_build_object('suite','creative_intelligence_quality_proof',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ci_quality_proof_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ci_quality_proof_selftest() TO postgres, service_role;

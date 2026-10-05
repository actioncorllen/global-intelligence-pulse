-- mig_348: Strateloq Creative Design System / Quality Engine.
--
-- EXTENDS (never replaces) the Creative Intelligence slice from mig_346 and the Website Asset
-- Capture / Brand Asset Lock from mig_347. Adds the durable layer the Creative Director needs to
-- consistently art-direct PREMIUM social creatives:
--   1. Creative Design System  -> creative_design_families (5 families, principles, not fixed templates)
--   2. Brand DNA               -> creative_brand_dna (structured, versioned, per-tenant)
--   3. Message -> design routing-> fn_ci_route_design_family (deterministic, never random)
--   4. Quality Engine          -> fn_ci_design_family_gate / fn_ci_platform_fit_gate /
--                                 fn_ci_design_quality_evaluate (layers deterministic design-system
--                                 gates ON TOP of the EXISTING fn_ci_quality_judge visual scoring)
--   5. Reference calibration    -> design-family reference_calibration (principles, not copies)
--   6. Variation                -> design_family on concepts + existing distinctness_key
--   7. Platform adaptation      -> creative_platform_contracts (LinkedIn/Facebook/Instagram/TikTok)
--   8. Product Asset Lock       -> REUSED unchanged (fn_media_product_identity_preserved)
--   9. Approval gate            -> creative_concepts.review_state + fn_ci_candidate_set_approval
--  10. Learning loop            -> creative_learning_records (metadata only; no autonomous spend)
--
-- Reuses (unchanged): creative_brand_assets, creative_concept_sets/concepts/generations,
-- creative_quality_evaluations, fn_ci_quality_judge, fn_ci_concept_truth_gate,
-- fn_ci_concept_asset_integrity, fn_ci_concept_approvable, fn_ci_concept_read,
-- fn_media_product_identity_preserved, fn_creative_quality_review, media_assets, fn__own_tenant().
--
-- NON-GOALS (explicitly NOT done here): no publishing, no scheduling, no campaign launch, no ad
-- creation/changes, no spend, no auto-approval. A quality PASS only makes a candidate ELIGIBLE for
-- founder review; founder approval remains mandatory. PENDING assets never become authoritative.

-- ============================================================================
-- 1. CREATIVE DESIGN SYSTEM — design families (principles, not fixed templates)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.creative_design_families (
  family_key                    text PRIMARY KEY,
  display_label                 text NOT NULL,
  description                   text NOT NULL,
  design_principles             jsonb NOT NULL DEFAULT '{}'::jsonb,
  requires_authoritative_assets jsonb NOT NULL DEFAULT '[]'::jsonb,  -- asset_classes that MUST be APPROVED authoritative
  reference_calibration         jsonb NOT NULL DEFAULT '{}'::jsonb,  -- quality-reference PRINCIPLES (not compositions to copy)
  default_platforms             jsonb NOT NULL DEFAULT '[]'::jsonb,
  enabled                       boolean NOT NULL DEFAULT true,
  sort_order                    int NOT NULL DEFAULT 100
);
COMMENT ON TABLE public.creative_design_families IS
  'Creative Design System: art-direction families the Creative Director composes within (principles, not fixed templates). mig_348.';

INSERT INTO public.creative_design_families
 (family_key, display_label, description, design_principles, requires_authoritative_assets, reference_calibration, default_platforms, sort_order)
VALUES
 ('BOLD_SIGNAL','Bold Signal','High-impact market-signal/opportunity creative.',
  jsonb_build_object('background','dark premium','typography','large high-impact','accent','restrained cyan/teal',
    'data_viz','minimal signal visualization','hierarchy','strong','cta','clear','whitespace','substantial negative space'),
  '[]'::jsonb,
  jsonb_build_object('reference','premium dark/cyan "Turn market signals into action" direction',
    'principles', jsonb_build_array('strong hierarchy','minimal clutter','intentional typography','generous whitespace','restrained palette','professional finish')),
  '["LINKEDIN","META_FACEBOOK","META_INSTAGRAM","TIKTOK"]'::jsonb, 10),
 ('EDITORIAL_INTELLIGENCE','Editorial Intelligence','Educational / market-intelligence editorial creative.',
  jsonb_build_object('background','warm/off-white editorial','typography','sophisticated headline','accent','restrained dark teal graphics',
    'data_viz','fine-line intelligence/data illustration','hierarchy','editorial','cta','understated','whitespace','generous'),
  '[]'::jsonb,
  jsonb_build_object('reference','premium cream/editorial "Market Intelligence" direction',
    'principles', jsonb_build_array('premium consultancy/editorial feel','generous whitespace','fine-line illustration','restrained palette','intentional typography')),
  '["LINKEDIN","META_FACEBOOK","META_INSTAGRAM"]'::jsonb, 20),
 ('PRODUCT_UI_STORY','Product UI Story','Showcase Strateloq capability using APPROVED authoritative UI screenshots.',
  jsonb_build_object('asset','APPROVED authoritative UI_SCREENSHOT','integrity','preserve screenshot integrity (no fabricated UI)',
    'framing','professionally frame/crop/place the UI','support','supporting headline + CTA','rule','never fabricate UI functionality'),
  '["UI_SCREENSHOT"]'::jsonb,
  jsonb_build_object('reference','product-truth composition','principles', jsonb_build_array('screenshot fidelity','clean framing','clear supporting message')),
  '["LINKEDIN","META_FACEBOOK","META_INSTAGRAM"]'::jsonb, 30),
 ('INSIGHT_CARD','Insight Card','One evidence-backed market insight, one dominant message.',
  jsonb_build_object('message','one dominant message','evidence','one evidence-backed insight','data_viz','supporting visualization',
    'sourcing','source/evidence treatment where appropriate','rule','avoid dashboard clutter'),
  '[]'::jsonb,
  jsonb_build_object('reference','single-insight clarity','principles', jsonb_build_array('one message','evidence-grounded','minimal clutter','clear hierarchy')),
  '["LINKEDIN","META_FACEBOOK","META_INSTAGRAM","TIKTOK"]'::jsonb, 40),
 ('THOUGHT_LEADERSHIP','Thought Leadership','Premium business/editorial, insight-led (LinkedIn-optimized).',
  jsonb_build_object('composition','premium business/editorial','platform_bias','optimized for LinkedIn','tone','insight-led not sales-heavy','branding','restrained'),
  '[]'::jsonb,
  jsonb_build_object('reference','editorial thought-leadership','principles', jsonb_build_array('insight-led','restrained branding','premium finish','generous whitespace')),
  '["LINKEDIN"]'::jsonb, 50)
ON CONFLICT (family_key) DO UPDATE SET
  display_label=excluded.display_label, description=excluded.description,
  design_principles=excluded.design_principles, requires_authoritative_assets=excluded.requires_authoritative_assets,
  reference_calibration=excluded.reference_calibration, default_platforms=excluded.default_platforms,
  enabled=true, sort_order=excluded.sort_order;

-- ============================================================================
-- 2. PLATFORM ADAPTATION — per-platform output contracts
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.creative_platform_contracts (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  platform_key         text NOT NULL,   -- LINKEDIN | META_FACEBOOK | META_INSTAGRAM | TIKTOK
  surface              text NOT NULL,   -- FEED | STORY | REELS
  aspect_ratio         text NOT NULL,   -- '1:1' | '4:5' | '9:16' | '1.91:1'
  width                int  NOT NULL,
  height               int  NOT NULL,
  safe_zone            jsonb NOT NULL,  -- margins in px/%, platform UI exclusions
  max_text_density     text NOT NULL CHECK (max_text_density IN ('LOW','MEDIUM','HIGH')),
  hierarchy_rules      jsonb NOT NULL DEFAULT '{}'::jsonb,
  cta_treatment        jsonb NOT NULL DEFAULT '{}'::jsonb,
  recompose_from_master boolean NOT NULL DEFAULT true,  -- re-compose, do not just resize, when aspect differs
  enabled              boolean NOT NULL DEFAULT true,
  UNIQUE (platform_key, surface, aspect_ratio)
);
COMMENT ON TABLE public.creative_platform_contracts IS
  'Platform-specific output contracts (aspect, safe zones, text density, hierarchy, CTA). Re-compose when aspect changes. mig_348.';

INSERT INTO public.creative_platform_contracts
 (platform_key, surface, aspect_ratio, width, height, safe_zone, max_text_density, hierarchy_rules, cta_treatment, recompose_from_master)
VALUES
 ('LINKEDIN','FEED','1:1',1080,1080,'{"margin_pct":8}','MEDIUM','{"headline":"dominant","supporting":"single line"}','{"style":"understated","prominence":"medium"}',true),
 ('LINKEDIN','FEED','4:5',1080,1350,'{"margin_pct":8}','MEDIUM','{"headline":"dominant"}','{"style":"understated","prominence":"medium"}',true),
 ('META_FACEBOOK','FEED','1:1',1080,1080,'{"margin_pct":10}','MEDIUM','{"headline":"dominant"}','{"style":"explicit","prominence":"high"}',true),
 ('META_FACEBOOK','FEED','4:5',1080,1350,'{"margin_pct":10}','MEDIUM','{"headline":"dominant"}','{"style":"explicit","prominence":"high"}',true),
 ('META_INSTAGRAM','FEED','1:1',1080,1080,'{"margin_pct":10}','LOW','{"headline":"dominant","visual":"lead"}','{"style":"explicit","prominence":"medium"}',true),
 ('META_INSTAGRAM','FEED','4:5',1080,1350,'{"margin_pct":10}','LOW','{"headline":"dominant","visual":"lead"}','{"style":"explicit","prominence":"medium"}',true),
 ('META_INSTAGRAM','STORY','9:16',1080,1920,'{"top_px":250,"bottom_px":250,"margin_pct":6}','LOW','{"headline":"dominant"}','{"style":"tap","prominence":"high"}',true),
 ('TIKTOK','FEED','9:16',1080,1920,'{"top_px":130,"bottom_px":480,"right_px":120,"margin_pct":5}','LOW','{"headline":"dominant","motion_safe":true}','{"style":"strong","prominence":"high"}',true)
ON CONFLICT (platform_key, surface, aspect_ratio) DO UPDATE SET
  width=excluded.width, height=excluded.height, safe_zone=excluded.safe_zone,
  max_text_density=excluded.max_text_density, hierarchy_rules=excluded.hierarchy_rules,
  cta_treatment=excluded.cta_treatment, recompose_from_master=excluded.recompose_from_master, enabled=true;

-- ============================================================================
-- 3. BRAND DNA — structured, versioned, per-tenant
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.creative_brand_dna (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL,
  version               int  NOT NULL,
  colors                jsonb NOT NULL DEFAULT '{}'::jsonb,
  typography            jsonb NOT NULL DEFAULT '{}'::jsonb,
  logo_treatment        jsonb NOT NULL DEFAULT '{}'::jsonb,
  spacing               jsonb NOT NULL DEFAULT '{}'::jsonb,
  cta_treatment         jsonb NOT NULL DEFAULT '{}'::jsonb,
  visual_tone           jsonb NOT NULL DEFAULT '{}'::jsonb,
  imagery_rules         jsonb NOT NULL DEFAULT '{}'::jsonb,
  dataviz_language      jsonb NOT NULL DEFAULT '{}'::jsonb,
  prohibited_treatments jsonb NOT NULL DEFAULT '[]'::jsonb,
  platform_safe_zones   jsonb NOT NULL DEFAULT '{}'::jsonb,
  approved_asset_classes jsonb NOT NULL DEFAULT '[]'::jsonb,  -- classes whose AUTHORITATIVE assets may be used
  is_active             boolean NOT NULL DEFAULT true,
  provenance            jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, version)
);
CREATE UNIQUE INDEX IF NOT EXISTS creative_brand_dna_one_active
  ON public.creative_brand_dna(tenant_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS creative_brand_dna_tenant_idx ON public.creative_brand_dna(tenant_id);
ALTER TABLE public.creative_brand_dna ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cbd_sel ON public.creative_brand_dna;
CREATE POLICY cbd_sel ON public.creative_brand_dna FOR SELECT TO authenticated USING (tenant_id = public.fn__own_tenant());

-- ============================================================================
-- 4. LEARNING LOOP — structured metadata (no autonomous spend/optimization)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.creative_learning_records (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL,
  concept_id          uuid REFERENCES public.creative_concepts(id) ON DELETE SET NULL,
  design_family       text,
  message_angle       text,
  platform            text,
  audience            text,
  campaign_ref        text,
  approval_result     text,
  performance_metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
  provenance          jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS creative_learning_records_tenant_idx ON public.creative_learning_records(tenant_id);
ALTER TABLE public.creative_learning_records ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS clr_sel ON public.creative_learning_records;
CREATE POLICY clr_sel ON public.creative_learning_records FOR SELECT TO authenticated USING (tenant_id = public.fn__own_tenant());

-- ============================================================================
-- 5. CONCEPT EXTENSIONS — design family, platform target, review lifecycle
-- ============================================================================
ALTER TABLE public.creative_concepts
  ADD COLUMN IF NOT EXISTS design_family    text REFERENCES public.creative_design_families(family_key),
  ADD COLUMN IF NOT EXISTS platform_target  text,
  ADD COLUMN IF NOT EXISTS review_state     text NOT NULL DEFAULT 'GENERATED'
     CHECK (review_state IN ('GENERATED','QUALITY_CHECKED','PENDING_FOUNDER_REVIEW','APPROVED','REJECTED')),
  ADD COLUMN IF NOT EXISTS founder_decision text,
  ADD COLUMN IF NOT EXISTS founder_decided_at timestamptz;

-- ============================================================================
-- 6. BRAND DNA writer / resolver
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ci_brand_dna_put(p_tenant uuid, p_dna jsonb, p_provenance jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_ver int; v_id uuid;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','tenant_required'); END IF;
  SELECT coalesce(max(version),0)+1 INTO v_ver FROM public.creative_brand_dna WHERE tenant_id=p_tenant;
  UPDATE public.creative_brand_dna SET is_active=false WHERE tenant_id=p_tenant AND is_active;
  INSERT INTO public.creative_brand_dna(tenant_id,version,colors,typography,logo_treatment,spacing,cta_treatment,
     visual_tone,imagery_rules,dataviz_language,prohibited_treatments,platform_safe_zones,approved_asset_classes,
     is_active,provenance)
  VALUES (p_tenant,v_ver,
     coalesce(p_dna->'colors','{}'::jsonb), coalesce(p_dna->'typography','{}'::jsonb),
     coalesce(p_dna->'logo_treatment','{}'::jsonb), coalesce(p_dna->'spacing','{}'::jsonb),
     coalesce(p_dna->'cta_treatment','{}'::jsonb), coalesce(p_dna->'visual_tone','{}'::jsonb),
     coalesce(p_dna->'imagery_rules','{}'::jsonb), coalesce(p_dna->'dataviz_language','{}'::jsonb),
     coalesce(p_dna->'prohibited_treatments','[]'::jsonb), coalesce(p_dna->'platform_safe_zones','{}'::jsonb),
     coalesce(p_dna->'approved_asset_classes','[]'::jsonb), true, coalesce(p_provenance,'{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok',true,'brand_dna_id',v_id,'version',v_ver);
END; $function$;

-- Resolve the ACTIVE brand DNA + the LIVE set of APPROVED authoritative assets (never PENDING).
CREATE OR REPLACE FUNCTION public.fn_ci_brand_dna_resolve(p_tenant uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE d public.creative_brand_dna%ROWTYPE; v_assets jsonb;
BEGIN
  SELECT * INTO d FROM public.creative_brand_dna WHERE tenant_id=p_tenant AND is_active LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','no_active_brand_dna'); END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('brand_asset_id',id,'asset_class',asset_class)),'[]'::jsonb)
    INTO v_assets FROM public.creative_brand_assets
    WHERE tenant_id=p_tenant AND authoritative=true AND approval_state='APPROVED';
  RETURN jsonb_build_object('ok',true,'version',d.version,'colors',d.colors,'typography',d.typography,
    'logo_treatment',d.logo_treatment,'spacing',d.spacing,'cta_treatment',d.cta_treatment,'visual_tone',d.visual_tone,
    'imagery_rules',d.imagery_rules,'dataviz_language',d.dataviz_language,'prohibited_treatments',d.prohibited_treatments,
    'platform_safe_zones',d.platform_safe_zones,'approved_authoritative_assets',v_assets,
    'note','Only APPROVED authoritative assets are returned; PENDING assets are never resolved as usable.');
END; $function$;

-- ============================================================================
-- 7. MESSAGE -> DESIGN ROUTING (deterministic; never random)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ci_route_design_family(
  p_objective text, p_audience text, p_platform text,
  p_intelligence_type text DEFAULT NULL, p_message_intent text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  o text := lower(coalesce(p_objective,'')); p text := upper(coalesce(p_platform,''));
  it text := upper(coalesce(p_intelligence_type,'')); mi text := lower(coalesce(p_message_intent,''));
  fam text; why text; req jsonb;
BEGIN
  IF it IN ('CAPABILITY','PRODUCT_UI','PRODUCT','UI') OR mi ~ 'screenshot|product ui|show (the )?(product|strateloq|platform|app)|demo|walkthrough' THEN
    fam := 'PRODUCT_UI_STORY'; why := 'Capability / product-UI intent -> frame APPROVED authoritative UI screenshots.';
  ELSIF it IN ('EDUCATIONAL','MARKET_INTELLIGENCE','HOW_TO','EXPLAINER') OR o ~ 'educat|explain|teach|how[- ]?to|guide' THEN
    fam := 'EDITORIAL_INTELLIGENCE'; why := 'Educational market intelligence -> editorial, generous whitespace, fine-line data.';
  ELSIF it IN ('FOUNDER_INSIGHT','INDUSTRY_INSIGHT','OPINION','POV','THOUGHT_LEADERSHIP')
        OR (p = 'LINKEDIN' AND (o ~ 'thought|insight|leadership|point of view|pov' OR mi ~ 'insight|opinion|founder')) THEN
    fam := 'THOUGHT_LEADERSHIP'; why := 'Founder / industry insight (esp. LinkedIn) -> insight-led, restrained branding.';
  ELSIF it IN ('EVIDENCE','INSIGHT','STAT','DATA_POINT') OR mi ~ 'one (stat|number|data|insight)|evidence|single insight' THEN
    fam := 'INSIGHT_CARD'; why := 'One evidence-backed insight -> single dominant message + supporting visualization.';
  ELSIF it IN ('MARKET_SIGNAL','OPPORTUNITY','SIGNAL') OR o ~ 'signal|opportunity|awareness|launch|convert|attention' THEN
    fam := 'BOLD_SIGNAL'; why := 'Market signal / opportunity / awareness -> dark premium, high-impact type, restrained cyan.';
  ELSE
    fam := 'BOLD_SIGNAL'; why := 'Default high-impact brand family (no stronger routing signal detected).';
  END IF;
  SELECT requires_authoritative_assets INTO req FROM public.creative_design_families WHERE family_key=fam AND enabled;
  RETURN jsonb_build_object('ok',true,'design_family',fam,'rationale',why,
    'required_authoritative_assets',coalesce(req,'[]'::jsonb),
    'inputs',jsonb_build_object('objective',p_objective,'audience',p_audience,'platform',p_platform,
      'intelligence_type',p_intelligence_type,'message_intent',p_message_intent));
END; $function$;

-- ============================================================================
-- 8. DESIGN-SYSTEM QUALITY GATES (deterministic; layered on fn_ci_quality_judge)
-- ============================================================================
-- Design-family gate: every asset class the family REQUIRES as authoritative must have an APPROVED
-- authoritative brand asset for the tenant. PENDING assets never satisfy this.
CREATE OR REPLACE FUNCTION public.fn_ci_design_family_gate(p_concept_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE c public.creative_concepts%ROWTYPE; v_req jsonb; v_cls text; v_missing text[] := ARRAY[]::text[];
BEGIN
  SELECT * INTO c FROM public.creative_concepts WHERE id=p_concept_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','concept_not_found'); END IF;
  IF c.design_family IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','no_design_family','note','Creative Director must assign a design family.');
  END IF;
  SELECT requires_authoritative_assets INTO v_req FROM public.creative_design_families WHERE family_key=c.design_family AND enabled;
  IF v_req IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unknown_or_disabled_family','family',c.design_family); END IF;
  FOR v_cls IN SELECT jsonb_array_elements_text(v_req) LOOP
    IF NOT EXISTS (SELECT 1 FROM public.creative_brand_assets b
                   WHERE b.tenant_id=c.tenant_id AND b.asset_class=v_cls
                     AND b.authoritative=true AND b.approval_state='APPROVED') THEN
      v_missing := array_append(v_missing, v_cls);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', array_length(v_missing,1) IS NULL, 'family', c.design_family,
    'required_authoritative_assets', v_req, 'missing_authoritative', to_jsonb(v_missing),
    'note','A required authoritative asset that is not APPROVED (e.g. still PENDING) fails this gate.');
END; $function$;

-- Platform-fit gate: the concept's platform_target must map to an enabled contract; flags recompose
-- when the produced format does not match a platform contract dimension (resize alone is not allowed).
CREATE OR REPLACE FUNCTION public.fn_ci_platform_fit_gate(p_concept_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE c public.creative_concepts%ROWTYPE; v_cnt int; v_match int; v_fmt text;
BEGIN
  SELECT * INTO c FROM public.creative_concepts WHERE id=p_concept_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','concept_not_found'); END IF;
  IF coalesce(c.platform_target,'')='' THEN RETURN jsonb_build_object('ok',false,'error','no_platform_target'); END IF;
  SELECT count(*) INTO v_cnt FROM public.creative_platform_contracts WHERE platform_key=upper(c.platform_target) AND enabled;
  IF v_cnt = 0 THEN
    RETURN jsonb_build_object('ok',false,'error','unsupported_platform','platform',c.platform_target);
  END IF;
  v_fmt := replace(lower(coalesce(c.platform_format,'')),' ','');
  SELECT count(*) INTO v_match FROM public.creative_platform_contracts
   WHERE platform_key=upper(c.platform_target) AND enabled
     AND (v_fmt = width||'x'||height OR v_fmt = aspect_ratio);
  RETURN jsonb_build_object('ok',true,'platform',upper(c.platform_target),'contracts',v_cnt,
    'format',c.platform_format,'matches_contract_dimension',(v_match>0),
    'recompose_required',(v_match=0),
    'note','recompose_required=true means re-compose for this platform, never merely resize the master.');
END; $function$;

-- Product identity preservation for CUSTOMER_PRODUCT concepts: the generation's media asset must
-- pass the existing Product Asset Lock identity gate (fn_media_product_identity_preserved).
CREATE OR REPLACE FUNCTION public.fn_ci_product_identity_gate(p_generation_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE g public.creative_concept_generations%ROWTYPE; s public.creative_concept_sets%ROWTYPE; v jsonb;
BEGIN
  SELECT * INTO g FROM public.creative_concept_generations WHERE id=p_generation_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','generation_not_found'); END IF;
  SELECT cs.* INTO s FROM public.creative_concept_sets cs
    JOIN public.creative_concepts c ON c.set_id=cs.id WHERE c.id=g.concept_id;
  IF s.source_mode <> 'CUSTOMER_PRODUCT' THEN
    RETURN jsonb_build_object('ok',true,'applicable',false,'note','Not a CUSTOMER_PRODUCT creative; Product Asset Lock identity gate not applicable.');
  END IF;
  IF g.media_asset_id IS NULL THEN RETURN jsonb_build_object('ok',false,'applicable',true,'error','no_media_asset'); END IF;
  v := public.fn_media_product_identity_preserved(g.media_asset_id);
  RETURN jsonb_build_object('ok',(v->>'state')='PASS','applicable',true,'identity',v);
END; $function$;

-- Combined Quality Engine: deterministic design-system gates + EXISTING visual judge. Advances the
-- candidate review lifecycle. NEVER auto-approves: a PASS only reaches PENDING_FOUNDER_REVIEW.
CREATE OR REPLACE FUNCTION public.fn_ci_design_quality_evaluate(
  p_generation_id uuid, p_scores jsonb, p_evaluator_provider text, p_evaluator_model text, p_image_ref text,
  p_visible_weaknesses jsonb DEFAULT '[]'::jsonb, p_recommended_corrections jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  g public.creative_concept_generations%ROWTYPE; c public.creative_concepts%ROWTYPE;
  v_judge jsonb; v_fam jsonb; v_plat jsonb; v_prod jsonb;
  v_det_ok boolean; v_verdict text; v_review text;
BEGIN
  SELECT * INTO g FROM public.creative_concept_generations WHERE id=p_generation_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','generation_not_found'); END IF;
  SELECT * INTO c FROM public.creative_concepts WHERE id=g.concept_id;

  v_fam  := public.fn_ci_design_family_gate(c.id);
  v_plat := public.fn_ci_platform_fit_gate(c.id);
  v_prod := public.fn_ci_product_identity_gate(p_generation_id);
  v_det_ok := coalesce((v_fam->>'ok')::boolean,false)
          AND coalesce((v_plat->>'ok')::boolean,false)
          AND coalesce((v_prod->>'ok')::boolean,false);

  -- EXISTING visual judge (truth gate + asset integrity + 11-dim thresholds) does the scoring.
  v_judge := public.fn_ci_quality_judge(p_generation_id, p_scores, p_evaluator_provider, p_evaluator_model,
               p_image_ref, p_visible_weaknesses, p_recommended_corrections);
  IF NOT coalesce((v_judge->>'ok')::boolean,false) THEN
    RETURN jsonb_build_object('ok',false,'stage','visual_judge','judge',v_judge,
      'design_family_gate',v_fam,'platform_fit_gate',v_plat,'product_identity_gate',v_prod);
  END IF;

  -- Deterministic design-system gates can only DOWNGRADE the visual verdict, never upgrade it.
  v_verdict := v_judge->>'verdict';
  IF NOT v_det_ok AND v_verdict = 'PASS' THEN
    v_verdict := CASE WHEN g.attempt_no < 3 THEN 'REVISE' ELSE 'REJECT' END;
  END IF;

  v_review := CASE v_verdict WHEN 'PASS' THEN 'PENDING_FOUNDER_REVIEW'
                             WHEN 'REVISE' THEN 'QUALITY_CHECKED'
                             ELSE 'REJECTED' END;
  UPDATE public.creative_concepts
     SET review_state = v_review,
         final_verdict = CASE WHEN v_verdict IN ('PASS','REJECT') THEN v_verdict ELSE final_verdict END
   WHERE id = c.id;

  RETURN jsonb_build_object('ok',true,'verdict',v_verdict,'review_state',v_review,
    'deterministic_gates_pass',v_det_ok,'visual_verdict',v_judge->>'verdict',
    'overall_score',v_judge->>'overall_score',
    'design_family_gate',v_fam,'platform_fit_gate',v_plat,'product_identity_gate',v_prod,
    'note','Deterministic design-system gates can only downgrade; a PASS reaches founder review only (no auto-approval).');
END; $function$;

-- ============================================================================
-- 9. APPROVAL GATE — founder decision (no quality score bypasses founder)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ci_candidate_set_approval(p_tenant uuid, p_concept_id uuid, p_decision text)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE c public.creative_concepts%ROWTYPE; s public.creative_concept_sets%ROWTYPE; v_state text;
BEGIN
  IF p_decision NOT IN ('APPROVE','REJECT') THEN RETURN jsonb_build_object('ok',false,'error','bad_decision'); END IF;
  SELECT * INTO c FROM public.creative_concepts WHERE id=p_concept_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','concept_not_found'); END IF;
  IF c.tenant_id <> p_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  IF p_decision='APPROVE' AND NOT public.fn_ci_concept_approvable(p_concept_id) THEN
    RETURN jsonb_build_object('ok',false,'error','not_quality_passed',
      'note','Only a candidate whose latest Quality Engine verdict is PASS can be founder-approved.');
  END IF;
  v_state := CASE WHEN p_decision='APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END;
  UPDATE public.creative_concepts
     SET review_state=v_state, founder_decision=p_decision, founder_decided_at=now()
   WHERE id=p_concept_id;
  SELECT * INTO s FROM public.creative_concept_sets WHERE id=c.set_id;
  INSERT INTO public.creative_learning_records(tenant_id,concept_id,design_family,message_angle,platform,audience,approval_result,provenance)
  VALUES (p_tenant,p_concept_id,c.design_family,c.message_angle,coalesce(c.platform_target,s.platform),s.audience,v_state,
          jsonb_build_object('source','fn_ci_candidate_set_approval'));
  RETURN jsonb_build_object('ok',true,'concept_id',p_concept_id,'review_state',v_state,'decision',p_decision);
END; $function$;

-- Record later performance metrics against a concept's learning record (no autonomous optimization).
CREATE OR REPLACE FUNCTION public.fn_ci_learning_record_performance(p_tenant uuid, p_concept_id uuid, p_metrics jsonb)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.creative_learning_records
   WHERE tenant_id=p_tenant AND concept_id=p_concept_id ORDER BY created_at DESC LIMIT 1;
  IF v_id IS NULL THEN RETURN jsonb_build_object('ok',false,'error','no_learning_record'); END IF;
  UPDATE public.creative_learning_records SET performance_metrics = coalesce(p_metrics,'{}'::jsonb) WHERE id=v_id;
  RETURN jsonb_build_object('ok',true,'learning_record_id',v_id);
END; $function$;

-- ============================================================================
-- 10. GRANTS (app members + service_role; never anon/public). Founder writes = service_role.
-- ============================================================================
REVOKE ALL ON FUNCTION public.fn_ci_brand_dna_put(uuid,jsonb,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ci_brand_dna_put(uuid,jsonb,jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.fn_ci_brand_dna_resolve(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_brand_dna_resolve(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_route_design_family(text,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_route_design_family(text,text,text,text,text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_design_family_gate(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_design_family_gate(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_platform_fit_gate(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_platform_fit_gate(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_product_identity_gate(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_product_identity_gate(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_design_quality_evaluate(uuid,jsonb,text,text,text,jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ci_design_quality_evaluate(uuid,jsonb,text,text,text,jsonb,jsonb) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ci_candidate_set_approval(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ci_candidate_set_approval(uuid,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION public.fn_ci_learning_record_performance(uuid,uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ci_learning_record_performance(uuid,uuid,jsonb) TO service_role;

-- ============================================================================
-- 11. SEED an initial ACTIVE Strateloq Brand DNA (reference-direction; founder may refine)
-- ============================================================================
DO $seed$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.creative_brand_dna WHERE tenant_id='5351ad83-5ce8-47b1-aef6-23f64daf415f' AND is_active) THEN
    PERFORM public.fn_ci_brand_dna_put('5351ad83-5ce8-47b1-aef6-23f64daf415f',
      jsonb_build_object(
        'colors', jsonb_build_object('background_dark','#0B1020','ink','#0A0F1E','canvas_cream','#F7F4EC',
           'accent_cyan','#22D3EE','accent_teal','#0E7490','neutral','#6B7280','usage','restrained; one accent at a time'),
        'typography', jsonb_build_object('headline','bold grotesque sans','editorial_alt','sophisticated serif',
           'body','clean grotesque','rules','large high-impact headlines; generous leading; mobile min 28pt'),
        'logo_treatment', jsonb_build_object('style','restrained','placement','corner','clearspace','>= cap height','never','stretch/recolor/add effects'),
        'spacing', jsonb_build_object('safe_margin_pct',10,'whitespace','substantial negative space','grid','8pt'),
        'cta_treatment', jsonb_build_object('bold','explicit button','editorial','understated text','rule','one clear CTA'),
        'visual_tone', jsonb_build_object('mood','premium, intelligent, confident','avoid','clutter, hype, stock cliche'),
        'imagery_rules', jsonb_build_object('allow','abstract signal/landscape; authoritative UI screenshots','forbid','fabricated UI, fake metrics, fake logos, fake people/testimonials'),
        'dataviz_language', jsonb_build_object('style','fine-line, minimal, intentional','forbid','dashboard clutter, fabricated numbers'),
        'prohibited_treatments', jsonb_build_array('fabricated UI/metrics/logos','unsupported claims','low-contrast text','edge-to-edge clutter','more than one accent colour'),
        'platform_safe_zones', jsonb_build_object('TIKTOK', jsonb_build_object('top_px',130,'bottom_px',480,'right_px',120),
           'META_INSTAGRAM_STORY', jsonb_build_object('top_px',250,'bottom_px',250)),
        'approved_asset_classes', jsonb_build_array('LOGO','UI_SCREENSHOT','BRAND_IMAGE','TAGLINE','BRAND_COLOUR_REFERENCE')
      ),
      jsonb_build_object('source','mig_348 seed','basis','founder-approved reference direction + observed public site','status','seed_awaiting_founder_confirmation'));
  END IF;
END $seed$;

-- ============================================================================
-- 12. SELF-TEST (rolled back; no external calls, no publishing, no spend)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_ci_design_system_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  c_tenant uuid := '5351ad83-5ce8-47b1-aef6-23f64daf415f';
  c_other  uuid := '95bb5658-5182-43af-add0-3d2ebc93393f';
  v_set uuid; v_cUI uuid; v_cSig uuid; v_gen uuid; v_r jsonb; v_asset uuid; v_media uuid; v_media2 uuid; v_media3 uuid; v_media4 uuid;
  v_good jsonb := '{"VISUAL_HIERARCHY":88,"COMPOSITION":86,"TYPOGRAPHY":84,"READABILITY":90,"BRAND_FIDELITY":85,"ASSET_FIDELITY":92,"MESSAGE_CLARITY":86,"PLATFORM_FIT":88,"ORIGINALITY":82,"CONVERSION_COMMUNICATION":83,"TRUTH_SAFETY":95}'::jsonb;
  v_weak jsonb := '{"VISUAL_HIERARCHY":60,"COMPOSITION":58,"TYPOGRAPHY":55,"READABILITY":62,"BRAND_FIDELITY":60,"ASSET_FIDELITY":70,"MESSAGE_CLARITY":61,"PLATFORM_FIT":64,"ORIGINALITY":59,"CONVERSION_COMMUNICATION":57,"TRUTH_SAFETY":90}'::jsonb;
BEGIN
  BEGIN
    -- (0) Regression FIRST — before this suite writes anything that could pollute shared tables
    --     (mig_346's suite picks a tenant media asset via LIMIT 1; our later inserts must not bias it).
    v := v || jsonb_build_object('case','ci_quality_proof_regression_intact','pass',
      (public.fn_ci_quality_proof_selftest()->>'all_pass')='true');
    -- (1) design families + platform contracts seeded
    v := v || jsonb_build_object('case','five_design_families_enabled','pass',
      (SELECT count(*) FROM public.creative_design_families WHERE enabled
        AND family_key IN ('BOLD_SIGNAL','EDITORIAL_INTELLIGENCE','PRODUCT_UI_STORY','INSIGHT_CARD','THOUGHT_LEADERSHIP'))=5);
    v := v || jsonb_build_object('case','platform_contracts_cover_four_platforms','pass',
      (SELECT count(DISTINCT platform_key) FROM public.creative_platform_contracts WHERE enabled
        AND platform_key IN ('LINKEDIN','META_FACEBOOK','META_INSTAGRAM','TIKTOK'))=4);

    -- (2) brand DNA active + provenance; resolve returns only APPROVED authoritative assets
    v := v || jsonb_build_object('case','brand_dna_active_present','pass',
      EXISTS(SELECT 1 FROM public.creative_brand_dna WHERE tenant_id=c_tenant AND is_active));
    v_r := public.fn_ci_brand_dna_resolve(c_tenant);
    v := v || jsonb_build_object('case','brand_dna_resolves_without_pending','pass',
      (v_r->>'ok')='true' AND (v_r->'approved_authoritative_assets') IS NOT NULL);
    v := v || jsonb_build_object('case','brand_dna_provenance_no_secrets','pass',
      NOT EXISTS(SELECT 1 FROM public.creative_brand_dna WHERE tenant_id=c_tenant
        AND (provenance::text ~* 'password|secret|token|bearer|authorization')));

    -- (3) deterministic routing
    v := v || jsonb_build_object('case','route_market_signal_bold','pass',
      public.fn_ci_route_design_family('brand awareness','founders','META_FACEBOOK','MARKET_SIGNAL',NULL)->>'design_family'='BOLD_SIGNAL');
    v := v || jsonb_build_object('case','route_educational_editorial','pass',
      public.fn_ci_route_design_family('educate the market','operators','LINKEDIN','EDUCATIONAL',NULL)->>'design_family'='EDITORIAL_INTELLIGENCE');
    v := v || jsonb_build_object('case','route_capability_product_ui','pass',
      public.fn_ci_route_design_family('show capability','buyers','LINKEDIN','CAPABILITY',NULL)->>'design_family'='PRODUCT_UI_STORY');
    v := v || jsonb_build_object('case','route_founder_insight_thought_leadership','pass',
      public.fn_ci_route_design_family('share POV','peers','LINKEDIN','FOUNDER_INSIGHT',NULL)->>'design_family'='THOUGHT_LEADERSHIP');
    v := v || jsonb_build_object('case','route_evidence_insight_card','pass',
      public.fn_ci_route_design_family('share a data point','founders','META_INSTAGRAM','EVIDENCE',NULL)->>'design_family'='INSIGHT_CARD');
    v := v || jsonb_build_object('case','routing_deterministic','pass',
      public.fn_ci_route_design_family('x','y','LINKEDIN','FOUNDER_INSIGHT',NULL)->>'design_family'
      = public.fn_ci_route_design_family('x','y','LINKEDIN','FOUNDER_INSIGHT',NULL)->>'design_family');

    -- set + concepts (PRODUCT_UI_STORY requires authoritative UI_SCREENSHOT; BOLD_SIGNAL does not)
    INSERT INTO public.creative_concept_sets(tenant_id,source_mode,subject,business_objective,audience,core_message,platform,creative_format)
    VALUES (c_tenant,'BUSINESS_SELF','Strateloq','BRAND_AWARENESS','founders','Turn market signals into action','META_FACEBOOK','SAAS_SOCIAL_SQUARE') RETURNING id INTO v_set;

    INSERT INTO public.creative_concepts(set_id,tenant_id,concept_label,concept_name,message_angle,visual_concept,
      visual_hierarchy,composition_direction,colour_direction,imagery_direction,copy_density,typography_treatment,
      cta_strategy,platform_format,headline,body_copy,cta_text,declares_real_assets,design_rationale,distinctness_key,
      design_family,platform_target)
    VALUES (v_set,c_tenant,'A','Signal','PROBLEM_SOLUTION','dark signal','headline-dominant','centered','dark+cyan','abstract',
      'low','bold grotesque','text CTA','1080x1080','Turn market signals into action','Decide and move','Learn more',
      '[]'::jsonb,'Bold family suits a cold audience','FAM_BOLD','BOLD_SIGNAL','META_FACEBOOK') RETURNING id INTO v_cSig;

    INSERT INTO public.creative_concepts(set_id,tenant_id,concept_label,concept_name,message_angle,visual_concept,
      visual_hierarchy,composition_direction,colour_direction,imagery_direction,copy_density,typography_treatment,
      cta_strategy,platform_format,headline,body_copy,cta_text,declares_real_assets,design_rationale,distinctness_key,
      design_family,platform_target)
    VALUES (v_set,c_tenant,'B','Capability','USE_CASE','framed UI','split','left-text right-visual','dark+cyan','ui',
      'medium','grotesque','button','1080x1080','See Strateloq in action','Real product UI','Explore',
      '["UI_SCREENSHOT"]'::jsonb,'Product UI story shows capability','FAM_UI','PRODUCT_UI_STORY','META_FACEBOOK') RETURNING id INTO v_cUI;

    -- (4) PENDING asset cannot satisfy a family that REQUIRES authoritative assets
    INSERT INTO public.media_assets(tenant_id,media_type,source_type,rights_state,generation_status,approval_state,is_launch_safe,identity_state,storage_ref,mime_type)
    VALUES (c_tenant,'IMAGE','WEBSITE_CAPTURE','FIRST_PARTY_OWNED','CAPTURED','DRAFT',false,'NOT_APPLICABLE','x-pending','image/png') RETURNING id INTO v_media;
    PERFORM public.fn_ci_brand_asset_put(c_tenant,'UI_SCREENSHOT',NULL,NULL,v_media,false,'{"state":"pending"}'::jsonb); -- authoritative=false => PENDING
    v_r := public.fn_ci_design_family_gate(v_cUI);
    v := v || jsonb_build_object('case','pending_asset_not_authoritative','pass',
      (v_r->>'ok')='false' AND (v_r->'missing_authoritative')::text ILIKE '%UI_SCREENSHOT%');

    -- approve an authoritative UI screenshot => family gate passes
    INSERT INTO public.media_assets(tenant_id,media_type,source_type,rights_state,generation_status,approval_state,is_launch_safe,identity_state,storage_ref,mime_type)
    VALUES (c_tenant,'IMAGE','WEBSITE_CAPTURE','FIRST_PARTY_OWNED','CAPTURED','APPROVED',true,'NOT_APPLICABLE','x-approved','image/png') RETURNING id INTO v_media2;
    PERFORM public.fn_ci_brand_asset_put(c_tenant,'UI_SCREENSHOT',NULL,NULL,v_media2,true,'{"state":"approved"}'::jsonb);
    v := v || jsonb_build_object('case','approved_authoritative_satisfies_family','pass',
      (public.fn_ci_design_family_gate(v_cUI)->>'ok')='true');

    -- (5) platform adaptation: supported platform ok; square master for TikTok requires recompose; unknown platform fails
    v := v || jsonb_build_object('case','platform_supported_facebook','pass',
      (public.fn_ci_platform_fit_gate(v_cSig)->>'ok')='true');
    UPDATE public.creative_concepts SET platform_target='TIKTOK', platform_format='1080x1080' WHERE id=v_cSig;
    v_r := public.fn_ci_platform_fit_gate(v_cSig);
    v := v || jsonb_build_object('case','tiktok_square_master_requires_recompose','pass',
      (v_r->>'ok')='true' AND (v_r->>'recompose_required')='true');
    UPDATE public.creative_concepts SET platform_target='MYSPACE' WHERE id=v_cSig;
    v := v || jsonb_build_object('case','unsupported_platform_fails','pass',
      (public.fn_ci_platform_fit_gate(v_cSig)->>'ok')='false');
    UPDATE public.creative_concepts SET platform_target='META_FACEBOOK', platform_format='1080x1080' WHERE id=v_cSig;

    -- (6) quality rejection / regeneration via the EXISTING judge (through the design evaluate wrapper)
    INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,provider,model,status,asset_storage_ref)
    VALUES (v_cSig,c_tenant,1,'GOOGLE_GEMINI','gemini-2.5-flash-image','GENERATED','pulse-generated-media/ci/sig1.png') RETURNING id INTO v_gen;
    v_r := public.fn_ci_design_quality_evaluate(v_gen, v_weak, 'GOOGLE_GEMINI','gemini-2.5-flash','pulse-generated-media/ci/sig1.png');
    v := v || jsonb_build_object('case','weak_quality_revises','pass', v_r->>'verdict'='REVISE' AND v_r->>'review_state'='QUALITY_CHECKED');

    INSERT INTO public.creative_concept_generations(concept_id,tenant_id,attempt_no,provider,model,status,asset_storage_ref)
    VALUES (v_cSig,c_tenant,2,'GOOGLE_GEMINI','gemini-2.5-flash-image','GENERATED','pulse-generated-media/ci/sig2.png') RETURNING id INTO v_gen;
    v_r := public.fn_ci_design_quality_evaluate(v_gen, v_good, 'GOOGLE_GEMINI','gemini-2.5-flash','pulse-generated-media/ci/sig2.png');
    v := v || jsonb_build_object('case','good_quality_reaches_founder_review','pass',
      v_r->>'verdict'='PASS' AND v_r->>'review_state'='PENDING_FOUNDER_REVIEW','observed',v_r->>'verdict');

    -- (7) approval gating: no auto-approve; APPROVE requires a PASS; founder decision flips state
    v := v || jsonb_build_object('case','not_auto_approved_after_pass','pass',
      (SELECT review_state FROM public.creative_concepts WHERE id=v_cSig)='PENDING_FOUNDER_REVIEW');
    -- a concept that never passed cannot be approved
    v_r := public.fn_ci_candidate_set_approval(c_tenant, v_cUI, 'APPROVE');
    v := v || jsonb_build_object('case','cannot_approve_without_pass','pass',(v_r->>'error')='not_quality_passed');
    -- the PASS candidate can be founder-approved
    v_r := public.fn_ci_candidate_set_approval(c_tenant, v_cSig, 'APPROVE');
    v := v || jsonb_build_object('case','founder_approve_sets_approved','pass',
      (v_r->>'ok')='true' AND (v_r->>'review_state')='APPROVED');

    -- (8) learning loop: approval wrote a learning record with family/platform metadata
    v := v || jsonb_build_object('case','learning_record_written','pass',
      EXISTS(SELECT 1 FROM public.creative_learning_records WHERE tenant_id=c_tenant AND concept_id=v_cSig
             AND design_family='BOLD_SIGNAL' AND approval_result='APPROVED'));

    -- (9) product identity preservation (Product Asset Lock reuse): AI full redraw FAILs; real composite PASSes
    INSERT INTO public.media_assets(tenant_id,media_type,source_type,rights_state,generation_status,approval_state,is_launch_safe,identity_state,storage_ref,mime_type,generation_mode)
    VALUES (c_tenant,'IMAGE','STORE_IMPORT','CLEARED','COMPLETE','DRAFT',false,'IDENTITY_RESOLVED','x-redraw','image/png','FULL_FRAME_AI_REDRAW') RETURNING id INTO v_media3;
    v_r := public.fn_media_product_identity_preserved(v_media3);
    v := v || jsonb_build_object('case','product_identity_ai_redraw_fails','pass',(v_r->>'state')='FAIL');
    INSERT INTO public.media_assets(tenant_id,media_type,source_type,rights_state,generation_status,approval_state,is_launch_safe,identity_state,storage_ref,mime_type,generation_mode,provenance)
    VALUES (c_tenant,'IMAGE','STORE_IMPORT','CLEARED','COMPLETE','DRAFT',false,'IDENTITY_RESOLVED','x-composite','image/png','REAL_PRODUCT_LAYER_COMPOSITE','{"product_layer_source":"authoritative_product_card"}'::jsonb) RETURNING id INTO v_media4;
    v_r := public.fn_media_product_identity_preserved(v_media4);
    v := v || jsonb_build_object('case','product_identity_real_composite_passes','pass',(v_r->>'state')='PASS');

    -- (10) tenant isolation at function layer
    v_r := public.fn_ci_candidate_set_approval(c_other, v_cSig, 'APPROVE');
    v := v || jsonb_build_object('case','cross_tenant_approval_rejected','pass',(v_r->>'error')='cross_tenant_rejected');

    -- (12) no autonomous publishing / spend created by this suite
    v := v || jsonb_build_object('case','no_publishing_request_created','pass',
      (SELECT count(*) FROM public.social_publishing_requests
         WHERE tenant_id=c_tenant AND created_at > now() - interval '2 minutes'
           AND content->>'subject'='DESIGN_SYSTEM_SELFTEST')=0);

    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN v := v || jsonb_build_object('case','UNEXPECTED_ERROR','pass',false,'err',SQLERRM); END IF;
  END;

  RETURN jsonb_build_object('suite','creative_design_system',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ci_design_system_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ci_design_system_selftest() TO postgres, service_role;

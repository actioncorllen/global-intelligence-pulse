-- STRATELOQ — INTERNAL CREATIVE STUDIO FORMAT EXPANSION
-- ============================================================================
-- Adds five founder-required creative FORMATS as first-class creative modes,
-- as a STYLE dimension layered on the existing creative_type (VIDEO/STATIC) and
-- the existing provider abstraction (fn_media_provider_for), Product Asset Lock
-- (fn_creative_scene_identity_policy) and QA. No parallel architecture is created;
-- no frozen contract function is modified; no paid generation is invoked.
--
--   LOW_FI_UGC        -> VIDEO  (Low-Fi UGC / Selfie Video)
--   GRID_MULTI_CARD   -> STATIC (Grid-Style / Multi-Card Static)
--   BROLL_TEXT_OVERLAY-> VIDEO  (B-Roll + Bold Text)
--   CASUAL_PODCAST    -> VIDEO  (Casual Podcast / Interview)
--   OBJECTION_POV     -> VIDEO  (Negative Marketing / Objection-Handling POV)
--
-- Flow: Product Intelligence -> Marketing Director -> Creative Strategy ->
--   CREATIVE FORMAT (select here) -> Commercial Creative Director (storyboard) ->
--   Product Asset Lock -> Generation Engine -> format-aware QA -> repair/fallback.
--
-- Reversible: DROP the functions, the creative_production_requests.creative_format
-- column, and the creative_format_registry table.
-- ============================================================================

-- 1) FORMAT REGISTRY (reference data; RLS on, readable by authenticated, service_role writes) ----
CREATE TABLE IF NOT EXISTS public.creative_format_registry (
  format_key            text PRIMARY KEY,
  display_label         text NOT NULL,
  output_type           text NOT NULL CHECK (output_type IN ('VIDEO','STATIC')),
  generator_route       text NOT NULL CHECK (generator_route IN ('VIDEO','IMAGE')),
  default_aspect_ratios jsonb NOT NULL DEFAULT '[]'::jsonb,
  prompt_template       text NOT NULL,
  storyboard_logic      jsonb NOT NULL,
  shot_rules            jsonb NOT NULL,
  pacing_rules          jsonb NOT NULL,
  text_treatment        jsonb NOT NULL,
  cta_treatment         jsonb NOT NULL,
  qa_criteria           jsonb NOT NULL,
  auto_select_signals   jsonb NOT NULL DEFAULT '{}'::jsonb,
  auto_reason           text NOT NULL,
  base_weight           numeric NOT NULL DEFAULT 0,
  enabled               boolean NOT NULL DEFAULT true,
  sort_order            integer NOT NULL DEFAULT 100,
  created_at            timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.creative_format_registry ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='creative_format_registry' AND policyname='creative_format_registry_read') THEN
    CREATE POLICY creative_format_registry_read ON public.creative_format_registry
      FOR SELECT TO authenticated USING (enabled);
  END IF;
END $$;

-- 2) SEED THE FIVE FORMATS (distinct storyboard/shot/pacing/text/CTA/QA per format) ----
INSERT INTO public.creative_format_registry
  (format_key, display_label, output_type, generator_route, default_aspect_ratios, prompt_template,
   storyboard_logic, shot_rules, pacing_rules, text_treatment, cta_treatment, qa_criteria,
   auto_select_signals, auto_reason, base_weight, sort_order)
VALUES
-- ---- LOW_FI_UGC ----------------------------------------------------------------
('LOW_FI_UGC','Low-Fi UGC / Selfie Video','VIDEO','VIDEO','["9:16"]',
 'Authentic creator/UGC selfie-style ad. Handheld/selfie framing, direct-to-camera, conversational and natural, imperfect-but-intentional. The referenced product must keep its exact geometry, branding, labels, colours, logo and packaging; only environment/creator context varies. Native TikTok/Reels feel; captions/subtitles on. No corporate voice-over, no fake testimonial, no unrealistic influencer claim.',
 '[{"t":"0-2","beat":"CONVERSATIONAL_HOOK","note":"direct-to-camera, immediate relevance"},{"t":"2-5","beat":"PROBLEM_OR_EXPERIENCE","note":"product introduced naturally"},{"t":"5-8","beat":"PRODUCT_BENEFIT_DEMO","note":"show product accurately"},{"t":"8-12","beat":"RESULT_OR_CTA","note":"reason to care / soft CTA"}]',
 '{"camera":"handheld/selfie","framing":"creator close/medium","movement":"natural, minor imperfection allowed","product":"shown accurately, no restyle"}',
 '{"feel":"natural pauses, conversational","polish":"low-fi intentional","hook_by_s":2}',
 '{"style":"captions/subtitles","tone":"conversational","length":"short spoken phrases"}',
 '{"style":"soft/spoken","placement":"end or lower-third","required":false}',
 '["PRODUCT_IDENTITY","CLAIM_SAFETY","NATIVE_NOT_CORPORATE","IMMEDIATE_HOOK","BELIEVABLE_DIALOGUE_CAPTIONS","NO_FAKE_TESTIMONIAL","CAPTION_READABILITY","PLATFORM_FORMAT"]',
 '{"ugc_preferred":3,"demonstration_suitable":2,"authenticity_preferred":3,"platform_tiktok":1}',
 'Selected because this product performs best with authentic, creator-style content.',
 1, 10),
-- ---- GRID_MULTI_CARD (STATIC) --------------------------------------------------
('GRID_MULTI_CARD','Grid-Style / Multi-Card Static','STATIC','IMAGE','["1:1","4:5","9:16"]',
 'High-performing paid-social STATIC that communicates multiple benefits/proof/comparison in one visual (2x2 grid, 3-card benefits, product+benefits, problem/product/result, feature comparison, listicle cards). Use the exact Product Card assets as the product layer; NEVER regenerate/replace the product. AI may generate only backgrounds, shapes, layout, supporting icons and typography. Preserve product appearance, logo, packaging, colour and identifiable details.',
 '[{"card":1,"role":"HOOK_OR_PRODUCT"},{"card":2,"role":"BENEFIT_OR_PROBLEM"},{"card":3,"role":"BENEFIT_OR_SOLUTION"},{"card":4,"role":"PROOF_OR_OFFER_OR_CTA"}]',
 '{"product_layer":"exact Product Card pixels (deterministic place/scale/mask only)","generated":"background/shapes/icons/typography only","layouts":["2x2","3-card","before-after","comparison","listicle"]}',
 '{"feel":"static","scan":"clear visual hierarchy, not overcrowded"}',
 '{"style":"bold headline + concise card labels","hierarchy":"headline > card labels > footnotes","readability":"mobile-first"}',
 '{"style":"button/pill or offer line","placement":"dedicated card or footer","required":false}',
 '["PRODUCT_IDENTITY","CLAIM_SAFETY","VISUAL_HIERARCHY_CLEAR","TEXT_READABLE","NOT_OVERCROWDED","MOBILE_AD_SUITABLE","LAYOUT_INTENTIONAL"]',
 '{"multiple_benefits":3,"comparison_evidence":2,"static_preferred":2,"proof_points":2}',
 'Selected because this message is strongest as a multi-point static that shows several benefits at once.',
 0, 20),
-- ---- BROLL_TEXT_OVERLAY --------------------------------------------------------
('BROLL_TEXT_OVERLAY','B-Roll + Bold Text','VIDEO','VIDEO','["9:16"]',
 'Short performance ad where strong B-roll + bold text overlays carry the message fast. Visual hook in first 1-2s, product close-ups, lifestyle context where apt, short bold phrases (not paragraphs), benefit-led sequencing, rhythmic pacing, CTA/end frame. Product must remain visually correct (geometry/branding/colour/logo/packaging). Keep text within TikTok/Reels/Meta safe margins.',
 '[{"beat":"HOOK_TEXT","t":"0-1.5"},{"beat":"PRODUCT_BROLL","t":"1.5-3.5"},{"beat":"PROBLEM_OR_BENEFIT","t":"3.5-5.5"},{"beat":"SECOND_PRODUCT_SHOT","t":"5.5-7"},{"beat":"PROOF_OR_DIFFERENTIATOR","t":"7-9"},{"beat":"CTA_END_FRAME","t":"9-10"}]',
 '{"camera":"dynamic b-roll + close-ups","product":"accurate close-ups, no restyle","context":"lifestyle where appropriate"}',
 '{"feel":"rhythmic/fast","hook_by_s":2}',
 '{"style":"bold overlay phrases","length":"short phrases","safe_margins":true,"readability":"mobile-first"}',
 '{"style":"bold CTA end frame","placement":"final frame","required":true}',
 '["PRODUCT_IDENTITY","CLAIM_SAFETY","FAST_HOOK","TEXT_OVERLAY_READABLE","BROLL_SUPPORTS_MESSAGE","COMMERCIAL_PACING","PRODUCT_VISUALLY_CORRECT","PLATFORM_FORMAT"]',
 '{"fast_hook_bold":2,"demonstration_suitable":2,"benefit_led":2}',
 'Selected because a fast, bold-text B-roll cut communicates this benefit quickly on feed.',
 0, 30),
-- ---- CASUAL_PODCAST ------------------------------------------------------------
('CASUAL_PODCAST','Casual Podcast / Interview','VIDEO','VIDEO','["9:16"]',
 'Ad resembling a casual podcast/interview/founder or expert conversation. Conversational framing (mic/relaxed setup where apt), natural speaker composition, social-native crop, subtitles, occasional product cutaway/B-roll. Conversational pacing. Do NOT present a generated speaker as a real expert/doctor/customer/founder or identifiable individual, and do NOT fabricate endorsements; keep it clearly promotional where required. Product shown accurately.',
 '[{"beat":"CONVERSATIONAL_OPENER","note":"e.g. common mistake / myth"},{"beat":"PRODUCT_CUTAWAY","note":"B-roll of accurate product"},{"beat":"WHAT_ACTUALLY_MATTERS","note":"benefit framed conversationally"},{"beat":"RECOMMENDATION_CTA"}]',
 '{"framing":"interview/podcast two-shot or single","product":"cutaway B-roll, accurate","setup":"mic/relaxed environment where apt"}',
 '{"feel":"relaxed/conversational","subtitles":true}',
 '{"style":"subtitles for spoken content","tone":"conversational","readability":"mobile-first"}',
 '{"style":"spoken recommendation","placement":"end","required":false}',
 '["PRODUCT_IDENTITY","CLAIM_SAFETY","CONVERSATIONAL_DIALOGUE","INTERVIEW_FRAMING","NO_FAKE_AUTHORITY_OR_ENDORSEMENT","CLEAR_PRODUCT_MESSAGE","SUBTITLES_MOBILE_SUITABLE"]',
 '{"educational_angle":3,"expert_explanation":2}',
 'Selected because an explanatory, conversational format suits this product''s decision.',
 0, 40),
-- ---- OBJECTION_POV -------------------------------------------------------------
('OBJECTION_POV','Negative Marketing / Objection-Handling POV','VIDEO','VIDEO','["9:16"]',
 'Ad that opens on a real pain point / objection / misconception / failed approach, then introduces the product as the relevant solution (e.g. "Still struggling with ___?", "Why ___ keeps failing", "POV: you''re tired of ___"). Objection must be chosen from Product Intelligence, real customer pain points, market evidence, competitor patterns and positioning. Persuasive but evidence-aware. Do NOT invent medical/financial outcomes, fake complaints, fake competitor failures, fake statistics, fabricated before/after or unverifiable superiority. Product shown accurately.',
 '[{"beat":"OBJECTION_OR_PAIN","t":"0-2","note":"evidence-grounded objection"},{"beat":"WHY_IT_FAILS","t":"2-5","note":"reframe, no fabricated claims"},{"beat":"PRODUCT_AS_SOLUTION","t":"5-8","note":"accurate product, supportable benefit"},{"beat":"SUPPORTABLE_PROOF_CTA","t":"8-12"}]',
 '{"open":"pain/objection first","product":"accurate; introduced as solution","evidence":"objection grounded in intelligence/evidence"}',
 '{"feel":"direct/persuasive","hook_by_s":2}',
 '{"style":"objection headline + supporting captions","tone":"direct, not misleading","readability":"mobile-first"}',
 '{"style":"solution-oriented CTA","placement":"end","required":true}',
 '["PRODUCT_IDENTITY","CLAIM_SAFETY","OBJECTION_UNDERSTANDABLE","PRODUCT_ADDRESSES_OBJECTION","CLAIMS_SUPPORTABLE","PERSUASIVE_NOT_MISLEADING","NO_FABRICATED_COMPETITOR_OR_CUSTOMER_CLAIM"]',
 '{"objection_present":3,"competitor_pain":2,"positioning_contrarian":1}',
 'Selected because addressing a known objection head-on fits this audience and evidence.',
 0, 50)
ON CONFLICT (format_key) DO NOTHING;

-- 3) PERSIST SELECTED FORMAT ON THE CREATIVE REQUEST (additive column) ----
ALTER TABLE public.creative_production_requests
  ADD COLUMN IF NOT EXISTS creative_format text
    REFERENCES public.creative_format_registry(format_key);

-- 4) CATALOG (customer-safe options for the UI selector) ----
CREATE OR REPLACE FUNCTION public.fn_creative_format_catalog()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'format', format_key, 'label', display_label,
           'output_type', output_type, 'aspect_ratios', default_aspect_ratios
         ) ORDER BY sort_order), '[]'::jsonb)
  FROM public.creative_format_registry WHERE enabled;
$function$;

-- 5) ROUTING: format -> output_type + generator + provider (no dispatch, no paid call) ----
CREATE OR REPLACE FUNCTION public.fn_creative_format_route(p_format text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE r public.creative_format_registry%ROWTYPE; v_provider text;
BEGIN
  SELECT * INTO r FROM public.creative_format_registry WHERE format_key=p_format AND enabled;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','unknown_format'); END IF;
  v_provider := public.fn_media_provider_for(r.generator_route);
  RETURN jsonb_build_object(
    'ok', true, 'format', r.format_key, 'output_type', r.output_type,
    'generator_route', r.generator_route, 'provider', v_provider,
    -- static is producible now; video generation is founder-gated/paid (see media_providers)
    'video_generation_paid_gated', (r.output_type='VIDEO'),
    'note', CASE WHEN r.output_type='STATIC'
                 THEN 'Routes to the existing static/image pipeline (available now).'
                 ELSE 'Routes to the generative-video provider; real generation is founder cost-gated (BLOCKED_EXTERNAL_DEPENDENCY until authorized).' END);
END; $function$;

-- 6) FORMAT-AWARE QA CRITERIA (extends QA; universal gates ∪ format gates) ----
CREATE OR REPLACE FUNCTION public.fn_creative_format_qa_criteria(p_format text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE r public.creative_format_registry%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.creative_format_registry WHERE format_key=p_format AND enabled;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','unknown_format'); END IF;
  RETURN jsonb_build_object(
    'ok', true, 'format', r.format_key, 'output_type', r.output_type,
    -- universal launch gates always apply (identity + claim-truth are non-negotiable)
    'universal_gates', jsonb_build_array('PRODUCT_IDENTITY','CLAIM_SAFETY','HUMAN_REVIEW'),
    'format_gates', r.qa_criteria);
END; $function$;

-- 7) FORMAT SELECTION: MANUAL + AUTO (deterministic; only a short user-facing reason) ----
CREATE OR REPLACE FUNCTION public.fn_creative_format_select(p_input jsonb, p_mode text DEFAULT 'AUTO')
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

  -- AUTO: score each enabled format = base_weight + sum(weight for each matched input signal).
  FOR r IN SELECT * FROM public.creative_format_registry WHERE enabled LOOP
    v_score := coalesce(r.base_weight,0);
    FOR k, w IN SELECT key, value::numeric FROM jsonb_each_text(r.auto_select_signals) LOOP
      IF coalesce((p_input->>k),'') IN ('true','t','1','yes') THEN
        v_score := v_score + w;
      END IF;
    END LOOP;
    IF v_score > v_best_score OR (v_score = v_best_score AND r.sort_order < v_best_sort) THEN
      v_best_score := v_score; v_best_key := r.format_key; v_best_sort := r.sort_order;
    END IF;
  END LOOP;

  SELECT * INTO r FROM public.creative_format_registry WHERE format_key=v_best_key;
  RETURN jsonb_build_object('ok',true,'mode','AUTO','format',r.format_key,'label',r.display_label,
    'output_type',r.output_type,'reason',r.auto_reason);
END; $function$;

-- 8) PERSIST the selected format onto a creative request (tenant-checked; additive) ----
CREATE OR REPLACE FUNCTION public.fn_creative_format_apply(p_tenant uuid, p_request_id uuid, p_format text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_exists boolean; v_valid boolean;
BEGIN
  SELECT exists(SELECT 1 FROM public.creative_format_registry WHERE format_key=p_format AND enabled) INTO v_valid;
  IF NOT v_valid THEN RETURN jsonb_build_object('ok',false,'error','unknown_format'); END IF;
  UPDATE public.creative_production_requests
     SET creative_format = p_format
   WHERE id = p_request_id AND tenant_id = p_tenant
  RETURNING true INTO v_exists;
  IF NOT coalesce(v_exists,false) THEN RETURN jsonb_build_object('ok',false,'error','request_not_found_for_tenant'); END IF;
  RETURN jsonb_build_object('ok',true,'request_id',p_request_id,'creative_format',p_format);
END; $function$;

-- 9) SELFTEST — verifies the PASS criteria deterministically, no paid call ----
CREATE OR REPLACE FUNCTION public.fn_creative_format_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE checks jsonb := '[]'::jsonb; v_n int; v_distinct int;
  v_ugc jsonb; v_grid jsonb; v_obj jsonb; v_route_static jsonb; v_route_video jsonb;
  v_manual jsonb; v_qa_ugc jsonb; v_qa_grid jsonb; f record;
  v_id_gen jsonb; v_id_real jsonb; v_all_identity boolean := true;
  add_check text;
BEGIN
  -- (1) five first-class formats exist
  SELECT count(*) INTO v_n FROM public.creative_format_registry WHERE enabled;
  checks := checks || jsonb_build_object('check','FIVE_FORMATS_EXIST','pass',(v_n=5),'detail',v_n);

  -- (2) each has distinct storyboard logic + non-empty rule sets
  SELECT count(DISTINCT storyboard_logic::text) INTO v_distinct FROM public.creative_format_registry WHERE enabled;
  checks := checks || jsonb_build_object('check','DISTINCT_STORYBOARD_LOGIC','pass',(v_distinct=5),'detail',v_distinct);
  SELECT count(*) INTO v_n FROM public.creative_format_registry WHERE enabled
    AND (length(prompt_template)>40 AND jsonb_array_length(qa_criteria)>=4
         AND shot_rules<>'{}'::jsonb AND pacing_rules<>'{}'::jsonb
         AND text_treatment<>'{}'::jsonb AND cta_treatment<>'{}'::jsonb);
  checks := checks || jsonb_build_object('check','EACH_FORMAT_HAS_DISTINCT_RULES','pass',(v_n=5),'detail',v_n);

  -- (3) routing: GRID static/IMAGE; the four others VIDEO
  v_route_static := public.fn_creative_format_route('GRID_MULTI_CARD');
  v_route_video  := public.fn_creative_format_route('LOW_FI_UGC');
  checks := checks || jsonb_build_object('check','STATIC_ROUTES_TO_IMAGE',
    'pass',(v_route_static->>'output_type'='STATIC' AND v_route_static->>'generator_route'='IMAGE'),'detail',v_route_static);
  checks := checks || jsonb_build_object('check','VIDEO_ROUTES_TO_VIDEO',
    'pass',(v_route_video->>'output_type'='VIDEO' AND v_route_video->>'generator_route'='VIDEO'),'detail',v_route_video);

  -- (4) manual selection works
  v_manual := public.fn_creative_format_select(jsonb_build_object('format','BROLL_TEXT_OVERLAY'),'MANUAL');
  checks := checks || jsonb_build_object('check','MANUAL_SELECTION',
    'pass',(v_manual->>'ok'='true' AND v_manual->>'format'='BROLL_TEXT_OVERLAY'),'detail',v_manual);

  -- (5) auto selection works and is signal-driven
  v_obj  := public.fn_creative_format_select(jsonb_build_object('objection_present',true),'AUTO');           -- -> OBJECTION_POV
  v_grid := public.fn_creative_format_select(jsonb_build_object('multiple_benefits',true,'static_preferred',true),'AUTO'); -- -> GRID_MULTI_CARD
  v_ugc  := public.fn_creative_format_select(jsonb_build_object('ugc_preferred',true),'AUTO');               -- -> LOW_FI_UGC
  checks := checks || jsonb_build_object('check','AUTO_OBJECTION','pass',(v_obj->>'format'='OBJECTION_POV'),'detail',v_obj->>'format');
  checks := checks || jsonb_build_object('check','AUTO_GRID','pass',(v_grid->>'format'='GRID_MULTI_CARD'),'detail',v_grid->>'format');
  checks := checks || jsonb_build_object('check','AUTO_UGC','pass',(v_ugc->>'format'='LOW_FI_UGC'),'detail',v_ugc->>'format');
  checks := checks || jsonb_build_object('check','AUTO_RETURNS_REASON','pass',(length(coalesce(v_obj->>'reason',''))>0),'detail',v_obj->>'reason');
  checks := checks || jsonb_build_object('check','AUTO_DEFAULT_HAS_WINNER',
    'pass',(public.fn_creative_format_select('{}'::jsonb,'AUTO')->>'ok'='true'),'detail',public.fn_creative_format_select('{}'::jsonb,'AUTO')->>'format');

  -- (6) Product Asset Lock applies to EVERY format (identity policy is format-agnostic but must hold)
  FOR f IN SELECT format_key FROM public.creative_format_registry WHERE enabled LOOP
    v_id_gen  := public.fn_creative_scene_identity_policy('CUSTOMER_PRODUCT','PRODUCT',true,true);
    v_id_real := public.fn_creative_scene_identity_policy('CUSTOMER_PRODUCT','PRODUCT',true,false);
    IF v_id_gen->>'identity_state' <> 'IDENTITY_REVIEW_REQUIRED'
       OR v_id_real->>'identity_state' <> 'AUTHORITATIVE_PRODUCT_CARD_PIXELS' THEN
      v_all_identity := false;
    END IF;
  END LOOP;
  checks := checks || jsonb_build_object('check','PRODUCT_IDENTITY_LOCK_ALL_FORMATS','pass',v_all_identity);

  -- (7) QA is format-aware (criteria differ by format) and always carries universal gates
  v_qa_ugc  := public.fn_creative_format_qa_criteria('LOW_FI_UGC');
  v_qa_grid := public.fn_creative_format_qa_criteria('GRID_MULTI_CARD');
  checks := checks || jsonb_build_object('check','QA_FORMAT_AWARE',
    'pass',(v_qa_ugc->'format_gates' <> v_qa_grid->'format_gates'
            AND v_qa_ugc->'universal_gates' ? 'PRODUCT_IDENTITY'
            AND v_qa_ugc->'universal_gates' ? 'CLAIM_SAFETY'),'detail',jsonb_build_object('ugc',v_qa_ugc->'format_gates','grid',v_qa_grid->'format_gates'));

  -- (8) persistence column exists
  SELECT count(*) INTO v_n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='creative_production_requests' AND column_name='creative_format';
  checks := checks || jsonb_build_object('check','FORMAT_PERSISTENCE_COLUMN','pass',(v_n=1));

  SELECT count(*) INTO v_n FROM jsonb_array_elements(checks) c WHERE (c->>'pass')::boolean IS NOT TRUE;
  RETURN jsonb_build_object('ok',(v_n=0),'contract','creative_format_expansion_v1',
    'failed',v_n,'total',jsonb_array_length(checks),'checks',checks);
END; $function$;

-- 10) GRANTS (reference reads for authenticated; tenant setter stays server-invoked) ----
GRANT EXECUTE ON FUNCTION public.fn_creative_format_catalog() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_creative_format_route(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_creative_format_qa_criteria(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_creative_format_select(jsonb, text) TO authenticated;

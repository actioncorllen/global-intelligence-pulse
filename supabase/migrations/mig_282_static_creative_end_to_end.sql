-- ============================================================================
-- mig_282_static_creative_end_to_end.sql
-- STRATELOQ-AI-AD-CREATIVE-STUDIO-015K — First end-to-end INTERNAL static ad
-- creative, up to (and stopping at) the founder paid-generation cost gate.
-- Governed by docs/STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md (LOCKED).
--
-- Proves the internal Creative Production Agent can drive a REAL static creative
-- end-to-end using ONLY existing entitled internal capabilities:
--   Intelligence (canonical product + Product Decision)
--   -> Marketing Director brief (fn_ad_studio_build_brief)
--   -> 3 distinct evidence-grounded hypotheses (fn_ad_studio_generate_angles)
--   -> SELECT ONE for test (fn_ad_studio_select_test_angle) — NOT a winner claim
--   -> Creative Studio image job (fn_media_create_image_job)
--   -> claim gate + CANONICAL lineage + cost gate (fn_media_prepare_image_job)
--   -> deterministic text/composition spec for META/INSTAGRAM 1080x1350
--      (fn_ad_compile_static_composition; n8n Edit Image / ImageMagick)
--   -> Creative Quality Reviewer (fn_creative_quality_review IMAGE_ASSET).
--
-- HARD RULES honoured here:
--  * NO generation / NO paid provider call is made by these functions. The single
--    gpt-image-1 paid call remains gated: the orchestrator STOPS at READY_TO_DISPATCH
--    and returns READY_FOR_FOUNDER_STATIC_GENERATION_APPROVAL.
--  * CANONICAL lineage is mandatory; INLINE_ONLY/UNRESOLVED -> STATIC_CREATIVE_BLOCKED.
--  * Authoritative Product Card image is the identity authority; background may change,
--    product model/shape/controls/logo/features/SKU may NOT.
--  * Deterministic composed text carries NO invented discount/price/scarcity/rating/
--    testimonial/guarantee/performance claim — every composed string is claim-scanned.
--  * A generated asset is never an automatic PASS; aesthetic gates stay REVIEW_REQUIRED;
--    asset stays IN_REVIEW / launch_safe=false; human approval mandatory.
--  * Provider-invisible: renderer is STRATELOQ_CREATIVE_STUDIO to customers.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Audit columns for test selection (deterministic, auditable, non-superlative)
-- ---------------------------------------------------------------------------
ALTER TABLE public.ad_studio_angles
  ADD COLUMN IF NOT EXISTS test_selection text,
  ADD COLUMN IF NOT EXISTS test_selection_reason text;

-- ---------------------------------------------------------------------------
-- 1. Select ONE hypothesis to TEST from a brief's 3 angles.
--    Deterministic rule: lowest claim-risk first (LOW before FLAGGED), then the
--    lowest angle_index. This is a STARTING POINT for testing — explicitly NOT a
--    prediction of performance and NEVER a "best"/"winner"/"high-converting" claim.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_studio_select_test_angle(p_brief_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_sel uuid; v_total int; v_reason text;
BEGIN
  SELECT count(*) INTO v_total FROM public.ad_studio_angles WHERE brief_id=p_brief_id;
  IF v_total = 0 THEN RETURN jsonb_build_object('status','no_angles'); END IF;

  SELECT id INTO v_sel
  FROM public.ad_studio_angles
  WHERE brief_id=p_brief_id
  ORDER BY (CASE WHEN claim_risk='LOW' THEN 0 ELSE 1 END), angle_index
  LIMIT 1;

  v_reason := 'Deterministic test-selection rule: lowest claim-risk, then lowest angle_index. '
           || 'This is the FIRST hypothesis to put into a test — a starting point only, '
           || 'NOT a performance prediction, ranking, or "best/winner/high-converting" claim. '
           || 'The other hypotheses are held for later tests.';

  UPDATE public.ad_studio_angles
     SET test_selection = CASE WHEN id=v_sel THEN 'SELECTED_FOR_TEST' ELSE 'HELD_FOR_FUTURE_TEST' END,
         test_selection_reason = CASE WHEN id=v_sel THEN v_reason ELSE 'Held for a later test cycle.' END,
         updated_at = now()
   WHERE brief_id=p_brief_id;

  RETURN jsonb_build_object('status','ok','brief_id',p_brief_id,'total_hypotheses',v_total,
    'selected_angle_id',v_sel,'selection_rule','LOWEST_RISK_THEN_LOWEST_INDEX',
    'selection_reason',v_reason,
    'hypotheses', (SELECT jsonb_agg(jsonb_build_object(
        'angle_id',id,'angle_index',angle_index,'angle_type',angle_type,'hook',hook,
        'headline',headline,'cta',cta,'claim_risk',claim_risk,'test_selection',test_selection)
        ORDER BY angle_index)
      FROM public.ad_studio_angles WHERE brief_id=p_brief_id));
END; $fn$;

-- ---------------------------------------------------------------------------
-- 2. Deterministic static composition spec (META / INSTAGRAM feed 1080x1350, 4:5).
--    Produces the internal n8n Edit Image / ImageMagick op plan that would place the
--    generated product hero on a brand-neutral portrait canvas and burn ONLY
--    deterministic, claim-scanned text (headline band + CTA pill). No pricing, no
--    scarcity, no ratings, no testimonials, no guarantees, no performance claims.
--    SPEC ONLY — nothing is rendered or generated here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_compile_static_composition(p_job_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE j public.media_image_jobs%rowtype; a public.ad_studio_angles%rowtype; b public.ad_studio_briefs%rowtype;
  v_headline text; v_cta text; v_scan jsonb; v_safe boolean; v_text text; v_ops jsonb;
BEGIN
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  SELECT * INTO a FROM public.ad_studio_angles WHERE id=j.angle_id;
  SELECT * INTO b FROM public.ad_studio_briefs WHERE id=a.brief_id;

  -- Deterministic text drawn ONLY from the approved angle copy (no invented claims).
  v_headline := btrim(coalesce(a.headline,''));
  v_cta := btrim(coalesce(a.cta,'Learn more'));
  v_text := concat_ws(' ', v_headline, v_cta);
  v_scan := public.fn_ad_studio_claim_scan(v_text);
  v_safe := (jsonb_array_length(v_scan) = 0);

  v_ops := jsonb_build_array(
    jsonb_build_object('step',1,'op','canvas',
      'detail','Create 1080x1350 (4:5) portrait canvas, brand-neutral background (#F5F5F4).'),
    jsonb_build_object('step',2,'op','composite_product_hero',
      'detail','Place the generated product hero (1024x1024) centered, scaled to ~92% width, preserving product identity from the authoritative Product Card image; do NOT alter product model/shape/controls/logo/features/SKU.'),
    jsonb_build_object('step',3,'op','headline_band',
      'detail','Top safe band: draw headline text, wrapped, high-contrast, within top 18% safe area.',
      'text', v_headline),
    jsonb_build_object('step',4,'op','cta_pill',
      'detail','Bottom pill button with CTA label, within bottom 14% safe area.',
      'text', v_cta),
    jsonb_build_object('step',5,'op','export',
      'detail','Export PNG 1080x1350 to the private bucket pulse-generated-media; delivery via signed URL only.'));

  RETURN jsonb_build_object('status','ok','job_id',p_job_id,
    'renderer','STRATELOQ_CREATIVE_STUDIO',
    'compositor','n8n Edit Image / ImageMagick (internal; provider-invisible to customers)',
    'platform','META','placement','INSTAGRAM_FEED / META_FEED',
    'delivery_format', jsonb_build_object('width',1080,'height',1350,'aspect_ratio','4:5'),
    'base_generation', jsonb_build_object('size','1024x1024','aspect_ratio','1:1','note','square hero generated once, composited onto the 4:5 canvas'),
    'text_elements', jsonb_build_object('headline',v_headline,'cta',v_cta,
      'source','angle copy only (evidence-grounded); no price/discount/scarcity/rating/testimonial/guarantee/performance text'),
    'claim_scan', v_scan, 'composed_text_claim_safe', v_safe,
    'ops', v_ops,
    'identity_authority', j.provenance->'product_identity',
    'human_review_required', true, 'launch_safe', false,
    'note', CASE WHEN v_safe THEN 'Composition spec is claim-safe and ready for the (founder-gated) generate+compose step.'
                 ELSE 'Composed text FLAGGED by claim scan — must be corrected before any render.' END);
END; $fn$;

-- ---------------------------------------------------------------------------
-- 3. End-to-end orchestrator — Intelligence -> MD brief -> 3 hypotheses ->
--    select 1 -> Creative Studio job -> claim+lineage+cost gate -> composition
--    spec -> Creative Production Agent view. STOPS at the cost gate. NO paid call.
--    Request: { brief: {...MD brief input...}, product_id, decision_id, market, is_fixture }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_static_creative_prepare(p_tenant uuid, p_request jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_product uuid; v_decision uuid; v_market text; v_fixture boolean;
  v_lin jsonb; v_lstate text; v_brief_input jsonb; v_brief_id uuid;
  v_angles jsonb; v_sel jsonb; v_sel_angle uuid; v_job jsonb; v_job_id uuid;
  v_prep jsonb; v_comp jsonb; v_cpr jsonb; v_caps jsonb; v_est numeric; v_prov_cfg jsonb;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('status','tenant_required'); END IF;
  v_product := nullif(p_request->>'product_id','')::uuid;
  v_decision := nullif(p_request->>'decision_id','')::uuid;
  v_market := upper(coalesce(p_request->>'market',''));
  v_fixture := coalesce((p_request->>'is_fixture')::boolean,false);

  -- (a) CANONICAL lineage is mandatory
  v_lin := public.fn_ad_studio_resolve_lineage(p_tenant, v_product, v_decision, v_market);
  v_lstate := v_lin->>'lineage_state';
  IF v_lstate <> 'CANONICAL' THEN
    RETURN jsonb_build_object('status','blocked','verdict','STATIC_CREATIVE_BLOCKED',
      'reason','CANONICAL product lineage required (got '||coalesce(v_lstate,'NULL')||')','lineage',v_lin);
  END IF;

  -- (b) Marketing Director brief (real product facts supplied by caller; product_id/decision_id/
  --     market/product_assets are pinned to the canonical entity here).
  v_brief_input := coalesce(p_request->'brief','{}'::jsonb)
    || jsonb_build_object('product_id',v_product::text,'decision_id',v_decision::text,'market',v_market);
  IF NOT (v_brief_input ? 'product_assets') OR jsonb_array_length(coalesce(v_brief_input->'product_assets','[]'::jsonb))=0 THEN
    RETURN jsonb_build_object('status','blocked','verdict','STATIC_CREATIVE_BLOCKED',
      'reason','no authoritative Product Card image supplied (product_assets empty)');
  END IF;
  v_brief_id := public.fn_ad_studio_build_brief(p_tenant, v_brief_input, v_fixture);

  -- (c) 3 distinct evidence-grounded hypotheses
  v_angles := public.fn_ad_studio_generate_angles(v_brief_id);

  -- (d) select ONE to test (never a winner claim)
  v_sel := public.fn_ad_studio_select_test_angle(v_brief_id);
  v_sel_angle := nullif(v_sel->>'selected_angle_id','')::uuid;
  IF v_sel_angle IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','no_angle_selected','angles',v_angles);
  END IF;

  -- (e) Creative Studio image job for the selected hypothesis
  v_job := public.fn_media_create_image_job(p_tenant, v_sel_angle);
  v_job_id := nullif(v_job->>'job_id','')::uuid;
  IF v_job_id IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','image_job_not_created','detail',v_job);
  END IF;

  -- (f) claim gate + CANONICAL lineage + cost gate (pre-flight; NO paid call)
  v_prep := public.fn_media_prepare_image_job(v_job_id, p_tenant);
  IF (v_prep->>'status') <> 'READY_TO_DISPATCH' THEN
    RETURN jsonb_build_object('status','blocked','verdict','STATIC_CREATIVE_BLOCKED',
      'reason','pre-flight did not reach READY_TO_DISPATCH','preflight',v_prep,
      'brief_id',v_brief_id,'selected_angle_id',v_sel_angle,'job_id',v_job_id);
  END IF;

  -- (g) deterministic composition spec (META/IG 1080x1350)
  v_comp := public.fn_ad_compile_static_composition(v_job_id);

  -- (h) Creative Production Agent view (provider-invisible)
  v_cpr := public.fn_creative_production_request(p_tenant, jsonb_build_object(
    'creative_type','STATIC','platform','META','asset_class','PRODUCT','hypothesis',
    (SELECT angle_type FROM public.ad_studio_angles WHERE id=v_sel_angle),
    'product_id',v_product::text,'decision_id',v_decision::text,'market',v_market));

  v_est := (v_prep->>'estimated_cost_usd')::numeric;

  RETURN jsonb_build_object('status','ok','verdict','READY_FOR_FOUNDER_STATIC_GENERATION_APPROVAL',
    'contract','static_creative_end_to_end_v1_015k',
    'tenant',p_tenant,'lineage',v_lin,'lineage_state',v_lstate,
    'brief_id',v_brief_id,'hypotheses',v_sel->'hypotheses','selection',v_sel,
    'selected_angle_id',v_sel_angle,'job_id',v_job_id,'preflight',v_prep,'composition',v_comp,
    'creative_production_agent',v_cpr,
    'cost_gate', jsonb_build_object(
      'state','AWAITING_FOUNDER_AUTHORIZATION','paid_call_made',false,
      'provider_internal','OPENAI_GPT_IMAGE','provider_customer_visible','STRATELOQ_CREATIVE_STUDIO',
      'operation','IMAGE_EDIT_FROM_PRODUCT_ASSET','model','gpt-image-1','provider_call_count',1,
      'estimated_cost_usd',v_est,'max_cost_usd',0.04,'currency','USD'),
    'quality', jsonb_build_object('reviewer','fn_creative_quality_review(IMAGE_ASSET, <asset_id>) after generation',
      'asset_state_after_generation','IN_REVIEW','launch_safe',false,'human_approval','mandatory'),
    'note','End-to-end static pipeline assembled on real canonical intelligence and STOPPED at the paid-generation cost gate. No generation, no paid call, no dispatch. Founder authorization required before the single gpt-image-1 call.');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 4. Selftest — fixture-only, self-cleaning, marker [[stx]], refs stxsrc://
--    Proves: CANONICAL lineage, exactly 3 hypotheses, exactly 1 SELECTED_FOR_TEST,
--    READY_TO_DISPATCH cost gate reached WITHOUT any paid call, composition claim-safe,
--    verdict READY_FOR_FOUNDER_STATIC_GENERATION_APPROVAL, asset never auto-launch-safe.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ad_static_creative_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_tenant uuid; v_product uuid; v_job_id uuid; v_res jsonb;
  v_pass int := 0; v_fail int := 0; v_checks jsonb := '[]'::jsonb;
  v_sel_count int; v_held_count int; v_jstatus text; v_jout jsonb; v_jactual numeric;
BEGIN
  -- an existing FK-valid owner (fixtures marked [[stx]] and fully cleaned up below)
  SELECT user_id INTO v_tenant FROM public.commerce_products WHERE user_id IS NOT NULL LIMIT 1;
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('suite','ad_static_creative_end_to_end','pass',0,'fail',1,'all_pass',false,'checks','["no_seed_user"]'::jsonb); END IF;

  -- clean any prior [[stx]] fixtures for this owner
  DELETE FROM public.media_job_costs WHERE job_id IN (SELECT id FROM public.media_image_jobs WHERE tenant_id=v_tenant
    AND angle_id IN (SELECT id FROM public.ad_studio_angles WHERE brief_id IN
      (SELECT id FROM public.ad_studio_briefs WHERE tenant_id=v_tenant AND product_name LIKE '%[[stx]]%')));
  DELETE FROM public.media_image_jobs WHERE tenant_id=v_tenant
    AND angle_id IN (SELECT id FROM public.ad_studio_angles WHERE brief_id IN
      (SELECT id FROM public.ad_studio_briefs WHERE tenant_id=v_tenant AND product_name LIKE '%[[stx]]%'));
  DELETE FROM public.ad_studio_angles WHERE brief_id IN
    (SELECT id FROM public.ad_studio_briefs WHERE tenant_id=v_tenant AND product_name LIKE '%[[stx]]%');
  DELETE FROM public.ad_studio_briefs WHERE tenant_id=v_tenant AND product_name LIKE '%[[stx]]%';
  DELETE FROM public.commerce_products WHERE user_id=v_tenant AND title LIKE '%[[stx]]%';

  INSERT INTO public.commerce_products(id, user_id, product_identity, identity_basis, title, category, source_store, product_role, visibility, provenance)
  VALUES (gen_random_uuid(), v_tenant, 'stx-fixture', 'normalized_name', 'selftest nightlight [[stx]]', 'nightlight projector', 'selftest', 'candidate', 'TENANT_PRIVATE', '{"product":"FIXTURE"}'::jsonb)
  RETURNING id INTO v_product;

  v_res := public.fn_ad_static_creative_prepare(v_tenant, jsonb_build_object(
    'product_id', v_product::text, 'market','GB', 'is_fixture', true,
    'brief', jsonb_build_object(
      'product_name','selftest nightlight [[stx]]',
      'product_description','a kids nightlight projector [[stx]] fixture',
      'problem_solved','settling kids at bedtime',
      'product_features', jsonb_build_array('projects stars','adjustable brightness'),
      'market','GB','market_currency','GBP',
      'product_assets', jsonb_build_array('stxsrc://cjdropshipping/selftest-hero.jpeg'),
      'destination_url','https://example.invalid/stx')));
  v_job_id := nullif(v_res->>'job_id','')::uuid;

  IF (v_res->>'verdict')='READY_FOR_FOUNDER_STATIC_GENERATION_APPROVAL' THEN v_pass:=v_pass+1;
    v_checks:=v_checks||jsonb_build_object('verdict_ready',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('verdict_ready',false,'got',v_res->>'verdict','detail',v_res); END IF;

  IF (v_res->>'lineage_state')='CANONICAL' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('canonical',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('canonical',false); END IF;

  IF jsonb_array_length(coalesce(v_res->'hypotheses','[]'::jsonb))=3 THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('three_hypotheses',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('three_hypotheses',false,'n',jsonb_array_length(coalesce(v_res->'hypotheses','[]'::jsonb))); END IF;

  SELECT count(*) FILTER (WHERE test_selection='SELECTED_FOR_TEST'),
         count(*) FILTER (WHERE test_selection='HELD_FOR_FUTURE_TEST')
    INTO v_sel_count, v_held_count
  FROM public.ad_studio_angles WHERE brief_id=(v_res->>'brief_id')::uuid;
  IF v_sel_count=1 AND v_held_count=2 THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('one_selected',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('one_selected',false,'selected',v_sel_count,'held',v_held_count); END IF;

  IF (v_res->'preflight'->>'status')='READY_TO_DISPATCH'
     AND (v_res->'cost_gate'->>'paid_call_made')='false' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('cost_gate_no_paid_call',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('cost_gate_no_paid_call',false); END IF;

  IF (v_res->'preflight'->>'production_launch_eligible')='true'
     AND (v_res->'quality'->>'launch_safe')='false' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('eligible_but_not_launch_safe',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('eligible_but_not_launch_safe',false); END IF;

  IF (v_res->'composition'->>'composed_text_claim_safe')='true'
     AND (v_res->'composition'->'delivery_format'->>'width')='1080'
     AND (v_res->'composition'->'delivery_format'->>'height')='1350' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('composition_claim_safe_portrait',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('composition_claim_safe_portrait',false); END IF;

  IF (v_res->'cost_gate'->>'estimated_cost_usd')::numeric <= (v_res->'cost_gate'->>'max_cost_usd')::numeric THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('cost_within_cap',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('cost_within_cap',false); END IF;

  -- job-scoped: nothing generated/dispatched (no output asset, no actual cost)
  SELECT status, output_asset_refs, actual_cost INTO v_jstatus, v_jout, v_jactual
    FROM public.media_image_jobs WHERE id=v_job_id;
  IF v_jstatus='READY_TO_DISPATCH' AND coalesce(jsonb_array_length(coalesce(v_jout,'[]'::jsonb)),0)=0 AND v_jactual IS NULL THEN
    v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('nothing_generated_or_dispatched',true);
  ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('nothing_generated_or_dispatched',false,'status',v_jstatus); END IF;

  DECLARE v_blk jsonb; BEGIN
    v_blk := public.fn_ad_static_creative_prepare(v_tenant, jsonb_build_object(
      'product_id', gen_random_uuid()::text, 'market','GB','is_fixture',true,
      'brief', jsonb_build_object('product_name','x [[stx]]','product_assets', jsonb_build_array('stxsrc://x'))));
    IF (v_blk->>'verdict')='STATIC_CREATIVE_BLOCKED' THEN v_pass:=v_pass+1; v_checks:=v_checks||jsonb_build_object('blocked_when_not_canonical',true);
    ELSE v_fail:=v_fail+1; v_checks:=v_checks||jsonb_build_object('blocked_when_not_canonical',false,'got',v_blk->>'verdict'); END IF;
  END;

  -- cleanup
  DELETE FROM public.media_job_costs WHERE job_id IN (SELECT id FROM public.media_image_jobs WHERE tenant_id=v_tenant
    AND angle_id IN (SELECT id FROM public.ad_studio_angles WHERE brief_id IN
      (SELECT id FROM public.ad_studio_briefs WHERE tenant_id=v_tenant AND product_name LIKE '%[[stx]]%')));
  DELETE FROM public.media_image_jobs WHERE tenant_id=v_tenant
    AND angle_id IN (SELECT id FROM public.ad_studio_angles WHERE brief_id IN
      (SELECT id FROM public.ad_studio_briefs WHERE tenant_id=v_tenant AND product_name LIKE '%[[stx]]%'));
  DELETE FROM public.ad_studio_angles WHERE brief_id IN
    (SELECT id FROM public.ad_studio_briefs WHERE tenant_id=v_tenant AND product_name LIKE '%[[stx]]%');
  DELETE FROM public.ad_studio_briefs WHERE tenant_id=v_tenant AND product_name LIKE '%[[stx]]%';
  DELETE FROM public.commerce_products WHERE user_id=v_tenant AND title LIKE '%[[stx]]%';

  RETURN jsonb_build_object('suite','ad_static_creative_end_to_end','pass',v_pass,'fail',v_fail,
    'all_pass',(v_fail=0),'checks',v_checks);
END; $fn$;

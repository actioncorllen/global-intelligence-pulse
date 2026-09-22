-- ============================================================================
-- mig_281_creative_production_agent.sql
-- STRATELOQ-AI-AD-CREATIVE-STUDIO-015J — Build-first internal Creative Production Agent.
-- Governed by docs/STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md (LOCKED).
--
-- FREE, INTERNAL, ADDITIVE orchestration foundation beneath the existing n8n
-- AI Marketing Director (YDhtr1EPQRUv5wdm) — the Marketing Director stays the
-- orchestration brain (WHY/WHEN/WHERE); the Creative Production Agent decides HOW
-- to produce a creative by routing to EXISTING Creative Studio tools. NO paid
-- provider, NO subscription, NO generation, NO new account. Provider-invisible.
--
-- Contracts: (1) capability map (the audit as live machine-readable truth),
-- (2) Creative Production Agent request router (Marketing Director -> Creative
-- Studio), (3) Creative Quality Reviewer (machine gates PASS/FAIL; aesthetic gates
-- REVIEW_REQUIRED; human approval mandatory). No composition backend reactivated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Capability map — the 015J audit encoded as live truth (so future sessions
--    read reality from the DB, not guess). Provider-invisible.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_creative_production_capabilities()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_img_provider text; v_video_provider text; v_comp text; v_brand int;
BEGIN
  v_img_provider := public.fn_media_provider_for('IMAGE');
  v_video_provider := public.fn_media_provider_for('VIDEO');
  v_comp := public.fn_media_composition_backend();
  SELECT count(*) INTO v_brand FROM public.member_business_dna;
  RETURN jsonb_build_object(
    'contract','creative_production_capabilities_v1_015j','renderer','STRATELOQ_CREATIVE_STUDIO',
    'static', jsonb_build_object(
      'product_ads','AVAILABLE_NOW','benefit_led','AVAILABLE_NOW','problem_solution','AVAILABLE_NOW',
      'social_posts','AVAILABLE_NOW','story_reel_covers','AVAILABLE_NOW','carousel_cards','AVAILABLE_NOW',
      'platform_variants','AVAILABLE_NOW',
      'basis', jsonb_build_object('image_generation', v_img_provider, 'image_compositor','n8n Edit Image / ImageMagick (captions, canvas, logo/CTA overlays, 9:16)',
        'brand_dna_rows', v_brand, 'claim_safety','fn_ad_studio_claim_scan','lineage','fn_ad_studio_resolve_lineage')),
    'video', jsonb_build_object(
      'A_storyboard','AVAILABLE_NOW',
      'B_scene_plan','AVAILABLE_NOW',
      'F_captions_spec','AVAILABLE_NOW',
      'J_cta_end_card_spec','AVAILABLE_NOW',
      'G_transitions_spec','AVAILABLE_NOW',
      'C_product_image_motion','MISSING_EXECUTION_RUNTIME',
      'E_screen_recording_scenes','MISSING_EXECUTION_RUNTIME',
      'K_assembly','MISSING_EXECUTION_RUNTIME',
      'L_encoding_export','MISSING_EXECUTION_RUNTIME',
      'D_generated_motion','REQUIRES_EXTERNAL_MODEL',
      'H_voiceover','OPTIONAL_FOR_BETA (requires paid TTS or self-hosted TTS)',
      'I_music_sfx','OPTIONAL_FOR_BETA (requires paid music model or licensed library)',
      'missing_execution_runtime','self-hosted FFmpeg/Remotion render worker (open-source, Strateloq-controlled) — NOT a paid creative SaaS; deferred (BETA_COMPOSITION_DEFERRED_BY_FOUNDER)',
      'external_model','image->video foundation model (e.g. Veo, visible-but-paid per 015J; MiniMax/Wan) — paid, founder-gated',
      'composition_backend', coalesce(v_comp,'NONE (deferred)'),'video_provider_entitled', (v_video_provider IS NOT NULL)),
    'quality', jsonb_build_object('machine_gates','automated','aesthetic_gates','REVIEW_REQUIRED (human)','human_approval','mandatory'),
    'note','Static advertising creative is producible internally NOW with existing entitled infra. Finished VIDEO needs a self-hosted render runtime (deferred) and/or a paid video model (founder-gated). Provider names are internal; customers never see them.');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 2. Creative Quality Reviewer — machine-checkable gates from real signals;
--    aesthetic gates REVIEW_REQUIRED; never fabricate an aesthetic PASS; human
--    approval always required (standard §14/§16/§19). Wraps fn_media_quality_gates.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_creative_quality_review(p_kind text, p_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE g jsonb; m public.media_assets%rowtype; v_gates jsonb; v_any_fail boolean;
BEGIN
  IF p_kind='VIDEO_JOB' THEN
    g := public.fn_media_quality_gates(p_id);
    IF (g->>'status') <> 'ok' THEN RETURN g; END IF;
    v_gates := g->'gates'; v_any_fail := (g->>'any_fail')::boolean;
  ELSIF p_kind='IMAGE_ASSET' THEN
    SELECT * INTO m FROM public.media_assets WHERE id=p_id AND media_type='IMAGE';
    IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
    v_gates := jsonb_build_object(
      'PRODUCT_IDENTITY', CASE WHEN m.identity_state='IDENTITY_CLEARED' THEN 'PASS' ELSE 'REVIEW_REQUIRED' END,
      'CLAIM_SAFETY', 'REVIEW_REQUIRED',
      'PLATFORM_FORMAT', CASE WHEN coalesce(m.aspect_ratio,'')<>'' THEN 'PASS' ELSE 'NOT_EVALUATED' END,
      'BRAND_COMPLIANCE', CASE WHEN EXISTS(SELECT 1 FROM public.member_business_dna d WHERE d.user_id=m.tenant_id) THEN 'REVIEW_REQUIRED' ELSE 'NOT_APPLICABLE' END,
      'VISUAL_QUALITY','REVIEW_REQUIRED','AI_ARTIFACTS','REVIEW_REQUIRED','COMPOSITION','REVIEW_REQUIRED',
      'PRODUCT_VISIBILITY','REVIEW_REQUIRED','COMMERCIAL_USEFULNESS','REVIEW_REQUIRED');
    v_any_fail := EXISTS(SELECT 1 FROM jsonb_each_text(v_gates) x WHERE x.value='FAIL');
  ELSE
    RETURN jsonb_build_object('status','invalid_kind','note','p_kind must be VIDEO_JOB or IMAGE_ASSET');
  END IF;
  RETURN jsonb_build_object('status','ok','kind',p_kind,'id',p_id,'gates',v_gates,
    'machine_gates_any_fail', v_any_fail,
    'aesthetic_pending', (SELECT count(*) FROM jsonb_each_text(v_gates) x WHERE x.value='REVIEW_REQUIRED'),
    'human_approval_required', true, 'launch_safe', false,
    'note','A rendered/generated asset is NOT a PASS on success (standard §2/§23). Aesthetic gates stay REVIEW_REQUIRED until a legitimate evaluator exists; launch-safe additionally requires canonical lineage + identity cleared + Product Decision + human approval.');
END; $fn$;

-- ---------------------------------------------------------------------------
-- 3. Creative Production Agent request router: Marketing Director -> Creative
--    Studio. Decides HOW to produce, routes to existing tools, returns readiness
--    + candidate route + quality contract. NO generation, NO paid call. The
--    Marketing Director keeps orchestration; this never launches a campaign.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_creative_production_request(p_tenant uuid, p_request jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_type text; v_platform text; v_hyp text; v_asset_class text; v_product uuid; v_decision uuid; v_market text;
  v_lin jsonb; v_lstate text; v_caps jsonb; v_route jsonb; v_ready text; v_brand_path boolean;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('status','tenant_required'); END IF;
  v_type := upper(coalesce(p_request->>'creative_type','STATIC'));            -- STATIC | VIDEO
  v_platform := coalesce(p_request->>'platform','META');
  v_hyp := coalesce(p_request->>'hypothesis','PROBLEM_SOLUTION');
  v_asset_class := coalesce(p_request->>'asset_class','PRODUCT');             -- PRODUCT | STRATELOQ_BRAND
  v_brand_path := (v_asset_class='STRATELOQ_BRAND');
  v_product := nullif(p_request->>'product_id','')::uuid;
  v_decision := nullif(p_request->>'decision_id','')::uuid;
  v_market := p_request->>'market';
  v_caps := public.fn_creative_production_capabilities();

  -- lineage (customer product path only; brand path uses Strateloq assets, not commerce lineage)
  IF v_brand_path THEN
    v_lstate := 'STRATELOQ_BRAND_ASSET';
    v_lin := jsonb_build_object('asset_authority','strateloq_brand (screenshots/UI/logo/approved assets)');
  ELSE
    v_lin := public.fn_ad_studio_resolve_lineage(p_tenant, v_product, v_decision, v_market);
    v_lstate := v_lin->>'lineage_state';
  END IF;

  IF v_type='STATIC' THEN
    v_ready := 'AVAILABLE_NOW';
    v_route := jsonb_build_object('pipeline','fn_ad_studio_build_brief -> fn_ad_studio_generate_angles -> fn_media_create_image_job -> fn_media_prepare_image_job (cost-gated) -> [founder-approved dispatch] -> fn_media_complete_image_real -> fn_creative_quality_review(IMAGE_ASSET)',
      'renderer','STRATELOQ_CREATIVE_STUDIO','compositor','n8n Edit Image (captions/branding/9:16 variants)','generation','gpt-image-1 (entitled)');
  ELSE
    v_route := jsonb_build_object('pipeline','fn_ad_studio_build_brief -> fn_ad_studio_generate_angles -> fn_media_create_video_job (storyboard/scenes) -> fn_ad_build_production_plan -> fn_ad_compile_render_spec -> [render backend / generated clips] -> fn_creative_quality_review(VIDEO_JOB)',
      'renderer','STRATELOQ_CREATIVE_STUDIO','required_capability','VIDEO_IMAGE_TO_VIDEO (generative scenes only)',
      'blockers', jsonb_build_array('render runtime deferred (self-hosted FFmpeg/Remotion)','generated motion needs a paid video model (founder-gated)'));
    v_ready := 'PLAN_READY_RENDER_DEFERRED';
  END IF;

  RETURN jsonb_build_object('status','ok','contract','creative_production_request_v1_015j',
    'tenant', p_tenant, 'creative_type', v_type, 'platform', v_platform, 'creative_hypothesis', v_hyp,
    'asset_class', v_asset_class, 'lineage_state', v_lstate, 'lineage', v_lin,
    'readiness', v_ready, 'route', v_route,
    'quality_contract','fn_creative_quality_review (machine gates automated; aesthetic REVIEW_REQUIRED; human approval mandatory)',
    'launch','NEVER auto-launched — returns candidates + lineage + quality state to the Marketing Director for a campaign draft + human approval',
    'capabilities', v_caps->v_type::text,
    'note','Creative Production Agent decides HOW; the AI Marketing Director keeps WHY/WHEN/WHERE. Provider-invisible. No generation performed in this planning call.');
END; $fn$;

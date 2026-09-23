-- ============================================================================
-- mig_289_creative_production_contract.sql
-- STRATELOQ-015U — Productionize the Creative Studio (015K–015T) as a GENERIC
-- contract the Creative Production Agent can invoke for any product/business
-- and for Strateloq brand marketing. No proof-specific hardcoding. No new
-- generation. Native FFmpeg compositor remains the composition backend.
-- Idempotent. Preserves the static/video systems and all identity/claim gates.
-- ============================================================================

-- Generic creative production request (both source modes).
CREATE TABLE IF NOT EXISTS public.creative_production_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  source_mode text NOT NULL,          -- CUSTOMER_PRODUCT | STRATELOQ_BRAND
  product_id uuid,                    -- required for CUSTOMER_PRODUCT
  decision_id uuid,
  market text,
  objective text,
  platform text,                      -- META | INSTAGRAM | TIKTOK | LINKEDIN
  creative_type text,                 -- COPY_ONLY | STATIC | VIDEO | CAROUSEL
  hypothesis jsonb DEFAULT '{}'::jsonb,
  brand_dna jsonb DEFAULT '{}'::jsonb,
  available_assets jsonb DEFAULT '[]'::jsonb,
  budget jsonb DEFAULT '{}'::jsonb,   -- {max_generation_calls,max_generation_cost,provider,model}
  generation_authorized boolean DEFAULT false,
  human_approval_required boolean DEFAULT true,
  status text DEFAULT 'REQUESTED',
  created_at timestamptz DEFAULT now()
);
ALTER TABLE public.creative_production_requests ENABLE ROW LEVEL SECURITY; -- deny-by-default

-- Validate + (optionally) persist a generic request. Pure when p_persist=false.
CREATE OR REPLACE FUNCTION public.fn_creative_production_request(
  p_tenant uuid, p_source_mode text, p_product_id uuid, p_decision_id uuid,
  p_market text, p_objective text, p_platform text, p_creative_type text,
  p_hypothesis jsonb DEFAULT '{}'::jsonb, p_brand_dna jsonb DEFAULT '{}'::jsonb,
  p_available_assets jsonb DEFAULT '[]'::jsonb, p_budget jsonb DEFAULT '{}'::jsonb,
  p_generation_authorized boolean DEFAULT false, p_human_approval_required boolean DEFAULT true,
  p_persist boolean DEFAULT true)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_err text[] := '{}'; v_id uuid; v_asset_policy text;
BEGIN
  IF p_source_mode NOT IN ('CUSTOMER_PRODUCT','STRATELOQ_BRAND') THEN v_err := array_append(v_err,'invalid_source_mode'); END IF;
  IF coalesce(p_creative_type,'') NOT IN ('COPY_ONLY','STATIC','VIDEO','CAROUSEL') THEN v_err := array_append(v_err,'invalid_creative_type'); END IF;
  IF coalesce(p_platform,'') NOT IN ('META','INSTAGRAM','TIKTOK','LINKEDIN') THEN v_err := array_append(v_err,'invalid_platform'); END IF;
  IF p_source_mode='CUSTOMER_PRODUCT' AND p_product_id IS NULL THEN v_err := array_append(v_err,'customer_product_requires_product_id'); END IF;
  v_asset_policy := CASE p_source_mode
    WHEN 'CUSTOMER_PRODUCT' THEN 'AUTHORITATIVE_PRODUCT_CARD_EXACT_SKU (never marketplace/competitor/web)'
    ELSE 'AUTHORITATIVE_STRATELOQ_BRAND (real screenshots/UI recordings/approved logo/Brand DNA; never fabricate UI where real exists)' END;

  IF array_length(v_err,1) IS NOT NULL THEN
    RETURN jsonb_build_object('status','rejected','errors',to_jsonb(v_err));
  END IF;

  IF p_persist THEN
    INSERT INTO public.creative_production_requests(tenant_id,source_mode,product_id,decision_id,market,objective,
      platform,creative_type,hypothesis,brand_dna,available_assets,budget,generation_authorized,human_approval_required)
    VALUES (p_tenant,p_source_mode,p_product_id,p_decision_id,p_market,p_objective,p_platform,p_creative_type,
      p_hypothesis,p_brand_dna,p_available_assets,p_budget,p_generation_authorized,p_human_approval_required)
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('status','accepted','request_id',v_id,
    'tenant_id',p_tenant,'source_mode',p_source_mode,'product_id',p_product_id,'market',p_market,
    'objective',p_objective,'platform',p_platform,'creative_type',p_creative_type,
    'authoritative_asset_policy',v_asset_policy,
    'generation_authorized',p_generation_authorized,'human_approval_required',p_human_approval_required,
    'budget',p_budget,'composition_backend','STRATELOQ_VIDEO_COMPOSITION');
END; $fn$;

-- Platform adaptation contract (never a blind resize).
CREATE OR REPLACE FUNCTION public.fn_creative_platform_spec(p_platform text, p_creative_type text DEFAULT 'VIDEO')
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $fn$
  SELECT CASE p_platform
    WHEN 'TIKTOK' THEN jsonb_build_object('aspect','9:16','alt_aspects',jsonb_build_array(),'duration_target_s',jsonb_build_array(9,30),'safe_zones','bottom 16% + right 12% (UI chrome)','copy_length_max',60,'cta_required',true,'pacing','fast')
    WHEN 'INSTAGRAM' THEN jsonb_build_object('aspect','9:16','alt_aspects',jsonb_build_array('4:5','1:1'),'duration_target_s',jsonb_build_array(7,30),'safe_zones','bottom 14%','copy_length_max',80,'cta_required',true,'pacing','medium')
    WHEN 'META' THEN jsonb_build_object('aspect','9:16','alt_aspects',jsonb_build_array('4:5','1:1'),'duration_target_s',jsonb_build_array(7,30),'safe_zones','bottom 14%','copy_length_max',100,'cta_required',true,'pacing','medium')
    WHEN 'LINKEDIN' THEN jsonb_build_object('aspect','1:1','alt_aspects',jsonb_build_array('4:5'),'duration_target_s',jsonb_build_array(10,30),'safe_zones','bottom 10%','copy_length_max',140,'cta_required',true,'pacing','measured','tone','professional')
    ELSE jsonb_build_object('status','unknown_platform') END;
$fn$;

-- Bounded generation authorization gate. Never exceed authorization.
CREATE OR REPLACE FUNCTION public.fn_creative_generation_cost_gate(
  p_budget jsonb, p_calls_so_far int, p_cost_so_far numeric, p_next_call_cost numeric)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $fn$
DECLARE v_max_calls int := coalesce((p_budget->>'max_generation_calls')::int, 0);
  v_max_cost numeric := coalesce((p_budget->>'max_generation_cost')::numeric, 0);
  v_allow boolean; v_reason text;
BEGIN
  IF p_calls_so_far + 1 > v_max_calls THEN v_allow:=false; v_reason:='max_generation_calls_exceeded';
  ELSIF p_cost_so_far + p_next_call_cost > v_max_cost THEN v_allow:=false; v_reason:='max_generation_cost_exceeded';
  ELSE v_allow:=true; v_reason:='within_authorization'; END IF;
  RETURN jsonb_build_object('allow',v_allow,'reason',v_reason,
    'remaining_calls',greatest(0, v_max_calls - p_calls_so_far),
    'remaining_cost',round(greatest(0, v_max_cost - p_cost_so_far),4),
    'authorized_provider',p_budget->>'provider','authorized_model',p_budget->>'model');
END; $fn$;

-- Per-scene identity policy (permanent product-identity rule).
CREATE OR REPLACE FUNCTION public.fn_creative_scene_identity_policy(
  p_source_mode text, p_scene_type text, p_contains_product boolean, p_is_generative boolean)
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $fn$
  SELECT CASE
    WHEN p_source_mode='CUSTOMER_PRODUCT' AND p_is_generative AND p_contains_product
      THEN jsonb_build_object('identity_state','IDENTITY_REVIEW_REQUIRED','rule','generative device -> human review; not authoritative pixels')
    WHEN p_source_mode='CUSTOMER_PRODUCT' AND NOT p_is_generative AND p_contains_product
      THEN jsonb_build_object('identity_state','AUTHORITATIVE_PRODUCT_CARD_PIXELS','rule','deterministic exact-SKU pixels; no redraw')
    WHEN p_is_generative AND NOT p_contains_product
      THEN jsonb_build_object('identity_state','NO_DEVICE_IDENTITY_NA','rule','environment/supporting only; no product shown')
    WHEN p_source_mode='STRATELOQ_BRAND' AND NOT p_is_generative
      THEN jsonb_build_object('identity_state','AUTHORITATIVE_STRATELOQ_ASSET','rule','real screenshots/UI/logo; never fabricate UI where real exists')
    ELSE jsonb_build_object('identity_state','REVIEW_REQUIRED','rule','default human review')
  END;
$fn$;

-- Zero-cost DRY-RUN production plan: request + data-driven storyboard -> plan.
-- Pure/no side effects. Proves genericity end-to-end without rendering or paid calls.
CREATE OR REPLACE FUNCTION public.fn_creative_production_plan(p_request jsonb, p_storyboard jsonb)
 RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO ''
AS $fn$
DECLARE s jsonb; v_scenes jsonb := '[]'::jsonb; v_gen int := 0; v_est numeric := 0;
  v_src text := p_request->>'source_mode'; v_gate jsonb; v_ord int := 0;
  v_gen_cost numeric;
BEGIN
  FOR s IN SELECT * FROM jsonb_array_elements(coalesce(p_storyboard->'scenes','[]'::jsonb)) LOOP
    v_ord := v_ord + 1;
    IF coalesce((s->>'is_generative')::boolean,false) THEN
      v_gen := v_gen + 1; v_est := v_est + coalesce((s->>'est_gen_cost')::numeric, 1.20);
    END IF;
    v_scenes := v_scenes || jsonb_build_object(
      'order', coalesce((s->>'scene_order')::int, v_ord),
      'scene_type', s->>'scene_type',
      'source', s->>'source_type',
      'identity', public.fn_creative_scene_identity_policy(v_src, s->>'scene_type',
                    coalesce((s->>'contains_product')::boolean,false), coalesce((s->>'is_generative')::boolean,false)));
  END LOOP;

  v_gen_cost := v_est;
  v_gate := public.fn_creative_generation_cost_gate(coalesce(p_request->'budget','{}'::jsonb), 0, 0, v_gen_cost);

  RETURN jsonb_build_object(
    'status','PLAN_READY',
    'dry_run', true,
    'source_mode', v_src,
    'platform_spec', public.fn_creative_platform_spec(p_request->>'platform', p_request->>'creative_type'),
    'scenes', v_scenes,
    'composition_backend','STRATELOQ_VIDEO_COMPOSITION',
    'planned_generation_calls', v_gen,
    'planned_generation_cost_est', round(v_gen_cost,4),
    'generation_cost_gate', v_gate,
    'generation_within_authorization', (v_gen = 0) OR ((p_request->>'generation_authorized')='true' AND (v_gate->>'allow')='true'),
    'cost_tracking', jsonb_build_object('AI_GENERATION_COST', round(v_gen_cost,4), 'COMPOSITION_EXTERNAL_COST', 0.00, 'AUDIO_API_COST', 0.00, 'TOTAL_EXTERNAL_COST', round(v_gen_cost,4)),
    'quality_gates', jsonb_build_array('PRODUCT_IDENTITY','VISUAL_QUALITY','AI_ARTIFACTS','HOOK_QUALITY','STORY_COHERENCE','PRODUCT_VISIBILITY','PACING','COMPOSITION','CAPTION_READABILITY','BRAND_COMPLIANCE','CLAIM_SAFETY','CTA_CLARITY','PLATFORM_FORMAT','COMMERCIAL_USEFULNESS'),
    'quality_gate_default','REVIEW_REQUIRED (subjective gates; provider success != creative success)',
    'human_approval_required', coalesce((p_request->>'human_approval_required')::boolean, true),
    'campaign_handoff', jsonb_build_object('publish', false, 'activation', false, 'contract','Marketing Director -> Campaign Builder -> channel execution (future)'));
END; $fn$;

-- Stable campaign-handoff contract for an APPROVED asset. publish/activation always false here.
CREATE OR REPLACE FUNCTION public.fn_creative_campaign_handoff(p_asset_id uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO ''
AS $fn$
DECLARE a record;
BEGIN
  SELECT id, tenant_id, product_id, country_code, media_type, approval_state, identity_state, is_launch_safe, storage_ref
    INTO a FROM public.media_assets WHERE id=p_asset_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','asset_not_found'); END IF;
  RETURN jsonb_build_object('status','ok','asset_id',a.id,'tenant_id',a.tenant_id,'product_id',a.product_id,
    'market',a.country_code,'media_type',a.media_type,'approval_state',a.approval_state,'identity_state',a.identity_state,
    'launch_safe',a.is_launch_safe,'storage_ref',a.storage_ref,
    'handoff_ready', (a.is_launch_safe AND a.approval_state='APPROVED'),
    'publish', false, 'activation', false,
    'note','Marketing Director/Campaign Builder consume this later; activation stays false until human approval + explicit launch unit.');
END; $fn$;

CREATE OR REPLACE FUNCTION public.fn_creative_production_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_pass int:=0; v_fail int:=0; v_c jsonb:='[]'::jsonb; r jsonb; g jsonb; pl jsonb;
BEGIN
  -- valid customer + brand requests (non-persist)
  IF (public.fn_creative_production_request('00000000-0000-0000-0000-000000000001','CUSTOMER_PRODUCT',gen_random_uuid(),null,'GB','SALES','TIKTOK','VIDEO','{}','{}','[]','{}',false,true,false)->>'status')='accepted'
     AND (public.fn_creative_production_request('00000000-0000-0000-0000-000000000001','STRATELOQ_BRAND',null,null,'GB','AWARENESS','LINKEDIN','VIDEO','{}','{}','[]','{}',false,true,false)->>'status')='accepted'
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('both_source_modes_accepted',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('both_source_modes_accepted',false); END IF;

  -- invalid inputs rejected
  IF (public.fn_creative_production_request('00000000-0000-0000-0000-000000000001','BOGUS',null,null,'GB','x','META','VIDEO','{}','{}','[]','{}',false,true,false)->>'status')='rejected'
     AND (public.fn_creative_production_request('00000000-0000-0000-0000-000000000001','CUSTOMER_PRODUCT',null,null,'GB','x','META','VIDEO','{}','{}','[]','{}',false,true,false)->>'status')='rejected'
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('invalid_rejected',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('invalid_rejected',false); END IF;

  -- cost gate blocks over-budget
  g := public.fn_creative_generation_cost_gate('{"max_generation_calls":3,"max_generation_cost":4.00}'::jsonb, 3, 3.60, 1.20);
  IF (g->>'allow')='false' AND (g->>'reason')='max_generation_calls_exceeded' THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('cost_gate_blocks',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('cost_gate_blocks',false); END IF;

  -- identity policy invariants
  IF (public.fn_creative_scene_identity_policy('CUSTOMER_PRODUCT','VIDEO_SCENE',true,true)->>'identity_state')='IDENTITY_REVIEW_REQUIRED'
     AND (public.fn_creative_scene_identity_policy('CUSTOMER_PRODUCT','IMAGE_SCENE',true,false)->>'identity_state')='AUTHORITATIVE_PRODUCT_CARD_PIXELS'
     AND (public.fn_creative_scene_identity_policy('CUSTOMER_PRODUCT','VIDEO_SCENE',false,true)->>'identity_state')='NO_DEVICE_IDENTITY_NA'
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('identity_policy_intact',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('identity_policy_intact',false); END IF;

  -- platform specs for all 4
  IF (public.fn_creative_platform_spec('META')->>'aspect') IS NOT NULL AND (public.fn_creative_platform_spec('INSTAGRAM')->>'aspect') IS NOT NULL
     AND (public.fn_creative_platform_spec('TIKTOK')->>'aspect')='9:16' AND (public.fn_creative_platform_spec('LINKEDIN')->>'aspect') IS NOT NULL
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('platform_specs_present',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('platform_specs_present',false); END IF;

  -- plan: publish/activation false + composition external cost 0
  r := public.fn_creative_production_request('00000000-0000-0000-0000-000000000001','CUSTOMER_PRODUCT',gen_random_uuid(),null,'GB','SALES','TIKTOK','VIDEO','{}','{}','[]','{"max_generation_calls":3,"max_generation_cost":4.00}'::jsonb,true,true,false);
  pl := public.fn_creative_production_plan(r, '{"scenes":[{"scene_type":"VIDEO_SCENE","is_generative":true,"contains_product":false,"est_gen_cost":1.20},{"scene_type":"CTA_SCENE","is_generative":false,"contains_product":true}]}'::jsonb);
  IF (pl->'campaign_handoff'->>'publish')='false' AND (pl->'campaign_handoff'->>'activation')='false'
     AND (pl->'cost_tracking'->>'COMPOSITION_EXTERNAL_COST')='0.00' AND (pl->>'status')='PLAN_READY'
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('plan_publish_false_comp_cost_zero',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('plan_publish_false_comp_cost_zero',false); END IF;

  RETURN jsonb_build_object('suite','creative_production_contract','pass',v_pass,'fail',v_fail,'all_pass',(v_fail=0),'checks',v_c);
END; $fn$;

-- Register the native compositor as the production composition backend.
UPDATE public.media_providers
SET config = config || jsonb_build_object(
      'production_status','PRODUCTION_REGISTERED (015U) — generic composition backend for the Creative Production Agent (CUSTOMER_PRODUCT + STRATELOQ_BRAND); data-driven storyboards; no proof-specific logic',
      'supported_creative_types', jsonb_build_array('COPY_ONLY','STATIC','VIDEO','CAROUSEL(extensible)'),
      'supported_platforms', jsonb_build_array('META','INSTAGRAM','TIKTOK','LINKEDIN'))
WHERE name = 'STRATELOQ_VIDEO_COMPOSITION';

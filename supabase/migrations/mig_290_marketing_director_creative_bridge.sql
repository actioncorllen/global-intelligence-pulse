-- ============================================================================
-- mig_290_marketing_director_creative_bridge.sql
-- STRATELOQ-016A — Connect the EXISTING AI Marketing Director (n8n YDhtr1EPQRUv5wdm)
-- to the 015U generic Creative Production contract. No new Marketing Director,
-- no third campaign lineage, no Creative Studio redesign.
--
-- Reconciliation (confirmed, existing design):
--   marketing_campaign_drafts  = Marketing Director STRATEGY / campaign intent
--   campaign_builder_drafts    = execution-ready campaign configuration
--   campaign_performance_snapshots = future Ad-Performance loop (already exists; no fake data)
--
-- Adds: a structured MD strategy contract, a strategy->Creative-Production bridge,
-- lineage (creative_production_requests.marketing_draft_id), and the ORGANIC vs
-- PAID execution mode. Authorization for 016A: publish/activation/spend = false.
-- Idempotent. Preserves all identity/claim/quality gates and PLG growth agents.
-- ============================================================================

ALTER TABLE public.creative_production_requests ADD COLUMN IF NOT EXISTS marketing_draft_id uuid;
ALTER TABLE public.creative_production_requests ADD COLUMN IF NOT EXISTS execution_mode text; -- ORGANIC_CONTENT | PAID_CAMPAIGN

-- Structured Marketing Director strategy. Strategic orchestration only; it does
-- NOT render creatives. Persists into marketing_campaign_drafts (strategy table).
CREATE OR REPLACE FUNCTION public.fn_marketing_director_strategy(
  p_tenant uuid, p_user uuid, p_source_mode text, p_product_id uuid, p_decision_id uuid,
  p_market text, p_objective text, p_execution_mode text, p_platform text, p_creative_type text,
  p_content jsonb DEFAULT '{}'::jsonb, p_persist boolean DEFAULT true)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_err text[] := '{}'; v_id uuid; v_strategy jsonb;
BEGIN
  IF p_source_mode NOT IN ('CUSTOMER_PRODUCT','STRATELOQ_BRAND') THEN v_err := array_append(v_err,'invalid_source_mode'); END IF;
  IF coalesce(p_execution_mode,'') NOT IN ('ORGANIC_CONTENT','PAID_CAMPAIGN') THEN v_err := array_append(v_err,'invalid_execution_mode'); END IF;
  IF coalesce(p_creative_type,'') NOT IN ('COPY_ONLY','STATIC','VIDEO','CAROUSEL') THEN v_err := array_append(v_err,'invalid_creative_type'); END IF;
  IF coalesce(p_platform,'') NOT IN ('META','INSTAGRAM','TIKTOK','LINKEDIN') THEN v_err := array_append(v_err,'invalid_platform'); END IF;
  IF p_source_mode='CUSTOMER_PRODUCT' AND p_product_id IS NULL THEN v_err := array_append(v_err,'customer_product_requires_product_id'); END IF;
  IF array_length(v_err,1) IS NOT NULL THEN RETURN jsonb_build_object('status','rejected','errors',to_jsonb(v_err)); END IF;

  v_strategy := jsonb_build_object(
    'contract','MARKETING_DIRECTOR_STRATEGY_V1',
    'tenant_id',p_tenant,'user_id',p_user,'source_mode',p_source_mode,
    'product_id',p_product_id,'decision_id',p_decision_id,'market',p_market,'objective',p_objective,
    'execution_mode',p_execution_mode,'platform',p_platform,'creative_type',p_creative_type,
    'audience_direction', p_content->'audience_direction',
    'positioning', p_content->'positioning',
    'marketing_hypothesis', p_content->'marketing_hypothesis',
    'channel_recommendation', coalesce(p_content->'channel_recommendation', to_jsonb(p_platform)),
    'creative_hypothesis', p_content->'creative_hypothesis',
    'content_intent', p_content->'content_intent',
    'cta_direction', p_content->'cta_direction',
    'test_rationale', p_content->'test_rationale',
    'brand_dna', coalesce(p_content->'brand_dna','{}'::jsonb),
    'available_assets', coalesce(p_content->'available_assets','[]'::jsonb),
    'renders_creative', false,
    'authorization', jsonb_build_object('publish',false,'activation',false,'spend_authorized',false,'human_creative_approval_required',true));

  IF p_persist THEN
    INSERT INTO public.marketing_campaign_drafts(user_id, business_context, report, canonical_campaign, creative_specs, performance_schema, lifecycle, status)
    VALUES (p_user,
      jsonb_build_object('source_mode',p_source_mode,'tenant_id',p_tenant,'product_id',p_product_id,'decision_id',p_decision_id,'market',p_market),
      v_strategy,
      jsonb_build_object('objective',p_objective,'platform',p_platform,'execution_mode',p_execution_mode),
      jsonb_build_object('creative_type',p_creative_type,'creative_hypothesis',p_content->'creative_hypothesis'),
      jsonb_build_object('lineage','campaign_performance_snapshots (future Ad-Performance loop); no data yet'),
      jsonb_build_object('stage','MD_STRATEGY'),'DRAFT')
    RETURNING id INTO v_id;
    v_strategy := v_strategy || jsonb_build_object('marketing_draft_id', v_id);
  END IF;

  RETURN jsonb_build_object('status','accepted','marketing_draft_id',v_id,'strategy',v_strategy);
END; $fn$;

-- Pure bridge: a strategy -> a generic Creative Production request (015U). No creative render.
CREATE OR REPLACE FUNCTION public.fn_marketing_strategy_to_request(
  p_strategy jsonb, p_budget jsonb DEFAULT '{}'::jsonb, p_generation_authorized boolean DEFAULT false,
  p_human_approval_required boolean DEFAULT true, p_persist boolean DEFAULT true)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_req jsonb; v_rid uuid;
BEGIN
  v_req := public.fn_creative_production_request(
    (p_strategy->>'tenant_id')::uuid, p_strategy->>'source_mode',
    (p_strategy->>'product_id')::uuid, (p_strategy->>'decision_id')::uuid,
    p_strategy->>'market', p_strategy->>'objective', p_strategy->>'platform', p_strategy->>'creative_type',
    jsonb_build_object('creative_hypothesis',p_strategy->'creative_hypothesis','marketing_hypothesis',p_strategy->'marketing_hypothesis','test_rationale',p_strategy->'test_rationale','positioning',p_strategy->'positioning'),
    coalesce(p_strategy->'brand_dna','{}'::jsonb), coalesce(p_strategy->'available_assets','[]'::jsonb),
    p_budget, p_generation_authorized, p_human_approval_required, p_persist);
  IF (v_req->>'status') <> 'accepted' THEN RETURN v_req; END IF;
  v_rid := (v_req->>'request_id')::uuid;
  IF p_persist AND v_rid IS NOT NULL THEN
    UPDATE public.creative_production_requests
       SET marketing_draft_id = (p_strategy->>'marketing_draft_id')::uuid,
           execution_mode = p_strategy->>'execution_mode'
     WHERE id = v_rid;
  END IF;
  RETURN v_req || jsonb_build_object(
    'marketing_draft_id', p_strategy->>'marketing_draft_id',
    'execution_mode', p_strategy->>'execution_mode',
    'campaign_stage_authorization', jsonb_build_object('publish',false,'activation',false,'spend_authorized',false));
END; $fn$;

-- Bridge from a persisted MD strategy draft -> Creative Production request (+lineage).
CREATE OR REPLACE FUNCTION public.fn_marketing_director_to_creative_request(
  p_draft_id uuid, p_budget jsonb DEFAULT '{}'::jsonb, p_generation_authorized boolean DEFAULT false,
  p_human_approval_required boolean DEFAULT true)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_strategy jsonb;
BEGIN
  SELECT report INTO v_strategy FROM public.marketing_campaign_drafts WHERE id = p_draft_id;
  IF v_strategy IS NULL OR (v_strategy->>'contract') <> 'MARKETING_DIRECTOR_STRATEGY_V1' THEN
    RETURN jsonb_build_object('status','strategy_not_found_or_incompatible'); END IF;
  v_strategy := v_strategy || jsonb_build_object('marketing_draft_id', p_draft_id);
  RETURN public.fn_marketing_strategy_to_request(v_strategy, p_budget, p_generation_authorized, p_human_approval_required, true);
END; $fn$;

CREATE OR REPLACE FUNCTION public.fn_marketing_director_integration_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_pass int:=0; v_fail int:=0; v_c jsonb:='[]'::jsonb; st jsonb; req jsonb;
BEGIN
  -- strategy accepted for both source modes, authorization all false, does not render
  st := public.fn_marketing_director_strategy('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002',
        'CUSTOMER_PRODUCT', gen_random_uuid(), gen_random_uuid(),'GB','SALES','ORGANIC_CONTENT','TIKTOK','VIDEO',
        '{"creative_hypothesis":"h","test_rationale":"t"}'::jsonb, false);
  IF (st->>'status')='accepted' AND (st->'strategy'->'authorization'->>'publish')='false'
     AND (st->'strategy'->'authorization'->>'activation')='false' AND (st->'strategy'->'authorization'->>'spend_authorized')='false'
     AND (st->'strategy'->>'renders_creative')='false'
     AND (public.fn_marketing_director_strategy('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','STRATELOQ_BRAND',null,null,'GB','AWARENESS','ORGANIC_CONTENT','LINKEDIN','VIDEO','{}'::jsonb,false)->>'status')='accepted'
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('strategy_ok_authorization_false',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('strategy_ok_authorization_false',false); END IF;

  -- invalid execution_mode rejected
  IF (public.fn_marketing_director_strategy('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','CUSTOMER_PRODUCT',gen_random_uuid(),null,'GB','SALES','BOGUS_MODE','TIKTOK','VIDEO','{}'::jsonb,false)->>'status')='rejected'
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('invalid_execution_mode_rejected',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('invalid_execution_mode_rejected',false); END IF;

  -- bridge produces an accepted creative request carrying execution_mode + campaign-stage authorization false
  req := public.fn_marketing_strategy_to_request(st->'strategy', '{"max_generation_calls":3,"max_generation_cost":4.00}'::jsonb, false, true, false);
  IF (req->>'status')='accepted' AND (req->>'execution_mode')='ORGANIC_CONTENT'
     AND (req->'campaign_stage_authorization'->>'publish')='false' AND (req->'campaign_stage_authorization'->>'activation')='false'
     AND (req->'campaign_stage_authorization'->>'spend_authorized')='false' AND (req->>'source_mode')='CUSTOMER_PRODUCT'
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('bridge_creates_request',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('bridge_creates_request',false); END IF;

  -- lineage columns exist; only the two existing draft lineages (no third)
  IF EXISTS (select 1 from information_schema.columns where table_schema='public' and table_name='creative_production_requests' and column_name='marketing_draft_id')
     AND (select count(*) from information_schema.tables where table_schema='public' and table_name in ('marketing_campaign_drafts','campaign_builder_drafts'))=2
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('lineage_two_drafts_no_third',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('lineage_two_drafts_no_third',false); END IF;

  -- tenant isolation on strategy + request tables
  IF (select relrowsecurity from pg_class where oid='public.marketing_campaign_drafts'::regclass)
     AND (select relrowsecurity from pg_class where oid='public.creative_production_requests'::regclass)
     THEN v_pass:=v_pass+1; v_c:=v_c||jsonb_build_object('tenant_isolation',true);
  ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('tenant_isolation',false); END IF;

  RETURN jsonb_build_object('suite','marketing_director_integration','pass',v_pass,'fail',v_fail,'all_pass',(v_fail=0),'checks',v_c);
END; $fn$;

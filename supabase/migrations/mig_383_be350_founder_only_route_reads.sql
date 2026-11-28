-- STRATELOQ — BE350 P1: server-side founder-only denial on the READ/action entry
-- points behind the founder-only routes (My Campaigns, Creative Studio). PREPARED,
-- NOT applied. Production remains df1e2f6 (BE336). 0 paid calls. No data/behaviour
-- change other than an additive fail-closed founder gate.
--
-- WHY: BE346 (mig_382) founder-gated every creative/campaign/store MUTATION
-- (generate / build_campaign / create_store / format_apply / production_request / ...).
-- The user-facing READ/action RPCs behind My Campaigns and the Creative Studio
-- artifact views were owner-scoped (WHERE user_id/tenant_id = auth.uid()) but NOT
-- founder-denied: a subscriber calling them directly got status:ok with their own
-- (empty) data instead of an explicit denial. The founder directive requires
-- founder-only access enforced server-side ("frontend hiding alone is insufficient").
-- This migration adds the same fail-closed fn_is_founder_uid gate used by BE346 so
-- direct-API access to these routes returns founder_only for non-founders.
--
-- DEPENDENCY: requires fn_is_founder_uid(uuid) from mig_382 (BE346). Apply mig_382
-- before this. fn_is_founder_uid returns TRUE for an active founder_principals row
-- keyed by the explicit uid, FALSE otherwise (incl. NULL) — fail-closed.
--
-- SCOPE (exactly 5 RPCs; chosen for zero entanglement with Discovery or the public
-- storefront):
--   My Campaigns  : get_own_marketing_campaign_drafts, fn_ecommerce_campaign_executions,
--                   reject_marketing_campaign_draft
--   Creative Studio: fn_creative_image_job_result, fn_creative_studio_design_family_result
-- DELIBERATELY NOT gated here (documented): the store reads (fn_hosted_store_get,
-- fn_store_website, fn_storefront_publish_context, ...) are entangled with the PUBLIC
-- storefront render path and gating them would risk published storefronts for
-- anonymous shoppers — store CREATION/management mutations are already founder-gated;
-- and fn_creative_studio_product_preview reads a product card the subscriber may
-- legitimately view in Discovery, so it is left (its generation path is already gated).
-- Product Discovery / Research / Compare / Save / Monitoring RPCs are untouched.

BEGIN;

-- 1) My Campaigns: owner's campaign drafts list -> founder_only for non-founders.
CREATE OR REPLACE FUNCTION public.get_own_marketing_campaign_drafts()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'unauthenticated', 'drafts', '[]'::jsonb);
    END IF;
    -- BE350: My Campaigns is founder-only (advertising = future scope).
    IF NOT public.fn_is_founder_uid(v_uid) THEN
        RETURN jsonb_build_object('status', 'founder_only', 'drafts', '[]'::jsonb);
    END IF;
    RETURN jsonb_build_object(
        'status', 'ok',
        'drafts', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                        'id', d.id, 'website', d.website, 'status', d.status,
                        'lifecycle', d.lifecycle, 'business_context', d.business_context,
                        'canonical_campaign', d.canonical_campaign,
                        'platform_payloads', d.platform_payloads,
                        'creative_specs', d.creative_specs, 'brand_assets', d.brand_assets,
                        'preview_payload', d.preview_payload, 'review_payload', d.review_payload,
                        'performance_schema', d.performance_schema,
                        'created_at', d.created_at, 'updated_at', d.updated_at)
                    ORDER BY d.created_at DESC)
            FROM public.marketing_campaign_drafts d
            WHERE d.user_id = v_uid), '[]'::jsonb)
    );
END;
$function$;

-- 2) My Campaigns: owner's campaign executions list -> founder_only for non-founders.
CREATE OR REPLACE FUNCTION public.fn_ecommerce_campaign_executions()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  -- BE350: My Campaigns is founder-only (advertising = future scope).
  IF NOT public.fn_is_founder_uid(v_uid) THEN RETURN jsonb_build_object('status','founder_only'); END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'execution_id', e.id, 'draft_id', e.draft_id, 'platform', e.platform,
      'status', e.status, 'launched', (e.meta_campaign_id IS NOT NULL),
      'created_at', e.created_at, 'updated_at', e.updated_at)
    ORDER BY e.created_at DESC), '[]'::jsonb) INTO v_rows
  FROM public.marketing_campaign_executions e WHERE e.user_id = v_uid;
  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'executions', v_rows,
    'drafts_contract','get_own_marketing_campaign_drafts', 'source_contract','marketing_campaign_executions');
END; $function$;

-- 3) My Campaigns: reject/archive a campaign draft -> founder_only for non-founders.
CREATE OR REPLACE FUNCTION public.reject_marketing_campaign_draft(p_draft_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid   uuid := auth.uid();
    d       public.marketing_campaign_drafts%ROWTYPE;
    v_now   timestamptz;
    v_life  jsonb;
    v_exec_id uuid;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status','unauthenticated');
    END IF;
    -- BE350: My Campaigns is founder-only (advertising = future scope).
    IF NOT public.fn_is_founder_uid(v_uid) THEN
        RETURN jsonb_build_object('status','founder_only');
    END IF;
    IF p_draft_id IS NULL THEN
        RETURN jsonb_build_object('status','invalid_request');
    END IF;

    SELECT * INTO d FROM public.marketing_campaign_drafts WHERE id = p_draft_id;
    IF NOT FOUND OR d.user_id IS DISTINCT FROM v_uid THEN
        RETURN jsonb_build_object('status','not_found');
    END IF;

    -- Never archive a draft that already produced live PAUSED Meta objects.
    SELECT e.id INTO v_exec_id
    FROM public.marketing_campaign_executions e
    WHERE e.draft_id = p_draft_id AND e.platform = 'meta' AND e.status = 'CREATED_PAUSED'
    LIMIT 1;
    IF v_exec_id IS NOT NULL THEN
        RETURN jsonb_build_object('status','already_executed','draft_id',p_draft_id,'execution_id',v_exec_id);
    END IF;

    -- Idempotent no-op if already archived.
    IF d.status = 'ARCHIVED' THEN
        RETURN jsonb_build_object('status','archived','draft_id',p_draft_id,'draft_status','ARCHIVED','idempotent',true);
    END IF;

    v_now := now();
    v_life := coalesce(d.lifecycle, '{}'::jsonb)
              || jsonb_build_object('status','ARCHIVED','publishable',false)
              || jsonb_build_object('rejection', jsonb_build_object(
                    'rejected_at', to_jsonb(v_now),
                    'rejected_by', to_jsonb(v_uid),
                    'reason', coalesce(p_reason,'rejected_by_owner')));
    v_life := jsonb_set(
                v_life, '{history}',
                coalesce(v_life->'history','[]'::jsonb)
                || jsonb_build_array(jsonb_build_object(
                     'stage','ARCHIVED','at', to_jsonb(v_now), 'by', to_jsonb(v_uid),
                     'reason', coalesce(p_reason,'rejected_by_owner'))));

    UPDATE public.marketing_campaign_drafts
       SET status = 'ARCHIVED', lifecycle = v_life, updated_at = v_now
     WHERE id = p_draft_id AND user_id = v_uid;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status','invalid_transition');
    END IF;

    RETURN jsonb_build_object('status','archived','draft_id',p_draft_id,'draft_status','ARCHIVED','rejected_at',to_jsonb(v_now));
END;
$function$;

-- 4) Creative Studio: creative image-job result -> founder_only for non-founders.
CREATE OR REPLACE FUNCTION public.fn_creative_image_job_result(p_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); j public.media_image_jobs%rowtype; v_asset uuid;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  -- BE350: Creative Studio is founder-only.
  IF NOT public.fn_is_founder_uid(v_tenant) THEN RETURN jsonb_build_object('status','founder_only'); END IF;
  IF p_job_id IS NULL THEN RETURN jsonb_build_object('status','no_job'); END IF;
  SELECT * INTO j FROM public.media_image_jobs WHERE id=p_job_id AND tenant_id=v_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  v_asset := nullif(j.output_asset_refs->>0,'')::uuid;
  RETURN jsonb_build_object(
    'status','ok', 'job_id', j.id::text, 'job_status', j.status, 'error_state', j.error_state,
    'asset_id', v_asset,
    'is_ready', (j.status IN ('GENERATED_REVIEW_REQUIRED','GENERATED_REAL')),
    'is_failed', (j.status IN ('FAILED','BLOCKED_EXTERNAL_PROVIDER','BLOCKED_CLAIM_REVIEW','BLOCKED_RIGHTS','BLOCKED_ASPECT')));
END; $function$;

-- 5) Creative Studio: design-family concept set result -> founder_only for non-founders.
CREATE OR REPLACE FUNCTION public.fn_creative_studio_design_family_result(p_request_id uuid, p_set_id uuid, p_reused boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid := auth.uid();
  r public.creative_production_requests%rowtype;
  v_variants jsonb;
BEGIN
  -- BE350: Creative Studio is founder-only (null uid -> fn_is_founder_uid=false -> founder_only).
  IF NOT public.fn_is_founder_uid(v_tenant) THEN RETURN jsonb_build_object('ok',false,'error','founder_only'); END IF;
  SELECT * INTO r FROM public.creative_production_requests WHERE id=p_request_id AND tenant_id=v_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','request_not_found_for_tenant'); END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'concept_id', c.id, 'label', c.concept_label, 'design_family', c.design_family,
      'design_family_label', c.concept_name, 'platform_target', c.platform_target,
      'review_state', c.review_state, 'headline', c.headline, 'cta_text', c.cta_text,
      'declares_real_assets', c.declares_real_assets,
      'product_asset_lock', c.generation_contract->'product_asset_lock',
      'quality_gate', public.fn_ci_design_family_gate(c.id),
      'truth_safety', public.fn_ci_concept_truth_gate(c.id),
      'dispatch', jsonb_build_object('webhook_path','pulse-saas-text-to-image',
                    'body', jsonb_build_object('job_id',c.id,'prompt',c.generation_contract->>'prompt')),
      'generation_contract', c.generation_contract
    ) ORDER BY c.concept_label), '[]'::jsonb)
    INTO v_variants
  FROM public.creative_concepts c
  WHERE c.set_id=p_set_id AND c.tenant_id=v_tenant;

  RETURN jsonb_build_object('ok',true,'reused',p_reused,'request_id',p_request_id,
    'creative_format', r.creative_format, 'output_type','STATIC',
    'generation_system','CI_DESIGN_FAMILY', 'job_kind','DESIGN_CONCEPT_SET',
    'concept_set_id', p_set_id, 'design_family', r.resolved_design_family,
    'design_family_variants', v_variants, 'generation_state', r.generation_state,
    'video_generation_paid_gated', false, 'image_generation_paid_gated', true, 'dispatched', false,
    'note','SAAS / business creative routed through the Creative Intelligence Design Director; the design family was selected adaptively and dispatch-ready generation contracts were produced. Real premium image generation is paid and held at the dispatch boundary (no spend). Concepts await Creative Studio review.');
END; $function$;

COMMIT;

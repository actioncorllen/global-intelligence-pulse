-- Functions transcribed verbatim from production pg_get_functiondef (2026-11-10 read-only fetch).
-- These four have no current repo migration file; parity verified post-apply via md5(pg_get_functiondef).

CREATE OR REPLACE FUNCTION public.fn_global_intelligence_uid()
 RETURNS uuid
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ SELECT '00000000-0000-4000-8000-000000000001'::uuid $function$;

CREATE OR REPLACE FUNCTION public.fn_entitlement_active(p_status text, p_current_period_end timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT upper(coalesce(p_status,'')) IN ('ACTIVE','COMP','TRIALING')
         AND (p_current_period_end IS NULL OR p_current_period_end > now());
$function$;

CREATE OR REPLACE FUNCTION public.fn_entitlement_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); e public.account_entitlement%rowtype;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO e FROM public.account_entitlement WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','ok','has_entitlement',false,'active',false,'plan_code',null,'entitlement_status',null,'source',null);
  END IF;
  RETURN jsonb_build_object(
    'status','ok',
    'has_entitlement', true,
    'active', public.fn_entitlement_active(e.status, e.current_period_end),
    'plan_code', e.plan_code,
    'entitlement_status', e.status,
    'source', e.source,
    'billing_interval', e.billing_interval,
    'current_period_end', e.current_period_end,
    'cancel_at_period_end', e.cancel_at_period_end,
    'trial_end', e.trial_end);
END; $function$;

CREATE OR REPLACE FUNCTION public.get_own_business_profile()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid          uuid := auth.uid();
    v_member_count integer;
    v_member_id    uuid;
    v_app          uuid;
    v_bp           public.business_profiles%ROWTYPE;
    v_ds_count     integer;
    v_ds_status    text;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'unauthenticated');
    END IF;

    -- Resolve member via UNIQUE(auth_user_id): count+min from ONE snapshot; no
    -- arbitrary/LIMIT selection; >1 is impossible and fails closed.
    SELECT count(*), min(m.id::text)::uuid, min(m.application_ref::text)::uuid
      INTO v_member_count, v_member_id, v_app
    FROM public.member AS m
    WHERE m.auth_user_id = v_uid;
    IF v_member_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_member');
    ELSIF v_member_count > 1 THEN
        RAISE EXCEPTION 'business profile resolution cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    -- Resolve profile by UNIQUE(application_id). No claim, no lock, no mutation.
    SELECT * INTO v_bp
    FROM public.business_profiles
    WHERE application_id = v_app;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'profile_not_ready');
    END IF;

    -- Ownership: unclaimed (NULL) or own may be read; other-owner fails closed.
    IF v_bp.user_id IS NOT NULL AND v_bp.user_id <> v_uid THEN
        RAISE EXCEPTION 'business profile ownership violation' USING ERRCODE = 'P0001';
    END IF;

    -- Discovery status: EXACTLY one row required (never invent a default status).
    SELECT count(*), min(ds.status)
      INTO v_ds_count, v_ds_status
    FROM public.discovery_state AS ds
    WHERE ds.member_id = v_member_id;
    IF v_ds_count <> 1 THEN
        RAISE EXCEPTION 'discovery_state cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object(
        'status', 'ready',
        'discovery', v_ds_status,
        'profile', jsonb_build_object(
            'business_name', v_bp.business_name,
            'website', v_bp.website,
            'country', v_bp.country,
            'industry', v_bp.industry,
            'business_type', v_bp.business_type,
            'company_size', v_bp.company_size,
            'target_audience', v_bp.target_audience,
            'primary_goal', v_bp.primary_goal,
            'preferred_platforms', coalesce(v_bp.preferred_platforms, '[]'::jsonb),
            'competitors', coalesce(v_bp.competitors, '[]'::jsonb),
            'brief_frequency', v_bp.brief_frequency,
            'brand_voice', v_bp.brand_voice,
            'business_summary', v_bp.business_summary,
            'positioning_summary', v_bp.positioning_summary,
            'businessDiscovery', coalesce(v_bp.opportunity_preferences -> 'businessDiscovery', 'null'::jsonb)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        -- Translate ANY internal fault (ownership, cardinality, drift) to the single
        -- non-enumerating result. No message/SQLSTATE/identifier is exposed.
        RETURN jsonb_build_object('status', 'temporary_failure');
END;
$function$;

-- STRATELOQ-ECOM-P8-AUTHENTICATED-WORKSPACE-RESOLUTION-010C
-- Systemic robustness fix: get_own_discovery_intelligence resolved the business
-- profile ONLY by member.application_ref -> business_profiles.application_id. When
-- a member's application_ref is NULL (or unlinked) — as with the approved ecommerce
-- test tenant, and potentially real customers — the business_profile came back null
-- even though a business profile owned by that user exists. business_profiles.user_id
-- is the authoritative owner key, so add a fallback: when the application_id lookup
-- misses, resolve the caller's OWN business profile by user_id. The ownership guard
-- is unchanged (fallback rows are user_id = v_uid, so they pass). Body is otherwise
-- byte-identical to mig_235. Additive; no other behavior changes.
CREATE OR REPLACE FUNCTION public.get_own_discovery_intelligence()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_uid            uuid := auth.uid();
    v_member_count   integer;
    v_member_id      uuid;
    v_app            uuid;
    v_ds_count       integer;
    v_analysis       text;
    v_profile_status text;
    v_bp             public.business_profiles%ROWTYPE;
    v_dna            public.member_business_dna%ROWTYPE;
    v_run            uuid;
    v_run_website    text;
    v_ident          jsonb;
    v_business_profile jsonb;
    v_business_dna   jsonb;
    v_icp            jsonb;
    v_radar          jsonb;
    v_decisions      jsonb;
    v_actions        jsonb;
    v_content        jsonb;
    v_commerce       jsonb := '[]'::jsonb;
    v_brief          jsonb;
    v_failure_reason text;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'unauthenticated');
    END IF;

    SELECT count(*), min(m.id::text)::uuid, min(m.application_ref::text)::uuid
      INTO v_member_count, v_member_id, v_app
    FROM public.member AS m
    WHERE m.auth_user_id = v_uid;
    IF v_member_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_member');
    ELSIF v_member_count > 1 THEN
        RAISE EXCEPTION 'member cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    SELECT count(*), min(ds.analysis_status), min(ds.status)
      INTO v_ds_count, v_analysis, v_profile_status
    FROM public.discovery_state AS ds
    WHERE ds.member_id = v_member_id;
    IF v_ds_count > 1 THEN
        RAISE EXCEPTION 'discovery_state cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    IF v_analysis = 'failed' THEN
        SELECT dr.error ->> 'detail' INTO v_failure_reason
        FROM public.discovery_runs AS dr
        WHERE dr.member_id = v_member_id AND dr.run_status = 'failed'
        ORDER BY dr.completed_at DESC NULLS LAST, dr.created_at DESC
        LIMIT 1;
        IF v_failure_reason IS NULL OR v_failure_reason NOT IN
           ('INVALID_URL','DOMAIN_NOT_FOUND','SITE_UNREACHABLE','REDIRECT_BLOCKED',
            'REDIRECT_LIMIT','TIMEOUT','FETCH_BLOCKED','INSUFFICIENT_CONTENT','ANALYSIS_FAILED') THEN
            v_failure_reason := 'TEMPORARY_FAILURE';
        END IF;
    END IF;

    SELECT * INTO v_bp
    FROM public.business_profiles
    WHERE application_id = v_app;
    IF NOT FOUND THEN
        -- Fallback: member.application_ref may be NULL/unlinked; resolve the
        -- authenticated user's OWN business profile by user_id (authoritative owner).
        SELECT * INTO v_bp
        FROM public.business_profiles
        WHERE user_id = v_uid
        ORDER BY updated_at DESC NULLS LAST
        LIMIT 1;
    END IF;
    IF FOUND THEN
        IF v_bp.user_id IS NOT NULL AND v_bp.user_id <> v_uid THEN
            RAISE EXCEPTION 'business profile ownership violation' USING ERRCODE = 'P0001';
        END IF;
        v_business_profile := jsonb_build_object(
            'business_name', v_bp.business_name, 'website', v_bp.website, 'country', v_bp.country,
            'industry', v_bp.industry, 'business_type', v_bp.business_type, 'company_size', v_bp.company_size,
            'target_audience', v_bp.target_audience, 'primary_goal', v_bp.primary_goal,
            'business_summary', v_bp.business_summary, 'positioning_summary', v_bp.positioning_summary,
            'brand_voice', v_bp.brand_voice,
            'preferred_platforms', coalesce(v_bp.preferred_platforms, '[]'::jsonb),
            'competitors', coalesce(v_bp.competitors, '[]'::jsonb),
            'businessDiscovery', coalesce(v_bp.opportunity_preferences -> 'businessDiscovery', 'null'::jsonb)
        );
    ELSE
        v_business_profile := 'null'::jsonb;
    END IF;

    SELECT * INTO v_dna
    FROM public.member_business_dna
    WHERE user_id = v_uid;
    IF FOUND THEN
        v_run := v_dna.source_run_id;
        v_business_dna := jsonb_build_object(
            'business_model', v_dna.business_model, 'unique_value_prop', v_dna.unique_value_prop,
            'brand_positioning', v_dna.brand_positioning, 'growth_stage', v_dna.growth_stage,
            'brand_voice', v_dna.brand_voice, 'goals', coalesce(v_dna.goals, 'null'::jsonb),
            'extended', coalesce(v_dna.dna_extended, 'null'::jsonb), 'provenance', v_dna.provenance
        );
        v_icp := coalesce(v_dna.icp, 'null'::jsonb);
    ELSE
        v_business_dna := 'null'::jsonb;
        v_icp := 'null'::jsonb;
    END IF;

    SELECT dr.website INTO v_run_website
    FROM public.discovery_runs AS dr
    WHERE dr.member_id = v_member_id AND dr.website IS NOT NULL
    ORDER BY (dr.id = v_run) DESC, dr.created_at DESC
    LIMIT 1;
    IF v_run_website IS NOT NULL
       AND jsonb_typeof(v_business_profile) = 'object'
       AND (v_business_profile ->> 'website') IS NULL THEN
        v_business_profile := jsonb_set(v_business_profile, '{website}', to_jsonb(v_run_website));
    END IF;

    IF jsonb_typeof(v_business_profile) = 'object'
       AND v_dna.dna_extended IS NOT NULL
       AND jsonb_typeof(v_dna.dna_extended -> 'identity') = 'object' THEN
        v_ident := v_dna.dna_extended -> 'identity';
        IF nullif(btrim(coalesce(v_ident ->> 'name','')),'') IS NOT NULL THEN
            v_business_profile := jsonb_set(v_business_profile, '{business_name}', to_jsonb(v_ident ->> 'name'));
        END IF;
        IF nullif(btrim(coalesce(v_ident ->> 'industry','')),'') IS NOT NULL THEN
            v_business_profile := jsonb_set(v_business_profile, '{industry}', to_jsonb(v_ident ->> 'industry'));
        END IF;
        IF nullif(btrim(coalesce(v_ident ->> 'geography','')),'') IS NOT NULL THEN
            v_business_profile := jsonb_set(v_business_profile, '{country}', to_jsonb(v_ident ->> 'geography'));
        END IF;
    END IF;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'opportunity_id', mo.opportunity_id,
                'source', CASE WHEN mo.opportunity_id IS NOT NULL THEN 'global' ELSE 'business_specific' END,
                'rank', mo.rank,
                'title', coalesce(o.title, mo.title),
                'summary', mo.summary,
                'opportunity_score', coalesce(mo.personalized_opportunity_score, o.opportunity_score),
                'confidence_score', coalesce(mo.confidence, o.confidence_score),
                'business_relevance', mo.business_relevance,
                'urgency', mo.urgency,
                'status', mo.status,
                'provenance', mo.provenance
            ) ORDER BY mo.rank NULLS LAST, mo.created_at), '[]'::jsonb)
      INTO v_radar
    FROM public.member_opportunities AS mo
    LEFT JOIN public.opportunities AS o ON o.id = mo.opportunity_id
    WHERE mo.user_id = v_uid AND mo.source_run_id = v_run;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'opportunity_id', mo.opportunity_id,
                'rank', mo.rank,
                'title', coalesce(mo.title, (SELECT o2.title FROM public.opportunities o2 WHERE o2.id = mo.opportunity_id)),
                'why_matters', mo.why_matters,
                'why_now', mo.why_now,
                'business_relevance', mo.business_relevance,
                'recommended_decision', mo.recommended_decision,
                'evidence', coalesce(mo.evidence, '[]'::jsonb),
                'provenance', mo.provenance
            ) ORDER BY mo.rank NULLS LAST), '[]'::jsonb)
      INTO v_decisions
    FROM public.member_opportunities AS mo
    WHERE mo.user_id = v_uid AND mo.source_run_id = v_run;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'opportunity_id', mo.opportunity_id,
                'rank', mo.rank,
                'content_reco', mo.content_reco
            ) ORDER BY mo.rank NULLS LAST) FILTER (WHERE mo.content_reco IS NOT NULL), '[]'::jsonb)
      INTO v_content
    FROM public.member_opportunities AS mo
    WHERE mo.user_id = v_uid AND mo.source_run_id = v_run;

    v_actions := jsonb_build_object(
        'quick_wins', coalesce((
            SELECT jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'detail', a.detail,
                        'rank', a.rank, 'status', a.status, 'provenance', a.provenance)
                    ORDER BY a.rank NULLS LAST)
            FROM public.member_actions AS a
            WHERE a.user_id = v_uid AND a.source_run_id = v_run AND a.action_type = 'quick_win'), '[]'::jsonb),
        'next_stage', coalesce((
            SELECT jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'detail', a.detail,
                        'rank', a.rank, 'status', a.status, 'provenance', a.provenance)
                    ORDER BY a.rank NULLS LAST)
            FROM public.member_actions AS a
            WHERE a.user_id = v_uid AND a.source_run_id = v_run AND a.action_type = 'next_stage'), '[]'::jsonb),
        'next_best_move', (
            SELECT jsonb_build_object('id', a.id, 'title', a.title, 'detail', a.detail,
                        'status', a.status, 'provenance', a.provenance)
            FROM public.member_actions AS a
            WHERE a.user_id = v_uid AND a.source_run_id = v_run AND a.action_type = 'next_best_move'
            ORDER BY a.rank NULLS LAST
            LIMIT 1)
    );

    BEGIN
        IF v_run IS NOT NULL THEN
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'rank', o.rank,
                        'product_id', o.product_id,
                        'product_title', cp.title,
                        'category', cp.category,
                        'product_url', cp.product_url,
                        'source_store', cp.source_store,
                        'observed_price', cp.observed_price,
                        'currency', cp.price_currency,
                        'availability', cp.availability,
                        'opportunity_class', o.opportunity_class,
                        'overall_score', o.overall_score,
                        'confidence', o.confidence,
                        'recommended_decision', o.recommended_decision,
                        'why_this_product', o.why_this_product,
                        'why_now', o.why_now,
                        'positive_factors', coalesce(o.positive_factors, '[]'::jsonb),
                        'risk_factors', coalesce(o.risk_factors, '[]'::jsonb),
                        'factor_scores', coalesce(o.factor_scores, '{}'::jsonb),
                        'evidence', coalesce(o.evidence_refs, '[]'::jsonb),
                        'recommended_actions', coalesce(o.recommended_actions, '[]'::jsonb),
                        'content_context', coalesce(o.content_context, '{}'::jsonb),
                        'provenance', o.provenance,
                        'scoring_version', o.scoring_version
                    ) ORDER BY o.rank NULLS LAST, o.overall_score DESC NULLS LAST), '[]'::jsonb)
              INTO v_commerce
            FROM public.commerce_product_opportunities AS o
            JOIN public.commerce_products AS cp ON cp.id = o.product_id
            WHERE o.user_id = v_uid AND o.source_run_id = v_run;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_commerce := '[]'::jsonb;
    END;

    SELECT to_jsonb(db) INTO v_brief
    FROM (
        SELECT b.date, b.brief_json, b.top_opportunities, b.generated_at
        FROM public.daily_briefs AS b
        WHERE b.user_id = v_uid
        ORDER BY b.date DESC NULLS LAST, b.generated_at DESC NULLS LAST
        LIMIT 1
    ) AS db;

    RETURN jsonb_build_object(
        'status', 'ok',
        'analysis_status', v_analysis,
        'failure_reason', v_failure_reason,
        'profile_completion_status', v_profile_status,
        'business_profile', v_business_profile,
        'business_dna', v_business_dna,
        'icp', v_icp,
        'opportunity_radar', v_radar,
        'decision_intelligence', v_decisions,
        'action_intelligence', v_actions,
        'content_intelligence', v_content,
        'commerce_opportunities', v_commerce,
        'morning_brief', coalesce(v_brief, 'null'::jsonb),
        'provenance_vocabulary', jsonb_build_array('OBSERVED', 'INFERRED', 'RESEARCHED', 'EXISTING_PULSE')
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('status', 'temporary_failure');
END;
$function$;

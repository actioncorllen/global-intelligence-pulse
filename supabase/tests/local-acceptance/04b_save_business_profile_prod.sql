-- Exact production pg_get_functiondef text for save_business_profile (2026-11-10 fetch).
CREATE OR REPLACE FUNCTION public.save_business_profile(p_content jsonb, p_complete boolean)
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
    v_invalid      text[] := ARRAY[]::text[];
    v_bd           jsonb;
    v_con          jsonb;
    v_bd_existing  jsonb;
    v_bd_new       jsonb;
    v_con_existing jsonb;
    v_con_new      jsonb;
    v_new_opp      jsonb;
    v_ds_status    text;
    v_ds_rows      integer;
    c_top   constant text[] := ARRAY['business_name','website','country','industry','business_type','company_size','target_audience','primary_goal','preferred_platforms','competitors','brief_frequency','brand_voice','business_summary','positioning_summary','businessDiscovery','business_category'];
    c_bd    constant text[] := ARRAY['schemaVersion','productsOrServices','customerPainPoints','desiredOutcomes','constraints','differentiation','opportunityFocus'];
    c_con   constant text[] := ARRAY['budgetRange','teamCapacity','timeCapacity','geographicFocus'];
    k    text;
    b    integer;
    eff_name text; eff_industry text; eff_audience text; eff_goal text; eff_summary text;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('status', 'unauthenticated');
    END IF;
    IF jsonb_typeof(p_content) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_object('status', 'invalid', 'fields', jsonb_build_array('content'));
    END IF;

    FOR k IN SELECT jsonb_object_keys(p_content) LOOP
        IF NOT (k = ANY (c_top)) THEN v_invalid := array_append(v_invalid, k); END IF;
    END LOOP;

    FOR k, b IN SELECT key, bound FROM (VALUES
        ('business_name',500),('website',500),('country',500),('industry',500),
        ('business_type',500),('company_size',500),('target_audience',500),('primary_goal',500),
        ('brief_frequency',500),('brand_voice',500),('business_summary',4000),('positioning_summary',4000)
    ) AS t(key,bound) LOOP
        IF p_content ? k AND NOT (
            jsonb_typeof(p_content->k) IN ('string','null')
            AND (jsonb_typeof(p_content->k) <> 'string' OR length(btrim(p_content->>k)) <= b)
        ) THEN v_invalid := array_append(v_invalid, k); END IF;
    END LOOP;

    IF p_content ? 'business_category' AND NOT (
        jsonb_typeof(p_content->'business_category') IN ('string','null')
        AND (jsonb_typeof(p_content->'business_category') <> 'string'
             OR EXISTS (SELECT 1 FROM public.business_category c
                        WHERE c.is_active AND c.code = btrim(p_content->>'business_category')))
    ) THEN v_invalid := array_append(v_invalid, 'business_category'); END IF;

    FOR k IN SELECT unnest(ARRAY['preferred_platforms','competitors']) LOOP
        IF p_content ? k AND NOT (
            jsonb_typeof(p_content->k) = 'array'
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_content->k) e WHERE jsonb_typeof(e.value) <> 'string')
            AND (SELECT count(*) FROM jsonb_array_elements_text(p_content->k)) <= 20
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_content->k) e WHERE length(btrim(e.value)) > 200)
        ) THEN v_invalid := array_append(v_invalid, k); END IF;
    END LOOP;

    IF p_content ? 'businessDiscovery' THEN
        v_bd := p_content -> 'businessDiscovery';
        IF jsonb_typeof(v_bd) IS DISTINCT FROM 'object' THEN
            v_invalid := array_append(v_invalid, 'businessDiscovery');
            v_bd := NULL;
        ELSE
            FOR k IN SELECT jsonb_object_keys(v_bd) LOOP
                IF NOT (k = ANY (c_bd)) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.' || k); END IF;
            END LOOP;
            IF v_bd ? 'schemaVersion' AND v_bd->'schemaVersion' IS DISTINCT FROM to_jsonb(1) THEN
                v_invalid := array_append(v_invalid, 'businessDiscovery.schemaVersion');
            END IF;
            FOR k IN SELECT unnest(ARRAY['productsOrServices','customerPainPoints','desiredOutcomes','opportunityFocus']) LOOP
                IF v_bd ? k AND NOT (
                    jsonb_typeof(v_bd->k) = 'array'
                    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_bd->k) e WHERE jsonb_typeof(e.value) <> 'string')
                    AND (SELECT count(*) FROM jsonb_array_elements_text(v_bd->k)) <= 20
                    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_bd->k) e WHERE length(btrim(e.value)) > 200)
                ) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.' || k); END IF;
            END LOOP;
            IF v_bd ? 'differentiation' AND NOT (
                jsonb_typeof(v_bd->'differentiation') IN ('string','null')
                AND (jsonb_typeof(v_bd->'differentiation') <> 'string' OR length(btrim(v_bd->>'differentiation')) <= 4000)
            ) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.differentiation'); END IF;
            IF v_bd ? 'constraints' THEN
                v_con := v_bd -> 'constraints';
                IF jsonb_typeof(v_con) IS DISTINCT FROM 'object' THEN
                    v_invalid := array_append(v_invalid, 'businessDiscovery.constraints');
                    v_con := NULL;
                ELSE
                    FOR k IN SELECT jsonb_object_keys(v_con) LOOP
                        IF NOT (k = ANY (c_con)) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.constraints.' || k); END IF;
                    END LOOP;
                    FOR k IN SELECT unnest(ARRAY['budgetRange','teamCapacity','timeCapacity']) LOOP
                        IF v_con ? k AND NOT (
                            jsonb_typeof(v_con->k) IN ('string','null')
                            AND (jsonb_typeof(v_con->k) <> 'string' OR length(btrim(v_con->>k)) <= 500)
                        ) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.constraints.' || k); END IF;
                    END LOOP;
                    IF v_con ? 'geographicFocus' AND NOT (
                        jsonb_typeof(v_con->'geographicFocus') = 'array'
                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_con->'geographicFocus') e WHERE jsonb_typeof(e.value) <> 'string')
                        AND (SELECT count(*) FROM jsonb_array_elements_text(v_con->'geographicFocus')) <= 20
                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_con->'geographicFocus') e WHERE length(btrim(e.value)) > 200)
                    ) THEN v_invalid := array_append(v_invalid, 'businessDiscovery.constraints.geographicFocus'); END IF;
                END IF;
            END IF;
        END IF;
    END IF;

    SELECT count(*), min(m.id::text)::uuid, min(m.application_ref::text)::uuid
      INTO v_member_count, v_member_id, v_app
    FROM public.member AS m
    WHERE m.auth_user_id = v_uid;
    IF v_member_count = 0 THEN
        RETURN jsonb_build_object('status', 'no_member');
    ELSIF v_member_count > 1 THEN
        RAISE EXCEPTION 'business profile resolution cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_bp
    FROM public.business_profiles
    WHERE application_id = v_app
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'profile_not_ready');
    END IF;
    IF v_bp.user_id IS NOT NULL AND v_bp.user_id <> v_uid THEN
        RAISE EXCEPTION 'business profile ownership violation' USING ERRCODE = 'P0001';
    END IF;

    v_bd_existing := CASE WHEN jsonb_typeof(v_bp.opportunity_preferences -> 'businessDiscovery') = 'object'
                          THEN v_bp.opportunity_preferences -> 'businessDiscovery' ELSE '{}'::jsonb END;

    IF p_complete THEN
        eff_name     := CASE WHEN p_content ? 'business_name'    THEN nullif(btrim(p_content->>'business_name'), '')    ELSE v_bp.business_name END;
        eff_industry := CASE WHEN p_content ? 'industry'         THEN nullif(btrim(p_content->>'industry'), '')         ELSE v_bp.industry END;
        eff_audience := CASE WHEN p_content ? 'target_audience'  THEN nullif(btrim(p_content->>'target_audience'), '')  ELSE v_bp.target_audience END;
        eff_goal     := CASE WHEN p_content ? 'primary_goal'     THEN nullif(btrim(p_content->>'primary_goal'), '')     ELSE v_bp.primary_goal END;
        eff_summary  := CASE WHEN p_content ? 'business_summary' THEN nullif(btrim(p_content->>'business_summary'), '') ELSE v_bp.business_summary END;
        IF eff_name IS NULL     THEN v_invalid := array_append(v_invalid, 'business_name'); END IF;
        IF eff_industry IS NULL THEN v_invalid := array_append(v_invalid, 'industry'); END IF;
        IF eff_audience IS NULL THEN v_invalid := array_append(v_invalid, 'target_audience'); END IF;
        IF eff_goal IS NULL     THEN v_invalid := array_append(v_invalid, 'primary_goal'); END IF;
        IF eff_summary IS NULL  THEN v_invalid := array_append(v_invalid, 'business_summary'); END IF;

        IF NOT ('businessDiscovery.productsOrServices' = ANY (v_invalid)) AND (
            CASE
                WHEN v_bd IS NOT NULL AND v_bd ? 'productsOrServices' AND jsonb_typeof(v_bd->'productsOrServices') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd->'productsOrServices') e WHERE btrim(e.value) <> '')
                WHEN (v_bd IS NULL OR NOT (v_bd ? 'productsOrServices')) AND jsonb_typeof(v_bd_existing->'productsOrServices') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd_existing->'productsOrServices') e WHERE btrim(e.value) <> '')
                ELSE 0
            END
        ) < 1 THEN v_invalid := array_append(v_invalid, 'businessDiscovery.productsOrServices'); END IF;

        IF NOT ('businessDiscovery.customerPainPoints' = ANY (v_invalid)) AND (
            CASE
                WHEN v_bd IS NOT NULL AND v_bd ? 'customerPainPoints' AND jsonb_typeof(v_bd->'customerPainPoints') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd->'customerPainPoints') e WHERE btrim(e.value) <> '')
                WHEN (v_bd IS NULL OR NOT (v_bd ? 'customerPainPoints')) AND jsonb_typeof(v_bd_existing->'customerPainPoints') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd_existing->'customerPainPoints') e WHERE btrim(e.value) <> '')
                ELSE 0
            END
        ) < 1 THEN v_invalid := array_append(v_invalid, 'businessDiscovery.customerPainPoints'); END IF;

        IF NOT ('businessDiscovery.desiredOutcomes' = ANY (v_invalid)) AND (
            CASE
                WHEN v_bd IS NOT NULL AND v_bd ? 'desiredOutcomes' AND jsonb_typeof(v_bd->'desiredOutcomes') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd->'desiredOutcomes') e WHERE btrim(e.value) <> '')
                WHEN (v_bd IS NULL OR NOT (v_bd ? 'desiredOutcomes')) AND jsonb_typeof(v_bd_existing->'desiredOutcomes') = 'array'
                    THEN (SELECT count(*) FROM jsonb_array_elements_text(v_bd_existing->'desiredOutcomes') e WHERE btrim(e.value) <> '')
                ELSE 0
            END
        ) < 1 THEN v_invalid := array_append(v_invalid, 'businessDiscovery.desiredOutcomes'); END IF;
    END IF;

    IF cardinality(v_invalid) > 0 THEN
        RETURN jsonb_build_object('status', 'invalid', 'fields', to_jsonb(v_invalid));
    END IF;

    v_bd_new := jsonb_build_object('schemaVersion', 1);

    IF v_bd IS NOT NULL AND v_bd ? 'productsOrServices' AND jsonb_typeof(v_bd->'productsOrServices') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('productsOrServices', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd->'productsOrServices') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_bd_existing->'productsOrServices') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('productsOrServices', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd_existing->'productsOrServices') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;

    IF v_bd IS NOT NULL AND v_bd ? 'customerPainPoints' AND jsonb_typeof(v_bd->'customerPainPoints') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('customerPainPoints', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd->'customerPainPoints') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_bd_existing->'customerPainPoints') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('customerPainPoints', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd_existing->'customerPainPoints') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;

    IF v_bd IS NOT NULL AND v_bd ? 'desiredOutcomes' AND jsonb_typeof(v_bd->'desiredOutcomes') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('desiredOutcomes', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd->'desiredOutcomes') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_bd_existing->'desiredOutcomes') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('desiredOutcomes', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd_existing->'desiredOutcomes') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;

    IF v_bd IS NOT NULL AND v_bd ? 'opportunityFocus' AND jsonb_typeof(v_bd->'opportunityFocus') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('opportunityFocus', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd->'opportunityFocus') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_bd_existing->'opportunityFocus') = 'array' THEN
        v_bd_new := v_bd_new || jsonb_build_object('opportunityFocus', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_bd_existing->'opportunityFocus') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;

    IF v_bd IS NOT NULL AND v_bd ? 'differentiation' THEN
        v_bd_new := v_bd_new || jsonb_build_object('differentiation', nullif(btrim(v_bd->>'differentiation'), ''));
    ELSIF jsonb_typeof(v_bd_existing->'differentiation') = 'string' THEN
        v_bd_new := v_bd_new || jsonb_build_object('differentiation', nullif(btrim(v_bd_existing->>'differentiation'), ''));
    END IF;

    v_con_existing := CASE WHEN jsonb_typeof(v_bd_existing -> 'constraints') = 'object' THEN v_bd_existing -> 'constraints' ELSE '{}'::jsonb END;
    v_con_new := jsonb_build_object();
    FOR k IN SELECT unnest(ARRAY['budgetRange','teamCapacity','timeCapacity']) LOOP
        IF v_con IS NOT NULL AND v_con ? k THEN
            v_con_new := v_con_new || jsonb_build_object(k, nullif(btrim(v_con->>k), ''));
        ELSIF jsonb_typeof(v_con_existing->k) = 'string' THEN
            v_con_new := v_con_new || jsonb_build_object(k, nullif(btrim(v_con_existing->>k), ''));
        END IF;
    END LOOP;
    IF v_con IS NOT NULL AND v_con ? 'geographicFocus' AND jsonb_typeof(v_con->'geographicFocus') = 'array' THEN
        v_con_new := v_con_new || jsonb_build_object('geographicFocus', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_con->'geographicFocus') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    ELSIF jsonb_typeof(v_con_existing->'geographicFocus') = 'array' THEN
        v_con_new := v_con_new || jsonb_build_object('geographicFocus', (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(v_con_existing->'geographicFocus') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d));
    END IF;
    IF v_con_new <> jsonb_build_object() THEN
        v_bd_new := v_bd_new || jsonb_build_object('constraints', v_con_new);
    END IF;

    v_new_opp := (CASE WHEN jsonb_typeof(v_bp.opportunity_preferences) = 'object'
                       THEN v_bp.opportunity_preferences ELSE '{}'::jsonb END)
                 || jsonb_build_object('businessDiscovery', v_bd_new);

    UPDATE public.business_profiles SET
        user_id = v_uid,
        business_name       = CASE WHEN p_content ? 'business_name'       THEN nullif(btrim(p_content->>'business_name'), '')       ELSE business_name END,
        website             = CASE WHEN p_content ? 'website'             THEN nullif(btrim(p_content->>'website'), '')             ELSE website END,
        country             = CASE WHEN p_content ? 'country'             THEN nullif(btrim(p_content->>'country'), '')             ELSE country END,
        industry            = CASE WHEN p_content ? 'industry'            THEN nullif(btrim(p_content->>'industry'), '')            ELSE industry END,
        business_type       = CASE WHEN p_content ? 'business_type'       THEN nullif(btrim(p_content->>'business_type'), '')       ELSE business_type END,
        company_size        = CASE WHEN p_content ? 'company_size'        THEN nullif(btrim(p_content->>'company_size'), '')        ELSE company_size END,
        target_audience     = CASE WHEN p_content ? 'target_audience'     THEN nullif(btrim(p_content->>'target_audience'), '')     ELSE target_audience END,
        primary_goal        = CASE WHEN p_content ? 'primary_goal'        THEN nullif(btrim(p_content->>'primary_goal'), '')        ELSE primary_goal END,
        preferred_platforms = CASE WHEN p_content ? 'preferred_platforms' AND jsonb_typeof(p_content->'preferred_platforms') = 'array' THEN
            (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(p_content->'preferred_platforms') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d)
            ELSE preferred_platforms END,
        competitors         = CASE WHEN p_content ? 'competitors' AND jsonb_typeof(p_content->'competitors') = 'array' THEN
            (SELECT coalesce(jsonb_agg(d.v ORDER BY d.v), '[]'::jsonb) FROM (SELECT DISTINCT ON (lower(btrim(ae.value))) btrim(ae.value) AS v FROM jsonb_array_elements_text(p_content->'competitors') AS ae WHERE btrim(ae.value) <> '' ORDER BY lower(btrim(ae.value)), btrim(ae.value)) AS d)
            ELSE competitors END,
        brief_frequency     = CASE WHEN p_content ? 'brief_frequency'     THEN nullif(btrim(p_content->>'brief_frequency'), '')     ELSE brief_frequency END,
        brand_voice         = CASE WHEN p_content ? 'brand_voice'         THEN nullif(btrim(p_content->>'brand_voice'), '')         ELSE brand_voice END,
        business_summary    = CASE WHEN p_content ? 'business_summary'    THEN nullif(btrim(p_content->>'business_summary'), '')    ELSE business_summary END,
        positioning_summary = CASE WHEN p_content ? 'positioning_summary' THEN nullif(btrim(p_content->>'positioning_summary'), '') ELSE positioning_summary END,
        business_category   = CASE WHEN p_content ? 'business_category'   THEN nullif(btrim(p_content->>'business_category'), '')   ELSE business_category END,
        opportunity_preferences = v_new_opp,
        updated_at          = now()
    WHERE application_id = v_app
    RETURNING * INTO v_bp;

    v_ds_status := CASE WHEN p_complete THEN 'complete' ELSE 'in_progress' END;
    UPDATE public.discovery_state SET status = v_ds_status WHERE member_id = v_member_id;
    GET DIAGNOSTICS v_ds_rows = ROW_COUNT;
    IF v_ds_rows <> 1 THEN
        RAISE EXCEPTION 'discovery_state cardinality violation' USING ERRCODE = 'P0001';
    END IF;

    RETURN jsonb_build_object(
        'status', 'saved',
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
            'business_category', v_bp.business_category,
            'businessDiscovery', coalesce(v_bp.opportunity_preferences -> 'businessDiscovery', 'null'::jsonb)
        )
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('status', 'temporary_failure');
END;
$function$;

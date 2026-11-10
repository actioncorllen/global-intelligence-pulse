-- Verbatim security functions, extracted from the repo migration files actually applied to prod.
-- Parity is verified post-apply via md5(pg_get_functiondef) local-vs-prod.

-- ===== from mig_240_ecommerce_workspace_connection.sql =====
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
    v_bd           jsonb;   -- submitted businessDiscovery (object or NULL)
    v_con          jsonb;   -- submitted constraints (object or NULL)
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

    -- 1. Reject unknown top-level client keys.
    FOR k IN SELECT jsonb_object_keys(p_content) LOOP
        IF NOT (k = ANY (c_top)) THEN v_invalid := array_append(v_invalid, k); END IF;
    END LOOP;

    -- 2. Validate top-level text fields (present -> string|null, bounded length).
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

    -- 2b. Validate business_category (013A): present -> string in the ACTIVE approved catalog, or null.
    IF p_content ? 'business_category' AND NOT (
        jsonb_typeof(p_content->'business_category') IN ('string','null')
        AND (jsonb_typeof(p_content->'business_category') <> 'string'
             OR EXISTS (SELECT 1 FROM public.business_category c
                        WHERE c.is_active AND c.code = btrim(p_content->>'business_category')))
    ) THEN v_invalid := array_append(v_invalid, 'business_category'); END IF;

    -- 3. Validate top-level string arrays (<=20 string items, each trimmed <=200).
    FOR k IN SELECT unnest(ARRAY['preferred_platforms','competitors']) LOOP
        IF p_content ? k AND NOT (
            jsonb_typeof(p_content->k) = 'array'
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_content->k) e WHERE jsonb_typeof(e.value) <> 'string')
            AND (SELECT count(*) FROM jsonb_array_elements_text(p_content->k)) <= 20
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_content->k) e WHERE length(btrim(e.value)) > 200)
        ) THEN v_invalid := array_append(v_invalid, k); END IF;
    END LOOP;

    -- 4. Validate the submitted businessDiscovery namespace (known keys + shapes).
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

    -- 5. Resolve member (UNIQUE) then profile (UNIQUE), locked.
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

    -- 6. Existing businessDiscovery namespace (approved existing values only).
    v_bd_existing := CASE WHEN jsonb_typeof(v_bp.opportunity_preferences -> 'businessDiscovery') = 'object'
                          THEN v_bp.opportunity_preferences -> 'businessDiscovery' ELSE '{}'::jsonb END;

    -- 7. Completion-required validation (effective = submitted-if-present else existing).
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

    -- 8. INVALID SHORT-CIRCUIT — after ALL validation, before ANY mutation/claim.
    IF cardinality(v_invalid) > 0 THEN
        RETURN jsonb_build_object('status', 'invalid', 'fields', to_jsonb(v_invalid));
    END IF;

    -- 9. Rebuild the CANONICAL businessDiscovery object from an approved-key allowlist.
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

    -- 10. Replace ONLY the businessDiscovery namespace; preserve every other opportunity_preferences key.
    v_new_opp := (CASE WHEN jsonb_typeof(v_bp.opportunity_preferences) = 'object'
                       THEN v_bp.opportunity_preferences ELSE '{}'::jsonb END)
                 || jsonb_build_object('businessDiscovery', v_bd_new);

    -- 11. Atomically claim (NULL->uid) and update ONLY approved contract columns (partial-save safe).
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

    -- 12. Atomic discovery_state transition — EXACTLY one row must update.
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

-- ===== from mig_331_phase0309_tenant_safe_notifications.sql =====
CREATE OR REPLACE FUNCTION public.get_own_notifications(p_limit integer DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_limit integer := greatest(1, least(coalesce(p_limit,30), 100));
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status','unauthenticated','items',jsonb_build_array(),'unread_count',0);
  END IF;
  RETURN jsonb_build_object(
    'status','ok',
    'unread_count', (SELECT count(*) FROM public.pulse_notifications WHERE user_id=v_uid AND read_at IS NULL),
    'items', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', s.id, 'kind', s.kind, 'title', s.title, 'body', s.body, 'link', s.link,
        'created_at', s.created_at, 'read', (s.read_at IS NOT NULL)))
      FROM (SELECT * FROM public.pulse_notifications WHERE user_id=v_uid
            ORDER BY (read_at IS NULL) DESC, created_at DESC LIMIT v_limit) s), jsonb_build_array())
  );
END; $function$;

CREATE OR REPLACE FUNCTION public.mark_notification_read(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_n integer;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  UPDATE public.pulse_notifications SET read_at=now() WHERE id=p_id AND user_id=v_uid AND read_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('status','ok','updated',v_n);
END; $function$;

CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_n integer;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  UPDATE public.pulse_notifications SET read_at=now() WHERE user_id=v_uid AND read_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('status','ok','updated',v_n);
END; $function$;

-- ===== from mig_346_mandatory_onboarding_gate.sql =====
CREATE OR REPLACE FUNCTION public.fn_member_onboarding_state(p_auth_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  p            public.onboarding_policy%ROWTYPE;
  v_member     public.member%ROWTYPE;
  v_verified   boolean := false;
  v_bp_done    boolean := false;   -- business profile complete
  v_bill_done  boolean := false;   -- billing profile complete
  v_has        boolean := false;   -- has entitlement
  v_active     boolean := false;   -- entitlement active
  v_confirmed  boolean := false;   -- membership confirmed
  v_ready      boolean := false;   -- workspace (discovery) ready
  v_plan       text;
  v_estatus    text;
  v_state      text;
BEGIN
  SELECT * INTO p FROM public.onboarding_policy WHERE id;

  IF p_auth_user_id IS NULL THEN
    RETURN jsonb_build_object('access_state','AUTH_REQUIRED','authenticated',false,
      'onboarding_enforced', coalesce(p.enforcement_active,false));
  END IF;

  SELECT * INTO v_member FROM public.member WHERE auth_user_id = p_auth_user_id;
  IF NOT FOUND THEN
    -- authenticated but not provisioned: cannot enter workspace
    v_verified := coalesce((SELECT au.email_confirmed_at IS NOT NULL FROM auth.users au WHERE au.id=p_auth_user_id), false);
    RETURN jsonb_build_object(
      'access_state', CASE WHEN NOT v_verified THEN 'EMAIL_VERIFICATION_REQUIRED' ELSE 'ENTITLEMENT_REQUIRED' END,
      'authenticated', true, 'email_verified', v_verified, 'note','no member record',
      'onboarding_enforced', coalesce(p.enforcement_active,false));
  END IF;

  v_verified := coalesce((SELECT au.email_confirmed_at IS NOT NULL FROM auth.users au WHERE au.id=p_auth_user_id), false)
                OR coalesce(v_member.email_verified,false);

  v_bp_done := EXISTS (SELECT 1 FROM public.discovery_state ds
                       WHERE ds.member_id = v_member.id AND ds.status = 'complete');

  v_bill_done := EXISTS (SELECT 1 FROM public.billing_profile b
                         WHERE b.auth_user_id = p_auth_user_id AND b.completed_at IS NOT NULL);

  SELECT true, public.fn_entitlement_active(e.status, e.current_period_end), e.plan_code, e.status
    INTO v_has, v_active, v_plan, v_estatus
  FROM public.account_entitlement e WHERE e.auth_user_id = p_auth_user_id;
  v_has := coalesce(v_has,false); v_active := coalesce(v_active,false);

  v_confirmed := v_member.membership_confirmed_at IS NOT NULL;

  v_ready := coalesce((SELECT ds.analysis_status='ready' FROM public.discovery_state ds WHERE ds.member_id=v_member.id), false);

  -- Ordered gate. The three enforced steps apply ONLY when enforcement_active.
  v_state := CASE
    WHEN NOT v_verified THEN 'EMAIL_VERIFICATION_REQUIRED'
    WHEN p.enforcement_active AND p.require_business_profile       AND NOT v_bp_done   THEN 'BUSINESS_PROFILE_REQUIRED'
    WHEN p.enforcement_active AND p.require_billing_profile        AND NOT v_bill_done THEN 'BILLING_PROFILE_REQUIRED'
    WHEN NOT v_has    THEN 'ENTITLEMENT_REQUIRED'
    WHEN NOT v_active THEN 'ENTITLEMENT_INACTIVE'
    WHEN p.enforcement_active AND p.require_membership_confirmation AND NOT v_confirmed THEN 'MEMBERSHIP_CONFIRMATION_REQUIRED'
    WHEN NOT v_ready  THEN 'WORKSPACE_PREPARING'
    ELSE 'READY'
  END;

  RETURN jsonb_build_object(
    'access_state', v_state,
    'authenticated', true,
    'email_verified', v_verified,
    'business_profile_complete', v_bp_done,
    'billing_profile_complete', v_bill_done,
    'has_entitlement', v_has,
    'entitlement_active', v_active,
    'plan_code', v_plan,
    'entitlement_status', v_estatus,
    'membership_confirmed', v_confirmed,
    'workspace_ready', v_ready,
    'onboarding_enforced', coalesce(p.enforcement_active,false));
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_workspace_access()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT public.fn_member_onboarding_state(auth.uid());
$function$;

CREATE OR REPLACE FUNCTION public.fn_workspace_entry_allowed(p_auth_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT (public.fn_member_onboarding_state(p_auth_user_id) ->> 'access_state') = 'READY';
$function$;

CREATE OR REPLACE FUNCTION public.get_own_billing_profile()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); b public.billing_profile%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO b FROM public.billing_profile WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','ok','completed',false,'profile',NULL);
  END IF;
  RETURN jsonb_build_object('status','ok','completed', b.completed_at IS NOT NULL,
    'profile', jsonb_build_object(
      'legal_name',b.legal_name,'billing_email',b.billing_email,'country',b.country,
      'address_line1',b.address_line1,'address_line2',b.address_line2,'city',b.city,
      'region',b.region,'postal_code',b.postal_code,'tax_id',b.tax_id,'is_business',b.is_business,
      'billing_kind',b.billing_kind,'currency',b.currency,'amount_minor',b.amount_minor));
END; $function$;

CREATE OR REPLACE FUNCTION public.save_billing_profile(p_content jsonb, p_complete boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_member public.member%ROWTYPE;
  v_kind text := 'COMP';
  v_currency text;
  v_invalid text[] := ARRAY[]::text[];
  k text;
  c_allowed constant text[] := ARRAY['legal_name','billing_email','country','address_line1',
    'address_line2','city','region','postal_code','tax_id','is_business'];
  eff_name text; eff_email text; eff_country text;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF jsonb_typeof(p_content) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('status','invalid','fields',jsonb_build_array('content')); END IF;

  -- reject any unknown key, and hard-reject any card/payment-credential-looking key
  FOR k IN SELECT jsonb_object_keys(p_content) LOOP
    IF k ~* '(card|cvv|cvc|pan|number|sort_code|iban|account_number|routing|secret|cvn)' THEN
      RETURN jsonb_build_object('status','rejected','reason','payment_credentials_not_accepted');
    END IF;
    IF NOT (k = ANY(c_allowed)) THEN v_invalid := array_append(v_invalid,k); END IF;
  END LOOP;
  IF cardinality(v_invalid) > 0 THEN
    RETURN jsonb_build_object('status','invalid','fields',to_jsonb(v_invalid)); END IF;

  SELECT * INTO v_member FROM public.member WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_member'); END IF;

  -- COMP vs PAID follows the member's entitlement source (COMP => €0, no charge)
  SELECT CASE WHEN e.source='PROVIDER' THEN 'PAID' ELSE 'COMP' END, e.currency
    INTO v_kind, v_currency
  FROM public.account_entitlement e WHERE e.auth_user_id = v_uid;
  v_kind := coalesce(v_kind,'COMP');

  INSERT INTO public.billing_profile
    (auth_user_id, member_id, legal_name, billing_email, country, address_line1, address_line2,
     city, region, postal_code, tax_id, is_business, billing_plan_code, billing_kind, currency, amount_minor)
  VALUES (v_uid, v_member.id,
     nullif(btrim(p_content->>'legal_name'),''), nullif(btrim(p_content->>'billing_email'),''),
     nullif(btrim(p_content->>'country'),''), nullif(btrim(p_content->>'address_line1'),''),
     nullif(btrim(p_content->>'address_line2'),''), nullif(btrim(p_content->>'city'),''),
     nullif(btrim(p_content->>'region'),''), nullif(btrim(p_content->>'postal_code'),''),
     nullif(btrim(p_content->>'tax_id'),''),
     coalesce((p_content->>'is_business')::boolean, true),
     'ecommerce_monthly', v_kind, v_currency, 0)
  ON CONFLICT (auth_user_id) DO UPDATE SET
     member_id = EXCLUDED.member_id,
     legal_name = coalesce(EXCLUDED.legal_name, public.billing_profile.legal_name),
     billing_email = coalesce(EXCLUDED.billing_email, public.billing_profile.billing_email),
     country = coalesce(EXCLUDED.country, public.billing_profile.country),
     address_line1 = coalesce(EXCLUDED.address_line1, public.billing_profile.address_line1),
     address_line2 = coalesce(EXCLUDED.address_line2, public.billing_profile.address_line2),
     city = coalesce(EXCLUDED.city, public.billing_profile.city),
     region = coalesce(EXCLUDED.region, public.billing_profile.region),
     postal_code = coalesce(EXCLUDED.postal_code, public.billing_profile.postal_code),
     tax_id = coalesce(EXCLUDED.tax_id, public.billing_profile.tax_id),
     is_business = EXCLUDED.is_business,
     billing_kind = EXCLUDED.billing_kind,
     currency = EXCLUDED.currency,
     amount_minor = 0,
     updated_at = now();

  IF p_complete THEN
    SELECT legal_name, billing_email, country INTO eff_name, eff_email, eff_country
      FROM public.billing_profile WHERE auth_user_id = v_uid;
    IF eff_name IS NULL THEN v_invalid := array_append(v_invalid,'legal_name'); END IF;
    IF eff_email IS NULL THEN v_invalid := array_append(v_invalid,'billing_email'); END IF;
    IF eff_country IS NULL THEN v_invalid := array_append(v_invalid,'country'); END IF;
    IF cardinality(v_invalid) > 0 THEN
      RETURN jsonb_build_object('status','invalid','fields',to_jsonb(v_invalid)); END IF;
    UPDATE public.billing_profile SET completed_at = coalesce(completed_at, now()), updated_at = now()
      WHERE auth_user_id = v_uid;
  END IF;

  RETURN jsonb_build_object('status','saved','completed',
    (SELECT completed_at IS NOT NULL FROM public.billing_profile WHERE auth_user_id=v_uid),
    'billing_kind', v_kind, 'amount_minor', 0);
END; $function$;

CREATE OR REPLACE FUNCTION public.confirm_membership()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_member public.member%ROWTYPE;
  v_bp_done boolean; v_bill_done boolean; v_active boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT * INTO v_member FROM public.member WHERE auth_user_id = v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_member'); END IF;

  IF v_member.membership_confirmed_at IS NOT NULL THEN
    RETURN jsonb_build_object('status','ok','outcome','already_confirmed'); END IF;

  v_bp_done := EXISTS (SELECT 1 FROM public.discovery_state ds WHERE ds.member_id=v_member.id AND ds.status='complete');
  v_bill_done := EXISTS (SELECT 1 FROM public.billing_profile b WHERE b.auth_user_id=v_uid AND b.completed_at IS NOT NULL);
  v_active := coalesce((SELECT public.fn_entitlement_active(e.status,e.current_period_end)
                        FROM public.account_entitlement e WHERE e.auth_user_id=v_uid), false);

  IF NOT v_active THEN RETURN jsonb_build_object('status','blocked','reason','no_active_membership'); END IF;
  IF NOT v_bp_done THEN RETURN jsonb_build_object('status','blocked','reason','business_profile_incomplete'); END IF;
  IF NOT v_bill_done THEN RETURN jsonb_build_object('status','blocked','reason','billing_profile_incomplete'); END IF;

  UPDATE public.member SET membership_confirmed_at = now(), updated_at = now() WHERE id = v_member.id;
  RETURN jsonb_build_object('status','ok','outcome','confirmed','confirmed_at', now());
END; $function$;

-- ===== from mig_347_appless_business_profile.sql =====
CREATE OR REPLACE FUNCTION public.fn_ensure_member_business_profile()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid     uuid := auth.uid();
  v_member  public.member%ROWTYPE;
  v_app     uuid;
  v_app_new uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;

  SELECT * INTO v_member FROM public.member WHERE auth_user_id = v_uid;   -- identity from auth.uid()
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_member'); END IF;

  -- Serialize per member so concurrent calls cannot create duplicate backfills.
  PERFORM 1 FROM public.member WHERE id = v_member.id FOR UPDATE;
  SELECT application_ref INTO v_app FROM public.member WHERE id = v_member.id;

  IF v_app IS NOT NULL THEN
    -- Already application-linked (normal applicant). The approval step created the
    -- business profile; never touch an existing application-linked profile.
    RETURN jsonb_build_object('status','ok','mode','application_linked','application_ref',v_app);
  END IF;

  -- Application-less member: create a clearly-marked backfill application (status
  -- 'accepted' so it never appears in the issuable 'new' queue) + an owned business
  -- profile, then link the member. Cross-tenant safe (keyed to this auth.uid()).
  INSERT INTO public.founding_applications (first_name, last_name, work_email, status, source)
  VALUES ('Direct', 'Member', coalesce(v_member.email,'unknown@direct.invalid'),
          'accepted', 'direct_invite_backfill')
  RETURNING id INTO v_app_new;

  INSERT INTO public.business_profiles (application_id, user_id, country)
  VALUES (v_app_new, v_uid, NULL);

  UPDATE public.member SET application_ref = v_app_new, updated_at = now() WHERE id = v_member.id;

  RETURN jsonb_build_object('status','ok','mode','backfilled','application_ref',v_app_new);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status','temporary_failure');
END; $function$;

-- ===== from mig_348_workspace_api_gate.sql =====
CREATE OR REPLACE FUNCTION public.fn_onboarding_complete(p_auth_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT (public.fn_member_onboarding_state(p_auth_user_id) ->> 'access_state')
         IN ('WORKSPACE_PREPARING','READY');
$function$;

-- ===== from mig_351_gate_covers_direct_tables.sql =====
CREATE OR REPLACE FUNCTION public.fn_pre_request_gate()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_enf      boolean;
  v_role     text;
  v_path     text;
  v_p        text;
  v_first    text;
  v_fname    text;
  v_is_rpc   boolean := false;
  v_allowed  boolean := false;
  v_uid      uuid;
  v_complete boolean;
  -- RPCs an incomplete member may call (onboarding / status / recovery).
  c_rpc_allow constant text[] := ARRAY[
    'fn_workspace_access','fn_entitlement_status',
    'fn_ensure_member_business_profile','get_own_business_profile','save_business_profile',
    'get_own_billing_profile','save_billing_profile','confirm_membership',
    'get_own_notifications','mark_notification_read','mark_all_notifications_read',
    'fn_global_intelligence_uid'
  ];
  -- Table endpoints an incomplete member may reach: own identity/session, onboarding data,
  -- notifications, public reference / marketing, and own telemetry. Everything else (workspace
  -- data: commerce_*, product_acquisitions, saved_opportunities, marketing_*, creative_*,
  -- discovery_runs, member_* data, social_*, store/page tables, …) is denied until onboarded.
  c_tbl_allow constant text[] := ARRAY[
    'member','users','business_profiles','billing_profile','discovery_state','pulse_notifications',
    'business_category','build_updates','roadmap_items','opportunities',
    'conversion_hero_variants','conversion_section_types','conversion_template_families',
    'creative_format_registry','provider_capability_registry',
    'analytics_events','engagement_patterns','demo_events','pulse_guide_events'
  ];
BEGIN
  -- 1. Enforcement state FIRST: definite OFF → no-op for the entire Data API (unchanged behaviour).
  BEGIN
    SELECT enforcement_active INTO v_enf FROM public.onboarding_policy WHERE id;
  EXCEPTION WHEN OTHERS THEN
    v_enf := NULL;                                           -- unreadable → treat as enforcing
  END;
  IF v_enf IS FALSE THEN
    RETURN;
  END IF;

  -- 2. anon / service_role are never gated (public access + privileged/operational jobs).
  BEGIN
    v_role := coalesce(
      nullif(current_setting('request.jwt.claim.role', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'));
  EXCEPTION WHEN OTHERS THEN
    v_role := NULL;                                          -- unknown → treated as protected end-user
  END;
  IF v_role IN ('anon','service_role') THEN
    RETURN;
  END IF;

  -- 3. Classify the request resource (robust to '/x', '/rest/v1/x', '/rpc/fn', '/rest/v1/rpc/fn').
  v_path := coalesce(current_setting('request.path', true), '');
  v_p := regexp_replace(v_path, '^/+', '');
  v_p := regexp_replace(v_p, '^rest/v1/', '');
  v_first := regexp_replace(v_p, '[/?].*$', '');
  IF v_first = 'rpc' THEN
    v_is_rpc := true;
    v_fname := regexp_replace(regexp_replace(v_p, '^rpc/', ''), '[?/].*$', '');
  END IF;

  -- 4. Allow-list (onboarding/recovery/status RPCs, or onboarding/session/reference tables).
  IF v_is_rpc THEN
    v_allowed := (v_fname = ANY (c_rpc_allow));
  ELSE
    v_allowed := (v_first = ANY (c_tbl_allow));
  END IF;
  IF v_allowed THEN
    RETURN;
  END IF;

  -- 5. Protected resource. Allow ONLY a member whose onboarding is definitely complete.
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    v_uid := NULL;
  END;
  IF v_uid IS NOT NULL THEN
    BEGIN
      v_complete := public.fn_onboarding_complete(v_uid);
    EXCEPTION WHEN OTHERS THEN
      v_complete := NULL;
    END;
    IF v_complete IS TRUE THEN
      RETURN;
    END IF;
  END IF;

  -- 6. Fail CLOSED: incomplete onboarding, or completeness could not be positively determined.
  RAISE EXCEPTION 'onboarding_incomplete'
    USING ERRCODE = '42501',
          HINT = 'Complete member onboarding (business profile, billing profile, membership confirmation) to access the workspace.';
END; $function$;


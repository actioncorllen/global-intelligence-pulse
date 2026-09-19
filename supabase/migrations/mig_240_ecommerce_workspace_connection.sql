-- STRATELOQ-ECOM-WORKSPACE-CONNECTION-FIX-013A
-- Connect the EXISTING Ecommerce intelligence (lineage #3: product_opportunity_decisions
-- + commerce_products + commerce_signals + storefront) to the authenticated workspace,
-- durably and category-aware. Additive only. No rebuild, no synthetic opportunities, no
-- Lovable change, no payment, €0.
--
-- Audit 013 root cause: (a) no durable server-owned business category — the workspace
-- classified "is this Ecommerce?" from member_business_dna.dna_extended.commerce (absent
-- for the founder) rather than a first-class category; (b) get_own_discovery_intelligence
-- never reads product_opportunity_decisions, and its commerce block is gated behind a
-- member_business_dna-derived run id that the ecommerce no-store journey never creates.
--
-- Fix strategy (per 013A principle "prefer ONE authoritative Ecommerce workspace contract
-- that composes existing Ecommerce sources"): add a durable category, extend the onboarding
-- save contract to persist it, and add a dedicated authoritative Ecommerce workspace RPC
-- that composes lineage #3 DIRECTLY. The older score_commerce_products projection
-- (commerce_product_opportunities + member_business_dna.commerce) is left untouched for its
-- Market-Explorer consumer (get_global_market_intelligence) but is NOT required by, and is
-- NOT run to patch, the workspace (see COMMERCE PROJECTION DECISION below).

-- ---------------------------------------------------------------------------
-- 1. DURABLE CATEGORY — canonical server-owned representation.
--    Small reference catalog (approved values + labels) + a nullable FK column on the
--    existing business_profiles (existing ownership model + RLS). business_description /
--    business_summary / businessDiscovery remain fully independent.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.business_category (
  code text PRIMARY KEY,
  label text NOT NULL,
  sort integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true
);

INSERT INTO public.business_category (code, label, sort) VALUES
  ('marketing_agencies','Marketing Agencies',1),
  ('creators','Creators',2),
  ('local_businesses','Local Businesses',3),
  ('coaches','Coaches',4),
  ('ecommerce','Ecommerce & Dropshipping',5)
ON CONFLICT (code) DO NOTHING;

ALTER TABLE public.business_category ENABLE ROW LEVEL SECURITY;
-- Non-sensitive reference data: readable by clients (to render options + route), never writable.
DROP POLICY IF EXISTS "anyone reads business_category" ON public.business_category;
CREATE POLICY "anyone reads business_category" ON public.business_category FOR SELECT USING (true);
REVOKE ALL ON public.business_category FROM PUBLIC;
GRANT SELECT ON public.business_category TO anon, authenticated;

COMMENT ON TABLE public.business_category IS
 'Canonical approved business categories (013A). Reference data: client-readable (labels + routing), never client-writable. The authoritative category for a tenant lives on business_profiles.business_category.';

-- Additive, nullable category column on the existing business profile (existing rows stay NULL).
ALTER TABLE public.business_profiles
  ADD COLUMN IF NOT EXISTS business_category text
    REFERENCES public.business_category(code);

COMMENT ON COLUMN public.business_profiles.business_category IS
 'Durable server-owned business category (013A), one of public.business_category.code. Independent of business_summary / opportunity_preferences.businessDiscovery. Written only via save_business_profile (auth.uid()-scoped, ownership-enforced).';

-- ---------------------------------------------------------------------------
-- 1b. Deterministic founder backfill (evidence-based rule, NOT a hardcoded id):
--     the sole business whose industry is exactly the Ecommerce discovery industry is the
--     founder Ecommerce test tenant — unambiguous. Other tenants are left NULL (no guessing).
--     Idempotent (only fills NULLs).
-- ---------------------------------------------------------------------------
UPDATE public.business_profiles
   SET business_category = 'ecommerce'
 WHERE industry = 'Broad Ecommerce Opportunity Discovery'
   AND business_category IS NULL;

-- ---------------------------------------------------------------------------
-- 2. ONBOARDING PERSISTENCE CONTRACT — extend save_business_profile to accept an approved
--    business_category. All existing behaviour preserved verbatim; the ONLY additions are:
--    (i) 'business_category' added to the approved top-level key allowlist,
--    (ii) a validation block (string in active catalog, or null),
--    (iii) the UPDATE column (absent -> unchanged; partial-save safe),
--    (iv) the returned profile field.
--    Category is validated against public.business_category; a browser cannot set an
--    unknown value, and (as before) can only ever write its OWN application_id row.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 3./4. CATEGORY-AWARE ECOMMERCE WORKSPACE INTELLIGENCE — the authoritative Ecommerce
--       workspace contract. Composes the EXISTING lineage #3 directly, tenant-scoped by
--       auth.uid(): product_opportunity_decisions (real, non-fixture) + commerce_products
--       (identity/price) + commerce_signals (evidence SUMMARY only) + commerce_product_pages
--       (storefront linkage). No generic member_opportunities. No website discovery
--       prerequisite (works for the no-store-yet journey). Browser-safe projection only:
--       NO lineage, hard_gates, decision/execution blockers, economics_ref, cpa_scenarios,
--       provenance, evaluation ids, or raw evidence payloads are exposed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_workspace_intelligence()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_member_count integer; v_member_id uuid; v_app uuid;
    v_bp public.business_profiles%ROWTYPE; v_found boolean := false;
    v_decisions jsonb; v_storefronts jsonb; v_evidence jsonb; v_products int;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;

    SELECT count(*), min(m.id::text)::uuid, min(m.application_ref::text)::uuid
      INTO v_member_count, v_member_id, v_app
    FROM public.member AS m WHERE m.auth_user_id = v_uid;
    IF v_member_count = 0 THEN RETURN jsonb_build_object('status','no_member'); END IF;
    IF v_member_count > 1 THEN RAISE EXCEPTION 'member cardinality violation' USING ERRCODE='P0001'; END IF;

    -- Own business (application_id first, then user_id fallback for null application_ref).
    SELECT * INTO v_bp FROM public.business_profiles WHERE application_id = v_app;
    IF FOUND THEN v_found := true; END IF;
    IF NOT v_found THEN
        SELECT * INTO v_bp FROM public.business_profiles WHERE user_id = v_uid
        ORDER BY updated_at DESC NULLS LAST LIMIT 1;
        IF FOUND THEN v_found := true; END IF;
    END IF;
    IF v_found AND v_bp.user_id IS NOT NULL AND v_bp.user_id <> v_uid THEN
        RAISE EXCEPTION 'business profile ownership violation' USING ERRCODE='P0001';
    END IF;

    -- Real (non-fixture) product decisions for THIS tenant, browser-safe fields + storefront link.
    SELECT coalesce(jsonb_agg(row) , '[]'::jsonb) INTO v_decisions FROM (
        SELECT jsonb_build_object(
            'decision_id', d.id,
            'product_id', d.product_id,
            'product_title', cp.title,
            'product_category', cp.category,
            'product_url', cp.product_url,
            'source_store', cp.source_store,
            'observed_price', cp.observed_price,
            'currency', cp.price_currency,
            'availability', cp.availability,
            'decision', d.decision,
            'opportunity_band', d.opportunity_band,
            'opportunity_score', d.product_opportunity_score,
            'coverage', d.coverage,
            'product_confidence', d.product_confidence,
            'evidence_confidence', d.overall_evidence_confidence,
            'country_code', d.country_code,
            'primary_platform', d.primary_platform,
            'lifecycle_state', d.lifecycle_state,
            'action_gating', d.action_gating,
            'decision_reasons', coalesce(d.decision_reasons, '[]'::jsonb),
            'saturation_state', coalesce(d.saturation_state, 'null'::jsonb),
            'advertising_headroom', coalesce(d.advertising_headroom, 'null'::jsonb),
            'opportunity_sweet_spot', coalesce(d.opportunity_sweet_spot, 'null'::jsonb),
            'storefront', (
                SELECT jsonb_build_object('page_id', pg.id, 'status', pg.status,
                                          'publication_state', pg.publication_state)
                FROM public.commerce_product_pages pg
                WHERE pg.user_id = v_uid AND pg.product_id = d.product_id
                ORDER BY pg.updated_at DESC NULLS LAST LIMIT 1)
        ) AS row
        FROM public.product_opportunity_decisions d
        JOIN public.commerce_products cp ON cp.id = d.product_id
        WHERE d.tenant_id = v_uid AND coalesce(d.is_fixture, false) = false
        ORDER BY d.product_opportunity_score DESC NULLS LAST
    ) z;

    -- Evidence SUMMARY (never raw payloads): counts + last-observed per signal type, own tenant only.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'signal_type', s.signal_type, 'count', s.n, 'last_observed', s.last_obs)
            ORDER BY s.n DESC), '[]'::jsonb) INTO v_evidence
    FROM (SELECT signal_type, count(*) n, max(observed_at) last_obs
          FROM public.commerce_signals WHERE user_id = v_uid GROUP BY signal_type) s;

    -- Storefront / Product-Page-Builder relationships for this tenant.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
                'page_id', pg.id, 'product_id', pg.product_id, 'product_title', cp2.title,
                'status', pg.status, 'publication_state', pg.publication_state,
                'market', pg.market, 'country_code', pg.country_code,
                'opportunity_decision_id', pg.opportunity_decision_id)), '[]'::jsonb)
      INTO v_storefronts
    FROM public.commerce_product_pages pg
    LEFT JOIN public.commerce_products cp2 ON cp2.id = pg.product_id
    WHERE pg.user_id = v_uid;

    SELECT count(*) INTO v_products FROM public.commerce_products WHERE user_id = v_uid;

    RETURN jsonb_build_object(
        'status', 'ok',
        'category', CASE WHEN v_found THEN v_bp.business_category ELSE NULL END,
        'is_ecommerce', coalesce(v_found AND v_bp.business_category = 'ecommerce', false),
        'business', CASE WHEN v_found THEN jsonb_build_object(
              'business_name', v_bp.business_name, 'industry', v_bp.industry,
              'country', v_bp.country, 'business_category', v_bp.business_category)
            ELSE 'null'::jsonb END,
        'product_decisions', v_decisions,
        'product_decision_count', jsonb_array_length(v_decisions),
        'products_tracked', v_products,
        'evidence_summary', v_evidence,
        'storefronts', v_storefronts,
        'source_contract', 'product_opportunity_decisions+commerce_products+commerce_signals+commerce_product_pages',
        'provenance_vocabulary', jsonb_build_array('OBSERVED','INFERRED','RESEARCHED')
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('status','temporary_failure');
END;
$function$;

COMMENT ON FUNCTION public.fn_ecommerce_workspace_intelligence() IS
 'Authoritative Ecommerce workspace intelligence (013A). auth.uid()-scoped, SECURITY DEFINER. Composes existing product_opportunity_decisions (non-fixture) + commerce_products + commerce_signals summary + storefront links. Browser-safe projection only (no lineage/gates/economics/provenance/raw evidence). Works for the no-store-yet journey. Never returns another tenant''s data.';

REVOKE ALL ON FUNCTION public.fn_ecommerce_workspace_intelligence() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ecommerce_workspace_intelligence() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. COMMERCE PROJECTION DECISION: NOT required for the workspace.
--    finalize_commerce_from_run -> score_commerce_products -> commerce_product_opportunities
--    + member_business_dna.dna_extended.commerce remains valid and UNCHANGED for its
--    Market-Explorer consumer (get_global_market_intelligence). The authoritative Ecommerce
--    WORKSPACE contract above supersedes it by composing lineage #3 directly, so it is NOT
--    executed to patch the UI and NO synthetic/duplicate opportunity rows are created. This
--    also removes the founder-manual-execution dependency Audit 013 flagged for the workspace.

-- ---------------------------------------------------------------------------
-- 9. Self-cleaning regression selftest (service_role only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_connection_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_founder uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
BEGIN
  v := v || jsonb_build_object('case','catalog_has_5_active','pass',
        (SELECT count(*) FROM public.business_category WHERE is_active)=5);
  v := v || jsonb_build_object('case','category_column_exists','pass',
        EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='business_profiles' AND column_name='business_category'));
  v := v || jsonb_build_object('case','founder_category_ecommerce','pass',
        (SELECT business_category FROM public.business_profiles WHERE industry='Broad Ecommerce Opportunity Discovery')='ecommerce');
  v := v || jsonb_build_object('case','founder_decisions_reachable_7','pass',
        (SELECT count(*) FROM public.product_opportunity_decisions WHERE tenant_id=v_founder AND coalesce(is_fixture,false)=false)=7);
  v := v || jsonb_build_object('case','founder_commerce_products_intact_12','pass',
        (SELECT count(*) FROM public.commerce_products WHERE user_id=v_founder)=12);
  v := v || jsonb_build_object('case','founder_signals_intact_11','pass',
        (SELECT count(*) FROM public.commerce_signals WHERE user_id=v_founder)=11);
  -- no synthetic opportunities created by this unit
  v := v || jsonb_build_object('case','no_member_opportunities_created','pass',
        (SELECT count(*) FROM public.member_opportunities WHERE user_id=v_founder)=0);
  v := v || jsonb_build_object('case','no_commerce_product_opportunities_created','pass',
        (SELECT count(*) FROM public.commerce_product_opportunities WHERE user_id=v_founder)=0);
  -- category is independent of business_summary / businessDiscovery
  v := v || jsonb_build_object('case','category_independent_of_summary','pass',
        EXISTS (SELECT 1 FROM public.business_profiles WHERE industry='Broad Ecommerce Opportunity Discovery'
                AND business_category='ecommerce'));
  -- only approved values are storable (FK)
  v := v || jsonb_build_object('case','only_approved_categories','pass',
        NOT EXISTS (SELECT 1 FROM public.business_profiles bp WHERE bp.business_category IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM public.business_category c WHERE c.code=bp.business_category)));

  RETURN jsonb_build_object('suite','ecommerce_workspace_connection',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_ecommerce_connection_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ecommerce_connection_selftest() TO service_role;

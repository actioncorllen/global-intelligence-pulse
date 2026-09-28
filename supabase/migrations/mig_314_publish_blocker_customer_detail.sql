-- ============================================================================
-- mig_314_publish_blocker_customer_detail.sql
-- STRATELOQ — hosted-store publishing UX: make publish blockers customer-readable
-- and actionable, from the AUTHORITATIVE backend contract. No change to the publish
-- gate logic itself, to what is/ isn't publishable, to Product Asset Lock, the
-- storefront generator or the decision pipeline. Additive only.
--
-- Root cause of "Publishing failed. Nothing was changed. / Try publishing again":
-- fn_storefront_publish and fn_storefront_publish_context already return PRECISE
-- blocker codes (NOT_APPROVED, NOT_GENERATED, ECONOMICS_NOT_VIABLE, CLAIMS_NOT_CLEAN,
-- ASSETS_UNAVAILABLE, DESTINATION_NOT_PULSE_HOSTED), but the frontend collapsed every
-- non-success into one generic error + a blind retry. This migration gives the
-- frontend an authoritative, ordered, customer-facing mapping so it can show the real
-- blocker(s) + the correct resolution action, and reserve retry for transient failure.
--
--   1. fn_storefront_publish_blocker_detail(code) -> { code, priority, retryable,
--        title, message, action_key, action_label } — canonical customer copy + action.
--   2. fn_storefront_publish_context() now also returns, per storefront row:
--        publish_blocker_details (ordered by priority) and primary_blocker.
--   3. fn_storefront_publish_status_blocker(status, reason_codes) maps a
--        fn_storefront_publish status to the same detail (for the post-publish path).
--   4. fn_storefront_publish_ux_selftest() — asserts every known code maps to a
--        non-empty message + action and is non-retryable.
-- Idempotent (CREATE OR REPLACE).
-- ============================================================================

-- 1) Canonical customer-facing blocker copy + resolution action (single source of truth).
--    priority: lower = shown first (build the page, then image, content, economics,
--    then review approval, then destination). retryable: false for every deterministic
--    precheck blocker (retry cannot clear it — a resolution action can).
CREATE OR REPLACE FUNCTION public.fn_storefront_publish_blocker_detail(p_code text)
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $fn$
  SELECT CASE upper(btrim(coalesce(p_code,'')))
    WHEN 'NOT_GENERATED' THEN jsonb_build_object('code','NOT_GENERATED','priority',10,'retryable',false,
      'title','Finish building this page',
      'message','This page''s storefront content has not been generated yet. Complete the builder steps to prepare it for publishing.',
      'action_key','OPEN_BUILDER','action_label','Review page')
    WHEN 'ASSETS_UNAVAILABLE' THEN jsonb_build_object('code','ASSETS_UNAVAILABLE','priority',20,'retryable',false,
      'title','Approved image required',
      'message','An approved, rights-cleared product image is required before this page can be published publicly.',
      'action_key','ADD_APPROVED_IMAGE','action_label','Add approved image')
    WHEN 'CLAIMS_NOT_CLEAN' THEN jsonb_build_object('code','CLAIMS_NOT_CLEAN','priority',30,'retryable',false,
      'title','Content review needed',
      'message','Some wording on this page needs review before it can be published.',
      'action_key','REVIEW_CONTENT','action_label','Review content')
    WHEN 'ECONOMICS_NOT_VIABLE' THEN jsonb_build_object('code','ECONOMICS_NOT_VIABLE','priority',40,'retryable',false,
      'title','Complete required details',
      'message','Complete the required pricing and margin details before publishing.',
      'action_key','FIX_DETAILS','action_label','Complete details')
    WHEN 'NOT_APPROVED' THEN jsonb_build_object('code','NOT_APPROVED','priority',50,'retryable',false,
      'title','Review approval needed',
      'message','This page still needs review approval before it can be published.',
      'action_key','COMPLETE_REVIEW','action_label','Complete review')
    WHEN 'DESTINATION_NOT_PULSE_HOSTED' THEN jsonb_build_object('code','DESTINATION_NOT_PULSE_HOSTED','priority',60,'retryable',false,
      'title','Set publishing destination',
      'message','Set this page''s destination to your Strateloq store before publishing.',
      'action_key','SET_DESTINATION','action_label','Choose destination')
    ELSE jsonb_build_object('code', upper(btrim(coalesce(p_code,'UNKNOWN'))),'priority',900,'retryable',false,
      'title','Not ready to publish',
      'message','This page is not ready to publish yet. Complete the remaining steps in the builder.',
      'action_key','OPEN_BUILDER','action_label','Review page')
  END;
$fn$;

-- 3) Map a fn_storefront_publish status (+ reason_codes) to the same detail, for the
--    post-publish path. Returns NULL for non-precheck outcomes (transient/auth/backend),
--    which the client treats as retryable/transient rather than a deterministic blocker.
CREATE OR REPLACE FUNCTION public.fn_storefront_publish_status_blocker(p_status text, p_reason_codes jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $fn$
  SELECT CASE upper(btrim(coalesce(p_status,'')))
    WHEN 'NOT_APPROVED' THEN public.fn_storefront_publish_blocker_detail('NOT_APPROVED')
    WHEN 'BLOCKED_CLAIM_SAFETY' THEN public.fn_storefront_publish_blocker_detail('CLAIMS_NOT_CLEAN')
    WHEN 'BLOCKED_ASSET_SAFETY' THEN public.fn_storefront_publish_blocker_detail('ASSETS_UNAVAILABLE')
    WHEN 'BLOCKED_PRODUCT_IMAGE_UNAVAILABLE' THEN public.fn_storefront_publish_blocker_detail('ASSETS_UNAVAILABLE')
    WHEN 'BLOCKED_DESTINATION' THEN public.fn_storefront_publish_blocker_detail('DESTINATION_NOT_PULSE_HOSTED')
    WHEN 'BLOCKED_TEST_ELIGIBILITY' THEN
      CASE WHEN coalesce(p_reason_codes,'[]'::jsonb) @> '["REJECT_ECONOMICS_NOT_VIABLE"]'::jsonb
           THEN public.fn_storefront_publish_blocker_detail('ECONOMICS_NOT_VIABLE')
           ELSE public.fn_storefront_publish_blocker_detail('NOT_GENERATED') END
    ELSE NULL
  END;
$fn$;

-- 2) fn_storefront_publish_context: add ordered customer-facing details + a primary blocker.
--    Gate logic and the raw publish_blockers array are unchanged (still authoritative);
--    this only adds a presentation-ready, ordered mapping alongside them.
CREATE OR REPLACE FUNCTION public.fn_storefront_publish_context(p_page_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_rows jsonb := '[]'::jsonb;
  r record;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('status','unauthenticated');
  END IF;

  FOR r IN
    SELECT p.id, p.review_state, p.publication_state, p.destination, p.template_family,
           p.published_url, sp.public_route,
           coalesce(p.page_model->>'product_title', p.runtime_contract->'selection'->>'product_title') AS product_title,
           upper(coalesce(p.review_state,'')) AS rs,
           coalesce(p.runtime_contract->>'generation_state','') AS gen_state,
           upper(coalesce(p.runtime_contract->>'economics_state','')) AS econ_state,
           coalesce((p.runtime_contract->'claim_safety'->>'claim_scan_clean')::boolean, false) AS claim_clean,
           coalesce(p.runtime_contract->>'assets_state','') AS assets_state,
           upper(coalesce(p.destination,'')) AS dest
    FROM public.commerce_product_pages p
    LEFT JOIN public.commerce_store_projects sp ON sp.product_page_id = p.id
    WHERE p.user_id = v_uid
      AND (p_page_id IS NULL OR p.id = p_page_id)
    ORDER BY p.updated_at DESC NULLS LAST
  LOOP
    DECLARE
      v_blockers text[] := ARRAY[]::text[];
      v_ready boolean;
      v_published boolean := (upper(coalesce(r.publication_state,'')) = 'PUBLISHED');
      v_details jsonb;
      v_primary jsonb;
    BEGIN
      IF r.rs NOT IN ('APPROVED','PUBLISHED') THEN v_blockers := array_append(v_blockers, 'NOT_APPROVED'::text); END IF;
      IF r.gen_state <> 'GENERATED' THEN v_blockers := array_append(v_blockers, 'NOT_GENERATED'::text); END IF;
      IF r.econ_state NOT IN ('VIABLE','POSITIVE') THEN v_blockers := array_append(v_blockers, 'ECONOMICS_NOT_VIABLE'::text); END IF;
      IF NOT r.claim_clean THEN v_blockers := array_append(v_blockers, 'CLAIMS_NOT_CLEAN'::text); END IF;
      IF r.assets_state <> 'ASSETS_AVAILABLE' THEN v_blockers := array_append(v_blockers, 'ASSETS_UNAVAILABLE'::text); END IF;
      IF r.dest <> 'PULSE_STORE' THEN v_blockers := array_append(v_blockers, 'DESTINATION_NOT_PULSE_HOSTED'::text); END IF;
      v_ready := (array_length(v_blockers,1) IS NULL);

      -- Ordered, customer-facing blocker details (single authoritative mapping).
      v_details := coalesce((
        SELECT jsonb_agg(d ORDER BY (d->>'priority')::int, d->>'code')
        FROM (SELECT public.fn_storefront_publish_blocker_detail(b) AS d FROM unnest(v_blockers) AS b) t
      ), '[]'::jsonb);
      v_primary := CASE WHEN jsonb_array_length(v_details) > 0 THEN v_details->0 ELSE NULL END;

      v_rows := v_rows || jsonb_build_object(
        'page_id', r.id,
        'product_title', r.product_title,
        'template_family', r.template_family,
        'review_state', r.review_state,
        'publication_state', r.publication_state,
        'destination', r.destination,
        'destination_kind', CASE WHEN r.dest='PULSE_STORE' THEN 'PULSE_HOSTED' ELSE r.destination END,
        'publish_ready', v_ready,
        'publish_blockers', to_jsonb(v_blockers),
        'publish_blocker_details', v_details,
        'primary_blocker', v_primary,
        'slug', r.public_route,
        'destination_url', CASE WHEN v_published THEN r.published_url ELSE NULL END,
        'checkout_state', 'CHECKOUT_NOT_CONFIGURED',
        'publish_call', jsonb_build_object('rpc','fn_storefront_publish','args', jsonb_build_object('p_page_id', r.id)),
        'unpublish_call', jsonb_build_object('rpc','fn_storefront_transition_state','args', jsonb_build_object('p_page_id', r.id, 'p_target_state','APPROVED')));
    END;
  END LOOP;

  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'storefronts', v_rows,
    'note','Authenticated merchant publish context; publish/unpublish take page_id only (gate is derived server-side).');
END; $function$;

-- 4) Structural selftest: every known blocker code maps to a complete, non-retryable detail.
CREATE OR REPLACE FUNCTION public.fn_storefront_publish_ux_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_pass int:=0; v_fail int:=0; v_c jsonb:='[]'::jsonb; d jsonb; code text;
  codes text[] := ARRAY['NOT_GENERATED','ASSETS_UNAVAILABLE','CLAIMS_NOT_CLEAN','ECONOMICS_NOT_VIABLE','NOT_APPROVED','DESTINATION_NOT_PULSE_HOSTED'];
BEGIN
  FOREACH code IN ARRAY codes LOOP
    d := public.fn_storefront_publish_blocker_detail(code);
    IF coalesce(d->>'message','')<>'' AND coalesce(d->>'action_key','')<>'' AND coalesce(d->>'action_label','')<>''
       AND (d->>'retryable')::boolean = false AND (d->>'code')=code THEN
      v_pass:=v_pass+1;
    ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('bad_code',code,'detail',d); END IF;
  END LOOP;
  -- status mapping sanity: a not-generated eligibility rejection maps to NOT_GENERATED.
  IF (public.fn_storefront_publish_status_blocker('BLOCKED_TEST_ELIGIBILITY','["REJECT_NOT_GENERATED"]'::jsonb)->>'code')='NOT_GENERATED'
     THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('status_map','not_generated_failed'); END IF;
  -- a transient/system status is NOT a deterministic blocker (NULL).
  IF public.fn_storefront_publish_status_blocker('PAGE_NOT_FOUND') IS NULL
     THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; v_c:=v_c||jsonb_build_object('status_map','page_not_found_should_be_null'); END IF;
  RETURN jsonb_build_object('suite','storefront_publish_ux','pass',v_pass,'fail',v_fail,'all_pass',(v_fail=0),'checks',v_c);
END; $fn$;

REVOKE EXECUTE ON FUNCTION public.fn_storefront_publish_ux_selftest() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_storefront_publish_ux_selftest() TO authenticated, service_role;

-- ============================================================================
-- mig_307_publish_context_blocker_append_fix.sql
-- STRATELOQ — REGRESSION REPAIR (F3 publish step).
-- fn_storefront_publish_context crashed with "malformed array literal" whenever a
-- page was NOT already approved: `v_blockers text[] || 'NOT_APPROVED'` is ambiguous
-- ( text[] || unknown ) and Postgres tried to parse the scalar as an array. Every
-- customer-store draft (review_state READY_FOR_REVIEW) hit this branch, so the
-- Product Page Builder's Review/Publish step errored instead of showing the honest
-- publish blockers. Fix: use array_append() with an explicit ::text element. No gate
-- logic, no contract, no column changes — only the append is made unambiguous.
-- Idempotent (CREATE OR REPLACE).
-- ============================================================================
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
    BEGIN
      IF r.rs NOT IN ('APPROVED','PUBLISHED') THEN v_blockers := array_append(v_blockers, 'NOT_APPROVED'::text); END IF;
      IF r.gen_state <> 'GENERATED' THEN v_blockers := array_append(v_blockers, 'NOT_GENERATED'::text); END IF;
      IF r.econ_state NOT IN ('VIABLE','POSITIVE') THEN v_blockers := array_append(v_blockers, 'ECONOMICS_NOT_VIABLE'::text); END IF;
      IF NOT r.claim_clean THEN v_blockers := array_append(v_blockers, 'CLAIMS_NOT_CLEAN'::text); END IF;
      IF r.assets_state <> 'ASSETS_AVAILABLE' THEN v_blockers := array_append(v_blockers, 'ASSETS_UNAVAILABLE'::text); END IF;
      IF r.dest <> 'PULSE_STORE' THEN v_blockers := array_append(v_blockers, 'DESTINATION_NOT_PULSE_HOSTED'::text); END IF;
      v_ready := (array_length(v_blockers,1) IS NULL);

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

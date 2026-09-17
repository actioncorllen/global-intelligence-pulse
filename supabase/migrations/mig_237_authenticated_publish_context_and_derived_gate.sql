-- STRATELOQ-ECOM-P8-AUTHENTICATED-PUBLISHING-E2E-TEST-SESSION-010
-- Close the authenticated product-contract gap that blocked the real E2E:
--   (1) The merchant frontend had no way to obtain its own storefront page_id +
--       publish context (commerce_product_pages is RLS deny-all to clients).
--   (2) Publish required the browser to construct gate_inputs (forbidden).
--
-- Fix (smallest safe correction, reuses the verified publish lifecycle):
--   A. fn_storefront_publish_context(page_id?) — authenticated, tenant-scoped by
--      auth.uid(), returns ONLY the caller's own storefront pages with page_id,
--      states, destination, publish readiness + blockers, slug and (published-only)
--      destination_url. No internal scoring / economics values / supplier ids leak.
--   B. fn_storefront_publish — gate_inputs is now OPTIONAL. When the browser passes
--      no gate (no 'recommendation' key), publish DERIVES eligibility from the page's
--      PERSISTED, generation-gated state (generation_state=GENERATED + economics
--      VIABLE/POSITIVE), then runs the same persisted claim/asset/destination gates.
--      The explicit-gate path (callers that pass a full gate) is unchanged, so all
--      existing selftests keep their exact behavior. Fail-closed throughout.
--
-- No RLS weakened, no anon grant, no service_role exposed, no new tenant.

-- ---------------------------------------------------------------------------
-- A. Authenticated publish context (page identity + eligibility for the frontend)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_publish_context(p_page_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
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
      IF r.rs NOT IN ('APPROVED','PUBLISHED') THEN v_blockers := v_blockers || 'NOT_APPROVED'; END IF;
      IF r.gen_state <> 'GENERATED' THEN v_blockers := v_blockers || 'NOT_GENERATED'; END IF;
      IF r.econ_state NOT IN ('VIABLE','POSITIVE') THEN v_blockers := v_blockers || 'ECONOMICS_NOT_VIABLE'; END IF;
      IF NOT r.claim_clean THEN v_blockers := v_blockers || 'CLAIMS_NOT_CLEAN'; END IF;
      IF r.assets_state <> 'ASSETS_AVAILABLE' THEN v_blockers := v_blockers || 'ASSETS_UNAVAILABLE'; END IF;
      IF r.dest <> 'PULSE_STORE' THEN v_blockers := v_blockers || 'DESTINATION_NOT_PULSE_HOSTED'; END IF;
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
        -- publish/unpublish are invoked with page_id alone; gate is server-derived.
        'publish_call', jsonb_build_object('rpc','fn_storefront_publish','args', jsonb_build_object('p_page_id', r.id)),
        'unpublish_call', jsonb_build_object('rpc','fn_storefront_transition_state','args', jsonb_build_object('p_page_id', r.id, 'p_target_state','APPROVED')));
    END;
  END LOOP;

  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'storefronts', v_rows,
    'note','Authenticated merchant publish context; publish/unpublish take page_id only (gate is derived server-side).');
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_publish_context(uuid) IS
 'Authenticated merchant publish context: the caller''s OWN storefront pages (tenant-scoped by auth.uid()) with page_id, states, destination, publish readiness + blockers, slug and published-only destination_url. No internal scoring/economics values/supplier ids exposed. Lets the frontend obtain page identity + eligibility without DB console access or browser-constructed gate inputs.';

REVOKE ALL ON FUNCTION public.fn_storefront_publish_context(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_storefront_publish_context(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- B. fn_storefront_publish with OPTIONAL, server-derived gate.
--    Body identical to mig_230 except: p_gate_inputs default '{}'; when no
--    'recommendation' key is supplied, eligibility is DERIVED from the page's
--    persisted generation-gated state instead of caller input. Fail-closed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_publish(
  p_page_id uuid, p_gate_inputs jsonb DEFAULT '{}'::jsonb, p_actor uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  p public.commerce_product_pages%rowtype;
  v_actor uuid := coalesce(auth.uid(), p_actor);
  v_gate jsonb; v_assets jsonb; v_clean boolean; v_slug text; v_url text;
  v_base text := 'https://nxaunmyihhjixxxljcqt.supabase.co';
  v_derived boolean := false; v_econ text;
BEGIN
  SELECT * INTO p FROM public.commerce_product_pages WHERE id = p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND p.user_id IS NOT NULL AND v_actor <> p.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  IF upper(coalesce(p.review_state,'')) <> 'APPROVED' THEN
    RETURN jsonb_build_object('status','NOT_APPROVED','review_state',p.review_state,
      'note','publish requires the page to be APPROVED first (DRAFT -> IN_REVIEW -> APPROVED)');
  END IF;

  -- Eligibility: explicit caller gate (unchanged) OR server-derived from persisted state.
  IF p_gate_inputs IS NOT NULL AND (p_gate_inputs ? 'recommendation') THEN
    v_gate := public.fn_storefront_test_eligibility(p_gate_inputs);
    IF NOT (v_gate->>'test_eligible')::boolean THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY','reason_codes',v_gate->'reason_codes','gate',v_gate);
    END IF;
  ELSE
    -- Server-derived: publish only a page that was produced by the gated generator
    -- and carries viable persisted economics. No browser-constructed gate required.
    v_derived := true;
    v_econ := upper(coalesce(p.runtime_contract->>'economics_state',''));
    IF coalesce(p.runtime_contract->>'generation_state','') <> 'GENERATED' THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY',
        'reason_codes', jsonb_build_array('REJECT_NOT_GENERATED'),
        'note','server-derived: page was not produced by the gated storefront generator');
    END IF;
    IF v_econ NOT IN ('VIABLE','POSITIVE') THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY',
        'reason_codes', jsonb_build_array('REJECT_ECONOMICS_NOT_VIABLE'),
        'note','server-derived: persisted economics not viable ('||coalesce(v_econ,'UNKNOWN')||')');
    END IF;
  END IF;

  -- Persisted claim safety (never caller-controlled).
  v_clean := coalesce((p.runtime_contract->'claim_safety'->>'claim_scan_clean')::boolean, false);
  IF NOT v_clean THEN
    RETURN jsonb_build_object('status','BLOCKED_CLAIM_SAFETY','note','claim scan not clean; resolve before publish');
  END IF;
  -- Asset safety re-resolved from persisted supplier refs.
  v_assets := public.fn_resolve_storefront_assets(
      coalesce(p.runtime_contract->'supplier_asset_refs'->>'fulfilment_supplier','cjdropshipping'),
      p.runtime_contract->'supplier_asset_refs'->>'supplier_product_id', p.country_code);
  IF (v_assets->>'rejected_count')::int > 0 AND (v_assets->>'usable_count')::int = 0 THEN
    RETURN jsonb_build_object('status','BLOCKED_ASSET_SAFETY','assets',v_assets,
      'note','no usable rights-clear supplier assets; only rejected/reference-only present');
  END IF;
  IF upper(coalesce(p.destination,'')) NOT IN ('PULSE_STORE') THEN
    RETURN jsonb_build_object('status','BLOCKED_DESTINATION','destination',p.destination,
      'note','this runtime publishes PULSE_STORE (Pulse-hosted) only');
  END IF;

  v_slug := 'p'||left(replace(p_page_id::text,'-',''),12);
  v_url := v_base||'/functions/v1/storefront/'||v_slug;

  UPDATE public.commerce_product_pages SET
    review_state = 'PUBLISHED', publication_state = 'PUBLISHED', published_url = v_url,
    runtime_contract = coalesce(runtime_contract,'{}'::jsonb) || jsonb_build_object(
      'review_state','PUBLISHED','publication_state','PUBLISHED',
      'publication', jsonb_build_object(
        'destination','PULSE_HOSTED','slug',v_slug,'destination_url',v_url,'noindex',true,
        'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT',
        'renderer','fn_public_storefront_render',
        'eligibility_source', CASE WHEN v_derived THEN 'SERVER_DERIVED_PERSISTED' ELSE 'EXPLICIT_GATE' END,
        'published_at', now(),
        'gates', jsonb_build_object('test_eligible',true,'claim_scan_clean',true,
           'assets_state',v_assets->>'state','destination','PULSE_STORE'),
        'checkout', jsonb_build_object('state','CHECKOUT_NOT_CONFIGURED',
           'dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER'))),
    supplier_asset_refs = v_assets, updated_at = now()
  WHERE id = p_page_id;

  UPDATE public.commerce_store_projects SET
    project_state = 'PUBLISHED', public_route = v_slug,
    settings = coalesce(settings,'{}'::jsonb) || jsonb_build_object(
      'publication_state','PUBLISHED','destination_url',v_url,'noindex',true,
      'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT'),
    updated_at = now()
  WHERE product_page_id = p_page_id;

  RETURN jsonb_build_object('status','ok','publication_state','PUBLISHED',
    'page_id',p_page_id,'slug',v_slug,'destination_url',v_url,
    'eligibility_source', CASE WHEN v_derived THEN 'SERVER_DERIVED_PERSISTED' ELSE 'EXPLICIT_GATE' END,
    'checkout_state','CHECKOUT_NOT_CONFIGURED','checkout_dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER',
    'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT',
    'renderer','fn_public_storefront_render',
    'gates', jsonb_build_object('test_eligible',true,'claim_scan_clean',true,
       'assets_state',v_assets->>'state','destination','PULSE_STORE'),
    'note','internal publication runtime complete; anonymous public HTTP endpoint deploy is founder-gated');
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_publish(uuid,jsonb,uuid) IS
 'Pulse-hosted publish: requires APPROVED + owner; eligibility via explicit caller gate OR (when no gate supplied) server-derived from persisted generation-gated state (GENERATED + viable economics); re-runs persisted claim/asset/destination gates (fail closed); sets PUBLISHED + stable URL. Public HTTP endpoint deploy remains founder-gated.';

REVOKE ALL ON FUNCTION public.fn_storefront_publish(uuid,jsonb,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_storefront_publish(uuid,jsonb,uuid) TO service_role, authenticated;

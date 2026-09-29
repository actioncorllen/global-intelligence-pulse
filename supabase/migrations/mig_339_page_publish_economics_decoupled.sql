-- mig_339: Decouple Product Opportunity Intelligence economics from PAGE PUBLISH readiness.
--
-- Founder-locked separation of contracts:
--   Contract A — PRODUCT OPPORTUNITY INTELLIGENCE (economics): CAC, margin target,
--     estimated profit ($25–$30+), economics confidence. Lives in fn_opportunity_score_v2
--     and fn_storefront_test_eligibility. UNCHANGED by this migration.
--   Contract B — PRODUCT PAGE PUBLISHABILITY: review approval (explicit merchant action),
--     page content generated, claim safety, publishable/rights-cleared commercial asset
--     (Product Asset Lock), publish destination, canonical product image.
--
-- Problem: the page-publish gate treated opportunity economics_state NOT IN
-- ('VIABLE','POSITIVE') as a hard blocker ("Complete the required pricing and margin
-- details before publishing."). That imported Contract A into Contract B and blocked a
-- perfectly publishable page whose opportunity economics is merely UNKNOWN.
--
-- Fix: remove opportunity-economics from the PAGE publish path only. Merchant selling
-- price is accepted without proving CAC/profit. Claim suppression, asset rights, image,
-- destination and explicit merchant review approval all remain. Nothing is auto-approved
-- or auto-published. No second readiness engine is built — the readiness matrix is a
-- presentational projection of the same server-derived states.

-- 1) READ PATH — publish context: drop the economics blocker; expose a generic,
--    reusable page-publish readiness matrix + informational (non-gating) economics state.
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
           upper(coalesce(p.runtime_contract->>'economics_state','UNKNOWN')) AS econ_state,
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
      v_matrix jsonb;
      v_gen_ok    boolean := (r.gen_state = 'GENERATED');
      v_assets_ok boolean := (r.assets_state = 'ASSETS_AVAILABLE');
      v_dest_ok   boolean := (r.dest = 'PULSE_STORE');
      v_review_ok boolean := (r.rs IN ('APPROVED','PUBLISHED'));
    BEGIN
      -- PAGE PUBLISHABILITY (Contract B) blockers ONLY. Opportunity economics
      -- (CAC / margin target / estimated profit / economics confidence) is Product
      -- Opportunity Intelligence (Contract A) and is intentionally NOT a page-publish gate.
      IF NOT v_review_ok  THEN v_blockers := array_append(v_blockers, 'NOT_APPROVED'::text); END IF;
      IF NOT v_gen_ok     THEN v_blockers := array_append(v_blockers, 'NOT_GENERATED'::text); END IF;
      IF NOT r.claim_clean THEN v_blockers := array_append(v_blockers, 'CLAIMS_NOT_CLEAN'::text); END IF;
      IF NOT v_assets_ok  THEN v_blockers := array_append(v_blockers, 'ASSETS_UNAVAILABLE'::text); END IF;
      IF NOT v_dest_ok    THEN v_blockers := array_append(v_blockers, 'DESTINATION_NOT_PULSE_HOSTED'::text); END IF;
      v_ready := (array_length(v_blockers,1) IS NULL);

      v_details := coalesce((
        SELECT jsonb_agg(d ORDER BY (d->>'priority')::int, d->>'code')
        FROM (SELECT public.fn_storefront_publish_blocker_detail(b) AS d FROM unnest(v_blockers) AS b) t
      ), '[]'::jsonb);
      v_primary := CASE WHEN jsonb_array_length(v_details) > 0 THEN v_details->0 ELSE NULL END;

      -- Generic page-publish readiness matrix: a presentational projection of the SAME
      -- server-derived states (NOT a second readiness engine). Opportunity-economics
      -- dimensions are surfaced as informational and explicitly NOT_REQUIRED_FOR_PAGE_PUBLISH.
      v_matrix := jsonb_build_array(
        jsonb_build_object('dimension','MERCHANT_REVIEW_APPROVAL','contract','PAGE_PUBLISH',
          'requirement','REQUIRED','status', CASE WHEN v_review_ok THEN 'PASS' ELSE 'ACTION_REQUIRED' END,
          'observed', r.review_state),
        jsonb_build_object('dimension','PAGE_CONTENT_GENERATED','contract','PAGE_PUBLISH',
          'requirement','REQUIRED','status', CASE WHEN v_gen_ok THEN 'PASS' ELSE 'ACTION_REQUIRED' END,
          'observed', r.gen_state),
        jsonb_build_object('dimension','CLAIM_SAFETY','contract','PAGE_PUBLISH',
          'requirement','REQUIRED','status', CASE WHEN r.claim_clean THEN 'PASS' ELSE 'ACTION_REQUIRED' END,
          'observed', r.claim_clean),
        jsonb_build_object('dimension','PUBLISHABLE_COMMERCIAL_ASSET','contract','PAGE_PUBLISH',
          'requirement','REQUIRED','status', CASE WHEN v_assets_ok THEN 'PASS' ELSE 'ACTION_REQUIRED' END,
          'observed', r.assets_state),
        jsonb_build_object('dimension','PUBLISH_DESTINATION','contract','PAGE_PUBLISH',
          'requirement','REQUIRED','status', CASE WHEN v_dest_ok THEN 'PASS' ELSE 'ACTION_REQUIRED' END,
          'observed', r.destination),
        jsonb_build_object('dimension','CAC_EVIDENCE','contract','OPPORTUNITY_INTELLIGENCE',
          'requirement','NOT_REQUIRED_FOR_PAGE_PUBLISH','status','INFO','observed', r.econ_state),
        jsonb_build_object('dimension','MARGIN_TARGET','contract','OPPORTUNITY_INTELLIGENCE',
          'requirement','NOT_REQUIRED_FOR_PAGE_PUBLISH','status','INFO','observed', r.econ_state),
        jsonb_build_object('dimension','ESTIMATED_PROFIT_THRESHOLD','contract','OPPORTUNITY_INTELLIGENCE',
          'requirement','NOT_REQUIRED_FOR_PAGE_PUBLISH','status','INFO','observed', r.econ_state),
        jsonb_build_object('dimension','OPPORTUNITY_ECONOMICS_CONFIDENCE','contract','OPPORTUNITY_INTELLIGENCE',
          'requirement','NOT_REQUIRED_FOR_PAGE_PUBLISH','status','INFO','observed', r.econ_state)
      );

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
        'page_publish_readiness', v_matrix,
        'opportunity_economics_state', r.econ_state,
        'opportunity_economics_note','Opportunity economics (CAC / margin target / estimated profit / confidence) is Product Opportunity Intelligence and does not gate page publishing.',
        'slug', r.public_route,
        'destination_url', CASE WHEN v_published THEN r.published_url ELSE NULL END,
        'checkout_state', 'CHECKOUT_NOT_CONFIGURED',
        'publish_call', jsonb_build_object('rpc','fn_storefront_publish','args', jsonb_build_object('p_page_id', r.id)),
        'unpublish_call', jsonb_build_object('rpc','fn_storefront_transition_state','args', jsonb_build_object('p_page_id', r.id, 'p_target_state','APPROVED')));
    END;
  END LOOP;

  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'storefronts', v_rows,
    'contract','PAGE_PUBLISHABILITY',
    'note','Authenticated merchant publish context; publish/unpublish take page_id only (gate is derived server-side). Opportunity economics is not a page-publish gate.');
END; $function$;

-- 2) WRITE PATH — publish: remove opportunity-economics enforcement from both branches.
--    Contract A (fn_storefront_test_eligibility) is still computed for transparency in the
--    explicit-gate branch, but economics-only reasons are stripped before the publish decision.
CREATE OR REPLACE FUNCTION public.fn_storefront_publish(p_page_id uuid, p_gate_inputs jsonb DEFAULT '{}'::jsonb, p_actor uuid DEFAULT NULL::uuid)
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
  v_derived boolean := false; v_pimg jsonb;
  v_page_reasons jsonb;
BEGIN
  SELECT * INTO p FROM public.commerce_product_pages WHERE id = p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND p.user_id IS NOT NULL AND v_actor <> p.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  -- Explicit merchant review approval remains a hard, human-driven precondition.
  IF upper(coalesce(p.review_state,'')) <> 'APPROVED' THEN
    RETURN jsonb_build_object('status','NOT_APPROVED','review_state',p.review_state,
      'note','publish requires the page to be APPROVED first (DRAFT -> IN_REVIEW -> APPROVED)');
  END IF;

  IF p_gate_inputs IS NOT NULL AND (p_gate_inputs ? 'recommendation') THEN
    -- Opportunity-intelligence eligibility is still computed for transparency, but PAGE
    -- publishing (Contract B) does NOT require opportunity economics: strip any
    -- economics-only reason before deciding. fn_storefront_test_eligibility is unchanged.
    v_gate := public.fn_storefront_test_eligibility(p_gate_inputs);
    SELECT coalesce(jsonb_agg(rc), '[]'::jsonb) INTO v_page_reasons
    FROM jsonb_array_elements_text(coalesce(v_gate->'reason_codes','[]'::jsonb)) rc
    WHERE upper(rc) NOT IN ('REJECT_ECONOMICS_UNVIABLE','REJECT_ECONOMICS_UNKNOWN',
                            'REJECT_ECONOMICS_NOT_VIABLE','ECONOMICS_THIN','OK_TEST_ELIGIBLE');
    IF jsonb_array_length(v_page_reasons) > 0 THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY','reason_codes',v_page_reasons,'gate',v_gate,
        'note','page-publish blocked by non-economics eligibility reasons; opportunity economics is not a page-publish gate');
    END IF;
  ELSE
    v_derived := true;
    IF coalesce(p.runtime_contract->>'generation_state','') <> 'GENERATED' THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY',
        'reason_codes', jsonb_build_array('REJECT_NOT_GENERATED'),
        'note','server-derived: page was not produced by the gated storefront generator');
    END IF;
    -- Opportunity economics (economics_state) intentionally NOT gated here for page publish.
  END IF;

  v_clean := coalesce((p.runtime_contract->'claim_safety'->>'claim_scan_clean')::boolean, false);
  IF NOT v_clean THEN
    RETURN jsonb_build_object('status','BLOCKED_CLAIM_SAFETY','note','claim scan not clean; resolve before publish');
  END IF;
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

  IF p.product_id IS NOT NULL THEN
    v_pimg := public.fn_resolve_product_image(p.product_id, p.country_code);
    IF coalesce(v_pimg->>'image_state','') <> 'AVAILABLE' OR coalesce(v_pimg->>'image_url','') = '' THEN
      RETURN jsonb_build_object('status','BLOCKED_PRODUCT_IMAGE_UNAVAILABLE',
        'image_state', coalesce(v_pimg->>'image_state','NONE'), 'product_id', p.product_id,
        'note','a customer-facing storefront requires a trustworthy canonical product image; none available for this product (never fabricated)');
    END IF;
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
           'assets_state',v_assets->>'state','destination','PULSE_STORE',
           'product_image_state', CASE WHEN p.product_id IS NOT NULL THEN coalesce(v_pimg->>'image_state','NONE') ELSE 'N/A' END),
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
       'assets_state',v_assets->>'state','destination','PULSE_STORE',
       'product_image_state', CASE WHEN p.product_id IS NOT NULL THEN coalesce(v_pimg->>'image_state','NONE') ELSE 'N/A' END),
    'note','internal publication runtime complete; anonymous public HTTP endpoint deploy is founder-gated');
END; $function$;

-- 3) STATUS→MESSAGE mapper: never surface the opportunity "pricing and margin" message for
--    a page-publish outcome. BLOCKED_TEST_ELIGIBILITY on the page path can only be NOT_GENERATED.
CREATE OR REPLACE FUNCTION public.fn_storefront_publish_status_blocker(p_status text, p_reason_codes jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT CASE upper(btrim(coalesce(p_status,'')))
    WHEN 'NOT_APPROVED' THEN public.fn_storefront_publish_blocker_detail('NOT_APPROVED')
    WHEN 'BLOCKED_CLAIM_SAFETY' THEN public.fn_storefront_publish_blocker_detail('CLAIMS_NOT_CLEAN')
    WHEN 'BLOCKED_ASSET_SAFETY' THEN public.fn_storefront_publish_blocker_detail('ASSETS_UNAVAILABLE')
    WHEN 'BLOCKED_PRODUCT_IMAGE_UNAVAILABLE' THEN public.fn_storefront_publish_blocker_detail('ASSETS_UNAVAILABLE')
    WHEN 'BLOCKED_DESTINATION' THEN public.fn_storefront_publish_blocker_detail('DESTINATION_NOT_PULSE_HOSTED')
    WHEN 'BLOCKED_TEST_ELIGIBILITY' THEN public.fn_storefront_publish_blocker_detail('NOT_GENERATED')
    ELSE NULL
  END;
$function$;

-- 4) SELFTEST — proves the decoupling on live data without publishing anything (write-path
--    proof runs inside a rolled-back subtransaction). Requires an authenticated founder JWT.
CREATE OR REPLACE FUNCTION public.fn_page_publish_economics_selftest(p_page_id uuid, p_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_pass int := 0; v_fail int := 0; v_checks jsonb := '[]'::jsonb;
  v_ctx jsonb; v_row jsonb; v_blockers jsonb; v_matrix jsonb;
  v_pub jsonb; v_pub_clean jsonb;
  v_orig_review text; v_orig_rc jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role','authenticated')::text, true);

  -- capture originals (restored anyway via rollback, but keep for clarity)
  SELECT review_state, runtime_contract INTO v_orig_review, v_orig_rc
    FROM public.commerce_product_pages WHERE id = p_page_id;

  v_ctx := public.fn_storefront_publish_context(p_page_id);
  v_row := v_ctx->'storefronts'->0;
  v_blockers := coalesce(v_row->'publish_blockers','[]'::jsonb);
  v_matrix := coalesce(v_row->'page_publish_readiness','[]'::jsonb);

  -- C1: economics blocker gone from publish_blockers
  IF NOT (v_blockers @> '["ECONOMICS_NOT_VIABLE"]'::jsonb) THEN v_pass:=v_pass+1;
  ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','no_economics_blocker','ok', NOT (v_blockers @> '["ECONOMICS_NOT_VIABLE"]'::jsonb),'observed',v_blockers);

  -- C2: all four opportunity-economics dimensions marked NOT_REQUIRED_FOR_PAGE_PUBLISH
  DECLARE v_ne int; BEGIN
    SELECT count(*) INTO v_ne FROM jsonb_array_elements(v_matrix) e
     WHERE e->>'dimension' IN ('CAC_EVIDENCE','MARGIN_TARGET','ESTIMATED_PROFIT_THRESHOLD','OPPORTUNITY_ECONOMICS_CONFIDENCE')
       AND e->>'requirement' = 'NOT_REQUIRED_FOR_PAGE_PUBLISH';
    IF v_ne = 4 THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
    v_checks := v_checks || jsonb_build_object('check','economics_dims_not_required','ok', v_ne=4,'observed',v_ne);
  END;

  -- C3: the five page-publish dimensions are all present & REQUIRED
  DECLARE v_pr int; BEGIN
    SELECT count(*) INTO v_pr FROM jsonb_array_elements(v_matrix) e
     WHERE e->>'contract'='PAGE_PUBLISH' AND e->>'requirement'='REQUIRED';
    IF v_pr = 5 THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
    v_checks := v_checks || jsonb_build_object('check','five_page_publish_dims_required','ok', v_pr=5,'observed',v_pr);
  END;

  -- C4: WRITE-PATH proof — APPROVED + economics UNKNOWN publishes 'ok' (rolled back).
  BEGIN
    UPDATE public.commerce_product_pages
       SET review_state='APPROVED',
           runtime_contract = coalesce(runtime_contract,'{}'::jsonb) || jsonb_build_object('economics_state','UNKNOWN')
     WHERE id = p_page_id;
    v_pub := public.fn_storefront_publish(p_page_id, '{}'::jsonb, p_uid);
    RAISE EXCEPTION 'SELFTEST_ROLLBACK_C4';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK_C4' THEN
      v_pub := jsonb_build_object('status','SELFTEST_ERR','err',SQLERRM);
    END IF;
  END;
  IF coalesce(v_pub->>'status','') = 'ok' THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','publishes_with_economics_unknown','ok', coalesce(v_pub->>'status','')='ok','observed',v_pub->>'status');

  -- C5: claim-safety still blocks (APPROVED but claim_scan_clean=false) — rolled back.
  BEGIN
    UPDATE public.commerce_product_pages
       SET review_state='APPROVED',
           runtime_contract = jsonb_set(coalesce(runtime_contract,'{}'::jsonb),
             '{claim_safety,claim_scan_clean}', 'false'::jsonb, true)
     WHERE id = p_page_id;
    v_pub_clean := public.fn_storefront_publish(p_page_id, '{}'::jsonb, p_uid);
    RAISE EXCEPTION 'SELFTEST_ROLLBACK_C5';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK_C5' THEN
      v_pub_clean := jsonb_build_object('status','SELFTEST_ERR','err',SQLERRM);
    END IF;
  END;
  IF coalesce(v_pub_clean->>'status','') = 'BLOCKED_CLAIM_SAFETY' THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','claim_safety_still_blocks','ok', coalesce(v_pub_clean->>'status','')='BLOCKED_CLAIM_SAFETY','observed',v_pub_clean->>'status');

  -- C6: explicit merchant review still required (DRAFT cannot publish).
  DECLARE v_draft jsonb; BEGIN
    BEGIN
      UPDATE public.commerce_product_pages SET review_state='DRAFT' WHERE id = p_page_id;
      v_draft := public.fn_storefront_publish(p_page_id, '{}'::jsonb, p_uid);
      RAISE EXCEPTION 'SELFTEST_ROLLBACK_C6';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'SELFTEST_ROLLBACK_C6' THEN v_draft := jsonb_build_object('status','SELFTEST_ERR','err',SQLERRM); END IF;
    END;
    IF coalesce(v_draft->>'status','')='NOT_APPROVED' THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
    v_checks := v_checks || jsonb_build_object('check','review_approval_still_required','ok', coalesce(v_draft->>'status','')='NOT_APPROVED','observed',v_draft->>'status');
  END;

  -- C7: no page was actually published (state unchanged after all rolled-back subtxns).
  DECLARE v_now_pub text; BEGIN
    SELECT publication_state INTO v_now_pub FROM public.commerce_product_pages WHERE id = p_page_id;
    IF coalesce(v_now_pub,'') <> 'PUBLISHED' THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
    v_checks := v_checks || jsonb_build_object('check','nothing_published','ok', coalesce(v_now_pub,'')<>'PUBLISHED','observed',v_now_pub);
  END;

  RETURN jsonb_build_object('suite','fn_page_publish_economics_selftest',
    'pass',v_pass,'fail',v_fail,'total',v_pass+v_fail,'checks',v_checks,
    'page_id',p_page_id);
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_publish_context(uuid) IS
  'Contract B (page publishability). Opportunity economics is informational only (NOT_REQUIRED_FOR_PAGE_PUBLISH). mig_339.';
COMMENT ON FUNCTION public.fn_storefront_publish(uuid,jsonb,uuid) IS
  'Page publish. Requires review APPROVED, generated content, claim safety, rights-cleared asset, canonical image, PULSE_STORE destination. Opportunity economics is NOT a gate. mig_339.';

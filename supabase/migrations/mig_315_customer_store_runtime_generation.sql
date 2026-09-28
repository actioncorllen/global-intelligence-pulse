-- ============================================================================
-- mig_315_customer_store_runtime_generation.sql
-- STRATELOQ — remove the NOT_GENERATED dead-end for CUSTOMER hosted-store pages.
-- ----------------------------------------------------------------------------
-- Root cause: fn_product_card_create_store's CUSTOMER_STORE branch created the page
-- via fn_create_pulse_store_draft ONLY (a DRAFT shell, runtime_contract = NULL) and
-- never ran the storefront runtime generator, so publish preflight reported
-- NOT_GENERATED forever ("Finish building this page") with no way to clear it.
-- fn_generate_storefront_runtime already builds the runtime, but it refused anything
-- that is not a TEST opportunity decision, and it always INSERTed a NEW page via
-- fn_create_pulse_store_draft (never reusing the existing page).
--
-- Fix (reuse the existing generator + existing page; do NOT weaken the global TEST
-- Product Intelligence gate; do NOT create another generator or another page):
--   1. fn_generate_storefront_runtime:
--        • honors an already-authorized CUSTOMER store — when the context carries
--          store_authorization='CUSTOMER_STORE_AUTHORIZED' it proceeds even though the
--          opportunity TEST gate refuses (the global TEST gate is unchanged for every
--          other path);
--        • targets an EXISTING page when p_selection_input.existing_page_id is set and
--          owned by the tenant (UPDATE in place; no fn_create_pulse_store_draft INSERT),
--          so the same product_page_id is reused. Idempotent.
--   2. fn_storefront_build_customer_runtime(p_page_id): thin builder-completion wrapper.
--        Reconstructs the customer-store inputs from the existing page + product +
--        display image and DELEGATES to fn_generate_storefront_runtime (persist, existing
--        page). Populates runtime_contract (generation_state=GENERATED) on the SAME page,
--        leaving review_state=DRAFT (build != approve). Tenant-guarded; anon revoked.
--   3. fn_product_card_create_store CUSTOMER_STORE branch: after the draft is created,
--        finalize the runtime once so new customer-store pages are born BUILD_READY.
--
-- BUILD / REVIEW / PUBLISH stay separate: generating the runtime does NOT approve or
-- publish. Real remaining blockers (review approval, required details, public-use
-- rights, destination, claims) stay visible via the existing publish context. Idempotent.
-- ============================================================================

-- 1) Storefront runtime generator: customer-store authorization + existing-page reuse.
CREATE OR REPLACE FUNCTION public.fn_generate_storefront_runtime(p_user_id uuid, p_gate_inputs jsonb, p_selection_input jsonb, p_context jsonb, p_decision jsonb, p_destination text DEFAULT 'PULSE_HOSTED'::text, p_source_kind text DEFAULT 'REAL'::text, p_product_id uuid DEFAULT NULL::uuid, p_country_code text DEFAULT NULL::text, p_opportunity_decision_id uuid DEFAULT NULL::uuid, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_gate jsonb; v_sel jsonb; v_assets jsonb; v_copy jsonb; v_scan jsonb;
  v_family text; v_market text := upper(coalesce(p_decision->>'target_market', p_country_code, ''));
  v_contract jsonb; v_draft jsonb; v_page_id uuid; v_marketing_text text; v_ad_match jsonb;
  v_dest text := upper(coalesce(p_destination,'PULSE_HOSTED'));
  v_gi_uid uuid; v_brand_scope text; v_theme jsonb; v_strategy jsonb; v_ctx jsonb;
  -- customer-store additions
  v_customer_auth boolean := (upper(coalesce(p_context->>'store_authorization','')) = 'CUSTOMER_STORE_AUTHORIZED');
  v_existing_page uuid := nullif(p_selection_input->>'existing_page_id','')::uuid;
  v_auth_basis text;
BEGIN
  v_gate := public.fn_storefront_test_eligibility(p_gate_inputs);
  -- The global TEST Product Intelligence gate is unchanged. A CUSTOMER-authorized hosted
  -- store (store_authorization=CUSTOMER_STORE_AUTHORIZED) is a legitimate second basis and
  -- proceeds even when the opportunity gate refuses; nothing else bypasses the gate.
  IF NOT (v_gate->>'test_eligible')::boolean AND NOT v_customer_auth THEN
    IF p_source_kind = 'FIXTURE' THEN
      v_sel := public.fn_select_conversion_template(p_selection_input);
      RETURN jsonb_build_object('status','REFUSED_PRODUCTION_DEV_PREVIEW_ONLY',
        'test_eligible', false, 'generation_state','DEV_PREVIEW_NON_PUBLISHABLE',
        'publication_state','BLOCKED_NON_PUBLISHABLE', 'is_fixture', true,
        'gate', v_gate, 'template_preview', v_sel->>'recommended_template_family',
        'note','Fixture/dev preview only; not eligible; nothing persisted as a real product.');
    END IF;
    RETURN jsonb_build_object('status','REFUSED','test_eligible', false,
      'generation_state','REFUSED','reason_codes', v_gate->'reason_codes',
      'decision_state', v_gate->>'decision_state', 'gate', v_gate,
      'note','Not TEST_ELIGIBLE; no storefront generated. Fail-closed.');
  END IF;
  v_auth_basis := CASE WHEN (v_gate->>'test_eligible')::boolean THEN 'OPPORTUNITY_TEST' ELSE 'CUSTOMER_STORE_AUTHORIZED' END;

  v_sel := public.fn_select_conversion_template(p_selection_input);
  v_family := v_sel->>'recommended_template_family';

  v_gi_uid := public.fn_global_intelligence_uid();
  IF p_user_id IS NOT NULL AND v_gi_uid IS NOT NULL AND p_user_id = v_gi_uid THEN
    v_brand_scope := 'INTERNAL_STRATELOQ';
  ELSIF (p_context ? 'brand_name')
     OR (p_user_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.business_profiles bp WHERE bp.user_id = p_user_id))
     OR (p_user_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.member_business_dna d WHERE d.user_id = p_user_id)) THEN
    v_brand_scope := 'MERCHANT';
  ELSE
    v_brand_scope := 'NEUTRAL';
  END IF;
  v_theme := public.fn_resolve_merchant_theme(p_context, v_brand_scope);
  v_ctx := coalesce(p_context,'{}'::jsonb)
           || jsonb_build_object('brand_name', v_theme->>'brand_name',
                                 'brand_voice', v_theme->>'brand_voice',
                                 'brand_theme_tokens', v_theme->'theme_tokens');

  v_copy := public.fn_generate_page_copy(p_decision, v_ctx);

  v_assets := public.fn_resolve_storefront_assets(
                p_context->>'supplier', p_context->>'supplier_product_id', p_country_code);

  v_marketing_text := concat_ws(' ',
     v_copy->'hero'->>'headline', v_copy->'hero'->>'subheadline', v_copy->>'short_description',
     v_copy->'problem_solution'->>'problem', v_copy->'problem_solution'->>'solution',
     (SELECT string_agg(b,' ') FROM jsonb_array_elements_text(coalesce(v_copy->'benefits','[]'::jsonb)) b));
  v_scan := public.fn_ad_studio_claim_scan(v_marketing_text);

  v_ad_match := coalesce(p_selection_input->'ad_match', jsonb_build_object(
      'state','NO_AD_MATCH_YET',
      'addressable_by', jsonb_build_object('product_id', p_product_id, 'country_code', p_country_code, 'market', v_market),
      'offer_version','v1'));

  v_strategy := public.fn_storefront_conversion_strategy(v_sel, p_decision);

  v_contract := jsonb_build_object(
    'product_id', p_product_id, 'country_code', p_country_code,
    'opportunity_decision_id', p_opportunity_decision_id,
    'template_family', v_family, 'template_version', v_sel->>'template_version',
    'market', v_market, 'destination', v_dest,
    'authorization_basis', v_auth_basis,
    'source_currency', coalesce(p_decision->'economics'->>'landed_cost_currency', p_context->>'source_currency'),
    'display_currency', p_context->>'display_currency',
    'economics_state', p_decision->'economics'->>'economics_state',
    'ad_match_ref', v_ad_match, 'sections', v_sel->'sections',
    'hero_variant', v_sel->>'hero_variant', 'cta_structure', v_sel->'cta_structure',
    'brand_scope', v_brand_scope, 'merchant_theme', v_theme, 'conversion_strategy', v_strategy,
    'claim_safety', (coalesce(v_copy->'claim_safety','{}'::jsonb)
                     || jsonb_build_object('runtime_claim_scan', v_scan,
                          'claim_scan_clean', (jsonb_array_length(v_scan)=0),
                          'unsafe_sections_editable_placeholder', (jsonb_array_length(v_scan) > 0))),
    'copy_provenance', v_copy->'copy_provenance',
    'supplier_asset_refs', v_assets, 'assets_state', v_assets->>'state',
    'selection', v_sel, 'generation_state', 'GENERATED', 'review_state', 'DRAFT',
    'publication_state', 'UNPUBLISHED', 'terminology_guard','BEST_FIT_PRE_PERFORMANCE_NOT_PROVEN');

  v_contract := v_contract || jsonb_build_object('explainability', public.fn_storefront_why_this_page(v_contract));

  IF NOT p_persist THEN
    RETURN jsonb_build_object('status','ok_preview','test_eligible',true,'persisted',false,
      'authorization_basis', v_auth_basis, 'runtime_contract', v_contract, 'gate', v_gate);
  END IF;

  -- Reuse the EXISTING page when one is supplied and owned by the tenant; never INSERT a
  -- duplicate. Otherwise create the canonical draft as before.
  IF v_existing_page IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.commerce_product_pages WHERE id = v_existing_page AND user_id = p_user_id) THEN
    v_page_id := v_existing_page;
    v_draft := jsonb_build_object('reused_existing_page', true, 'product_page_id', v_page_id);
  ELSE
    v_draft := public.fn_create_pulse_store_draft(p_user_id, p_decision, p_context, p_source_kind, p_product_id);
    IF coalesce((v_draft->>'created')::boolean,false) IS NOT TRUE THEN
      RETURN jsonb_build_object('status','REFUSED_AT_PERSIST','gate',v_gate,'draft',v_draft,
        'note','Eligibility passed but canonical draft creation refused (decision not TEST at persist).');
    END IF;
    v_page_id := (v_draft->>'product_page_id')::uuid;
  END IF;

  UPDATE public.commerce_product_pages SET
    country_code = coalesce(p_country_code, country_code), opportunity_decision_id = coalesce(p_opportunity_decision_id, opportunity_decision_id),
    template_family = v_family, template_version = v_sel->>'template_version',
    ad_match_ref = v_ad_match, supplier_asset_refs = v_assets,
    generation_state = 'GENERATED', review_state = 'DRAFT', publication_state = 'UNPUBLISHED',
    runtime_contract = v_contract,
    page_model = coalesce(page_model,'{}'::jsonb)
      || jsonb_build_object('template_family', v_family, 'template_version', v_sel->>'template_version',
           'sections', v_sel->'sections', 'hero_variant', v_sel->>'hero_variant',
           'assets_runtime', v_assets, 'ad_match_ref', v_ad_match,
           'merchant_theme', v_theme, 'conversion_strategy', v_strategy)
      || jsonb_build_object('assets', jsonb_build_object(
            'primary_image', v_assets->'primary_image'->>'source_url',
            'gallery', (SELECT coalesce(jsonb_agg(x->>'source_url'),'[]'::jsonb) FROM jsonb_array_elements(v_assets->'gallery') x),
            'state', CASE WHEN v_assets->>'state'='ASSETS_AVAILABLE' THEN 'SUPPLIER_ASSETS_RESOLVED' ELSE 'PRODUCT_ASSET_REQUIRED' END,
            'origin','SOURCE_SUPPLIER','note','rights-clear supplier images; no fabricated replacement')),
    updated_at = now()
  WHERE id = v_page_id;

  RETURN jsonb_build_object('status','ok','test_eligible',true,'persisted',true,
    'authorization_basis', v_auth_basis, 'reused_existing_page', coalesce((v_draft->>'reused_existing_page')::boolean,false),
    'product_page_id', v_page_id, 'store_project_id', v_draft->>'store_project_id',
    'template_family', v_family, 'template_version', v_sel->>'template_version',
    'review_state','DRAFT','publication_state','UNPUBLISHED','generation_state','GENERATED',
    'assets_state', v_assets->>'state', 'claim_scan_clean', (jsonb_array_length(v_scan)=0),
    'runtime_contract', v_contract, 'ad_studio_handoff', v_draft->'ad_studio_handoff',
    'preview', v_draft->'preview', 'gate', v_gate);
END; $function$;

-- 2) Builder-completion wrapper for an EXISTING customer hosted-store page.
--    Delegates to fn_generate_storefront_runtime (existing generator) targeting the same
--    page. Populates runtime_contract without approving/publishing. Idempotent.
CREATE OR REPLACE FUNCTION public.fn_storefront_build_customer_runtime(p_page_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_tenant uuid := auth.uid(); pg record; cp record; v_img jsonb; v_market text;
  v_decision jsonb; v_context jsonb; v_sel jsonb; v_res jsonb; v_econ text;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO pg FROM public.commerce_product_pages WHERE id = p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','page_not_found'); END IF;
  IF pg.user_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  IF upper(coalesce(pg.destination,'')) <> 'PULSE_STORE' THEN
    RETURN jsonb_build_object('ok',false,'error','not_a_customer_store_page','destination',pg.destination);
  END IF;

  SELECT * INTO cp FROM public.commerce_products WHERE id = pg.product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  v_market := upper(coalesce(pg.market, pg.country_code, ''));
  v_img := public.fn_product_card_display_image(v_tenant, pg.product_id, nullif(v_market,''));
  IF NOT coalesce((v_img->>'has_image')::boolean,false) THEN
    RETURN jsonb_build_object('ok',false,'status','IMPORT_REQUIRED','gate','AUTHORITATIVE_ASSET_REQUIRED',
      'error','no_product_image','action','IMPORT_PRODUCT_IMAGES',
      'message','Add your product image so Strateloq can finish building this page.');
  END IF;

  v_econ := upper(coalesce(pg.economics_state, pg.runtime_contract->>'economics_state', 'UNKNOWN'));
  v_decision := jsonb_build_object('recommendation','TEST','classification','CUSTOMER_STORE','target_market',v_market,
     'economics', jsonb_build_object('economics_state', v_econ),
     'supplier_execution', jsonb_build_object('economics', jsonb_build_object()));
  v_context := jsonb_build_object('product_title', cp.title, 'positioning', coalesce(cp.description,''),
     'store_authorization','CUSTOMER_STORE_AUTHORIZED',
     'display_currency', pg.display_currency,
     'authoritative_primary_image', CASE WHEN (v_img->>'is_authoritative')::boolean THEN v_img->>'url' ELSE NULL END,
     'supplier_reference', jsonb_build_object('provider', v_img->>'source_provider'));
  v_sel := jsonb_build_object('product_id', pg.product_id::text, 'country_code', v_market,
     'existing_page_id', p_page_id::text, 'ad_match', jsonb_build_object('state','NO_AD_MATCH_YET'));

  -- Empty gate inputs => opportunity gate refuses; CUSTOMER_STORE_AUTHORIZED authorizes.
  v_res := public.fn_generate_storefront_runtime(v_tenant, '{}'::jsonb, v_sel, v_context, v_decision,
     'PULSE_HOSTED', 'REAL', pg.product_id, nullif(v_market,''), NULL, true);

  RETURN jsonb_build_object('ok', ((v_res->>'status')='ok'),
    'product_page_id', p_page_id, 'store_id_unchanged', true,
    'reused_existing_page', coalesce((v_res->>'reused_existing_page')::boolean,false),
    'generation_state', v_res->>'generation_state',
    'authorization_basis', v_res->>'authorization_basis',
    'assets_state', v_res->>'assets_state', 'claim_scan_clean', v_res->>'claim_scan_clean',
    'note','runtime generated on the same page; build only — review/publish gates still apply',
    'result', v_res);
END; $fn$;

REVOKE EXECUTE ON FUNCTION public.fn_storefront_build_customer_runtime(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_storefront_build_customer_runtime(uuid) TO authenticated, service_role;

-- 3) New customer-store pages are born BUILD_READY: after the draft is created, finalize
--    the runtime once (same page). The TEST-opportunity branch is unchanged.
CREATE OR REPLACE FUNCTION public.fn_product_card_create_store(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); cp record; v_img jsonb; v_has_image boolean; d record;
  v_market text := upper(nullif(btrim(coalesce(p_market,'')),'')); v_rec text;
  v_gate jsonb; v_decision jsonb; v_context jsonb; v_sel jsonb; v_primary_url text; v_res jsonb; v_page_id uuid;
  v_build jsonb;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF cp.user_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  v_img := public.fn_product_card_display_image(v_tenant, p_product_id, v_market);
  v_has_image := (v_img->>'has_image')::boolean;
  IF NOT v_has_image THEN
    RETURN jsonb_build_object('ok',false,'status','IMPORT_REQUIRED','gate','AUTHORITATIVE_ASSET_REQUIRED',
      'error','no_product_image','action','IMPORT_PRODUCT_IMAGES',
      'message','Add your product images so Strateloq can create ads and product pages using the correct product.');
  END IF;
  v_primary_url := v_img->>'url';
  SELECT * INTO d FROM public.product_opportunity_decisions
    WHERE product_id=p_product_id AND (v_market IS NULL OR upper(country_code)=v_market)
    ORDER BY created_at DESC LIMIT 1;
  IF FOUND AND d.decision IN ('TEST','HIGH_CONFIDENCE_TEST') THEN
    v_market := coalesce(v_market, upper(d.country_code));
    v_rec := 'TEST';
    v_gate := jsonb_build_object(
      'recommendation', v_rec, 'decision_tier', d.opportunity_band,
      'supplier_identity_state', CASE WHEN d.hard_gates->>'supplier'='PASS' THEN 'SUPPLIER_EXACT' ELSE 'WEAK' END,
      'market_supplier_match', CASE WHEN d.hard_gates->>'market_price'='PASS' THEN 'MATCH' ELSE 'NO_MATCH' END,
      'subtype_price_valid', (d.hard_gates->>'market_price'='PASS'),
      'stock_state', CASE WHEN d.hard_gates->>'supplier'='PASS' AND d.hard_gates->>'fulfilment'='PASS' THEN 'IN_STOCK' ELSE 'UNKNOWN' END,
      'economics_state', upper(coalesce(d.economics_ref->>'economics_state','UNKNOWN')),
      'product_confidence', upper(coalesce(d.product_confidence,'UNKNOWN')),
      'fulfilment_evidence', (d.hard_gates->>'fulfilment'='PASS'),
      'no_critical_risk', (d.hard_gates->>'compliance'='PASS' AND coalesce(jsonb_array_length(coalesce(d.decision_blockers,'[]'::jsonb)),0)=0),
      'sourcing_status', '');
    v_decision := jsonb_build_object('recommendation', v_rec, 'classification', d.opportunity_band, 'target_market', v_market,
      'economics', jsonb_build_object('economics_state', upper(coalesce(d.economics_ref->>'economics_state','UNKNOWN')),
          'landed_cost_display', d.economics_ref->>'landed_cost_display'),
      'supplier_execution', jsonb_build_object('economics', jsonb_build_object(
          'landed_cost_original', d.economics_ref->>'landed_cost_original', 'landed_cost_currency', d.market_currency)));
    v_context := jsonb_build_object('product_title', cp.title, 'positioning', coalesce(cp.description,''),
      'display_currency', d.market_currency, 'source_currency', d.market_currency,
      'supplier','CUSTOMER_UPLOAD','supplier_product_id', p_product_id::text,
      'authoritative_primary_image', CASE WHEN (v_img->>'is_authoritative')::boolean THEN v_primary_url ELSE NULL END,
      'supplier_reference', jsonb_build_object('provider', v_img->>'source_provider'));
    v_sel := jsonb_build_object('product_id', p_product_id::text, 'country_code', v_market,
       'ad_match', jsonb_build_object('state','NO_AD_MATCH_YET'));
    v_res := public.fn_generate_storefront_runtime(v_tenant, v_gate, v_sel, v_context, v_decision,
       'PULSE_HOSTED', 'REAL', p_product_id, v_market, d.id, true);
    v_page_id := nullif(v_res->>'product_page_id','')::uuid;
    RETURN jsonb_build_object('ok', ((v_res->>'status') IN ('ok','ok_preview')),
       'product_id',p_product_id,'market',v_market,'opportunity_decision_id',d.id,
       'authorization','OPPORTUNITY_TEST','decision_verdict', d.decision,
       'product_page_id', v_page_id, 'authoritative_primary_image', v_primary_url, 'storefront', v_res);
  END IF;
  v_market := coalesce(v_market, '');
  v_decision := jsonb_build_object('recommendation','TEST','classification','CUSTOMER_STORE','target_market',v_market,
     'economics', jsonb_build_object('economics_state','UNKNOWN'),
     'supplier_execution', jsonb_build_object('economics', jsonb_build_object()));
  v_context := jsonb_build_object('product_title', cp.title, 'positioning', coalesce(cp.description,''),
     'authoritative_primary_image', CASE WHEN (v_img->>'is_authoritative')::boolean THEN v_primary_url ELSE NULL END,
     'store_authorization','CUSTOMER_STORE_AUTHORIZED',
     'supplier_reference', jsonb_build_object('provider', v_img->>'source_provider'));
  v_res := public.fn_create_pulse_store_draft(v_tenant, v_decision, v_context, 'REAL', p_product_id);
  v_page_id := nullif(v_res->>'product_page_id','')::uuid;
  -- Born BUILD_READY: finalize the customer-store runtime on the SAME page (no NOT_GENERATED loop).
  IF v_page_id IS NOT NULL THEN
    v_build := public.fn_storefront_build_customer_runtime(v_page_id);
  END IF;
  RETURN jsonb_build_object('ok', coalesce((v_res->>'created')::boolean,false),
     'product_id',p_product_id,'market',v_market,'authorization','CUSTOMER_STORE',
     'product_page_id', v_page_id, 'runtime_build', v_build,
     'authoritative_primary_image', CASE WHEN (v_img->>'is_authoritative')::boolean THEN v_primary_url ELSE NULL END,
     'display_image_used', v_primary_url, 'display_image_is_authoritative', (v_img->>'is_authoritative')::boolean,
     'storefront', v_res);
END; $function$;

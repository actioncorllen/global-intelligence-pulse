-- PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001
-- PHASE J: re-runnable, deterministic regression harness for the storefront
-- runtime. Pure-logic scenarios assert on the gate/selection/asset functions;
-- persistence/tenant/state scenarios create a synthetic page under random
-- tenants and DELETE it before returning (no residue). Safe to run in prod.
CREATE OR REPLACE FUNCTION public.fn_storefront_runtime_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  g jsonb; s jsonb; a jsonb; r jsonb;
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
  pid uuid; pid2 uuid;
  base_ok jsonb := '{"recommendation":"TEST","decision_tier":"STRONG_TEST","supplier_identity_state":"SUPPLIER_EXACT","market_supplier_match":"EXACT_CONFIRMED","subtype_price_valid":true,"stock_state":"IN_STOCK","economics_state":"VIABLE","product_confidence":"ACCEPTABLE","fulfilment_evidence":true,"no_critical_risk":true}'::jsonb;
  PROCEDURE_note text;
BEGIN
  -- helper inline: push(case, pass, detail)
  -- 1) TEST accepted
  g := public.fn_storefront_test_eligibility(base_ok);
  v := v || jsonb_build_object('case','test_accepted','pass',(g->>'test_eligible')::boolean = true,'got',g->>'decision_state');
  -- WPS-79 NOT upgraded to HIGH-CONFIDENCE
  v := v || jsonb_build_object('case','no_silent_high_confidence_upgrade','pass',(g->>'high_confidence')::boolean = false AND g->>'decision_tier'='STRONG_TEST','got',g->>'decision_tier');

  -- 2) WATCH rejected
  g := public.fn_storefront_test_eligibility(base_ok || '{"recommendation":"WATCH"}'::jsonb);
  v := v || jsonb_build_object('case','watch_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_WATCH','got',g->'reason_codes');
  -- 3) AVOID rejected
  g := public.fn_storefront_test_eligibility(base_ok || '{"recommendation":"AVOID"}'::jsonb);
  v := v || jsonb_build_object('case','avoid_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_AVOID','got',g->'reason_codes');
  -- 4) ANALYSIS_REQUIRED rejected
  g := public.fn_storefront_test_eligibility(base_ok || '{"recommendation":"ANALYSIS_REQUIRED"}'::jsonb);
  v := v || jsonb_build_object('case','analysis_required_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_ANALYSIS_REQUIRED','got',g->'reason_codes');
  -- 5) PENDING_EXTERNAL_CJ_SOURCING rejected (Nitro negative test)
  g := public.fn_storefront_test_eligibility(base_ok || '{"recommendation":"WATCH","sourcing_status":"PENDING_EXTERNAL_CJ_SOURCING"}'::jsonb);
  v := v || jsonb_build_object('case','pending_external_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_SOURCING_PENDING_EXTERNAL','got',g->'reason_codes');
  -- 6) OUT_OF_STOCK rejected
  g := public.fn_storefront_test_eligibility(base_ok || '{"stock_state":"OUT_OF_STOCK"}'::jsonb);
  v := v || jsonb_build_object('case','out_of_stock_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_OUT_OF_STOCK','got',g->'reason_codes');
  -- 7) unknown stock rejected (hard gate requires stock)
  g := public.fn_storefront_test_eligibility(base_ok || '{"stock_state":"UNKNOWN"}'::jsonb);
  v := v || jsonb_build_object('case','unknown_stock_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_STOCK_UNKNOWN','got',g->'reason_codes');
  -- 8) invalid economics rejected (NEGATIVE and UNKNOWN)
  g := public.fn_storefront_test_eligibility(base_ok || '{"economics_state":"NEGATIVE"}'::jsonb);
  v := v || jsonb_build_object('case','economics_negative_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_ECONOMICS_UNVIABLE','got',g->'reason_codes');
  g := public.fn_storefront_test_eligibility(base_ok || '{"economics_state":"UNKNOWN"}'::jsonb);
  v := v || jsonb_build_object('case','economics_unknown_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_ECONOMICS_UNKNOWN','got',g->'reason_codes');
  -- 9) cross-market evidence cannot satisfy local hard gate (identity weak)
  g := public.fn_storefront_test_eligibility(base_ok || '{"market_supplier_match":"CLOSE_COMPARABLE","subtype_price_valid":false}'::jsonb);
  v := v || jsonb_build_object('case','cross_market_cannot_satisfy_local','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_IDENTITY_WEAK','got',g->'reason_codes');
  -- also: supplier not canonical
  g := public.fn_storefront_test_eligibility(base_ok || '{"supplier_identity_state":"SUPPLIER_AMBIGUOUS"}'::jsonb);
  v := v || jsonb_build_object('case','supplier_not_canonical_rejected','pass',(g->>'test_eligible')::boolean=false AND g->'reason_codes' ? 'REJECT_SUPPLIER_NOT_CANONICAL','got',g->'reason_codes');

  -- 10) template selection deterministic (electronics/research -> FEATURE_TECHNOLOGY)
  s := public.fn_select_conversion_template('{"category":"electronics","traffic_source":"research","buyer_pain":true,"has_specs":true,"has_product_image":true}'::jsonb);
  v := v || jsonb_build_object('case','template_selection_feature_tech','pass',s->>'recommended_template_family'='FEATURE_TECHNOLOGY' AND s->>'label'='BEST_FIT','got',s->>'recommended_template_family');
  -- idempotent selection (same input -> same family)
  r := public.fn_select_conversion_template('{"category":"electronics","traffic_source":"research","buyer_pain":true,"has_specs":true,"has_product_image":true}'::jsonb);
  v := v || jsonb_build_object('case','selection_deterministic','pass',(s->>'recommended_template_family')=(r->>'recommended_template_family'),'got',r->>'recommended_template_family');
  -- versioning present
  v := v || jsonb_build_object('case','template_versioning','pass',s->>'template_version' IS NOT NULL,'got',s->>'template_version');

  -- 11) section selection: COMPARISON hides without comparison basis
  v := v || jsonb_build_object('case','comparison_section_hidden','pass', s->'missing_evidence' ? 'COMPARISON','got',s->'missing_evidence');
  -- 12) UGC family excluded / SOCIAL_EVIDENCE not forced without reviews
  v := v || jsonb_build_object('case','ugc_excluded_without_reviews','pass',
        NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'all_candidates') c WHERE c->>'family'='UGC_SOCIAL_COMMERCE'),'got',s->'all_candidates');
  -- reviews present -> UGC becomes a candidate
  r := public.fn_select_conversion_template('{"category":"broad_consumer","traffic_source":"social","buyer_pain":true,"has_reviews_ugc":true,"has_product_image":true}'::jsonb);
  v := v || jsonb_build_object('case','ugc_candidate_with_reviews','pass',
        EXISTS (SELECT 1 FROM jsonb_array_elements(r->'all_candidates') c WHERE c->>'family'='UGC_SOCIAL_COMMERCE'),'got',r->'all_candidates');

  -- 13) claim safety: fabricated reviews text is flagged
  v := v || jsonb_build_object('case','claim_scan_flags_reviews','pass', jsonb_array_length(public.fn_ad_studio_claim_scan('Rated 5 stars by 2000 happy customers, best seller!')) > 0,'got',public.fn_ad_studio_claim_scan('Rated 5 stars by 2000 happy customers'));
  -- clean honest copy passes
  v := v || jsonb_build_object('case','claim_scan_clean_honest_copy','pass', jsonb_array_length(public.fn_ad_studio_claim_scan('A practical countertop device for everyday use. Ships from the supplier warehouse.')) = 0,'got',public.fn_ad_studio_claim_scan('A practical countertop device for everyday use.'));

  -- 14) supplier asset rights/provenance + 15) reference-only rejected
  --   synthetic assets under a throwaway supplier_product_id
  INSERT INTO public.supplier_product_assets(id,supplier,supplier_product_id,asset_type,asset_class,rights_state,availability,is_primary,original_source,provenance,is_fixture)
   VALUES (gen_random_uuid(),'cjdropshipping','SELFTEST_PID','IMAGE','SOURCE_PRODUCT_ASSET','SUPPLIER_PROVIDED','AVAILABLE',true,'cjdropshipping','{}'::jsonb,true),
          (gen_random_uuid(),'cjdropshipping','SELFTEST_PID','IMAGE','SOURCE_PRODUCT_ASSET','UNKNOWN','AVAILABLE',false,'cjdropshipping','{}'::jsonb,true),
          (gen_random_uuid(),'cjdropshipping','SELFTEST_PID','IMAGE','SOURCE_PRODUCT_ASSET','SUPPLIER_PROVIDED','AVAILABLE',false,'cjdropshipping','{"purpose":"SOURCING_REFERENCE"}'::jsonb,true),
          (gen_random_uuid(),'fruugo','SELFTEST_PID','IMAGE','SOURCE_PRODUCT_ASSET','SUPPLIER_PROVIDED','AVAILABLE',false,'fruugo','{}'::jsonb,true);
  a := public.fn_resolve_storefront_assets('cjdropshipping','SELFTEST_PID','US');
  v := v || jsonb_build_object('case','assets_available_supplier_provided','pass',a->>'state'='ASSETS_AVAILABLE' AND (a->>'usable_count')::int=1,'got',a->>'usable_count');
  v := v || jsonb_build_object('case','asset_rights_unknown_rejected','pass',
        EXISTS (SELECT 1 FROM jsonb_array_elements(a->'rejected') x WHERE x->>'reason'='RIGHTS_NOT_ESTABLISHED'),'got',a->'rejected');
  v := v || jsonb_build_object('case','asset_sourcing_reference_rejected','pass',
        EXISTS (SELECT 1 FROM jsonb_array_elements(a->'rejected') x WHERE x->>'reason'='SOURCING_REFERENCE'),'got',a->'rejected');
  v := v || jsonb_build_object('case','asset_reference_marketplace_rejected','pass',
        EXISTS (SELECT 1 FROM jsonb_array_elements(a->'rejected') x WHERE x->>'reason'='REFERENCE_ONLY_MARKETPLACE'),'got',a->'rejected');
  -- nitro-like: no assets at all -> IMAGE_UNAVAILABLE (CJ sourcing image cannot resolve)
  a := public.fn_resolve_storefront_assets('cjdropshipping','2609120902334496901','US');
  v := v || jsonb_build_object('case','nitro_image_unavailable','pass',a->>'state'='IMAGE_UNAVAILABLE' AND (a->>'usable_count')::int=0,'got',a->>'state');
  DELETE FROM public.supplier_product_assets WHERE supplier_product_id='SELFTEST_PID';

  -- 16) full generation REFUSED for ineligible (nitro pending), nothing persisted
  r := public.fn_generate_storefront_runtime(u1,
        base_ok || '{"recommendation":"WATCH","sourcing_status":"PENDING_EXTERNAL_CJ_SOURCING","stock_state":"UNKNOWN","economics_state":"UNKNOWN","product_confidence":"UNKNOWN","fulfilment_evidence":false}'::jsonb,
        '{"category":"kitchen","buyer_pain":true}'::jsonb,
        '{"product_title":"Nitro Cold Brew Maker","positioning":"nitro cold brew maker","display_currency":"USD","selling_price":"89","supplier":"cjdropshipping","supplier_product_id":"2609120902334496901"}'::jsonb,
        '{"recommendation":"WATCH","target_market":"US","economics":{"economics_state":"UNKNOWN"}}'::jsonb,
        'PULSE_HOSTED','REAL',NULL,'US',NULL,false);
  v := v || jsonb_build_object('case','generation_refused_nitro','pass',r->>'status'='REFUSED' AND (r->>'test_eligible')::boolean=false,'got',r->>'status');
  -- eligible generation preview (no persist) resolves the runtime contract
  r := public.fn_generate_storefront_runtime(u1, base_ok,
        '{"category":"electronics","traffic_source":"research","buyer_pain":true,"has_specs":true,"has_product_image":true}'::jsonb,
        '{"product_title":"3-Channel Dash Cam","positioning":"3-channel dash cam","category":"electronics","display_currency":"USD","selling_price":"91.79","source_currency":"USD","supplier":"cjdropshipping","supplier_product_id":"1980170173102026754"}'::jsonb,
        '{"recommendation":"TEST","target_market":"US","economics":{"economics_state":"VIABLE","landed_cost_currency":"USD","landed_cost_display":"24.28"}}'::jsonb,
        'PULSE_HOSTED','REAL',NULL,'US',NULL,false);
  v := v || jsonb_build_object('case','generation_preview_contract','pass',
        r->>'status'='ok_preview' AND r->'runtime_contract'->>'template_family'='FEATURE_TECHNOLOGY'
        AND r->'runtime_contract'->>'template_version' IS NOT NULL
        AND r->'runtime_contract' ? 'ad_match_ref','got',r->'runtime_contract'->>'template_family');
  -- idempotent generation (same inputs -> same gate + family)
  g := public.fn_generate_storefront_runtime(u1, base_ok,
        '{"category":"electronics","traffic_source":"research","buyer_pain":true,"has_specs":true,"has_product_image":true}'::jsonb,
        '{"product_title":"3-Channel Dash Cam","positioning":"3-channel dash cam","category":"electronics","display_currency":"USD","selling_price":"91.79","supplier":"cjdropshipping","supplier_product_id":"1980170173102026754"}'::jsonb,
        '{"recommendation":"TEST","target_market":"US","economics":{"economics_state":"VIABLE"}}'::jsonb,
        'PULSE_HOSTED','REAL',NULL,'US',NULL,false);
  v := v || jsonb_build_object('case','generation_idempotent_preview','pass',
        (g->'runtime_contract'->>'template_family')=(r->'runtime_contract'->>'template_family'),'got',g->'runtime_contract'->>'template_family');

  -- ===== Persistence / state / tenant scenarios (synthetic page, cleaned up) =====
  INSERT INTO public.commerce_product_pages(user_id,market,destination,decision_classification,page_model,status,
     source_kind,review_state,publication_state,runtime_contract,country_code)
   VALUES (u1,'US','PULSE_STORE','TEST','{}'::jsonb,'DRAFT','REAL','DRAFT','UNPUBLISHED',
     '{"claim_safety":{"claim_scan_clean":true}}'::jsonb,'US')
   RETURNING id INTO pid;
  INSERT INTO public.commerce_store_projects(user_id,product_page_id,project_state,slug,source_kind)
   VALUES (u1,pid,'DRAFT','selftest-'||left(replace(pid::text,'-',''),8),'REAL');

  -- 17) state transitions DRAFT->IN_REVIEW->APPROVED->PUBLISHED
  r := public.fn_storefront_transition_state(pid,'IN_REVIEW',u1);
  v := v || jsonb_build_object('case','transition_draft_to_in_review','pass',r->>'status'='ok' AND r->>'review_state'='IN_REVIEW','got',r->>'status');
  r := public.fn_storefront_transition_state(pid,'APPROVED',u1);
  v := v || jsonb_build_object('case','transition_in_review_to_approved','pass',r->>'status'='ok','got',r->>'status');
  r := public.fn_storefront_transition_state(pid,'PUBLISHED',u1);
  v := v || jsonb_build_object('case','transition_approved_to_published_pulse','pass',r->>'status'='ok' AND r->>'publication_state'='PUBLISHED','got',r->>'status');
  -- 18) publication state safety: ad addressable exposes URL only when published
  a := public.fn_storefront_ad_addressable(pid,u1);
  v := v || jsonb_build_object('case','ad_addressable_no_campaign_no_spend','pass',
        (a->>'campaign_created')::boolean=false AND (a->>'ad_spend_authorized')::int=0 AND (a->>'meta_activated')::boolean=false AND (a->>'addressable')::boolean=true,'got',a->>'status');
  -- 19) tenant isolation / cross-tenant denial
  r := public.fn_storefront_transition_state(pid,'ARCHIVED',u2);
  v := v || jsonb_build_object('case','cross_tenant_denied','pass',r->>'status'='DENIED_CROSS_TENANT','got',r->>'status');
  -- 20) country switch resolves new Product×Country (not currency conversion)
  r := public.fn_storefront_change_country(pid,'DE',u1);
  v := v || jsonb_build_object('case','country_switch_resolves_context','pass',r->>'status'='COUNTRY_CONTEXT_RESOLUTION_REQUIRED' AND (r->>'currency_only_conversion_permitted')::boolean=false,'got',r->>'status');

  -- second page for invalid-transition + shopify-block tests
  INSERT INTO public.commerce_product_pages(user_id,market,destination,decision_classification,page_model,status,
     source_kind,review_state,publication_state,runtime_contract)
   VALUES (u1,'US','PULSE_STORE','TEST','{}'::jsonb,'DRAFT','REAL','DRAFT','UNPUBLISHED','{"claim_safety":{"claim_scan_clean":true}}'::jsonb)
   RETURNING id INTO pid2;
  -- invalid transition DRAFT->PUBLISHED
  r := public.fn_storefront_transition_state(pid2,'PUBLISHED',u1);
  v := v || jsonb_build_object('case','invalid_transition_draft_to_published','pass',r->>'status'='INVALID_TRANSITION','got',r->>'status');
  -- Shopify without connection blocked
  r := public.fn_storefront_set_destination(pid2,'SHOPIFY',NULL,NULL,u1);
  v := v || jsonb_build_object('case','shopify_blocked_without_connection','pass',r->>'status'='BLOCKED_EXTERNAL_SHOPIFY_CONNECTION','got',r->>'status');
  -- generic external url validation path
  r := public.fn_storefront_set_destination(pid2,'GENERIC_EXTERNAL_URL',NULL,'not a url',u1);
  v := v || jsonb_build_object('case','generic_url_invalid_blocked','pass',r->>'status' LIKE 'BLOCKED%','got',r->>'status');
  -- claim-safety cannot be bypassed on approve: flip claim_scan_clean=false
  UPDATE public.commerce_product_pages SET runtime_contract='{"claim_safety":{"claim_scan_clean":false}}'::jsonb, review_state='IN_REVIEW' WHERE id=pid2;
  r := public.fn_storefront_transition_state(pid2,'APPROVED',u1);
  v := v || jsonb_build_object('case','claim_safety_not_bypassed_on_approve','pass',r->>'status'='BLOCKED_CLAIM_SAFETY','got',r->>'status');

  -- cleanup
  DELETE FROM public.commerce_store_projects WHERE product_page_id IN (pid,pid2);
  DELETE FROM public.commerce_product_pages WHERE id IN (pid,pid2);

  RETURN jsonb_build_object(
    'suite','PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'failures', (SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_runtime_selftest() IS
 'PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001 regression harness. Deterministic; persistence tests use synthetic tenants and clean up. Returns pass/fail per scenario.';
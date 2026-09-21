-- ============================================================================
-- mig_270_selftest_reconcile_tiktok_available.sql
-- STRATELOQ — deferred 014F.10 selftest reconcile (test-truth only)
--
-- 014F.10 legitimately connected TikTok Commercial Content and mig_267 transitioned
-- provider_capability_registry (TIKTOK, SOCIAL_VIDEO).availability
-- SOURCE_UNSUPPORTED -> AVAILABLE. mig_268 reconciled fn_tiktok_executor_selftest but
-- two other selftests kept stale assertions that expected TikTok to be blocked:
--
--   * fn_deep_research_selftest      -> case tiktok_registered_blocked
--       (asserted availability='SOURCE_UNSUPPORTED')
--   * fn_research_orchestrator_selftest -> cases tiktok_blocked
--       (asserted the SOCIAL_VIDEO attempt is created BLOCKED_EXTERNAL_ACCESS) and
--       finalize_partial_with_gap
--       (asserted a finalized PARTIAL run has launch_critical_gap=true, where the
--        gap came from TikTok being the blocked source)
--
-- These are now false because TikTok is AVAILABLE: attempt creation
-- (fn_own_request_product_market_research, mig_243) gives an AVAILABLE source
-- state='NOT_SEARCHED', and with every GB source connected there is no blocked-source
-- launch gap (launch_critical_gap = v_blocked>0 = false).
--
-- This migration reconciles ONLY those three stale assertions to the connected truth
-- (CREATE OR REPLACE, changing only the affected lines). It is TEST-TRUTH ONLY:
--   * No pipeline behavior, dispatch logic, coverage/gap computation, WPS/PME scoring,
--     Product Decision gates, provider availability or multi-market behavior is changed.
--   * fn_deep_research_selftest.founder_tiktok_blocked is intentionally LEFT UNCHANGED:
--     fn_ecommerce_research_source_states still returns BLOCKED_EXTERNAL_ACCESS for
--     SOCIAL_VIDEO for a product (its read-side behavior did not change), so that
--     assertion is still truthful and passing. (The read-vs-dispatch inconsistency for
--     TikTok is a product-first question flagged separately, not touched here.)
--   * No 015B problem-foundation object is touched.
-- ============================================================================

-- (1) fn_deep_research_selftest: tiktok_registered_blocked -> tiktok_registered_available
CREATE OR REPLACE FUNCTION public.fn_deep_research_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v jsonb := '[]'::jsonb; f uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61'; s jsonb;
BEGIN
  -- reconciled: TikTok is registered AND live-connected (AVAILABLE) since 014F.10/mig_267
  v := v || jsonb_build_object('case','tiktok_registered_available','pass',
    EXISTS(SELECT 1 FROM public.provider_capability_registry
           WHERE source='TIKTOK' AND evidence_category='SOCIAL_VIDEO' AND availability='AVAILABLE'));
  v := v || jsonb_build_object('case','semantics_mismatch_flagged','pass',
    (public.fn_ecommerce_opportunity_labels('HIGH_CONFIDENCE_TEST','NONE')->>'label_evidence_mismatch')::boolean = true
    AND (public.fn_ecommerce_opportunity_labels('HIGH_CONFIDENCE_TEST','NONE')->>'opportunity_label') = 'Strong test candidate');
  v := v || jsonb_build_object('case','grade_high_needs_4_and_high','pass',
    (public.fn_ecommerce_evidence_grade(4,'HIGH',false)->>'grade')='HIGH_CONFIDENCE'
    AND (public.fn_ecommerce_evidence_grade(4,'HIGH',true)->>'grade')<>'HIGH_CONFIDENCE');
  v := v || jsonb_build_object('case','grade_strong_needs_3_moderate','pass',
    (public.fn_ecommerce_evidence_grade(3,'MODERATE',true)->>'grade')='STRONG_EVIDENCE_BACKED');
  v := v || jsonb_build_object('case','grade_two_source_developing','pass',
    (public.fn_ecommerce_evidence_grade(2,'LOW',true)->>'grade')='DEVELOPING_EVIDENCE');
  s := public.fn_ecommerce_research_source_states(f,'275266ba-0569-4a47-a5fc-2c5bef27eb0e','GB');
  v := v || jsonb_build_object('case','founder_community_found','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='COMMUNITY')='SEARCHED_EVIDENCE_FOUND');
  v := v || jsonb_build_object('case','founder_marketplace_found','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='MARKETPLACE')='SEARCHED_EVIDENCE_FOUND');
  v := v || jsonb_build_object('case','founder_search_not_searched','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='SEARCH_DEMAND')='NOT_SEARCHED');
  v := v || jsonb_build_object('case','founder_advertising_not_searched','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='ADVERTISING')='NOT_SEARCHED');
  -- unchanged: fn_ecommerce_research_source_states still reports SOCIAL_VIDEO as
  -- BLOCKED_EXTERNAL_ACCESS for a product (read-side behavior not changed by 014F.10)
  v := v || jsonb_build_object('case','founder_tiktok_blocked','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='SOCIAL_VIDEO')='BLOCKED_EXTERNAL_ACCESS');
  v := v || jsonb_build_object('case','ledger_integrity_no_synthetic','pass',
    NOT EXISTS (SELECT 1 FROM public.commerce_research_run r
                 WHERE r.product_id NOT IN (SELECT id FROM public.commerce_products)
                    OR r.tenant_id IS NULL)
    AND NOT EXISTS (SELECT 1 FROM public.commerce_research_source_attempt a
                     WHERE a.run_id NOT IN (SELECT id FROM public.commerce_research_run)));
  RETURN jsonb_build_object('suite','deep_research_infrastructure',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

-- (2) fn_research_orchestrator_selftest: tiktok_blocked -> tiktok_dispatchable (NOT_SEARCHED);
--     finalize_partial_with_gap -> finalize_partial_no_blocked_gap (gap=false now no source is blocked)
CREATE OR REPLACE FUNCTION public.fn_research_orchestrator_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_founder uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_req jsonb; v_run uuid; v_res jsonb := '[]'::jsonb; v_pass boolean := true;
  n_att int; n_tiktok int; n_meta_gb int; n_ebay int;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_founder::text, 'role','authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_founder::text, true);
  PERFORM set_config('pulse.suppress_dispatch','on', true);
  v_req := public.fn_own_request_product_market_research(v_prod, 'GB', 0);
  v_run := nullif(v_req->>'run_id','')::uuid;
  SELECT count(*) INTO n_att FROM public.commerce_research_source_attempt WHERE run_id=v_run;
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','request_creates_6_attempts','pass',(v_req->>'status'='RESEARCHING' AND n_att=6),'attempts',n_att));
  v_pass := v_pass AND (v_req->>'status'='RESEARCHING' AND n_att=6);
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','auto_dispatch_suppressed_in_selftest','pass',(v_req->>'auto_dispatch'='DISPATCH_SUPPRESSED'),'auto_dispatch',v_req->>'auto_dispatch'));
  v_pass := v_pass AND (v_req->>'auto_dispatch'='DISPATCH_SUPPRESSED');
  -- reconciled: TikTok is AVAILABLE since 014F.10, so its SOCIAL_VIDEO attempt is now
  -- created dispatchable (NOT_SEARCHED), no longer BLOCKED_EXTERNAL_ACCESS
  SELECT count(*) INTO n_tiktok FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='SOCIAL_VIDEO' AND state='NOT_SEARCHED' AND source='TIKTOK';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','tiktok_dispatchable','pass',(n_tiktok=1)));
  v_pass := v_pass AND (n_tiktok=1);
  SELECT count(*) INTO n_meta_gb FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='ADVERTISING' AND state='NOT_SEARCHED' AND source='META_AD_LIBRARY';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','meta_available_gb','pass',(n_meta_gb=1)));
  v_pass := v_pass AND (n_meta_gb=1);
  SELECT count(*) INTO n_ebay FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='MARKETPLACE' AND state='NOT_SEARCHED' AND source='EBAY';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','ebay_dispatchable','pass',(n_ebay=1)));
  v_pass := v_pass AND (n_ebay=1);
  DECLARE v_fin jsonb; BEGIN
    v_fin := public.fn_finalize_research_run(v_run);
    -- reconciled: with every GB source connected (incl. TikTok AVAILABLE) there is no
    -- blocked-source launch gap; a finalized, un-searched run is PARTIAL with gap=false
    v_res := v_res || jsonb_build_array(jsonb_build_object('case','finalize_partial_no_blocked_gap',
      'pass',(v_fin->>'status'='PARTIAL' AND (v_fin->>'launch_critical_gap')::boolean=false),
      'status',v_fin->>'status','gap',v_fin->>'launch_critical_gap'));
    v_pass := v_pass AND (v_fin->>'status'='PARTIAL' AND (v_fin->>'launch_critical_gap')::boolean=false);
  END;
  DECLARE v_bad jsonb; BEGIN
    v_bad := public.fn_own_request_product_market_research(v_prod, 'ZZ', 0);
    v_res := v_res || jsonb_build_array(jsonb_build_object('case','unsupported_market_rejected','pass',(v_bad->>'status'='UNSUPPORTED_MARKET')));
    v_pass := v_pass AND (v_bad->>'status'='UNSUPPORTED_MARKET');
  END;
  DECLARE v_cache jsonb; BEGIN
    v_cache := public.fn_own_request_product_market_research(v_prod, 'GB');
    v_res := v_res || jsonb_build_array(jsonb_build_object('case','cache_reused_default_freshness','pass',(v_cache->>'status'='CACHE_REUSED')));
    v_pass := v_pass AND (v_cache->>'status'='CACHE_REUSED');
  END;
  DELETE FROM public.commerce_research_source_attempt WHERE run_id=v_run;
  DELETE FROM public.commerce_research_run WHERE id=v_run;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('pulse.suppress_dispatch','', true);
  RETURN jsonb_build_object('all_pass',v_pass,'cases',v_res,'contract','pulse_research_selftest_v3_013n');
END; $function$;

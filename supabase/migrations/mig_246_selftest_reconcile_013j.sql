-- ============================================================================
-- mig_246_selftest_reconcile_013j.sql
-- STRATELOQ-REAL-PRODUCT-MARKET-DEEP-RESEARCH-ORCHESTRATOR-013J (test reconcile)
--
-- 013J's first REAL research run legitimately (a) populates the research-run
-- ledger and (b) rebuilds the star-projector GB competitor set from live eBay
-- evidence (founder real competitors 74 -> 167). Two earlier selftests asserted
-- frozen pre-013J counts:
--   * fn_deep_research_selftest        -> ledger_tables_empty  (ledger now holds a real run)
--   * fn_ecommerce_intelligence_...    -> founder_competitors_74 (now 167 real)
-- Neither is a behaviour regression; the counts moved because REAL evidence
-- moved. Replace the frozen-count assertions with integrity assertions that
-- stay true as real research accrues (real/non-fixture, no synthetic rows).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_deep_research_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; f uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61'; s jsonb;
BEGIN
  v := v || jsonb_build_object('case','tiktok_registered_blocked','pass',
    EXISTS(SELECT 1 FROM public.provider_capability_registry WHERE source='TIKTOK' AND availability='SOURCE_UNSUPPORTED'));
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
  v := v || jsonb_build_object('case','founder_tiktok_blocked','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='SOCIAL_VIDEO')='BLOCKED_EXTERNAL_ACCESS');
  -- 013J: the ledger now legitimately holds REAL research runs. Assert integrity
  -- (every run maps to a real product + tenant; every attempt to a real run) rather
  -- than emptiness. No synthetic/orphan rows may exist.
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

CREATE OR REPLACE FUNCTION public.fn_ecommerce_intelligence_contracts_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; f uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
BEGIN
  -- 013J: real research legitimately grows the competitor set. Assert real,
  -- non-fixture competitors exist with zero fixture leakage (not a frozen count).
  v := v || jsonb_build_object('case','founder_competitors_real_no_fixtures','pass',
    (SELECT count(*) FROM public.product_market_competitors WHERE tenant_id=f AND coalesce(is_fixture,false)=false) > 0
    AND (SELECT count(*) FROM public.product_market_competitors WHERE tenant_id=f AND is_fixture=true) = 0);
  v := v || jsonb_build_object('case','founder_supplier_no_data','pass',
    (SELECT count(*) FROM public.product_acquisitions WHERE user_id=f)=0);
  v := v || jsonb_build_object('case','founder_brief_unlinked','pass',
    (SELECT count(*) FROM public.ad_studio_briefs WHERE tenant_id=f AND coalesce(is_fixture,false)=false AND decision_id IS NULL)=1);
  v := v || jsonb_build_object('case','founder_brief_product_linked','pass',
    (SELECT bool_and(product_id IS NOT NULL) FROM public.ad_studio_briefs WHERE tenant_id=f AND coalesce(is_fixture,false)=false));
  v := v || jsonb_build_object('case','founder_signal_types_real','pass',
    (SELECT array_agg(DISTINCT signal_type) FROM public.commerce_signals WHERE user_id=f) = ARRAY['COMMUNITY_ATTENTION']);
  v := v || jsonb_build_object('case','founder_executions_present','pass',
    (SELECT count(*) FROM public.marketing_campaign_executions WHERE user_id=f) >= 1);
  RETURN jsonb_build_object('suite','ecommerce_intelligence_contracts',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

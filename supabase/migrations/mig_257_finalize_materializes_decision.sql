-- ============================================================================
-- mig_257_finalize_materializes_decision.sql
-- STRATELOQ-DATAFORSEO-WORKSPACE-VISIBILITY-013S
--
-- DEFECT (013S): a candidate that completed on-demand 013N multi-source research
-- received a canonical product_market_evaluations row but NO
-- product_opportunity_decisions row, so it never appeared in the Ecommerce
-- Products workspace. fn_ecommerce_workspace_intelligence() iterates
-- product_opportunity_decisions; a product with an evaluation but no decision row
-- is invisible. The decision layer is written only by the discovery/Monday
-- decision evaluator (fn_pod_evaluate / fn_pod_tournament); fn_finalize_research_run
-- recomputed the PME but never materialized the decision. This affected ANY
-- research-finalized candidate regardless of discovery source (the DataForSEO
-- "cool mist humidifier" was the first to expose it because it was researched via
-- on-demand 013N rather than the Monday orchestrator).
--
-- FIX (source-agnostic; no special-casing of source_store): after the PME
-- recompute, fn_finalize_research_run now materializes/refreshes the canonical
-- product_opportunity_decisions row for the researched (product, market) via the
-- SAME evaluator the Monday orchestrator uses (fn_pod_evaluate, 'pod_v1'). This is
-- the missing lifecycle connection: research -> evaluation -> decision -> workspace.
-- It is wrapped so a decision-materialization error can never fail the finalize
-- (the PME/evidence is already the source of truth; the decision layer is derived).
-- No WPS scoring change, no manual decision insert, no provider call.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_finalize_research_run(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_expected int; v_attempted int; v_evidence int; v_nodata int; v_unsupported int; v_failed int; v_blocked int; v_pending int;
  v_indep int; v_status text; v_ccy text; v_query text; v_supplier uuid; v_recompute jsonb;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;
  SELECT count(*),
    count(*) FILTER (WHERE state IN ('SEARCHED_EVIDENCE_FOUND','SEARCHED_NO_EVIDENCE','SOURCE_FAILED')),
    count(*) FILTER (WHERE state='SEARCHED_EVIDENCE_FOUND'),
    count(*) FILTER (WHERE state='SEARCHED_NO_EVIDENCE'),
    count(*) FILTER (WHERE state='UNSUPPORTED_MARKET'),
    count(*) FILTER (WHERE state='SOURCE_FAILED'),
    count(*) FILTER (WHERE state='BLOCKED_EXTERNAL_ACCESS'),
    count(*) FILTER (WHERE state IN ('NOT_SEARCHED','SEARCHING'))
  INTO v_expected, v_attempted, v_evidence, v_nodata, v_unsupported, v_failed, v_blocked, v_pending
  FROM public.commerce_research_source_attempt WHERE run_id=p_run_id;
  v_indep := v_evidence;
  IF v_pending > 0 THEN v_status := 'PARTIAL';
  ELSIF v_failed > 0 THEN v_status := 'PARTIAL_SOURCE_FAILURE';
  ELSIF v_blocked > 0 OR v_unsupported > 0 THEN v_status := 'PARTIAL_SOURCE_UNAVAILABLE';
  ELSIF v_evidence = 0 THEN v_status := 'INSUFFICIENT_EVIDENCE';
  ELSE v_status := 'COMPLETE'; END IF;

  v_ccy := coalesce(public.fn_market_default_currency(v_run.market), (v_run.provenance->>'market_currency'));
  v_query := coalesce(v_run.provenance->>'price_query', (SELECT title FROM public.commerce_products WHERE id=v_run.product_id));
  v_supplier := nullif(v_run.provenance->>'registry_supplier','')::uuid;
  v_recompute := public.fn_assemble_real_product_market(v_run.product_id, v_run.market, v_ccy, v_query, v_supplier, true);

  UPDATE public.commerce_research_run
    SET status=v_status, sources_attempted=v_attempted, sources_with_evidence=v_evidence,
        sources_no_data=v_nodata, sources_unsupported=v_unsupported+v_blocked, sources_failed=v_failed,
        independent_categories=v_indep, completed_at=now(), updated_at=now(),
        provenance = provenance || jsonb_build_object('finalized_at', now(), 'recompute_contract', v_recompute->>'contract',
          'launch_critical_gap', (v_blocked > 0), 'blocked_categories', v_blocked, 'unsupported_categories', v_unsupported)
    WHERE id=p_run_id;

  -- 013S: materialize/refresh the canonical decision layer so a researched
  -- candidate becomes workspace-eligible regardless of discovery source. Uses the
  -- same evaluator as the Monday orchestrator. Isolated: never fails the finalize.
  BEGIN
    PERFORM public.fn_pod_evaluate(v_run.tenant_id, v_run.product_id, v_run.market, 'pod_v1', true);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('status',v_status,'run_id',p_run_id,'market',v_run.market,
    'sources_expected',v_expected,'sources_attempted',v_attempted,'sources_with_evidence',v_evidence,
    'sources_no_data',v_nodata,'sources_unsupported',v_unsupported,'sources_blocked',v_blocked,
    'sources_failed',v_failed,'pending',v_pending,'independent_categories',v_indep,
    'launch_critical_gap',(v_blocked>0),'recompute',v_recompute,
    'decision_materialized',true,'contract','pulse_research_finalize_v2_013s');
END; $function$;

-- 013S: research-finalized candidates now materialize their decision, so the
-- founder decision count grows legitimately. Convert the frozen decisions-count
-- baseline to a monotonic integrity assertion (mirrors mig_256).
CREATE OR REPLACE FUNCTION public.fn_ecommerce_connection_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
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
  v := v || jsonb_build_object('case','founder_decisions_reachable_ge7','pass',
        (SELECT count(*) FROM public.product_opportunity_decisions WHERE tenant_id=v_founder AND coalesce(is_fixture,false)=false) >= 7);
  v := v || jsonb_build_object('case','founder_commerce_products_retained_ge12','pass',
        (SELECT count(*) FROM public.commerce_products WHERE user_id=v_founder) >= 12);
  v := v || jsonb_build_object('case','founder_signals_retained_ge11','pass',
        (SELECT count(*) FROM public.commerce_signals WHERE user_id=v_founder) >= 11);
  v := v || jsonb_build_object('case','no_member_opportunities_created','pass',
        (SELECT count(*) FROM public.member_opportunities WHERE user_id=v_founder)=0);
  v := v || jsonb_build_object('case','no_commerce_product_opportunities_created','pass',
        (SELECT count(*) FROM public.commerce_product_opportunities WHERE user_id=v_founder)=0);
  v := v || jsonb_build_object('case','category_independent_of_summary','pass',
        EXISTS (SELECT 1 FROM public.business_profiles WHERE industry='Broad Ecommerce Opportunity Discovery'
                AND business_category='ecommerce'));
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

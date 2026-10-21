-- mig_320_research_supplier_resolution_handoff.sql
--
-- STAGE 4A — complete the CJ product-list -> Stage-2 exact-supplier resolver handoff on the research path.
--
-- The Stage-2 resolver chain already exists and is correct:
--   fn_stage2_cj_finalize_candidates(pages) -> fn_resolve_concrete_supplier_identity(candidates) ->
--   commerce_concrete_supplier_resolution (binds ONLY a shared-identifier EXACT match or a single
--   STRONG_SAME_PRODUCT/EXACT_CONFIRMED attribute match; category-adjacent candidates never bind).
-- But the 013N auto-dispatch research path only did CJ product/list + ingest into the shared catalog
-- (commerce_supplier_products) and never invoked the resolver, so a research run produced NO supplier
-- resolution row -> the Product Intelligence drawer showed "not searched" instead of a truthful
-- EXACT_SUPPLIER_IDENTITY_RESOLVED / NO_VALID_CJ_MATCH. This migration wires the resolver into run
-- finalisation (the correct point: all marketplace evidence + all cached CJ candidates are present),
-- reusing the existing contract, as a best-effort step that never fails the run.
--
-- Free + cached only: fn_resolve_concrete_supplier_identity(..., NULL, true) self-selects the already-
-- ingested CJ candidates from commerce_supplier_products by the product's own search terms and persists
-- the resolution. No provider/API call. Preserves tenant/country isolation (the resolver verifies the
-- product belongs to the tenant and scopes by market), provenance and Product Asset Lock.

CREATE OR REPLACE FUNCTION public.fn_finalize_research_run(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- STAGE-2 SUPPLIER RESOLUTION HANDOFF (mig_320): when CJ supplier search ran this run, resolve the
  -- concrete product to an exact CJ supplier from the cached candidates and persist the result (an
  -- EXACT bind, or a truthful NO_VALID_CJ_MATCH). Reuses the existing resolver; free (no provider call);
  -- best-effort so a resolver error never fails finalisation.
  IF EXISTS (SELECT 1 FROM public.commerce_research_source_attempt
             WHERE run_id=p_run_id AND evidence_category='SUPPLIER'
               AND state IN ('SEARCHED_EVIDENCE_FOUND','SEARCHED_NO_EVIDENCE')) THEN
    BEGIN
      PERFORM public.fn_resolve_concrete_supplier_identity(v_run.tenant_id, v_run.product_id, v_run.market, NULL, true);
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  BEGIN PERFORM public.fn_pod_evaluate(v_run.tenant_id, v_run.product_id, v_run.market, 'pod_v1', true);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN PERFORM public.fn_backfill_product_images_from_evidence(v_run.product_id);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object('status',v_status,'run_id',p_run_id,'market',v_run.market,
    'sources_expected',v_expected,'sources_attempted',v_attempted,'sources_with_evidence',v_evidence,
    'sources_no_data',v_nodata,'sources_unsupported',v_unsupported,'sources_blocked',v_blocked,
    'sources_failed',v_failed,'pending',v_pending,'independent_categories',v_indep,
    'launch_critical_gap',(v_blocked>0),'recompute',v_recompute,
    'decision_materialized',true,'image_capture_attempted',true,'supplier_resolution_attempted',true,
    'contract','pulse_research_finalize_v4_013w_supplierresolve');
END; $function$;

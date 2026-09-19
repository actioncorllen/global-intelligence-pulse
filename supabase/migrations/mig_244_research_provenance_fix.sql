-- ============================================================================
-- mig_244_research_provenance_fix.sql
-- STRATELOQ-REAL-PRODUCT-MARKET-DEEP-RESEARCH-ORCHESTRATOR-013J (fix)
--
-- Two defects in mig_243's fn_research_ingest_source provenance linkage:
--  1. It filtered new rows by `created_at >= clock_timestamp()`, but
--     commerce_signals.created_at defaults to transaction-start now(), which is
--     earlier than the marker — so no newly-inserted row ever matched (0 tagged).
--  2. It wrote research_run_id into commerce_signals.source_run_id, but that
--     column has a FK to discovery_runs — a research run id would violate it.
--     (No violation actually occurred only because (1) matched 0 rows.)
--
-- The real evidence WAS ingested; only the provenance link failed. Fix: snapshot
-- existing signal ids before the receiver call and tag exactly the new rows, and
-- record the research linkage in the provenance jsonb ONLY (never source_run_id).
--
-- Plus a one-time backfill of the real eBay 013J run (04f2933a…, e453eed4…, GB)
-- executed before this fix — provenance-only, today's GB MARKETPLACE rows, never
-- legacy rows.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_research_ingest_source(p_run_id uuid, p_source text, p_raw jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_att public.commerce_research_source_attempt%rowtype;
  v_src text := upper(btrim(coalesce(p_source,'')));
  v_cat text; v_res jsonb; v_found boolean := false; v_failed boolean := false;
  v_existing uuid[]; v_state text; v_note text; v_tagged int := 0; v_mkt_ebay text;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;
  v_cat := CASE v_src
    WHEN 'EBAY' THEN 'MARKETPLACE' WHEN 'META' THEN 'ADVERTISING' WHEN 'META_AD_LIBRARY' THEN 'ADVERTISING'
    WHEN 'DATAFORSEO' THEN 'SEARCH_DEMAND' WHEN 'CJ' THEN 'SUPPLIER' WHEN 'REDDIT' THEN 'COMMUNITY' ELSE NULL END;
  IF v_cat IS NULL THEN RETURN jsonb_build_object('status','UNKNOWN_SOURCE','source',v_src); END IF;
  SELECT * INTO v_att FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND evidence_category=v_cat ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NO_ATTEMPT_FOR_CATEGORY','category',v_cat); END IF;

  UPDATE public.commerce_research_source_attempt SET state='SEARCHING', observed_at=now() WHERE id=v_att.id;
  -- snapshot existing signal ids so we tag EXACTLY the rows this receiver call inserts
  SELECT array_agg(id) INTO v_existing FROM public.commerce_signals WHERE product_id=v_run.product_id;

  BEGIN
    IF v_src='EBAY' THEN
      v_mkt_ebay := 'EBAY_'||v_run.market;
      v_res := public.fn_ingest_ebay_listings(v_run.product_id, v_mkt_ebay, p_raw, false);
      v_found := (v_res->>'marketplace_activity_state') = 'OBSERVED';
      v_failed := (v_res->>'status') IN ('not_item_array','product_not_found');
    ELSIF v_src IN ('META','META_AD_LIBRARY') THEN
      v_res := public.fn_ingest_meta_ads(v_run.product_id, v_run.market, p_raw, false);
      v_found := (v_res->>'advertising_activity_state') = 'OBSERVED';
      v_failed := (v_res->>'status') IN ('not_ad_array','product_not_found');
    ELSIF v_src='DATAFORSEO' THEN
      v_res := public.fn_ingest_search_demand_for_product(v_run.product_id, v_run.market, 'DATAFORSEO', p_raw, false);
      v_found := (v_res->>'status') = 'ok';
      v_failed := (v_res->>'status') IN ('not_keyword_array','product_not_found');
    ELSIF v_src='CJ' THEN
      v_res := public.ingest_cj_supplier_products(p_raw);
      v_found := coalesce((v_res->>'ingested')::int,0) > 0 OR coalesce((v_res->>'upserted')::int,0) > 0;
      v_failed := false;
    ELSIF v_src='REDDIT' THEN
      v_res := jsonb_build_object('status','sweep_source','note','COMMUNITY is a cross-market sweep, not a per-request fetch');
      v_found := false;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.commerce_research_source_attempt
      SET state='SOURCE_FAILED', observed_at=now(), note=left('receiver error: '||SQLERRM,480),
          evidence_ref=jsonb_build_object('error','receiver_exception') WHERE id=v_att.id;
    RETURN jsonb_build_object('status','SOURCE_FAILED','source',v_src,'category',v_cat,'error','receiver_exception');
  END;

  -- provenance linkage (jsonb ONLY; source_run_id is FK'd to discovery_runs and left untouched):
  -- tag exactly the rows this call inserted (ids not present before the receiver ran).
  UPDATE public.commerce_signals
    SET provenance = coalesce(provenance,'{}'::jsonb)
          || jsonb_build_object('research_run_id',p_run_id,'source_attempt_id',v_att.id,'research_market',v_run.market)
    WHERE product_id = v_run.product_id
      AND (provenance->>'research_run_id') IS NULL
      AND (v_existing IS NULL OR id <> ALL(v_existing));
  GET DIAGNOSTICS v_tagged = ROW_COUNT;

  IF v_failed THEN v_state:='SOURCE_FAILED'; v_note:='provider/credential operational issue; evidence unchanged, never zeroed';
  ELSIF v_found THEN v_state:='SEARCHED_EVIDENCE_FOUND'; v_note:='canonical evidence accepted';
  ELSE v_state:='SEARCHED_NO_EVIDENCE'; v_note:='legitimate search returned no product-relevant evidence'; END IF;

  UPDATE public.commerce_research_source_attempt
    SET state=v_state, observed_at=now(), note=v_note,
        evidence_ref=jsonb_build_object('rows_tagged',v_tagged,'receiver_status',v_res->>'status',
          'marketplace_activity_state',v_res->>'marketplace_activity_state',
          'advertising_activity_state',v_res->>'advertising_activity_state','buyer_intent_band',v_res->>'buyer_intent_band')
    WHERE id=v_att.id;

  RETURN jsonb_build_object('status','ok','source',v_src,'category',v_cat,'attempt_state',v_state,
    'rows_tagged',v_tagged,'receiver',v_res,'contract','pulse_research_ingest_v1_013j');
END; $function$;

-- one-time provenance backfill for the real eBay run executed before the fix.
DO $backfill$
DECLARE
  v_run uuid := '04f2933a-fb19-4430-9176-2ce3d438d3ce';
  v_prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_att uuid;
BEGIN
  SELECT id INTO v_att FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='MARKETPLACE' LIMIT 1;
  IF v_att IS NOT NULL THEN
    UPDATE public.commerce_signals
      SET provenance = coalesce(provenance,'{}'::jsonb)
            || jsonb_build_object('research_run_id',v_run,'source_attempt_id',v_att,'research_market','GB',
                                  'provenance_backfilled','mig_244')
      WHERE product_id=v_prod AND signal_type='MARKETPLACE_ACTIVITY'
        AND value->>'market'='GB' AND (provenance->>'research_run_id') IS NULL
        AND created_at::date = current_date;
  END IF;
END; $backfill$;

-- ============================================================================
-- mig_333_research_ingest_self_finalize.sql
-- LAUNCH-CRITICAL: since the TikTok AVAILABLE flip (2026-09-21) seeded
-- SOCIAL_VIDEO as NOT_SEARCHED, and nothing (no cron, no trigger, no finalize
-- workflow) re-invokes finalization after the executor ingests the last
-- provider, EVERY run created since then is stuck in RESEARCHING. Making
-- fn_research_ingest_source call fn_research_maybe_finalize at the end makes the
-- pipeline self-finalizing: the run finalizes the instant its last attempt
-- reaches a terminal state, regardless of provider order or external triggers.
-- fn_research_maybe_finalize is idempotent (advisory xact lock + ALREADY_FINAL
-- guard) so concurrent provider ingests are safe. Only the finalize call is
-- added; all existing ingest/normalization/terminal-state logic is unchanged.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_research_ingest_source(
  p_run_id uuid, p_source text, p_raw jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_att public.commerce_research_source_attempt%rowtype;
  v_src text := upper(btrim(coalesce(p_source,'')));
  v_cat text; v_res jsonb; v_found boolean := false; v_failed boolean := false;
  v_t0 timestamptz; v_state text; v_note text; v_tagged int := 0; v_mkt_ebay text;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;

  v_cat := CASE v_src
    WHEN 'EBAY' THEN 'MARKETPLACE' WHEN 'META' THEN 'ADVERTISING' WHEN 'META_AD_LIBRARY' THEN 'ADVERTISING'
    WHEN 'DATAFORSEO' THEN 'SEARCH_DEMAND' WHEN 'CJ' THEN 'SUPPLIER' WHEN 'REDDIT' THEN 'COMMUNITY'
    WHEN 'TIKTOK' THEN 'SOCIAL_VIDEO'
    ELSE NULL END;
  IF v_cat IS NULL THEN RETURN jsonb_build_object('status','UNKNOWN_SOURCE','source',v_src); END IF;

  SELECT * INTO v_att FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND evidence_category=v_cat ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NO_ATTEMPT_FOR_CATEGORY','category',v_cat); END IF;

  UPDATE public.commerce_research_source_attempt SET state='SEARCHING', observed_at=now() WHERE id=v_att.id;
  v_t0 := clock_timestamp();

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
    ELSIF v_src='TIKTOK' THEN
      v_res := public.fn_ingest_tiktok_commercial_content(v_run.product_id, v_run.market, p_raw, false);
      v_found := (v_res->>'advertising_activity_state') = 'OBSERVED';
      v_failed := (v_res->>'status') IN ('not_ad_array','product_not_found');
    ELSIF v_src='REDDIT' THEN
      v_res := jsonb_build_object('status','sweep_source','note','COMMUNITY is a cross-market sweep, not a per-request fetch');
      v_found := false;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.commerce_research_source_attempt
      SET state='SOURCE_FAILED', observed_at=now(), note=left('receiver error: '||SQLERRM,480),
          evidence_ref=jsonb_build_object('error','receiver_exception')
      WHERE id=v_att.id;
    PERFORM public.fn_research_maybe_finalize(p_run_id);
    RETURN jsonb_build_object('status','SOURCE_FAILED','source',v_src,'category',v_cat,'error','receiver_exception');
  END;

  UPDATE public.commerce_signals
    SET source_run_id = p_run_id,
        provenance = coalesce(provenance,'{}'::jsonb)
          || jsonb_build_object('research_run_id',p_run_id,'source_attempt_id',v_att.id,'research_market',v_run.market)
    WHERE product_id = v_run.product_id AND created_at >= v_t0 AND source_run_id IS NULL;
  GET DIAGNOSTICS v_tagged = ROW_COUNT;

  IF v_failed THEN v_state:='SOURCE_FAILED'; v_note:='provider/credential operational issue; evidence unchanged, never zeroed';
  ELSIF v_found THEN v_state:='SEARCHED_EVIDENCE_FOUND'; v_note:='canonical evidence accepted';
  ELSE v_state:='SEARCHED_NO_EVIDENCE'; v_note:='legitimate search returned no product-relevant evidence';
  END IF;

  UPDATE public.commerce_research_source_attempt
    SET state=v_state, observed_at=now(), note=v_note,
        evidence_ref=jsonb_build_object('rows_tagged',v_tagged,
          'receiver_status',v_res->>'status',
          'marketplace_activity_state',v_res->>'marketplace_activity_state',
          'advertising_activity_state',v_res->>'advertising_activity_state',
          'buyer_intent_band',v_res->>'buyer_intent_band')
    WHERE id=v_att.id;

  -- Self-finalize: finalize the run as soon as its last attempt is terminal.
  -- Idempotent (advisory xact lock + ALREADY_FINAL guard); safe under concurrent
  -- provider ingests. Prevents runs from stalling in RESEARCHING.
  PERFORM public.fn_research_maybe_finalize(p_run_id);

  RETURN jsonb_build_object('status','ok','source',v_src,'category',v_cat,'attempt_state',v_state,
    'rows_tagged',v_tagged,'receiver',v_res,'contract','pulse_research_ingest_v1_013j_selffinalize');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_research_ingest_source(uuid,text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_ingest_source(uuid,text,jsonb) TO service_role;

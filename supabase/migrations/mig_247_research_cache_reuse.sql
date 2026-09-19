-- ============================================================================
-- mig_247_research_cache_reuse.sql
-- STRATELOQ-COMPLETE-AVAILABLE-MULTI-SOURCE-RESEARCH-013K
--
-- Cache-reuse for a research source attempt: mark a source's attempt terminal by
-- reusing existing sufficiently-fresh canonical evidence, WITHOUT re-fetching or
-- re-tagging. Used for COMMUNITY (Reddit) — a cross-market sweep source whose
-- evidence is not market-specific — and available for MARKETPLACE reuse per the
-- 013K freshness rule. Records truthful cache-reuse provenance and preserves the
-- cross-market limitation for community evidence (never treated as GB-verified
-- demand). service_role only. Additive; no data mutation of evidence rows.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_research_reuse_source(
  p_run_id uuid, p_source text, p_freshness_hours integer DEFAULT 336)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_att public.commerce_research_source_attempt%rowtype;
  v_src text := upper(btrim(coalesce(p_source,'')));
  v_cat text; v_sigtype text; v_market_scoped boolean; v_cross_market boolean;
  v_count int := 0; v_state text; v_note text; v_latest timestamptz;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;

  v_cat := CASE v_src
    WHEN 'EBAY' THEN 'MARKETPLACE' WHEN 'REDDIT' THEN 'COMMUNITY'
    WHEN 'META' THEN 'ADVERTISING' WHEN 'META_AD_LIBRARY' THEN 'ADVERTISING'
    WHEN 'DATAFORSEO' THEN 'SEARCH_DEMAND' ELSE NULL END;
  IF v_cat IS NULL THEN RETURN jsonb_build_object('status','UNKNOWN_SOURCE','source',v_src); END IF;

  v_sigtype := CASE v_cat WHEN 'MARKETPLACE' THEN 'MARKETPLACE_ACTIVITY'
    WHEN 'COMMUNITY' THEN 'COMMUNITY_ATTENTION' WHEN 'ADVERTISING' THEN 'ADVERTISING_ACTIVITY'
    WHEN 'SEARCH_DEMAND' THEN 'SEARCH_DEMAND' END;
  v_cross_market := (v_cat = 'COMMUNITY');           -- community is cross-market, not GB-verified
  v_market_scoped := NOT v_cross_market;

  SELECT * INTO v_att FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND evidence_category=v_cat ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NO_ATTEMPT_FOR_CATEGORY','category',v_cat); END IF;

  -- count sufficiently-fresh existing evidence for this product (and market when scoped)
  SELECT count(*), max(observed_at) INTO v_count, v_latest
  FROM public.commerce_signals
  WHERE product_id = v_run.product_id
    AND signal_type = v_sigtype
    AND observed_at > now() - make_interval(hours => greatest(1,coalesce(p_freshness_hours,336)))
    AND (NOT v_market_scoped OR value->>'market' = v_run.market);

  IF v_count > 0 THEN
    v_state := 'SEARCHED_EVIDENCE_FOUND';
    v_note := CASE WHEN v_cross_market
      THEN 'CACHE_REUSED cross-market community evidence; NOT GB-verified demand'
      ELSE 'CACHE_REUSED fresh market evidence' END;
  ELSE
    v_state := 'SEARCHED_NO_EVIDENCE';
    v_note := 'no sufficiently fresh reusable evidence';
  END IF;

  UPDATE public.commerce_research_source_attempt
    SET state=v_state, observed_at=now(), note=v_note,
        evidence_ref=jsonb_build_object('reused',true,'reused_count',v_count,
          'evidence_latest_observed_at',v_latest,'cross_market',v_cross_market,
          'freshness_hours',p_freshness_hours)
    WHERE id=v_att.id;

  RETURN jsonb_build_object('status','ok','source',v_src,'category',v_cat,'attempt_state',v_state,
    'reused_count',v_count,'cross_market',v_cross_market,'contract','pulse_research_reuse_v1_013k');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_research_reuse_source(uuid,text,integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_reuse_source(uuid,text,integer) TO service_role;

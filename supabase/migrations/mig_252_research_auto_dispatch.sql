-- ============================================================================
-- mig_252_research_auto_dispatch.sql
-- STRATELOQ-ECOM-DEEP-RESEARCH-AUTO-DISPATCH-013N (close the connection)
--
-- Turns fn_own_request_product_market_research(product_id, market) into a
-- self-completing, zero-manual-intervention deep-research run:
--
--  (1) fn_research_maybe_finalize(run_id) — idempotent completion trigger:
--      once no source attempt remains NOT_SEARCHED/SEARCHING it calls the
--      canonical fn_finalize_research_run (recompute via the real assembler).
--      Serialized per run with a transaction advisory lock so concurrent
--      provider callbacks never both finalize or both skip.
--
--  (2) fn_research_ingest_source — HARDENED + auto-finalizing:
--      only NOT_SEARCHED / SEARCHING / SOURCE_FAILED attempts are (re)processed;
--      terminal states (SEARCHED_*, UNSUPPORTED_MARKET, BLOCKED_EXTERNAL_ACCESS,
--      SOURCE_UNAVAILABLE) are REFUSED unchanged. This is the idempotency +
--      "no duplicate paid work re-ingested" guard for repeated executor fires.
--      After a successful transition it calls fn_research_maybe_finalize.
--
--  (3) fn_research_reuse_source — also calls fn_research_maybe_finalize.
--
--  (4) fn_research_dispatch(run_id) — service-side dispatcher:
--      reuses cross-market COMMUNITY (Reddit) evidence, marks SEARCH_DEMAND
--      SOURCE_UNAVAILABLE where the market has no DataForSEO location code
--      (so the run can still complete truthfully), then fires the canonical
--      n8n provider executor once via pg_net (URL + secret from
--      server_integration_config; never exposed to the browser). TikTok is
--      never called. If nothing is dispatchable it finalizes immediately.
--
--  (5) fn_own_request_product_market_research — after creating a NEW run
--      (never on CACHE_REUSED / CACHE_REUSED_IN_FLIGHT) it now performs
--      fn_research_dispatch(run_id): one authenticated browser request →
--      full server-side multi-source dispatch, with ZERO manual n8n work.
--
-- The executor webhook URL + dispatch secret are inserted into
-- server_integration_config at deploy time (runtime, NOT in this file) so no
-- secret is committed. Additive; no WPS/scoring/cadence change; no new
-- provider/country/orchestrator.
-- ============================================================================

-- (1) idempotent completion trigger -----------------------------------------
CREATE OR REPLACE FUNCTION public.fn_research_maybe_finalize(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_pending int; v_status text; v_completed timestamptz;
BEGIN
  -- serialize the check per run so concurrent provider callbacks can't race
  PERFORM pg_advisory_xact_lock(hashtext(p_run_id::text));
  SELECT status, completed_at INTO v_status, v_completed
    FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;
  -- already finalized -> never recompute again on a late/duplicate callback
  IF v_completed IS NOT NULL AND v_status <> 'RESEARCHING' THEN
    RETURN jsonb_build_object('status','ALREADY_FINAL','run_status',v_status);
  END IF;
  SELECT count(*) FILTER (WHERE state IN ('NOT_SEARCHED','SEARCHING'))
    INTO v_pending FROM public.commerce_research_source_attempt WHERE run_id=p_run_id;
  IF v_pending > 0 THEN
    RETURN jsonb_build_object('status','PENDING','pending',v_pending);
  END IF;
  RETURN public.fn_finalize_research_run(p_run_id);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_research_maybe_finalize(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_maybe_finalize(uuid) TO service_role;

-- (2) hardened + auto-finalizing ingest -------------------------------------
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

  -- GUARD: only (re)process dispatchable/retryable attempts. Terminal states
  -- (SEARCHED_EVIDENCE_FOUND / SEARCHED_NO_EVIDENCE / UNSUPPORTED_MARKET /
  -- BLOCKED_EXTERNAL_ACCESS / SOURCE_UNAVAILABLE) are refused unchanged so a
  -- duplicate/late executor callback cannot re-ingest or overwrite evidence.
  IF v_att.state NOT IN ('NOT_SEARCHED','SEARCHING','SOURCE_FAILED') THEN
    RETURN jsonb_build_object('status','REFUSED_TERMINAL_STATE','source',v_src,
      'category',v_cat,'attempt_state',v_att.state,
      'note','attempt already terminal; not overwritten (idempotent)');
  END IF;

  UPDATE public.commerce_research_source_attempt SET state='SEARCHING', observed_at=now() WHERE id=v_att.id;
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
    -- a failed source is a terminal-for-this-attempt outcome; run may still complete
    PERFORM public.fn_research_maybe_finalize(p_run_id);
    RETURN jsonb_build_object('status','SOURCE_FAILED','source',v_src,'category',v_cat,'error','receiver_exception');
  END;

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

  -- auto-complete the run when this was the last outstanding source (isolated:
  -- a finalize error must never lose the accepted evidence/attempt transition)
  BEGIN
    PERFORM public.fn_research_maybe_finalize(p_run_id);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('status','ok','source',v_src,'category',v_cat,'attempt_state',v_state,
    'rows_tagged',v_tagged,'receiver',v_res,'contract','pulse_research_ingest_v2_013n');
END; $function$;

-- (3) reuse now auto-finalizes too ------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_research_reuse_source(p_run_id uuid, p_source text, p_freshness_hours integer DEFAULT 336)
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
  v_cross_market := (v_cat = 'COMMUNITY');
  v_market_scoped := NOT v_cross_market;
  SELECT * INTO v_att FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND evidence_category=v_cat ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NO_ATTEMPT_FOR_CATEGORY','category',v_cat); END IF;
  -- do not overwrite an attempt already resolved to a terminal state
  IF v_att.state NOT IN ('NOT_SEARCHED','SEARCHING','SOURCE_FAILED') THEN
    RETURN jsonb_build_object('status','REFUSED_TERMINAL_STATE','category',v_cat,'attempt_state',v_att.state);
  END IF;
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
  BEGIN
    PERFORM public.fn_research_maybe_finalize(p_run_id);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RETURN jsonb_build_object('status','ok','source',v_src,'category',v_cat,'attempt_state',v_state,
    'reused_count',v_count,'cross_market',v_cross_market,'contract','pulse_research_reuse_v2_013n');
END; $function$;

-- (4) server-side dispatcher -------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_research_dispatch(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_url text; v_secret text; v_loc int; v_req bigint; v_reddit jsonb; v_dispatchable int;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;

  -- COMMUNITY (Reddit) is a cross-market sweep -> reuse synchronously, never fetched here
  v_reddit := public.fn_research_reuse_source(p_run_id,'REDDIT',720);

  -- markets without a configured DataForSEO location code cannot run SEARCH_DEMAND;
  -- record it truthfully so the run can still finalize (never a silent skip)
  SELECT dataforseo_location_code INTO v_loc FROM public.ecommerce_market_universe WHERE country_code=v_run.market;
  IF v_loc IS NULL THEN
    UPDATE public.commerce_research_source_attempt
      SET state='SOURCE_UNAVAILABLE', observed_at=now(),
          note='DataForSEO location code not configured for market; search-demand not run'
      WHERE run_id=p_run_id AND evidence_category='SEARCH_DEMAND' AND state IN ('NOT_SEARCHED','SEARCHING');
  END IF;

  SELECT count(*) INTO v_dispatchable FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND state IN ('NOT_SEARCHED','SEARCHING')
      AND evidence_category IN ('MARKETPLACE','ADVERTISING','SEARCH_DEMAND','SUPPLIER');

  SELECT url, secret INTO v_url, v_secret FROM public.server_integration_config
    WHERE key='research_executor_webhook';

  IF v_dispatchable = 0 THEN
    PERFORM public.fn_research_maybe_finalize(p_run_id);
    RETURN jsonb_build_object('status','NOTHING_TO_DISPATCH','run_id',p_run_id,'reddit',v_reddit);
  END IF;

  IF v_url IS NULL OR btrim(v_url)='' THEN
    RETURN jsonb_build_object('status','NO_WEBHOOK_CONFIGURED','run_id',p_run_id,
      'dispatchable',v_dispatchable,'reddit',v_reddit,
      'note','server_integration_config.research_executor_webhook not set; providers not fired');
  END IF;

  -- self-test / CI guard: a transaction-scoped GUC suppresses the real webhook
  -- fire so regression selftests never trigger live paid provider calls.
  IF coalesce(current_setting('pulse.suppress_dispatch', true),'') = 'on' THEN
    RETURN jsonb_build_object('status','DISPATCH_SUPPRESSED','run_id',p_run_id,
      'dispatchable',v_dispatchable,'reddit',v_reddit,
      'note','pulse.suppress_dispatch=on; no webhook fired, no paid provider calls');
  END IF;

  -- fire the canonical n8n provider executor once (async, after commit).
  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('run_id', p_run_id),
    params := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type','application/json','x-pulse-secret', v_secret),
    timeout_milliseconds := 8000
  ) INTO v_req;

  RETURN jsonb_build_object('status','DISPATCHED','run_id',p_run_id,'net_request_id',v_req,
    'dispatchable',v_dispatchable,'dataforseo_location_code',v_loc,'reddit',v_reddit,
    'contract','pulse_research_dispatch_v1_013n');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_research_dispatch(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_dispatch(uuid) TO service_role;

-- (5) request contract now auto-dispatches a new run ------------------------
CREATE OR REPLACE FUNCTION public.fn_own_request_product_market_research(
  p_product_id uuid, p_market text, p_freshness_hours integer DEFAULT 168)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_prod public.commerce_products%rowtype;
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_ccy text; v_run_id uuid; v_fresh record; v_inflight record;
  v_query text; v_supplier uuid;
  v_expected int := 0; v_manifest jsonb := '[]'::jsonb; v_dispatch jsonb;
  cat record;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication required' USING errcode='28000'; END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PRODUCT_NOT_FOUND'); END IF;
  IF v_prod.user_id <> v_uid THEN RAISE EXCEPTION 'not authorized for this product' USING errcode='42501'; END IF;

  SELECT default_currency INTO v_ccy FROM public.ecommerce_market_universe
    WHERE country_code = v_mkt AND coalesce(ecommerce_eligible,true) LIMIT 1;
  IF v_ccy IS NULL THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','market',v_mkt,
      'note','market not present / not ecommerce-eligible in ecommerce_market_universe');
  END IF;

  IF coalesce(p_freshness_hours,168) > 0 THEN
    SELECT * INTO v_fresh FROM public.commerce_research_run
      WHERE tenant_id=v_uid AND product_id=p_product_id AND market=v_mkt
        AND status IN ('COMPLETE','PARTIAL','PARTIAL_SOURCE_FAILURE','PARTIAL_SOURCE_UNAVAILABLE')
        AND completed_at IS NOT NULL
        AND completed_at > now() - make_interval(hours => p_freshness_hours)
      ORDER BY completed_at DESC LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('status','CACHE_REUSED','run_id',v_fresh.id,'market',v_mkt,
        'reused_completed_at',v_fresh.completed_at,'freshness_hours',p_freshness_hours,
        'note','fresh completed run reused; no new provider dispatch, no paid calls');
    END IF;
    SELECT * INTO v_inflight FROM public.commerce_research_run
      WHERE tenant_id=v_uid AND product_id=p_product_id AND market=v_mkt
        AND status='RESEARCHING' AND started_at > now() - interval '1 hour'
      ORDER BY started_at DESC LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('status','CACHE_REUSED_IN_FLIGHT','run_id',v_inflight.id,'market',v_mkt,
        'started_at',v_inflight.started_at,'note','a research run for this product+market is already in progress; not duplicated, not re-dispatched');
    END IF;
  END IF;

  SELECT (m.value->>'price_query') AS pq, r.supplier_id AS sup INTO v_query, v_supplier
  FROM public.monday_opportunity_registry r
       CROSS JOIN LATERAL jsonb_array_elements(r.markets) m
  WHERE r.product_id = p_product_id AND (m.value->>'country') = v_mkt LIMIT 1;
  v_query := coalesce(v_query, v_prod.title);

  v_run_id := gen_random_uuid();
  INSERT INTO public.commerce_research_run
    (id, tenant_id, product_id, market, status, sources_expected, started_at, freshness_at, provenance)
  VALUES (v_run_id, v_uid, p_product_id, v_mkt, 'RESEARCHING', 0, now(), now(),
    jsonb_build_object('trigger','on_demand_user_request','requested_by',v_uid,
      'product_title',v_prod.title,'price_query',v_query,'market_currency',v_ccy,'registry_supplier', v_supplier,
      'snapshot_note','applicable provider/category set snapshotted at request time'));

  FOR cat IN
    WITH cats(evidence_category) AS (
      VALUES ('COMMUNITY'),('SEARCH_DEMAND'),('MARKETPLACE'),('ADVERTISING'),('SUPPLIER'),('SOCIAL_VIDEO')
    ),
    ranked AS (
      SELECT c.evidence_category, r.source, r.availability, r.market,
             row_number() OVER (PARTITION BY c.evidence_category ORDER BY
                 (r.availability='AVAILABLE' AND r.market=v_mkt) DESC,
                 (r.availability='AVAILABLE' AND r.market='*')   DESC,
                 (r.availability='AVAILABLE')                    DESC,
                 (r.market=v_mkt)                                DESC,
                 (r.market='*')                                  DESC) AS rnk
      FROM cats c JOIN public.provider_capability_registry r USING (evidence_category)
    )
    SELECT evidence_category, source, availability, market FROM ranked WHERE rnk=1
  LOOP
    DECLARE v_state text; v_note text;
    BEGIN
      IF cat.availability = 'AVAILABLE' THEN v_state := 'NOT_SEARCHED'; v_note := 'applicable; awaiting provider dispatch';
      ELSIF cat.availability = 'SOURCE_UNSUPPORTED' AND cat.evidence_category='SOCIAL_VIDEO' THEN v_state := 'BLOCKED_EXTERNAL_ACCESS'; v_note := 'EXTERNAL_PROVIDER_REQUIRED';
      ELSIF cat.availability = 'SOURCE_UNSUPPORTED' THEN v_state := 'UNSUPPORTED_MARKET'; v_note := 'provider not available for selected market';
      ELSIF cat.availability = 'SOURCE_BLOCKED' THEN v_state := 'SOURCE_UNAVAILABLE'; v_note := 'provider access blocked';
      ELSE v_state := 'SOURCE_UNAVAILABLE'; v_note := coalesce(cat.availability,'UNKNOWN'); END IF;
      INSERT INTO public.commerce_research_source_attempt
        (id, run_id, evidence_category, source, state, note, created_at)
      VALUES (gen_random_uuid(), v_run_id, cat.evidence_category, cat.source, v_state, v_note, now());
      v_expected := v_expected + 1;
      v_manifest := v_manifest || jsonb_build_array(jsonb_build_object(
        'evidence_category', cat.evidence_category, 'source', cat.source, 'state', v_state,
        'dispatchable', (v_state='NOT_SEARCHED'),
        'query', CASE WHEN v_state='NOT_SEARCHED' THEN v_query ELSE NULL END,
        'market', v_mkt, 'note', v_note));
    END;
  END LOOP;

  UPDATE public.commerce_research_run SET sources_expected=v_expected, updated_at=now() WHERE id=v_run_id;

  -- CLOSE THE CONNECTION: automatically dispatch all applicable providers
  -- server-side (Reddit reuse + n8n executor via pg_net). Zero manual work.
  v_dispatch := public.fn_research_dispatch(v_run_id);

  RETURN jsonb_build_object('status','RESEARCHING','run_id',v_run_id,
    'product_id',p_product_id,'product_title',v_prod.title,'market',v_mkt,'market_currency',v_ccy,
    'price_query',v_query,'sources_expected',v_expected,'dispatch_manifest',v_manifest,
    'auto_dispatch',v_dispatch->>'status','dispatch',v_dispatch,
    'tiktok','BLOCKED_EXTERNAL_ACCESS','contract','pulse_research_request_v2_013n');
END; $function$;

-- (6) orchestrator selftest now suppresses real dispatch -------------------
-- fn_own_request auto-dispatches; the selftest must never fire a live webhook
-- or incur paid provider calls, so it sets the transaction-scoped guard.
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
  PERFORM set_config('pulse.suppress_dispatch','on', true);  -- no live webhook / paid calls in selftest
  v_req := public.fn_own_request_product_market_research(v_prod, 'GB', 0);
  v_run := nullif(v_req->>'run_id','')::uuid;
  SELECT count(*) INTO n_att FROM public.commerce_research_source_attempt WHERE run_id=v_run;
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','request_creates_6_attempts','pass',(v_req->>'status'='RESEARCHING' AND n_att=6),'attempts',n_att));
  v_pass := v_pass AND (v_req->>'status'='RESEARCHING' AND n_att=6);
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','auto_dispatch_suppressed_in_selftest','pass',(v_req->>'auto_dispatch'='DISPATCH_SUPPRESSED'),'auto_dispatch',v_req->>'auto_dispatch'));
  v_pass := v_pass AND (v_req->>'auto_dispatch'='DISPATCH_SUPPRESSED');
  SELECT count(*) INTO n_tiktok FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='SOCIAL_VIDEO' AND state='BLOCKED_EXTERNAL_ACCESS' AND source='TIKTOK';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','tiktok_blocked','pass',(n_tiktok=1)));
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
    v_res := v_res || jsonb_build_array(jsonb_build_object('case','finalize_partial_with_gap',
      'pass',(v_fin->>'status'='PARTIAL' AND (v_fin->>'launch_critical_gap')::boolean=true),
      'status',v_fin->>'status','gap',v_fin->>'launch_critical_gap'));
    v_pass := v_pass AND (v_fin->>'status'='PARTIAL' AND (v_fin->>'launch_critical_gap')::boolean=true);
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

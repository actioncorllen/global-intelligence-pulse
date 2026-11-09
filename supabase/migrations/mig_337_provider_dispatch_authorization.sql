-- mig_337 — Provider-dispatch authorization gate (PREPARED; NOT deployed without founder approval)
-- 2026-11-09
-- Depends on mig_336 (uses fn_dispatch_suppressed). Apply order: mig_336 -> mig_337.
--
-- Closes the provider-dispatch authorization gap found in the release gate: the n8n research
-- executor ("Pulse — Research Auto-Dispatch Executor 013N") calls eBay / Meta / DataForSEO / CJ /
-- TikTok directly with its own n8n credentials, acting ONLY on sources the manifest marks DISPATCH.
-- Previously only DataForSEO was gated (USD reserve); CJ/eBay/Meta/TikTok were dispatched with no
-- authorization. This makes EVERY external provider operation require explicit, tenant+provider+
-- market-scoped authorization, consumed atomically, fail-closed — so an unauthorized source is
-- marked SOURCE_UNAVAILABLE before the webhook fires and the executor never calls it (no n8n bypass).
--
-- Usage authorization is separate from monetary charging:
--   * DataForSEO  -> monetary (USD) authorization via fn_research_budget_reserve (unchanged).
--   * CJ/eBay/Meta/TikTok -> USAGE/operation authorization via an active provider_call_budget
--     (tenant+provider+market, max_calls = operation limit), consumed atomically. No per-call USD is
--     assumed or invented here; CJ catalogue reads and eBay/Meta/TikTok queries carry no money in
--     this path — the budget is an operation grant, not a charge.
-- Run-scoped suppression (mig_336) is kept as DEFENSE-IN-DEPTH, not the sole barrier: even with
-- suppression missing/expired, an unauthorized provider cannot be dispatched.

-- Market-scoped, provider-scoped, tenant-scoped, atomic, fail-closed authorization consume.
-- Consumes one operation from an active provider_call_budget matching (provider, tenant, market or
-- market-agnostic). Does NOT reuse fn_provider_budget_try_consume because that ignores market and
-- treats non-metered providers as permitted-but-unenforced; this gate is always fail-closed and
-- market-aware. max_calls is an OPERATION limit (usage), not a monetary charge.
CREATE OR REPLACE FUNCTION public.fn_dispatch_provider_authorize(p_provider text, p_tenant uuid, p_market text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_prov text := upper(btrim(coalesce(p_provider,'')));
  v_mkt  text := upper(btrim(coalesce(p_market,'')));
  v_id uuid; v_rem int; v_active boolean;
BEGIN
  IF v_prov='' OR p_tenant IS NULL THEN
    RETURN jsonb_build_object('authorized',false,'reason','missing_args');
  END IF;
  UPDATE public.provider_call_budget b
     SET consumed_calls = b.consumed_calls + 1, last_consumed_at = now()
   WHERE b.id = (
     SELECT id FROM public.provider_call_budget
      WHERE provider=v_prov AND user_id=p_tenant AND active
        AND (expires_at IS NULL OR expires_at > now())
        AND (market IS NULL OR upper(market)=v_mkt)
        AND consumed_calls < max_calls
      ORDER BY created_at DESC LIMIT 1
      FOR UPDATE)
  RETURNING b.id, (b.max_calls - b.consumed_calls) INTO v_id, v_rem;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('authorized',true,'enforced',true,'budget_id',v_id,'remaining',v_rem,'market',v_mkt);
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.provider_call_budget
     WHERE provider=v_prov AND user_id=p_tenant AND active AND (expires_at IS NULL OR expires_at > now())
       AND (market IS NULL OR upper(market)=v_mkt)) INTO v_active;
  RETURN jsonb_build_object('authorized',false,'enforced',true,'market',v_mkt,
    'reason', CASE WHEN v_active THEN 'budget_exceeded' ELSE 'no_budget_fail_closed' END);
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_research_dispatch(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_url text; v_secret text; v_loc int; v_req bigint; v_reddit jsonb; v_dispatchable int;
  v_dfs_pending boolean := false; v_reserve jsonb := NULL;
  a record; v_prov text; v_consume jsonb; v_authz jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;

  v_reddit := public.fn_research_reuse_source(p_run_id,'REDDIT',720);

  -- DataForSEO: monetary (USD) authorization — unchanged, fail-closed.
  SELECT dataforseo_location_code INTO v_loc FROM public.ecommerce_market_universe WHERE country_code=v_run.market;
  IF v_loc IS NULL THEN
    UPDATE public.commerce_research_source_attempt
      SET state='SOURCE_UNAVAILABLE', observed_at=now(),
          note='DataForSEO location code not configured for market; search-demand not run'
      WHERE run_id=p_run_id AND evidence_category='SEARCH_DEMAND' AND state IN ('NOT_SEARCHED','SEARCHING');
  END IF;
  IF v_loc IS NOT NULL THEN
    SELECT EXISTS(SELECT 1 FROM public.commerce_research_source_attempt
      WHERE run_id=p_run_id AND evidence_category='SEARCH_DEMAND' AND source='DATAFORSEO'
        AND state IN ('NOT_SEARCHED','SEARCHING')) INTO v_dfs_pending;
    IF v_dfs_pending THEN
      v_reserve := public.fn_research_budget_reserve(p_run_id, 'DATAFORSEO', v_run.product_id, v_run.market);
      IF coalesce((v_reserve->>'ok')::boolean,false) IS NOT TRUE THEN
        UPDATE public.commerce_research_source_attempt
          SET state='SOURCE_UNAVAILABLE', observed_at=now(),
              note=left('USD budget guard: '||coalesce(v_reserve->>'reason','refused')
                        ||'; paid DataForSEO search-demand skipped (fail-closed)',480)
          WHERE run_id=p_run_id AND evidence_category='SEARCH_DEMAND' AND source='DATAFORSEO'
            AND state IN ('NOT_SEARCHED','SEARCHING');
      END IF;
    END IF;
  END IF;

  -- mig_337: usage authorization (fail-closed, atomic) for the other external providers.
  -- Authorized ONLY when an active provider_call_budget (tenant+provider+market) grants an
  -- operation AND it is actually consumed (allowed AND enforced). Otherwise the source is marked
  -- SOURCE_UNAVAILABLE -> manifest TERMINAL -> the n8n executor never calls that provider.
  FOR a IN
    SELECT id, source FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND state IN ('NOT_SEARCHED','SEARCHING')
      AND source IN ('CJ','EBAY','META_AD_LIBRARY','TIKTOK')
  LOOP
    v_prov := CASE a.source WHEN 'CJ' THEN 'CJDROPSHIPPING' ELSE a.source END;
    v_consume := public.fn_dispatch_provider_authorize(v_prov, v_run.tenant_id, v_run.market);
    IF NOT coalesce((v_consume->>'authorized')::boolean,false) THEN
      UPDATE public.commerce_research_source_attempt
        SET state='SOURCE_UNAVAILABLE', observed_at=now(),
            note=left('usage authorization required: provider '||v_prov||' not authorized for this tenant/market ('
                      ||coalesce(v_consume->>'reason','no_budget')||'); fail-closed, no external call', 480)
        WHERE id=a.id;
      v_authz := v_authz || jsonb_build_array(jsonb_build_object(
        'source',a.source,'provider',v_prov,'authorized',false,'reason',coalesce(v_consume->>'reason','no_budget')));
    ELSE
      v_authz := v_authz || jsonb_build_array(jsonb_build_object(
        'source',a.source,'provider',v_prov,'authorized',true,'remaining',v_consume->>'remaining'));
    END IF;
  END LOOP;

  SELECT count(*) INTO v_dispatchable FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND state IN ('NOT_SEARCHED','SEARCHING')
      AND evidence_category IN ('MARKETPLACE','ADVERTISING','SEARCH_DEMAND','SUPPLIER','SOCIAL_VIDEO');

  SELECT url, secret INTO v_url, v_secret FROM public.server_integration_config
    WHERE key='research_executor_webhook';

  IF v_dispatchable = 0 THEN
    PERFORM public.fn_research_maybe_finalize(p_run_id);
    RETURN jsonb_build_object('status','NOTHING_TO_DISPATCH','run_id',p_run_id,'reddit',v_reddit,
      'dataforseo_budget',v_reserve,'authorization',v_authz);
  END IF;

  IF v_url IS NULL OR btrim(v_url)='' THEN
    RETURN jsonb_build_object('status','NO_WEBHOOK_CONFIGURED','run_id',p_run_id,
      'dispatchable',v_dispatchable,'reddit',v_reddit,'dataforseo_budget',v_reserve,'authorization',v_authz,
      'note','server_integration_config.research_executor_webhook not set; providers not fired');
  END IF;

  -- Defense-in-depth: run-scoped suppression (mig_336). NOT the sole authorization barrier — the
  -- per-provider gate above already fail-closes unauthorized providers.
  IF coalesce(current_setting('pulse.suppress_dispatch', true),'') = 'on'
     OR public.fn_dispatch_suppressed(v_run.tenant_id) THEN
    RETURN jsonb_build_object('status','DISPATCH_SUPPRESSED','run_id',p_run_id,
      'dispatchable',v_dispatchable,'reddit',v_reddit,'dataforseo_budget',v_reserve,'authorization',v_authz,
      'note','dispatch suppressed (GUC or run-scoped tenant suppression); no webhook fired, no provider calls');
  END IF;

  -- Only AUTHORIZED sources remain NOT_SEARCHED, so the manifest marks only those DISPATCH.
  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('run_id', p_run_id),
    params := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type','application/json','x-pulse-secret', v_secret),
    timeout_milliseconds := 8000
  ) INTO v_req;

  RETURN jsonb_build_object('status','DISPATCHED','run_id',p_run_id,'net_request_id',v_req,
    'dispatchable',v_dispatchable,'dataforseo_location_code',v_loc,'reddit',v_reddit,
    'dataforseo_budget',v_reserve,'authorization',v_authz,
    'contract','pulse_research_dispatch_v4_provider_authz');
END; $function$;

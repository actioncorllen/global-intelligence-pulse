-- ============================================================================
-- mig_332_research_dispatch_include_social_video.sql
-- Fix: since TikTok flipped to AVAILABLE (mig_267, 2026-09-21),
-- fn_own_request_product_market_research seeds SOCIAL_VIDEO as NOT_SEARCHED
-- (dispatchable), but fn_research_dispatch excluded SOCIAL_VIDEO from its
-- dispatchable set and the auto-dispatch executor had no TikTok branch -> the
-- SOCIAL_VIDEO attempt was never serviced, leaving affected runs stuck in
-- RESEARCHING (finalize requires zero NOT_SEARCHED/SEARCHING attempts).
-- The executor now has a TikTok branch (services SOCIAL_VIDEO and always drives
-- it terminal). This adds SOCIAL_VIDEO to the dispatchable category set so the
-- webhook fires while TikTok is pending. Only this one line of intent changes.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_research_dispatch(p_run_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_url text; v_secret text; v_loc int; v_req bigint; v_reddit jsonb; v_dispatchable int;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;

  v_reddit := public.fn_research_reuse_source(p_run_id,'REDDIT',720);

  SELECT dataforseo_location_code INTO v_loc FROM public.ecommerce_market_universe WHERE country_code=v_run.market;
  IF v_loc IS NULL THEN
    UPDATE public.commerce_research_source_attempt
      SET state='SOURCE_UNAVAILABLE', observed_at=now(),
          note='DataForSEO location code not configured for market; search-demand not run'
      WHERE run_id=p_run_id AND evidence_category='SEARCH_DEMAND' AND state IN ('NOT_SEARCHED','SEARCHING');
  END IF;

  SELECT count(*) INTO v_dispatchable FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND state IN ('NOT_SEARCHED','SEARCHING')
      AND evidence_category IN ('MARKETPLACE','ADVERTISING','SEARCH_DEMAND','SUPPLIER','SOCIAL_VIDEO');

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

  IF coalesce(current_setting('pulse.suppress_dispatch', true),'') = 'on' THEN
    RETURN jsonb_build_object('status','DISPATCH_SUPPRESSED','run_id',p_run_id,
      'dispatchable',v_dispatchable,'reddit',v_reddit,
      'note','pulse.suppress_dispatch=on; no webhook fired, no paid provider calls');
  END IF;

  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('run_id', p_run_id),
    params := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type','application/json','x-pulse-secret', v_secret),
    timeout_milliseconds := 8000
  ) INTO v_req;

  RETURN jsonb_build_object('status','DISPATCHED','run_id',p_run_id,'net_request_id',v_req,
    'dispatchable',v_dispatchable,'dataforseo_location_code',v_loc,'reddit',v_reddit,
    'contract','pulse_research_dispatch_v1_013n_socialvideo');
END; $function$;

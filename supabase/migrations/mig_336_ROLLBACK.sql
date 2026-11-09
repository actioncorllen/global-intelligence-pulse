-- mig_336 ROLLBACK — restores pre-mig_336 production state.
-- Run order on rollback: (1) redeploy the kalodata-discovery edge function to its v11 (1-arg
-- request-builder caller) FIRST, then (2) apply this script. (Applying this while the paged edge
-- function is still live would make the edge call a 2-arg function that no longer exists.)
-- Restores original function bodies, then removes mig_336's added objects. No data is touched.

-- 1) Restore the dispatch-path functions to their originals (removes the suppression checks) FIRST,
--    so nothing references fn_dispatch_suppressed before it is dropped.
CREATE OR REPLACE FUNCTION public.fn_auto_dispatch_candidate_research(p_user_id uuid, p_product_id uuid, p_market text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_prod public.commerce_products%rowtype;
  v_registered boolean;
BEGIN
  IF p_user_id IS NULL OR p_product_id IS NULL OR v_mkt='' THEN
    RETURN jsonb_build_object('status','MISSING_ARGS');
  END IF;

  IF coalesce(current_setting('pulse.suppress_dispatch', true),'') = 'on' THEN
    RETURN jsonb_build_object('status','DISPATCH_SUPPRESSED','product_id',p_product_id,'market',v_mkt,
      'note','pulse.suppress_dispatch=on; auto-research not started');
  END IF;

  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PRODUCT_NOT_FOUND'); END IF;
  IF v_prod.user_id <> p_user_id THEN RETURN jsonb_build_object('status','NOT_AUTHORIZED'); END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.monday_opportunity_registry r
    WHERE r.tenant_id = p_user_id AND r.product_id = p_product_id AND r.active
      AND EXISTS (SELECT 1 FROM jsonb_array_elements(r.markets) m WHERE upper(m->>'country') = v_mkt)
  ) INTO v_registered;
  IF NOT v_registered THEN
    RETURN jsonb_build_object('status','NOT_ELIGIBLE','product_id',p_product_id,'market',v_mkt,
      'reason','candidate_not_registered_for_market',
      'note','only discovery-qualified, registered candidates enter deep research');
  END IF;

  RETURN public.fn_research_request_core(p_user_id, p_product_id, v_mkt, 168, 'auto_fresh_discovery');
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_research_dispatch(p_run_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_url text; v_secret text; v_loc int; v_req bigint; v_reddit jsonb; v_dispatchable int;
  v_dfs_pending boolean := false; v_reserve jsonb := NULL;
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

  SELECT count(*) INTO v_dispatchable FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND state IN ('NOT_SEARCHED','SEARCHING')
      AND evidence_category IN ('MARKETPLACE','ADVERTISING','SEARCH_DEMAND','SUPPLIER','SOCIAL_VIDEO');

  SELECT url, secret INTO v_url, v_secret FROM public.server_integration_config
    WHERE key='research_executor_webhook';

  IF v_dispatchable = 0 THEN
    PERFORM public.fn_research_maybe_finalize(p_run_id);
    RETURN jsonb_build_object('status','NOTHING_TO_DISPATCH','run_id',p_run_id,'reddit',v_reddit,
      'dataforseo_budget',v_reserve);
  END IF;

  IF v_url IS NULL OR btrim(v_url)='' THEN
    RETURN jsonb_build_object('status','NO_WEBHOOK_CONFIGURED','run_id',p_run_id,
      'dispatchable',v_dispatchable,'reddit',v_reddit,'dataforseo_budget',v_reserve,
      'note','server_integration_config.research_executor_webhook not set; providers not fired');
  END IF;

  IF coalesce(current_setting('pulse.suppress_dispatch', true),'') = 'on' THEN
    RETURN jsonb_build_object('status','DISPATCH_SUPPRESSED','run_id',p_run_id,
      'dispatchable',v_dispatchable,'reddit',v_reddit,'dataforseo_budget',v_reserve,
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
    'dataforseo_budget',v_reserve,
    'contract','pulse_research_dispatch_v2_013n_usdguard_scoped');
END; $function$;

-- 2) Restore original signatures of the paged functions (drop the paged versions, recreate originals).
DROP FUNCTION IF EXISTS public.fn_kalodata_discovery_request(text, integer);
CREATE OR REPLACE FUNCTION public.fn_kalodata_discovery_request(p_market text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE c record;
BEGIN
  SELECT * INTO c FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=upper(btrim(coalesce(p_market,''))) AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'provider','KALODATA','market',upper(coalesce(p_market,'')),'reason','UNSUPPORTED_MARKET');
  END IF;
  RETURN jsonb_build_object('ok',true,'provider','KALODATA','market',c.market,
    'region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
    'endpoint','POST https://www.kalodata.com/openapi/v1/tiktok/product/rank',
    'auth','secret-key header (backend broker only; never in DB/logs/response)',
    'strategy','early_emerging',
    'request_body', jsonb_build_object('region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
      'date_range','last7Day','sort',jsonb_build_object('field','revenue_growth_rate','type','DESC'),
      'page_size',10,'page_number',1,'launch_date','<30'),
    'note','early/emerging bias: revenue_growth_rate DESC + recent launch; complementary windows can be added. Candidates only; not opportunity.',
    'contract','pulse_kalodata_request_v1');
END; $function$;

DROP FUNCTION IF EXISTS public.fn_kalodata_run_discovery(uuid, text, integer, text, integer);
CREATE OR REPLACE FUNCTION public.fn_kalodata_run_discovery(p_user_id uuid, p_market text, p_candidate_limit integer, p_anon_key text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_token text := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_req bigint;
  v_url text := 'https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/kalodata-discovery';
BEGIN
  IF p_user_id IS NULL OR coalesce(btrim(p_market),'')='' OR coalesce(btrim(p_anon_key),'')='' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args'); END IF;
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market) VALUES (v_token,p_user_id,upper(btrim(p_market)));
  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('market',upper(btrim(p_market)),'user_id',p_user_id,
                               'candidate_limit',greatest(1,least(coalesce(p_candidate_limit,10),25))),
    headers := jsonb_build_object('Content-Type','application/json','apikey',p_anon_key,
                                  'Authorization','Bearer '||p_anon_key,'x-pulse-nonce',v_token),
    timeout_milliseconds := 30000
  ) INTO v_req;
  RETURN jsonb_build_object('ok',true,'request_id',v_req,'market',upper(btrim(p_market)));
END; $function$;

-- 3) Remove mig_336's added helper functions and tables.
DROP FUNCTION IF EXISTS public.fn_kalodata_next_page(uuid, text);
DROP FUNCTION IF EXISTS public.fn_kalodata_advance_page(uuid, text, integer);
DROP FUNCTION IF EXISTS public.fn_dispatch_suppression_open(uuid, integer, text);
DROP FUNCTION IF EXISTS public.fn_dispatch_suppression_close(uuid);
DROP FUNCTION IF EXISTS public.fn_dispatch_suppressed(uuid);
DROP TABLE IF EXISTS public.kalodata_discovery_cursor;
DROP TABLE IF EXISTS public.discovery_dispatch_suppression;

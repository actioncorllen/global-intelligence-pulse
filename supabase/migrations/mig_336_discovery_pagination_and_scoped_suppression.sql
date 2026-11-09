-- mig_336 — Discovery engine corrections (PREPARED; NOT deployed without founder approval)
-- 2026-11-09
--
-- Two narrowly-scoped corrections, no threshold / engine / tier changes:
--   PART 1  Kalodata pagination: future approved runs advance page_number instead of
--           repeatedly buying page 1 (same 10 products). Backward compatible (defaults = page 1).
--   PART 2  Run-scoped, fail-closed downstream-dispatch suppression that REPLACES the
--           temporary shared-webhook parking. Scoped to a single tenant + time-boxed, so it
--           never interrupts other users or workflows and never touches shared config.
--
-- Atomic budget enforcement (fn_provider_budget_try_consume) and the approved credit limits
-- are unchanged. Canonical-identity dedup (ingest_commerce_product) is unchanged.
-- ============================================================================================

-- ===================== PART 1 — KALODATA PAGINATION =========================================

-- 1a) Request builder gains an explicit, bounded page_number (default 1 => identical to today).
--     Drop the old 1-arg signature first so the new default-arg version is unambiguous.
DROP FUNCTION IF EXISTS public.fn_kalodata_discovery_request(text);
CREATE OR REPLACE FUNCTION public.fn_kalodata_discovery_request(p_market text, p_page_number integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c record; v_page int := greatest(1, coalesce(p_page_number,1));
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
    'strategy','early_emerging','page_number',v_page,
    'request_body', jsonb_build_object('region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
      'date_range','last7Day','sort',jsonb_build_object('field','revenue_growth_rate','type','DESC'),
      'page_size',10,'page_number',v_page,'launch_date','<30'),
    'note','early/emerging bias: revenue_growth_rate DESC + recent launch; page_number advances to avoid re-buying the same results. Candidates only; not opportunity.',
    'contract','pulse_kalodata_request_v2_paged');
END; $function$;

-- 1b) Per-tenant+market page cursor so an approved run buys the next unbought page, never a repeat.
CREATE TABLE IF NOT EXISTS public.kalodata_discovery_cursor (
  tenant_id   uuid NOT NULL,
  market      text NOT NULL,
  next_page   integer NOT NULL DEFAULT 1 CHECK (next_page >= 1),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, market)
);
ALTER TABLE public.kalodata_discovery_cursor ENABLE ROW LEVEL SECURITY;
-- No PostgREST policies: this is a server-internal cursor, reached only by SECURITY DEFINER
-- functions. RLS enabled + zero policies = deny-all to anon/authenticated (fail-closed).

CREATE OR REPLACE FUNCTION public.fn_kalodata_next_page(p_user_id uuid, p_market text)
 RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT coalesce((SELECT next_page FROM public.kalodata_discovery_cursor
                    WHERE tenant_id=p_user_id AND market=upper(btrim(coalesce(p_market,'')))), 1);
$function$;

-- Advance the cursor to just past the page that was actually bought (called by the orchestrator
-- after a page is fired). Monotonic: never moves backwards, so a repeat of the same page is a no-op.
CREATE OR REPLACE FUNCTION public.fn_kalodata_advance_page(p_user_id uuid, p_market text, p_fetched_page integer)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_mkt text := upper(btrim(coalesce(p_market,''))); v_next int := greatest(1, coalesce(p_fetched_page,1)) + 1;
BEGIN
  INSERT INTO public.kalodata_discovery_cursor(tenant_id, market, next_page, updated_at)
  VALUES (p_user_id, v_mkt, v_next, now())
  ON CONFLICT (tenant_id, market) DO UPDATE
    SET next_page = greatest(public.kalodata_discovery_cursor.next_page, EXCLUDED.next_page),
        updated_at = now();
  RETURN (SELECT next_page FROM public.kalodata_discovery_cursor WHERE tenant_id=p_user_id AND market=v_mkt);
END; $function$;

-- 1c) Orchestrator threads the page to the edge function and advances the cursor on fire.
--     p_page_number NULL => auto-advance to the next unbought page. Explicit value => that page.
--     Drop the old 4-arg signature first so the new default-arg version is unambiguous.
DROP FUNCTION IF EXISTS public.fn_kalodata_run_discovery(uuid, text, integer, text);
CREATE OR REPLACE FUNCTION public.fn_kalodata_run_discovery(p_user_id uuid, p_market text, p_candidate_limit integer, p_anon_key text, p_page_number integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_token text := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_req bigint; v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_page int;
  v_url text := 'https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/kalodata-discovery';
BEGIN
  IF p_user_id IS NULL OR v_mkt='' OR coalesce(btrim(p_anon_key),'')='' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args'); END IF;
  v_page := greatest(1, coalesce(p_page_number, public.fn_kalodata_next_page(p_user_id, v_mkt)));
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market) VALUES (v_token,p_user_id,v_mkt);
  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('market',v_mkt,'user_id',p_user_id,
                               'candidate_limit',greatest(1,least(coalesce(p_candidate_limit,10),25)),
                               'page_number',v_page),
    headers := jsonb_build_object('Content-Type','application/json','apikey',p_anon_key,
                                  'Authorization','Bearer '||p_anon_key,'x-pulse-nonce',v_token),
    timeout_milliseconds := 30000
  ) INTO v_req;
  -- Advance the cursor to the next unbought page. Monotonic: a later explicit re-fire of the same
  -- page will not move it backwards, so the next AUTO run still never re-buys a page.
  PERFORM public.fn_kalodata_advance_page(p_user_id, v_mkt, v_page);
  RETURN jsonb_build_object('ok',true,'request_id',v_req,'market',v_mkt,'page_number',v_page,
                            'next_page',public.fn_kalodata_next_page(p_user_id, v_mkt));
END; $function$;

-- ===================== PART 2 — RUN-SCOPED FAIL-CLOSED DISPATCH SUPPRESSION ==================
-- Replaces the temporary "blank the shared research_executor_webhook" approach. A per-tenant,
-- time-boxed token suppresses ONLY that tenant's downstream research dispatch. Other tenants and
-- all other workflows are unaffected; the shared webhook config is never mutated.

CREATE TABLE IF NOT EXISTS public.discovery_dispatch_suppression (
  tenant_id   uuid NOT NULL PRIMARY KEY,
  active      boolean NOT NULL DEFAULT true,
  reason      text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL
);
ALTER TABLE public.discovery_dispatch_suppression ENABLE ROW LEVEL SECURITY;
-- RLS enabled + zero policies = deny-all to anon/authenticated; only SECURITY DEFINER functions touch it.

-- Fail-closed check: an active, unexpired row for this tenant => suppress downstream dispatch.
CREATE OR REPLACE FUNCTION public.fn_dispatch_suppressed(p_tenant_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.discovery_dispatch_suppression
                  WHERE tenant_id=p_tenant_id AND active AND expires_at > now());
$function$;

CREATE OR REPLACE FUNCTION public.fn_dispatch_suppression_open(p_tenant_id uuid, p_ttl_minutes integer DEFAULT 15, p_reason text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_exp timestamptz := now() + make_interval(mins => greatest(1, least(coalesce(p_ttl_minutes,15), 120)));
BEGIN
  IF p_tenant_id IS NULL THEN RETURN jsonb_build_object('status','MISSING_ARGS'); END IF;
  INSERT INTO public.discovery_dispatch_suppression(tenant_id, active, reason, created_at, expires_at)
  VALUES (p_tenant_id, true, p_reason, now(), v_exp)
  ON CONFLICT (tenant_id) DO UPDATE SET active=true, reason=EXCLUDED.reason, created_at=now(), expires_at=EXCLUDED.expires_at;
  RETURN jsonb_build_object('status','ok','tenant_id',p_tenant_id,'expires_at',v_exp,'contract','pulse_dispatch_suppression_v1');
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_dispatch_suppression_close(p_tenant_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  UPDATE public.discovery_dispatch_suppression SET active=false WHERE tenant_id=p_tenant_id;
  RETURN jsonb_build_object('status','ok','tenant_id',p_tenant_id);
END; $function$;

-- 2a) Entry gate: auto-research for a candidate is skipped for a suppressed tenant (no inert runs).
CREATE OR REPLACE FUNCTION public.fn_auto_dispatch_candidate_research(p_user_id uuid, p_product_id uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_prod public.commerce_products%rowtype;
  v_registered boolean;
BEGIN
  IF p_user_id IS NULL OR p_product_id IS NULL OR v_mkt='' THEN
    RETURN jsonb_build_object('status','MISSING_ARGS');
  END IF;

  IF coalesce(current_setting('pulse.suppress_dispatch', true),'') = 'on'
     OR public.fn_dispatch_suppressed(p_user_id) THEN
    RETURN jsonb_build_object('status','DISPATCH_SUPPRESSED','product_id',p_product_id,'market',v_mkt,
      'note','dispatch suppressed (session GUC or run-scoped tenant suppression); auto-research not started, no paid provider call');
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

-- 2b) External-call gate: the single place that fires the research-executor webhook now also
--     honours run-scoped tenant suppression (defence in depth for any caller, incl. direct ones).
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

  IF coalesce(current_setting('pulse.suppress_dispatch', true),'') = 'on'
     OR public.fn_dispatch_suppressed(v_run.tenant_id) THEN
    RETURN jsonb_build_object('status','DISPATCH_SUPPRESSED','run_id',p_run_id,
      'dispatchable',v_dispatchable,'reddit',v_reddit,'dataforseo_budget',v_reserve,
      'note','dispatch suppressed (session GUC or run-scoped tenant suppression); no webhook fired, no paid provider calls');
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
    'contract','pulse_research_dispatch_v3_013n_usdguard_scoped_suppress');
END; $function$;

-- Edge function change (prepared separately, NOT deployed):
--   supabase/functions/kalodata-discovery/index.ts reads payload.page_number (default 1, clamp>=1)
--   and passes it to fn_kalodata_discovery_request(p_market, p_page_number). Ingest call unchanged.

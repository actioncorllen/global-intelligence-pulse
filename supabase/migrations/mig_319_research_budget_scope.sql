-- mig_319_research_budget_scope.sql
--
-- STAGE 4A — scope the DataForSEO USD budget authorisation to ONE product+market.
--
-- mig_318 enforces global monthly + per-run USD ceilings but cannot restrict WHICH product/market may
-- spend. The controlled Snowman live test requires authorisation isolated to the target product+market,
-- so this migration adds an optional (authorized_product_id, authorized_market) scope to the budget
-- config and enforces it in the reservation. When the scope is set, a reserve for any other product or
-- market fails CLOSED (scope_mismatch); when the scope is NULL the guard behaves globally as before.
--
-- The reserve now receives the run's product_id + market explicitly from fn_research_dispatch (which
-- already has them), rather than re-querying the run table. Default remains DISABLED + unscoped.
-- Preserves mig_318 semantics (atomic, idempotent, fail-closed, forfeit-no-refund) and everything else.

ALTER TABLE public.research_budget_config
  ADD COLUMN IF NOT EXISTS authorized_product_id uuid,
  ADD COLUMN IF NOT EXISTS authorized_market     text;

-- State now reports the scope
CREATE OR REPLACE FUNCTION public.fn_research_budget_state()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_cfg public.research_budget_config%rowtype; v_month text := to_char(timezone('UTC',now()),'YYYY-MM');
        v_m public.research_spend_month%rowtype;
BEGIN
  SELECT * INTO v_cfg FROM public.research_budget_config WHERE id LIMIT 1;
  SELECT * INTO v_m FROM public.research_spend_month WHERE month=v_month;
  RETURN jsonb_build_object(
    'enabled', coalesce(v_cfg.enabled,false),
    'monthly_cap_micro', coalesce(v_cfg.monthly_cap_micro,0),
    'per_run_cap_micro', coalesce(v_cfg.per_run_cap_micro,0),
    'per_run_worstcase_micro', coalesce(v_cfg.per_run_worstcase_micro,0),
    'authorized_product_id', v_cfg.authorized_product_id,
    'authorized_market', v_cfg.authorized_market,
    'month', v_month,
    'spent_micro', coalesce(v_m.spent_micro,0),
    'reserved_micro', coalesce(v_m.reserved_micro,0),
    'remaining_micro', coalesce(v_m.cap_micro,v_cfg.monthly_cap_micro,0) - coalesce(v_m.spent_micro,0) - coalesce(v_m.reserved_micro,0),
    'contract','pulse_research_budget_v2_scoped');
END; $function$;

-- Global setter (clears scope => unscoped)
CREATE OR REPLACE FUNCTION public.fn_research_budget_set(
  p_enabled boolean, p_monthly_cap_micro bigint, p_per_run_cap_micro bigint,
  p_per_run_worstcase_micro bigint DEFAULT 150000)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  UPDATE public.research_budget_config
     SET enabled = coalesce(p_enabled,false),
         monthly_cap_micro = greatest(coalesce(p_monthly_cap_micro,0),0),
         per_run_cap_micro = greatest(coalesce(p_per_run_cap_micro,0),0),
         per_run_worstcase_micro = greatest(coalesce(p_per_run_worstcase_micro,150000),0),
         authorized_product_id = NULL, authorized_market = NULL,
         updated_at = now()
   WHERE id;
  RETURN public.fn_research_budget_state();
END; $function$;

-- Scoped authorisation setter (restricts spend to ONE product+market)
CREATE OR REPLACE FUNCTION public.fn_research_budget_authorize(
  p_enabled boolean, p_monthly_cap_micro bigint, p_per_run_cap_micro bigint,
  p_per_run_worstcase_micro bigint, p_product_id uuid, p_market text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  UPDATE public.research_budget_config
     SET enabled = coalesce(p_enabled,false),
         monthly_cap_micro = greatest(coalesce(p_monthly_cap_micro,0),0),
         per_run_cap_micro = greatest(coalesce(p_per_run_cap_micro,0),0),
         per_run_worstcase_micro = greatest(coalesce(p_per_run_worstcase_micro,150000),0),
         authorized_product_id = p_product_id,
         authorized_market = nullif(upper(btrim(coalesce(p_market,''))),''),
         updated_at = now()
   WHERE id;
  RETURN public.fn_research_budget_state();
END; $function$;

-- Reserve now takes the run's product_id + market and enforces the scope when set.
-- The old unscoped 2-arg reserve is NEUTRALISED to a fail-closed shim (rather than dropped) so it can
-- never reserve spend without the product+market scope — equivalent to dropping it, and robust whether
-- or not a DROP can acquire its lock.
CREATE OR REPLACE FUNCTION public.fn_research_budget_reserve(p_run_id uuid, p_provider text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  RETURN jsonb_build_object('ok',false,'reason','deprecated_unscoped_reserve','enforced',true,
    'note','use scoped fn_research_budget_reserve(run,provider,product,market)');
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_research_budget_reserve(
  p_run_id uuid, p_provider text, p_product_id uuid, p_market text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_prov  text := upper(btrim(coalesce(p_provider,'')));
  v_mkt   text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_month text := to_char(timezone('UTC',now()),'YYYY-MM');
  v_cfg   public.research_budget_config%rowtype;
  v_existing public.research_spend_reservation%rowtype;
  v_wc bigint; v_resv_id uuid; v_remaining bigint;
BEGIN
  IF p_run_id IS NULL OR v_prov='' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args','enforced',true);
  END IF;
  SELECT * INTO v_cfg FROM public.research_budget_config WHERE id LIMIT 1;
  IF NOT FOUND OR v_cfg.enabled IS NOT TRUE OR coalesce(v_cfg.monthly_cap_micro,0) <= 0 THEN
    RETURN jsonb_build_object('ok',false,'reason','budget_disabled','enforced',true,
      'note','research USD budget not authorised; paid provider call refused (fail-closed)');
  END IF;

  -- SCOPE ISOLATION: when an authorised product is set, only that exact product+market may spend.
  IF v_cfg.authorized_product_id IS NOT NULL THEN
    IF p_product_id IS DISTINCT FROM v_cfg.authorized_product_id
       OR v_mkt IS DISTINCT FROM nullif(upper(btrim(coalesce(v_cfg.authorized_market,''))),'') THEN
      RETURN jsonb_build_object('ok',false,'reason','scope_mismatch','enforced',true,
        'authorized_product_id',v_cfg.authorized_product_id,'authorized_market',v_cfg.authorized_market,
        'requested_product_id',p_product_id,'requested_market',v_mkt,
        'note','spend authorised only for the scoped product+market (fail-closed)');
    END IF;
  END IF;

  v_wc := coalesce(v_cfg.per_run_worstcase_micro,0);
  IF v_wc <= 0 THEN
    RETURN jsonb_build_object('ok',false,'reason','worstcase_unset','enforced',true);
  END IF;
  IF v_wc > coalesce(v_cfg.per_run_cap_micro,0) THEN
    RETURN jsonb_build_object('ok',false,'reason','exceeds_per_run_cap','enforced',true,
      'per_run_cap_micro',v_cfg.per_run_cap_micro,'worst_case_micro',v_wc);
  END IF;

  INSERT INTO public.research_spend_month(month,cap_micro,spent_micro,reserved_micro)
    VALUES (v_month, v_cfg.monthly_cap_micro, 0, 0)
    ON CONFLICT (month) DO UPDATE SET cap_micro=EXCLUDED.cap_micro, updated_at=now();

  INSERT INTO public.research_spend_reservation(run_id,provider,month,worst_case_micro,status)
    VALUES (p_run_id, v_prov, v_month, v_wc, 'RESERVED')
    ON CONFLICT (run_id,provider) DO NOTHING
    RETURNING id INTO v_resv_id;
  IF v_resv_id IS NULL THEN
    SELECT * INTO v_existing FROM public.research_spend_reservation WHERE run_id=p_run_id AND provider=v_prov;
    RETURN jsonb_build_object('ok',(v_existing.status IN ('RESERVED','RECONCILED')),
      'reason','idempotent_existing','idempotent',true,'status',v_existing.status,
      'reservation_id',v_existing.id,'worst_case_micro',v_existing.worst_case_micro,'enforced',true);
  END IF;

  UPDATE public.research_spend_month
     SET reserved_micro = reserved_micro + v_wc, updated_at=now()
   WHERE month=v_month AND (spent_micro + reserved_micro + v_wc) <= cap_micro
   RETURNING (cap_micro - spent_micro - reserved_micro) INTO v_remaining;
  IF NOT FOUND THEN
    DELETE FROM public.research_spend_reservation WHERE id=v_resv_id;
    RETURN jsonb_build_object('ok',false,'reason','monthly_cap_exceeded','enforced',true,'month',v_month);
  END IF;

  RETURN jsonb_build_object('ok',true,'reservation_id',v_resv_id,'month',v_month,
    'worst_case_micro',v_wc,'remaining_micro',v_remaining,'enforced',true);
END; $function$;

-- Dispatch now passes the run's product_id + market into the scoped reserve.
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

-- Grants (service_role only; Supabase grants anon/authenticated directly, so revoke them explicitly)
REVOKE ALL ON FUNCTION public.fn_research_budget_state() FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_research_budget_set(boolean,bigint,bigint,bigint) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_research_budget_authorize(boolean,bigint,bigint,bigint,uuid,text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_research_budget_reserve(uuid,text,uuid,text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_research_budget_reserve(uuid,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_state() TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_set(boolean,bigint,bigint,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_authorize(boolean,bigint,bigint,bigint,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_reserve(uuid,text,uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_reserve(uuid,text) TO service_role;

-- Self-test updated for the scoped reserve signature + scope enforcement cases.
CREATE OR REPLACE FUNCTION public.fn_research_budget_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_cases jsonb := '[]'::jsonb; v_pass int := 0; v_total int := 0;
  v_runA uuid := gen_random_uuid(); v_runB uuid := gen_random_uuid();
  v_runC uuid := gen_random_uuid(); v_runD uuid := gen_random_uuid();
  v_runE uuid := gen_random_uuid(); v_runF uuid := gen_random_uuid(); v_runZ uuid := gen_random_uuid();
  v_runS1 uuid := gen_random_uuid(); v_runS2 uuid := gen_random_uuid(); v_runS3 uuid := gen_random_uuid();
  v_prod uuid := gen_random_uuid(); v_prodX uuid := gen_random_uuid();
  r jsonb; st jsonb; ok boolean;
BEGIN
  BEGIN
    -- DISABLED => refused
    PERFORM public.fn_research_budget_set(false, 0, 0, 150000);
    r := public.fn_research_budget_reserve(v_runA,'DATAFORSEO',v_prod,'GB');
    ok := (r->>'ok')='false' AND (r->>'reason')='budget_disabled';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','disabled_refused','pass',ok,'got',r));

    -- Global enable (scope null)
    PERFORM public.fn_research_budget_set(true, 1000000, 200000, 150000);
    r := public.fn_research_budget_reserve(v_runA,'DATAFORSEO',v_prod,'GB');
    ok := (r->>'ok')='true' AND (r->>'remaining_micro')='850000';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','reserve_ok_global','pass',ok,'got',r));

    r := public.fn_research_budget_reserve(v_runA,'DATAFORSEO',v_prod,'GB');
    st := public.fn_research_budget_state();
    ok := coalesce((r->>'idempotent')='true',false) AND (st->>'reserved_micro')='150000';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','duplicate_idempotent','pass',ok,'got',r));

    r := public.fn_research_budget_reconcile(v_runA,'DATAFORSEO',102000,'success');
    st := public.fn_research_budget_state();
    ok := (r->>'status')='RECONCILED' AND (r->>'spent_micro')='102000' AND (st->>'spent_micro')='102000' AND (st->>'reserved_micro')='0';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','reconcile_success_actual','pass',ok,'got',r));

    r := public.fn_research_budget_reconcile(v_runA,'DATAFORSEO',102000,'success');
    ok := (r->>'reason')='idempotent';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','reconcile_idempotent','pass',ok,'got',r));

    r := public.fn_research_budget_reserve(v_runB,'DATAFORSEO',v_prod,'GB');
    r := public.fn_research_budget_reconcile(v_runB,'DATAFORSEO',0,'uncertain');
    st := public.fn_research_budget_state();
    ok := (r->>'status')='FORFEITED' AND (r->>'forfeited_micro')='150000' AND (st->>'spent_micro')='252000';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','forfeit_uncertain_no_refund','pass',ok,'got',r));

    r := public.fn_research_budget_reconcile(v_runZ,'DATAFORSEO',102000,'success');
    ok := (r->>'ok')='false' AND (r->>'reason')='no_reservation';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','reconcile_no_reservation','pass',ok,'got',r));

    PERFORM public.fn_research_budget_set(true, 1000000, 100000, 150000);
    r := public.fn_research_budget_reserve(v_runC,'DATAFORSEO',v_prod,'GB');
    ok := (r->>'ok')='false' AND (r->>'reason')='exceeds_per_run_cap';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','per_run_cap_refused','pass',ok,'got',r));

    PERFORM public.fn_research_budget_set(true, 300000, 200000, 150000);
    r := public.fn_research_budget_reserve(v_runD,'DATAFORSEO',v_prod,'GB');
    st := public.fn_research_budget_state();
    ok := (r->>'ok')='false' AND (r->>'reason')='monthly_cap_exceeded' AND (st->>'spent_micro')='252000' AND (st->>'reserved_micro')='0';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','monthly_cap_refused_no_mutation','pass',ok,'got',r));

    PERFORM public.fn_research_budget_set(true, 300000, 200000, 48000);
    r := public.fn_research_budget_reserve(v_runE,'DATAFORSEO',v_prod,'GB');
    ok := (r->>'ok')='true' AND (r->>'remaining_micro')='0';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','exact_boundary_ok','pass',ok,'got',r));

    PERFORM public.fn_research_budget_set(true, 300000, 200000, 1);
    r := public.fn_research_budget_reserve(v_runF,'DATAFORSEO',v_prod,'GB');
    ok := (r->>'ok')='false' AND (r->>'reason')='monthly_cap_exceeded';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','one_micro_over_refused','pass',ok,'got',r));

    -- SCOPE: authorise v_prod+GB only; mismatches fail closed, the exact match succeeds.
    PERFORM public.fn_research_budget_authorize(true, 1000000, 200000, 150000, v_prod, 'GB');
    r := public.fn_research_budget_reserve(v_runS1,'DATAFORSEO',v_prodX,'GB');
    ok := (r->>'ok')='false' AND (r->>'reason')='scope_mismatch';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','scope_wrong_product_refused','pass',ok,'got',r));

    r := public.fn_research_budget_reserve(v_runS2,'DATAFORSEO',v_prod,'US');
    ok := (r->>'ok')='false' AND (r->>'reason')='scope_mismatch';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','scope_wrong_market_refused','pass',ok,'got',r));

    r := public.fn_research_budget_reserve(v_runS3,'DATAFORSEO',v_prod,'GB');
    ok := (r->>'ok')='true';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','scope_match_ok','pass',ok,'got',r));

    RAISE EXCEPTION 'RB_SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'RB_SELFTEST_ROLLBACK' THEN
      RETURN jsonb_build_object('status','SELFTEST_ERROR','error',SQLERRM,'passed',v_pass,'total',v_total,'cases',v_cases);
    END IF;
  END;
  RETURN jsonb_build_object('status', CASE WHEN v_pass=v_total THEN 'PASS' ELSE 'FAIL' END,
    'passed',v_pass,'total',v_total,'cases',v_cases,'contract','pulse_research_budget_selftest_v2_scoped');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_research_budget_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_selftest() TO service_role;

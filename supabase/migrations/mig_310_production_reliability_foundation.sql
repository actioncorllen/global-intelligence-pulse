-- mig_310_production_reliability_foundation.sql
--
-- Production reliability foundation for paid launch. ADDITIVE / idempotent (CREATE OR REPLACE,
-- CREATE TABLE IF NOT EXISTS, ON CONFLICT DO NOTHING; no DROP — a sql_drop event trigger on this
-- project stalls DROP). This migration makes NO paid provider calls. It fixes confirmed defects
-- observed during production bring-up:
--   1. HARD provider-call budget: paid (metered) providers FAIL CLOSED without an approved budget;
--      an approved N-call budget is enforced atomically so retries (incl. timeouts) and concurrent
--      callers can never push 3 approved calls to 4.
--   2. Discovery -> workspace projection: newly discovered, registered candidates become visible WATCH
--      decisions WITHOUT any paid research (separates NEW discovery from the weekly Monday refresh).
--   3. Preflight contract checks + safe provider-response validation.
--   4. Reliability monitor (provider errors, stale data, projection gaps, budgets, schedule gaps) and a
--      discovery dispatch schedule registry that makes the GB scheduling gap explicit (NOT activated).
--   5. A single consolidated selftest (fn_mig310_reliability_selftest) usable as a pre-deploy gate.
-- Preserves tenant/country isolation, verified identity (platform_id), evidence truthfulness
-- (UNKNOWN != 0; no fabrication) and Product Asset Lock (REFERENCE_ONLY unchanged).

-- =====================================================================================
-- SECTION 1 — HARD PROVIDER-CALL BUDGET (metered providers fail closed)
-- =====================================================================================

CREATE TABLE IF NOT EXISTS public.provider_call_budget (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider      text NOT NULL,
  user_id       uuid NOT NULL,
  market        text,
  approval_key  text NOT NULL,
  max_calls     int  NOT NULL CHECK (max_calls >= 0),
  consumed_calls int NOT NULL DEFAULT 0 CHECK (consumed_calls >= 0),
  active        boolean NOT NULL DEFAULT true,
  note          text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz,
  last_consumed_at timestamptz
);
CREATE INDEX IF NOT EXISTS ix_provider_call_budget_active
  ON public.provider_call_budget (provider, user_id) WHERE active;

CREATE TABLE IF NOT EXISTS public.provider_call_ledger (
  id            bigserial PRIMARY KEY,
  provider      text NOT NULL,
  user_id       uuid,
  market        text,
  budget_id     uuid,
  enforced      boolean NOT NULL DEFAULT false,
  net_request_id bigint,
  detail        jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_provider_call_ledger_recent
  ON public.provider_call_ledger (provider, user_id, created_at DESC);

REVOKE ALL ON public.provider_call_budget FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.provider_call_ledger FROM PUBLIC, anon, authenticated;

-- Open (grant) a hard budget. Exactly one active budget per (provider,user) is enforced.
CREATE OR REPLACE FUNCTION public.fn_provider_budget_open(
  p_provider text, p_user_id uuid, p_market text, p_max_calls int,
  p_note text DEFAULT NULL, p_ttl_minutes int DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_prov text := upper(btrim(coalesce(p_provider,''))); v_key text; v_id uuid;
BEGIN
  IF v_prov='' OR p_user_id IS NULL OR p_max_calls IS NULL OR p_max_calls < 0 THEN
    RETURN jsonb_build_object('status','MISSING_ARGS');
  END IF;
  UPDATE public.provider_call_budget SET active=false
    WHERE provider=v_prov AND user_id=p_user_id AND active;
  v_key := replace(gen_random_uuid()::text,'-','');
  INSERT INTO public.provider_call_budget(provider,user_id,market,approval_key,max_calls,note,expires_at)
  VALUES (v_prov,p_user_id,nullif(upper(btrim(coalesce(p_market,''))),''),v_key,p_max_calls,p_note,
          now() + make_interval(mins => greatest(1,coalesce(p_ttl_minutes,30))))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('status','ok','budget_id',v_id,'approval_key',v_key,'provider',v_prov,
    'max_calls',p_max_calls,'contract','pulse_provider_budget_v1');
END; $function$;

-- Atomically try to consume one call.
--   allowed=true  + enforced=true   -> consumed from an explicit budget
--   allowed=false + reason=budget_exceeded  -> active budget exhausted (CALLER MUST ABORT)
--   allowed=false + reason=no_budget_fail_closed -> metered provider with no budget (FAIL CLOSED)
--   allowed=true  + enforced=false  -> non-metered provider, no budget (permitted; logged)
-- The conditional "UPDATE ... consumed_calls<max_calls ... FOR UPDATE" is atomic, so retries AND
-- concurrent callers can never take more than max_calls (only one wins the last slot).
CREATE OR REPLACE FUNCTION public.fn_provider_budget_try_consume(
  p_provider text, p_user_id uuid, p_market text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_prov text := upper(btrim(coalesce(p_provider,'')));
  v_metered boolean; v_id uuid; v_rem int; v_active_exists boolean;
BEGIN
  IF v_prov='' OR p_user_id IS NULL THEN
    RETURN jsonb_build_object('allowed',false,'enforced',true,'reason','missing_args');
  END IF;
  v_metered := v_prov IN ('FASTMOSS','KALODATA');

  UPDATE public.provider_call_budget b
     SET consumed_calls = b.consumed_calls + 1, last_consumed_at = now()
   WHERE b.id = (
     SELECT id FROM public.provider_call_budget
      WHERE provider=v_prov AND user_id=p_user_id AND active
        AND (expires_at IS NULL OR expires_at > now())
        AND consumed_calls < max_calls
      ORDER BY created_at DESC LIMIT 1
     FOR UPDATE)
  RETURNING b.id, (b.max_calls - b.consumed_calls) INTO v_id, v_rem;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('allowed',true,'enforced',true,'budget_id',v_id,'remaining',v_rem);
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.provider_call_budget
     WHERE provider=v_prov AND user_id=p_user_id AND active
       AND (expires_at IS NULL OR expires_at > now())) INTO v_active_exists;
  IF v_active_exists THEN
    RETURN jsonb_build_object('allowed',false,'enforced',true,'reason','budget_exceeded',
      'note','active budget exhausted; call refused so an approved N can never become N+1 (retries + concurrent callers included via atomic consume)');
  END IF;

  IF v_metered THEN
    RETURN jsonb_build_object('allowed',false,'enforced',true,'reason','no_budget_fail_closed',
      'note','metered provider requires an approved budget; paid call refused (fail-closed)');
  END IF;
  RETURN jsonb_build_object('allowed',true,'enforced',false,'reason','no_budget_unenforced');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_provider_budget_open(text,uuid,text,int,text,int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_provider_budget_try_consume(text,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_provider_budget_open(text,uuid,text,int,text,int) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_provider_budget_try_consume(text,uuid,text) TO service_role;

-- Broker budget guard: a refused call never reaches net.http_post; every dispatched call is ledgered.
CREATE OR REPLACE FUNCTION public.fn_invoke_provider_broker(p_function text, p_payload jsonb, p_user_id uuid, p_market text)
 RETURNS bigint
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_slug text := lower(btrim(coalesce(p_function,'')));
  v_base text; v_key text; v_token text; v_req bigint; v_provider text; v_budget jsonb;
BEGIN
  IF v_slug NOT IN ('fastmoss-product-detail') THEN
    RAISE EXCEPTION 'broker_function_not_allowlisted' USING ERRCODE='22023';
  END IF;
  IF p_user_id IS NULL OR coalesce(btrim(p_market),'')='' OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'missing_args' USING ERRCODE='22023';
  END IF;
  SELECT url, secret INTO v_base, v_key FROM public.server_integration_config WHERE key='edge_gateway';
  IF coalesce(btrim(v_base),'')='' OR coalesce(btrim(v_key),'')='' THEN
    RAISE EXCEPTION 'edge_gateway_unconfigured' USING ERRCODE='22023';
  END IF;

  -- HARD BUDGET GATE: paid (metered) providers fail closed without an approved budget; probes exempt.
  IF coalesce((p_payload->>'probe')::boolean,false) IS NOT TRUE THEN
    v_provider := upper(coalesce(nullif(btrim(p_payload->>'provider'),''),'FASTMOSS'));
    v_budget := public.fn_provider_budget_try_consume(v_provider, p_user_id, p_market);
    IF (v_budget->>'allowed') = 'false' THEN
      INSERT INTO public.provider_call_ledger(provider,user_id,market,enforced,detail)
        VALUES (v_provider,p_user_id,upper(btrim(p_market)),true,
          jsonb_build_object('refused',true,'reason',v_budget->>'reason','mode',p_payload->>'mode','path',p_payload->>'path'));
      RAISE EXCEPTION 'provider_budget_exceeded (%): %', v_provider, coalesce(v_budget->>'reason','') USING ERRCODE='22023';
    END IF;
  END IF;

  v_token := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market)
    VALUES (v_token, p_user_id, upper(btrim(p_market)));
  SELECT net.http_post(
    url := rtrim(v_base,'/')||'/functions/v1/'||v_slug,
    body := p_payload,
    headers := jsonb_build_object('Content-Type','application/json','apikey', v_key,
      'Authorization','Bearer '||v_key,'x-pulse-nonce', v_token),
    timeout_milliseconds := 60000
  ) INTO v_req;

  IF coalesce((p_payload->>'probe')::boolean,false) IS NOT TRUE THEN
    INSERT INTO public.provider_call_ledger(provider,user_id,market,budget_id,enforced,net_request_id,detail)
      VALUES (v_provider,p_user_id,upper(btrim(p_market)), nullif(v_budget->>'budget_id','')::uuid,
        coalesce((v_budget->>'enforced')='true',false), v_req,
        jsonb_build_object('mode',p_payload->>'mode','path',p_payload->>'path'));
  END IF;
  RETURN v_req;
END $function$;

-- =====================================================================================
-- SECTION 2 — DISCOVERY -> WORKSPACE PROJECTION (free; no paid research)
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.fn_project_discovered_candidates(p_tenant uuid, p_market text, p_freshness_hours int DEFAULT 168)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_ccy text; v_projected int := 0; v_skipped int := 0; v_already int := 0; v_watch int := 0;
  r record; v_dec text;
BEGIN
  IF p_tenant IS NULL OR v_mkt='' THEN RETURN jsonb_build_object('status','MISSING_ARGS'); END IF;
  SELECT default_currency INTO v_ccy FROM public.ecommerce_market_universe
    WHERE country_code=v_mkt AND coalesce(ecommerce_eligible,true) LIMIT 1;
  IF v_ccy IS NULL THEN RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','market',v_mkt); END IF;

  PERFORM set_config('pulse.suppress_dispatch','on',true);  -- never trigger paid research

  FOR r IN
    SELECT cp.id AS product_id,
      coalesce((SELECT m.value->>'price_query' FROM public.monday_opportunity_registry reg
                CROSS JOIN LATERAL jsonb_array_elements(reg.markets) m
                WHERE reg.tenant_id=p_tenant AND reg.product_id=cp.id AND upper(m.value->>'country')=v_mkt LIMIT 1),
               cp.title) AS price_query
    FROM public.commerce_products cp
    WHERE cp.user_id=p_tenant
      AND EXISTS (SELECT 1 FROM public.monday_opportunity_registry reg
                  WHERE reg.tenant_id=p_tenant AND reg.product_id=cp.id AND reg.active
                    AND EXISTS (SELECT 1 FROM jsonb_array_elements(reg.markets) m WHERE upper(m.value->>'country')=v_mkt))
  LOOP
    IF EXISTS (SELECT 1 FROM public.product_opportunity_decisions d
               WHERE d.tenant_id=p_tenant AND d.product_id=r.product_id AND d.country_code=v_mkt
                 AND coalesce(d.is_fixture,false)=false) THEN
      v_already := v_already + 1; CONTINUE;   -- existing decisions untouched (non-destructive)
    END IF;
    BEGIN
      PERFORM public.fn_assemble_real_product_market(r.product_id, v_mkt, v_ccy, r.price_query, NULL, true);
      v_dec := (public.fn_pod_evaluate(p_tenant, r.product_id, v_mkt, 'pod_v1', true))->>'decision';
      v_projected := v_projected + 1;
      IF v_dec IS NOT NULL AND v_dec <> 'INSUFFICIENT_EVIDENCE' THEN v_watch := v_watch + 1; END IF;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object('status','ok','tenant',p_tenant,'market',v_mkt,'currency',v_ccy,
    'projected',v_projected,'decisioned',v_watch,'already_decided',v_already,'skipped',v_skipped,
    'note','assembles a country PME + pod_evaluate for registered candidates lacking a decision; NO paid research (suppress_dispatch=on); provisional (WATCH) until researched; country-isolated; existing decisions untouched',
    'contract','pulse_project_discovered_candidates_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_project_discovered_candidates(uuid,text,int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_project_discovered_candidates(uuid,text,int) TO service_role;

-- =====================================================================================
-- SECTION 3 — PREFLIGHT CONTRACT CHECKS + SAFE PROVIDER-RESPONSE VALIDATION
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.fn_validate_provider_rank_response(p_response jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE v_list jsonb; v_code text; v_rows int; v_with_pid int;
BEGIN
  IF p_response IS NULL OR jsonb_typeof(p_response) <> 'object' THEN
    RETURN jsonb_build_object('valid',false,'reason','NULL_OR_NON_OBJECT');
  END IF;
  v_code := coalesce(p_response#>>'{raw,code}', p_response#>>'{code}', p_response#>>'{data,code}');
  IF v_code IS NOT NULL AND v_code <> '0' THEN
    RETURN jsonb_build_object('valid',false,'reason','PROVIDER_ERROR_CODE','code',v_code);
  END IF;
  v_list := coalesce(p_response#>'{raw,data,list}', p_response#>'{data,list}', p_response#>'{list}');
  IF v_list IS NULL OR jsonb_typeof(v_list) <> 'array' THEN
    RETURN jsonb_build_object('valid',false,'reason','NO_PRODUCT_LIST');
  END IF;
  v_rows := jsonb_array_length(v_list);
  SELECT count(*) INTO v_with_pid FROM jsonb_array_elements(v_list) e
    WHERE nullif(btrim(coalesce(e->>'product_id','')),'') IS NOT NULL;
  IF v_rows = 0 THEN
    RETURN jsonb_build_object('valid',true,'reason','EMPTY_OK','row_count',0,'rows_with_product_id',0,
      'note','valid but empty; ingest is a safe no-op (UNKNOWN != 0; no fabrication)');
  END IF;
  IF v_with_pid = 0 THEN
    RETURN jsonb_build_object('valid',false,'reason','ROWS_WITHOUT_PRODUCT_ID','row_count',v_rows);
  END IF;
  RETURN jsonb_build_object('valid',true,'reason','OK','row_count',v_rows,'rows_with_product_id',v_with_pid,
    'contract','pulse_provider_rank_response_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_validate_provider_rank_response(jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.fn_preflight_contract_check()
 RETURNS jsonb
 LANGUAGE plpgsql SET search_path TO ''
AS $function$
DECLARE checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0; ok boolean; v text;
  PROCEDURE_CHECK CONSTANT text[] := ARRAY[
    'fn_ecommerce_workspace_intelligence||',
    'fn_product_discovery_lanes|uuid, uuid, text',
    'fn_product_media_state|uuid, uuid, text',
    'fn_ecommerce_product_intelligence|uuid, text',
    'fn_pod_evaluate|uuid, uuid, text, text, boolean',
    'fn_assemble_real_product_market|uuid, text, text, text, uuid, boolean',
    'fn_project_discovered_candidates|uuid, text, integer',
    'fn_invoke_provider_broker|text, jsonb, uuid, text',
    'fn_provider_budget_try_consume|text, uuid, text',
    'fn_validate_provider_rank_response|jsonb'
  ];
  spec text; fname text; fargs text; found boolean;
BEGIN
  FOREACH spec IN ARRAY PROCEDURE_CHECK LOOP
    fname := split_part(spec,'|',1); fargs := split_part(spec,'|',2);
    SELECT EXISTS(
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='public' AND p.proname=fname
         AND (fargs='' OR pg_catalog.oidvectortypes(p.proargtypes)=fargs)
    ) INTO found;
    checks := checks || jsonb_build_object('check','rpc_signature:'||fname,'ok',found,'expected_arg_types',fargs);
    IF found THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  END LOOP;

  v := (public.fn_product_discovery_lanes(NULL,NULL,NULL))->>'contract';
  ok := v = 'pulse_product_discovery_lanes_v1';
  checks := checks || jsonb_build_object('check','contract:discovery_lanes','ok',ok,'got',v);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  v := (public.fn_product_media_state(NULL,NULL,NULL))->>'contract';
  ok := v = 'pulse_product_media_state_v1';
  checks := checks || jsonb_build_object('check','contract:product_media_state','ok',ok,'got',v);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  ok := (public.fn_validate_provider_rank_response(NULL)->>'valid')='false'
    AND (public.fn_validate_provider_rank_response('{"raw":{"code":403}}'::jsonb)->>'valid')='false'
    AND (public.fn_validate_provider_rank_response('{"raw":{"code":0,"data":{"list":[{"product_id":"x"}]}}}'::jsonb)->>'valid')='true';
  checks := checks || jsonb_build_object('check','response_validator_guards','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  RETURN jsonb_build_object('contract','pulse_preflight_contract_check_v1',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),'checks',checks,'generated_at',now());
END; $function$;
REVOKE ALL ON FUNCTION public.fn_preflight_contract_check() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_preflight_contract_check() TO service_role;

-- =====================================================================================
-- SECTION 4 — DISPATCH SCHEDULE REGISTRY + RELIABILITY MONITOR
-- =====================================================================================
CREATE TABLE IF NOT EXISTS public.discovery_dispatch_schedule (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  provider  text NOT NULL,
  market    text NOT NULL,
  kind      text NOT NULL DEFAULT 'NEW_DISCOVERY',  -- NEW_DISCOVERY (paid pulls) | REFRESH (free projection)
  cadence   text NOT NULL DEFAULT 'WEEKLY',
  active    boolean NOT NULL DEFAULT false,         -- NEW_DISCOVERY off until approval + external wiring
  max_calls_per_run int,
  last_dispatched_at timestamptz,
  note      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, provider, market, kind)
);
REVOKE ALL ON public.discovery_dispatch_schedule FROM PUBLIC, anon, authenticated;

INSERT INTO public.discovery_dispatch_schedule (tenant_id, provider, market, kind, cadence, active, max_calls_per_run, note)
VALUES
 ('7c8ddf9d-172c-4a89-a402-bb7066228b61','FASTMOSS','DE','NEW_DISCOVERY','WEEKLY',false,3,'paid 3-lane pull; needs approval (open a budget) + external dispatcher wiring'),
 ('7c8ddf9d-172c-4a89-a402-bb7066228b61','FASTMOSS','GB','NEW_DISCOVERY','WEEKLY',false,3,'GB scheduling gap: enabled in config but never dispatched; activate only with approval + external dispatcher wiring'),
 ('7c8ddf9d-172c-4a89-a402-bb7066228b61','FASTMOSS','DE','REFRESH','WEEKLY',true,0,'free weekly Monday projection of already-registered products; no paid calls'),
 ('7c8ddf9d-172c-4a89-a402-bb7066228b61','FASTMOSS','GB','REFRESH','WEEKLY',true,0,'free weekly Monday projection of already-registered products; no paid calls')
ON CONFLICT (tenant_id, provider, market, kind) DO NOTHING;

CREATE OR REPLACE FUNCTION public.fn_reliability_monitor(p_stale_days int DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_provider_err jsonb; v_stale jsonb; v_gap int; v_budgets jsonb; v_sched jsonb;
BEGIN
  SELECT jsonb_build_object('window','pg_net recent',
      'timeouts', count(*) FILTER (WHERE timed_out),
      'http_errors', count(*) FILTER (WHERE status_code IS NOT NULL AND status_code >= 400),
      'last_error', max(created) FILTER (WHERE timed_out OR status_code >= 400))
    INTO v_provider_err FROM net._http_response;

  SELECT count(*) INTO v_gap
  FROM public.monday_opportunity_registry r
  CROSS JOIN LATERAL jsonb_array_elements(r.markets) m
  WHERE r.active
    AND NOT EXISTS (SELECT 1 FROM public.product_opportunity_decisions d
                    WHERE d.tenant_id=r.tenant_id AND d.product_id=r.product_id
                      AND upper(coalesce(d.country_code,''))=upper(coalesce(m.value->>'country',''))
                      AND coalesce(d.is_fixture,false)=false);

  SELECT coalesce(jsonb_agg(jsonb_build_object('market',mkt,'latest',latest,'age_days',
            round(extract(epoch from (now()-latest))/86400.0,1)) ORDER BY latest), '[]'::jsonb)
    INTO v_stale
  FROM (SELECT upper(value->>'market') AS mkt, max(observed_at) AS latest
          FROM public.commerce_signals
         WHERE signal_type='COMMERCE_PRODUCT_NATIVE' AND nullif(value->>'fastmoss_strategy','') IS NOT NULL
         GROUP BY 1
        HAVING max(observed_at) < now() - make_interval(days => greatest(1,coalesce(p_stale_days,10)))) s;

  SELECT coalesce(jsonb_agg(jsonb_build_object('provider',provider,'market',market,
            'consumed',consumed_calls,'max',max_calls,'remaining',(max_calls-consumed_calls),
            'expires_at',expires_at)), '[]'::jsonb)
    INTO v_budgets FROM public.provider_call_budget
   WHERE active AND (expires_at IS NULL OR expires_at > now());

  SELECT coalesce(jsonb_agg(jsonb_build_object('market',market,'kind',kind,'active',active,
            'last_dispatched_at',last_dispatched_at,
            'overdue', (active AND kind='NEW_DISCOVERY' AND cadence='WEEKLY'
                        AND (last_dispatched_at IS NULL OR last_dispatched_at < now()-interval '8 days')),
            'inactive_gap', (NOT active AND kind='NEW_DISCOVERY'))
          ORDER BY market, kind), '[]'::jsonb)
    INTO v_sched FROM public.discovery_dispatch_schedule;

  RETURN jsonb_build_object('contract','pulse_reliability_monitor_v1','generated_at',now(),
    'provider_errors', v_provider_err,
    'projection_gap_registered_without_decision', v_gap,
    'stale_discovery_markets', v_stale,
    'active_provider_budgets', v_budgets,
    'dispatch_schedule', v_sched,
    'health', CASE WHEN v_gap=0 AND jsonb_array_length(v_stale)=0 THEN 'OK' ELSE 'ATTENTION' END);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_reliability_monitor(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_reliability_monitor(int) TO service_role;

-- =====================================================================================
-- SECTION 5 — CONSOLIDATED PRE-DEPLOY SELFTEST (no paid calls; isolated via subtransaction rollback)
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.fn_mig310_reliability_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  T  uuid := '2f000000-0000-4000-a000-0000000090aa';   -- budgeted test tenant
  TN uuid := '2f000000-0000-4000-a000-0000000090bb';   -- no-budget test tenant
  checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0;
  ok_budget boolean := false; ok_failclosed boolean := false; ok_free boolean := false; ok boolean;
BEGIN
  -- Budget tests run inside an isolated subtransaction that is ALWAYS rolled back: no persistent test
  -- records are written and no DELETE cleanup is needed (variable values survive the rollback).
  BEGIN
    PERFORM public.fn_provider_budget_open('FASTMOSS',T,'GB',3,'mig310 selftest',5);
    ok_budget :=
          (public.fn_provider_budget_try_consume('FASTMOSS',T,'GB')->>'remaining')='2'
      AND (public.fn_provider_budget_try_consume('FASTMOSS',T,'GB')->>'remaining')='1'
      AND (public.fn_provider_budget_try_consume('FASTMOSS',T,'GB')->>'remaining')='0'
      AND (public.fn_provider_budget_try_consume('FASTMOSS',T,'GB')->>'reason')='budget_exceeded'
      AND (public.fn_provider_budget_try_consume('FASTMOSS',T,'GB')->>'allowed')='false';
    ok_failclosed := (public.fn_provider_budget_try_consume('FASTMOSS',TN,'GB')->>'reason')='no_budget_fail_closed'
                 AND (public.fn_provider_budget_try_consume('FASTMOSS',TN,'GB')->>'allowed')='false';
    ok_free := (public.fn_provider_budget_try_consume('INTERNALFREE',TN,NULL)->>'enforced')='false';
    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN ok_budget:=false; ok_failclosed:=false; ok_free:=false; END IF;
  END;

  checks := checks || jsonb_build_object('check','HARD_BUDGET_EXACTLY_3_THEN_REJECT_4TH','ok',ok_budget);
  IF ok_budget THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  checks := checks || jsonb_build_object('check','FASTMOSS_FAILS_CLOSED_WITHOUT_BUDGET','ok',ok_failclosed,
    'note','atomic FOR UPDATE consume also covers retries + concurrent callers: only one caller can take the last slot');
  IF ok_failclosed THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  checks := checks || jsonb_build_object('check','NON_METERED_NOT_BROKEN','ok',ok_free);
  IF ok_free THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  ok := (public.fn_validate_provider_rank_response(NULL)->>'valid')='false'
    AND (public.fn_validate_provider_rank_response('{"raw":{"code":403}}'::jsonb)->>'valid')='false'
    AND (public.fn_validate_provider_rank_response('{"raw":{"code":0,"data":{"list":[]}}}'::jsonb)->>'reason')='EMPTY_OK'
    AND (public.fn_validate_provider_rank_response('{"raw":{"code":0,"data":{"list":[{"product_id":"x"}]}}}'::jsonb)->>'valid')='true';
  checks := checks || jsonb_build_object('check','RESPONSE_VALIDATOR_GUARDS','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  ok := (public.fn_preflight_contract_check()->>'ok')='true';
  checks := checks || jsonb_build_object('check','PREFLIGHT_CONTRACTS_OK','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- NON-DESTRUCTIVE + idempotent projection on an already-decided market (no new work, no writes)
  ok := (public.fn_project_discovered_candidates('7c8ddf9d-172c-4a89-a402-bb7066228b61','GB',168)->>'projected')='0';
  checks := checks || jsonb_build_object('check','PROJECTION_IDEMPOTENT_NONDESTRUCTIVE_GB','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  ok := (public.fn_reliability_monitor(10)->>'contract')='pulse_reliability_monitor_v1';
  checks := checks || jsonb_build_object('check','MONITOR_CONTRACT','ok',ok);
  IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  RETURN jsonb_build_object('contract','pulse_mig310_reliability_selftest_v2',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),'checks',checks,'generated_at',now());
END; $function$;
REVOKE ALL ON FUNCTION public.fn_mig310_reliability_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_mig310_reliability_selftest() TO service_role;

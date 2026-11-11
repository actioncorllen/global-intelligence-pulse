-- ============================================================================
-- DRAFT (PROPOSED, NOT DEPLOYED): kalodata_caller_wiring.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A (Phase 9 — caller wiring)
--
-- Reuses the EXISTING discovery credit workflow for Product Detail + Video Ranking +
-- Video Detail. NO new credit ledger, NO parallel billing:
--   ledger            -> public.discovery_credit_ledger (RESERVE / SETTLE / REFUND)
--   request lifecycle -> public.discovery_refresh_request (+ additive `operation` column)
--   provider budget   -> public.provider_call_budget via fn_provider_budget_try_consume (KALODATA fail-closed)
--   quote/gate        -> fn_discovery_refresh_quote (pricing, balance, entitlement, provider budget)
--   authorize         -> fn_discovery_refresh_authorize (UNCHANGED; operation-agnostic)
--   settle/refund     -> fn_discovery_refresh_settle / fn_discovery_refresh_is_refund (UNCHANGED)
--   nonce             -> public.kalodata_invoke_nonce + fn_kalodata_consume_invoke_nonce
--   market gate       -> public.discovery_provider_market_config (9 enabled Kalodata markets)
--
-- Only two thin additions are operation-generic: a reserve that tags `operation` (reusing the quote +
-- ledger), and a service-role-safe completion (tenant derived from the request row, like the discovery
-- edge's complete_from_edge). The three run_* callers then do: reserve -> authorize -> fire(edge w/ nonce);
-- the edge persists + records usage and calls the completion with the outcome (success settles, failure
-- refunds). Lifecycle, idempotency, tenant isolation and fail-closed budget are inherited unchanged.
--
-- APPLY ONLY via the canonical Supabase migration pipeline. No chargeable call / deploy here.
-- ============================================================================

-- Additive: tag the request lifecycle with the operation (default preserves discovery byte-for-byte).
ALTER TABLE public.discovery_refresh_request
  ADD COLUMN IF NOT EXISTS operation text NOT NULL DEFAULT 'DISCOVERY_REFRESH';

-- Operation-generic reserve (market-gated; reuses fn_discovery_refresh_quote + discovery_credit_ledger).
CREATE OR REPLACE FUNCTION public.fn_kalodata_op_reserve(
  p_operation text, p_market text, p_idempotency_key text, p_page_number integer DEFAULT 1)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_op  text := upper(btrim(coalesce(p_operation,'')));
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_idem text := nullif(btrim(coalesce(p_idempotency_key,'')),'');
  v_q jsonb; v_price int; v_req public.discovery_refresh_request; v_page int := greatest(0, coalesce(p_page_number,1));
BEGIN
  IF v_uid IS NULL OR v_mkt IS NULL OR v_idem IS NULL
     OR v_op NOT IN ('PRODUCT_DETAIL','VIDEO_RANK','VIDEO_DETAIL') THEN
    RETURN jsonb_build_object('status','error','reason','UNAUTHENTICATED_OR_BAD_ARGS','contract','pulse_kalodata_op_reserve_v1');
  END IF;
  -- idempotent replay (never double-charge)
  SELECT * INTO v_req FROM public.discovery_refresh_request WHERE tenant_id=v_uid AND idempotency_key=v_idem;
  IF FOUND THEN
    RETURN jsonb_build_object('status','ok','idempotent_replay',true,'request_id',v_req.id,'state',v_req.status,
      'operation',v_req.operation,'credits_cost',v_req.credits_cost,'market',v_req.market,'contract','pulse_kalodata_op_reserve_v1');
  END IF;
  -- 9-market gate (same source the lane uses). Unsupported/disabled markets never reach pricing/budget.
  IF NOT EXISTS (SELECT 1 FROM public.discovery_provider_market_config
                 WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled) THEN
    RETURN jsonb_build_object('status','denied','reason','UNSUPPORTED_MARKET','market',v_mkt,'contract','pulse_kalodata_op_reserve_v1');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text,42));
  v_q := public.fn_discovery_refresh_quote(v_mkt);
  IF (v_q->>'can_refresh') <> 'true' THEN
    RETURN jsonb_build_object('status','denied','reason',v_q->>'reason','quote',v_q,'contract','pulse_kalodata_op_reserve_v1');
  END IF;
  v_price := (v_q->>'required_credits')::int;
  INSERT INTO public.discovery_refresh_request(tenant_id,market,idempotency_key,status,provider,credits_cost,page_number,operation)
    VALUES (v_uid,v_mkt,v_idem,'RESERVED','KALODATA',v_price,v_page,v_op)
  RETURNING * INTO v_req;
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,idempotency_key,reason)
    VALUES (v_uid,'RESERVE',-v_price,v_req.id,v_idem,lower(v_op)||' '||v_mkt);
  RETURN jsonb_build_object('status','ok','reserved',true,'request_id',v_req.id,'operation',v_op,'credits_cost',v_price,
    'balance_after',public.fn_discovery_credit_balance(),'market',v_mkt,'contract','pulse_kalodata_op_reserve_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_op_reserve(text,text,text,integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_op_reserve(text,text,text,integer) TO authenticated, service_role;

-- Service-role-safe completion (tenant derived from the request row, never auth.uid()) so the edge can
-- settle/refund under service_role. Same ledger + same is_refund logic as fn_discovery_refresh_settle.
CREATE OR REPLACE FUNCTION public.fn_kalodata_op_complete_from_edge(p_request_id uuid, p_outcome text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_req public.discovery_refresh_request; v_outcome text := upper(coalesce(p_outcome,'SUCCESS')); v_refund boolean;
BEGIN
  SELECT * INTO v_req FROM public.discovery_refresh_request WHERE id=p_request_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','error','reason','REQUEST_NOT_FOUND'); END IF;
  IF v_req.status IN ('SETTLED','REFUNDED') THEN
    RETURN jsonb_build_object('status','ok','idempotent_replay',true,'state',v_req.status); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_req.tenant_id::text,42));
  v_refund := public.fn_discovery_refresh_is_refund(v_outcome);
  IF v_refund THEN
    INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,reason)
      VALUES (v_req.tenant_id,'REFUND',v_req.credits_cost,v_req.id,'refund:'||lower(v_outcome)||' op='||lower(coalesce(v_req.operation,'')));
    UPDATE public.discovery_refresh_request SET status='REFUNDED', provider_outcome=v_outcome, updated_at=now() WHERE id=v_req.id;
  ELSE
    INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,reason)
      VALUES (v_req.tenant_id,'SETTLE',0,v_req.id,'settle:'||lower(v_outcome)||' op='||lower(coalesce(v_req.operation,'')));
    UPDATE public.discovery_refresh_request SET status='SETTLED', provider_outcome=v_outcome, updated_at=now() WHERE id=v_req.id;
  END IF;
  RETURN jsonb_build_object('status','ok','outcome',v_outcome,'refunded',v_refund,'settled',NOT v_refund,'operation',v_req.operation);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_op_complete_from_edge(uuid,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_op_complete_from_edge(uuid,text) TO service_role;

-- Generic fire: dispatch-once + nonce + net.http_post to the operation's edge (mirrors fn_discovery_refresh_fire).
CREATE OR REPLACE FUNCTION public.fn_kalodata_op_fire(
  p_request_id uuid, p_anon_key text, p_edge_slug text, p_extra_body jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_req public.discovery_refresh_request;
  v_token text := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_url text := 'https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/'||p_edge_slug; v_net bigint;
BEGIN
  IF v_uid IS NULL OR coalesce(btrim(p_anon_key),'')='' OR coalesce(btrim(p_edge_slug),'')='' THEN
    RETURN jsonb_build_object('status','error','reason','UNAUTHENTICATED_OR_BAD_ARGS'); END IF;
  SELECT * INTO v_req FROM public.discovery_refresh_request WHERE id=p_request_id AND tenant_id=v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','error','reason','REQUEST_NOT_FOUND'); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text,42));
  IF v_req.status <> 'EXECUTING' THEN RETURN jsonb_build_object('status','error','reason','NOT_AUTHORIZED_OR_TERMINAL','state',v_req.status); END IF;
  IF v_req.dispatched_at IS NOT NULL THEN RETURN jsonb_build_object('status','ok','idempotent_replay',true,'already_dispatched',true,'request_id',v_req.id); END IF;
  UPDATE public.discovery_refresh_request SET dispatched_at=now(), updated_at=now() WHERE id=v_req.id;
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market) VALUES (v_token,v_uid,v_req.market);
  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('market',v_req.market,'user_id',v_uid,'refresh_request_id',v_req.id) || coalesce(p_extra_body,'{}'::jsonb),
    headers := jsonb_build_object('Content-Type','application/json','apikey',p_anon_key,'Authorization','Bearer '||p_anon_key,'x-pulse-nonce',v_token),
    timeout_milliseconds := 30000
  ) INTO v_net;
  RETURN jsonb_build_object('status','ok','fired',true,'request_id',v_req.id,'edge',p_edge_slug,'net_request_id',v_net);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_op_fire(uuid,text,text,jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_op_fire(uuid,text,text,jsonb) TO authenticated, service_role;

-- Run callers: reserve -> authorize -> fire. p_dry_run skips the provider fire (reserve+authorize only),
-- used by the self-test and for a no-cost readiness check. authorize already fail-closes without budget.
CREATE OR REPLACE FUNCTION public.fn_kalodata_run_product_detail(
  p_market text, p_product_id uuid, p_kalodata_product_id text, p_idempotency_key text,
  p_anon_key text DEFAULT NULL, p_dry_run boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_res jsonb; v_auth jsonb; v_req uuid;
BEGIN
  v_res := public.fn_kalodata_op_reserve('PRODUCT_DETAIL', p_market, p_idempotency_key, 1);
  IF (v_res->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_res->>'status','stage','reserve','detail',v_res); END IF;
  v_req := (v_res->>'request_id')::uuid;
  v_auth := public.fn_discovery_refresh_authorize(v_req);
  IF (v_auth->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_auth->>'status','stage','authorize','request_id',v_req,'detail',v_auth); END IF;
  IF coalesce(p_dry_run,false) THEN
    RETURN jsonb_build_object('status','ok','stage','authorized_dry_run','request_id',v_req,'note','reserve+authorize ok; fire skipped'); END IF;
  RETURN public.fn_kalodata_op_fire(v_req, p_anon_key, 'kalodata-product-detail',
    jsonb_build_object('product_id', p_product_id, 'kalodata_product_id', p_kalodata_product_id));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_run_product_detail(text,uuid,text,text,text,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_run_product_detail(text,uuid,text,text,text,boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_kalodata_run_video_rank(
  p_market text, p_product_id uuid, p_kalodata_product_id text, p_page_number integer, p_idempotency_key text,
  p_anon_key text DEFAULT NULL, p_dry_run boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_res jsonb; v_auth jsonb; v_req uuid;
BEGIN
  v_res := public.fn_kalodata_op_reserve('VIDEO_RANK', p_market, p_idempotency_key, greatest(1,coalesce(p_page_number,1)));
  IF (v_res->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_res->>'status','stage','reserve','detail',v_res); END IF;
  v_req := (v_res->>'request_id')::uuid;
  v_auth := public.fn_discovery_refresh_authorize(v_req);
  IF (v_auth->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_auth->>'status','stage','authorize','request_id',v_req,'detail',v_auth); END IF;
  IF coalesce(p_dry_run,false) THEN RETURN jsonb_build_object('status','ok','stage','authorized_dry_run','request_id',v_req); END IF;
  RETURN public.fn_kalodata_op_fire(v_req, p_anon_key, 'kalodata-video-rank',
    jsonb_build_object('product_id', p_product_id, 'kalodata_product_id', p_kalodata_product_id, 'page_number', greatest(1,coalesce(p_page_number,1))));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_run_video_rank(text,uuid,text,integer,text,text,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_run_video_rank(text,uuid,text,integer,text,text,boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_kalodata_run_video_detail(
  p_market text, p_video_id text, p_idempotency_key text, p_anon_key text DEFAULT NULL, p_dry_run boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_res jsonb; v_auth jsonb; v_req uuid;
BEGIN
  IF nullif(btrim(coalesce(p_video_id,'')),'') IS NULL THEN RETURN jsonb_build_object('status','error','reason','MISSING_VIDEO_ID'); END IF;
  v_res := public.fn_kalodata_op_reserve('VIDEO_DETAIL', p_market, p_idempotency_key, 1);
  IF (v_res->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_res->>'status','stage','reserve','detail',v_res); END IF;
  v_req := (v_res->>'request_id')::uuid;
  v_auth := public.fn_discovery_refresh_authorize(v_req);
  IF (v_auth->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_auth->>'status','stage','authorize','request_id',v_req,'detail',v_auth); END IF;
  IF coalesce(p_dry_run,false) THEN RETURN jsonb_build_object('status','ok','stage','authorized_dry_run','request_id',v_req); END IF;
  RETURN public.fn_kalodata_op_fire(v_req, p_anon_key, 'kalodata-video-detail', jsonb_build_object('video_id', p_video_id));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_run_video_detail(text,text,text,text,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_run_video_detail(text,text,text,text,boolean) TO authenticated, service_role;

-- Full internal-lifecycle self-test with mocks (seeds its own sentinel tenants; self-cleaning; no fire).
CREATE OR REPLACE FUNCTION public.fn_kalodata_caller_lifecycle_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_a uuid := 'ca11a000-0000-4000-8000-00000000000a';
  v_b uuid := 'ca11b000-0000-4000-8000-00000000000b';
  r_res jsonb; r_auth jsonb; r_done jsonb; r_dup jsonb; r_exhaust jsonb; r_unsup jsonb;
  r_pre jsonb; r_xauth jsonb; r_xsettle jsonb; r_run jsonb; req1 uuid; req2 uuid; req3 uuid;
  bal0 numeric; bal_after_settle numeric; bal_after_refund numeric;
  old_nonce boolean; fresh_nonce boolean; v_tok text := repeat('n',40);
BEGIN
  -- clean + seed
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.discovery_refresh_request WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.provider_call_budget WHERE user_id IN (v_a,v_b);
  DELETE FROM public.account_entitlement WHERE auth_user_id IN (v_a,v_b);
  DELETE FROM public.kalodata_invoke_nonce WHERE user_id IN (v_a,v_b) OR token=v_tok;
  INSERT INTO public.account_entitlement(auth_user_id,status,current_period_end) VALUES (v_a,'ACTIVE', now()+interval '30 days');
  INSERT INTO public.provider_call_budget(provider,user_id,market,active,consumed_calls,max_calls,created_at)
    VALUES ('KALODATA',v_a,'US',true,0,2,now());
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,reason) VALUES (v_a,'GRANT',10,'test grant');
  PERFORM set_config('test.uid', v_a::text, true);
  bal0 := public.fn_discovery_credit_balance();

  -- 1) happy: reserve -> authorize -> complete(SUCCESS) settles (not refunds)
  r_res := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','US','idem1',1); req1 := (r_res->>'request_id')::uuid;
  r_auth := public.fn_discovery_refresh_authorize(req1);
  r_done := public.fn_kalodata_op_complete_from_edge(req1,'SUCCESS');
  bal_after_settle := public.fn_discovery_credit_balance();
  v := v || jsonb_build_object('case','happy_reserve_authorize_settle','pass',
        (r_res->>'status'='ok' AND (r_res->>'credits_cost')::int=1 AND r_auth->>'status'='ok'
         AND (r_auth->>'authorized')::boolean=true AND (r_done->>'settled')::boolean=true
         AND bal_after_settle = bal0 - 1));

  -- 1b) double settlement is idempotent: second complete is a replay, no second SETTLE, no balance change
  r_done := public.fn_kalodata_op_complete_from_edge(req1,'SUCCESS');
  v := v || jsonb_build_object('case','double_settle_idempotent','pass',
        ((r_done->>'idempotent_replay')::boolean=true AND public.fn_discovery_credit_balance() = bal_after_settle
         AND (SELECT count(*) FROM public.discovery_credit_ledger WHERE refresh_request_id=req1 AND entry_type='SETTLE')=1));

  -- 2) duplicate idempotency: same key -> replay, no extra charge
  r_dup := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','US','idem1',1);
  v := v || jsonb_build_object('case','duplicate_request_idempotent','pass',
        ((r_dup->>'idempotent_replay')::boolean=true AND (r_dup->>'request_id')::uuid=req1
         AND public.fn_discovery_credit_balance() = bal_after_settle));

  -- 3) malformed/provider failure after charge -> refund restores credits
  r_res := public.fn_kalodata_op_reserve('VIDEO_RANK','US','idem2',1); req2 := (r_res->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req2);
  r_done := public.fn_kalodata_op_complete_from_edge(req2,'PROVIDER_FAILED_POST_CHARGE');
  bal_after_refund := public.fn_discovery_credit_balance();
  v := v || jsonb_build_object('case','malformed_or_failure_refund','pass',
        ((r_done->>'refunded')::boolean=true AND bal_after_refund = bal_after_settle));  -- reserve(-1)+refund(+1)=net 0

  -- 3b) double refund is idempotent: second complete is a replay, no second REFUND, no balance change
  r_done := public.fn_kalodata_op_complete_from_edge(req2,'PROVIDER_FAILED_POST_CHARGE');
  v := v || jsonb_build_object('case','double_refund_idempotent','pass',
        ((r_done->>'idempotent_replay')::boolean=true AND public.fn_discovery_credit_balance() = bal_after_refund
         AND (SELECT count(*) FROM public.discovery_credit_ledger WHERE refresh_request_id=req2 AND entry_type='REFUND')=1));

  -- 4) credit exhaustion: drain balance below price -> reserve denied
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,reason) VALUES (v_a,'ADJUST', -public.fn_discovery_credit_balance(), 'drain for test');
  r_exhaust := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','US','idem_drain',1);
  v := v || jsonb_build_object('case','credit_exhaustion_denied','pass',
        (r_exhaust->>'status'='denied' AND r_exhaust->>'reason'='INSUFFICIENT_CREDITS'));
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,reason) VALUES (v_a,'GRANT',10,'restore after drain');

  -- 5) unsupported market: reserve rejected by the 9-market gate (IE disabled)
  r_unsup := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','IE','idem_ie',1);
  v := v || jsonb_build_object('case','unsupported_market_denied','pass', (r_unsup->>'reason'='UNSUPPORTED_MARKET'));

  -- 6a) provider budget exhausted at RESERVE: quote denies PROVIDER_NOT_AUTHORIZED (fail-closed before charge)
  UPDATE public.provider_call_budget SET consumed_calls=max_calls WHERE user_id=v_a;
  r_exhaust := public.fn_kalodata_op_reserve('VIDEO_DETAIL','US','idem_noprov',1);
  v := v || jsonb_build_object('case','provider_budget_exhausted_reserve_denied','pass', (r_exhaust->>'reason'='PROVIDER_NOT_AUTHORIZED'));
  -- 6b) budget exhausted AFTER reserve (race): authorize fails closed + auto-refunds, request REFUNDED
  UPDATE public.provider_call_budget SET consumed_calls=0, max_calls=1 WHERE user_id=v_a;
  r_res := public.fn_kalodata_op_reserve('VIDEO_DETAIL','US','idem3',1); req3 := (r_res->>'request_id')::uuid;
  UPDATE public.provider_call_budget SET consumed_calls=1 WHERE user_id=v_a;  -- a concurrent consumer took the last unit
  r_pre := public.fn_discovery_refresh_authorize(req3);
  v := v || jsonb_build_object('case','provider_budget_precharge_fail_closed','pass',
        (r_res->>'status'='ok' AND r_pre->>'status'='denied' AND (r_pre->>'refunded')::boolean=true
         AND (SELECT status FROM public.discovery_refresh_request WHERE id=req3)='REFUNDED'));

  -- 7) cross-tenant: tenant B cannot authorize/settle tenant A's request
  PERFORM set_config('test.uid', v_b::text, true);
  r_xauth   := public.fn_discovery_refresh_authorize(req1);
  r_xsettle := public.fn_discovery_refresh_settle(req1,0,'SUCCESS');
  PERFORM set_config('test.uid', v_a::text, true);
  v := v || jsonb_build_object('case','cross_tenant_rejected','pass',
        (r_xauth->>'reason'='REQUEST_NOT_FOUND' AND r_xsettle->>'reason'='REQUEST_NOT_FOUND'));

  -- 8) expired nonce rejected; fresh nonce accepted
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market,created_at) VALUES (v_tok,v_a,'US', now()-interval '6 minutes');
  old_nonce := public.fn_kalodata_consume_invoke_nonce(v_tok);
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market) VALUES (repeat('f',40),v_a,'US');
  fresh_nonce := public.fn_kalodata_consume_invoke_nonce(repeat('f',40));
  v := v || jsonb_build_object('case','expired_nonce_rejected_fresh_accepted','pass', (old_nonce=false AND fresh_nonce=true));

  -- 9) run_* caller dry-run reaches authorized state through the same path (reset budget first)
  UPDATE public.provider_call_budget SET consumed_calls=0 WHERE user_id=v_a;
  r_run := public.fn_kalodata_run_video_rank('US', NULL, 'kd_prod_1', 1, 'idem_run1', NULL, true);
  v := v || jsonb_build_object('case','run_caller_dry_run_authorized','pass', (r_run->>'stage'='authorized_dry_run'));

  -- cleanup
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.discovery_refresh_request WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.provider_call_budget WHERE user_id IN (v_a,v_b);
  DELETE FROM public.account_entitlement WHERE auth_user_id IN (v_a,v_b);
  DELETE FROM public.kalodata_invoke_nonce WHERE user_id IN (v_a,v_b) OR token IN (v_tok, repeat('f',40));

  RETURN jsonb_build_object('suite','kalodata_caller_lifecycle',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'note','reuses discovery_credit_ledger + provider_call_budget + authorize/settle; no new ledger.',
    'results', v);
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.discovery_refresh_request WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.provider_call_budget WHERE user_id IN (v_a,v_b);
  DELETE FROM public.account_entitlement WHERE auth_user_id IN (v_a,v_b);
  RETURN jsonb_build_object('suite','kalodata_caller_lifecycle','status','error','error',SQLERRM);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_caller_lifecycle_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_caller_lifecycle_selftest() TO service_role;

-- End-to-end lifecycle with MOCKED provider responses + reconcile (requires the full bundle:
-- video intelligence + the product-detail persister). Proves reserve -> authorize -> ingest/persist
-- (mock provider payload) -> settle/refund, and the operation-agnostic reconcile of abandoned EXECUTING.
CREATE OR REPLACE FUNCTION public.fn_kalodata_e2e_mock_lifecycle_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_a uuid := 'ca11e2e0-0000-4000-8000-00000000000e';
  v_p uuid := 'ca11e2e0-0000-4000-8000-0000000000aa';
  r jsonb; req uuid; req2 uuid; req3 uuid; ing jsonb; pr jsonb; done jsonb; bal0 numeric;
  mock_videos jsonb := jsonb_build_array(jsonb_build_object('video_id','ev1','video_title','E2E',
    'belonged_creator_id','c','belonged_creator_handle','@c','revenue',10,'views',99));
  mock_detail jsonb := jsonb_build_object('product_id','kdp1','master_image_url','https://cdn/x.jpg',
    'product_description',jsonb_build_array('d'),'pri_cate_id','1');
BEGIN
  DELETE FROM public.kalodata_video_research WHERE tenant_id=v_a;
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id=v_a;
  DELETE FROM public.discovery_refresh_request WHERE tenant_id=v_a;
  DELETE FROM public.provider_call_budget WHERE user_id=v_a;
  DELETE FROM public.account_entitlement WHERE auth_user_id=v_a;
  DELETE FROM public.commerce_products WHERE id=v_p;
  INSERT INTO public.commerce_products(id,user_id,extended) VALUES (v_p,v_a,jsonb_build_object('kalodata_product_id','kdp1'));
  INSERT INTO public.account_entitlement(auth_user_id,status,current_period_end) VALUES (v_a,'ACTIVE',now()+interval '30 days');
  INSERT INTO public.provider_call_budget(provider,user_id,market,active,consumed_calls,max_calls,created_at) VALUES ('KALODATA',v_a,'US',true,0,10,now());
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,reason) VALUES (v_a,'GRANT',10,'e2e grant');
  PERFORM set_config('test.uid', v_a::text, true);
  bal0 := public.fn_discovery_credit_balance();

  -- A) VIDEO_RANK happy e2e: reserve -> authorize -> ingest mock videos -> settle
  r := public.fn_kalodata_op_reserve('VIDEO_RANK','US','e2e_v1',1); req := (r->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req);
  ing := public.fn_kalodata_ingest_video_rank(v_a, v_p, 'kdp1', 'US', mock_videos);
  done := public.fn_kalodata_op_complete_from_edge(req,'SUCCESS');
  v := v || jsonb_build_object('case','e2e_video_rank_mock_success','pass',
        (ing->>'status'='ok' AND (ing->>'inserted')::int=1 AND (done->>'settled')::boolean=true
         AND (SELECT status FROM public.discovery_refresh_request WHERE id=req)='SETTLED'
         AND EXISTS(SELECT 1 FROM public.kalodata_video_research WHERE tenant_id=v_a AND kalodata_video_id='ev1'
                    AND requested_product_id=v_p AND rights_state='RESEARCH_ONLY')
         AND public.fn_discovery_credit_balance() = bal0 - 1));

  -- B) PRODUCT_DETAIL happy e2e: reserve -> authorize -> persist mock detail -> settle
  r := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','US','e2e_d1',1); req2 := (r->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req2);
  pr := public.fn_persist_kalodata_product_detail(v_a, v_p, 'US', mock_detail);
  done := public.fn_kalodata_op_complete_from_edge(req2,'SUCCESS');
  v := v || jsonb_build_object('case','e2e_product_detail_mock_success','pass',
        ((pr->>'ok')::boolean=true AND (done->>'settled')::boolean=true
         AND (SELECT status FROM public.discovery_refresh_request WHERE id=req2)='SETTLED'));

  -- C) VIDEO_DETAIL provider-failure e2e: reserve -> authorize -> provider fails -> refund, nothing persisted
  r := public.fn_kalodata_op_reserve('VIDEO_DETAIL','US','e2e_f1',1); req3 := (r->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req3);
  done := public.fn_kalodata_op_complete_from_edge(req3,'PROVIDER_FAILED_POST_CHARGE');
  v := v || jsonb_build_object('case','e2e_video_detail_mock_failure_refund','pass',
        ((done->>'refunded')::boolean=true
         AND (SELECT status FROM public.discovery_refresh_request WHERE id=req3)='REFUNDED'
         AND NOT EXISTS(SELECT 1 FROM public.kalodata_video_research WHERE tenant_id=v_a AND source_endpoint='tiktok/video/detail')));

  -- D) abandoned EXECUTING (interrupted provider call) reconciles to REFUNDED, operation-agnostic
  r := public.fn_kalodata_op_reserve('VIDEO_RANK','US','e2e_abandon',1); req := (r->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req);   -- EXECUTING; completion never arrives
  UPDATE public.discovery_refresh_request SET updated_at = now() - interval '31 minutes' WHERE id=req;
  PERFORM public.fn_discovery_refresh_reconcile(30);
  v := v || jsonb_build_object('case','e2e_abandoned_executing_reconciled_refund','pass',
        ((SELECT status FROM public.discovery_refresh_request WHERE id=req)='REFUNDED'
         AND (SELECT provider_outcome FROM public.discovery_refresh_request WHERE id=req)='UNRESOLVED_POST_DISPATCH'));
  -- E) a late completion after reconcile is idempotent (no double refund)
  done := public.fn_kalodata_op_complete_from_edge(req,'SUCCESS');
  v := v || jsonb_build_object('case','e2e_late_completion_after_reconcile_idempotent','pass',
        ((done->>'idempotent_replay')::boolean=true
         AND (SELECT count(*) FROM public.discovery_credit_ledger WHERE refresh_request_id=req AND entry_type='REFUND')=1));

  DELETE FROM public.kalodata_video_research WHERE tenant_id=v_a;
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id=v_a;
  DELETE FROM public.discovery_refresh_request WHERE tenant_id=v_a;
  DELETE FROM public.provider_call_budget WHERE user_id=v_a;
  DELETE FROM public.account_entitlement WHERE auth_user_id=v_a;
  DELETE FROM public.commerce_products WHERE id=v_p;
  RETURN jsonb_build_object('suite','kalodata_e2e_mock_lifecycle',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'note','full lifecycle with mocked provider responses + reconcile; requires the full bundle.',
    'results', v);
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.kalodata_video_research WHERE tenant_id=v_a;
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id=v_a;
  DELETE FROM public.discovery_refresh_request WHERE tenant_id=v_a;
  DELETE FROM public.provider_call_budget WHERE user_id=v_a;
  DELETE FROM public.account_entitlement WHERE auth_user_id=v_a;
  DELETE FROM public.commerce_products WHERE id=v_p;
  RETURN jsonb_build_object('suite','kalodata_e2e_mock_lifecycle','status','error','error',SQLERRM);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_e2e_mock_lifecycle_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_e2e_mock_lifecycle_selftest() TO service_role;

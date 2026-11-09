-- mig_341 — Customer-credit Refresh Discovery: ledger + atomic reserve/settle/refund + fail-closed quote
-- 2026-11-09  (PREPARED; NOT deployed; INERT until the founder sets pricing + grants credits + authorises providers)
--
-- Phase C scaffold. Distinguishes CUSTOMER credits (Strateloq credits, this file) from EXTERNAL PROVIDER
-- credits (provider_call_budget, already present). Reuses the existing entitlement (fn_entitlement_status/
-- account_entitlement), provider budgets (provider_call_budget / fn_provider_budget_try_consume) and the
-- Kalodata discovery dispatch + pagination cursor (fn_kalodata_run_discovery / fn_kalodata_next_page).
--
-- INERT BY DESIGN (prepare, do not activate):
--   * discovery_credit_price starts EMPTY  -> quote returns can_refresh=false (PRICING_NOT_CONFIGURED).
--   * no customer has a balance            -> even priced, balance 0 => INSUFFICIENT_CREDITS.
--   * no active provider budget            -> dispatch fails closed (PROVIDER_NOT_AUTHORIZED).
-- So nothing here can charge a customer or trigger a paid provider call until the founder (1) sets credit
-- pricing, (2) grants customer credit balances, (3) authorises provider budgets. Pricing VALUES are a
-- founder decision and are NOT invented here.
--
-- FOUNDER DECISIONS REQUIRED before activation (none assumed):
--   D1. Credits per refresh, per market (discovery_credit_price rows).
--   D2. How customers receive credits (subscription allowance grant vs purchased packs) -> who writes GRANT rows.
--   D3. Settlement/refund policy confirmation (this file: full refund on provider failure or zero NEW products;
--       otherwise settle). Adjust fn_discovery_refresh_settle if the founder wants a different policy.

-- ---------- tables ----------
CREATE TABLE IF NOT EXISTS public.discovery_credit_ledger (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  entry_type      text NOT NULL CHECK (entry_type IN ('GRANT','RESERVE','SETTLE','REFUND','ADJUST')),
  credits         numeric NOT NULL,                 -- signed: +GRANT/+REFUND, -RESERVE; SETTLE=0 (marker)
  refresh_request_id uuid,
  idempotency_key text,
  reason          text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_dcl_tenant ON public.discovery_credit_ledger(tenant_id, created_at DESC);
-- idempotent accounting: a given idempotency_key writes at most one RESERVE per tenant
CREATE UNIQUE INDEX IF NOT EXISTS uq_dcl_reserve_idem
  ON public.discovery_credit_ledger(tenant_id, idempotency_key)
  WHERE entry_type='RESERVE' AND idempotency_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.discovery_refresh_request (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  market          text NOT NULL,
  idempotency_key text NOT NULL,
  status          text NOT NULL DEFAULT 'RESERVED'
                    CHECK (status IN ('RESERVED','EXECUTING','SETTLED','REFUNDED','FAILED')),
  provider        text NOT NULL DEFAULT 'KALODATA',
  credits_cost    integer NOT NULL,
  page_number     integer,
  candidates_requested integer,
  new_products    integer,
  run_id          uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_drr_tenant_idem ON public.discovery_refresh_request(tenant_id, idempotency_key);

CREATE TABLE IF NOT EXISTS public.discovery_credit_price (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  market             text,                 -- NULL = default for any market
  credits_per_refresh integer NOT NULL CHECK (credits_per_refresh >= 0),
  active             boolean NOT NULL DEFAULT false,
  note               text,
  created_at         timestamptz NOT NULL DEFAULT now()
);
-- intentionally EMPTY: no price is invented. Founder inserts active rows to activate (D1).

-- ---------- RLS: deny-all; access only through SECURITY DEFINER fns (fail-closed) ----------
ALTER TABLE public.discovery_credit_ledger   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discovery_refresh_request ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discovery_credit_price    ENABLE ROW LEVEL SECURITY;
-- tenants may READ their own ledger/requests (for audit history surfaces); no direct writes.
DROP POLICY IF EXISTS dcl_read_own ON public.discovery_credit_ledger;
CREATE POLICY dcl_read_own ON public.discovery_credit_ledger FOR SELECT TO authenticated USING (tenant_id = auth.uid());
DROP POLICY IF EXISTS drr_read_own ON public.discovery_refresh_request;
CREATE POLICY drr_read_own ON public.discovery_refresh_request FOR SELECT TO authenticated USING (tenant_id = auth.uid());
-- price config: no tenant access at all (founder/service-role only, via table editor or a separate admin path).

-- ---------- balance ----------
CREATE OR REPLACE FUNCTION public.fn_discovery_credit_balance()
 RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $fn$
  SELECT coalesce(sum(credits),0)::numeric
  FROM public.discovery_credit_ledger WHERE tenant_id = auth.uid();
$fn$;

-- ---------- quote (pure read; server-authoritative cost; fail-closed) ----------
CREATE OR REPLACE FUNCTION public.fn_discovery_refresh_quote(p_market text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_price int;
  v_bal numeric;
  v_ent boolean;
  v_prov boolean;
  v_reason text := null;
BEGIN
  IF v_uid IS NULL OR v_mkt IS NULL THEN
    RETURN jsonb_build_object('status','error','can_refresh',false,'reason','UNAUTHENTICATED_OR_NO_MARKET',
      'contract','pulse_discovery_refresh_quote_v1');
  END IF;
  -- server-authoritative cost: active price for the market, else the default (market IS NULL) row
  SELECT credits_per_refresh INTO v_price FROM public.discovery_credit_price
   WHERE active AND (market = v_mkt OR market IS NULL)
   ORDER BY (market = v_mkt) DESC LIMIT 1;
  v_bal := public.fn_discovery_credit_balance();
  -- active paid subscription entitlement (reuse existing contract fn_entitlement_active)
  SELECT EXISTS (SELECT 1 FROM public.account_entitlement e
                 WHERE e.auth_user_id = v_uid
                   AND public.fn_entitlement_active(e.status, e.current_period_end)) INTO v_ent;
  v_ent := coalesce(v_ent,false);
  -- provider authorised to run a paid discovery for this market (founder-granted budget with headroom)
  SELECT EXISTS (SELECT 1 FROM public.provider_call_budget b
                 WHERE b.provider='KALODATA' AND b.user_id=v_uid AND b.market=v_mkt
                   AND b.active AND coalesce(b.consumed_calls,0) < b.max_calls
                   AND (b.expires_at IS NULL OR b.expires_at > now())) INTO v_prov;
  IF v_price IS NULL THEN v_reason := 'PRICING_NOT_CONFIGURED';
  ELSIF NOT v_ent THEN v_reason := 'NO_ACTIVE_SUBSCRIPTION';
  ELSIF v_bal < v_price THEN v_reason := 'INSUFFICIENT_CREDITS';
  ELSIF NOT v_prov THEN v_reason := 'PROVIDER_NOT_AUTHORIZED';
  END IF;
  RETURN jsonb_build_object(
    'status','ok','market',v_mkt,
    'required_credits', v_price,                       -- null when no price configured
    'available_credits', v_bal,
    'entitlement_active', v_ent,
    'provider_authorized', coalesce(v_prov,false),
    'can_refresh', (v_reason IS NULL),
    'reason', v_reason,
    'contract','pulse_discovery_refresh_quote_v1');
END; $fn$;

-- ---------- reserve (atomic; idempotent; fail-closed) — does NOT fire the provider call ----------
CREATE OR REPLACE FUNCTION public.fn_discovery_refresh_reserve(p_market text, p_idempotency_key text)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_idem text := nullif(btrim(coalesce(p_idempotency_key,'')),'');
  v_q jsonb;
  v_price int;
  v_req public.discovery_refresh_request;
  v_next int;
BEGIN
  IF v_uid IS NULL OR v_mkt IS NULL OR v_idem IS NULL THEN
    RETURN jsonb_build_object('status','error','reason','UNAUTHENTICATED_OR_BAD_ARGS','contract','pulse_discovery_refresh_reserve_v1');
  END IF;
  -- idempotency: a prior request with this key returns unchanged (no double charge, double-click safe)
  SELECT * INTO v_req FROM public.discovery_refresh_request WHERE tenant_id=v_uid AND idempotency_key=v_idem;
  IF FOUND THEN
    RETURN jsonb_build_object('status','ok','idempotent_replay',true,'request_id',v_req.id,'state',v_req.status,
      'credits_cost',v_req.credits_cost,'market',v_req.market,'contract','pulse_discovery_refresh_reserve_v1');
  END IF;
  -- serialise this tenant's credit mutations (concurrency / double-submit protection)
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text,42));
  -- re-evaluate authoritatively inside the lock
  v_q := public.fn_discovery_refresh_quote(v_mkt);
  IF (v_q->>'can_refresh') <> 'true' THEN
    RETURN jsonb_build_object('status','denied','reason',v_q->>'reason','quote',v_q,'contract','pulse_discovery_refresh_reserve_v1');
  END IF;
  v_price := (v_q->>'required_credits')::int;
  v_next := public.fn_kalodata_next_page(v_uid, v_mkt);   -- correct provider pagination cursor (no page-1 re-buy)
  INSERT INTO public.discovery_refresh_request(tenant_id,market,idempotency_key,status,provider,credits_cost,page_number)
    VALUES (v_uid,v_mkt,v_idem,'RESERVED','KALODATA',v_price,v_next)
  RETURNING * INTO v_req;
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,idempotency_key,reason)
    VALUES (v_uid,'RESERVE',-v_price,v_req.id,v_idem,'refresh_discovery '||v_mkt);
  RETURN jsonb_build_object('status','ok','reserved',true,'request_id',v_req.id,'credits_cost',v_price,
    'balance_after',public.fn_discovery_credit_balance(),'page_number',v_next,'market',v_mkt,
    'contract','pulse_discovery_refresh_reserve_v1');
END; $fn$;

-- ---------- settle / refund (idempotent; explicit policy) ----------
-- Policy (founder decision D3): SUCCESS with >=1 NEW product => SETTLE (credits consumed).
--   Provider failure OR zero NEW products => full REFUND. Partial handling is a founder decision; default is
--   settle on any NEW>0 (a refresh that returns some new products delivered value).
CREATE OR REPLACE FUNCTION public.fn_discovery_refresh_settle(p_request_id uuid, p_new_products integer, p_outcome text)
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_req public.discovery_refresh_request;
  v_outcome text := upper(coalesce(p_outcome,'SUCCESS'));
  v_new int := greatest(coalesce(p_new_products,0),0);
  v_refund boolean;
BEGIN
  SELECT * INTO v_req FROM public.discovery_refresh_request WHERE id=p_request_id AND tenant_id=v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','error','reason','REQUEST_NOT_FOUND','contract','pulse_discovery_refresh_settle_v1'); END IF;
  IF v_req.status IN ('SETTLED','REFUNDED') THEN
    RETURN jsonb_build_object('status','ok','idempotent_replay',true,'state',v_req.status,'contract','pulse_discovery_refresh_settle_v1');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text,42));
  v_refund := (v_outcome <> 'SUCCESS') OR (v_new = 0);
  IF v_refund THEN
    INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,reason)
      VALUES (v_uid,'REFUND',v_req.credits_cost,v_req.id,'refund:'||lower(v_outcome)||' new='||v_new);
    UPDATE public.discovery_refresh_request SET status='REFUNDED', new_products=v_new, updated_at=now() WHERE id=v_req.id;
  ELSE
    INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,reason)
      VALUES (v_uid,'SETTLE',0,v_req.id,'settle new='||v_new);
    UPDATE public.discovery_refresh_request SET status='SETTLED', new_products=v_new, updated_at=now() WHERE id=v_req.id;
  END IF;
  RETURN jsonb_build_object('status','ok','settled',NOT v_refund,'refunded',v_refund,'new_products',v_new,
    'balance_after',public.fn_discovery_credit_balance(),'contract','pulse_discovery_refresh_settle_v1');
END; $fn$;

GRANT EXECUTE ON FUNCTION public.fn_discovery_credit_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_discovery_refresh_quote(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_discovery_refresh_reserve(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_discovery_refresh_settle(uuid,integer,text) TO authenticated;

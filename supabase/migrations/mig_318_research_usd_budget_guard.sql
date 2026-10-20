-- mig_318_research_usd_budget_guard.sql
--
-- STAGE 4A — real server-side USD spending ceiling for paid product research (DataForSEO).
--
-- The 013N auto-dispatch path (fn_auto_dispatch_candidate_research -> fn_research_request_core ->
-- fn_research_dispatch -> research_executor_webhook -> n8n 013N -> fn_research_ingest_source) had NO
-- monetary ceiling: provider_call_budget enforces only CALL COUNTS, DataForSEO is not in its metered
-- set, and the auto-dispatch path never consults it. This migration adds a fail-closed, atomic USD
-- reservation for DataForSEO *before* the webhook fires, enforcing an approved per-run worst-case and a
-- configurable monthly ceiling. It mirrors the proven mig_315 translation-cap pattern
-- (reserve-worst-case-before, reconcile-actual-after, forfeit-on-uncertainty, never refund).
--
-- Verified account pricing (2026-10-20, appendix/user_data): google_ads/search_volume/live = $0.09 flat,
-- dataforseo_labs/search_intent/live = $0.012 min. Known actual per run = $0.102 (102000 micro-USD).
-- Conservative per-run worst-case reserved = $0.15 (150000 micro) by default.
--
-- DEFAULT: DISABLED. With the guard disabled (or no monthly cap authorised), DataForSEO fails CLOSED —
-- it is removed from the dispatch set and no paid call fires. The founder authorises spend by calling
-- fn_research_budget_set(true, <monthly_cap_micro>, <per_run_cap_micro>). 1 USD = 1,000,000 micro-USD.
--
-- Preserves: tenant/country isolation, Product Asset Lock, the separate Gemini $2/mo translation cap
-- (mig_315, untouched), all free providers (eBay/Meta/CJ/TikTok/Reddit unaffected), and every existing
-- workflow (no n8n change). The only paid provider on this path is DataForSEO.

-- ============================================================================================
-- 1) Config singleton (DISABLED by default), monthly spend ledger, per-run reservation ledger
-- ============================================================================================
CREATE TABLE IF NOT EXISTS public.research_budget_config (
  id                       boolean PRIMARY KEY DEFAULT true CHECK (id),  -- singleton row
  enabled                  boolean NOT NULL DEFAULT false,
  monthly_cap_micro        bigint  NOT NULL DEFAULT 0,       -- 0 => no authorised ceiling => fail closed
  per_run_cap_micro        bigint  NOT NULL DEFAULT 0,       -- max a single run may reserve
  per_run_worstcase_micro  bigint  NOT NULL DEFAULT 150000,  -- $0.15 conservative upper bound (> $0.102)
  updated_at               timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.research_budget_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.research_budget_config ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.research_spend_month (
  month          text PRIMARY KEY,               -- 'YYYY-MM' (UTC)
  cap_micro      bigint NOT NULL,
  spent_micro    bigint NOT NULL DEFAULT 0,
  reserved_micro bigint NOT NULL DEFAULT 0,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.research_spend_month ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.research_spend_reservation (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id           uuid NOT NULL,
  provider         text NOT NULL,
  month            text NOT NULL,
  worst_case_micro bigint NOT NULL,
  actual_micro     bigint,
  status           text NOT NULL DEFAULT 'RESERVED',  -- RESERVED | RECONCILED | FORFEITED
  created_at       timestamptz NOT NULL DEFAULT now(),
  reconciled_at    timestamptz,
  UNIQUE (run_id, provider)
);
ALTER TABLE public.research_spend_reservation ENABLE ROW LEVEL SECURITY;
-- No RLS policies: SECURITY DEFINER functions (owned by the table owner) are the only access path;
-- service_role bypasses RLS; anon/authenticated are denied direct table access.

-- ============================================================================================
-- 2) State + founder authorisation setter
-- ============================================================================================
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
    'month', v_month,
    'spent_micro', coalesce(v_m.spent_micro,0),
    'reserved_micro', coalesce(v_m.reserved_micro,0),
    'remaining_micro', coalesce(v_m.cap_micro,v_cfg.monthly_cap_micro,0) - coalesce(v_m.spent_micro,0) - coalesce(v_m.reserved_micro,0),
    'contract','pulse_research_budget_v1');
END; $function$;

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
         updated_at = now()
   WHERE id;
  RETURN public.fn_research_budget_state();
END; $function$;

-- ============================================================================================
-- 3) Atomic, fail-closed reservation (server-owned worst-case; idempotent per run+provider)
-- ============================================================================================
CREATE OR REPLACE FUNCTION public.fn_research_budget_reserve(p_run_id uuid, p_provider text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_prov  text := upper(btrim(coalesce(p_provider,'')));
  v_month text := to_char(timezone('UTC',now()),'YYYY-MM');
  v_cfg   public.research_budget_config%rowtype;
  v_existing public.research_spend_reservation%rowtype;
  v_wc bigint; v_resv_id uuid; v_remaining bigint;
BEGIN
  IF p_run_id IS NULL OR v_prov='' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args','enforced',true);
  END IF;

  SELECT * INTO v_cfg FROM public.research_budget_config WHERE id LIMIT 1;
  -- fail CLOSED: disabled, or no authorised monthly dollar ceiling => no paid call
  IF NOT FOUND OR v_cfg.enabled IS NOT TRUE OR coalesce(v_cfg.monthly_cap_micro,0) <= 0 THEN
    RETURN jsonb_build_object('ok',false,'reason','budget_disabled','enforced',true,
      'note','research USD budget not authorised; paid provider call refused (fail-closed)');
  END IF;

  v_wc := coalesce(v_cfg.per_run_worstcase_micro,0);
  IF v_wc <= 0 THEN
    RETURN jsonb_build_object('ok',false,'reason','worstcase_unset','enforced',true);
  END IF;
  IF v_wc > coalesce(v_cfg.per_run_cap_micro,0) THEN
    RETURN jsonb_build_object('ok',false,'reason','exceeds_per_run_cap','enforced',true,
      'per_run_cap_micro',v_cfg.per_run_cap_micro,'worst_case_micro',v_wc);
  END IF;

  -- ensure the month row exists and tracks the currently authorised cap
  INSERT INTO public.research_spend_month(month,cap_micro,spent_micro,reserved_micro)
    VALUES (v_month, v_cfg.monthly_cap_micro, 0, 0)
    ON CONFLICT (month) DO UPDATE SET cap_micro=EXCLUDED.cap_micro, updated_at=now();

  -- idempotency: claim the one reservation slot for this run+provider FIRST. A retry / duplicate
  -- dispatch / concurrent caller that already holds the slot does not double-charge.
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

  -- atomic conditional reserve against the monthly ceiling. The UPDATE row-locks the month row, so
  -- concurrent reserves serialize and an approved cap can never be exceeded (retries included).
  UPDATE public.research_spend_month
     SET reserved_micro = reserved_micro + v_wc, updated_at=now()
   WHERE month=v_month AND (spent_micro + reserved_micro + v_wc) <= cap_micro
   RETURNING (cap_micro - spent_micro - reserved_micro) INTO v_remaining;
  IF NOT FOUND THEN
    DELETE FROM public.research_spend_reservation WHERE id=v_resv_id;  -- release the claim; no mutation stands
    RETURN jsonb_build_object('ok',false,'reason','monthly_cap_exceeded','enforced',true,'month',v_month);
  END IF;

  RETURN jsonb_build_object('ok',true,'reservation_id',v_resv_id,'month',v_month,
    'worst_case_micro',v_wc,'remaining_micro',v_remaining,'enforced',true);
END; $function$;

-- ============================================================================================
-- 4) Reconcile: success => spend actual (clamped, surplus released); uncertain => forfeit full
--    worst-case. NEVER refunds an uncertain charge. Idempotent.
-- ============================================================================================
CREATE OR REPLACE FUNCTION public.fn_research_budget_reconcile(
  p_run_id uuid, p_provider text, p_actual_micro bigint, p_outcome text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_prov text := upper(btrim(coalesce(p_provider,''))); v_r public.research_spend_reservation%rowtype; v_spend bigint;
BEGIN
  SELECT * INTO v_r FROM public.research_spend_reservation
    WHERE run_id=p_run_id AND provider=v_prov FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','no_reservation'); END IF;
  IF v_r.status <> 'RESERVED' THEN
    RETURN jsonb_build_object('ok',true,'reason','idempotent','status',v_r.status);
  END IF;

  IF lower(coalesce(p_outcome,'')) = 'success' THEN
    v_spend := least(greatest(coalesce(p_actual_micro,0),0), v_r.worst_case_micro);  -- clamp 0..worst_case
    UPDATE public.research_spend_month
       SET spent_micro = spent_micro + v_spend,
           reserved_micro = greatest(reserved_micro - v_r.worst_case_micro, 0), updated_at=now()
     WHERE month=v_r.month;
    UPDATE public.research_spend_reservation
       SET status='RECONCILED', actual_micro=v_spend, reconciled_at=now() WHERE id=v_r.id;
    RETURN jsonb_build_object('ok',true,'status','RECONCILED','spent_micro',v_spend,
      'released_micro',(v_r.worst_case_micro - v_spend));
  ELSE
    -- failure / uncertain: forfeit the FULL worst-case (never refund an uncertain charge)
    UPDATE public.research_spend_month
       SET spent_micro = spent_micro + v_r.worst_case_micro,
           reserved_micro = greatest(reserved_micro - v_r.worst_case_micro, 0), updated_at=now()
     WHERE month=v_r.month;
    UPDATE public.research_spend_reservation
       SET status='FORFEITED', actual_micro=v_r.worst_case_micro, reconciled_at=now() WHERE id=v_r.id;
    RETURN jsonb_build_object('ok',true,'status','FORFEITED','forfeited_micro',v_r.worst_case_micro);
  END IF;
END; $function$;

-- ============================================================================================
-- 5) fn_research_dispatch — unchanged except the DataForSEO USD guard inserted before the webhook
-- ============================================================================================
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

  -- USD BUDGET GUARD (mig_318): DataForSEO is the only paid provider on this path. Before the webhook
  -- fires, atomically reserve its worst-case against the authorised monthly ceiling. If the guard is
  -- disabled or the ceiling would be breached, DataForSEO is removed from the dispatch set (fail-closed)
  -- so the 013N executor skips it; the free providers are unaffected.
  IF v_loc IS NOT NULL THEN
    SELECT EXISTS(SELECT 1 FROM public.commerce_research_source_attempt
      WHERE run_id=p_run_id AND evidence_category='SEARCH_DEMAND' AND source='DATAFORSEO'
        AND state IN ('NOT_SEARCHED','SEARCHING')) INTO v_dfs_pending;
    IF v_dfs_pending THEN
      v_reserve := public.fn_research_budget_reserve(p_run_id, 'DATAFORSEO');
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
    'contract','pulse_research_dispatch_v1_013n_socialvideo_usdguard');
END; $function$;

-- ============================================================================================
-- 6) fn_research_ingest_source — unchanged except DataForSEO reconcile hooks (success/uncertain)
--    Known actual per run = $0.102 = 102000 micro (search_volume $0.09 + search_intent $0.012).
-- ============================================================================================
CREATE OR REPLACE FUNCTION public.fn_research_ingest_source(p_run_id uuid, p_source text, p_raw jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_att public.commerce_research_source_attempt%rowtype;
  v_src text := upper(btrim(coalesce(p_source,'')));
  v_cat text; v_res jsonb; v_found boolean := false; v_failed boolean := false;
  v_t0 timestamptz; v_state text; v_note text; v_tagged int := 0; v_mkt_ebay text;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;

  v_cat := CASE v_src
    WHEN 'EBAY' THEN 'MARKETPLACE' WHEN 'META' THEN 'ADVERTISING' WHEN 'META_AD_LIBRARY' THEN 'ADVERTISING'
    WHEN 'DATAFORSEO' THEN 'SEARCH_DEMAND' WHEN 'CJ' THEN 'SUPPLIER' WHEN 'REDDIT' THEN 'COMMUNITY'
    WHEN 'TIKTOK' THEN 'SOCIAL_VIDEO'
    ELSE NULL END;
  IF v_cat IS NULL THEN RETURN jsonb_build_object('status','UNKNOWN_SOURCE','source',v_src); END IF;

  SELECT * INTO v_att FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND evidence_category=v_cat ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NO_ATTEMPT_FOR_CATEGORY','category',v_cat); END IF;

  UPDATE public.commerce_research_source_attempt SET state='SEARCHING', observed_at=now() WHERE id=v_att.id;
  v_t0 := clock_timestamp();

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
    ELSIF v_src='TIKTOK' THEN
      v_res := public.fn_ingest_tiktok_commercial_content(v_run.product_id, v_run.market, p_raw, false);
      v_found := (v_res->>'advertising_activity_state') = 'OBSERVED';
      v_failed := (v_res->>'status') IN ('not_ad_array','product_not_found');
    ELSIF v_src='REDDIT' THEN
      v_res := jsonb_build_object('status','sweep_source','note','COMMUNITY is a cross-market sweep, not a per-request fetch');
      v_found := false;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- DataForSEO calls may have been billed before the receiver failed; fail CLOSED (forfeit, no refund).
    IF v_src='DATAFORSEO' THEN PERFORM public.fn_research_budget_reconcile(p_run_id,'DATAFORSEO',0,'uncertain'); END IF;
    UPDATE public.commerce_research_source_attempt
      SET state='SOURCE_FAILED', observed_at=now(), note=left('receiver error: '||SQLERRM,480),
          evidence_ref=jsonb_build_object('error','receiver_exception')
      WHERE id=v_att.id;
    PERFORM public.fn_research_maybe_finalize(p_run_id);
    RETURN jsonb_build_object('status','SOURCE_FAILED','source',v_src,'category',v_cat,'error','receiver_exception');
  END;

  UPDATE public.commerce_signals
    SET source_run_id = p_run_id,
        provenance = coalesce(provenance,'{}'::jsonb)
          || jsonb_build_object('research_run_id',p_run_id,'source_attempt_id',v_att.id,'research_market',v_run.market)
    WHERE product_id = v_run.product_id AND created_at >= v_t0 AND source_run_id IS NULL;
  GET DIAGNOSTICS v_tagged = ROW_COUNT;

  IF v_failed THEN v_state:='SOURCE_FAILED'; v_note:='provider/credential operational issue; evidence unchanged, never zeroed';
  ELSIF v_found THEN v_state:='SEARCHED_EVIDENCE_FOUND'; v_note:='canonical evidence accepted';
  ELSE v_state:='SEARCHED_NO_EVIDENCE'; v_note:='legitimate search returned no product-relevant evidence';
  END IF;

  -- USD budget reconcile (mig_318): the DataForSEO live calls bill whenever the executor reaches ingest.
  -- A clean ingest (evidence or honest no-evidence) reconciles to the known actual $0.102; a failed/
  -- uncertain ingest forfeits the full reserved worst-case (never refunded).
  IF v_src='DATAFORSEO' THEN
    PERFORM public.fn_research_budget_reconcile(p_run_id,'DATAFORSEO',
      CASE WHEN v_failed THEN 0 ELSE 102000 END,
      CASE WHEN v_failed THEN 'uncertain' ELSE 'success' END);
  END IF;

  UPDATE public.commerce_research_source_attempt
    SET state=v_state, observed_at=now(), note=v_note,
        evidence_ref=jsonb_build_object('rows_tagged',v_tagged,
          'receiver_status',v_res->>'status',
          'marketplace_activity_state',v_res->>'marketplace_activity_state',
          'advertising_activity_state',v_res->>'advertising_activity_state',
          'buyer_intent_band',v_res->>'buyer_intent_band')
    WHERE id=v_att.id;

  PERFORM public.fn_research_maybe_finalize(p_run_id);

  RETURN jsonb_build_object('status','ok','source',v_src,'category',v_cat,'attempt_state',v_state,
    'rows_tagged',v_tagged,'receiver',v_res,'contract','pulse_research_ingest_v2_013j_usdreconcile');
END; $function$;

-- ============================================================================================
-- 7) Grants: budget functions are server/service-role only (never the browser)
-- ============================================================================================
-- Supabase grants EXECUTE to anon/authenticated directly (not via PUBLIC), so revoke those roles
-- explicitly: these are server-side spend controls and must never be callable from the browser.
REVOKE ALL ON FUNCTION public.fn_research_budget_state() FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_research_budget_set(boolean,bigint,bigint,bigint) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_research_budget_reserve(uuid,text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_research_budget_reconcile(uuid,text,bigint,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_state() TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_set(boolean,bigint,bigint,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_reserve(uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_reconcile(uuid,text,bigint,text) TO service_role;

-- ============================================================================================
-- 8) Self-test (API-only, rolled back in a subtransaction; no paid calls, no persisted state)
-- ============================================================================================
CREATE OR REPLACE FUNCTION public.fn_research_budget_selftest()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_cases jsonb := '[]'::jsonb; v_pass int := 0; v_total int := 0;
  v_runA uuid := gen_random_uuid(); v_runB uuid := gen_random_uuid();
  v_runC uuid := gen_random_uuid(); v_runD uuid := gen_random_uuid();
  v_runE uuid := gen_random_uuid(); v_runF uuid := gen_random_uuid(); v_runZ uuid := gen_random_uuid();
  r jsonb; st jsonb; ok boolean;
BEGIN
  BEGIN  -- rolled-back subtransaction
    -- Case 1: DISABLED => reserve refused (fail-closed)
    PERFORM public.fn_research_budget_set(false, 0, 0, 150000);
    r := public.fn_research_budget_reserve(v_runA,'DATAFORSEO');
    ok := (r->>'ok')='false' AND (r->>'reason')='budget_disabled';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','disabled_refused','pass',ok,'got',r));

    -- Enable: monthly $1.00 (1,000,000), per-run cap $0.20 (200,000), worst-case $0.15 (150,000)
    PERFORM public.fn_research_budget_set(true, 1000000, 200000, 150000);

    -- Case 2: reserve A ok, reserved 150000, remaining 850000
    r := public.fn_research_budget_reserve(v_runA,'DATAFORSEO');
    ok := (r->>'ok')='true' AND (r->>'worst_case_micro')='150000' AND (r->>'remaining_micro')='850000';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','reserve_ok','pass',ok,'got',r));

    -- Case 3: duplicate reserve A => idempotent, no double-charge (month reserved stays 150000)
    r := public.fn_research_budget_reserve(v_runA,'DATAFORSEO');
    st := public.fn_research_budget_state();
    ok := coalesce((r->>'idempotent')='true',false) AND (st->>'reserved_micro')='150000';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','duplicate_idempotent','pass',ok,'got',r,'state',st));

    -- Case 4: reconcile A success at actual 102000 => spent 102000, reserved 0, released 48000
    r := public.fn_research_budget_reconcile(v_runA,'DATAFORSEO',102000,'success');
    st := public.fn_research_budget_state();
    ok := (r->>'status')='RECONCILED' AND (r->>'spent_micro')='102000' AND (r->>'released_micro')='48000'
          AND (st->>'spent_micro')='102000' AND (st->>'reserved_micro')='0';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','reconcile_success_actual','pass',ok,'got',r,'state',st));

    -- Case 5: idempotent reconcile A again => no further mutation
    r := public.fn_research_budget_reconcile(v_runA,'DATAFORSEO',102000,'success');
    st := public.fn_research_budget_state();
    ok := (r->>'reason')='idempotent' AND (st->>'spent_micro')='102000';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','reconcile_idempotent','pass',ok,'got',r));

    -- Case 6: reserve B then forfeit on uncertain => full worst-case charged, never refunded
    r := public.fn_research_budget_reserve(v_runB,'DATAFORSEO');            -- reserved 150000 (spent 102000)
    r := public.fn_research_budget_reconcile(v_runB,'DATAFORSEO',0,'uncertain');
    st := public.fn_research_budget_state();
    ok := (r->>'status')='FORFEITED' AND (r->>'forfeited_micro')='150000'
          AND (st->>'spent_micro')='252000' AND (st->>'reserved_micro')='0';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','forfeit_uncertain_no_refund','pass',ok,'got',r,'state',st));

    -- Case 7: no_reservation reconcile (guard-disabled run never reserved)
    r := public.fn_research_budget_reconcile(v_runZ,'DATAFORSEO',102000,'success');
    ok := (r->>'ok')='false' AND (r->>'reason')='no_reservation';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','reconcile_no_reservation','pass',ok,'got',r));

    -- Case 8: per-run cap enforcement — worst-case (150000) > per-run cap (100000) => refused
    PERFORM public.fn_research_budget_set(true, 1000000, 100000, 150000);
    r := public.fn_research_budget_reserve(v_runC,'DATAFORSEO');
    ok := (r->>'ok')='false' AND (r->>'reason')='exceeds_per_run_cap';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','per_run_cap_refused','pass',ok,'got',r));

    -- Case 9: monthly over-cap boundary + no mutation on refusal.
    -- Fresh accounting is simulated by a tiny monthly cap: cap 300000, worst-case 150000.
    PERFORM public.fn_research_budget_set(true, 300000, 200000, 150000);
    -- NB: the month row already carries spent 252000 from cases 4+6, so only 48000 remains (< 150000):
    -- the very next reserve must be refused, and the month row must be unchanged.
    r := public.fn_research_budget_reserve(v_runD,'DATAFORSEO');
    st := public.fn_research_budget_state();
    ok := (r->>'ok')='false' AND (r->>'reason')='monthly_cap_exceeded'
          AND (st->>'spent_micro')='252000' AND (st->>'reserved_micro')='0';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','monthly_cap_refused_no_mutation','pass',ok,'got',r,'state',st));

    -- Case 10: exact-boundary reserve succeeds (remaining 48000 == worst-case 48000)
    PERFORM public.fn_research_budget_set(true, 300000, 200000, 48000);
    r := public.fn_research_budget_reserve(v_runE,'DATAFORSEO');
    st := public.fn_research_budget_state();
    ok := (r->>'ok')='true' AND (r->>'remaining_micro')='0' AND (st->>'reserved_micro')='48000';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','exact_boundary_ok','pass',ok,'got',r,'state',st));

    -- Case 11: one micro over the now-exhausted cap => refused
    PERFORM public.fn_research_budget_set(true, 300000, 200000, 1);
    r := public.fn_research_budget_reserve(v_runF,'DATAFORSEO');
    ok := (r->>'ok')='false' AND (r->>'reason')='monthly_cap_exceeded';
    v_total:=v_total+1; v_pass:=v_pass+(CASE WHEN ok THEN 1 ELSE 0 END);
    v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','one_micro_over_refused','pass',ok,'got',r));

    RAISE EXCEPTION 'RB_SELFTEST_ROLLBACK';  -- undo ALL selftest writes
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'RB_SELFTEST_ROLLBACK' THEN
      RETURN jsonb_build_object('status','SELFTEST_ERROR','error',SQLERRM,'passed',v_pass,'total',v_total,'cases',v_cases);
    END IF;
  END;
  RETURN jsonb_build_object('status', CASE WHEN v_pass=v_total THEN 'PASS' ELSE 'FAIL' END,
    'passed',v_pass,'total',v_total,'cases',v_cases,'contract','pulse_research_budget_selftest_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_research_budget_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_budget_selftest() TO service_role;

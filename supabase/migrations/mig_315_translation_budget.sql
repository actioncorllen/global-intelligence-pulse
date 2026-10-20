-- mig_315_translation_budget.sql
--
-- STAGE 3 — APPROVED Gemini text translation, under a HARD global $2.00 USD / calendar-month cap.
-- Founder approval: Gemini 2.5 Flash-Lite TEXT only, max $2/month across ALL users. No other paid
-- provider calls. $5/month is NOT yet authorised.
--
-- This migration is the money-critical core: an ATOMIC, server-side, global monthly spend cap with
-- reserve-worst-case-before-call + reconcile-actual-after, that FAILS CLOSED on any error / retry /
-- concurrency / uncertain charge (an uncertain outcome counts the full worst-case as spent, never
-- refunded). It also adds a cache WRITER so translated text is stored once and reused for free.
-- Pricing: the founder-approved Gemini 2.5 Flash-Lite ($0.10/$0.40 per 1M) proved access-denied on
-- this API key ("no longer available to new users"); the founder authorised Gemini 3.1 Flash-Lite
-- instead. Verified pricing (public, 2026): Gemini 3.1 Flash-Lite = $0.25 / 1M input tokens,
-- $1.50 / 1M output tokens. We reserve at a safety margin ABOVE these rates so the cap can
-- never be exceeded, and the SAME (margined) rate is used to reconcile actual spend, so the live
-- counter over-counts rather than under-counts real Google spend — the $2 ceiling binds early, never
-- late.
--
-- Budget functions are service_role ONLY: the browser never touches the budget. The ONLY path to
-- Gemini is the server-side edge function, which must reserve here before any call. Credentials stay
-- server-side (n8n); nothing here exposes a key.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.translation_budget_month (
  month         text PRIMARY KEY,                 -- 'YYYY-MM' (UTC calendar month)
  cap_micro     bigint NOT NULL DEFAULT 2000000,  -- $2.00 in micro-USD (1 USD = 1e6 µUSD)
  reserved_micro bigint NOT NULL DEFAULT 0,
  spent_micro   bigint NOT NULL DEFAULT 0,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (cap_micro >= 0 AND reserved_micro >= 0 AND spent_micro >= 0)
);
ALTER TABLE public.translation_budget_month ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.translation_budget_month FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.translation_spend_ledger (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  month           text NOT NULL,
  worst_case_micro bigint NOT NULL CHECK (worst_case_micro >= 0),
  actual_micro    bigint,
  state           text NOT NULL DEFAULT 'RESERVED' CHECK (state IN ('RESERVED','RECONCILED','FORFEITED')),
  request_hash    text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  reconciled_at   timestamptz
);
ALTER TABLE public.translation_spend_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.translation_spend_ledger FROM PUBLIC, anon, authenticated;
CREATE INDEX IF NOT EXISTS translation_spend_ledger_month_idx ON public.translation_spend_ledger(month, state);

-- ---------------------------------------------------------------------------
-- Cost at verified Gemini 3.1 Flash-Lite rates, in micro-USD, rounded UP, with a safety margin.
-- input $0.25/1M = 0.25 µUSD/token ; output $1.50/1M = 1.50 µUSD/token. SAFETY = 1.5x.
-- (Founder-authorised model after 2.5 Flash-Lite was access-denied on this key.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_translation_cost_micro(p_in_tokens bigint, p_out_tokens bigint)
 RETURNS bigint
 LANGUAGE sql IMMUTABLE
AS $function$
  SELECT ceil(
    (greatest(coalesce(p_in_tokens,0),0) * 0.25 + greatest(coalesce(p_out_tokens,0),0) * 1.50) * 1.5
  )::bigint;
$function$;

-- Worst-case µUSD for a batch, from the source character count (chars/4 ≈ tokens), a fixed prompt
-- overhead, and a generous output bound. Used to RESERVE before the call. Always an over-estimate.
CREATE OR REPLACE FUNCTION public.fn_translation_worstcase_micro(p_total_source_chars bigint, p_item_count int)
 RETURNS bigint
 LANGUAGE sql IMMUTABLE
AS $function$
  SELECT public.fn_translation_cost_micro(
    -- input: source tokens (chars/4) + ~400 prompt-overhead tokens per item
    ceil(greatest(coalesce(p_total_source_chars,0),0) / 4.0)::bigint + (greatest(coalesce(p_item_count,0),0) * 400),
    -- output worst case: ~3x the source tokens, with a floor of 256 tokens per item
    greatest(ceil(greatest(coalesce(p_total_source_chars,0),0) / 4.0 * 3)::bigint, greatest(coalesce(p_item_count,0),0) * 256)
  );
$function$;

-- ---------------------------------------------------------------------------
-- Reserve (atomic). Creates the month row on demand and reserves worst-case, only if it still fits
-- under the cap. Concurrency- and retry-safe: the conditional UPDATE is the single gate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_translation_budget_reserve(p_worst_case_micro bigint, p_request_hash text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_month text := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM');
  v_wc bigint := greatest(coalesce(p_worst_case_micro,0),0);
  v_updated int;
  v_id uuid;
  v_remaining bigint;
BEGIN
  IF v_wc <= 0 THEN RETURN jsonb_build_object('ok',false,'reason','nothing_to_reserve'); END IF;

  INSERT INTO public.translation_budget_month(month) VALUES (v_month) ON CONFLICT (month) DO NOTHING;

  UPDATE public.translation_budget_month
     SET reserved_micro = reserved_micro + v_wc, updated_at = now()
   WHERE month = v_month
     AND (reserved_micro + spent_micro + v_wc) <= cap_micro;
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated = 0 THEN
    SELECT cap_micro - reserved_micro - spent_micro INTO v_remaining
      FROM public.translation_budget_month WHERE month = v_month;
    RETURN jsonb_build_object('ok',false,'reason','budget_exhausted','month',v_month,
      'remaining_micro', greatest(coalesce(v_remaining,0),0));
  END IF;

  INSERT INTO public.translation_spend_ledger(month, worst_case_micro, request_hash)
    VALUES (v_month, v_wc, p_request_hash) RETURNING id INTO v_id;

  SELECT cap_micro - reserved_micro - spent_micro INTO v_remaining
    FROM public.translation_budget_month WHERE month = v_month;

  RETURN jsonb_build_object('ok',true,'reservation_id',v_id,'month',v_month,
    'worst_case_micro',v_wc,'remaining_micro', greatest(coalesce(v_remaining,0),0),
    'contract','pulse_translation_budget_v1');
END; $function$;

-- Reconcile. 'success' -> spend the ACTUAL (clamped to worst-case); 'forfeit' (any failure / timeout /
-- uncertain charge) -> spend the FULL worst-case (fail closed). Idempotent: only a RESERVED row moves.
CREATE OR REPLACE FUNCTION public.fn_translation_budget_reconcile(p_reservation_id uuid, p_actual_micro bigint, p_outcome text)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_month text; v_wc bigint; v_state text; v_spend bigint; v_new_state text;
BEGIN
  SELECT month, worst_case_micro, state INTO v_month, v_wc, v_state
    FROM public.translation_spend_ledger WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','reservation_not_found'); END IF;
  IF v_state <> 'RESERVED' THEN
    RETURN jsonb_build_object('ok',true,'already',v_state,'note','idempotent_no_op');
  END IF;

  IF p_outcome = 'success' THEN
    v_spend := least(greatest(coalesce(p_actual_micro,0),0), v_wc);  -- never charge more than reserved
    v_new_state := 'RECONCILED';
  ELSE
    v_spend := v_wc;                                                  -- fail closed: full worst-case
    v_new_state := 'FORFEITED';
  END IF;

  UPDATE public.translation_budget_month
     SET reserved_micro = greatest(reserved_micro - v_wc, 0),
         spent_micro    = spent_micro + v_spend,
         updated_at = now()
   WHERE month = v_month;

  UPDATE public.translation_spend_ledger
     SET state = v_new_state, actual_micro = v_spend, reconciled_at = now()
   WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok',true,'reservation_id',p_reservation_id,'outcome',p_outcome,
    'spent_micro',v_spend,'state',v_new_state,'contract','pulse_translation_budget_v1');
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_translation_budget_state()
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_month text := to_char(now() AT TIME ZONE 'UTC','YYYY-MM'); v jsonb;
BEGIN
  SELECT jsonb_build_object('month',month,'cap_micro',cap_micro,'reserved_micro',reserved_micro,
    'spent_micro',spent_micro,'remaining_micro', greatest(cap_micro - reserved_micro - spent_micro,0),
    'cap_usd', round(cap_micro/1e6,2),'spent_usd', round(spent_micro/1e6,6),
    'contract','pulse_translation_budget_v1')
  INTO v FROM public.translation_budget_month WHERE month = v_month;
  RETURN coalesce(v, jsonb_build_object('month',v_month,'cap_micro',2000000,'reserved_micro',0,'spent_micro',0,
    'remaining_micro',2000000,'cap_usd',2.00,'spent_usd',0,'contract','pulse_translation_budget_v1'));
END; $function$;

-- Cache WRITER (service_role): store Gemini translations so each phrase is paid for at most once.
-- Idempotent (ON CONFLICT DO NOTHING); never overwrites an existing translation.
CREATE OR REPLACE FUNCTION public.fn_text_translations_put(p_entries jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_n int := 0; e jsonb; v_src text; v_tr text; v_tl text;
BEGIN
  IF jsonb_typeof(p_entries) <> 'array' THEN RETURN jsonb_build_object('ok',false,'reason','bad_input'); END IF;
  FOR e IN SELECT * FROM jsonb_array_elements(p_entries) LOOP
    v_src := btrim(coalesce(e->>'source',''));
    v_tr  := btrim(coalesce(e->>'translated',''));
    v_tl  := lower(btrim(coalesce(e->>'target_lang','')));
    CONTINUE WHEN v_src = '' OR v_tr = '' OR v_tl = '' OR v_tr = v_src;
    INSERT INTO public.text_translation_cache(source_key, source_text, source_lang, target_lang, translated_text, provenance)
    VALUES (md5(v_src), v_src, nullif(lower(btrim(coalesce(e->>'source_lang',''))),''), v_tl, v_tr,
            coalesce(nullif(e->>'provenance',''),'gemini_2_5_flash_lite'))
    ON CONFLICT (source_key, target_lang) DO NOTHING;
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok',true,'written',v_n,'contract','pulse_text_translations_put_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_translation_budget_reserve(bigint,text)   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_translation_budget_reconcile(uuid,bigint,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_translation_budget_state()                FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_text_translations_put(jsonb)              FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_translation_budget_reserve(bigint,text)     TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_translation_budget_reconcile(uuid,bigint,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_translation_budget_state()                 TO service_role;
GRANT EXECUTE ON FUNCTION public.fn_text_translations_put(jsonb)               TO service_role;

-- Ensure the current calendar month exists with the approved $2 cap.
INSERT INTO public.translation_budget_month(month, cap_micro)
VALUES (to_char(now() AT TIME ZONE 'UTC','YYYY-MM'), 2000000)
ON CONFLICT (month) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Selftest (service_role) — verifies the $2/month cap through the REAL reservation API only.
--   * No direct UPDATE of the budget counters (the production reserve/reconcile functions ARE the
--     code under test); no DELETE cleanup.
--   * Every write is made inside a subtransaction that is force-rolled-back (RAISE 'ST_ROLLBACK'),
--     so the live month's counters and the ledger are left exactly as they were — the test is
--     rollback-safe and leaves no persistent rows.
--   * All amounts are relative to a snapshot of the live month, so the test never false-fails as the
--     real budget is consumed; it only needs a little free headroom (guarded).
-- Coverage: reserve + remaining math, reconcile-success (spend=actual, surplus returned),
-- idempotent double-reconcile (no double spend), fail-closed forfeit (charges FULL worst-case, never
-- the larger actual, never a refund), unknown-reservation denial, reserve to the EXACT cap boundary,
-- one-microdollar-over-cap REFUSED with no mutation (the ceiling), and the cost/worst-case helpers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_translation_budget_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0;
  v_stage text := 'init'; v_ended text := 'incomplete'; v_err text := null;
  v_month text := to_char(now() AT TIME ZONE 'UTC','YYYY-MM');
  v_cap bigint; v_res0 bigint; v_spent0 bigint; v_avail0 bigint; v_fill bigint;
  rA jsonb; rB jsonb; rC jsonb; rD jsonb; rE jsonb; rF jsonb; rG jsonb; rH jsonb;
  sB jsonb; sC jsonb; sE jsonb; sH jsonb; idA uuid; idD uuid;
BEGIN
  -- read-only snapshot of the live month (outside the write subtransaction)
  SELECT cap_micro, reserved_micro, spent_micro INTO v_cap, v_res0, v_spent0
    FROM public.translation_budget_month WHERE month = v_month;
  IF NOT FOUND THEN v_cap := 2000000; v_res0 := 0; v_spent0 := 0; END IF;
  v_avail0 := v_cap - v_res0 - v_spent0;

  BEGIN  -- ===== subtransaction: every write below is rolled back =====
    IF v_avail0 < 2000 THEN
      -- Real budget nearly exhausted: skip the headroom-hungry reserves (would be legitimately refused).
      v_checks := v_checks || jsonb_build_object('check','HEADROOM_FOR_FULL_TEST',
        'ok', false, 'detail', jsonb_build_object('available_micro', v_avail0, 'note','insufficient_headroom_cap_checks_skipped'));
    ELSE
      -- A: reserve + remaining math
      v_stage := 'A_reserve';
      rA := public.fn_translation_budget_reserve(1000, 'st-a'); idA := (rA->>'reservation_id')::uuid;
      v_checks := v_checks || jsonb_build_object('check','A_RESERVE_OK',
        'ok', (rA->>'ok')::boolean AND (rA->>'remaining_micro')::bigint = (v_avail0 - 1000) AND idA IS NOT NULL, 'detail', rA);

      -- B: reconcile success, actual < worst_case -> spend=actual, unused reservation returned
      v_stage := 'B_recon_success';
      rB := public.fn_translation_budget_reconcile(idA, 300, 'success'); sB := public.fn_translation_budget_state();
      v_checks := v_checks || jsonb_build_object('check','B_RECONCILE_SUCCESS_PARTIAL',
        'ok', (rB->>'ok')::boolean AND rB->>'state'='RECONCILED' AND (rB->>'spent_micro')::bigint = 300
              AND (sB->>'reserved_micro')::bigint = v_res0 AND (sB->>'spent_micro')::bigint = (v_spent0 + 300), 'detail', rB);

      -- C: idempotent double reconcile — no double spend
      v_stage := 'C_idem';
      rC := public.fn_translation_budget_reconcile(idA, 300, 'success'); sC := public.fn_translation_budget_state();
      v_checks := v_checks || jsonb_build_object('check','C_IDEMPOTENT_NO_DOUBLE_SPEND',
        'ok', (rC->>'ok')::boolean AND rC->>'already'='RECONCILED' AND (sC->>'spent_micro')::bigint = (v_spent0 + 300), 'detail', rC);

      -- D + E: fail-closed forfeit charges FULL worst-case (1000), NOT the larger actual (999999), no refund
      v_stage := 'D_reserve2';
      rD := public.fn_translation_budget_reserve(1000, 'st-d'); idD := (rD->>'reservation_id')::uuid;
      v_stage := 'E_forfeit';
      rE := public.fn_translation_budget_reconcile(idD, 999999, 'error'); sE := public.fn_translation_budget_state();
      v_checks := v_checks || jsonb_build_object('check','E_FAILCLOSED_FORFEIT_FULL_WC',
        'ok', (rD->>'ok')::boolean AND (rE->>'ok')::boolean AND rE->>'state'='FORFEITED'
              AND (rE->>'spent_micro')::bigint = 1000
              AND (sE->>'reserved_micro')::bigint = v_res0 AND (sE->>'spent_micro')::bigint = (v_spent0 + 1300), 'detail', rE);

      -- G: reserve to the EXACT cap boundary succeeds
      v_stage := 'G_fill';
      v_fill := v_cap - v_res0 - (v_spent0 + 1300);
      rG := public.fn_translation_budget_reserve(v_fill, 'st-fill');
      v_checks := v_checks || jsonb_build_object('check','G_RESERVE_TO_EXACT_CAP',
        'ok', (rG->>'ok')::boolean AND (rG->>'remaining_micro')::bigint = 0, 'detail', rG);

      -- H: one microdollar over the cap is REFUSED and mutates nothing (the $2 ceiling, fail closed)
      v_stage := 'H_overcap';
      rH := public.fn_translation_budget_reserve(1, 'st-over'); sH := public.fn_translation_budget_state();
      v_checks := v_checks || jsonb_build_object('check','H_OVER_CAP_REFUSED_FAILCLOSED',
        'ok', (rH->>'ok')::boolean = false AND rH->>'reason'='budget_exhausted' AND (rH->>'remaining_micro')::bigint = 0
              AND (sH->>'reserved_micro')::bigint = (v_cap - v_spent0 - 1300) AND (sH->>'remaining_micro')::bigint = 0, 'detail', rH);
    END IF;

    -- F: unknown reservation safely denied (independent of headroom)
    v_stage := 'F_notfound';
    rF := public.fn_translation_budget_reconcile('00000000-0000-0000-0000-000000000000'::uuid, 0, 'success');
    v_checks := v_checks || jsonb_build_object('check','F_UNKNOWN_RESERVATION_DENIED',
      'ok', (rF->>'ok')::boolean = false AND rF->>'reason'='reservation_not_found', 'detail', rF);

    -- J/K: cost + worst-case helpers at verified Gemini 3.1 Flash-Lite rates ($0.25 in / $1.50 out per 1M, x1.5)
    v_checks := v_checks || jsonb_build_object('check','J_COST_MICRO',
      'ok', public.fn_translation_cost_micro(100,100) = 263, 'detail', public.fn_translation_cost_micro(100,100));
    v_checks := v_checks || jsonb_build_object('check','K_WORSTCASE_MICRO',
      'ok', public.fn_translation_worstcase_micro(50,1) = 731, 'detail', public.fn_translation_worstcase_micro(50,1));

    v_ended := 'completed';
    RAISE EXCEPTION 'ST_ROLLBACK';  -- discard every write above; the live month is left untouched
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'ST_ROLLBACK' THEN v_ended := 'completed_rolledback';
    ELSE v_ended := 'error_at:' || v_stage; v_err := SQLERRM; END IF;
  END;  -- ===== subtransaction rolled back; v_checks (a variable) survives =====

  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass, v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok', v_fail = 0 AND v_ended IN ('completed','completed_rolledback'),
    'ended', v_ended, 'error', v_err, 'passed', v_pass, 'failed', v_fail, 'total', v_pass + v_fail,
    'live_month_snapshot', jsonb_build_object('month',v_month,'cap_micro',v_cap,'reserved_micro',v_res0,
      'spent_micro',v_spent0,'available_micro',v_avail0),
    'checks', v_checks, 'contract','pulse_translation_budget_selftest_v2','generated_at',now());
END; $function$;

REVOKE ALL ON FUNCTION public.fn_translation_budget_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_translation_budget_selftest() TO service_role;

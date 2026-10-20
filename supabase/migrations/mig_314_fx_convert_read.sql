-- mig_314_fx_convert_read.sql
--
-- STAGE 3 GLOBAL LOCALISATION — display-currency conversion (additive, NO paid API, NO rebuild).
-- Reuses the EXISTING, already-authorised FX capability (get_fx_rate over the fx_rates table, sourced
-- from ECB via frankfurter.app and refreshed daily by the existing ingest). fx_rates has RLS enabled
-- with no policy and get_fx_rate is SECURITY INVOKER, so a signed-in member cannot read rates directly.
-- This adds ONE SECURITY DEFINER read wrapper so the client can convert a display amount using genuine,
-- dated rates. Original amount + currency are always preserved by the caller; converted values are
-- labelled with the rate's as_of date + source and a stale flag. Rates are NEVER invented: an
-- unavailable pair returns available=false and the client shows the original only.

CREATE OR REPLACE FUNCTION public.fn_fx_convert(p_from text, p_to text, p_amount numeric DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_from text := upper(btrim(coalesce(p_from,'')));
  v_to   text := upper(btrim(coalesce(p_to,'')));
  v_q jsonb;
  v_rate numeric;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF v_from = '' OR v_to = '' THEN RETURN jsonb_build_object('status','currency_required'); END IF;

  v_q := public.get_fx_rate(v_from, v_to, 36);   -- genuine dated ECB rate (via existing capability)
  IF coalesce((v_q->>'available')::boolean, false) = false THEN
    RETURN jsonb_build_object('status','ok','available',false,
      'from',v_from,'to',v_to,'reason', coalesce(v_q->>'reason','no_rate'),
      'authority','REFERENCE_FX','contract','pulse_fx_convert_v1');
  END IF;

  v_rate := (v_q->>'rate')::numeric;
  RETURN jsonb_build_object('status','ok','available',true,
    'from',v_from,'to',v_to,'rate',v_rate,
    'amount',p_amount,'converted', round(coalesce(p_amount,1) * v_rate, 4),
    'as_of', v_q->>'as_of', 'source', v_q->>'source', 'stale', (v_q->>'stale')::boolean,
    'authority','REFERENCE_FX','contract','pulse_fx_convert_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_fx_convert(text, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_fx_convert(text, text, numeric) TO authenticated, service_role;
COMMENT ON FUNCTION public.fn_fx_convert(text, text, numeric) IS
  'pulse_fx_convert_v1 — display-currency conversion using the existing authorised ECB rates (get_fx_rate over fx_rates). Genuine dated rates only (as_of + source + stale); unavailable pairs return available=false (client keeps the original). Original amount/currency never mutated; no paid API.';

-- Selftest (service_role only): auth gate, currency gate, identity, a real cross rate, an unknown pair.
CREATE OR REPLACE FUNCTION public.fn_fx_convert_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_checks jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0; v_prev text; v_r jsonb;
BEGIN
  v_prev := current_setting('request.jwt.claims', true);

  -- unauthenticated fails closed
  PERFORM set_config('request.jwt.claims','',true);
  v_r := public.fn_fx_convert('GBP','USD',100);
  v_checks := v_checks || jsonb_build_object('check','UNAUTH_FAILS_CLOSED','ok', v_r->>'status'='unauthenticated','detail',v_r);

  PERFORM set_config('request.jwt.claims', json_build_object('sub','7c8ddf9d-172c-4a89-a402-bb7066228b61')::text, true);

  -- currency gate
  v_r := public.fn_fx_convert('', 'USD', 1);
  v_checks := v_checks || jsonb_build_object('check','CURRENCY_REQUIRED','ok', v_r->>'status'='currency_required','detail',v_r);

  -- identity rate = 1
  v_r := public.fn_fx_convert('USD','USD',50);
  v_checks := v_checks || jsonb_build_object('check','IDENTITY_RATE_1',
    'ok', (v_r->>'available')::boolean AND (v_r->>'rate')::numeric = 1 AND (v_r->>'converted')::numeric = 50, 'detail', v_r);

  -- a genuine cross rate with a dated as_of
  v_r := public.fn_fx_convert('GBP','USD',100);
  v_checks := v_checks || jsonb_build_object('check','REAL_CROSS_RATE',
    'ok', (v_r->>'available')::boolean AND (v_r->>'rate')::numeric > 0
          AND (v_r->>'as_of') IS NOT NULL AND (v_r->>'source') IS NOT NULL
          AND round((v_r->>'converted')::numeric, 2) = round(100*(v_r->>'rate')::numeric, 2), 'detail', v_r);

  -- an unknown currency returns available=false (never invented)
  v_r := public.fn_fx_convert('USD','XXX',10);
  v_checks := v_checks || jsonb_build_object('check','UNKNOWN_PAIR_NOT_INVENTED',
    'ok', v_r->>'status'='ok' AND (v_r->>'available')::boolean = false, 'detail', v_r);

  PERFORM set_config('request.jwt.claims', coalesce(v_prev,''), true);

  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean), count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass, v_fail FROM jsonb_array_elements(v_checks) c;
  RETURN jsonb_build_object('ok', v_fail=0,'passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,
    'checks',v_checks,'contract','pulse_fx_convert_selftest_v1','generated_at',now());
END; $function$;

REVOKE ALL ON FUNCTION public.fn_fx_convert_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fx_convert_selftest() TO service_role;

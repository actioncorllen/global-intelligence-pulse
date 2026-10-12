-- mig_374c — Kalodata request builder + multi-lane plan v2 (COMMERCE lane wired)
--
-- fn_kalodata_discovery_request(market): secret-free request builder. Resolves region/
-- language/currency from discovery_provider_market_config and emits the exact seed-free
-- product/rank request body (early/emerging bias: revenue_growth_rate DESC + launch_date<30).
-- No keyword/category/product/shop/creator/video/livestream. UNSUPPORTED_MARKET when the
-- market is not Kalodata-supported. The 'auth' field is a human note only; the raw key
-- lives solely in the backend broker env and never appears in the request body.
--
-- fn_multi_lane_discovery_plan v2: the COMMERCE lane now calls fn_kalodata_discovery_request
-- and reports READY/UNSUPPORTED_MARKET independently of every other lane. SEARCH stays an
-- independent DataForSEO lane; a DataForSEO 402/zero/rate-limit never blocks COMMERCE, and a
-- Kalodata UNSUPPORTED_MARKET never corrupts other lanes. product_native_gap is now computed
-- data-drivenly from the Kalodata market config.
--
-- check_function_bodies disabled for these CREATEs only (managed-instance validation path).

SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_kalodata_discovery_request(p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
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

GRANT EXECUTE ON FUNCTION public.fn_kalodata_discovery_request(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_multi_lane_discovery_plan(p_market text, p_max_lanes integer DEFAULT 5, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  cfg jsonb; v_lanes jsonb := '[]'::jsonb; L record; v_plan jsonb; v_status text; v_runnable boolean;
  v_runnable_lanes text[] := ARRAY[]::text[]; v_n int := greatest(1, least(coalesce(p_max_lanes,5), 10)); v_kreq jsonb;
BEGIN
  cfg := public.fn_market_provider_config(v_mkt);
  IF coalesce((cfg->>'ok')::boolean,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok',false,'market',v_mkt,'reason',coalesce(cfg->>'reason','UNSUPPORTED_MARKET'));
  END IF;
  FOR L IN SELECT * FROM public.discovery_lane_registry WHERE is_active ORDER BY
    CASE availability WHEN 'AVAILABLE' THEN 0 WHEN 'SEEDED_AVAILABLE' THEN 1 ELSE 2 END, lane_key LIMIT v_n
  LOOP
    v_plan := NULL; v_runnable := false; v_kreq := NULL;
    IF L.lane_key='SEARCH' AND L.discovery_mode='AUTONOMOUS' AND L.availability='AVAILABLE' THEN
      v_plan := public.fn_autonomous_discovery_plan(v_mkt, 1, p_user_id);
      IF coalesce((v_plan->>'ok')::boolean,false) THEN v_status := 'READY'; v_runnable := true; v_runnable_lanes := array_append(v_runnable_lanes,'SEARCH');
      ELSE v_status := 'SEARCH_PLAN_'||coalesce(v_plan->>'reason','ERROR'); END IF;
    ELSIF L.lane_key='COMMERCE' AND L.provider='KALODATA' AND L.availability='AVAILABLE' THEN
      v_kreq := public.fn_kalodata_discovery_request(v_mkt);
      IF coalesce((v_kreq->>'ok')::boolean,false) THEN v_status := 'READY'; v_runnable := true; v_runnable_lanes := array_append(v_runnable_lanes,'COMMERCE');
      ELSE v_status := 'UNSUPPORTED_MARKET'; END IF;
    ELSIF L.availability='PRODUCT_NATIVE_GAP' THEN v_status := 'GAP_NO_PRODUCT_NATIVE_PROVIDER';
    ELSIF L.availability='BLOCKED_EXTERNAL_APPROVAL' THEN v_status := 'BLOCKED_EXTERNAL_APPROVAL';
    ELSIF L.availability='RESEARCH_ONLY' THEN v_status := 'RESEARCH_ONLY_NOT_AUTONOMOUS_DISCOVERY';
    ELSIF L.availability='SEEDED_AVAILABLE' THEN v_status := 'SEEDED_REQUIRES_SCOPE';
    ELSE v_status := 'UNAVAILABLE'; END IF;
    v_lanes := v_lanes || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'lane', L.lane_key, 'label', L.label, 'provider', L.provider, 'capability_class', L.capability_class,
      'discovery_mode', L.discovery_mode, 'availability', L.availability, 'status', v_status, 'runnable', v_runnable,
      'selected_scope', v_plan->>'selected_scope', 'keyword_ideas_request', v_plan->'keyword_ideas_request',
      'location_code', v_plan->>'location_code', 'language_code', v_plan->>'language_code',
      'kalodata_request', v_kreq->'request_body', 'kalodata_endpoint', v_kreq->>'endpoint', 'lane_note', L.note)));
  END LOOP;
  RETURN jsonb_build_object('ok',true,'market',v_mkt,'mode','MULTI_LANE_MARKET',
    'runnable_autonomous_lanes', to_jsonb(v_runnable_lanes), 'lane_count', jsonb_array_length(v_lanes),
    'product_native_gap', NOT EXISTS(SELECT 1 FROM public.discovery_provider_market_config WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled),
    'zero_yield_rule','one lane returning zero/unavailable does not stop the cycle; other lanes still run and report explicit status',
    'lanes', v_lanes, 'contract','pulse_multi_lane_discovery_v2');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_multi_lane_discovery_plan(text, integer, uuid) TO authenticated, service_role;

-- Best-effort provider usage/credit telemetry written by the kalodata-discovery broker.
-- Stores observed usage/credit + endpoint on the discovery run. NEVER stores the secret.
CREATE OR REPLACE FUNCTION public.fn_kalodata_record_usage(p_run_id uuid, p_usage jsonb, p_endpoint text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
BEGIN
  IF p_run_id IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','missing_run'); END IF;
  UPDATE public.discovery_runs
    SET raw_contract = coalesce(raw_contract,'{}'::jsonb) || jsonb_build_object(
      'provider_usage', p_usage, 'provider_endpoint', p_endpoint, 'provider_usage_at', now())
    WHERE id = p_run_id;
  RETURN jsonb_build_object('ok', FOUND, 'run_id', p_run_id);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_kalodata_record_usage(uuid, jsonb, text) TO service_role;

-- Persist an explicit COMMERCE lane outcome (requirement 9: lane failure isolation).
-- The broker records every terminal outcome it alone can see (AUTH_FAILED / PAYMENT_REQUIRED
-- / RATE_LIMITED / PROVIDER_UNAVAILABLE / UNSUPPORTED_MARKET / SUCCESS_ZERO_CANDIDATES /
-- FAILED) as a discovery run, so a provider failure is durably observable and is NEVER
-- silently converted to "zero market demand". p_detail must never carry the secret.
CREATE OR REPLACE FUNCTION public.fn_kalodata_record_lane_outcome(p_user_id uuid, p_market text, p_lane_status text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_member uuid; v_run uuid; v_status text := upper(btrim(coalesce(p_lane_status,'FAILED')));
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','missing_user'); END IF;
  SELECT id INTO v_member FROM public.member WHERE auth_user_id=p_user_id LIMIT 1;
  IF v_member IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','no_member'); END IF;
  v_run := gen_random_uuid();
  INSERT INTO public.discovery_runs (id, user_id, member_id, run_status, entry_mode, contract_version, raw_contract, created_at, completed_at)
  VALUES (v_run, p_user_id, v_member,
    CASE WHEN v_status LIKE 'SUCCESS%' THEN 'completed' ELSE 'failed' END,
    'no_store_yet', 1,
    jsonb_build_object('discovery_source','kalodata','lane','COMMERCE','provider','KALODATA',
      'market',upper(btrim(coalesce(p_market,''))),'capability','PRODUCT_NATIVE_COMMERCE_DISCOVERY',
      'lane_status',v_status,'detail',coalesce(p_detail,'{}'::jsonb),
      'contract','kalodata_commerce_lane_outcome_v1'),
    now(), now());
  RETURN jsonb_build_object('ok',true,'run_id',v_run,'lane_status',v_status);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_kalodata_record_lane_outcome(uuid, text, text, jsonb) TO service_role;

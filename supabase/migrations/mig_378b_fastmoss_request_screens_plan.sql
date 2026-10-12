-- mig_378b — FastMoss request builder + branded/IP screen + lane-outcome recorder
--             + multi-lane plan v3 (additive: COMMERCE lane exposes both providers).

-- Seed-free New Listed request builder. date_info.value is DERIVED (yesterday UTC, a
-- completed provider day) per the FastMoss contract, never the hardcoded test date.
CREATE OR REPLACE FUNCTION public.fn_fastmoss_discovery_request(p_market text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE c record; v_date text := to_char(((now() AT TIME ZONE 'UTC')::date - 1), 'YYYY-MM-DD');
BEGIN
  SELECT * INTO c FROM public.discovery_provider_market_config
    WHERE provider='FASTMOSS' AND market=upper(btrim(coalesce(p_market,''))) AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'provider','FASTMOSS','market',upper(coalesce(p_market,'')),'reason','UNSUPPORTED_MARKET');
  END IF;
  RETURN jsonb_build_object('ok',true,'provider','FASTMOSS','market',c.market,'region',c.region,'currency',c.currency,
    'endpoint','POST https://openapi.fastmoss.com/product/v1/rank/newListed',
    'auth','Authorization: Bearer <client_secret> (backend broker only; never in DB/logs/response)',
    'strategy','new_listed_early',
    'request_body', jsonb_build_object(
      'filter', jsonb_build_object('region', c.region, 'date_info', jsonb_build_object('type','day','value',v_date)),
      'orderby', jsonb_build_array(jsonb_build_object('field','day3_units_sold','order','desc')),
      'page', 1, 'pagesize', 10),
    'date_rule','day; anchored to yesterday (UTC), a completed provider day (derived, not hardcoded)',
    'note','new-listed early discovery; candidates only, never opportunity. No keyword/category/product/shop/creator/video seed.',
    'contract','pulse_fastmoss_request_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_discovery_request(text) TO authenticated, service_role;

-- Smallest durable branded/IP screen (not a giant blacklist): distinctive brand/IP tokens +
-- trademark symbols. Flagged -> BRANDED_OR_IP_REVIEW (fail closed to review, never silent pass).
CREATE OR REPLACE FUNCTION public.fn_is_branded_or_ip_sensitive(p_name text)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE
  v text := lower(coalesce(p_name,'')); tok text; matched text[] := ARRAY[]::text[];
  brands text[] := ARRAY['pokemon','pokémon','pikachu','disney','marvel','nintendo','lego','sanrio',
    'hello kitty','harry potter','star wars','barbie','hasbro','funko','jellycat','labubu','bluey',
    'nike','adidas','puma','new balance','jordan','apple','iphone','ipad','airpods','samsung','galaxy',
    'sony','playstation','xbox','dyson','stanley','reisenthel','makita','dewalt','bosch','dji','gopro',
    'gucci','prada','chanel','dior','louis vuitton','rolex','lululemon','ugg','crocs','birkenstock',
    'starbucks','coca cola','red bull','nutella','lindt','haribo'];
BEGIN
  IF v ~ '[®™©]' THEN matched := array_append(matched,'trademark_symbol'); END IF;
  FOREACH tok IN ARRAY brands LOOP
    IF position(tok in v) > 0 THEN matched := array_append(matched, tok); END IF;
  END LOOP;
  IF array_length(matched,1) > 0 THEN
    RETURN jsonb_build_object('flagged',true,'screening_state','BRANDED_OR_IP_REVIEW','matched',to_jsonb(matched));
  END IF;
  RETURN jsonb_build_object('flagged',false,'screening_state','GENERIC_OK');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_is_branded_or_ip_sensitive(text) TO authenticated, service_role;

-- FastMoss explicit lane-outcome recorder (mirrors the Kalodata one; provider FASTMOSS; no secret).
CREATE OR REPLACE FUNCTION public.fn_fastmoss_record_lane_outcome(p_user_id uuid, p_market text, p_lane_status text, p_detail jsonb DEFAULT '{}'::jsonb)
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
    jsonb_build_object('discovery_source','fastmoss','lane','COMMERCE','provider','FASTMOSS',
      'market',upper(btrim(coalesce(p_market,''))),'capability','PRODUCT_NATIVE_COMMERCE_DISCOVERY',
      'lane_status',v_status,'detail',coalesce(p_detail,'{}'::jsonb),
      'contract','fastmoss_commerce_lane_outcome_v1'),
    now(), now());
  RETURN jsonb_build_object('ok',true,'run_id',v_run,'lane_status',v_status);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_record_lane_outcome(uuid, text, text, jsonb) TO service_role;

-- Multi-lane plan v3: COMMERCE lane now exposes BOTH product-native providers (additive;
-- all existing fields preserved). Lane runnable if ANY provider is supported for the market.
CREATE OR REPLACE FUNCTION public.fn_multi_lane_discovery_plan(p_market text, p_max_lanes integer DEFAULT 5, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  cfg jsonb; v_lanes jsonb := '[]'::jsonb; L record; v_plan jsonb; v_status text; v_runnable boolean;
  v_runnable_lanes text[] := ARRAY[]::text[]; v_n int := greatest(1, least(coalesce(p_max_lanes,5), 10));
  v_kreq jsonb; v_freq jsonb; v_kok boolean; v_fok boolean; v_cproviders jsonb;
BEGIN
  cfg := public.fn_market_provider_config(v_mkt);
  IF coalesce((cfg->>'ok')::boolean,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok',false,'market',v_mkt,'reason',coalesce(cfg->>'reason','UNSUPPORTED_MARKET'));
  END IF;
  FOR L IN SELECT * FROM public.discovery_lane_registry WHERE is_active ORDER BY
    CASE availability WHEN 'AVAILABLE' THEN 0 WHEN 'SEEDED_AVAILABLE' THEN 1 ELSE 2 END, lane_key LIMIT v_n
  LOOP
    v_plan := NULL; v_runnable := false; v_kreq := NULL; v_freq := NULL; v_cproviders := NULL;
    IF L.lane_key='SEARCH' AND L.discovery_mode='AUTONOMOUS' AND L.availability='AVAILABLE' THEN
      v_plan := public.fn_autonomous_discovery_plan(v_mkt, 1, p_user_id);
      IF coalesce((v_plan->>'ok')::boolean,false) THEN v_status := 'READY'; v_runnable := true; v_runnable_lanes := array_append(v_runnable_lanes,'SEARCH');
      ELSE v_status := 'SEARCH_PLAN_'||coalesce(v_plan->>'reason','ERROR'); END IF;
    ELSIF L.lane_key='COMMERCE' AND L.provider='KALODATA' AND L.availability='AVAILABLE' THEN
      v_kreq := public.fn_kalodata_discovery_request(v_mkt); v_kok := coalesce((v_kreq->>'ok')::boolean,false);
      v_freq := public.fn_fastmoss_discovery_request(v_mkt); v_fok := coalesce((v_freq->>'ok')::boolean,false);
      v_cproviders := jsonb_build_array(
        jsonb_build_object('provider','KALODATA','role','product_native_commerce_discovery','status', CASE WHEN v_kok THEN 'READY' ELSE 'UNSUPPORTED_MARKET' END),
        jsonb_build_object('provider','FASTMOSS','role','new_listed_early_discovery','status', CASE WHEN v_fok THEN 'READY' ELSE 'UNSUPPORTED_MARKET' END));
      IF v_kok OR v_fok THEN v_status := 'READY'; v_runnable := true; v_runnable_lanes := array_append(v_runnable_lanes,'COMMERCE');
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
      'kalodata_request', v_kreq->'request_body', 'kalodata_endpoint', v_kreq->>'endpoint',
      'fastmoss_request', v_freq->'request_body', 'commerce_providers', v_cproviders, 'lane_note', L.note)));
  END LOOP;
  RETURN jsonb_build_object('ok',true,'market',v_mkt,'mode','MULTI_LANE_MARKET',
    'runnable_autonomous_lanes', to_jsonb(v_runnable_lanes), 'lane_count', jsonb_array_length(v_lanes),
    'product_native_gap', NOT EXISTS(SELECT 1 FROM public.discovery_provider_market_config WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled),
    'zero_yield_rule','one lane returning zero/unavailable does not stop the cycle; other lanes still run and report explicit status',
    'lanes', v_lanes, 'contract','pulse_multi_lane_discovery_v3');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_multi_lane_discovery_plan(text, integer, uuid) TO authenticated, service_role;

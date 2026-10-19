-- mig_308_fastmoss_momentum_enrichment.sql
--
-- Requirement 4: use Historical Sales for country-specific momentum, and attach reviews / creators
-- (videos already handled by mig_305/306) ONLY where real records exist. On-demand enrichment from a
-- stored broker response (fm_raw salesTrend | reviewList | creatorList) — no bulk runs, no provider call
-- here (reads an already-captured net._http_response). Country-isolated; tenant-checked; UNKNOWN != 0;
-- empty provider result => NO_DATA (nothing attached, no fabrication). REFERENCE_ONLY evidence only
-- (Product Asset Lock untouched — nothing written to supplier_product_assets).
--
-- Signature is explicit (user, product, market, response_id, kind): the provider body does not always
-- echo the product id, and enrichment is always for a known, already-discovered product. A single
-- hoisted NO_DATA guard (`jsonb_typeof(list) IS DISTINCT FROM 'array' OR length=0`) covers every kind,
-- including creatorList's empty shape (data without a `list` key).

CREATE OR REPLACE FUNCTION public.fn_fastmoss_enrich_from_response(
  p_user_id uuid, p_product_id uuid, p_market text, p_response_id bigint, p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_kind text := upper(btrim(coalesce(p_kind,'')));
  v_owner uuid; v_fmid text; v_c jsonb; v_raw jsonb; v_list jsonb; v_ov jsonb;
  v_norm jsonb; v_ev jsonb; v_sig text; v_dedup text; v_cnt int; v_avg numeric; v_sig_res jsonb;
BEGIN
  IF p_user_id IS NULL OR p_product_id IS NULL OR v_mkt='' OR p_response_id IS NULL THEN
    RETURN jsonb_build_object('status','MISSING_ARGS'); END IF;
  IF v_kind NOT IN ('SALES_TREND','REVIEWS','CREATORS') THEN
    RETURN jsonb_build_object('status','UNKNOWN_KIND','kind',v_kind); END IF;
  SELECT user_id, nullif(btrim(coalesce(extended->>'fastmoss_product_id','')),'')
    INTO v_owner, v_fmid FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PRODUCT_NOT_FOUND'); END IF;
  IF v_owner IS DISTINCT FROM p_user_id THEN RETURN jsonb_build_object('status','NOT_AUTHORIZED'); END IF;
  SELECT content::jsonb INTO v_c FROM net._http_response WHERE id=p_response_id;
  IF v_c IS NULL THEN RETURN jsonb_build_object('status','RESPONSE_NOT_FOUND','response_id',p_response_id); END IF;
  v_raw := v_c -> 'raw';
  IF coalesce(v_raw->>'code','') <> '0' THEN
    RETURN jsonb_build_object('status','PROVIDER_BODY_NOT_SUCCESS','code',v_raw->>'code','message',v_raw->>'message'); END IF;
  v_list := v_raw -> 'data' -> 'list';
  v_dedup := 'fastmoss:'||coalesce(v_fmid,p_product_id::text)||':'||v_mkt||':'||lower(v_kind);
  -- Hoisted NO_DATA guard: covers an absent/empty list for every kind (creatorList returns {region,
  -- seller_id, product_id} with no list when no creators exist). IS DISTINCT FROM handles SQL NULL.
  IF jsonb_typeof(v_list) IS DISTINCT FROM 'array' OR jsonb_array_length(v_list)=0 THEN
    RETURN jsonb_build_object('status','NO_DATA','kind',v_kind,'product_id',p_product_id,'market',v_mkt); END IF;

  IF v_kind = 'SALES_TREND' THEN
    v_ov := v_raw -> 'data' -> 'overview';
    v_norm := public.fn_discovery_signal_normalize('COMMERCE','fastmoss',v_mkt, jsonb_strip_nulls(jsonb_build_object(
        'revenue', v_ov->>'gmv', 'sales_units', v_ov->>'units_sold',
        'creator_count', v_ov->>'creator_count', 'video_count', v_ov->>'aweme_count',
        'cross_market_reference', false)))
      || jsonb_build_object('fastmoss_strategy','SALES_TREND','momentum_window_days', jsonb_array_length(v_list));
    v_ev := jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'claim','FastMoss Historical Sales (country-specific daily momentum, '||v_mkt||')',
      'source_name','fastmoss','discovery_lane','SALES_TREND','provenance','PLATFORM_REPORTED',
      'daily_series', v_list, 'overview', v_ov, 'net_response_id', p_response_id,
      'note','market-scoped momentum; UNKNOWN != 0; not opportunity; REFERENCE_ONLY evidence')));
    v_sig := 'COMMERCE_SALES_MOMENTUM';

  ELSIF v_kind = 'REVIEWS' THEN
    v_cnt := coalesce(nullif(v_raw->'data'->>'total','')::int, jsonb_array_length(v_list));
    SELECT round(avg((e->>'rating')::numeric),2) INTO v_avg
      FROM jsonb_array_elements(v_list) e WHERE (e->>'rating') ~ '^[0-9]+(\.[0-9]+)?$';
    v_norm := jsonb_build_object('lane','COMMERCE','source','fastmoss','market',v_mkt,
      'review_count', v_cnt, 'avg_rating', v_avg, 'buyer_intent','REVIEWED','fastmoss_strategy','REVIEWS',
      'contract','pulse_discovery_signal_v1');
    v_ev := jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'claim','FastMoss product reviews ('||v_mkt||'): '||v_cnt||' reviews'||coalesce(', avg rating '||v_avg,''),
      'source_name','fastmoss','discovery_lane','REVIEWS','provenance','PLATFORM_REPORTED',
      'review_count', v_cnt, 'avg_rating', v_avg,
      'sample', (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('rating', e->>'rating',
                   'digg_count', e->>'digg_count', 'sku_specification', e->>'sku_specification',
                   'create_time', e->>'create_time'))) FROM (SELECT e FROM jsonb_array_elements(v_list) e LIMIT 5) q),
      'net_response_id', p_response_id)));
    v_sig := 'MARKETPLACE_REVIEW_EVIDENCE';

  ELSE  -- CREATORS
    v_cnt := coalesce(nullif(v_raw->'data'->>'total','')::int, jsonb_array_length(v_list));
    v_norm := jsonb_build_object('lane','COMMERCE','source','fastmoss','market',v_mkt,
      'creator_count', v_cnt, 'fastmoss_strategy','CREATORS','contract','pulse_discovery_signal_v1');
    v_ev := jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'claim','FastMoss product-associated creators ('||v_mkt||'): '||v_cnt||' creators',
      'source_name','fastmoss','discovery_lane','CREATORS','provenance','PLATFORM_REPORTED',
      'creator_count', v_cnt,
      'sample', (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('uid', e->>'uid','unique_id', e->>'unique_id',
                   'units_sold', e->>'units_sold','follower_count', e->>'follower_count')))
                 FROM (SELECT e FROM jsonb_array_elements(v_list) e LIMIT 5) q),
      'net_response_id', p_response_id)));
    v_sig := 'COMMUNITY_CREATOR_EVIDENCE';
  END IF;

  v_sig_res := public.ingest_commerce_signal(p_user_id, p_product_id, NULL, v_sig,
    v_norm, v_ev, 'PLATFORM_REPORTED', 0.6, now(), NULL, v_dedup);
  RETURN jsonb_build_object('status','ATTACHED','kind',v_kind,'signal_type',v_sig,
    'product_id',p_product_id,'market',v_mkt,'dedup_key',v_dedup,'records', jsonb_array_length(v_list),
    'signal_result', v_sig_res, 'authority','REFERENCE_ONLY','contract','pulse_fastmoss_enrich_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_fastmoss_enrich_from_response(uuid,uuid,text,bigint,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_enrich_from_response(uuid,uuid,text,bigint,text) TO service_role;

-- Selftest: SALES_TREND attaches real country-specific momentum; REVIEWS/CREATORS with no genuine
-- records => NO_DATA (never fabricated); momentum signal is persisted + country-scoped; cross-tenant
-- rejected. (Validated against captured responses 167/168/169 the day of deploy; those net._http_response
-- rows are ephemeral, so on a fresh environment the attach/NO_DATA checks read from whatever is captured.)
CREATE OR REPLACE FUNCTION public.fn_fastmoss_enrich_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  OWNER_T uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  PROD uuid := '5bc29d0a-b8e0-4fa9-bb80-d77197d770c4';
  checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0; ok boolean;
  r_st jsonb; r_rv jsonb; r_cr jsonb; v_cnt int;
BEGIN
  r_st := public.fn_fastmoss_enrich_from_response(OWNER_T, PROD, 'DE', 167::bigint, 'SALES_TREND');
  ok := (r_st->>'status'='ATTACHED') AND (r_st->>'signal_type'='COMMERCE_SALES_MOMENTUM') AND ((r_st->>'records')::int=7);
  checks := checks || jsonb_build_object('check','SALES_TREND_ATTACHED_REAL','ok',ok,'records',r_st->>'records'); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  r_rv := public.fn_fastmoss_enrich_from_response(OWNER_T, PROD, 'DE', 168::bigint, 'REVIEWS');
  ok := (r_rv->>'status'='NO_DATA');
  checks := checks || jsonb_build_object('check','REVIEWS_NO_DATA_NOT_FABRICATED','ok',ok,'status',r_rv->>'status'); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  r_cr := public.fn_fastmoss_enrich_from_response(OWNER_T, PROD, 'DE', 169::bigint, 'CREATORS');
  ok := (r_cr->>'status'='NO_DATA');
  checks := checks || jsonb_build_object('check','CREATORS_NO_DATA_NOT_FABRICATED','ok',ok,'status',r_cr->>'status'); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  SELECT count(*) INTO v_cnt FROM public.commerce_signals
    WHERE user_id=OWNER_T AND product_id=PROD AND signal_type='COMMERCE_SALES_MOMENTUM'
      AND value->>'market'='DE' AND (value->>'sales_units') IS NOT NULL;
  ok := (v_cnt >= 1);
  checks := checks || jsonb_build_object('check','MOMENTUM_SIGNAL_PERSISTED_COUNTRY_SCOPED','ok',ok,'rows',v_cnt); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  ok := (public.fn_fastmoss_enrich_from_response('2f000000-0000-4000-a000-000000002999'::uuid, PROD, 'DE', 167::bigint, 'SALES_TREND')->>'status'='NOT_AUTHORIZED');
  checks := checks || jsonb_build_object('check','CROSS_TENANT_REJECTED','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  RETURN jsonb_build_object('contract','pulse_fastmoss_enrich_selftest_v1',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),'checks',checks,'generated_at',now());
END; $function$;

REVOKE ALL ON FUNCTION public.fn_fastmoss_enrich_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_enrich_selftest() TO service_role;

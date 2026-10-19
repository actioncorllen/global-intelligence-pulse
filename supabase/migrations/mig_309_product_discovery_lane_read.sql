-- mig_309_product_discovery_lane_read.sql
--
-- Server-owned, country-isolated READ contract for the Product Intelligence workspace to surface the
-- three distinct FastMoss discovery lanes (New Listed / Top Selling / Most Promoted) and their genuine
-- evidence: per-lane sales/growth/promotion, country-specific historical momentum, and source freshness.
-- Display-only (REFERENCE_ONLY). Auth is server-owned via auth.uid() (p_tenant is NEVER trusted for
-- authorization — same model as fn_product_media_state). Fail-closed.
--
-- Integrity (req 5): empty/UNKNOWN signals never surface as evidence — reviews require a non-null
-- review_count, creators require a non-null creator_count (so the known spurious empty-creator row,
-- creator_count=null, is excluded and contributes nothing). Lanes are derived from the per-lane,
-- market-scoped COMMERCE_PRODUCT_NATIVE signals (verified fastmoss identity), not from loose family keys.

CREATE OR REPLACE FUNCTION public.fn_product_discovery_lanes(p_tenant uuid, p_product uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();   -- SERVER-OWNED identity; p_tenant ignored for authorization.
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_owns boolean; v_lanes jsonb; v_lane_keys jsonb; v_momentum jsonb; v_reviews jsonb; v_creators jsonb; v_fresh timestamptz;
  v_denied jsonb := jsonb_build_object('status','unauthorized','discovery_lanes','[]'::jsonb,'lanes','[]'::jsonb,
    'momentum',NULL,'reviews',NULL,'creators',NULL,'authority','REFERENCE_ONLY','contract','pulse_product_discovery_lanes_v1');
BEGIN
  IF v_uid IS NULL OR p_product IS NULL OR v_mkt IS NULL THEN RETURN v_denied; END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product AND user_id=v_uid) INTO v_owns;
  IF NOT v_owns THEN RETURN v_denied; END IF;

  -- Per-lane evidence from the distinct, market-scoped discovery signals (one per lane; latest wins).
  SELECT coalesce(jsonb_agg(l ORDER BY l->>'lane'), '[]'::jsonb),
         coalesce(jsonb_agg(DISTINCT (l->>'lane')) FILTER (WHERE l->>'lane' IS NOT NULL), '[]'::jsonb),
         max((l->>'observed_at')::timestamptz)
    INTO v_lanes, v_lane_keys, v_fresh
  FROM (
    SELECT DISTINCT ON (s.value->>'fastmoss_strategy') jsonb_strip_nulls(jsonb_build_object(
      'lane', s.value->>'fastmoss_strategy',
      'sales_units', nullif(s.value->>'sales_units','')::numeric,
      'revenue', nullif(s.value->>'revenue','')::numeric,
      'sales_growth_rate', nullif(s.value->>'sales_growth_rate','')::numeric,
      'promotions_affiliate_count', nullif(s.value->>'creator_count','')::numeric,  -- MOST_PROMOTED: affiliate_count
      'observed_at', s.observed_at,
      'source', 'FASTMOSS', 'authority','REFERENCE_ONLY')) AS l
    FROM public.commerce_signals s
    WHERE s.product_id=p_product AND s.user_id=v_uid AND s.signal_type='COMMERCE_PRODUCT_NATIVE'
      AND upper(coalesce(s.value->>'market',''))=v_mkt
      AND nullif(s.value->>'fastmoss_strategy','') IS NOT NULL
    ORDER BY s.value->>'fastmoss_strategy', s.observed_at DESC
  ) q;

  -- Country-specific historical momentum (latest). Non-fabricated: only if a genuine signal exists.
  SELECT jsonb_strip_nulls(jsonb_build_object(
      'units_sold', nullif(s.value->>'sales_units','')::numeric,
      'revenue', nullif(s.value->>'revenue','')::numeric,
      'creator_count', nullif(s.value->>'creator_count','')::numeric,
      'window_days', nullif(s.value->>'momentum_window_days','')::int,
      'observed_at', s.observed_at, 'source','FASTMOSS', 'authority','REFERENCE_ONLY'))
    INTO v_momentum
  FROM public.commerce_signals s
  WHERE s.product_id=p_product AND s.user_id=v_uid AND s.signal_type='COMMERCE_SALES_MOMENTUM'
    AND upper(coalesce(s.value->>'market',''))=v_mkt
  ORDER BY s.observed_at DESC LIMIT 1;

  -- Reviews: only when a genuine review_count exists (empty review responses never surface).
  SELECT jsonb_build_object('review_count', (s.value->>'review_count')::numeric,
      'avg_rating', nullif(s.value->>'avg_rating','')::numeric, 'observed_at', s.observed_at,
      'source','FASTMOSS','authority','REFERENCE_ONLY')
    INTO v_reviews
  FROM public.commerce_signals s
  WHERE s.product_id=p_product AND s.user_id=v_uid AND s.signal_type='MARKETPLACE_REVIEW_EVIDENCE'
    AND upper(coalesce(s.value->>'market',''))=v_mkt AND nullif(s.value->>'review_count','') IS NOT NULL
  ORDER BY s.observed_at DESC LIMIT 1;

  -- Creators: only when a genuine creator_count exists -> EXCLUDES the spurious empty-creator row.
  SELECT jsonb_build_object('creator_count', (s.value->>'creator_count')::numeric, 'observed_at', s.observed_at,
      'source','FASTMOSS','authority','REFERENCE_ONLY')
    INTO v_creators
  FROM public.commerce_signals s
  WHERE s.product_id=p_product AND s.user_id=v_uid AND s.signal_type='COMMUNITY_CREATOR_EVIDENCE'
    AND upper(coalesce(s.value->>'market',''))=v_mkt AND nullif(s.value->>'creator_count','') IS NOT NULL
  ORDER BY s.observed_at DESC LIMIT 1;

  RETURN jsonb_build_object('status','ok','product_id',p_product,'market',v_mkt,
    'discovery_lanes', v_lane_keys, 'lanes', v_lanes,
    'momentum', v_momentum, 'reviews', v_reviews, 'creators', v_creators,
    'source_freshness', v_fresh, 'authority','REFERENCE_ONLY',
    'invariants', jsonb_build_object('identity_server_owned_auth_uid', true, 'country_isolated', true,
      'empty_or_unknown_signals_excluded', true, 'display_only_never_unlocks_actions', true),
    'contract','pulse_product_discovery_lanes_v1');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_product_discovery_lanes(uuid,uuid,text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_product_discovery_lanes_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  OWNER_T uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  KRIPPEN uuid := '5bc29d0a-b8e0-4fa9-bb80-d77197d770c4';
  MULTI uuid; checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0; ok boolean;
  r_k jsonb; r_m jsonb; r_x jsonb;
BEGIN
  SELECT id INTO MULTI FROM public.commerce_products
   WHERE user_id=OWNER_T AND jsonb_array_length(coalesce(extended->'fastmoss_discovery_lanes','[]'::jsonb))>=2 LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER_T)::text, true);

  -- Krippen: momentum present (mig_308), creators EXCLUDED (spurious null row), authority REFERENCE_ONLY
  r_k := public.fn_product_discovery_lanes(NULL, KRIPPEN, 'DE');
  ok := (r_k->>'status'='ok') AND (r_k->'creators'='null'::jsonb OR r_k->'creators' IS NULL)
        AND (r_k->>'authority'='REFERENCE_ONLY');
  checks := checks || jsonb_build_object('check','KRIPPEN_SPURIOUS_CREATOR_EXCLUDED','ok',ok,'creators',coalesce(r_k->'creators','null'::jsonb)); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  ok := (r_k->'momentum' IS NOT NULL AND r_k->'momentum' <> 'null'::jsonb) AND ((r_k->'momentum'->>'units_sold') IS NOT NULL);
  checks := checks || jsonb_build_object('check','KRIPPEN_MOMENTUM_PRESENT','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- A multi-lane product: >=2 distinct lanes with sales evidence, country-isolated
  IF MULTI IS NOT NULL THEN
    r_m := public.fn_product_discovery_lanes(NULL, MULTI, 'DE');
    ok := (jsonb_array_length(r_m->'discovery_lanes') >= 2) AND (jsonb_array_length(r_m->'lanes') >= 2)
          AND (r_m->'lanes'->0->>'source'='FASTMOSS');
  ELSE ok := false; END IF;
  checks := checks || jsonb_build_object('check','MULTI_LANE_EVIDENCE_PRESENT','ok',ok,'lanes',coalesce(r_m->'discovery_lanes','null'::jsonb)); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- JP (no DE evidence) -> empty lanes (country isolation)
  r_m := public.fn_product_discovery_lanes(NULL, coalesce(MULTI,KRIPPEN), 'JP');
  ok := (jsonb_array_length(r_m->'discovery_lanes')=0) AND (r_m->'momentum'='null'::jsonb OR r_m->'momentum' IS NULL);
  checks := checks || jsonb_build_object('check','COUNTRY_ISOLATION_JP_EMPTY','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- cross-tenant denied
  PERFORM set_config('request.jwt.claims', json_build_object('sub','2f000000-0000-4000-a000-000000002999')::text, true);
  r_x := public.fn_product_discovery_lanes(NULL, KRIPPEN, 'DE');
  ok := (r_x->>'status'='unauthorized') AND (jsonb_array_length(r_x->'discovery_lanes')=0);
  checks := checks || jsonb_build_object('check','CROSS_TENANT_DENIED','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  PERFORM set_config('request.jwt.claims', '', true);

  RETURN jsonb_build_object('contract','pulse_product_discovery_lanes_selftest_v1',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),'checks',checks,'generated_at',now());
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_discovery_lanes_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_product_discovery_lanes_selftest() TO service_role;

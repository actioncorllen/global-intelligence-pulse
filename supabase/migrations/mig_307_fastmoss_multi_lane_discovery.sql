-- mig_307_fastmoss_multi_lane_discovery.sql
--
-- Upgrade FastMoss Product Discovery from ONE strategy (New Listed) to THREE DISTINCT,
-- source-attributed discovery lanes using the verified ranking APIs:
--   NEW_LISTED     -> POST /product/v1/rank/newListed    (early emergence; day3 units)
--   TOP_SELLING    -> POST /product/v1/rank/topSelling   (established demand; monthly GMV)
--   MOST_PROMOTED  -> POST /product/v1/rank/mostPromoted (affiliate/creator promotion momentum)
--
-- Lanes are kept DISTINCT and source-attributed (distinct acquisition_method, distinct signal
-- dedup key, distinct evidence claim, lane tag on the normalized signal, and an
-- extended.fastmoss_discovery_lanes[] array) but CONVERGE on product identity: a product found
-- in several lanes is ONE product carrying several distinct lane signals — never duplicated, and
-- never equated to a concrete SKU (identity_basis stays 'platform_id'; concrete supplier identity
-- remains Stage-2's job). Kalodata and every other lane are untouched. 18-market eligibility,
-- tenant isolation, multilingual product-entity screening, source freshness, Product Asset Lock
-- (REFERENCE_ONLY covers only) and provider budgets (bounded pagesize; per-strategy enable flags)
-- are all preserved. UNKNOWN is never 0.

-- ---------------------------------------------------------------------------
-- 1. Strategy registry — the three distinct FastMoss discovery lanes (data-driven)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fastmoss_discovery_strategy (
  strategy            text PRIMARY KEY,                 -- NEW_LISTED | TOP_SELLING | MOST_PROMOTED
  label               text NOT NULL,
  api_path            text NOT NULL,                    -- e.g. /product/v1/rank/topSelling
  orderby_field       text NOT NULL,
  orderby_order       text NOT NULL DEFAULT 'desc',
  date_type           text NOT NULL,                    -- 'day' | 'month'
  date_offset_days    int,                              -- for date_type='day' (value = N days ago, UTC)
  default_category_id int,                              -- NULL => broad (all categories)
  acquisition_method  text NOT NULL,                    -- fastmoss_new_listed | fastmoss_top_selling | fastmoss_most_promoted
  enabled             boolean NOT NULL DEFAULT true,
  note                text,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fastmoss_discovery_strategy_date_type_chk CHECK (date_type IN ('day','month')),
  CONSTRAINT fastmoss_discovery_strategy_order_chk CHECK (orderby_order IN ('asc','desc'))
);

INSERT INTO public.fastmoss_discovery_strategy
  (strategy, label, api_path, orderby_field, orderby_order, date_type, date_offset_days, default_category_id, acquisition_method, enabled, note)
VALUES
  ('NEW_LISTED','New Listed (early emergence)','/product/v1/rank/newListed','day3_units_sold','desc','day',3,NULL,'fastmoss_new_listed',true,
     'Early product-native emergence; date_info day = 3 days ago (UTC). Unchanged from the original lane.'),
  ('TOP_SELLING','Top Selling','/product/v1/rank/topSelling','gmv','desc','month',NULL,NULL,'fastmoss_top_selling',true,
     'Established TikTok-Shop demand by monthly GMV; broad (all categories) unless a default_category_id is set.'),
  ('MOST_PROMOTED','Most Promoted','/product/v1/rank/mostPromoted','affiliate_count','desc','month',NULL,NULL,'fastmoss_most_promoted',true,
     'Products with the strongest affiliate/creator promotion momentum (affiliate_count).')
ON CONFLICT (strategy) DO NOTHING;

REVOKE ALL ON public.fastmoss_discovery_strategy FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.fastmoss_discovery_strategy TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Localized price parser (TikTok-Shop real_price is a display string, e.g. "28,95 €")
--    Honest: returns NULL when it cannot parse a clean number (UNKNOWN, never 0).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_parse_localized_price(p_text text)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE v text := btrim(coalesce(p_text,''));
BEGIN
  IF v = '' THEN RETURN NULL; END IF;
  v := regexp_replace(v, '[^0-9,.\-]', '', 'g');       -- strip currency symbols/letters/spaces
  IF v = '' THEN RETURN NULL; END IF;
  IF position(',' in v) > 0 AND position('.' in v) > 0 THEN
    IF position('.' in v) > position(',' in v) THEN     -- US: 1,234.56 -> comma = thousands
      v := replace(v, ',', '');
    ELSE                                                -- EU: 1.234,56 -> dot = thousands, comma = decimal
      v := replace(v, '.', ''); v := replace(v, ',', '.');
    END IF;
  ELSIF position(',' in v) > 0 THEN
    IF v ~ ',[0-9]{1,2}$' THEN v := replace(v, ',', '.');  -- "28,95" -> decimal comma
    ELSE v := replace(v, ',', ''); END IF;                 -- "1,234" -> thousands
  END IF;
  IF v ~ '^-?[0-9]+(\.[0-9]+)?$' THEN RETURN v::numeric; END IF;
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.fn_parse_localized_price(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_parse_localized_price(text) TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Request builder — now strategy-parameterized. The 1-arg form stays (NEW_LISTED)
--    for backward compatibility (edge fn + multi-lane plan call it today).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_fastmoss_discovery_request(p_market text, p_strategy text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  c record; s record;
  v_strat text := upper(btrim(coalesce(p_strategy,'NEW_LISTED')));
  v_filter jsonb; v_value text;
BEGIN
  SELECT * INTO s FROM public.fastmoss_discovery_strategy WHERE strategy=v_strat AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'provider','FASTMOSS','strategy',v_strat,'reason','UNKNOWN_OR_DISABLED_STRATEGY');
  END IF;
  SELECT * INTO c FROM public.discovery_provider_market_config
    WHERE provider='FASTMOSS' AND market=upper(btrim(coalesce(p_market,''))) AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'provider','FASTMOSS','strategy',v_strat,
      'market',upper(coalesce(p_market,'')),'reason','UNSUPPORTED_MARKET');
  END IF;

  IF s.date_type='day' THEN
    v_value := to_char(((now() AT TIME ZONE 'UTC')::date - coalesce(s.date_offset_days,3)), 'YYYY-MM-DD');
  ELSE  -- month: last completed calendar month (UTC)
    v_value := to_char((date_trunc('month', (now() AT TIME ZONE 'UTC')) - interval '1 day'), 'YYYY-MM');
  END IF;

  v_filter := jsonb_build_object('region', c.region,
    'date_info', jsonb_build_object('type', s.date_type, 'value', v_value));
  IF s.default_category_id IS NOT NULL THEN
    v_filter := v_filter || jsonb_build_object('category_id', s.default_category_id);
  END IF;

  RETURN jsonb_build_object('ok',true,'provider','FASTMOSS','strategy',v_strat,'acquisition_method',s.acquisition_method,
    'market',c.market,'region',c.region,'currency',c.currency,
    'endpoint','POST https://openapi.fastmoss.com'||s.api_path,
    'api_path', s.api_path,
    'request_body', jsonb_build_object(
      'filter', v_filter,
      'orderby', jsonb_build_array(jsonb_build_object('field', s.orderby_field, 'order', s.orderby_order)),
      'page', 1, 'pagesize', 10),
    'date_rule', s.date_type||'; derived UTC, not hardcoded',
    'note','product-native ranking discovery; candidates only, never opportunity. No keyword/category/product/shop/creator/video seed.',
    'contract','pulse_fastmoss_request_v3');
END; $function$;

-- Backward-compatible 1-arg wrapper (NEW_LISTED). Kept byte-compatible for existing callers.
CREATE OR REPLACE FUNCTION public.fn_fastmoss_discovery_request(p_market text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT public.fn_fastmoss_discovery_request(p_market, 'NEW_LISTED');
$function$;

REVOKE ALL ON FUNCTION public.fn_fastmoss_discovery_request(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_discovery_request(text,text) TO service_role;
REVOKE ALL ON FUNCTION public.fn_fastmoss_discovery_request(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_discovery_request(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Ingest — strategy-parameterized, source-attributed, identity-safe, converging.
--    Published as a NEW function name (…_ml) rather than replacing the 6-arg legacy form:
--    DROP FUNCTION on this Supabase project fires a sql_drop event trigger (schema reload)
--    that stalls on the large schema, so we add a 7-arg `_ml` form the edge fn v4 calls and
--    leave the 6-arg legacy function intact (dormant; no DROP needed, no behaviour change).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_fastmoss_ingest_candidates_ml(
  p_user_id uuid, p_market text, p_run_id uuid, p_candidate_limit integer, p_products jsonb,
  p_dry_run boolean DEFAULT false, p_strategy text DEFAULT 'NEW_LISTED')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_strat text := upper(btrim(coalesce(p_strategy,'NEW_LISTED')));
  s record; v_cfg record; v_run uuid := p_run_id; v_member uuid;
  v_cap int := greatest(1, least(coalesce(p_candidate_limit,10), 25));
  v_promoted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb;
  v_scanned int := 0; v_qualified int := 0; v_promoted_n int := 0;
  v_new int := 0; v_branded int := 0; v_correlated int := 0; v_idempotent int := 0;
  r record; v_raw jsonb; v_norm jsonb; v_name text; v_kid text; v_gate jsonb; v_brand jsonb;
  v_family text; v_screen text; v_pid uuid; v_ing jsonb; v_existing uuid; v_fam_existing uuid;
  v_auto jsonb; v_price numeric; v_dedup text; v_dispatch boolean; v_evidence jsonb;
  v_units text; v_rev text; v_growth text; v_affil text; v_dedup_key text; v_cat text;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','missing_user'); END IF;
  SELECT * INTO s FROM public.fastmoss_discovery_strategy WHERE strategy=v_strat;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','FAILED','reason','unknown_strategy','strategy',v_strat); END IF;
  SELECT * INTO v_cfg FROM public.discovery_provider_market_config
    WHERE provider='FASTMOSS' AND market=v_mkt AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','provider','FASTMOSS','market',v_mkt,'strategy',v_strat,
      'note','FastMoss does not support this market in discovery_provider_market_config; no substitution, no contamination');
  END IF;
  IF jsonb_typeof(p_products) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('status','PROVIDER_UNAVAILABLE','market',v_mkt,'strategy',v_strat,'note','no product array supplied by provider adapter');
  END IF;
  IF jsonb_array_length(p_products) = 0 THEN
    RETURN jsonb_build_object('status','SUCCESS_ZERO_CANDIDATES','market',v_mkt,'strategy',v_strat,'scanned',0,'promoted_count',0);
  END IF;
  IF v_run IS NULL AND NOT p_dry_run THEN
    SELECT id INTO v_member FROM public.member WHERE auth_user_id=p_user_id LIMIT 1;
    IF v_member IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','no_member'); END IF;
    v_run := gen_random_uuid();
    INSERT INTO public.discovery_runs (id, user_id, member_id, run_status, entry_mode, contract_version, raw_contract, created_at, completed_at)
    VALUES (v_run, p_user_id, v_member, 'completed', 'no_store_yet', 1,
      jsonb_build_object('discovery_source','fastmoss','lane','COMMERCE','discovery_lane',v_strat,'provider','FASTMOSS','market',v_mkt,
        'acquisition_method',s.acquisition_method,
        'capability','PRODUCT_NATIVE_COMMERCE_DISCOVERY','contract','fastmoss_commerce_discovery_v2'), now(), now());
  END IF;

  FOR r IN SELECT e FROM jsonb_array_elements(p_products) e LOOP
    EXIT WHEN v_promoted_n >= v_cap;
    v_scanned := v_scanned + 1;
    BEGIN
      v_name := btrim(coalesce(r.e->>'title', r.e->>'product_name',''));
      v_kid  := nullif(btrim(coalesce(r.e->>'product_id','')),'');
      IF v_name='' OR v_kid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','missing_name_or_id')); CONTINUE; END IF;
      v_gate := public.fn_is_product_native_entity(v_name);
      IF (v_gate->>'verdict') <> 'ACCEPT' THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'reason','not_product_entity')); CONTINUE; END IF;
      v_qualified := v_qualified + 1;
      v_family := public.fn_product_family_key(v_name);
      v_brand := public.fn_is_branded_or_ip_sensitive(v_name);
      v_screen := v_brand->>'screening_state';
      v_dispatch := NOT (v_brand->>'flagged')::boolean;

      -- Per-strategy metric mapping (UNKNOWN stays NULL; never coerced to 0).
      IF v_strat = 'NEW_LISTED' THEN
        v_units := r.e->>'day3_units_sold'; v_rev := r.e->>'day3_gmv'; v_growth := NULL; v_affil := NULL;
        v_price := CASE WHEN (r.e->>'real_price') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r.e->>'real_price')::numeric
                        ELSE public.fn_parse_localized_price(r.e->>'real_price') END;
      ELSIF v_strat = 'TOP_SELLING' THEN
        v_units := r.e->>'units_sold'; v_rev := r.e->>'gmv'; v_growth := r.e->>'units_sold_growth_rate'; v_affil := NULL;
        v_price := public.fn_parse_localized_price(r.e->>'real_price');
      ELSE  -- MOST_PROMOTED
        v_units := r.e->>'units_sold'; v_rev := r.e->>'gmv'; v_growth := NULL; v_affil := r.e->>'affiliate_count';
        v_price := public.fn_parse_localized_price(r.e->>'real_price');
      END IF;

      -- category can be a string (newListed) or an {l1,l2,l3} object (top/promoted).
      v_cat := CASE WHEN jsonb_typeof(r.e->'category')='object'
                    THEN nullif(btrim(coalesce(r.e->'category'->'l1'->>'name','')),'')
                    ELSE nullif(btrim(coalesce(r.e->>'category','')),'') END;

      v_raw := jsonb_strip_nulls(jsonb_build_object('product_identity',v_name,
        'revenue', v_rev, 'sales_units', v_units, 'sales_growth_rate', v_growth,
        'creator_count', v_affil,   -- affiliates promoting the product are creators (MOST_PROMOTED)
        'price', (v_price)::text, 'cross_market_reference', false));
      v_norm := public.fn_discovery_signal_normalize('COMMERCE','fastmoss',v_mkt,v_raw)
                || jsonb_build_object('fastmoss_strategy', v_strat);  -- distinct source tag on the signal
      v_dedup_key := 'fastmoss:'||v_kid||':'||v_mkt||':'||lower(v_strat);

      IF p_dry_run THEN
        v_promoted := v_promoted || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,
          'strategy',v_strat,'acquisition_method',s.acquisition_method,'normalized',v_norm,
          'screening_state',v_screen,'product_family_key',v_family,'observed_unit_price',v_price,
          'dedup_key',v_dedup_key,'auto_dispatch_eligible',v_dispatch,'dry_run',true));
        v_promoted_n := v_promoted_n + 1; CONTINUE;
      END IF;

      v_evidence := jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'claim','TikTok Shop '||s.label||' product-native commerce signal ('||v_mkt||') from FastMoss '||s.api_path,
        'source_name','fastmoss','discovery_lane',v_strat,'provenance','PLATFORM_REPORTED',
        'seller', jsonb_strip_nulls(jsonb_build_object('seller_id', nullif(btrim(coalesce(r.e->'shop'->>'seller_id','')),''),
          'name', nullif(btrim(coalesce(r.e->'shop'->>'name','')),''),
          'seller_total_units_sold', r.e->'shop'->>'total_units_sold')),
        'provider_totals', jsonb_strip_nulls(jsonb_build_object('total_units_sold', r.e->>'total_units_sold',
          'total_gmv', r.e->>'total_gmv','growth_rate', r.e->>'growth_rate','units_sold_growth_rate', r.e->>'units_sold_growth_rate',
          'affiliate_count', r.e->>'affiliate_count','total_affiliate_count', r.e->>'total_affiliate_count',
          'commission_rate', r.e->>'commission_rate')),
        'real_price_raw', r.e->>'real_price','launch_time_raw', r.e->>'launch_time','category', r.e->'category')));

      SELECT id INTO v_existing FROM public.commerce_products
        WHERE user_id=p_user_id AND extended->>'fastmoss_product_id'=v_kid ORDER BY created_at LIMIT 1;
      SELECT id INTO v_fam_existing FROM public.commerce_products
        WHERE user_id=p_user_id AND extended->>'product_family_key'=v_family
          AND extended->>'market'=v_mkt AND (v_existing IS NULL) ORDER BY created_at LIMIT 1;
      IF v_existing IS NOT NULL THEN
        v_pid := v_existing; v_dedup := 'idempotent_existing'; v_idempotent := v_idempotent + 1;
        -- record this lane on an already-discovered product (convergence; distinct lane evidence follows)
        UPDATE public.commerce_products SET extended = coalesce(extended,'{}'::jsonb) || jsonb_build_object(
          'fastmoss_discovery_lanes',
          (SELECT jsonb_agg(DISTINCT x) FROM jsonb_array_elements_text(
             coalesce(extended->'fastmoss_discovery_lanes','[]'::jsonb) || jsonb_build_array(v_strat)) x))
          WHERE id=v_pid;
      ELSIF v_fam_existing IS NOT NULL THEN
        v_pid := v_fam_existing; v_dedup := 'correlated_existing'; v_correlated := v_correlated + 1;
        UPDATE public.commerce_products SET extended = coalesce(extended,'{}'::jsonb)
          || jsonb_build_object('fastmoss_correlated_ids',
               coalesce(extended->'fastmoss_correlated_ids','[]'::jsonb) || jsonb_build_array(v_kid))
          || jsonb_build_object('fastmoss_discovery_lanes',
             (SELECT jsonb_agg(DISTINCT x) FROM jsonb_array_elements_text(
                coalesce(extended->'fastmoss_discovery_lanes','[]'::jsonb) || jsonb_build_array(v_strat)) x))
          WHERE id=v_pid;
      ELSE
        v_ing := public.ingest_commerce_product(p_user_id, v_run,
          jsonb_build_object('title',v_name,'product_type','tiktok_shop_product','category','tiktok_shop',
            'source_store','fastmoss','provenance','PLATFORM_REPORTED','is_physical_sellable','true',
            'candidate_acquisition_method',s.acquisition_method,'source_family','product_native_commerce',
            'market',v_mkt),'INFERRED','candidate');
        v_pid := nullif(v_ing->>'product_id','')::uuid;
        IF v_pid IS NULL THEN
          v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','promotion_'||coalesce(v_ing->>'status','failed'))); CONTINUE; END IF;
        UPDATE public.commerce_products
          SET identity_basis='platform_id',
              observed_price=coalesce(observed_price, v_price),
              price_currency=coalesce(price_currency, v_cfg.currency),
              extended = coalesce(extended,'{}'::jsonb) || jsonb_build_object(
                'fastmoss_product_id', v_kid, 'product_family_key', v_family, 'market', v_mkt,
                'fastmoss_seller_id', nullif(btrim(coalesce(r.e->'shop'->>'seller_id','')),''),
                'fastmoss_seller_name', nullif(btrim(coalesce(r.e->'shop'->>'name','')),''),
                'fastmoss_discovery_lanes', jsonb_build_array(v_strat),
                'fastmoss_category', v_cat,
                'provider_product_native','FASTMOSS','screening_state',v_screen,
                'launch_time_raw', r.e->>'launch_time')
          WHERE id=v_pid;
        IF EXISTS (SELECT 1 FROM public.monday_opportunity_registry WHERE tenant_id=p_user_id AND product_id=v_pid) THEN
          UPDATE public.monday_opportunity_registry SET active=true,
            markets = CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(markets) m WHERE m->>'country'=v_mkt)
                           THEN markets ELSE markets || jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)) END
            WHERE tenant_id=p_user_id AND product_id=v_pid;
        ELSE
          INSERT INTO public.monday_opportunity_registry (id, tenant_id, product_id, markets, active, created_at)
          VALUES (gen_random_uuid(), p_user_id, v_pid, jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)), true, now());
        END IF;
        IF v_dispatch THEN v_dedup := 'new'; v_new := v_new + 1;
        ELSE v_dedup := 'new_branded_review'; v_branded := v_branded + 1; END IF;
      END IF;

      PERFORM public.fn_persist_reference_image(p_user_id, v_pid, v_mkt, 'FASTMOSS', v_kid, public.fn_extract_cover_url(r.e));
      -- distinct per-lane signal (distinct dedup key keeps NEW/TOP_SELLING/MOST_PROMOTED coexisting)
      PERFORM public.ingest_commerce_signal(p_user_id, v_pid, v_run, 'COMMERCE_PRODUCT_NATIVE',
        v_norm, v_evidence, 'PLATFORM_REPORTED', 0.6, now(), NULL, v_dedup_key);
      IF v_dedup = 'new' THEN
        BEGIN v_auto := public.fn_auto_dispatch_candidate_research(p_user_id, v_pid, v_mkt);
        EXCEPTION WHEN OTHERS THEN v_auto := jsonb_build_object('status','auto_dispatch_error','error',left(SQLERRM,160)); END;
      ELSE v_auto := jsonb_build_object('status','held_'||v_dedup); END IF;
      v_promoted_n := v_promoted_n + 1;
      v_promoted := v_promoted || jsonb_build_array(jsonb_build_object(
        'fastmoss_product_id',v_kid,'product_name',v_name,'product_id',v_pid,'dedup_status',v_dedup,
        'strategy',v_strat,'acquisition_method',s.acquisition_method,
        'screening_state',v_screen,'observed_unit_price',v_price,
        'research_auto_dispatch', coalesce(v_auto->>'status','skipped'),'research_run_id', v_auto->>'run_id'));
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','error:'||left(SQLERRM,140)));
    END;
  END LOOP;
  RETURN jsonb_build_object(
    'status', CASE WHEN v_promoted_n>0 THEN 'SUCCESS_WITH_CANDIDATES' ELSE 'SUCCESS_ZERO_CANDIDATES' END,
    'provider','FASTMOSS','lane','COMMERCE','discovery_lane',v_strat,'acquisition_method',s.acquisition_method,'market',v_mkt,'run_id',v_run,
    'scanned',v_scanned,'qualified',v_qualified,'promoted_count',v_promoted_n,
    'new_dispatched',v_new,'branded_review',v_branded,'correlated',v_correlated,'idempotent',v_idempotent,
    'promoted',v_promoted,'skipped',v_skipped,'dry_run',p_dry_run,
    'note','FastMoss ranking lane discovers product-native candidates only; lanes are distinct+source-attributed but converge on fastmoss_product_id. Identity/dedup + branded/IP review applied; provider cover persisted REFERENCE_ONLY. Provider record != product identity != seller != concrete SKU; UNKNOWN != 0; launch_time not authoritative; country-isolated.',
    'contract','pulse_fastmoss_commerce_ingest_v2');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_fastmoss_ingest_candidates_ml(uuid,text,uuid,integer,jsonb,boolean,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_ingest_candidates_ml(uuid,text,uuid,integer,jsonb,boolean,text) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Selftest (no provider call): request builder for 3 lanes, price parser, ingest
--    attribution (dry-run) with REAL captured rows, lane distinctness + convergence.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_fastmoss_multilane_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  OWNER_T uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0; ok boolean;
  r_new jsonb; r_top jsonb; r_mp jsonb; d_top jsonb; d_mp jsonb; el jsonb;
  sample_top jsonb; sample_mp jsonb;
BEGIN
  r_new := public.fn_fastmoss_discovery_request('DE','NEW_LISTED');
  r_top := public.fn_fastmoss_discovery_request('DE','TOP_SELLING');
  r_mp  := public.fn_fastmoss_discovery_request('DE','MOST_PROMOTED');

  ok := (r_new->>'api_path'='/product/v1/rank/newListed')
     AND (r_new->'request_body'->'orderby'->0->>'field'='day3_units_sold')
     AND (r_new->'request_body'->'filter'->'date_info'->>'type'='day');
  checks := checks || jsonb_build_object('check','NEW_LISTED_REQUEST','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  ok := (r_top->>'api_path'='/product/v1/rank/topSelling')
     AND (r_top->'request_body'->'orderby'->0->>'field'='gmv')
     AND (r_top->'request_body'->'filter'->'date_info'->>'type'='month')
     AND (r_top->>'acquisition_method'='fastmoss_top_selling');
  checks := checks || jsonb_build_object('check','TOP_SELLING_REQUEST','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  ok := (r_mp->>'api_path'='/product/v1/rank/mostPromoted')
     AND (r_mp->'request_body'->'orderby'->0->>'field'='affiliate_count')
     AND (r_mp->>'acquisition_method'='fastmoss_most_promoted');
  checks := checks || jsonb_build_object('check','MOST_PROMOTED_REQUEST','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- price parser
  ok := public.fn_parse_localized_price('28,95 €')=28.95
    AND public.fn_parse_localized_price('1,234.56')=1234.56
    AND public.fn_parse_localized_price('1.234,56')=1234.56
    AND public.fn_parse_localized_price('19.99')=19.99
    AND public.fn_parse_localized_price('abc') IS NULL;
  checks := checks || jsonb_build_object('check','LOCALIZED_PRICE_PARSE','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- REAL captured rows (DE), dry-run ingest attribution
  sample_top := jsonb_build_array(jsonb_build_object('product_id','1729813656293841847',
    'title','Stainless Steel Insulated Water Bottle','gmv',560078.5,'units_sold',19170,'units_sold_growth_rate',4826,
    'real_price','28,95 €','shop',jsonb_build_object('seller_id','7494542612017022903','name','Example Shop'),
    'category',jsonb_build_object('l1',jsonb_build_object('id',2,'name','Kitchenware')),'cover','https://s.500fd.com/x.jpeg'));
  sample_mp := jsonb_build_array(jsonb_build_object('product_id','1729813656293841847',
    'title','Stainless Steel Insulated Water Bottle','gmv',560078.5,'units_sold',19170,'affiliate_count',2061,'total_affiliate_count',1125,
    'real_price','28,95 €','shop',jsonb_build_object('seller_id','7494542612017022903','name','Example Shop'),
    'category',jsonb_build_object('l1',jsonb_build_object('id',2,'name','Kitchenware')),'cover','https://s.500fd.com/x.jpeg'));

  d_top := public.fn_fastmoss_ingest_candidates_ml(OWNER_T,'DE',NULL,5,sample_top,true,'TOP_SELLING');
  el := d_top->'promoted'->0;
  ok := (d_top->>'discovery_lane'='TOP_SELLING') AND (el->>'acquisition_method'='fastmoss_top_selling')
     AND ((el->>'observed_unit_price')::numeric=28.95)
     AND ((el->'normalized'->>'revenue')::numeric=560078.5)
     AND (el->'normalized'->>'fastmoss_strategy'='TOP_SELLING')
     AND (el->>'dedup_key'='fastmoss:1729813656293841847:DE:top_selling');
  checks := checks || jsonb_build_object('check','TOP_SELLING_INGEST_ATTRIBUTION','ok',ok,'price',el->>'observed_unit_price'); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  d_mp := public.fn_fastmoss_ingest_candidates_ml(OWNER_T,'DE',NULL,5,sample_mp,true,'MOST_PROMOTED');
  el := d_mp->'promoted'->0;
  ok := (d_mp->>'discovery_lane'='MOST_PROMOTED') AND (el->>'acquisition_method'='fastmoss_most_promoted')
     AND ((el->'normalized'->>'creator_count')::numeric=2061)   -- affiliates mapped to creators
     AND (el->>'dedup_key'='fastmoss:1729813656293841847:DE:most_promoted');
  checks := checks || jsonb_build_object('check','MOST_PROMOTED_INGEST_ATTRIBUTION','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- lane distinctness: same product id yields distinct dedup keys per lane (coexisting signals)
  ok := ((d_top->'promoted'->0->>'dedup_key') <> (d_mp->'promoted'->0->>'dedup_key'));
  checks := checks || jsonb_build_object('check','LANE_DEDUP_KEYS_DISTINCT','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- unsupported market fails closed (no contamination)
  ok := (public.fn_fastmoss_discovery_request('ZZ','TOP_SELLING')->>'reason'='UNSUPPORTED_MARKET');
  checks := checks || jsonb_build_object('check','UNSUPPORTED_MARKET_FAILS_CLOSED','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  RETURN jsonb_build_object('contract','pulse_fastmoss_multilane_selftest_v1',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),'checks',checks,'generated_at',now());
END; $function$;

REVOKE ALL ON FUNCTION public.fn_fastmoss_multilane_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_multilane_selftest() TO service_role;

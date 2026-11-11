-- ============================================================================
-- kalodata_commerce_lane_production_snapshot_2026-11-11.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A (Phase 5 — source-of-truth export)
--
-- PROVENANCE: reverse-engineered READ-ONLY from the live production project
-- "Strateloq Technologies" (ref nxaunmyihhjixxxljcqt) on 2026-11-11 via
-- pg_get_functiondef / information_schema. This is the AUTHORITATIVE definition of
-- the deployed Kalodata COMMERCE discovery lane, which was ABSENT from this git repo
-- (repo/production drift: the repo's migrations stop at mig_294 while production
-- references mig_336+). It is a REFERENCE SNAPSHOT, not a clean forward migration:
--   * It is NOT numbered into supabase/migrations/ and must not be blindly re-applied.
--   * Diff against production before any redeploy; the repo is many migrations behind.
--   * Dependencies on other production objects (discovery_runs, commerce_products,
--     member, monday_opportunity_registry, ingest_commerce_product,
--     ingest_commerce_signal, fn_is_product_native_entity, fn_discovery_signal_normalize,
--     fn_persist_reference_image, fn_extract_cover_url, fn_auto_dispatch_candidate_research,
--     fn_multi_lane_discovery_plan, fn_research_request_core, net.http_post) are NOT
--     included here and also live only in production.
--
-- WHAT THIS LANE DOES (authoritative behaviour):
--   * Edge function `kalodata-discovery` (see supabase/functions/kalodata-discovery/
--     index.ts) makes ONE chargeable POST to
--     https://www.kalodata.com/openapi/v1/tiktok/product/rank with the API key in a
--     header named `secret-key` (env KALODATA_SECRET_KEY; header overridable via
--     KALODATA_SECRET_HEADER; base via KALODATA_BASE_URL). Secret is read ONLY from
--     Edge env, never persisted/logged/returned.
--   * Market gating is `discovery_provider_market_config` (provider='KALODATA'); an
--     unsupported/disabled market returns UNSUPPORTED_MARKET — never substituted.
--   * Kalodata yields product-native CANDIDATES only (never a winner/opportunity).
--     Each candidate passes the existing eligibility + auto-research + evaluation
--     gates. The provider cover image is persisted as a REFERENCE_ONLY primary image
--     via fn_persist_reference_image — it does NOT enter product_image_assets /
--     supplier_product_assets / fn_resolve_product_image (asserted by the self-test).
--   * Credit/budget control is UPSTREAM (one paid call per request; authorize/reserve;
--     refund on failure) + usage recorded into discovery_runs via fn_kalodata_record_usage.
--
-- RECONCILIATION NOTE (repo migrations that DUPLICATE this and must be revised/withdrawn):
--   * mig_293 provider_capability_registry(KALODATA) || this lane gates markets via
--     discovery_provider_market_config (authoritative), not provider_capability_registry.
--   * mig_294 kalodata_cost_policy / fn_kalodata_budget_precheck / kalodata_api_usage_ledger
--     and mig_294 fn_kalodata_record_usage(5-arg) || this lane's upstream budget +
--     fn_kalodata_record_usage(p_run_id uuid, p_usage jsonb, p_endpoint text) (NAME COLLISION).
--   * mig_292 product_research_images lane || this lane's REFERENCE_ONLY image via
--     fn_persist_reference_image.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- TABLES (structure as deployed; RLS enabled, deny-by-default: no client policies)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kalodata_discovery_cursor (
  tenant_id  uuid NOT NULL,
  market     text NOT NULL,
  next_page  integer NOT NULL DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kalodata_discovery_cursor_pkey PRIMARY KEY (tenant_id, market),
  CONSTRAINT kalodata_discovery_cursor_next_page_check CHECK (next_page >= 1)
);
ALTER TABLE public.kalodata_discovery_cursor ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.kalodata_invoke_nonce (
  token      text NOT NULL,
  user_id    uuid,
  market     text,
  created_at timestamptz NOT NULL DEFAULT now(),
  used_at    timestamptz,
  CONSTRAINT kalodata_invoke_nonce_pkey PRIMARY KEY (token)
);
ALTER TABLE public.kalodata_invoke_nonce ENABLE ROW LEVEL SECURITY;

-- Shared discovery provider market config (Kalodata rows shown; table is provider-generic).
CREATE TABLE IF NOT EXISTS public.discovery_provider_market_config (
  provider         text NOT NULL,
  market           text NOT NULL,
  supported        boolean NOT NULL DEFAULT true,
  enabled          boolean NOT NULL DEFAULT true,
  region           text,
  language         text,
  currency         text,
  capabilities     jsonb NOT NULL DEFAULT '{}'::jsonb,
  note             text,
  last_verified_at timestamptz,
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- AUTHORITATIVE Kalodata market coverage as deployed (9 enabled; IE present-but-disabled).
-- Enabled: US, GB, DE, FR, ES, IT, MY, PH, SG. Disabled: IE. (Kalodata also covers MX, BR,
-- ID, TH, VN, JP at the provider, but Strateloq has NOT enabled those here.)
INSERT INTO public.discovery_provider_market_config (provider, market, supported, enabled, region, language, currency) VALUES
  ('KALODATA','US',true ,true ,'US','en-US','USD'),
  ('KALODATA','GB',true ,true ,'GB','en-US','GBP'),
  ('KALODATA','DE',true ,true ,'DE','en-US','EUR'),
  ('KALODATA','FR',true ,true ,'FR','en-US','EUR'),
  ('KALODATA','ES',true ,true ,'ES','en-US','EUR'),
  ('KALODATA','IT',true ,true ,'IT','en-US','EUR'),
  ('KALODATA','MY',true ,true ,'MY','en-US','MYR'),
  ('KALODATA','PH',true ,true ,'PH','en-US','PHP'),
  ('KALODATA','SG',true ,true ,'SG','en-US','SGD'),
  ('KALODATA','IE',false,false,'IE','en-US','EUR')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- FUNCTIONS (verbatim from production pg_get_functiondef, 2026-11-11)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_kalodata_advance_page(p_user_id uuid, p_market text, p_fetched_page integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_mkt text := upper(btrim(coalesce(p_market,''))); v_next int := greatest(1, coalesce(p_fetched_page,1)) + 1;
BEGIN
  INSERT INTO public.kalodata_discovery_cursor(tenant_id, market, next_page, updated_at)
  VALUES (p_user_id, v_mkt, v_next, now())
  ON CONFLICT (tenant_id, market) DO UPDATE
    SET next_page = greatest(public.kalodata_discovery_cursor.next_page, EXCLUDED.next_page), updated_at = now();
  RETURN (SELECT next_page FROM public.kalodata_discovery_cursor WHERE tenant_id=p_user_id AND market=v_mkt);
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_kalodata_consume_invoke_nonce(p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE ok boolean := false;
BEGIN
  IF p_token IS NULL OR length(p_token) < 32 THEN RETURN false; END IF;
  UPDATE public.kalodata_invoke_nonce
    SET used_at = now()
    WHERE token = p_token AND used_at IS NULL AND created_at > now() - interval '5 minutes'
    RETURNING true INTO ok;
  RETURN coalesce(ok, false);
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_kalodata_discovery_request(p_market text, p_page_number integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c record; v_page int := greatest(1, coalesce(p_page_number,1));
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
    'strategy','early_emerging','page_number',v_page,
    'request_body', jsonb_build_object('region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
      'date_range','last7Day','sort',jsonb_build_object('field','revenue_growth_rate','type','DESC'),
      'page_size',10,'page_number',v_page,'launch_date','<30'),
    'note','early/emerging bias: revenue_growth_rate DESC + recent launch; page_number advances to avoid re-buying the same results. Candidates only; not opportunity.',
    'contract','pulse_kalodata_request_v2_paged');
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_kalodata_next_page(p_user_id uuid, p_market text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ SELECT coalesce((SELECT next_page FROM public.kalodata_discovery_cursor
   WHERE tenant_id=p_user_id AND market=upper(btrim(coalesce(p_market,'')))), 1); $function$;

CREATE OR REPLACE FUNCTION public.fn_kalodata_record_lane_outcome(p_user_id uuid, p_market text, p_lane_status text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
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

CREATE OR REPLACE FUNCTION public.fn_kalodata_record_usage(p_run_id uuid, p_usage jsonb, p_endpoint text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  IF p_run_id IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','missing_run'); END IF;
  UPDATE public.discovery_runs
    SET raw_contract = coalesce(raw_contract,'{}'::jsonb) || jsonb_build_object(
      'provider_usage', p_usage, 'provider_endpoint', p_endpoint, 'provider_usage_at', now())
    WHERE id = p_run_id;
  RETURN jsonb_build_object('ok', FOUND, 'run_id', p_run_id);
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_kalodata_run_discovery(p_user_id uuid, p_market text, p_candidate_limit integer, p_anon_key text, p_page_number integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_token text := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_req bigint; v_mkt text := upper(btrim(coalesce(p_market,''))); v_page int;
  v_url text := 'https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/kalodata-discovery';
BEGIN
  IF p_user_id IS NULL OR v_mkt='' OR coalesce(btrim(p_anon_key),'')='' THEN RETURN jsonb_build_object('ok',false,'reason','missing_args'); END IF;
  v_page := greatest(1, coalesce(p_page_number, public.fn_kalodata_next_page(p_user_id, v_mkt)));
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market) VALUES (v_token,p_user_id,v_mkt);
  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('market',v_mkt,'user_id',p_user_id,'candidate_limit',greatest(1,least(coalesce(p_candidate_limit,10),25)),'page_number',v_page),
    headers := jsonb_build_object('Content-Type','application/json','apikey',p_anon_key,'Authorization','Bearer '||p_anon_key,'x-pulse-nonce',v_token),
    timeout_milliseconds := 30000
  ) INTO v_req;
  PERFORM public.fn_kalodata_advance_page(p_user_id, v_mkt, v_page);
  RETURN jsonb_build_object('ok',true,'request_id',v_req,'market',v_mkt,'page_number',v_page,'next_page',public.fn_kalodata_next_page(p_user_id, v_mkt));
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_kalodata_ingest_candidates(p_user_id uuid, p_market text, p_run_id uuid, p_candidate_limit integer, p_products jsonb, p_dry_run boolean DEFAULT false, p_suppress_auto_research boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_cfg record; v_run uuid := p_run_id; v_member uuid;
  v_cap int := greatest(1, least(coalesce(p_candidate_limit,10), 25));
  v_promoted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb;
  v_scanned int := 0; v_qualified int := 0; v_promoted_n int := 0;
  r record; v_raw jsonb; v_norm jsonb; v_name text; v_kid text; v_gate jsonb;
  v_pid uuid; v_ing jsonb; v_dedup text; v_existing uuid; v_auto jsonb; v_price numeric;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','missing_user'); END IF;
  SELECT * INTO v_cfg FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','provider','KALODATA','market',v_mkt,
      'note','Kalodata does not support this market in discovery_provider_market_config; no substitution, no contamination');
  END IF;
  IF jsonb_typeof(p_products) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('status','PROVIDER_UNAVAILABLE','market',v_mkt,'note','no product array supplied by provider adapter');
  END IF;
  IF jsonb_array_length(p_products) = 0 THEN
    RETURN jsonb_build_object('status','SUCCESS_ZERO_CANDIDATES','market',v_mkt,'scanned',0,'promoted_count',0);
  END IF;
  IF v_run IS NULL AND NOT p_dry_run THEN
    SELECT id INTO v_member FROM public.member WHERE auth_user_id=p_user_id LIMIT 1;
    IF v_member IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','no_member'); END IF;
    v_run := gen_random_uuid();
    INSERT INTO public.discovery_runs (id, user_id, member_id, run_status, entry_mode, contract_version, raw_contract, created_at, completed_at)
    VALUES (v_run, p_user_id, v_member, 'completed', 'no_store_yet', 1,
      jsonb_build_object('discovery_source','kalodata','lane','COMMERCE','provider','KALODATA','market',v_mkt,
        'capability','PRODUCT_NATIVE_COMMERCE_DISCOVERY','contract','kalodata_commerce_discovery_v1'), now(), now());
  END IF;
  FOR r IN SELECT e FROM jsonb_array_elements(p_products) e LOOP
    EXIT WHEN v_promoted_n >= v_cap;
    v_scanned := v_scanned + 1;
    BEGIN
      v_name := btrim(coalesce(r.e->>'product_name',''));
      v_kid  := nullif(btrim(coalesce(r.e->>'product_id','')),'');
      IF v_name='' OR v_kid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','missing_name_or_id')); CONTINUE; END IF;
      v_gate := public.fn_is_product_native_entity(v_name);
      IF (v_gate->>'verdict') <> 'ACCEPT' THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'reason','not_product_entity','gate',v_gate->'reasons')); CONTINUE; END IF;
      v_qualified := v_qualified + 1;
      v_raw := jsonb_build_object('product_identity',v_name,'revenue',r.e->>'revenue',
        'revenue_growth_rate',r.e->>'revenue_growth_rate','sales_units',r.e->>'sales_volumn',
        'price',r.e->>'unit_price','first_seen',r.e->>'launch_date','cross_market_reference',false);
      v_norm := public.fn_discovery_signal_normalize('COMMERCE','kalodata',v_mkt,v_raw);
      v_price := CASE WHEN (r.e->>'unit_price') ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN (r.e->>'unit_price')::numeric END;
      IF p_dry_run THEN
        v_promoted := v_promoted || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'normalized',v_norm,'dry_run',true));
        v_promoted_n := v_promoted_n + 1; CONTINUE;
      END IF;
      SELECT id INTO v_existing FROM public.commerce_products
        WHERE user_id=p_user_id AND extended->>'kalodata_product_id'=v_kid ORDER BY created_at LIMIT 1;
      v_ing := public.ingest_commerce_product(p_user_id, v_run,
        jsonb_build_object('title',v_name,'product_type','tiktok_shop_product','category','tiktok_shop',
          'source_store','kalodata','provenance','PLATFORM_REPORTED','is_physical_sellable','true',
          'candidate_acquisition_method','kalodata_product_rank','source_family','product_native_commerce',
          'market',v_mkt),'INFERRED','candidate');
      v_pid := nullif(v_ing->>'product_id','')::uuid;
      IF v_pid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','promotion_'||coalesce(v_ing->>'status','failed'))); CONTINUE; END IF;
      UPDATE public.commerce_products
        SET identity_basis='platform_id',
            observed_price=coalesce(observed_price, v_price),
            price_currency=coalesce(price_currency, v_cfg.currency),
            extended = coalesce(extended,'{}'::jsonb) || jsonb_build_object(
              'kalodata_product_id', v_kid, 'kalodata_seller_id', nullif(btrim(coalesce(r.e->>'seller_id','')),''),
              'kalodata_seller_name', nullif(btrim(coalesce(r.e->>'seller_name','')),''),
              'provider_product_native','KALODATA')
        WHERE id=v_pid;
      PERFORM public.fn_persist_reference_image(p_user_id, v_pid, v_mkt, 'KALODATA', v_kid, public.fn_extract_cover_url(r.e));
      PERFORM public.ingest_commerce_signal(p_user_id, v_pid, v_run, 'COMMERCE_PRODUCT_NATIVE',
        v_norm,
        jsonb_build_array(jsonb_build_object('claim','TikTok Shop product-native commerce signal ('||v_mkt||') from Kalodata product rank',
          'source_name','kalodata','provenance','PLATFORM_REPORTED',
          'channel_revenue', jsonb_strip_nulls(jsonb_build_object(
            'live_revenue', r.e->>'live_revenue','video_revenue', r.e->>'video_revenue','showcase_revenue', r.e->>'showcase_revenue')))),
        'PLATFORM_REPORTED', 0.6, now(), NULL,
        'kalodata:'||v_kid||':'||v_mkt||':commerce_product_native');
      IF EXISTS (SELECT 1 FROM public.monday_opportunity_registry WHERE tenant_id=p_user_id AND product_id=v_pid) THEN
        UPDATE public.monday_opportunity_registry SET active=true,
          markets = CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(markets) m WHERE m->>'country'=v_mkt)
                         THEN markets ELSE markets || jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)) END
          WHERE tenant_id=p_user_id AND product_id=v_pid;
      ELSE
        INSERT INTO public.monday_opportunity_registry (id, tenant_id, product_id, markets, active, created_at)
        VALUES (gen_random_uuid(), p_user_id, v_pid, jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)), true, now());
      END IF;
      IF p_suppress_auto_research THEN
        v_auto := jsonb_build_object('status','AUTO_RESEARCH_SUPPRESSED',
          'note','customer Refresh Discovery: deep per-candidate research not auto-initiated; available only via the existing separately-authorized, budget-gated research workflow; no paid research call');
      ELSE
        BEGIN v_auto := public.fn_auto_dispatch_candidate_research(p_user_id, v_pid, v_mkt);
        EXCEPTION WHEN OTHERS THEN v_auto := jsonb_build_object('status','auto_dispatch_error','error',left(SQLERRM,160)); END;
      END IF;
      v_promoted_n := v_promoted_n + 1;
      v_promoted := v_promoted || jsonb_build_array(jsonb_build_object(
        'kalodata_product_id',v_kid,'product_name',v_name,'product_id',v_pid,
        'dedup_status', CASE WHEN v_existing IS NULL THEN 'new' ELSE 'deduplicated' END,
        'observed_unit_price', v_price, 'research_auto_dispatch', coalesce(v_auto->>'status','skipped'),
        'research_run_id', v_auto->>'run_id'));
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','error:'||left(SQLERRM,140)));
    END;
  END LOOP;
  RETURN jsonb_build_object(
    'status', CASE WHEN v_promoted_n>0 THEN 'SUCCESS_WITH_CANDIDATES' ELSE 'SUCCESS_ZERO_CANDIDATES' END,
    'provider','KALODATA','lane','COMMERCE','market',v_mkt,'run_id',v_run,
    'scanned',v_scanned,'qualified',v_qualified,'promoted_count',v_promoted_n,
    'promoted',v_promoted,'skipped',v_skipped,'dry_run',p_dry_run,
    'auto_research_suppressed', p_suppress_auto_research,
    'note','Kalodata discovers product-native candidates only; each passes the existing eligibility + auto-research + concrete-resolution + evaluation gates; cover persisted as REFERENCE_ONLY primary image when the entitled rank response carries one. Provider record != concrete SKU; UNKNOWN != 0; country-isolated.',
    'contract','pulse_kalodata_commerce_ingest_v1');
END; $function$;

-- Self-test (17 checks). Depends on fn_multi_lane_discovery_plan, fn_research_request_core,
-- fn_discovery_signal_normalize and seed tenant data in production.
CREATE OR REPLACE FUNCTION public.fn_kalodata_commerce_adapter_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; n_fail int;
  uid uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid;
  prods jsonb := '[{"product_id":"kd_sel_1","product_name":"Mini Neck Fan","revenue":"1000","revenue_growth_rate":"4190.39","sales_volumn":"22","unit_price":"26.16","launch_date":"2026-09-20","live_revenue":"300","video_revenue":"500","showcase_revenue":"200","master_image_url":"https://x/y.jpg","seller_id":"s1","seller_name":"ACME","sku_count":"3"},{"product_id":"kd_sel_2","product_name":"Portable Blender Bottle","master_image_url":null,"seller_name":"","sku_count":null},{"product_id":"","product_name":"missing id"},{"product_id":"kd_sel_4","product_name":"the best cheap deals near me how to"}]'::jsonb;
  req_de jsonb; req_ie jsonb; plan_de jsonb; plan_gb jsonb; plan_no jsonb; plan_ie jsonb;
  dry_de jsonb; dry_ie jsonb; dry_de_empty jsonb; dry_de_nonarray jsonb;
  lane_de_com jsonb; lane_gb_com jsonb; lane_no_com jsonb; lane_no_search jsonb; lane_ie_com jsonb;
  pr_fan jsonb; pr_blender jsonb;
  d_ing text; d_core text; d_plan text; img boolean; has_pp boolean;
  ie_supported boolean; ie_enabled boolean; ie_in_enabled_set boolean;
BEGIN
  req_de := public.fn_kalodata_discovery_request('DE');
  req_ie := public.fn_kalodata_discovery_request('IE');
  plan_de := public.fn_multi_lane_discovery_plan('DE',5,uid);
  plan_gb := public.fn_multi_lane_discovery_plan('GB',5,NULL);
  plan_no := public.fn_multi_lane_discovery_plan('NO',5,NULL);
  plan_ie := public.fn_multi_lane_discovery_plan('IE',5,NULL);
  dry_de := public.fn_kalodata_ingest_candidates(uid,'DE',NULL,10,prods,true);
  dry_ie := public.fn_kalodata_ingest_candidates(uid,'IE',NULL,10,prods,true);
  dry_de_empty := public.fn_kalodata_ingest_candidates(uid,'DE',NULL,10,'[]'::jsonb,true);
  dry_de_nonarray := public.fn_kalodata_ingest_candidates(uid,'DE',NULL,10,'{}'::jsonb,true);
  SELECT e INTO lane_de_com FROM jsonb_array_elements(plan_de->'lanes') e WHERE e->>'lane'='COMMERCE';
  SELECT e INTO lane_gb_com FROM jsonb_array_elements(plan_gb->'lanes') e WHERE e->>'lane'='COMMERCE';
  SELECT e INTO lane_no_com FROM jsonb_array_elements(plan_no->'lanes') e WHERE e->>'lane'='COMMERCE';
  SELECT e INTO lane_no_search FROM jsonb_array_elements(plan_no->'lanes') e WHERE e->>'lane'='SEARCH';
  SELECT e INTO lane_ie_com FROM jsonb_array_elements(plan_ie->'lanes') e WHERE e->>'lane'='COMMERCE';
  SELECT e INTO pr_fan FROM jsonb_array_elements(dry_de->'promoted') e WHERE e->>'product_id'='kd_sel_1';
  SELECT e INTO pr_blender FROM jsonb_array_elements(dry_de->'promoted') e WHERE e->>'product_id'='kd_sel_2';
  SELECT supported, enabled INTO ie_supported, ie_enabled FROM public.discovery_provider_market_config WHERE provider='KALODATA' AND market='IE';
  ie_in_enabled_set := coalesce(ie_supported,false) AND coalesce(ie_enabled,false);
  SELECT pg_get_functiondef(p.oid) INTO d_ing FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_kalodata_ingest_candidates';
  SELECT pg_get_functiondef(p.oid) INTO d_core FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_research_request_core';
  SELECT pg_get_functiondef(p.oid) INTO d_plan FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_multi_lane_discovery_plan';
  SELECT bool_or(pg_get_functiondef(p.oid) ~* 'product_image_assets|supplier_product_assets|product_asset_intelligence|fn_resolve_product_image') INTO img
    FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public'
      AND p.proname IN ('fn_kalodata_ingest_candidates','fn_kalodata_discovery_request','fn_multi_lane_discovery_plan','fn_discovery_signal_normalize');
  SELECT ('p_products' = ANY(p.proargnames)) INTO has_pp FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_kalodata_ingest_candidates';

  v := v || jsonb_build_object('check','01_DE_INVOKES_KALODATA_NO_SEED','pass',
    ((req_de->>'ok')::boolean AND req_de->>'provider'='KALODATA' AND req_de->>'endpoint' ~* 'tiktok/product/rank'
     AND NOT (req_de->'request_body' ? 'keyword') AND NOT (req_de->'request_body' ? 'category_ids')
     AND NOT (req_de->'request_body' ? 'product_id') AND NOT (req_de->'request_body' ? 'shop_id')
     AND NOT (req_de->'request_body' ? 'creator_id') AND NOT (req_de->'request_body' ? 'video_id')
     AND NOT (req_de->'request_body' ? 'livestream_id')
     AND lane_de_com->>'status'='READY' AND lane_de_com->>'provider'='KALODATA'));
  v := v || jsonb_build_object('check','02_PRODUCT_BECOMES_CANDIDATE','pass',
    (dry_de->>'status'='SUCCESS_WITH_CANDIDATES' AND (dry_de->>'promoted_count')::int=2
     AND pr_fan IS NOT NULL AND pr_fan->'normalized'->>'product_identity'='Mini Neck Fan'));
  v := v || jsonb_build_object('check','03_COUNTRY_ISOLATION','pass',
    (req_de->'request_body'->>'region'='DE' AND req_de->'request_body'->>'currency'='EUR'
     AND lane_gb_com->'kalodata_request'->>'region'='GB'
     AND pr_fan->'normalized'->>'market'='DE' AND pr_blender->'normalized'->>'market'='DE'));
  v := v || jsonb_build_object('check','04_UNSUPPORTED_MARKET_EXPLICIT','pass',
    (req_ie->>'reason'='UNSUPPORTED_MARKET' AND dry_ie->>'status'='UNSUPPORTED_MARKET'
     AND NOT (dry_ie ? 'promoted') AND lane_no_com->>'status'='UNSUPPORTED_MARKET'));
  v := v || jsonb_build_object('check','05_UNKNOWN_NOT_ZERO','pass',
    (pr_blender IS NOT NULL
     AND (pr_blender->'normalized'->'revenue')='null'::jsonb
     AND (pr_blender->'normalized'->'sales_units')='null'::jsonb
     AND (pr_blender->'normalized'->'price')='null'::jsonb
     AND (pr_blender->'normalized'->'revenue_growth_rate')='null'::jsonb));
  v := v || jsonb_build_object('check','06_KALODATA_NOT_CONCRETE_RESOLVED','pass',
    (coalesce(d_ing,'') !~* 'fn_assemble_real_product_market' AND coalesce(d_ing,'') !~* 'concrete_resolved'
     AND NOT (pr_fan ? 'concrete_resolved')));
  v := v || jsonb_build_object('check','07_KALODATA_NOT_SUPPLIER_SKU','pass',
    (coalesce(d_ing,'') !~* 'supplier_product_assets' AND coalesce(d_ing,'') ~* 'provider_product_native'));
  v := v || jsonb_build_object('check','08_HIGH_REVENUE_NO_BYPASS','pass',
    ((pr_fan->'normalized'->>'revenue')::numeric=1000 AND NOT (pr_fan ? 'decision')
     AND NOT (pr_fan ? 'opportunity_band') AND NOT (pr_fan ? 'qualified')
     AND coalesce(d_ing,'') !~* 'fn_pod_evaluate' AND coalesce(d_ing,'') !~* 'product_opportunity_decisions'));
  v := v || jsonb_build_object('check','09_EXTREME_GROWTH_NO_BYPASS','pass',
    ((pr_fan->'normalized'->>'revenue_growth_rate')::numeric=4190.39
     AND NOT (pr_fan->'normalized' ? 'decision') AND NOT (pr_fan->'normalized' ? 'opportunity_band')
     AND coalesce(d_ing,'') !~* 'product_market_evaluations'));
  v := v || jsonb_build_object('check','10_IMAGE_IRRELEVANT','pass',
    (img IS NOT TRUE AND pr_fan IS NOT NULL AND pr_blender IS NOT NULL));
  v := v || jsonb_build_object('check','11_DATAFORSEO_FAILURE_NOT_FATAL_TO_COMMERCE','pass',
    (lane_de_com->>'runnable'='true' AND (plan_de->'runnable_autonomous_lanes') ? 'COMMERCE'
     AND coalesce(d_plan,'') ~* 'zero_yield_rule'));
  v := v || jsonb_build_object('check','12_LANE_ISOLATION_KALODATA_FAIL','pass',
    ((plan_no->>'ok')::boolean AND (plan_no->>'lane_count')::int=5
     AND lane_no_com->>'status'='UNSUPPORTED_MARKET' AND lane_no_search->>'status'='READY'
     AND dry_de_empty->>'status'='SUCCESS_ZERO_CANDIDATES' AND dry_de_nonarray->>'status'='PROVIDER_UNAVAILABLE'));
  v := v || jsonb_build_object('check','13_DEDUP_BY_PROVIDER_ID','pass',
    (coalesce(d_ing,'') ~* 'kalodata_product_id' AND coalesce(d_ing,'') ~* 'dedup'));
  v := v || jsonb_build_object('check','14_ENTERS_AUTO_RESEARCH_BRIDGE','pass',
    (coalesce(d_ing,'') ~* 'fn_auto_dispatch_candidate_research'));
  v := v || jsonb_build_object('check','15_IDEMPOTENT_NO_DUP_RESEARCH','pass',
    (coalesce(d_core,'') ~* 'CACHE_REUSED' AND coalesce(d_ing,'') ~* 'fn_auto_dispatch_candidate_research'));
  v := v || jsonb_build_object('check','16_SECRET_NEVER_PERSISTED','pass',
    (has_pp IS TRUE AND coalesce(d_ing,'') !~* 'secret'
     AND NOT (req_de->'request_body' ? 'secret') AND NOT (req_de->'request_body' ? 'key')
     AND NOT (req_de->'request_body' ? 'token') AND NOT (req_de->'request_body' ? 'authorization')
     AND NOT (req_de->'request_body' ? 'auth')));
  v := v || jsonb_build_object('check','17_IE_NOT_SILENTLY_SUPPORTED','pass',
    (ie_supported IS FALSE AND ie_enabled IS FALSE AND ie_in_enabled_set IS FALSE
     AND req_ie->>'reason'='UNSUPPORTED_MARKET'
     AND (plan_ie->>'ok')::boolean AND lane_ie_com->>'status'='UNSUPPORTED_MARKET'),
    'detail', jsonb_build_object('ie_supported',ie_supported,'ie_enabled',ie_enabled,'strateloq_supports_ie',(plan_ie->>'ok')::boolean));

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE (x->>'pass') IS DISTINCT FROM 'true';
  RETURN jsonb_build_object('suite','kalodata_commerce_adapter','contract','stage1_kalodata_commerce_v1',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'results',v);
END; $function$;

-- ---------------------------------------------------------------------------
-- GRANTS (as deployed, 2026-11-11)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.fn_kalodata_advance_page(uuid,text,integer)            TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_discovery_request(text,integer)            TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_ingest_candidates(uuid,text,uuid,integer,jsonb,boolean,boolean) TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_next_page(uuid,text)                       TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_run_discovery(uuid,text,integer,text,integer) TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_consume_invoke_nonce(text)                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_record_lane_outcome(uuid,text,text,jsonb)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_record_usage(uuid,jsonb,text)              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_commerce_adapter_selftest()                TO service_role;
-- END SNAPSHOT

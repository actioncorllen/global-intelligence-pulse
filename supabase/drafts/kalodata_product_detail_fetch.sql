-- ============================================================================
-- DRAFT (PROPOSED, NOT DEPLOYED): kalodata_product_detail_fetch.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A (Phase 8 — documented contract)
--
-- Wires the MISSING Product Detail fetch to the deployed persister
-- fn_persist_kalodata_product_detail. Request now matches the DOCUMENTED Open Center
-- contract (docs/ref: kalodata_official_api_contracts_2026-11-11.md):
--   POST /openapi/v1/tiktok/product/detail  (rate limit 100 req/10s — a request limit, NOT a price)
--   required: region, language, currency, date_range, product_id (string)
--   optional: need_image  0=none | 1=official URL (image rights confirmed) | 2=Kalodata-hosted (PAID)
-- Reuses existing infra only (no duplicate provider/ledger/image/persistence):
--   market gate -> discovery_provider_market_config; auth -> secret-key + KALODATA_SECRET_KEY (edge);
--   persist -> fn_persist_kalodata_product_detail (REFERENCE_ONLY; tenant-isolated);
--   usage -> fn_kalodata_record_lane_outcome + fn_kalodata_record_usage.
-- The documented product/detail RESPONSE fields already match the deployed persister.
-- APPLY ONLY via the canonical Supabase migration pipeline. No chargeable call here.
-- ============================================================================

-- Request builder: market-gated, secret-free (mirrors fn_kalodata_discovery_request).
-- need_image defaults to 1 (official URL; image rights confirmed per the Andrew Lin email).
-- need_image=2 is a PAID Kalodata-hosted image service and must only be used with budget approval.
CREATE OR REPLACE FUNCTION public.fn_kalodata_detail_request(
  p_market text, p_kalodata_product_id text, p_date_range text DEFAULT 'last7Day', p_need_image integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE c record;
  v_pid text := nullif(btrim(coalesce(p_kalodata_product_id,'')),'');
  v_dr  text := coalesce(nullif(btrim(p_date_range),''),'last7Day');
  v_ni  int  := coalesce(p_need_image,1);
BEGIN
  IF v_pid IS NULL THEN
    RETURN jsonb_build_object('ok',false,'provider','KALODATA','reason','MISSING_PRODUCT_ID'); END IF;
  IF v_ni NOT IN (0,1,2) THEN v_ni := 1; END IF;
  SELECT * INTO c FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=upper(btrim(coalesce(p_market,''))) AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'provider','KALODATA','market',upper(coalesce(p_market,'')),'reason','UNSUPPORTED_MARKET');
  END IF;
  RETURN jsonb_build_object('ok',true,'provider','KALODATA','market',c.market,
    'endpoint','POST https://www.kalodata.com/openapi/v1/tiktok/product/detail',
    'auth','secret-key header (backend broker only; never in DB/logs/response)',
    'rate_limit','100 req / 10s (request limit, not a price or credit cost)',
    'request_body', jsonb_build_object(
      'region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
      'date_range',v_dr,'product_id',v_pid,'need_image',v_ni),
    'need_image_note','0=none, 1=official URL (image rights confirmed), 2=Kalodata-hosted (PAID; requires budget approval)',
    'contract','pulse_kalodata_detail_request_v2_documented');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_detail_request(text,text,text,integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_detail_request(text,text,text,integer) TO authenticated, service_role;

-- Self-test: documented request contract + persister guards (no commerce_products insert).
CREATE OR REPLACE FUNCTION public.fn_kalodata_product_detail_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v jsonb := '[]'::jsonb; r_us jsonb; r_ie jsonb; r_ca jsonb; r_noid jsonb; r_ni2 jsonb;
  v_sample jsonb := jsonb_build_object('product_id','kd_detail_1','master_image_url','https://cdn.kalodata.example/d.jpg',
    'product_description', jsonb_build_array('line a','line b'),
    'pri_cate_id','1','sec_cate_id','12','ter_cate_id','123','sales_volumn','42');
  p_notowned jsonb; p_missing jsonb;
BEGIN
  r_us   := public.fn_kalodata_detail_request('US','kd_detail_1');
  r_ie   := public.fn_kalodata_detail_request('IE','kd_detail_1');
  r_ca   := public.fn_kalodata_detail_request('CA','kd_detail_1');
  r_noid := public.fn_kalodata_detail_request('US', NULL);
  r_ni2  := public.fn_kalodata_detail_request('US','kd_detail_1','last30Day',2);

  v := v || jsonb_build_object('case','detail_request_documented_params','pass',
        ((r_us->>'ok')::boolean = true AND r_us->>'endpoint' ~* 'tiktok/product/detail'
         AND r_us->'request_body'->>'region'='US' AND r_us->'request_body'->>'product_id'='kd_detail_1'
         AND r_us->'request_body'->>'date_range'='last7Day'
         AND (r_us->'request_body'->>'need_image')::int = 1
         AND r_us->>'contract'='pulse_kalodata_detail_request_v2_documented'));
  v := v || jsonb_build_object('case','detail_request_need_image_passthrough','pass',
        ((r_ni2->'request_body'->>'need_image')::int = 2 AND r_ni2->'request_body'->>'date_range'='last30Day'));
  v := v || jsonb_build_object('case','detail_request_disabled_market_blocked','pass', (r_ie->>'reason'='UNSUPPORTED_MARKET'));
  v := v || jsonb_build_object('case','detail_request_uncovered_market_blocked','pass', (r_ca->>'reason'='UNSUPPORTED_MARKET'));
  v := v || jsonb_build_object('case','detail_request_requires_product_id','pass', (r_noid->>'reason'='MISSING_PRODUCT_ID'));
  v := v || jsonb_build_object('case','detail_request_never_carries_secret','pass',
        (NOT (r_us->'request_body' ? 'secret') AND NOT (r_us->'request_body' ? 'secret-key')
         AND NOT (r_us->'request_body' ? 'key') AND NOT (r_us->'request_body' ? 'authorization')));
  -- persister reuse (tenant isolation + arg validation); no commerce_products row -> not_owned
  p_notowned := public.fn_persist_kalodata_product_detail(
    '00000000-0000-4000-8000-0000000000aa'::uuid, '00000000-0000-4000-8000-0000000000bb'::uuid, 'US', v_sample);
  v := v || jsonb_build_object('case','persister_tenant_isolation_guard','pass', (p_notowned->>'reason'='not_owned'));
  p_missing := public.fn_persist_kalodata_product_detail(
    '00000000-0000-4000-8000-0000000000aa'::uuid, '00000000-0000-4000-8000-0000000000bb'::uuid, 'US', '[]'::jsonb);
  v := v || jsonb_build_object('case','persister_rejects_non_object_detail','pass', (p_missing->>'reason'='missing_args'));

  RETURN jsonb_build_object('suite','kalodata_product_detail_fetch',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'contract','pulse_kalodata_detail_request_v2_documented',
    'note','request matches documented Open Center contract; live fetch still requires chargeable-call approval + deploy via the canonical pipeline.',
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_product_detail_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_product_detail_selftest() TO service_role;

-- ============================================================================
-- 20261111000000_kalodata_detail_video_caller.sql
-- PROPOSED production migration (NOT executed from this repo). Apply via the
-- canonical Supabase pipeline: supabase db push / Management API apply_migration.
-- Bundles (dependency order): Product Detail request builder; Video Intelligence
-- (research-only, video/url blocked); operation-generic caller wiring reusing the
-- discovery credit ledger + provider budget + authorize/settle (no new ledger).
-- Pre-existing in prod (do NOT recreate): fn_persist_kalodata_product_detail,
-- fn_discovery_refresh_* , fn_provider_budget_try_consume, kalodata_invoke_nonce,
-- discovery_provider_market_config, discovery_credit_ledger, provider_call_budget.
-- Generated 2026-11-11T13:54:35Z from supabase/drafts/*.sql; diff before apply.
-- ============================================================================
BEGIN;

-- ---- 1) Product Detail request builder ----
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

-- ---- 2) Video Ranking + Video Detail intelligence (research-only) ----
-- ============================================================================
-- DRAFT (PROPOSED, NOT DEPLOYED): kalodata_video_intelligence.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A (Phase 8 — Video Ranking + Video Detail)
--
-- Extends the existing Kalodata discovery lane with Video RANKING + Video DETAIL
-- intelligence (RESEARCH-ONLY). Reuses market gate (discovery_provider_market_config),
-- secret-key auth + KALODATA_SECRET_KEY (edge), nonce/trusted-server gate, and the
-- existing usage accounting. NO new provider, NO duplicate credit ledger.
--
-- Contracts: docs/ref kalodata_official_api_contracts_2026-11-11.md (documented fields only).
--   video/rank   POST /openapi/v1/tiktok/video/rank   (10 req/10s)
--   video/detail POST /openapi/v1/tiktok/video/detail (100 req/10s)
--   video/url    POST /openapi/v1/tiktok/video/url    (10 req/10s) -- RIGHTS-BLOCKED (see below)
--
-- ASSOCIATION NUANCE (documented): the video/rank response has NO per-video product_id, and
-- video/detail exposes product_number as a COUNT (not a list). So videos are associated to the
-- REQUESTED {product_id, country} as PROVENANCE only — never an invented/exclusive product link
-- (a video may attach multiple products). Canonical identity is validated on ingestion.
--
-- MEDIA RIGHTS: video metrics are research intelligence. The video/url endpoint returns a 5-minute
-- signed CloudFront URL that is NOT permission to play/download/proxy/store videos for paying users.
-- This store has NO video_url/playback/media column; the video/url request builder is HARD-BLOCKED and
-- there is no edge function that invokes it. No customer-facing playback/download/permanent media storage.
-- ============================================================================

-- Research-only video intelligence store (metrics only; NO playback/media/url column).
CREATE TABLE IF NOT EXISTS public.kalodata_video_research (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  requested_product_id uuid,                 -- Strateloq canonical product the rank was fetched FOR (provenance; NOT exclusive)
  requested_kalodata_product_id text,        -- Kalodata product_id filter used (provenance)
  market text NOT NULL,                       -- requested country (provenance + country isolation)
  kalodata_video_id text NOT NULL,
  video_title text,
  belonged_creator_id text,
  belonged_creator_handle text,
  metrics jsonb NOT NULL DEFAULT '{}'::jsonb, -- documented row/detail fields, verbatim names (incl. sales_volumn [sic])
  source_endpoint text NOT NULL,              -- 'tiktok/video/rank' | 'tiktok/video/detail'
  association_basis text NOT NULL DEFAULT 'REQUESTED_FILTER_PROVENANCE',
  rights_state text NOT NULL DEFAULT 'RESEARCH_ONLY',
  source_provider text NOT NULL DEFAULT 'KALODATA',
  provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
  observed_at timestamptz NOT NULL DEFAULT now(),
  is_fixture boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kalodata_video_research_rights CHECK (rights_state = 'RESEARCH_ONLY'),
  CONSTRAINT kalodata_video_research_assoc  CHECK (association_basis IN ('REQUESTED_FILTER_PROVENANCE','VIDEO_LEVEL'))
);
ALTER TABLE public.kalodata_video_research ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.kalodata_video_research FROM anon, authenticated;
CREATE UNIQUE INDEX IF NOT EXISTS kalodata_video_research_uniq
  ON public.kalodata_video_research (tenant_id, kalodata_video_id, market, (coalesce(requested_kalodata_product_id,'')), source_endpoint);
CREATE INDEX IF NOT EXISTS kalodata_video_research_product ON public.kalodata_video_research (requested_product_id);

-- Request builders (market-gated, secret-free) -------------------------------------
CREATE OR REPLACE FUNCTION public.fn_kalodata_video_rank_request(
  p_market text, p_kalodata_product_id text DEFAULT NULL, p_page_number integer DEFAULT 1,
  p_date_range text DEFAULT 'last7Day', p_sort_field text DEFAULT 'revenue', p_sort_type text DEFAULT 'DESC')
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE c record; v_page int := greatest(1, coalesce(p_page_number,1));
  v_pid text := nullif(btrim(coalesce(p_kalodata_product_id,'')),'');
  v_dr text := coalesce(nullif(btrim(p_date_range),''),'last7Day');
  v_sf text := coalesce(nullif(btrim(p_sort_field),''),'revenue');
  v_st text := upper(coalesce(nullif(btrim(p_sort_type),''),'DESC'));
  v_body jsonb;
BEGIN
  SELECT * INTO c FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=upper(btrim(coalesce(p_market,''))) AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'provider','KALODATA','market',upper(coalesce(p_market,'')),'reason','UNSUPPORTED_MARKET'); END IF;
  v_body := jsonb_build_object('region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
    'date_range',v_dr,'sort_field',jsonb_build_object('field',v_sf,'type',v_st),'page_size',10,'page_number',v_page);
  IF v_pid IS NOT NULL THEN v_body := v_body || jsonb_build_object('product_id',v_pid); END IF;
  RETURN jsonb_build_object('ok',true,'provider','KALODATA','market',c.market,
    'endpoint','POST https://www.kalodata.com/openapi/v1/tiktok/video/rank',
    'auth','secret-key header (backend broker only; never in DB/logs/response)',
    'rate_limit','10 req / 10s (request limit, not a price)',
    'date_range_note','ranking window capped at 30 days (lastDay|last7Day|last30Day|span<=30d|yyyy-MM)',
    'request_body', v_body, 'contract','pulse_kalodata_video_rank_request_v1_documented');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_video_rank_request(text,text,integer,text,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_video_rank_request(text,text,integer,text,text,text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_kalodata_video_detail_request(
  p_market text, p_video_id text, p_date_range text DEFAULT 'last7Day', p_need_extra boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE c record; v_vid text := nullif(btrim(coalesce(p_video_id,'')),'');
  v_dr text := coalesce(nullif(btrim(p_date_range),''),'last7Day');
BEGIN
  IF v_vid IS NULL THEN RETURN jsonb_build_object('ok',false,'provider','KALODATA','reason','MISSING_VIDEO_ID'); END IF;
  SELECT * INTO c FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=upper(btrim(coalesce(p_market,''))) AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'provider','KALODATA','market',upper(coalesce(p_market,'')),'reason','UNSUPPORTED_MARKET'); END IF;
  RETURN jsonb_build_object('ok',true,'provider','KALODATA','market',c.market,
    'endpoint','POST https://www.kalodata.com/openapi/v1/tiktok/video/detail',
    'auth','secret-key header (backend broker only; never in DB/logs/response)',
    'rate_limit','100 req / 10s (request limit, not a price)',
    'request_body', jsonb_build_object('region',c.region,'language',coalesce(c.language,'en-US'),'currency',c.currency,
      'date_range',v_dr,'video_id',v_vid,'need_extra',coalesce(p_need_extra,false)),
    'contract','pulse_kalodata_video_detail_request_v1_documented');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_video_detail_request(text,text,text,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_video_detail_request(text,text,text,boolean) TO authenticated, service_role;

-- video/url: HARD-BLOCKED. Documented for reference only; returns the request shape but refuses
-- invocation. There is intentionally NO edge function that calls this endpoint and NO url storage.
CREATE OR REPLACE FUNCTION public.fn_kalodata_video_url_request(p_video_id text)
 RETURNS jsonb LANGUAGE sql IMMUTABLE SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT jsonb_build_object(
    'ok', false, 'provider','KALODATA', 'reason','VIDEO_RIGHTS_UNCONFIRMED', 'invocation_blocked', true,
    'endpoint','POST https://www.kalodata.com/openapi/v1/tiktok/video/url',
    'request_body', jsonb_build_object('video_id', nullif(btrim(coalesce(p_video_id,'')),'')),
    'rate_limit','10 req / 10s',
    'note','Returns a 5-minute signed CloudFront URL. NOT permission to play/download/proxy/store videos for paying users. Do not invoke, expose or persist until Kalodata confirms video rights AND a chargeable budget is approved.',
    'contract','pulse_kalodata_video_url_request_v1_blocked');
$function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_video_url_request(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_video_url_request(text) TO authenticated, service_role;

-- Ingest video RANK rows (research-only; requested {product,country} as provenance only).
CREATE OR REPLACE FUNCTION public.fn_kalodata_ingest_video_rank(
  p_tenant uuid, p_requested_product_id uuid, p_requested_kalodata_product_id text, p_market text, p_videos jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_mkt text := upper(btrim(coalesce(p_market,''))); v_cfg record; r record;
  v_ins int := 0; v_skipped int := 0; v_vid text; v_owns boolean;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','missing_user'); END IF;
  SELECT * INTO v_cfg FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','provider','KALODATA','market',v_mkt); END IF;
  IF jsonb_typeof(p_videos) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('status','PROVIDER_UNAVAILABLE','market',v_mkt,'note','no video array supplied'); END IF;
  -- tenant isolation: when a canonical product is named, it must belong to the tenant.
  IF p_requested_product_id IS NOT NULL THEN
    SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_requested_product_id AND user_id=p_tenant) INTO v_owns;
    IF NOT v_owns THEN RETURN jsonb_build_object('status','not_owned','market',v_mkt); END IF;
  END IF;
  FOR r IN SELECT e FROM jsonb_array_elements(p_videos) e LOOP
    v_vid := nullif(btrim(coalesce(r.e->>'video_id','')),'');
    IF v_vid IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;
    INSERT INTO public.kalodata_video_research(
      tenant_id, requested_product_id, requested_kalodata_product_id, market, kalodata_video_id,
      video_title, belonged_creator_id, belonged_creator_handle, metrics, source_endpoint,
      association_basis, rights_state, provenance)
    VALUES (p_tenant, p_requested_product_id, nullif(btrim(coalesce(p_requested_kalodata_product_id,'')),''), v_mkt, v_vid,
      r.e->>'video_title', r.e->>'belonged_creator_id', r.e->>'belonged_creator_handle',
      -- documented video/rank row fields only (verbatim names):
      jsonb_strip_nulls(jsonb_build_object(
        'revenue', r.e->'revenue', 'views', r.e->'views', 'revenue_growth_rate', r.e->'revenue_growth_rate',
        'ads_roas', r.e->'ads_roas', 'digg_count', r.e->'digg_count', 'share_count', r.e->'share_count',
        'comment_count', r.e->'comment_count', 'ad_revenue_ratio', r.e->'ad_revenue_ratio',
        'ad_view_ratio', r.e->'ad_view_ratio', 'creator_debut', r.e->'creator_debut',
        'ad', r.e->'ad', 'ai_video', r.e->'ai_video', 'publish_date', r.e->'publish_date')),
      'tiktok/video/rank', 'REQUESTED_FILTER_PROVENANCE', 'RESEARCH_ONLY',
      jsonb_build_object('source_provider','KALODATA','source_endpoint','tiktok/video/rank',
        'requested_product_id', p_requested_product_id, 'requested_kalodata_product_id', nullif(btrim(coalesce(p_requested_kalodata_product_id,'')),''),
        'market', v_mkt, 'association_note','requested-filter provenance; video/rank exposes no per-video product_id; a video may attach multiple products; not an exclusive link'))
    ON CONFLICT DO NOTHING;
    IF FOUND THEN v_ins := v_ins + 1; ELSE v_skipped := v_skipped + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('status','ok','provider','KALODATA','market',v_mkt,
    'inserted', v_ins, 'skipped', v_skipped, 'rights_state','RESEARCH_ONLY',
    'association_basis','REQUESTED_FILTER_PROVENANCE',
    'note','video metrics stored as research intelligence; no playback URL / media stored; requested product+country kept as provenance only',
    'contract','pulse_kalodata_video_rank_ingest_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_ingest_video_rank(uuid,uuid,text,text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_ingest_video_rank(uuid,uuid,text,text,jsonb) TO service_role;

-- Persist a single video DETAIL (video-level; product_number is a COUNT, never a product list).
CREATE OR REPLACE FUNCTION public.fn_persist_kalodata_video_detail(p_tenant uuid, p_market text, p_detail jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_mkt text := upper(btrim(coalesce(p_market,''))); v_vid text := nullif(btrim(coalesce(p_detail->>'video_id','')),''); v_id uuid;
BEGIN
  IF p_tenant IS NULL OR p_detail IS NULL OR jsonb_typeof(p_detail) <> 'object' THEN
    RETURN jsonb_build_object('ok',false,'reason','missing_args'); END IF;
  IF v_vid IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','missing_video_id'); END IF;
  INSERT INTO public.kalodata_video_research(
    tenant_id, requested_product_id, requested_kalodata_product_id, market, kalodata_video_id,
    video_title, belonged_creator_id, belonged_creator_handle, metrics, source_endpoint,
    association_basis, rights_state, provenance)
  VALUES (p_tenant, NULL, NULL, v_mkt, v_vid,
    p_detail->>'video_title', p_detail->>'belonged_creator_id', p_detail->>'belonged_creator_handle',
    -- documented video/detail data fields only (verbatim; product_number is a COUNT; sales_volumn [sic]):
    jsonb_strip_nulls(jsonb_build_object(
      'video_region', p_detail->'video_region', 'product_number', p_detail->'product_number',
      'revenue', p_detail->'revenue', 'sales_volumn', p_detail->'sales_volumn', 'views', p_detail->'views',
      'video_gpm', p_detail->'video_gpm', 'ads_views', p_detail->'ads_views', 'ads_roas', p_detail->'ads_roas',
      'ads_period', p_detail->'ads_period', 'digg_count', p_detail->'digg_count', 'share_count', p_detail->'share_count',
      'comment_count', p_detail->'comment_count', 'ad_cpa', p_detail->'ad_cpa', 'revenue_trend', p_detail->'revenue_trend',
      'ad', p_detail->'ad', 'ad_view_ratio', p_detail->'ad_view_ratio', 'duration', p_detail->'duration',
      'ai_video', p_detail->'ai_video')),
    'tiktok/video/detail', 'VIDEO_LEVEL', 'RESEARCH_ONLY',
    jsonb_build_object('source_provider','KALODATA','source_endpoint','tiktok/video/detail','market',v_mkt,
      'association_note','video-level detail; product_number is a count, not a product list'))
  ON CONFLICT (tenant_id, kalodata_video_id, market, (coalesce(requested_kalodata_product_id,'')), source_endpoint)
  DO UPDATE SET metrics = EXCLUDED.metrics, video_title = EXCLUDED.video_title, observed_at = now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'video_id', v_vid, 'market', v_mkt, 'row_id', v_id,
    'product_number', p_detail->'product_number', 'rights_state','RESEARCH_ONLY',
    'note','video-level research metrics; no playback/media stored', 'contract','pulse_kalodata_video_detail_persist_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_persist_kalodata_video_detail(uuid,text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_persist_kalodata_video_detail(uuid,text,jsonb) TO service_role;

-- Contract-based self-test (mocks; self-cleaning sentinel tenant; no paid call).
CREATE OR REPLACE FUNCTION public.fn_kalodata_video_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v jsonb := '[]'::jsonb;
  v_t uuid := 'cafe0000-0000-4000-8000-00000000f001';  -- sentinel tenant
  r_rank jsonb; r_rank_ie jsonb; r_det jsonb; r_url jsonb; ing jsonb; ing_notowned jsonb; det jsonb; v_check boolean;
  v_videos jsonb := jsonb_build_array(
    jsonb_build_object('video_id','v1','video_title','T1','belonged_creator_id','c1','belonged_creator_handle','@c1',
      'revenue',1000,'views',50000,'revenue_growth_rate',12.5,'ads_roas',3.1,'digg_count',10,'share_count',2,
      'comment_count',4,'ad',true,'ai_video',false,'publish_date','2026-10-01'),
    jsonb_build_object('video_id','','video_title','missing id'));
  v_detail jsonb := jsonb_build_object('video_id','v9','video_region','US','video_title','D9',
    'belonged_creator_id','c9','belonged_creator_handle','@c9','product_number',3,'revenue',500,'sales_volumn',42,
    'views',9000,'video_gpm',1.2,'ads_roas',2.0,'duration',31,'ai_video',false);
BEGIN
  DELETE FROM public.kalodata_video_research WHERE tenant_id = v_t;
  r_rank    := public.fn_kalodata_video_rank_request('US','kd_prod_1',1);
  r_rank_ie := public.fn_kalodata_video_rank_request('IE','kd_prod_1',1);  -- disabled market
  r_det     := public.fn_kalodata_video_detail_request('US','v9');
  r_url     := public.fn_kalodata_video_url_request('v9');

  v := v || jsonb_build_object('case','video_rank_request_documented','pass',
        ((r_rank->>'ok')::boolean = true AND r_rank->>'endpoint' ~* 'tiktok/video/rank'
         AND r_rank->'request_body'->>'region'='US' AND r_rank->'request_body'->'sort_field'->>'field'='revenue'
         AND (r_rank->'request_body'->>'page_size')::int=10 AND r_rank->'request_body'->>'product_id'='kd_prod_1'));
  v := v || jsonb_build_object('case','video_rank_market_gated','pass', (r_rank_ie->>'reason'='UNSUPPORTED_MARKET'));
  v := v || jsonb_build_object('case','video_detail_request_documented','pass',
        ((r_det->>'ok')::boolean = true AND r_det->>'endpoint' ~* 'tiktok/video/detail'
         AND r_det->'request_body'->>'video_id'='v9' AND (r_det->'request_body' ? 'need_extra')));
  v := v || jsonb_build_object('case','video_url_hard_blocked','pass',
        ((r_url->>'ok')::boolean = false AND r_url->>'reason'='VIDEO_RIGHTS_UNCONFIRMED'
         AND (r_url->>'invocation_blocked')::boolean = true));

  -- ingest rank (no product filter -> no ownership check; general top videos)
  ing := public.fn_kalodata_ingest_video_rank(v_t, NULL, 'kd_prod_1', 'US', v_videos);
  v := v || jsonb_build_object('case','video_rank_ingest_research_only','pass',
        (ing->>'status'='ok' AND (ing->>'inserted')::int = 1 AND (ing->>'skipped')::int = 1
         AND ing->>'rights_state'='RESEARCH_ONLY'));
  -- stored row: provenance kept, documented metrics present, NO invented per-video product_id, NO url stored
  v := v || jsonb_build_object('case','video_row_provenance_and_no_invented_link','pass',
        EXISTS (SELECT 1 FROM public.kalodata_video_research a
                WHERE a.tenant_id=v_t AND a.kalodata_video_id='v1'
                  AND a.association_basis='REQUESTED_FILTER_PROVENANCE'
                  AND a.requested_kalodata_product_id='kd_prod_1'
                  AND (a.metrics->>'revenue')='1000' AND (a.metrics->>'views')='50000'
                  AND NOT (a.metrics ? 'product_id') AND NOT (a.metrics ? 'video_url')
                  AND NOT (a.provenance ? 'product_id')));            -- provenance uses requested_* keys, not an exclusive product_id
  -- tenant isolation: a named product that the tenant does not own is rejected
  ing_notowned := public.fn_kalodata_ingest_video_rank(v_t, '00000000-0000-4000-8000-0000000000cc'::uuid, 'kd_prod_1', 'US', v_videos);
  v := v || jsonb_build_object('case','video_rank_ingest_tenant_isolation','pass', (ing_notowned->>'status'='not_owned'));

  -- video detail persist: product_number kept as a count, sales_volumn spelling preserved
  det := public.fn_persist_kalodata_video_detail(v_t, 'US', v_detail);
  v := v || jsonb_build_object('case','video_detail_persist_product_number_count','pass',
        ((det->>'ok')::boolean = true AND (det->>'product_number')::int = 3
         AND EXISTS (SELECT 1 FROM public.kalodata_video_research a WHERE a.tenant_id=v_t AND a.kalodata_video_id='v9'
                     AND (a.metrics->>'product_number')='3' AND (a.metrics->>'sales_volumn')='42'
                     AND a.association_basis='VIDEO_LEVEL')));
  -- research-only CHECK enforced
  v_check := false;
  BEGIN
    INSERT INTO public.kalodata_video_research(tenant_id, market, kalodata_video_id, source_endpoint, rights_state)
    VALUES (v_t, 'US','vx','tiktok/video/rank','COMMERCIAL');
  EXCEPTION WHEN check_violation THEN v_check := true; END;
  v := v || jsonb_build_object('case','video_research_only_check_enforced','pass', v_check);
  -- structural: the store has NO playback/url/media column (no permanent video storage)
  v := v || jsonb_build_object('case','no_playback_url_column','pass',
        NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='kalodata_video_research'
                      AND (column_name ILIKE '%url%' OR column_name ILIKE '%playback%' OR column_name ILIKE '%media%' OR column_name ILIKE '%download%')));

  DELETE FROM public.kalodata_video_research WHERE tenant_id = v_t;
  RETURN jsonb_build_object('suite','kalodata_video_intelligence',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'note','video intelligence research-only; video/url blocked; no playback/media/permanent-video storage.',
    'results', v);
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.kalodata_video_research WHERE tenant_id = v_t;
  RETURN jsonb_build_object('suite','kalodata_video_intelligence','status','error','error',SQLERRM);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_video_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_video_selftest() TO service_role;

-- ---- 3) Operation-generic caller wiring (reuse credit workflow) ----
-- ============================================================================
-- DRAFT (PROPOSED, NOT DEPLOYED): kalodata_caller_wiring.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A (Phase 9 — caller wiring)
--
-- Reuses the EXISTING discovery credit workflow for Product Detail + Video Ranking +
-- Video Detail. NO new credit ledger, NO parallel billing:
--   ledger            -> public.discovery_credit_ledger (RESERVE / SETTLE / REFUND)
--   request lifecycle -> public.discovery_refresh_request (+ additive `operation` column)
--   provider budget   -> public.provider_call_budget via fn_provider_budget_try_consume (KALODATA fail-closed)
--   quote/gate        -> fn_discovery_refresh_quote (pricing, balance, entitlement, provider budget)
--   authorize         -> fn_discovery_refresh_authorize (UNCHANGED; operation-agnostic)
--   settle/refund     -> fn_discovery_refresh_settle / fn_discovery_refresh_is_refund (UNCHANGED)
--   nonce             -> public.kalodata_invoke_nonce + fn_kalodata_consume_invoke_nonce
--   market gate       -> public.discovery_provider_market_config (9 enabled Kalodata markets)
--
-- Only two thin additions are operation-generic: a reserve that tags `operation` (reusing the quote +
-- ledger), and a service-role-safe completion (tenant derived from the request row, like the discovery
-- edge's complete_from_edge). The three run_* callers then do: reserve -> authorize -> fire(edge w/ nonce);
-- the edge persists + records usage and calls the completion with the outcome (success settles, failure
-- refunds). Lifecycle, idempotency, tenant isolation and fail-closed budget are inherited unchanged.
--
-- APPLY ONLY via the canonical Supabase migration pipeline. No chargeable call / deploy here.
-- ============================================================================

-- Additive: tag the request lifecycle with the operation (default preserves discovery byte-for-byte).
ALTER TABLE public.discovery_refresh_request
  ADD COLUMN IF NOT EXISTS operation text NOT NULL DEFAULT 'DISCOVERY_REFRESH';

-- Operation-generic reserve (market-gated; reuses fn_discovery_refresh_quote + discovery_credit_ledger).
CREATE OR REPLACE FUNCTION public.fn_kalodata_op_reserve(
  p_operation text, p_market text, p_idempotency_key text, p_page_number integer DEFAULT 1)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_op  text := upper(btrim(coalesce(p_operation,'')));
  v_mkt text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_idem text := nullif(btrim(coalesce(p_idempotency_key,'')),'');
  v_q jsonb; v_price int; v_req public.discovery_refresh_request; v_page int := greatest(0, coalesce(p_page_number,1));
BEGIN
  IF v_uid IS NULL OR v_mkt IS NULL OR v_idem IS NULL
     OR v_op NOT IN ('PRODUCT_DETAIL','VIDEO_RANK','VIDEO_DETAIL') THEN
    RETURN jsonb_build_object('status','error','reason','UNAUTHENTICATED_OR_BAD_ARGS','contract','pulse_kalodata_op_reserve_v1');
  END IF;
  -- idempotent replay (never double-charge)
  SELECT * INTO v_req FROM public.discovery_refresh_request WHERE tenant_id=v_uid AND idempotency_key=v_idem;
  IF FOUND THEN
    RETURN jsonb_build_object('status','ok','idempotent_replay',true,'request_id',v_req.id,'state',v_req.status,
      'operation',v_req.operation,'credits_cost',v_req.credits_cost,'market',v_req.market,'contract','pulse_kalodata_op_reserve_v1');
  END IF;
  -- 9-market gate (same source the lane uses). Unsupported/disabled markets never reach pricing/budget.
  IF NOT EXISTS (SELECT 1 FROM public.discovery_provider_market_config
                 WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled) THEN
    RETURN jsonb_build_object('status','denied','reason','UNSUPPORTED_MARKET','market',v_mkt,'contract','pulse_kalodata_op_reserve_v1');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text,42));
  v_q := public.fn_discovery_refresh_quote(v_mkt);
  IF (v_q->>'can_refresh') <> 'true' THEN
    RETURN jsonb_build_object('status','denied','reason',v_q->>'reason','quote',v_q,'contract','pulse_kalodata_op_reserve_v1');
  END IF;
  v_price := (v_q->>'required_credits')::int;
  INSERT INTO public.discovery_refresh_request(tenant_id,market,idempotency_key,status,provider,credits_cost,page_number,operation)
    VALUES (v_uid,v_mkt,v_idem,'RESERVED','KALODATA',v_price,v_page,v_op)
  RETURNING * INTO v_req;
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,idempotency_key,reason)
    VALUES (v_uid,'RESERVE',-v_price,v_req.id,v_idem,lower(v_op)||' '||v_mkt);
  RETURN jsonb_build_object('status','ok','reserved',true,'request_id',v_req.id,'operation',v_op,'credits_cost',v_price,
    'balance_after',public.fn_discovery_credit_balance(),'market',v_mkt,'contract','pulse_kalodata_op_reserve_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_op_reserve(text,text,text,integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_op_reserve(text,text,text,integer) TO authenticated, service_role;

-- Service-role-safe completion (tenant derived from the request row, never auth.uid()) so the edge can
-- settle/refund under service_role. Same ledger + same is_refund logic as fn_discovery_refresh_settle.
CREATE OR REPLACE FUNCTION public.fn_kalodata_op_complete_from_edge(p_request_id uuid, p_outcome text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_req public.discovery_refresh_request; v_outcome text := upper(coalesce(p_outcome,'SUCCESS')); v_refund boolean;
BEGIN
  SELECT * INTO v_req FROM public.discovery_refresh_request WHERE id=p_request_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','error','reason','REQUEST_NOT_FOUND'); END IF;
  IF v_req.status IN ('SETTLED','REFUNDED') THEN
    RETURN jsonb_build_object('status','ok','idempotent_replay',true,'state',v_req.status); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_req.tenant_id::text,42));
  v_refund := public.fn_discovery_refresh_is_refund(v_outcome);
  IF v_refund THEN
    INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,reason)
      VALUES (v_req.tenant_id,'REFUND',v_req.credits_cost,v_req.id,'refund:'||lower(v_outcome)||' op='||lower(coalesce(v_req.operation,'')));
    UPDATE public.discovery_refresh_request SET status='REFUNDED', provider_outcome=v_outcome, updated_at=now() WHERE id=v_req.id;
  ELSE
    INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,refresh_request_id,reason)
      VALUES (v_req.tenant_id,'SETTLE',0,v_req.id,'settle:'||lower(v_outcome)||' op='||lower(coalesce(v_req.operation,'')));
    UPDATE public.discovery_refresh_request SET status='SETTLED', provider_outcome=v_outcome, updated_at=now() WHERE id=v_req.id;
  END IF;
  RETURN jsonb_build_object('status','ok','outcome',v_outcome,'refunded',v_refund,'settled',NOT v_refund,'operation',v_req.operation);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_op_complete_from_edge(uuid,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_op_complete_from_edge(uuid,text) TO service_role;

-- Generic fire: dispatch-once + nonce + net.http_post to the operation's edge (mirrors fn_discovery_refresh_fire).
CREATE OR REPLACE FUNCTION public.fn_kalodata_op_fire(
  p_request_id uuid, p_anon_key text, p_edge_slug text, p_extra_body jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_req public.discovery_refresh_request;
  v_token text := replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_url text := 'https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/'||p_edge_slug; v_net bigint;
BEGIN
  IF v_uid IS NULL OR coalesce(btrim(p_anon_key),'')='' OR coalesce(btrim(p_edge_slug),'')='' THEN
    RETURN jsonb_build_object('status','error','reason','UNAUTHENTICATED_OR_BAD_ARGS'); END IF;
  SELECT * INTO v_req FROM public.discovery_refresh_request WHERE id=p_request_id AND tenant_id=v_uid;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','error','reason','REQUEST_NOT_FOUND'); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text,42));
  IF v_req.status <> 'EXECUTING' THEN RETURN jsonb_build_object('status','error','reason','NOT_AUTHORIZED_OR_TERMINAL','state',v_req.status); END IF;
  IF v_req.dispatched_at IS NOT NULL THEN RETURN jsonb_build_object('status','ok','idempotent_replay',true,'already_dispatched',true,'request_id',v_req.id); END IF;
  UPDATE public.discovery_refresh_request SET dispatched_at=now(), updated_at=now() WHERE id=v_req.id;
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market) VALUES (v_token,v_uid,v_req.market);
  SELECT net.http_post(
    url := v_url,
    body := jsonb_build_object('market',v_req.market,'user_id',v_uid,'refresh_request_id',v_req.id) || coalesce(p_extra_body,'{}'::jsonb),
    headers := jsonb_build_object('Content-Type','application/json','apikey',p_anon_key,'Authorization','Bearer '||p_anon_key,'x-pulse-nonce',v_token),
    timeout_milliseconds := 30000
  ) INTO v_net;
  RETURN jsonb_build_object('status','ok','fired',true,'request_id',v_req.id,'edge',p_edge_slug,'net_request_id',v_net);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_op_fire(uuid,text,text,jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_op_fire(uuid,text,text,jsonb) TO authenticated, service_role;

-- Run callers: reserve -> authorize -> fire. p_dry_run skips the provider fire (reserve+authorize only),
-- used by the self-test and for a no-cost readiness check. authorize already fail-closes without budget.
CREATE OR REPLACE FUNCTION public.fn_kalodata_run_product_detail(
  p_market text, p_product_id uuid, p_kalodata_product_id text, p_idempotency_key text,
  p_anon_key text DEFAULT NULL, p_dry_run boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_res jsonb; v_auth jsonb; v_req uuid;
BEGIN
  v_res := public.fn_kalodata_op_reserve('PRODUCT_DETAIL', p_market, p_idempotency_key, 1);
  IF (v_res->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_res->>'status','stage','reserve','detail',v_res); END IF;
  v_req := (v_res->>'request_id')::uuid;
  v_auth := public.fn_discovery_refresh_authorize(v_req);
  IF (v_auth->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_auth->>'status','stage','authorize','request_id',v_req,'detail',v_auth); END IF;
  IF coalesce(p_dry_run,false) THEN
    RETURN jsonb_build_object('status','ok','stage','authorized_dry_run','request_id',v_req,'note','reserve+authorize ok; fire skipped'); END IF;
  RETURN public.fn_kalodata_op_fire(v_req, p_anon_key, 'kalodata-product-detail',
    jsonb_build_object('product_id', p_product_id, 'kalodata_product_id', p_kalodata_product_id));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_run_product_detail(text,uuid,text,text,text,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_run_product_detail(text,uuid,text,text,text,boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_kalodata_run_video_rank(
  p_market text, p_product_id uuid, p_kalodata_product_id text, p_page_number integer, p_idempotency_key text,
  p_anon_key text DEFAULT NULL, p_dry_run boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_res jsonb; v_auth jsonb; v_req uuid;
BEGIN
  v_res := public.fn_kalodata_op_reserve('VIDEO_RANK', p_market, p_idempotency_key, greatest(1,coalesce(p_page_number,1)));
  IF (v_res->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_res->>'status','stage','reserve','detail',v_res); END IF;
  v_req := (v_res->>'request_id')::uuid;
  v_auth := public.fn_discovery_refresh_authorize(v_req);
  IF (v_auth->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_auth->>'status','stage','authorize','request_id',v_req,'detail',v_auth); END IF;
  IF coalesce(p_dry_run,false) THEN RETURN jsonb_build_object('status','ok','stage','authorized_dry_run','request_id',v_req); END IF;
  RETURN public.fn_kalodata_op_fire(v_req, p_anon_key, 'kalodata-video-rank',
    jsonb_build_object('product_id', p_product_id, 'kalodata_product_id', p_kalodata_product_id, 'page_number', greatest(1,coalesce(p_page_number,1))));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_run_video_rank(text,uuid,text,integer,text,text,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_run_video_rank(text,uuid,text,integer,text,text,boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.fn_kalodata_run_video_detail(
  p_market text, p_video_id text, p_idempotency_key text, p_anon_key text DEFAULT NULL, p_dry_run boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_res jsonb; v_auth jsonb; v_req uuid;
BEGIN
  IF nullif(btrim(coalesce(p_video_id,'')),'') IS NULL THEN RETURN jsonb_build_object('status','error','reason','MISSING_VIDEO_ID'); END IF;
  v_res := public.fn_kalodata_op_reserve('VIDEO_DETAIL', p_market, p_idempotency_key, 1);
  IF (v_res->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_res->>'status','stage','reserve','detail',v_res); END IF;
  v_req := (v_res->>'request_id')::uuid;
  v_auth := public.fn_discovery_refresh_authorize(v_req);
  IF (v_auth->>'status') <> 'ok' THEN RETURN jsonb_build_object('status', v_auth->>'status','stage','authorize','request_id',v_req,'detail',v_auth); END IF;
  IF coalesce(p_dry_run,false) THEN RETURN jsonb_build_object('status','ok','stage','authorized_dry_run','request_id',v_req); END IF;
  RETURN public.fn_kalodata_op_fire(v_req, p_anon_key, 'kalodata-video-detail', jsonb_build_object('video_id', p_video_id));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_run_video_detail(text,text,text,text,boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_run_video_detail(text,text,text,text,boolean) TO authenticated, service_role;

-- Full internal-lifecycle self-test with mocks (seeds its own sentinel tenants; self-cleaning; no fire).
CREATE OR REPLACE FUNCTION public.fn_kalodata_caller_lifecycle_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_a uuid := 'ca11a000-0000-4000-8000-00000000000a';
  v_b uuid := 'ca11b000-0000-4000-8000-00000000000b';
  r_res jsonb; r_auth jsonb; r_done jsonb; r_dup jsonb; r_exhaust jsonb; r_unsup jsonb;
  r_pre jsonb; r_xauth jsonb; r_xsettle jsonb; r_run jsonb; req1 uuid; req2 uuid; req3 uuid;
  bal0 numeric; bal_after_settle numeric; bal_after_refund numeric;
  old_nonce boolean; fresh_nonce boolean; v_tok text := repeat('n',40);
BEGIN
  -- clean + seed
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.discovery_refresh_request WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.provider_call_budget WHERE user_id IN (v_a,v_b);
  DELETE FROM public.account_entitlement WHERE auth_user_id IN (v_a,v_b);
  DELETE FROM public.kalodata_invoke_nonce WHERE user_id IN (v_a,v_b) OR token=v_tok;
  INSERT INTO public.account_entitlement(auth_user_id,status,current_period_end) VALUES (v_a,'ACTIVE', now()+interval '30 days');
  INSERT INTO public.provider_call_budget(provider,user_id,market,active,consumed_calls,max_calls,created_at)
    VALUES ('KALODATA',v_a,'US',true,0,2,now());
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,reason) VALUES (v_a,'GRANT',10,'test grant');
  PERFORM set_config('test.uid', v_a::text, true);
  bal0 := public.fn_discovery_credit_balance();

  -- 1) happy: reserve -> authorize -> complete(SUCCESS) settles (not refunds)
  r_res := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','US','idem1',1); req1 := (r_res->>'request_id')::uuid;
  r_auth := public.fn_discovery_refresh_authorize(req1);
  r_done := public.fn_kalodata_op_complete_from_edge(req1,'SUCCESS');
  bal_after_settle := public.fn_discovery_credit_balance();
  v := v || jsonb_build_object('case','happy_reserve_authorize_settle','pass',
        (r_res->>'status'='ok' AND (r_res->>'credits_cost')::int=1 AND r_auth->>'status'='ok'
         AND (r_auth->>'authorized')::boolean=true AND (r_done->>'settled')::boolean=true
         AND bal_after_settle = bal0 - 1));

  -- 1b) double settlement is idempotent: second complete is a replay, no second SETTLE, no balance change
  r_done := public.fn_kalodata_op_complete_from_edge(req1,'SUCCESS');
  v := v || jsonb_build_object('case','double_settle_idempotent','pass',
        ((r_done->>'idempotent_replay')::boolean=true AND public.fn_discovery_credit_balance() = bal_after_settle
         AND (SELECT count(*) FROM public.discovery_credit_ledger WHERE refresh_request_id=req1 AND entry_type='SETTLE')=1));

  -- 2) duplicate idempotency: same key -> replay, no extra charge
  r_dup := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','US','idem1',1);
  v := v || jsonb_build_object('case','duplicate_request_idempotent','pass',
        ((r_dup->>'idempotent_replay')::boolean=true AND (r_dup->>'request_id')::uuid=req1
         AND public.fn_discovery_credit_balance() = bal_after_settle));

  -- 3) malformed/provider failure after charge -> refund restores credits
  r_res := public.fn_kalodata_op_reserve('VIDEO_RANK','US','idem2',1); req2 := (r_res->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req2);
  r_done := public.fn_kalodata_op_complete_from_edge(req2,'PROVIDER_FAILED_POST_CHARGE');
  bal_after_refund := public.fn_discovery_credit_balance();
  v := v || jsonb_build_object('case','malformed_or_failure_refund','pass',
        ((r_done->>'refunded')::boolean=true AND bal_after_refund = bal_after_settle));  -- reserve(-1)+refund(+1)=net 0

  -- 3b) double refund is idempotent: second complete is a replay, no second REFUND, no balance change
  r_done := public.fn_kalodata_op_complete_from_edge(req2,'PROVIDER_FAILED_POST_CHARGE');
  v := v || jsonb_build_object('case','double_refund_idempotent','pass',
        ((r_done->>'idempotent_replay')::boolean=true AND public.fn_discovery_credit_balance() = bal_after_refund
         AND (SELECT count(*) FROM public.discovery_credit_ledger WHERE refresh_request_id=req2 AND entry_type='REFUND')=1));

  -- 4) credit exhaustion: drain balance below price -> reserve denied
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,reason) VALUES (v_a,'ADJUST', -public.fn_discovery_credit_balance(), 'drain for test');
  r_exhaust := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','US','idem_drain',1);
  v := v || jsonb_build_object('case','credit_exhaustion_denied','pass',
        (r_exhaust->>'status'='denied' AND r_exhaust->>'reason'='INSUFFICIENT_CREDITS'));
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,reason) VALUES (v_a,'GRANT',10,'restore after drain');

  -- 5) unsupported market: reserve rejected by the 9-market gate (IE disabled)
  r_unsup := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','IE','idem_ie',1);
  v := v || jsonb_build_object('case','unsupported_market_denied','pass', (r_unsup->>'reason'='UNSUPPORTED_MARKET'));

  -- 6a) provider budget exhausted at RESERVE: quote denies PROVIDER_NOT_AUTHORIZED (fail-closed before charge)
  UPDATE public.provider_call_budget SET consumed_calls=max_calls WHERE user_id=v_a;
  r_exhaust := public.fn_kalodata_op_reserve('VIDEO_DETAIL','US','idem_noprov',1);
  v := v || jsonb_build_object('case','provider_budget_exhausted_reserve_denied','pass', (r_exhaust->>'reason'='PROVIDER_NOT_AUTHORIZED'));
  -- 6b) budget exhausted AFTER reserve (race): authorize fails closed + auto-refunds, request REFUNDED
  UPDATE public.provider_call_budget SET consumed_calls=0, max_calls=1 WHERE user_id=v_a;
  r_res := public.fn_kalodata_op_reserve('VIDEO_DETAIL','US','idem3',1); req3 := (r_res->>'request_id')::uuid;
  UPDATE public.provider_call_budget SET consumed_calls=1 WHERE user_id=v_a;  -- a concurrent consumer took the last unit
  r_pre := public.fn_discovery_refresh_authorize(req3);
  v := v || jsonb_build_object('case','provider_budget_precharge_fail_closed','pass',
        (r_res->>'status'='ok' AND r_pre->>'status'='denied' AND (r_pre->>'refunded')::boolean=true
         AND (SELECT status FROM public.discovery_refresh_request WHERE id=req3)='REFUNDED'));

  -- 7) cross-tenant: tenant B cannot authorize/settle tenant A's request
  PERFORM set_config('test.uid', v_b::text, true);
  r_xauth   := public.fn_discovery_refresh_authorize(req1);
  r_xsettle := public.fn_discovery_refresh_settle(req1,0,'SUCCESS');
  PERFORM set_config('test.uid', v_a::text, true);
  v := v || jsonb_build_object('case','cross_tenant_rejected','pass',
        (r_xauth->>'reason'='REQUEST_NOT_FOUND' AND r_xsettle->>'reason'='REQUEST_NOT_FOUND'));

  -- 8) expired nonce rejected; fresh nonce accepted
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market,created_at) VALUES (v_tok,v_a,'US', now()-interval '6 minutes');
  old_nonce := public.fn_kalodata_consume_invoke_nonce(v_tok);
  INSERT INTO public.kalodata_invoke_nonce(token,user_id,market) VALUES (repeat('f',40),v_a,'US');
  fresh_nonce := public.fn_kalodata_consume_invoke_nonce(repeat('f',40));
  v := v || jsonb_build_object('case','expired_nonce_rejected_fresh_accepted','pass', (old_nonce=false AND fresh_nonce=true));

  -- 9) run_* caller dry-run reaches authorized state through the same path (reset budget first)
  UPDATE public.provider_call_budget SET consumed_calls=0 WHERE user_id=v_a;
  r_run := public.fn_kalodata_run_video_rank('US', NULL, 'kd_prod_1', 1, 'idem_run1', NULL, true);
  v := v || jsonb_build_object('case','run_caller_dry_run_authorized','pass', (r_run->>'stage'='authorized_dry_run'));

  -- cleanup
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.discovery_refresh_request WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.provider_call_budget WHERE user_id IN (v_a,v_b);
  DELETE FROM public.account_entitlement WHERE auth_user_id IN (v_a,v_b);
  DELETE FROM public.kalodata_invoke_nonce WHERE user_id IN (v_a,v_b) OR token IN (v_tok, repeat('f',40));

  RETURN jsonb_build_object('suite','kalodata_caller_lifecycle',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'note','reuses discovery_credit_ledger + provider_call_budget + authorize/settle; no new ledger.',
    'results', v);
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.discovery_refresh_request WHERE tenant_id IN (v_a,v_b);
  DELETE FROM public.provider_call_budget WHERE user_id IN (v_a,v_b);
  DELETE FROM public.account_entitlement WHERE auth_user_id IN (v_a,v_b);
  RETURN jsonb_build_object('suite','kalodata_caller_lifecycle','status','error','error',SQLERRM);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_caller_lifecycle_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_caller_lifecycle_selftest() TO service_role;

-- End-to-end lifecycle with MOCKED provider responses + reconcile (requires the full bundle:
-- video intelligence + the product-detail persister). Proves reserve -> authorize -> ingest/persist
-- (mock provider payload) -> settle/refund, and the operation-agnostic reconcile of abandoned EXECUTING.
CREATE OR REPLACE FUNCTION public.fn_kalodata_e2e_mock_lifecycle_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_a uuid := 'ca11e2e0-0000-4000-8000-00000000000e';
  v_p uuid := 'ca11e2e0-0000-4000-8000-0000000000aa';
  r jsonb; req uuid; req2 uuid; req3 uuid; ing jsonb; pr jsonb; done jsonb; bal0 numeric;
  mock_videos jsonb := jsonb_build_array(jsonb_build_object('video_id','ev1','video_title','E2E',
    'belonged_creator_id','c','belonged_creator_handle','@c','revenue',10,'views',99));
  mock_detail jsonb := jsonb_build_object('product_id','kdp1','master_image_url','https://cdn/x.jpg',
    'product_description',jsonb_build_array('d'),'pri_cate_id','1');
BEGIN
  DELETE FROM public.kalodata_video_research WHERE tenant_id=v_a;
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id=v_a;
  DELETE FROM public.discovery_refresh_request WHERE tenant_id=v_a;
  DELETE FROM public.provider_call_budget WHERE user_id=v_a;
  DELETE FROM public.account_entitlement WHERE auth_user_id=v_a;
  DELETE FROM public.commerce_products WHERE id=v_p;
  INSERT INTO public.commerce_products(id,user_id,extended) VALUES (v_p,v_a,jsonb_build_object('kalodata_product_id','kdp1'));
  INSERT INTO public.account_entitlement(auth_user_id,status,current_period_end) VALUES (v_a,'ACTIVE',now()+interval '30 days');
  INSERT INTO public.provider_call_budget(provider,user_id,market,active,consumed_calls,max_calls,created_at) VALUES ('KALODATA',v_a,'US',true,0,10,now());
  INSERT INTO public.discovery_credit_ledger(tenant_id,entry_type,credits,reason) VALUES (v_a,'GRANT',10,'e2e grant');
  PERFORM set_config('test.uid', v_a::text, true);
  bal0 := public.fn_discovery_credit_balance();

  -- A) VIDEO_RANK happy e2e: reserve -> authorize -> ingest mock videos -> settle
  r := public.fn_kalodata_op_reserve('VIDEO_RANK','US','e2e_v1',1); req := (r->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req);
  ing := public.fn_kalodata_ingest_video_rank(v_a, v_p, 'kdp1', 'US', mock_videos);
  done := public.fn_kalodata_op_complete_from_edge(req,'SUCCESS');
  v := v || jsonb_build_object('case','e2e_video_rank_mock_success','pass',
        (ing->>'status'='ok' AND (ing->>'inserted')::int=1 AND (done->>'settled')::boolean=true
         AND (SELECT status FROM public.discovery_refresh_request WHERE id=req)='SETTLED'
         AND EXISTS(SELECT 1 FROM public.kalodata_video_research WHERE tenant_id=v_a AND kalodata_video_id='ev1'
                    AND requested_product_id=v_p AND rights_state='RESEARCH_ONLY')
         AND public.fn_discovery_credit_balance() = bal0 - 1));

  -- B) PRODUCT_DETAIL happy e2e: reserve -> authorize -> persist mock detail -> settle
  r := public.fn_kalodata_op_reserve('PRODUCT_DETAIL','US','e2e_d1',1); req2 := (r->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req2);
  pr := public.fn_persist_kalodata_product_detail(v_a, v_p, 'US', mock_detail);
  done := public.fn_kalodata_op_complete_from_edge(req2,'SUCCESS');
  v := v || jsonb_build_object('case','e2e_product_detail_mock_success','pass',
        ((pr->>'ok')::boolean=true AND (done->>'settled')::boolean=true
         AND (SELECT status FROM public.discovery_refresh_request WHERE id=req2)='SETTLED'));

  -- C) VIDEO_DETAIL provider-failure e2e: reserve -> authorize -> provider fails -> refund, nothing persisted
  r := public.fn_kalodata_op_reserve('VIDEO_DETAIL','US','e2e_f1',1); req3 := (r->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req3);
  done := public.fn_kalodata_op_complete_from_edge(req3,'PROVIDER_FAILED_POST_CHARGE');
  v := v || jsonb_build_object('case','e2e_video_detail_mock_failure_refund','pass',
        ((done->>'refunded')::boolean=true
         AND (SELECT status FROM public.discovery_refresh_request WHERE id=req3)='REFUNDED'
         AND NOT EXISTS(SELECT 1 FROM public.kalodata_video_research WHERE tenant_id=v_a AND source_endpoint='tiktok/video/detail')));

  -- D) abandoned EXECUTING (interrupted provider call) reconciles to REFUNDED, operation-agnostic
  r := public.fn_kalodata_op_reserve('VIDEO_RANK','US','e2e_abandon',1); req := (r->>'request_id')::uuid;
  PERFORM public.fn_discovery_refresh_authorize(req);   -- EXECUTING; completion never arrives
  UPDATE public.discovery_refresh_request SET updated_at = now() - interval '31 minutes' WHERE id=req;
  PERFORM public.fn_discovery_refresh_reconcile(30);
  v := v || jsonb_build_object('case','e2e_abandoned_executing_reconciled_refund','pass',
        ((SELECT status FROM public.discovery_refresh_request WHERE id=req)='REFUNDED'
         AND (SELECT provider_outcome FROM public.discovery_refresh_request WHERE id=req)='UNRESOLVED_POST_DISPATCH'));
  -- E) a late completion after reconcile is idempotent (no double refund)
  done := public.fn_kalodata_op_complete_from_edge(req,'SUCCESS');
  v := v || jsonb_build_object('case','e2e_late_completion_after_reconcile_idempotent','pass',
        ((done->>'idempotent_replay')::boolean=true
         AND (SELECT count(*) FROM public.discovery_credit_ledger WHERE refresh_request_id=req AND entry_type='REFUND')=1));

  DELETE FROM public.kalodata_video_research WHERE tenant_id=v_a;
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id=v_a;
  DELETE FROM public.discovery_refresh_request WHERE tenant_id=v_a;
  DELETE FROM public.provider_call_budget WHERE user_id=v_a;
  DELETE FROM public.account_entitlement WHERE auth_user_id=v_a;
  DELETE FROM public.commerce_products WHERE id=v_p;
  RETURN jsonb_build_object('suite','kalodata_e2e_mock_lifecycle',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'note','full lifecycle with mocked provider responses + reconcile; requires the full bundle.',
    'results', v);
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.kalodata_video_research WHERE tenant_id=v_a;
  DELETE FROM public.discovery_credit_ledger WHERE tenant_id=v_a;
  DELETE FROM public.discovery_refresh_request WHERE tenant_id=v_a;
  DELETE FROM public.provider_call_budget WHERE user_id=v_a;
  DELETE FROM public.account_entitlement WHERE auth_user_id=v_a;
  DELETE FROM public.commerce_products WHERE id=v_p;
  RETURN jsonb_build_object('suite','kalodata_e2e_mock_lifecycle','status','error','error',SQLERRM);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_e2e_mock_lifecycle_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_e2e_mock_lifecycle_selftest() TO service_role;

COMMIT;

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

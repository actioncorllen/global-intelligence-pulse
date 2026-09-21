-- ============================================================================
-- mig_261_tiktok_commercial_content_executor.sql
-- STRATELOQ-TIKTOK-COMMERCIAL-CONTENT-IMPLEMENTATION-014B
--
-- Extends the EXISTING 013N research ingestion architecture with TikTok as a
-- SOCIAL_VIDEO evidence source. No parallel research system, no WPS scoring change,
-- no provider auto-dispatch change. TikTok runtime availability stays
-- SOURCE_UNSUPPORTED (BLOCKED) until a real authenticated bounded request succeeds
-- (flip is a later step, gated on that success — not done here).
--
-- VERIFIED OFFICIAL CONTRACT (developers.tiktok.com, Commercial Content API):
--   token : POST https://open.tiktokapis.com/v2/oauth/token/
--           content-type application/x-www-form-urlencoded
--           params: client_key, client_secret, grant_type=client_credentials
--           response: { access_token, expires_in=7200, token_type="Bearer" }  (no refresh token)
--   query : POST https://open.tiktokapis.com/v2/research/adlib/ad/query/
--           Authorization: Bearer <access_token>
--           body filters: search_term, country_code_list, ad_published_date_range, max_count
--           fields query param selects returned fields; response data.ads[] + search_id + has_more
--   scope : research.adlib.basic (public commercial data for research)
-- Credentials live ONLY in n8n's encrypted credential store; never in DB/repo/logs.
--
-- This migration adds:
--  1) fn_ingest_tiktok_commercial_content — normalizes a TikTok ad/query response
--     into SOCIAL_VIDEO advertising evidence (commerce_signals), mirroring the Meta
--     ingestion pattern. Never fabricates engagement/sales/virality/conversion.
--  2) fn_research_ingest_source — adds the TIKTOK -> SOCIAL_VIDEO receiver branch
--     (auth/API error -> SOURCE_FAILED; zero ads -> SEARCHED_NO_EVIDENCE; matched ads
--     -> SEARCHED_EVIDENCE_FOUND) reusing the existing terminal-state machinery.
--  3) fn_tiktok_executor_selftest — offline tests (no external call, nothing persisted).
-- ============================================================================

-- 1) TikTok Commercial Content normalizer (SOCIAL_VIDEO advertising evidence) -----
CREATE OR REPLACE FUNCTION public.fn_ingest_tiktok_commercial_content(
  p_product_id uuid, p_market text, p_ads jsonb, p_dry_run boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_gid uuid := public.fn_global_intelligence_uid(); v_prod public.commerce_products%rowtype;
  v_name text; v_mkt text := upper(btrim(coalesce(p_market,''))); ad jsonb; v_rel jsonb; v_match text;
  v_text text; v_adv text; v_adid text; v_first text; v_last text;
  v_returned int := 0; v_matched int := 0; v_likely int := 0; v_amb int := 0; v_nomatch int := 0; v_ingested int := 0;
  v_advs text[] := '{}'; v_details jsonb := '[]'::jsonb;
BEGIN
  -- auth/API-error safety: a non-array (error body / token failure) is an operational
  -- issue, NOT zero evidence. Mirrors the Meta receiver so it maps to SOURCE_FAILED.
  IF jsonb_typeof(p_ads) <> 'array' THEN
    RETURN jsonb_build_object('status','not_ad_array',
      'note','credential/API operational issue; social-video evidence unchanged, never zeroed',
      'source','TIKTOK_COMMERCIAL_CONTENT','target_market',v_mkt);
  END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  v_name := coalesce(v_prod.extended->>'normalized_name', v_prod.title);

  FOR ad IN SELECT * FROM jsonb_array_elements(p_ads) LOOP
    v_returned := v_returned + 1;
    -- defensive field extraction (TikTok nests fields under ad/advertiser variants)
    v_adid := coalesce(ad->>'id', ad->'ad'->>'id', ad->>'ad_id');
    v_adv  := coalesce(ad->>'advertiser_business_name', ad->'advertiser'->>'business_name', ad->>'advertiser_name','');
    v_text := btrim(concat_ws(' ',
                nullif(ad->'ad'->>'title',''), nullif(ad->>'ad_group_name',''),
                nullif(ad->>'search_term',''),
                (SELECT string_agg(x,' ') FROM jsonb_array_elements_text(coalesce(ad->'ad'->'texts', ad->'texts','[]'::jsonb)) x)));
    v_first := coalesce(ad->'ad'->>'first_shown_date', ad->>'first_shown_date');
    v_last  := coalesce(ad->'ad'->>'last_shown_date', ad->>'last_shown_date');
    v_rel := public.fn_meta_ad_relevance(v_name, coalesce(v_text,''), v_adv);
    v_match := v_rel->>'match';
    v_details := v_details || jsonb_build_array(jsonb_build_object('ad_id',v_adid,'advertiser',v_adv,'match',v_match));
    IF v_match='MATCHED' THEN v_matched:=v_matched+1; ELSIF v_match='LIKELY_MATCH' THEN v_likely:=v_likely+1;
    ELSIF v_match='AMBIGUOUS' THEN v_amb:=v_amb+1; ELSE v_nomatch:=v_nomatch+1; END IF;

    IF v_match IN ('MATCHED','LIKELY_MATCH') THEN
      v_advs := array_append(v_advs, nullif(v_adv,''));
      IF NOT p_dry_run THEN
        INSERT INTO public.commerce_signals(user_id,product_id,signal_type,value,evidence,provenance,confidence,observed_at,source_event_at,dedup_key,visibility)
        VALUES (v_gid, p_product_id, 'SOCIAL_VIDEO_ADVERTISING',
          -- factual presence only; NO engagement/sales/virality/conversion invented
          jsonb_build_object('market',v_mkt,'platform','TIKTOK','advertiser',v_adv,'ad_id',v_adid,
            'first_shown_date',v_first,'last_shown_date',v_last,'match',v_match),
          jsonb_build_array(jsonb_build_object('ad_id',v_adid,'advertiser',v_adv,'first_shown_date',v_first,'last_shown_date',v_last)),
          jsonb_build_object('source','TIKTOK_COMMERCIAL_CONTENT','api','research/adlib/ad/query','scope','research.adlib.basic','relevance',v_rel),
          coalesce((v_rel->>'relevance_score')::numeric,0.5), now(), nullif(v_first,'')::timestamptz,
          'tiktok:'||coalesce(v_adid, md5(ad::text)), 'GLOBAL_SAFE')
        ON CONFLICT (user_id, dedup_key) DO NOTHING;
        IF FOUND THEN v_ingested := v_ingested + 1; END IF;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('status','ok','dry_run',p_dry_run,'source','TIKTOK_COMMERCIAL_CONTENT','target_market',v_mkt,
    'ads_returned',v_returned,'MATCHED',v_matched,'LIKELY_MATCH',v_likely,'AMBIGUOUS',v_amb,'NO_MATCH',v_nomatch,
    'distinct_advertisers',(SELECT count(DISTINCT a) FROM unnest(v_advs) a WHERE a IS NOT NULL),'ingested_signals',v_ingested,
    'advertising_activity_state', CASE WHEN (v_matched+v_likely)>0 THEN 'OBSERVED' ELSE 'NO_PRODUCT_MATCH' END,
    'details',v_details);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_ingest_tiktok_commercial_content(uuid,text,jsonb,boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ingest_tiktok_commercial_content(uuid,text,jsonb,boolean) TO service_role;

-- 2) research ingest receiver: add the TIKTOK -> SOCIAL_VIDEO branch ---------------
CREATE OR REPLACE FUNCTION public.fn_research_ingest_source(
  p_run_id uuid, p_source text, p_raw jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_att public.commerce_research_source_attempt%rowtype;
  v_src text := upper(btrim(coalesce(p_source,'')));
  v_cat text; v_res jsonb; v_found boolean := false; v_failed boolean := false;
  v_t0 timestamptz; v_state text; v_note text; v_tagged int := 0; v_mkt_ebay text;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;

  v_cat := CASE v_src
    WHEN 'EBAY' THEN 'MARKETPLACE' WHEN 'META' THEN 'ADVERTISING' WHEN 'META_AD_LIBRARY' THEN 'ADVERTISING'
    WHEN 'DATAFORSEO' THEN 'SEARCH_DEMAND' WHEN 'CJ' THEN 'SUPPLIER' WHEN 'REDDIT' THEN 'COMMUNITY'
    WHEN 'TIKTOK' THEN 'SOCIAL_VIDEO'
    ELSE NULL END;
  IF v_cat IS NULL THEN RETURN jsonb_build_object('status','UNKNOWN_SOURCE','source',v_src); END IF;

  SELECT * INTO v_att FROM public.commerce_research_source_attempt
    WHERE run_id=p_run_id AND evidence_category=v_cat ORDER BY created_at LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NO_ATTEMPT_FOR_CATEGORY','category',v_cat); END IF;

  UPDATE public.commerce_research_source_attempt SET state='SEARCHING', observed_at=now() WHERE id=v_att.id;
  v_t0 := clock_timestamp();

  BEGIN
    IF v_src='EBAY' THEN
      v_mkt_ebay := 'EBAY_'||v_run.market;
      v_res := public.fn_ingest_ebay_listings(v_run.product_id, v_mkt_ebay, p_raw, false);
      v_found := (v_res->>'marketplace_activity_state') = 'OBSERVED';
      v_failed := (v_res->>'status') IN ('not_item_array','product_not_found');
    ELSIF v_src IN ('META','META_AD_LIBRARY') THEN
      v_res := public.fn_ingest_meta_ads(v_run.product_id, v_run.market, p_raw, false);
      v_found := (v_res->>'advertising_activity_state') = 'OBSERVED';
      v_failed := (v_res->>'status') IN ('not_ad_array','product_not_found');
    ELSIF v_src='DATAFORSEO' THEN
      v_res := public.fn_ingest_search_demand_for_product(v_run.product_id, v_run.market, 'DATAFORSEO', p_raw, false);
      v_found := (v_res->>'status') = 'ok';
      v_failed := (v_res->>'status') IN ('not_keyword_array','product_not_found');
    ELSIF v_src='CJ' THEN
      v_res := public.ingest_cj_supplier_products(p_raw);
      v_found := coalesce((v_res->>'ingested')::int,0) > 0 OR coalesce((v_res->>'upserted')::int,0) > 0;
      v_failed := false;
    ELSIF v_src='TIKTOK' THEN
      v_res := public.fn_ingest_tiktok_commercial_content(v_run.product_id, v_run.market, p_raw, false);
      v_found := (v_res->>'advertising_activity_state') = 'OBSERVED';
      v_failed := (v_res->>'status') IN ('not_ad_array','product_not_found');
    ELSIF v_src='REDDIT' THEN
      v_res := jsonb_build_object('status','sweep_source','note','COMMUNITY is a cross-market sweep, not a per-request fetch');
      v_found := false;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    UPDATE public.commerce_research_source_attempt
      SET state='SOURCE_FAILED', observed_at=now(), note=left('receiver error: '||SQLERRM,480),
          evidence_ref=jsonb_build_object('error','receiver_exception')
      WHERE id=v_att.id;
    RETURN jsonb_build_object('status','SOURCE_FAILED','source',v_src,'category',v_cat,'error','receiver_exception');
  END;

  -- provenance linkage: tag exactly the rows this call just inserted (same txn, new, unlinked)
  UPDATE public.commerce_signals
    SET source_run_id = p_run_id,
        provenance = coalesce(provenance,'{}'::jsonb)
          || jsonb_build_object('research_run_id',p_run_id,'source_attempt_id',v_att.id,'research_market',v_run.market)
    WHERE product_id = v_run.product_id AND created_at >= v_t0 AND source_run_id IS NULL;
  GET DIAGNOSTICS v_tagged = ROW_COUNT;

  IF v_failed THEN v_state:='SOURCE_FAILED'; v_note:='provider/credential operational issue; evidence unchanged, never zeroed';
  ELSIF v_found THEN v_state:='SEARCHED_EVIDENCE_FOUND'; v_note:='canonical evidence accepted';
  ELSE v_state:='SEARCHED_NO_EVIDENCE'; v_note:='legitimate search returned no product-relevant evidence';
  END IF;

  UPDATE public.commerce_research_source_attempt
    SET state=v_state, observed_at=now(), note=v_note,
        evidence_ref=jsonb_build_object('rows_tagged',v_tagged,
          'receiver_status',v_res->>'status',
          'marketplace_activity_state',v_res->>'marketplace_activity_state',
          'advertising_activity_state',v_res->>'advertising_activity_state',
          'buyer_intent_band',v_res->>'buyer_intent_band')
    WHERE id=v_att.id;

  RETURN jsonb_build_object('status','ok','source',v_src,'category',v_cat,'attempt_state',v_state,
    'rows_tagged',v_tagged,'receiver',v_res,'contract','pulse_research_ingest_v1_013j');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_research_ingest_source(uuid,text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_ingest_source(uuid,text,jsonb) TO service_role;

-- 3) offline selftest (no external call; nothing persisted; secrets never present) -
CREATE OR REPLACE FUNCTION public.fn_tiktok_executor_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_founder uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba'; -- kids nightlight projector
  r_zero jsonb; r_found jsonb; r_fail jsonb; r_iso jsonb; v_def text; v_ingest_def text;
BEGIN
  -- provider applicability: TikTok is a registered SOCIAL_VIDEO provider, still BLOCKED
  v := v || jsonb_build_object('case','provider_registered_social_video','pass',
        EXISTS (SELECT 1 FROM public.provider_capability_registry
                WHERE source='TIKTOK' AND evidence_category='SOCIAL_VIDEO'));
  v := v || jsonb_build_object('case','availability_still_blocked','pass',
        (SELECT availability FROM public.provider_capability_registry WHERE source='TIKTOK' AND evidence_category='SOCIAL_VIDEO')='SOURCE_UNSUPPORTED');

  -- zero-result: empty ad array is SEARCHED_NO_EVIDENCE (NO_PRODUCT_MATCH), not failure
  r_zero := public.fn_ingest_tiktok_commercial_content(v_prod,'GB','[]'::jsonb, true);
  v := v || jsonb_build_object('case','zero_result_is_no_evidence','pass',
        (r_zero->>'status'='ok' AND r_zero->>'advertising_activity_state'='NO_PRODUCT_MATCH'));

  -- evidence-found: a crafted ad naming the product matches (dry-run: NOTHING persisted)
  r_found := public.fn_ingest_tiktok_commercial_content(v_prod,'GB',
    jsonb_build_array(jsonb_build_object('id','tt_selftest_1','advertiser_business_name','Kids Nightlight Projector Store',
      'ad', jsonb_build_object('title','kids nightlight projector galaxy','first_shown_date','2026-09-01','last_shown_date','2026-09-10'))), true);
  v := v || jsonb_build_object('case','evidence_found_observed_dry_run','pass',
        (r_found->>'advertising_activity_state'='OBSERVED' AND (r_found->>'ingested_signals')::int=0));

  -- token/API failure: non-array error body -> not_ad_array (maps to SOURCE_FAILED)
  r_fail := public.fn_ingest_tiktok_commercial_content(v_prod,'GB',
    jsonb_build_object('error', jsonb_build_object('code','access_token_invalid','message','x')), true);
  v := v || jsonb_build_object('case','auth_failure_not_zeroed','pass', (r_fail->>'status'='not_ad_array'));

  -- market isolation: the market stamped is exactly the one requested
  r_iso := public.fn_ingest_tiktok_commercial_content(v_prod,'DE','[]'::jsonb, true);
  v := v || jsonb_build_object('case','market_isolation_de','pass', (r_iso->>'target_market'='DE'));

  -- executor dispatch wiring: fn_research_ingest_source routes TIKTOK -> SOCIAL_VIDEO via the normalizer
  v_def := pg_get_functiondef('public.fn_research_ingest_source'::regproc);
  v := v || jsonb_build_object('case','ingest_routes_tiktok','pass',
        (v_def ILIKE '%WHEN ''TIKTOK'' THEN ''SOCIAL_VIDEO''%' AND v_def ILIKE '%fn_ingest_tiktok_commercial_content%'));

  -- terminal-state mapping present (OBSERVED->FOUND, else NO_EVIDENCE, not_ad_array->FAILED)
  v := v || jsonb_build_object('case','terminal_state_mapping','pass',
        (v_def ILIKE '%SEARCHED_EVIDENCE_FOUND%' AND v_def ILIKE '%SEARCHED_NO_EVIDENCE%' AND v_def ILIKE '%SOURCE_FAILED%'));

  -- secret absence: no client key/secret/token literal anywhere in the shipped functions
  v_ingest_def := pg_get_functiondef('public.fn_ingest_tiktok_commercial_content'::regproc);
  v := v || jsonb_build_object('case','no_secret_in_functions','pass',
        (v_ingest_def !~* 'client_secret|client_key|access_token[^_]' AND v_def !~* 'client_secret|client_key'));

  -- no synthetic evidence persisted for the founder by this selftest
  v := v || jsonb_build_object('case','no_founder_tiktok_evidence_persisted','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_signals WHERE user_id=v_founder AND signal_type='SOCIAL_VIDEO_ADVERTISING'));

  RETURN jsonb_build_object('suite','tiktok_commercial_content_executor',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_tiktok_executor_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_tiktok_executor_selftest() TO service_role;

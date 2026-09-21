-- ============================================================================
-- mig_268_tiktok_selftest_reconcile_available.sql
-- STRATELOQ-TIKTOK-FINAL-DATE-BOUNDARY-014F.10 (selftest reconcile)
--
-- mig_261's fn_tiktok_executor_selftest asserted the pre-connection truth
-- `availability = 'SOURCE_UNSUPPORTED'` (case `availability_still_blocked`).
-- mig_267 legitimately transitioned TikTok to AVAILABLE after a real, live,
-- authenticated bounded request proved connectivity. That single assertion is
-- now stale and would report a false failure.
--
-- This migration replaces ONLY that one assertion with the post-connection
-- truth (`availability = 'AVAILABLE'`, connectivity proven). Every other case,
-- the normalizer, the ingest receiver, the terminal-state mapping, the
-- secret-absence checks and the no-synthetic-evidence guard are byte-identical
-- to mig_261. No behavioral change; no scoring change; no evidence written.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_tiktok_executor_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_founder uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba'; -- kids nightlight projector
  r_zero jsonb; r_found jsonb; r_fail jsonb; r_iso jsonb; v_def text; v_ingest_def text;
BEGIN
  -- provider applicability: TikTok is a registered SOCIAL_VIDEO provider
  v := v || jsonb_build_object('case','provider_registered_social_video','pass',
        EXISTS (SELECT 1 FROM public.provider_capability_registry
                WHERE source='TIKTOK' AND evidence_category='SOCIAL_VIDEO'));
  -- post-connection truth: availability is AVAILABLE (live-verified in 014F.10 / mig_267)
  v := v || jsonb_build_object('case','availability_now_available','pass',
        (SELECT availability FROM public.provider_capability_registry WHERE source='TIKTOK' AND evidence_category='SOCIAL_VIDEO')='AVAILABLE');

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

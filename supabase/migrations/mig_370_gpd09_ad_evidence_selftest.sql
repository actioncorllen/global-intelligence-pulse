-- mig_370 — GPD.09 Meta/TikTok advertiser-evidence regression selftest
-- Proves, on real seeded fixtures + pure-logic units, the provider-independent guarantees of
-- fn_product_ad_evidence WITHOUT changing any rights flag and WITHOUT enabling any display:
--   * authentication + tenant/product ownership gate (unauthenticated / product_not_found / cross_tenant_rejected)
--   * BE264 rights gate: META & TIKTOK uncleared -> coverage_state NOT_AUTHORISED, counts NULL, verdict UNKNOWN
--     (never turns NOT AUTHORISED into a count or a competition verdict)
--   * ADVERTISER is not SELLER (observed_sellers stays null)
--   * per-country coverage differentiation (GB/DE/IE/IT AVAILABLE vs US SOURCE_UNSUPPORTED)
--   * US raw Meta observations are withheld AND can never be classified as OBSERVED competition
--   * advertiser deduplication (distinct page_id collapses duplicate creatives) — raw predicate the reader applies
--   * country isolation / no cross-country borrowing — raw predicate, per-market partition
--   * honest zero-vs-unknown classification (missing run != zero competition)
-- Read-only except transaction-local request.jwt.claims (the proven fn_product_competitor_evidence_selftest pattern).

CREATE OR REPLACE FUNCTION public.fn_product_ad_evidence_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_checks jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0;
  v_prev_claims text;
  v_p1 uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';  -- kids nightlight projector (Meta obs in DE/GB/BE/FR)
  v_p2 uuid := '77004cbb-d7dc-4ed7-abf3-3b9d43e6e7d6';  -- coaxial cable (Meta obs in DE and US)
  v_owner uuid; v_other uuid := '11111111-1111-4111-8111-111111111111';
  v_r jsonb; v_r2 jsonb;
  de_adv int; gb_adv int; de_rows int; nodata_adv int;
BEGIN
  v_prev_claims := current_setting('request.jwt.claims', true);

  -- Owner of the fixture products (expected: founder tenant). Ownership is read from commerce_products.user_id.
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=v_p1;

  -- 1) UNAUTHENTICATED: no sub -> status unauthenticated.
  PERFORM set_config('request.jwt.claims', '{}', true);
  v_r := public.fn_product_ad_evidence(v_p1, 'DE');
  v_checks := v_checks || jsonb_build_object('check','UNAUTHENTICATED',
    'ok', v_r->>'status'='unauthenticated', 'detail', v_r->>'status');

  -- 2) PRODUCT_NOT_FOUND: authenticated owner, unknown product id.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  v_r := public.fn_product_ad_evidence('00000000-0000-4000-8000-0000000000ff', 'DE');
  v_checks := v_checks || jsonb_build_object('check','PRODUCT_NOT_FOUND',
    'ok', v_r->>'status'='product_not_found', 'detail', v_r->>'status');

  -- 3) CROSS_TENANT_REJECTED: a different tenant may not read this product's ad evidence.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_other::text)::text, true);
  v_r := public.fn_product_ad_evidence(v_p1, 'DE');
  v_checks := v_checks || jsonb_build_object('check','CROSS_TENANT_REJECTED',
    'ok', v_r->>'status' IN ('cross_tenant_rejected','product_not_found'), 'detail', v_r->>'status');

  -- Owner context for the remaining function checks.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  v_r := public.fn_product_ad_evidence(v_p1, 'DE');

  -- 4) META WITHHELD: source not analyse_cleared -> NOT_AUTHORISED, advertiser count NULL, rights_authorised false.
  v_checks := v_checks || jsonb_build_object('check','META_WITHHELD_NOT_AUTHORISED',
    'ok', (v_r->>'status'='ok'
           AND v_r->'sources'->'meta'->>'coverage_state'='NOT_AUTHORISED'
           AND jsonb_typeof(v_r->'sources'->'meta'->'observed_advertisers')='null'
           AND (v_r->'sources'->'meta'->>'rights_authorised')='false'),
    'detail', v_r->'sources'->'meta');

  -- 5) TIKTOK WITHHELD: same guarantee for the second uncleared source.
  v_checks := v_checks || jsonb_build_object('check','TIKTOK_WITHHELD_NOT_AUTHORISED',
    'ok', (v_r->'sources'->'tiktok'->>'coverage_state'='NOT_AUTHORISED'
           AND jsonb_typeof(v_r->'sources'->'tiktok'->'observed_advertisers')='null'
           AND (v_r->'sources'->'tiktok'->>'rights_authorised')='false'),
    'detail', v_r->'sources'->'tiktok');

  -- 6) TOTALS + VERDICT WITHHELD: both sources uncleared -> totals NULL, verdict UNKNOWN (never fabricated).
  v_checks := v_checks || jsonb_build_object('check','TOTALS_AND_VERDICT_WITHHELD',
    'ok', (jsonb_typeof(v_r->'observed_advertisers_total')='null'
           AND jsonb_typeof(v_r->'observed_creatives_total')='null'
           AND v_r->>'combined_competition_state'='ADVERTISING_COMPETITION_UNKNOWN'),
    'detail', jsonb_build_object('adv_total', v_r->'observed_advertisers_total',
                                 'crea_total', v_r->'observed_creatives_total',
                                 'verdict', v_r->>'combined_competition_state'));

  -- 7) ADVERTISER IS NOT SELLER: observed_sellers is intentionally null (sellers come from marketplace evidence).
  v_checks := v_checks || jsonb_build_object('check','ADVERTISER_NOT_SELLER',
    'ok', jsonb_typeof(v_r->'observed_sellers')='null', 'detail', v_r->'observed_sellers');

  -- 8) RIGHTS ENFORCEMENT lists the uncleared sources (audit-visible withholding).
  v_checks := v_checks || jsonb_build_object('check','RIGHTS_ENFORCEMENT_LISTS_UNCLEARED',
    'ok', (v_r->'rights_enforcement'->'uncleared_sources') @> '["META_AD_LIBRARY","TIKTOK"]'::jsonb,
    'detail', v_r->'rights_enforcement'->'uncleared_sources');

  -- 9) PER-COUNTRY COVERAGE DIFFERENTIATION: US is SOURCE_UNSUPPORTED for commercial all-ads; DE is AVAILABLE.
  v_r  := public.fn_product_ad_evidence(v_p2, 'US');
  v_r2 := public.fn_product_ad_evidence(v_p2, 'DE');
  v_checks := v_checks || jsonb_build_object('check','PER_COUNTRY_MARKET_STATE_DIFFERENTIATED',
    'ok', (v_r->'sources'->'meta'->>'market_state'='SOURCE_UNSUPPORTED'
           AND v_r2->'sources'->'meta'->>'market_state'='AVAILABLE'),
    'detail', jsonb_build_object('US', v_r->'sources'->'meta'->>'market_state',
                                 'DE', v_r2->'sources'->'meta'->>'market_state'));

  -- 10) US RAW OBSERVATIONS WITHHELD: US has raw Meta rows, yet the reader exposes no count (rights gate).
  v_checks := v_checks || jsonb_build_object('check','US_RAW_OBS_WITHHELD',
    'ok', (v_r->>'status'='ok'
           AND v_r->'sources'->'meta'->>'coverage_state'='NOT_AUTHORISED'
           AND jsonb_typeof(v_r->'sources'->'meta'->'observed_advertisers')='null'),
    'detail', v_r->'sources'->'meta');

  -- Restore caller claims before the rights-independent raw/pure checks.
  PERFORM set_config('request.jwt.claims', coalesce(v_prev_claims,''), true);

  -- 11) DEDUPLICATION (raw predicate the reader applies): distinct advertiser pages collapse duplicate creatives.
  SELECT count(DISTINCT coalesce(nullif(value->>'page_id',''), nullif(value->>'advertiser_page',''))), count(*)
    INTO de_adv, de_rows
  FROM public.commerce_signals
  WHERE product_id=v_p1 AND signal_type='ADVERTISING_ACTIVITY'
    AND provenance->>'source'='META_AD_LIBRARY' AND upper(coalesce(value->>'market',''))='DE';
  v_checks := v_checks || jsonb_build_object('check','DEDUP_COLLAPSES_DUPLICATES',
    'ok', (de_adv >= 1 AND de_adv < de_rows), 'detail', jsonb_build_object('distinct_advertisers',de_adv,'raw_rows',de_rows));

  -- 12) COUNTRY ISOLATION / NO BORROW (raw predicate): each market partitions independently; empty market -> 0.
  SELECT count(DISTINCT coalesce(nullif(value->>'page_id',''), nullif(value->>'advertiser_page','')))
    INTO gb_adv
  FROM public.commerce_signals
  WHERE product_id=v_p1 AND signal_type='ADVERTISING_ACTIVITY'
    AND provenance->>'source'='META_AD_LIBRARY' AND upper(coalesce(value->>'market',''))='GB';
  SELECT count(DISTINCT coalesce(nullif(value->>'page_id',''), nullif(value->>'advertiser_page','')))
    INTO nodata_adv
  FROM public.commerce_signals
  WHERE product_id=v_p1 AND signal_type='ADVERTISING_ACTIVITY'
    AND provenance->>'source'='META_AD_LIBRARY' AND upper(coalesce(value->>'market',''))='JP';
  v_checks := v_checks || jsonb_build_object('check','COUNTRY_ISOLATION_NO_BORROW',
    'ok', (de_adv > 0 AND gb_adv > 0 AND de_adv <> gb_adv AND nodata_adv = 0),
    'detail', jsonb_build_object('DE',de_adv,'GB',gb_adv,'JP_no_data',nodata_adv));

  -- 13) CLASSIFIER OBSERVED (pure fn_ad_coverage_class): adequate coverage + a positive count -> OBSERVED.
  v_r := public.fn_ad_coverage_class('AVAILABLE','SEARCHED_EVIDENCE_FOUND',5);
  v_checks := v_checks || jsonb_build_object('check','CLASSIFIER_OBSERVED',
    'ok', (v_r->>'coverage_state'='SEARCHED' AND v_r->>'zero_vs_unknown'='OBSERVED'), 'detail', v_r);

  -- 14) CLASSIFIER ZERO-WITH-COVERAGE: searched, no evidence, 0 -> positive low-competition (only from coverage).
  v_r := public.fn_ad_coverage_class('AVAILABLE','SEARCHED_NO_EVIDENCE',0);
  v_checks := v_checks || jsonb_build_object('check','CLASSIFIER_ZERO_WITH_COVERAGE',
    'ok', v_r->>'zero_vs_unknown'='ZERO_WITH_ADEQUATE_COVERAGE', 'detail', v_r);

  -- 15) CLASSIFIER US UNSUPPORTED NEVER OBSERVED: an unsupported market never yields OBSERVED, even with a count.
  v_r := public.fn_ad_coverage_class('SOURCE_UNSUPPORTED','SEARCHED_EVIDENCE_FOUND',17);
  v_checks := v_checks || jsonb_build_object('check','CLASSIFIER_US_UNSUPPORTED_NEVER_OBSERVED',
    'ok', (v_r->>'coverage_state'='UNSUPPORTED' AND v_r->>'zero_vs_unknown'='SOURCE_UNSUPPORTED'), 'detail', v_r);

  -- 16) CLASSIFIER UNKNOWN != ZERO: missing run (null attempt) with 0 count is UNKNOWN, not zero competition.
  v_r := public.fn_ad_coverage_class('AVAILABLE', NULL, 0);
  v_checks := v_checks || jsonb_build_object('check','CLASSIFIER_UNKNOWN_NOT_ZERO',
    'ok', v_r->>'zero_vs_unknown'='ADVERTISING_COMPETITION_UNKNOWN', 'detail', v_r);

  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean),
         count(*) FILTER (WHERE NOT (c->>'ok')::boolean)
    INTO v_pass, v_fail
  FROM jsonb_array_elements(v_checks) c;

  RETURN jsonb_build_object('ok', v_fail=0, 'passed',v_pass,'failed',v_fail,'total',v_pass+v_fail,
    'checks',v_checks,'contract','pulse_product_ad_evidence_selftest_v1_rights_aware',
    'generated_at', now());
END; $function$;
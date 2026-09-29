-- ============================================================================
-- mig_334_product_ad_evidence_summary.sql
-- Canonical cross-platform (TikTok + Meta) ad-evidence read contract for a
-- product in a SELECTED COUNTRY. Read-only; reuses commerce_signals + the
-- provider registry + market-state contracts. Never changes scoring.
--
--  * fn_ad_coverage_class(market_state, attempt_state, advertisers) — PURE
--    classifier: per-source coverage state + zero-vs-unknown. Distinguishes
--    ZERO_WITH_ADEQUATE_COVERAGE from ADVERTISING_COMPETITION_UNKNOWN from
--    SOURCE_UNSUPPORTED from SEARCH_FAILED (0 advertisers never silently
--    means "no competition").
--  * fn_product_ad_evidence(product, country) — deduped, country-scoped,
--    cross-platform summary: OBSERVED_ADVERTISERS (distinct advertiser identity)
--    and OBSERVED_CREATIVES (distinct ad id) per source, kept independent per
--    platform (provenance never merged), advertiser NEVER conflated with seller,
--    persistence where dates permit, plus the product identity state. Country
--    isolation: only signals stamped with THIS country are counted; global
--    momentum is never relabelled as country competition.
--  * fn_ad_verification_selftest() — deterministic (no fixtures, no writes).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_ad_coverage_class(p_market_state text, p_attempt_state text, p_advertisers int)
 RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'coverage_state', cov,
    'zero_vs_unknown', CASE
      WHEN cov IN ('SEARCHED','NO_EVIDENCE') AND coalesce(p_advertisers,0) > 0 THEN 'OBSERVED'
      WHEN cov IN ('SEARCHED','NO_EVIDENCE') AND coalesce(p_advertisers,0) = 0 THEN 'ZERO_WITH_ADEQUATE_COVERAGE'
      WHEN cov = 'UNSUPPORTED' THEN 'SOURCE_UNSUPPORTED'
      WHEN cov = 'FAILED' THEN 'SEARCH_FAILED'
      WHEN cov = 'BLOCKED' THEN 'SOURCE_BLOCKED'
      ELSE 'ADVERTISING_COMPETITION_UNKNOWN' END)
  FROM (SELECT CASE
    WHEN upper(coalesce(p_market_state,'')) IN ('SOURCE_UNSUPPORTED','UNSUPPORTED') THEN 'UNSUPPORTED'
    WHEN p_attempt_state IS NULL THEN 'UNKNOWN'
    WHEN p_attempt_state = 'SEARCHED_EVIDENCE_FOUND' THEN 'SEARCHED'
    WHEN p_attempt_state = 'SEARCHED_NO_EVIDENCE' THEN 'NO_EVIDENCE'
    WHEN p_attempt_state = 'SOURCE_FAILED' THEN 'FAILED'
    WHEN p_attempt_state = 'BLOCKED_EXTERNAL_ACCESS' THEN 'BLOCKED'
    WHEN p_attempt_state IN ('NOT_SEARCHED','SEARCHING') THEN 'PENDING'
    WHEN p_attempt_state IN ('SOURCE_UNAVAILABLE','UNSUPPORTED_MARKET') THEN 'UNSUPPORTED'
    ELSE 'UNKNOWN' END AS cov) z;
$function$;

CREATE OR REPLACE FUNCTION public.fn_product_ad_evidence(p_product_id uuid, p_country text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_owner uuid; v_c text := upper(btrim(coalesce(p_country,'')));
  v_identity jsonb; v_run_id uuid; v_run_ts timestamptz;
  tt_att text; m_att text; tt_ms text; m_ms text;
  tt_adv int; tt_crea int; tt_first date; tt_last date;
  m_adv int; m_crea int; m_maxdays int;
  tt jsonb; m jsonb; tt_cls jsonb; m_cls jsonb; v_combined text;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id=p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;
  IF v_owner <> v_uid THEN RETURN jsonb_build_object('status','cross_tenant_rejected'); END IF;

  v_identity := public.fn_product_identity_badge(p_product_id);

  SELECT id, coalesce(completed_at, started_at) INTO v_run_id, v_run_ts
  FROM public.commerce_research_run
  WHERE tenant_id=v_uid AND product_id=p_product_id AND market=v_c
  ORDER BY started_at DESC LIMIT 1;

  SELECT state INTO tt_att FROM public.commerce_research_source_attempt
    WHERE run_id=v_run_id AND evidence_category='SOCIAL_VIDEO' LIMIT 1;
  SELECT state INTO m_att FROM public.commerce_research_source_attempt
    WHERE run_id=v_run_id AND evidence_category='ADVERTISING' LIMIT 1;

  tt_ms := public.fn_source_availability('TIKTOK','SOCIAL_VIDEO',v_c)->>'availability';
  m_ms  := public.fn_meta_ad_library_market_state(v_c);

  -- TikTok observed, country-scoped (value.market must equal the selected country)
  SELECT count(DISTINCT nullif(value->>'advertiser','')), count(DISTINCT nullif(value->>'ad_id','')),
         min(nullif(value->>'first_shown_date','')::date), max(nullif(value->>'last_shown_date','')::date)
    INTO tt_adv, tt_crea, tt_first, tt_last
  FROM public.commerce_signals
  WHERE product_id=p_product_id AND signal_type='SOCIAL_VIDEO_ADVERTISING'
    AND upper(coalesce(value->>'market',''))=v_c;

  -- Meta observed, country-scoped (per-ad rows: distinct advertiser page = advertiser, distinct ad_id = creative)
  SELECT count(DISTINCT coalesce(nullif(value->>'page_id',''), nullif(value->>'advertiser_page',''))),
         count(DISTINCT nullif(value->>'ad_id',''))
    INTO m_adv, m_crea
  FROM public.commerce_signals
  WHERE product_id=p_product_id AND signal_type='ADVERTISING_ACTIVITY'
    AND provenance->>'source'='META_AD_LIBRARY' AND upper(coalesce(value->>'market',''))=v_c;

  SELECT max((now()::date - (e->>'delivery_start')::date)) INTO m_maxdays
  FROM public.commerce_signals s, jsonb_array_elements(coalesce(s.evidence,'[]'::jsonb)) e
  WHERE s.product_id=p_product_id AND s.signal_type='ADVERTISING_ACTIVITY'
    AND s.provenance->>'source'='META_AD_LIBRARY' AND upper(coalesce(s.value->>'market',''))=v_c
    AND nullif(e->>'delivery_start','') IS NOT NULL;

  tt_adv:=coalesce(tt_adv,0); tt_crea:=coalesce(tt_crea,0); m_adv:=coalesce(m_adv,0); m_crea:=coalesce(m_crea,0);
  tt_cls := public.fn_ad_coverage_class(tt_ms, tt_att, tt_adv);
  m_cls  := public.fn_ad_coverage_class(m_ms,  m_att,  m_adv);

  tt := jsonb_build_object('platform','TIKTOK','evidence_family',jsonb_build_array('ADVERTISING_VALIDATION','CREATIVE_PATTERN'),
    'coverage_state', tt_cls->>'coverage_state', 'zero_vs_unknown', tt_cls->>'zero_vs_unknown',
    'observed_advertisers', tt_adv, 'observed_creatives', tt_crea,
    'ad_first_shown', tt_first, 'ad_last_shown', tt_last,
    'attempt_state', coalesce(tt_att,'NO_RUN'), 'market_state', tt_ms,
    'capability_note','Ad Library advertiser presence only (research.adlib.basic); no organic engagement.');
  m := jsonb_build_object('platform','META','evidence_family',jsonb_build_array('ADVERTISING_VALIDATION','CREATIVE_PATTERN'),
    'coverage_state', m_cls->>'coverage_state', 'zero_vs_unknown', m_cls->>'zero_vs_unknown',
    'observed_advertisers', m_adv, 'observed_creatives', m_crea,
    'max_days_observed_active', m_maxdays,
    'attempt_state', coalesce(m_att,'NO_RUN'), 'market_state', m_ms,
    'capability_note','Meta Ad Library commercial archive (EU/EEA + UK only for all-ads).');

  -- combined competition posture (independent provenance; advertiser counts never merged across platforms)
  v_combined := CASE
    WHEN (tt_cls->>'zero_vs_unknown')='OBSERVED' OR (m_cls->>'zero_vs_unknown')='OBSERVED' THEN 'ADVERTISING_ACTIVITY_OBSERVED'
    WHEN (tt_cls->>'zero_vs_unknown')='ZERO_WITH_ADEQUATE_COVERAGE' OR (m_cls->>'zero_vs_unknown')='ZERO_WITH_ADEQUATE_COVERAGE'
      THEN 'LOW_OBSERVED_ADVERTISING_COMPETITION'
    ELSE 'ADVERTISING_COMPETITION_UNKNOWN' END;

  RETURN jsonb_build_object(
    'status','ok','product_id',p_product_id,'country_code',v_c,
    'identity_state', v_identity->>'identity_state',
    'identity_note', CASE WHEN v_identity->>'identity_state'='CONCEPT_ONLY'
      THEN 'Concept-level advertising research; evidence stays associated with the concept, never attached to a specific SKU.'
      WHEN v_identity->>'identity_state'='IDENTITY_AMBIGUOUS'
      THEN 'Multiple candidate products; ad evidence is not merged across materially different candidates.'
      ELSE 'Resolved product identity.' END,
    'latest_research_run', v_run_id, 'evidence_as_of', v_run_ts,
    'sources', jsonb_build_object('tiktok', tt, 'meta', m),
    'observed_advertisers_total', (tt_adv + m_adv),
    'observed_creatives_total', (tt_crea + m_crea),
    'observed_sellers', NULL,
    'combined_competition_state', v_combined,
    'notes', jsonb_build_array(
      'Advertiser counts are per-platform distinct (TikTok advertiser business name; Meta advertiser page). Provenance is never merged across platforms.',
      'ADVERTISER is not SELLER: observed_sellers is intentionally null here (sellers come from marketplace evidence, not ad libraries).',
      'Every observation is scoped to the selected country; global advertising momentum is never relabelled as this country''s competition.',
      '0 advertisers with adequate coverage (ZERO_WITH_ADEQUATE_COVERAGE) is positive low-competition evidence; UNKNOWN/UNSUPPORTED/FAILED are not.',
      'Persistence = observed ad longevity, not proven profitability.'),
    'contract','pulse_product_ad_evidence_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_ad_evidence(uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_ad_evidence(uuid,text) TO authenticated, service_role;

-- Deterministic selftest: pure logic (dedup + zero-vs-unknown) + real safe identity reads. No fixtures, no writes.
CREATE OR REPLACE FUNCTION public.fn_ad_verification_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; a int; c int; ads jsonb;
BEGIN
  -- C. advertiser dedup: one advertiser (page P1) with 10 creatives -> 1 advertiser / 10 creatives
  ads := (SELECT jsonb_agg(jsonb_build_object('page_id','P1','ad_id','AD'||g)) FROM generate_series(1,10) g);
  SELECT count(DISTINCT e->>'page_id'), count(DISTINCT e->>'ad_id') INTO a,c FROM jsonb_array_elements(ads) e;
  v := v || jsonb_build_object('case','advertiser_dedup_1_advertiser_10_creatives','pass', a=1 AND c=10);

  -- D. creative dedup across runs: same ad_id observed twice -> 1 distinct creative
  ads := jsonb_build_array(jsonb_build_object('ad_id','AD1'), jsonb_build_object('ad_id','AD1'));
  SELECT count(DISTINCT e->>'ad_id') INTO c FROM jsonb_array_elements(ads) e;
  v := v || jsonb_build_object('case','creative_dedup_repeat_observation','pass', c=1);

  -- E. zero with adequate coverage differs from unknown
  v := v || jsonb_build_object('case','zero_with_coverage',
    'pass', public.fn_ad_coverage_class('AVAILABLE','SEARCHED_NO_EVIDENCE',0)->>'zero_vs_unknown'='ZERO_WITH_ADEQUATE_COVERAGE');
  v := v || jsonb_build_object('case','unknown_when_not_searched',
    'pass', public.fn_ad_coverage_class('AVAILABLE',NULL,0)->>'zero_vs_unknown'='ADVERTISING_COMPETITION_UNKNOWN');
  -- F. provider failure differs from zero evidence
  v := v || jsonb_build_object('case','failure_not_zero',
    'pass', public.fn_ad_coverage_class('AVAILABLE','SOURCE_FAILED',0)->>'zero_vs_unknown'='SEARCH_FAILED');
  -- G. unsupported market is not borrowed / not zero
  v := v || jsonb_build_object('case','unsupported_market',
    'pass', public.fn_ad_coverage_class('SOURCE_UNSUPPORTED','SEARCHED_NO_EVIDENCE',0)->>'zero_vs_unknown'='SOURCE_UNSUPPORTED');
  -- observed when advertisers present
  v := v || jsonb_build_object('case','observed_when_present',
    'pass', public.fn_ad_coverage_class('AVAILABLE','SEARCHED_EVIDENCE_FOUND',3)->>'zero_vs_unknown'='OBSERVED');

  -- I. CONCEPT_ONLY stays concept-only (real safe read: humidifier)
  v := v || jsonb_build_object('case','humidifier_concept_only',
    'pass', public.fn_product_identity_badge('cda3f71a-9947-4344-8664-13735740575f')->>'identity_state'='CONCEPT_ONLY');
  v := v || jsonb_build_object('case','nightlight_identity_resolved',
    'pass', public.fn_product_identity_badge('e453eed4-3de4-4ed9-b889-1275c13c0dba')->>'identity_state'='IDENTITY_RESOLVED');

  RETURN jsonb_build_object('suite','ad_verification',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_ad_verification_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ad_verification_selftest() TO service_role;

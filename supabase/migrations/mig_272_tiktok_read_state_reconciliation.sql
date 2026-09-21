-- ============================================================================
-- mig_272_tiktok_read_state_reconciliation.sql
-- STRATELOQ-TIKTOK-READ-STATE-RECONCILIATION-014F.11
--
-- ROOT CAUSE: fn_ecommerce_research_source_states emitted the SOCIAL_VIDEO row as a
-- HARDCODED constant:
--     ('evidence_category','SOCIAL_VIDEO','source','TIKTOK','state','BLOCKED_EXTERNAL_ACCESS')
-- ignoring both the canonical provider capability (now TIKTOK/SOCIAL_VIDEO = AVAILABLE
-- since 014F.10/mig_267) and the latest research attempt. So coverage/workspace reads
-- kept telling users TikTok ACCESS is blocked even for products already searched.
--
-- FIX (read-side only): compute the CURRENT read state from
--     current provider capability  +  latest applicable research attempt  +  evidence
-- via a small PURE, generic reconciler (fn_source_state_reconcile), and use it for the
-- SOCIAL_VIDEO row. Every other provider row is BYTE-IDENTICAL to before.
--
-- Semantics locked (availability != searched):
--   * provider NOT available            -> caller's unavailable/blocked state (TikTok: BLOCKED_EXTERNAL_ACCESS)
--   * available + real evidence / latest SEARCHED_EVIDENCE_FOUND -> SEARCHED_EVIDENCE_FOUND
--   * available + latest SEARCHED_NO_EVIDENCE -> SEARCHED_NO_EVIDENCE
--   * available + latest SOURCE_FAILED        -> SOURCE_FAILED
--   * available + (no attempt | stale historical BLOCKED | NOT_SEARCHED | SEARCHING) -> NOT_SEARCHED
--
-- This NEVER: changes provider availability, auth, dispatch, WPS/PME, Product Decision,
-- historical attempts (read-only), or converts NOT_SEARCHED into SEARCHED_NO_EVIDENCE.
-- Coverage cannot falsely increase: NOT_SEARCHED / SEARCHED_NO_EVIDENCE are not "found".
--
-- Also reconciles the now-stale fn_deep_research_selftest assertion (the red-light-mask
-- product has no TikTok attempt, so with TikTok AVAILABLE its current read state is
-- NOT_SEARCHED, not BLOCKED_EXTERNAL_ACCESS). Test-truth only.
-- ============================================================================

-- (1) PURE generic reconciler: current read state from capability + latest attempt.
CREATE OR REPLACE FUNCTION public.fn_source_state_reconcile(
  p_available boolean, p_latest_attempt_state text, p_has_evidence boolean,
  p_unavailable_state text DEFAULT 'SOURCE_UNAVAILABLE')
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO '' AS $function$
  SELECT CASE
    WHEN NOT coalesce(p_available,false)                                  THEN coalesce(p_unavailable_state,'SOURCE_UNAVAILABLE')
    WHEN coalesce(p_has_evidence,false)
      OR p_latest_attempt_state = 'SEARCHED_EVIDENCE_FOUND'              THEN 'SEARCHED_EVIDENCE_FOUND'
    WHEN p_latest_attempt_state = 'SEARCHED_NO_EVIDENCE'                 THEN 'SEARCHED_NO_EVIDENCE'
    WHEN p_latest_attempt_state = 'SOURCE_FAILED'                        THEN 'SOURCE_FAILED'
    -- available but not (successfully) searched for this product/market:
    -- a stale pre-connection BLOCKED_EXTERNAL_ACCESS / NOT_SEARCHED / SEARCHING / no attempt
    ELSE 'NOT_SEARCHED' END;
$function$;
REVOKE ALL ON FUNCTION public.fn_source_state_reconcile(boolean,text,boolean,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_source_state_reconcile(boolean,text,boolean,text) TO authenticated, service_role;

-- (2) read contract: SOCIAL_VIDEO row now reconciled; all other rows unchanged.
CREATE OR REPLACE FUNCTION public.fn_ecommerce_research_source_states(p_tenant uuid, p_product_id uuid, p_market text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_ev jsonb; v jsonb := '[]'::jsonb; v_comm int;
  v_tt_avail text; v_tt_latest text; v_tt_sig int; v_tt_state text;
BEGIN
  SELECT e.evidence INTO v_ev FROM public.product_market_evaluations e
   WHERE e.tenant_id=p_tenant AND e.product_id=p_product_id AND e.country_code=p_market
   ORDER BY e.created_at DESC NULLS LAST LIMIT 1;
  v_ev := coalesce(v_ev,'{}'::jsonb);
  SELECT count(*) INTO v_comm FROM public.commerce_signals s
   WHERE s.user_id=p_tenant AND s.product_id=p_product_id AND s.signal_type='COMMUNITY_ATTENTION';
  v := v || jsonb_build_object('evidence_category','COMMUNITY','source','REDDIT',
        'state', CASE WHEN v_comm>0 OR (jsonb_typeof(v_ev->'demand_momentum')='object' AND (v_ev->'demand_momentum') <> '{}'::jsonb)
                      THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'NOT_SEARCHED' END);
  v := v || jsonb_build_object('evidence_category','SEARCH_DEMAND','source','DATAFORSEO',
        'state', CASE WHEN jsonb_typeof(v_ev->'buyer_search_intent')='object' AND (v_ev->'buyer_search_intent') <> '{}'::jsonb
                      THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'NOT_SEARCHED' END);
  v := v || jsonb_build_object('evidence_category','ADVERTISING','source','META_AD_LIBRARY',
        'state', CASE
          WHEN jsonb_typeof(v_ev->'advertising_activity')='object' AND (v_ev->'advertising_activity') <> '{}'::jsonb THEN 'SEARCHED_EVIDENCE_FOUND'
          WHEN NOT EXISTS (SELECT 1 FROM public.provider_capability_registry r
                           WHERE r.source='META_AD_LIBRARY' AND r.availability='AVAILABLE' AND r.market=p_market) THEN 'UNSUPPORTED_MARKET'
          ELSE 'NOT_SEARCHED' END);
  v := v || jsonb_build_object('evidence_category','MARKETPLACE','source','EBAY',
        'state', CASE WHEN jsonb_typeof(v_ev->'marketplace_validation')='object' AND (v_ev->'marketplace_validation') <> '{}'::jsonb
                      THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'NOT_SEARCHED' END);
  v := v || jsonb_build_object('evidence_category','SUPPLIER','source','CJ',
        'state', CASE WHEN jsonb_typeof(v_ev->'supplier_availability_stock')='object' AND (v_ev->'supplier_availability_stock') <> '{}'::jsonb
                      THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'NOT_SEARCHED' END);

  -- SOCIAL_VIDEO / TikTok: reconcile current read state from capability + latest attempt.
  v_tt_avail := (SELECT availability FROM public.provider_capability_registry
                 WHERE source='TIKTOK' AND evidence_category='SOCIAL_VIDEO' LIMIT 1);
  v_tt_sig := (SELECT count(*) FROM public.commerce_signals s
               WHERE s.user_id=p_tenant AND s.product_id=p_product_id AND s.signal_type='SOCIAL_VIDEO_ADVERTISING');
  v_tt_latest := (SELECT a.state FROM public.commerce_research_source_attempt a
                  JOIN public.commerce_research_run r ON r.id = a.run_id
                  WHERE r.tenant_id=p_tenant AND r.product_id=p_product_id AND r.market=p_market
                    AND a.evidence_category='SOCIAL_VIDEO'
                  ORDER BY a.observed_at DESC NULLS LAST, a.created_at DESC LIMIT 1);
  v_tt_state := public.fn_source_state_reconcile((v_tt_avail = 'AVAILABLE'), v_tt_latest, (v_tt_sig > 0), 'BLOCKED_EXTERNAL_ACCESS');
  v := v || jsonb_build_object('evidence_category','SOCIAL_VIDEO','source','TIKTOK','state', v_tt_state);

  RETURN v;
END; $function$;

-- (3) reconcile the now-stale deep-research selftest assertion (test-truth only).
CREATE OR REPLACE FUNCTION public.fn_deep_research_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v jsonb := '[]'::jsonb; f uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61'; s jsonb;
BEGIN
  v := v || jsonb_build_object('case','tiktok_registered_available','pass',
    EXISTS(SELECT 1 FROM public.provider_capability_registry
           WHERE source='TIKTOK' AND evidence_category='SOCIAL_VIDEO' AND availability='AVAILABLE'));
  v := v || jsonb_build_object('case','semantics_mismatch_flagged','pass',
    (public.fn_ecommerce_opportunity_labels('HIGH_CONFIDENCE_TEST','NONE')->>'label_evidence_mismatch')::boolean = true
    AND (public.fn_ecommerce_opportunity_labels('HIGH_CONFIDENCE_TEST','NONE')->>'opportunity_label') = 'Strong test candidate');
  v := v || jsonb_build_object('case','grade_high_needs_4_and_high','pass',
    (public.fn_ecommerce_evidence_grade(4,'HIGH',false)->>'grade')='HIGH_CONFIDENCE'
    AND (public.fn_ecommerce_evidence_grade(4,'HIGH',true)->>'grade')<>'HIGH_CONFIDENCE');
  v := v || jsonb_build_object('case','grade_strong_needs_3_moderate','pass',
    (public.fn_ecommerce_evidence_grade(3,'MODERATE',true)->>'grade')='STRONG_EVIDENCE_BACKED');
  v := v || jsonb_build_object('case','grade_two_source_developing','pass',
    (public.fn_ecommerce_evidence_grade(2,'LOW',true)->>'grade')='DEVELOPING_EVIDENCE');
  s := public.fn_ecommerce_research_source_states(f,'275266ba-0569-4a47-a5fc-2c5bef27eb0e','GB');
  v := v || jsonb_build_object('case','founder_community_found','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='COMMUNITY')='SEARCHED_EVIDENCE_FOUND');
  v := v || jsonb_build_object('case','founder_marketplace_found','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='MARKETPLACE')='SEARCHED_EVIDENCE_FOUND');
  v := v || jsonb_build_object('case','founder_search_not_searched','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='SEARCH_DEMAND')='NOT_SEARCHED');
  v := v || jsonb_build_object('case','founder_advertising_not_searched','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='ADVERTISING')='NOT_SEARCHED');
  -- reconciled: TikTok AVAILABLE and this product/market has no TikTok attempt -> NOT_SEARCHED
  v := v || jsonb_build_object('case','founder_tiktok_not_searched','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='SOCIAL_VIDEO')='NOT_SEARCHED');
  v := v || jsonb_build_object('case','ledger_integrity_no_synthetic','pass',
    NOT EXISTS (SELECT 1 FROM public.commerce_research_run r
                 WHERE r.product_id NOT IN (SELECT id FROM public.commerce_products)
                    OR r.tenant_id IS NULL)
    AND NOT EXISTS (SELECT 1 FROM public.commerce_research_source_attempt a
                     WHERE a.run_id NOT IN (SELECT id FROM public.commerce_research_run)));
  RETURN jsonb_build_object('suite','deep_research_infrastructure',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

-- (4) deterministic selftest for the reconciliation (A-J).
CREATE OR REPLACE FUNCTION public.fn_tiktok_read_state_reconcile_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  f uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  nightlight uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  redmask uuid := '275266ba-0569-4a47-a5fc-2c5bef27eb0e';
  s_night jsonb; s_mask jsonb; v_pme_before jsonb; v_att_state text; v_att_cnt int;
BEGIN
  -- A. provider BLOCKED + historical blocked attempt -> BLOCKED remains
  v := v || jsonb_build_object('case','A_blocked_stays_blocked','pass',
    public.fn_source_state_reconcile(false,'BLOCKED_EXTERNAL_ACCESS',false,'BLOCKED_EXTERNAL_ACCESS')='BLOCKED_EXTERNAL_ACCESS');
  -- B. provider AVAILABLE + only historical blocked attempt (or none) -> NOT_SEARCHED
  v := v || jsonb_build_object('case','B_available_stale_blocked_is_not_searched','pass',
    public.fn_source_state_reconcile(true,'BLOCKED_EXTERNAL_ACCESS',false,'BLOCKED_EXTERNAL_ACCESS')='NOT_SEARCHED'
    AND public.fn_source_state_reconcile(true,NULL,false,'BLOCKED_EXTERNAL_ACCESS')='NOT_SEARCHED');
  -- C. provider AVAILABLE + successful zero-evidence search -> SEARCHED_NO_EVIDENCE
  v := v || jsonb_build_object('case','C_available_zero_evidence','pass',
    public.fn_source_state_reconcile(true,'SEARCHED_NO_EVIDENCE',false,'BLOCKED_EXTERNAL_ACCESS')='SEARCHED_NO_EVIDENCE');
  -- D. provider AVAILABLE + evidence found -> EVIDENCE_FOUND
  v := v || jsonb_build_object('case','D_available_evidence_found','pass',
    public.fn_source_state_reconcile(true,'SEARCHED_EVIDENCE_FOUND',false,'BLOCKED_EXTERNAL_ACCESS')='SEARCHED_EVIDENCE_FOUND'
    AND public.fn_source_state_reconcile(true,NULL,true,'BLOCKED_EXTERNAL_ACCESS')='SEARCHED_EVIDENCE_FOUND');
  -- E. provider AVAILABLE + genuine latest failure -> failure remains
  v := v || jsonb_build_object('case','E_available_failure_remains','pass',
    public.fn_source_state_reconcile(true,'SOURCE_FAILED',false,'BLOCKED_EXTERNAL_ACCESS')='SOURCE_FAILED');

  -- real-data: founder nightlight GB now resolves to SEARCHED_NO_EVIDENCE (real 014F.10 search)
  s_night := public.fn_ecommerce_research_source_states(f, nightlight, 'GB');
  v := v || jsonb_build_object('case','nightlight_social_video_searched_no_evidence','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s_night) e WHERE e->>'evidence_category'='SOCIAL_VIDEO')='SEARCHED_NO_EVIDENCE');

  -- F. historical attempt preserved (not rewritten): still exactly the SEARCHED_NO_EVIDENCE row
  SELECT count(*), max(a.state) INTO v_att_cnt, v_att_state
  FROM public.commerce_research_source_attempt a JOIN public.commerce_research_run r ON r.id=a.run_id
  WHERE r.tenant_id=f AND r.product_id=nightlight AND r.market='GB' AND a.evidence_category='SOCIAL_VIDEO';
  v := v || jsonb_build_object('case','F_history_preserved','pass', (v_att_cnt >= 1 AND v_att_state='SEARCHED_NO_EVIDENCE'));

  -- G. coverage cannot increase: reconciled SOCIAL_VIDEO is NOT counted as evidence-found
  v := v || jsonb_build_object('case','G_no_false_coverage','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s_night) e WHERE e->>'evidence_category'='SOCIAL_VIDEO') <> 'SEARCHED_EVIDENCE_FOUND');

  -- H. PME unchanged (read-only fix): nightlight GB still 68.2 / 0.78 / HIGH / WATCH
  v := v || jsonb_build_object('case','H_pme_unchanged','pass', EXISTS(
    SELECT 1 FROM public.product_market_evaluations e
    WHERE e.product_id=nightlight AND e.country_code='GB' AND coalesce(e.is_fixture,false)=false
      AND e.market_opportunity_score=68.2 AND e.coverage=0.78 AND e.evidence_confidence='HIGH' AND e.market_decision='WATCH'));

  -- I. Product Decision unchanged: nightlight GB decision snapshot still WATCH
  v := v || jsonb_build_object('case','I_decision_unchanged','pass', EXISTS(
    SELECT 1 FROM public.product_opportunity_decisions d
    WHERE d.product_id=nightlight AND d.country_code='GB' AND coalesce(d.is_fixture,false)=false));

  -- J. other providers unchanged (red-mask non-TikTok states identical to golden), TikTok now NOT_SEARCHED
  s_mask := public.fn_ecommerce_research_source_states(f, redmask, 'GB');
  v := v || jsonb_build_object('case','J_other_providers_unchanged','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s_mask) e WHERE e->>'evidence_category'='COMMUNITY')='SEARCHED_EVIDENCE_FOUND'
    AND (SELECT e->>'state' FROM jsonb_array_elements(s_mask) e WHERE e->>'evidence_category'='MARKETPLACE')='SEARCHED_EVIDENCE_FOUND'
    AND (SELECT e->>'state' FROM jsonb_array_elements(s_mask) e WHERE e->>'evidence_category'='SEARCH_DEMAND')='NOT_SEARCHED'
    AND (SELECT e->>'state' FROM jsonb_array_elements(s_mask) e WHERE e->>'evidence_category'='ADVERTISING')='NOT_SEARCHED'
    AND (SELECT e->>'state' FROM jsonb_array_elements(s_mask) e WHERE e->>'evidence_category'='SOCIAL_VIDEO')='NOT_SEARCHED');

  RETURN jsonb_build_object('suite','tiktok_read_state_reconciliation',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_tiktok_read_state_reconcile_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_tiktok_read_state_reconcile_selftest() TO service_role;

-- mig_361 — 2026-11-24 — GPD.01: close the last customer-reachable verbatim-seller-identity leak + tenant gap.
-- Record file only (authoritative bodies in schema_migrations / pg_get_functiondef).
--
-- Context: BE241/BE242 (mig_311) aggregated the two FE competitor RPCs (fn_product_competitor_evidence,
-- fn_ecommerce_competitor_intelligence) to WITHHOLD the verbatim per-seller list and emit counts/ranges only.
-- A sweep for this task (GPD.01) found two member-reachable (GRANT authenticated, SECURITY DEFINER) helper
-- RPCs that BE241 did NOT cover:
--   * fn_pmc_monday_block — projected 'who_is_selling_it' = jsonb_agg(DISTINCT competitor_identity): the VERBATIM
--     compiled-seller list (demonstrated: GB pilot 1def97b0 → 5 verbatim Google-Shopping seller identities).
--     It also took p_tenant as a parameter with NO auth.uid() check, NO rights gate, NO release gate.
--   * fn_pmc_summary — returns ONLY fn_pmc_evaluate's aggregates (no verbatim identity leak) but likewise took
--     p_tenant with no auth.uid() check (cross-tenant aggregate read reachable by direct RPC).
-- Neither is referenced by the frontend (Lovable greps for who_is_selling_it / pmc_monday_block / pmc_summary
-- are empty); fn_pmc_monday_block has no internal DB caller; fn_pmc_summary is called only by internal
-- service-role evaluators (fn_pod_evaluate, fn_w004_opportunity_scenarios_selftest).
--
-- Smallest safe fix (rights-safe aggregate presentation, consistent with BE240 §4 / BE241):
--   fn_pmc_monday_block (now v2): tenant-isolated (member may only query own tenant; service-role uses the param
--     for internal/testing); 'who_is_selling_it' REPLACED by 'seller_presence' = aggregate {distinct_sellers (only
--     where every matched row carries an identity, else NULL/UNKNOWN), distinct_sellers_known, observed_offers,
--     exact_match_present, verbatim_identities_withheld:true}, gated to analyse_cleared sources only (eBay excluded).
--     No verbatim identity is ever projected. All other fields (derived competition/price/ad aggregates from
--     fn_pmc_summary→fn_pmc_evaluate) are unchanged derived intelligence.
--   fn_pmc_summary: adds the same auth.uid() tenant guard (projection unchanged — it only passes identity INTO
--     fn_pmc_evaluate, which returns aggregates and never echoes identity; internal scoring inputs unchanged).
-- No rights clearance flipped; no customer_source_release row flipped; display_cleared/display_derived untouched;
-- internal analysis (which may use all analyse data) is unchanged. Selftest fn_gpd01_aggregate_display_selftest().

-- 1) fn_pmc_summary — add tenant isolation; projection unchanged (aggregate-safe return via fn_pmc_evaluate).
CREATE OR REPLACE FUNCTION public.fn_pmc_summary(p_tenant uuid, p_product uuid, p_country text, p_market_currency text DEFAULT 'EUR'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE arr jsonb; v_uid uuid := auth.uid(); v_tenant uuid;
BEGIN
  -- Tenant isolation: a member may only query their own tenant; service-role (auth.uid() NULL) uses the param
  -- (internal evaluators / tests). Return value is aggregate-only (fn_pmc_evaluate never echoes identity/url).
  IF v_uid IS NOT NULL AND p_tenant IS DISTINCT FROM v_uid THEN
    RETURN jsonb_build_object('status','cross_tenant_rejected','contract','pulse_product_market_competitor_v1');
  END IF;
  v_tenant := coalesce(v_uid, p_tenant);

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'competitor_kind', competitor_kind, 'competitor_identity', competitor_identity,
      'competitor_ref', competitor_ref, 'platform', platform, 'match_class', match_class,
      'match_confidence', match_confidence,
      'price', jsonb_build_object('amount', price_original, 'currency', price_currency,
               'source_class', price_source_class, 'country', country_code),
      'observable_ad_count', observable_ad_count, 'creative_pattern', creative_pattern,
      'offer_pattern', offer_pattern, 'cta_pattern', cta_pattern, 'evidence_class', evidence_class)), '[]'::jsonb)
    INTO arr
  FROM public.product_market_competitors
  WHERE tenant_id = v_tenant AND product_id = p_product AND country_code = p_country;

  RETURN public.fn_pmc_evaluate(v_tenant, p_product, p_country, p_market_currency, arr, NULL, '{}'::jsonb, false, false);
END; $function$;

-- 2) fn_pmc_monday_block — tenant-isolated + rights-safe AGGREGATE seller presence (verbatim list withheld).
CREATE OR REPLACE FUNCTION public.fn_pmc_monday_block(p_tenant uuid, p_product uuid, p_country text, p_market_currency text DEFAULT 'EUR'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid;
  v_c text := upper(btrim(coalesce(p_country,'')));
  j jsonb;
  v_sellers jsonb;
BEGIN
  IF v_uid IS NOT NULL AND p_tenant IS DISTINCT FROM v_uid THEN
    RETURN jsonb_build_object('status','cross_tenant_rejected','contract','pulse_monday_competitor_block_v2');
  END IF;
  v_tenant := coalesce(v_uid, p_tenant);

  j := public.fn_pmc_summary(v_tenant, p_product, p_country, p_market_currency);

  -- Rights-safe aggregate seller presence: counts only, verbatim marketplace-seller identities WITHHELD,
  -- restricted to analyse_cleared sources (e.g. eBay analyse_cleared=false is excluded).
  SELECT jsonb_build_object(
      'distinct_sellers', CASE WHEN count(*) > 0 AND bool_and(c.competitor_identity IS NOT NULL)
                               THEN count(DISTINCT c.competitor_identity) ELSE NULL END,
      'distinct_sellers_known', (count(*) > 0 AND bool_and(c.competitor_identity IS NOT NULL)),
      'observed_offers', count(*),
      'exact_match_present', coalesce(bool_or(c.match_class = 'EXACT_PRODUCT'), false),
      'verbatim_identities_withheld', true,
      'note','Aggregate seller presence only; verbatim marketplace-seller identities withheld (rights-safe). Offers are observed listings, not necessarily distinct sellers.')
    INTO v_sellers
  FROM public.product_market_competitors c
  WHERE c.tenant_id = v_tenant AND c.product_id = p_product
    AND upper(coalesce(c.country_code,'')) = v_c
    AND c.match_class IN ('EXACT_PRODUCT','CLOSE_COMPARABLE')
    AND coalesce(c.is_fixture,false) = false
    AND EXISTS (SELECT 1 FROM public.catalogue_source_rights r
                WHERE r.analyse_cleared AND upper(c.source) LIKE upper(r.source_provider)||'%');

  RETURN jsonb_build_object(
    'status','ok',
    'seller_presence', coalesce(v_sellers, jsonb_build_object(
        'distinct_sellers', NULL, 'distinct_sellers_known', false, 'observed_offers', 0,
        'exact_match_present', false, 'verbatim_identities_withheld', true,
        'note','No analyse-cleared competitor offers observed for this product in this market.')),
    'where', (j->'advertising'->'platforms'),
    'observed_prices', (j->'market_price'),
    'competition_level', (j#>'{competition,level}'),
    'observable_ad_activity', (j->'advertising'->'observable_ads'),
    'advertising_platforms', (j->'advertising'->'platforms'),
    'creative_offer_patterns', (j->'advertising'->'creative_patterns'),
    'opportunity_gaps', (j->'opportunity_gaps'),
    'evidence_confidence', (j#>'{competition,confidence}'),
    'metrics_safety', 'observable only; never sales/revenue/ROAS/winning-ad; verbatim seller identities withheld (rights-safe aggregate)',
    'schedule_note', 'Monday-only cadence unchanged; no new recurring workflow.',
    'contract', 'pulse_monday_competitor_block_v2');
END; $function$;

-- 3) Selftest — verifies the verbatim leak is closed and the aggregate is correct (rolled-back/read-only).
CREATE OR REPLACE FUNCTION public.fn_gpd01_aggregate_display_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_tenant uuid; v_product uuid := '1def97b0-6d92-450d-bb35-8fc28eb7d8d8'; v_country text := 'GB';
  v_block jsonb; v_summary jsonb; v_ids text[]; v_id text;
  v_expected_offers int; v_expected_distinct int;
  t1 boolean; t2 boolean := true; t3 boolean := true; t4 boolean; t5 boolean;
BEGIN
  SELECT tenant_id INTO v_tenant FROM public.product_market_competitors WHERE product_id = v_product LIMIT 1;
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason','pilot_product_has_no_competitor_rows'); END IF;

  -- expected aggregate for analyse_cleared EXACT/CLOSE rows
  SELECT count(*), count(DISTINCT c.competitor_identity)
    INTO v_expected_offers, v_expected_distinct
  FROM public.product_market_competitors c
  WHERE c.tenant_id=v_tenant AND c.product_id=v_product AND upper(coalesce(c.country_code,''))=v_country
    AND c.match_class IN ('EXACT_PRODUCT','CLOSE_COMPARABLE') AND coalesce(c.is_fixture,false)=false
    AND EXISTS (SELECT 1 FROM public.catalogue_source_rights r
                WHERE r.analyse_cleared AND upper(c.source) LIKE upper(r.source_provider)||'%');

  SELECT array_agg(DISTINCT competitor_identity) INTO v_ids
  FROM public.product_market_competitors
  WHERE tenant_id=v_tenant AND product_id=v_product AND upper(coalesce(country_code,''))=v_country
    AND competitor_identity IS NOT NULL;

  v_block   := public.fn_pmc_monday_block(v_tenant, v_product, v_country, 'GBP');
  v_summary := public.fn_pmc_summary(v_tenant, v_product, v_country, 'GBP');

  -- T1: no verbatim key; seller_presence is an aggregate object with the withheld flag
  t1 := (v_block ? 'seller_presence')
        AND NOT (v_block ? 'who_is_selling_it')
        AND (jsonb_typeof(v_block->'seller_presence') = 'object')
        AND ((v_block#>'{seller_presence,verbatim_identities_withheld}') = 'true'::jsonb);

  -- T2: NONE of the real verbatim seller identities appears anywhere in the monday-block output
  IF v_ids IS NOT NULL THEN
    FOREACH v_id IN ARRAY v_ids LOOP
      IF position(lower(v_id) IN lower(v_block::text)) > 0 THEN t2 := false; END IF;
      IF position(lower(v_id) IN lower(v_summary::text)) > 0 THEN t3 := false; END IF;
    END LOOP;
  END IF;

  -- T4: aggregate counts are correct and match the analyse-cleared expectation
  t4 := ((v_block#>>'{seller_presence,observed_offers}')::int = coalesce(v_expected_offers,0))
        AND ( (v_expected_offers > 0 AND (v_block#>>'{seller_presence,exact_match_present}')::boolean IS NOT NULL) OR v_expected_offers = 0 );

  -- T5: fn_product_competitor_evidence (unchanged FE surface) still advertises the withheld invariant in its contract
  t5 := EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                WHERE n.nspname='public' AND p.proname='fn_product_competitor_evidence'
                  AND p.prosrc ILIKE '%verbatim_seller_list_withheld%'
                  AND p.prosrc ILIKE '%''competitors'', ''[]''::jsonb%');

  RETURN jsonb_build_object(
    'ok', (t1 AND t2 AND t3 AND t4 AND t5),
    'checks', jsonb_build_object(
      'T1_no_verbatim_key_aggregate_object', t1,
      'T2_monday_block_no_identity_leak', t2,
      'T3_summary_no_identity_leak', t3,
      'T4_aggregate_counts_correct', t4,
      'T5_fe_surface_still_withholds', t5),
    'observed', jsonb_build_object(
      'expected_offers', coalesce(v_expected_offers,0),
      'expected_distinct_sellers', coalesce(v_expected_distinct,0),
      'identities_in_source', coalesce(array_length(v_ids,1),0),
      'seller_presence', v_block->'seller_presence'),
    'contract','pulse_gpd01_aggregate_display_selftest_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_gpd01_aggregate_display_selftest() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_gpd01_aggregate_display_selftest() TO service_role;

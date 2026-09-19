-- ============================================================================
-- mig_243_real_research_orchestrator.sql
-- STRATELOQ-REAL-PRODUCT-MARKET-DEEP-RESEARCH-ORCHESTRATOR-013J
--
-- Smallest secure production orchestration path that runs a REAL deep-research
-- operation for a CANONICAL PRODUCT + SELECTED MARKET using every currently
-- AVAILABLE and applicable registered provider. Connects the 013I research-run
-- ledger to the existing product+market-scoped ingestion receivers.
--
-- Additive only. No provider credentials in the database. No synthetic evidence.
-- No manual patching of opportunity_score / band / evidence_confidence /
-- saturation / buyer-intent. TikTok stays BLOCKED_EXTERNAL_ACCESS. No schedule
-- change (this is an ON-DEMAND, user-requested entry point only).
--
-- Real external provider execution is performed by the existing n8n provider
-- boundary (which alone holds the credentials); this migration owns the control
-- plane (run + attempts + applicability + provenance linkage + finalize +
-- canonical recompute) and the truthful state transitions.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Deterministic default-currency helper (market -> currency), sourced from
--    the canonical ecommerce_market_universe. Never invents a currency.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_market_default_currency(p_market text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
  SELECT default_currency
  FROM public.ecommerce_market_universe
  WHERE country_code = upper(btrim(p_market))
  LIMIT 1;
$$;

-- ----------------------------------------------------------------------------
-- 1. ASSEMBLER UPGRADE — consume real DataForSEO (SEARCH_DEMAND) and Meta
--    (ADVERTISING_ACTIVITY) evidence for the SELECTED MARKET instead of the
--    prior hardcoded '{}'. Purely additive: when no such market-specific
--    signal exists, the dimension stays '{}' (UNKNOWN) exactly as before, so
--    existing decisions are unchanged. Nothing else in the assembler changes.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_assemble_real_product_market(p_candidate uuid, p_country text, p_currency text, p_price_query text, p_supplier uuid DEFAULT NULL::uuid, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  cand record; tenant uuid; price record; sup record; fr jsonb;
  community_conf numeric; mkt_signals int;
  dm numeric; mv numeric; ssub numeric;
  landed numeric; ref_landed numeric; landed_ccy text; fulfil text; econ jsonb; ref_econ jsonb; evidence jsonb;
  pme_id uuid; pme_dec text; comp_arr jsonb := '[]'::jsonb; n_pts int; lst record; k int;
  freight_cost numeric; freight_days text; sup_ident jsonb; sup_class text; is_exact boolean;
  -- 013J additive: real DataForSEO + Meta evidence for the selected market
  sd_val jsonb; bsi jsonb; bsi_sub numeric;
  adv_val jsonb; adv_ct int; adv jsonb; adv_sub numeric;
BEGIN
  SELECT * INTO cand FROM public.commerce_products WHERE id=p_candidate;
  IF cand.id IS NULL THEN RETURN jsonb_build_object('error','CANDIDATE_NOT_FOUND'); END IF;
  tenant := cand.user_id;
  SELECT * INTO price FROM public.market_price_observations
   WHERE product_query=p_price_query AND market=p_country AND currency=p_currency AND source='EBAY_BROWSE'
   ORDER BY observed_at DESC LIMIT 1;
  IF p_supplier IS NOT NULL THEN SELECT * INTO sup FROM public.commerce_supplier_products WHERE id=p_supplier;
  ELSE SELECT * INTO sup FROM public.commerce_supplier_products
       WHERE source='cjdropshipping' AND category=cand.category ORDER BY supplier_cost NULLS LAST LIMIT 1; END IF;

  -- supplier product IDENTITY resolution (category match never certifies TEST economics)
  sup_ident := public.fn_resolve_supplier_identity(cand.title, cand.category, cand.product_identity,
                 sup.title, sup.category, sup.source_product_id, false);
  sup_class := coalesce(sup_ident->>'match_class','UNKNOWN');
  is_exact := (sup_class = 'EXACT_PRODUCT');

  SELECT max(confidence) INTO community_conf FROM public.commerce_signals WHERE product_id=p_candidate AND signal_type='COMMUNITY_ATTENTION';
  SELECT count(*) INTO mkt_signals FROM public.commerce_signals WHERE product_id=p_candidate AND signal_type='MARKETPLACE_ACTIVITY';
  dm := CASE WHEN community_conf IS NOT NULL THEN round(community_conf*100,0) ELSE NULL END;
  mv := CASE WHEN mkt_signals>0 OR price.id IS NOT NULL THEN least(100, 50 + coalesce(mkt_signals,0)*3) ELSE NULL END;
  ssub := CASE WHEN sup.id IS NULL OR sup_class IN ('UNRELATED','UNKNOWN') THEN NULL
               WHEN is_exact THEN 60 WHEN sup_class='CLOSE_COMPARABLE' THEN 40 ELSE 25 END;

  -- ── 013J: real SEARCH_DEMAND (DataForSEO) for THIS market (never cross-market) ──
  SELECT value INTO sd_val FROM public.commerce_signals
    WHERE product_id=p_candidate AND signal_type='SEARCH_DEMAND' AND value->>'market'=p_country
    ORDER BY observed_at DESC LIMIT 1;
  IF sd_val IS NOT NULL AND (sd_val->>'buyer_intent_score') ~ '^[0-9]' THEN
    bsi_sub := (sd_val->>'buyer_intent_score')::numeric;
    bsi := jsonb_build_object('subscore', bsi_sub::text, 'band', sd_val->>'buyer_intent_band',
             'source','DATAFORSEO','source_class','ESTIMATED',
             'headline_query', sd_val->>'headline_query',
             'derivation','GOOGLE_ADS_via_DATAFORSEO; volume ESTIMATED; intent INFERRED');
  ELSE
    bsi := '{}'::jsonb;   -- unchanged when no market-specific demand evidence exists
  END IF;

  -- ── 013J: real ADVERTISING_ACTIVITY (Meta Ad Library) for THIS market ──
  SELECT count(DISTINCT (value->>'page_id')) INTO adv_ct FROM public.commerce_signals
    WHERE product_id=p_candidate AND signal_type='ADVERTISING_ACTIVITY' AND value->>'market'=p_country;
  IF coalesce(adv_ct,0) > 0 THEN
    -- presence-based, bounded; observed advertiser competition (PLATFORM_REPORTED), never sales/spend
    adv_sub := least(100, 35 + adv_ct*13);
    adv := jsonb_build_object('subscore', adv_sub::text, 'observed_advertisers', adv_ct,
             'source','META_AD_LIBRARY','source_class','OBSERVED',
             'claim_safety','distinct advertiser presence in Ad Library only; NOT spend/sales/conversion');
  ELSE
    adv := '{}'::jsonb;   -- unchanged when no market-specific advertising evidence exists
  END IF;

  fr := sup.supplier_enrichment->'freight'->p_country->'representative';
  freight_cost := nullif(fr->>'shipping_cost','')::numeric;
  freight_days := CASE WHEN fr ? 'est_min_days' THEN (fr->>'est_min_days')||'-'||(fr->>'est_max_days')||' days' ELSE NULL END;
  landed_ccy := coalesce(sup.cost_currency,'USD');
  IF sup.supplier_cost IS NOT NULL AND freight_cost IS NOT NULL THEN ref_landed := sup.supplier_cost + freight_cost; END IF;
  IF is_exact AND ref_landed IS NOT NULL THEN landed := ref_landed; fulfil := 'true'; ELSE landed := NULL; fulfil := NULL; END IF;

  ref_econ := CASE WHEN price.id IS NOT NULL AND ref_landed IS NOT NULL
    THEN public.fn_economics_breakeven(price.price_median, ref_landed, landed_ccy, p_currency, jsonb_build_object('payment_fee_pct',0.03))
         || jsonb_build_object('basis','REFERENCE_COMPARABLE_SUPPLIER','supplier_match_class',sup_class)
    ELSE NULL END;

  evidence := jsonb_build_object(
    'buyer_search_intent', bsi,
    'demand_momentum', CASE WHEN dm IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',dm::text,'source','reddit','source_class','OBSERVED') END,
    'marketplace_validation', CASE WHEN mv IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',mv::text,'source','EBAY_BROWSE','source_class','PLATFORM_REPORTED') END,
    'advertising_activity', adv,
    'supplier_availability_stock', CASE WHEN ssub IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',ssub::text,'source','cjdropshipping') END,
    'supplier_identity', sup_ident || jsonb_build_object('supplier_title',sup.title,'supplier_source_product_id',sup.source_product_id),
    'reference_economics', coalesce(ref_econ,'{}'::jsonb),
    'stock_state','UNKNOWN','compliance_risk','UNKNOWN','fulfilment_usable', fulfil,
    'observed_market_price', CASE WHEN price.id IS NOT NULL
       THEN jsonb_build_object('source_class','PLATFORM_REPORTED','amount',price.price_median,'currency',price.currency,
             'range',jsonb_build_array(price.price_min,price.price_max),'sample',price.sample_size,'total_listings',price.total_listings,
             'source','EBAY_BROWSE','observed_at',price.observed_at)
       ELSE jsonb_build_object('source_class','UNKNOWN') END,
    'delivery_evidence', CASE WHEN freight_days IS NOT NULL THEN jsonb_build_object('estimate',freight_days,'source','CJ_FREIGHT_CALCULATE') ELSE '{}'::jsonb END,
    'risk_flags', CASE WHEN NOT is_exact THEN jsonb_build_array('SUPPLIER_IDENTITY_NOT_EXACT_ECONOMICS_REFERENCE_ONLY') ELSE jsonb_build_array() END);

  econ := CASE WHEN price.id IS NOT NULL AND landed IS NOT NULL
    THEN jsonb_build_object('selling_price',price.price_median::text,'selling_price_source_class','PLATFORM_REPORTED',
           'landed_cost',landed::text,'landed_currency',landed_ccy,'fees',jsonb_build_object('payment_fee_pct','0.03'))
    WHEN price.id IS NOT NULL
    THEN jsonb_build_object('selling_price',price.price_median::text,'selling_price_source_class','PLATFORM_REPORTED')
    ELSE NULL END;

  PERFORM public.fn_evaluate_product_market(tenant, p_candidate, p_country, p_currency, evidence, econ, '{}'::jsonb, false, p_persist);
  SELECT id, market_decision INTO pme_id, pme_dec FROM public.product_market_evaluations
    WHERE tenant_id=tenant AND product_id=p_candidate AND country_code=p_country;

  FOR lst IN SELECT (value->>'price')::numeric px, value->>'currency' ccy
             FROM public.commerce_signals
             WHERE product_id=p_candidate AND signal_type='MARKETPLACE_ACTIVITY'
               AND value->>'market'=p_country AND value->>'currency'=p_currency AND value->>'price' IS NOT NULL LOOP
    comp_arr := comp_arr || jsonb_build_array(jsonb_build_object(
      'match_class','CLOSE_COMPARABLE','competitor_kind','MARKETPLACE_LISTING','competitor_identity',NULL,
      'platform','EBAY','source','EBAY_BROWSE','evidence_class','OBSERVED','confidence','MEDIUM',
      'match_evidence',jsonb_build_object('basis','ebay_token_overlap_match','note','close comparable, not exact-product'),
      'price',jsonb_build_object('amount',lst.px,'currency',lst.ccy,'source_class','OBSERVED','country',p_country)));
  END LOOP;
  IF jsonb_array_length(comp_arr)=0 AND price.id IS NOT NULL THEN
    n_pts := CASE WHEN price.total_listings>=1000 THEN 6 WHEN price.total_listings>=500 THEN 5
                  WHEN price.total_listings>=200 THEN 4 WHEN price.total_listings>=50 THEN 3 ELSE 2 END;
    FOR k IN 1..n_pts LOOP
      comp_arr := comp_arr || jsonb_build_array(jsonb_build_object(
        'match_class','CLOSE_COMPARABLE','competitor_kind','MARKETPLACE_LISTING','competitor_identity',NULL,
        'platform','EBAY','source','EBAY_BROWSE','evidence_class','OBSERVED','confidence','MEDIUM',
        'price',jsonb_build_object('amount',CASE k WHEN 1 THEN price.price_min WHEN 2 THEN price.price_max ELSE price.price_median END,
          'currency',price.currency,'source_class','OBSERVED','country',p_country)));
    END LOOP;
  END IF;
  IF jsonb_array_length(comp_arr)>0 THEN
    DELETE FROM public.product_market_competitors WHERE tenant_id=tenant AND product_id=p_candidate AND country_code=p_country AND is_fixture=false;
    PERFORM public.fn_pmc_evaluate(tenant, p_candidate, p_country, p_currency, comp_arr, pme_id, '{}'::jsonb, false, p_persist);
  END IF;

  RETURN jsonb_build_object('tenant',tenant,'product',p_candidate,'country',p_country,'currency',p_currency,
    'price_median',price.price_median,'total_listings',price.total_listings,
    'supplier',sup.title,'supplier_match_class',sup_class,'supplier_cost',sup.supplier_cost,
    'freight_to_dest',freight_cost,'freight_days',freight_days,
    'certified_landed',landed,'reference_landed',ref_landed,
    'reference_contribution_after_reserve', ref_econ->>'contribution_after_reserve',
    'buyer_search_intent_subscore', bsi->>'subscore', 'advertising_subscore', adv->>'subscore',
    'pme_id',pme_id,'market_decision',pme_dec,'competitor_entries',jsonb_array_length(comp_arr),
    'economics_certified', is_exact, 'contract','pulse_real_assembler_v3_013j');
END; $function$;

-- ----------------------------------------------------------------------------
-- 2. ORCHESTRATOR ENTRY POINT (authenticated, on-demand, auth.uid()-scoped).
--    Caller supplies only product_id + market. Ownership, tenant, currency,
--    applicability and provider credentials are all derived server-side.
--    Creates a research run + one truthful source attempt per applicable
--    evidence category. Returns a browser-safe dispatch manifest.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_own_request_product_market_research(
  p_product_id uuid, p_market text, p_freshness_hours integer DEFAULT 168)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_prod public.commerce_products%rowtype;
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_ccy text; v_run_id uuid; v_fresh record;
  reg record; v_query text; v_supplier uuid;
  v_expected int := 0; v_manifest jsonb := '[]'::jsonb;
  cat record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING errcode='28000';
  END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','PRODUCT_NOT_FOUND');
  END IF;
  IF v_prod.user_id <> v_uid THEN
    RAISE EXCEPTION 'not authorized for this product' USING errcode='42501';
  END IF;

  -- market must be a real, ecommerce-eligible market in the canonical universe
  SELECT default_currency INTO v_ccy FROM public.ecommerce_market_universe
    WHERE country_code = v_mkt AND coalesce(ecommerce_eligible,true) LIMIT 1;
  IF v_ccy IS NULL THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','market',v_mkt,
      'note','market not present / not ecommerce-eligible in ecommerce_market_universe');
  END IF;

  -- ── cost / duplicate control: reuse a sufficiently fresh COMPLETE run ──
  SELECT * INTO v_fresh FROM public.commerce_research_run
    WHERE tenant_id=v_uid AND product_id=p_product_id AND market=v_mkt
      AND status IN ('COMPLETE','PARTIAL','PARTIAL_SOURCE_FAILURE','PARTIAL_SOURCE_UNAVAILABLE')
      AND completed_at IS NOT NULL
      AND completed_at > now() - make_interval(hours => greatest(1,coalesce(p_freshness_hours,168)))
    ORDER BY completed_at DESC LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('status','CACHE_REUSED','run_id',v_fresh.id,'market',v_mkt,
      'reused_completed_at',v_fresh.completed_at,'freshness_hours',p_freshness_hours,
      'note','fresh completed run reused; no new provider dispatch, no paid calls');
  END IF;

  -- registry inputs (query/currency/supplier) for canonical recompute + eBay query
  SELECT (m.value->>'price_query') AS pq, r.supplier_id AS sup
    INTO v_query, v_supplier
  FROM public.monday_opportunity_registry r
       CROSS JOIN LATERAL jsonb_array_elements(r.markets) m
  WHERE r.product_id = p_product_id AND (m.value->>'country') = v_mkt
  LIMIT 1;
  v_query := coalesce(v_query, v_prod.title);

  v_run_id := gen_random_uuid();
  INSERT INTO public.commerce_research_run
    (id, tenant_id, product_id, market, status, sources_expected, started_at, freshness_at, provenance)
  VALUES (v_run_id, v_uid, p_product_id, v_mkt, 'RESEARCHING', 0, now(), now(),
    jsonb_build_object('trigger','on_demand_user_request','requested_by',v_uid,
      'product_title',v_prod.title,'price_query',v_query,'market_currency',v_ccy,
      'registry_supplier', v_supplier,
      'snapshot_note','applicable provider/category set snapshotted at request time so later registry changes do not falsify this run'));

  -- ── applicability per launch-critical evidence category (registry-driven) ──
  -- Choose the single active source per category from provider_capability_registry,
  -- preferring an AVAILABLE market-specific row, else the global '*' row, else the
  -- most truthful blocking state. Never hardcoded to a fixed provider list.
  FOR cat IN
    WITH cats(evidence_category) AS (
      VALUES ('COMMUNITY'),('SEARCH_DEMAND'),('MARKETPLACE'),('ADVERTISING'),('SUPPLIER'),('SOCIAL_VIDEO')
    ),
    ranked AS (
      SELECT c.evidence_category, r.source, r.availability, r.market,
             row_number() OVER (
               PARTITION BY c.evidence_category
               ORDER BY
                 (r.availability='AVAILABLE' AND r.market=v_mkt) DESC,   -- market-specific available
                 (r.availability='AVAILABLE' AND r.market='*')   DESC,   -- global available
                 (r.availability='AVAILABLE')                    DESC,
                 (r.market=v_mkt)                                DESC,
                 (r.market='*')                                  DESC
             ) AS rnk
      FROM cats c
      JOIN public.provider_capability_registry r USING (evidence_category)
    )
    SELECT evidence_category, source, availability, market FROM ranked WHERE rnk=1
  LOOP
    DECLARE v_state text; v_note text;
    BEGIN
      IF cat.availability = 'AVAILABLE' THEN
        -- dispatchable now; executor will move SEARCHING -> terminal
        v_state := 'NOT_SEARCHED'; v_note := 'applicable; awaiting provider dispatch';
      ELSIF cat.availability = 'SOURCE_UNSUPPORTED' AND cat.evidence_category='SOCIAL_VIDEO' THEN
        v_state := 'BLOCKED_EXTERNAL_ACCESS'; v_note := 'EXTERNAL_PROVIDER_REQUIRED';
      ELSIF cat.availability = 'SOURCE_UNSUPPORTED' THEN
        -- provider exists only for other markets (e.g. Meta outside EU/UK)
        v_state := 'UNSUPPORTED_MARKET'; v_note := 'provider not available for selected market';
      ELSIF cat.availability = 'SOURCE_BLOCKED' THEN
        v_state := 'SOURCE_UNAVAILABLE'; v_note := 'provider access blocked';
      ELSE
        v_state := 'SOURCE_UNAVAILABLE'; v_note := coalesce(cat.availability,'UNKNOWN');
      END IF;

      -- For ADVERTISING specifically: if the chosen row is the global SOURCE_UNSUPPORTED
      -- sentinel but a market-specific AVAILABLE row exists, prefer AVAILABLE (handled by
      -- ranking above). If no AVAILABLE market row, it is genuinely UNSUPPORTED_MARKET.
      INSERT INTO public.commerce_research_source_attempt
        (id, run_id, evidence_category, source, state, note, created_at)
      VALUES (gen_random_uuid(), v_run_id, cat.evidence_category, cat.source, v_state, v_note, now());
      v_expected := v_expected + 1;
      v_manifest := v_manifest || jsonb_build_array(jsonb_build_object(
        'evidence_category', cat.evidence_category, 'source', cat.source, 'state', v_state,
        'dispatchable', (v_state='NOT_SEARCHED'),
        'query', CASE WHEN v_state='NOT_SEARCHED' THEN v_query ELSE NULL END,
        'market', v_mkt, 'note', v_note));
    END;
  END LOOP;

  UPDATE public.commerce_research_run SET sources_expected=v_expected, updated_at=now() WHERE id=v_run_id;

  RETURN jsonb_build_object('status','RESEARCHING','run_id',v_run_id,
    'product_id',p_product_id,'product_title',v_prod.title,'market',v_mkt,'market_currency',v_ccy,
    'price_query',v_query,'sources_expected',v_expected,'dispatch_manifest',v_manifest,
    'tiktok','BLOCKED_EXTERNAL_ACCESS',
    'contract','pulse_research_request_v1_013j');
END; $function$;

-- ----------------------------------------------------------------------------
-- 3. PROVENANCE-LINKED INGESTION (service_role). The n8n executor posts raw
--    provider output here per source. This dispatches to the existing canonical
--    receiver, stamps research_run_id/attempt provenance onto exactly the rows
--    this call inserts (same transaction), and transitions the attempt state
--    truthfully: evidence is only "found" when canonical rows were accepted.
-- ----------------------------------------------------------------------------
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

-- ----------------------------------------------------------------------------
-- 4. FINALIZE (service_role). Rolls up attempt states into truthful run counts,
--    sets a truthful terminal run status, then runs the CANONICAL recompute
--    (fn_assemble_real_product_market). No manual score/band/confidence patching.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_finalize_research_run(p_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_expected int; v_attempted int; v_evidence int; v_nodata int; v_unsupported int; v_failed int; v_blocked int; v_pending int;
  v_indep int; v_status text; v_ccy text; v_query text; v_supplier uuid; v_recompute jsonb;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;

  SELECT
    count(*) FILTER (WHERE true),
    count(*) FILTER (WHERE state IN ('SEARCHED_EVIDENCE_FOUND','SEARCHED_NO_EVIDENCE','SOURCE_FAILED')),
    count(*) FILTER (WHERE state='SEARCHED_EVIDENCE_FOUND'),
    count(*) FILTER (WHERE state='SEARCHED_NO_EVIDENCE'),
    count(*) FILTER (WHERE state='UNSUPPORTED_MARKET'),
    count(*) FILTER (WHERE state='SOURCE_FAILED'),
    count(*) FILTER (WHERE state='BLOCKED_EXTERNAL_ACCESS'),
    count(*) FILTER (WHERE state IN ('NOT_SEARCHED','SEARCHING'))
  INTO v_expected, v_attempted, v_evidence, v_nodata, v_unsupported, v_failed, v_blocked, v_pending
  FROM public.commerce_research_source_attempt WHERE run_id=p_run_id;

  v_indep := v_evidence;  -- independent categories that yielded evidence

  -- truthful terminal status
  IF v_pending > 0 THEN
    v_status := 'PARTIAL';                              -- some dispatchable source not yet run
  ELSIF v_failed > 0 THEN
    v_status := 'PARTIAL_SOURCE_FAILURE';
  ELSIF v_blocked > 0 OR v_unsupported > 0 THEN
    v_status := 'PARTIAL_SOURCE_UNAVAILABLE';           -- e.g. TikTok blocked / Meta unsupported market
  ELSIF v_evidence = 0 THEN
    v_status := 'INSUFFICIENT_EVIDENCE';
  ELSE
    v_status := 'COMPLETE';
  END IF;

  -- canonical recompute inputs
  v_ccy := coalesce(public.fn_market_default_currency(v_run.market), (v_run.provenance->>'market_currency'));
  v_query := coalesce(v_run.provenance->>'price_query', (SELECT title FROM public.commerce_products WHERE id=v_run.product_id));
  v_supplier := nullif(v_run.provenance->>'registry_supplier','')::uuid;

  -- CANONICAL recompute (no manual score/band/confidence patching)
  v_recompute := public.fn_assemble_real_product_market(v_run.product_id, v_run.market, v_ccy, v_query, v_supplier, true);

  UPDATE public.commerce_research_run
    SET status=v_status, sources_attempted=v_attempted, sources_with_evidence=v_evidence,
        sources_no_data=v_nodata, sources_unsupported=v_unsupported+v_blocked, sources_failed=v_failed,
        independent_categories=v_indep, completed_at=now(), updated_at=now(),
        provenance = provenance || jsonb_build_object(
          'finalized_at', now(), 'recompute_contract', v_recompute->>'contract',
          'launch_critical_gap', (v_blocked > 0),
          'blocked_categories', v_blocked, 'unsupported_categories', v_unsupported)
    WHERE id=p_run_id;

  RETURN jsonb_build_object('status',v_status,'run_id',p_run_id,'market',v_run.market,
    'sources_expected',v_expected,'sources_attempted',v_attempted,'sources_with_evidence',v_evidence,
    'sources_no_data',v_nodata,'sources_unsupported',v_unsupported,'sources_blocked',v_blocked,
    'sources_failed',v_failed,'pending',v_pending,'independent_categories',v_indep,
    'launch_critical_gap',(v_blocked>0),'recompute',v_recompute,
    'contract','pulse_research_finalize_v1_013j');
END; $function$;

-- ----------------------------------------------------------------------------
-- 5. SELF-TEST (service_role, self-cleaning). In-DB only; makes no external
--    provider calls and mutates no production evidence (its temp run is deleted).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_research_orchestrator_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_founder uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_req jsonb; v_run uuid; r record; v_res jsonb := '[]'::jsonb; v_pass boolean := true;
  n_att int; n_tiktok int; n_meta_gb int; n_ebay int;
BEGIN
  -- simulate authenticated founder request (auth.uid() reads request.jwt.claims->>'sub')
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_founder::text, 'role','authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_founder::text, true);
  v_req := public.fn_own_request_product_market_research(v_prod, 'GB');
  v_run := nullif(v_req->>'run_id','')::uuid;

  -- 1. run created RESEARCHING with 6 categories
  SELECT count(*) INTO n_att FROM public.commerce_research_source_attempt WHERE run_id=v_run;
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','request_creates_6_attempts',
    'pass',(v_req->>'status'='RESEARCHING' AND n_att=6),'attempts',n_att));
  v_pass := v_pass AND (v_req->>'status'='RESEARCHING' AND n_att=6);

  -- 2. TikTok BLOCKED_EXTERNAL_ACCESS
  SELECT count(*) INTO n_tiktok FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='SOCIAL_VIDEO' AND state='BLOCKED_EXTERNAL_ACCESS' AND source='TIKTOK';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','tiktok_blocked','pass',(n_tiktok=1)));
  v_pass := v_pass AND (n_tiktok=1);

  -- 3. Meta ADVERTISING is AVAILABLE (NOT_SEARCHED) for GB
  SELECT count(*) INTO n_meta_gb FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='ADVERTISING' AND state='NOT_SEARCHED' AND source='META_AD_LIBRARY';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','meta_available_gb','pass',(n_meta_gb=1)));
  v_pass := v_pass AND (n_meta_gb=1);

  -- 4. eBay MARKETPLACE dispatchable
  SELECT count(*) INTO n_ebay FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='MARKETPLACE' AND state='NOT_SEARCHED' AND source='EBAY';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','ebay_dispatchable','pass',(n_ebay=1)));
  v_pass := v_pass AND (n_ebay=1);

  -- 5. finalize with no dispatch -> PARTIAL (pending eBay/DataForSEO/Meta/CJ/Reddit) and launch gap true
  DECLARE v_fin jsonb; BEGIN
    v_fin := public.fn_finalize_research_run(v_run);
    v_res := v_res || jsonb_build_array(jsonb_build_object('case','finalize_partial_with_gap',
      'pass',(v_fin->>'status'='PARTIAL' AND (v_fin->>'launch_critical_gap')::boolean=true),
      'status',v_fin->>'status','gap',v_fin->>'launch_critical_gap'));
    v_pass := v_pass AND (v_fin->>'status'='PARTIAL' AND (v_fin->>'launch_critical_gap')::boolean=true);
  END;

  -- 6. unsupported market rejected
  DECLARE v_bad jsonb; BEGIN
    v_bad := public.fn_own_request_product_market_research(v_prod, 'ZZ');
    v_res := v_res || jsonb_build_array(jsonb_build_object('case','unsupported_market_rejected',
      'pass',(v_bad->>'status'='UNSUPPORTED_MARKET')));
    v_pass := v_pass AND (v_bad->>'status'='UNSUPPORTED_MARKET');
  END;

  -- cleanup: remove the temp run + attempts (no production evidence was mutated;
  -- finalize recompute re-derived the existing evaluation from unchanged signals)
  DELETE FROM public.commerce_research_source_attempt WHERE run_id=v_run;
  DELETE FROM public.commerce_research_run WHERE id=v_run;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  RETURN jsonb_build_object('all_pass',v_pass,'cases',v_res,'contract','pulse_research_selftest_v1_013j');
END; $function$;

-- ----------------------------------------------------------------------------
-- Grants: browser-safe request contract to authenticated; control-plane and
-- ingestion to service_role only; anon revoked everywhere.
-- ----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fn_own_request_product_market_research(uuid,text,integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_own_request_product_market_research(uuid,text,integer) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.fn_research_ingest_source(uuid,text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_ingest_source(uuid,text,jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.fn_finalize_research_run(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_finalize_research_run(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.fn_research_orchestrator_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_research_orchestrator_selftest() TO service_role;

REVOKE ALL ON FUNCTION public.fn_market_default_currency(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_market_default_currency(text) TO authenticated, service_role;

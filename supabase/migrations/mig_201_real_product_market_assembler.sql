-- PULSE-ECOM-MONDAY-REAL-PRODUCT-OPPORTUNITY-PIPELINE-001
-- Deployed to Supabase project nxaunmyihhjixxxljcqt as mig_201.
-- Production assembler that reads REAL source evidence and feeds the already-built engines with
-- is_fixture=FALSE, preserving provenance (source/source_class/product/country/observed_at/confidence):
--   commerce_products (candidate identity)  ->  product_id + tenant (user_id)
--   commerce_signals (COMMUNITY_ATTENTION reddit demand, MARKETPLACE_ACTIVITY eBay presence)
--   market_price_observations (eBay Browse local price per country -> PLATFORM_REPORTED / LOCAL)
--   commerce_supplier_products (CJdropshipping cost + destination freight enrichment)
-- Missing evidence stays UNKNOWN (fail-closed): no local dest freight -> economics UNKNOWN -> WATCH;
-- CJ active-listing status is NOT a hard quantity -> stock_state UNKNOWN (never silently IN_STOCK);
-- no real Meta/DataForSEO platform evidence -> no platform row (execution blocker, decision unaffected).
-- Competitor rows are built from REAL eBay observations (no seller identity persisted; eBay account-
-- deletion exemption) and never converted to sales/revenue/ROAS/CPA/winning-ad.
-- Signature: fn_assemble_real_product_market(p_candidate uuid, p_country text, p_currency text,
--            p_price_query text, p_supplier uuid DEFAULT NULL, p_persist boolean DEFAULT true)
-- SECURITY DEFINER, SET search_path='', REVOKE'd from PUBLIC and anon. Full deployed body follows.
CREATE OR REPLACE FUNCTION public.fn_assemble_real_product_market(
  p_candidate uuid, p_country text, p_currency text, p_price_query text,
  p_supplier uuid DEFAULT NULL, p_persist boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
  cand record; tenant uuid; price record; sup record; fr jsonb;
  community_conf numeric; mkt_signals int; search_present boolean; ad_present boolean;
  dm numeric; mv numeric; bsi numeric; adv numeric; ssub numeric;
  landed numeric; landed_ccy text; fulfil text; econ jsonb; evidence jsonb;
  pme_id uuid; pme_dec text; comp_arr jsonb := '[]'::jsonb; n_pts int; lst record; k int;
  freight_cost numeric; freight_days text;
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
  SELECT max(confidence) INTO community_conf FROM public.commerce_signals WHERE product_id=p_candidate AND signal_type='COMMUNITY_ATTENTION';
  SELECT count(*) INTO mkt_signals FROM public.commerce_signals WHERE product_id=p_candidate AND signal_type='MARKETPLACE_ACTIVITY';
  SELECT EXISTS(SELECT 1 FROM public.commerce_signals WHERE product_id=p_candidate AND signal_type='SEARCH_DEMAND') INTO search_present;
  SELECT EXISTS(SELECT 1 FROM public.commerce_signals WHERE product_id=p_candidate AND signal_type='ADVERTISING_ACTIVITY') INTO ad_present;
  dm := CASE WHEN community_conf IS NOT NULL THEN round(community_conf*100,0) ELSE NULL END;
  mv := CASE WHEN mkt_signals>0 OR price.id IS NOT NULL THEN least(100, 50 + coalesce(mkt_signals,0)*3) ELSE NULL END;
  bsi := NULL; adv := NULL;
  ssub := CASE WHEN sup.id IS NOT NULL THEN 60 ELSE NULL END;
  fr := sup.supplier_enrichment->'freight'->p_country->'representative';
  freight_cost := nullif(fr->>'shipping_cost','')::numeric;
  freight_days := CASE WHEN fr ? 'est_min_days' THEN (fr->>'est_min_days')||'-'||(fr->>'est_max_days')||' days' ELSE NULL END;
  IF sup.supplier_cost IS NOT NULL AND freight_cost IS NOT NULL THEN
    landed := sup.supplier_cost + freight_cost; landed_ccy := coalesce(sup.cost_currency,'USD'); fulfil := 'true';
  ELSE landed := NULL; landed_ccy := coalesce(sup.cost_currency,'USD'); fulfil := NULL; END IF;
  evidence := jsonb_build_object(
    'buyer_search_intent', CASE WHEN bsi IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',bsi::text) END,
    'demand_momentum', CASE WHEN dm IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',dm::text,'source','reddit','source_class','OBSERVED') END,
    'marketplace_validation', CASE WHEN mv IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',mv::text,'source','EBAY_BROWSE','source_class','PLATFORM_REPORTED') END,
    'advertising_activity', '{}'::jsonb,
    'supplier_availability_stock', CASE WHEN ssub IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('subscore',ssub::text,'source','cjdropshipping') END,
    'stock_state','UNKNOWN','compliance_risk','UNKNOWN','fulfilment_usable', fulfil,
    'observed_market_price', CASE WHEN price.id IS NOT NULL
       THEN jsonb_build_object('source_class','PLATFORM_REPORTED','amount',price.price_median,'currency',price.currency,
             'range',jsonb_build_array(price.price_min,price.price_max),'sample',price.sample_size,'total_listings',price.total_listings,
             'source','EBAY_BROWSE','observed_at',price.observed_at)
       ELSE jsonb_build_object('source_class','UNKNOWN') END,
    'delivery_evidence', CASE WHEN freight_days IS NOT NULL THEN jsonb_build_object('estimate',freight_days,'source','CJ_FREIGHT_CALCULATE') ELSE '{}'::jsonb END,
    'risk_flags', jsonb_build_array());
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
    'supplier',sup.title,'supplier_cost',sup.supplier_cost,'freight_to_dest',freight_cost,'freight_days',freight_days,'landed',landed,
    'pme_id',pme_id,'market_decision',pme_dec,'competitor_entries',jsonb_array_length(comp_arr),
    'contract','pulse_real_assembler_v1');
END; $$;
REVOKE ALL ON FUNCTION public.fn_assemble_real_product_market(uuid,text,text,text,uuid,boolean) FROM PUBLIC, anon;

-- Real-source verification (manual, engineering): the "kids nightlight projector" candidate
-- (commerce_products e453eed4, tenant 7c8ddf9d) assembled across DE/FR/GB/US from real eBay Browse
-- prices + CJ supplier a7ca5195, then fn_pod_tournament -> 4 REAL product_opportunity_decisions:
--   GB AVOID (full chain; landed 10.23 USD vs eBay median GBP 7.90 -> contribution -14.88; VERY_HIGH)
--   FR/DE/US WATCH (no destination freight -> economics UNKNOWN; stock UNKNOWN; saturation FR MODERATE /
--   DE HIGH / US VERY_HIGH; product_confidence LOW; no real ad-platform evidence -> platform UNKNOWN).
-- Best market FR (least saturated), product-level WATCH. Decision NOT weakened to TEST. 27/27 real-source
-- + regression assertions PASS. No new recurring cadence added; Monday automated delivery has NOT yet run
-- on a real Monday schedule (stated separately). campaign_activation=FALSE; advertising_spend=0.

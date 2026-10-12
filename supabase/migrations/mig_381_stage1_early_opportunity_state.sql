-- mig_381 — Stage-1 early-opportunity state: wire COMMERCE_PRODUCT_NATIVE evidence into a
-- provider-independent early-opportunity family map, WITHOUT weakening qualification.
--
-- ROOT CAUSE (diagnosis D — MIXED): fn_assemble_real_product_market consumes only the research-lane
-- providers (DataForSEO/Reddit/eBay/Meta/CJ) and never reads COMMERCE_PRODUCT_NATIVE, so the real
-- country-specific FastMoss/Kalodata commerce evidence already persisted (short-window units/GMV,
-- seller identity, newness, and any observed local listing price) contributes nothing — early,
-- genuinely-emerging products score coverage 0 and read as INSUFFICIENT.
--
-- FIX (additive, generalises across products/tenants/countries/providers): a read-only
-- fn_stage1_early_opportunity_state that reuses the existing fn_stage1_commerce_evidence (commerce
-- momentum + LOCAL_OBSERVED price + deduped observed sellers) and the existing
-- fn_stage1_opportunity_qualified (the UNCHANGED qualification contract), assembles a
-- provider-independent evidence-family map, and emits an explicit early_opportunity_state:
--   DISCOVERED -> EMERGING -> RESEARCH_PRIORITY -> QUALIFIED_FOR_SUPPLIER_RESOLUTION.
--
-- PERMANENT INVARIANTS (enforced here):
--  * Commerce momentum ALONE can reach at most EMERGING; corroborated by a second independent
--    momentum family (ads/search/community) or a marketplace/local-observed-price signal it can
--    reach RESEARCH_PRIORITY; it can NEVER reach QUALIFIED_FOR_SUPPLIER_RESOLUTION (which is taken
--    verbatim from fn_stage1_opportunity_qualified — score>=70 + MEDIUM/HIGH confidence + LOCAL +
--    saturation PASS + market_price PASS, thresholds unchanged).
--  * WINNER is never produced here (post-launch/performance only).
--  * One provider listing price = LOCAL_OBSERVED_PRICE, never VALIDATED_LOCAL_MARKET_PRICE and never
--    a market_price-gate PASS (the gate is untouched).
--  * One observed seller != proven seller_count=1 != LOW competition; the saturation gate is
--    untouched (still fail-closed). Provider sellers only seed the observed-seller set (deduped).
--  * UNKNOWN stays UNKNOWN; country isolation, Product Identity Resolution, branded/IP fail-close,
--    image independence and Stage-2/3 supplier-gate separation are all preserved (not touched).
--
-- No existing function, gate, score, threshold or decision is modified. This object is additive and
-- read-only (STABLE).
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_stage1_early_opportunity_state(p_tenant uuid, p_product uuid, p_country text, p_freshness_hours integer DEFAULT 336)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_country,'')));
  ce jsonb; q jsonb; pme record;
  cm_present boolean; adv boolean; bsi boolean; comm boolean;
  mkt boolean; loc_observed boolean; sellers_present boolean;
  m int := 0; fams text[] := '{}'; state text; qualified boolean;
BEGIN
  ce := public.fn_stage1_commerce_evidence(p_tenant, p_product, v_mkt, p_freshness_hours);
  q  := public.fn_stage1_opportunity_qualified(p_tenant, p_product, v_mkt);
  qualified := coalesce((q->>'stage1_opportunity_qualified')::boolean, false);

  SELECT * INTO pme FROM public.product_market_evaluations
    WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=v_mkt
    ORDER BY evaluation_ts DESC NULLS LAST, created_at DESC LIMIT 1;

  -- MOMENTUM families (independent early-traction evidence)
  cm_present := coalesce((ce->'commerce_momentum'->>'present')::boolean, false);
  adv  := (pme.component_scores->'advertising_activity'->>'subscore') IS NOT NULL;
  bsi  := (pme.component_scores->'buyer_search_intent'->>'subscore') IS NOT NULL;
  comm := (pme.component_scores->'demand_momentum'->>'subscore') IS NOT NULL;
  -- CORROBORATING families
  mkt  := (pme.component_scores->'marketplace_validation'->>'subscore') IS NOT NULL;
  loc_observed := (ce->'local_price'->>'class') = 'LOCAL_OBSERVED_PRICE';
  sellers_present := (ce->'observed_sellers'->>'provider_observed_distinct') IS NOT NULL;

  IF cm_present THEN m:=m+1; fams:=array_append(fams,'COMMERCE_MOMENTUM'); END IF;
  IF adv  THEN m:=m+1; fams:=array_append(fams,'ADVERTISING_EMERGENCE'); END IF;
  IF bsi  THEN m:=m+1; fams:=array_append(fams,'SEARCH_DEMAND'); END IF;
  IF comm THEN m:=m+1; fams:=array_append(fams,'COMMUNITY_MOMENTUM'); END IF;
  IF mkt  THEN fams:=array_append(fams,'MARKETPLACE_VALIDATION'); END IF;
  IF loc_observed THEN fams:=array_append(fams,'LOCAL_OBSERVED_PRICE'); END IF;
  IF sellers_present THEN fams:=array_append(fams,'OBSERVED_SELLER'); END IF;

  -- early-stage classification (never QUALIFIED unless the unchanged contract says so)
  state := CASE
    WHEN qualified THEN 'QUALIFIED_FOR_SUPPLIER_RESOLUTION'
    WHEN m >= 2 OR (m >= 1 AND (mkt OR loc_observed)) THEN 'RESEARCH_PRIORITY'
    WHEN m >= 1 THEN 'EMERGING'
    ELSE 'DISCOVERED' END;

  RETURN jsonb_build_object(
    'country', v_mkt,
    'early_opportunity_state', state,
    'momentum_family_count', m,
    'evidence_families_present', to_jsonb(fams),
    'commerce_momentum', ce->'commerce_momentum',
    'local_price', ce->'local_price',
    'observed_sellers', ce->'observed_sellers',
    'qualification', jsonb_build_object(
       'stage1_opportunity_qualified', qualified,
       'stage1_qualification_state', q->>'stage1_qualification_state',
       'overall_evidence_confidence', q->>'overall_evidence_confidence',
       'metric_scope', q->>'metric_scope',
       'market_price_gate', q->'stage1_owned_gates'->>'market_price',
       'saturation_gate', q->'stage1_owned_gates'->>'saturation'),
    'invariants', jsonb_build_object(
       'commerce_alone_max_state','EMERGING',
       'commerce_alone_sufficient_for_qualify', false,
       'winner_is_post_launch_only', true,
       'qualification_contract_unchanged', true,
       'one_listing_not_validated_market_price', true,
       'one_seller_not_low_competition', true,
       'unknown_stays_unknown', true),
    'lifecycle', jsonb_build_array('DISCOVERED','EMERGING','RESEARCH_PRIORITY','QUALIFIED_FOR_SUPPLIER_RESOLUTION'),
    'contract','pulse_stage1_early_opportunity_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_stage1_early_opportunity_state(uuid, uuid, text, integer) TO authenticated, service_role;

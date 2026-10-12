-- mig_383 — Stage-1 supplier-resolution qualification (investigation-worthiness) +
-- explicit commercial/launch gate relabel. Permanent correction of the CONTRACT_DEFECT:
-- Stage 1 conflated "enough evidence to justify EXACT SUPPLIER RESOLUTION" (A) with
-- "COMMERCIALLY VALIDATED / LAUNCH_READY" (B). The strict bar (score>=70 + MEDIUM/HIGH +
-- LOCAL + saturation PASS + market_price PASS) is correct as the LATER commercial gate but is
-- structurally too mature for early-opportunity qualification.
--
-- This migration is ADDITIVE and read-only:
--   * fn_stage1_opportunity_qualified is NOT modified (existing callers keep working).
--   * fn_stage1_commercially_validated wraps it under its correct name (the B gate).
--   * fn_stage1_supplier_resolution_qualified is the new A gate: enough INDEPENDENT, country-
--     specific, minimum-strength evidence families to justify exact supplier resolution — never
--     from one family alone, never from GMV/ads/supplier alone, never converting UNKNOWN to PASS,
--     never requiring validated local price or validated saturation.
SET check_function_bodies = off;

-- ===== B gate (explicit name; preserves the unchanged strict bar) =====
CREATE OR REPLACE FUNCTION public.fn_stage1_commercially_validated(p_tenant uuid, p_product uuid, p_country text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE q jsonb;
BEGIN
  q := public.fn_stage1_opportunity_qualified(p_tenant, p_product, upper(btrim(coalesce(p_country,''))));
  RETURN jsonb_build_object(
    'commercially_validated', coalesce((q->>'stage1_opportunity_qualified')::boolean,false),
    'launch_bar','score>=70 + MEDIUM/HIGH confidence + metric_scope LOCAL + saturation PASS + market_price PASS',
    'source_contract', q->>'contract',
    'stage1_owned_gates', q->'stage1_owned_gates',
    'opportunity_score', q->>'opportunity_score',
    'overall_evidence_confidence', q->>'overall_evidence_confidence',
    'metric_scope', q->>'metric_scope',
    'note','COMMERCIALLY_VALIDATED / LAUNCH_READY gate (post Stage-2/3). Unchanged strict bar; distinct from STAGE_1_OPPORTUNITY_QUALIFIED which only means worth exact supplier resolution.',
    'contract','pulse_stage1_commercially_validated_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_stage1_commercially_validated(uuid, uuid, text) TO authenticated, service_role;

-- ===== A gate: Stage-1 supplier-resolution qualification =====
CREATE OR REPLACE FUNCTION public.fn_stage1_supplier_resolution_qualified(p_tenant uuid, p_product uuid, p_country text, p_freshness_hours integer DEFAULT 336)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_country,'')));
  cp record; ce jsonb; pme record; pod record;
  cm_present boolean; cm_qual boolean; cm_units numeric; cm_rev numeric;
  adv_count int; adv_present boolean; adv_qual boolean;
  bsi_present boolean; bsi_qual boolean;
  comm_present boolean; comm_qual boolean;
  mkt_present boolean; mkt_qual boolean;
  present_ct int; qual_ct int; fams jsonb := '[]'::jsonb;
  sat_level text; sat_gap boolean; sat_repr text; observed_high_sat boolean;
  branded boolean; identity_ambiguous boolean; disq boolean;
  price_class text; price_validated boolean; sellers_distinct int;
  qualified boolean; reasons text[] := '{}';
BEGIN
  SELECT * INTO cp FROM public.commerce_products WHERE id=p_product AND user_id=p_tenant;
  ce := public.fn_stage1_commerce_evidence(p_tenant, p_product, v_mkt, p_freshness_hours);
  SELECT * INTO pme FROM public.product_market_evaluations
    WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=v_mkt
    ORDER BY evaluation_ts DESC NULLS LAST, created_at DESC LIMIT 1;
  SELECT * INTO pod FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=v_mkt
    ORDER BY created_at DESC LIMIT 1;

  -- ---- evidence families (present vs qualifying; each qualifying rule from existing semantics) ----
  -- COMMERCE_MOMENTUM: real short-window traction (nonzero units AND revenue); a bare record is not enough.
  cm_present := coalesce((ce->'commerce_momentum'->>'present')::boolean,false);
  cm_units := nullif(ce->'commerce_momentum'->>'short_window_units','')::numeric;
  cm_rev   := nullif(ce->'commerce_momentum'->>'short_window_revenue','')::numeric;
  cm_qual  := cm_present AND coalesce(cm_units,0) > 0 AND coalesce(cm_rev,0) > 0;

  -- ADVERTISING_EMERGENCE: credible MULTI-advertiser emergence (>=2 distinct observed advertisers);
  -- one weak advertiser does NOT count. Count from normalized evidence (provider-independent).
  adv_count := greatest(
    coalesce(nullif(pme.evidence->'advertising_activity'->>'observed_advertisers','')::int, 0),
    coalesce((SELECT count(DISTINCT coalesce(s.value->>'advertiser_id', s.value->>'page_id', s.value->>'advertiser'))
              FROM public.commerce_signals s
              WHERE s.product_id=p_product AND s.signal_type='ADVERTISING_ACTIVITY'
                AND coalesce(s.value->>'market','')=v_mkt)::int, 0));
  adv_present := adv_count > 0;
  adv_qual := adv_count >= 2;

  -- SEARCH_DEMAND: genuine selected-country buyer-intent (assembler sets the subscore only from a
  -- real numeric buyer-intent observation).
  bsi_present := (pme.component_scores->'buyer_search_intent'->>'subscore') IS NOT NULL;
  bsi_qual := bsi_present
    AND coalesce(pme.evidence->'buyer_search_intent'->>'band','') NOT IN ('NONE','VERY_LOW','UNKNOWN');

  -- COMMUNITY_SOCIAL: genuine community/social attention (assembler sets it only from a real signal).
  comm_present := (pme.component_scores->'demand_momentum'->>'subscore') IS NOT NULL;
  comm_qual := comm_present;

  -- MARKETPLACE_VALIDATION: genuine same/substantially-identical selected-country marketplace evidence.
  mkt_present := (pme.component_scores->'marketplace_validation'->>'subscore') IS NOT NULL;
  mkt_qual := mkt_present;

  present_ct := (cm_present::int)+(adv_present::int)+(bsi_present::int)+(comm_present::int)+(mkt_present::int);
  qual_ct    := (cm_qual::int)+(adv_qual::int)+(bsi_qual::int)+(comm_qual::int)+(mkt_qual::int);
  fams := jsonb_build_array(
    jsonb_build_object('family','COMMERCE_MOMENTUM','present',cm_present,'qualifying',cm_qual,'strength',jsonb_build_object('units',cm_units,'revenue',cm_rev),'rule','units>0 AND revenue>0'),
    jsonb_build_object('family','ADVERTISING_EMERGENCE','present',adv_present,'qualifying',adv_qual,'strength',jsonb_build_object('distinct_advertisers',adv_count),'rule','>=2 distinct observed advertisers'),
    jsonb_build_object('family','SEARCH_DEMAND','present',bsi_present,'qualifying',bsi_qual,'rule','genuine numeric buyer-intent, band not NONE/VERY_LOW'),
    jsonb_build_object('family','COMMUNITY_SOCIAL','present',comm_present,'qualifying',comm_qual,'rule','genuine community/social attention signal'),
    jsonb_build_object('family','MARKETPLACE_VALIDATION','present',mkt_present,'qualifying',mkt_qual,'rule','same-product selected-country marketplace evidence'));

  -- ---- negative / disqualifying evidence (observed negatives fail-close; UNKNOWN does not) ----
  sat_level := coalesce(pod.saturation_state->>'level','UNKNOWN');
  sat_gap := coalesce((pod.saturation_state->>'has_defensible_gap')::boolean,false);
  observed_high_sat := (sat_level='VERY_HIGH') OR (sat_level='HIGH' AND NOT sat_gap);
  branded := coalesce((public.fn_is_branded_or_ip_sensitive(coalesce(cp.title,''))->>'flagged')::boolean,false);
  identity_ambiguous := (cp.id IS NULL) OR (coalesce(cp.identity_basis,'') NOT IN ('platform_id','canonical_url'));
  disq := observed_high_sat OR branded OR identity_ambiguous;

  -- ---- saturation representation (never fabricate low competition from thin coverage) ----
  sellers_distinct := nullif(ce->'observed_sellers'->>'provider_observed_distinct','')::int;
  sat_repr := CASE
    WHEN sat_level IN ('LOW','MODERATE','HIGH','VERY_HIGH') THEN 'OBSERVED_'||sat_level
    WHEN sellers_distinct IS NOT NULL THEN 'LIMITED_COVERAGE'
    ELSE 'UNKNOWN' END;

  -- ---- price representation (never required for Stage-1; one listing stays LOCAL_OBSERVED) ----
  price_class := ce->'local_price'->>'class';
  price_validated := coalesce((ce->'local_price'->>'validated_local_market_price')::boolean,false);

  qualified := (qual_ct >= 2) AND NOT disq;

  IF disq THEN
    IF observed_high_sat THEN reasons:=array_append(reasons,'DISQUALIFIED_OBSERVED_HIGH_SATURATION'); END IF;
    IF branded THEN reasons:=array_append(reasons,'DISQUALIFIED_BRANDED_OR_IP'); END IF;
    IF identity_ambiguous THEN reasons:=array_append(reasons,'DISQUALIFIED_IDENTITY_AMBIGUOUS'); END IF;
  ELSIF qualified THEN reasons:=array_append(reasons,'TWO_INDEPENDENT_QUALIFYING_FAMILIES');
  ELSIF qual_ct=1 THEN reasons:=array_append(reasons,'ONLY_ONE_QUALIFYING_FAMILY');
  ELSE reasons:=array_append(reasons,'NO_QUALIFYING_FAMILY'); END IF;

  RETURN jsonb_build_object(
    'stage1_supplier_resolution_qualified', qualified,
    'selected_country', v_mkt,
    'qualifying_family_count', qual_ct,
    'present_family_count', present_ct,
    'evidence_families', fams,
    'disqualifiers', jsonb_build_object('observed_high_saturation',observed_high_sat,'branded_or_ip',branded,'identity_ambiguous',identity_ambiguous),
    'saturation_representation', sat_repr,
    'local_price', jsonb_build_object('class', coalesce(price_class,'UNKNOWN'),'validated_local_market_price', price_validated),
    'observed_sellers_distinct', sellers_distinct,
    'reasons', to_jsonb(reasons),
    'invariants', jsonb_build_object(
      'two_independent_qualifying_families_required', true,
      'commerce_alone_insufficient', true,
      'ads_alone_insufficient', true,
      'supplier_or_economics_cannot_qualify', true,
      'validated_local_price_not_required', true,
      'validated_saturation_not_required', true,
      'observed_high_saturation_blocks', true,
      'unknown_is_not_pass_and_not_observed_negative', true,
      'one_seller_not_low_competition', true,
      'one_listing_not_validated_price', true),
    'meaning','Enough independent, country-specific evidence to justify exact supplier resolution; NOT launch-ready.',
    'contract','pulse_stage1_supplier_resolution_qualified_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_stage1_supplier_resolution_qualified(uuid, uuid, text, integer) TO authenticated, service_role;

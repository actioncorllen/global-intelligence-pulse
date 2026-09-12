-- PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001
-- PHASE B (hard TEST eligibility gate) + PHASE C (deterministic template selection).
-- Both are pure/deterministic and explainable. The eligibility gate FAILS CLOSED:
-- a product must NOT generate a production storefront merely because it exists as an
-- opportunity. Composes the existing canonical hard gates (fn_test_identity_gate).

CREATE OR REPLACE FUNCTION public.fn_storefront_test_eligibility(p_inputs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO ''
AS $function$
DECLARE
  v_rec text := upper(coalesce(p_inputs->>'recommendation',''));
  v_tier text := upper(coalesce(p_inputs->>'decision_tier',''));
  v_sup text := upper(coalesce(p_inputs->>'supplier_identity_state',''));
  v_match text := upper(coalesce(p_inputs->>'market_supplier_match',''));
  v_subtype boolean := coalesce((p_inputs->>'subtype_price_valid')::boolean,false);
  v_stock text := upper(coalesce(p_inputs->>'stock_state','UNKNOWN'));
  v_econ text := upper(coalesce(p_inputs->>'economics_state','UNKNOWN'));
  v_conf text := upper(coalesce(p_inputs->>'product_confidence','UNKNOWN'));
  v_fulfil boolean := coalesce((p_inputs->>'fulfilment_evidence')::boolean,false);
  v_norisk boolean := coalesce((p_inputs->>'no_critical_risk')::boolean,false);
  v_sourcing text := upper(coalesce(p_inputs->>'sourcing_status',''));
  v_identity jsonb;
  v_reasons text[] := '{}';
  v_warn text[] := '{}';
  v_hi boolean := false;
BEGIN
  -- (0) External sourcing pending must fail closed (Nitro negative test).
  IF v_sourcing IN ('PENDING_EXTERNAL_CJ_SOURCING','PENDING','PROCESSING','SOURCING','AWAITING_SUPPLIER_RESULT','AWAITING_REFERENCE_IMAGE') THEN
    v_reasons := array_append(v_reasons, 'REJECT_SOURCING_PENDING_EXTERNAL');
  END IF;

  -- (1) Decision must be a genuine TEST decision from the canonical engine.
  IF v_rec NOT IN ('TEST','HIGH_CONFIDENCE_TEST') THEN
    v_reasons := array_append(v_reasons, CASE v_rec
      WHEN 'WATCH' THEN 'REJECT_WATCH'
      WHEN 'AVOID' THEN 'REJECT_AVOID'
      WHEN 'ANALYSIS_REQUIRED' THEN 'REJECT_ANALYSIS_REQUIRED'
      ELSE 'REJECT_NOT_TEST_DECISION' END);
  END IF;

  -- (2) Canonical supplier + market<->supplier identity (reuse existing gate).
  v_identity := public.fn_test_identity_gate(v_sup, v_match, v_subtype, v_norisk);
  IF (v_identity->>'test_identity') IS DISTINCT FROM 'TEST_IDENTITY_SATISFIED' THEN
    IF v_sup IS DISTINCT FROM 'SUPPLIER_EXACT' THEN
      v_reasons := array_append(v_reasons, 'REJECT_SUPPLIER_NOT_CANONICAL');
    ELSE
      v_reasons := array_append(v_reasons, 'REJECT_IDENTITY_WEAK');
    END IF;
  END IF;

  -- (3) Stock is a HARD gate. UNKNOWN never satisfies it.
  IF v_stock = 'OUT_OF_STOCK' THEN v_reasons := array_append(v_reasons, 'REJECT_OUT_OF_STOCK');
  ELSIF v_stock <> 'IN_STOCK' THEN v_reasons := array_append(v_reasons, 'REJECT_STOCK_UNKNOWN');
  END IF;

  -- (4) Landed economics must be viable. UNKNOWN/NEGATIVE fail closed; THIN warns.
  IF v_econ = 'NEGATIVE' THEN v_reasons := array_append(v_reasons, 'REJECT_ECONOMICS_UNVIABLE');
  ELSIF v_econ = 'THIN' THEN v_warn := array_append(v_warn, 'ECONOMICS_THIN');
  ELSIF v_econ <> 'VIABLE' THEN v_reasons := array_append(v_reasons, 'REJECT_ECONOMICS_UNKNOWN');
  END IF;

  -- (5) Product Confidence must be acceptable.
  IF v_conf NOT IN ('ACCEPTABLE','HIGH','STRONG') THEN
    v_reasons := array_append(v_reasons, 'REJECT_PRODUCT_CONFIDENCE_LOW');
  END IF;

  -- (6) Destination fulfilment evidence required.
  IF NOT v_fulfil THEN v_reasons := array_append(v_reasons, 'REJECT_NO_FULFILMENT_EVIDENCE'); END IF;

  -- (7) No critical evidence/risk gate failure.
  IF NOT v_norisk THEN v_reasons := array_append(v_reasons, 'REJECT_CRITICAL_RISK'); END IF;

  -- Tier is carried through faithfully; NEVER silently upgraded to HIGH-CONFIDENCE.
  v_hi := (v_rec = 'HIGH_CONFIDENCE_TEST') OR (v_tier = 'HIGH_CONFIDENCE_TEST');

  IF array_length(v_reasons,1) IS NULL THEN
    RETURN jsonb_build_object(
      'test_eligible', true, 'decision_state','TEST_ELIGIBLE',
      'decision_tier', CASE WHEN v_hi THEN 'HIGH_CONFIDENCE_TEST' ELSE 'STRONG_TEST' END,
      'high_confidence', v_hi,
      'reason_codes', jsonb_build_array('OK_TEST_ELIGIBLE'),
      'warnings', to_jsonb(v_warn), 'identity', v_identity,
      'checked', jsonb_build_object('recommendation',v_rec,'stock',v_stock,'economics',v_econ,
        'product_confidence',v_conf,'fulfilment_evidence',v_fulfil,'no_critical_risk',v_norisk,'sourcing_status',v_sourcing));
  ELSE
    RETURN jsonb_build_object(
      'test_eligible', false, 'decision_state','REFUSED',
      'decision_tier', CASE WHEN v_hi THEN 'HIGH_CONFIDENCE_TEST' ELSE NULLIF(v_tier,'') END,
      'high_confidence', false,
      'reason_codes', to_jsonb(v_reasons),
      'warnings', to_jsonb(v_warn), 'identity', v_identity,
      'checked', jsonb_build_object('recommendation',v_rec,'stock',v_stock,'economics',v_econ,
        'product_confidence',v_conf,'fulfilment_evidence',v_fulfil,'no_critical_risk',v_norisk,'sourcing_status',v_sourcing));
  END IF;
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_test_eligibility(jsonb) IS
 'Hard server-side gate for production-storefront generation. Fails closed on WATCH/AVOID/ANALYSIS_REQUIRED/PENDING_EXTERNAL/OUT_OF_STOCK/UNKNOWN-stock/UNVIABLE-or-UNKNOWN-economics/low-confidence/no-fulfilment/critical-risk. Never upgrades tier to HIGH-CONFIDENCE.';

CREATE OR REPLACE FUNCTION public.fn_select_conversion_template(p_input jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO ''
AS $function$
DECLARE
  v_cat text := lower(coalesce(p_input->>'category',''));
  v_traffic text := lower(coalesce(p_input->>'traffic_source',''));
  v_ev text[] := '{}';
  v_fam record;
  v_cands jsonb := '[]'::jsonb;
  v_disq boolean; v_missing text[]; v_score int; v_reasons text[];
  v_best jsonb := NULL; v_alt jsonb := NULL;
  v_sections jsonb; v_hero text; v_hero_ev text[]; v_note text := NULL;
BEGIN
  IF coalesce((p_input->>'buyer_pain')::boolean,false)        THEN v_ev := array_append(v_ev,'BUYER_PAIN'); END IF;
  IF coalesce((p_input->>'has_product_image')::boolean,false) THEN v_ev := array_append(v_ev,'PRODUCT_IMAGE'); END IF;
  IF coalesce((p_input->>'has_demo_asset')::boolean,false)    THEN v_ev := array_append(v_ev,'DEMO_ASSET'); END IF;
  IF coalesce((p_input->>'has_video_asset')::boolean,false)   THEN v_ev := array_append(v_ev,'VIDEO_ASSET'); END IF;
  IF coalesce((p_input->>'has_specs')::boolean,false)         THEN v_ev := array_append(v_ev,'PRODUCT_SPECS'); END IF;
  IF coalesce((p_input->>'has_reviews_ugc')::boolean,false)   THEN v_ev := array_append(v_ev,'REVIEWS_OR_UGC'); END IF;
  IF coalesce((p_input->>'has_comparison_basis')::boolean,false) THEN v_ev := array_append(v_ev,'COMPARISON_BASIS'); END IF;
  IF coalesce((p_input->>'has_before_after')::boolean,false)  THEN v_ev := array_append(v_ev,'BEFORE_AFTER_EVIDENCE'); END IF;
  IF coalesce((p_input->>'genuine_offer')::boolean,false)     THEN v_ev := array_append(v_ev,'GENUINE_OFFER'); END IF;
  IF coalesce((p_input->>'has_returns_policy')::boolean,false) THEN v_ev := array_append(v_ev,'RETURNS_POLICY'); END IF;

  FOR v_fam IN SELECT * FROM public.conversion_template_families WHERE is_active ORDER BY selection_priority LOOP
    v_disq := false; v_missing := '{}'; v_reasons := '{}';
    IF 'no_articulable_problem' = ANY(v_fam.disqualifiers) AND NOT ('BUYER_PAIN' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_articulable_problem'); END IF;
    IF 'no_usable_demo_asset' = ANY(v_fam.disqualifiers) AND NOT ('DEMO_ASSET' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_usable_demo_asset'); END IF;
    IF 'low_cost_commodity_no_premium_substantiation' = ANY(v_fam.disqualifiers) AND NOT coalesce((p_input->>'premium_substantiation')::boolean,false) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_premium_substantiation'); END IF;
    IF 'no_legitimate_social_proof' = ANY(v_fam.disqualifiers) AND NOT ('REVIEWS_OR_UGC' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_legitimate_social_proof'); END IF;
    IF 'unknown_specs' = ANY(v_fam.disqualifiers) AND NOT ('PRODUCT_SPECS' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:unknown_specs'); END IF;
    IF 'no_legitimate_comparison_basis' = ANY(v_fam.disqualifiers) AND NOT ('COMPARISON_BASIS' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_legitimate_comparison_basis'); END IF;
    IF 'purely_functional_no_emotional_angle' = ANY(v_fam.disqualifiers) AND NOT coalesce((p_input->>'emotional_angle')::boolean,false) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_emotional_angle'); END IF;
    IF 'no_legitimate_offer' = ANY(v_fam.disqualifiers) AND NOT ('GENUINE_OFFER' = ANY(v_ev)) THEN v_disq := true; v_reasons := array_append(v_reasons,'disqualified:no_legitimate_offer'); END IF;

    SELECT array_agg(e) INTO v_missing FROM unnest(v_fam.evidence_requirements) e WHERE NOT (e = ANY(v_ev));
    IF v_missing IS NOT NULL AND array_length(v_missing,1) > 0 THEN
      v_reasons := array_append(v_reasons, 'missing_evidence:'||array_to_string(v_missing,','));
    END IF;

    IF v_disq OR (v_missing IS NOT NULL AND array_length(v_missing,1) > 0) THEN
      CONTINUE;
    END IF;

    v_score := 0;
    IF v_cat <> '' AND v_cat = ANY(v_fam.categories) THEN v_score := v_score + 3; v_reasons := array_append(v_reasons,'category_match'); END IF;
    IF v_traffic <> '' AND v_traffic = ANY(v_fam.traffic_fit) THEN v_score := v_score + 2; v_reasons := array_append(v_reasons,'traffic_match'); END IF;
    v_score := v_score + (SELECT count(*)::int FROM unnest(v_fam.optional_sections) s
                          JOIN public.conversion_section_types t ON t.section_type=s
                          WHERE t.required_evidence <@ v_ev AND array_length(t.required_evidence,1) > 0);
    v_cands := v_cands || jsonb_build_object('family',v_fam.family,'score',v_score,
                 'priority',v_fam.selection_priority,'reasons',to_jsonb(v_reasons),'hero',v_fam.hero_variant);
  END LOOP;

  SELECT jsonb_agg(c ORDER BY (c->>'score')::int DESC, (c->>'priority')::int ASC)
    INTO v_cands FROM jsonb_array_elements(v_cands) c;
  IF v_cands IS NOT NULL AND jsonb_array_length(v_cands) >= 1 THEN v_best := v_cands->0; END IF;
  IF v_cands IS NOT NULL AND jsonb_array_length(v_cands) >= 2 THEN v_alt := v_cands->1; END IF;

  IF v_best IS NULL THEN
    v_best := jsonb_build_object('family','PROBLEM_SOLUTION','score',0,'priority',20,
                'reasons', jsonb_build_array('insufficient_evidence_fallback'),'hero','HERO_PROBLEM_FRAMING');
    v_note := 'INSUFFICIENT_EVIDENCE_FALLBACK';
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
           'type', o.section_type, 'order', o.ord,
           'conversion_role', st.default_conversion_role,
           'required_evidence', to_jsonb(st.required_evidence),
           'render', (st.required_evidence <@ v_ev),
           'degrade', CASE WHEN st.required_evidence <@ v_ev THEN 'RENDER'
                           WHEN st.structural THEN 'RENDER_EDITABLE' ELSE 'HIDE_OR_PLACEHOLDER' END,
           'mobile', st.mobile_defaults) ORDER BY o.ord)
    INTO v_sections
  FROM public.conversion_template_families f
  CROSS JOIN LATERAL unnest(f.ordering_strategy) WITH ORDINALITY AS o(section_type, ord)
  JOIN public.conversion_section_types st ON st.section_type = o.section_type
  WHERE f.family = (v_best->>'family');

  SELECT hero_variant INTO v_hero FROM public.conversion_template_families WHERE family=(v_best->>'family');
  SELECT required_evidence INTO v_hero_ev FROM public.conversion_hero_variants WHERE variant=v_hero;
  IF NOT (coalesce(v_hero_ev,'{}') <@ v_ev) THEN
    v_hero := 'HERO_PROBLEM_FRAMING';
  END IF;

  RETURN jsonb_build_object(
    'label','BEST_FIT',
    'recommended_template_family', v_best->>'family',
    'alternative_template_family', v_alt->>'family',
    'template_version','v1',
    'confidence', CASE WHEN v_note IS NOT NULL THEN 'LOW'
                       WHEN (v_best->>'score')::int >= 4 THEN 'HIGH'
                       WHEN (v_best->>'score')::int >= 2 THEN 'MEDIUM' ELSE 'LOW' END,
    'selection_reasons', v_best->'reasons',
    'hero_variant', v_hero,
    'cta_structure', (SELECT cta_structure FROM public.conversion_template_families WHERE family=(v_best->>'family')),
    'sections', v_sections,
    'recommended_section_order', (SELECT to_jsonb(ordering_strategy) FROM public.conversion_template_families WHERE family=(v_best->>'family')),
    'excluded_sections', (SELECT to_jsonb(excluded_sections) FROM public.conversion_template_families WHERE family=(v_best->>'family')),
    'missing_evidence', (SELECT coalesce(jsonb_agg(x->>'type'),'[]'::jsonb) FROM jsonb_array_elements(v_sections) x WHERE (x->>'render')::boolean = false),
    'available_evidence', to_jsonb(v_ev),
    'all_candidates', coalesce(v_cands,'[]'::jsonb),
    'note', v_note,
    'terminology_guard','PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN');
END; $function$;

COMMENT ON FUNCTION public.fn_select_conversion_template(jsonb) IS
 'Deterministic, evidence-gated template-family + section selection over the locked registry. Label BEST_FIT/RECOMMENDED, never PROVEN_BEST.';
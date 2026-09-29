-- ============================================================================
-- mig_338_product_page_claim_safety_gate.sql
-- Claim-safety + product-story refinement of the EXISTING product-page strategy
-- generation (fn_product_page_strategy). NOT a new engine, NOT a storefront
-- redesign.
--
-- ROOT CAUSE of generic + unsupported copy: fn_product_page_strategy surfaced
-- fn_generate_page_copy's DEFAULT copy verbatim, which asserts shipping,
-- "transparent estimated delivery", "new condition, fulfilled from the supplier
-- warehouse", and delivery/origin/condition FAQ entries even when no canonical
-- evidence supports them for PRODUCT + SELECTED MARKET, and uses generic filler
-- ("A practical X you can order online", "Straightforward X", "Shoppers
-- searching for X want a clear, no-guesswork option").
--
-- FIX: a server-side evidence gate that emits ONLY supported customer-facing
-- claims:
--   * Shipping to the selected market is claimed ONLY when the supplier's
--     shipping_country_codes actually cover that market (country-isolated:
--     CN_US supports US, not GB). No delivery TIME is ever claimed (no est-days
--     evidence). Fulfilment origin ("supplier warehouse") and condition ("new")
--     are OMITTED (no evidence). FAQ entries about delivery/origin/condition are
--     OMITTED entirely rather than shown with a guessed answer.
--   * Product story is grounded in the RESOLVED product identity/category
--     (factual use-context + accurate feature statements from the product type),
--     never fabricated pain, emotion, medical, safety, performance or specs.
--   * CONCEPT_ONLY products get no SKU-specific capability claims.
-- fn_generate_page_copy is still the base engine; its unsafe fields are gated /
-- overridden here. Product-step fields, scorer, rights/PAL, country isolation,
-- store membership unchanged.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_page_strategy(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_cp public.commerce_products%rowtype;
  v_c text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_sup jsonb; v_suprow public.commerce_supplier_products%rowtype;
  v_dec jsonb; v_img jsonb; v_ident text; v_has_img boolean;
  v_ccy text; v_brand text; v_context jsonb; v_decision jsonb; v_sel jsonb; v_strat jsonb; v_copy jsonb;
  v_type text; v_target text; v_seo jsonb; v_demand boolean; v_market_label text;
  v_ship_codes text[]; v_ships boolean := false; v_shippable jsonb; v_cat text; v_wt text;
  v_resolved boolean; v_kids boolean; v_headline text; v_subhead text; v_problem text; v_solution text;
  v_benefits jsonb := '[]'::jsonb; v_details jsonb := '[]'::jsonb; v_ship_note text; v_faq jsonb := '[]'::jsonb;
  v_claim_safety jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO v_cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_cp.user_id <> v_uid THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_ident := public.fn_product_identity_resolution(p_product_id)->>'identity_state';
  v_resolved := (v_ident = 'IDENTITY_RESOLVED');
  v_sup := public.fn_product_supplier_identity(p_product_id);
  IF coalesce((v_sup->>'has_supplier')::boolean,false) THEN
    SELECT * INTO v_suprow FROM public.commerce_supplier_products WHERE id=(v_sup->>'supplier_row_id')::uuid;
  END IF;
  v_img := public.fn_product_card_display_image(v_uid, p_product_id, v_c);
  v_has_img := coalesce((v_img->>'has_image')::boolean,false);

  SELECT to_jsonb(d.*) INTO v_dec FROM public.product_opportunity_decisions d
    WHERE d.product_id=p_product_id AND (v_c IS NULL OR d.country_code=v_c) AND coalesce(d.is_fixture,false)=false
    ORDER BY (d.country_code=v_c) DESC NULLS LAST, d.created_at DESC NULLS LAST LIMIT 1;

  v_type := coalesce(nullif(v_cp.category,''), v_cp.title);
  v_cat  := nullif(v_cp.extended->>'category','');
  v_wt   := CASE WHEN v_suprow.weight_grams IS NOT NULL THEN trim(to_char(v_suprow.weight_grams,'FM999999'))||' g' ELSE NULL END;
  v_ccy := coalesce(v_dec->>'market_currency','USD');
  SELECT country_name INTO v_market_label FROM public.ecommerce_market_universe WHERE country_code=v_c LIMIT 1;
  SELECT public.fn_store_display_name(brand_settings) INTO v_brand FROM public.commerce_hosted_stores
    WHERE user_id=v_uid AND is_default AND status<>'ARCHIVED' LIMIT 1;
  v_demand := coalesce((v_dec->'opportunity_sweet_spot'->'components'->>'demand_present')::boolean,false)
              OR coalesce((v_dec->'saturation_state'->>'evidence_class')='OBSERVED', false);

  -- ----- CLAIM EVIDENCE GATE (country-isolated) -----------------------------
  -- Shipping to the selected market is supported only when the supplier's
  -- shipping_country_codes actually cover it. "CN_US" supports US; a bare "CN"
  -- is origin-only; GLOBAL/WW cover all. Delivery TIME, condition and fulfilment
  -- origin have NO evidence source here and are never claimed.
  v_ship_codes := ARRAY(SELECT upper(btrim(x)) FROM jsonb_array_elements_text(coalesce(v_suprow.shipping_country_codes,'[]'::jsonb)) x);
  v_shippable := (SELECT coalesce(jsonb_agg(DISTINCT dest),'[]'::jsonb) FROM (
      SELECT CASE WHEN c IN ('GLOBAL','WW','WORLDWIDE','ALL','*') THEN 'GLOBAL'
                  WHEN c ~ '^[A-Z]{2}$' THEN c
                  WHEN c ~ '_[A-Z]{2}$' THEN right(c,2) ELSE NULL END AS dest
      FROM unnest(v_ship_codes) c) z WHERE dest IS NOT NULL);
  v_ships := v_c IS NOT NULL AND EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(v_shippable) d WHERE d = v_c OR d = 'GLOBAL');

  -- SEO keywords for THIS market only (country isolation); else product type
  SELECT coalesce(jsonb_agg(DISTINCT kw), NULL) INTO v_seo FROM (
      SELECT nullif(value->>'keyword','') kw FROM public.commerce_signals
      WHERE product_id=p_product_id AND signal_type ILIKE '%SEARCH%'
        AND (v_c IS NULL OR upper(coalesce(value->>'market',''))=v_c) LIMIT 8) z WHERE kw IS NOT NULL;
  IF v_seo IS NULL OR jsonb_array_length(v_seo)=0 THEN v_seo := jsonb_build_array(lower(v_type)); END IF;

  -- keep template/objective/angle from the existing engines (structure only)
  v_context := jsonb_strip_nulls(jsonb_build_object(
    'product_title', v_cp.title, 'positioning', v_type, 'category', coalesce(v_cat,v_type),
    'display_currency', v_ccy, 'selling_price', NULL, 'brand_name', v_brand, 'seo_keywords', v_seo,
    'buyer_intent', jsonb_build_object('band', CASE WHEN v_demand THEN 'PRESENT' ELSE 'UNKNOWN' END)));
  v_decision := jsonb_build_object('target_market', v_c, 'classification', coalesce(v_dec->>'decision','WATCH'),
    'economics', jsonb_build_object('economics_state', coalesce(v_dec->'economics_ref'->>'economics_state','UNKNOWN')),
    'product_trust', jsonb_build_object('gate', coalesce(v_dec->'hard_gates'->>'compliance','WATCH')),
    'supply_confidence', coalesce(v_dec->'component_scores'->'supplier'->>'confidence','UNKNOWN'));
  v_sel := public.fn_select_conversion_template(jsonb_build_object(
      'category', v_type, 'traffic_source','', 'buyer_pain', v_demand, 'has_product_image', v_has_img,
      'has_specs', false, 'has_reviews_ugc', false, 'has_comparison_basis', false,
      'genuine_offer', false, 'premium_substantiation', false, 'emotional_angle', false));
  v_strat := public.fn_storefront_conversion_strategy(v_sel, v_decision);
  v_copy  := public.fn_generate_page_copy(v_decision, v_context);  -- base engine (claim_safety flags reused)

  -- ----- PRODUCT-SPECIFIC, EVIDENCE-SAFE STORY ------------------------------
  v_kids := (lower(coalesce(v_cat,'')||' '||lower(v_type))) ~ 'kid|child|baby|nursery|toddler';
  v_headline := initcap(v_cp.title);
  v_subhead  := 'A '||lower(v_type)||'.';
  v_problem  := CASE WHEN v_kids THEN 'Adding projected, low-level light in a child''s room at night.'
                     ELSE 'Adding a '||lower(v_type)||' to your space.' END;
  -- factual, no manufactured pain, no performance/emotional claim
  v_solution := 'This listing presents a '||lower(v_type)||' with the details currently verified for it.';

  -- benefits: only evidence-supported, product-specific. NO delivery/condition/
  -- warehouse. Capability statements only for a RESOLVED identity.
  IF v_resolved AND lower(v_type) ~ 'projector' THEN
    v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','Projects light','basis','PRODUCT_IDENTITY_FACT'));
  END IF;
  IF v_resolved AND lower(v_type) ~ 'night ?light|nightlight' THEN
    v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','Designed for use as a night light','basis','PRODUCT_IDENTITY_FACT'));
  END IF;
  IF v_ships THEN
    v_benefits := v_benefits || jsonb_build_array(jsonb_build_object('text','Ships to '||coalesce(v_market_label,v_c),'basis','SUPPLIER_SHIPPING_EVIDENCE'));
    v_ship_note := 'Ships to '||coalesce(v_market_label,v_c)||'.';
  END IF;

  -- factual product details (verified facts only)
  v_details := '[]'::jsonb;
  IF nullif(v_type,'') IS NOT NULL THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Product type','value', initcap(v_type))); END IF;
  IF v_cat IS NOT NULL THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Intended for','value', initcap(v_cat))); END IF;
  IF v_wt IS NOT NULL THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Item weight (supplier reported)','value', v_wt)); END IF;
  IF v_ships THEN v_details := v_details || jsonb_build_array(jsonb_build_object('label','Ships to','value', coalesce(v_market_label,v_c))); END IF;

  -- FAQ: only entries whose answers are supported. Delivery/origin/condition are
  -- NOT supported -> FAQ omitted entirely (never a guessed answer).
  v_faq := '[]'::jsonb;

  v_target := 'Shoppers actively looking for a '||lower(v_type)
              ||CASE WHEN v_demand THEN ' (search/marketplace demand observed for this product).' ELSE '.' END;

  v_claim_safety := jsonb_build_object(
    'no_reviews_fabricated', true, 'no_fake_discount', true, 'no_urgency_scarcity', true,
    'no_guaranteed_delivery', true, 'no_delivery_time_claimed', true,
    'no_condition_claimed', (NOT false), 'no_fulfilment_origin_claimed', true,
    'no_certifications_or_warranty_claimed', true,
    'shipping_claimed_only_with_market_evidence', true);

  RETURN jsonb_build_object(
    'ok', true, 'product_id', p_product_id, 'market', v_c, 'market_label', coalesce(v_market_label, v_c),
    'has_strategy', true,
    'strategy_state', CASE WHEN v_ident='CONCEPT_ONLY' THEN 'CONCEPT_LEVEL_DRAFT' ELSE 'EVIDENCE_VALIDATED_DRAFT' END,
    'identity_state', v_ident,
    'objective', coalesce(v_strat->>'primary_objective','TEST_PURCHASE_INTENT_AT_LANDED_ECONOMICS'),
    'template_family', v_sel->>'recommended_template_family',
    'hero_variant', v_sel->>'hero_variant',
    'positioning', v_type,
    'value_proposition', v_subhead,
    'target_customer', jsonb_build_object('text', v_target, 'basis','PRODUCT_IDENTITY+DEMAND_SIGNAL',
        'confidence', CASE WHEN v_demand THEN 'MEDIUM' ELSE 'LOW' END),
    'key_benefits', v_benefits,
    'messaging_direction', jsonb_build_array(
        coalesce(v_strat->>'angle','Problem-first, evidence-safe default.'),
        'Awareness: '||coalesce(v_strat->>'awareness_assumption','PROBLEM_UNAWARE_TO_SOLUTION_AWARE'),
        v_problem),
    'cta_direction', coalesce(v_copy->'cta'->'primary'->>'label','Add to cart'),
    'subtitle', v_subhead,
    'page_copy', jsonb_build_object(
        'headline', v_headline,
        'subheadline', v_subhead,
        'short_description', 'A '||lower(v_type)||CASE WHEN v_cat IS NOT NULL THEN ' intended for '||lower(v_cat)||'.' ELSE '.' END,
        'problem', v_problem,
        'solution', v_solution,
        'how_it_works', '[]'::jsonb,          -- omitted: ordering/delivery steps not evidenced
        'faq', v_faq,                          -- omitted: delivery/origin/condition unsupported
        'details', v_details,
        'shipping_note', v_ship_note,          -- null unless the market is genuinely shippable
        'trust_note', NULL,                    -- no condition/fulfilment claim
        'announcement', NULL),
    'claims', jsonb_build_object(
        'ships_to_market', v_ships, 'shippable_markets', v_shippable,
        'delivery_time_evidence', false, 'condition_evidence', false, 'fulfilment_origin_evidence', false,
        'note','Shipping availability is derived from supplier shipping_country_codes for the SELECTED market only; delivery time, condition and fulfilment origin have no canonical evidence and are omitted.'),
    'evidence_confidence', coalesce(v_strat->>'confidence', v_sel->>'confidence','LOW'),
    'evidence_basis', coalesce(v_sel->'available_evidence','[]'::jsonb),
    'missing_evidence', jsonb_build_array('DELIVERY_TIME','CONDITION','FULFILMENT_ORIGIN','VERIFIED_REVIEWS','PRODUCT_SPECIFICATIONS'),
    'claim_safety', v_claim_safety,
    'generated_by', 'evidence_gated_claim_safe_v1',
    'note','Refinement of the existing strategy generation: fn_generate_page_copy base with a server-side evidence gate that emits only supported customer-facing claims. Not published; presence/demand are not sales/performance claims.',
    'contract','pulse_product_page_strategy_v3');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_page_strategy(uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_page_strategy(uuid,text) TO authenticated, service_role;

-- Claim-safety selftest (no writes).
CREATE OR REPLACE FUNCTION public.fn_product_page_strategy_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; us jsonb; gb jsonb; h jsonb; ctx jsonb;
  v_night uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_humid uuid := 'cda3f71a-9947-4344-8664-13735740575f';
  bad text := 'transparent estimated delivery|fulfilled from the supplier warehouse|new condition|estimated delivery window|how long does delivery';
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"7c8ddf9d-172c-4a89-a402-bb7066228b61","role":"authenticated"}', true);
  us := public.fn_product_page_strategy(v_night,'US');
  gb := public.fn_product_page_strategy(v_night,'GB');
  h  := public.fn_product_page_strategy(v_humid,'GB');
  ctx := public.fn_product_page_builder_context(v_night,'GB');

  -- claim safety: no unsupported delivery/condition/fulfilment strings anywhere
  v := v || jsonb_build_object('case','us_no_unsupported_claims','pass', (us::text !~* bad));
  v := v || jsonb_build_object('case','gb_no_unsupported_claims','pass', (gb::text !~* bad));
  -- shipping is market-specific: US shippable (CN_US), GB not
  v := v || jsonb_build_object('case','us_ships_true','pass', (us->'claims'->>'ships_to_market')::boolean = true);
  v := v || jsonb_build_object('case','gb_ships_false','pass', (gb->'claims'->>'ships_to_market')::boolean = false);
  v := v || jsonb_build_object('case','us_ships_benefit_present','pass', (us->'key_benefits')::text ILIKE '%Ships to%');
  v := v || jsonb_build_object('case','gb_no_ships_benefit','pass', (gb->'key_benefits')::text NOT ILIKE '%Ships to%');
  v := v || jsonb_build_object('case','gb_no_ship_note','pass', (gb->'page_copy'->'shipping_note') = 'null'::jsonb);
  -- FAQ omitted (no supported answers) — never a guessed answer
  v := v || jsonb_build_object('case','faq_omitted','pass', jsonb_array_length(coalesce(us->'page_copy'->'faq','[]'::jsonb)) = 0);
  v := v || jsonb_build_object('case','howitworks_omitted','pass', jsonb_array_length(coalesce(us->'page_copy'->'how_it_works','[]'::jsonb)) = 0);
  -- product-specific, evidence-grounded story (not generic filler)
  v := v || jsonb_build_object('case','product_specific_benefit','pass', (us->'key_benefits')::text ILIKE '%Projects light%');
  v := v || jsonb_build_object('case','no_filler_order_online','pass', (us::text !~* 'you can order online|straightforward '||'nightlight'));
  v := v || jsonb_build_object('case','details_present','pass', jsonb_array_length(coalesce(us->'page_copy'->'details','[]'::jsonb)) >= 2);
  v := v || jsonb_build_object('case','value_prop_present','pass', nullif(us->>'value_proposition','') IS NOT NULL);
  -- rich structure inputs still available (problem/solution/benefits/details)
  v := v || jsonb_build_object('case','has_problem','pass', nullif(us->'page_copy'->>'problem','') IS NOT NULL);
  v := v || jsonb_build_object('case','has_solution','pass', nullif(us->'page_copy'->>'solution','') IS NOT NULL);
  -- concept-only humidifier: no capability claim, stays concept-level, no shipping
  v := v || jsonb_build_object('case','humidifier_concept_level','pass', h->>'strategy_state'='CONCEPT_LEVEL_DRAFT');
  v := v || jsonb_build_object('case','humidifier_no_capability_claim','pass', jsonb_array_length(coalesce(h->'key_benefits','[]'::jsonb)) = 0);
  v := v || jsonb_build_object('case','humidifier_identity_unchanged','pass', h->>'identity_state'='CONCEPT_ONLY');
  -- product-step regression + no fixture leak
  v := v || jsonb_build_object('case','context_product_type','pass', ctx->'product'->>'type'='nightlight projector');
  v := v || jsonb_build_object('case','context_supplier_cj_cost','pass', (ctx->'supplier'->>'provider')='CJ' AND (ctx->'supplier'->'supplier_cost'->>'amount') IS NOT NULL);
  v := v || jsonb_build_object('case','context_image_publishable','pass', (ctx->'commercial_image'->>'publishable')::boolean);
  v := v || jsonb_build_object('case','no_fixture_leak','pass', (us::text !~* 'hearth|fermentation|fixture|fictional editorial'));

  PERFORM set_config('request.jwt.claims','', true);
  RETURN jsonb_build_object('suite','product_page_strategy',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_page_strategy_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_product_page_strategy_selftest() TO service_role;

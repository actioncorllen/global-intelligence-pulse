-- ============================================================================
-- mig_337_product_page_full_copy_and_market_label.sql
-- Premium page depth: the real product page rendered only Hero -> Trust -> CTA
-- because (a) fn_product_page_strategy forwarded only a SUBSET of the existing
-- claim-safe copy engine (fn_generate_page_copy) output -- positioning / value
-- proposition / benefits -- and dropped problem, solution, how-it-works and FAQ,
-- so the frontend had no content to render those sections; and (b) no market
-- label was exposed, so the storefront showed "Your market".
--
-- This surfaces the FULL claim-safe copy (page_copy) and a market_label from the
-- EXISTING engines/tables. No new engine, no fabrication (fn_generate_page_copy
-- remains claim-safe: no reviews/discount/urgency/guarantee). Country isolation
-- preserved (market-scoped). fn_product_page_builder_context also exposes
-- market_label. Product-step + strategy fields are otherwise unchanged.
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
  v_type text; v_pos text; v_vp text; v_benefits jsonb; v_target text; v_seo jsonb; v_demand boolean;
  v_market_label text;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO v_cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_cp.user_id <> v_uid THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_ident := public.fn_product_identity_resolution(p_product_id)->>'identity_state';
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
  v_ccy := coalesce(v_dec->>'market_currency','USD');
  SELECT country_name INTO v_market_label FROM public.ecommerce_market_universe WHERE country_code=v_c LIMIT 1;
  SELECT public.fn_store_display_name(brand_settings) INTO v_brand FROM public.commerce_hosted_stores
    WHERE user_id=v_uid AND is_default AND status<>'ARCHIVED' LIMIT 1;
  v_demand := coalesce((v_dec->'opportunity_sweet_spot'->'components'->>'demand_present')::boolean,false)
              OR coalesce((v_dec->'saturation_state'->>'evidence_class')='OBSERVED', false);

  SELECT coalesce(jsonb_agg(DISTINCT kw), NULL)
    INTO v_seo FROM (
      SELECT nullif(value->>'keyword','') kw FROM public.commerce_signals
      WHERE product_id=p_product_id AND signal_type ILIKE '%SEARCH%'
        AND (v_c IS NULL OR upper(coalesce(value->>'market',''))=v_c)
      LIMIT 8) z WHERE kw IS NOT NULL;
  IF v_seo IS NULL OR jsonb_array_length(v_seo)=0 THEN v_seo := jsonb_build_array(lower(v_type)); END IF;

  v_context := jsonb_strip_nulls(jsonb_build_object(
    'product_title', v_cp.title, 'positioning', v_type, 'category', v_type,
    'display_currency', v_ccy, 'selling_price', NULL,
    'brand_name', v_brand, 'seo_keywords', v_seo,
    'buyer_intent', jsonb_build_object('band', CASE WHEN v_demand THEN 'PRESENT' ELSE 'UNKNOWN' END)));

  v_decision := jsonb_build_object(
    'target_market', v_c, 'classification', coalesce(v_dec->>'decision','WATCH'),
    'economics', jsonb_build_object(
       'economics_state', coalesce(v_dec->'economics_ref'->>'economics_state','UNKNOWN'),
       'landed_cost_currency', coalesce(v_suprow.cost_currency,'USD'),
       'landed_cost_display', CASE WHEN v_suprow.supplier_cost IS NOT NULL
            THEN v_suprow.supplier_cost::text||' '||coalesce(v_suprow.cost_currency,'USD') ELSE NULL END),
    'product_trust', jsonb_build_object('gate', coalesce(v_dec->'hard_gates'->>'compliance','WATCH')),
    'supply_confidence', coalesce(v_dec->'component_scores'->'supplier'->>'confidence','UNKNOWN'),
    'supplier_execution', jsonb_build_object('delivery','{}'::jsonb));

  v_sel := public.fn_select_conversion_template(jsonb_build_object(
      'category', v_type, 'traffic_source','',
      'buyer_pain', v_demand, 'has_product_image', v_has_img,
      'has_specs', false, 'has_reviews_ugc', false, 'has_comparison_basis', false,
      'genuine_offer', false, 'premium_substantiation', false, 'emotional_angle', false));
  v_strat := public.fn_storefront_conversion_strategy(v_sel, v_decision);
  v_copy := public.fn_generate_page_copy(v_decision, v_context);

  v_pos := coalesce(v_copy->>'positioning', v_type);
  v_vp := coalesce(v_copy->'problem_solution'->>'solution', v_copy->'hero'->>'subheadline', v_copy->>'short_description');
  v_benefits := coalesce(v_copy->'benefits','[]'::jsonb);
  v_target := 'Shoppers actively looking for a '||lower(v_type)
              ||CASE WHEN v_demand THEN ' (search/marketplace demand observed for this product).' ELSE '.' END;

  RETURN jsonb_build_object(
    'ok', true, 'product_id', p_product_id, 'market', v_c, 'market_label', coalesce(v_market_label, v_c),
    'has_strategy', true,
    'strategy_state', CASE WHEN v_ident='CONCEPT_ONLY' THEN 'CONCEPT_LEVEL_DRAFT' ELSE 'EVIDENCE_VALIDATED_DRAFT' END,
    'identity_state', v_ident,
    'objective', coalesce(v_strat->>'primary_objective','TEST_PURCHASE_INTENT_AT_LANDED_ECONOMICS'),
    'template_family', v_sel->>'recommended_template_family',
    'hero_variant', v_sel->>'hero_variant',
    'positioning', v_pos,
    'value_proposition', v_vp,
    'target_customer', jsonb_build_object('text', v_target, 'basis','PRODUCT_IDENTITY+DEMAND_SIGNAL',
        'confidence', CASE WHEN v_demand THEN 'MEDIUM' ELSE 'LOW' END),
    'key_benefits', (SELECT coalesce(jsonb_agg(jsonb_build_object('text', b, 'basis','CLAIM_SAFE_TEMPLATE_EDITABLE')),'[]'::jsonb)
                     FROM jsonb_array_elements_text(v_benefits) b),
    'messaging_direction', jsonb_build_array(
        coalesce(v_strat->>'angle','Problem-first, evidence-safe default.'),
        'Awareness: '||coalesce(v_strat->>'awareness_assumption','PROBLEM_UNAWARE_TO_SOLUTION_AWARE'),
        v_copy->'problem_solution'->>'problem'),
    'cta_direction', coalesce(v_copy->'cta'->'primary'->>'label','Add to cart'),
    'subtitle', v_copy->'hero'->>'subheadline',
    -- FULL claim-safe copy so the frontend can render premium page depth
    'page_copy', jsonb_build_object(
        'headline', v_copy->'hero'->>'headline',
        'subheadline', v_copy->'hero'->>'subheadline',
        'short_description', v_copy->>'short_description',
        'problem', v_copy->'problem_solution'->>'problem',
        'solution', v_copy->'problem_solution'->>'solution',
        'how_it_works', coalesce(v_copy->'how_it_works','[]'::jsonb),
        'faq', coalesce(v_copy->'faq','[]'::jsonb),
        'details', coalesce(v_copy->'details','{}'::jsonb),
        'shipping_note', v_copy->'shipping'->>'copy',
        'trust_note', v_copy->'trust'->>'copy',
        'announcement', v_copy->>'announcement'),
    'evidence_confidence', coalesce(v_strat->>'confidence', v_sel->>'confidence','LOW'),
    'evidence_basis', coalesce(v_sel->'available_evidence','[]'::jsonb),
    'missing_evidence', coalesce(v_strat->'missing_evidence', v_sel->'missing_evidence','[]'::jsonb),
    'claim_safety', v_copy->'claim_safety',
    'generated_by', v_copy->>'generated_by',
    'note','Assembled from existing engines (fn_select_conversion_template + fn_storefront_conversion_strategy + fn_generate_page_copy). Claim-safe deterministic draft for merchant review; not published; presence/demand are not sales/performance claims.',
    'contract','pulse_product_page_strategy_v2');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_page_strategy(uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_page_strategy(uuid,text) TO authenticated, service_role;

-- Expose market_label on the builder context (fixes "Your market").
CREATE OR REPLACE FUNCTION public.fn_product_page_builder_context(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_cp public.commerce_products%rowtype;
  v_c text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_ident jsonb; v_sup jsonb; v_suprow public.commerce_supplier_products%rowtype;
  v_img jsonb; v_ready jsonb; v_econ jsonb; v_econ_state text; v_page record;
  v_acq record; v_listing jsonb; v_type text; v_obs_present boolean; v_strategy jsonb; v_market_label text;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO v_cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_cp.user_id <> v_uid THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_ident := public.fn_product_identity_resolution(p_product_id);
  v_sup := public.fn_product_supplier_identity(p_product_id);
  IF coalesce((v_sup->>'has_supplier')::boolean,false) THEN
    SELECT * INTO v_suprow FROM public.commerce_supplier_products WHERE id = (v_sup->>'supplier_row_id')::uuid;
  END IF;

  v_img := public.fn_product_card_display_image(v_uid, p_product_id, v_c);
  v_ready := public.fn_product_commercial_asset_readiness(p_product_id, v_c);

  SELECT economics_ref INTO v_econ FROM public.product_opportunity_decisions
    WHERE product_id=p_product_id AND (v_c IS NULL OR country_code=v_c) AND coalesce(is_fixture,false)=false
    ORDER BY (country_code=v_c) DESC NULLS LAST, created_at DESC NULLS LAST LIMIT 1;
  v_econ_state := coalesce(v_econ->>'economics_state','UNKNOWN');

  SELECT id, status, publication_state, published_url INTO v_page
    FROM public.commerce_product_pages
    WHERE user_id=v_uid AND product_id=p_product_id AND (v_c IS NULL OR market=v_c OR country_code=v_c)
    ORDER BY updated_at DESC NULLS LAST LIMIT 1;

  SELECT prepared_package INTO v_acq FROM public.product_acquisitions
    WHERE user_id=v_uid AND winning_product_snapshot->>'product_id' = p_product_id::text
    ORDER BY updated_at DESC NULLS LAST LIMIT 1;
  v_listing := CASE WHEN v_acq.prepared_package IS NOT NULL THEN v_acq.prepared_package->'listing' ELSE NULL END;

  v_type := coalesce(nullif(v_cp.category,''), nullif(v_cp.extended->>'product_type',''), nullif(v_cp.extended->>'category',''));
  v_obs_present := v_cp.observed_price IS NOT NULL;
  v_strategy := public.fn_product_page_strategy(p_product_id, v_c);
  SELECT country_name INTO v_market_label FROM public.ecommerce_market_universe WHERE country_code=v_c LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true, 'product_id', p_product_id, 'market', v_c, 'market_label', coalesce(v_market_label, v_c),
    'product', jsonb_build_object(
       'title', coalesce(v_listing->>'title', v_cp.title),
       'type', v_type,
       'normalized_name', v_cp.extended->>'normalized_name',
       'source_store', v_cp.source_store),
    'identity', jsonb_build_object(
       'state', v_ident->>'identity_state', 'label', v_ident->>'label',
       'supplier_link_allowed', (v_ident->>'supplier_link_allowed')::boolean),
    'supplier', CASE WHEN coalesce((v_sup->>'has_supplier')::boolean,false) THEN jsonb_build_object(
       'matched', true, 'provider', v_sup->>'provider',
       'supplier_product_id', v_sup->>'supplier_product_id',
       'supplier_name', coalesce(v_suprow.supplier_name, v_sup->>'provider'),
       'product_url', v_suprow.product_url,
       'supplier_cost', CASE WHEN v_suprow.supplier_cost IS NOT NULL
            THEN jsonb_build_object('amount', v_suprow.supplier_cost, 'currency', coalesce(v_suprow.cost_currency,'USD'),
                 'provenance','SUPPLIER_REPORTED')
            ELSE NULL END)
       ELSE jsonb_build_object('matched', false,
            'note','No connected-supplier product is linked. Supplier selection/recovery required before a supplier cost exists.') END,
    'pricing', jsonb_build_object(
       'observed_source_price', CASE WHEN v_obs_present
            THEN jsonb_build_object('amount', v_cp.observed_price, 'currency', v_cp.price_currency,
                 'provenance','MARKETPLACE_OBSERVED')
            ELSE NULL END,
       'observed_source_price_present', v_obs_present,
       'supplier_cost', CASE WHEN v_suprow.supplier_cost IS NOT NULL
            THEN jsonb_build_object('amount', v_suprow.supplier_cost, 'currency', coalesce(v_suprow.cost_currency,'USD'))
            ELSE NULL END,
       'economics_state', v_econ_state,
       'suggested_selling_price', NULL,
       'selling_price_configured', false,
       'profit_target_rule','Target ~$25-30+ net profit per sale after supplier/product cost + estimated customer-acquisition cost. Strateloq suggests a selling price only when economics evidence supports it; otherwise the merchant sets it.',
       'economics_note', CASE WHEN v_econ_state='UNKNOWN'
            THEN 'Customer-acquisition/economics evidence is not yet established for this market, so no selling price is auto-suggested. Supplier cost is shown; the merchant confirms the selling price.'
            ELSE NULL END),
    'commercial_image', jsonb_build_object(
       'url', v_img->>'url', 'has_image', coalesce((v_img->>'has_image')::boolean,false),
       'rights_state', v_img->>'rights_state', 'source_provider', v_img->>'source_provider',
       'is_authoritative', coalesce((v_img->>'is_authoritative')::boolean,false),
       'publishable', coalesce((v_img->>'is_authoritative')::boolean,false)),
    'commercial_asset_readiness', v_ready->>'commercial_asset_readiness',
    'commercial_testability', v_ready->>'commercial_testability',
    'strategy', v_strategy,
    'prepared_listing', CASE WHEN v_listing IS NOT NULL THEN jsonb_build_object(
        'positioning', v_listing->>'positioning_statement', 'target_customer', v_listing->>'target_customer',
        'key_benefits', coalesce(v_listing->'key_benefits','[]'::jsonb), 'subtitle', v_listing->>'subtitle',
        'source','APPROVED_PREPARED_LISTING') ELSE NULL END,
    'page', jsonb_build_object('page_id', v_page.id, 'status', v_page.status,
       'publication_state', coalesce(v_page.publication_state,'UNPUBLISHED'), 'published_url', v_page.published_url),
    'provenance_note','Assembled from canonical Strateloq intelligence (identity, supplier, supplier cost, commercial image, readiness, economics, evidence-validated strategy). Null fields are genuinely uncollected, never fabricated.',
    'contract','pulse_product_page_builder_context_v3');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_page_builder_context(uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_page_builder_context(uuid,text) TO authenticated, service_role;

-- Extend the strategy selftest with page-depth + market-label assertions.
CREATE OR REPLACE FUNCTION public.fn_product_page_strategy_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; n jsonb; h jsonb; ctx jsonb;
  v_night uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_humid uuid := 'cda3f71a-9947-4344-8664-13735740575f';
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"7c8ddf9d-172c-4a89-a402-bb7066228b61","role":"authenticated"}', true);
  n := public.fn_product_page_strategy(v_night,'GB');
  h := public.fn_product_page_strategy(v_humid,'GB');
  ctx := public.fn_product_page_builder_context(v_night,'GB');

  v := v || jsonb_build_object('case','nightlight_positioning_present','pass', nullif(n->>'positioning','') IS NOT NULL);
  v := v || jsonb_build_object('case','nightlight_value_prop_present','pass', nullif(n->>'value_proposition','') IS NOT NULL);
  v := v || jsonb_build_object('case','nightlight_benefits_present','pass', jsonb_array_length(coalesce(n->'key_benefits','[]'::jsonb)) > 0);
  v := v || jsonb_build_object('case','nightlight_target_customer_present','pass', nullif(n->'target_customer'->>'text','') IS NOT NULL);
  v := v || jsonb_build_object('case','nightlight_objective_present','pass', nullif(n->>'objective','') IS NOT NULL);
  v := v || jsonb_build_object('case','nightlight_cta_present','pass', nullif(n->>'cta_direction','') IS NOT NULL);
  v := v || jsonb_build_object('case','nightlight_evidence_validated','pass', n->>'strategy_state'='EVIDENCE_VALIDATED_DRAFT');
  -- page depth: full claim-safe copy present so richer sections can render
  v := v || jsonb_build_object('case','nightlight_pagecopy_problem','pass', nullif(n->'page_copy'->>'problem','') IS NOT NULL);
  v := v || jsonb_build_object('case','nightlight_pagecopy_solution','pass', nullif(n->'page_copy'->>'solution','') IS NOT NULL);
  v := v || jsonb_build_object('case','nightlight_pagecopy_howitworks','pass', jsonb_array_length(coalesce(n->'page_copy'->'how_it_works','[]'::jsonb)) > 0);
  v := v || jsonb_build_object('case','nightlight_pagecopy_faq','pass', jsonb_array_length(coalesce(n->'page_copy'->'faq','[]'::jsonb)) > 0);
  v := v || jsonb_build_object('case','nightlight_market_label','pass', n->>'market_label'='United Kingdom');
  v := v || jsonb_build_object('case','ctx_market_label','pass', nullif(ctx->>'market_label','') IS NOT NULL AND ctx->>'market_label' <> 'GB');
  -- claim safety
  v := v || jsonb_build_object('case','claim_safe_no_reviews','pass', (n->'claim_safety'->>'no_reviews_fabricated')::boolean IS TRUE);
  v := v || jsonb_build_object('case','claim_safe_no_guarantee','pass', (n->'claim_safety'->>'no_guaranteed_delivery')::boolean IS TRUE);
  -- concept-only stays concept-level
  v := v || jsonb_build_object('case','humidifier_concept_level_draft','pass', h->>'strategy_state'='CONCEPT_LEVEL_DRAFT');
  v := v || jsonb_build_object('case','humidifier_identity_unchanged','pass', h->>'identity_state'='CONCEPT_ONLY');
  -- product-step regression + strategy in context
  v := v || jsonb_build_object('case','context_product_type','pass', ctx->'product'->>'type'='nightlight projector');
  v := v || jsonb_build_object('case','context_supplier_cj_cost','pass', (ctx->'supplier'->>'provider')='CJ' AND (ctx->'supplier'->'supplier_cost'->>'amount') IS NOT NULL);
  v := v || jsonb_build_object('case','context_image_publishable','pass', (ctx->'commercial_image'->>'publishable')::boolean);
  v := v || jsonb_build_object('case','context_strategy_populated','pass', nullif(ctx->'strategy'->>'value_proposition','') IS NOT NULL);
  -- fixture-leak guard: no fixture strings anywhere in the strategy/copy
  v := v || jsonb_build_object('case','no_fixture_leak','pass',
        (n::text !~* 'hearth|fermentation|fixture|fictional editorial') );

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

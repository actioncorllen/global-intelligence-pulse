-- PULSE-ECOM-P8-PUBLISHED-COPY-AUTHORING-NOTE-FIX-001
-- Remove customer-visible internal authoring/editor instructions from the copy
-- generator so no future published page carries them. Three surgical string
-- swaps in the customer-facing fields the public renderer exposes; all other
-- copy, structure, claim-safety and provenance are unchanged. No new claims.
--   1. short_description: drop the "...Confirm specifications ... before publishing" editor clause.
--   2. benefits: replace the "Edit these bullets to match verified product features" authoring line.
--   3. faq: replace the merchant-facing "Can I edit this page? / editable before you publish" entry
--      with a customer-facing, evidence-supported condition FAQ.
CREATE OR REPLACE FUNCTION public.fn_generate_page_copy(p_decision jsonb, p_context jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  v_title text := coalesce(p_context->>'product_title','Product');
  v_pos text := coalesce(p_context->>'positioning', v_title);
  v_cur text := coalesce(p_context->>'display_currency','USD'); v_price text := p_context->>'selling_price';
  v_deliv jsonb := coalesce(p_decision->'supplier_execution'->'delivery','{}'::jsonb);
  v_min text := v_deliv->>'est_min_days'; v_max text := v_deliv->>'est_max_days'; v_method text := v_deliv->>'method';
  v_brand text := coalesce(p_context->>'brand_name', initcap(split_part(v_pos,' ',1))||' Supply Co.');
  v_ship text;
BEGIN
  v_ship := CASE WHEN v_min IS NOT NULL AND v_max IS NOT NULL
    THEN 'Estimated delivery: '||v_min||E'–'||v_max||' days ('||coalesce(v_method,'standard shipping')||'; carrier estimate, not guaranteed).'
    ELSE 'Delivery estimate confirmed at checkout.' END;
  RETURN jsonb_build_object(
   'model_version','pulse_product_page_v1','editable',true,'draft_first',true,'generated_by','deterministic_claim_safe_generator_v1',
   'brand', jsonb_build_object('name', v_brand,'logo','TEXT_MARK_PLACEHOLDER','voice','clear, practical, honest','headline_style','benefit-led, factual',
      'theme_tokens', jsonb_build_object('primary','#111827','accent','#2563eb','bg','#ffffff','text','#1f2937')),
   'announcement','Estimated delivery '||coalesce(v_min||E'–'||v_max||' days','shown at checkout')||' • Draft store (not published)',
   'hero', jsonb_build_object('headline', initcap(v_pos),'subheadline','A practical '||lower(v_pos)||' you can order online.'),
   'product_title', v_title,'positioning', v_pos,
   'short_description','This listing is for a '||lower(v_pos)||'.',
   'benefits', jsonb_build_array('Straightforward '||lower(v_pos),'Ships to '||coalesce(p_decision->>'target_market','your market'),
      'Transparent estimated delivery','New condition, fulfilled from the supplier warehouse'),
   'problem_solution', jsonb_build_object('problem','Shoppers searching for '||lower(v_pos)||' want a clear, no-guesswork option.',
      'solution','This page presents the product with honest details and an estimated delivery window.'),
   'how_it_works', jsonb_build_array('Choose your options','Place your order','Receive within the estimated delivery window'),
   'details', jsonb_build_object('category', p_context->>'category','material', p_context->>'material','note','confirm specifications from supplier data'),
   'shipping', jsonb_build_object('copy', v_ship,'est_min_days', v_min,'est_max_days', v_max,'method', v_method),
   'trust', jsonb_build_object('copy','New condition. Fulfilled from the supplier warehouse. Delivery times are estimates, not guarantees.',
      'authenticity_state', p_decision->'product_trust'->>'gate','supply_confidence', p_decision->>'supply_confidence',
      'disclaimers', jsonb_build_array('No reviews, ratings, or testimonials are shown (none verified).','Delivery is an estimate, not a guarantee.')),
   'price', jsonb_build_object('selling_price', v_price,'currency', v_cur,'source_currency', p_decision->'economics'->>'landed_cost_currency',
      'landed_cost_display', p_decision->'economics'->>'landed_cost_display','offer_note','No discount or crossed-out price shown (no verified prior price).'),
   'faq', jsonb_build_array(
      jsonb_build_object('q','How long is delivery?','a', v_ship),
      jsonb_build_object('q','Where does it ship from?','a','From the supplier warehouse; see the shipping estimate.'),
      jsonb_build_object('q','What condition is the product?','a','New, fulfilled from the supplier warehouse. Delivery times are estimates, not guarantees.')),
   'cta', jsonb_build_object(
      'primary', jsonb_build_object('label','Add to cart','checkout_boundary','CHECKOUT_HANDLED_BY_DESTINATION_STORE','functional',false),
      'secondary', jsonb_build_object('label','See product details','action','SCROLL_TO_DETAILS')),
   'seo', jsonb_build_object('title', left(v_title||' | '||v_brand,60),
      'meta_description', left('Order '||lower(v_pos)||'. Estimated delivery '||coalesce(v_min||E'–'||v_max||' days','shown at checkout')||'.',155),
      'keywords', coalesce(p_context->'seo_keywords', jsonb_build_array(lower(v_pos)))),
   'assets', jsonb_build_object('primary_image', NULL,'gallery','[]'::jsonb,'state','PRODUCT_ASSET_REQUIRED',
      'note','no legitimate product image available; merchant must upload/verify (no fabricated supplier photo)'),
   'copy_provenance', jsonb_build_object('headline','AI_TRANSFORMATION(positioning)','short_description','AI_TRANSFORMATION(positioning)',
      'benefits','AI_TEMPLATE(editable)','shipping','DELIVERY_EVIDENCE(CJ_FREIGHT_CALCULATE)','price','PRODUCT_DECISION_ECONOMICS',
      'trust','PRODUCT_DECISION(product_trust,supply_confidence)','seo','AI_TRANSFORMATION(title,positioning)',
      'brand', CASE WHEN p_context ? 'brand_name' THEN 'BUSINESS_DNA' ELSE 'AI_SUGGESTION_EDITABLE' END),
   'claim_safety', jsonb_build_object('no_reviews_fabricated',true,'no_fake_discount',true,'no_guaranteed_delivery',true,
      'no_urgency_scarcity',true,'no_certifications_or_warranty_claimed',true,'delivery_labeled_estimate',true));
END; $function$;

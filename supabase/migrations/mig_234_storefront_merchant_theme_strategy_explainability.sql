-- STRATELOQ-ECOM-P8-CONVERSION-RUNTIME-INTEGRATION-002
-- Close the three GENUINE gaps found in the storefront conversion runtime audit.
-- Everything here is ADDITIVE and reuses the existing runtime (mig_224–233):
-- no table is created, no existing runtime_contract key is removed or renamed,
-- and the existing fn_storefront_runtime_selftest (38 cases) must stay green.
--
-- Gap 1 — Merchant branding -> theme tokens. The runtime contract carried no
--   resolved brand/theme. fn_generate_page_copy hard-coded neutral tokens and
--   took brand_name verbatim. This adds a DETERMINISTIC resolver enforcing:
--     customer  = merchant brand   (business identity)
--     internal  = Strateloq brand  (ONLY when Strateloq is itself the merchant)
--     fallback  = neutral          (never Strateloq)
--   with a hard safety rule: the Strateloq brand is never exposed as a customer
--   brand unless the tenant genuinely IS Strateloq (INTERNAL_STRATELOQ scope).
--   No brand COLOURS are stored anywhere, so non-Strateloq tokens stay neutral
--   (we never fabricate a merchant palette); the merchant's NAME and VOICE are
--   real (business_profiles / member_business_dna).
--
-- Gap 2 — Founder explainability. selection_reasons were machine codes only.
--   fn_storefront_why_this_page renders an honest human-readable "Why this page?"
--   (best-fit pre-performance, evidence used/missing, currency, assets, claims,
--   brand) — no fake precision, no "highest converting" language.
--
-- Gap 3 — Explicit Conversion Strategy contract. The strategy was implicit in
--   the selection. fn_storefront_conversion_strategy emits a typed, named block
--   (objective / angle / awareness / cta model / evidence basis / terminology
--   guard) so the contract states the strategy explicitly.
--
-- All three are wired into fn_generate_storefront_runtime as new contract keys
-- (merchant_theme, brand_scope, conversion_strategy, explainability). A companion
-- deterministic selftest (fn_storefront_branding_selftest) proves the gap closures.

-- ---------------------------------------------------------------------------
-- Gap 1: deterministic merchant-branding -> theme-token resolver (pure).
-- p_brand_scope is resolved by the caller (the generator) from tenant identity:
--   INTERNAL_STRATELOQ  -> tenant == fn_global_intelligence_uid()
--   MERCHANT            -> a real merchant with a business identity / brand
--   NEUTRAL             -> no brand identity resolved
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_merchant_theme(
  p_context jsonb, p_brand_scope text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE
  v_scope text := upper(coalesce(p_brand_scope,'NEUTRAL'));
  v_pos text := coalesce(nullif(trim(coalesce(p_context->>'positioning','')),''),
                         nullif(trim(coalesce(p_context->>'product_title','')),''), 'Product');
  v_ctx_name text := nullif(trim(coalesce(p_context->>'brand_name','')),'');
  v_neutral_name text := initcap(split_part(v_pos,' ',1))||' Supply Co.';
  v_voice text := coalesce(nullif(trim(coalesce(p_context->>'brand_voice','')),''),'clear, practical, honest');
  v_neutral_tokens jsonb := jsonb_build_object('primary','#111827','accent','#2563eb','bg','#FFFFFF','text','#1F2937');
  v_strq_tokens jsonb := jsonb_build_object('primary','#0B2239','accent','#12B5A5','bg','#FFFFFF','text','#0B2239');
  v_name text; v_owner text; v_source text; v_strq boolean := false; v_tokens jsonb; v_note text;
BEGIN
  IF v_scope NOT IN ('MERCHANT','INTERNAL_STRATELOQ','NEUTRAL') THEN v_scope := 'NEUTRAL'; END IF;

  IF v_scope = 'INTERNAL_STRATELOQ' THEN
    -- Strateloq is itself the merchant here: the ONLY case its brand is customer-facing.
    v_name := 'Strateloq'; v_owner := 'STRATELOQ'; v_source := 'STRATELOQ_INTERNAL';
    v_strq := true; v_tokens := v_strq_tokens;
    v_note := 'Strateloq is the merchant for this storefront; Strateloq brand is legitimately customer-facing.';
  ELSIF v_scope = 'MERCHANT' AND v_ctx_name IS NOT NULL THEN
    v_name := v_ctx_name; v_owner := 'MERCHANT'; v_source := 'MERCHANT_BUSINESS_IDENTITY';
    -- No merchant brand palette is stored anywhere, so we never fabricate one:
    -- honest neutral tokens carry the merchant's real name + voice.
    v_tokens := coalesce(p_context->'brand_theme_tokens', v_neutral_tokens);
    v_note := 'Customer storefront uses the merchant''s own brand identity (name/voice); neutral palette until a merchant palette is provided.';
  ELSE
    v_name := coalesce(v_ctx_name, v_neutral_name); v_owner := 'NEUTRAL'; v_source := 'NEUTRAL_FALLBACK';
    v_tokens := v_neutral_tokens;
    v_note := 'No merchant brand identity resolved; neutral fallback (never Strateloq).';
  END IF;

  -- HARD SAFETY: never expose the Strateloq brand as a customer brand unless
  -- Strateloq genuinely IS the merchant (INTERNAL_STRATELOQ scope).
  IF v_scope <> 'INTERNAL_STRATELOQ' AND lower(coalesce(v_name,'')) LIKE '%strateloq%' THEN
    v_name := v_neutral_name; v_owner := 'NEUTRAL'; v_source := 'NEUTRAL_FALLBACK_STRATELOQ_SUPPRESSED';
    v_strq := false; v_tokens := v_neutral_tokens;
    v_note := 'Strateloq brand suppressed on a non-Strateloq merchant storefront (safety rule).';
  END IF;

  RETURN jsonb_build_object(
    'brand_scope', v_scope,
    'brand_owner', v_owner,
    'brand_name', v_name,
    'brand_voice', v_voice,
    'theme_tokens', v_tokens,
    'logo', coalesce(nullif(trim(coalesce(p_context->>'brand_logo','')),''),'TEXT_MARK_PLACEHOLDER'),
    'source', v_source,
    'strateloq_as_customer_brand', v_strq,
    'palette_fabricated', false,
    'note', v_note);
END; $function$;

COMMENT ON FUNCTION public.fn_resolve_merchant_theme(jsonb,text) IS
 'Deterministic merchant-branding -> theme-token resolver. customer=merchant brand, internal=Strateloq brand (only when Strateloq is the merchant), fallback=neutral. Hard rule: Strateloq brand never customer-facing unless INTERNAL_STRATELOQ. Never fabricates a merchant palette.';

-- ---------------------------------------------------------------------------
-- Gap 3: explicit, typed Conversion Strategy contract (pure).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_conversion_strategy(
  p_selection jsonb, p_decision jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE
  v_family text := coalesce(p_selection->>'recommended_template_family','PROBLEM_SOLUTION');
  v_angle text; v_aware text;
BEGIN
  v_angle := CASE v_family
    WHEN 'PROBLEM_SOLUTION'      THEN 'Lead with the buyer problem, resolve with the product.'
    WHEN 'VISUAL_DEMO'           THEN 'Show the product working; let demonstration carry the proof.'
    WHEN 'PREMIUM_LUXURY'        THEN 'Signal quality and craft; restrained, aspirational framing.'
    WHEN 'UGC_SOCIAL_COMMERCE'   THEN 'Social-proof-led — only when genuine reviews/UGC evidence exists.'
    WHEN 'FEATURE_TECHNOLOGY'    THEN 'Specification- and capability-led for considered buyers.'
    WHEN 'COMPARISON_EVIDENCE'   THEN 'Why-this-vs-alternatives, only on a genuine comparison basis.'
    WHEN 'LIFESTYLE_EMOTIONAL'   THEN 'Aspirational lifestyle context around the product.'
    WHEN 'DIRECT_RESPONSE_OFFER' THEN 'Clear offer and single next action, no fabricated urgency.'
    ELSE 'Problem-first, evidence-safe default.' END;
  v_aware := CASE v_family
    WHEN 'PROBLEM_SOLUTION'      THEN 'PROBLEM_AWARE'
    WHEN 'DIRECT_RESPONSE_OFFER' THEN 'PRODUCT_AWARE'
    WHEN 'COMPARISON_EVIDENCE'   THEN 'SOLUTION_AWARE'
    WHEN 'FEATURE_TECHNOLOGY'    THEN 'SOLUTION_AWARE'
    WHEN 'UGC_SOCIAL_COMMERCE'   THEN 'SOLUTION_AWARE'
    ELSE 'PROBLEM_UNAWARE_TO_SOLUTION_AWARE' END;
  RETURN jsonb_build_object(
    'primary_objective','TEST_PURCHASE_INTENT_AT_LANDED_ECONOMICS',
    'template_family', v_family,
    'angle', v_angle,
    'awareness_assumption', v_aware,
    'cta_model', coalesce(p_selection->'cta_structure', jsonb_build_object('primary','Add to cart')),
    'confidence', coalesce(p_selection->>'confidence','LOW'),
    'evidence_basis', coalesce(p_selection->'available_evidence','[]'::jsonb),
    'missing_evidence', coalesce(p_selection->'missing_evidence','[]'::jsonb),
    'economics_state', coalesce(p_decision->'economics'->>'economics_state','UNKNOWN'),
    'terminology_guard','PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN',
    'not_a_performance_claim', true);
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_conversion_strategy(jsonb,jsonb) IS
 'Explicit typed Conversion Strategy contract derived deterministically from the template selection. No performance claims; terminology guard = PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN.';

-- ---------------------------------------------------------------------------
-- Gap 2: founder-readable "Why this page?" explainability (pure over contract).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_why_this_page(p_contract jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE
  v_sel jsonb := coalesce(p_contract->'selection','{}'::jsonb);
  v_family text := coalesce(p_contract->>'template_family', v_sel->>'recommended_template_family','PROBLEM_SOLUTION');
  v_conf text := coalesce(v_sel->>'confidence','LOW');
  v_theme jsonb := coalesce(p_contract->'merchant_theme','{}'::jsonb);
  v_avail text; v_missing text; v_bullets jsonb := '[]'::jsonb;
BEGIN
  SELECT string_agg(x,', ') INTO v_avail
    FROM jsonb_array_elements_text(coalesce(v_sel->'available_evidence','[]'::jsonb)) x;
  SELECT string_agg(x,', ') INTO v_missing
    FROM jsonb_array_elements_text(coalesce(v_sel->'missing_evidence','[]'::jsonb)) x;

  v_bullets := v_bullets
    || to_jsonb('Template chosen: '||v_family||' — selected deterministically as the best fit for the evidence available, not because it "converts best" (there is no performance data yet).'::text)
    || to_jsonb('Confidence: '||v_conf||'. This is a pre-performance best-fit recommendation, not a proven winner.'::text)
    || to_jsonb('Evidence used: '||coalesce(v_avail,'none')||'.'::text)
    || to_jsonb('Evidence missing: '||coalesce(v_missing,'none')||' — sections that need it are hidden or shown as editable placeholders, never fabricated.'::text)
    || to_jsonb('Currency: shown in '||coalesce(p_contract->>'display_currency','the display currency')||', sourced from '||coalesce(p_contract->>'source_currency','the supplier currency')||' — the source currency is preserved, not silently converted.'::text)
    || to_jsonb('Product images: '||coalesce(p_contract->>'assets_state','UNKNOWN')||' — only rights-clear supplier/owned assets are used; reference-only competitor creatives are never used as storefront assets.'::text)
    || to_jsonb('Claim safety: '||CASE WHEN coalesce((p_contract->'claim_safety'->>'claim_scan_clean')::boolean,true)
          THEN 'clean — no reviews, ratings, guarantees, urgency, or discounts were fabricated.'
          ELSE 'flagged surfaces are held as editable placeholders and cannot be approved or published until resolved.' END::text)
    || to_jsonb('Brand: '||coalesce(v_theme->>'brand_name','neutral')||' ('||coalesce(v_theme->>'brand_owner','NEUTRAL')||') — the storefront shows the merchant''s brand; Strateloq''s brand is never shown as the customer brand unless Strateloq is the merchant.'::text);

  RETURN jsonb_build_object(
    'headline','Why this page was generated',
    'template_family', v_family,
    'confidence', v_conf,
    'bullets', v_bullets,
    'terminology_guard','PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN',
    'human_readable', true);
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_why_this_page(jsonb) IS
 'Founder-readable "Why this page?" explainability rendered from the runtime contract. Honest: best-fit pre-performance, evidence used/missing, currency, assets, claim safety, brand. No fake precision.';

-- ---------------------------------------------------------------------------
-- Wire Gap 1 into the claim-safe copy generator: prefer resolved brand theme
-- tokens / voice from context when present (the generator injects them), else
-- keep the existing neutral default. Purely additive read; still IMMUTABLE.
-- (Body is otherwise byte-identical to mig_231.)
-- ---------------------------------------------------------------------------
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
  v_voice text := coalesce(nullif(trim(coalesce(p_context->>'brand_voice','')),''),'clear, practical, honest');
  v_theme jsonb := coalesce(p_context->'brand_theme_tokens',
                     jsonb_build_object('primary','#111827','accent','#2563eb','bg','#ffffff','text','#1f2937'));
  v_ship text;
BEGIN
  v_ship := CASE WHEN v_min IS NOT NULL AND v_max IS NOT NULL
    THEN 'Estimated delivery: '||v_min||E'–'||v_max||' days ('||coalesce(v_method,'standard shipping')||'; carrier estimate, not guaranteed).'
    ELSE 'Delivery estimate confirmed at checkout.' END;
  RETURN jsonb_build_object(
   'model_version','pulse_product_page_v1','editable',true,'draft_first',true,'generated_by','deterministic_claim_safe_generator_v1',
   'brand', jsonb_build_object('name', v_brand,'logo','TEXT_MARK_PLACEHOLDER','voice', v_voice,'headline_style','benefit-led, factual',
      'theme_tokens', v_theme),
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

-- ---------------------------------------------------------------------------
-- Wire all three gaps into the runtime generator. Additive: resolves the brand
-- scope from tenant identity, enriches the copy context with the resolved brand,
-- and adds merchant_theme / brand_scope / conversion_strategy / explainability
-- to the LOCKED RUNTIME CONTRACT. No existing key is removed or renamed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_generate_storefront_runtime(
  p_user_id uuid,
  p_gate_inputs jsonb,
  p_selection_input jsonb,
  p_context jsonb,
  p_decision jsonb,
  p_destination text DEFAULT 'PULSE_HOSTED',
  p_source_kind text DEFAULT 'REAL',
  p_product_id uuid DEFAULT NULL,
  p_country_code text DEFAULT NULL,
  p_opportunity_decision_id uuid DEFAULT NULL,
  p_persist boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_gate jsonb; v_sel jsonb; v_assets jsonb; v_copy jsonb; v_scan jsonb;
  v_family text; v_market text := upper(coalesce(p_decision->>'target_market', p_country_code, ''));
  v_contract jsonb; v_draft jsonb; v_page_id uuid; v_marketing_text text; v_ad_match jsonb;
  v_dest text := upper(coalesce(p_destination,'PULSE_HOSTED'));
  v_gi_uid uuid; v_brand_scope text; v_theme jsonb; v_strategy jsonb; v_ctx jsonb;
BEGIN
  -- STEP 1 — HARD TEST eligibility gate (fail closed).
  v_gate := public.fn_storefront_test_eligibility(p_gate_inputs);
  IF NOT (v_gate->>'test_eligible')::boolean THEN
    IF p_source_kind = 'FIXTURE' THEN
      -- Isolated dev preview ONLY: never a real publishable product.
      v_sel := public.fn_select_conversion_template(p_selection_input);
      RETURN jsonb_build_object('status','REFUSED_PRODUCTION_DEV_PREVIEW_ONLY',
        'test_eligible', false, 'generation_state','DEV_PREVIEW_NON_PUBLISHABLE',
        'publication_state','BLOCKED_NON_PUBLISHABLE', 'is_fixture', true,
        'gate', v_gate, 'template_preview', v_sel->>'recommended_template_family',
        'note','Fixture/dev preview only; not eligible; nothing persisted as a real product.');
    END IF;
    RETURN jsonb_build_object('status','REFUSED','test_eligible', false,
      'generation_state','REFUSED','reason_codes', v_gate->'reason_codes',
      'decision_state', v_gate->>'decision_state', 'gate', v_gate,
      'note','Not TEST_ELIGIBLE; no storefront generated. Fail-closed.');
  END IF;

  -- STEP 2 — deterministic template selection.
  v_sel := public.fn_select_conversion_template(p_selection_input);
  v_family := v_sel->>'recommended_template_family';

  -- STEP 2b — resolve brand scope from tenant identity, then the merchant theme.
  v_gi_uid := public.fn_global_intelligence_uid();
  IF p_user_id IS NOT NULL AND v_gi_uid IS NOT NULL AND p_user_id = v_gi_uid THEN
    v_brand_scope := 'INTERNAL_STRATELOQ';
  ELSIF (p_context ? 'brand_name')
     OR (p_user_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.business_profiles bp WHERE bp.user_id = p_user_id))
     OR (p_user_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.member_business_dna d WHERE d.user_id = p_user_id)) THEN
    v_brand_scope := 'MERCHANT';
  ELSE
    v_brand_scope := 'NEUTRAL';
  END IF;
  v_theme := public.fn_resolve_merchant_theme(p_context, v_brand_scope);
  -- Enrich the copy context so the customer-facing copy uses the resolved brand.
  v_ctx := coalesce(p_context,'{}'::jsonb)
           || jsonb_build_object('brand_name', v_theme->>'brand_name',
                                 'brand_voice', v_theme->>'brand_voice',
                                 'brand_theme_tokens', v_theme->'theme_tokens');

  -- STEP 3 — evidence-safe base copy (reuse existing claim-safe generator).
  v_copy := public.fn_generate_page_copy(p_decision, v_ctx);

  -- STEP 4 — asset safety (reference-only can never resolve).
  v_assets := public.fn_resolve_storefront_assets(
                p_context->>'supplier', p_context->>'supplier_product_id', p_country_code);

  -- Defense-in-depth claim scan across PERSUASIVE copy surfaces only
  -- (hero / short_description / problem-solution / benefits). The trust section
  -- and announcement are honest disclaimers ("delivery times are estimates, not
  -- guarantees") — scanning them would false-positive on negated claim words.
  v_marketing_text := concat_ws(' ',
     v_copy->'hero'->>'headline', v_copy->'hero'->>'subheadline', v_copy->>'short_description',
     v_copy->'problem_solution'->>'problem', v_copy->'problem_solution'->>'solution',
     (SELECT string_agg(b,' ') FROM jsonb_array_elements_text(coalesce(v_copy->'benefits','[]'::jsonb)) b));
  v_scan := public.fn_ad_studio_claim_scan(v_marketing_text);

  -- Ad->page message match (Ad Studio addressability).
  v_ad_match := coalesce(p_selection_input->'ad_match', jsonb_build_object(
      'state','NO_AD_MATCH_YET',
      'addressable_by', jsonb_build_object('product_id', p_product_id, 'country_code', p_country_code, 'market', v_market),
      'offer_version','v1'));

  -- STEP 4b — explicit conversion strategy contract.
  v_strategy := public.fn_storefront_conversion_strategy(v_sel, p_decision);

  -- LOCKED RUNTIME CONTRACT
  v_contract := jsonb_build_object(
    'product_id', p_product_id,
    'country_code', p_country_code,
    'opportunity_decision_id', p_opportunity_decision_id,
    'template_family', v_family,
    'template_version', v_sel->>'template_version',
    'market', v_market,
    'destination', v_dest,
    'source_currency', coalesce(p_decision->'economics'->>'landed_cost_currency', p_context->>'source_currency'),
    'display_currency', p_context->>'display_currency',
    'economics_state', p_decision->'economics'->>'economics_state',
    'ad_match_ref', v_ad_match,
    'sections', v_sel->'sections',
    'hero_variant', v_sel->>'hero_variant',
    'cta_structure', v_sel->'cta_structure',
    'brand_scope', v_brand_scope,
    'merchant_theme', v_theme,
    'conversion_strategy', v_strategy,
    'claim_safety', (coalesce(v_copy->'claim_safety','{}'::jsonb)
                     || jsonb_build_object('runtime_claim_scan', v_scan,
                          'claim_scan_clean', (jsonb_array_length(v_scan)=0),
                          'unsafe_sections_editable_placeholder', (jsonb_array_length(v_scan) > 0))),
    'copy_provenance', v_copy->'copy_provenance',
    'supplier_asset_refs', v_assets,
    'assets_state', v_assets->>'state',
    'selection', v_sel,
    'generation_state', 'GENERATED',
    'review_state', 'DRAFT',
    'publication_state', 'UNPUBLISHED',
    'terminology_guard','BEST_FIT_PRE_PERFORMANCE_NOT_PROVEN');

  -- Founder-readable explainability (computed from the assembled contract).
  v_contract := v_contract || jsonb_build_object('explainability', public.fn_storefront_why_this_page(v_contract));

  IF NOT p_persist THEN
    RETURN jsonb_build_object('status','ok_preview','test_eligible',true,'persisted',false,
      'runtime_contract', v_contract, 'gate', v_gate);
  END IF;

  -- STEP 5 — persist. Reuse fn_create_pulse_store_draft (re-enforces TEST +
  -- creates page + project + Ad Studio handoff + conversion identity), then
  -- stamp the runtime-contract columns onto the created page.
  v_draft := public.fn_create_pulse_store_draft(p_user_id, p_decision, p_context, p_source_kind, p_product_id);
  IF coalesce((v_draft->>'created')::boolean,false) IS NOT TRUE THEN
    RETURN jsonb_build_object('status','REFUSED_AT_PERSIST','gate',v_gate,'draft',v_draft,
      'note','Eligibility passed but canonical draft creation refused (decision not TEST at persist).');
  END IF;
  v_page_id := (v_draft->>'product_page_id')::uuid;

  UPDATE public.commerce_product_pages SET
    country_code = p_country_code,
    opportunity_decision_id = p_opportunity_decision_id,
    template_family = v_family,
    template_version = v_sel->>'template_version',
    ad_match_ref = v_ad_match,
    supplier_asset_refs = v_assets,
    generation_state = 'GENERATED',
    review_state = 'DRAFT',
    publication_state = 'UNPUBLISHED',
    runtime_contract = v_contract,
    page_model = page_model
      || jsonb_build_object('template_family', v_family, 'template_version', v_sel->>'template_version',
           'sections', v_sel->'sections', 'hero_variant', v_sel->>'hero_variant',
           'assets_runtime', v_assets, 'ad_match_ref', v_ad_match,
           'merchant_theme', v_theme, 'conversion_strategy', v_strategy)
      || jsonb_build_object('assets', jsonb_build_object(
            'primary_image', v_assets->'primary_image'->>'source_url',
            'gallery', (SELECT coalesce(jsonb_agg(x->>'source_url'),'[]'::jsonb) FROM jsonb_array_elements(v_assets->'gallery') x),
            'state', CASE WHEN v_assets->>'state'='ASSETS_AVAILABLE' THEN 'SUPPLIER_ASSETS_RESOLVED' ELSE 'PRODUCT_ASSET_REQUIRED' END,
            'origin','SOURCE_SUPPLIER','note','rights-clear supplier images; no fabricated replacement')),
    updated_at = now()
  WHERE id = v_page_id;

  RETURN jsonb_build_object('status','ok','test_eligible',true,'persisted',true,
    'product_page_id', v_page_id, 'store_project_id', v_draft->>'store_project_id',
    'template_family', v_family, 'template_version', v_sel->>'template_version',
    'review_state','DRAFT','publication_state','UNPUBLISHED','generation_state','GENERATED',
    'assets_state', v_assets->>'state', 'claim_scan_clean', (jsonb_array_length(v_scan)=0),
    'runtime_contract', v_contract, 'ad_studio_handoff', v_draft->'ad_studio_handoff',
    'preview', v_draft->'preview', 'gate', v_gate);
END; $function$;

COMMENT ON FUNCTION public.fn_generate_storefront_runtime(uuid,jsonb,jsonb,jsonb,jsonb,text,text,uuid,text,uuid,boolean) IS
 'Runtime storefront generator. Fails closed at the hard TEST gate; deterministic selection; claim + asset safety; resolves merchant branding -> theme tokens (customer/internal/neutral, Strateloq-safe), an explicit conversion strategy, and founder-readable explainability into the locked runtime contract. FIXTURE source yields a non-publishable dev preview only.';

-- ---------------------------------------------------------------------------
-- Companion deterministic selftest for the three gap closures. Pure: it calls
-- the new functions and inspects a synthetic contract; it writes no rows and is
-- safe to run in production. Complements fn_storefront_runtime_selftest.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_branding_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0;
  v_t jsonb; v_s jsonb; v_w jsonb; v_c jsonb;
BEGIN
  -- 1. MERCHANT brand applied.
  v_t := public.fn_resolve_merchant_theme(jsonb_build_object('brand_name','Acme Trading Co','positioning','ergonomic desk mat'),'MERCHANT');
  IF v_t->>'brand_owner'='MERCHANT' AND v_t->>'brand_name'='Acme Trading Co'
     AND (v_t->>'strateloq_as_customer_brand')::boolean = false THEN
    v_pass:=v_pass+1; v:=v||jsonb_build_object('case','theme_merchant_brand_applied','pass',true);
  ELSE v_fail:=v_fail+1; v:=v||jsonb_build_object('case','theme_merchant_brand_applied','pass',false,'got',v_t); END IF;

  -- 2. INTERNAL_STRATELOQ -> Strateloq brand, legitimately customer-facing.
  v_t := public.fn_resolve_merchant_theme(jsonb_build_object('positioning','internal test'),'INTERNAL_STRATELOQ');
  IF v_t->>'brand_owner'='STRATELOQ' AND v_t->>'brand_name'='Strateloq'
     AND (v_t->>'strateloq_as_customer_brand')::boolean = true THEN
    v_pass:=v_pass+1; v:=v||jsonb_build_object('case','theme_internal_strateloq','pass',true);
  ELSE v_fail:=v_fail+1; v:=v||jsonb_build_object('case','theme_internal_strateloq','pass',false,'got',v_t); END IF;

  -- 3. NEUTRAL fallback (no brand) -> neutral, never Strateloq.
  v_t := public.fn_resolve_merchant_theme(jsonb_build_object('positioning','portable blender'),'NEUTRAL');
  IF v_t->>'brand_owner'='NEUTRAL' AND v_t->>'brand_name' LIKE '%Supply Co.'
     AND lower(v_t->>'brand_name') NOT LIKE '%strateloq%'
     AND (v_t->>'strateloq_as_customer_brand')::boolean = false THEN
    v_pass:=v_pass+1; v:=v||jsonb_build_object('case','theme_neutral_fallback','pass',true);
  ELSE v_fail:=v_fail+1; v:=v||jsonb_build_object('case','theme_neutral_fallback','pass',false,'got',v_t); END IF;

  -- 4. HARD SAFETY: a non-Strateloq tenant cannot surface the Strateloq brand.
  v_t := public.fn_resolve_merchant_theme(jsonb_build_object('brand_name','Strateloq','positioning','desk lamp'),'MERCHANT');
  IF lower(v_t->>'brand_name') NOT LIKE '%strateloq%'
     AND v_t->>'brand_owner'='NEUTRAL'
     AND (v_t->>'strateloq_as_customer_brand')::boolean = false THEN
    v_pass:=v_pass+1; v:=v||jsonb_build_object('case','theme_never_strateloq_as_customer','pass',true);
  ELSE v_fail:=v_fail+1; v:=v||jsonb_build_object('case','theme_never_strateloq_as_customer','pass',false,'got',v_t); END IF;

  -- 5. Palette never fabricated for a merchant with no stored colours.
  v_t := public.fn_resolve_merchant_theme(jsonb_build_object('brand_name','Nimbus Home','positioning','air purifier'),'MERCHANT');
  IF (v_t->>'palette_fabricated')::boolean = false
     AND v_t->'theme_tokens'->>'primary' = '#111827' THEN
    v_pass:=v_pass+1; v:=v||jsonb_build_object('case','theme_palette_not_fabricated','pass',true);
  ELSE v_fail:=v_fail+1; v:=v||jsonb_build_object('case','theme_palette_not_fabricated','pass',false,'got',v_t); END IF;

  -- 6. Conversion strategy present, typed, no performance claim.
  v_s := public.fn_storefront_conversion_strategy(
           jsonb_build_object('recommended_template_family','FEATURE_TECHNOLOGY','confidence','MEDIUM',
             'available_evidence', jsonb_build_array('has_specs','has_product_image'),
             'cta_structure', jsonb_build_object('primary','Add to cart')),
           jsonb_build_object('economics','{"economics_state":"POSITIVE"}'::jsonb));
  IF v_s->>'primary_objective'='TEST_PURCHASE_INTENT_AT_LANDED_ECONOMICS'
     AND v_s->>'template_family'='FEATURE_TECHNOLOGY'
     AND v_s->>'terminology_guard'='PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN'
     AND (v_s->>'not_a_performance_claim')::boolean = true THEN
    v_pass:=v_pass+1; v:=v||jsonb_build_object('case','conversion_strategy_present','pass',true);
  ELSE v_fail:=v_fail+1; v:=v||jsonb_build_object('case','conversion_strategy_present','pass',false,'got',v_s); END IF;

  -- 7. Strategy angle carries no "best converting"/"highest" performance language.
  IF lower(v_s->>'angle') NOT LIKE '%best converting%'
     AND lower(v_s->>'angle') NOT LIKE '%highest%'
     AND lower(v_s->>'angle') NOT LIKE '%guaranteed%' THEN
    v_pass:=v_pass+1; v:=v||jsonb_build_object('case','conversion_strategy_no_performance_claim','pass',true);
  ELSE v_fail:=v_fail+1; v:=v||jsonb_build_object('case','conversion_strategy_no_performance_claim','pass',false,'got',v_s->>'angle'); END IF;

  -- 8. "Why this page?" is human-readable, honest, currency-preserving.
  v_c := jsonb_build_object(
           'template_family','PROBLEM_SOLUTION','display_currency','GBP','source_currency','CNY',
           'assets_state','IMAGE_UNAVAILABLE',
           'claim_safety', jsonb_build_object('claim_scan_clean',true),
           'merchant_theme', jsonb_build_object('brand_name','Acme Trading Co','brand_owner','MERCHANT'),
           'selection', jsonb_build_object('confidence','LOW',
              'available_evidence', jsonb_build_array('buyer_pain'),
              'missing_evidence', jsonb_build_array('has_reviews_ugc','has_before_after')));
  v_w := public.fn_storefront_why_this_page(v_c);
  IF (v_w->>'human_readable')::boolean = true
     AND jsonb_array_length(v_w->'bullets') >= 6
     AND v_w->>'terminology_guard'='PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN'
     AND (v_w->'bullets')::text LIKE '%GBP%'
     AND (v_w->'bullets')::text LIKE '%CNY%'
     AND (v_w->'bullets')::text LIKE '%source currency is preserved%' THEN
    v_pass:=v_pass+1; v:=v||jsonb_build_object('case','why_this_page_human_readable','pass',true);
  ELSE v_fail:=v_fail+1; v:=v||jsonb_build_object('case','why_this_page_human_readable','pass',false,'got',v_w); END IF;

  RETURN jsonb_build_object(
    'suite','fn_storefront_branding_selftest',
    'total', v_pass+v_fail, 'passed', v_pass, 'failed', v_fail,
    'all_pass', (v_fail=0), 'results', v);
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_branding_selftest() IS
 'Deterministic selftest for STRATELOQ-ECOM-P8-002 gap closures: merchant theme resolution (customer/internal/neutral + Strateloq safety + no fabricated palette), explicit conversion strategy, and human-readable explainability. Writes nothing.';

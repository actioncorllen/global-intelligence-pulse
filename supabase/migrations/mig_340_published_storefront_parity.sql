-- mig_340: Published storefront parity — single canonical page contract.
--
-- Defect: the Builder PREVIEW rendered the live claim-safe strategy
-- (fn_product_page_strategy v3, "evidence_gated_claim_safe_v1"), but the PUBLISHED
-- public page (fn_public_storefront_render → storefront edge fn) rendered a STALE,
-- separately-generated page_model ("deterministic_claim_safe_generator_v1") that still
-- carried suppressed/unsupported strings ("Transparent estimated delivery",
-- "New condition, fulfilled from the supplier warehouse", delivery/condition FAQ,
-- empty product-noun placeholders, "Draft store (not published)"). Two independently
-- generated representations = preview != published.
--
-- Fix (reuse the existing strategy; no second architecture):
--  1. fn_storefront_publish captures an IMMUTABLE published snapshot
--     (runtime_contract.published_spec + published_revision_id) built from the SAME
--     canonical source the preview uses (fn_product_page_strategy v3) plus the
--     rights-cleared asset (Product Asset Lock), merchant selling price and market.
--  2. fn_public_storefront_render renders ONLY that immutable snapshot; the stale
--     page_model and the hardcoded product_provenance condition/fulfilment are gone.
--     A legacy page published before this fix (no snapshot) renders a minimal
--     claim-safe page (no stale strings) and reports needs_republish=true.
--
-- Preserves mig_339 (opportunity economics is NOT a page-publish gate). Nothing is
-- auto-published or auto-republished here.

-- 1) PUBLISH: capture the canonical immutable snapshot at publish time.
CREATE OR REPLACE FUNCTION public.fn_storefront_publish(p_page_id uuid, p_gate_inputs jsonb DEFAULT '{}'::jsonb, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  p public.commerce_product_pages%rowtype;
  v_actor uuid := coalesce(auth.uid(), p_actor);
  v_gate jsonb; v_assets jsonb; v_clean boolean; v_slug text; v_url text;
  v_base text := 'https://nxaunmyihhjixxxljcqt.supabase.co';
  v_derived boolean := false; v_pimg jsonb;
  v_page_reasons jsonb;
  v_strategy jsonb; v_spec jsonb; v_rev text; v_title text; v_benefits jsonb;
BEGIN
  SELECT * INTO p FROM public.commerce_product_pages WHERE id = p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PAGE_NOT_FOUND'); END IF;
  IF v_actor IS NOT NULL AND p.user_id IS NOT NULL AND v_actor <> p.user_id THEN
    RETURN jsonb_build_object('status','DENIED_CROSS_TENANT');
  END IF;
  IF upper(coalesce(p.review_state,'')) <> 'APPROVED' THEN
    RETURN jsonb_build_object('status','NOT_APPROVED','review_state',p.review_state,
      'note','publish requires the page to be APPROVED first (DRAFT -> IN_REVIEW -> APPROVED)');
  END IF;

  IF p_gate_inputs IS NOT NULL AND (p_gate_inputs ? 'recommendation') THEN
    v_gate := public.fn_storefront_test_eligibility(p_gate_inputs);
    SELECT coalesce(jsonb_agg(rc), '[]'::jsonb) INTO v_page_reasons
    FROM jsonb_array_elements_text(coalesce(v_gate->'reason_codes','[]'::jsonb)) rc
    WHERE upper(rc) NOT IN ('REJECT_ECONOMICS_UNVIABLE','REJECT_ECONOMICS_UNKNOWN',
                            'REJECT_ECONOMICS_NOT_VIABLE','ECONOMICS_THIN','OK_TEST_ELIGIBLE');
    IF jsonb_array_length(v_page_reasons) > 0 THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY','reason_codes',v_page_reasons,'gate',v_gate,
        'note','page-publish blocked by non-economics eligibility reasons; opportunity economics is not a page-publish gate');
    END IF;
  ELSE
    v_derived := true;
    IF coalesce(p.runtime_contract->>'generation_state','') <> 'GENERATED' THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY',
        'reason_codes', jsonb_build_array('REJECT_NOT_GENERATED'),
        'note','server-derived: page was not produced by the gated storefront generator');
    END IF;
  END IF;

  v_clean := coalesce((p.runtime_contract->'claim_safety'->>'claim_scan_clean')::boolean, false);
  IF NOT v_clean THEN
    RETURN jsonb_build_object('status','BLOCKED_CLAIM_SAFETY','note','claim scan not clean; resolve before publish');
  END IF;
  v_assets := public.fn_resolve_storefront_assets(
      coalesce(p.runtime_contract->'supplier_asset_refs'->>'fulfilment_supplier','cjdropshipping'),
      p.runtime_contract->'supplier_asset_refs'->>'supplier_product_id', p.country_code);
  IF (v_assets->>'rejected_count')::int > 0 AND (v_assets->>'usable_count')::int = 0 THEN
    RETURN jsonb_build_object('status','BLOCKED_ASSET_SAFETY','assets',v_assets,
      'note','no usable rights-clear supplier assets; only rejected/reference-only present');
  END IF;
  IF upper(coalesce(p.destination,'')) NOT IN ('PULSE_STORE') THEN
    RETURN jsonb_build_object('status','BLOCKED_DESTINATION','destination',p.destination,
      'note','this runtime publishes PULSE_STORE (Pulse-hosted) only');
  END IF;

  IF p.product_id IS NOT NULL THEN
    v_pimg := public.fn_resolve_product_image(p.product_id, p.country_code);
    IF coalesce(v_pimg->>'image_state','') <> 'AVAILABLE' OR coalesce(v_pimg->>'image_url','') = '' THEN
      RETURN jsonb_build_object('status','BLOCKED_PRODUCT_IMAGE_UNAVAILABLE',
        'image_state', coalesce(v_pimg->>'image_state','NONE'), 'product_id', p.product_id,
        'note','a customer-facing storefront requires a trustworthy canonical product image; none available for this product (never fabricated)');
    END IF;
  END IF;

  v_slug := 'p'||left(replace(p_page_id::text,'-',''),12);
  v_url := v_base||'/functions/v1/storefront/'||v_slug;

  -- CANONICAL IMMUTABLE SNAPSHOT — same source as the merchant preview
  -- (fn_product_page_strategy v3). Runs as the authenticated owner at publish time.
  SELECT title INTO v_title FROM public.commerce_products WHERE id = p.product_id;
  v_title := coalesce(p.page_model->>'product_title', v_title, 'Product');
  v_strategy := public.fn_product_page_strategy(p.product_id, p.country_code);
  v_benefits := (SELECT coalesce(jsonb_agg(b->>'text'),'[]'::jsonb)
                 FROM jsonb_array_elements(coalesce(v_strategy->'key_benefits','[]'::jsonb)) b);

  v_spec := jsonb_build_object(
    'slug', v_slug,
    'template_family', coalesce(v_strategy->>'template_family', p.template_family),
    'template_version', p.template_version,
    'market', p.market,
    'country_code', p.country_code,
    'market_label', coalesce(v_strategy->>'market_label', p.market),
    'currency', jsonb_build_object('display', p.display_currency, 'source', p.source_currency),
    'offer', jsonb_build_object('price', p.selling_price, 'currency', p.display_currency,
               'note','no fabricated discount or crossed-out price'),
    'hero', jsonb_build_object('variant', v_strategy->>'hero_variant',
               'headline', coalesce(v_strategy->'page_copy'->>'headline', v_title),
               'subheadline', v_strategy->'page_copy'->>'subheadline'),
    'copy', jsonb_build_object(
       'product_title', v_title,
       'short_description', v_strategy->'page_copy'->>'short_description',
       'benefits', v_benefits,
       'how_it_works', coalesce(v_strategy->'page_copy'->'how_it_works','[]'::jsonb),
       'problem_solution', jsonb_build_object(
           'problem', v_strategy->'page_copy'->>'problem',
           'solution', v_strategy->'page_copy'->>'solution'),
       'details', coalesce(v_strategy->'page_copy'->'details','[]'::jsonb),
       'shipping', jsonb_build_object('copy', v_strategy->'page_copy'->>'shipping_note'),
       'trust', jsonb_build_object('copy', v_strategy->'page_copy'->>'trust_note',
           'disclaimers', jsonb_build_array(
             'No reviews, ratings, or testimonials are shown (none verified).')),
       'faq', coalesce(v_strategy->'page_copy'->'faq','[]'::jsonb),
       'seo', jsonb_build_object('title', v_title,
           'meta_description', v_strategy->'page_copy'->>'short_description')),
    'assets', jsonb_build_object(
       'primary_image', v_assets->'primary_image'->>'source_url',
       'gallery', (SELECT coalesce(jsonb_agg(g->>'source_url'),'[]'::jsonb)
                   FROM jsonb_array_elements(coalesce(v_assets->'gallery','[]'::jsonb)) g),
       'state', CASE WHEN v_assets->>'state'='ASSETS_AVAILABLE' THEN 'SUPPLIER_ASSETS' ELSE 'IMAGE_UNAVAILABLE' END,
       'provenance_class', 'SOURCE_SUPPLIER_RIGHTS_CLEARED'),
    'video', jsonb_build_object('state', coalesce(v_assets->>'video_state','VIDEO_ASSET_NOT_AVAILABLE'), 'url', NULL),
    'claim_safety', coalesce(v_strategy->'claim_safety','{}'::jsonb)
       || jsonb_build_object('claim_scan_clean', v_clean),
    'checkout', jsonb_build_object('state','CHECKOUT_NOT_CONFIGURED','functional', false,
       'dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER'),
    'publication', jsonb_build_object('state','PUBLISHED','noindex', true),
    'strategy_state', v_strategy->>'strategy_state',
    'spec_source','fn_product_page_strategy_v3');
  v_rev := md5(v_spec::text);
  v_spec := v_spec || jsonb_build_object('published_revision_id', v_rev);

  UPDATE public.commerce_product_pages SET
    review_state = 'PUBLISHED', publication_state = 'PUBLISHED', published_url = v_url,
    runtime_contract = coalesce(runtime_contract,'{}'::jsonb) || jsonb_build_object(
      'review_state','PUBLISHED','publication_state','PUBLISHED',
      'published_spec', v_spec,
      'published_revision_id', v_rev,
      'publication', jsonb_build_object(
        'destination','PULSE_HOSTED','slug',v_slug,'destination_url',v_url,'noindex',true,
        'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT',
        'renderer','fn_public_storefront_render',
        'published_revision_id', v_rev,
        'eligibility_source', CASE WHEN v_derived THEN 'SERVER_DERIVED_PERSISTED' ELSE 'EXPLICIT_GATE' END,
        'published_at', now(),
        'gates', jsonb_build_object('test_eligible',true,'claim_scan_clean',true,
           'assets_state',v_assets->>'state','destination','PULSE_STORE',
           'product_image_state', CASE WHEN p.product_id IS NOT NULL THEN coalesce(v_pimg->>'image_state','NONE') ELSE 'N/A' END),
        'checkout', jsonb_build_object('state','CHECKOUT_NOT_CONFIGURED',
           'dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER'))),
    supplier_asset_refs = v_assets, updated_at = now()
  WHERE id = p_page_id;

  UPDATE public.commerce_store_projects SET
    project_state = 'PUBLISHED', public_route = v_slug,
    settings = coalesce(settings,'{}'::jsonb) || jsonb_build_object(
      'publication_state','PUBLISHED','destination_url',v_url,'noindex',true,
      'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT'),
    updated_at = now()
  WHERE product_page_id = p_page_id;

  RETURN jsonb_build_object('status','ok','publication_state','PUBLISHED',
    'page_id',p_page_id,'slug',v_slug,'destination_url',v_url,
    'published_revision_id', v_rev,
    'eligibility_source', CASE WHEN v_derived THEN 'SERVER_DERIVED_PERSISTED' ELSE 'EXPLICIT_GATE' END,
    'checkout_state','CHECKOUT_NOT_CONFIGURED','checkout_dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER',
    'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT',
    'renderer','fn_public_storefront_render',
    'gates', jsonb_build_object('test_eligible',true,'claim_scan_clean',true,
       'assets_state',v_assets->>'state','destination','PULSE_STORE',
       'product_image_state', CASE WHEN p.product_id IS NOT NULL THEN coalesce(v_pimg->>'image_state','NONE') ELSE 'N/A' END),
    'note','internal publication runtime complete; canonical published snapshot captured; anonymous public HTTP endpoint deploy is founder-gated');
END; $function$;

-- 2) PUBLIC RENDER: serve the immutable canonical snapshot only. No stale page_model,
--    no hardcoded condition/fulfilment provenance. Legacy pages (no snapshot) render a
--    minimal claim-safe page and report needs_republish.
CREATE OR REPLACE FUNCTION public.fn_public_storefront_render(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  p public.commerce_product_pages%rowtype;
  sp public.commerce_store_projects%rowtype;
  pm jsonb; rc jsonb; v_assets jsonb; v_title text; v_spec jsonb;
BEGIN
  SELECT * INTO sp FROM public.commerce_store_projects WHERE (public_route = p_slug OR slug = p_slug) LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  SELECT * INTO p FROM public.commerce_product_pages WHERE id = sp.product_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  IF coalesce(p.publication_state,'') <> 'PUBLISHED' THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;

  rc := coalesce(p.runtime_contract,'{}'::jsonb);

  -- Canonical path: immutable snapshot captured at publish time (parity with preview).
  IF rc ? 'published_spec' AND jsonb_typeof(rc->'published_spec') = 'object' THEN
    v_spec := rc->'published_spec';
    -- Never leak internal-only fields to the public contract.
    v_spec := v_spec - 'strategy_state' - 'spec_source';
    RETURN jsonb_build_object('status','OK','storefront', v_spec, 'render_mode','CANONICAL_PUBLISHED_SNAPSHOT');
  END IF;

  -- Legacy publish (no snapshot): minimal claim-safe render. Do NOT resurrect stale
  -- page_model copy (no benefits/FAQ/trust text). Full canonical content requires the
  -- merchant to republish through the corrected publish path.
  pm := coalesce(p.page_model,'{}'::jsonb);
  v_assets := rc->'supplier_asset_refs';
  SELECT title INTO v_title FROM public.commerce_products WHERE id = p.product_id;
  v_title := coalesce(nullif(pm->>'product_title',''), nullif(v_title,''), 'Product');
  RETURN jsonb_build_object('status','OK','render_mode','LEGACY_MINIMAL_NEEDS_REPUBLISH',
    'storefront', jsonb_build_object(
      'slug', coalesce(sp.public_route, sp.slug),
      'template_family', p.template_family, 'template_version', p.template_version,
      'market', p.market, 'country_code', p.country_code, 'market_label', p.market,
      'currency', jsonb_build_object('display', p.display_currency, 'source', p.source_currency),
      'offer', jsonb_build_object('price', p.selling_price, 'currency', p.display_currency,
                 'note','no fabricated discount or crossed-out price'),
      'hero', jsonb_build_object('variant', rc->>'hero_variant', 'headline', v_title, 'subheadline', NULL),
      'copy', jsonb_build_object(
         'product_title', v_title, 'short_description', NULL,
         'benefits', '[]'::jsonb, 'how_it_works', '[]'::jsonb, 'faq', '[]'::jsonb,
         'problem_solution', jsonb_build_object('problem', NULL, 'solution', NULL),
         'details', '[]'::jsonb,
         'shipping', jsonb_build_object('copy', NULL),
         'trust', jsonb_build_object('copy', NULL,
             'disclaimers', jsonb_build_array('No reviews, ratings, or testimonials are shown (none verified).')),
         'seo', jsonb_build_object('title', v_title, 'meta_description', NULL)),
      'assets', jsonb_build_object(
         'primary_image', v_assets->'primary_image'->>'source_url',
         'gallery', (SELECT coalesce(jsonb_agg(g->>'source_url'),'[]'::jsonb)
                     FROM jsonb_array_elements(coalesce(v_assets->'gallery','[]'::jsonb)) g),
         'state', CASE WHEN v_assets->>'state'='ASSETS_AVAILABLE' THEN 'SUPPLIER_ASSETS' ELSE 'IMAGE_UNAVAILABLE' END,
         'provenance_class', 'SOURCE_SUPPLIER_RIGHTS_CLEARED'),
      'video', jsonb_build_object('state', coalesce(v_assets->>'video_state','VIDEO_ASSET_NOT_AVAILABLE'), 'url', NULL),
      'claim_safety', jsonb_build_object(
         'no_reviews_fabricated', true, 'no_fake_discount', true, 'no_guaranteed_delivery', true,
         'no_urgency_scarcity', true, 'no_delivery_time_claimed', true, 'no_condition_claimed', true,
         'claim_scan_clean', (rc->'claim_safety'->>'claim_scan_clean')::boolean),
      'checkout', jsonb_build_object('state','CHECKOUT_NOT_CONFIGURED','functional', false,
         'dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER'),
      'needs_republish', true,
      'publication', jsonb_build_object('state','PUBLISHED','noindex', true)));
END; $function$;

COMMENT ON FUNCTION public.fn_public_storefront_render(text) IS
  'Public read-only storefront. Serves the immutable canonical published_spec (parity with merchant preview). Legacy pages without a snapshot render minimal claim-safe + needs_republish. mig_340.';

-- 3) SELFTEST — proves publish captures a claim-safe canonical snapshot equal to the
--    approved strategy, and the public renderer serves it without stale/legacy strings.
--    Write-path runs in a rolled-back subtransaction; nothing is published.
CREATE OR REPLACE FUNCTION public.fn_storefront_public_parity_selftest(p_page_id uuid, p_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_pass int := 0; v_fail int := 0; v_checks jsonb := '[]'::jsonb;
  v_pub jsonb; v_render jsonb; v_sf jsonb; v_strategy jsonb;
  v_product uuid; v_market text; v_img text; v_exp_title text;
  v_blob text; v_pre_snapshot boolean; v_post_snapshot boolean; v_supplier text; v_supplier_pid text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role','authenticated')::text, true);
  SELECT product_id, country_code,
         coalesce(runtime_contract->'supplier_asset_refs'->>'fulfilment_supplier','cjdropshipping'),
         runtime_contract->'supplier_asset_refs'->>'supplier_product_id',
         (runtime_contract ? 'published_spec')
    INTO v_product, v_market, v_supplier, v_supplier_pid, v_pre_snapshot
    FROM public.commerce_product_pages WHERE id = p_page_id;
  v_strategy := public.fn_product_page_strategy(v_product, v_market);
  -- canonical storefront image = rights-cleared supplier assets primary (Product Asset Lock)
  v_img := public.fn_resolve_storefront_assets(v_supplier, v_supplier_pid, v_market)->'primary_image'->>'source_url';
  SELECT coalesce(nullif(cpp.page_model->>'product_title',''), cp.title, 'Product')
    INTO v_exp_title
    FROM public.commerce_product_pages cpp
    LEFT JOIN public.commerce_products cp ON cp.id = cpp.product_id
    WHERE cpp.id = p_page_id;

  BEGIN
    UPDATE public.commerce_product_pages
       SET review_state='APPROVED',
           runtime_contract = coalesce(runtime_contract,'{}'::jsonb) || jsonb_build_object('economics_state','UNKNOWN')
     WHERE id = p_page_id;
    v_pub := public.fn_storefront_publish(p_page_id, '{}'::jsonb, p_uid);
    -- read the public render WITHIN the same subtransaction (snapshot now present)
    v_render := public.fn_public_storefront_render(v_pub->>'slug');
    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN
      v_pub := jsonb_build_object('status','SELFTEST_ERR','err',SQLERRM);
    END IF;
  END;
  v_sf := v_render->'storefront';
  v_blob := coalesce(v_sf::text,'');

  -- A: publish ok + snapshot captured
  IF coalesce(v_pub->>'status','')='ok' AND (v_pub ? 'published_revision_id') THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','publish_ok_with_revision','ok',
     coalesce(v_pub->>'status','')='ok' AND (v_pub ? 'published_revision_id'),'observed',v_pub->>'status');

  -- B: render mode canonical
  IF v_render->>'render_mode'='CANONICAL_PUBLISHED_SNAPSHOT' THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','render_mode_canonical','ok',
     v_render->>'render_mode'='CANONICAL_PUBLISHED_SNAPSHOT','observed',v_render->>'render_mode');

  -- C: published identity == approved product identity (canonical product title)
  IF coalesce(v_sf->'copy'->>'product_title','') = coalesce(v_exp_title,'') THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','identity_matches_approved','ok',
     coalesce(v_sf->'copy'->>'product_title','')=coalesce(v_exp_title,''),
     'observed', v_sf->'copy'->>'product_title');

  -- D: published canonical image == rights-cleared supplier assets primary (Product Asset Lock)
  IF coalesce(v_sf->'assets'->>'primary_image','') = coalesce(v_img,'X')
     AND v_sf->'assets'->>'provenance_class' = 'SOURCE_SUPPLIER_RIGHTS_CLEARED' THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','image_matches_approved','ok',
     coalesce(v_sf->'assets'->>'primary_image','')=coalesce(v_img,'X')
     AND v_sf->'assets'->>'provenance_class'='SOURCE_SUPPLIER_RIGHTS_CLEARED','observed',v_sf->'assets'->>'primary_image');

  -- E: published market == approved market
  IF coalesce(v_sf->>'market','') = coalesce(v_market,'') THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','market_matches','ok', coalesce(v_sf->>'market','')=coalesce(v_market,''),'observed',v_sf->>'market');

  -- F: NO stale/unsupported legacy strings anywhere in the public contract
  IF v_blob !~* 'transparent estimated delivery'
     AND v_blob !~* 'fulfilled from the supplier warehouse'
     AND v_blob !~* 'new condition'
     AND v_blob !~* 'draft store'
     AND v_blob !~* 'delivery estimate confirmed at checkout'
  THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','no_stale_legacy_strings','ok',
     v_blob !~* 'transparent estimated delivery' AND v_blob !~* 'fulfilled from the supplier warehouse'
     AND v_blob !~* 'new condition' AND v_blob !~* 'draft store'
     AND v_blob !~* 'delivery estimate confirmed at checkout');

  -- G: no workspace-only internals / debug leaked publicly
  IF v_blob !~* 'why this page' AND v_blob !~* 'fixture' AND v_blob !~* 'demo'
     AND v_blob !~* 'strategy_state' AND v_blob !~* 'economics_state' AND v_blob !~* 'opportunity'
  THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','no_internal_leak','ok',
     v_blob !~* 'why this page' AND v_blob !~* 'fixture' AND v_blob !~* 'demo'
     AND v_blob !~* 'strategy_state' AND v_blob !~* 'economics_state' AND v_blob !~* 'opportunity');

  -- H: checkout disabled
  IF v_sf->'checkout'->>'state'='CHECKOUT_NOT_CONFIGURED' AND (v_sf->'checkout'->>'functional')::boolean IS FALSE THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','checkout_disabled','ok',
     v_sf->'checkout'->>'state'='CHECKOUT_NOT_CONFIGURED','observed',v_sf->'checkout'->>'state');

  -- I: benefits parity (published benefits == strategy key_benefits text)
  DECLARE v_exp jsonb; BEGIN
    v_exp := (SELECT coalesce(jsonb_agg(b->>'text'),'[]'::jsonb) FROM jsonb_array_elements(coalesce(v_strategy->'key_benefits','[]'::jsonb)) b);
    IF coalesce(v_sf->'copy'->'benefits','[]'::jsonb) = v_exp THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
    v_checks := v_checks || jsonb_build_object('check','benefits_parity','ok', coalesce(v_sf->'copy'->'benefits','[]'::jsonb)=v_exp,'observed',v_sf->'copy'->'benefits');
  END;

  -- J: the test persisted nothing (write-path rolled back) — snapshot presence is unchanged
  --    from its pre-test value, proving fn_storefront_publish did not persist during the test.
  SELECT (runtime_contract ? 'published_spec') INTO v_post_snapshot FROM public.commerce_product_pages WHERE id = p_page_id;
  IF v_post_snapshot IS NOT DISTINCT FROM v_pre_snapshot THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','test_persisted_nothing','ok',
     v_post_snapshot IS NOT DISTINCT FROM v_pre_snapshot,
     'observed', jsonb_build_object('pre_snapshot',v_pre_snapshot,'post_snapshot',v_post_snapshot));

  RETURN jsonb_build_object('suite','fn_storefront_public_parity_selftest',
    'pass',v_pass,'fail',v_fail,'total',v_pass+v_fail,'checks',v_checks,'page_id',p_page_id);
END; $function$;

-- 4) Amend mig_339 selftest: the "nothing published" check compared publication_state to
--    'PUBLISHED', which is invalid once the merchant has legitimately published the page.
--    Replace it with an idempotency invariant: the rolled-back write-path test leaves
--    publication_state exactly as it was before the test (it persists nothing).
CREATE OR REPLACE FUNCTION public.fn_page_publish_economics_selftest(p_page_id uuid, p_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_pass int := 0; v_fail int := 0; v_checks jsonb := '[]'::jsonb;
  v_ctx jsonb; v_row jsonb; v_blockers jsonb; v_matrix jsonb;
  v_pub jsonb; v_pub_clean jsonb; v_pre_state text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role','authenticated')::text, true);
  SELECT publication_state INTO v_pre_state FROM public.commerce_product_pages WHERE id = p_page_id;

  v_ctx := public.fn_storefront_publish_context(p_page_id);
  v_row := v_ctx->'storefronts'->0;
  v_blockers := coalesce(v_row->'publish_blockers','[]'::jsonb);
  v_matrix := coalesce(v_row->'page_publish_readiness','[]'::jsonb);

  IF NOT (v_blockers @> '["ECONOMICS_NOT_VIABLE"]'::jsonb) THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','no_economics_blocker','ok', NOT (v_blockers @> '["ECONOMICS_NOT_VIABLE"]'::jsonb),'observed',v_blockers);

  DECLARE v_ne int; BEGIN
    SELECT count(*) INTO v_ne FROM jsonb_array_elements(v_matrix) e
     WHERE e->>'dimension' IN ('CAC_EVIDENCE','MARGIN_TARGET','ESTIMATED_PROFIT_THRESHOLD','OPPORTUNITY_ECONOMICS_CONFIDENCE')
       AND e->>'requirement' = 'NOT_REQUIRED_FOR_PAGE_PUBLISH';
    IF v_ne = 4 THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
    v_checks := v_checks || jsonb_build_object('check','economics_dims_not_required','ok', v_ne=4,'observed',v_ne);
  END;

  DECLARE v_pr int; BEGIN
    SELECT count(*) INTO v_pr FROM jsonb_array_elements(v_matrix) e
     WHERE e->>'contract'='PAGE_PUBLISH' AND e->>'requirement'='REQUIRED';
    IF v_pr = 5 THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
    v_checks := v_checks || jsonb_build_object('check','five_page_publish_dims_required','ok', v_pr=5,'observed',v_pr);
  END;

  BEGIN
    UPDATE public.commerce_product_pages
       SET review_state='APPROVED',
           runtime_contract = coalesce(runtime_contract,'{}'::jsonb) || jsonb_build_object('economics_state','UNKNOWN')
     WHERE id = p_page_id;
    v_pub := public.fn_storefront_publish(p_page_id, '{}'::jsonb, p_uid);
    RAISE EXCEPTION 'SELFTEST_ROLLBACK_C4';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK_C4' THEN v_pub := jsonb_build_object('status','SELFTEST_ERR','err',SQLERRM); END IF;
  END;
  IF coalesce(v_pub->>'status','') = 'ok' THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','publishes_with_economics_unknown','ok', coalesce(v_pub->>'status','')='ok','observed',v_pub->>'status');

  BEGIN
    UPDATE public.commerce_product_pages
       SET review_state='APPROVED',
           runtime_contract = jsonb_set(coalesce(runtime_contract,'{}'::jsonb),
             '{claim_safety,claim_scan_clean}', 'false'::jsonb, true)
     WHERE id = p_page_id;
    v_pub_clean := public.fn_storefront_publish(p_page_id, '{}'::jsonb, p_uid);
    RAISE EXCEPTION 'SELFTEST_ROLLBACK_C5';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'SELFTEST_ROLLBACK_C5' THEN v_pub_clean := jsonb_build_object('status','SELFTEST_ERR','err',SQLERRM); END IF;
  END;
  IF coalesce(v_pub_clean->>'status','') = 'BLOCKED_CLAIM_SAFETY' THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
  v_checks := v_checks || jsonb_build_object('check','claim_safety_still_blocks','ok', coalesce(v_pub_clean->>'status','')='BLOCKED_CLAIM_SAFETY','observed',v_pub_clean->>'status');

  DECLARE v_draft jsonb; BEGIN
    BEGIN
      UPDATE public.commerce_product_pages SET review_state='DRAFT' WHERE id = p_page_id;
      v_draft := public.fn_storefront_publish(p_page_id, '{}'::jsonb, p_uid);
      RAISE EXCEPTION 'SELFTEST_ROLLBACK_C6';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'SELFTEST_ROLLBACK_C6' THEN v_draft := jsonb_build_object('status','SELFTEST_ERR','err',SQLERRM); END IF;
    END;
    IF coalesce(v_draft->>'status','')='NOT_APPROVED' THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
    v_checks := v_checks || jsonb_build_object('check','review_approval_still_required','ok', coalesce(v_draft->>'status','')='NOT_APPROVED','observed',v_draft->>'status');
  END;

  -- idempotency: the rolled-back test leaves publication_state exactly as before.
  DECLARE v_now text; BEGIN
    SELECT publication_state INTO v_now FROM public.commerce_product_pages WHERE id = p_page_id;
    IF coalesce(v_now,'') IS NOT DISTINCT FROM coalesce(v_pre_state,'') THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;
    v_checks := v_checks || jsonb_build_object('check','test_persisted_nothing','ok',
       coalesce(v_now,'') IS NOT DISTINCT FROM coalesce(v_pre_state,''),
       'observed', jsonb_build_object('pre',v_pre_state,'post',v_now));
  END;

  RETURN jsonb_build_object('suite','fn_page_publish_economics_selftest',
    'pass',v_pass,'fail',v_fail,'total',v_pass+v_fail,'checks',v_checks,'page_id',p_page_id);
END; $function$;

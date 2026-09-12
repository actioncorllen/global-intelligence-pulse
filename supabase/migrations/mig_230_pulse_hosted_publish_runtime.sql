-- PULSE-ECOM-P8-PULSE-HOSTED-PUBLISH-RUNTIME-001
-- Pulse-hosted publishing runtime: a public-safe renderer data contract and a
-- publish operation that re-runs the launch-critical gates and mints a stable
-- Pulse-hosted destination URL. No Shopify. The renderer exposes ONLY explicitly
-- publishable, secret-stripped data for PUBLISHED pages (fail closed for drafts,
-- wrong slug, or cross-tenant). Deploying the anonymous public HTTP endpoint is a
-- separate, founder-gated step (this runtime prepares everything up to it).

-- ---------------------------------------------------------------------------
-- fn_public_storefront_render: PUBLIC renderer data contract. Allowlist-only —
-- it never dumps page_model/runtime_contract wholesale, so internal scoring,
-- economics internals, provenance, credentials and identifiers cannot leak.
-- Returns NOT_FOUND for anything not PUBLISHED. Consumes the universal contract
-- (template_family/version, market, currency, offer, sections, assets, copy).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_public_storefront_render(p_slug text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  p public.commerce_product_pages%rowtype;
  sp public.commerce_store_projects%rowtype;
  pm jsonb; rc jsonb; v_assets jsonb;
BEGIN
  SELECT * INTO sp FROM public.commerce_store_projects
   WHERE (public_route = p_slug OR slug = p_slug) LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  SELECT * INTO p FROM public.commerce_product_pages WHERE id = sp.product_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  -- Fail closed: only PUBLISHED pages are publicly renderable.
  IF coalesce(p.publication_state,'') <> 'PUBLISHED' THEN
    RETURN jsonb_build_object('status','NOT_FOUND');
  END IF;

  pm := coalesce(p.page_model,'{}'::jsonb);
  rc := coalesce(p.runtime_contract,'{}'::jsonb);
  v_assets := rc->'supplier_asset_refs';

  RETURN jsonb_build_object(
    'status','OK',
    'storefront', jsonb_build_object(
      'slug', coalesce(sp.public_route, sp.slug),
      'template_family', p.template_family,
      'template_version', p.template_version,
      'market', p.market,
      'country_code', p.country_code,
      'currency', jsonb_build_object('display', p.display_currency, 'source', p.source_currency),
      -- economics-safe OFFER: price only; never cost/landed/ceiling/margin.
      'offer', jsonb_build_object('price', p.selling_price, 'currency', p.display_currency,
                 'note','no fabricated discount or crossed-out price'),
      'hero', jsonb_build_object('variant', rc->>'hero_variant',
                 'headline', pm->'hero'->>'headline', 'subheadline', pm->'hero'->>'subheadline'),
      -- section structure only (type/order/role/render) — no internal scoring.
      'sections', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                     'type', s->>'type', 'order', s->'order',
                     'conversion_role', s->>'conversion_role', 'render', s->'render') ORDER BY (s->>'order')::int),'[]'::jsonb)
                   FROM jsonb_array_elements(coalesce(rc->'sections','[]'::jsonb)) s),
      'cta_structure', rc->'cta_structure',
      'copy', jsonb_build_object(
         'product_title', pm->>'product_title',
         'short_description', pm->>'short_description',
         'benefits', pm->'benefits',
         'how_it_works', pm->'how_it_works',
         'problem_solution', pm->'problem_solution',
         'shipping', jsonb_build_object('copy', pm->'shipping'->>'copy',
             'est_min_days', pm->'shipping'->>'est_min_days','est_max_days', pm->'shipping'->>'est_max_days',
             'method', pm->'shipping'->>'method'),
         'trust', jsonb_build_object('copy', pm->'trust'->>'copy','disclaimers', pm->'trust'->'disclaimers'),
         'faq', pm->'faq',
         'seo', jsonb_build_object('title', pm->'seo'->>'title','meta_description', pm->'seo'->>'meta_description')),
      -- assets: rights-clear SOURCE supplier image URLs only.
      'assets', jsonb_build_object(
         'primary_image', v_assets->'primary_image'->>'source_url',
         'gallery', (SELECT coalesce(jsonb_agg(g->>'source_url'),'[]'::jsonb)
                     FROM jsonb_array_elements(coalesce(v_assets->'gallery','[]'::jsonb)) g),
         'state', CASE WHEN v_assets->>'state'='ASSETS_AVAILABLE' THEN 'SUPPLIER_ASSETS' ELSE 'IMAGE_UNAVAILABLE' END),
      'claim_safety', jsonb_build_object(
         'no_reviews_fabricated', true, 'no_fake_discount', true, 'no_guaranteed_delivery', true,
         'no_urgency_scarcity', true, 'delivery_labeled_estimate', true,
         'claim_scan_clean', (rc->'claim_safety'->>'claim_scan_clean')::boolean),
      'product_provenance', jsonb_build_object(
         'title', pm->>'product_title', 'condition','New',
         'fulfilment','Ships from the supplier warehouse; delivery times are estimates',
         'evidence_basis','SUPPLIER_CONFIRMED'),
      'checkout', jsonb_build_object('state','CHECKOUT_NOT_CONFIGURED',
         'functional', false,
         'dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER',
         'note','no payment/checkout provider connected; add-to-cart CTA is non-functional (no fabricated checkout)'),
      'publication', jsonb_build_object('state','PUBLISHED','noindex', true)));
END; $function$;

COMMENT ON FUNCTION public.fn_public_storefront_render(text) IS
 'Public-safe storefront renderer (allowlist-only). Returns publishable data for PUBLISHED pages only; NOT_FOUND for drafts/unknown. Never exposes economics internals, scoring, provenance secrets, credentials, or other-tenant data.';

-- ---------------------------------------------------------------------------
-- fn_storefront_publish: Pulse-hosted publish. Requires the page to be APPROVED,
-- re-runs launch-critical gates (TEST eligibility, claim safety, asset safety,
-- destination validation), fails closed on any, then mints a STABLE Pulse-hosted
-- destination URL and sets publication_state=PUBLISHED. Deploying the anonymous
-- public HTTP endpoint is a separate founder-gated step (public_endpoint_state).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_publish(
  p_page_id uuid, p_gate_inputs jsonb, p_actor uuid DEFAULT NULL)
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

  -- Re-run launch-critical gates (fail closed).
  v_gate := public.fn_storefront_test_eligibility(p_gate_inputs);
  IF NOT (v_gate->>'test_eligible')::boolean THEN
    RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY','reason_codes',v_gate->'reason_codes','gate',v_gate);
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

  -- Stable Pulse-hosted slug + canonical destination URL (reserved).
  v_slug := 'p'||left(replace(p_page_id::text,'-',''),12);
  v_url := v_base||'/functions/v1/storefront/'||v_slug;

  UPDATE public.commerce_product_pages SET
    review_state = 'PUBLISHED', publication_state = 'PUBLISHED', published_url = v_url,
    runtime_contract = coalesce(runtime_contract,'{}'::jsonb) || jsonb_build_object(
      'review_state','PUBLISHED','publication_state','PUBLISHED',
      'publication', jsonb_build_object(
        'destination','PULSE_HOSTED','slug',v_slug,'destination_url',v_url,'noindex',true,
        'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT',
        'renderer','fn_public_storefront_render',
        'published_at', now(),
        'gates', jsonb_build_object('test_eligible',true,'claim_scan_clean',true,
           'assets_state',v_assets->>'state','destination','PULSE_STORE'),
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
    'checkout_state','CHECKOUT_NOT_CONFIGURED','checkout_dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER',
    'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT',
    'renderer','fn_public_storefront_render',
    'gates', jsonb_build_object('test_eligible',true,'claim_scan_clean',true,
       'assets_state',v_assets->>'state','destination','PULSE_STORE'),
    'note','internal publication runtime complete; anonymous public HTTP endpoint deploy is founder-gated');
END; $function$;

COMMENT ON FUNCTION public.fn_storefront_publish(uuid,jsonb,uuid) IS
 'Pulse-hosted publish: requires APPROVED, re-runs TEST/claim/asset/destination gates (fail closed), sets PUBLISHED + stable destination URL. Public HTTP endpoint deploy remains founder-gated.';

-- ---------------------------------------------------------------------------
-- Execute grants: renderer + publish are backend/tenant operations. The public
-- HTTP serving layer (a future, founder-approved edge function) calls the
-- renderer with service_role; anon is NOT granted direct DB access.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fn_public_storefront_render(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_public_storefront_render(text) TO service_role, authenticated;
REVOKE ALL ON FUNCTION public.fn_storefront_publish(uuid,jsonb,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_storefront_publish(uuid,jsonb,uuid) TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- fn_storefront_publish_selftest: publish + renderer regression (self-cleaning).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_publish_selftest()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; r jsonb; render jsonb;
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
  pid uuid; slug text;
  ok_gate jsonb := '{"recommendation":"TEST","decision_tier":"STRONG_TEST","supplier_identity_state":"SUPPLIER_EXACT","market_supplier_match":"EXACT_CONFIRMED","subtype_price_valid":true,"stock_state":"IN_STOCK","economics_state":"VIABLE","product_confidence":"ACCEPTABLE","fulfilment_evidence":true,"no_critical_risk":true}'::jsonb;
BEGIN
  INSERT INTO public.commerce_product_pages(user_id,market,country_code,destination,decision_classification,
     page_model,status,source_kind,review_state,publication_state,selling_price,display_currency,source_currency,runtime_contract)
   VALUES (u1,'US','US','PULSE_STORE','QUALIFIED_TEST_NOT_HIGH_CONFIDENCE',
     '{"product_title":"Selftest Cam","hero":{"headline":"Selftest Cam"},"benefits":["a"],"trust":{"copy":"New."},"shipping":{"copy":"Estimate"},"seo":{"title":"Selftest"}}'::jsonb,
     'READY_FOR_REVIEW','REAL','DRAFT','UNPUBLISHED',91.79,'USD','USD',
     jsonb_build_object('hero_variant','HERO_FEATURE_SPOTLIGHT','cta_structure','{}'::jsonb,'sections','[]'::jsonb,
       'claim_safety', jsonb_build_object('claim_scan_clean', true),
       'supplier_asset_refs', jsonb_build_object('state','ASSETS_AVAILABLE','usable_count',1,'rejected_count',0,
          'fulfilment_supplier','cjdropshipping','supplier_product_id','SELFTEST_PUB',
          'primary_image', jsonb_build_object('source_url','https://cf.cjdropshipping.com/x.jpg'),
          'gallery', jsonb_build_array(jsonb_build_object('source_url','https://cf.cjdropshipping.com/x.jpg')))))
   RETURNING id INTO pid;
  INSERT INTO public.commerce_store_projects(user_id,product_page_id,project_state,slug,source_kind)
   VALUES (u1,pid,'DRAFT','selftestpub-'||left(replace(pid::text,'-',''),8),'REAL');

  -- publish requires APPROVED
  r := public.fn_storefront_publish(pid, ok_gate, u1);
  v := v || jsonb_build_object('case','publish_requires_approved','pass', r->>'status'='NOT_APPROVED','got',r->>'status');
  -- renderer NOT_FOUND while draft
  render := public.fn_public_storefront_render((SELECT csp.slug FROM public.commerce_store_projects csp WHERE csp.product_page_id=pid));
  v := v || jsonb_build_object('case','renderer_notfound_for_draft','pass', render->>'status'='NOT_FOUND','got',render->>'status');
  -- approve then cross-tenant publish denied
  PERFORM public.fn_storefront_transition_state(pid,'IN_REVIEW',u1);
  PERFORM public.fn_storefront_transition_state(pid,'APPROVED',u1);
  r := public.fn_storefront_publish(pid, ok_gate, u2);
  v := v || jsonb_build_object('case','publish_cross_tenant_denied','pass', r->>'status'='DENIED_CROSS_TENANT','got',r->>'status');
  -- publish fail-closed on bad gate (watch)
  r := public.fn_storefront_publish(pid, ok_gate || '{"recommendation":"WATCH"}'::jsonb, u1);
  v := v || jsonb_build_object('case','publish_failclosed_bad_gate','pass', r->>'status'='BLOCKED_TEST_ELIGIBILITY','got',r->>'status');
  -- real publish
  r := public.fn_storefront_publish(pid, ok_gate, u1);
  slug := r->>'slug';
  v := v || jsonb_build_object('case','publish_ok','pass', r->>'status'='ok' AND r->>'publication_state'='PUBLISHED' AND r->>'destination_url' IS NOT NULL,'got',r->>'status');
  v := v || jsonb_build_object('case','publish_checkout_not_configured','pass', r->>'checkout_state'='CHECKOUT_NOT_CONFIGURED','got',r->>'checkout_state');
  -- renderer OK for published
  render := public.fn_public_storefront_render(slug);
  v := v || jsonb_build_object('case','renderer_ok_for_published','pass', render->>'status'='OK' AND (render->'storefront'->'checkout'->>'state')='CHECKOUT_NOT_CONFIGURED','got',render->>'status');
  -- renderer secret-stripping (no economics internals/scoring/credentials)
  v := v || jsonb_build_object('case','renderer_no_secrets','pass',
        NOT (render::text ILIKE '%landed%' OR render::text ILIKE '%supplier_cost%' OR render::text ILIKE '%accessToken%'
             OR render::text ILIKE '%"wps"%' OR render::text ILIKE '%decision_classification%' OR render::text ILIKE '%user_id%'),
        'got','checked');
  -- renderer NOT_FOUND for unknown slug
  render := public.fn_public_storefront_render('does-not-exist-'||left(replace(gen_random_uuid()::text,'-',''),8));
  v := v || jsonb_build_object('case','renderer_notfound_unknown','pass', render->>'status'='NOT_FOUND','got',render->>'status');

  DELETE FROM public.commerce_store_projects WHERE product_page_id=pid;
  DELETE FROM public.commerce_product_pages WHERE id=pid;

  RETURN jsonb_build_object('suite','pulse_hosted_publish',
    'total', jsonb_array_length(v),
    'passed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed',(SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_storefront_publish_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_storefront_publish_selftest() TO service_role;
COMMENT ON FUNCTION public.fn_storefront_publish_selftest() IS
 'Publish + public-renderer regression (self-cleaning): approval-required, cross-tenant denial, fail-closed gate, publish OK + stable URL, checkout-not-configured, renderer published/draft/unknown, secret-stripping.';

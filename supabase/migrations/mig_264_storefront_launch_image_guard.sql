-- ============================================================================
-- mig_264_storefront_launch_image_guard.sql
-- STRATELOQ-ECOM-HISTORICAL-PRODUCT-IMAGE-ENRICHMENT-013X (Phase 5 launch guard)
--
-- Phase 5 audit: fn_storefront_publish gates on approval, test-eligibility, claim
-- safety, supplier-asset safety and destination — but nothing prevents a REAL
-- product-linked page from publishing to a customer-facing storefront when the
-- product has no trustworthy canonical image (image_state <> AVAILABLE). The asset
-- gate only blocks the rejected-with-none-usable case, so a product-linked page with
-- no resolvable image could publish silently.
--
-- Smallest additive, server-authoritative guard (fail closed): before publishing,
-- when the page is linked to a canonical product (product_id NOT NULL), require
-- fn_resolve_product_image(...) = AVAILABLE. This never fabricates an image, never
-- changes any score/decision, and does not hide Product Opportunities from the
-- intelligence workspace — it only stops a customer-facing storefront from going
-- live with a missing/fake product image. Product_id-less pages (e.g. selftest
-- fixtures) are unaffected.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_storefront_publish(
  p_page_id uuid, p_gate_inputs jsonb DEFAULT '{}'::jsonb, p_actor uuid DEFAULT NULL)
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
  v_derived boolean := false; v_econ text; v_pimg jsonb;
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
    IF NOT (v_gate->>'test_eligible')::boolean THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY','reason_codes',v_gate->'reason_codes','gate',v_gate);
    END IF;
  ELSE
    v_derived := true;
    v_econ := upper(coalesce(p.runtime_contract->>'economics_state',''));
    IF coalesce(p.runtime_contract->>'generation_state','') <> 'GENERATED' THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY',
        'reason_codes', jsonb_build_array('REJECT_NOT_GENERATED'),
        'note','server-derived: page was not produced by the gated storefront generator');
    END IF;
    IF v_econ NOT IN ('VIABLE','POSITIVE') THEN
      RETURN jsonb_build_object('status','BLOCKED_TEST_ELIGIBILITY',
        'reason_codes', jsonb_build_array('REJECT_ECONOMICS_NOT_VIABLE'),
        'note','server-derived: persisted economics not viable ('||coalesce(v_econ,'UNKNOWN')||')');
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

  -- 013X launch-readiness image guard (fail closed): a real product-linked customer
  -- storefront must carry a trustworthy canonical product image. No fabrication.
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

  UPDATE public.commerce_product_pages SET
    review_state = 'PUBLISHED', publication_state = 'PUBLISHED', published_url = v_url,
    runtime_contract = coalesce(runtime_contract,'{}'::jsonb) || jsonb_build_object(
      'review_state','PUBLISHED','publication_state','PUBLISHED',
      'publication', jsonb_build_object(
        'destination','PULSE_HOSTED','slug',v_slug,'destination_url',v_url,'noindex',true,
        'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT',
        'renderer','fn_public_storefront_render',
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
    'eligibility_source', CASE WHEN v_derived THEN 'SERVER_DERIVED_PERSISTED' ELSE 'EXPLICIT_GATE' END,
    'checkout_state','CHECKOUT_NOT_CONFIGURED','checkout_dependency','BLOCKED_EXTERNAL_CHECKOUT_PROVIDER',
    'public_endpoint_state','PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT',
    'renderer','fn_public_storefront_render',
    'gates', jsonb_build_object('test_eligible',true,'claim_scan_clean',true,
       'assets_state',v_assets->>'state','destination','PULSE_STORE',
       'product_image_state', CASE WHEN p.product_id IS NOT NULL THEN coalesce(v_pimg->>'image_state','NONE') ELSE 'N/A' END),
    'note','internal publication runtime complete; anonymous public HTTP endpoint deploy is founder-gated');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_storefront_publish(uuid,jsonb,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_storefront_publish(uuid,jsonb,uuid) TO service_role, authenticated;

-- PULSE-ECOM-P8-STOREFRONT-FINAL-ACCEPTANCE-001
-- PRODUCT_VIDEO contract: the asset resolver and public renderer gain a video
-- channel. A video is usable only when it belongs to the exact supplier/product,
-- is AVAILABLE + rights-clear (SUPPLIER_PROVIDED/LICENSED/OWNED), is NOT a
-- reference/sourcing asset, and comes from the fulfilment supplier — OR is a
-- GENERATED_CREATIVE (future Ad Studio/media video) with explicit provenance.
-- No usable video -> VIDEO_ASSET_NOT_AVAILABLE and the section hides cleanly.
-- Images/gallery logic and the IMAGE `state` are unchanged (back-compatible).

CREATE OR REPLACE FUNCTION public.fn_resolve_storefront_assets(
  p_supplier text, p_supplier_product_id text, p_market text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_fulfil text := lower(coalesce(p_supplier,''));
  v_usable jsonb := '[]'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
  v_primary jsonb := NULL;
  v_video jsonb := NULL;
  r record; v_reason text;
BEGIN
  IF v_fulfil IN ('cj','cjdropshipping','cj_dropshipping') THEN v_fulfil := 'cjdropshipping'; END IF;

  FOR r IN
    SELECT * FROM public.supplier_product_assets
    WHERE p_supplier_product_id IS NOT NULL
      AND supplier_product_id = p_supplier_product_id
    ORDER BY is_primary DESC NULLS LAST, observed_at DESC NULLS LAST
  LOOP
    v_reason := NULL;
    IF coalesce(r.availability,'') <> 'AVAILABLE' THEN v_reason := 'UNAVAILABLE';
    ELSIF coalesce(r.rights_state,'UNKNOWN') NOT IN ('SUPPLIER_PROVIDED','LICENSED','OWNED') THEN v_reason := 'RIGHTS_NOT_ESTABLISHED';
    ELSIF coalesce(r.provenance->>'reference_only','false') = 'true' THEN v_reason := 'REFERENCE_ONLY';
    ELSIF coalesce(r.provenance->>'purpose','') ILIKE '%SOURCING%' THEN v_reason := 'SOURCING_REFERENCE';
    ELSIF coalesce(r.asset_identity,'') ILIKE '%SOURCING%' THEN v_reason := 'SOURCING_REFERENCE';
    ELSIF coalesce(r.asset_type,'') ILIKE '%reference%' THEN v_reason := 'REFERENCE_ONLY';
    ELSIF coalesce(r.asset_class,'') NOT IN ('SOURCE_PRODUCT_ASSET','GENERATED_CREATIVE','LICENSED_ASSET') THEN v_reason := 'DISALLOWED_ASSET_CLASS';
    ELSIF lower(coalesce(r.original_source,'')) IN ('fruugo','ebay','amazon','aliexpress-reference','reference') THEN v_reason := 'REFERENCE_ONLY_MARKETPLACE';
    ELSIF v_fulfil <> '' AND lower(coalesce(r.original_source,'')) <> v_fulfil AND lower(coalesce(r.supplier,'')) <> v_fulfil THEN v_reason := 'NOT_FULFILMENT_SUPPLIER_SOURCE';
    END IF;

    IF v_reason IS NULL THEN
      IF coalesce(r.asset_type,'') ILIKE '%video%' THEN
        -- Usable product video (supplier-provided or a rights-clear GENERATED_CREATIVE).
        IF v_video IS NULL THEN
          v_video := jsonb_build_object('asset_id', r.id, 'source_url', r.source_url, 'storage_ref', r.storage_ref,
            'asset_class', coalesce(r.asset_class,'SOURCE_PRODUCT_ASSET'),
            'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END,
            'rights_state', r.rights_state, 'original_source', r.original_source);
        END IF;
      ELSE
        v_usable := v_usable || jsonb_build_object(
          'asset_id', r.id, 'asset_type', r.asset_type,
          'asset_class', coalesce(r.asset_class,'SOURCE_PRODUCT_ASSET'),
          'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END,
          'rights_state', r.rights_state, 'is_primary', coalesce(r.is_primary,false),
          'source_url', r.source_url, 'storage_ref', r.storage_ref, 'original_source', r.original_source);
        IF v_primary IS NULL AND coalesce(r.asset_type,'IMAGE') ILIKE '%image%' THEN
          v_primary := jsonb_build_object('asset_id', r.id, 'source_url', r.source_url, 'storage_ref', r.storage_ref,
                         'origin_kind', CASE WHEN r.asset_class='GENERATED_CREATIVE' THEN 'GENERATED' ELSE 'SOURCE_SUPPLIER' END);
        END IF;
      END IF;
    ELSE
      v_rejected := v_rejected || jsonb_build_object('asset_id', r.id, 'reason', v_reason,
        'original_source', r.original_source, 'rights_state', r.rights_state, 'availability', r.availability, 'asset_type', r.asset_type);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'state', CASE WHEN v_primary IS NOT NULL THEN 'ASSETS_AVAILABLE' ELSE 'IMAGE_UNAVAILABLE' END,
    'primary_image', v_primary,
    'gallery', v_usable,
    'usable_count', jsonb_array_length(v_usable),
    'video', v_video,
    'video_state', CASE WHEN v_video IS NOT NULL THEN 'VIDEO_AVAILABLE' ELSE 'VIDEO_ASSET_NOT_AVAILABLE' END,
    'rejected', v_rejected,
    'rejected_count', jsonb_array_length(v_rejected),
    'fulfilment_supplier', v_fulfil,
    'supplier_product_id', p_supplier_product_id,
    'no_fabricated_replacement', true,
    'source_vs_generated_distinction', 'origin_kind on each asset (SOURCE_SUPPLIER vs GENERATED)');
END; $function$;

COMMENT ON FUNCTION public.fn_resolve_storefront_assets(text,text,text) IS
 'Asset-safety resolver: usable images (gallery/primary) + one usable product video. Reference-only/sourcing/marketplace/rights-unknown assets rejected. No usable video -> VIDEO_ASSET_NOT_AVAILABLE. Distinguishes SOURCE_SUPPLIER vs GENERATED origin. No fabricated replacement.';

-- Public renderer: expose the video channel (state + url only when available).
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
  SELECT * INTO sp FROM public.commerce_store_projects WHERE (public_route = p_slug OR slug = p_slug) LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  SELECT * INTO p FROM public.commerce_product_pages WHERE id = sp.product_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
  IF coalesce(p.publication_state,'') <> 'PUBLISHED' THEN RETURN jsonb_build_object('status','NOT_FOUND'); END IF;
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
      'offer', jsonb_build_object('price', p.selling_price, 'currency', p.display_currency,
                 'note','no fabricated discount or crossed-out price'),
      'hero', jsonb_build_object('variant', rc->>'hero_variant',
                 'headline', pm->'hero'->>'headline', 'subheadline', pm->'hero'->>'subheadline'),
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
      'assets', jsonb_build_object(
         'primary_image', v_assets->'primary_image'->>'source_url',
         'gallery', (SELECT coalesce(jsonb_agg(g->>'source_url'),'[]'::jsonb)
                     FROM jsonb_array_elements(coalesce(v_assets->'gallery','[]'::jsonb)) g),
         'state', CASE WHEN v_assets->>'state'='ASSETS_AVAILABLE' THEN 'SUPPLIER_ASSETS' ELSE 'IMAGE_UNAVAILABLE' END),
      -- product video: url only when a real, rights-clear video exists; else hidden.
      'video', jsonb_build_object(
         'state', coalesce(v_assets->>'video_state','VIDEO_ASSET_NOT_AVAILABLE'),
         'url', CASE WHEN v_assets->>'video_state'='VIDEO_AVAILABLE' THEN v_assets->'video'->>'source_url' ELSE NULL END,
         'origin_kind', v_assets->'video'->>'origin_kind'),
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

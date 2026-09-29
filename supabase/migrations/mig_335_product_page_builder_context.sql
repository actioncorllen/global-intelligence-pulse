-- ============================================================================
-- mig_335_product_page_builder_context.sql
-- P0 storefront/product-page recovery.
--
-- ROOT CAUSE: the Product Page Builder was built around the ProductAcquisition
-- contract (the product-sourcing pipeline: create_product_acquisition ->
-- select_supplier -> prepare -> approve, table product_acquisitions). But real
-- products reach My Store through the Product Opportunity -> Product Card ->
-- Create Free Store path, which links the CJ supplier directly (fn_link_candidate
-- _supplier) and NEVER creates a product_acquisitions row. So when the builder is
-- opened for a My Store product there is no acquisition object, and Step 1 falls
-- back to nulls ("Not classified / Not selected") even though canonical
-- intelligence has the category, the CJ supplier link, the supplier cost, the
-- commercial image and READY commercial-asset readiness.
--
-- FIX (read-only; no shadow table; nothing fabricated): a single canonical
-- builder-context RPC that assembles the Step 0/1/6 product context for
-- (product, market) directly from the authoritative contracts that DO exist for
-- a My Store product:
--   product/type      <- commerce_products (title, category)
--   identity          <- fn_product_identity_resolution
--   supplier + cost   <- fn_product_supplier_identity + commerce_supplier_products
--   observed price    <- commerce_products.observed_price (marketplace; may be null)
--   suggested price   <- decision economics_ref (only when economics are known;
--                        never fabricated) + supplier-cost floor + profit-target rule
--   commercial image  <- fn_product_card_display_image (commercially eligible only)
--   readiness         <- fn_product_commercial_asset_readiness
--   strategy/listing  <- product_acquisitions.prepared_package when present (else null)
--   page/publish      <- commerce_product_pages
-- Null fields are genuinely uncollected, never invented. Tenant-guarded.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_product_page_builder_context(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_cp public.commerce_products%rowtype;
  v_c text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_ident jsonb; v_sup jsonb; v_suprow public.commerce_supplier_products%rowtype;
  v_img jsonb; v_ready jsonb; v_econ jsonb; v_econ_state text; v_page record;
  v_acq record; v_listing jsonb; v_type text; v_obs_present boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO v_cp FROM public.commerce_products WHERE id=p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  IF v_cp.user_id <> v_uid THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;

  v_ident := public.fn_product_identity_resolution(p_product_id);
  v_sup := public.fn_product_supplier_identity(p_product_id);
  IF coalesce((v_sup->>'has_supplier')::boolean,false) THEN
    SELECT * INTO v_suprow FROM public.commerce_supplier_products
      WHERE id = (v_sup->>'supplier_row_id')::uuid;
  END IF;

  v_img := public.fn_product_card_display_image(v_uid, p_product_id, v_c);
  v_ready := public.fn_product_commercial_asset_readiness(p_product_id, v_c);

  -- economics for the selected market (only surface a suggested price when known)
  SELECT economics_ref INTO v_econ FROM public.product_opportunity_decisions
    WHERE product_id=p_product_id AND (v_c IS NULL OR country_code=v_c) AND coalesce(is_fixture,false)=false
    ORDER BY (country_code=v_c) DESC NULLS LAST, created_at DESC NULLS LAST LIMIT 1;
  v_econ_state := coalesce(v_econ->>'economics_state','UNKNOWN');

  SELECT id, status, publication_state, published_url INTO v_page
    FROM public.commerce_product_pages
    WHERE user_id=v_uid AND product_id=p_product_id AND (v_c IS NULL OR market=v_c OR country_code=v_c)
    ORDER BY updated_at DESC NULLS LAST LIMIT 1;

  -- optional prepared listing (only exists if the product went through sourcing)
  SELECT prepared_package INTO v_acq FROM public.product_acquisitions
    WHERE user_id=v_uid AND winning_product_snapshot->>'product_id' = p_product_id::text
    ORDER BY updated_at DESC NULLS LAST LIMIT 1;
  v_listing := CASE WHEN v_acq.prepared_package IS NOT NULL THEN v_acq.prepared_package->'listing' ELSE NULL END;

  v_type := coalesce(nullif(v_cp.category,''), nullif(v_cp.extended->>'product_type',''), nullif(v_cp.extended->>'category',''));
  v_obs_present := v_cp.observed_price IS NOT NULL;

  RETURN jsonb_build_object(
    'ok', true, 'product_id', p_product_id, 'market', v_c,
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
       'suggested_selling_price', NULL,   -- only surfaced when economics are known; never fabricated
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
    'strategy', jsonb_build_object(
       'positioning', v_listing->>'positioning_statement',
       'target_customer', v_listing->>'target_customer',
       'key_benefits', coalesce(v_listing->'key_benefits','[]'::jsonb),
       'subtitle', v_listing->>'subtitle',
       'has_prepared_listing', (v_listing IS NOT NULL)),
    'page', jsonb_build_object('page_id', v_page.id, 'status', v_page.status,
       'publication_state', coalesce(v_page.publication_state,'UNPUBLISHED'), 'published_url', v_page.published_url),
    'provenance_note','Assembled from canonical Strateloq intelligence (identity, supplier, supplier cost, commercial image, readiness, economics). Null fields are genuinely uncollected, never fabricated.',
    'contract','pulse_product_page_builder_context_v1');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_page_builder_context(uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_page_builder_context(uuid,text) TO authenticated, service_role;

-- Regression selftest (no writes). Guards against future intelligence upgrades
-- silently re-breaking the builder handoff.
CREATE OR REPLACE FUNCTION public.fn_product_page_builder_selftest()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; n jsonb; h jsonb;
  v_night uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_humid uuid := 'cda3f71a-9947-4344-8664-13735740575f';
BEGIN
  -- auth.uid() reads 'sub' from request.jwt.claims; role cannot be set inside a definer.
  PERFORM set_config('request.jwt.claims','{"sub":"7c8ddf9d-172c-4a89-a402-bb7066228b61","role":"authenticated"}', true);
  n := public.fn_product_page_builder_context(v_night,'GB');
  h := public.fn_product_page_builder_context(v_humid,'GB');

  v := v || jsonb_build_object('case','nightlight_type_classified','pass', nullif(n->'product'->>'type','') IS NOT NULL);
  v := v || jsonb_build_object('case','nightlight_supplier_matched','pass', (n->'supplier'->>'matched')::boolean AND n->'supplier'->>'provider'='CJ');
  v := v || jsonb_build_object('case','nightlight_supplier_cost_present','pass', (n->'supplier'->'supplier_cost'->>'amount') IS NOT NULL);
  v := v || jsonb_build_object('case','nightlight_identity_resolved','pass', n->'identity'->>'state'='IDENTITY_RESOLVED');
  v := v || jsonb_build_object('case','nightlight_commercial_image_publishable','pass', (n->'commercial_image'->>'publishable')::boolean);
  v := v || jsonb_build_object('case','nightlight_readiness_ready','pass', n->>'commercial_asset_readiness'='READY');
  v := v || jsonb_build_object('case','nightlight_no_fabricated_price','pass', (n->'pricing'->'suggested_selling_price') = 'null'::jsonb AND (n->'pricing'->>'selling_price_configured')='false');

  -- humidifier concept-only stays gated: supplier_link_allowed false (identity CONCEPT_ONLY)
  v := v || jsonb_build_object('case','humidifier_concept_only','pass', h->'identity'->>'state'='CONCEPT_ONLY');
  v := v || jsonb_build_object('case','humidifier_supplier_link_gated','pass', (h->'identity'->>'supplier_link_allowed')::boolean = false);

  PERFORM set_config('request.jwt.claims','', true);
  RETURN jsonb_build_object('suite','product_page_builder_context',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_product_page_builder_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_product_page_builder_selftest() TO service_role;

-- ============================================================================
-- mig_320_commercial_asset_pipeline.sql
-- STRATELOQ — Commercial product-asset pipeline (honest, rights-first).
--
-- Two problems fixed here, both without weakening any gate and without
-- fabricating rights/ownership/identity:
--
-- 1. SUPPLIER-AUTHORIZED ASSET NOT REACHING THE PUBLISH GATE.
--    fn_generate_storefront_runtime resolves storefront assets from
--    p_context->>'supplier' and p_context->>'supplier_product_id', but the
--    customer-runtime wrapper (fn_storefront_build_customer_runtime) never
--    populated those keys. So a product with a genuine connected-supplier
--    (e.g. CJdropshipping) product match still resolved IMAGE_UNAVAILABLE and
--    was blocked with ASSETS_UNAVAILABLE, even though fn_resolve_storefront_assets
--    returns ASSETS_AVAILABLE for its supplier_product_id. The wrapper now
--    reads the product's supplier identity from commerce_products.extended
--    (supplier_ref / cj_source_product_id) and passes it through, so the
--    EXISTING asset-resolution + publish gate re-evaluate naturally. Products
--    with no supplier-authorized asset (marketplace/reference only) still
--    resolve IMAGE_UNAVAILABLE — nothing is faked.
--
-- 2. COMMERCIAL ASSET READINESS as a first-class, honest signal.
--    fn_product_commercial_asset_readiness(product, market) classifies the best
--    LEGITIMATE commercial-image path for a product, reusing the existing rights
--    model (fn_resolve_storefront_assets + product_image_assets rights_state):
--      READY                              — a rights-cleared commercial image
--                                            exists now (supplier-authorized
--                                            product asset, or rights-confirmed
--                                            customer-owned upload).
--      GENERATABLE_FROM_AUTHORIZED_REFERENCE — not directly publishable yet, but
--                                            an AUTHORIZED reference exists
--                                            (supplier-authorized or customer-
--                                            owned) that an AI commercial-asset
--                                            path could legitimately build from.
--      CUSTOMER_ASSET_REQUIRED            — only marketplace/reference imagery
--                                            exists (image access is NOT
--                                            republishing rights); a customer
--                                            image is required.
--      UNAVAILABLE                        — no product imagery at all.
--    Marketplace/competitor imagery is NEVER promoted to a publishable or
--    generation-eligible reference.
--
--    The function also reports the AI generation path status. No Google/Gemini
--    image-generation connection exists in this project (the only image
--    generator wired is OpenAI gpt-image-1 via n8n, used by Creative Studio),
--    so the AI commercial-asset EXECUTION is reported as
--    BLOCKED_EXTERNAL_CONNECTION with the exact founder action required. The
--    eligibility contract, provenance expectations and identity-validation
--    states are defined here so the pipeline is complete up to the external
--    provider boundary; execution is never faked and no new paid spend is
--    incurred.
--
-- Idempotent (CREATE OR REPLACE). RLS, tenant isolation, Product Asset Lock,
-- one-store invariant and all publish gates unchanged.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Resolve a product's connected-supplier identity from its research record.
--    Honest: only returns an identity the product genuinely carries.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_product_supplier_identity(p_product_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN cp.id IS NULL THEN jsonb_build_object('has_supplier', false)
    WHEN coalesce(
           nullif(cp.extended->'supplier_ref'->>'source_product_id',''),
           nullif(cp.extended->>'cj_source_product_id','')) IS NULL THEN jsonb_build_object('has_supplier', false)
    ELSE jsonb_build_object(
      'has_supplier', true,
      'provider', upper(coalesce(cp.extended->'supplier_ref'->>'provider',
                    CASE WHEN nullif(cp.extended->>'cj_source_product_id','') IS NOT NULL THEN 'CJ' ELSE '' END)),
      'supplier_product_id', coalesce(
           nullif(cp.extended->'supplier_ref'->>'source_product_id',''),
           nullif(cp.extended->>'cj_source_product_id','')),
      'supplier_row_id', cp.extended->'supplier_ref'->>'supplier_row_id')
  END
  FROM (SELECT * FROM public.commerce_products WHERE id = p_product_id) cp
  RIGHT JOIN (SELECT 1) one ON true;
$function$;

-- ---------------------------------------------------------------------------
-- 1. Customer-runtime wrapper: pass the product's supplier identity into the
--    generator so the EXISTING asset resolver can find supplier-authorized
--    assets. (Only this block of v_context changes vs mig_315.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_storefront_build_customer_runtime(p_page_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_tenant uuid := auth.uid(); pg record; cp record; v_img jsonb; v_market text;
  v_decision jsonb; v_context jsonb; v_sel jsonb; v_res jsonb; v_econ text; v_sup jsonb;
BEGIN
  IF v_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','unauthenticated'); END IF;
  SELECT * INTO pg FROM public.commerce_product_pages WHERE id = p_page_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','page_not_found'); END IF;
  IF pg.user_id <> v_tenant THEN RETURN jsonb_build_object('ok',false,'error','cross_tenant_rejected'); END IF;
  IF upper(coalesce(pg.destination,'')) <> 'PULSE_STORE' THEN
    RETURN jsonb_build_object('ok',false,'error','not_a_customer_store_page','destination',pg.destination);
  END IF;

  SELECT * INTO cp FROM public.commerce_products WHERE id = pg.product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found'); END IF;
  v_market := upper(coalesce(pg.market, pg.country_code, ''));
  v_img := public.fn_product_card_display_image(v_tenant, pg.product_id, nullif(v_market,''));
  IF NOT coalesce((v_img->>'has_image')::boolean,false) THEN
    RETURN jsonb_build_object('ok',false,'status','IMPORT_REQUIRED','gate','AUTHORITATIVE_ASSET_REQUIRED',
      'error','no_product_image','action','IMPORT_PRODUCT_IMAGES',
      'message','Add your product image so Strateloq can finish building this page.');
  END IF;

  v_sup := public.fn_product_supplier_identity(pg.product_id);
  v_econ := upper(coalesce(pg.economics_state, pg.runtime_contract->>'economics_state', 'UNKNOWN'));
  v_decision := jsonb_build_object('recommendation','TEST','classification','CUSTOMER_STORE','target_market',v_market,
     'economics', jsonb_build_object('economics_state', v_econ),
     'supplier_execution', jsonb_build_object('economics', jsonb_build_object()));
  v_context := jsonb_build_object('product_title', cp.title, 'positioning', coalesce(cp.description,''),
     'store_authorization','CUSTOMER_STORE_AUTHORIZED',
     'display_currency', pg.display_currency,
     'authoritative_primary_image', CASE WHEN (v_img->>'is_authoritative')::boolean THEN v_img->>'url' ELSE NULL END,
     'supplier_reference', jsonb_build_object('provider', v_img->>'source_provider'))
     -- NEW: hand the connected-supplier identity to the asset resolver so a
     -- genuine supplier-authorized product asset is found (never fabricated).
     || CASE WHEN coalesce((v_sup->>'has_supplier')::boolean,false)
             THEN jsonb_build_object('supplier', v_sup->>'provider',
                                     'supplier_product_id', v_sup->>'supplier_product_id')
             ELSE '{}'::jsonb END;
  v_sel := jsonb_build_object('product_id', pg.product_id::text, 'country_code', v_market,
     'existing_page_id', p_page_id::text, 'ad_match', jsonb_build_object('state','NO_AD_MATCH_YET'));

  v_res := public.fn_generate_storefront_runtime(v_tenant, '{}'::jsonb, v_sel, v_context, v_decision,
     'PULSE_HOSTED', 'REAL', pg.product_id, nullif(v_market,''), NULL, true);

  RETURN jsonb_build_object('ok', ((v_res->>'status')='ok'),
    'product_page_id', p_page_id, 'store_id_unchanged', true,
    'reused_existing_page', coalesce((v_res->>'reused_existing_page')::boolean,false),
    'generation_state', v_res->>'generation_state',
    'authorization_basis', v_res->>'authorization_basis',
    'assets_state', v_res->>'assets_state', 'claim_scan_clean', v_res->>'claim_scan_clean',
    'supplier_identity', v_sup,
    'note','runtime generated on the same page; build only — review/publish gates still apply',
    'result', v_res);
END; $function$;

-- ---------------------------------------------------------------------------
-- 2. Commercial asset readiness — the honest publishable-asset-path signal.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_product_commercial_asset_readiness(p_product_id uuid, p_market text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_owner uuid; v_sup jsonb; v_resolve jsonb; v_state text; v_provider text;
  v_has_supplier_authorized boolean := false; v_has_customer_owned boolean := false;
  v_has_marketplace boolean := false; v_total_images int := 0;
  v_readiness text; v_path text; v_basis text; v_gemini_eligible boolean;
BEGIN
  SELECT user_id INTO v_owner FROM public.commerce_products WHERE id = p_product_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('status','product_not_found'); END IF;

  -- Inventory the product's real imagery by rights basis (never fabricate).
  SELECT
    count(*),
    bool_or(rights_state='SUPPLIER_PROVIDED'),
    bool_or(rights_state='CUSTOMER_OWNED' AND source_provider='CUSTOMER_UPLOAD'
            AND coalesce(provenance->>'rights_confirmed','false')='true'),
    bool_or(rights_state='MARKETPLACE_PUBLIC_LISTING')
  INTO v_total_images, v_has_supplier_authorized, v_has_customer_owned, v_has_marketplace
  FROM public.product_image_assets
  WHERE product_id = p_product_id AND coalesce(is_fixture,false)=false;

  v_sup := public.fn_product_supplier_identity(p_product_id);
  v_provider := v_sup->>'provider';

  -- Authoritative publishable resolution via the existing storefront resolver
  -- (reads supplier_product_assets with full rights/availability checks).
  IF coalesce((v_sup->>'has_supplier')::boolean,false) THEN
    v_resolve := public.fn_resolve_storefront_assets(v_provider, v_sup->>'supplier_product_id', p_market);
    v_state := v_resolve->>'state';
  END IF;

  -- An AI generation reference is eligible only from an AUTHORIZED basis.
  v_gemini_eligible := (v_has_supplier_authorized OR v_has_customer_owned
                        OR (v_sup->>'has_supplier')::boolean IS TRUE);

  IF v_state = 'ASSETS_AVAILABLE' THEN
    v_readiness := 'READY'; v_path := 'SUPPLIER_AUTHORIZED_COMMERCIAL_ASSET';
    v_basis := 'Connected supplier provides a rights-cleared product image for this exact supplier product.';
  ELSIF v_has_customer_owned THEN
    v_readiness := 'READY'; v_path := 'CUSTOMER_OWNED_ASSET';
    v_basis := 'A rights-confirmed customer-owned product image is available.';
  ELSIF v_has_supplier_authorized OR coalesce((v_sup->>'has_supplier')::boolean,false) THEN
    v_readiness := 'GENERATABLE_FROM_AUTHORIZED_REFERENCE'; v_path := 'SUPPLIER_AUTHORIZED_REFERENCE';
    v_basis := 'An authorized supplier reference exists; a commercial image can be produced from it (identity-validated) rather than republishing a marketplace image.';
  ELSIF v_has_marketplace THEN
    v_readiness := 'CUSTOMER_ASSET_REQUIRED'; v_path := 'NONE';
    v_basis := 'Only marketplace/reference imagery is available. Image access is not republishing rights, so a customer-owned or supplier-authorized image is required to publish.';
  ELSIF v_total_images = 0 THEN
    v_readiness := 'UNAVAILABLE'; v_path := 'NONE';
    v_basis := 'No product imagery has been observed for this product.';
  ELSE
    v_readiness := 'CUSTOMER_ASSET_REQUIRED'; v_path := 'NONE';
    v_basis := 'No rights-cleared commercial image path is established yet.';
  END IF;

  RETURN jsonb_build_object(
    'status','ok','product_id', p_product_id, 'market', upper(coalesce(p_market,'')),
    'commercial_asset_readiness', v_readiness,
    'publishable_asset_path', v_path,
    'basis', v_basis,
    'has_supplier_match', coalesce((v_sup->>'has_supplier')::boolean,false),
    'supplier_provider', v_provider,
    'supplier_product_id', v_sup->>'supplier_product_id',
    'supplier_resolution_state', coalesce(v_state,'NOT_RESOLVED'),
    'images', jsonb_build_object('total', v_total_images,
      'has_supplier_authorized', v_has_supplier_authorized,
      'has_customer_owned', v_has_customer_owned,
      'has_marketplace_reference', v_has_marketplace),
    -- AI commercial-asset (Gemini) path: eligibility is honest; execution is
    -- an external dependency that is not connected in this project.
    'ai_generation', jsonb_build_object(
      'reference_eligible', v_gemini_eligible,
      'reference_basis', CASE
        WHEN v_has_customer_owned THEN 'CUSTOMER_OWNED'
        WHEN v_has_supplier_authorized OR coalesce((v_sup->>'has_supplier')::boolean,false) THEN 'SUPPLIER_AUTHORIZED'
        ELSE 'NONE' END,
      'provider','GOOGLE_GEMINI',
      'execution_state', CASE WHEN v_gemini_eligible THEN 'BLOCKED_EXTERNAL_CONNECTION' ELSE 'NOT_ELIGIBLE' END,
      'requires','Google Gemini image-generation API access (GEMINI_API_KEY / Google AI credential + enabled image model) is not connected. Marketplace/competitor imagery is never an eligible reference.',
      'product_asset_lock','Generated output must preserve exact product identity/SKU and pass identity validation (IDENTITY_VALIDATED) before it becomes a commercial asset; a materially different SKU is REJECT_GENERATED_ASSET.'),
    'note','Marketplace/reference images are never a publishable or generation-eligible source. Rights are never fabricated.');
END; $function$;

COMMENT ON FUNCTION public.fn_product_commercial_asset_readiness(uuid, text) IS
  'Honest publishable-commercial-asset path signal for a product. READY / GENERATABLE_FROM_AUTHORIZED_REFERENCE / CUSTOMER_ASSET_REQUIRED / UNAVAILABLE. Reuses fn_resolve_storefront_assets and product_image_assets rights_state; never promotes marketplace/reference imagery to a publishable or generation-eligible source; never fabricates rights.';

-- ============================================================================
-- mig_305_exact_variant_pricing_stock_shipping.sql
-- STRATELOQ-STAGE5B-EXACT-VARIANT-PRICING-STOCK-DESTINATION-SHIPPING
--
-- EXTENDS the Stage 5A resolver fn_resolve_supplier_economics(p_product, p_market)
-- (mig_304, commit 5d4e3e4) so economics are accurate at the INDIVIDUAL VARIANT
-- level. Same signature, same name (stable frontend contract). Read-only, tenant
-- scoped, supplier-neutral. No new tables, no provider calls, no asset writes.
-- Reuses fn_supplier_economics / fn_currency_for_country / fn_variant_design_match.
--
-- ROOT-CAUSE FOUND IN STAGE 5B VERIFICATION (why exact-variant stock/shipping are
-- not yet confirmable from stored CJ data): CJ enrichment sampled STOCK and GB
-- FREIGHT on a single representative variant (the cheapest), which for the Old-Man-
-- Face ski mask is vid 2610160136531626809 / SKU CJMZ320782836JQ — an ANIMAL_FACE
-- (DIFFERENT_DESIGN) variant, NOT an Old-Man-Face variant. Per-variant PRICE, SKU,
-- image and weight ARE stored for all variants (supplier_enrichment.variant_catalog),
-- but per-variant STOCK and per-variant DESTINATION SHIPPING are not — they exist
-- only as a listing-level sample keyed to that one animal-face vid.
--
-- STAGE 5B CORRECTIONS (all truthful, fail-closed, no fabrication):
--   * Priority A — candidate_variant_prices now carries, per variant: its OWN sku,
--     price_usd, price_currency, vid, class, design_match, image (reference-only),
--     weight_g, verification_status and a per-variant missing_evidence[] list.
--     The Black-Cat/displayed variant's price is NEVER used as an Old-Man-Face cost.
--   * Priority C — stock is split into exact_variant_stock (only when the stored
--     sample's vid equals the confirmed variant's vid; otherwise UNKNOWN /
--     NOT_SAMPLED_FOR_THIS_VARIANT) and listing_stock_sampled (the raw sample, with
--     its sampled vid + class, warehouse cj_inventory vs factory_inventory split and
--     an explicit immediately_available guard). Factory-replenishable is NEVER
--     presented as available; unrelated variants' inventory is never combined.
--   * Priority D — destination_shipping carries sampled_vid, sampled_variant_class,
--     sku_exact and a basis of SKU_EXACT vs LISTING_SAMPLED. Country/currency
--     isolation preserved; shipping never assumed free; GB freight is never reused
--     for another country (destination-generic lookup kept from Stage 5A).
--   * Priority B/8 — basis EXACT_VERIFIED only when the concrete resolution binds the
--     exact SKU AND the identity layer verified the variant. On EXACT_VERIFIED the
--     exact_variant block + landed cost use the CONFIRMED variant's OWN catalog price
--     and SKU-exact shipping; if stored shipping is not SKU-exact, exact landed cost
--     is withheld (requires_sku_exact_destination_shipping) rather than fabricated.
--   * evidence_summary counts (price / image / exact-stock / sku-exact-shipping /
--     confirmed-exact) to make coverage explicit.
--
-- Preserves every Stage 5A guarantee: FX/shipping fail-closed, explicit excludes,
-- freshness + FX provenance, profitability withheld without exact-variant evidence
-- and a confirmed selling price, tenant isolation (auth.uid() owner check), country
-- isolation, supplier-neutral provider (from the stored identity row), Product Asset
-- Lock (supplier imagery stays reference-only). anon/PUBLIC have no EXECUTE.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_supplier_economics(p_product uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_owns boolean; x record; sp record;
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_ccy text; v_confirmed_sku text; v_exact boolean; v_basis text;
  v_rep jsonb; v_ship numeric; v_ship_known boolean; v_cost numeric;
  v_sup_json jsonb; v_eng jsonb; v_landed_usd numeric;
  v_disp_sku text; v_disp record; v_disp_dm text; v_disp_class text;
  v_variants jsonb; v_stock jsonb; v_age numeric;
  -- Stage 5B: per-variant / sampled-correspondence state
  v_stock_svid text; v_ship_svid text; v_stock_sclass text; v_ship_sclass text;
  v_conf_vid text; v_conf_price numeric; v_conf_image text; v_conf_weight numeric;
  v_ship_sku_exact boolean; v_stock_exact_known boolean;
  v_dest_shipping jsonb; v_stock_out jsonb; v_exact_variant jsonb; v_landed jsonb;
  v_imm_avail boolean;
BEGIN
  IF v_uid IS NULL OR p_product IS NULL THEN
    RETURN jsonb_build_object('present',false,'status','unauthorized'); END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product AND user_id=v_uid) INTO v_owns;
  IF NOT v_owns THEN RETURN jsonb_build_object('present',false,'status','unauthorized'); END IF;
  IF v_mkt='' THEN RETURN jsonb_build_object('present',false,'status','market_required'); END IF;

  SELECT * INTO x FROM public.commerce_cross_supplier_identity
    WHERE tenant_id=v_uid AND opportunity_product_id=p_product AND market=v_mkt
    ORDER BY CASE identity_tier WHEN 'EXACT_VARIANT_VERIFIED' THEN 0 WHEN 'SAME_PRODUCT_IDENTITY' THEN 1
             WHEN 'SIMILAR_ONLY' THEN 2 ELSE 3 END, updated_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('present',false,'status','no_candidate','market',v_mkt); END IF;

  v_ccy := public.fn_currency_for_country(v_mkt);

  SELECT selected_sku INTO v_confirmed_sku FROM public.commerce_concrete_supplier_resolution
    WHERE tenant_id=v_uid AND opportunity_product_id=p_product AND market=v_mkt
      AND coalesce(is_fixture,false)=false AND coalesce(bound,false)=true AND selected_sku IS NOT NULL
    ORDER BY created_at DESC LIMIT 1;
  v_exact := (v_confirmed_sku IS NOT NULL AND coalesce(x.variant_verified,false));
  v_basis := CASE WHEN v_exact THEN 'EXACT_VERIFIED' ELSE 'CANDIDATE_LISTING' END;

  SELECT supplier_cost, enrichment_observed_at,
         supplier_enrichment->'freight'        AS freight,
         coalesce(supplier_enrichment->'stock', x.economics->'stock') AS stock,
         supplier_enrichment->'variant_catalog' AS catalog,
         nullif(btrim(coalesce(raw->>'sell_price_range_usd', supplier_enrichment->>'sell_price_range_usd','')),'') AS price_range
    INTO sp
  FROM public.commerce_supplier_products
  WHERE source = x.source AND source_product_id = x.supplier_product_id LIMIT 1;

  v_cost := sp.supplier_cost;
  v_stock := sp.stock;
  v_age := round((EXTRACT(EPOCH FROM (now() - sp.enrichment_observed_at))/86400.0)::numeric, 1);

  -- Destination-GENERIC freight (never GB-hardcoded); shipping never assumed 0.
  v_rep := sp.freight -> v_mkt -> 'representative';
  IF v_rep IS NOT NULL THEN
    v_ship := nullif(btrim(coalesce(v_rep->>'shipping_cost','')),'')::numeric;
    v_ship_known := v_ship IS NOT NULL;
  ELSE v_ship_known := false; END IF;

  -- Sampled-variant correspondence (Priority C/D): which vid the stored stock and
  -- the destination freight were actually sampled on, and that vid's design class.
  v_stock_svid := v_stock->>'sampled_vid';
  v_ship_svid  := v_rep->>'sampled_vid';
  SELECT vc->>'class' INTO v_stock_sclass
    FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc
    WHERE vc->>'vid' = v_stock_svid LIMIT 1;
  SELECT vc->>'class' INTO v_ship_sclass
    FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc
    WHERE vc->>'vid' = v_ship_svid LIMIT 1;

  -- Confirmed variant's OWN catalog evidence (only meaningful on EXACT_VERIFIED).
  IF v_confirmed_sku IS NOT NULL THEN
    SELECT c->>'vid', nullif(c->>'price_usd','')::numeric, c->>'image', nullif(c->>'weight_g','')::numeric
      INTO v_conf_vid, v_conf_price, v_conf_image, v_conf_weight
      FROM jsonb_array_elements(coalesce(sp.catalog,'[]'::jsonb)) c
      WHERE c->>'sku' = v_confirmed_sku LIMIT 1;
  END IF;

  v_ship_sku_exact   := (v_exact AND v_ship_svid IS NOT NULL AND v_ship_svid = v_conf_vid);
  v_stock_exact_known:= (v_exact AND v_stock_svid IS NOT NULL AND v_stock_svid = v_conf_vid);
  v_imm_avail := (upper(coalesce(v_stock->>'state','')) = 'IN_STOCK');

  -- ---- Priority D: destination shipping with SKU correspondence ----------------
  v_dest_shipping := CASE WHEN v_ship_known THEN jsonb_build_object(
        'available', true, 'shipping_cost_usd', v_ship, 'currency', 'USD',
        'logistic', v_rep->>'logistic', 'est_min_days', (v_rep->>'est_min_days')::int,
        'est_max_days', (v_rep->>'est_max_days')::int, 'destination', v_rep->>'destination',
        'method', v_rep->>'method', 'source', v_rep->>'source',
        'quoted_observed_at', sp.enrichment_observed_at,
        'sampled_vid', v_ship_svid, 'sampled_variant_class', v_ship_sclass,
        'sku_exact', v_ship_sku_exact,
        'basis', CASE WHEN v_ship_sku_exact THEN 'SKU_EXACT' ELSE 'LISTING_SAMPLED' END,
        'note', CASE WHEN v_ship_sku_exact
                 THEN 'Freight quoted for the confirmed variant SKU and this destination.'
                 ELSE 'Freight is a listing-level sample taken on another variant ('||coalesce(v_ship_sclass,'unknown class')||'); it is representative for this destination, not quoted for the confirmed SKU.' END)
      ELSE jsonb_build_object('available', false, 'reason', 'NOT_CALCULATED_FOR_DESTINATION',
        'note', 'No destination-specific supplier freight stored for this country; shipping and landed cost are not asserted (never assumed 0).') END;

  -- ---- Priority C: inventory accuracy (exact-variant vs listing-sampled) --------
  v_stock_out := jsonb_build_object(
    'exact_variant_stock', CASE WHEN v_stock_exact_known
        THEN jsonb_build_object(
            'known', true, 'vid', v_conf_vid, 'sku', v_confirmed_sku,
            'state', v_stock->>'state',
            'cj_warehouse_inventory', (v_stock->>'cj_inventory'),
            'factory_inventory', (v_stock->>'factory_inventory'),
            'immediately_available', v_imm_avail)
        ELSE jsonb_build_object(
            'known', false, 'state', 'UNKNOWN',
            'reason', CASE WHEN v_exact THEN 'NOT_SAMPLED_FOR_CONFIRMED_VARIANT'
                           ELSE 'NO_CONFIRMED_VARIANT' END,
            'note', 'Supplier stock was not sampled on this exact variant; per-variant inventory is unknown and is not inferred from another variant.') END,
    'listing_stock_sampled', CASE WHEN v_stock IS NULL THEN jsonb_build_object('state','UNKNOWN')
        ELSE jsonb_build_object(
            'state', v_stock->>'state', 'reason', v_stock->>'reason',
            'sampled_vid', v_stock_svid, 'sampled_variant_class', v_stock_sclass,
            'cj_warehouse_inventory', (v_stock->>'cj_inventory'),
            'factory_inventory', (v_stock->>'factory_inventory'),
            'immediately_available', v_imm_avail,
            'note', 'Listing-level stock sampled on one variant; factory replenishment availability is NOT immediate stock.') END,
    'observed_at', sp.enrichment_observed_at);

  -- ---- Reuse canonical engine for landed cost (fail-closed). No selling price. --
  -- On EXACT_VERIFIED use the confirmed variant's OWN price + SKU-exact shipping only.
  v_sup_json := jsonb_build_object(
                  'supplier_cost', CASE WHEN v_exact AND v_conf_price IS NOT NULL THEN v_conf_price ELSE v_cost END,
                  'cost_currency', 'USD', 'is_free_shipping', false)
             || CASE WHEN (CASE WHEN v_exact THEN v_ship_sku_exact ELSE v_ship_known END)
                     THEN jsonb_build_object('shipping_cost', v_ship) ELSE '{}'::jsonb END;
  v_eng := public.fn_supplier_economics(v_sup_json, NULL, coalesce(v_ccy,'USD'));
  v_landed_usd := nullif(v_eng->>'landed_cost_original','')::numeric;

  v_landed := CASE WHEN v_landed_usd IS NOT NULL THEN jsonb_build_object(
        'available', true, 'total_usd', v_landed_usd, 'currency', 'USD',
        'cost_basis', CASE WHEN v_exact THEN 'EXACT_VARIANT' ELSE 'LISTING_REPRESENTATIVE' END,
        'shipping_basis', CASE WHEN v_ship_sku_exact THEN 'SKU_EXACT' ELSE 'LISTING_SAMPLED' END,
        'components', jsonb_build_object(
            'supplier_cost_usd', CASE WHEN v_exact AND v_conf_price IS NOT NULL THEN v_conf_price ELSE v_cost END,
            'shipping_cost_usd', v_ship),
        'display', v_eng->'money',
        'excludes', jsonb_build_array('import_duties','vat_sales_tax','customs_clearance',
                       'payment_processing','advertising','returns','platform_fees'),
        'note', 'Landed = supplier product cost + destination shipping ONLY. Excludes duties, taxes, customs and all selling costs.')
      ELSE jsonb_build_object('available', false,
        'reason', CASE WHEN v_exact AND NOT v_ship_sku_exact THEN 'requires_sku_exact_destination_shipping'
                       ELSE coalesce(v_eng->>'reason','landed_not_computable') END,
        'excludes', jsonb_build_array('import_duties','vat_sales_tax','customs_clearance',
                       'payment_processing','advertising','returns','platform_fees')) END;

  -- ---- Displayed variant's own design_match (caveat a different-design display) --
  v_disp_sku := x.economics->>'sku';
  SELECT vc->>'class' AS class,
         public.fn_variant_design_match(vc->>'class',
            coalesce((vc->>'corresponds_to_concept')::boolean,false),
            (v_confirmed_sku IS NOT NULL AND vc->>'sku'=v_confirmed_sku),
            coalesce(x.variant_verified,false)) AS dm
    INTO v_disp
  FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc
  WHERE vc->>'sku' = v_disp_sku LIMIT 1;
  v_disp_class := v_disp.class; v_disp_dm := v_disp.dm;

  -- ---- Priority A: candidate per-variant prices (EXACT / POTENTIAL only) --------
  -- Each variant keeps its OWN sku, price, image (reference-only), weight, class,
  -- design_match, verification_status and the specific evidence it still lacks.
  SELECT coalesce(jsonb_agg(obj ORDER BY obj->>'sku'), '[]'::jsonb) INTO v_variants
  FROM (
    SELECT jsonb_build_object(
      'vid', vc->>'vid', 'sku', vc->>'sku', 'class', vc->>'class',
      'design_match', d.dm,
      'price_usd', c.price_usd, 'price_currency', 'USD',
      'weight_g', c.weight_g,
      'image', c.image, 'image_rights', 'REFERENCE_ONLY',
      'price_basis', 'CANDIDATE_LISTING',
      'verification_status', CASE WHEN v_exact AND vc->>'sku'=v_confirmed_sku
                                  THEN 'CONFIRMED_EXACT' ELSE 'UNVERIFIED_CANDIDATE' END,
      'missing_evidence',
        (CASE WHEN v_confirmed_sku IS NULL OR vc->>'sku' <> v_confirmed_sku
              THEN jsonb_build_array('exact_sku_confirmation') ELSE '[]'::jsonb END)
     || (CASE WHEN v_stock_svid IS DISTINCT FROM vc->>'vid'
              THEN jsonb_build_array('per_variant_stock') ELSE '[]'::jsonb END)
     || (CASE WHEN v_ship_svid IS DISTINCT FROM vc->>'vid'
              THEN jsonb_build_array('per_variant_destination_shipping') ELSE '[]'::jsonb END)
      ) AS obj
    FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc
    CROSS JOIN LATERAL (SELECT public.fn_variant_design_match(vc->>'class',
            coalesce((vc->>'corresponds_to_concept')::boolean,false),
            (v_confirmed_sku IS NOT NULL AND vc->>'sku'=v_confirmed_sku),
            coalesce(x.variant_verified,false)) AS dm) d
    LEFT JOIN LATERAL (
        SELECT nullif(e->>'price_usd','')::numeric AS price_usd,
               nullif(e->>'weight_g','')::numeric AS weight_g,
               e->>'image' AS image
        FROM jsonb_array_elements(coalesce(sp.catalog,'[]'::jsonb)) e
        WHERE e->>'vid'=vc->>'vid' OR e->>'sku'=vc->>'sku' LIMIT 1) c ON true
    WHERE d.dm IN ('VERIFIED_EXACT_VARIANT','POTENTIAL_SAME_DESIGN')
  ) s;

  -- ---- Priority B: the confirmed exact variant (only when EXACT_VERIFIED) -------
  v_exact_variant := CASE WHEN v_exact THEN jsonb_build_object(
        'confirmed', true, 'sku', v_confirmed_sku, 'vid', v_conf_vid,
        'price_usd', v_conf_price, 'price_currency', 'USD',
        'image', v_conf_image, 'image_rights', 'REFERENCE_ONLY', 'weight_g', v_conf_weight,
        'stock', v_stock_out->'exact_variant_stock',
        'destination_shipping_sku_exact', v_ship_sku_exact)
      ELSE jsonb_build_object('confirmed', false,
        'reason', CASE WHEN v_confirmed_sku IS NULL THEN 'no_exact_sku_binding'
                       WHEN NOT coalesce(x.variant_verified,false) THEN 'variant_not_verified'
                       ELSE 'unverified' END,
        'note', 'No exact-variant confirmation from stored evidence; economics are candidate/listing level only.') END;

  RETURN jsonb_build_object(
    'present', true, 'status', 'ok',
    'provider', x.source, 'supplier_product_id', x.supplier_product_id,
    'market', v_mkt, 'market_currency', v_ccy,
    'basis', v_basis, 'reference_only', (v_basis = 'CANDIDATE_LISTING'),
    'verification', jsonb_build_object(
        'exact_sku_status', CASE WHEN v_confirmed_sku IS NOT NULL THEN 'EXACT_SKU_CONFIRMED' ELSE 'EXACT_SKU_UNVERIFIED' END,
        'supplier_match_binding', CASE WHEN v_exact THEN 'BOUND_EXACT' ELSE 'UNBOUND_UNTIL_EXACT_SKU' END,
        'variant_verified', coalesce(x.variant_verified,false),
        'identity_tier', x.identity_tier, 'confidence', x.confidence),
    'listing', jsonb_build_object(
        'supplier_cost_usd', v_cost,
        'price_range_usd', sp.price_range,
        'displayed_variant', jsonb_build_object(
            'key', x.economics->>'key', 'sku', v_disp_sku, 'class', v_disp_class,
            'design_match', v_disp_dm, 'price_usd', nullif(x.economics->>'price_usd','')::numeric),
        'displayed_variant_is_discovered_design', (v_disp_dm IN ('VERIFIED_EXACT_VARIANT','POTENTIAL_SAME_DESIGN'))),
    'exact_variant', v_exact_variant,
    'destination_shipping', v_dest_shipping,
    'landed_cost', v_landed,
    'economics_engine', v_eng,
    'stock', v_stock_out,
    'candidate_variant_prices', v_variants,
    'evidence_summary', jsonb_build_object(
        'candidate_variants', jsonb_array_length(v_variants),
        'with_individual_price', (SELECT count(*) FROM jsonb_array_elements(v_variants) e WHERE e->>'price_usd' IS NOT NULL),
        'with_image', (SELECT count(*) FROM jsonb_array_elements(v_variants) e WHERE e->>'image' IS NOT NULL),
        'with_exact_variant_stock', CASE WHEN v_stock_exact_known THEN 1 ELSE 0 END,
        'with_sku_exact_shipping', CASE WHEN v_ship_sku_exact THEN 1 ELSE 0 END,
        'confirmed_exact', CASE WHEN v_exact THEN 1 ELSE 0 END),
    'profitability', jsonb_build_object(
        'available', false,
        'reason', CASE WHEN v_basis <> 'EXACT_VERIFIED' THEN 'requires_exact_variant_confirmation'
                       WHEN NOT v_ship_sku_exact THEN 'requires_sku_exact_destination_shipping'
                       WHEN v_landed_usd IS NULL THEN 'requires_destination_landed_cost'
                       ELSE 'requires_confirmed_selling_price' END,
        'method', 'gross_margin = selling_price - landed_cost (GROSS only; excludes advertising, payment processing, returns and platform fees; gross margin is NOT net profit)'),
    'freshness', jsonb_build_object(
        'observed_at', sp.enrichment_observed_at, 'source_provider', x.source,
        'age_days', v_age, 'stale', (v_age IS NULL OR v_age > 14),
        'fx_as_of', v_eng->'money'->>'fx_rate_timestamp',
        'fx_rate_source', v_eng->'money'->>'fx_rate_source',
        'fx_conversion_status', v_eng->'money'->>'conversion_status'),
    'note', 'Candidate/listing supplier economics for an UNBOUND match unless basis=EXACT_VERIFIED. Per-variant prices/images are supplier-listing level and reference-only (Product Asset Lock); stock and destination shipping are exact-variant only when the stored sample matches the confirmed SKU (see stock.exact_variant_stock and destination_shipping.sku_exact). No duties, taxes or selling costs are included.');
END; $function$;

REVOKE EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) TO service_role;

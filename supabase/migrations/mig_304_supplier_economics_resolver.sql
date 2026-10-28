-- ============================================================================
-- mig_304_supplier_economics_resolver.sql
-- STRATELOQ-STAGE5A-SUPPLIER-ECONOMICS-FOUNDATION
--
-- Adds fn_resolve_supplier_economics(p_product, p_market): a read-only, tenant-scoped,
-- supplier-NEUTRAL economics contract that composes a TRUSTWORTHY, clearly-labelled
-- supplier-economics view for a candidate product in a selected destination country,
-- reusing the existing engine and data (no new tables, no provider calls, no asset writes).
--
-- WHY (gap found in Stage 5A verification): economics for an UNBOUND product was surfaced
-- only as the raw CJ "displayed_variant_economics" blob (the cheapest/displayed variant,
-- which for the Old-Man-Face ski mask is "Black Cat with Velvet" — an ANIMAL_FACE /
-- DIFFERENT_DESIGN variant) with no basis/exclusions/freshness/verification labels and a
-- GB-hardcoded shape. This resolver fixes that against the Stage 5A requirements:
--   * basis EXACT_VERIFIED only when the concrete resolution binds the exact SKU AND the
--     identity layer verified the variant; otherwise CANDIDATE_LISTING (reference-only).
--   * destination-GENERIC freight (supplier_enrichment.freight -> <MARKET>), never GB-hardcoded;
--     shipping is NEVER assumed 0 (reuses fn_supplier_economics which fails closed).
--   * landed cost = supplier cost + destination shipping ONLY, with an explicit `excludes`
--     list (duties, taxes, customs, payment, advertising, returns, platform fees) — nothing
--     silently omitted; display-currency conversion via the existing fail-closed FX engine.
--   * per-variant candidate prices are limited to VERIFIED_EXACT / POTENTIAL_SAME_DESIGN
--     variants (DIFFERENT_DESIGN and UNVERIFIED are EXCLUDED, per Stage 4E/5A §4C);
--     the displayed variant carries its own design_match so the UI can caveat it.
--   * freshness: observed_at + age + stale flag; FX as_of/stale carried through.
--   * profitability is withheld (gross-margin method documented) unless a confirmed selling
--     price and exact-variant landed cost exist — no fabricated selling prices; gross != net.
--
-- Preserves: exact-SKU verification (UNBOUND stays CANDIDATE_LISTING), tenant isolation
-- (owner check via auth.uid()), country isolation (per-market), supplier-neutral architecture
-- (provider taken from the stored identity row; CJ only as current data), and Product Asset
-- Lock (read-only; references no image/asset promotion). anon has no EXECUTE.
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

  -- Reuse the canonical engine (fail-closed on missing shipping / FX). No selling price here.
  v_sup_json := jsonb_build_object('supplier_cost', v_cost, 'cost_currency', 'USD',
                  'is_free_shipping', false)
             || CASE WHEN v_ship_known THEN jsonb_build_object('shipping_cost', v_ship) ELSE '{}'::jsonb END;
  v_eng := public.fn_supplier_economics(v_sup_json, NULL, coalesce(v_ccy,'USD'));
  v_landed_usd := nullif(v_eng->>'landed_cost_original','')::numeric;

  -- Displayed variant's own design_match (so economics for a different design can be caveated).
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

  -- Candidate per-variant prices: EXACT / POTENTIAL only (exclude DIFFERENT_DESIGN & UNVERIFIED).
  SELECT coalesce(jsonb_agg(obj ORDER BY obj->>'sku'), '[]'::jsonb) INTO v_variants
  FROM (
    SELECT jsonb_build_object(
      'vid', vc->>'vid', 'sku', vc->>'sku', 'class', vc->>'class',
      'design_match', d.dm,
      'price_usd', (SELECT nullif(e->>'price_usd','')::numeric
                    FROM jsonb_array_elements(coalesce(sp.catalog,'[]'::jsonb)) e
                    WHERE e->>'vid'=vc->>'vid' OR e->>'sku'=vc->>'sku' LIMIT 1),
      'price_basis', 'CANDIDATE_LISTING') AS obj
    FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc
    CROSS JOIN LATERAL (SELECT public.fn_variant_design_match(vc->>'class',
            coalesce((vc->>'corresponds_to_concept')::boolean,false),
            (v_confirmed_sku IS NOT NULL AND vc->>'sku'=v_confirmed_sku),
            coalesce(x.variant_verified,false)) AS dm) d
    WHERE d.dm IN ('VERIFIED_EXACT_VARIANT','POTENTIAL_SAME_DESIGN')
  ) s;

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
    'destination_shipping', CASE WHEN v_ship_known THEN jsonb_build_object(
        'available', true, 'shipping_cost_usd', v_ship, 'currency', 'USD',
        'logistic', v_rep->>'logistic', 'est_min_days', (v_rep->>'est_min_days')::int,
        'est_max_days', (v_rep->>'est_max_days')::int, 'start_country', v_rep->>'destination',
        'source', v_rep->>'source')
      ELSE jsonb_build_object('available', false, 'reason', 'NOT_CALCULATED_FOR_DESTINATION',
        'note', 'No destination-specific supplier freight stored for this country; shipping and landed cost are not asserted (never assumed 0).') END,
    'landed_cost', CASE WHEN v_landed_usd IS NOT NULL THEN jsonb_build_object(
        'available', true, 'total_usd', v_landed_usd, 'currency', 'USD',
        'components', jsonb_build_object('supplier_cost_usd', v_cost, 'shipping_cost_usd', v_ship),
        'display', v_eng->'money',
        'excludes', jsonb_build_array('import_duties','vat_sales_tax','customs_clearance',
                       'payment_processing','advertising','returns','platform_fees'),
        'note', 'Landed = supplier product cost + destination shipping ONLY. Excludes duties, taxes, customs and all selling costs.')
      ELSE jsonb_build_object('available', false, 'reason', coalesce(v_eng->>'reason','landed_not_computable'),
        'excludes', jsonb_build_array('import_duties','vat_sales_tax','customs_clearance',
                       'payment_processing','advertising','returns','platform_fees')) END,
    'economics_engine', v_eng,
    'stock', coalesce(v_stock, jsonb_build_object('state','UNKNOWN')),
    'candidate_variant_prices', v_variants,
    'profitability', jsonb_build_object(
        'available', false,
        'reason', CASE WHEN v_basis <> 'EXACT_VERIFIED' THEN 'requires_exact_variant_confirmation'
                       WHEN v_landed_usd IS NULL THEN 'requires_destination_landed_cost'
                       ELSE 'requires_confirmed_selling_price' END,
        'method', 'gross_margin = selling_price - landed_cost (GROSS only; excludes advertising, payment processing, returns and platform fees; gross margin is NOT net profit)'),
    'freshness', jsonb_build_object(
        'observed_at', sp.enrichment_observed_at, 'source_provider', x.source,
        'age_days', v_age, 'stale', (v_age IS NULL OR v_age > 14),
        'fx_as_of', v_eng->'money'->>'fx_rate_timestamp',
        'fx_rate_source', v_eng->'money'->>'fx_rate_source',
        'fx_conversion_status', v_eng->'money'->>'conversion_status'),
    'note', 'Candidate/listing supplier economics for an UNBOUND match unless basis=EXACT_VERIFIED. Figures are supplier-listing level (the displayed variant may be a different design — see listing.displayed_variant.design_match) and are NOT exact-variant verified. No duties, taxes or selling costs are included. Reference-only; does not affect Product Asset Lock or commercial eligibility.');
END; $function$;

REVOKE EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) TO service_role;

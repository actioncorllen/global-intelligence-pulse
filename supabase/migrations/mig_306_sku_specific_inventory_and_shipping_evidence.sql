-- ============================================================================
-- mig_306_sku_specific_inventory_and_shipping_evidence.sql
-- STRATELOQ-STAGE5C-EXACT-VARIANT-INVENTORY-AND-DESTINATION-SHIPPING
--
-- Builds the SKU-specific supplier-evidence path on top of Stage 5A (mig_304,
-- 5d4e3e4) and Stage 5B (mig_305, 3960c77). Supplier-neutral, read/validate only
-- against the existing CJ adapter; NO provider calls in SQL; NO new provider; NO
-- asset writes. Reuses the existing CJ enrichment write path semantics.
--
-- CJ INTEGRATION (verified): the existing CJ adapter already calls variant/SKU-level
-- endpoints — product/stock/queryByVid (per-vid warehouse inventory) and
-- logistic/freightCalculate (products:[{vid}] + endCountryCode). The only gap was
-- that enrichment sampled ONE representative variant (the cheapest/displayed), so
-- stock and freight were stored listing-level, not per confirmed SKU. The single DB
-- write path is fn_ingest_cj_product_media (jsonb '||' merge into supplier_enrichment).
--
-- THIS MIGRATION ADDS:
--   1. fn_ingest_cj_variant_evidence(...) — targeted, service-role-only writer that
--      stores SKU-specific inventory and destination shipping under
--      supplier_enrichment.variant_evidence.by_vid[<vid>], WITHOUT overwriting the
--      listing-level freight/stock. Full provenance (provider, supplier_product_id,
--      vid, sku, warehouse, qty, timestamp for inventory; + vid/sku, destination,
--      origin, method, cost, currency, est delivery, timestamp for shipping).
--      Provider-response validation (vid must exist in the stored variant_catalog;
--      sku must match that vid — associations are never inferred). Fail-closed:
--      missing/zero/error data is stored as UNKNOWN / available=false (never 0, never
--      free), and a provider error NEVER overwrites a previously-valid value.
--   2. fn_cj_variant_evidence_is_fresh(...) — service-role freshness/dedup helper the
--      n8n adapter calls BEFORE a live CJ request, so repeat requests reuse valid
--      cache instead of re-billing the provider.
--   3. fn_resolve_supplier_economics(...) — extended to PREFER per-SKU evidence:
--      exact_variant_stock and SKU-exact destination shipping come from
--      variant_evidence.by_vid[confirmed vid] when present; otherwise the Stage 5B
--      listing-sampled behavior is retained. candidate_variant_prices now carry each
--      variant's own per-SKU stock/shipping evidence (when present) and a reduced
--      missing_evidence list.
--
-- INDEPENDENCE (Stage 5C §5): a successful inventory/shipping quote NEVER sets
-- variant_verified or creates a bound concrete resolution. Identity, inventory,
-- shipping and media rights stay separate. An unverified variant may carry a valid
-- SKU-specific quote yet remain UNBOUND / CANDIDATE_LISTING.
--
-- Preserves: FX/shipping fail-closed, explicit excludes, freshness + FX provenance,
-- profitability withheld, tenant isolation (auth.uid()), country isolation (GB freight
-- never reused for another destination), supplier-neutral architecture and Product
-- Asset Lock (supplier imagery stays reference-only). anon has no EXECUTE on any of these.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. SKU-specific evidence writer (service-role only; invoked by the CJ n8n adapter)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ingest_cj_variant_evidence(
    p_pid text, p_vid text, p_sku text, p_market text,
    p_inventory jsonb DEFAULT NULL, p_shipping jsonb DEFAULT NULL,
    p_observed_at timestamptz DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_catalog jsonb; v_cat jsonb; v_sku text; v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_se jsonb; v_vid_obj jsonb; v_existing jsonb;
  v_inv_state text; v_inv_store jsonb; v_inv_is_error boolean := false; v_inv_written boolean := false;
  v_ship_store jsonb; v_ship_is_error boolean := false; v_ship_written boolean := false;
  v_ship_map jsonb; v_cost numeric;
BEGIN
  IF p_pid IS NULL OR btrim(p_pid)='' OR p_vid IS NULL OR btrim(p_vid)='' THEN
    RETURN jsonb_build_object('status','bad_request','reason','pid_and_vid_required'); END IF;

  SELECT supplier_enrichment, coalesce(supplier_enrichment->'variant_catalog','[]'::jsonb)
    INTO v_se, v_catalog
  FROM public.commerce_supplier_products
  WHERE source='cjdropshipping' AND source_product_id=p_pid LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','supplier_product_not_found','pid',p_pid); END IF;

  -- Provider-response validation: vid must exist in the stored catalog; sku must match.
  SELECT c INTO v_cat FROM jsonb_array_elements(v_catalog) c WHERE c->>'vid'=p_vid LIMIT 1;
  IF v_cat IS NULL THEN
    RETURN jsonb_build_object('status','unknown_variant','pid',p_pid,'vid',p_vid); END IF;
  IF p_sku IS NOT NULL AND btrim(p_sku)<>'' AND (v_cat->>'sku') IS DISTINCT FROM p_sku THEN
    RETURN jsonb_build_object('status','sku_vid_mismatch','vid',p_vid,
      'expected_sku', v_cat->>'sku','received_sku',p_sku); END IF;
  v_sku := coalesce(v_cat->>'sku', p_sku);

  v_se := coalesce(v_se,'{}'::jsonb);
  v_existing := v_se->'variant_evidence'->'by_vid'->p_vid;
  v_vid_obj := coalesce(v_existing,'{}'::jsonb) || jsonb_build_object('vid',p_vid,'sku',v_sku);

  -- ---- Inventory (per vid) ----------------------------------------------------
  IF p_inventory IS NOT NULL THEN
    v_inv_state := upper(btrim(coalesce(p_inventory->>'state','')));
    IF (p_inventory ? 'error') OR v_inv_state='' OR v_inv_state='UNKNOWN' THEN
      v_inv_is_error := true;
      v_inv_store := jsonb_build_object('state','UNKNOWN',
        'reason', coalesce(p_inventory->>'error', p_inventory->>'reason','NO_STATE'),
        'observed_at', p_observed_at, 'provider','cjdropshipping',
        'supplier_product_id',p_pid,'vid',p_vid,'sku',v_sku,'source','CJ_STOCK_QUERY_BY_VID');
    ELSE
      v_inv_store := jsonb_build_object('state', v_inv_state, 'reason', p_inventory->>'reason',
        'cj_warehouse_inventory', nullif(p_inventory->>'cj_inventory','')::numeric,
        'factory_inventory', nullif(p_inventory->>'factory_inventory','')::numeric,
        'warehouses', coalesce(p_inventory->'warehouses','[]'::jsonb),
        'immediately_available', (v_inv_state='IN_STOCK'),
        'observed_at', p_observed_at, 'provider','cjdropshipping',
        'supplier_product_id',p_pid,'vid',p_vid,'sku',v_sku,'source','CJ_STOCK_QUERY_BY_VID');
    END IF;
    -- never overwrite a previously valid inventory with an error/unknown
    IF v_inv_is_error AND v_existing IS NOT NULL
       AND upper(coalesce(v_existing->'inventory'->>'state','UNKNOWN'))<>'UNKNOWN' THEN
      v_vid_obj := v_vid_obj || jsonb_build_object('inventory', v_existing->'inventory',
                                                   'inventory_last_error', v_inv_store);
    ELSE
      v_vid_obj := v_vid_obj || jsonb_build_object('inventory', v_inv_store);
      v_inv_written := NOT v_inv_is_error;
    END IF;
  END IF;

  -- ---- Destination shipping (per vid, per market) -----------------------------
  IF p_shipping IS NOT NULL THEN
    IF v_mkt='' THEN RETURN jsonb_build_object('status','bad_request','reason','market_required_for_shipping'); END IF;
    v_cost := nullif(p_shipping->>'shipping_cost_usd','')::numeric;
    IF (p_shipping ? 'error') OR v_cost IS NULL THEN
      v_ship_is_error := true;
      v_ship_store := jsonb_build_object('available', false,
        'reason', coalesce(p_shipping->>'error', p_shipping->>'reason','NOT_CALCULATED_FOR_DESTINATION'),
        'destination', v_mkt, 'observed_at', p_observed_at, 'provider','cjdropshipping',
        'supplier_product_id',p_pid,'vid',p_vid,'sku',v_sku,'source','CJ_FREIGHT_CALCULATE');
    ELSE
      v_ship_store := jsonb_build_object('available', true, 'shipping_cost_usd', v_cost,
        'currency', coalesce(nullif(p_shipping->>'currency',''),'USD'),
        'logistic', p_shipping->>'logistic',
        'est_min_days', nullif(p_shipping->>'est_min_days','')::int,
        'est_max_days', nullif(p_shipping->>'est_max_days','')::int,
        'start_country', p_shipping->>'start_country', 'destination', v_mkt,
        'method', coalesce(p_shipping->>'method','freightCalculate'),
        'options_count', nullif(p_shipping->>'options_count','')::int,
        'observed_at', p_observed_at, 'provider','cjdropshipping',
        'supplier_product_id',p_pid,'vid',p_vid,'sku',v_sku,'source','CJ_FREIGHT_CALCULATE');
    END IF;
    v_ship_map := coalesce(v_vid_obj->'shipping','{}'::jsonb);
    -- never overwrite a previously valid quote for this market with an error/unavailable
    IF v_ship_is_error AND coalesce((v_ship_map->v_mkt->>'available')::boolean,false) THEN
      v_ship_map := v_ship_map || jsonb_build_object(v_mkt||'_last_error', v_ship_store);
    ELSE
      v_ship_map := v_ship_map || jsonb_build_object(v_mkt, v_ship_store);
      v_ship_written := NOT v_ship_is_error;
    END IF;
    v_vid_obj := v_vid_obj || jsonb_build_object('shipping', v_ship_map);
  END IF;

  -- ---- Store under variant_evidence.by_vid[vid] (preserve siblings + listing data)
  v_se := jsonb_set(v_se, '{variant_evidence}', coalesce(v_se->'variant_evidence','{}'::jsonb), true);
  v_se := jsonb_set(v_se, '{variant_evidence,by_vid}', coalesce(v_se->'variant_evidence'->'by_vid','{}'::jsonb), true);
  v_se := jsonb_set(v_se, array['variant_evidence','by_vid',p_vid], v_vid_obj, true);

  UPDATE public.commerce_supplier_products
     SET supplier_enrichment = v_se, last_seen_at = now()
   WHERE source='cjdropshipping' AND source_product_id=p_pid;

  RETURN jsonb_build_object('status','ok','pid',p_pid,'vid',p_vid,'sku',v_sku,'market',nullif(v_mkt,''),
    'inventory_written', v_inv_written, 'inventory_error', v_inv_is_error,
    'shipping_written', v_ship_written, 'shipping_error', v_ship_is_error,
    'observed_at', p_observed_at);
END; $function$;

-- service-role only (the CJ n8n adapter writes as service_role). The explicit
-- `authenticated` revoke is required because Supabase default privileges grant
-- EXECUTE to `authenticated` on new public functions at CREATE time.
REVOKE EXECUTE ON FUNCTION public.fn_ingest_cj_variant_evidence(text,text,text,text,jsonb,jsonb,timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_ingest_cj_variant_evidence(text,text,text,text,jsonb,jsonb,timestamptz) FROM anon;
REVOKE EXECUTE ON FUNCTION public.fn_ingest_cj_variant_evidence(text,text,text,text,jsonb,jsonb,timestamptz) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_ingest_cj_variant_evidence(text,text,text,text,jsonb,jsonb,timestamptz) TO service_role;

-- ----------------------------------------------------------------------------
-- 2. Freshness / dedup helper (service-role; the n8n adapter checks this first)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_cj_variant_evidence_is_fresh(
    p_pid text, p_vid text, p_market text, p_max_age_hours int DEFAULT 24)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_ev jsonb; v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_inv_obs timestamptz; v_ship_obs timestamptz; v_inv_age numeric; v_ship_age numeric;
  v_inv_fresh boolean; v_ship_fresh boolean;
BEGIN
  SELECT supplier_enrichment->'variant_evidence'->'by_vid'->p_vid INTO v_ev
  FROM public.commerce_supplier_products
  WHERE source='cjdropshipping' AND source_product_id=p_pid LIMIT 1;

  v_inv_obs := nullif(v_ev->'inventory'->>'observed_at','')::timestamptz;
  v_ship_obs := nullif(v_ev->'shipping'->v_mkt->>'observed_at','')::timestamptz;
  v_inv_age  := CASE WHEN v_inv_obs IS NULL THEN NULL ELSE round((EXTRACT(EPOCH FROM (now()-v_inv_obs))/3600.0)::numeric,2) END;
  v_ship_age := CASE WHEN v_ship_obs IS NULL THEN NULL ELSE round((EXTRACT(EPOCH FROM (now()-v_ship_obs))/3600.0)::numeric,2) END;
  v_inv_fresh  := (v_inv_age IS NOT NULL AND v_inv_age <= p_max_age_hours);
  v_ship_fresh := (v_ship_age IS NOT NULL AND v_ship_age <= p_max_age_hours);

  RETURN jsonb_build_object(
    'present', (v_ev IS NOT NULL), 'pid', p_pid, 'vid', p_vid, 'market', nullif(v_mkt,''),
    'max_age_hours', p_max_age_hours,
    'inventory_observed_at', v_inv_obs, 'inventory_age_hours', v_inv_age, 'inventory_fresh', v_inv_fresh,
    'shipping_observed_at', v_ship_obs, 'shipping_age_hours', v_ship_age, 'shipping_fresh', v_ship_fresh,
    'needs_inventory_refresh', NOT v_inv_fresh,
    'needs_shipping_refresh', NOT v_ship_fresh);
END; $function$;

REVOKE EXECUTE ON FUNCTION public.fn_cj_variant_evidence_is_fresh(text,text,text,int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_cj_variant_evidence_is_fresh(text,text,text,int) FROM anon;
REVOKE EXECUTE ON FUNCTION public.fn_cj_variant_evidence_is_fresh(text,text,text,int) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_cj_variant_evidence_is_fresh(text,text,text,int) TO service_role;

-- ----------------------------------------------------------------------------
-- 3. Resolver: prefer per-SKU evidence; otherwise retain Stage 5B listing-sampled.
-- ----------------------------------------------------------------------------
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
  v_rep jsonb; v_ship_rep numeric; v_rep_known boolean; v_cost numeric;
  v_sup_json jsonb; v_eng jsonb; v_landed_usd numeric;
  v_disp_sku text; v_disp record; v_disp_dm text; v_disp_class text;
  v_variants jsonb; v_stock jsonb; v_age numeric;
  v_stock_svid text; v_ship_svid text; v_stock_sclass text; v_ship_sclass text;
  v_conf_vid text; v_conf_price numeric; v_conf_image text; v_conf_weight numeric;
  v_conf_inv jsonb; v_conf_ship jsonb;
  v_ship_rec jsonb; v_ship numeric; v_ship_known boolean; v_ship_sku_exact boolean;
  v_stock_out jsonb; v_exact_stock jsonb; v_stock_exact_known boolean;
  v_exact_variant jsonb; v_landed jsonb; v_imm_avail boolean;
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
         coalesce(supplier_enrichment->'variant_evidence'->'by_vid','{}'::jsonb) AS vev,
         nullif(btrim(coalesce(raw->>'sell_price_range_usd', supplier_enrichment->>'sell_price_range_usd','')),'') AS price_range
    INTO sp
  FROM public.commerce_supplier_products
  WHERE source = x.source AND source_product_id = x.supplier_product_id LIMIT 1;

  v_cost := sp.supplier_cost;
  v_stock := sp.stock;
  v_age := round((EXTRACT(EPOCH FROM (now() - sp.enrichment_observed_at))/86400.0)::numeric, 1);

  -- Listing-sampled freight (Stage 5B): destination-generic; shipping never assumed 0.
  v_rep := sp.freight -> v_mkt -> 'representative';
  IF v_rep IS NOT NULL THEN
    v_ship_rep := nullif(btrim(coalesce(v_rep->>'shipping_cost','')),'')::numeric;
    v_rep_known := v_ship_rep IS NOT NULL;
  ELSE v_rep_known := false; END IF;

  v_stock_svid := v_stock->>'sampled_vid';
  v_ship_svid  := v_rep->>'sampled_vid';
  SELECT vc->>'class' INTO v_stock_sclass
    FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc
    WHERE vc->>'vid' = v_stock_svid LIMIT 1;
  SELECT vc->>'class' INTO v_ship_sclass
    FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc
    WHERE vc->>'vid' = v_ship_svid LIMIT 1;

  -- Confirmed variant catalog + per-SKU evidence (Stage 5C).
  IF v_confirmed_sku IS NOT NULL THEN
    SELECT c->>'vid', nullif(c->>'price_usd','')::numeric, c->>'image', nullif(c->>'weight_g','')::numeric
      INTO v_conf_vid, v_conf_price, v_conf_image, v_conf_weight
      FROM jsonb_array_elements(coalesce(sp.catalog,'[]'::jsonb)) c
      WHERE c->>'sku' = v_confirmed_sku LIMIT 1;
    v_conf_inv  := sp.vev -> v_conf_vid -> 'inventory';
    v_conf_ship := sp.vev -> v_conf_vid -> 'shipping' -> v_mkt;
  END IF;

  -- ---- Destination shipping: prefer per-SKU quote, then SKU-exact sample, else listing
  IF v_exact AND v_conf_ship IS NOT NULL AND coalesce((v_conf_ship->>'available')::boolean,false) THEN
    v_ship_rec := v_conf_ship || jsonb_build_object('sku_exact', true, 'basis','SKU_EXACT','evidence','PER_VARIANT_QUOTE');
  ELSIF v_rep_known THEN
    v_ship_rec := jsonb_build_object(
      'available', true, 'shipping_cost_usd', v_ship_rep, 'currency','USD',
      'logistic', v_rep->>'logistic', 'est_min_days', (v_rep->>'est_min_days')::int,
      'est_max_days', (v_rep->>'est_max_days')::int, 'destination', v_rep->>'destination',
      'method', v_rep->>'method', 'source', v_rep->>'source', 'observed_at', sp.enrichment_observed_at,
      'sampled_vid', v_ship_svid, 'sampled_variant_class', v_ship_sclass,
      'sku_exact', (v_exact AND v_ship_svid IS NOT NULL AND v_ship_svid = v_conf_vid),
      'basis', CASE WHEN v_exact AND v_ship_svid = v_conf_vid THEN 'SKU_EXACT' ELSE 'LISTING_SAMPLED' END,
      'evidence','LISTING_SAMPLE',
      'note', CASE WHEN v_exact AND v_ship_svid = v_conf_vid
               THEN 'Listing freight sample happens to be the confirmed SKU.'
               ELSE 'Listing-level freight sampled on another variant ('||coalesce(v_ship_sclass,'unknown class')||'); representative only, not quoted for the confirmed SKU.' END);
  ELSE
    v_ship_rec := jsonb_build_object('available', false, 'reason','NOT_CALCULATED_FOR_DESTINATION',
      'note','No destination-specific supplier freight stored for this country; shipping and landed cost are not asserted (never assumed 0).');
  END IF;
  v_ship        := nullif(v_ship_rec->>'shipping_cost_usd','')::numeric;
  v_ship_known  := coalesce((v_ship_rec->>'available')::boolean,false);
  v_ship_sku_exact := coalesce((v_ship_rec->>'sku_exact')::boolean,false);

  -- ---- Exact-variant stock: prefer per-SKU evidence, then SKU-exact listing sample
  IF v_exact AND v_conf_inv IS NOT NULL AND coalesce(v_conf_inv->>'state','') <> '' THEN
    v_stock_exact_known := true;
    v_exact_stock := v_conf_inv || jsonb_build_object('known', true, 'evidence','PER_VARIANT_QUERY');
  ELSIF v_exact AND v_stock_svid IS NOT NULL AND v_stock_svid = v_conf_vid THEN
    v_stock_exact_known := true;
    v_exact_stock := jsonb_build_object('known', true, 'vid', v_conf_vid, 'sku', v_confirmed_sku,
        'state', v_stock->>'state', 'cj_warehouse_inventory', (v_stock->>'cj_inventory'),
        'factory_inventory', (v_stock->>'factory_inventory'),
        'immediately_available', (upper(coalesce(v_stock->>'state',''))='IN_STOCK'),
        'evidence','LISTING_SAMPLE_MATCHES_SKU');
  ELSE
    v_stock_exact_known := false;
    v_exact_stock := jsonb_build_object('known', false, 'state','UNKNOWN',
        'reason', CASE WHEN v_exact THEN 'NOT_SAMPLED_FOR_CONFIRMED_VARIANT' ELSE 'NO_CONFIRMED_VARIANT' END,
        'note','Supplier stock was not sampled on this exact variant; per-variant inventory is unknown and is not inferred from another variant.');
  END IF;
  v_imm_avail := (upper(coalesce(v_stock->>'state','')) = 'IN_STOCK');

  v_stock_out := jsonb_build_object(
    'exact_variant_stock', v_exact_stock,
    'listing_stock_sampled', CASE WHEN v_stock IS NULL THEN jsonb_build_object('state','UNKNOWN')
        ELSE jsonb_build_object(
            'state', v_stock->>'state', 'reason', v_stock->>'reason',
            'sampled_vid', v_stock_svid, 'sampled_variant_class', v_stock_sclass,
            'cj_warehouse_inventory', (v_stock->>'cj_inventory'),
            'factory_inventory', (v_stock->>'factory_inventory'),
            'immediately_available', v_imm_avail,
            'note', 'Listing-level stock sampled on one variant; factory replenishment availability is NOT immediate stock.') END,
    'observed_at', sp.enrichment_observed_at);

  -- ---- Landed cost (fail-closed). Exact uses confirmed price + SKU-exact shipping only.
  v_sup_json := jsonb_build_object(
                  'supplier_cost', CASE WHEN v_exact AND v_conf_price IS NOT NULL THEN v_conf_price ELSE v_cost END,
                  'cost_currency', 'USD', 'is_free_shipping', false)
             || CASE WHEN (CASE WHEN v_exact THEN v_ship_sku_exact ELSE v_ship_known END) AND v_ship IS NOT NULL
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

  -- ---- Candidate per-variant prices + per-SKU evidence (EXACT / POTENTIAL only) --
  SELECT coalesce(jsonb_agg(obj ORDER BY obj->>'sku'), '[]'::jsonb) INTO v_variants
  FROM (
    SELECT jsonb_build_object(
      'vid', vc->>'vid', 'sku', vc->>'sku', 'class', vc->>'class',
      'design_match', d.dm,
      'price_usd', c.price_usd, 'price_currency', 'USD', 'weight_g', c.weight_g,
      'image', c.image, 'image_rights', 'REFERENCE_ONLY', 'price_basis', 'CANDIDATE_LISTING',
      'verification_status', CASE WHEN v_exact AND vc->>'sku'=v_confirmed_sku
                                  THEN 'CONFIRMED_EXACT' ELSE 'UNVERIFIED_CANDIDATE' END,
      'stock', coalesce(pe->'inventory', jsonb_build_object('state','UNKNOWN','known',false)),
      'destination_shipping', coalesce(pe->'shipping'->v_mkt,
          jsonb_build_object('available',false,'reason','NOT_CALCULATED_FOR_DESTINATION')),
      'missing_evidence',
        (CASE WHEN v_confirmed_sku IS NULL OR vc->>'sku' <> v_confirmed_sku
              THEN jsonb_build_array('exact_sku_confirmation') ELSE '[]'::jsonb END)
     || (CASE WHEN (pe->'inventory' IS NULL) AND (v_stock_svid IS DISTINCT FROM vc->>'vid')
              THEN jsonb_build_array('per_variant_stock') ELSE '[]'::jsonb END)
     || (CASE WHEN (pe->'shipping'->v_mkt IS NULL) AND (v_ship_svid IS DISTINCT FROM vc->>'vid')
              THEN jsonb_build_array('per_variant_destination_shipping') ELSE '[]'::jsonb END)
      ) AS obj
    FROM jsonb_array_elements(coalesce(x.variant_classifications,'[]'::jsonb)) vc
    CROSS JOIN LATERAL (SELECT public.fn_variant_design_match(vc->>'class',
            coalesce((vc->>'corresponds_to_concept')::boolean,false),
            (v_confirmed_sku IS NOT NULL AND vc->>'sku'=v_confirmed_sku),
            coalesce(x.variant_verified,false)) AS dm) d
    LEFT JOIN LATERAL (
        SELECT nullif(e->>'price_usd','')::numeric AS price_usd,
               nullif(e->>'weight_g','')::numeric AS weight_g, e->>'image' AS image
        FROM jsonb_array_elements(coalesce(sp.catalog,'[]'::jsonb)) e
        WHERE e->>'vid'=vc->>'vid' OR e->>'sku'=vc->>'sku' LIMIT 1) c ON true
    LEFT JOIN LATERAL (SELECT sp.vev -> (vc->>'vid') AS pe) pev ON true
    WHERE d.dm IN ('VERIFIED_EXACT_VARIANT','POTENTIAL_SAME_DESIGN')
  ) s;

  v_exact_variant := CASE WHEN v_exact THEN jsonb_build_object(
        'confirmed', true, 'sku', v_confirmed_sku, 'vid', v_conf_vid,
        'price_usd', v_conf_price, 'price_currency', 'USD',
        'image', v_conf_image, 'image_rights', 'REFERENCE_ONLY', 'weight_g', v_conf_weight,
        'stock', v_exact_stock, 'destination_shipping', v_ship_rec)
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
    'destination_shipping', v_ship_rec,
    'landed_cost', v_landed,
    'economics_engine', v_eng,
    'stock', v_stock_out,
    'candidate_variant_prices', v_variants,
    'evidence_summary', jsonb_build_object(
        'candidate_variants', jsonb_array_length(v_variants),
        'with_individual_price', (SELECT count(*) FROM jsonb_array_elements(v_variants) e WHERE e->>'price_usd' IS NOT NULL),
        'with_image', (SELECT count(*) FROM jsonb_array_elements(v_variants) e WHERE e->>'image' IS NOT NULL),
        'with_per_variant_stock_evidence', (SELECT count(*) FROM jsonb_array_elements(v_variants) e WHERE coalesce((e->'stock'->>'known')::boolean,false) OR (e->'stock'->>'state') IS DISTINCT FROM 'UNKNOWN'),
        'with_per_variant_shipping_evidence', (SELECT count(*) FROM jsonb_array_elements(v_variants) e WHERE coalesce((e->'destination_shipping'->>'available')::boolean,false)),
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
        'exact_variant_stock_observed_at', v_conf_inv->>'observed_at',
        'sku_exact_shipping_observed_at', v_conf_ship->>'observed_at',
        'fx_as_of', v_eng->'money'->>'fx_rate_timestamp',
        'fx_rate_source', v_eng->'money'->>'fx_rate_source',
        'fx_conversion_status', v_eng->'money'->>'conversion_status'),
    'note', 'Candidate/listing supplier economics for an UNBOUND match unless basis=EXACT_VERIFIED. Per-variant prices/images are supplier-listing level and reference-only (Product Asset Lock). Stock and destination shipping are exact-variant only when per-SKU evidence exists for the confirmed SKU (see exact_variant / destination_shipping.sku_exact); a SKU-specific quote never verifies product identity. No duties, taxes or selling costs are included.');
END; $function$;

REVOKE EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_resolve_supplier_economics(uuid, text) TO service_role;

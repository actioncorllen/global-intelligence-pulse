-- =====================================================================================
-- PULSE-ECOM-CJ-STOCK-BY-VID-001 (repo mirror of mig_219)
-- Applied to Supabase project nxaunmyihhjixxxljcqt.
--
-- Completes the CJ supplier VERIFIED-STOCK hard gate by reusing the existing CJ
-- /product/stock/queryByVid endpoint (proven in the P4 probe ZbhPyAuvDD4h4xid) — added as an
-- additive branch off "Pick Variant" in the existing detail workflow OxH9sb6jKCqiqXOk
-- (CJ Stock -> Normalize Stock), leaving product-detail + destination-freight behaviour intact.
-- Credential "CJ Dropshipping API" (id 2IV5tXPu9jAItjKh) reused; token never printed.
--
-- fn_cj_normalize_stock normalizes the queryByVid `data` array into IN_STOCK / OUT_OF_STOCK /
-- UNKNOWN. Ready-to-ship = cjInventoryNum (CJ warehouse). factoryInventoryNum is
-- replenishable-only and never counts as immediately fulfillable. Missing/empty/error data ->
-- UNKNOWN (never IN_STOCK). Aggregates across warehouse/variant rows: any CJ-warehouse stock
-- -> IN_STOCK (a product is not OUT_OF_STOCK merely because one warehouse is empty).
--
-- Verified against real CJ data (execution 30133):
--   jewelry box vid 2609070153091625901: cj=0 factory=9567 -> OUT_OF_STOCK (China Warehouse, CN)
--   leather patch vid 2608261145001631600: cj=0 factory=8631 -> OUT_OF_STOCK
--   IN_STOCK logic test (cj=120)          -> IN_STOCK
--   multi-warehouse (US cj0 + CN cj40)    -> IN_STOCK (aggregation)
--   empty []                              -> UNKNOWN
-- Freight + supplier_product_assets (mig_218) unaffected. No fabricated stock.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.fn_cj_normalize_stock(p_data jsonb)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE cj numeric:=0; fac numeric:=0; tot numeric:=0; n int:=0; w jsonb; whs jsonb:='[]'::jsonb;
  st text; reason text;
BEGIN
  IF p_data IS NULL OR jsonb_typeof(p_data)<>'array' OR jsonb_array_length(p_data)=0 THEN
    RETURN jsonb_build_object('stock_state','UNKNOWN','reason','NO_WAREHOUSE_ROWS',
      'cj_inventory',0,'factory_inventory',0,'total_inventory',0,'warehouses','[]'::jsonb,
      'source','CJ_STOCK_QUERY_BY_VID');
  END IF;
  FOR w IN SELECT * FROM jsonb_array_elements(p_data) LOOP
    n := n+1;
    cj  := cj  + coalesce((w->>'cjInventoryNum')::numeric,0);
    fac := fac + coalesce((w->>'factoryInventoryNum')::numeric,0);
    tot := tot + coalesce((w->>'totalInventoryNum')::numeric, (w->>'storageNum')::numeric, 0);
    whs := whs || jsonb_build_array(jsonb_build_object(
      'warehouse', w->>'areaEn', 'country', w->>'countryCode', 'vid', w->>'vid',
      'cj_inventory', coalesce((w->>'cjInventoryNum')::numeric,0),
      'factory_inventory', coalesce((w->>'factoryInventoryNum')::numeric,0),
      'total_inventory', coalesce((w->>'totalInventoryNum')::numeric,(w->>'storageNum')::numeric,0)));
  END LOOP;
  IF cj > 0 THEN st:='IN_STOCK'; reason:='CJ_WAREHOUSE_READY_TO_SHIP';
  ELSIF fac > 0 THEN st:='OUT_OF_STOCK'; reason:='ZERO_CJ_WAREHOUSE_FACTORY_REPLENISHABLE_ONLY';
  ELSE st:='OUT_OF_STOCK'; reason:='VERIFIED_ZERO_ALL_LOCATIONS'; END IF;
  RETURN jsonb_build_object('stock_state',st,'reason',reason,
    'cj_inventory',cj,'factory_inventory',fac,'total_inventory',tot,
    'warehouses',whs,'source','CJ_STOCK_QUERY_BY_VID');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_cj_normalize_stock(jsonb) FROM PUBLIC, anon;

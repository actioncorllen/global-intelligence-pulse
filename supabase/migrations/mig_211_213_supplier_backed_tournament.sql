-- =====================================================================================
-- PULSE-ECOM-SUPPLIER-BACKED-MULTI-PRODUCT-TOURNAMENT-001
-- Repo mirror of migrations applied to Supabase project nxaunmyihhjixxxljcqt:
--   mig_211b  fn_supplier_backed_scan          (read-only discovery funnel)
--   mig_212   fn_resolve_supplier_identity     (defect fix: tighten CLOSE_COMPARABLE)
--   mig_213   fn_resolve_supplier_identity     (defect fix: generic-token guard)
--
-- Proves the Supplier Product Asset Contract inside REAL opportunity discovery:
-- start from real CJdropshipping catalog products (SUPPLY_ONLY -- supplier availability
-- alone never creates an opportunity), pre-filter on supplier signals, then demand-
-- validate independently against real eBay market observations through the canonical
-- identity resolver. Founder-only; nothing published to Pulse customers.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- fn_resolve_supplier_identity (final: mig_213)
-- Canonical identity classes EXACT_PRODUCT / CLOSE_COMPARABLE / CATEGORY_MATCH /
-- UNRELATED / UNKNOWN. EXACT_PRODUCT requires a shared product identifier and is never
-- granted from free-text title alone. CLOSE_COMPARABLE requires token overlap >= 0.5 AND
-- >= 2 shared tokens AND >= 1 shared NON-GENERIC (product-discriminating) token --
-- generic category/material/placement co-occurrence (e.g. "desk organizer", "mirror",
-- "aluminium", "seat") is NEVER product identity. This implements the LOCKED principle:
-- "Do not attach generic category popularity to an exact CJ product and present it as
--  exact-product demand."
-- Defect history (founder git rule #21: STOP -> FIX -> REGRESSION -> RESTART):
--   mig_212 removed a 0.34 single-token CLOSE tier that produced false matches
--           (pet water fountain -> stainless-steel necklace; watch winder -> watch hands).
--   mig_213 added the non-generic-token requirement after the supplier-backed scan
--           surfaced generic-category false matches (wooden desk organizer -> Skull
--           Eyeglasses Holder; aluminium laptop stand -> Foldable Camping Table).
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_supplier_identity(
  p_cand_title text, p_cand_category text, p_cand_ident text,
  p_sup_title text, p_sup_category text, p_sup_ref text,
  p_shared_identifier boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
DECLARE
  ct text[]; st text[]; inter int; ngshared int; base int; overlap numeric;
  cls text; conf text; cn text; sn text;
  generic_arr text[] := ARRAY[
    'holder','stand','organizer','organiser','case','box','tray','rack','storage',
    'mount','bracket','dish','bowl','cover','bag','pouch','basket','bin','caddy',
    'shelf','hook','hanger','clip','strap',
    'set','kit','pack','piece','pieces','pcs','bundle','lot','pair',
    'desk','table','wall','door','floor','car','seat','back','front','side','top',
    'home','office','kitchen','bathroom','bedroom','living','outdoor','indoor','travel','portable',
    'adjustable','foldable','folding','collapsible','mini','small','large','big',
    'multi','multifunction','multifunctional','universal','premium','luxury','deluxe',
    'new','hot','cute','fashion','fashionable','creative','simple','modern','nordic',
    'aluminium','aluminum','steel','stainless','metal','plastic','wooden','wood',
    'silicone','leather','glass','ceramic','fabric','cotton','rubber'
  ];
BEGIN
  IF p_cand_title IS NULL OR p_sup_title IS NULL THEN
    RETURN jsonb_build_object('match_class','UNKNOWN','match_confidence','NONE',
      'matching_evidence',jsonb_build_object('reason','missing_title'));
  END IF;
  cn := lower(p_cand_title||' '||coalesce(p_cand_category,''));
  sn := lower(p_sup_title||' '||coalesce(p_sup_category,''));
  cn := regexp_replace(cn, 'night[ -]?light', 'nightlight', 'g'); sn := regexp_replace(sn, 'night[ -]?light', 'nightlight', 'g');
  cn := regexp_replace(cn, 'projection', 'projector', 'g');       sn := regexp_replace(sn, 'projection', 'projector', 'g');
  cn := regexp_replace(cn, 'children|child|toddler|baby', 'kids', 'g'); sn := regexp_replace(sn, 'children|child|toddler|baby', 'kids', 'g');
  ct := public.fn_text_tokens(cn); st := public.fn_text_tokens(sn);
  SELECT count(*) INTO inter    FROM (SELECT unnest(ct) INTERSECT SELECT unnest(st)) x;
  SELECT count(*) INTO ngshared FROM (SELECT unnest(ct) INTERSECT SELECT unnest(st)) y(tok)
    WHERE y.tok <> ALL (generic_arr);
  base := greatest(cardinality(ct),1);
  overlap := round(inter::numeric/base, 3);
  IF p_shared_identifier THEN
    cls := 'EXACT_PRODUCT'; conf := 'HIGH';
  ELSIF overlap >= 0.5 AND inter >= 2 AND ngshared >= 1 THEN
    cls := 'CLOSE_COMPARABLE'; conf := CASE WHEN overlap>=0.7 THEN 'MEDIUM' ELSE 'LOW' END;
  ELSIF inter >= 2 AND p_cand_category IS NOT NULL AND lower(p_cand_category)=lower(p_sup_category) THEN
    cls := 'CATEGORY_MATCH'; conf := 'LOW';
  ELSE
    cls := 'UNRELATED'; conf := 'NONE';
  END IF;
  RETURN jsonb_build_object('match_class', cls, 'match_confidence', conf,
    'matching_evidence', jsonb_build_object(
      'token_overlap', overlap, 'shared_tokens', inter, 'nongeneric_shared_tokens', ngshared,
      'shared_identifier', p_shared_identifier,
      'candidate_ref', p_cand_ident, 'supplier_product_ref', p_sup_ref,
      'note','EXACT requires a shared product identifier; CLOSE requires overlap>=0.5 AND >=2 shared tokens AND >=1 shared NON-GENERIC (product-discriminating) token; generic category/material/placement co-occurrence is not product identity'));
END; $function$;

REVOKE ALL ON FUNCTION public.fn_resolve_supplier_identity(text,text,text,text,text,text,boolean) FROM PUBLIC, anon;

-- -------------------------------------------------------------------------------------
-- fn_supplier_backed_scan (mig_211b): read-only discovery funnel over the real CJ pool.
--   pool      -> first N CJ products (bounded, deterministic order)
--   pf        -> pre-filter keep = usable primary image + supplier cost + active sale
--   matched   -> LATERAL best real eBay demand query whose identity resolves to
--                EXACT_PRODUCT / CLOSE_COMPARABLE (category/keyword overlap never validates)
-- Built as a single query into a variable: CTEs do not persist across statements in
-- plpgsql, and execute_sql returns only the last statement's rows.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_supplier_backed_scan(p_pool_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE result jsonb;
BEGIN
  WITH pool AS (
    SELECT * FROM public.commerce_supplier_products WHERE source='cjdropshipping' ORDER BY id LIMIT p_pool_limit
  ),
  pf AS (
    SELECT *, (image_url IS NOT NULL AND image_url<>'' AND supplier_cost IS NOT NULL AND sale_status='3') AS keep FROM pool
  ),
  matched AS (
    SELECT p.id, p.keep, p.source_product_id cj_pid, p.title, p.category, p.supplier_cost, p.cost_currency,
      dm.product_query, dm.market, dm.currency, dm.price_median, dm.total_listings, dm.mc
    FROM pf p
    LEFT JOIN LATERAL (
      SELECT q.product_query, q.market, q.currency, q.price_median, q.total_listings,
        public.fn_resolve_supplier_identity(q.product_query, q.product_query, NULL, p.title, p.category, p.source_product_id, false)->>'match_class' mc
      FROM (SELECT DISTINCT product_query, market, currency, price_median, total_listings FROM public.market_price_observations) q
      WHERE p.keep AND public.fn_resolve_supplier_identity(q.product_query, q.product_query, NULL, p.title, p.category, p.source_product_id, false)->>'match_class'
            IN ('EXACT_PRODUCT','CLOSE_COMPARABLE')
      ORDER BY CASE public.fn_resolve_supplier_identity(q.product_query, q.product_query, NULL, p.title, p.category, p.source_product_id, false)->>'match_class'
                 WHEN 'EXACT_PRODUCT' THEN 0 ELSE 1 END, q.total_listings DESC
      LIMIT 1
    ) dm ON true
  )
  SELECT jsonb_build_object(
    'cj_products_scanned', (SELECT count(*) FROM matched),
    'pre_filtered_survivors', (SELECT count(*) FROM matched WHERE keep),
    'rejected_prefilter', (SELECT count(*) FROM matched WHERE NOT keep),
    'market_validated', (SELECT count(*) FROM matched WHERE mc IS NOT NULL),
    'rejected_no_exact_demand_match', (SELECT count(*) FROM matched WHERE keep AND mc IS NULL),
    'validated_candidates', coalesce((SELECT jsonb_agg(jsonb_build_object('cj_pid',cj_pid,'title',left(title,44),
        'category',category,'demand_query',product_query,'market',market,'local_price',price_median,'currency',currency,
        'listings',total_listings,'demand_match_class',mc,'supplier_cost',supplier_cost,'cost_currency',cost_currency)
        ORDER BY CASE mc WHEN 'EXACT_PRODUCT' THEN 0 ELSE 1 END, total_listings DESC)
      FROM matched WHERE mc IS NOT NULL),'[]'::jsonb),
    'policy', jsonb_build_object('supply_source','CJDROPSHIPPING (SUPPLY_ONLY)',
      'prefilter','usable primary image + supplier cost + active sale status',
      'demand_validation','canonical identity resolver EXACT_PRODUCT/CLOSE_COMPARABLE vs real eBay demand queries; category/keyword overlap never validates',
      'note','supplier availability alone never creates an opportunity; missing demand stays UNKNOWN'),
    'contract','pulse_supplier_backed_scan_v1')
  INTO result FROM (SELECT 1) _;
  RETURN result;
END; $function$;

REVOKE ALL ON FUNCTION public.fn_supplier_backed_scan(integer) FROM PUBLIC, anon;

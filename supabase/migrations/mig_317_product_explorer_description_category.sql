-- mig_317_product_explorer_description_category.sql
--
-- STAGE 3 localisation completion — minimum safe contract extension.
-- fn_product_explorer (mig_311) returns each product's title but NOT its genuine free-text
-- `description` or `category`, even though both columns exist on commerce_products. This blocked the
-- frontend from translating anything beyond titles. This migration ADDITIVELY surfaces those two
-- EXISTING columns on each item so the authorised translate-text path can translate them too:
--   * category  — populated for every product (controlled-ish free-text labels, e.g. "DVR & Dash Camera")
--   * description — genuine supplier/listing prose where present (often absent; NEVER invented)
-- Empty/blank values are stripped (jsonb_strip_nulls), so an item never carries fabricated text.
-- Nothing else changes: same auth, tenant/market scoping, dedup, filters, sorts, facets, media and
-- REFERENCE_ONLY authority. No new tables, no paid calls.

CREATE OR REPLACE FUNCTION public.fn_product_explorer(p_market text, p_filter text DEFAULT 'ALL'::text, p_search text DEFAULT NULL::text, p_sort text DEFAULT 'NEWEST'::text, p_page integer DEFAULT 1, p_pagesize integer DEFAULT 24)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid    uuid := auth.uid();
  v_mkt    text := nullif(upper(btrim(coalesce(p_market,''))),'');
  v_filter text := upper(coalesce(nullif(btrim(p_filter),''),'ALL'));
  v_sort   text := upper(coalesce(nullif(btrim(p_sort),''),'NEWEST'));
  v_search text := nullif(btrim(coalesce(p_search,'')),'');
  v_page   int  := greatest(1, coalesce(p_page,1));
  v_size   int  := least(greatest(coalesce(p_pagesize,24),1),60);
  v_off    int;
  v_result jsonb;
  v_denied jsonb := jsonb_build_object('status','unauthorized','items','[]'::jsonb,'total',0,'page',1,
    'pagesize',0,'total_pages',0,'facets','{}'::jsonb,'authority','REFERENCE_ONLY',
    'contract','pulse_product_explorer_v1');
BEGIN
  IF v_uid IS NULL OR v_mkt IS NULL THEN RETURN v_denied; END IF;
  v_off := (v_page-1)*v_size;

  WITH base AS (
    SELECT cp.id, cp.title, cp.observed_price, cp.price_currency, cp.source_store, cp.first_observed_at,
           cp.description, cp.category,
           coalesce(array_agg(DISTINCT s.value->>'fastmoss_strategy')
                    FILTER (WHERE nullif(s.value->>'fastmoss_strategy','') IS NOT NULL), ARRAY[]::text[]) AS lanes,
           max(nullif(s.value->>'sales_units','')::numeric)        AS sales_units,
           max(nullif(s.value->>'revenue','')::numeric)            AS revenue,
           max(nullif(s.value->>'sales_growth_rate','')::numeric)  AS sales_growth_rate,
           max(nullif(s.value->>'creator_count','')::numeric)
             FILTER (WHERE s.value->>'fastmoss_strategy'='MOST_PROMOTED') AS promotions,
           max(nullif(s.value->>'seller_count','')::numeric)       AS seller_count,
           max(nullif(s.value->>'advertiser_count','')::numeric)   AS advertiser_count,
           max(nullif(s.value->>'video_count','')::numeric)        AS video_count,
           max(s.observed_at)                                      AS observed_at
    FROM public.commerce_products cp
    JOIN public.commerce_signals s
      ON s.product_id=cp.id AND s.user_id=cp.user_id
     AND s.signal_type='COMMERCE_PRODUCT_NATIVE'
     AND upper(coalesce(s.value->>'market',''))=v_mkt
     AND nullif(s.value->>'fastmoss_strategy','') IS NOT NULL
    WHERE cp.user_id=v_uid
    GROUP BY cp.id, cp.title, cp.observed_price, cp.price_currency, cp.source_store, cp.first_observed_at,
             cp.description, cp.category
  ),
  enriched AS (
    SELECT b.*, d.opportunity_band, d.decision, d.lifecycle_state, d.product_opportunity_score,
      CASE WHEN 'TOP_SELLING'=ANY(b.lanes)   THEN 'BEST_SELLER'
           WHEN 'MOST_PROMOTED'=ANY(b.lanes) THEN 'MOST_PROMOTED'
           WHEN 'NEW_LISTED'=ANY(b.lanes)    THEN 'NEWLY_LISTED' ELSE 'DISCOVERED' END AS derived_class,
      (('NEW_LISTED'=ANY(b.lanes)) AND NOT ('TOP_SELLING'=ANY(b.lanes))) AS is_early
    FROM base b
    LEFT JOIN LATERAL (
      SELECT opportunity_band, decision, lifecycle_state, product_opportunity_score
      FROM public.product_opportunity_decisions d
      WHERE d.tenant_id=v_uid AND d.product_id=b.id AND upper(coalesce(d.country_code,''))=v_mkt
        AND coalesce(d.is_fixture,false)=false
      ORDER BY created_at DESC LIMIT 1) d ON true
  ),
  searched AS (
    SELECT * FROM enriched e WHERE (v_search IS NULL OR e.title ILIKE '%'||v_search||'%')
  ),
  facets AS (
    SELECT jsonb_build_object(
      'ALL', count(*),
      'NEWLY_LISTED',        count(*) FILTER (WHERE 'NEW_LISTED'=ANY(lanes)),
      'BEST_SELLERS',        count(*) FILTER (WHERE 'TOP_SELLING'=ANY(lanes)),
      'HIGH_GROWTH',         count(*) FILTER (WHERE sales_growth_rate IS NOT NULL AND sales_growth_rate > 0),
      'MOST_PROMOTED',       count(*) FILTER (WHERE 'MOST_PROMOTED'=ANY(lanes)),
      'EARLY_OPPORTUNITIES', count(*) FILTER (WHERE is_early OR lifecycle_state IN ('EMERGING','RESEARCH_PRIORITY') OR opportunity_band='EMERGING')
    ) AS f FROM searched
  ),
  filtered AS (
    SELECT * FROM searched e WHERE CASE v_filter
      WHEN 'ALL' THEN true
      WHEN 'NEWLY_LISTED' THEN 'NEW_LISTED'=ANY(e.lanes)
      WHEN 'BEST_SELLERS' THEN 'TOP_SELLING'=ANY(e.lanes)
      WHEN 'HIGH_GROWTH' THEN e.sales_growth_rate IS NOT NULL AND e.sales_growth_rate > 0
      WHEN 'MOST_PROMOTED' THEN 'MOST_PROMOTED'=ANY(e.lanes)
      WHEN 'EARLY_OPPORTUNITIES' THEN e.is_early OR e.lifecycle_state IN ('EMERGING','RESEARCH_PRIORITY') OR e.opportunity_band='EMERGING'
      ELSE true END
  ),
  total AS (SELECT count(*) AS n FROM filtered),
  page AS (
    SELECT f.* FROM filtered f
    ORDER BY
      CASE WHEN v_sort='REVENUE'  THEN f.revenue           END DESC NULLS LAST,
      CASE WHEN v_sort='SALES'    THEN f.sales_units       END DESC NULLS LAST,
      CASE WHEN v_sort='GROWTH'   THEN f.sales_growth_rate END DESC NULLS LAST,
      CASE WHEN v_sort='PROMOTED' THEN f.promotions        END DESC NULLS LAST,
      f.observed_at DESC NULLS LAST, f.id
    LIMIT v_size OFFSET v_off
  ),
  items AS (
    SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'product_id', p.id, 'title', p.title, 'market', v_mkt,
      'category', nullif(btrim(coalesce(p.category,'')),''),
      'description', nullif(btrim(coalesce(p.description,'')),''),
      'cover', (SELECT i.image_url FROM public.product_image_assets i
                WHERE i.product_id=p.id AND i.tenant_id=v_uid AND (i.market IS NULL OR i.market=v_mkt)
                ORDER BY i.is_primary DESC NULLS LAST,
                         (lower(coalesce(i.image_url,'')) NOT LIKE '%/default/%') DESC, i.observed_at DESC NULLS LAST
                LIMIT 1),
      'price', p.observed_price, 'currency', p.price_currency,
      'sales_units', p.sales_units, 'revenue', p.revenue,
      'sales_growth_rate', p.sales_growth_rate, 'promotions', p.promotions,
      'seller_count', p.seller_count, 'advertiser_count', p.advertiser_count, 'video_count', p.video_count,
      'lanes', to_jsonb(p.lanes), 'opportunity_class', p.derived_class,
      'opportunity_band', p.opportunity_band, 'decision', p.decision, 'lifecycle_state', p.lifecycle_state,
      'opportunity_score', p.product_opportunity_score,
      'observed_at', p.observed_at, 'source','FASTMOSS', 'authority','REFERENCE_ONLY'))), '[]'::jsonb) AS arr
    FROM page p
  )
  SELECT jsonb_build_object('status','ok','market',v_mkt,'filter',v_filter,'sort',v_sort,'search',v_search,
    'page',v_page,'pagesize',v_size,'total',(SELECT n FROM total),
    'total_pages', (SELECT CASE WHEN n=0 THEN 0 ELSE ceil(n::numeric/v_size)::int END FROM total),
    'facets',(SELECT f FROM facets),'items',(SELECT arr FROM items),
    'authority','REFERENCE_ONLY',
    'invariants', jsonb_build_object('server_owned_auth_uid',true,'tenant_market_scoped',true,
      'no_decision_dependency',true,'dedup_by_product_identity',true,'unknown_not_zero',true,
      'reference_only_media',true),
    'contract','pulse_product_explorer_v1')
  INTO v_result;
  RETURN v_result;
END; $function$;

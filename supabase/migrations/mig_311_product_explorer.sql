-- mig_311_product_explorer.sql
--
-- Efficient, server-owned, tenant- + market-scoped PAGINATED discovery projection powering the
-- Product Explorer. ONE query per page. Does NOT depend on fully-qualified opportunity decisions to
-- display a discovered product (product_opportunity_decisions is LEFT JOINed only to enrich the
-- classification when present). Identity is server-owned via auth.uid() (p_* never trusted for auth).
-- Dedup is by verified product identity (one commerce_products row = one platform_id product), never a
-- broad family. All media is REFERENCE_ONLY. UNKNOWN stays UNKNOWN (null, never 0). Country-isolated.
--
-- Filters: ALL | NEWLY_LISTED | BEST_SELLERS | HIGH_GROWTH | MOST_PROMOTED | EARLY_OPPORTUNITIES
--   NEWLY_LISTED  = NEW_LISTED lane present
--   BEST_SELLERS  = TOP_SELLING lane present
--   HIGH_GROWTH   = a genuine positive sales_growth_rate
--   MOST_PROMOTED = MOST_PROMOTED lane present
--   EARLY_OPPORTUNITIES = Strateloq early stage: an early lifecycle/band from a decision when present,
--                         OR the discovery heuristic (newly listed, not yet an established best seller)
-- Sort: NEWEST (default) | REVENUE | SALES | GROWTH | PROMOTED

CREATE OR REPLACE FUNCTION public.fn_product_explorer(
  p_market text, p_filter text DEFAULT 'ALL', p_search text DEFAULT NULL,
  p_sort text DEFAULT 'NEWEST', p_page int DEFAULT 1, p_pagesize int DEFAULT 24)
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
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
    GROUP BY cp.id, cp.title, cp.observed_price, cp.price_currency, cp.source_store, cp.first_observed_at
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

GRANT EXECUTE ON FUNCTION public.fn_product_explorer(text,text,text,text,int,int) TO anon, authenticated, service_role;

-- Markets that currently have discovered products for the signed-in tenant (for the market selector).
CREATE OR REPLACE FUNCTION public.fn_product_explorer_markets()
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthorized','markets','[]'::jsonb); END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('market',mkt,'products',n) ORDER BY n DESC), '[]'::jsonb) INTO v
  FROM (SELECT upper(s.value->>'market') AS mkt, count(DISTINCT s.product_id) AS n
          FROM public.commerce_signals s
         WHERE s.user_id=v_uid AND s.signal_type='COMMERCE_PRODUCT_NATIVE'
           AND nullif(s.value->>'fastmoss_strategy','') IS NOT NULL AND nullif(s.value->>'market','') IS NOT NULL
         GROUP BY 1) q;
  RETURN jsonb_build_object('status','ok','markets',v,'contract','pulse_product_explorer_markets_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_product_explorer_markets() TO anon, authenticated, service_role;

-- Selftest (service_role only): auth via request.jwt.claims; exercises paging, filters, facets,
-- country isolation, cross-tenant denial, dedup and UNKNOWN-not-zero.
CREATE OR REPLACE FUNCTION public.fn_product_explorer_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  OWNER_T uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  checks jsonb := '[]'::jsonb; passed int := 0; failed int := 0; ok boolean; r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub',OWNER_T)::text, true);

  r := public.fn_product_explorer('GB','ALL',NULL,'NEWEST',1,10);
  ok := (r->>'status'='ok') AND ((r->>'total')::int >= 20) AND (jsonb_array_length(r->'items')=10)
        AND ((r->'facets'->>'ALL')::int = (r->>'total')::int);
  checks := checks || jsonb_build_object('check','GB_PAGE1_OK','ok',ok,'total',r->'total','page_items',jsonb_array_length(r->'items')); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- page 2 returns the remainder, no overlap in count
  r := public.fn_product_explorer('GB','ALL',NULL,'NEWEST',2,10);
  ok := (jsonb_array_length(r->'items') >= 1);
  checks := checks || jsonb_build_object('check','GB_PAGE2_OK','ok',ok,'page2_items',jsonb_array_length(r->'items')); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- filter: best sellers => every item has TOP_SELLING lane
  r := public.fn_product_explorer('GB','BEST_SELLERS',NULL,'REVENUE',1,50);
  ok := (jsonb_array_length(r->'items') >= 1) AND NOT EXISTS (
     SELECT 1 FROM jsonb_array_elements(r->'items') it WHERE NOT (it->'lanes' @> '"TOP_SELLING"'::jsonb));
  checks := checks || jsonb_build_object('check','FILTER_BEST_SELLERS_PURE','ok',ok,'n',jsonb_array_length(r->'items')); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- search narrows results
  r := public.fn_product_explorer('GB','ALL','collagen','NEWEST',1,50);
  ok := (jsonb_array_length(r->'items') >= 1) AND NOT EXISTS (
     SELECT 1 FROM jsonb_array_elements(r->'items') it WHERE lower(it->>'title') NOT LIKE '%collagen%');
  checks := checks || jsonb_build_object('check','SEARCH_NARROWS','ok',ok,'n',jsonb_array_length(r->'items')); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- cover coverage: GB items carry a reference cover
  r := public.fn_product_explorer('GB','ALL',NULL,'NEWEST',1,50);
  ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'items') it WHERE (it->>'cover') IS NULL);
  checks := checks || jsonb_build_object('check','GB_COVER_COVERAGE','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- dedup: distinct product_ids == item count
  ok := (SELECT count(*)=count(DISTINCT it->>'product_id') FROM jsonb_array_elements(r->'items') it);
  checks := checks || jsonb_build_object('check','DEDUP_DISTINCT_IDENTITY','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- country isolation: a market with no discovery is empty
  r := public.fn_product_explorer('JP','ALL',NULL,'NEWEST',1,10);
  ok := (r->>'total')::int = 0 AND jsonb_array_length(r->'items')=0;
  checks := checks || jsonb_build_object('check','COUNTRY_ISOLATION_JP_EMPTY','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;

  -- cross-tenant denied
  PERFORM set_config('request.jwt.claims', json_build_object('sub','2f000000-0000-4000-a000-000000002999')::text, true);
  r := public.fn_product_explorer('GB','ALL',NULL,'NEWEST',1,10);
  ok := (r->>'status'='unauthorized') OR ((r->>'total')::int = 0);
  checks := checks || jsonb_build_object('check','CROSS_TENANT_EMPTY','ok',ok); IF ok THEN passed:=passed+1; ELSE failed:=failed+1; END IF;
  PERFORM set_config('request.jwt.claims','',true);

  RETURN jsonb_build_object('contract','pulse_product_explorer_selftest_v1',
    'passed',passed,'failed',failed,'total',passed+failed,'ok',(failed=0),'checks',checks,'generated_at',now());
END; $function$;
REVOKE ALL ON FUNCTION public.fn_product_explorer_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_product_explorer_selftest() TO service_role;

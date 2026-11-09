-- mig_342 — Product Explorer v5: MANDATORY IMAGE GATE (customer-facing = display-image products only)
-- 2026-11-09  (PREPARED; NOT deployed without founder approval)
--
-- Decision 1: NO VERIFIED DISPLAYABLE IMAGE = NO CUSTOMER-FACING PRODUCT.
-- Builds on v4 (mig_340). Additive gate: the customer-facing projection returns ONLY products that resolve a
-- tenant-owned display image (SUPPLIER_PROVIDED or PROVIDER_DISCOVERY_REFERENCE, available, http). REFERENCE
-- (marketplace link-only) and NONE products are EXCLUDED from items, total, facets, search, filters and
-- pagination. Hidden products and their research evidence are NOT deleted — they remain in the DB and are
-- counted in `hidden_pending_image` for internal recovery. Tenant + market scoping, country isolation,
-- Product Asset Lock, growth and provenance are unchanged. Contract: pulse_product_explorer_v5.
-- With the gate, every returned item has image_status='DISPLAY'; `reference`/NONE branches never fire.

CREATE OR REPLACE FUNCTION public.fn_product_explorer(p_market text, p_filter text DEFAULT 'ALL'::text, p_search text DEFAULT NULL::text, p_sort text DEFAULT 'NEWEST'::text, p_page integer DEFAULT 1, p_pagesize integer DEFAULT 24, p_category text DEFAULT NULL::text, p_price_min numeric DEFAULT NULL::numeric, p_price_max numeric DEFAULT NULL::numeric, p_revenue_min numeric DEFAULT NULL::numeric, p_revenue_max numeric DEFAULT NULL::numeric, p_sales_min numeric DEFAULT NULL::numeric, p_sales_max numeric DEFAULT NULL::numeric, p_growth_min numeric DEFAULT NULL::numeric, p_growth_max numeric DEFAULT NULL::numeric)
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
  v_category    text    := nullif(btrim(coalesce(p_category,'')),'');
  v_price_min   numeric := p_price_min;   v_price_max   numeric := p_price_max;
  v_revenue_min numeric := p_revenue_min; v_revenue_max numeric := p_revenue_max;
  v_sales_min   numeric := p_sales_min;   v_sales_max   numeric := p_sales_max;
  v_growth_min  numeric := p_growth_min;  v_growth_max  numeric := p_growth_max;
  v_off    int;
  v_result jsonb;
  v_denied jsonb := jsonb_build_object('status','unauthorized','items','[]'::jsonb,'total',0,'page',1,
    'pagesize',0,'total_pages',0,'facets','{}'::jsonb,'authority','REFERENCE_ONLY','contract','pulse_product_explorer_v5');
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
           max(nullif(s.value->>'revenue_growth_rate','')::numeric) AS revenue_growth_rate,
           bool_or(nullif(s.value->>'fastmoss_strategy','') IS NOT NULL) AS has_fastmoss,
           bool_or(lower(coalesce(s.value->>'source','')) = 'kalodata') AS has_kalodata,
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
     AND (nullif(s.value->>'fastmoss_strategy','') IS NOT NULL
          OR lower(coalesce(s.value->>'source','')) = 'kalodata')
    WHERE cp.user_id=v_uid
      AND NOT public.fn_discovery_product_hidden(v_uid, cp.id)
    GROUP BY cp.id, cp.title, cp.observed_price, cp.price_currency, cp.source_store, cp.first_observed_at,
             cp.description, cp.category
  ),
  enriched AS (
    SELECT b.*, d.opportunity_band, d.decision, d.lifecycle_state, d.product_opportunity_score,
      CASE WHEN 'TOP_SELLING'=ANY(b.lanes)   THEN 'BEST_SELLER'
           WHEN 'MOST_PROMOTED'=ANY(b.lanes) THEN 'MOST_PROMOTED'
           WHEN 'NEW_LISTED'=ANY(b.lanes)    THEN 'NEWLY_LISTED'
           WHEN b.has_kalodata AND NOT b.has_fastmoss THEN 'NEWLY_DISCOVERED'
           ELSE 'DISCOVERED' END AS derived_class,
      CASE WHEN b.has_fastmoss THEN 'FASTMOSS'
           WHEN b.has_kalodata THEN 'KALODATA'
           ELSE 'COMMERCE' END AS source_label,
      CASE WHEN d.decision IS NULL AND d.opportunity_band IS NULL
           THEN 'NEWLY_DISCOVERED_RESEARCH_PENDING' ELSE 'EVALUATED' END AS research_status,
      CASE WHEN b.has_kalodata AND NOT b.has_fastmoss AND b.revenue_growth_rate IS NOT NULL
             THEN b.revenue_growth_rate ELSE NULL END AS growth_pct,
      CASE WHEN b.has_kalodata AND NOT b.has_fastmoss AND b.revenue_growth_rate IS NOT NULL THEN 'revenue_7d_pct'
           WHEN b.has_fastmoss AND b.sales_growth_rate IS NOT NULL THEN 'units_sold_growth_rate_unverified'
           ELSE NULL END AS growth_basis,
      CASE WHEN b.has_kalodata AND NOT b.has_fastmoss AND b.revenue_growth_rate IS NOT NULL THEN 'VERIFIED'
           WHEN b.has_fastmoss AND b.sales_growth_rate IS NOT NULL THEN 'UNVERIFIED'
           ELSE NULL END AS growth_status,
      coalesce(
        CASE WHEN b.has_kalodata AND NOT b.has_fastmoss THEN b.revenue_growth_rate END,
        CASE WHEN b.has_fastmoss THEN b.sales_growth_rate END) AS growth_sign_src,
      (('NEW_LISTED'=ANY(b.lanes)) AND NOT ('TOP_SELLING'=ANY(b.lanes))) AS is_early,
      -- IMAGE GATE predicate: a tenant-owned display-tier image exists (same filter as the cover LATERAL)
      EXISTS (SELECT 1 FROM public.product_image_assets i
              WHERE i.product_id=b.id AND i.tenant_id=v_uid AND (i.market IS NULL OR i.market=v_mkt)
                AND i.rights_state IN ('SUPPLIER_PROVIDED','PROVIDER_DISCOVERY_REFERENCE')
                AND coalesce(upper(i.availability),'AVAILABLE') <> 'UNAVAILABLE'
                AND i.image_url ILIKE 'http%') AS has_display_image
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
  scoped AS (
    SELECT * FROM searched e
    WHERE (v_category    IS NULL OR lower(btrim(coalesce(e.category,''))) = lower(v_category))
      AND (v_price_min   IS NULL OR (e.observed_price IS NOT NULL AND e.observed_price >= v_price_min))
      AND (v_price_max   IS NULL OR (e.observed_price IS NOT NULL AND e.observed_price <= v_price_max))
      AND (v_revenue_min IS NULL OR (e.revenue        IS NOT NULL AND e.revenue        >= v_revenue_min))
      AND (v_revenue_max IS NULL OR (e.revenue        IS NOT NULL AND e.revenue        <= v_revenue_max))
      AND (v_sales_min   IS NULL OR (e.sales_units    IS NOT NULL AND e.sales_units    >= v_sales_min))
      AND (v_sales_max   IS NULL OR (e.sales_units    IS NOT NULL AND e.sales_units    <= v_sales_max))
      AND (v_growth_min  IS NULL OR (e.growth_pct     IS NOT NULL AND e.growth_pct     >= v_growth_min))
      AND (v_growth_max  IS NULL OR (e.growth_pct     IS NOT NULL AND e.growth_pct     <= v_growth_max))
  ),
  -- MANDATORY IMAGE GATE: customer-facing set = display-image products only.
  prefiltered AS (
    SELECT * FROM scoped WHERE has_display_image
  ),
  facets AS (
    SELECT jsonb_build_object(
      'ALL', count(*),
      'NEWLY_LISTED',        count(*) FILTER (WHERE 'NEW_LISTED'=ANY(lanes)),
      'BEST_SELLERS',        count(*) FILTER (WHERE 'TOP_SELLING'=ANY(lanes)),
      'HIGH_GROWTH',         count(*) FILTER (WHERE growth_sign_src IS NOT NULL AND growth_sign_src > 0),
      'MOST_PROMOTED',       count(*) FILTER (WHERE 'MOST_PROMOTED'=ANY(lanes)),
      'EARLY_OPPORTUNITIES', count(*) FILTER (WHERE is_early OR lifecycle_state IN ('EMERGING','RESEARCH_PRIORITY') OR opportunity_band='EMERGING'),
      'NEWLY_DISCOVERED',    count(*) FILTER (WHERE research_status='NEWLY_DISCOVERED_RESEARCH_PENDING')
    ) AS f FROM prefiltered
  ),
  filtered AS (
    SELECT * FROM prefiltered e WHERE CASE v_filter
      WHEN 'ALL' THEN true
      WHEN 'NEWLY_LISTED' THEN 'NEW_LISTED'=ANY(e.lanes)
      WHEN 'BEST_SELLERS' THEN 'TOP_SELLING'=ANY(e.lanes)
      WHEN 'HIGH_GROWTH' THEN e.growth_sign_src IS NOT NULL AND e.growth_sign_src > 0
      WHEN 'MOST_PROMOTED' THEN 'MOST_PROMOTED'=ANY(e.lanes)
      WHEN 'EARLY_OPPORTUNITIES' THEN e.is_early OR e.lifecycle_state IN ('EMERGING','RESEARCH_PRIORITY') OR e.opportunity_band='EMERGING'
      WHEN 'NEWLY_DISCOVERED' THEN e.research_status='NEWLY_DISCOVERED_RESEARCH_PENDING'
      ELSE true END
  ),
  total AS (SELECT count(*) AS n FROM filtered),
  page AS (
    SELECT f.*,
      img.cover_url, img.img_source, img.img_rights, img.img_source_url, img.img_observed_at
    FROM filtered f
    LEFT JOIN LATERAL (
      SELECT i.image_url AS cover_url, i.source_provider AS img_source, i.rights_state AS img_rights,
             i.source_url AS img_source_url, i.observed_at AS img_observed_at
      FROM public.product_image_assets i
      WHERE i.product_id=f.id AND i.tenant_id=v_uid AND (i.market IS NULL OR i.market=v_mkt)
        AND i.rights_state IN ('SUPPLIER_PROVIDED','PROVIDER_DISCOVERY_REFERENCE')
        AND coalesce(upper(i.availability),'AVAILABLE') <> 'UNAVAILABLE'
        AND i.image_url ILIKE 'http%'
      ORDER BY CASE i.rights_state WHEN 'SUPPLIER_PROVIDED' THEN 0
                                   WHEN 'PROVIDER_DISCOVERY_REFERENCE' THEN 1 ELSE 2 END,
               i.is_primary DESC NULLS LAST,
               (lower(coalesce(i.image_url,'')) NOT LIKE '%/default/%') DESC, i.observed_at DESC NULLS LAST
      LIMIT 1) img ON true
    ORDER BY
      CASE WHEN v_sort='REVENUE'  THEN f.revenue     END DESC NULLS LAST,
      CASE WHEN v_sort='SALES'    THEN f.sales_units END DESC NULLS LAST,
      CASE WHEN v_sort='GROWTH'   THEN f.growth_pct  END DESC NULLS LAST,
      CASE WHEN v_sort='PROMOTED' THEN f.promotions  END DESC NULLS LAST,
      f.observed_at DESC NULLS LAST, f.id
    LIMIT v_size OFFSET v_off
  ),
  items AS (
    SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'product_id', p.id, 'title', p.title, 'market', v_mkt,
      'category', nullif(btrim(coalesce(p.category,'')),''),
      'description', nullif(btrim(coalesce(p.description,'')),''),
      'cover', p.cover_url,
      'image_status', 'DISPLAY',
      'image', jsonb_strip_nulls(jsonb_build_object(
                 'url', p.cover_url,
                 'source_provider', p.img_source,
                 'rights_state', p.img_rights,
                 'source_url', p.img_source_url,
                 'observed_at', p.img_observed_at,
                 'display_cleared', true,
                 'commercial_cleared', false,
                 'reference_only', (p.img_rights IS DISTINCT FROM 'SUPPLIER_PROVIDED'))),
      'price', p.observed_price, 'currency', p.price_currency,
      'sales_units', p.sales_units, 'revenue', p.revenue,
      'growth_pct', p.growth_pct, 'growth_basis', p.growth_basis, 'growth_status', p.growth_status,
      'sales_growth_rate', p.sales_growth_rate, 'revenue_growth_rate', p.revenue_growth_rate,
      'promotions', p.promotions,
      'seller_count', p.seller_count, 'advertiser_count', p.advertiser_count, 'video_count', p.video_count,
      'lanes', to_jsonb(p.lanes), 'opportunity_class', p.derived_class,
      'opportunity_band', p.opportunity_band, 'decision', p.decision, 'lifecycle_state', p.lifecycle_state,
      'opportunity_score', p.product_opportunity_score,
      'research_status', p.research_status,
      'observed_at', p.observed_at, 'source', p.source_label, 'authority','REFERENCE_ONLY'))), '[]'::jsonb) AS arr
    FROM page p
  )
  SELECT jsonb_build_object('status','ok','market',v_mkt,'filter',v_filter,'sort',v_sort,'search',v_search,
    'page',v_page,'pagesize',v_size,'total',(SELECT n FROM total),
    'total_pages', (SELECT CASE WHEN n=0 THEN 0 ELSE ceil(n::numeric/v_size)::int END FROM total),
    'facets',(SELECT f FROM facets),'items',(SELECT arr FROM items),
    'authority','REFERENCE_ONLY',
    -- internal recovery visibility: products hidden by the image gate (not deleted), after search+filters
    'hidden_pending_image', (SELECT count(*) FROM scoped WHERE NOT has_display_image),
    'filters', jsonb_strip_nulls(jsonb_build_object(
      'category', v_category, 'price_min', v_price_min, 'price_max', v_price_max,
      'revenue_min', v_revenue_min, 'revenue_max', v_revenue_max, 'sales_min', v_sales_min, 'sales_max', v_sales_max,
      'growth_min', v_growth_min, 'growth_max', v_growth_max)),
    'invariants', jsonb_build_object('server_owned_auth_uid',true,'tenant_market_scoped',true,
      'no_decision_dependency',true,'dedup_by_product_identity',true,'unknown_not_zero',true,
      'reference_only_media',true,'legacy_discovery_hidden_excluded',true,'ranges_exclude_unknown',true,
      'kalodata_native_included',true,'unevaluated_scores_null',true,
      'growth_never_fabricated',true,'fastmoss_growth_unverified',true,
      'image_rights_ranked',true,'reference_link_only_never_copied',true,'image_commercial_never_asserted',true,
      'image_gated_display_only',true),
    'growth_units', jsonb_build_object(
      'revenue_7d_pct','VERIFIED percentage (Kalodata revenue growth, 7-day window)',
      'units_sold_growth_rate_unverified','UNVERIFIED — FastMoss units_sold_growth_rate has no authoritative unit; not shown as a percentage'),
    'image_rights', jsonb_build_object(
      'DISPLAY','tenant-owned display image (supplier-authorised or provider research reference); shown, not commercial',
      'gate','customer-facing products require a display image; REFERENCE/NONE are hidden (not deleted)'),
    'contract','pulse_product_explorer_v5')
  INTO v_result;
  RETURN v_result;
END; $function$;

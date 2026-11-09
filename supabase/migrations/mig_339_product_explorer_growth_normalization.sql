-- mig_339 — Product Explorer v3: source-aware growth presentation + honest image status (PREPARED; NOT deployed)
-- 2026-11-09
--
-- P2 growth metrics. Provider-unit verification (release gate):
--   * Kalodata growth = `revenue_growth_rate`, a GENUINE percentage (live range -96..+746, nothing below
--     -100%). VERIFIED. Surfaced as growth_pct with basis 'revenue_7d_pct'. The card previously read
--     `sales_growth_rate` (null for Kalodata) => "missing growth"; now fixed.
--   * FastMoss `sales_growth_rate` = provider `units_sold_growth_rate`, stored RAW (no adapter transform).
--     Its unit CANNOT be established authoritatively:
--       - FastMoss official docs (developers.fastmoss.com/.../product/v1/fullyManaged) list the field as
--         "Sales volume growth rate" with NO unit and a large-integer sample (59335);
--       - the live data is internally inconsistent with any single percentage scale: negatives like
--         -3906 rule out a raw % (a decline cannot exceed -100%), while the vendor overview's
--         "growth_rate 212 -> +212%" rules out a /100 %.
--     Therefore it is NOT converted (no speculative /100) and is surfaced as UNVERIFIED
--     (growth_pct NULL, growth_status 'UNVERIFIED'). The raw value is kept only for transparency and is
--     NEVER displayed as a percentage. (Kalodata and FastMoss growth are different metrics — revenue vs
--     units-sold — and are never treated as interchangeable.)
--
-- Fields added to each item (source-aware, never fabricated):
--   growth_pct    numeric — Kalodata revenue_growth_rate only; NULL for FastMoss (unverified unit)
--   growth_basis  text    — 'revenue_7d_pct' | 'units_sold_growth_rate_unverified' | null
--   growth_status text    — 'VERIFIED' | 'UNVERIFIED' | null
--   image_status  text    — 'DISPLAY' when a rights-cleared cover exists, else 'NONE' (honest "No image")
-- Raw sales_growth_rate / revenue_growth_rate kept for transparency. HIGH_GROWTH facet uses the growth
-- SIGN (reliable even for an unknown-scale unit); the numeric growth_min/max filter uses only the
-- VERIFIED growth_pct. No engine/tier/label/identity change; tenant+market scoping and PAL unchanged.
-- image_status=NONE is correct for Kalodata — the only images present are eBay MARKETPLACE_PUBLIC_LISTING
-- (rights not established, tenant-null); PAL keeps them hidden.

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
    'pagesize',0,'total_pages',0,'facets','{}'::jsonb,'authority','REFERENCE_ONLY','contract','pulse_product_explorer_v3');
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
      -- VERIFIED growth % ONLY: Kalodata revenue_growth_rate is a genuine percentage. FastMoss
      -- units_sold_growth_rate has no authoritative unit (see header) and is NOT converted.
      CASE WHEN b.has_kalodata AND NOT b.has_fastmoss AND b.revenue_growth_rate IS NOT NULL
             THEN b.revenue_growth_rate ELSE NULL END AS growth_pct,
      CASE WHEN b.has_kalodata AND NOT b.has_fastmoss AND b.revenue_growth_rate IS NOT NULL THEN 'revenue_7d_pct'
           WHEN b.has_fastmoss AND b.sales_growth_rate IS NOT NULL THEN 'units_sold_growth_rate_unverified'
           ELSE NULL END AS growth_basis,
      CASE WHEN b.has_kalodata AND NOT b.has_fastmoss AND b.revenue_growth_rate IS NOT NULL THEN 'VERIFIED'
           WHEN b.has_fastmoss AND b.sales_growth_rate IS NOT NULL THEN 'UNVERIFIED'
           ELSE NULL END AS growth_status,
      -- reliable growth SIGN (direction) regardless of the FastMoss unit scale, for the HIGH_GROWTH facet
      coalesce(
        CASE WHEN b.has_kalodata AND NOT b.has_fastmoss THEN b.revenue_growth_rate END,
        CASE WHEN b.has_fastmoss THEN b.sales_growth_rate END) AS growth_sign_src,
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
  prefiltered AS (
    SELECT * FROM searched e
    WHERE (v_category    IS NULL OR lower(btrim(coalesce(e.category,''))) = lower(v_category))
      AND (v_price_min   IS NULL OR (e.observed_price IS NOT NULL AND e.observed_price >= v_price_min))
      AND (v_price_max   IS NULL OR (e.observed_price IS NOT NULL AND e.observed_price <= v_price_max))
      AND (v_revenue_min IS NULL OR (e.revenue        IS NOT NULL AND e.revenue        >= v_revenue_min))
      AND (v_revenue_max IS NULL OR (e.revenue        IS NOT NULL AND e.revenue        <= v_revenue_max))
      AND (v_sales_min   IS NULL OR (e.sales_units    IS NOT NULL AND e.sales_units    >= v_sales_min))
      AND (v_sales_max   IS NULL OR (e.sales_units    IS NOT NULL AND e.sales_units    <= v_sales_max))
      -- numeric growth range applies only to VERIFIED growth_pct (never the unverified FastMoss unit)
      AND (v_growth_min  IS NULL OR (e.growth_pct     IS NOT NULL AND e.growth_pct     >= v_growth_min))
      AND (v_growth_max  IS NULL OR (e.growth_pct     IS NOT NULL AND e.growth_pct     <= v_growth_max))
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
      (SELECT i.image_url FROM public.product_image_assets i
         WHERE i.product_id=f.id AND i.tenant_id=v_uid AND (i.market IS NULL OR i.market=v_mkt)
         ORDER BY i.is_primary DESC NULLS LAST,
                  (lower(coalesce(i.image_url,'')) NOT LIKE '%/default/%') DESC, i.observed_at DESC NULLS LAST
         LIMIT 1) AS cover_url
    FROM filtered f
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
      'image_status', CASE WHEN p.cover_url IS NOT NULL THEN 'DISPLAY' ELSE 'NONE' END,
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
    'filters', jsonb_strip_nulls(jsonb_build_object(
      'category', v_category, 'price_min', v_price_min, 'price_max', v_price_max,
      'revenue_min', v_revenue_min, 'revenue_max', v_revenue_max, 'sales_min', v_sales_min, 'sales_max', v_sales_max,
      'growth_min', v_growth_min, 'growth_max', v_growth_max)),
    'invariants', jsonb_build_object('server_owned_auth_uid',true,'tenant_market_scoped',true,
      'no_decision_dependency',true,'dedup_by_product_identity',true,'unknown_not_zero',true,
      'reference_only_media',true,'legacy_discovery_hidden_excluded',true,'ranges_exclude_unknown',true,
      'kalodata_native_included',true,'unevaluated_scores_null',true,
      'growth_never_fabricated',true,'fastmoss_growth_unverified',true),
    'growth_units', jsonb_build_object(
      'revenue_7d_pct','VERIFIED percentage (Kalodata revenue growth, 7-day window)',
      'units_sold_growth_rate_unverified','UNVERIFIED — FastMoss units_sold_growth_rate has no authoritative unit; not shown as a percentage'),
    'contract','pulse_product_explorer_v3')
  INTO v_result;
  RETURN v_result;
END; $function$;

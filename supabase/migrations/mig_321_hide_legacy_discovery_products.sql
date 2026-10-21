-- mig_321_hide_legacy_discovery_products.sql
--
-- STAGE 4A — remove legacy / research-concept products from the active customer-facing Product
-- Discovery experience (founder decision). Reversible + auditable: a hide-list table, not a delete.
--
-- Classification (verified source + discovery timestamp + lifecycle):
--   * GENUINE recent discoveries = commerce_products.source_store IN ('fastmoss','kalodata') — the live
--     TikTok-Shop discovery lanes; every one carries a COMMERCE_PRODUCT_NATIVE signal and was first seen
--     2026-10-12/19. These STAY visible and keep progressing through supplier verification + Product
--     Intelligence (req 5).
--   * LEGACY research-concepts = source_store IN ('dataforseo','reddit','industry_blog') or NULL — old
--     generic keyword seeds (cables, pillows, "cool mist humidifier", "kids nightlight projector"),
--     first seen Sept–early Oct, with NO native discovery signal. These are HIDDEN from discovery.
--   Researched-ness and older source dates are NOT used to hide a product — only the lane is, so a
--   genuine recent FastMoss product is never hidden merely for having been researched (req 3).
--
-- Nothing is deleted: historical evidence, supplier bindings (e.g. the nightlight's bound CJ supplier),
-- audit rows, product pages and store-product rows are all preserved. The hide only filters the
-- customer-facing discovery READS. Reverse by deleting a hide-list row. Tenant-scoped; other tenants
-- are unaffected.

-- 1) Hide-list (audit record; one row per hidden product)
CREATE TABLE IF NOT EXISTS public.commerce_discovery_hidden (
  tenant_id                  uuid NOT NULL,
  product_id                 uuid NOT NULL,
  reason                     text NOT NULL DEFAULT 'legacy_research_concept',
  source_store_at_hide       text,
  first_observed_at_snapshot timestamptz,
  hidden_at                  timestamptz NOT NULL DEFAULT now(),
  hidden_by                  text NOT NULL DEFAULT 'stage4a_legacy_cleanup',
  PRIMARY KEY (tenant_id, product_id)
);
ALTER TABLE public.commerce_discovery_hidden ENABLE ROW LEVEL SECURITY;
-- No RLS policies: the customer-facing SECURITY DEFINER read contracts are the only access path;
-- service_role bypasses RLS; anon/authenticated get no direct access.

-- 2) Predicate used by the customer-facing discovery contracts
CREATE OR REPLACE FUNCTION public.fn_discovery_product_hidden(p_tenant uuid, p_product_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.commerce_discovery_hidden h
                 WHERE h.tenant_id = p_tenant AND h.product_id = p_product_id);
$function$;
REVOKE ALL ON FUNCTION public.fn_discovery_product_hidden(uuid,uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_discovery_product_hidden(uuid,uuid) TO service_role;

-- 3) Seed the hide-list from the legacy rule (tenant-scoped; idempotent). 21 products:
--    reddit(10) + dataforseo(9) + industry_blog(1) + NULL-source(1).
INSERT INTO public.commerce_discovery_hidden (tenant_id, product_id, reason, source_store_at_hide, first_observed_at_snapshot)
SELECT cp.user_id, cp.id, 'legacy_research_concept_pre_fastmoss',
       coalesce(cp.source_store,'(null)'), cp.first_observed_at
FROM public.commerce_products cp
WHERE cp.user_id = '7c8ddf9d-172c-4a89-a402-bb7066228b61'
  AND (cp.source_store IS NULL OR cp.source_store NOT IN ('fastmoss','kalodata'))
ON CONFLICT (tenant_id, product_id) DO NOTHING;

-- 4) Recommendation feed — exclude hidden (the primary leak surface: 26 legacy rows pre-fix -> 0).
CREATE OR REPLACE FUNCTION public.fn_monday_top_opportunities(p_tenant uuid, p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE ready jsonb; watch jsonb; scanned int;
BEGIN
  WITH best AS (
    SELECT DISTINCT ON (d.product_id) d.*, cp.title AS product_name, cp.category,
      pme.evidence->'observed_market_price' AS price_obj,
      coalesce(pme.evidence->'supplier_identity'->>'match_class','UNKNOWN') AS sup_match
    FROM public.product_opportunity_decisions d
    JOIN public.commerce_products cp ON cp.id=d.product_id
    LEFT JOIN public.product_market_evaluations pme
      ON pme.tenant_id=d.tenant_id AND pme.product_id=d.product_id AND pme.country_code=d.country_code
    WHERE d.tenant_id=p_tenant AND d.is_fixture=false AND d.decision<>'AVOID' AND d.product_opportunity_score IS NOT NULL
      AND NOT public.fn_discovery_product_hidden(d.tenant_id, d.product_id)
    ORDER BY d.product_id,
      CASE d.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END,
      CASE d.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END,
      CASE d.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END,
      d.product_opportunity_score DESC
  ),
  ranked AS (
    SELECT b.*, CASE WHEN b.metric_scope='LOCAL' THEN 0 ELSE 1 END AS price_rank,
      (SELECT to_jsonb(pai) FROM public.product_asset_intelligence pai
        WHERE pai.tenant_id=b.tenant_id AND pai.product_id=b.product_id AND pai.is_primary
        ORDER BY pai.created_at DESC LIMIT 1) AS asset
    FROM best b
  ),
  ord AS (
    SELECT r.*, row_number() OVER (ORDER BY
      CASE r.decision WHEN 'TEST' THEN 0 WHEN 'WATCH' THEN 1 ELSE 2 END, r.price_rank,
      CASE r.opportunity_sweet_spot->>'state' WHEN 'STRONG' THEN 0 WHEN 'PROMISING' THEN 1 WHEN 'WEAK' THEN 2 ELSE 3 END,
      CASE r.saturation_state->>'level' WHEN 'LOW' THEN 0 WHEN 'MODERATE' THEN 0 WHEN 'HIGH' THEN 2 WHEN 'VERY_HIGH' THEN 3 ELSE 2 END,
      r.product_opportunity_score DESC) AS rk
    FROM ranked r
  ),
  capped AS (SELECT * FROM ord WHERE rk <= p_limit),
  cards AS (
    SELECT decision, jsonb_build_object(
      'product_id', product_id, 'product', product_name, 'category', category,
      'best_market', country_code, 'decision', decision, 'lifecycle', lifecycle_state,
      'product_confidence', product_confidence, 'product_opportunity_score', product_opportunity_score,
      'saturation', saturation_state->>'level',
      'market_price', CASE WHEN price_obj->>'amount' IS NOT NULL
          THEN (price_obj->>'amount')||' '||coalesce(price_obj->>'currency','') ELSE 'UNKNOWN (no local price observed)' END,
      'market_price_scope', metric_scope,
      'supplier_match', CASE WHEN sup_match='EXACT_PRODUCT' THEN 'EXACT' ELSE coalesce(nullif(sup_match,'UNKNOWN'),'unresolved') END,
      'advertising_headroom', advertising_headroom->>'state', 'opportunity_sweet_spot', opportunity_sweet_spot->>'state',
      'image', CASE WHEN asset IS NOT NULL THEN jsonb_build_object(
                   'available',true,'url',asset->>'source_url','identity_state',asset->>'identity_state',
                   'rights_state',asset->>'rights_state','hero_eligible',(asset->>'hero_eligible')::boolean,
                   'source',asset->>'source','asset_type',asset->>'asset_type',
                   'note', CASE WHEN (asset->>'hero_eligible')::boolean THEN 'exact-product supplier image'
                           ELSE 'comparable supplier image ('||(asset->>'identity_state')||') — NOT the exact candidate; shown as reference' END)
                 ELSE jsonb_build_object('available',false,'reason','IMAGE_UNAVAILABLE — no legitimate exact/comparable supplier image resolved') END,
      'commercial_assets', public.fn_product_commercial_readiness_badge(product_id, country_code),
      'why', 'Real demand'||CASE WHEN metric_scope='LOCAL' THEN ' + validated local price' ELSE '' END||
             '; held for '||coalesce((SELECT string_agg(x,', ') FROM (SELECT jsonb_array_elements_text(decision_blockers) x LIMIT 2) z),'—'),
      'action', CASE WHEN decision='TEST' THEN 'View Opportunity (Build Product Page eligible)' ELSE 'View Opportunity (launch actions locked)' END
    ) AS card, rk
    FROM capped
  )
  SELECT coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='TEST'),'[]'::jsonb),
         coalesce((SELECT jsonb_agg(card ORDER BY rk) FROM cards WHERE decision='WATCH'),'[]'::jsonb)
  INTO ready, watch;
  SELECT count(*) INTO scanned FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND is_fixture=false
      AND NOT public.fn_discovery_product_hidden(tenant_id, product_id);
  RETURN jsonb_build_object('tenant_id', p_tenant, 'generated_at', now(),
    'ready_to_test', ready, 'watchlist', watch,
    'ready_to_test_count', jsonb_array_length(ready), 'watchlist_count', jsonb_array_length(watch),
    'total_opportunities', jsonb_array_length(ready)+jsonb_array_length(watch),
    'limit', p_limit, 'product_market_rows_scanned', scanned,
    'discovery_policy', jsonb_build_object('max_portfolio', p_limit,
      'stop_conditions', jsonb_build_array('source_candidate_exhaustion','configured_max_candidate_scan','sufficient_qualified_portfolio'),
      'min_evidence_quality','real Product x Market decision, non-AVOID, real demand evidence; no gate lowered to fill slots',
      'note','fewer than the limit is expected when few candidates meet evidence quality; AVOID never enters the portfolio'),
    'campaign_activation', false, 'advertising_spend', 0,
    'note','READY_TO_TEST are launch-eligible only after downstream gates; WATCHLIST are emerging, not launch-ready; WINNER is post-performance only. commercial_assets is an independent launch-readiness dimension: opportunity quality does not depend on it. Legacy research-concept products are excluded from this feed.',
    'contract','pulse_monday_top_opportunities_v2_nolegacy');
END; $function$;

-- 5) Discovered-candidate projector — never re-project a hidden product into decisions.
CREATE OR REPLACE FUNCTION public.fn_project_discovered_candidates(p_tenant uuid, p_market text, p_freshness_hours integer DEFAULT 168)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_ccy text; v_projected int := 0; v_skipped int := 0; v_already int := 0; v_watch int := 0;
  r record; v_dec text;
BEGIN
  IF p_tenant IS NULL OR v_mkt='' THEN RETURN jsonb_build_object('status','MISSING_ARGS'); END IF;
  SELECT default_currency INTO v_ccy FROM public.ecommerce_market_universe
    WHERE country_code=v_mkt AND coalesce(ecommerce_eligible,true) LIMIT 1;
  IF v_ccy IS NULL THEN RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','market',v_mkt); END IF;

  PERFORM set_config('pulse.suppress_dispatch','on',true);

  FOR r IN
    SELECT cp.id AS product_id,
      coalesce((SELECT m.value->>'price_query' FROM public.monday_opportunity_registry reg
                CROSS JOIN LATERAL jsonb_array_elements(reg.markets) m
                WHERE reg.tenant_id=p_tenant AND reg.product_id=cp.id AND upper(m.value->>'country')=v_mkt LIMIT 1),
               cp.title) AS price_query
    FROM public.commerce_products cp
    WHERE cp.user_id=p_tenant
      AND NOT public.fn_discovery_product_hidden(p_tenant, cp.id)
      AND EXISTS (SELECT 1 FROM public.monday_opportunity_registry reg
                  WHERE reg.tenant_id=p_tenant AND reg.product_id=cp.id AND reg.active
                    AND EXISTS (SELECT 1 FROM jsonb_array_elements(reg.markets) m WHERE upper(m.value->>'country')=v_mkt))
  LOOP
    IF EXISTS (SELECT 1 FROM public.product_opportunity_decisions d
               WHERE d.tenant_id=p_tenant AND d.product_id=r.product_id AND d.country_code=v_mkt
                 AND coalesce(d.is_fixture,false)=false) THEN
      v_already := v_already + 1; CONTINUE;
    END IF;
    BEGIN
      PERFORM public.fn_assemble_real_product_market(r.product_id, v_mkt, v_ccy, r.price_query, NULL, true);
      v_dec := (public.fn_pod_evaluate(p_tenant, r.product_id, v_mkt, 'pod_v1', true))->>'decision';
      v_projected := v_projected + 1;
      IF v_dec IS NOT NULL AND v_dec <> 'INSUFFICIENT_EVIDENCE' THEN v_watch := v_watch + 1; END IF;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object('status','ok','tenant',p_tenant,'market',v_mkt,'currency',v_ccy,
    'projected',v_projected,'decisioned',v_watch,'already_decided',v_already,'skipped',v_skipped,
    'note','assembles a country PME + pod_evaluate for registered candidates lacking a decision; NO paid research (suppress_dispatch=on); provisional (WATCH) until researched; country-isolated; existing decisions untouched; legacy research-concept products excluded',
    'contract','pulse_project_discovered_candidates_v2_nolegacy');
END; $function$;

-- 6) Explorer — belt: already excludes non-native-signal legacy; predicate future-proofs it so any
--    product explicitly hide-listed (even a fastmoss one) is removed. (contract unchanged; invariant added)
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
      AND NOT public.fn_discovery_product_hidden(v_uid, cp.id)
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
      'reference_only_media',true,'legacy_discovery_hidden_excluded',true),
    'contract','pulse_product_explorer_v1')
  INTO v_result;
  RETURN v_result;
END; $function$;

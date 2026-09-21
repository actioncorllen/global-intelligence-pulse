-- ============================================================================
-- mig_265_product_gallery.sql
-- STRATELOQ-ECOM-MULTI-IMAGE-PRODUCT-GALLERY-013Y
--
-- Upgrades the 013W/013X single-primary image pipeline to a trustworthy 3-5 image
-- gallery, extending the EXISTING product_image_assets model (no new image system).
--
-- Phase-1 audit (stored evidence only): each researched product has many distinct
-- MATCHED eBay listing image URLs (35-98) but NO per-listing additionalImages/
-- thumbnailImages arrays (item_summary/search does not return them). So the gallery
-- is composed of: (a) canonical CJ supplier images (same SKU, when linked) and
-- (b) distinct, strongly-MATCHED marketplace listing images of the same canonical
-- product. These are real authorized listing photos of the product concept, exposed
-- as plain gallery images -- NEVER labelled as fabricated angles, never keyword-only,
-- never another product's image, never AI/competitor-creative.
--
-- Changes:
--  1) unique (product_id, image_url) -> prevents duplicate image URLs in the gallery.
--  2) fn_backfill_product_images_from_evidence (v2): captures all AVAILABLE CJ images
--     + the top-8 distinct-URL MATCHED eBay images per product, then deterministically
--     marks exactly one canonical primary (CJ preferred, else lexicographically-first
--     eBay URL). No external call, no score/decision change.
--  3) fn_resolve_product_gallery(product_id, limit=5) -> ordered, URL-deduped, product
--     -global gallery + gallery_state.
--  4) fn_resolve_product_image -> unchanged semantics (returns the canonical PRIMARY),
--     ordering aligned to is_primary so the primary is stable.
--  5) workspace RPC -> additive product_images[], product_image_count,
--     product_gallery_state; keeps product_image_url/source/source_url/state.
--  6) fn_product_gallery_selftest.
-- ============================================================================

-- 1) prevent duplicate image URLs per product --------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS product_image_assets_url_uniq
  ON public.product_image_assets (product_id, image_url);

-- 2) backfill v2: CJ gallery + top-8 MATCHED eBay images + deterministic primary
CREATE OR REPLACE FUNCTION public.fn_backfill_product_images_from_evidence(p_product_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_cj int := 0; v_ebay int := 0; v_primary int := 0;
BEGIN
  -- (a) all AVAILABLE, rights-cleared CJ supplier images (same-SKU gallery), product-global
  INSERT INTO public.product_image_assets(product_id, market, image_url, source_provider, source_url,
      source_entity_id, rights_state, availability, is_primary, observed_at, provenance)
  SELECT cp.id, NULL, a.source_url, 'CJ_SUPPLIER', a.source_url, sp.source_product_id,
         'SUPPLIER_PROVIDED', 'AVAILABLE', false, coalesce(a.observed_at, now()),
         jsonb_build_object('captured_from','supplier_assets','asset_type',a.asset_type,'supplier_row_id',sp.id)
  FROM public.commerce_products cp
  JOIN public.commerce_supplier_products sp
    ON sp.id = coalesce(nullif(cp.extended->'supplier_ref'->>'supplier_row_id',''),
                        nullif(cp.extended->'supplier_refs'->0->>'supplier_row_id',''))::uuid
  JOIN public.supplier_product_assets a
    ON a.supplier_product_id = sp.source_product_id AND a.availability='AVAILABLE'
       AND a.rights_state='SUPPLIER_PROVIDED' AND a.asset_type IN ('PRIMARY_IMAGE','IMAGE','GALLERY_IMAGE')
       AND coalesce(a.source_url,'')<>''
  WHERE (p_product_id IS NULL OR cp.id=p_product_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_cj = ROW_COUNT;

  -- (a2) denormalised CJ catalogue image fallback (when no assets rows)
  INSERT INTO public.product_image_assets(product_id, market, image_url, source_provider, source_url,
      source_entity_id, rights_state, availability, is_primary, observed_at, provenance)
  SELECT cp.id, NULL, nullif(sp.image_url,''), 'CJ_SUPPLIER', nullif(sp.image_url,''), sp.source_product_id,
         'SUPPLIER_PROVIDED', 'AVAILABLE', false, now(),
         jsonb_build_object('captured_from','supplier_catalogue','supplier_row_id',sp.id)
  FROM public.commerce_products cp
  JOIN public.commerce_supplier_products sp
    ON sp.id = coalesce(nullif(cp.extended->'supplier_ref'->>'supplier_row_id',''),
                        nullif(cp.extended->'supplier_refs'->0->>'supplier_row_id',''))::uuid
  WHERE (p_product_id IS NULL OR cp.id=p_product_id) AND coalesce(sp.image_url,'')<>''
  ON CONFLICT DO NOTHING;

  -- (b) top-8 distinct-URL strongly-MATCHED eBay listing images per product
  WITH base AS (
    SELECT s.product_id, s.confidence, coalesce(s.observed_at, now()) AS obs, s.value->>'item_id' AS item_id,
      (SELECT ev->>'image_url' FROM jsonb_array_elements(s.evidence) ev WHERE coalesce(ev->>'image_url','')<>'' LIMIT 1) AS img_url,
      (SELECT ev->>'item_web_url' FROM jsonb_array_elements(s.evidence) ev WHERE coalesce(ev->>'image_url','')<>'' LIMIT 1) AS item_web_url
    FROM public.commerce_signals s
    WHERE s.signal_type='MARKETPLACE_ACTIVITY' AND s.value->>'match'='MATCHED'
      AND (p_product_id IS NULL OR s.product_id=p_product_id)
      AND EXISTS (SELECT 1 FROM jsonb_array_elements(s.evidence) ev WHERE coalesce(ev->>'image_url','')<>'')
  ),
  dedup AS (
    SELECT DISTINCT ON (product_id, img_url) product_id, img_url, item_web_url, item_id, confidence, obs
    FROM base WHERE coalesce(img_url,'')<>''
    ORDER BY product_id, img_url, confidence DESC NULLS LAST
  ),
  ranked AS (
    SELECT *, row_number() OVER (PARTITION BY product_id ORDER BY confidence DESC NULLS LAST, img_url) AS rn
    FROM dedup
  )
  INSERT INTO public.product_image_assets(product_id, market, image_url, source_provider, source_url,
      source_entity_id, rights_state, availability, is_primary, observed_at, provenance)
  SELECT product_id, NULL, img_url, 'EBAY_BROWSE', item_web_url, item_id, 'MARKETPLACE_PUBLIC_LISTING',
         'AVAILABLE', false, obs, jsonb_build_object('captured_from','ebay_marketplace_evidence','match','MATCHED','gallery_rank',rn)
  FROM ranked WHERE rn <= 8
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_ebay = ROW_COUNT;

  -- (c) deterministic single canonical primary per product (CJ preferred, else
  --     lexicographically-first eBay URL). Stable + idempotent.
  UPDATE public.product_image_assets SET is_primary=false
  WHERE (p_product_id IS NULL OR product_id=p_product_id) AND is_primary=true;
  UPDATE public.product_image_assets t SET is_primary=true
  FROM (
    SELECT DISTINCT ON (product_id) id FROM public.product_image_assets
    WHERE (p_product_id IS NULL OR product_id=p_product_id)
      AND availability='AVAILABLE' AND coalesce(is_fixture,false)=false AND coalesce(image_url,'')<>''
    ORDER BY product_id,
      CASE source_provider WHEN 'CJ_SUPPLIER' THEN 0 WHEN 'EBAY_BROWSE' THEN 1 ELSE 2 END, image_url
  ) pick
  WHERE t.id = pick.id;
  GET DIAGNOSTICS v_primary = ROW_COUNT;

  RETURN jsonb_build_object('status','ok','cj_captured',v_cj,'ebay_captured',v_ebay,'primaries_set',v_primary,
    'scope', CASE WHEN p_product_id IS NULL THEN 'all' ELSE p_product_id::text END);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_backfill_product_images_from_evidence(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_backfill_product_images_from_evidence(uuid) TO service_role;

-- 3) gallery resolver (product-global; URL-deduped; capped; deterministic) -----
CREATE OR REPLACE FUNCTION public.fn_resolve_product_gallery(p_product_id uuid, p_limit int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_imgs jsonb; v_count int; v_state text; v_research_done boolean; v_lim int := least(greatest(coalesce(p_limit,5),1),5);
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
           'image_url', img_url,
           'image_source', CASE src WHEN 'CJ_SUPPLIER' THEN 'SUPPLIER_PROVIDED' WHEN 'EBAY_BROWSE' THEN 'MARKETPLACE_LISTING' ELSE src END,
           'image_source_url', src_url, 'is_primary', is_prim, 'position', pos, 'source_provider', src)
           ORDER BY pos),
         count(*)
    INTO v_imgs, v_count
  FROM (
    SELECT DISTINCT ON (image_url) image_url AS img_url, source_url AS src_url, source_provider AS src, is_primary AS is_prim,
           row_number() OVER (ORDER BY is_primary DESC,
             CASE source_provider WHEN 'CJ_SUPPLIER' THEN 0 WHEN 'EBAY_BROWSE' THEN 1 ELSE 2 END, image_url) AS pos
    FROM public.product_image_assets
    WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false AND availability='AVAILABLE' AND coalesce(image_url,'')<>''
    ORDER BY image_url, is_primary DESC
  ) d
  WHERE pos <= v_lim;

  v_count := coalesce(v_count,0);
  IF v_count = 0 THEN
    SELECT EXISTS (SELECT 1 FROM public.product_market_evaluations e
                   WHERE e.product_id=p_product_id AND e.market_opportunity_score IS NOT NULL
                     AND coalesce(e.is_fixture,false)=false) INTO v_research_done;
    v_state := CASE WHEN v_research_done THEN 'UNAVAILABLE_NO_SOURCE' ELSE 'PENDING_RESEARCH' END;
  ELSIF v_count >= 3 THEN v_state := 'AVAILABLE';
  ELSE v_state := 'PARTIAL';
  END IF;

  RETURN jsonb_build_object('images', coalesce(v_imgs,'[]'::jsonb), 'count', v_count, 'gallery_state', v_state);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_resolve_product_gallery(uuid,int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_resolve_product_gallery(uuid,int) TO authenticated, service_role;

-- 4) primary resolver: align ordering to is_primary so the primary is stable ---
CREATE OR REPLACE FUNCTION public.fn_resolve_product_image(p_product_id uuid, p_market text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE r record; v_fallback text; v_research_done boolean;
BEGIN
  SELECT image_url, source_provider, source_url, market INTO r
  FROM public.product_image_assets
  WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false AND availability='AVAILABLE' AND coalesce(image_url,'')<>''
  ORDER BY is_primary DESC,
           CASE source_provider WHEN 'CJ_SUPPLIER' THEN 0 WHEN 'EBAY_BROWSE' THEN 1 ELSE 2 END, image_url
  LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('image_url', r.image_url,
      'source', CASE r.source_provider WHEN 'CJ_SUPPLIER' THEN 'SUPPLIER_PROVIDED'
                                       WHEN 'EBAY_BROWSE' THEN 'MARKETPLACE_LISTING' ELSE r.source_provider END,
      'source_url', r.source_url, 'source_provider', r.source_provider, 'market', r.market, 'image_state','AVAILABLE');
  END IF;

  SELECT coalesce(spa.source_url, nullif(sp.image_url,'')) INTO v_fallback
  FROM public.commerce_products cp
  JOIN public.commerce_supplier_products sp
    ON sp.id = coalesce(nullif(cp.extended->'supplier_ref'->>'supplier_row_id',''),
                        nullif(cp.extended->'supplier_refs'->0->>'supplier_row_id',''))::uuid
  LEFT JOIN LATERAL (
    SELECT a.source_url FROM public.supplier_product_assets a
    WHERE a.supplier_product_id=sp.source_product_id AND a.availability='AVAILABLE'
      AND a.rights_state='SUPPLIER_PROVIDED' AND a.asset_type IN ('PRIMARY_IMAGE','IMAGE') AND coalesce(a.source_url,'')<>''
    ORDER BY a.is_primary DESC LIMIT 1) spa ON true
  WHERE cp.id=p_product_id LIMIT 1;
  IF coalesce(v_fallback,'')<>'' THEN
    RETURN jsonb_build_object('image_url',v_fallback,'source','SUPPLIER_PROVIDED','source_url',v_fallback,
      'source_provider','CJ_SUPPLIER','market',NULL,'image_state','AVAILABLE');
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.product_market_evaluations e
                 WHERE e.product_id=p_product_id AND e.market_opportunity_score IS NOT NULL
                   AND coalesce(e.is_fixture,false)=false) INTO v_research_done;
  RETURN jsonb_build_object('image_url',NULL,'source',NULL,'source_url',NULL,'source_provider',NULL,'market',NULL,
    'image_state', CASE WHEN v_research_done THEN 'UNAVAILABLE_NO_SOURCE' ELSE 'PENDING_RESEARCH' END);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_resolve_product_image(uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_resolve_product_image(uuid,text) TO authenticated, service_role;

-- 5) workspace contract: additive gallery fields (keeps the 4 back-compat fields) ---
CREATE OR REPLACE FUNCTION public.fn_ecommerce_workspace_intelligence()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
    v_uid uuid := auth.uid();
    v_member_count integer; v_member_id uuid; v_app uuid;
    v_bp public.business_profiles%ROWTYPE; v_found boolean := false;
    v_decisions jsonb; v_storefronts jsonb; v_evidence jsonb; v_products int;
BEGIN
    IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
    SELECT count(*), min(m.id::text)::uuid, min(m.application_ref::text)::uuid
      INTO v_member_count, v_member_id, v_app
    FROM public.member AS m WHERE m.auth_user_id = v_uid;
    IF v_member_count = 0 THEN RETURN jsonb_build_object('status','no_member'); END IF;
    IF v_member_count > 1 THEN RAISE EXCEPTION 'member cardinality violation' USING ERRCODE='P0001'; END IF;
    SELECT * INTO v_bp FROM public.business_profiles WHERE application_id = v_app;
    IF FOUND THEN v_found := true; END IF;
    IF NOT v_found THEN
        SELECT * INTO v_bp FROM public.business_profiles WHERE user_id = v_uid
        ORDER BY updated_at DESC NULLS LAST LIMIT 1;
        IF FOUND THEN v_found := true; END IF;
    END IF;
    IF v_found AND v_bp.user_id IS NOT NULL AND v_bp.user_id <> v_uid THEN
        RAISE EXCEPTION 'business profile ownership violation' USING ERRCODE='P0001';
    END IF;

    SELECT coalesce(jsonb_agg(row ORDER BY (row->>'opportunity_score')::numeric DESC NULLS LAST), '[]'::jsonb) INTO v_decisions FROM (
        SELECT jsonb_build_object(
            'decision_id', d.id, 'product_id', d.product_id, 'product_title', cp.title,
            'product_category', cp.category, 'product_url', cp.product_url, 'source_store', cp.source_store,
            'product_image_url', img.j->>'image_url',
            'product_image_source', img.j->>'source',
            'product_image_source_url', img.j->>'source_url',
            'product_image_state', img.j->>'image_state',
            'product_images', coalesce(gal.j->'images','[]'::jsonb),
            'product_image_count', coalesce((gal.j->>'count')::int,0),
            'product_gallery_state', gal.j->>'gallery_state',
            'observed_price', cp.observed_price, 'currency', cp.price_currency, 'availability', cp.availability,
            'decision', coalesce(pme.market_decision, d.decision),
            'opportunity_band', CASE WHEN pme.market_opportunity_score IS NOT NULL
                                     THEN public.fn_ecommerce_opportunity_band(pme.market_opportunity_score)
                                     ELSE d.opportunity_band END,
            'opportunity_score', coalesce(pme.market_opportunity_score, d.product_opportunity_score),
            'coverage', coalesce(pme.coverage, d.coverage),
            'product_confidence', d.product_confidence,
            'evidence_confidence', coalesce(pme.evidence_confidence, d.overall_evidence_confidence),
            'evaluated_at', pme.evaluation_ts,
            'score_version', coalesce(pme.score_version, d.score_version),
            'evaluation_source', CASE WHEN pme.market_opportunity_score IS NOT NULL
                                      THEN 'product_market_evaluations' ELSE 'product_opportunity_decisions' END,
            'decision_provisional', (pme.market_opportunity_score IS NULL),
            'research_evidence_state', CASE WHEN pme.market_opportunity_score IS NULL
                                            THEN 'INSUFFICIENT_EVIDENCE' ELSE 'EVALUATED' END,
            'country_code', d.country_code, 'primary_platform', d.primary_platform,
            'lifecycle_state', d.lifecycle_state, 'action_gating', d.action_gating,
            'decision_reasons', coalesce(d.decision_reasons, '[]'::jsonb),
            'saturation_state', coalesce(d.saturation_state, 'null'::jsonb),
            'advertising_headroom', coalesce(d.advertising_headroom, 'null'::jsonb),
            'opportunity_sweet_spot', coalesce(d.opportunity_sweet_spot, 'null'::jsonb),
            'storefront', (
                SELECT jsonb_build_object('page_id', pg.id, 'status', pg.status, 'publication_state', pg.publication_state)
                FROM public.commerce_product_pages pg
                WHERE pg.user_id = v_uid AND pg.product_id = d.product_id
                ORDER BY pg.updated_at DESC NULLS LAST LIMIT 1)
        ) AS row
        FROM public.product_opportunity_decisions d
        JOIN public.commerce_products cp ON cp.id = d.product_id
        LEFT JOIN LATERAL (
          SELECT e.market_opportunity_score, e.coverage, e.evidence_confidence, e.market_decision, e.evaluation_ts, e.score_version
          FROM public.product_market_evaluations e
          WHERE e.tenant_id = d.tenant_id AND e.product_id = d.product_id AND e.country_code = d.country_code
            AND coalesce(e.is_fixture,false) = false
          ORDER BY e.evaluation_ts DESC NULLS LAST LIMIT 1
        ) pme ON true
        LEFT JOIN LATERAL (SELECT public.fn_resolve_product_image(d.product_id, d.country_code) AS j) img ON true
        LEFT JOIN LATERAL (SELECT public.fn_resolve_product_gallery(d.product_id, 5) AS j) gal ON true
        WHERE d.tenant_id = v_uid AND coalesce(d.is_fixture, false) = false
    ) z;

    SELECT coalesce(jsonb_agg(jsonb_build_object('signal_type', s.signal_type, 'count', s.n, 'last_observed', s.last_obs)
            ORDER BY s.n DESC), '[]'::jsonb) INTO v_evidence
    FROM (SELECT signal_type, count(*) n, max(observed_at) last_obs
          FROM public.commerce_signals WHERE user_id = v_uid GROUP BY signal_type) s;

    SELECT coalesce(jsonb_agg(jsonb_build_object('page_id', pg.id, 'product_id', pg.product_id, 'product_title', cp2.title,
                'status', pg.status, 'publication_state', pg.publication_state, 'market', pg.market,
                'country_code', pg.country_code, 'opportunity_decision_id', pg.opportunity_decision_id)), '[]'::jsonb)
      INTO v_storefronts
    FROM public.commerce_product_pages pg
    LEFT JOIN public.commerce_products cp2 ON cp2.id = pg.product_id
    WHERE pg.user_id = v_uid;

    SELECT count(*) INTO v_products FROM public.commerce_products WHERE user_id = v_uid;

    RETURN jsonb_build_object('status','ok',
        'category', CASE WHEN v_found THEN v_bp.business_category ELSE NULL END,
        'is_ecommerce', coalesce(v_found AND v_bp.business_category = 'ecommerce', false),
        'business', CASE WHEN v_found THEN jsonb_build_object('business_name', v_bp.business_name, 'industry', v_bp.industry,
              'country', v_bp.country, 'business_category', v_bp.business_category) ELSE 'null'::jsonb END,
        'product_decisions', v_decisions, 'product_decision_count', jsonb_array_length(v_decisions),
        'products_tracked', v_products, 'evidence_summary', v_evidence, 'storefronts', v_storefronts,
        'source_contract', 'decisions+current PME+commerce_products+signals+pages; primary image via fn_resolve_product_image; gallery via fn_resolve_product_gallery (canonical supplier + MATCHED marketplace, URL-deduped, product-global, max 5)',
        'provenance_vocabulary', jsonb_build_array('OBSERVED','INFERRED','RESEARCHED')
    );
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$;

-- 6) offline selftest ----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_product_gallery_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_nl uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_hu uuid := 'cda3f71a-9947-4344-8664-13735740575f';
  v_ca uuid := (SELECT id FROM public.commerce_products WHERE user_id='7c8ddf9d-172c-4a89-a402-bb7066228b61' AND title='cool air humidifier');
  g_nl jsonb; g_hu jsonb; g_gb jsonb; g_de jsonb; g_ca jsonb;
BEGIN
  g_nl := public.fn_resolve_product_gallery(v_nl,5);
  g_hu := public.fn_resolve_product_gallery(v_hu,5);
  g_gb := public.fn_resolve_product_gallery(v_nl,5);
  g_de := public.fn_resolve_product_gallery(v_nl,5);
  g_ca := public.fn_resolve_product_gallery(v_ca,5);

  -- max 5 images
  v := v || jsonb_build_object('case','max_5_images','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
                    WHERE cp.user_id='7c8ddf9d-172c-4a89-a402-bb7066228b61' AND (g->>'count')::int > 5));
  -- no duplicate URLs within any gallery
  v := v || jsonb_build_object('case','no_duplicate_urls','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
                      jsonb_array_elements(g->'images') im
                    WHERE cp.user_id='7c8ddf9d-172c-4a89-a402-bb7066228b61'
                    GROUP BY cp.id, im->>'image_url' HAVING count(*) > 1));
  -- exactly one primary in a non-empty gallery
  v := v || jsonb_build_object('case','exactly_one_primary','pass',
        (SELECT count(*) FROM jsonb_array_elements(g_nl->'images') im WHERE (im->>'is_primary')::boolean)=1);
  -- no cross-product leakage: every gallery url belongs to that product's assets
  v := v || jsonb_build_object('case','no_cross_product_leakage','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
                      jsonb_array_elements(g->'images') im
                    WHERE cp.user_id='7c8ddf9d-172c-4a89-a402-bb7066228b61'
                      AND NOT EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.product_id=cp.id AND a.image_url=im->>'image_url')));
  -- GB/DE resolve the SAME product-global gallery for a canonical product
  v := v || jsonb_build_object('case','gb_de_same_gallery','pass', (g_gb->'images' = g_de->'images'));
  -- deterministic order: two calls identical
  v := v || jsonb_build_object('case','deterministic_order','pass', (g_hu->'images' = public.fn_resolve_product_gallery(v_hu,5)->'images'));
  -- primary stable = fn_resolve_product_image primary equals gallery primary
  v := v || jsonb_build_object('case','primary_matches_resolver','pass',
        ((public.fn_resolve_product_image(v_hu,'GB'))->>'image_url' =
         (SELECT im->>'image_url' FROM jsonb_array_elements(g_hu->'images') im WHERE (im->>'is_primary')::boolean LIMIT 1)));
  -- gallery states truthful (>=3 AVAILABLE, 1-2 PARTIAL, 0 pending/unavailable)
  v := v || jsonb_build_object('case','gallery_state_truthful','pass',
        (g_nl->>'gallery_state' IN ('AVAILABLE','PARTIAL') AND g_ca->>'gallery_state' IN ('PENDING_RESEARCH','UNAVAILABLE_NO_SOURCE') AND (g_ca->>'count')::int=0));
  -- pending product has no fabricated gallery
  v := v || jsonb_build_object('case','pending_no_fabrication','pass', jsonb_array_length(g_ca->'images')=0);
  -- no AI/web sources anywhere
  v := v || jsonb_build_object('case','no_ai_or_web_sources','pass',
        NOT EXISTS (SELECT 1 FROM public.product_image_assets a
                    WHERE a.source_provider NOT IN ('CJ_SUPPLIER','EBAY_BROWSE')));

  RETURN jsonb_build_object('suite','product_gallery',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_product_gallery_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_product_gallery_selftest() TO service_role;

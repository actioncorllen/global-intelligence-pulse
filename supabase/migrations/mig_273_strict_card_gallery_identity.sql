-- ============================================================================
-- mig_273_strict_card_gallery_identity.sql
-- STRATELOQ-PRODUCT-GALLERY-013Y.2 — strict CARD ↔ GALLERY product identity
--
-- LAUNCH-CRITICAL DATA-INTEGRITY FIX (founder visually verified).
--
-- DEFECT: the workspace card hero (fn_resolve_product_image) and the multi-image
-- gallery (fn_resolve_product_gallery) resolved their source identity INDEPENDENTLY.
-- The gallery picked the identity with the MOST images ((n>=3) DESC, CJ, n DESC),
-- which for every researched product is a DIFFERENT marketplace listing than the
-- card hero. Result: the card shows product X while its 5-image gallery shows a
-- different product Y (e.g. nightlight hero = CJ "GINGER TECH" item
-- 2608250310481611400, gallery = eBay item v1|117296648744|0 — a different listing).
--
-- Why 013Y.1's same-item test missed it: fn_product_gallery_selftest only asserted a
-- gallery was INTERNALLY single-identity (all images share one source_entity_id). It
-- NEVER asserted GALLERY identity == CARD HERO identity. A self-consistent gallery of
-- the wrong item passed.
--
-- FIX (read-side, deterministic, no external call): fn_resolve_product_gallery now
-- resolves the gallery from the EXACT card/hero identity — the same source item that
-- fn_resolve_product_image selects as primary (is_primary DESC, CJ>EBAY>other,
-- image_url) — and returns up to 5 images from THAT identity ONLY. It never switches
-- to another item for more photographs. Identity outranks image count: a hero item
-- with 1 image yields a 1-image gallery; missing positions are NEVER filled from
-- another product. Adds explicit card_source_provider / card_source_item_id, equal to
-- the gallery identity by construction.
--
-- No image is deleted (marketplace evidence preserved); only the SELECTION is
-- corrected. Storefront (fn_resolve_storefront_assets) already resolves from a single
-- fulfilment supplier_product_id and rejects marketplace/reference images (fail
-- closed) — unchanged. No PME / Product Decision change (read-only).
-- ============================================================================

-- 1) gallery resolver bound to the CARD/HERO identity -------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_product_gallery(p_product_id uuid, p_limit int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_lim int := least(greatest(coalesce(p_limit,5),1),5);
  v_prov text; v_eid text; v_imgs jsonb; v_count int; v_state text; v_ident text; v_research_done boolean;
BEGIN
  -- CARD/HERO identity: the EXACT source item fn_resolve_product_image(product,market)
  -- selects as primary. Same deterministic ordering. The gallery MUST come from this
  -- identity only — never the identity that merely has the most images.
  SELECT source_provider, source_entity_id INTO v_prov, v_eid
  FROM public.product_image_assets
  WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false
    AND availability='AVAILABLE' AND coalesce(image_url,'')<>'' AND coalesce(source_entity_id,'')<>''
  ORDER BY is_primary DESC,
           CASE source_provider WHEN 'CJ_SUPPLIER' THEN 0 WHEN 'EBAY_BROWSE' THEN 1 ELSE 2 END,
           image_url
  LIMIT 1;

  IF v_eid IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object(
             'image_url', image_url,
             'image_source', CASE src WHEN 'CJ_SUPPLIER' THEN 'SUPPLIER_PROVIDED'
                                      WHEN 'EBAY_BROWSE' THEN 'MARKETPLACE_LISTING' ELSE src END,
             'image_source_url', src_url, 'is_primary', (pos=1), 'position', pos,
             'source_provider', src, 'source_item_id', v_eid) ORDER BY pos),
           count(*)
      INTO v_imgs, v_count
    FROM (
      SELECT image_url, src_url, src,
             row_number() OVER (ORDER BY gpos, image_url) AS pos
      FROM (
        SELECT image_url,
               max(source_url) AS src_url, max(source_provider) AS src,
               min(coalesce((provenance->>'gallery_position')::int, 999)) AS gpos
        FROM public.product_image_assets
        WHERE product_id=p_product_id AND source_provider=v_prov AND source_entity_id=v_eid
          AND coalesce(is_fixture,false)=false AND availability='AVAILABLE' AND coalesce(image_url,'')<>''
        GROUP BY image_url
      ) u
    ) d
    WHERE pos <= v_lim;
  END IF;

  v_count := coalesce(v_count,0);
  IF v_count = 0 THEN
    SELECT EXISTS (SELECT 1 FROM public.product_market_evaluations e
                   WHERE e.product_id=p_product_id AND e.market_opportunity_score IS NOT NULL
                     AND coalesce(e.is_fixture,false)=false) INTO v_research_done;
    v_state := CASE WHEN v_research_done THEN 'UNAVAILABLE_NO_SOURCE' ELSE 'PENDING_RESEARCH' END;
    v_ident := CASE WHEN v_research_done THEN 'SAME_PRODUCT_GALLERY_UNAVAILABLE' ELSE 'PENDING_RESEARCH' END;
  ELSIF v_count >= 3 THEN v_state := 'AVAILABLE'; v_ident := 'SAME_PRODUCT_GALLERY_READY';
  ELSE v_state := 'PARTIAL'; v_ident := 'SAME_PRODUCT_GALLERY_PARTIAL';
  END IF;

  RETURN jsonb_build_object('images', coalesce(v_imgs,'[]'::jsonb), 'count', v_count,
    'gallery_state', v_state, 'gallery_identity_state', v_ident,
    -- card identity == gallery identity by construction (strict 013Y.2 invariant)
    'card_source_provider', v_prov, 'card_source_item_id', v_eid,
    'gallery_source_provider', v_prov, 'gallery_source_item_id', v_eid);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_resolve_product_gallery(uuid,int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_resolve_product_gallery(uuid,int) TO authenticated, service_role;

-- 2) workspace contract: surface explicit card_source_provider / card_source_item_id --
--    (only these two keys added vs mig_266; everything else byte-identical)
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
            'gallery_identity_state', gal.j->>'gallery_identity_state',
            'card_source_provider', gal.j->>'card_source_provider',
            'card_source_item_id', gal.j->>'card_source_item_id',
            'gallery_source_provider', gal.j->>'gallery_source_provider',
            'gallery_source_item_id', gal.j->>'gallery_source_item_id',
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
        'source_contract', 'decisions+current PME+commerce_products+signals+pages; primary image via fn_resolve_product_image; gallery via fn_resolve_product_gallery bound to the SAME card/hero identity (card_source_item_id == gallery_source_item_id; same-item images only, never multi-listing, never image-count optimization)',
        'provenance_vocabulary', jsonb_build_array('OBSERVED','INFERRED','RESEARCHED')
    );
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$;

-- 3) selftest: add strict CARD==GALLERY identity invariants (keep 013Y.1 invariants) --
CREATE OR REPLACE FUNCTION public.fn_product_gallery_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_owner uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_nl uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_hu uuid := 'cda3f71a-9947-4344-8664-13735740575f';
  v_ca uuid := (SELECT id FROM public.commerce_products WHERE user_id=v_owner AND title='cool air humidifier' LIMIT 1);
  g_hu jsonb; g_gb jsonb; g_de jsonb; g_ca jsonb;
BEGIN
  g_hu := public.fn_resolve_product_gallery(v_hu,5);
  g_gb := public.fn_resolve_product_gallery(v_nl,5);
  g_de := public.fn_resolve_product_gallery(v_nl,5);
  g_ca := public.fn_resolve_product_gallery(v_ca,5);

  -- STRICT 013Y.2: gallery identity == card/hero identity (the exact hero source item)
  v := v || jsonb_build_object('case','gallery_identity_equals_card_identity','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND (g->>'gallery_source_item_id') IS DISTINCT FROM (
                 SELECT a.source_entity_id FROM public.product_image_assets a
                 WHERE a.product_id=cp.id AND a.image_url=(public.fn_resolve_product_image(cp.id,'GB')->>'image_url')
                 LIMIT 1)));
  -- STRICT 013Y.2: the hero image itself is present in its own gallery
  v := v || jsonb_build_object('case','hero_image_in_gallery','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(g->'images') im
                            WHERE im->>'image_url' = (public.fn_resolve_product_image(cp.id,'GB')->>'image_url'))));
  -- STRICT 013Y.2: card_source_item_id == gallery_source_item_id (explicit contract)
  v := v || jsonb_build_object('case','card_equals_gallery_field','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
                    WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
                      AND (g->>'card_source_item_id') IS DISTINCT FROM (g->>'gallery_source_item_id')));

  -- 013Y.1 retained: single identity per gallery
  v := v || jsonb_build_object('case','single_identity_per_gallery','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND (SELECT count(DISTINCT a.source_entity_id)
                 FROM jsonb_array_elements(g->'images') im
                 JOIN public.product_image_assets a
                   ON a.product_id=cp.id AND a.image_url = im->>'image_url') <> 1));
  v := v || jsonb_build_object('case','gallery_identity_matches_images','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
               jsonb_array_elements(g->'images') im
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND im->>'source_item_id' IS DISTINCT FROM g->>'gallery_source_item_id'));
  v := v || jsonb_build_object('case','images_trace_to_identity','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
               jsonb_array_elements(g->'images') im
          WHERE cp.user_id=v_owner
            AND NOT EXISTS (SELECT 1 FROM public.product_image_assets a
                            WHERE a.product_id=cp.id AND a.image_url=im->>'image_url'
                              AND a.source_entity_id=g->>'gallery_source_item_id')));
  v := v || jsonb_build_object('case','max_5_images','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
                    WHERE cp.user_id=v_owner AND (g->>'count')::int > 5));
  v := v || jsonb_build_object('case','no_duplicate_urls','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
                      jsonb_array_elements(g->'images') im
                    WHERE cp.user_id=v_owner GROUP BY cp.id, im->>'image_url' HAVING count(*) > 1));
  v := v || jsonb_build_object('case','exactly_one_primary','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
                    WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
                      AND (SELECT count(*) FROM jsonb_array_elements(g->'images') im WHERE (im->>'is_primary')::boolean) <> 1));
  v := v || jsonb_build_object('case','no_cross_product_leakage','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
                      jsonb_array_elements(g->'images') im
                    WHERE cp.user_id=v_owner
                      AND NOT EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.product_id=cp.id AND a.image_url=im->>'image_url')));
  v := v || jsonb_build_object('case','gb_de_same_gallery','pass', (g_gb->'images' = g_de->'images'));
  v := v || jsonb_build_object('case','deterministic_order','pass', (g_hu->'images' = public.fn_resolve_product_gallery(v_hu,5)->'images'));
  v := v || jsonb_build_object('case','gallery_state_truthful','pass',
        (g_ca->>'gallery_state' IN ('PENDING_RESEARCH','UNAVAILABLE_NO_SOURCE') AND (g_ca->>'count')::int=0));
  v := v || jsonb_build_object('case','pending_no_fabrication','pass', jsonb_array_length(g_ca->'images')=0);
  v := v || jsonb_build_object('case','no_ai_or_web_sources','pass',
        NOT EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.source_provider NOT IN ('CJ_SUPPLIER','EBAY_BROWSE')));

  RETURN jsonb_build_object('suite','product_gallery',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_product_gallery_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_product_gallery_selftest() TO service_role;

-- 4) hero resolver: within the hero identity, return the MAIN full-size image (lowest
--    gallery_position) so the card hero == gallery[1] exactly (avoids search-thumbnail
--    vs getItem full-size URL-variant mismatch). Identity selection is IDENTICAL to the
--    gallery resolver, so card identity == gallery identity by construction. Supplier
--    fallback and research-state logic unchanged.
CREATE OR REPLACE FUNCTION public.fn_resolve_product_image(p_product_id uuid, p_market text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE r record; v_prov text; v_eid text; v_fallback text; v_research_done boolean;
BEGIN
  SELECT source_provider, source_entity_id INTO v_prov, v_eid
  FROM public.product_image_assets
  WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false AND availability='AVAILABLE'
    AND coalesce(image_url,'')<>'' AND coalesce(source_entity_id,'')<>''
  ORDER BY is_primary DESC,
           CASE source_provider WHEN 'CJ_SUPPLIER' THEN 0 WHEN 'EBAY_BROWSE' THEN 1 ELSE 2 END, image_url
  LIMIT 1;

  IF v_eid IS NOT NULL THEN
    SELECT image_url, source_provider, source_url, market INTO r
    FROM public.product_image_assets
    WHERE product_id=p_product_id AND source_provider=v_prov AND source_entity_id=v_eid
      AND coalesce(is_fixture,false)=false AND availability='AVAILABLE' AND coalesce(image_url,'')<>''
    ORDER BY coalesce((provenance->>'gallery_position')::int, 999) ASC, is_primary DESC, image_url
    LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('image_url', r.image_url,
        'source', CASE r.source_provider WHEN 'CJ_SUPPLIER' THEN 'SUPPLIER_PROVIDED'
                                         WHEN 'EBAY_BROWSE' THEN 'MARKETPLACE_LISTING' ELSE r.source_provider END,
        'source_url', r.source_url, 'source_provider', r.source_provider, 'market', r.market, 'image_state','AVAILABLE');
    END IF;
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

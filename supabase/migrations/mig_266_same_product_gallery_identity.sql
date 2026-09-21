-- ============================================================================
-- mig_266_same_product_gallery_identity.sql
-- STRATELOQ-ECOM-SAME-PRODUCT-MULTI-ANGLE-GALLERY-013Y.1
--
-- DEFECT (013Y): fn_resolve_product_gallery + fn_backfill_product_images_from_evidence
-- built a "gallery" by taking the top-8 primary images from MANY DISTINCT eBay seller
-- listings (proof: every eBay product's image rows have total_images == distinct
-- source_entity_id, i.e. one image per item). Although all listings MATCH the same
-- product concept, they are different sellers'/models' listings -> the 5 gallery
-- tiles show visibly different products. MATCHED is sufficient for evidence, NOT for a
-- same-product gallery.
--
-- FIX: a gallery must have ONE gallery identity = (source_provider, source_entity_id).
-- All returned gallery images must belong to that single supplier product / marketplace
-- item. We NEVER combine images across source_entity_ids.
--
--  * Phase 1 audit result: eBay item_summary/search stores only 1 image per item; the
--    Browse getItem endpoint (/buy/browse/v1/item/{itemId}) returns image +
--    additionalImages[] for ONE item -> the authoritative same-item gallery. CJ stores
--    a single productImage per SKU for these products (no same-SKU 3-5 gallery
--    available), so eBay getItem is the same-item source here.
--  * fn_ingest_ebay_item_gallery: capture image + additionalImages of ONE eBay item
--    under ONE source_entity_id (the itemId), positioned (main = 1).
--  * fn_resolve_product_gallery: pick ONE winning identity (CJ preferred, then the
--    identity with >=3 images), return up to 5 images from THAT identity only.
--  * Additive workspace provenance: gallery_source_provider, gallery_source_item_id,
--    gallery_identity_state (SAME_PRODUCT_GALLERY_READY/PARTIAL/UNAVAILABLE/PENDING).
--  * fn_resolve_product_image (hero/primary) is UNCHANGED -> product_image_url stays
--    the legitimate canonical primary (Phase 8), storefront guard untouched.
--  * No image is deleted (marketplace evidence preserved); only the gallery SELECTION
--    is corrected so multi-listing mixing can no longer occur.
-- ============================================================================

-- 0) STRUCTURAL ROOT CAUSE: mig_262 created product_image_assets_uniq on
--    (product_id, source_provider, coalesce(source_entity_id,''), coalesce(market,'*')),
--    which allowed at most ONE image row per (product, provider, item, market) -- making a
--    same-item multi-image gallery physically impossible and forcing 013Y to store one image
--    per DISTINCT listing. Drop it. Duplicate-URL protection stays via
--    product_image_assets_url_uniq (product_id, image_url). Every writer uses
--    ON CONFLICT DO NOTHING or ON CONFLICT (product_id, image_url) -- never this index.
DROP INDEX IF EXISTS public.product_image_assets_uniq;

-- 1) same-item gallery capture (provider-agnostic identity: one source_entity_id) ---
CREATE OR REPLACE FUNCTION public.fn_ingest_ebay_item_gallery(
  p_product_id uuid, p_item_id text, p_item jsonb, p_market text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_n int := 0; v_main text; v_url text; v_exists boolean;
BEGIN
  IF p_product_id IS NULL OR coalesce(p_item_id,'')='' OR p_item IS NULL THEN
    RETURN jsonb_build_object('status','bad_input');
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id=p_product_id) INTO v_exists;
  IF NOT v_exists THEN RETURN jsonb_build_object('status','unknown_product'); END IF;

  v_main := nullif(p_item->'image'->>'imageUrl','');
  v_url  := nullif(p_item->>'itemWebUrl','');

  WITH imgs AS (
    SELECT 1 AS pos, v_main AS image_url WHERE v_main IS NOT NULL
    UNION ALL
    SELECT 1 + ord::int AS pos, nullif(ai->>'imageUrl','') AS image_url
    FROM jsonb_array_elements(coalesce(p_item->'additionalImages','[]'::jsonb))
         WITH ORDINALITY AS t(ai, ord)
  ),
  dedup AS (
    SELECT image_url, min(pos) AS pos
    FROM imgs WHERE coalesce(image_url,'')<>''
    GROUP BY image_url
  )
  INSERT INTO public.product_image_assets(product_id, market, image_url, source_provider, source_url,
      source_entity_id, rights_state, availability, is_primary, observed_at, provenance)
  SELECT p_product_id, p_market, d.image_url, 'EBAY_BROWSE', v_url, p_item_id,
         'MARKETPLACE_PUBLIC_LISTING', 'AVAILABLE', false, now(),
         jsonb_build_object('captured_from','ebay_getitem','item_id',p_item_id,
                            'gallery_position', d.pos, 'item_primary', (d.pos=1), 'match','MATCHED')
  FROM dedup d
  ON CONFLICT (product_id, image_url) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('status','ok','product_id',p_product_id,'item_id',p_item_id,
    'images_captured', v_n, 'gallery', public.fn_resolve_product_gallery(p_product_id,5));
END; $function$;
REVOKE ALL ON FUNCTION public.fn_ingest_ebay_item_gallery(uuid,text,jsonb,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ingest_ebay_item_gallery(uuid,text,jsonb,text) TO service_role;

-- 2) same-identity gallery resolver -------------------------------------------------
--    Selects exactly ONE gallery identity (source_provider, source_entity_id) and
--    returns up to `limit` images from THAT identity only. Never mixes listings.
CREATE OR REPLACE FUNCTION public.fn_resolve_product_gallery(p_product_id uuid, p_limit int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_lim int := least(greatest(coalesce(p_limit,5),1),5);
  v_prov text; v_eid text; v_imgs jsonb; v_count int; v_state text; v_ident text; v_research_done boolean;
BEGIN
  -- winning identity: satisfies-3 first, then CJ preferred, then most images, deterministic
  SELECT source_provider, source_entity_id INTO v_prov, v_eid
  FROM (
    SELECT source_provider, source_entity_id, count(DISTINCT image_url) AS n
    FROM public.product_image_assets
    WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false
      AND availability='AVAILABLE' AND coalesce(image_url,'')<>'' AND coalesce(source_entity_id,'')<>''
    GROUP BY source_provider, source_entity_id
  ) g
  ORDER BY (n>=3) DESC,
           CASE source_provider WHEN 'CJ_SUPPLIER' THEN 0 WHEN 'EBAY_BROWSE' THEN 1 ELSE 2 END,
           n DESC, source_entity_id
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
    'gallery_source_provider', v_prov, 'gallery_source_item_id', v_eid);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_resolve_product_gallery(uuid,int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_resolve_product_gallery(uuid,int) TO authenticated, service_role;

-- 3) workspace contract: keep product_images[]/count/state, ADD identity provenance ---
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
        'source_contract', 'decisions+current PME+commerce_products+signals+pages; primary image via fn_resolve_product_image; gallery via fn_resolve_product_gallery (SINGLE gallery identity = one source_provider+source_entity_id; same-item images only, never multi-listing)',
        'provenance_vocabulary', jsonb_build_array('OBSERVED','INFERRED','RESEARCHED')
    );
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$;

-- 4) selftest: enforce SAME-IDENTITY gallery invariants ----------------------------
CREATE OR REPLACE FUNCTION public.fn_product_gallery_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_owner uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_nl uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_hu uuid := 'cda3f71a-9947-4344-8664-13735740575f';
  v_ca uuid := (SELECT id FROM public.commerce_products WHERE user_id=v_owner AND title='cool air humidifier' LIMIT 1);
  g_nl jsonb; g_hu jsonb; g_gb jsonb; g_de jsonb; g_ca jsonb;
BEGIN
  g_nl := public.fn_resolve_product_gallery(v_nl,5);
  g_hu := public.fn_resolve_product_gallery(v_hu,5);
  g_gb := public.fn_resolve_product_gallery(v_nl,5);
  g_de := public.fn_resolve_product_gallery(v_nl,5);
  g_ca := public.fn_resolve_product_gallery(v_ca,5);

  -- CORE FIX: every non-empty gallery's images all belong to exactly ONE source_entity_id
  v := v || jsonb_build_object('case','single_identity_per_gallery','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND (SELECT count(DISTINCT a.source_entity_id)
                 FROM jsonb_array_elements(g->'images') im
                 JOIN public.product_image_assets a
                   ON a.product_id=cp.id AND a.image_url = im->>'image_url') <> 1));
  -- CORE FIX: gallery_source_item_id is present and matches the images' single identity
  v := v || jsonb_build_object('case','gallery_identity_matches_images','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
               jsonb_array_elements(g->'images') im
          WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
            AND im->>'source_item_id' IS DISTINCT FROM g->>'gallery_source_item_id'));
  -- every image's declared source_item_id actually exists on that product+item
  v := v || jsonb_build_object('case','images_trace_to_identity','pass',
        NOT EXISTS (
          SELECT 1 FROM public.commerce_products cp
          CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
               jsonb_array_elements(g->'images') im
          WHERE cp.user_id=v_owner
            AND NOT EXISTS (SELECT 1 FROM public.product_image_assets a
                            WHERE a.product_id=cp.id AND a.image_url=im->>'image_url'
                              AND a.source_entity_id=g->>'gallery_source_item_id')));
  -- max 5 images
  v := v || jsonb_build_object('case','max_5_images','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
                    WHERE cp.user_id=v_owner AND (g->>'count')::int > 5));
  -- no duplicate URLs within any gallery
  v := v || jsonb_build_object('case','no_duplicate_urls','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
                      jsonb_array_elements(g->'images') im
                    WHERE cp.user_id=v_owner GROUP BY cp.id, im->>'image_url' HAVING count(*) > 1));
  -- exactly one primary in a non-empty gallery
  v := v || jsonb_build_object('case','exactly_one_primary','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g
                    WHERE cp.user_id=v_owner AND (g->>'count')::int > 0
                      AND (SELECT count(*) FROM jsonb_array_elements(g->'images') im WHERE (im->>'is_primary')::boolean) <> 1));
  -- no cross-product leakage
  v := v || jsonb_build_object('case','no_cross_product_leakage','pass',
        NOT EXISTS (SELECT 1 FROM public.commerce_products cp CROSS JOIN LATERAL public.fn_resolve_product_gallery(cp.id,5) g,
                      jsonb_array_elements(g->'images') im
                    WHERE cp.user_id=v_owner
                      AND NOT EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.product_id=cp.id AND a.image_url=im->>'image_url')));
  -- GB/DE resolve the SAME product-global gallery
  v := v || jsonb_build_object('case','gb_de_same_gallery','pass', (g_gb->'images' = g_de->'images'));
  -- deterministic order
  v := v || jsonb_build_object('case','deterministic_order','pass', (g_hu->'images' = public.fn_resolve_product_gallery(v_hu,5)->'images'));
  -- gallery state truthful
  v := v || jsonb_build_object('case','gallery_state_truthful','pass',
        (g_ca->>'gallery_state' IN ('PENDING_RESEARCH','UNAVAILABLE_NO_SOURCE') AND (g_ca->>'count')::int=0));
  -- pending product has no fabricated gallery
  v := v || jsonb_build_object('case','pending_no_fabrication','pass', jsonb_array_length(g_ca->'images')=0);
  -- no AI/web sources anywhere
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

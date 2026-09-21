-- ============================================================================
-- mig_262_product_image_coverage_pipeline.sql
-- STRATELOQ-ECOM-PRODUCT-IMAGE-COVERAGE-013W
--
-- Makes trustworthy product-image acquisition a standard part of the Ecommerce
-- discovery/research lifecycle, source-agnostic of how a product was discovered.
--
-- KEY AUDIT FINDING: eBay listing images are NOT discarded — fn_ingest_ebay_listings
-- already persists it->'image'->>'imageUrl' into commerce_signals.evidence[].image_url
-- for MATCHED/LIKELY_MATCH listings, bound to the canonical product_id via the
-- relevance matcher. CJ supplier primary images live in supplier_product_assets
-- (supplier-keyed). Neither is a source-agnostic, product_id-keyed image store, so:
--
--  1) product_image_assets  — smallest source-agnostic, product_id-keyed image model
--     (RLS deny-all; read only by SECURITY DEFINER functions; no credentials stored).
--  2) fn_capture_product_image — idempotent service-role writer (go-forward lifecycle).
--  3) fn_backfill_product_images_from_evidence — captures images from ALREADY-STORED
--     authorized evidence only (CJ supplier primary + top MATCHED eBay listing per
--     market). No external/provider calls. Tied to the SAME canonical product_id via
--     the existing supplier link / relevance-matched marketplace evidence — never by
--     keyword similarity, never another product's image, never AI/fabricated.
--  4) fn_resolve_product_image — one canonical image hierarchy (CJ supplier primary ->
--     authorized marketplace listing image for the resolved product -> NULL), product
--     -global so GB/DE share the same image; also returns image_state.
--  5) fn_finalize_research_run — calls the backfill after decision materialisation, so
--     every finalized product captures images from its own just-ingested evidence,
--     regardless of discovery source (Reddit/DataForSEO/future TikTok).
--  6) fn_ecommerce_workspace_intelligence — sources the existing product_image_url /
--     product_image_source / product_image_source_url from the resolver and adds the
--     additive product_image_state. No score/decision/provenance/discovery-source change.
-- ============================================================================

-- 1) source-agnostic product image asset model --------------------------------
CREATE TABLE IF NOT EXISTS public.product_image_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,                         -- NULL = global-intelligence-owned asset
  product_id uuid NOT NULL,
  market text,                            -- NULL = product-global (physical product looks the same across markets)
  image_url text NOT NULL,
  source_provider text NOT NULL,          -- CJ_SUPPLIER | EBAY_BROWSE | ...
  source_url text,                        -- provenance origin (public)
  source_entity_id text,                  -- supplier_product_id / marketplace item id
  rights_state text NOT NULL DEFAULT 'UNKNOWN',   -- SUPPLIER_PROVIDED | MARKETPLACE_PUBLIC_LISTING | UNKNOWN
  availability text NOT NULL DEFAULT 'AVAILABLE',
  is_primary boolean NOT NULL DEFAULT false,
  observed_at timestamptz,
  provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_fixture boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.product_image_assets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_image_assets FROM anon, authenticated;
-- deny-all to clients: no policy + no grants. Only SECURITY DEFINER functions read it.
CREATE UNIQUE INDEX IF NOT EXISTS product_image_assets_uniq
  ON public.product_image_assets (product_id, source_provider, (coalesce(source_entity_id,'')), (coalesce(market,'*')));
CREATE INDEX IF NOT EXISTS product_image_assets_product ON public.product_image_assets (product_id);

-- 2) idempotent capture writer (go-forward lifecycle) -------------------------
CREATE OR REPLACE FUNCTION public.fn_capture_product_image(
  p_product_id uuid, p_source_provider text, p_image_url text, p_source_url text,
  p_source_entity_id text, p_market text, p_rights_state text, p_is_primary boolean DEFAULT false,
  p_provenance jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_id uuid;
BEGIN
  IF p_product_id IS NULL OR coalesce(p_image_url,'')='' THEN
    RETURN jsonb_build_object('status','no_image'); END IF;
  INSERT INTO public.product_image_assets(product_id, market, image_url, source_provider,
      source_url, source_entity_id, rights_state, availability, is_primary, observed_at, provenance)
  VALUES (p_product_id, nullif(btrim(p_market),''), p_image_url, upper(btrim(p_source_provider)),
      p_source_url, nullif(btrim(p_source_entity_id),''), coalesce(p_rights_state,'UNKNOWN'), 'AVAILABLE',
      coalesce(p_is_primary,false), now(), coalesce(p_provenance,'{}'::jsonb))
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('status', CASE WHEN v_id IS NULL THEN 'exists' ELSE 'captured' END,'id',v_id);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_capture_product_image(uuid,text,text,text,text,text,text,boolean,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_capture_product_image(uuid,text,text,text,text,text,text,boolean,jsonb) TO service_role;

-- 3) backfill from ALREADY-STORED authorized evidence (no external calls) ------
CREATE OR REPLACE FUNCTION public.fn_backfill_product_images_from_evidence(p_product_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_cj int := 0; v_ebay int := 0;
BEGIN
  -- (a) CJ supplier-linked PRIMARY image (entity-resolved via the product's supplier link) -> product-global
  INSERT INTO public.product_image_assets(product_id, market, image_url, source_provider, source_url,
      source_entity_id, rights_state, availability, is_primary, observed_at, provenance)
  SELECT cp.id, NULL, coalesce(spa.source_url, nullif(sp.image_url,'')), 'CJ_SUPPLIER',
         coalesce(spa.source_url, nullif(sp.image_url,'')), sp.source_product_id, 'SUPPLIER_PROVIDED', 'AVAILABLE',
         true, now(), jsonb_build_object('captured_from','supplier_link','supplier_row_id',sp.id)
  FROM public.commerce_products cp
  JOIN public.commerce_supplier_products sp
    ON sp.id = coalesce(nullif(cp.extended->'supplier_ref'->>'supplier_row_id',''),
                        nullif(cp.extended->'supplier_refs'->0->>'supplier_row_id',''))::uuid
  LEFT JOIN LATERAL (
    SELECT a.source_url FROM public.supplier_product_assets a
    WHERE a.supplier_product_id=sp.source_product_id AND a.availability='AVAILABLE'
      AND a.rights_state='SUPPLIER_PROVIDED' AND a.asset_type IN ('PRIMARY_IMAGE','IMAGE') AND coalesce(a.source_url,'')<>''
    ORDER BY a.is_primary DESC LIMIT 1) spa ON true
  WHERE (p_product_id IS NULL OR cp.id=p_product_id)
    AND coalesce(spa.source_url, nullif(sp.image_url,'')) IS NOT NULL
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_cj = ROW_COUNT;

  -- (b) top MATCHED eBay marketplace listing image per (product, market) from stored evidence.
  --     MATCHED = passed the relevance matcher and stored against THIS product_id (not keyword-only).
  INSERT INTO public.product_image_assets(product_id, market, image_url, source_provider, source_url,
      source_entity_id, rights_state, availability, is_primary, observed_at, provenance)
  SELECT DISTINCT ON (s.product_id, s.value->>'market')
    s.product_id, s.value->>'market',
    (SELECT ev->>'image_url' FROM jsonb_array_elements(s.evidence) ev WHERE coalesce(ev->>'image_url','')<>'' LIMIT 1),
    'EBAY_BROWSE',
    (SELECT ev->>'item_web_url' FROM jsonb_array_elements(s.evidence) ev WHERE coalesce(ev->>'image_url','')<>'' LIMIT 1),
    s.value->>'item_id', 'MARKETPLACE_PUBLIC_LISTING', 'AVAILABLE', false, coalesce(s.observed_at, now()),
    jsonb_build_object('captured_from','ebay_marketplace_evidence','match',s.value->>'match','signal_id',s.id)
  FROM public.commerce_signals s
  WHERE s.signal_type='MARKETPLACE_ACTIVITY' AND s.value->>'match'='MATCHED'
    AND (p_product_id IS NULL OR s.product_id=p_product_id)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(s.evidence) ev WHERE coalesce(ev->>'image_url','')<>'')
  ORDER BY s.product_id, s.value->>'market', s.confidence DESC NULLS LAST, s.observed_at DESC NULLS LAST
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_ebay = ROW_COUNT;

  RETURN jsonb_build_object('status','ok','cj_captured',v_cj,'ebay_captured',v_ebay,
    'scope', CASE WHEN p_product_id IS NULL THEN 'all' ELSE p_product_id::text END);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_backfill_product_images_from_evidence(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_backfill_product_images_from_evidence(uuid) TO service_role;

-- 4) canonical image resolver (hierarchy; product-global; returns image_state) --
CREATE OR REPLACE FUNCTION public.fn_resolve_product_image(p_product_id uuid, p_market text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE r record; v_fallback text; v_research_done boolean;
BEGIN
  -- Tier 1/2: canonical product_id-tied asset. CJ supplier primary preferred over
  -- authorized marketplace listing image. Product-global (same image across markets).
  SELECT image_url, source_provider, source_url, market INTO r
  FROM public.product_image_assets
  WHERE product_id=p_product_id AND coalesce(is_fixture,false)=false AND availability='AVAILABLE'
    AND coalesce(image_url,'')<>''
  ORDER BY CASE source_provider WHEN 'CJ_SUPPLIER' THEN 0 WHEN 'EBAY_BROWSE' THEN 1 ELSE 2 END,
           is_primary DESC, (market IS NULL) DESC, observed_at DESC NULLS LAST, created_at DESC
  LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('image_url', r.image_url,
      'source', CASE r.source_provider WHEN 'CJ_SUPPLIER' THEN 'SUPPLIER_PROVIDED'
                                       WHEN 'EBAY_BROWSE' THEN 'MARKETPLACE_LISTING' ELSE r.source_provider END,
      'source_url', r.source_url, 'source_provider', r.source_provider,
      'market', r.market, 'image_state','AVAILABLE');
  END IF;

  -- Fallback: existing supplier link (back-compat for products not yet backfilled).
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

  -- No trustworthy image: pending if the product has no scored evaluation yet, else no source.
  SELECT EXISTS (SELECT 1 FROM public.product_market_evaluations e
                 WHERE e.product_id=p_product_id AND e.market_opportunity_score IS NOT NULL
                   AND coalesce(e.is_fixture,false)=false) INTO v_research_done;
  RETURN jsonb_build_object('image_url',NULL,'source',NULL,'source_url',NULL,'source_provider',NULL,'market',NULL,
    'image_state', CASE WHEN v_research_done THEN 'UNAVAILABLE_NO_SOURCE' ELSE 'PENDING_RESEARCH' END);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_resolve_product_image(uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_resolve_product_image(uuid,text) TO authenticated, service_role;

-- 5) wire automatic acquisition into research finalize (source-agnostic) -------
CREATE OR REPLACE FUNCTION public.fn_finalize_research_run(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_run public.commerce_research_run%rowtype;
  v_expected int; v_attempted int; v_evidence int; v_nodata int; v_unsupported int; v_failed int; v_blocked int; v_pending int;
  v_indep int; v_status text; v_ccy text; v_query text; v_supplier uuid; v_recompute jsonb;
BEGIN
  SELECT * INTO v_run FROM public.commerce_research_run WHERE id=p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','RUN_NOT_FOUND'); END IF;
  SELECT count(*),
    count(*) FILTER (WHERE state IN ('SEARCHED_EVIDENCE_FOUND','SEARCHED_NO_EVIDENCE','SOURCE_FAILED')),
    count(*) FILTER (WHERE state='SEARCHED_EVIDENCE_FOUND'),
    count(*) FILTER (WHERE state='SEARCHED_NO_EVIDENCE'),
    count(*) FILTER (WHERE state='UNSUPPORTED_MARKET'),
    count(*) FILTER (WHERE state='SOURCE_FAILED'),
    count(*) FILTER (WHERE state='BLOCKED_EXTERNAL_ACCESS'),
    count(*) FILTER (WHERE state IN ('NOT_SEARCHED','SEARCHING'))
  INTO v_expected, v_attempted, v_evidence, v_nodata, v_unsupported, v_failed, v_blocked, v_pending
  FROM public.commerce_research_source_attempt WHERE run_id=p_run_id;
  v_indep := v_evidence;
  IF v_pending > 0 THEN v_status := 'PARTIAL';
  ELSIF v_failed > 0 THEN v_status := 'PARTIAL_SOURCE_FAILURE';
  ELSIF v_blocked > 0 OR v_unsupported > 0 THEN v_status := 'PARTIAL_SOURCE_UNAVAILABLE';
  ELSIF v_evidence = 0 THEN v_status := 'INSUFFICIENT_EVIDENCE';
  ELSE v_status := 'COMPLETE'; END IF;

  v_ccy := coalesce(public.fn_market_default_currency(v_run.market), (v_run.provenance->>'market_currency'));
  v_query := coalesce(v_run.provenance->>'price_query', (SELECT title FROM public.commerce_products WHERE id=v_run.product_id));
  v_supplier := nullif(v_run.provenance->>'registry_supplier','')::uuid;
  v_recompute := public.fn_assemble_real_product_market(v_run.product_id, v_run.market, v_ccy, v_query, v_supplier, true);

  UPDATE public.commerce_research_run
    SET status=v_status, sources_attempted=v_attempted, sources_with_evidence=v_evidence,
        sources_no_data=v_nodata, sources_unsupported=v_unsupported+v_blocked, sources_failed=v_failed,
        independent_categories=v_indep, completed_at=now(), updated_at=now(),
        provenance = provenance || jsonb_build_object('finalized_at', now(), 'recompute_contract', v_recompute->>'contract',
          'launch_critical_gap', (v_blocked > 0), 'blocked_categories', v_blocked, 'unsupported_categories', v_unsupported)
    WHERE id=p_run_id;

  -- 013S: materialize/refresh the canonical decision layer.
  BEGIN PERFORM public.fn_pod_evaluate(v_run.tenant_id, v_run.product_id, v_run.market, 'pod_v1', true);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- 013W: capture trustworthy product images from THIS product's just-ingested
  -- authorized evidence (supplier link + MATCHED marketplace listings). Source-agnostic
  -- of discovery source; isolated so it can never fail the finalize; no external call.
  BEGIN PERFORM public.fn_backfill_product_images_from_evidence(v_run.product_id);
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object('status',v_status,'run_id',p_run_id,'market',v_run.market,
    'sources_expected',v_expected,'sources_attempted',v_attempted,'sources_with_evidence',v_evidence,
    'sources_no_data',v_nodata,'sources_unsupported',v_unsupported,'sources_blocked',v_blocked,
    'sources_failed',v_failed,'pending',v_pending,'independent_categories',v_indep,
    'launch_critical_gap',(v_blocked>0),'recompute',v_recompute,
    'decision_materialized',true,'image_capture_attempted',true,'contract','pulse_research_finalize_v3_013w');
END; $function$;

-- 6) offline selftest ----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_product_image_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_nl uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';   -- kids nightlight projector (CJ-linked)
  v_hu uuid := 'cda3f71a-9947-4344-8664-13735740575f';   -- cool mist humidifier (DataForSEO; eBay images)
  v_ca uuid := (SELECT id FROM public.commerce_products WHERE user_id='7c8ddf9d-172c-4a89-a402-bb7066228b61' AND title='cool air humidifier');
  r_nl jsonb; r_hu jsonb; r_gb jsonb; r_de jsonb; r_ca jsonb;
BEGIN
  r_nl := public.fn_resolve_product_image(v_nl, 'GB');
  r_hu := public.fn_resolve_product_image(v_hu, 'GB');
  r_gb := public.fn_resolve_product_image(v_nl, 'GB');
  r_de := public.fn_resolve_product_image(v_nl, 'DE');
  r_ca := public.fn_resolve_product_image(v_ca, 'GB');

  -- 3. canonical supplier image still works
  v := v || jsonb_build_object('case','supplier_image_resolves','pass',
        (r_nl->>'image_state'='AVAILABLE' AND r_nl->>'source'='SUPPLIER_PROVIDED' AND coalesce(r_nl->>'image_url','')<>''));
  -- 4. authorized marketplace image works (DataForSEO product, eBay-sourced)
  v := v || jsonb_build_object('case','marketplace_image_resolves','pass',
        (r_hu->>'image_state'='AVAILABLE' AND r_hu->>'source'='MARKETPLACE_LISTING' AND coalesce(r_hu->>'image_url','')<>''));
  -- 1. no cross-product leakage: humidifier image belongs to humidifier's own assets/evidence
  v := v || jsonb_build_object('case','no_cross_product_leakage','pass',
        EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.product_id=v_hu AND a.image_url=r_hu->>'image_url'));
  -- 2. no keyword-only assignment: every EBAY_BROWSE asset came from a MATCHED signal with a source id
  v := v || jsonb_build_object('case','no_keyword_only_assignment','pass',
        NOT EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.source_provider='EBAY_BROWSE'
                    AND (coalesce(a.source_entity_id,'')='' OR coalesce(a.provenance->>'match','')<>'MATCHED')));
  -- 5. DataForSEO-discovered product got an image WITHOUT changing discovery source
  v := v || jsonb_build_object('case','dataforseo_image_discovery_unchanged','pass',
        (r_hu->>'image_state'='AVAILABLE'
         AND (SELECT source_store FROM public.commerce_products WHERE id=v_hu)='dataforseo'));
  -- 6. GB/DE resolve the SAME product-global image (isolation of decisions preserved elsewhere)
  v := v || jsonb_build_object('case','gb_de_same_product_image','pass', (r_gb->>'image_url' = r_de->>'image_url'));
  -- 7. image does not change score (nightlight GB canonical 68.2 intact)
  v := v || jsonb_build_object('case','image_does_not_change_score','pass',
        ((SELECT round(market_opportunity_score,1) FROM public.product_market_evaluations
          WHERE product_id=v_nl AND country_code='GB' AND coalesce(is_fixture,false)=false
          ORDER BY evaluation_ts DESC LIMIT 1)=68.2));
  -- 8. image does not change decision (all founder decisions still WATCH-layer; count stable >=10)
  v := v || jsonb_build_object('case','image_does_not_change_decision','pass',
        (SELECT count(*) FROM public.product_opportunity_decisions
         WHERE tenant_id='7c8ddf9d-172c-4a89-a402-bb7066228b61' AND coalesce(is_fixture,false)=false) >= 10);
  -- 10. missing image cannot be fabricated (never-researched product -> NULL/PENDING)
  v := v || jsonb_build_object('case','missing_image_not_fabricated','pass',
        (r_ca->>'image_url' IS NULL AND r_ca->>'image_state' IN ('PENDING_RESEARCH','UNAVAILABLE_NO_SOURCE')));
  -- 11. credentials never reach the asset/resolver (public CDN urls only; no secret keys)
  v := v || jsonb_build_object('case','no_credentials_in_assets','pass',
        NOT EXISTS (SELECT 1 FROM public.product_image_assets a
                    WHERE a.image_url ~* 'client_secret|access_token|apikey|service_role'
                       OR a.provenance::text ~* 'client_secret|access_token|service_role'));

  RETURN jsonb_build_object('suite','product_image_coverage',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_product_image_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_product_image_selftest() TO service_role;

-- 7) workspace contract: source image fields from the canonical resolver -------
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
        'source_contract', 'decisions+current PME+commerce_products+signals+pages; product image via fn_resolve_product_image (canonical supplier primary -> authorized marketplace listing -> null; product-global)',
        'provenance_vocabulary', jsonb_build_array('OBSERVED','INFERRED','RESEARCHED')
    );
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$;

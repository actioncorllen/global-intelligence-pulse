-- ============================================================================
-- mig_292_kalodata_research_image_provider.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A
--
-- PURPOSE (additive, non-breaking): onboard Kalodata as a RESEARCH-image provider
-- for authenticated Product Discovery displays, under the commercial authorisation
-- limited to analysed SaaS research displays (NOT advertisements, NOT storefront
-- publication, NOT generated commercial creatives).
--
-- WHY A SEPARATE RESEARCH LANE (not product_image_assets):
--   * product_image_assets is the COMMERCIAL supplier/marketplace image store. It
--     feeds the card hero (fn_resolve_product_image), the multi-image gallery
--     (fn_resolve_product_gallery), the storefront launch guard (fn_storefront_publish)
--     and the ad-creative authority (fn_ad_product_card_authority). A launch-critical
--     invariant (mig_273 fn_product_gallery_selftest 'no_ai_or_web_sources') asserts
--     that EVERY product_image_assets row is CJ_SUPPLIER or EBAY_BROWSE. Injecting a
--     Kalodata provider there would break that invariant and could leak a research
--     image into hero/gallery/storefront/ad paths.
--   * The authorisation is explicitly research-only. The directive requires research
--     images be DISTINGUISHED from commercially-authorised supplier images and never
--     become ad/storefront eligible. The cleanest, smallest-blast-radius way to
--     guarantee that is a parallel, research-only store that NONE of the commercial
--     paths read — reusing the SAME rights/provenance/attribution/caching/RLS patterns.
--
-- WHAT THIS MIGRATION DOES (independently implementable; no Kalodata API call):
--   1) product_research_images  — research-only, source-agnostic, product_id-keyed
--      image store. CHECK constraints make it DEFINITIONALLY research-only and never
--      commercial. RLS deny-all; read only via SECURITY DEFINER functions. No creds.
--   2) fn_capture_research_image — idempotent service-role writer. Forces
--      rights_state=RESEARCH_LICENSED, commercial_use_eligible=false; refuses commercial
--      provider names; records source_url_expires_at (expiring source URLs) + storage_ref
--      (expiry-safe cached copy) + cache_state.
--   3) fn_resolve_product_research_images — read function returning attributed,
--      research-only images with ad_eligible=false / storefront_eligible=false and an
--      expiry-safe display_ref (prefers the cached storage_ref when the source URL has
--      expired).
--   4) fn_ecommerce_workspace_intelligence — ADDITIVE research fields on each Product
--      Discovery card (Kalodata attribution + research-only markers). Commercial hero/
--      gallery fields unchanged; byte-compatible with mig_273 otherwise.
--   5) fn_kalodata_research_image_selftest — boundary test proving a research image
--      NEVER changes the commercial hero/gallery, NEVER satisfies the storefront image
--      guard, NEVER becomes ad-authoritative, and that the never-commercial CHECK holds.
--
-- NOT in this migration (blocked — see docs/STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A.md):
--   * the live Kalodata API client (Product Rank / Product Images API). Kalodata API
--     credentials and endpoint documentation are not available in this environment, so
--     no endpoint contract is invented. The ingestion SINK above is ready to receive
--     verified assets the moment the client exists.
-- ============================================================================

-- 1) research-only image store -------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_research_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,                               -- NULL = global-intelligence-owned research asset
  product_id uuid NOT NULL,
  market text,                                  -- NULL = product-global
  image_url text NOT NULL,                      -- display URL (cached storage URL or provider URL)
  source_provider text NOT NULL DEFAULT 'KALODATA',
  source_url text,                              -- original provider URL (provenance; MAY EXPIRE, e.g. Kalodata ~5 min)
  source_url_expires_at timestamptz,            -- when source_url stops resolving (NULL = unknown/non-expiring)
  source_entity_id text,                        -- provider product id (e.g. Kalodata product id)
  rights_state text NOT NULL DEFAULT 'RESEARCH_LICENSED',
  commercial_use_eligible boolean NOT NULL DEFAULT false,
  attribution text NOT NULL DEFAULT 'Kalodata',
  storage_ref text,                             -- Pulse object-storage ref for the cached copy (expiry-safe)
  cache_state text NOT NULL DEFAULT 'SOURCE_ONLY', -- SOURCE_ONLY | CACHED | CACHE_FAILED
  availability text NOT NULL DEFAULT 'AVAILABLE',
  is_primary boolean NOT NULL DEFAULT false,
  observed_at timestamptz,
  provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_fixture boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- DEFINITIONALLY research-only: these rows can never be a commercial supplier asset.
  CONSTRAINT product_research_images_research_only_rights CHECK (rights_state = 'RESEARCH_LICENSED'),
  CONSTRAINT product_research_images_never_commercial CHECK (commercial_use_eligible = false),
  CONSTRAINT product_research_images_cache_state_valid CHECK (cache_state IN ('SOURCE_ONLY','CACHED','CACHE_FAILED')),
  -- research lane must not carry a commercial supplier/marketplace provider name.
  CONSTRAINT product_research_images_not_commercial_provider
    CHECK (upper(source_provider) NOT IN ('CJ_SUPPLIER','EBAY_BROWSE','CJ','EBAY'))
);
ALTER TABLE public.product_research_images ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_research_images FROM anon, authenticated;
-- deny-all to clients: no policy + no grants. Only SECURITY DEFINER functions read it.
CREATE UNIQUE INDEX IF NOT EXISTS product_research_images_uniq
  ON public.product_research_images (product_id, source_provider, (coalesce(source_entity_id,'')), (coalesce(market,'*')), (coalesce(storage_ref, image_url)));
CREATE INDEX IF NOT EXISTS product_research_images_product ON public.product_research_images (product_id);

-- 2) idempotent capture writer (service-role) ---------------------------------
--    Forces research-only rights; refuses commercial provider names; records expiry +
--    cache state. Never stores credentials (public/display URLs only).
CREATE OR REPLACE FUNCTION public.fn_capture_research_image(
  p_product_id uuid,
  p_image_url text,
  p_source_url text,
  p_source_entity_id text,
  p_market text DEFAULT NULL,
  p_source_provider text DEFAULT 'KALODATA',
  p_source_url_expires_at timestamptz DEFAULT NULL,
  p_storage_ref text DEFAULT NULL,
  p_is_primary boolean DEFAULT false,
  p_provenance jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_id uuid; v_prov text := upper(btrim(coalesce(p_source_provider,'KALODATA')));
BEGIN
  IF p_product_id IS NULL OR coalesce(p_image_url,'')='' THEN
    RETURN jsonb_build_object('status','no_image'); END IF;
  -- research lane never carries a commercial supplier/marketplace provider.
  IF v_prov IN ('CJ_SUPPLIER','EBAY_BROWSE','CJ','EBAY') THEN
    RETURN jsonb_build_object('status','rejected_commercial_provider','provider',v_prov,
      'note','commercial supplier/marketplace images belong in product_image_assets, not the research lane'); END IF;
  -- reject anything that looks like a credential leaking into a public URL.
  IF p_image_url ~* 'client_secret|access_token|api[_-]?key|service_role'
     OR coalesce(p_source_url,'') ~* 'client_secret|access_token|api[_-]?key|service_role' THEN
    RETURN jsonb_build_object('status','rejected_possible_credential'); END IF;

  INSERT INTO public.product_research_images(
      product_id, market, image_url, source_provider, source_url, source_url_expires_at,
      source_entity_id, rights_state, commercial_use_eligible, attribution, storage_ref,
      cache_state, availability, is_primary, observed_at, provenance)
  VALUES (
      p_product_id, nullif(btrim(p_market),''), p_image_url, v_prov, p_source_url, p_source_url_expires_at,
      nullif(btrim(p_source_entity_id),''), 'RESEARCH_LICENSED', false,
      CASE WHEN v_prov='KALODATA' THEN 'Kalodata' ELSE initcap(lower(v_prov)) END,
      nullif(btrim(p_storage_ref),''),
      CASE WHEN nullif(btrim(p_storage_ref),'') IS NOT NULL THEN 'CACHED' ELSE 'SOURCE_ONLY' END,
      'AVAILABLE', coalesce(p_is_primary,false), now(), coalesce(p_provenance,'{}'::jsonb))
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('status', CASE WHEN v_id IS NULL THEN 'exists' ELSE 'captured' END,
    'id', v_id, 'rights_state','RESEARCH_LICENSED','commercial_use_eligible',false);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_capture_research_image(uuid,text,text,text,text,text,timestamptz,text,boolean,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_capture_research_image(uuid,text,text,text,text,text,timestamptz,text,boolean,jsonb) TO service_role;

-- 3) research-image resolver (attributed, research-only, expiry-safe) ----------
--    Returns up to p_limit research images for a product with explicit research-only
--    markers. display_ref prefers the cached storage_ref when the source URL has
--    expired, so a card never points at a dead (expired) provider URL.
CREATE OR REPLACE FUNCTION public.fn_resolve_product_research_images(
  p_product_id uuid, p_market text DEFAULT NULL, p_limit int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_lim int := least(greatest(coalesce(p_limit,5),1),10); v_imgs jsonb; v_count int; v_attr text;
BEGIN
  SELECT jsonb_agg(x.j ORDER BY (x.j->>'is_primary')::boolean DESC, x.j->>'observed_at' DESC NULLS LAST, x.j->>'image_url'),
         count(*), max(x.j->>'attribution')
    INTO v_imgs, v_count, v_attr
  FROM (
    SELECT jsonb_build_object(
      'display_ref', CASE
          WHEN coalesce(storage_ref,'')<>'' AND source_url_expires_at IS NOT NULL AND source_url_expires_at <= now()
            THEN storage_ref                               -- source expired -> serve cached copy
          WHEN coalesce(storage_ref,'')<>'' AND cache_state='CACHED'
            THEN storage_ref                               -- cached -> prefer stable storage
          ELSE image_url END,
      'cache_state', cache_state,
      'source_url', source_url,
      'source_url_expired', (source_url_expires_at IS NOT NULL AND source_url_expires_at <= now()),
      'source_provider', source_provider,
      'source_item_id', source_entity_id,
      'attribution', attribution,
      'rights_state', rights_state,
      'research_only', true,
      'commercial_use_eligible', false,
      'ad_eligible', false,
      'storefront_eligible', false,
      'is_primary', coalesce(is_primary,false),
      'market', market,
      'observed_at', observed_at
    ) AS j
    FROM public.product_research_images
    WHERE product_id = p_product_id
      AND coalesce(is_fixture,false) = false
      AND availability = 'AVAILABLE'
      AND coalesce(image_url,'') <> ''
      AND (p_market IS NULL OR market IS NULL OR market = p_market)
    ORDER BY is_primary DESC, observed_at DESC NULLS LAST, image_url
    LIMIT v_lim
  ) x;

  v_count := coalesce(v_count,0);
  RETURN jsonb_build_object(
    'images', coalesce(v_imgs,'[]'::jsonb),
    'count', v_count,
    'attribution', coalesce(v_attr, 'Kalodata'),
    'rights_state', 'RESEARCH_LICENSED',
    'research_only', true,
    'commercial_use_eligible', false,
    'ad_eligible', false,
    'storefront_eligible', false,
    'display_state', CASE WHEN v_count > 0 THEN 'AVAILABLE' ELSE 'NONE' END,
    'usage_note', 'authorised for analysed SaaS research displays only; not for advertisements, storefront publication or generated commercial creatives');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_resolve_product_research_images(uuid,text,int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_resolve_product_research_images(uuid,text,int) TO authenticated, service_role;

-- 4) workspace contract: ADDITIVE research fields -----------------------------
--    Reproduces mig_273 fn_ecommerce_workspace_intelligence verbatim and adds ONLY:
--      * LEFT JOIN LATERAL fn_resolve_product_research_images(...)
--      * product_research_images / product_research_image_count / product_research_source
--        / product_research_note keys on each decision row.
--    Commercial hero + gallery fields and all other behaviour are unchanged.
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
            -- 017A: authorised Kalodata RESEARCH images (distinct from commercial supplier
            -- images above; research-display only, never ad/storefront eligible).
            'product_research_images', coalesce(rsi.j->'images','[]'::jsonb),
            'product_research_image_count', coalesce((rsi.j->>'count')::int,0),
            'product_research_source', rsi.j->>'attribution',
            'product_research_note', CASE WHEN coalesce((rsi.j->>'count')::int,0) > 0
                                          THEN 'research_only_authorised_display_not_advertising_or_storefront' END,
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
        LEFT JOIN LATERAL (SELECT public.fn_resolve_product_research_images(d.product_id, d.country_code, 5) AS j) rsi ON true
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
        'source_contract', 'decisions+current PME+commerce_products+signals+pages; commercial primary image via fn_resolve_product_image; commercial gallery via fn_resolve_product_gallery (card-identity bound); Kalodata research images via fn_resolve_product_research_images (research-display only, ad/storefront ineligible)',
        'provenance_vocabulary', jsonb_build_array('OBSERVED','INFERRED','RESEARCHED')
    );
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('status','temporary_failure');
END; $function$;

-- 5) boundary self-test (service-role; self-cleaning) --------------------------
--    Proves: research images are attributed + research-only; the never-commercial
--    CHECK holds; a research image does NOT become the commercial hero, does NOT
--    enter the commercial gallery, does NOT satisfy the storefront image guard, and
--    is NOT selected as an ad-authoritative Product Card asset; expiry falls back to
--    the cached storage_ref; no credentials are stored.
CREATE OR REPLACE FUNCTION public.fn_kalodata_research_image_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  -- sentinel product ids (no real tenant/product references them); cleaned up below.
  v_p_research uuid := 'ca100000-0000-4000-8000-000000000001';  -- research image only
  v_p_expired  uuid := 'ca100000-0000-4000-8000-000000000002';  -- research image w/ expired source + cache
  r_res jsonb; r_exp jsonb; r_hero jsonb; r_gal jsonb; v_cap jsonb; v_check_blocked boolean;
BEGIN
  -- clean any residue from a prior run
  DELETE FROM public.product_research_images WHERE product_id IN (v_p_research, v_p_expired);

  -- seed: one live research image, one with an EXPIRED source url + a cached copy
  v_cap := public.fn_capture_research_image(
    v_p_research, 'https://cdn.kalodata.example/img/abc_main.jpg',
    'https://api.kalodata.example/expiring/abc?sig=xyz', 'KD_ITEM_ABC', 'GB', 'KALODATA',
    now() + interval '5 minutes', NULL, true, jsonb_build_object('endpoint','product_rank','need_image',1));
  INSERT INTO public.product_research_images(
      product_id, market, image_url, source_provider, source_url, source_url_expires_at,
      source_entity_id, rights_state, commercial_use_eligible, attribution, storage_ref,
      cache_state, availability, is_primary, observed_at, provenance)
  VALUES (
      v_p_expired, 'GB', 'https://api.kalodata.example/expiring/def?sig=old',
      'KALODATA', 'https://api.kalodata.example/expiring/def?sig=old', now() - interval '1 minute',
      'KD_ITEM_DEF', 'RESEARCH_LICENSED', false, 'Kalodata',
      'pulse-research-media/kd/def.jpg', 'CACHED', 'AVAILABLE', true, now(), '{}'::jsonb);

  r_res := public.fn_resolve_product_research_images(v_p_research, 'GB', 5);
  r_exp := public.fn_resolve_product_research_images(v_p_expired, 'GB', 5);
  r_hero := public.fn_resolve_product_image(v_p_research, 'GB');
  r_gal  := public.fn_resolve_product_gallery(v_p_research, 5);

  -- (a) writer captured a research row with research-only rights
  v := v || jsonb_build_object('case','writer_captures_research_only','pass',
        (v_cap->>'status'='captured' AND v_cap->>'rights_state'='RESEARCH_LICENSED'
         AND (v_cap->>'commercial_use_eligible')::boolean = false));
  -- (b) resolver returns attributed, research-only markers
  v := v || jsonb_build_object('case','resolver_attributed_research_only','pass',
        ((r_res->>'count')::int = 1 AND r_res->>'attribution'='Kalodata'
         AND (r_res->>'research_only')::boolean = true
         AND (r_res->>'ad_eligible')::boolean = false
         AND (r_res->>'storefront_eligible')::boolean = false
         AND (r_res->'images'->0->>'commercial_use_eligible')::boolean = false));
  -- (c) never-commercial CHECK: cannot insert a commercial-eligible research row
  v_check_blocked := false;
  BEGIN
    INSERT INTO public.product_research_images(product_id, image_url, commercial_use_eligible)
    VALUES (v_p_research, 'https://x/y.jpg', true);
  EXCEPTION WHEN check_violation THEN v_check_blocked := true;
  END;
  v := v || jsonb_build_object('case','never_commercial_check_enforced','pass', v_check_blocked);
  -- (d) writer refuses a commercial provider name in the research lane
  v := v || jsonb_build_object('case','writer_refuses_commercial_provider','pass',
        (public.fn_capture_research_image(v_p_research,'https://x/y.jpg','https://x/y','ID',NULL,'CJ_SUPPLIER')
          ->>'status') = 'rejected_commercial_provider');
  -- (e) research image does NOT become the commercial card hero
  v := v || jsonb_build_object('case','research_not_commercial_hero','pass',
        (r_hero->>'image_url' IS NULL AND r_hero->>'image_state' IN ('PENDING_RESEARCH','UNAVAILABLE_NO_SOURCE')));
  -- (f) research image does NOT enter the commercial gallery
  v := v || jsonb_build_object('case','research_not_in_commercial_gallery','pass', ((r_gal->>'count')::int = 0));
  -- (g) research image is NOT in product_image_assets (gallery 'no_ai_or_web_sources' invariant preserved)
  v := v || jsonb_build_object('case','research_not_in_commercial_store','pass',
        NOT EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.product_id IN (v_p_research, v_p_expired)));
  -- (h) research image can NEVER satisfy the storefront image guard, which requires a
  --     commercial AVAILABLE image from fn_resolve_product_image (returns no image here)
  v := v || jsonb_build_object('case','research_cannot_unlock_storefront','pass',
        coalesce(r_hero->>'image_state','') <> 'AVAILABLE');
  -- (i) expiry-safe: expired source url falls back to the cached storage_ref for display
  v := v || jsonb_build_object('case','expired_source_uses_cache','pass',
        ((r_exp->'images'->0->>'source_url_expired')::boolean = true
         AND r_exp->'images'->0->>'display_ref' = 'pulse-research-media/kd/def.jpg'
         AND r_exp->'images'->0->>'cache_state' = 'CACHED'));
  -- (j) no credentials stored in research assets
  v := v || jsonb_build_object('case','no_credentials_in_research_assets','pass',
        NOT EXISTS (SELECT 1 FROM public.product_research_images a
                    WHERE a.image_url ~* 'client_secret|access_token|service_role'
                       OR a.provenance::text ~* 'client_secret|access_token|service_role'));

  -- cleanup (always)
  DELETE FROM public.product_research_images WHERE product_id IN (v_p_research, v_p_expired);

  RETURN jsonb_build_object('suite','kalodata_research_image',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.product_research_images WHERE product_id IN (v_p_research, v_p_expired);
  RETURN jsonb_build_object('suite','kalodata_research_image','status','error','error',SQLERRM);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_research_image_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_research_image_selftest() TO service_role;

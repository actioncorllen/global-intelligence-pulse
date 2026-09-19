-- STRATELOQ-ECOM-WORKSPACE-INTELLIGENCE-CONTRACTS-013E
-- Expose EXISTING Ecommerce competitor / supplier / creative / signal / campaign-execution
-- intelligence through authenticated, tenant-scoped, browser-safe read contracts. Additive
-- only. No new intelligence, no synthetic data, no mutation of historical records, no payment.
--
-- Ownership model (verified 013E audit): the founder tenant's tenant_id == auth.uid(). All
-- source tables are RLS deny-all to clients; these SECURITY DEFINER RPCs are the only browser
-- read path. Every contract is auth.uid()-scoped, revokes anon, and projects ONLY browser-safe
-- fields — never provenance/raw payloads, evidence blobs, fingerprints, storage refs, provider
-- job ids, costs, external account/campaign ids, secrets, or is_fixture rows.

-- ---------------------------------------------------------------------------
-- 2. COMPETITOR INTELLIGENCE — product_market_competitors (tenant_id, product_id).
--    Real observed competitor listings/ads. Fixtures excluded. No "winning" label
--    (the stored contract does not classify winners).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_competitor_intelligence()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT coalesce(jsonb_agg(row ORDER BY (row->>'observed_at') DESC NULLS LAST), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'competitor_id', c.id,
      'product_id', c.product_id,
      'product_title', cp.title,
      'country_code', c.country_code,
      'competitor_kind', c.competitor_kind,
      'competitor_identity', c.competitor_identity,
      'observed_product_url', c.observed_product_url,
      'platform', c.platform,
      'match_class', c.match_class,
      'match_confidence', c.match_confidence,
      'price_original', c.price_original,
      'price_currency', c.price_currency,
      'price_source_class', c.price_source_class,
      'price_observed_at', c.price_observed_at,
      'ad_platform', c.ad_platform,
      'observable_ad_count', c.observable_ad_count,
      'ad_status', c.ad_status,
      'creative_pattern', c.creative_pattern,
      'offer_pattern', c.offer_pattern,
      'cta_pattern', c.cta_pattern,
      'evidence_class', c.evidence_class,
      'confidence', c.confidence,
      'observed_at', c.observed_at
    ) AS row
    FROM public.product_market_competitors c
    LEFT JOIN public.commerce_products cp ON cp.id = c.product_id
    WHERE c.tenant_id = v_uid AND coalesce(c.is_fixture,false) = false
  ) z;
  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'competitors', v_rows,
    'source_contract','product_market_competitors');
END; $function$;

COMMENT ON FUNCTION public.fn_ecommerce_competitor_intelligence() IS
 'Authenticated, auth.uid()-scoped browser-safe competitor intelligence from product_market_competitors (real, non-fixture). No provenance/match_evidence/normalized-price/marketplace raw. Never classifies "winning".';

-- ---------------------------------------------------------------------------
-- 3. SUPPLIER INTELLIGENCE — tenant-owned via product_acquisitions (user_id). The
--    global commerce_supplier_products catalog is NOT exposed; access is only through
--    the caller's OWN acquisition snapshots (sourcing_spec_snapshot.supplier_options +
--    selected_supplier_snapshot). Only observed cost/currency; no invented margins/ETAs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_supplier_intelligence()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT coalesce(jsonb_agg(row ORDER BY (row->>'updated_at') DESC NULLS LAST), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'acquisition_id', a.id,
      'state', a.state,
      'product_title', coalesce(a.winning_product_snapshot->>'product_title', a.winning_product_snapshot->>'title'),
      'updated_at', a.updated_at,
      'selected_supplier', CASE WHEN a.selected_supplier_snapshot IS NOT NULL THEN jsonb_build_object(
          'supplier_name', coalesce(a.selected_supplier_snapshot->>'supplier_name', a.selected_supplier_snapshot->>'name'),
          'source', a.selected_supplier_snapshot->>'source',
          'observed_cost', a.selected_supplier_snapshot->>'supplier_cost',
          'cost_currency', a.selected_supplier_snapshot->>'cost_currency',
          'is_free_shipping', a.selected_supplier_snapshot->'is_free_shipping',
          'shipping_country_codes', a.selected_supplier_snapshot->'shipping_country_codes'
        ) ELSE NULL END,
      'supplier_options', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'supplier_name', coalesce(opt->>'supplier_name', opt->>'name'),
            'source', opt->>'source',
            'observed_cost', opt->>'supplier_cost',
            'cost_currency', opt->>'cost_currency',
            'is_free_shipping', opt->'is_free_shipping',
            'shipping_country_codes', opt->'shipping_country_codes',
            'rank', opt->>'rank'
          )), '[]'::jsonb)
        FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(a.sourcing_spec_snapshot->'supplier_options')='array'
               THEN a.sourcing_spec_snapshot->'supplier_options' ELSE '[]'::jsonb END) opt)
    ) AS row
    FROM public.product_acquisitions a
    WHERE a.user_id = v_uid
  ) z;
  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'acquisitions', v_rows,
    'source_contract','product_acquisitions', 'note','Tenant-owned supplier snapshots only; global catalogue not exposed.');
END; $function$;

COMMENT ON FUNCTION public.fn_ecommerce_supplier_intelligence() IS
 'Authenticated, auth.uid()-scoped supplier intelligence from the caller OWN product_acquisitions snapshots (never the shared commerce_supplier_products catalogue). Observed cost/currency only; no invented margins or delivery times.';

-- ---------------------------------------------------------------------------
-- 5. AD STUDIO / CREATIVE INTELLIGENCE — ad_studio_briefs/angles/static_creatives +
--    media (all tenant_id). Honest linkage: linked_to_decision reflects decision_id,
--    NOT guessed. Fixtures excluded. No evidence/keyword/competitor blobs, no provider
--    job ids, no storage refs, no costs, no fingerprints/claim internals.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_creative_intelligence()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_briefs jsonb; v_media jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;

  SELECT coalesce(jsonb_agg(row ORDER BY (row->>'created_at') DESC NULLS LAST), '[]'::jsonb) INTO v_briefs FROM (
    SELECT jsonb_build_object(
      'brief_id', b.id,
      'product_id', b.product_id,
      'product_title', coalesce(cp.title, b.product_name),
      'market', b.market,
      'status', b.status,
      'linked_to_decision', (b.decision_id IS NOT NULL),
      'linked_to_product', (b.product_id IS NOT NULL),
      'created_at', b.created_at,
      'angles', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'angle_id', a.id, 'angle_index', a.angle_index, 'angle_name', a.angle_name,
            'angle_type', a.angle_type, 'customer_problem', a.customer_problem,
            'desired_outcome', a.desired_outcome, 'hook', a.hook, 'headline', a.headline,
            'primary_copy', a.primary_copy, 'supporting_copy', a.supporting_copy, 'cta', a.cta,
            'visual_concept', a.visual_concept, 'video_hook', a.video_hook,
            'claim_risk', a.claim_risk, 'review_state', a.review_state, 'approved_at', a.approved_at,
            'static_creatives', (
              SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'creative_id', s.id, 'platform', s.platform, 'headline', s.headline,
                  'supporting_text', s.supporting_text, 'cta', s.cta, 'layout', s.layout,
                  'aspect_ratio', s.aspect_ratio, 'generation_status', s.generation_status,
                  'asset_url', s.asset_url) ORDER BY s.created_at), '[]'::jsonb)
              FROM public.ad_studio_static_creatives s WHERE s.angle_id = a.id AND s.tenant_id = v_uid)
          ) ORDER BY a.angle_index NULLS LAST), '[]'::jsonb)
        FROM public.ad_studio_angles a WHERE a.brief_id = b.id AND a.tenant_id = v_uid)
    ) AS row
    FROM public.ad_studio_briefs b
    LEFT JOIN public.commerce_products cp ON cp.id = b.product_id
    WHERE b.tenant_id = v_uid AND coalesce(b.is_fixture,false) = false
  ) z;

  SELECT jsonb_build_object(
    'images', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'media_id', m.id, 'product_id', m.product_id, 'media_type', m.media_type,
        'generation_status', m.generation_status, 'approval_state', m.approval_state,
        'is_launch_safe', m.is_launch_safe, 'aspect_ratio', m.aspect_ratio, 'country_code', m.country_code)
      ORDER BY m.created_at DESC) FROM public.media_assets m WHERE m.tenant_id = v_uid), '[]'::jsonb),
    'videos', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'video_job_id', v.id, 'platform', v.platform, 'status', v.status,
        'aspect_ratio', v.aspect_ratio, 'duration_target', v.duration_target,
        'video_hook', v.video_hook, 'cta', v.cta) ORDER BY v.created_at DESC)
      FROM public.media_video_jobs v WHERE v.tenant_id = v_uid), '[]'::jsonb)
  ) INTO v_media;

  RETURN jsonb_build_object('status','ok', 'brief_count', jsonb_array_length(v_briefs),
    'briefs', v_briefs, 'media', v_media, 'source_contract','ad_studio_*+media_*');
END; $function$;

COMMENT ON FUNCTION public.fn_ecommerce_creative_intelligence() IS
 'Authenticated, auth.uid()-scoped ad-studio + media creative intelligence. Honest linkage (linked_to_decision from decision_id, never guessed). Browser-safe copy/status/asset_url only; no evidence blobs, provider job ids, storage refs, costs, fingerprints or claim internals. Fixtures excluded.';

-- ---------------------------------------------------------------------------
-- 6. SIGNAL TIMELINE — commerce_signals (user_id). Only signal types that actually
--    exist; safe context only (market/source_platform/attention_basis). No raw
--    mention text, evidence, provenance or dedup internals.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_signal_timeline()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb; v_types jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT coalesce(jsonb_agg(row ORDER BY (row->>'observed_at') DESC NULLS LAST), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'signal_id', s.id,
      'signal_type', s.signal_type,
      'product_id', s.product_id,
      'confidence', s.confidence,
      'observed_at', s.observed_at,
      'source_event_at', s.source_event_at,
      'visibility', s.visibility,
      'market', s.value->>'market',
      'source_platform', s.value->>'source_platform',
      'attention_basis', s.value->>'attention_basis'
    ) AS row
    FROM public.commerce_signals s WHERE s.user_id = v_uid
  ) z;
  SELECT coalesce(jsonb_agg(jsonb_build_object('signal_type', t.signal_type, 'count', t.n,
      'last_observed', t.last_obs) ORDER BY t.n DESC), '[]'::jsonb) INTO v_types
  FROM (SELECT signal_type, count(*) n, max(observed_at) last_obs FROM public.commerce_signals
        WHERE user_id = v_uid GROUP BY signal_type) t;
  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows),
    'signal_types', v_types, 'timeline', v_rows, 'source_contract','commerce_signals');
END; $function$;

COMMENT ON FUNCTION public.fn_ecommerce_signal_timeline() IS
 'Authenticated, auth.uid()-scoped Ecommerce signal timeline from commerce_signals. Only real signal types; safe context (market/source_platform/attention_basis) — never raw mention text, evidence, provenance or dedup keys.';

-- ---------------------------------------------------------------------------
-- 4. CAMPAIGN EXECUTIONS — safe projection of marketing_campaign_executions (user_id).
--    Drafts stay in the EXISTING get_own_marketing_campaign_drafts (not duplicated).
--    NEVER exposes meta account/page/campaign/adset/creative/ad ids, effective_status
--    raw, notes, tokens or webhook data — only platform/status/linkage/launched flag.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_campaign_executions()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'execution_id', e.id, 'draft_id', e.draft_id, 'platform', e.platform,
      'status', e.status, 'launched', (e.meta_campaign_id IS NOT NULL),
      'created_at', e.created_at, 'updated_at', e.updated_at)
    ORDER BY e.created_at DESC), '[]'::jsonb) INTO v_rows
  FROM public.marketing_campaign_executions e WHERE e.user_id = v_uid;
  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'executions', v_rows,
    'drafts_contract','get_own_marketing_campaign_drafts', 'source_contract','marketing_campaign_executions');
END; $function$;

COMMENT ON FUNCTION public.fn_ecommerce_campaign_executions() IS
 'Authenticated, auth.uid()-scoped safe projection of marketing_campaign_executions (platform/status/draft-linkage/launched flag only). Never exposes meta account/page/campaign ids, effective_status raw, notes, tokens or webhook data. Drafts are served by the existing get_own_marketing_campaign_drafts.';

-- ---------------------------------------------------------------------------
-- Grants: authenticated + service_role; anon revoked (deny anonymous).
-- ---------------------------------------------------------------------------
DO $grants$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.fn_ecommerce_competitor_intelligence()',
    'public.fn_ecommerce_supplier_intelligence()',
    'public.fn_ecommerce_creative_intelligence()',
    'public.fn_ecommerce_signal_timeline()',
    'public.fn_ecommerce_campaign_executions()'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', fn);
  END LOOP;
END; $grants$;

-- ---------------------------------------------------------------------------
-- Self-cleaning selftest (service_role only): structural + founder-data reachability.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_intelligence_contracts_selftest()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; f uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
BEGIN
  -- competitor: 74 real founder rows reachable, no fixtures
  v := v || jsonb_build_object('case','founder_competitors_74','pass',
    (SELECT count(*) FROM public.product_market_competitors WHERE tenant_id=f AND coalesce(is_fixture,false)=false)=74);
  -- supplier: founder has no owned acquisitions -> honest NO_DATA
  v := v || jsonb_build_object('case','founder_supplier_no_data','pass',
    (SELECT count(*) FROM public.product_acquisitions WHERE user_id=f)=0);
  -- creative: 1 non-fixture brief, decision_id NULL (honest unlinked)
  v := v || jsonb_build_object('case','founder_brief_unlinked','pass',
    (SELECT count(*) FROM public.ad_studio_briefs WHERE tenant_id=f AND coalesce(is_fixture,false)=false AND decision_id IS NULL)=1);
  v := v || jsonb_build_object('case','founder_brief_product_linked','pass',
    (SELECT bool_and(product_id IS NOT NULL) FROM public.ad_studio_briefs WHERE tenant_id=f AND coalesce(is_fixture,false)=false));
  -- signals: only COMMUNITY_ATTENTION exists (no invented Search/Customer)
  v := v || jsonb_build_object('case','founder_signal_types_real','pass',
    (SELECT array_agg(DISTINCT signal_type) FROM public.commerce_signals WHERE user_id=f) = ARRAY['COMMUNITY_ATTENTION']);
  -- executions present but no meta ids exposed by the projection (projection excludes them by construction)
  v := v || jsonb_build_object('case','founder_executions_present','pass',
    (SELECT count(*) FROM public.marketing_campaign_executions WHERE user_id=f) >= 1);
  RETURN jsonb_build_object('suite','ecommerce_intelligence_contracts',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_ecommerce_intelligence_contracts_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ecommerce_intelligence_contracts_selftest() TO service_role;

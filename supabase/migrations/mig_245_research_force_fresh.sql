-- ============================================================================
-- mig_245_research_force_fresh.sql
-- STRATELOQ-REAL-PRODUCT-MARKET-DEEP-RESEARCH-ORCHESTRATOR-013J (follow-up)
--
-- Add an explicit force-fresh path to the on-demand request entry point:
-- p_freshness_hours <= 0 bypasses the cache/dedupe lookup and always creates a
-- new run (an intentional "re-research now, ignore cache" control). Production
-- callers keep the default 168h dedupe unchanged.
--
-- Also make fn_research_orchestrator_selftest robust to the presence of a real,
-- freshly-completed run (which now correctly triggers CACHE_REUSED) by running
-- its request with force-fresh so it always exercises run creation.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_own_request_product_market_research(
  p_product_id uuid, p_market text, p_freshness_hours integer DEFAULT 168)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_prod public.commerce_products%rowtype;
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_ccy text; v_run_id uuid; v_fresh record;
  v_query text; v_supplier uuid;
  v_expected int := 0; v_manifest jsonb := '[]'::jsonb;
  cat record;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication required' USING errcode='28000'; END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PRODUCT_NOT_FOUND'); END IF;
  IF v_prod.user_id <> v_uid THEN RAISE EXCEPTION 'not authorized for this product' USING errcode='42501'; END IF;

  SELECT default_currency INTO v_ccy FROM public.ecommerce_market_universe
    WHERE country_code = v_mkt AND coalesce(ecommerce_eligible,true) LIMIT 1;
  IF v_ccy IS NULL THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','market',v_mkt,
      'note','market not present / not ecommerce-eligible in ecommerce_market_universe');
  END IF;

  -- cost / duplicate control: reuse a sufficiently fresh completed run.
  -- p_freshness_hours <= 0 forces a fresh run (explicit "re-research now, ignore cache").
  IF coalesce(p_freshness_hours,168) > 0 THEN
    SELECT * INTO v_fresh FROM public.commerce_research_run
      WHERE tenant_id=v_uid AND product_id=p_product_id AND market=v_mkt
        AND status IN ('COMPLETE','PARTIAL','PARTIAL_SOURCE_FAILURE','PARTIAL_SOURCE_UNAVAILABLE')
        AND completed_at IS NOT NULL
        AND completed_at > now() - make_interval(hours => p_freshness_hours)
      ORDER BY completed_at DESC LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('status','CACHE_REUSED','run_id',v_fresh.id,'market',v_mkt,
        'reused_completed_at',v_fresh.completed_at,'freshness_hours',p_freshness_hours,
        'note','fresh completed run reused; no new provider dispatch, no paid calls');
    END IF;
  END IF;

  SELECT (m.value->>'price_query') AS pq, r.supplier_id AS sup INTO v_query, v_supplier
  FROM public.monday_opportunity_registry r
       CROSS JOIN LATERAL jsonb_array_elements(r.markets) m
  WHERE r.product_id = p_product_id AND (m.value->>'country') = v_mkt LIMIT 1;
  v_query := coalesce(v_query, v_prod.title);

  v_run_id := gen_random_uuid();
  INSERT INTO public.commerce_research_run
    (id, tenant_id, product_id, market, status, sources_expected, started_at, freshness_at, provenance)
  VALUES (v_run_id, v_uid, p_product_id, v_mkt, 'RESEARCHING', 0, now(), now(),
    jsonb_build_object('trigger','on_demand_user_request','requested_by',v_uid,
      'product_title',v_prod.title,'price_query',v_query,'market_currency',v_ccy,'registry_supplier', v_supplier,
      'snapshot_note','applicable provider/category set snapshotted at request time'));

  FOR cat IN
    WITH cats(evidence_category) AS (
      VALUES ('COMMUNITY'),('SEARCH_DEMAND'),('MARKETPLACE'),('ADVERTISING'),('SUPPLIER'),('SOCIAL_VIDEO')
    ),
    ranked AS (
      SELECT c.evidence_category, r.source, r.availability, r.market,
             row_number() OVER (PARTITION BY c.evidence_category ORDER BY
                 (r.availability='AVAILABLE' AND r.market=v_mkt) DESC,
                 (r.availability='AVAILABLE' AND r.market='*')   DESC,
                 (r.availability='AVAILABLE')                    DESC,
                 (r.market=v_mkt)                                DESC,
                 (r.market='*')                                  DESC) AS rnk
      FROM cats c JOIN public.provider_capability_registry r USING (evidence_category)
    )
    SELECT evidence_category, source, availability, market FROM ranked WHERE rnk=1
  LOOP
    DECLARE v_state text; v_note text;
    BEGIN
      IF cat.availability = 'AVAILABLE' THEN v_state := 'NOT_SEARCHED'; v_note := 'applicable; awaiting provider dispatch';
      ELSIF cat.availability = 'SOURCE_UNSUPPORTED' AND cat.evidence_category='SOCIAL_VIDEO' THEN v_state := 'BLOCKED_EXTERNAL_ACCESS'; v_note := 'EXTERNAL_PROVIDER_REQUIRED';
      ELSIF cat.availability = 'SOURCE_UNSUPPORTED' THEN v_state := 'UNSUPPORTED_MARKET'; v_note := 'provider not available for selected market';
      ELSIF cat.availability = 'SOURCE_BLOCKED' THEN v_state := 'SOURCE_UNAVAILABLE'; v_note := 'provider access blocked';
      ELSE v_state := 'SOURCE_UNAVAILABLE'; v_note := coalesce(cat.availability,'UNKNOWN'); END IF;

      INSERT INTO public.commerce_research_source_attempt
        (id, run_id, evidence_category, source, state, note, created_at)
      VALUES (gen_random_uuid(), v_run_id, cat.evidence_category, cat.source, v_state, v_note, now());
      v_expected := v_expected + 1;
      v_manifest := v_manifest || jsonb_build_array(jsonb_build_object(
        'evidence_category', cat.evidence_category, 'source', cat.source, 'state', v_state,
        'dispatchable', (v_state='NOT_SEARCHED'),
        'query', CASE WHEN v_state='NOT_SEARCHED' THEN v_query ELSE NULL END,
        'market', v_mkt, 'note', v_note));
    END;
  END LOOP;

  UPDATE public.commerce_research_run SET sources_expected=v_expected, updated_at=now() WHERE id=v_run_id;

  RETURN jsonb_build_object('status','RESEARCHING','run_id',v_run_id,
    'product_id',p_product_id,'product_title',v_prod.title,'market',v_mkt,'market_currency',v_ccy,
    'price_query',v_query,'sources_expected',v_expected,'dispatch_manifest',v_manifest,
    'tiktok','BLOCKED_EXTERNAL_ACCESS','contract','pulse_research_request_v1_013j');
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_research_orchestrator_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_founder uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  v_prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_req jsonb; v_run uuid; v_res jsonb := '[]'::jsonb; v_pass boolean := true;
  n_att int; n_tiktok int; n_meta_gb int; n_ebay int;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_founder::text, 'role','authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_founder::text, true);
  -- force-fresh (0) so the real completed run does not trigger CACHE_REUSED here
  v_req := public.fn_own_request_product_market_research(v_prod, 'GB', 0);
  v_run := nullif(v_req->>'run_id','')::uuid;
  SELECT count(*) INTO n_att FROM public.commerce_research_source_attempt WHERE run_id=v_run;
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','request_creates_6_attempts','pass',(v_req->>'status'='RESEARCHING' AND n_att=6),'attempts',n_att));
  v_pass := v_pass AND (v_req->>'status'='RESEARCHING' AND n_att=6);
  SELECT count(*) INTO n_tiktok FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='SOCIAL_VIDEO' AND state='BLOCKED_EXTERNAL_ACCESS' AND source='TIKTOK';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','tiktok_blocked','pass',(n_tiktok=1)));
  v_pass := v_pass AND (n_tiktok=1);
  SELECT count(*) INTO n_meta_gb FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='ADVERTISING' AND state='NOT_SEARCHED' AND source='META_AD_LIBRARY';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','meta_available_gb','pass',(n_meta_gb=1)));
  v_pass := v_pass AND (n_meta_gb=1);
  SELECT count(*) INTO n_ebay FROM public.commerce_research_source_attempt
    WHERE run_id=v_run AND evidence_category='MARKETPLACE' AND state='NOT_SEARCHED' AND source='EBAY';
  v_res := v_res || jsonb_build_array(jsonb_build_object('case','ebay_dispatchable','pass',(n_ebay=1)));
  v_pass := v_pass AND (n_ebay=1);
  DECLARE v_fin jsonb; BEGIN
    v_fin := public.fn_finalize_research_run(v_run);
    v_res := v_res || jsonb_build_array(jsonb_build_object('case','finalize_partial_with_gap',
      'pass',(v_fin->>'status'='PARTIAL' AND (v_fin->>'launch_critical_gap')::boolean=true),
      'status',v_fin->>'status','gap',v_fin->>'launch_critical_gap'));
    v_pass := v_pass AND (v_fin->>'status'='PARTIAL' AND (v_fin->>'launch_critical_gap')::boolean=true);
  END;
  DECLARE v_bad jsonb; BEGIN
    v_bad := public.fn_own_request_product_market_research(v_prod, 'ZZ', 0);
    v_res := v_res || jsonb_build_array(jsonb_build_object('case','unsupported_market_rejected','pass',(v_bad->>'status'='UNSUPPORTED_MARKET')));
    v_pass := v_pass AND (v_bad->>'status'='UNSUPPORTED_MARKET');
  END;
  -- cache path still works with default freshness (real run present)
  DECLARE v_cache jsonb; BEGIN
    v_cache := public.fn_own_request_product_market_research(v_prod, 'GB');
    v_res := v_res || jsonb_build_array(jsonb_build_object('case','cache_reused_default_freshness','pass',(v_cache->>'status'='CACHE_REUSED')));
    v_pass := v_pass AND (v_cache->>'status'='CACHE_REUSED');
  END;
  DELETE FROM public.commerce_research_source_attempt WHERE run_id=v_run;
  DELETE FROM public.commerce_research_run WHERE id=v_run;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN jsonb_build_object('all_pass',v_pass,'cases',v_res,'contract','pulse_research_selftest_v2_013j');
END; $function$;

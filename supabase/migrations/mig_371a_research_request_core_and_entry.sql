-- mig_371a — Shared research-request core (service-context) + on-demand entry delegate
--
-- ROOT CAUSE (bridge gap): the canonical "research this product" entry
-- fn_own_request_product_market_research is gated on auth.uid() + product
-- ownership — built for the on-demand UI button. The fresh-discovery path runs in
-- a service context with an explicit tenant (p_user_id), so it had no way to reach
-- the research lifecycle, leaving newly discovered candidates stranded in
-- commerce_products + monday_opportunity_registry with no research run.
--
-- FIX (correct boundary, no parallel system): extract the run-creation + manifest
-- + dedup + dispatch into ONE shared core fn_research_request_core(user_id,
-- product, market, freshness, trigger). The on-demand entry keeps its exact auth
-- and ownership behaviour and delegates to the core; the auto-dispatch bridge
-- (mig_371b) calls the same core with an explicit tenant. Byte-for-byte the same
-- run creation, idempotency (CACHE_REUSED / CACHE_REUSED_IN_FLIGHT), source-state
-- semantics and fn_research_dispatch call as before — one source of truth.

CREATE OR REPLACE FUNCTION public.fn_research_request_core(
    p_user_id uuid, p_product_id uuid, p_market text,
    p_freshness_hours integer DEFAULT 168, p_trigger text DEFAULT 'on_demand_user_request')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := p_user_id;
  v_prod public.commerce_products%rowtype;
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_ccy text; v_run_id uuid; v_fresh record; v_inflight record;
  v_query text; v_supplier uuid;
  v_expected int := 0; v_manifest jsonb := '[]'::jsonb; v_dispatch jsonb;
  cat record;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','MISSING_TENANT'); END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PRODUCT_NOT_FOUND'); END IF;
  IF v_prod.user_id <> v_uid THEN RETURN jsonb_build_object('status','NOT_AUTHORIZED'); END IF;

  SELECT default_currency INTO v_ccy FROM public.ecommerce_market_universe
    WHERE country_code = v_mkt AND coalesce(ecommerce_eligible,true) LIMIT 1;
  IF v_ccy IS NULL THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','market',v_mkt,
      'note','market not present / not ecommerce-eligible in ecommerce_market_universe');
  END IF;

  -- IDEMPOTENCY: a fresh completed run is reused; an in-flight run is never
  -- duplicated or re-dispatched. Retries therefore cannot create duplicate runs.
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
    SELECT * INTO v_inflight FROM public.commerce_research_run
      WHERE tenant_id=v_uid AND product_id=p_product_id AND market=v_mkt
        AND status='RESEARCHING' AND started_at > now() - interval '1 hour'
      ORDER BY started_at DESC LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('status','CACHE_REUSED_IN_FLIGHT','run_id',v_inflight.id,'market',v_mkt,
        'started_at',v_inflight.started_at,'note','a research run for this product+market is already in progress; not duplicated, not re-dispatched');
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
    jsonb_build_object('trigger',p_trigger,'requested_by',v_uid,
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

  v_dispatch := public.fn_research_dispatch(v_run_id);

  RETURN jsonb_build_object('status','RESEARCHING','run_id',v_run_id,
    'product_id',p_product_id,'product_title',v_prod.title,'market',v_mkt,'market_currency',v_ccy,
    'price_query',v_query,'sources_expected',v_expected,'dispatch_manifest',v_manifest,
    'auto_dispatch',v_dispatch->>'status','dispatch',v_dispatch,'trigger',p_trigger,
    'tiktok','BLOCKED_EXTERNAL_ACCESS','contract','pulse_research_request_v2_013n');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_research_request_core(uuid,uuid,text,integer,text) TO service_role;

-- On-demand entry: preserves auth + ownership, delegates to the shared core.
CREATE OR REPLACE FUNCTION public.fn_own_request_product_market_research(p_product_id uuid, p_market text, p_freshness_hours integer DEFAULT 168)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_prod public.commerce_products%rowtype;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'authentication required' USING errcode='28000'; END IF;
  SELECT * INTO v_prod FROM public.commerce_products WHERE id = p_product_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','PRODUCT_NOT_FOUND'); END IF;
  IF v_prod.user_id <> v_uid THEN RAISE EXCEPTION 'not authorized for this product' USING errcode='42501'; END IF;
  RETURN public.fn_research_request_core(v_uid, p_product_id, p_market, p_freshness_hours, 'on_demand_user_request');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_own_request_product_market_research(uuid,text,integer) TO authenticated, service_role;

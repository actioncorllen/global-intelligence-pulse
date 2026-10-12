-- mig_379a — Product search identity + family normalization + research-query fix
--
-- ROOT CAUSE (Stage-1 evidence gap): fn_research_request_core used the raw provider title as the
-- research/search query. Product-native titles are long, local-language marketing sentences, so
-- every source searched a sentence and returned SEARCHED_NO_EVIDENCE. The query was the defect,
-- not the provider. Fix: a small product-search-identity layer that derives a concise
-- local-language product-search query from a noisy title (cut at the first qualifier clause,
-- strip quantity prefix, cap length), applied at the single chokepoint (fn_research_request_core),
-- preserving the raw title. Also a conservative family key that strips only demonstrably
-- non-identity provider decorations (e.g. [Y], [DE]) before family-key generation.
--
-- check_function_bodies disabled for these CREATEs only (managed-instance validation path).
SET check_function_bodies = off;

-- Conservative family key: strip only short square-bracket provider decorations ([Y],[DE],[2024])
-- BEFORE normalizing; keep sizes/models/variants/brands/quantities (identity-relevant).
CREATE OR REPLACE FUNCTION public.fn_product_family_key(p_title text)
 RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE v text;
BEGIN
  v := lower(coalesce(p_title,''));
  v := regexp_replace(v, '\[[^\]]{1,8}\]', ' ', 'g');
  v := btrim(regexp_replace(regexp_replace(v, '[[:space:][:punct:]]+',' ','g'), '\s+',' ','g'));
  RETURN nullif(v,'');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_product_family_key(text) TO authenticated, service_role;

-- Product search identity: concise local-language product-search query from a noisy provider
-- title. Cut at first qualifier clause; strip leading quantity prefix ONLY when a unit token is
-- present (so "360"/"3 in 1" are kept, "1pc"/"2 x" stripped); cap to 6 tokens. Idempotent on
-- already-clean short queries. Never converts an ambiguous concept into a concrete SKU.
CREATE OR REPLACE FUNCTION public.fn_product_search_identity(p_title text)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO ''
AS $function$
DECLARE
  v_title text := btrim(coalesce(p_title,''));
  v_low text := lower(v_title); v_head text; v_q text; v_tokens text[]; v_norm text;
BEGIN
  IF v_title = '' THEN RETURN jsonb_build_object('provider_title',NULL,'search_query',NULL); END IF;
  v_head := (regexp_split_to_array(v_low, '\s*[,\|\[\n]\s*|\s+[-–]\s+|\s+(inklusive|incl|mit|fuer|für|with|for|und|plus)\s+'))[1];
  v_head := coalesce(nullif(btrim(v_head),''), v_low);
  v_q := regexp_replace(v_head, '^\s*(set of\s+)?\d+\s*(pc|pcs|stk|stück|stueck|x|er|pack|set)[\s\-]+', '', 'i');
  v_q := btrim(regexp_replace(regexp_replace(v_q, '[[:punct:]]+',' ','g'), '\s+',' ','g'));
  v_tokens := string_to_array(v_q,' ');
  IF array_length(v_tokens,1) > 6 THEN v_q := array_to_string(v_tokens[1:6],' '); END IF;
  v_norm := btrim(regexp_replace(regexp_replace(lower(v_title), '[[:space:][:punct:]]+',' ','g'),'\s+',' ','g'));
  RETURN jsonb_build_object(
    'provider_title', v_title,
    'normalized_identity', v_norm,
    'search_query', nullif(btrim(v_q),''),
    'local_query', nullif(btrim(v_q),''),
    'family_key', public.fn_product_family_key(v_title),
    'brand_tokens', public.fn_is_branded_or_ip_sensitive(v_title)->'matched',
    'contract','pulse_product_search_identity_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_product_search_identity(text) TO authenticated, service_role;

-- Research request core v4: derive the concise product-search query from the (often noisy,
-- local-language) provider title/registry query before dispatch; preserve the raw title.
-- v4 adds the FUNCTION-LEVEL idempotency guard (companion to the DB-level partial unique index in
-- mig_380): a transaction advisory lock on the logical key (tenant+product+market) serialises all
-- callers, and in-flight reuse is ALWAYS applied (moved out of the `freshness>0` block) so a
-- freshness=0 replay / duplicate RPC evaluation / double-click / webhook/n8n/worker retry /
-- concurrent caller reuses the running execution and returns CACHE_REUSED_IN_FLIGHT
-- (already_dispatched=true) instead of creating a second paid execution.
CREATE OR REPLACE FUNCTION public.fn_research_request_core(p_user_id uuid, p_product_id uuid, p_market text, p_freshness_hours integer DEFAULT 168, p_trigger text DEFAULT 'on_demand_user_request'::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := p_user_id;
  v_prod public.commerce_products%rowtype;
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_ccy text; v_run_id uuid; v_fresh record; v_inflight record;
  v_query text; v_raw_query text; v_ident jsonb; v_supplier uuid; v_suppress boolean;
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

  -- IDEMPOTENCY/COST BOUNDARY: serialize all callers for the same logical research key
  -- (tenant+product+market), so SQL double-evaluation, double-click, webhook/n8n/worker retry
  -- and concurrent callers cannot create two paid executions. The advisory lock is released at
  -- transaction end; it is re-entrant within a transaction.
  PERFORM pg_advisory_xact_lock(hashtextextended('commerce_research:'||v_uid::text||':'||p_product_id::text||':'||v_mkt, 0));

  IF coalesce(p_freshness_hours,168) > 0 THEN
    SELECT * INTO v_fresh FROM public.commerce_research_run
      WHERE tenant_id=v_uid AND product_id=p_product_id AND market=v_mkt
        AND status IN ('COMPLETE','PARTIAL','PARTIAL_SOURCE_FAILURE','PARTIAL_SOURCE_UNAVAILABLE')
        AND completed_at IS NOT NULL
        AND completed_at > now() - make_interval(hours => p_freshness_hours)
      ORDER BY completed_at DESC LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('status','CACHE_REUSED','run_id',v_fresh.id,'market',v_mkt,'idempotent',true,
        'reused_completed_at',v_fresh.completed_at,'freshness_hours',p_freshness_hours,
        'note','fresh completed run reused; no new provider dispatch, no paid calls');
    END IF;
  END IF;

  -- in-flight dedup ALWAYS applies (even when freshness=0 forces fresh completed research): an
  -- already-running execution for this logical key is reused, never duplicated. (ALREADY_DISPATCHED)
  SELECT * INTO v_inflight FROM public.commerce_research_run
    WHERE tenant_id=v_uid AND product_id=p_product_id AND market=v_mkt
      AND status='RESEARCHING' AND started_at > now() - interval '1 hour'
    ORDER BY started_at DESC LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('status','CACHE_REUSED_IN_FLIGHT','already_dispatched',true,'run_id',v_inflight.id,'market',v_mkt,
      'started_at',v_inflight.started_at,'note','a research run for this product+market is already in progress; idempotent, not duplicated, not re-dispatched');
  END IF;

  SELECT (m.value->>'price_query') AS pq, r.supplier_id AS sup INTO v_raw_query, v_supplier
  FROM public.monday_opportunity_registry r
       CROSS JOIN LATERAL jsonb_array_elements(r.markets) m
  WHERE r.product_id = p_product_id AND (m.value->>'country') = v_mkt LIMIT 1;
  v_raw_query := coalesce(v_raw_query, v_prod.title);
  v_ident := public.fn_product_search_identity(v_raw_query);
  v_query := coalesce(nullif(btrim(v_ident->>'search_query'),''), v_raw_query);

  v_run_id := gen_random_uuid();
  INSERT INTO public.commerce_research_run
    (id, tenant_id, product_id, market, status, sources_expected, started_at, freshness_at, provenance)
  VALUES (v_run_id, v_uid, p_product_id, v_mkt, 'RESEARCHING', 0, now(), now(),
    jsonb_build_object('trigger',p_trigger,'requested_by',v_uid,
      'product_title',v_prod.title,'raw_query',v_raw_query,'price_query',v_query,'search_identity',v_ident,
      'market_currency',v_ccy,'registry_supplier', v_supplier,
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

  -- suppress-aware dispatch (same contract as fn_auto_dispatch_candidate_research): a suppressed
  -- session creates the run but makes no paid provider call.
  v_suppress := coalesce(current_setting('pulse.suppress_dispatch', true),'') = 'on';
  IF v_suppress THEN
    v_dispatch := jsonb_build_object('status','DISPATCH_SUPPRESSED','note','pulse.suppress_dispatch=on; no paid provider call');
  ELSE
    v_dispatch := public.fn_research_dispatch(v_run_id);
  END IF;

  RETURN jsonb_build_object('status','RESEARCHING','run_id',v_run_id,
    'product_id',p_product_id,'product_title',v_prod.title,'market',v_mkt,'market_currency',v_ccy,
    'raw_query',v_raw_query,'price_query',v_query,'search_identity',v_ident,
    'sources_expected',v_expected,'dispatch_manifest',v_manifest,
    'auto_dispatch',v_dispatch->>'status','dispatch',v_dispatch,'trigger',p_trigger,
    'tiktok','BLOCKED_EXTERNAL_ACCESS','contract','pulse_research_request_v4_idempotent');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_research_request_core(uuid, uuid, text, integer, text) TO authenticated, service_role;

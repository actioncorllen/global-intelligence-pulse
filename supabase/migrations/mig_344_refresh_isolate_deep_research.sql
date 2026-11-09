-- mig_344 — Isolate customer Refresh Discovery from the automatic deep-research cascade (PREPARED; NOT applied)
-- 2026-11-09
--
-- ROOT CAUSE (verified from live code):
--   fn_kalodata_ingest_candidates, for every promoted candidate, (a) registers it active-for-market in
--   monday_opportunity_registry and then (b) UNCONDITIONALLY calls fn_auto_dispatch_candidate_research. That
--   dispatcher's eligibility gate (product must be active in the registry for the market) is therefore
--   SELF-SATISFIED by the ingest that precedes it, so a freshly-ingested candidate always passes it and
--   fn_research_request_core(..., 'auto_fresh_discovery') runs. The customer Refresh Discovery path reaches
--   ingest through the kalodata-discovery edge, which calls ingest as a fresh service-role PostgREST RPC: the
--   pulse.suppress_dispatch GUC is NOT set in that transaction and a normal customer tenant has no
--   discovery_dispatch_suppression row, so the only thing left standing between one customer refresh click and a
--   FastMoss/DataForSEO/CJ research fan-out is the per-provider fail-closed budget in fn_research_dispatch.
--
-- SMALLEST SAFE CHANGE:
--   Add an explicit, default-false parameter p_suppress_auto_research to fn_kalodata_ingest_candidates. When
--   true, ingestion/identity/dedup/registry/storage all run EXACTLY as before, but the per-candidate
--   fn_auto_dispatch_candidate_research bridge is NOT crossed (it records AUTO_RESEARCH_SUPPRESSED instead). The
--   edge passes true ONLY for a customer Refresh Discovery run (refresh_request_id present). Normal discovery
--   waves (no refresh_request_id) pass false and are byte-for-byte unchanged, preserving production behaviour
--   outside the customer-refresh path. Deep research stays fully available through its existing, separately
--   authorized and budget-gated workflow (on-demand fn_research_request_core / fn_research_dispatch), which this
--   migration does not touch.
--
--   This is defence-in-depth: fn_research_dispatch's per-provider fail-closed authorization still stands; this
--   change stops the cascade from even being ENTERED on a customer refresh, rather than relying on empty budgets.
--
-- COMPATIBILITY: the only callers of the 6-arg function are the kalodata-discovery edge (named args) and
--   fn_kalodata_commerce_adapter_selftest (positional, dry_run=true). A 7th default-false param keeps both
--   working. The 6-arg signature is dropped and replaced by a single 7-arg function to avoid named-argument
--   overload ambiguity. EXECUTE is re-granted to authenticated and service_role (unchanged from the original ACL).
--
-- INERT until deployed: this file changes only how a customer refresh treats auto-research; nothing here runs a
--   provider call, charges a customer, activates credits, or sets a price. Apply alongside deploying the prepared
--   kalodata-discovery edge (which passes the flag + records usage unconditionally). Rollback: mig_344_ROLLBACK.sql.

DROP FUNCTION IF EXISTS public.fn_kalodata_ingest_candidates(uuid, text, uuid, integer, jsonb, boolean);

CREATE OR REPLACE FUNCTION public.fn_kalodata_ingest_candidates(p_user_id uuid, p_market text, p_run_id uuid, p_candidate_limit integer, p_products jsonb, p_dry_run boolean DEFAULT false, p_suppress_auto_research boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $fn$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_cfg record; v_run uuid := p_run_id; v_member uuid;
  v_cap int := greatest(1, least(coalesce(p_candidate_limit,10), 25));
  v_promoted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb;
  v_scanned int := 0; v_qualified int := 0; v_promoted_n int := 0;
  r record; v_raw jsonb; v_norm jsonb; v_name text; v_kid text; v_gate jsonb;
  v_pid uuid; v_ing jsonb; v_dedup text; v_existing uuid; v_auto jsonb; v_price numeric;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','missing_user'); END IF;
  SELECT * INTO v_cfg FROM public.discovery_provider_market_config
    WHERE provider='KALODATA' AND market=v_mkt AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','provider','KALODATA','market',v_mkt,
      'note','Kalodata does not support this market in discovery_provider_market_config; no substitution, no contamination');
  END IF;
  IF jsonb_typeof(p_products) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('status','PROVIDER_UNAVAILABLE','market',v_mkt,'note','no product array supplied by provider adapter');
  END IF;
  IF jsonb_array_length(p_products) = 0 THEN
    RETURN jsonb_build_object('status','SUCCESS_ZERO_CANDIDATES','market',v_mkt,'scanned',0,'promoted_count',0);
  END IF;
  IF v_run IS NULL AND NOT p_dry_run THEN
    SELECT id INTO v_member FROM public.member WHERE auth_user_id=p_user_id LIMIT 1;
    IF v_member IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','no_member'); END IF;
    v_run := gen_random_uuid();
    INSERT INTO public.discovery_runs (id, user_id, member_id, run_status, entry_mode, contract_version, raw_contract, created_at, completed_at)
    VALUES (v_run, p_user_id, v_member, 'completed', 'no_store_yet', 1,
      jsonb_build_object('discovery_source','kalodata','lane','COMMERCE','provider','KALODATA','market',v_mkt,
        'capability','PRODUCT_NATIVE_COMMERCE_DISCOVERY','contract','kalodata_commerce_discovery_v1'), now(), now());
  END IF;
  FOR r IN SELECT e FROM jsonb_array_elements(p_products) e LOOP
    EXIT WHEN v_promoted_n >= v_cap;
    v_scanned := v_scanned + 1;
    BEGIN
      v_name := btrim(coalesce(r.e->>'product_name',''));
      v_kid  := nullif(btrim(coalesce(r.e->>'product_id','')),'');
      IF v_name='' OR v_kid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','missing_name_or_id')); CONTINUE; END IF;
      v_gate := public.fn_is_product_native_entity(v_name);
      IF (v_gate->>'verdict') <> 'ACCEPT' THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'reason','not_product_entity','gate',v_gate->'reasons')); CONTINUE; END IF;
      v_qualified := v_qualified + 1;
      v_raw := jsonb_build_object('product_identity',v_name,'revenue',r.e->>'revenue',
        'revenue_growth_rate',r.e->>'revenue_growth_rate','sales_units',r.e->>'sales_volumn',
        'price',r.e->>'unit_price','first_seen',r.e->>'launch_date','cross_market_reference',false);
      v_norm := public.fn_discovery_signal_normalize('COMMERCE','kalodata',v_mkt,v_raw);
      v_price := CASE WHEN (r.e->>'unit_price') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r.e->>'unit_price')::numeric END;
      IF p_dry_run THEN
        v_promoted := v_promoted || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'normalized',v_norm,'dry_run',true));
        v_promoted_n := v_promoted_n + 1; CONTINUE;
      END IF;
      SELECT id INTO v_existing FROM public.commerce_products
        WHERE user_id=p_user_id AND extended->>'kalodata_product_id'=v_kid ORDER BY created_at LIMIT 1;
      v_ing := public.ingest_commerce_product(p_user_id, v_run,
        jsonb_build_object('title',v_name,'product_type','tiktok_shop_product','category','tiktok_shop',
          'source_store','kalodata','provenance','PLATFORM_REPORTED','is_physical_sellable','true',
          'candidate_acquisition_method','kalodata_product_rank','source_family','product_native_commerce',
          'market',v_mkt),'INFERRED','candidate');
      v_pid := nullif(v_ing->>'product_id','')::uuid;
      IF v_pid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','promotion_'||coalesce(v_ing->>'status','failed'))); CONTINUE; END IF;
      UPDATE public.commerce_products
        SET identity_basis='platform_id',
            observed_price=coalesce(observed_price, v_price),
            price_currency=coalesce(price_currency, v_cfg.currency),
            extended = coalesce(extended,'{}'::jsonb) || jsonb_build_object(
              'kalodata_product_id', v_kid, 'kalodata_seller_id', nullif(btrim(coalesce(r.e->>'seller_id','')),''),
              'kalodata_seller_name', nullif(btrim(coalesce(r.e->>'seller_name','')),''),
              'provider_product_native','KALODATA')
        WHERE id=v_pid;
      PERFORM public.fn_persist_reference_image(p_user_id, v_pid, v_mkt, 'KALODATA', v_kid, public.fn_extract_cover_url(r.e));
      PERFORM public.ingest_commerce_signal(p_user_id, v_pid, v_run, 'COMMERCE_PRODUCT_NATIVE',
        v_norm,
        jsonb_build_array(jsonb_build_object('claim','TikTok Shop product-native commerce signal ('||v_mkt||') from Kalodata product rank',
          'source_name','kalodata','provenance','PLATFORM_REPORTED',
          'channel_revenue', jsonb_strip_nulls(jsonb_build_object(
            'live_revenue', r.e->>'live_revenue','video_revenue', r.e->>'video_revenue','showcase_revenue', r.e->>'showcase_revenue')))),
        'PLATFORM_REPORTED', 0.6, now(), NULL,
        'kalodata:'||v_kid||':'||v_mkt||':commerce_product_native');
      IF EXISTS (SELECT 1 FROM public.monday_opportunity_registry WHERE tenant_id=p_user_id AND product_id=v_pid) THEN
        UPDATE public.monday_opportunity_registry SET active=true,
          markets = CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(markets) m WHERE m->>'country'=v_mkt)
                         THEN markets ELSE markets || jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)) END
          WHERE tenant_id=p_user_id AND product_id=v_pid;
      ELSE
        INSERT INTO public.monday_opportunity_registry (id, tenant_id, product_id, markets, active, created_at)
        VALUES (gen_random_uuid(), p_user_id, v_pid, jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)), true, now());
      END IF;
      -- Deep per-candidate research bridge. In a customer Refresh Discovery run (p_suppress_auto_research=true)
      -- the candidate is ingested, identity-resolved, de-duplicated, stored and registered exactly as above, but
      -- NO deep research is auto-initiated. Deep research then only runs via its existing separately-authorized,
      -- budget-gated workflow. Normal discovery waves (false) keep the pre-existing auto-dispatch behaviour.
      IF p_suppress_auto_research THEN
        v_auto := jsonb_build_object('status','AUTO_RESEARCH_SUPPRESSED',
          'note','customer Refresh Discovery: deep per-candidate research not auto-initiated; available only via the existing separately-authorized, budget-gated research workflow; no paid research call');
      ELSE
        BEGIN v_auto := public.fn_auto_dispatch_candidate_research(p_user_id, v_pid, v_mkt);
        EXCEPTION WHEN OTHERS THEN v_auto := jsonb_build_object('status','auto_dispatch_error','error',left(SQLERRM,160)); END;
      END IF;
      v_promoted_n := v_promoted_n + 1;
      v_promoted := v_promoted || jsonb_build_array(jsonb_build_object(
        'kalodata_product_id',v_kid,'product_name',v_name,'product_id',v_pid,
        'dedup_status', CASE WHEN v_existing IS NULL THEN 'new' ELSE 'deduplicated' END,
        'observed_unit_price', v_price, 'research_auto_dispatch', coalesce(v_auto->>'status','skipped'),
        'research_run_id', v_auto->>'run_id'));
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','error:'||left(SQLERRM,140)));
    END;
  END LOOP;
  RETURN jsonb_build_object(
    'status', CASE WHEN v_promoted_n>0 THEN 'SUCCESS_WITH_CANDIDATES' ELSE 'SUCCESS_ZERO_CANDIDATES' END,
    'provider','KALODATA','lane','COMMERCE','market',v_mkt,'run_id',v_run,
    'scanned',v_scanned,'qualified',v_qualified,'promoted_count',v_promoted_n,
    'promoted',v_promoted,'skipped',v_skipped,'dry_run',p_dry_run,
    'auto_research_suppressed', p_suppress_auto_research,
    'note','Kalodata discovers product-native candidates only; each passes the existing eligibility + auto-research + concrete-resolution + evaluation gates; cover persisted as REFERENCE_ONLY primary image when the entitled rank response carries one. Provider record != concrete SKU; UNKNOWN != 0; country-isolated.',
    'contract','pulse_kalodata_commerce_ingest_v1');
END; $fn$;

GRANT EXECUTE ON FUNCTION public.fn_kalodata_ingest_candidates(uuid, text, uuid, integer, jsonb, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_ingest_candidates(uuid, text, uuid, integer, jsonb, boolean, boolean) TO service_role;

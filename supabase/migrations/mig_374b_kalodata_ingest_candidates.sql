-- mig_374b — Kalodata COMMERCE ingest adapter (secret-free; reuses the Stage 1 bridge)
--
-- The backend broker (kalodata-discovery edge function) holds the secret in env and
-- fetches product rows; this DB adapter INGESTS those rows. The raw secret never reaches
-- the database: p_products is the only provider input. Each candidate:
--   noise gate (fn_is_sellable_product_entity)
--   -> normalized discovery signal (fn_discovery_signal_normalize; UNKNOWN stays NULL)
--   -> ingest_commerce_product (identity_basis=provider_product_native, NOT a concrete SKU)
--   -> ingest_commerce_signal (COMMERCE_PRODUCT_NATIVE; channel breakdown in evidence)
--   -> monday_opportunity_registry upsert (country-isolated market entry)
--   -> fn_auto_dispatch_candidate_research (existing auto_fresh_discovery bridge; eligibility gate)
-- Dedup by Kalodata provider product id within tenant. Explicit lane statuses:
-- SUCCESS_WITH_CANDIDATES / SUCCESS_ZERO_CANDIDATES / UNSUPPORTED_MARKET /
-- PROVIDER_UNAVAILABLE / FAILED. Kalodata DISCOVERS; it never decides opportunity.
--
-- check_function_bodies disabled for this CREATE only (managed-instance validation path).

SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_kalodata_ingest_candidates(p_user_id uuid, p_market text, p_run_id uuid, p_candidate_limit integer, p_products jsonb, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

      -- noise gate: only concrete sellable products enter the pipeline
      v_gate := public.fn_is_sellable_product_entity(v_name);
      IF (v_gate->>'verdict') <> 'ACCEPT' THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','not_sellable_product')); CONTINUE; END IF;
      v_qualified := v_qualified + 1;

      -- normalized signal (UNKNOWN stays NULL; Kalodata 'sales_volumn' typo mapped)
      v_raw := jsonb_build_object('product_identity',v_name,'revenue',r.e->>'revenue',
        'revenue_growth_rate',r.e->>'revenue_growth_rate','sales_units',r.e->>'sales_volumn',
        'price',r.e->>'unit_price','first_seen',r.e->>'launch_date','cross_market_reference',false);
      v_norm := public.fn_discovery_signal_normalize('COMMERCE','kalodata',v_mkt,v_raw);
      v_price := CASE WHEN (r.e->>'unit_price') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r.e->>'unit_price')::numeric END;

      IF p_dry_run THEN
        v_promoted := v_promoted || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'normalized',v_norm,'dry_run',true));
        v_promoted_n := v_promoted_n + 1; CONTINUE;
      END IF;

      -- dedup by Kalodata provider product id within tenant
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

      -- persist provider identity + observed price (discovery evidence, NOT concrete SKU)
      UPDATE public.commerce_products
        SET identity_basis='provider_product_native',
            observed_price=coalesce(observed_price, v_price),
            price_currency=coalesce(price_currency, v_cfg.currency),
            extended = coalesce(extended,'{}'::jsonb) || jsonb_build_object(
              'kalodata_product_id', v_kid, 'kalodata_seller_id', nullif(btrim(coalesce(r.e->>'seller_id','')),''),
              'kalodata_seller_name', nullif(btrim(coalesce(r.e->>'seller_name','')),''),
              'provider_product_native','KALODATA')
        WHERE id=v_pid;

      -- normalized product-native commerce signal (UNKNOWN preserved; channel breakdown in evidence)
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

      BEGIN v_auto := public.fn_auto_dispatch_candidate_research(p_user_id, v_pid, v_mkt);
      EXCEPTION WHEN OTHERS THEN v_auto := jsonb_build_object('status','auto_dispatch_error','error',left(SQLERRM,160)); END;

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
    'note','Kalodata discovers product-native candidates only; each passes the existing eligibility + auto-research + concrete-resolution + evaluation gates. Provider record != concrete SKU; UNKNOWN != 0; country-isolated.',
    'contract','pulse_kalodata_commerce_ingest_v1');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_kalodata_ingest_candidates(uuid, text, uuid, integer, jsonb, boolean) TO authenticated, service_role;

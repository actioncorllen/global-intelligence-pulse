-- mig_378c — FastMoss COMMERCE ingest adapter (secret-free; reuses the Stage 1 bridge).
--
-- Mirrors the Kalodata adapter: noise gate (fn_is_product_native_entity) -> normalized signal
-- (fn_discovery_signal_normalize; UNKNOWN stays NULL) -> identity/dedup -> auto_fresh_discovery.
-- FastMoss-specific: branded/IP screen (fail-closed to BRANDED_OR_IP_REVIEW, no silent generic
-- pass), provider-id dedup (idempotent) + normalized-family correlation (country-isolated; keeps
-- each seller as separate evidence; cross-provider-ready via shared family_key+market), and
-- launch_time is stored RAW only (never used as authoritative first_seen). FastMoss DISCOVERS;
-- high 3-day sales/GMV/commission/seller volume never bypass qualification.
--
-- check_function_bodies disabled for this CREATE only (managed-instance validation path).
SET check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.fn_fastmoss_ingest_candidates(p_user_id uuid, p_market text, p_run_id uuid, p_candidate_limit integer, p_products jsonb, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_cfg record; v_run uuid := p_run_id; v_member uuid;
  v_cap int := greatest(1, least(coalesce(p_candidate_limit,10), 25));
  v_promoted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb;
  v_scanned int := 0; v_qualified int := 0; v_promoted_n int := 0;
  v_new int := 0; v_branded int := 0; v_correlated int := 0; v_idempotent int := 0;
  r record; v_raw jsonb; v_norm jsonb; v_name text; v_kid text; v_gate jsonb; v_brand jsonb;
  v_family text; v_screen text; v_pid uuid; v_ing jsonb; v_existing uuid; v_fam_existing uuid;
  v_auto jsonb; v_price numeric; v_dedup text; v_dispatch boolean; v_evidence jsonb;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('status','FAILED','reason','missing_user'); END IF;
  SELECT * INTO v_cfg FROM public.discovery_provider_market_config
    WHERE provider='FASTMOSS' AND market=v_mkt AND supported AND enabled;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','provider','FASTMOSS','market',v_mkt,
      'note','FastMoss does not support this market in discovery_provider_market_config; no substitution, no contamination');
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
      jsonb_build_object('discovery_source','fastmoss','lane','COMMERCE','provider','FASTMOSS','market',v_mkt,
        'capability','PRODUCT_NATIVE_COMMERCE_DISCOVERY','contract','fastmoss_commerce_discovery_v1'), now(), now());
  END IF;

  FOR r IN SELECT e FROM jsonb_array_elements(p_products) e LOOP
    EXIT WHEN v_promoted_n >= v_cap;
    v_scanned := v_scanned + 1;
    BEGIN
      v_name := btrim(coalesce(r.e->>'title', r.e->>'product_name',''));
      v_kid  := nullif(btrim(coalesce(r.e->>'product_id','')),'');
      IF v_name='' OR v_kid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','missing_name_or_id')); CONTINUE; END IF;

      v_gate := public.fn_is_product_native_entity(v_name);
      IF (v_gate->>'verdict') <> 'ACCEPT' THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,'reason','not_product_entity')); CONTINUE; END IF;
      v_qualified := v_qualified + 1;
      v_family := v_gate->>'normalized_name';
      v_brand := public.fn_is_branded_or_ip_sensitive(v_name);
      v_screen := v_brand->>'screening_state';
      v_dispatch := NOT (v_brand->>'flagged')::boolean;

      -- normalized signal: day3 -> short-window revenue/sales; real_price -> price.
      -- launch_time is NOT mapped to first_seen (semantics unverified): first_seen stays NULL.
      v_raw := jsonb_build_object('product_identity',v_name,'revenue',r.e->>'day3_gmv',
        'sales_units',r.e->>'day3_units_sold','price',r.e->>'real_price','cross_market_reference',false);
      v_norm := public.fn_discovery_signal_normalize('COMMERCE','fastmoss',v_mkt,v_raw);
      v_price := CASE WHEN (r.e->>'real_price') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (r.e->>'real_price')::numeric END;

      IF p_dry_run THEN
        v_promoted := v_promoted || jsonb_build_array(jsonb_build_object('product_id',v_kid,'product_name',v_name,
          'normalized',v_norm,'screening_state',v_screen,'product_family_key',v_family,
          'auto_dispatch_eligible',v_dispatch,'dry_run',true));
        v_promoted_n := v_promoted_n + 1; CONTINUE;
      END IF;

      -- provider raw evidence (seller preserved separately; provider totals + commission + raw launch_time)
      v_evidence := jsonb_build_array(jsonb_build_object(
        'claim','TikTok Shop new-listed product-native commerce signal ('||v_mkt||') from FastMoss newListed',
        'source_name','fastmoss','provenance','PLATFORM_REPORTED',
        'seller', jsonb_strip_nulls(jsonb_build_object('seller_id', nullif(btrim(coalesce(r.e->'shop'->>'seller_id','')),''),
          'name', nullif(btrim(coalesce(r.e->'shop'->>'name','')),''),
          'seller_total_units_sold', r.e->'shop'->>'total_units_sold')),
        'provider_totals', jsonb_strip_nulls(jsonb_build_object('total_units_sold', r.e->>'total_units_sold',
          'total_gmv', r.e->>'total_gmv','commission_rate', r.e->>'commission_rate')),
        'launch_time_raw', r.e->>'launch_time',
        'category', r.e->>'category'));

      -- 1) idempotent dedup by FastMoss provider product id
      SELECT id INTO v_existing FROM public.commerce_products
        WHERE user_id=p_user_id AND extended->>'fastmoss_product_id'=v_kid ORDER BY created_at LIMIT 1;
      -- 2) country-isolated normalized-family correlation (same product, different seller/provider record)
      SELECT id INTO v_fam_existing FROM public.commerce_products
        WHERE user_id=p_user_id AND extended->>'product_family_key'=v_family
          AND extended->>'market'=v_mkt AND (v_existing IS NULL) ORDER BY created_at LIMIT 1;

      IF v_existing IS NOT NULL THEN
        v_pid := v_existing; v_dedup := 'idempotent_existing'; v_idempotent := v_idempotent + 1;
      ELSIF v_fam_existing IS NOT NULL THEN
        v_pid := v_fam_existing; v_dedup := 'correlated_existing'; v_correlated := v_correlated + 1;
        UPDATE public.commerce_products SET extended = coalesce(extended,'{}'::jsonb)
          || jsonb_build_object('fastmoss_correlated_ids',
               coalesce(extended->'fastmoss_correlated_ids','[]'::jsonb) || jsonb_build_array(v_kid))
          WHERE id=v_pid;
      ELSE
        v_ing := public.ingest_commerce_product(p_user_id, v_run,
          jsonb_build_object('title',v_name,'product_type','tiktok_shop_product','category','tiktok_shop',
            'source_store','fastmoss','provenance','PLATFORM_REPORTED','is_physical_sellable','true',
            'candidate_acquisition_method','fastmoss_new_listed','source_family','product_native_commerce',
            'market',v_mkt),'INFERRED','candidate');
        v_pid := nullif(v_ing->>'product_id','')::uuid;
        IF v_pid IS NULL THEN
          v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','promotion_'||coalesce(v_ing->>'status','failed'))); CONTINUE; END IF;
        UPDATE public.commerce_products
          SET identity_basis='platform_id',
              observed_price=coalesce(observed_price, v_price),
              price_currency=coalesce(price_currency, v_cfg.currency),
              extended = coalesce(extended,'{}'::jsonb) || jsonb_build_object(
                'fastmoss_product_id', v_kid, 'product_family_key', v_family, 'market', v_mkt,
                'fastmoss_seller_id', nullif(btrim(coalesce(r.e->'shop'->>'seller_id','')),''),
                'fastmoss_seller_name', nullif(btrim(coalesce(r.e->'shop'->>'name','')),''),
                'provider_product_native','FASTMOSS','screening_state',v_screen,
                'launch_time_raw', r.e->>'launch_time')
          WHERE id=v_pid;
        IF EXISTS (SELECT 1 FROM public.monday_opportunity_registry WHERE tenant_id=p_user_id AND product_id=v_pid) THEN
          UPDATE public.monday_opportunity_registry SET active=true,
            markets = CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(markets) m WHERE m->>'country'=v_mkt)
                           THEN markets ELSE markets || jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)) END
            WHERE tenant_id=p_user_id AND product_id=v_pid;
        ELSE
          INSERT INTO public.monday_opportunity_registry (id, tenant_id, product_id, markets, active, created_at)
          VALUES (gen_random_uuid(), p_user_id, v_pid, jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_name)), true, now());
        END IF;
        IF v_dispatch THEN v_dedup := 'new'; v_new := v_new + 1;
        ELSE v_dedup := 'new_branded_review'; v_branded := v_branded + 1; END IF;
      END IF;

      -- every provider record contributes its (seller) evidence to the product, dedup-keyed per record
      PERFORM public.ingest_commerce_signal(p_user_id, v_pid, v_run, 'COMMERCE_PRODUCT_NATIVE',
        v_norm, v_evidence, 'PLATFORM_REPORTED', 0.6, now(), NULL,
        'fastmoss:'||v_kid||':'||v_mkt||':commerce_product_native');

      -- auto-dispatch deep research ONLY for a genuinely new, non-branded candidate (bounded)
      IF v_dedup = 'new' THEN
        BEGIN v_auto := public.fn_auto_dispatch_candidate_research(p_user_id, v_pid, v_mkt);
        EXCEPTION WHEN OTHERS THEN v_auto := jsonb_build_object('status','auto_dispatch_error','error',left(SQLERRM,160)); END;
      ELSE v_auto := jsonb_build_object('status','held_'||v_dedup); END IF;

      v_promoted_n := v_promoted_n + 1;
      v_promoted := v_promoted || jsonb_build_array(jsonb_build_object(
        'fastmoss_product_id',v_kid,'product_name',v_name,'product_id',v_pid,'dedup_status',v_dedup,
        'screening_state',v_screen,'observed_unit_price',v_price,
        'research_auto_dispatch', coalesce(v_auto->>'status','skipped'),'research_run_id', v_auto->>'run_id'));
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('product_id',v_kid,'reason','error:'||left(SQLERRM,140)));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_promoted_n>0 THEN 'SUCCESS_WITH_CANDIDATES' ELSE 'SUCCESS_ZERO_CANDIDATES' END,
    'provider','FASTMOSS','lane','COMMERCE','market',v_mkt,'run_id',v_run,
    'scanned',v_scanned,'qualified',v_qualified,'promoted_count',v_promoted_n,
    'new_dispatched',v_new,'branded_review',v_branded,'correlated',v_correlated,'idempotent',v_idempotent,
    'promoted',v_promoted,'skipped',v_skipped,'dry_run',p_dry_run,
    'note','FastMoss new-listed discovers product-native candidates only; identity/dedup + branded/IP review applied; each generic new candidate passes the existing eligibility + auto-research + concrete-resolution + evaluation gates. Provider record != product identity != seller != concrete SKU; UNKNOWN != 0; launch_time not authoritative; country-isolated.',
    'contract','pulse_fastmoss_commerce_ingest_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_fastmoss_ingest_candidates(uuid, text, uuid, integer, jsonb, boolean) TO authenticated, service_role;

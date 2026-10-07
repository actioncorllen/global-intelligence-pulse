-- mig_371c — Wire fresh discovery to automatic research dispatch
--
-- The discovery RPC previously ended at "created candidates only; each must pass
-- the deep-research pipeline before any opportunity claim" — but nothing carried
-- them there. This wires the final step: after a candidate is promoted and
-- registered, call fn_auto_dispatch_candidate_research so it enters the existing
-- research lifecycle automatically. The call is exception-isolated so a dispatch
-- hiccup never breaks discovery/registration, and its status is surfaced per
-- promoted candidate. Everything else in the discovery RPC is unchanged.

CREATE OR REPLACE FUNCTION public.fn_dataforseo_discover_candidates(p_user_id uuid, p_market text, p_category text, p_run_id uuid, p_candidate_limit integer, p_keywords jsonb, p_min_volume integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_loc int; v_run uuid := p_run_id; v_member uuid;
  v_cap int := greatest(1, least(coalesce(p_candidate_limit,5), 25));
  v_promoted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb;
  v_scanned int := 0; v_qualified int := 0; v_promoted_n int := 0;
  r record; v_q jsonb; v_kw text; v_vol int; v_intent text; v_rel text;
  v_existing_id uuid; v_existing_src text; v_entity_source text;
  v_entity jsonb; v_demand jsonb; v_ing jsonb; v_pid uuid; v_dedup text;
  v_auto jsonb;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('status','missing_user'); END IF;
  SELECT dataforseo_location_code INTO v_loc FROM public.ecommerce_market_universe
    WHERE country_code=v_mkt AND coalesce(ecommerce_eligible,true);
  IF v_loc IS NULL THEN
    RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','market',v_mkt,
      'note','market not ecommerce-eligible or has no DataForSEO location code');
  END IF;
  IF jsonb_typeof(p_keywords) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('status','no_keywords');
  END IF;

  IF v_run IS NULL THEN
    SELECT id INTO v_member FROM public.member WHERE auth_user_id=p_user_id LIMIT 1;
    IF v_member IS NULL THEN RETURN jsonb_build_object('status','no_member'); END IF;
    v_run := gen_random_uuid();
    INSERT INTO public.discovery_runs (id, user_id, member_id, run_status, entry_mode,
        contract_version, raw_contract, created_at, completed_at)
    VALUES (v_run, p_user_id, v_member, 'completed', 'no_store_yet',
        1,
        jsonb_build_object('discovery_source','dataforseo','market',v_mkt,'category',p_category,
          'location_code',v_loc,'candidate_limit',v_cap,'contract','dataforseo_discovery_v1_013q'),
        now(), now());
  END IF;

  FOR r IN SELECT e FROM jsonb_array_elements(p_keywords) e LOOP
    EXIT WHEN v_promoted_n >= v_cap;
    v_scanned := v_scanned + 1;
    BEGIN
      v_kw := btrim(coalesce(r.e->>'keyword',''));
      v_vol := CASE WHEN (r.e->>'search_volume') ~ '^[0-9]+$' THEN (r.e->>'search_volume')::int ELSE 0 END;
      v_intent := btrim(lower(coalesce(r.e->>'intent', r.e->>'intent_label','')));
      v_q := public.fn_dataforseo_discovery_qualify(p_category, v_kw, v_intent, v_vol, p_min_volume);
      IF NOT (v_q->>'qualified')::boolean THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('keyword',v_kw,'reason',v_q->>'reason'));
        CONTINUE;
      END IF;
      v_qualified := v_qualified + 1;
      v_rel := v_q->>'relevance';

      SELECT id, source_store INTO v_existing_id, v_existing_src
        FROM public.commerce_products
        WHERE user_id=p_user_id
          AND lower(regexp_replace(btrim(title),'\s+',' ','g')) = lower(regexp_replace(v_kw,'\s+',' ','g'))
        ORDER BY created_at LIMIT 1;
      v_entity_source := coalesce(v_existing_src, 'dataforseo');
      v_dedup := CASE WHEN v_existing_id IS NULL THEN 'new' ELSE 'deduplicated' END;

      v_entity := jsonb_build_object(
        'canonical_name', v_kw, 'source', v_entity_source,
        'product_type', p_category, 'category', p_category,
        'market', v_mkt, 'provenance', 'PLATFORM_REPORTED', 'is_physical_sellable','true');
      v_demand := jsonb_build_object(
        'market', v_mkt, 'language', coalesce(nullif(btrim(r.e->>'language'),''),'en'),
        'source', 'dataforseo_labs', 'source_reference', 'dataforseo:keyword_ideas',
        'queries', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
          'query', v_kw, 'relevance', v_rel,
          'avg_monthly_searches', v_vol,
          'competition', nullif(btrim(r.e->>'competition'),''),
          'competition_index', CASE WHEN (r.e->>'competition_index') ~ '^[0-9]+(\.[0-9]+)?$' THEN (r.e->>'competition_index')::numeric ELSE NULL END,
          'monthly_history', r.e->'monthly_history'))));

      v_ing := public.ingest_search_demand(p_user_id, v_run, v_entity, v_demand);
      v_pid := nullif(v_ing->>'product_id','')::uuid;
      IF v_pid IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('keyword',v_kw,'reason','promotion_'||coalesce(v_ing->>'status','failed')));
        CONTINUE;
      END IF;

      IF EXISTS (SELECT 1 FROM public.monday_opportunity_registry WHERE tenant_id=p_user_id AND product_id=v_pid) THEN
        UPDATE public.monday_opportunity_registry SET active=true,
          markets = CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(markets) m WHERE m->>'country'=v_mkt)
                         THEN markets
                         ELSE markets || jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_kw)) END
          WHERE tenant_id=p_user_id AND product_id=v_pid;
      ELSE
        INSERT INTO public.monday_opportunity_registry (id, tenant_id, product_id, markets, active, created_at)
        VALUES (gen_random_uuid(), p_user_id, v_pid,
          jsonb_build_array(jsonb_build_object('country',v_mkt,'price_query',v_kw)), true, now());
      END IF;

      -- BRIDGE: automatically dispatch the newly discovered, registered candidate
      -- into the existing research lifecycle. Exception-isolated so discovery and
      -- registration never fail on a dispatch hiccup.
      BEGIN
        v_auto := public.fn_auto_dispatch_candidate_research(p_user_id, v_pid, v_mkt);
      EXCEPTION WHEN OTHERS THEN
        v_auto := jsonb_build_object('status','auto_dispatch_error','error',left(SQLERRM,160));
      END;

      v_promoted_n := v_promoted_n + 1;
      v_promoted := v_promoted || jsonb_build_array(jsonb_build_object(
        'keyword', v_kw, 'market', v_mkt, 'search_volume', v_vol, 'intent', v_intent,
        'relevance', v_rel, 'dedup_status', v_dedup, 'product_id', v_pid,
        'discovered_via', v_entity_source, 'registered', true,
        'research_auto_dispatch', coalesce(v_auto->>'status','skipped'),
        'research_run_id', v_auto->>'run_id',
        'seasonality', v_ing->>'seasonality', 'momentum', v_ing->>'momentum'));
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('keyword',v_kw,'reason','error:'||left(SQLERRM,120)));
    END;
  END LOOP;

  RETURN jsonb_build_object('status','ok','market',v_mkt,'category',p_category,'run_id',v_run,
    'scanned',v_scanned,'qualified',v_qualified,'promoted_count',v_promoted_n,
    'promoted',v_promoted,'skipped',v_skipped,
    'note','DataForSEO discovery created candidates AND auto-dispatched each registered candidate into the existing multi-source deep-research pipeline (013N); opportunity claims still require that pipeline to complete.',
    'contract','pulse_dataforseo_discovery_v2_013q_autoresearch');
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_dataforseo_discover_candidates(uuid,text,text,uuid,integer,jsonb,integer) TO authenticated, service_role;

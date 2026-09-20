-- ============================================================================
-- mig_255_dataforseo_discovery_adapter.sql
-- STRATELOQ-DATAFORSEO-PRODUCT-DISCOVERY-013Q
--
-- 013P proved DataForSEO was validation-only (0 DataForSEO-originated products;
-- Reddit the sole active discovery feeder). This adds the missing DISCOVERY
-- adapter so DataForSEO search demand can surface product candidates that then
-- pass Strateloq's normal multi-source deep-research pipeline. It is an
-- EXTENSION that REUSES the existing plumbing — it creates no second pipeline:
--
--   DataForSEO discovery keywords (fetched server-side in n8n)
--     -> fn_dataforseo_discovery_qualify  (buyer intent + volume + 013L relevance + sellability)
--     -> ingest_search_demand -> resolve_product_entity -> ingest_commerce_product
--     -> monday_opportunity_registry  (existing candidate registry)
--     -> [existing 013N multi-source deep research -> WPS -> Product Decision]
--
-- Guarantees:
--  * DataForSEO NEVER declares a winner — it only creates a candidate; the WPS
--    decision comes from the unchanged multi-source pipeline.
--  * Dedup is SOURCE-INDEPENDENT by normalized title: a rediscovery of an
--    existing product (e.g. "kids nightlight projector", originally Reddit) links
--    DataForSEO demand evidence to the existing canonical product and PRESERVES
--    its original discovery provenance (source_store), never creating a duplicate.
--  * A genuinely new candidate is stamped source_store='dataforseo' (Discovered via).
--  * Market-aware (no hardcoded GB); reuses ecommerce_market_universe.
--  * No paid call here — the adapter processes results n8n already fetched.
--  * No WPS change, no cadence change, no second orchestrator.
-- ============================================================================

-- (1) Pure candidate qualifier: demand + commercial intent + product relevance.
--     Volume alone is never sufficient. Reuses the 013L relevance classifier and
--     the sellability gate. IMMUTABLE + no data access -> safe to call in a loop.
CREATE OR REPLACE FUNCTION public.fn_dataforseo_discovery_qualify(
  p_category text, p_keyword text, p_intent text, p_volume integer,
  p_min_volume integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $function$
DECLARE
  v_kw text := btrim(lower(coalesce(p_keyword,'')));
  v_intent text := btrim(lower(coalesce(p_intent,'')));
  v_rel text; v_sell text;
BEGIN
  IF v_kw = '' THEN
    RETURN jsonb_build_object('qualified',false,'reason','empty_keyword');
  END IF;
  -- buyer/commercial intent required (reject informational/navigational)
  IF v_intent NOT IN ('commercial','transactional') THEN
    RETURN jsonb_build_object('qualified',false,'reason','non_commercial_intent','intent',v_intent);
  END IF;
  -- meaningful search demand required (volume necessary, never sufficient alone)
  IF coalesce(p_volume,0) < greatest(1,coalesce(p_min_volume,50)) THEN
    RETURN jsonb_build_object('qualified',false,'reason','below_min_volume','volume',p_volume);
  END IF;
  -- product relevance vs the discovery category/topic (013L tiers; rejects
  -- accessory / service / informational / irrelevant / category-noise queries)
  v_rel := coalesce(public.fn_classify_search_query_relevance(coalesce(nullif(btrim(p_category),''), v_kw), v_kw)->>'relevance','IRRELEVANT');
  IF v_rel NOT IN ('DIRECT_PRODUCT','CLOSE_VARIANT','CATEGORY_DEMAND','SOLUTION_DEMAND') THEN
    RETURN jsonb_build_object('qualified',false,'reason','non_product_relevance','relevance',v_rel);
  END IF;
  -- sellable physical product gate (rejects services/jobs/news/non-product)
  v_sell := public.resolve_product_entity(jsonb_build_object('canonical_name', v_kw))->>'verdict';
  IF v_sell <> 'ACCEPT' THEN
    RETURN jsonb_build_object('qualified',false,'reason','not_sellable_product','verdict',v_sell,'relevance',v_rel);
  END IF;
  RETURN jsonb_build_object('qualified',true,'relevance',v_rel,'intent',v_intent,'volume',p_volume);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_dataforseo_discovery_qualify(text,text,text,integer,integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_dataforseo_discovery_qualify(text,text,text,integer,integer) TO authenticated, service_role;

-- (2) Discovery adapter: qualify -> dedup -> promote (existing path) -> register.
--     Service-role only; tenant is an explicit server-controlled argument (never
--     from the browser). Does NOT call any paid API and does NOT auto-dispatch
--     research (candidates enter the existing registry -> 013N pipeline).
CREATE OR REPLACE FUNCTION public.fn_dataforseo_discover_candidates(
  p_user_id uuid, p_market text, p_category text, p_run_id uuid,
  p_candidate_limit integer, p_keywords jsonb, p_min_volume integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_loc int; v_run uuid := p_run_id; v_member uuid;
  v_cap int := greatest(1, least(coalesce(p_candidate_limit,5), 25));
  v_promoted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb;
  v_scanned int := 0; v_qualified int := 0; v_promoted_n int := 0;
  r record; v_q jsonb; v_kw text; v_vol int; v_intent text; v_rel text;
  v_existing_id uuid; v_existing_src text; v_entity_source text;
  v_entity jsonb; v_demand jsonb; v_ing jsonb; v_pid uuid; v_dedup text;
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

  -- ensure a discovery run to attribute candidates to (reuses discovery_runs)
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

      -- SOURCE-INDEPENDENT dedup by normalized title against founder products
      SELECT id, source_store INTO v_existing_id, v_existing_src
        FROM public.commerce_products
        WHERE user_id=p_user_id
          AND lower(regexp_replace(btrim(title),'\s+',' ','g')) = lower(regexp_replace(v_kw,'\s+',' ','g'))
        ORDER BY created_at LIMIT 1;
      -- rediscovery -> reuse existing source so identity dedups AND original
      -- discovery provenance is preserved; new -> stamp 'dataforseo'
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

      -- register into the EXISTING candidate registry (per-market), idempotently
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

      v_promoted_n := v_promoted_n + 1;
      v_promoted := v_promoted || jsonb_build_array(jsonb_build_object(
        'keyword', v_kw, 'market', v_mkt, 'search_volume', v_vol, 'intent', v_intent,
        'relevance', v_rel, 'dedup_status', v_dedup, 'product_id', v_pid,
        'discovered_via', v_entity_source, 'registered', true,
        'seasonality', v_ing->>'seasonality', 'momentum', v_ing->>'momentum'));
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('keyword',v_kw,'reason','error:'||left(SQLERRM,120)));
    END;
  END LOOP;

  RETURN jsonb_build_object('status','ok','market',v_mkt,'category',p_category,'run_id',v_run,
    'scanned',v_scanned,'qualified',v_qualified,'promoted_count',v_promoted_n,
    'promoted',v_promoted,'skipped',v_skipped,
    'note','DataForSEO discovery created candidates only; each must pass the existing multi-source deep-research pipeline (013N) before any opportunity claim.',
    'contract','pulse_dataforseo_discovery_v1_013q');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_dataforseo_discover_candidates(uuid,text,text,uuid,integer,jsonb,integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_dataforseo_discover_candidates(uuid,text,text,uuid,integer,jsonb,integer) TO service_role;

-- (3) Offline selftest of the qualifier (no DB writes, no paid call).
CREATE OR REPLACE FUNCTION public.fn_dataforseo_discovery_selftest()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_res jsonb := '[]'::jsonb; v_pass boolean := true;
  cases jsonb := jsonb_build_array(
    jsonb_build_object('cat','star projector','kw','galaxy star projector','intent','commercial','vol',2900,'want',true),
    jsonb_build_object('cat','star projector','kw','star projector','intent','transactional','vol',5000,'want',true),
    jsonb_build_object('cat','star projector','kw','projector repair service','intent','commercial','vol',500,'want',false),
    jsonb_build_object('cat','star projector','kw','how does a star projector work','intent','informational','vol',900,'want',false),
    jsonb_build_object('cat','star projector','kw','projector screen','intent','commercial','vol',800,'want',false),
    jsonb_build_object('cat','star projector','kw','galaxy projector','intent','navigational','vol',3600,'want',false),
    jsonb_build_object('cat','star projector','kw','star projector','intent','commercial','vol',5,'want',false));
  c jsonb; v_got boolean;
BEGIN
  FOR c IN SELECT e FROM jsonb_array_elements(cases) e LOOP
    v_got := (public.fn_dataforseo_discovery_qualify(c->>'cat', c->>'kw', c->>'intent', (c->>'vol')::int)->>'qualified')::boolean;
    v_res := v_res || jsonb_build_array(jsonb_build_object('kw',c->>'kw','intent',c->>'intent','vol',c->>'vol',
      'want',(c->>'want')::boolean,'got',v_got,'pass',(v_got = (c->>'want')::boolean)));
    v_pass := v_pass AND (v_got = (c->>'want')::boolean);
  END LOOP;
  RETURN jsonb_build_object('all_pass',v_pass,'cases',v_res,'contract','pulse_dataforseo_discovery_selftest_v1_013q');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_dataforseo_discovery_selftest() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_dataforseo_discovery_selftest() TO authenticated, service_role;

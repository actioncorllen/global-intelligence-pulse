-- ============================================================================
-- mig_271_problem_discovery_dataforseo_reddit.sql
-- STRATELOQ-PROBLEM-DISCOVERY-015C — DataForSEO + Reddit problem discovery
--
-- Turns the 015B problem foundation into an evidence-backed discovery capability,
-- reusing the EXISTING providers (SEARCH_DEMAND/DataForSEO, COMMUNITY/Reddit) in an
-- ADDITIONAL "problem mode". No new providers. Product-first discovery is untouched:
-- the product-mode qualifier fn_dataforseo_discovery_qualify and the Reddit
-- product-attention path are NOT modified.
--
-- Ends at PROBLEM_DISCOVERED / (when corroborated) PROBLEM_CORROBORATED. No product
-- matching, no suppliers, no Product Decisions (that is 015D/015E).
--
-- Adds:
--   * commerce_problem_discovery_runs — a tenant-scoped, market+category scoped run
--     with canonical per-provider source-attempt states.
--   * fn_dataforseo_problem_qualify — PURE problem-mode qualifier (keeps problem/
--     question/solution-seeking queries; rejects commercial-product and generic noise).
--   * fn_reddit_pain_classify — PURE community-pain classifier (COMMUNITY_PAIN /
--     COMMUNITY_WORKAROUND / COMMUNITY_UNMET_NEED; rejects promo/supplier/generic).
--   * fn_problem_cluster_ensure — service-side cluster upsert under a run's tenant.
--   * fn_ingest_dataforseo_problem_demand / fn_ingest_reddit_problem_pain — receivers
--     that qualify real fetched evidence and attach it via the 015B canonical path
--     (commerce_signals, product_id NULL). Provider failure -> SOURCE_FAILED (never
--     SEARCHED_NO_EVIDENCE); a real search with 0 qualifying evidence ->
--     SEARCHED_NO_EVIDENCE.
--   * fn_request_problem_discovery — browser-safe entry point (market, category,
--     optional seed); server owns tenant/dispatch/ownership; makes NO paid call.
--   * fn_problem_discovery_read — own runs + source states + clusters + corroboration.
--   * fn_problem_discovery_selftest — deterministic fixtures (A-O), self-cleaning.
--
-- Corroboration reuses the 015B deterministic contract verbatim (no new score).
-- ============================================================================

-- (1) problem discovery run ----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.commerce_problem_discovery_runs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  market        text NOT NULL,
  category      text NOT NULL,
  problem_seed  text,
  status        text NOT NULL DEFAULT 'DISPATCHED'
                  CHECK (status IN ('DISPATCHED','PARTIAL','COMPLETE','FAILED')),
  source_states jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(source_states)='object'),
  provenance    jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(provenance)='object'),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commerce_problem_discovery_runs_market_chk CHECK (market = upper(market) AND length(market) BETWEEN 2 AND 8)
);
CREATE INDEX IF NOT EXISTS commerce_problem_discovery_runs_tenant_idx ON public.commerce_problem_discovery_runs(tenant_id);

DROP TRIGGER IF EXISTS trg_problem_discovery_runs_updated_at ON public.commerce_problem_discovery_runs;
CREATE TRIGGER trg_problem_discovery_runs_updated_at BEFORE UPDATE ON public.commerce_problem_discovery_runs
  FOR EACH ROW EXECUTE FUNCTION public.fn_problem_clusters_set_updated_at();

ALTER TABLE public.commerce_problem_discovery_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS commerce_problem_discovery_runs_select_own ON public.commerce_problem_discovery_runs;
CREATE POLICY commerce_problem_discovery_runs_select_own ON public.commerce_problem_discovery_runs
  FOR SELECT TO authenticated USING (auth.uid() = tenant_id);
DROP POLICY IF EXISTS commerce_problem_discovery_runs_service_all ON public.commerce_problem_discovery_runs;
CREATE POLICY commerce_problem_discovery_runs_service_all ON public.commerce_problem_discovery_runs
  FOR ALL TO service_role USING (true) WITH CHECK (true);
REVOKE ALL ON public.commerce_problem_discovery_runs FROM public, anon;
GRANT SELECT ON public.commerce_problem_discovery_runs TO authenticated;
GRANT ALL ON public.commerce_problem_discovery_runs TO service_role;

-- (2) PURE problem-mode DataForSEO qualifier -----------------------------------
-- Keeps observable problem/question/solution-seeking queries; rejects commercial
-- product queries (they belong to product mode) and generic informational noise.
-- Volume/intent are RECORDED, never converted to sales; volume is not a hard gate
-- (real problems can be low-volume) but is returned for evidence review.
CREATE OR REPLACE FUNCTION public.fn_dataforseo_problem_qualify(
  p_query text, p_category text, p_intent text DEFAULT NULL, p_volume integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $function$
DECLARE
  v_q text := btrim(lower(coalesce(p_query,'')));
  v_solution boolean; v_problem boolean; v_question boolean; v_commercial boolean; v_cat_share boolean;
BEGIN
  IF v_q = '' THEN RETURN jsonb_build_object('qualified',false,'reason','empty_query'); END IF;
  v_solution := v_q ~* '(how (to|do i|can i|do you)|best way to|easiest way to|way to|solution for|fix|prevent|avoid|stop |get rid of|declutter|organi[sz]e|tidy|help with|alternative to|hack (for|to))';
  v_problem  := v_q ~* '(problem with|struggl|trouble with|difficult|issue with|can''?t|cannot|won''?t|keeps |too much|no room|not enough|running out of|annoying|tired of|sick of|hate |messy|clutter|nowhere to)';
  v_question := v_q ~* '(^|[[:space:]])(how|why|what causes|is there a way)([[:space:]]|$)';
  v_commercial := v_q ~* '(^|[[:space:]])(buy|for sale|price|pricing|cheap|discount|coupon|deal|review|reviews)([[:space:]]|$)'
                  OR v_q ~* 'best .*(brand|model|deal)';
  v_cat_share := EXISTS(SELECT 1 FROM regexp_split_to_table(btrim(lower(coalesce(p_category,''))),'[[:space:]]+') t
                        WHERE length(t) >= 3 AND v_q LIKE '%'||t||'%');

  IF v_solution THEN
    RETURN jsonb_build_object('qualified',true,'problem_kind','SOLUTION_SEEKING','query',v_q,'intent',lower(coalesce(p_intent,'')),'volume',p_volume);
  ELSIF v_problem THEN
    RETURN jsonb_build_object('qualified',true,'problem_kind','PROBLEM','query',v_q,'intent',lower(coalesce(p_intent,'')),'volume',p_volume);
  ELSIF v_commercial THEN
    RETURN jsonb_build_object('qualified',false,'reason','commercial_product_query','query',v_q);
  ELSIF v_question AND v_cat_share THEN
    RETURN jsonb_build_object('qualified',true,'problem_kind','QUESTION','query',v_q,'intent',lower(coalesce(p_intent,'')),'volume',p_volume);
  ELSE
    RETURN jsonb_build_object('qualified',false,'reason','no_problem_pattern','query',v_q);
  END IF;
END; $function$;

-- (3) PURE Reddit community-pain classifier ------------------------------------
CREATE OR REPLACE FUNCTION public.fn_reddit_pain_classify(p_text text, p_category text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $function$
DECLARE v_t text := btrim(lower(coalesce(p_text,'')));
BEGIN
  IF v_t = '' THEN RETURN jsonb_build_object('kind','NONE','reason','empty'); END IF;
  -- reject promotional / supplier posts first (never pain evidence)
  IF v_t ~* '(use code|discount code|coupon|link in bio|shop now|for sale|affiliate|buy now|dm me|wholesale|dropship|supplier|\bmoq\b|b2b|check out my|our store)' THEN
    RETURN jsonb_build_object('kind','NONE','reason','promotional_or_supplier');
  END IF;
  IF v_t ~* '(wish there was|why isn''?t there|someone should make|no product (that|for)|can''?t find any|nothing exists|is there anything that|need something that|does anyone make|why is there no)' THEN
    RETURN jsonb_build_object('kind','COMMUNITY_UNMET_NEED','reason','unmet_need_marker');
  END IF;
  IF v_t ~* '(workaround|work around|makeshift|\bdiy\b|jury ?rig|duct tape|i ended up|i just use|my hack|hack to|instead i (use|used|bought)|had to improvise|rigged up)' THEN
    RETURN jsonb_build_object('kind','COMMUNITY_WORKAROUND','reason','workaround_marker');
  END IF;
  IF v_t ~* '(hate |frustrat|annoying|struggl|problem with|keeps |too much|no room|not enough|tired of|sick of|can''?t|cannot|driving me (crazy|nuts)|nightmare|impossible to|nowhere to|pain to)' THEN
    RETURN jsonb_build_object('kind','COMMUNITY_PAIN','reason','pain_marker');
  END IF;
  RETURN jsonb_build_object('kind','NONE','reason','no_pain_marker');
END; $function$;

-- (4) canonical vocabulary set-source-state on a run ---------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_discovery_set_source_state(
  p_run_id uuid, p_evidence_category text, p_source text, p_state text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_allowed text[] := ARRAY['NOT_SEARCHED','SEARCHING','SEARCHED_EVIDENCE_FOUND','SEARCHED_NO_EVIDENCE',
                            'SOURCE_FAILED','SOURCE_UNAVAILABLE','SOURCE_BLOCKED','UNSUPPORTED_MARKET'];
  v_ss jsonb; v_status text; v_open int; v_ok int; v_bad int; v_total int;
BEGIN
  IF NOT (upper(p_state) = ANY(v_allowed)) THEN RETURN jsonb_build_object('status','invalid_state','state',p_state); END IF;
  UPDATE public.commerce_problem_discovery_runs
    SET source_states = coalesce(source_states,'{}'::jsonb) || jsonb_build_object(
          upper(p_evidence_category), jsonb_build_object('source',upper(p_source),'state',upper(p_state),
            'note',p_note,'observed_at',now()))
    WHERE id = p_run_id
    RETURNING source_states INTO v_ss;
  IF v_ss IS NULL THEN RETURN jsonb_build_object('status','run_not_found'); END IF;

  SELECT count(*), count(*) FILTER (WHERE (e.value->>'state') IN ('NOT_SEARCHED','SEARCHING')),
         count(*) FILTER (WHERE (e.value->>'state') IN ('SEARCHED_EVIDENCE_FOUND','SEARCHED_NO_EVIDENCE')),
         count(*) FILTER (WHERE (e.value->>'state') IN ('SOURCE_FAILED','SOURCE_UNAVAILABLE','SOURCE_BLOCKED','UNSUPPORTED_MARKET'))
    INTO v_total, v_open, v_ok, v_bad
  FROM jsonb_each(v_ss) e;

  v_status := CASE
    WHEN v_total = 0 THEN 'DISPATCHED'
    WHEN v_open > 0 THEN 'PARTIAL'
    WHEN v_ok = 0 AND v_bad > 0 THEN 'FAILED'
    ELSE 'COMPLETE' END;
  UPDATE public.commerce_problem_discovery_runs SET status = v_status WHERE id = p_run_id;
  RETURN jsonb_build_object('status','ok','run_status',v_status,'source_states',v_ss);
END; $function$;

-- (5) service-side cluster ensure (tenant from the run, never the browser) ------
CREATE OR REPLACE FUNCTION public.fn_problem_cluster_ensure(
  p_run_id uuid, p_canonical_problem text, p_problem_summary text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_run public.commerce_problem_discovery_runs%rowtype; v_id uuid;
BEGIN
  SELECT * INTO v_run FROM public.commerce_problem_discovery_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','run_not_found'); END IF;
  IF btrim(coalesce(p_canonical_problem,'')) = '' THEN RETURN jsonb_build_object('status','invalid_problem'); END IF;

  INSERT INTO public.commerce_problem_clusters(tenant_id, market, category, canonical_problem, problem_summary, provenance)
  VALUES (v_run.tenant_id, v_run.market, v_run.category, btrim(p_canonical_problem), p_problem_summary,
          jsonb_build_object('created_via','fn_problem_cluster_ensure','discovery_run_id',p_run_id,'entry','SERVER'))
  ON CONFLICT (tenant_id, market, canonical_problem)
    DO UPDATE SET problem_summary = coalesce(excluded.problem_summary, public.commerce_problem_clusters.problem_summary),
                  provenance = public.commerce_problem_clusters.provenance || jsonb_build_object('discovery_run_id',p_run_id)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('status','ok','cluster_id',v_id,'tenant_id',v_run.tenant_id,'market',v_run.market);
END; $function$;

-- (6) DataForSEO problem-demand receiver ---------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ingest_dataforseo_problem_demand(
  p_run_id uuid, p_cluster_id uuid, p_market text, p_keywords jsonb, p_dry_run boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_run public.commerce_problem_discovery_runs%rowtype; v_c public.commerce_problem_clusters%rowtype;
  k jsonb; v_qual jsonb; v_scanned int := 0; v_qualified int := 0; v_attached int := 0;
  v_details jsonb := '[]'::jsonb; v_ev jsonb; v_q text; v_vol int; v_intent text; v_att jsonb;
BEGIN
  SELECT * INTO v_run FROM public.commerce_problem_discovery_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','run_not_found'); END IF;
  -- provider/API operational failure: NOT zero evidence -> SOURCE_FAILED
  IF jsonb_typeof(p_keywords) <> 'array' THEN
    PERFORM public.fn_problem_discovery_set_source_state(p_run_id,'SEARCH_DEMAND','DATAFORSEO','SOURCE_FAILED','non-array payload (provider/API issue)');
    RETURN jsonb_build_object('status','not_keyword_array','note','operational issue; evidence unchanged, never zeroed');
  END IF;
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','cluster_not_found'); END IF;

  FOR k IN SELECT * FROM jsonb_array_elements(p_keywords) LOOP
    v_scanned := v_scanned + 1;
    v_q := k->>'query'; v_intent := k->>'intent';
    v_vol := nullif(k->>'volume','')::int;
    v_qual := public.fn_dataforseo_problem_qualify(v_q, v_c.category, v_intent, v_vol);
    IF (v_qual->>'qualified')::boolean THEN
      v_qualified := v_qualified + 1;
      IF NOT p_dry_run THEN
        v_ev := jsonb_build_array(jsonb_build_object(
          'claim','Platform-reported problem/solution-seeking search query',
          'query', v_q, 'problem_kind', v_qual->>'problem_kind',
          'avg_monthly_searches', v_vol, 'intent_label', lower(coalesce(v_intent,'')),
          'competition', k->>'competition', 'provenance','PLATFORM_REPORTED',
          'source_name','dataforseo_labs', 'source_reference', coalesce(k->>'source_reference','dataforseo:keyword_ideas')));
        v_att := public.fn_problem_signal_attach(p_cluster_id,'SEARCH_PROBLEM_DEMAND','DATAFORSEO',p_market,
                   v_q, NULL, v_ev, now(), NULL, 'problemdemand:'||p_cluster_id::text||':'||md5(coalesce(v_q,'')), false,
                   CASE WHEN lower(coalesce(v_intent,'')) IN ('commercial','transactional') THEN 0.6 ELSE 0.5 END);
        IF (v_att->>'inserted')::boolean THEN v_attached := v_attached + 1; END IF;
      END IF;
    END IF;
    v_details := v_details || jsonb_build_array(jsonb_build_object('query',v_q,'qualified',(v_qual->>'qualified')::boolean,
      'problem_kind',v_qual->>'problem_kind','reason',v_qual->>'reason'));
  END LOOP;

  IF NOT p_dry_run THEN
    PERFORM public.fn_problem_discovery_set_source_state(p_run_id,'SEARCH_DEMAND','DATAFORSEO',
      CASE WHEN v_qualified > 0 THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'SEARCHED_NO_EVIDENCE' END,
      'scanned '||v_scanned||', qualified '||v_qualified);
  END IF;
  RETURN jsonb_build_object('status','ok','source','DATAFORSEO','signal_type','SEARCH_PROBLEM_DEMAND',
    'scanned',v_scanned,'qualified',v_qualified,'attached',v_attached,
    'attempt_state', CASE WHEN v_qualified > 0 THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'SEARCHED_NO_EVIDENCE' END,
    'details',v_details);
END; $function$;

-- (7) Reddit problem-pain receiver ---------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ingest_reddit_problem_pain(
  p_run_id uuid, p_cluster_id uuid, p_market text, p_posts jsonb, p_dry_run boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_run public.commerce_problem_discovery_runs%rowtype; v_c public.commerce_problem_clusters%rowtype;
  po jsonb; v_cls jsonb; v_kind text; v_scanned int := 0; v_qualified int := 0; v_attached int := 0;
  v_details jsonb := '[]'::jsonb; v_ev jsonb; v_txt text; v_att jsonb; v_url text; v_sub text; v_when timestamptz;
BEGIN
  SELECT * INTO v_run FROM public.commerce_problem_discovery_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','run_not_found'); END IF;
  IF jsonb_typeof(p_posts) <> 'array' THEN
    PERFORM public.fn_problem_discovery_set_source_state(p_run_id,'COMMUNITY','REDDIT','SOURCE_FAILED','non-array payload (provider/API issue)');
    RETURN jsonb_build_object('status','not_post_array','note','operational issue; evidence unchanged, never zeroed');
  END IF;
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','cluster_not_found'); END IF;

  FOR po IN SELECT * FROM jsonb_array_elements(p_posts) LOOP
    v_scanned := v_scanned + 1;
    v_txt := btrim(concat_ws(' ', po->>'title', po->>'text', po->>'body'));
    v_sub := po->>'subreddit'; v_url := po->>'url'; v_when := nullif(po->>'created_at','')::timestamptz;
    v_cls := public.fn_reddit_pain_classify(v_txt, v_c.category);
    v_kind := v_cls->>'kind';
    IF v_kind IN ('COMMUNITY_PAIN','COMMUNITY_WORKAROUND','COMMUNITY_UNMET_NEED') THEN
      v_qualified := v_qualified + 1;
      IF NOT p_dry_run THEN
        v_ev := jsonb_build_array(jsonb_build_object(
          'claim','Observed community pain statement on reddit',
          'provenance','OBSERVED','signal_type', lower(v_kind), 'reason', v_cls->>'reason',
          'source_name','reddit','subreddit',v_sub,'source_reference', coalesce(v_url,'reddit'),
          'context', left(v_txt, 500)));
        v_att := public.fn_problem_signal_attach(p_cluster_id, v_kind, 'REDDIT', p_market,
                   NULL, left(v_txt,500), v_ev, now(), v_when,
                   'problempain:'||p_cluster_id::text||':'||v_kind||':'||md5(coalesce(v_txt,'')||coalesce(v_url,'')), false, NULL);
        IF (v_att->>'inserted')::boolean THEN v_attached := v_attached + 1; END IF;
      END IF;
    END IF;
    v_details := v_details || jsonb_build_array(jsonb_build_object('subreddit',v_sub,'kind',v_kind,'reason',v_cls->>'reason'));
  END LOOP;

  IF NOT p_dry_run THEN
    PERFORM public.fn_problem_discovery_set_source_state(p_run_id,'COMMUNITY','REDDIT',
      CASE WHEN v_qualified > 0 THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'SEARCHED_NO_EVIDENCE' END,
      'scanned '||v_scanned||', qualified '||v_qualified);
  END IF;
  RETURN jsonb_build_object('status','ok','source','REDDIT',
    'scanned',v_scanned,'qualified',v_qualified,'attached',v_attached,
    'attempt_state', CASE WHEN v_qualified > 0 THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'SEARCHED_NO_EVIDENCE' END,
    'details',v_details);
END; $function$;

-- (8) browser-safe entry point (no paid call here) -----------------------------
CREATE OR REPLACE FUNCTION public.fn_request_problem_discovery(
  p_market text, p_category text, p_problem_seed text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_mkt text := upper(btrim(coalesce(p_market,''))); v_loc int;
  v_run uuid; v_ss jsonb; v_ds text; v_rd text;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF btrim(coalesce(p_category,'')) = '' THEN RETURN jsonb_build_object('status','category_required',
    'note','problem discovery must be scoped to a category/niche; unconstrained search is not allowed'); END IF;
  SELECT dataforseo_location_code INTO v_loc FROM public.ecommerce_market_universe
    WHERE country_code = v_mkt AND coalesce(ecommerce_eligible,true);
  IF v_loc IS NULL THEN RETURN jsonb_build_object('status','UNSUPPORTED_MARKET','market',v_mkt); END IF;

  v_ds := CASE WHEN (SELECT availability FROM public.provider_capability_registry
                     WHERE source='DATAFORSEO' AND evidence_category='SEARCH_DEMAND')='AVAILABLE'
               THEN 'NOT_SEARCHED' ELSE 'SOURCE_UNAVAILABLE' END;
  v_rd := CASE WHEN (SELECT availability FROM public.provider_capability_registry
                     WHERE source='REDDIT' AND evidence_category='COMMUNITY')='AVAILABLE'
               THEN 'NOT_SEARCHED' ELSE 'SOURCE_UNAVAILABLE' END;
  v_ss := jsonb_build_object(
    'SEARCH_DEMAND', jsonb_build_object('source','DATAFORSEO','state',v_ds,'observed_at',now()),
    'COMMUNITY',     jsonb_build_object('source','REDDIT','state',v_rd,'observed_at',now()));

  INSERT INTO public.commerce_problem_discovery_runs(tenant_id, market, category, problem_seed, status, source_states, provenance)
  VALUES (v_uid, v_mkt, btrim(p_category), nullif(btrim(coalesce(p_problem_seed,'')),''), 'DISPATCHED', v_ss,
          jsonb_build_object('created_via','fn_request_problem_discovery','entry','USER'))
  RETURNING id INTO v_run;

  RETURN jsonb_build_object('status','DISPATCHED','run_id',v_run,'market',v_mkt,'category',btrim(p_category),
    'problem_seed', nullif(btrim(coalesce(p_problem_seed,'')),''),
    'dispatch_manifest', jsonb_build_object(
      'dataforseo', jsonb_build_object('endpoints', jsonb_build_array('dataforseo_labs/google/keyword_ideas/live','dataforseo_labs/google/search_intent/live'),
        'location_code', v_loc, 'mode','PROBLEM', 'note','n8n fetches server-side; receiver fn_ingest_dataforseo_problem_demand qualifies'),
      'reddit', jsonb_build_object('mode','PROBLEM','note','n8n fetches public JSON; receiver fn_ingest_reddit_problem_pain classifies')),
    'note','No paid provider call is made by this function; providers are dispatched via n8n. Server owns tenant/ownership.');
END; $function$;

-- (9) own runs read ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_discovery_read(p_run_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT coalesce(jsonb_agg(row ORDER BY (row->>'created_at') DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'run_id', r.id, 'market', r.market, 'category', r.category, 'problem_seed', r.problem_seed,
      'status', r.status, 'source_states', r.source_states,
      'clusters', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'cluster_id', c.id, 'canonical_problem', c.canonical_problem, 'status', c.status,
          'corroboration', public.fn_problem_corroboration_state(c.id))), '[]'::jsonb)
        FROM public.commerce_problem_clusters c
        WHERE c.tenant_id = r.tenant_id AND (c.provenance->>'discovery_run_id') = r.id::text),
      'created_at', r.created_at
    ) AS row
    FROM public.commerce_problem_discovery_runs r
    WHERE r.tenant_id = v_uid AND (p_run_id IS NULL OR r.id = p_run_id)
  ) z;
  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'runs', v_rows);
END; $function$;

-- grants
REVOKE ALL ON FUNCTION public.fn_dataforseo_problem_qualify(text,text,text,integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_dataforseo_problem_qualify(text,text,text,integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_reddit_pain_classify(text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_reddit_pain_classify(text,text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_request_problem_discovery(text,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_request_problem_discovery(text,text,text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_problem_discovery_read(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_problem_discovery_read(uuid) TO authenticated, service_role;
-- service-role only (executors)
REVOKE ALL ON FUNCTION public.fn_problem_discovery_set_source_state(uuid,text,text,text,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_problem_discovery_set_source_state(uuid,text,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION public.fn_problem_cluster_ensure(uuid,text,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_problem_cluster_ensure(uuid,text,text) TO service_role;
REVOKE ALL ON FUNCTION public.fn_ingest_dataforseo_problem_demand(uuid,uuid,text,jsonb,boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ingest_dataforseo_problem_demand(uuid,uuid,text,jsonb,boolean) TO service_role;
REVOKE ALL ON FUNCTION public.fn_ingest_reddit_problem_pain(uuid,uuid,text,jsonb,boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ingest_reddit_problem_pain(uuid,uuid,text,jsonb,boolean) TO service_role;

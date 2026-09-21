-- ============================================================================
-- mig_269_problem_intelligence_foundation.sql
-- STRATELOQ-PROBLEM-INTELLIGENCE-015B — Canonical Problem Foundation
--
-- Smallest ADDITIVE backend for problem-first discovery. Per the 015A verdict
-- (PROBLEM_INTELLIGENCE_REUSE_READY) this builds NO parallel research or scoring
-- system. It adds:
--   1. commerce_problem_clusters — a tenant-scoped canonical problem entity with a
--      deterministic status lifecycle.
--   2. commerce_signals.problem_cluster_id — a nullable relational link so problem
--      evidence stays CANONICAL evidence (product_id remains NULL) rather than a
--      second evidence warehouse.
--   3. A minimal problem signal taxonomy (values only; signal_type has no CHECK).
--   4. A DETERMINISTIC corroboration contract (SINGLE_SOURCE /
--      MULTI_EVIDENCE_SINGLE_SOURCE / MULTI_SOURCE_CORROBORATED) — many records from
--      one provider never manufacture corroboration; only >=2 independent qualifying
--      providers in the SELECTED market corroborate.
--   5. Safe browser/server contracts (auth.uid ownership; no browser-supplied
--      ownership; no cross-tenant leakage).
--   6. Product-match LINKAGE (matched_product_id -> commerce_products) prepared but
--      the matcher itself is NOT implemented here. Supplier presence alone can never
--      set PRODUCT_MATCHED.
--
-- LLM boundary (LOCKED): hypothesis-flagged evidence is NEVER counted toward
-- corroboration, and every promoted status is gated on observable evidence +
-- deterministic rules. An LLM may summarize/cluster/hypothesize only.
--
-- Market truth (LOCKED): every cluster is market-scoped; cross-market evidence is
-- retained but labelled CONTEXTUAL_CROSS_MARKET and never counts as selected-market
-- corroboration. Presence language is reserved for a later unit as LOW OBSERVED
-- MARKET PRESENCE — this migration never claims a product is "not sold" anywhere.
--
-- The existing product-first pipeline is UNCHANGED. The only touch to an existing
-- table is a single nullable, default-NULL column on commerce_signals (additive;
-- existing explicit-column inserts are unaffected).
-- ============================================================================

-- 0) status rank helper (pure) --------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_status_rank(p_status text)
RETURNS int LANGUAGE sql IMMUTABLE SET search_path TO '' AS $function$
  SELECT CASE p_status
    WHEN 'PROBLEM_DISCOVERED'     THEN 1
    WHEN 'PROBLEM_CORROBORATED'   THEN 2
    WHEN 'SOLUTION_CANDIDATE'     THEN 3
    WHEN 'PRODUCT_MATCHED'        THEN 4
    WHEN 'MARKET_ASSESSED'        THEN 5
    WHEN 'PRODUCT_DECISION_READY' THEN 6
    ELSE 0 END;
$function$;

-- 1) canonical problem cluster --------------------------------------------------
CREATE TABLE IF NOT EXISTS public.commerce_problem_clusters (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  market            text NOT NULL,
  category          text,
  canonical_problem text NOT NULL,
  problem_summary   text,
  status            text NOT NULL DEFAULT 'PROBLEM_DISCOVERED'
                      CHECK (status IN ('PROBLEM_DISCOVERED','PROBLEM_CORROBORATED','SOLUTION_CANDIDATE',
                                        'PRODUCT_MATCHED','MARKET_ASSESSED','PRODUCT_DECISION_READY')),
  matched_product_id uuid REFERENCES public.commerce_products(id) ON DELETE SET NULL,
  provenance        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(provenance)='object'),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commerce_problem_clusters_market_chk CHECK (market = upper(market) AND length(market) BETWEEN 2 AND 8),
  CONSTRAINT commerce_problem_clusters_identity_uniq UNIQUE (tenant_id, market, canonical_problem)
);
CREATE INDEX IF NOT EXISTS commerce_problem_clusters_tenant_idx ON public.commerce_problem_clusters(tenant_id);
CREATE INDEX IF NOT EXISTS commerce_problem_clusters_market_idx ON public.commerce_problem_clusters(tenant_id, market);
CREATE INDEX IF NOT EXISTS commerce_problem_clusters_matched_idx ON public.commerce_problem_clusters(matched_product_id);

-- updated_at maintenance (dedicated, does not clobber any shared helper)
CREATE OR REPLACE FUNCTION public.fn_problem_clusters_set_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $function$
BEGIN NEW.updated_at := now(); RETURN NEW; END; $function$;
DROP TRIGGER IF EXISTS trg_problem_clusters_updated_at ON public.commerce_problem_clusters;
CREATE TRIGGER trg_problem_clusters_updated_at BEFORE UPDATE ON public.commerce_problem_clusters
  FOR EACH ROW EXECUTE FUNCTION public.fn_problem_clusters_set_updated_at();

-- RLS: own-tenant read for authenticated; full access for service_role only.
-- Writes flow exclusively through SECURITY DEFINER RPCs (no direct authenticated write).
ALTER TABLE public.commerce_problem_clusters ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS commerce_problem_clusters_select_own ON public.commerce_problem_clusters;
CREATE POLICY commerce_problem_clusters_select_own ON public.commerce_problem_clusters
  FOR SELECT TO authenticated USING (auth.uid() = tenant_id);
DROP POLICY IF EXISTS commerce_problem_clusters_service_all ON public.commerce_problem_clusters;
CREATE POLICY commerce_problem_clusters_service_all ON public.commerce_problem_clusters
  FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL ON public.commerce_problem_clusters FROM public, anon;
GRANT SELECT ON public.commerce_problem_clusters TO authenticated;
GRANT ALL ON public.commerce_problem_clusters TO service_role;

-- 2) minimal relational link on the CANONICAL evidence store (additive, nullable) --
ALTER TABLE public.commerce_signals
  ADD COLUMN IF NOT EXISTS problem_cluster_id uuid
  REFERENCES public.commerce_problem_clusters(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS commerce_signals_problem_cluster_idx
  ON public.commerce_signals(problem_cluster_id) WHERE problem_cluster_id IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 3+4) DETERMINISTIC corroboration state
--   Qualifying problem signal = linked to the cluster
--       AND signal_type in the problem taxonomy
--       AND provenance.market_scope = 'SELECTED_MARKET' (signal market = cluster market)
--       AND NOT hypothesis (provenance.hypothesis <> 'true')     -- LLM boundary
--       AND provider (provenance.source) NOT a supplier          -- supplier != demand
--   n = qualifying count; d = distinct qualifying providers.
--   n=0 -> INSUFFICIENT_EVIDENCE ; n=1 -> SINGLE_SOURCE ;
--   n>=2 & d=1 -> MULTI_EVIDENCE_SINGLE_SOURCE ; n>=2 & d>=2 -> MULTI_SOURCE_CORROBORATED.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_corroboration_state(p_cluster_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_c public.commerce_problem_clusters%rowtype;
  v_types text[] := ARRAY['SEARCH_PROBLEM_DEMAND','COMMUNITY_PAIN','COMMUNITY_WORKAROUND','COMMUNITY_UNMET_NEED'];
  v_supplier text[] := ARRAY['CJ','CJDROPSHIPPING','SUPPLIER'];
  v_n int; v_d int; v_ctx int; v_state text; v_sources jsonb;
BEGIN
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF v_uid IS NOT NULL AND v_c.tenant_id <> v_uid THEN
    RETURN jsonb_build_object('status','forbidden');
  END IF;

  WITH q AS (
    SELECT upper(coalesce(s.provenance->>'source','')) AS src
    FROM public.commerce_signals s
    WHERE s.problem_cluster_id = p_cluster_id
      AND s.signal_type = ANY(v_types)
      AND coalesce(s.provenance->>'market_scope','') = 'SELECTED_MARKET'
      AND coalesce(s.provenance->>'hypothesis','false') <> 'true'
      AND upper(coalesce(s.provenance->>'source','')) <> ALL(v_supplier)
  )
  SELECT count(*)::int, count(DISTINCT src)::int,
         coalesce(jsonb_agg(DISTINCT src),'[]'::jsonb)
    INTO v_n, v_d, v_sources FROM q;

  SELECT count(*)::int INTO v_ctx
  FROM public.commerce_signals s
  WHERE s.problem_cluster_id = p_cluster_id
    AND s.signal_type = ANY(v_types)
    AND coalesce(s.provenance->>'market_scope','') = 'CONTEXTUAL_CROSS_MARKET';

  v_state := CASE
    WHEN v_n = 0 THEN 'INSUFFICIENT_EVIDENCE'
    WHEN v_n = 1 THEN 'SINGLE_SOURCE'
    WHEN v_d = 1 THEN 'MULTI_EVIDENCE_SINGLE_SOURCE'
    ELSE 'MULTI_SOURCE_CORROBORATED' END;

  RETURN jsonb_build_object(
    'status','ok','cluster_id',p_cluster_id,'market',v_c.market,
    'corroboration_state',v_state,
    'qualifying_signals',v_n,'distinct_qualifying_sources',v_d,
    'contextual_cross_market_signals',v_ctx,
    'sources',v_sources,
    'corroborated', (v_state = 'MULTI_SOURCE_CORROBORATED'),
    'rule','n=0:INSUFFICIENT; n=1:SINGLE_SOURCE; n>=2 & d=1:MULTI_EVIDENCE_SINGLE_SOURCE; n>=2 & d>=2:MULTI_SOURCE_CORROBORATED (selected-market, non-hypothesis, non-supplier only)');
END; $function$;

-- ------------------------------------------------------------------------------
-- 5) browser-safe upsert (authenticated; tenant = auth.uid(); no status authority)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_cluster_upsert(
  p_market text, p_category text, p_canonical_problem text,
  p_problem_summary text DEFAULT NULL, p_cluster_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_mkt text := upper(btrim(coalesce(p_market,''))); v_id uuid; v_row public.commerce_problem_clusters%rowtype;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF v_mkt = '' OR btrim(coalesce(p_canonical_problem,'')) = '' THEN
    RETURN jsonb_build_object('status','invalid_input','note','market and canonical_problem are required');
  END IF;

  IF p_cluster_id IS NOT NULL THEN
    UPDATE public.commerce_problem_clusters
      SET category = coalesce(p_category, category),
          problem_summary = coalesce(p_problem_summary, problem_summary)
      WHERE id = p_cluster_id AND tenant_id = v_uid
      RETURNING id INTO v_id;
    IF v_id IS NULL THEN RETURN jsonb_build_object('status','not_found_or_forbidden'); END IF;
  ELSE
    INSERT INTO public.commerce_problem_clusters(tenant_id, market, category, canonical_problem, problem_summary,
                                                 provenance)
    VALUES (v_uid, v_mkt, p_category, btrim(p_canonical_problem), p_problem_summary,
            jsonb_build_object('created_via','fn_problem_cluster_upsert','entry','USER'))
    ON CONFLICT (tenant_id, market, canonical_problem)
      DO UPDATE SET category = coalesce(excluded.category, public.commerce_problem_clusters.category),
                    problem_summary = coalesce(excluded.problem_summary, public.commerce_problem_clusters.problem_summary)
    RETURNING id INTO v_id;
  END IF;

  SELECT * INTO v_row FROM public.commerce_problem_clusters WHERE id = v_id;
  RETURN jsonb_build_object('status','ok','cluster', to_jsonb(v_row));
END; $function$;

-- ------------------------------------------------------------------------------
-- 6) attach problem evidence (service_role only — executors write evidence, never
--    the browser). product_id stays NULL; evidence stays canonical in commerce_signals.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_signal_attach(
  p_cluster_id uuid, p_signal_type text, p_source text, p_market text,
  p_query text DEFAULT NULL, p_context text DEFAULT NULL, p_evidence jsonb DEFAULT NULL,
  p_observed_at timestamptz DEFAULT now(), p_source_event_at timestamptz DEFAULT NULL,
  p_dedup_key text DEFAULT NULL, p_hypothesis boolean DEFAULT false, p_confidence numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_c public.commerce_problem_clusters%rowtype;
  v_types text[] := ARRAY['SEARCH_PROBLEM_DEMAND','COMMUNITY_PAIN','COMMUNITY_WORKAROUND','COMMUNITY_UNMET_NEED'];
  v_supplier text[] := ARRAY['CJ','CJDROPSHIPPING','SUPPLIER'];
  v_st text := upper(btrim(coalesce(p_signal_type,'')));
  v_src text := upper(btrim(coalesce(p_source,'')));
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_scope text; v_ev jsonb; v_prov jsonb; v_dedup text; v_id uuid; v_counted boolean;
BEGIN
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','cluster_not_found'); END IF;
  IF NOT (v_st = ANY(v_types)) THEN
    RETURN jsonb_build_object('status','invalid_signal_type','allowed',to_jsonb(v_types));
  END IF;
  IF v_mkt = '' THEN RETURN jsonb_build_object('status','invalid_market'); END IF;

  v_scope := CASE WHEN v_mkt = v_c.market THEN 'SELECTED_MARKET' ELSE 'CONTEXTUAL_CROSS_MARKET' END;

  v_ev := coalesce(p_evidence, jsonb_build_array(jsonb_build_object(
            'claim', concat_ws(' ', 'Observed problem evidence on', v_src, 'for', v_c.market),
            'query', p_query, 'context', p_context,
            'provenance', CASE WHEN p_hypothesis THEN 'HYPOTHESIS' ELSE 'OBSERVED' END,
            'source_name', lower(v_src))));
  IF jsonb_typeof(v_ev) <> 'array' THEN v_ev := jsonb_build_array(v_ev); END IF;

  v_prov := jsonb_build_object(
    'source', v_src, 'market', v_mkt, 'market_scope', v_scope,
    'hypothesis', p_hypothesis, 'signal', CASE WHEN p_hypothesis THEN 'HYPOTHESIS' ELSE 'OBSERVED' END,
    'problem_cluster_id', p_cluster_id, 'entry', 'SERVER',
    'is_supplier_source', (v_src = ANY(v_supplier)));

  v_dedup := coalesce(p_dedup_key, 'problem:'||p_cluster_id::text||':'||v_st||':'||v_src||':'||md5(coalesce(p_query,'')||'|'||coalesce(p_context,'')));

  v_counted := (v_scope = 'SELECTED_MARKET' AND NOT p_hypothesis AND NOT (v_src = ANY(v_supplier)));

  INSERT INTO public.commerce_signals(user_id, product_id, problem_cluster_id, signal_type, value, evidence,
                                      provenance, confidence, observed_at, source_event_at, dedup_key, visibility)
  VALUES (v_c.tenant_id, NULL, p_cluster_id, v_st,
          jsonb_build_object('market', v_mkt, 'query', p_query, 'context', p_context, 'signal_type', v_st,
                             'market_scope', v_scope),
          v_ev, v_prov,
          CASE WHEN p_confidence IS NULL THEN NULL WHEN p_confidence < 0 THEN 0 WHEN p_confidence > 1 THEN 1 ELSE p_confidence END,
          coalesce(p_observed_at, now()), p_source_event_at, v_dedup, 'TENANT_PRIVATE')
  ON CONFLICT (user_id, dedup_key) DO NOTHING
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('status','ok','signal_id',v_id,'inserted',(v_id IS NOT NULL),
    'market_scope',v_scope,'counts_toward_corroboration',v_counted,'dedup_key',v_dedup);
END; $function$;

-- ------------------------------------------------------------------------------
-- 7) product-match LINKAGE only (matcher NOT implemented). Requires a real canonical
--    commerce_products id; supplier rows cannot be linked here, so supplier presence
--    alone can never establish PRODUCT_MATCHED.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_cluster_link_product(p_cluster_id uuid, p_product_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_c public.commerce_problem_clusters%rowtype; v_exists boolean;
BEGIN
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF v_uid IS NOT NULL AND v_c.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;
  SELECT EXISTS(SELECT 1 FROM public.commerce_products WHERE id = p_product_id) INTO v_exists;
  IF NOT v_exists THEN RETURN jsonb_build_object('status','product_not_found','note','matched_product_id must reference a canonical commerce_products row'); END IF;
  UPDATE public.commerce_problem_clusters SET matched_product_id = p_product_id WHERE id = p_cluster_id;
  RETURN jsonb_build_object('status','ok','cluster_id',p_cluster_id,'matched_product_id',p_product_id);
END; $function$;

-- ------------------------------------------------------------------------------
-- 8) deterministic single-step promotion with per-target evidence gates.
--    Each target advances exactly one rank and must satisfy its observable gate.
--    LLM/hypothesis metadata can never satisfy a gate.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_cluster_promote(p_cluster_id uuid, p_target_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_c public.commerce_problem_clusters%rowtype;
  v_cur int; v_tgt int; v_corr jsonb; v_reason text; v_ok boolean := false;
BEGIN
  SELECT * INTO v_c FROM public.commerce_problem_clusters WHERE id = p_cluster_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','not_found'); END IF;
  IF v_uid IS NOT NULL AND v_c.tenant_id <> v_uid THEN RETURN jsonb_build_object('status','forbidden'); END IF;

  v_cur := public.fn_problem_status_rank(v_c.status);
  v_tgt := public.fn_problem_status_rank(p_target_status);
  IF v_tgt = 0 THEN RETURN jsonb_build_object('status','invalid_target'); END IF;
  IF v_tgt <> v_cur + 1 THEN
    RETURN jsonb_build_object('status','rejected','reason','must_advance_exactly_one_step',
      'from',v_c.status,'to',p_target_status);
  END IF;

  v_corr := public.fn_problem_corroboration_state(p_cluster_id);

  IF p_target_status = 'PROBLEM_CORROBORATED' THEN
    v_ok := (v_corr->>'corroboration_state') = 'MULTI_SOURCE_CORROBORATED';
    v_reason := 'requires MULTI_SOURCE_CORROBORATED';
  ELSIF p_target_status = 'SOLUTION_CANDIDATE' THEN
    v_ok := true; v_reason := 'hypothesis stage (allowed once corroborated)';
  ELSIF p_target_status = 'PRODUCT_MATCHED' THEN
    v_ok := (v_c.matched_product_id IS NOT NULL);
    v_reason := 'requires matched_product_id (canonical product); supplier presence alone is insufficient';
  ELSIF p_target_status = 'MARKET_ASSESSED' THEN
    v_ok := (v_c.matched_product_id IS NOT NULL) AND EXISTS(
      SELECT 1 FROM public.product_market_evaluations e
      WHERE e.product_id = v_c.matched_product_id AND e.country_code = v_c.market AND coalesce(e.is_fixture,false)=false);
    v_reason := 'requires a non-fixture PME for the matched product in this market';
  ELSIF p_target_status = 'PRODUCT_DECISION_READY' THEN
    v_ok := (v_c.matched_product_id IS NOT NULL) AND EXISTS(
      SELECT 1 FROM public.product_opportunity_decisions d
      WHERE d.product_id = v_c.matched_product_id AND d.country_code = v_c.market AND coalesce(d.is_fixture,false)=false);
    v_reason := 'requires a Product Decision for the matched product in this market';
  END IF;

  IF NOT v_ok THEN
    RETURN jsonb_build_object('status','rejected','reason',v_reason,'from',v_c.status,'to',p_target_status,
      'corroboration',v_corr);
  END IF;

  UPDATE public.commerce_problem_clusters SET status = p_target_status WHERE id = p_cluster_id;
  RETURN jsonb_build_object('status','ok','from',v_c.status,'to',p_target_status,'corroboration',v_corr);
END; $function$;

-- ------------------------------------------------------------------------------
-- 9) browser read of own clusters (with deterministic corroboration + evidence summary)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_clusters_read()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  SELECT coalesce(jsonb_agg(row ORDER BY (row->>'created_at') DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'cluster_id', c.id, 'market', c.market, 'category', c.category,
      'canonical_problem', c.canonical_problem, 'problem_summary', c.problem_summary,
      'status', c.status, 'matched_product_id', c.matched_product_id,
      'matched_product_title', (SELECT title FROM public.commerce_products p WHERE p.id = c.matched_product_id),
      'corroboration', public.fn_problem_corroboration_state(c.id),
      'evidence_summary', (
        SELECT jsonb_build_object(
          'total_problem_signals', count(*),
          'selected_market', count(*) FILTER (WHERE s.provenance->>'market_scope'='SELECTED_MARKET'),
          'contextual_cross_market', count(*) FILTER (WHERE s.provenance->>'market_scope'='CONTEXTUAL_CROSS_MARKET'),
          'by_source', coalesce((
            SELECT jsonb_object_agg(src, cnt) FROM (
              SELECT upper(s2.provenance->>'source') AS src, count(*) AS cnt
              FROM public.commerce_signals s2 WHERE s2.problem_cluster_id = c.id
              GROUP BY upper(s2.provenance->>'source')
            ) bs), '{}'::jsonb))
        FROM public.commerce_signals s WHERE s.problem_cluster_id = c.id
      ),
      'created_at', c.created_at, 'updated_at', c.updated_at
    ) AS row
    FROM public.commerce_problem_clusters c
    WHERE c.tenant_id = v_uid
  ) z;
  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'clusters', v_rows,
    'market_presence_contract','presence is expressed as LOW OBSERVED MARKET PRESENCE with coverage/freshness/source-attempt evidence; never as a product not being sold in a market');
END; $function$;

-- grants
REVOKE ALL ON FUNCTION public.fn_problem_status_rank(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_problem_status_rank(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_problem_corroboration_state(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_problem_corroboration_state(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_problem_cluster_upsert(text,text,text,text,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_problem_cluster_upsert(text,text,text,text,uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_problem_clusters_read() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_problem_clusters_read() TO authenticated, service_role;
-- server-side only (executors): evidence write, product linkage, state promotion
REVOKE ALL ON FUNCTION public.fn_problem_signal_attach(uuid,text,text,text,text,text,jsonb,timestamptz,timestamptz,text,boolean,numeric) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_problem_signal_attach(uuid,text,text,text,text,text,jsonb,timestamptz,timestamptz,text,boolean,numeric) TO service_role;
REVOKE ALL ON FUNCTION public.fn_problem_cluster_link_product(uuid,uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_problem_cluster_link_product(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.fn_problem_cluster_promote(uuid,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_problem_cluster_promote(uuid,text) TO service_role;

-- ------------------------------------------------------------------------------
-- 10) deterministic selftest (fixtures only; no external calls; self-cleaning)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_problem_foundation_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  tA uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';           -- tenant A (founder)
  tB uuid := '3d0eb793-685a-4ec2-aea7-8b95fda7112a';           -- tenant B (distinct)
  prod uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';         -- canonical product for linkage
  cA uuid; cB uuid; cD uuid; cG uuid; cH uuid; cI uuid;
  r jsonb; st text; v_pol text; v_upsert jsonb;
BEGIN
  -- clean any prior selftest residue
  DELETE FROM public.commerce_signals WHERE dedup_key LIKE 'problemtest:%';
  DELETE FROM public.commerce_problem_clusters WHERE canonical_problem LIKE '[[selftest]]%';

  -- fixtures (direct inserts; the definer bypasses RLS for setup)
  INSERT INTO public.commerce_problem_clusters(tenant_id,market,category,canonical_problem)
    VALUES (tA,'GB','sleep','[[selftest]] alpha') RETURNING id INTO cA;
  INSERT INTO public.commerce_problem_clusters(tenant_id,market,category,canonical_problem)
    VALUES (tB,'GB','sleep','[[selftest]] beta_other_tenant') RETURNING id INTO cB;
  INSERT INTO public.commerce_problem_clusters(tenant_id,market,category,canonical_problem)
    VALUES (tA,'DE','sleep','[[selftest]] delta_de') RETURNING id INTO cD;
  INSERT INTO public.commerce_problem_clusters(tenant_id,market,category,canonical_problem)
    VALUES (tA,'GB','supply','[[selftest]] gamma_supplier') RETURNING id INTO cG;
  INSERT INTO public.commerce_problem_clusters(tenant_id,market,category,canonical_problem)
    VALUES (tA,'GB','hypo','[[selftest]] eta_hypothesis') RETURNING id INTO cH;
  INSERT INTO public.commerce_problem_clusters(tenant_id,market,category,canonical_problem)
    VALUES (tA,'GB','match','[[selftest]] iota_match') RETURNING id INTO cI;

  -- A. one signal cannot be multi-source
  PERFORM public.fn_problem_signal_attach(cA,'SEARCH_PROBLEM_DEMAND','DATAFORSEO','GB','how to sleep better',NULL,NULL,now(),NULL,'problemtest:cA:1',false,NULL);
  st := public.fn_problem_corroboration_state(cA)->>'corroboration_state';
  v := v || jsonb_build_object('case','A_one_signal_not_multisource','pass', st='SINGLE_SOURCE','got',st);

  -- B. many from one provider stay single-source
  PERFORM public.fn_problem_signal_attach(cA,'SEARCH_PROBLEM_DEMAND','DATAFORSEO','GB','best way to fall asleep',NULL,NULL,now(),NULL,'problemtest:cA:2',false,NULL);
  PERFORM public.fn_problem_signal_attach(cA,'SEARCH_PROBLEM_DEMAND','DATAFORSEO','GB','cant sleep at night',NULL,NULL,now(),NULL,'problemtest:cA:3',false,NULL);
  st := public.fn_problem_corroboration_state(cA)->>'corroboration_state';
  v := v || jsonb_build_object('case','B_multi_evidence_single_source','pass', st='MULTI_EVIDENCE_SINGLE_SOURCE','got',st);

  -- C. independent providers corroborate
  PERFORM public.fn_problem_signal_attach(cA,'COMMUNITY_PAIN','REDDIT','GB',NULL,'cannot fall asleep, tried everything',NULL,now(),NULL,'problemtest:cA:4',false,NULL);
  st := public.fn_problem_corroboration_state(cA)->>'corroboration_state';
  v := v || jsonb_build_object('case','C_multi_source_corroborated','pass', st='MULTI_SOURCE_CORROBORATED','got',st);

  -- D. GB evidence does not corroborate a DE-selected cluster
  PERFORM public.fn_problem_signal_attach(cD,'SEARCH_PROBLEM_DEMAND','DATAFORSEO','GB','how to sleep better',NULL,NULL,now(),NULL,'problemtest:cD:ctx',false,NULL); -- cross-market context
  PERFORM public.fn_problem_signal_attach(cD,'COMMUNITY_PAIN','REDDIT','DE',NULL,'kann nicht schlafen',NULL,now(),NULL,'problemtest:cD:de1',false,NULL);           -- 1 selected-market
  r := public.fn_problem_corroboration_state(cD);
  v := v || jsonb_build_object('case','D_gb_not_de_corroboration',
        'pass', (r->>'corroboration_state'='SINGLE_SOURCE' AND (r->>'contextual_cross_market_signals')::int=1),
        'got', r->'corroboration_state','ctx',r->'contextual_cross_market_signals');

  -- E. problem evidence exists with product_id NULL
  v := v || jsonb_build_object('case','E_evidence_product_id_null','pass',
        EXISTS(SELECT 1 FROM public.commerce_signals s WHERE s.problem_cluster_id=cA AND s.product_id IS NULL)
        AND NOT EXISTS(SELECT 1 FROM public.commerce_signals s WHERE s.problem_cluster_id=cA AND s.product_id IS NOT NULL));

  -- F. RLS select policy isolates tenants (deterministic predicate assertion)
  SELECT qual INTO v_pol FROM pg_policies
    WHERE schemaname='public' AND tablename='commerce_problem_clusters' AND policyname='commerce_problem_clusters_select_own';
  v := v || jsonb_build_object('case','F_rls_tenant_isolation',
        'pass', (v_pol ILIKE '%auth.uid()%' AND v_pol ILIKE '%tenant_id%')
                AND NOT EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public'
                     AND tablename='commerce_problem_clusters' AND 'anon'=ANY(roles)),
        'select_policy', v_pol);

  -- G. supplier-sourced evidence cannot establish corroboration/demand
  PERFORM public.fn_problem_signal_attach(cG,'SEARCH_PROBLEM_DEMAND','CJ','GB','supplier offers sleep mask',NULL,NULL,now(),NULL,'problemtest:cG:1',false,NULL);
  PERFORM public.fn_problem_signal_attach(cG,'SEARCH_PROBLEM_DEMAND','CJ','GB','supplier catalog sleep aid',NULL,NULL,now(),NULL,'problemtest:cG:2',false,NULL);
  r := public.fn_problem_corroboration_state(cG);
  st := (public.fn_problem_cluster_promote(cG,'PROBLEM_CORROBORATED'))->>'status';
  v := v || jsonb_build_object('case','G_supplier_only_no_demand',
        'pass', (r->>'corroboration_state'='INSUFFICIENT_EVIDENCE' AND st='rejected'),'got',r->'corroboration_state','promote',st);

  -- H. LLM/hypothesis-only evidence cannot corroborate or promote
  PERFORM public.fn_problem_signal_attach(cH,'COMMUNITY_UNMET_NEED','REDDIT','GB',NULL,'AI-proposed unmet need',NULL,now(),NULL,'problemtest:cH:1',true,NULL);
  PERFORM public.fn_problem_signal_attach(cH,'SEARCH_PROBLEM_DEMAND','DATAFORSEO','GB','AI-proposed query',NULL,NULL,now(),NULL,'problemtest:cH:2',true,NULL);
  r := public.fn_problem_corroboration_state(cH);
  st := (public.fn_problem_cluster_promote(cH,'PROBLEM_CORROBORATED'))->>'status';
  v := v || jsonb_build_object('case','H_hypothesis_only_no_promote',
        'pass', (r->>'corroboration_state'='INSUFFICIENT_EVIDENCE' AND st='rejected'),'got',r->'corroboration_state','promote',st);

  -- I. PRODUCT_MATCHED requires canonical product linkage
  PERFORM public.fn_problem_signal_attach(cI,'SEARCH_PROBLEM_DEMAND','DATAFORSEO','GB','sleep problem q',NULL,NULL,now(),NULL,'problemtest:cI:1',false,NULL);
  PERFORM public.fn_problem_signal_attach(cI,'COMMUNITY_PAIN','REDDIT','GB',NULL,'real pain statement',NULL,now(),NULL,'problemtest:cI:2',false,NULL);
  PERFORM public.fn_problem_cluster_promote(cI,'PROBLEM_CORROBORATED');
  PERFORM public.fn_problem_cluster_promote(cI,'SOLUTION_CANDIDATE');
  st := (public.fn_problem_cluster_promote(cI,'PRODUCT_MATCHED'))->>'status';      -- no link yet -> rejected
  PERFORM public.fn_problem_cluster_link_product(cI, prod);
  r := public.fn_problem_cluster_promote(cI,'PRODUCT_MATCHED');                    -- linked -> ok
  v := v || jsonb_build_object('case','I_product_matched_requires_link',
        'pass', (st='rejected' AND r->>'status'='ok'),'no_link',st,'with_link',r->'status');

  -- J. existing product-first pipeline unchanged (protected fns present; new column additive/nullable)
  v := v || jsonb_build_object('case','J_product_first_unchanged','pass',
        (to_regprocedure('public.fn_research_ingest_source(uuid,text,jsonb)') IS NOT NULL
         AND to_regprocedure('public.fn_evaluate_product_market(uuid,uuid,text,text,jsonb,jsonb,jsonb,boolean,boolean)') IS NOT NULL
         AND to_regprocedure('public.fn_pod_evaluate(uuid,uuid,text,text,boolean)') IS NOT NULL
         AND EXISTS(SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='commerce_signals'
                      AND column_name='problem_cluster_id' AND is_nullable='YES' AND column_default IS NULL)));

  -- cleanup
  DELETE FROM public.commerce_signals WHERE dedup_key LIKE 'problemtest:%';
  DELETE FROM public.commerce_problem_clusters WHERE canonical_problem LIKE '[[selftest]]%';

  RETURN jsonb_build_object('suite','problem_intelligence_foundation',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_problem_foundation_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_problem_foundation_selftest() TO service_role;

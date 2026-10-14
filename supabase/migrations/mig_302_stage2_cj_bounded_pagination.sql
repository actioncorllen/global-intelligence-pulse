-- mig_302_stage2_cj_bounded_pagination.sql
-- STRATELOQ — Stage-2 CJ bounded pagination (deterministic DB contract; the n8n workflow drives the loop).
--
-- Problem: CJ supplier retrieval (n8n `stage2-cj-supplier-search`, node "CJ Search") fetched a single page
-- (pageNum=1, pageSize=20) per query, so an existing exact product ranked beyond the top-20 was missed.
--
-- Fix (deterministic, testable, no live CJ, no new paid service): the pagination POLICY and the
-- candidate AGGREGATION live in the DB so they are provable with mocked pages; the orchestrator (n8n)
-- performs the bounded HTTP loop and feeds page responses back in.
--  - fn_stage2_cj_budget(): request budget (page_size, max_pages_per_query, max_candidates, max_api_calls).
--  - fn_stage2_cj_should_continue(page, page_num, collected, budget): per-page stop decision — stop on
--    error/rate-limit/malformed page, on a partial (last) page, at max_pages_per_query, or at the
--    candidate budget; otherwise continue.
--  - fn_stage2_cj_finalize_candidates(pages, budget): flatten all collected pages, DEDUPLICATE by CJ
--    product id (pid, first occurrence wins), cap at max_candidates (flag truncation), skip/record error
--    pages (rate-limit / provider / client / malformed) without aborting, and emit the candidate list in
--    the exact shape fn_resolve_concrete_supplier_identity consumes, plus retrieval stats.
--  - fn_stage2_cj_retrieval_plan(tenant, product, market): queries (canonical expansion, mig_300/301) + budget.
--  - fn_stage2_resolve_from_pages(tenant, product, market, pages, persist): finalize -> resolve, one call.
--
-- Preserved: canonical query expansion (mig_300) and multilingual recognition (mig_301); exact-product
-- matching strictness and form-conflict (fn_market_supplier_match unchanged); tenant isolation (ownership
-- re-checked in fn_resolve_concrete_supplier_identity / fn_stage2_supplier_search_queries); country
-- isolation; Product Asset Lock. No live CJ/Apify calls. pageSize stays 20 (CJ default); only DEPTH is added.

-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_stage2_cj_budget()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path TO '' AS $function$
  SELECT jsonb_build_object(
    'page_size', 20,
    'max_pages_per_query', 5,
    'max_candidates', 200,
    'max_api_calls', 40,
    'contract','pulse_stage2_cj_budget_v1');
$function$;
REVOKE ALL ON FUNCTION public.fn_stage2_cj_budget() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_cj_budget() TO service_role, authenticated;

-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_stage2_cj_should_continue(p_page jsonb, p_page_num int, p_collected int, p_budget jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $function$
DECLARE
  v_b jsonb := coalesce(p_budget, public.fn_stage2_cj_budget());
  v_ps  int := coalesce((v_b->>'page_size')::int, 20);
  v_mpp int := coalesce((v_b->>'max_pages_per_query')::int, 5);
  v_mc  int := coalesce((v_b->>'max_candidates')::int, 200);
  v_http int := coalesce((p_page->>'http_status')::int, 0);
  v_list jsonb := p_page->'body'->'data'->'list';
  v_is_arr boolean := coalesce(jsonb_typeof(v_list) = 'array', false);
  v_rows int := CASE WHEN v_is_arr THEN jsonb_array_length(v_list) ELSE 0 END;
  v_rate boolean := (v_http = 429);
  v_err  boolean := (v_http >= 400) OR (NOT v_is_arr);
  v_cont boolean; v_reason text;
BEGIN
  IF v_err THEN
    v_cont := false; v_reason := CASE WHEN v_rate THEN 'rate_limited_stop_query'
      WHEN v_http >= 500 THEN 'provider_error_stop_query'
      WHEN v_http >= 400 THEN 'client_error_stop_query' ELSE 'malformed_page_stop_query' END;
  ELSIF coalesce(p_collected,0) >= v_mc THEN v_cont := false; v_reason := 'candidate_budget_reached';
  ELSIF coalesce(p_page_num,1) >= v_mpp THEN v_cont := false; v_reason := 'max_pages_per_query_reached';
  ELSIF v_rows < v_ps THEN v_cont := false; v_reason := 'last_page_partial';
  ELSE v_cont := true; v_reason := 'continue';
  END IF;
  RETURN jsonb_build_object('continue',v_cont,'reason',v_reason,'is_error',v_err,
    'rate_limited',v_rate,'rows',v_rows,'http_status',v_http);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage2_cj_should_continue(jsonb,int,int,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_cj_should_continue(jsonb,int,int,jsonb) TO service_role, authenticated;

-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_stage2_cj_finalize_candidates(p_pages jsonb, p_budget jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path TO '' AS $function$
DECLARE
  v_b jsonb := coalesce(p_budget, public.fn_stage2_cj_budget());
  v_mc int := coalesce((v_b->>'max_candidates')::int, 200);
  v_cands jsonb := '[]'::jsonb; v_seen text[] := ARRAY[]::text[];
  v_pages_total int := 0; v_pages_ok int := 0; v_pages_error int := 0;
  v_rows_seen int := 0; v_dups int := 0; v_truncated boolean := false;
  v_errors jsonb := '[]'::jsonb;
  v_pg jsonb; v_row jsonb; v_pid text; v_http int; v_list jsonb; v_sku text;
BEGIN
  IF p_pages IS NULL OR jsonb_typeof(p_pages) <> 'array' THEN
    RETURN jsonb_build_object('ok',false,'reason','pages_must_be_array'); END IF;

  FOR v_pg IN SELECT * FROM jsonb_array_elements(p_pages) LOOP
    v_pages_total := v_pages_total + 1;
    v_http := coalesce((v_pg->>'http_status')::int, 0);
    v_list := v_pg->'body'->'data'->'list';
    IF v_http >= 400 OR coalesce(jsonb_typeof(v_list),'') <> 'array' THEN
      v_pages_error := v_pages_error + 1;
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'query', v_pg->>'query', 'page_num', v_pg->>'page_num', 'http_status', v_http,
        'kind', CASE WHEN v_http=429 THEN 'RATE_LIMITED' WHEN v_http>=500 THEN 'PROVIDER_ERROR'
                     WHEN v_http>=400 THEN 'CLIENT_ERROR' ELSE 'MALFORMED' END));
      CONTINUE;
    END IF;
    v_pages_ok := v_pages_ok + 1;
    FOR v_row IN SELECT * FROM jsonb_array_elements(v_list) LOOP
      v_rows_seen := v_rows_seen + 1;
      v_pid := nullif(btrim(coalesce(v_row->>'pid','')),'');
      IF v_pid IS NULL THEN CONTINUE; END IF;
      IF v_pid = ANY(v_seen) THEN v_dups := v_dups + 1; CONTINUE; END IF;
      IF cardinality(v_seen) >= v_mc THEN v_truncated := true; EXIT; END IF;
      v_sku := nullif(btrim(coalesce(v_row->>'productSku','')),'');
      v_seen := v_seen || v_pid;
      v_cands := v_cands || jsonb_build_array(jsonb_build_object(
        'supplier','CJDROPSHIPPING','supplier_product_id',v_pid,'sku',v_sku,
        'title', v_row->>'productNameEn','category', v_row->>'categoryName','variant',null,
        'supplier_reference', coalesce(v_sku, v_pid)));
    END LOOP;
    IF v_truncated THEN EXIT; END IF;
  END LOOP;

  RETURN jsonb_build_object('ok',true,'candidates',v_cands,
    'stats', jsonb_build_object('pages_total',v_pages_total,'pages_ok',v_pages_ok,'pages_error',v_pages_error,
      'rows_seen',v_rows_seen,'duplicates_removed',v_dups,'candidate_count',jsonb_array_length(v_cands),
      'truncated',v_truncated,'max_candidates',v_mc,'errors',v_errors),
    'contract','pulse_stage2_cj_finalize_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage2_cj_finalize_candidates(jsonb,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_cj_finalize_candidates(jsonb,jsonb) TO service_role;

-- ---------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_stage2_cj_retrieval_plan(p_tenant uuid, p_product_id uuid, p_market text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_q jsonb;
BEGIN
  v_q := public.fn_stage2_supplier_search_queries(p_tenant, p_product_id, p_market);
  IF coalesce(v_q->>'ok','false') <> 'true' THEN RETURN v_q; END IF;
  RETURN v_q || jsonb_build_object('budget', public.fn_stage2_cj_budget(),
    'retrieval_contract','pulse_stage2_cj_retrieval_plan_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage2_cj_retrieval_plan(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_cj_retrieval_plan(uuid,uuid,text) TO service_role;

-- ---------------------------------------------------------------------------------------------------
-- One-call integration: finalize collected pages -> resolve. Tenant isolation inherited from the resolver.
CREATE OR REPLACE FUNCTION public.fn_stage2_resolve_from_pages(p_tenant uuid, p_product_id uuid, p_market text, p_pages jsonb, p_persist boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_fin jsonb; v_res jsonb;
BEGIN
  v_fin := public.fn_stage2_cj_finalize_candidates(p_pages, public.fn_stage2_cj_budget());
  IF coalesce(v_fin->>'ok','false') <> 'true' THEN RETURN v_fin; END IF;
  v_res := public.fn_resolve_concrete_supplier_identity(p_tenant, p_product_id, p_market, v_fin->'candidates', p_persist);
  RETURN v_res || jsonb_build_object('retrieval_stats', v_fin->'stats');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage2_resolve_from_pages(uuid,uuid,text,jsonb,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_resolve_from_pages(uuid,uuid,text,jsonb,boolean) TO service_role;

-- ---------------------------------------------------------------------------------------------------
-- Deterministic self-test (service_role only; mocked CJ pages; no provider calls, no writes).
CREATE OR REPLACE FUNCTION public.fn_stage2_cj_pagination_selftest()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  pass int := 0; fail int := 0; results jsonb := '[]'::jsonb;
  tb jsonb := jsonb_build_object('page_size',3,'max_pages_per_query',3,'max_candidates',200);
  pageA jsonb; pageB jsonb; pageC jsonb; pageRate jsonb; pageFail jsonb; pageEmpty jsonb; pageNoPid jsonb;
  fin jsonb; sc jsonb; pids text[];
  function_row jsonb;
BEGIN
  pageA := jsonb_build_object('query','nativity scene','page_num',1,'http_status',200,'body',
    jsonb_build_object('code',200,'data',jsonb_build_object('total',6,'list',jsonb_build_array(
      jsonb_build_object('pid','p1','productNameEn','LED Lighted Nativity Scene Wall Decoration 1','productSku','S1','categoryName','Home Decor'),
      jsonb_build_object('pid','p2','productNameEn','LED Lighted Nativity Scene Wall Decoration 2','productSku','S2','categoryName','Home Decor'),
      jsonb_build_object('pid','p3','productNameEn','LED Lighted Nativity Scene Wall Decoration 3','productSku','S3','categoryName','Home Decor')))));
  pageB := jsonb_build_object('query','nativity scene','page_num',2,'http_status',200,'body',
    jsonb_build_object('code',200,'data',jsonb_build_object('total',6,'list',jsonb_build_array(
      jsonb_build_object('pid','p3','productNameEn','LED Lighted Nativity Scene Wall Decoration 3 (dup)','productSku','S3','categoryName','Home Decor'),
      jsonb_build_object('pid','p4','productNameEn','LED Lighted Nativity Scene Wall Decoration 4','productSku','S4','categoryName','Home Decor'),
      jsonb_build_object('pid','p5','productNameEn','LED Lighted Nativity Scene Wall Decoration 5','productSku','S5','categoryName','Home Decor')))));
  pageC := jsonb_build_object('query','nativity scene','page_num',3,'http_status',200,'body',
    jsonb_build_object('code',200,'data',jsonb_build_object('total',6,'list',jsonb_build_array(
      jsonb_build_object('pid','p6','productNameEn','LED Lighted Nativity Scene Wall Decoration 6','productSku','S6','categoryName','Home Decor')))));
  pageRate := jsonb_build_object('query','creche','page_num',1,'http_status',429,'body',
    jsonb_build_object('code',429,'message','Too Many Requests'));
  pageFail := jsonb_build_object('query','manger scene','page_num',1,'http_status',500,'body',
    jsonb_build_object('code',500,'message','Internal Error'));
  pageEmpty := jsonb_build_object('query','nativity set','page_num',1,'http_status',200,'body',
    jsonb_build_object('code',200,'data',jsonb_build_object('total',0,'list',jsonb_build_array())));
  pageNoPid := jsonb_build_object('query','nativity scene','page_num',1,'http_status',200,'body',
    jsonb_build_object('code',200,'data',jsonb_build_object('total',1,'list',jsonb_build_array(
      jsonb_build_object('productNameEn','No PID row','productSku','SX','categoryName','Home Decor')))));

  -- 1: full page -> continue
  sc := public.fn_stage2_cj_should_continue(pageA, 1, 3, tb);
  IF (sc->>'continue')::boolean AND sc->>'reason'='continue'
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','1_full_page_continue','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','1_full_page_continue','pass',false,'got',sc); END IF;

  -- 2: partial (last) page -> stop
  sc := public.fn_stage2_cj_should_continue(pageC, 3, 5, tb);
  IF NOT (sc->>'continue')::boolean AND sc->>'reason' IN ('last_page_partial','max_pages_per_query_reached') AND NOT (sc->>'is_error')::boolean
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','2_partial_last_page_stop','pass',true,'reason',sc->>'reason');
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','2_partial_last_page_stop','pass',false,'got',sc); END IF;

  -- 3: rate limit -> stop + is_error + rate_limited
  sc := public.fn_stage2_cj_should_continue(pageRate, 1, 0, tb);
  IF NOT (sc->>'continue')::boolean AND (sc->>'is_error')::boolean AND (sc->>'rate_limited')::boolean
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','3_rate_limit_stop','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','3_rate_limit_stop','pass',false,'got',sc); END IF;

  -- 4: provider failure -> stop + is_error
  sc := public.fn_stage2_cj_should_continue(pageFail, 1, 0, tb);
  IF NOT (sc->>'continue')::boolean AND (sc->>'is_error')::boolean AND NOT (sc->>'rate_limited')::boolean
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','4_provider_fail_stop','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','4_provider_fail_stop','pass',false,'got',sc); END IF;

  -- 5: empty page -> stop, not an error
  sc := public.fn_stage2_cj_should_continue(pageEmpty, 1, 0, tb);
  IF NOT (sc->>'continue')::boolean AND NOT (sc->>'is_error')::boolean AND sc->>'reason'='last_page_partial'
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','5_empty_page_stop','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','5_empty_page_stop','pass',false,'got',sc); END IF;

  -- 6: request limit -> stop at max_pages_per_query
  sc := public.fn_stage2_cj_should_continue(pageA, 3, 3, tb);
  IF NOT (sc->>'continue')::boolean AND sc->>'reason'='max_pages_per_query_reached'
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','6_max_pages_stop','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','6_max_pages_stop','pass',false,'got',sc); END IF;

  -- 7: finalize — matches beyond page 1, dedup by pid, errors recorded, no abort
  fin := public.fn_stage2_cj_finalize_candidates(
    jsonb_build_array(pageA,pageB,pageC,pageRate,pageFail,pageEmpty,pageNoPid), tb);
  pids := ARRAY(SELECT e->>'supplier_product_id' FROM jsonb_array_elements(fin->'candidates') e);
  IF (fin->'stats'->>'candidate_count')::int = 6
     AND (fin->'stats'->>'duplicates_removed')::int >= 1
     AND (fin->'stats'->>'pages_error')::int = 2
     AND (fin->'stats'->>'truncated')::boolean = false
     AND 'p4' = ANY(pids) AND 'p6' = ANY(pids)
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','7_finalize_dedup_errors','pass',true,'stats',fin->'stats');
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','7_finalize_dedup_errors','pass',false,'got',fin); END IF;

  -- 8: request limit (max_candidates) -> truncation flagged
  fin := public.fn_stage2_cj_finalize_candidates(jsonb_build_array(pageA), jsonb_build_object('max_candidates',2,'page_size',3));
  IF (fin->'stats'->>'candidate_count')::int = 2 AND (fin->'stats'->>'truncated')::boolean = true
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','8_candidate_cap_truncation','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','8_candidate_cap_truncation','pass',false,'got',fin); END IF;

  -- 9: finalized candidate shape is resolver-compatible (has supplier_product_id + title)
  fin := public.fn_stage2_cj_finalize_candidates(jsonb_build_array(pageA), tb);
  function_row := fin->'candidates'->0;
  IF function_row ? 'supplier_product_id' AND function_row ? 'title' AND function_row->>'supplier'='CJDROPSHIPPING'
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','9_candidate_shape','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','9_candidate_shape','pass',false,'got',function_row); END IF;

  -- 10: malformed page (no data.list) treated as error, not a crash
  sc := public.fn_stage2_cj_should_continue(jsonb_build_object('query','x','page_num',1,'http_status',200,'body',jsonb_build_object('code',200)), 1, 0, tb);
  IF NOT (sc->>'continue')::boolean AND (sc->>'is_error')::boolean AND sc->>'reason'='malformed_page_stop_query'
     THEN pass:=pass+1; results:=results||jsonb_build_object('check','10_malformed_page','pass',true);
     ELSE fail:=fail+1; results:=results||jsonb_build_object('check','10_malformed_page','pass',false,'got',sc); END IF;

  RETURN jsonb_build_object('suite','fn_stage2_cj_pagination_selftest','pass',pass,'fail',fail,'ok',(fail=0),'results',results);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage2_cj_pagination_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage2_cj_pagination_selftest() TO service_role;

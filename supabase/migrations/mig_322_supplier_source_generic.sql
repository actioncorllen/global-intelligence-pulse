-- mig_322_supplier_source_generic.sql
-- Stage 4B (continuation): make the exact-identity supplier resolver source-generic and prepare
-- the AliExpress secondary source behind a DISABLED provider gate. No AliExpress activation, no live
-- wiring, no invented API response contracts, no scraping, no paid calls.
--
-- What this migration does (all approval-free, CJ behaviour byte-identical):
--   1. fn_resolve_concrete_supplier_identity — remove the 3 hardcoded 'CJDROPSHIPPING' supplier
--      labels; each is now derived from the matched candidate's own source
--      (upper(source) on self-built CJ candidates; upper(coalesce(v_sel->>'supplier','CJDROPSHIPPING'))
--      on the persisted + provenance labels). The only stored source is 'cjdropshipping', so
--      upper(source)='CJDROPSHIPPING' — zero drift for existing CJ bindings. The CJ-stage result
--      token NO_VALID_CJ_MATCH, the 'cj_product_id' provenance key, the claim text and the ON CONFLICT
--      clause are intentionally UNCHANGED (stable contracts / asserted by selftests; the CJ-worded
--      claim + key remain an authorised-phase provenance refinement, harmless while AliExpress is gated).
--   2. commerce_supplier_provider_config + fn_supplier_provider_enabled — a disabled provider gate.
--      CJDROPSHIPPING enabled/AVAILABLE; ALIEXPRESS disabled/EXTERNAL_APPROVAL_REQUIRED.
--   3. fn_supplier_candidates_from_canonical — a source-generic adapter from OUR canonical supplier
--      DTO (fields we define) to the resolver's candidate shape. It does NOT encode any AliExpress API
--      response schema (that raw->canonical mapping is an authorised-phase step once the real API shape
--      is known). Absent fields are stripped, never fabricated.
--   4. fn_resolve_supplier_identity_multi — a CJ-first -> AliExpress fallback helper, GATED OFF and NOT
--      wired into fn_finalize_research_run. While ALIEXPRESS is disabled it never attempts AliExpress and
--      returns the CJ result verbatim (aliexpress_fallback='PROVIDER_DISABLED').
--   5. fn_supplier_sourcegeneric_selftest — mock dry-run (persist=false, synthetic candidates) covering
--      exact/incorrect variant matching, country/tenant isolation, missing shipping/rights (never
--      invented), the disabled gate, and failed/empty API responses.
--
-- Isolation, the never-approximate rule, Product Asset Lock and the DataForSEO USD budget guard
-- (mig_318/319, still DISABLED) are untouched.

-- =====================================================================================================
-- 1. SOURCE-GENERIC EXACT-IDENTITY RESOLVER (3 label literals only; everything else identical)
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_concrete_supplier_identity(p_tenant uuid, p_product_id uuid, p_market text, p_candidates jsonb DEFAULT NULL::jsonb, p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_der jsonb; v_spec jsonb; v_state text; cp record;
  c jsonb; m jsonb; cls text; attrs_ok boolean; excl_hit boolean; form_conflict boolean; v_shared boolean;
  v_considered jsonb := '[]'::jsonb; v_contra jsonb := '[]'::jsonb; v_qualify jsonb := '[]'::jsonb; v_idqualify jsonb := '[]'::jsonb;
  v_result text; v_sel jsonb; v_prov jsonb; v_qn int; v_qn_id int; v_basis text := 'ATTRIBUTE';
  v_sterms text[]; v_nouns_src text[]; v_linked text[];
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('ok',false,'error','tenant_required'); END IF;
  SELECT title, category, extended INTO cp FROM public.commerce_products WHERE id=p_product_id AND user_id=p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant'); END IF;

  v_linked := coalesce(ARRAY(
    SELECT DISTINCT sid FROM (
      SELECT cp.extended->'supplier_ref'->>'source_product_id' AS sid, lower(coalesce(cp.extended->'supplier_ref'->>'provider','')) AS prov
      UNION ALL SELECT cp.extended->>'cj_source_product_id', 'cj'
      UNION ALL SELECT e->>'source_product_id', lower(coalesce(e->>'provider',''))
                 FROM jsonb_array_elements(coalesce(cp.extended->'supplier_refs','[]'::jsonb)) e
    ) z WHERE sid IS NOT NULL AND sid <> '' AND prov LIKE 'cj%'
  ), '{}'::text[]);

  v_der := public.fn_derive_concrete_product_identity(p_tenant, p_product_id, p_market);
  IF coalesce(v_der->>'ok','false')<>'true' THEN RETURN v_der; END IF;
  v_spec := v_der->'match_spec';
  v_state := v_der->>'concrete_state';

  IF v_state = 'NO_CONCRETE_EVIDENCE' THEN
    v_result := 'NO_VALID_CJ_MATCH';
  ELSE
    IF p_candidates IS NULL THEN
      v_sterms := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(public.fn_supplier_search_terms(v_spec)->'queries','[]'::jsonb)) x);
      v_nouns_src := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(coalesce(v_spec->'product_noun','[]'::jsonb)) x);
      WITH termed AS (
        SELECT sp.source, sp.source_product_id, sp.sku, sp.title, sp.category, sp.supplier_enrichment->'variant' AS variant
        FROM public.commerce_supplier_products sp
        WHERE sp.source ILIKE 'cj%'
          AND ( EXISTS (SELECT 1 FROM unnest(v_sterms) t WHERE t<>'' AND position(t in lower(sp.title))>0)
             OR EXISTS (SELECT 1 FROM unnest(v_nouns_src) t WHERE t<>'' AND position(t in lower(sp.title))>0) )
        LIMIT 40
      ),
      linked AS (
        SELECT sp.source, sp.source_product_id, sp.sku, sp.title, sp.category, sp.supplier_enrichment->'variant' AS variant
        FROM public.commerce_supplier_products sp
        WHERE array_length(v_linked,1) > 0 AND sp.source_product_id = ANY(v_linked)
      ),
      allc AS (SELECT * FROM termed UNION SELECT * FROM linked)
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'supplier',upper(source),'supplier_product_id',source_product_id,'sku',sku,
               'title',title,'category',category,'variant',variant)),'[]'::jsonb)
        INTO p_candidates FROM allc;
    END IF;

    FOR c IN SELECT * FROM jsonb_array_elements(coalesce(p_candidates,'[]'::jsonb)) LOOP
      v_shared := (array_length(v_linked,1) > 0 AND lower(coalesce(c->>'supplier_product_id','')) = ANY (SELECT lower(u) FROM unnest(v_linked) u));
      m := public.fn_market_supplier_match(v_spec, c->>'title', c->>'category', c->>'supplier_product_id', v_shared);
      cls := m->>'market_supplier_match';
      attrs_ok := coalesce((m->'evidence'->>'attrs_ok')::boolean, false);
      excl_hit := coalesce((m->'evidence'->>'excluded_subtype_hit')::boolean, false);
      form_conflict := coalesce((m->'evidence'->>'form_conflict')::boolean, false);
      v_considered := v_considered || jsonb_build_array(jsonb_build_object(
        'supplier_product_id', c->>'supplier_product_id','title',c->>'title',
        'match_class', cls, 'attrs_ok', attrs_ok, 'excluded_subtype_hit', excl_hit,
        'shared_identifier', v_shared, 'evidence', m->'evidence'));
      IF excl_hit THEN
        v_contra := v_contra || jsonb_build_array(jsonb_build_object(
          'supplier_product_id', c->>'supplier_product_id','title',c->>'title','reason','EXCLUDED_SUBTYPE_PRESENT'));
      ELSE
        IF v_shared AND cls = 'EXACT_CONFIRMED' AND NOT form_conflict THEN
          v_idqualify := v_idqualify || jsonb_build_array(c || jsonb_build_object('match_class',cls,'match_evidence',m->'evidence'));
        END IF;
        IF cls IN ('STRONG_SAME_PRODUCT','EXACT_CONFIRMED') AND attrs_ok THEN
          v_qualify := v_qualify || jsonb_build_array(c || jsonb_build_object('match_class',cls,'match_evidence',m->'evidence'));
        END IF;
      END IF;
    END LOOP;

    v_qn_id := jsonb_array_length(v_idqualify);
    v_qn := jsonb_array_length(v_qualify);
    IF v_qn_id = 1 THEN
      v_result := 'EXACT_SUPPLIER_IDENTITY_RESOLVED'; v_sel := v_idqualify->0; v_basis := 'SHARED_PRODUCT_IDENTIFIER';
    ELSIF v_qn_id > 1 THEN
      v_result := 'CONCRETE_PRODUCT_AMBIGUOUS'; v_basis := 'SHARED_PRODUCT_IDENTIFIER';
    ELSE
      IF v_qn = 0 THEN v_result := 'NO_VALID_CJ_MATCH';
      ELSIF v_qn = 1 THEN v_result := 'EXACT_SUPPLIER_IDENTITY_RESOLVED'; v_sel := v_qualify->0;
      ELSE v_result := 'CONCRETE_PRODUCT_AMBIGUOUS'; END IF;
    END IF;
  END IF;

  v_prov := jsonb_build_object(
    'step1_opportunity_to_concrete', jsonb_build_object(
      'opportunity_concept', cp.title, 'market', upper(p_market),
      'concrete_state', v_state, 'concrete_identity', v_der->'concrete_identity',
      'claim','Market opportunity resolved to a concrete product from observed marketplace evidence.'),
    'step2_concrete_to_supplier', CASE WHEN v_sel IS NOT NULL THEN jsonb_build_object(
      'supplier', upper(coalesce(v_sel->>'supplier','CJDROPSHIPPING')),'cj_product_id', v_sel->>'supplier_product_id',
      'match_class', v_sel->>'match_class', 'match_basis', v_basis,
      'claim', CASE WHEN v_basis='SHARED_PRODUCT_IDENTIFIER'
                    THEN 'Concrete product is supplied by this CJ product (RECORDED shared supplier identifier; identifier precedence over attribute matches).'
                    ELSE 'Concrete product is supplied by this CJ product (attribute match, explicitly bound).' END) ELSE NULL END,
    'identity_separation_note','This is NOT a claim that the DataForSEO concept equals a CJ SKU; the concept was first resolved to a concrete product, then a CJ product was bound to supply that concrete product.');

  IF p_persist THEN
    INSERT INTO public.commerce_concrete_supplier_resolution AS t (
      tenant_id, opportunity_product_id, market, concrete_identity, concrete_state, match_spec,
      candidates_considered, selected_supplier, selected_supplier_product_id, selected_sku, selected_variant,
      supplier_match_evidence, contradictory_evidence, identity_result, provenance, bound, bound_at)
    VALUES (p_tenant, p_product_id, upper(p_market), v_der->'concrete_identity', v_state, v_spec,
      v_considered, CASE WHEN v_sel IS NOT NULL THEN upper(coalesce(v_sel->>'supplier','CJDROPSHIPPING')) END,
      v_sel->>'supplier_product_id', v_sel->>'sku', v_sel->'variant',
      v_sel->'match_evidence', v_contra, v_result, v_prov,
      (v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED'),
      CASE WHEN v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED' THEN now() END)
    ON CONFLICT (tenant_id, opportunity_product_id, market) DO UPDATE SET
      concrete_identity=excluded.concrete_identity, concrete_state=excluded.concrete_state,
      match_spec=excluded.match_spec, candidates_considered=excluded.candidates_considered,
      selected_supplier=excluded.selected_supplier, selected_supplier_product_id=excluded.selected_supplier_product_id,
      selected_sku=excluded.selected_sku, selected_variant=excluded.selected_variant,
      supplier_match_evidence=excluded.supplier_match_evidence, contradictory_evidence=excluded.contradictory_evidence,
      identity_result=excluded.identity_result, provenance=excluded.provenance,
      bound=excluded.bound, bound_at=excluded.bound_at, created_at=now();
  END IF;

  RETURN jsonb_build_object('ok',true,'opportunity_product_id',p_product_id,'market',upper(p_market),
    'concrete_state',v_state,'concrete_identity',v_der->'concrete_identity','match_spec',v_spec,
    'candidates_considered',v_considered,'contradictory_evidence',v_contra,
    'qualifying_count', CASE WHEN v_qn_id >= 1 THEN v_qn_id ELSE coalesce(v_qn,0) END,
    'match_basis', v_basis, 'identity_result',v_result,
    'selected_supplier_product_id', v_sel->>'supplier_product_id','selected_sku', v_sel->>'sku',
    'selected_variant', v_sel->'variant',
    'bound',(v_result='EXACT_SUPPLIER_IDENTITY_RESOLVED'),'provenance',v_prov);
END; $function$;

-- =====================================================================================================
-- 2. DISABLED PROVIDER GATE
-- =====================================================================================================
CREATE TABLE IF NOT EXISTS public.commerce_supplier_provider_config (
  provider          text PRIMARY KEY,
  enabled           boolean NOT NULL DEFAULT false,
  evidence_category text NOT NULL DEFAULT 'SUPPLIER',
  access_state      text NOT NULL DEFAULT 'EXTERNAL_APPROVAL_REQUIRED',
  priority          int NOT NULL DEFAULT 100,   -- lower = tried first (CJ-first ordering)
  notes             text,
  updated_at        timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.commerce_supplier_provider_config ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.commerce_supplier_provider_config FROM public, anon, authenticated;

INSERT INTO public.commerce_supplier_provider_config (provider, enabled, access_state, priority, notes)
VALUES
 ('CJDROPSHIPPING', true,  'AVAILABLE',                  10, 'Primary supplier source (live).'),
 ('ALIEXPRESS',     false, 'EXTERNAL_APPROVAL_REQUIRED', 20, 'Secondary source; DORMANT until AliExpress Open Platform access + multi-tenant SaaS rights (and any paid tier) are approved. Enabling this row is an authorised-phase action only.')
ON CONFLICT (provider) DO NOTHING;

CREATE OR REPLACE FUNCTION public.fn_supplier_provider_enabled(p_provider text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT coalesce((SELECT enabled FROM public.commerce_supplier_provider_config
                   WHERE provider = upper(coalesce(p_provider,''))), false);
$function$;

REVOKE ALL ON FUNCTION public.fn_supplier_provider_enabled(text) FROM public, anon, authenticated;

-- =====================================================================================================
-- 3. SOURCE-GENERIC CANONICAL-DTO -> CANDIDATE ADAPTER
--    Input is OUR canonical supplier DTO (fields we define), NOT any provider's raw API schema.
--    The provider-specific raw->canonical mapping is an authorised-phase step (unknown until the real
--    API shape is available; never invented here). Absent fields are stripped, never fabricated.
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_supplier_candidates_from_canonical(p_provider text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'supplier',            upper(coalesce(p_provider,'')),
    'supplier_product_id', it->>'supplier_product_id',
    'sku',                 it->>'sku',
    'title',               it->>'title',
    'category',            it->>'category',
    'variant',             it->'variant'
  ))), '[]'::jsonb)
  FROM jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) it;
$function$;

REVOKE ALL ON FUNCTION public.fn_supplier_candidates_from_canonical(text,jsonb) FROM public, anon, authenticated;

-- =====================================================================================================
-- 4. CJ-FIRST -> ALIEXPRESS FALLBACK HELPER (GATED OFF, NOT wired into finalisation)
--    While ALIEXPRESS is disabled this never attempts AliExpress and returns the CJ result verbatim.
--    Default persist=false; wiring + persist semantics for the live fallback are an authorised-phase
--    decision. fn_finalize_research_run (mig_320) still calls the CJ resolver directly, unchanged.
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_resolve_supplier_identity_multi(
  p_tenant uuid, p_product_id uuid, p_market text,
  p_aliexpress_items jsonb DEFAULT NULL, p_persist boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_cj jsonb; v_ae jsonb; v_cands jsonb; v_enabled boolean;
BEGIN
  -- CJ-first: always resolve CJ first (contract unchanged).
  v_cj := public.fn_resolve_concrete_supplier_identity(p_tenant, p_product_id, p_market, NULL, p_persist);
  IF coalesce(v_cj->>'ok','false') <> 'true' THEN
    RETURN v_cj;  -- propagate errors (e.g. tenant isolation) verbatim
  END IF;

  -- CJ wins outright on an exact resolution.
  IF v_cj->>'identity_result' = 'EXACT_SUPPLIER_IDENTITY_RESOLVED' THEN
    RETURN v_cj || jsonb_build_object('resolution_source','CJDROPSHIPPING','aliexpress_fallback','NOT_ATTEMPTED_CJ_RESOLVED');
  END IF;

  -- CJ did not resolve. Consider AliExpress ONLY if the provider is enabled (default DISABLED).
  v_enabled := public.fn_supplier_provider_enabled('ALIEXPRESS');
  IF NOT v_enabled THEN
    RETURN v_cj || jsonb_build_object('resolution_source','CJDROPSHIPPING','aliexpress_fallback','PROVIDER_DISABLED');
  END IF;

  -- Provider enabled (authorised phase only). No API-sourced items -> nothing to evaluate; never invent.
  IF p_aliexpress_items IS NULL OR jsonb_array_length(coalesce(p_aliexpress_items,'[]'::jsonb)) = 0 THEN
    RETURN v_cj || jsonb_build_object('resolution_source','NONE','aliexpress_fallback','BLOCKED_EXTERNAL_NO_CANDIDATES');
  END IF;

  v_cands := public.fn_supplier_candidates_from_canonical('ALIEXPRESS', p_aliexpress_items);
  v_ae := public.fn_resolve_concrete_supplier_identity(p_tenant, p_product_id, p_market, v_cands, p_persist);
  IF v_ae->>'identity_result' = 'EXACT_SUPPLIER_IDENTITY_RESOLVED' THEN
    RETURN v_ae || jsonb_build_object('resolution_source','ALIEXPRESS','aliexpress_fallback','EXACT_MATCH_BOUND');
  END IF;
  RETURN v_ae || jsonb_build_object('resolution_source','NONE','aliexpress_fallback','NO_VALID_SUPPLIER_MATCH');
END; $function$;

REVOKE ALL ON FUNCTION public.fn_resolve_supplier_identity_multi(uuid,uuid,text,jsonb,boolean) FROM public, anon, authenticated;

-- =====================================================================================================
-- 5. MOCK SELFTEST (persist=false; synthetic candidates — no API, no writes, no paid calls)
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_supplier_sourcegeneric_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_t uuid; v_pid uuid := '873551b0-a0d0-44f6-8792-7b2650d904cd';
  v_title text; v_cases jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0; b boolean;
  r jsonb; v_norm jsonb; v_keys text[];
  v_cj_exact jsonb; v_ae_exact jsonb; v_ae_adj jsonb; v_fb jsonb;
BEGIN
  SELECT user_id, title INTO v_t, v_title FROM public.commerce_products WHERE id = v_pid;
  IF v_t IS NULL THEN
    RETURN jsonb_build_object('ok',false,'error','selftest_fixture_product_missing','product_id',v_pid);
  END IF;

  -- case 1: CJ exact candidate binds AND keeps the CJDROPSHIPPING label (regression)
  v_cj_exact := public.fn_resolve_concrete_supplier_identity(v_t,v_pid,'GB',
    jsonb_build_array(jsonb_build_object('supplier','CJDROPSHIPPING','supplier_product_id','CJ-SELFTEST-EXACT','sku','CJ-SNOW','title',v_title,'category','tiktok_shop_product','variant',jsonb_build_object('color','warm white'))),false);
  b := (v_cj_exact->>'identity_result'='EXACT_SUPPLIER_IDENTITY_RESOLVED')
       AND (v_cj_exact#>>'{provenance,step2_concrete_to_supplier,supplier}'='CJDROPSHIPPING');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','cj_exact_regression','pass',b,
    'actual_result',v_cj_exact->>'identity_result','actual_label',v_cj_exact#>>'{provenance,step2_concrete_to_supplier,supplier}'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- case 2: exact AliExpress candidate binds AND is labelled ALIEXPRESS (source-generic fix; lower->upper)
  v_ae_exact := public.fn_resolve_concrete_supplier_identity(v_t,v_pid,'GB',
    jsonb_build_array(jsonb_build_object('supplier','aliexpress','supplier_product_id','1005013410315354','sku','AE-SNOW','title',v_title,'category','tiktok_shop_product','variant',jsonb_build_object('color','warm white'))),false);
  b := (v_ae_exact->>'identity_result'='EXACT_SUPPLIER_IDENTITY_RESOLVED')
       AND (v_ae_exact#>>'{provenance,step2_concrete_to_supplier,supplier}'='ALIEXPRESS');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','aliexpress_exact_variant_match','pass',b,
    'actual_result',v_ae_exact->>'identity_result','actual_label',v_ae_exact#>>'{provenance,step2_concrete_to_supplier,supplier}'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- case 3: incorrect/category-adjacent AliExpress candidate must NOT bind (never-approximate)
  v_ae_adj := public.fn_resolve_concrete_supplier_identity(v_t,v_pid,'GB',
    jsonb_build_array(jsonb_build_object('supplier','ALIEXPRESS','supplier_product_id','1005099999999','sku','AE-SANTA','title','Christmas Inflatable Santa Claus Outdoor Yard LED Decoration','category','tiktok_shop_product','variant',jsonb_build_object('color','red'))),false);
  b := ((v_ae_adj->>'bound')::boolean IS NOT TRUE) AND (v_ae_adj->>'identity_result' <> 'EXACT_SUPPLIER_IDENTITY_RESOLVED');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','aliexpress_incorrect_variant_not_bound','pass',b,
    'actual_result',v_ae_adj->>'identity_result','actual_bound',v_ae_adj->>'bound'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- case 4: country/tenant isolation — a foreign tenant is rejected, never cross-reads another tenant
  r := public.fn_resolve_concrete_supplier_identity('00000000-0000-0000-0000-000000000000'::uuid, v_pid, 'GB', NULL, false);
  b := (r->>'ok'='false') AND (r->>'error'='product_not_found_for_tenant');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','tenant_isolation_foreign_rejected','pass',b,'actual',r));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- case 4b: market is normalised/carried (lower 'gb' -> 'GB') — country scoping preserved
  r := public.fn_resolve_concrete_supplier_identity(v_t, v_pid, 'gb', NULL, false);
  b := (r->>'market'='GB');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','market_normalised_GB','pass',b,'actual_market',r->>'market'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- case 5: provider gate default state (CJ enabled, AliExpress disabled, case-insensitive)
  b := (public.fn_supplier_provider_enabled('CJDROPSHIPPING') = true)
       AND (public.fn_supplier_provider_enabled('ALIEXPRESS') = false)
       AND (public.fn_supplier_provider_enabled('aliexpress') = false);
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','provider_gate_default_disabled','pass',b,
    'cj_enabled',public.fn_supplier_provider_enabled('CJDROPSHIPPING'),'ae_enabled',public.fn_supplier_provider_enabled('ALIEXPRESS')));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- case 6: normaliser never invents missing fields (no shipping/rights/price keys; absent id fields stripped)
  v_norm := public.fn_supplier_candidates_from_canonical('ALIEXPRESS',
    jsonb_build_array(jsonb_build_object('supplier_product_id','AE-NOSHIP','title','Some AliExpress Title')));
  v_keys := ARRAY(SELECT jsonb_object_keys(v_norm->0));
  b := (upper(v_norm#>>'{0,supplier}')='ALIEXPRESS')
       AND (v_norm#>>'{0,supplier_product_id}'='AE-NOSHIP')
       AND NOT (v_keys && ARRAY['shipping','rights','rights_state','price','supplier_cost','stock','shipping_country_codes','image_url'])
       AND NOT ('sku' = ANY(v_keys))
       AND NOT ('variant' = ANY(v_keys))
       AND NOT ('category' = ANY(v_keys));
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','normaliser_no_invented_fields','pass',b,'keys',to_jsonb(v_keys)));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- case 7: fallback helper is GATED OFF — even with a matching AliExpress item supplied, no AliExpress
  -- attempt is made; the CJ result (NO_VALID_CJ_MATCH from the live self-build) is returned verbatim.
  v_fb := public.fn_resolve_supplier_identity_multi(v_t, v_pid, 'GB',
    jsonb_build_array(jsonb_build_object('supplier_product_id','1005013410315354','title',v_title,'variant',jsonb_build_object('color','warm white'))),
    false);
  b := (v_fb->>'aliexpress_fallback'='PROVIDER_DISABLED')
       AND (v_fb->>'identity_result'='NO_VALID_CJ_MATCH')
       AND (v_fb->>'resolution_source'='CJDROPSHIPPING');
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','fallback_gated_off_no_aliexpress_attempt','pass',b,
    'fallback',v_fb->>'aliexpress_fallback','result',v_fb->>'identity_result','source',v_fb->>'resolution_source'));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  -- case 8: failed/empty API responses — normaliser returns [] (no crash, no fabricated candidates)
  b := (public.fn_supplier_candidates_from_canonical('ALIEXPRESS', NULL) = '[]'::jsonb)
       AND (public.fn_supplier_candidates_from_canonical('ALIEXPRESS', '[]'::jsonb) = '[]'::jsonb);
  v_cases := v_cases || jsonb_build_array(jsonb_build_object('case','failed_or_empty_api_response_no_candidates','pass',b));
  IF b THEN v_pass:=v_pass+1; ELSE v_fail:=v_fail+1; END IF;

  RETURN jsonb_build_object('ok', v_fail=0, 'passed', v_pass, 'failed', v_fail, 'total', v_pass+v_fail,
    'contract','pulse_supplier_sourcegeneric_selftest_v1', 'cases', v_cases, 'generated_at', now());
END; $function$;

REVOKE ALL ON FUNCTION public.fn_supplier_sourcegeneric_selftest() FROM public, anon, authenticated;

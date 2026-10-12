-- mig_379b — Stage-boundary separation + evidence/identity regression
--
-- PART E: fn_pod_evaluate sends the opportunity decision to WATCH whenever any hard gate is in
-- WATCH, including SUPPLIER_STOCK_UNKNOWN / ECONOMICS_UNKNOWN / COMPLIANCE_UNVERIFIED /
-- FULFILMENT_ROUTE_UNCONFIRMED. Those four are Stage-2/3 (Exact Supplier Resolution / Supplier
-- Commercial Verification) concerns — they conflated "opportunity qualified" with "commercially
-- launchable". This adds a standalone Stage-1 qualification signal derived ONLY from Stage-1-owned
-- evidence (opportunity score + overall evidence confidence + LOCAL price validation + saturation),
-- explicitly EXCLUDING the four supplier/commercial gates. It changes no gate and no existing
-- decision; it answers "worth taking into supplier resolution?" — not "commercially launchable".
--
-- check_function_bodies disabled for these CREATEs only (managed-instance validation path).
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_stage1_opportunity_qualified(p_tenant uuid, p_product uuid, p_country text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE d record; v_score numeric; v_conf text; v_scope text; v_sat text; v_price text; v_q boolean; v_state text;
BEGIN
  SELECT * INTO d FROM public.product_opportunity_decisions
    WHERE tenant_id=p_tenant AND product_id=p_product AND country_code=upper(btrim(coalesce(p_country,'')))
    ORDER BY created_at DESC LIMIT 1;
  IF d.id IS NULL THEN
    RETURN jsonb_build_object('stage1_opportunity_qualified',false,'stage1_qualification_state','NO_DECISION',
      'note','no persisted opportunity decision for this product x country');
  END IF;
  v_score := d.product_opportunity_score; v_conf := d.overall_evidence_confidence; v_scope := d.metric_scope;
  v_sat := d.hard_gates->>'saturation'; v_price := d.hard_gates->>'market_price';
  -- Stage-1-owned standard (no supplier/economics/compliance/fulfilment):
  v_q := (v_score IS NOT NULL AND v_score >= 70 AND v_conf IN ('MEDIUM','HIGH')
          AND v_scope = 'LOCAL' AND v_sat = 'PASS' AND v_price = 'PASS');
  v_state := CASE WHEN v_score IS NULL THEN 'INSUFFICIENT_EVIDENCE'
                  WHEN v_q THEN 'QUALIFIED_FOR_SUPPLIER_RESOLUTION'
                  WHEN v_score >= 40 THEN 'WATCH'
                  ELSE 'AVOID' END;
  RETURN jsonb_build_object(
    'stage1_opportunity_qualified', v_q,
    'stage1_qualification_state', v_state,
    'opportunity_score', v_score, 'overall_evidence_confidence', v_conf, 'metric_scope', v_scope,
    'stage1_owned_gates', jsonb_build_object('market_price', v_price, 'saturation', v_sat),
    'stage2_3_gates_excluded', jsonb_build_object('supplier', d.hard_gates->>'supplier','economics', d.hard_gates->>'economics',
      'compliance', d.hard_gates->>'compliance','fulfilment', d.hard_gates->>'fulfilment'),
    'pod_decision', d.decision, 'pod_band', d.opportunity_band,
    'note','Stage-1 qualification uses only Stage-1-owned evidence; supplier/economics/compliance/fulfilment are Stage-2/3 and never block Stage-1 opportunity qualification. QUALIFIED_FOR_SUPPLIER_RESOLUTION != SUPPLIER_VERIFIED != COMMERCIALLY_LAUNCHABLE.',
    'contract','pulse_stage1_opportunity_qualification_v1');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_stage1_opportunity_qualified(uuid, uuid, text) TO authenticated, service_role;

-- Regression: search identity, family normalization, research-query wiring, Stage-1 separation.
CREATE OR REPLACE FUNCTION public.fn_stage1_evidence_identity_selftest()
 RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb; n_fail int;
  mw_q text; cable_q text; rot_q text; three_q text; twox_q text;
  fam_dec text; fam_plain text; fam_sizeM text;
  d_core text; d_s1 text; d_s1_vq text;
BEGIN
  mw_q := public.fn_product_search_identity('1PC erweiterbares Mikrowellen-Lagerhalter mit 6 Haken, Küchenzähler-Organizer')->>'search_query';
  cable_q := public.fn_product_search_identity('cable organizer')->>'search_query';
  rot_q := public.fn_product_search_identity('360 Grad drehbarer Wasserhahn Aufsatz')->>'search_query';
  three_q := public.fn_product_search_identity('3 in 1 Gemüseschneider Set')->>'search_query';
  twox_q := public.fn_product_search_identity('2 x Mini Neck Fan tragbar')->>'search_query';
  fam_dec   := public.fn_product_family_key('reisenthel carrybag XS Kleiner Einkaufskorb 5 l Leo Macchiato [Y]');
  fam_plain := public.fn_product_family_key('reisenthel carrybag XS Kleiner Einkaufskorb 5 l Leo Macchiato');
  fam_sizeM := public.fn_product_family_key('reisenthel carrybag M Kleiner Einkaufskorb 10 l Leo Macchiato');
  SELECT pg_get_functiondef(p.oid) INTO d_core FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_research_request_core';
  SELECT pg_get_functiondef(p.oid) INTO d_s1 FROM pg_proc p JOIN pg_namespace nn ON nn.oid=p.pronamespace WHERE nn.nspname='public' AND p.proname='fn_stage1_opportunity_qualified';
  d_s1_vq := substring(coalesce(d_s1,'') from 'v_q :=[^;]*;');

  v := v || jsonb_build_object('check','01_SEARCH_IDENTITY_TRIMS_NOISY_TITLE','pass',
    (mw_q = 'erweiterbares mikrowellen lagerhalter'));
  v := v || jsonb_build_object('check','02_SEARCH_IDENTITY_IDEMPOTENT_CLEAN','pass',
    (cable_q = 'cable organizer'));
  v := v || jsonb_build_object('check','03_QUANTITY_STRIP_CONSERVATIVE','pass',
    (rot_q ~ '^360' AND three_q ~ '^3 in 1' AND twox_q = 'mini neck fan tragbar'));
  v := v || jsonb_build_object('check','04_FAMILY_DECORATION_SAME','pass',
    (fam_dec IS NOT NULL AND fam_dec = fam_plain));
  v := v || jsonb_build_object('check','05_FAMILY_VARIANT_DISTINCT','pass',
    (fam_plain <> fam_sizeM));
  v := v || jsonb_build_object('check','06_FAMILY_PRESERVES_IDENTITY_TOKENS','pass',
    (fam_plain ~ '\yxs\y' AND fam_plain ~ '\y5\y'));
  v := v || jsonb_build_object('check','07_RESEARCH_CORE_USES_SEARCH_IDENTITY','pass',
    (coalesce(d_core,'') ~* 'fn_product_search_identity' AND coalesce(d_core,'') ~* 'raw_query'));
  v := v || jsonb_build_object('check','08_STAGE1_EXCLUDES_SUPPLIER_GATES','pass',
    (coalesce(d_s1,'') ~* 'stage2_3_gates_excluded'
     AND coalesce(d_s1_vq,'') !~* 'supplier|economics|compliance|fulfilment'
     AND coalesce(d_s1_vq,'') ~* 'market_price|v_price' AND coalesce(d_s1_vq,'') ~* 'v_sat'));
  v := v || jsonb_build_object('check','09_STAGE1_REQUIRES_STRONG_STAGE1_EVIDENCE','pass',
    (coalesce(d_s1_vq,'') ~* 'v_score >= 70' AND coalesce(d_s1_vq,'') ~* 'MEDIUM' AND coalesce(d_s1_vq,'') ~* 'LOCAL'));
  v := v || jsonb_build_object('check','10_EXISTING_SUITES_GREEN','pass',
    ((public.fn_fastmoss_commerce_adapter_selftest()->>'all_pass')::boolean
     AND (public.fn_kalodata_commerce_adapter_selftest()->>'all_pass')::boolean
     AND (public.fn_multi_lane_discovery_selftest()->>'all_pass')::boolean
     AND (public.fn_stage1_research_bridge_selftest()->>'all_pass')::boolean
     AND (public.fn_stage1_product_opportunity_invariants_selftest()->>'all_pass')::boolean
     AND (public.fn_product_image_selftest()->>'all_pass')::boolean
     AND (public.fn_autonomous_discovery_selftest()->>'all_pass')::boolean));

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE (x->>'pass') IS DISTINCT FROM 'true';
  RETURN jsonb_build_object('suite','stage1_evidence_identity','contract','stage1_evidence_identity_v1',
    'total',jsonb_array_length(v),'failed',n_fail,'all_pass',(n_fail=0),'results',v);
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_stage1_evidence_identity_selftest() TO authenticated, service_role;

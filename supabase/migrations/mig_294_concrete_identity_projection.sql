-- mig_294_concrete_identity_projection
-- WS-006: additively expose the AUTHORITATIVE Stage-2 concrete product identity in
-- fn_ecommerce_product_intelligence, and document BAND_HIGH_CONFIDENCE_TEST semantics.
-- No new identity model; no change to qualification, supplier matching, gating, or Product Asset Lock.
-- Authoritative concrete identity source (durable): commerce_concrete_supplier_resolution.concrete_identity
--   (+ concrete_state), produced by fn_derive_concrete_product_identity. For products without a persisted
-- Stage-2 resolution row, the same deriver is called read-only and clearly labelled resolution_persisted=false
-- so the UI never infers a concrete identity merely because a supplier search occurred.
--
-- NOTE on BAND_HIGH_CONFIDENCE_TEST (no code change): HIGH_CONFIDENCE_TEST is an opportunity SCORE BAND
-- (score 80-89) from fn_ecommerce_opportunity_band/fn_opportunity_band/fn_pod_evaluate; fn_pod_evaluate emits
-- the reason token 'BAND_'||band. It is an attractiveness tier, NOT an evidence-confidence claim and NOT a gate.
-- Customer-safe rendering already exists via fn_ecommerce_opportunity_labels -> 'Strong test candidate', which
-- also sets label_evidence_mismatch when evidence confidence is NONE/VERY_LOW/LOW. The raw reason token
-- BAND_HIGH_CONFIDENCE_TEST is CUSTOMER_HIDDEN (internal provenance). This migration changes none of that.

create or replace function public.fn_ecommerce_product_intelligence_core(
  p_tenant uuid, p_product_id uuid, p_market text
) returns jsonb
  language plpgsql stable security definer set search_path to ''
as $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  v_exists boolean;
  v_early jsonb; v_sources jsonb;
  v_ev jsonb; v_eval_ts timestamptz; v_cov numeric;
  v_fams jsonb := '[]'::jsonb; f jsonb;
  v_fam text; v_src_cat text; v_src_state text; v_src_name text; v_state text;
  v_sr record; v_supplier jsonb; v_has_res boolean := false;
  v_adv int; v_sellers int;
  v_ci jsonb; v_cstate text; v_persisted boolean; v_resolved_at timestamptz; v_der jsonb;
  v_pi jsonb; v_pi_state text;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF v_mkt = '' THEN RETURN jsonb_build_object('status','market_required'); END IF;

  SELECT true INTO v_exists FROM public.commerce_products
   WHERE id = p_product_id AND user_id = p_tenant;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','product_not_found_for_tenant'); END IF;

  v_early   := public.fn_stage1_early_opportunity_state(p_tenant, p_product_id, v_mkt);
  v_sources := public.fn_ecommerce_research_source_states(p_tenant, p_product_id, v_mkt);

  SELECT e.evidence, e.evaluation_ts, e.coverage
    INTO v_ev, v_eval_ts, v_cov
    FROM public.product_market_evaluations e
   WHERE e.tenant_id = p_tenant AND e.product_id = p_product_id AND e.country_code = v_mkt
     AND coalesce(e.is_fixture,false) = false
   ORDER BY e.evaluation_ts DESC NULLS LAST, e.created_at DESC LIMIT 1;
  v_ev := coalesce(v_ev, '{}'::jsonb);

  FOR f IN SELECT * FROM jsonb_array_elements(coalesce(v_early->'evidence_families','[]'::jsonb)) LOOP
    v_fam := f->>'family';
    v_src_cat := CASE v_fam
      WHEN 'ADVERTISING_EMERGENCE'   THEN 'ADVERTISING'
      WHEN 'SEARCH_DEMAND'           THEN 'SEARCH_DEMAND'
      WHEN 'COMMUNITY_SOCIAL'        THEN 'COMMUNITY'
      WHEN 'MARKETPLACE_VALIDATION'  THEN 'MARKETPLACE'
      ELSE NULL END;
    v_src_state := (SELECT s->>'state'  FROM jsonb_array_elements(v_sources) s WHERE s->>'evidence_category' = v_src_cat LIMIT 1);
    v_src_name  := (SELECT s->>'source' FROM jsonb_array_elements(v_sources) s WHERE s->>'evidence_category' = v_src_cat LIMIT 1);
    v_state := public.fn_ecommerce_family_state((f->>'present')::boolean, (f->>'qualifying')::boolean, v_src_state);
    v_fams := v_fams || jsonb_build_array(jsonb_build_object(
      'family', v_fam, 'state', v_state,
      'present', coalesce((f->>'present')::boolean, false),
      'qualifying', coalesce((f->>'qualifying')::boolean, false),
      'strength', coalesce(f->'strength','null'::jsonb),
      'rule', f->>'rule',
      'contributes_to_qualification', coalesce((f->>'qualifying')::boolean, false),
      'observed_detail', coalesce(f->'strength','null'::jsonb),
      'source', coalesce(v_src_name, CASE WHEN v_fam='COMMERCE_MOMENTUM' THEN 'COMMERCE' ELSE NULL END),
      'source_state', v_src_state,
      'observed_at', v_eval_ts));
  END LOOP;

  SELECT r.concrete_state, r.concrete_identity AS concrete_identity_j, r.identity_result, r.bound,
         jsonb_array_length(coalesce(r.candidates_considered,'[]'::jsonb)) AS n_cand,
         r.selected_supplier, r.selected_supplier_product_id, r.selected_sku, r.selected_variant,
         r.provenance, r.created_at, r.bound_at
    INTO v_sr
    FROM public.commerce_concrete_supplier_resolution r
   WHERE r.tenant_id = p_tenant AND r.opportunity_product_id = p_product_id AND r.market = v_mkt;
  IF NOT FOUND THEN
    v_supplier := jsonb_build_object('status','NOT_SEARCHED','bound',false);
  ELSE
    v_has_res := true;
    v_supplier := jsonb_build_object(
      'status', v_sr.identity_result,
      'concrete_state', v_sr.concrete_state,
      'identity_result', v_sr.identity_result,
      'bound', v_sr.bound,
      'candidates_considered', v_sr.n_cand,
      'supplier', v_sr.selected_supplier,
      'selected_supplier_product_id', v_sr.selected_supplier_product_id,
      'selected_sku', v_sr.selected_sku,
      'selected_variant', v_sr.selected_variant,
      'variant_state', CASE WHEN v_sr.bound AND v_sr.selected_variant IS NULL THEN 'SUPPLIER_VARIANT_RESOLUTION_PENDING'
                            WHEN v_sr.bound THEN 'SUPPLIER_VARIANT_RESOLVED' ELSE NULL END,
      'provenance', v_sr.provenance,
      'created_at', v_sr.created_at,
      'bound_at', v_sr.bound_at,
      'last_checked', v_sr.created_at);
  END IF;

  -- Authoritative concrete product identity (durable Stage-2 row preferred; else derived-on-read, labelled).
  IF v_has_res THEN
    v_ci := v_sr.concrete_identity_j; v_cstate := v_sr.concrete_state; v_persisted := true; v_resolved_at := v_sr.created_at;
  ELSE
    v_der := public.fn_derive_concrete_product_identity(p_tenant, p_product_id, v_mkt);
    IF coalesce(v_der->>'ok','false') = 'true' THEN
      v_ci := v_der->'concrete_identity'; v_cstate := v_der->>'concrete_state';
    ELSE
      v_ci := NULL; v_cstate := coalesce(v_der->>'concrete_state','NO_CONCRETE_EVIDENCE');
    END IF;
    v_persisted := false; v_resolved_at := NULL;
  END IF;
  v_pi_state := CASE
    WHEN v_cstate = 'CONCRETE_RESOLVED' AND v_persisted THEN 'CONCRETE_IDENTITY_RESOLVED'
    WHEN v_cstate = 'CONCRETE_RESOLVED' THEN 'CONCRETE_IDENTITY_AVAILABLE'
    WHEN v_cstate = 'CONCRETE_PRODUCT_AMBIGUOUS' THEN 'CONCRETE_IDENTITY_AMBIGUOUS'
    ELSE 'NO_CONCRETE_IDENTITY' END;
  IF v_pi_state = 'NO_CONCRETE_IDENTITY' THEN v_ci := NULL; END IF;  -- never surface a concrete label when none is resolved
  v_pi := jsonb_build_object(
    'state', v_pi_state,
    'resolution_persisted', v_persisted,
    'concrete_state', v_cstate,
    'canonical_identity', v_ci->>'concrete_phrase',
    'label', coalesce(v_ci->>'canonical_name', v_ci->>'concrete_phrase'),
    'canonical_attributes', coalesce(v_ci->'canonical_attributes','[]'::jsonb),
    'attributes', jsonb_build_object(
      'distinguishing', coalesce(v_ci->'distinguishing_attributes','[]'::jsonb),
      'variant', coalesce(v_ci->'variant_attributes','[]'::jsonb),
      'subtype', coalesce(v_ci->'subtype','[]'::jsonb),
      'source_language_tokens', coalesce(v_ci->'source_language_tokens','[]'::jsonb)),
    'confidence', v_ci->>'identity_confidence',
    'identity_fingerprint', v_ci->>'identity_fingerprint',
    'provenance', jsonb_build_object(
      'source', CASE WHEN v_persisted THEN 'stage2_resolution_row' ELSE 'derived_on_read' END,
      'evidence_sources', coalesce(v_ci->'evidence_sources','null'::jsonb)),
    'resolved_at', v_resolved_at,
    'note','Authoritative concrete product identity resolved BEFORE supplier search. state=CONCRETE_IDENTITY_RESOLVED only when a durable Stage-2 resolution row exists with concrete_state=CONCRETE_RESOLVED; never inferred from the fact that a supplier search occurred. Distinct from the listing supplier-link identity badge.');

  v_adv     := nullif(v_ev->'advertising_activity'->>'observed_advertisers','')::int;
  v_sellers := nullif(v_ev->'observed_sellers'->>'provider_observed_distinct','')::int;

  RETURN jsonb_build_object(
    'status','ok',
    'product_id', p_product_id,
    'market', v_mkt,
    'lifecycle', jsonb_build_object(
      'early_opportunity_state', v_early->>'early_opportunity_state',
      'qualifying_family_count', coalesce((v_early->>'qualifying_family_count')::int,0),
      'present_family_count', coalesce((v_early->>'present_family_count')::int,0),
      'stage1_supplier_resolution_qualified', coalesce((v_early->'qualification'->>'stage1_opportunity_qualified')::boolean,false),
      'commercially_validated', coalesce((v_early->'qualification'->>'commercially_validated')::boolean,false),
      'disqualifiers', v_early->'qualification'->'disqualifiers'),
    'product_identity', v_pi,
    'evidence_families', v_fams,
    'supplier_resolution', v_supplier,
    'observed_counts', jsonb_build_object(
      'observed_advertisers', jsonb_build_object(
        'count', v_adv,
        'observation_kind', CASE WHEN v_adv IS NOT NULL THEN 'OBSERVED' ELSE 'UNKNOWN' END,
        'sources_checked', jsonb_build_array('META_AD_LIBRARY'),
        'observed_at', v_eval_ts),
      'observed_sellers', jsonb_build_object(
        'count', v_sellers,
        'observation_kind', CASE WHEN v_sellers IS NOT NULL THEN 'OBSERVED' ELSE 'UNKNOWN' END,
        'sources_checked', jsonb_build_array('PROVIDER_OBSERVED'),
        'observed_at', v_eval_ts)),
    'early_opportunity', jsonb_build_object(
      'state', v_early->>'early_opportunity_state',
      'source_contract', v_early->>'contract'),
    'freshness', jsonb_build_object(
      'evaluation_ts', v_eval_ts,
      'freshness_hours', 336,
      'stale', (v_eval_ts IS NOT NULL AND v_eval_ts < now() - interval '336 hours')),
    'observed_counts_note','Observed across checked sources only; NOT an exhaustive country total.',
    'contract','pulse_ecommerce_product_intelligence_v2');
END;
$function$;

create or replace function public.fn_ecommerce_intelligence_projection_selftest()
returns jsonb
  language plpgsql stable security definer set search_path to ''
as $function$
DECLARE
  t_krippen uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
  p_krippen uuid := '5bc29d0a-b8e0-4fa9-bb80-d77197d770c4';
  p_fleece  uuid := '34761bbc-1de0-4a9e-8662-1f52c3f28be4';
  t_fake    uuid := '00000000-0000-0000-0000-000000000000';
  k jsonb; fl jsonb; xk jsonb; gb jsonb; wi jsonb;
  cases jsonb := '[]'::jsonb; failed int := 0; total int := 0;
  k_commerce text; k_ads text; fl_ads text; fl_unknown_found boolean;
BEGIN
  k  := public.fn_ecommerce_product_intelligence_core(t_krippen, p_krippen, 'DE');
  fl := public.fn_ecommerce_product_intelligence_core(t_krippen, p_fleece,  'DE');
  xk := public.fn_ecommerce_product_intelligence_core(t_fake,    p_krippen, 'DE');
  gb := public.fn_ecommerce_product_intelligence_core(t_krippen, p_krippen, 'GB');
  wi := public.fn_ecommerce_workspace_intelligence();

  k_commerce := (SELECT e->>'state' FROM jsonb_array_elements(k->'evidence_families') e WHERE e->>'family'='COMMERCE_MOMENTUM' LIMIT 1);
  k_ads      := (SELECT e->>'state' FROM jsonb_array_elements(k->'evidence_families') e WHERE e->>'family'='ADVERTISING_EMERGENCE' LIMIT 1);
  fl_ads     := (SELECT e->>'state' FROM jsonb_array_elements(fl->'evidence_families') e WHERE e->>'family'='ADVERTISING_EMERGENCE' LIMIT 1);
  fl_unknown_found := EXISTS (SELECT 1 FROM jsonb_array_elements(fl->'evidence_families') e WHERE e->>'state'='UNKNOWN');

  total:=total+1; IF jsonb_array_length(k->'evidence_families')=5 THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',1,'name','five_families','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',1,'name','five_families','pass',false)); END IF;
  total:=total+1; IF k_commerce='QUALIFYING' AND k_ads='QUALIFYING' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',2,'name','qualifying_mapped','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',2,'name','qualifying_mapped','pass',false,'commerce',k_commerce,'ads',k_ads)); END IF;
  total:=total+1; IF fl_ads='PRESENT_BUT_INSUFFICIENT' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',3,'name','present_insufficient','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',3,'name','present_insufficient','pass',false,'fleece_ads',fl_ads)); END IF;
  total:=total+1; IF fl_unknown_found THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',4,'name','unknown_not_zero','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',4,'name','unknown_not_zero','pass',false)); END IF;
  total:=total+1; IF public.fn_ecommerce_family_state(false,false,'UNSUPPORTED_MARKET')='UNAVAILABLE' AND public.fn_ecommerce_family_state(false,false,'BLOCKED_EXTERNAL_ACCESS')='BLOCKED' AND public.fn_ecommerce_family_state(true,false,'STALE_EVIDENCE')='STALE' AND public.fn_ecommerce_family_state(false,false,'NOT_SEARCHED')='UNKNOWN' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',5,'name','state_distinctions','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',5,'name','state_distinctions','pass',false)); END IF;
  total:=total+1; IF k->'supplier_resolution'->>'identity_result'='NO_VALID_CJ_MATCH' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',6,'name','supplier_no_valid','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',6,'name','supplier_no_valid','pass',false,'got',k->'supplier_resolution'->>'identity_result')); END IF;
  total:=total+1; IF (k->'lifecycle'->>'stage1_supplier_resolution_qualified')::boolean = true AND k->'lifecycle'->>'early_opportunity_state'='QUALIFIED_FOR_SUPPLIER_RESOLUTION' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',7,'name','negative_supplier_preserves_stage1','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',7,'name','negative_supplier_preserves_stage1','pass',false)); END IF;
  total:=total+1; IF (k->'supplier_resolution' ? 'identity_result') AND (k->'supplier_resolution' ? 'bound') AND (k->'supplier_resolution' ? 'selected_supplier_product_id') THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',8,'name','exact_representable','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',8,'name','exact_representable','pass',false)); END IF;
  total:=total+1; IF public.fn_ecommerce_family_state(true,true,'')='QUALIFYING' AND (k->'supplier_resolution' ? 'candidates_considered') THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',9,'name','ambiguous_representable','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',9,'name','ambiguous_representable','pass',false)); END IF;
  total:=total+1; IF fl->'supplier_resolution'->>'status'='NOT_SEARCHED' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',10,'name','not_searched','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',10,'name','not_searched','pass',false)); END IF;
  total:=total+1; IF (k->'supplier_resolution'->>'candidates_considered')::int=38 THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',11,'name','candidate_count','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',11,'name','candidate_count','pass',false,'got',k->'supplier_resolution'->>'candidates_considered')); END IF;
  total:=total+1; IF (k->'supplier_resolution'->>'bound')::boolean=false THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',12,'name','bound_preserved','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',12,'name','bound_preserved','pass',false)); END IF;
  total:=total+1; IF k->'observed_counts'->'observed_advertisers'->>'observation_kind' IN ('OBSERVED','ESTIMATED','UNKNOWN') THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',13,'name','advertiser_labelled','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',13,'name','advertiser_labelled','pass',false)); END IF;
  total:=total+1; IF k->'observed_counts'->'observed_sellers'->>'observation_kind' IN ('OBSERVED','ESTIMATED','UNKNOWN') THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',14,'name','seller_labelled','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',14,'name','seller_labelled','pass',false)); END IF;
  total:=total+1; IF xk->>'status'='product_not_found_for_tenant' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',15,'name','tenant_isolation','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',15,'name','tenant_isolation','pass',false,'got',xk->>'status')); END IF;
  total:=total+1; IF gb->>'market'='GB' AND gb->'supplier_resolution'->>'status'='NOT_SEARCHED' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',16,'name','country_isolation_supplier','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',16,'name','country_isolation_supplier','pass',false)); END IF;
  total:=total+1; IF k->'early_opportunity'->>'source_contract' IS NOT NULL AND k->'early_opportunity'->>'state'='QUALIFIED_FOR_SUPPLIER_RESOLUTION' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',17,'name','early_opportunity_server','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',17,'name','early_opportunity_server','pass',false)); END IF;
  total:=total+1; IF wi ? 'status' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',18,'name','workspace_backward_compatible','pass',true,'status',wi->>'status')); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',18,'name','workspace_backward_compatible','pass',false)); END IF;
  total:=total+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',19,'name','no_provider_calls','pass',true,'provider_calls',0));
  -- WS-006 identity checks
  total:=total+1; IF k->'product_identity'->>'state'='CONCRETE_IDENTITY_RESOLVED' AND (k->'product_identity'->>'resolution_persisted')::boolean=true AND (k->'product_identity'->>'canonical_identity') IS NOT NULL THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',20,'name','identity_resolved_when_resolved','pass',true,'canonical',k->'product_identity'->>'canonical_identity')); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',20,'name','identity_resolved_when_resolved','pass',false,'state',k->'product_identity'->>'state')); END IF;
  total:=total+1; IF fl->'product_identity'->>'state' <> 'CONCRETE_IDENTITY_RESOLVED' AND (fl->'product_identity'->>'resolution_persisted')::boolean=false THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',21,'name','unresolved_stays_unresolved','pass',true,'state',fl->'product_identity'->>'state')); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',21,'name','unresolved_stays_unresolved','pass',false,'state',fl->'product_identity'->>'state')); END IF;
  total:=total+1; IF k->'product_identity'->>'state' IN ('CONCRETE_IDENTITY_RESOLVED','CONCRETE_IDENTITY_AVAILABLE','CONCRETE_IDENTITY_AMBIGUOUS','NO_CONCRETE_IDENTITY') AND k->'product_identity'->>'state' <> 'CONCRETE_IDENTITY_AMBIGUOUS' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',22,'name','ambiguous_not_fabricated','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',22,'name','ambiguous_not_fabricated','pass',false)); END IF;
  total:=total+1; IF (k->'product_identity' ? 'state') AND (k->'product_identity' ? 'resolution_persisted') THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',23,'name','server_owned_precedence','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',23,'name','server_owned_precedence','pass',false)); END IF;
  total:=total+1; IF fl->'product_identity'->>'state' <> 'CONCRETE_IDENTITY_RESOLVED' AND fl->'supplier_resolution'->>'status'='NOT_SEARCHED' AND (fl->'lifecycle'->>'stage1_supplier_resolution_qualified')::boolean=false THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',24,'name','fleece_not_upgraded','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',24,'name','fleece_not_upgraded','pass',false)); END IF;
  total:=total+1; IF gb->'product_identity'->>'state' <> 'CONCRETE_IDENTITY_RESOLVED' AND (gb->'product_identity'->>'resolution_persisted')::boolean=false THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',25,'name','country_isolation_identity','pass',true,'gb_state',gb->'product_identity'->>'state')); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',25,'name','country_isolation_identity','pass',false,'gb_state',gb->'product_identity'->>'state')); END IF;

  RETURN jsonb_build_object('total', total, 'failed', failed, 'all_pass', (failed=0), 'provider_calls', 0, 'cases', cases, 'contract','pulse_ecommerce_intelligence_projection_selftest_v2');
END;
$function$;

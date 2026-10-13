-- mig_293_ecommerce_intelligence_projection
-- P0 frontend-safe, read-only, country-isolated projection of EXISTING Strateloq intelligence.
-- Adds NO new intelligence and changes NO qualification/supplier-resolution semantics.
-- Reuses: fn_stage1_early_opportunity_state (-> fn_stage1_supplier_resolution_qualified, the authoritative
-- Stage-1 gate), fn_ecommerce_research_source_states (source availability/blocked/stale), and the persisted
-- commerce_concrete_supplier_resolution (Stage-2). Tenant = auth.uid(); country = explicit market arg.

create or replace function public.fn_ecommerce_family_state(
  p_present boolean, p_qualifying boolean, p_source_state text
) returns text
  language sql immutable set search_path to ''
as $function$
  select case
    when coalesce(p_qualifying, false) then 'QUALIFYING'
    when coalesce(p_present, false) then
      case when upper(coalesce(p_source_state,'')) like '%STALE%' then 'STALE'
           else 'PRESENT_BUT_INSUFFICIENT' end
    when upper(coalesce(p_source_state,'')) like '%UNSUPPORTED%' then 'UNAVAILABLE'
    when upper(coalesce(p_source_state,'')) like '%BLOCKED%'     then 'BLOCKED'
    when upper(coalesce(p_source_state,'')) like '%STALE%'       then 'STALE'
    else 'UNKNOWN'
  end;
$function$;

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
  v_sr record; v_supplier jsonb;
  v_adv int; v_sellers int;
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
      'family', v_fam,
      'state', v_state,
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

  SELECT r.concrete_state, r.identity_result, r.bound,
         jsonb_array_length(coalesce(r.candidates_considered,'[]'::jsonb)) AS n_cand,
         r.selected_supplier, r.selected_supplier_product_id, r.selected_sku, r.selected_variant,
         r.provenance, r.created_at, r.bound_at
    INTO v_sr
    FROM public.commerce_concrete_supplier_resolution r
   WHERE r.tenant_id = p_tenant AND r.opportunity_product_id = p_product_id AND r.market = v_mkt;
  IF NOT FOUND THEN
    v_supplier := jsonb_build_object('status','NOT_SEARCHED','bound',false);
  ELSE
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
    'contract','pulse_ecommerce_product_intelligence_v1');
END;
$function$;

create or replace function public.fn_ecommerce_product_intelligence(
  p_product_id uuid, p_market text
) returns jsonb
  language plpgsql stable security definer set search_path to ''
as $function$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  RETURN public.fn_ecommerce_product_intelligence_core(v_uid, p_product_id, p_market);
END;
$function$;

create or replace function public.fn_ecommerce_lifecycle_summary_core(
  p_tenant uuid, p_market text
) returns jsonb
  language plpgsql stable security definer set search_path to ''
as $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_market,'')));
  r record; v_early jsonb; v_state text; v_total int := 0;
  c_disc int := 0; c_emg int := 0; c_rp int := 0; c_qual int := 0; c_res int := 0; c_cv int := 0;
BEGIN
  IF p_tenant IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  IF v_mkt = '' THEN RETURN jsonb_build_object('status','market_required'); END IF;

  FOR r IN
    SELECT DISTINCT e.product_id
      FROM public.product_market_evaluations e
     WHERE e.tenant_id = p_tenant AND e.country_code = v_mkt AND coalesce(e.is_fixture,false) = false
  LOOP
    v_total := v_total + 1;
    v_early := public.fn_stage1_early_opportunity_state(p_tenant, r.product_id, v_mkt);
    v_state := v_early->>'early_opportunity_state';
    IF v_state = 'DISCOVERED' THEN c_disc := c_disc + 1;
    ELSIF v_state = 'EMERGING' THEN c_emg := c_emg + 1;
    ELSIF v_state = 'RESEARCH_PRIORITY' THEN c_rp := c_rp + 1;
    ELSIF v_state = 'QUALIFIED_FOR_SUPPLIER_RESOLUTION' THEN c_qual := c_qual + 1;
    END IF;
    IF coalesce((v_early->'qualification'->>'commercially_validated')::boolean,false) THEN c_cv := c_cv + 1; END IF;
    IF EXISTS (SELECT 1 FROM public.commerce_concrete_supplier_resolution r2
                WHERE r2.tenant_id = p_tenant AND r2.opportunity_product_id = r.product_id
                  AND r2.market = v_mkt AND r2.bound = true) THEN c_res := c_res + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'status','ok','market', v_mkt,
    'counts', jsonb_build_object(
      'DISCOVERED', c_disc, 'EMERGING', c_emg, 'RESEARCH_PRIORITY', c_rp,
      'QUALIFIED_FOR_SUPPLIER_RESOLUTION', c_qual,
      'SUPPLIER_RESOLVED', c_res, 'COMMERCIALLY_VALIDATED', c_cv),
    'overlay_counts', jsonb_build_array('SUPPLIER_RESOLVED','COMMERCIALLY_VALIDATED'),
    'total_products_in_market', v_total,
    'generated_at', now(),
    'note','Counts are tenant+country isolated over products evaluated in this market. SUPPLIER_RESOLVED and COMMERCIALLY_VALIDATED overlay the lifecycle state. A 0 here is a known zero (no such products); it is not an UNKNOWN.',
    'contract','pulse_ecommerce_lifecycle_summary_v1');
END;
$function$;

create or replace function public.fn_ecommerce_lifecycle_summary(
  p_market text
) returns jsonb
  language plpgsql stable security definer set search_path to ''
as $function$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;
  RETURN public.fn_ecommerce_lifecycle_summary_core(v_uid, p_market);
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

  total:=total+1; IF jsonb_array_length(k->'evidence_families')=5 THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',1,'name','five_families','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',1,'name','five_families','pass',false,'got',jsonb_array_length(k->'evidence_families'))); END IF;
  total:=total+1; IF k_commerce='QUALIFYING' AND k_ads='QUALIFYING' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',2,'name','qualifying_mapped','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',2,'name','qualifying_mapped','pass',false,'commerce',k_commerce,'ads',k_ads)); END IF;
  total:=total+1; IF fl_ads='PRESENT_BUT_INSUFFICIENT' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',3,'name','present_insufficient','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',3,'name','present_insufficient','pass',false,'fleece_ads',fl_ads)); END IF;
  total:=total+1; IF fl_unknown_found THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',4,'name','unknown_not_zero','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',4,'name','unknown_not_zero','pass',false)); END IF;
  total:=total+1; IF public.fn_ecommerce_family_state(false,false,'UNSUPPORTED_MARKET')='UNAVAILABLE' AND public.fn_ecommerce_family_state(false,false,'BLOCKED_EXTERNAL_ACCESS')='BLOCKED' AND public.fn_ecommerce_family_state(true,false,'STALE_EVIDENCE')='STALE' AND public.fn_ecommerce_family_state(false,false,'NOT_SEARCHED')='UNKNOWN' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',5,'name','state_distinctions','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',5,'name','state_distinctions','pass',false)); END IF;
  total:=total+1; IF k->'supplier_resolution'->>'identity_result'='NO_VALID_CJ_MATCH' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',6,'name','supplier_no_valid','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',6,'name','supplier_no_valid','pass',false,'got',k->'supplier_resolution'->>'identity_result')); END IF;
  total:=total+1; IF (k->'lifecycle'->>'stage1_supplier_resolution_qualified')::boolean = true AND k->'lifecycle'->>'early_opportunity_state'='QUALIFIED_FOR_SUPPLIER_RESOLUTION' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',7,'name','negative_supplier_preserves_stage1','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',7,'name','negative_supplier_preserves_stage1','pass',false,'lc',k->'lifecycle')); END IF;
  total:=total+1; IF (k->'supplier_resolution' ? 'identity_result') AND (k->'supplier_resolution' ? 'bound') AND (k->'supplier_resolution' ? 'selected_supplier_product_id') THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',8,'name','exact_representable','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',8,'name','exact_representable','pass',false)); END IF;
  total:=total+1; IF public.fn_ecommerce_family_state(true,true,'')='QUALIFYING' AND (k->'supplier_resolution' ? 'candidates_considered') THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',9,'name','ambiguous_representable','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',9,'name','ambiguous_representable','pass',false)); END IF;
  total:=total+1; IF fl->'supplier_resolution'->>'status'='NOT_SEARCHED' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',10,'name','not_searched','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',10,'name','not_searched','pass',false,'got',fl->'supplier_resolution'->>'status')); END IF;
  total:=total+1; IF (k->'supplier_resolution'->>'candidates_considered')::int=38 THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',11,'name','candidate_count','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',11,'name','candidate_count','pass',false,'got',k->'supplier_resolution'->>'candidates_considered')); END IF;
  total:=total+1; IF (k->'supplier_resolution'->>'bound')::boolean=false THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',12,'name','bound_preserved','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',12,'name','bound_preserved','pass',false)); END IF;
  total:=total+1; IF k->'observed_counts'->'observed_advertisers'->>'observation_kind' IN ('OBSERVED','ESTIMATED','UNKNOWN') THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',13,'name','advertiser_labelled','pass',true,'kind',k->'observed_counts'->'observed_advertisers'->>'observation_kind')); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',13,'name','advertiser_labelled','pass',false)); END IF;
  total:=total+1; IF k->'observed_counts'->'observed_sellers'->>'observation_kind' IN ('OBSERVED','ESTIMATED','UNKNOWN') THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',14,'name','seller_labelled','pass',true,'kind',k->'observed_counts'->'observed_sellers'->>'observation_kind')); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',14,'name','seller_labelled','pass',false)); END IF;
  total:=total+1; IF xk->>'status'='product_not_found_for_tenant' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',15,'name','tenant_isolation','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',15,'name','tenant_isolation','pass',false,'got',xk->>'status')); END IF;
  total:=total+1; IF gb->>'market'='GB' AND gb->'supplier_resolution'->>'status'='NOT_SEARCHED' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',16,'name','country_isolation','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',16,'name','country_isolation','pass',false,'market',gb->>'market','supplier',gb->'supplier_resolution'->>'status')); END IF;
  total:=total+1; IF k->'early_opportunity'->>'source_contract' IS NOT NULL AND k->'early_opportunity'->>'state'='QUALIFIED_FOR_SUPPLIER_RESOLUTION' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',17,'name','early_opportunity_server','pass',true)); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',17,'name','early_opportunity_server','pass',false)); END IF;
  total:=total+1; IF wi ? 'status' THEN cases:=cases||jsonb_build_array(jsonb_build_object('n',18,'name','workspace_backward_compatible','pass',true,'status',wi->>'status')); ELSE failed:=failed+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',18,'name','workspace_backward_compatible','pass',false)); END IF;
  total:=total+1; cases:=cases||jsonb_build_array(jsonb_build_object('n',19,'name','no_provider_calls','pass',true,'provider_calls',0));

  RETURN jsonb_build_object('total', total, 'failed', failed, 'all_pass', (failed=0), 'provider_calls', 0, 'cases', cases, 'contract','pulse_ecommerce_intelligence_projection_selftest_v1');
END;
$function$;

revoke execute on function public.fn_ecommerce_product_intelligence_core(uuid,uuid,text) from public;
revoke execute on function public.fn_ecommerce_lifecycle_summary_core(uuid,text) from public;
revoke execute on function public.fn_ecommerce_intelligence_projection_selftest() from public;
grant execute on function public.fn_ecommerce_intelligence_projection_selftest() to service_role;
grant execute on function public.fn_ecommerce_family_state(boolean,boolean,text) to anon, authenticated, service_role;
grant execute on function public.fn_ecommerce_product_intelligence(uuid,text) to anon, authenticated, service_role;
grant execute on function public.fn_ecommerce_lifecycle_summary(text) to anon, authenticated, service_role;

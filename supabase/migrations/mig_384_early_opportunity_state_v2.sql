-- mig_384 — fn_stage1_early_opportunity_state v2: QUALIFIED_FOR_SUPPLIER_RESOLUTION is now decided by
-- the investigation-worthiness gate fn_stage1_supplier_resolution_qualified (A), NOT the launch-grade
-- bar. Lifecycle: DISCOVERED -> EMERGING -> RESEARCH_PRIORITY -> QUALIFIED_FOR_SUPPLIER_RESOLUTION
-- (-> Stage 2 -> Stage 3 -> COMMERCIALLY_VALIDATED, reported separately via fn_stage1_commercially_validated).
-- Additive, read-only. WINNER never emitted. Provider-independent. Backward-compatible keys retained.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_stage1_early_opportunity_state(p_tenant uuid, p_product uuid, p_country text, p_freshness_hours integer DEFAULT 336)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_mkt text := upper(btrim(coalesce(p_country,'')));
  ce jsonb; sr jsonb; cv jsonb;
  qualified boolean; qual_ct int; present_ct int; loc_observed boolean;
  state text; fam_names text[] := '{}'; f jsonb;
BEGIN
  ce := public.fn_stage1_commerce_evidence(p_tenant, p_product, v_mkt, p_freshness_hours);
  sr := public.fn_stage1_supplier_resolution_qualified(p_tenant, p_product, v_mkt, p_freshness_hours);
  cv := public.fn_stage1_commercially_validated(p_tenant, p_product, v_mkt);

  qualified := coalesce((sr->>'stage1_supplier_resolution_qualified')::boolean,false);
  qual_ct := coalesce((sr->>'qualifying_family_count')::int,0);
  present_ct := coalesce((sr->>'present_family_count')::int,0);
  loc_observed := (ce->'local_price'->>'class') = 'LOCAL_OBSERVED_PRICE';

  FOR f IN SELECT * FROM jsonb_array_elements(coalesce(sr->'evidence_families','[]'::jsonb)) LOOP
    IF coalesce((f->>'present')::boolean,false) THEN fam_names := array_append(fam_names, f->>'family'); END IF;
  END LOOP;

  state := CASE
    WHEN qualified THEN 'QUALIFIED_FOR_SUPPLIER_RESOLUTION'
    WHEN qual_ct >= 1 AND (present_ct >= 2 OR loc_observed) THEN 'RESEARCH_PRIORITY'
    WHEN qual_ct >= 1 THEN 'EMERGING'
    ELSE 'DISCOVERED' END;

  RETURN jsonb_build_object(
    'country', v_mkt,
    'early_opportunity_state', state,
    'qualifying_family_count', qual_ct,
    'present_family_count', present_ct,
    'momentum_family_count', qual_ct,
    'evidence_families_present', to_jsonb(fam_names),
    'evidence_families', sr->'evidence_families',
    'commerce_momentum', ce->'commerce_momentum',
    'local_price', ce->'local_price',
    'observed_sellers', ce->'observed_sellers',
    'saturation_representation', sr->>'saturation_representation',
    'supplier_resolution', sr,
    'commercial_gate', cv,
    'qualification', jsonb_build_object(
       'stage1_opportunity_qualified', qualified,
       'basis','supplier_resolution_investigation_worthiness',
       'stage1_qualification_state', CASE WHEN qualified THEN 'QUALIFIED_FOR_SUPPLIER_RESOLUTION' ELSE state END,
       'commercially_validated', coalesce((cv->>'commercially_validated')::boolean,false),
       'disqualifiers', sr->'disqualifiers'),
    'invariants', jsonb_build_object(
       'qualified_means','worth exact supplier resolution; NOT launch-ready',
       'commerce_alone_max_state','EMERGING',
       'two_independent_qualifying_families_required_for_qualified', true,
       'winner_is_post_launch_only', true,
       'launch_bar_unchanged', true,
       'one_listing_not_validated_market_price', true,
       'one_seller_not_low_competition', true,
       'unknown_stays_unknown', true),
    'lifecycle', jsonb_build_array('DISCOVERED','EMERGING','RESEARCH_PRIORITY','QUALIFIED_FOR_SUPPLIER_RESOLUTION','COMMERCIALLY_VALIDATED'),
    'contract','pulse_stage1_early_opportunity_v2');
END; $function$;
GRANT EXECUTE ON FUNCTION public.fn_stage1_early_opportunity_state(uuid, uuid, text, integer) TO authenticated, service_role;

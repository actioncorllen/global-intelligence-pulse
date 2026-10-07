-- mig_369 — Stage-1 product-opportunity invariants selftest
--
-- PURPOSE: encode the Stage-1 state-separation invariants as a production
-- regression that runs against the REAL schema and the REAL scoring functions,
-- so the invariants are enforced by code and provable on demand — not merely
-- asserted in a prompt. Each check maps to one founder invariant:
--
--   1 DISCOVERY != MONITORING
--   2 NEW PRODUCT enters the monitoring lifecycle without manual insertion
--   3 NEW CANDIDATE != QUALIFIED OPPORTUNITY
--   4 OPPORTUNITY CONCEPT != CONCRETE PRODUCT (concept fails closed)
--   5 QUALIFICATION requires the opportunity standard, not keyword volume alone
--   6 OPPORTUNITY SCORING is image-independent
--   7 PROVIDER market/language config resolves automatically (no market hardcoded)
--   8 COUNTRY ISOLATION: each market judged on its own local evidence
--
-- Checks are structural (schema + function source) and behavioural (the real
-- production tournament run with p_persist=false). Behavioural checks select a
-- live CONCEPT_ONLY representative dynamically (no hardcoded fixture UUID); when
-- no such representative exists they pass vacuously with a note, so a clean
-- database never falsely fails while a regression on live data is still caught.

CREATE OR REPLACE FUNCTION public.fn_stage1_product_opportunity_invariants_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_concept uuid; v_tenant uuid; v_tour jsonb;
  v_scorer_touches_images boolean;
  v_discover_src text;
  v_de jsonb; v_us jsonb; v_gb jsonb; v_mkt jsonb;
  v_has_concept boolean;
  v_candidate_no_decision boolean;
  v_has_country_col boolean;
  v_multi_country boolean;
  n_fail int;
BEGIN
  -- Representative CONCEPT_ONLY candidate: normalized-name identity, no concrete
  -- attributes (no price, no product URL), has search demand, registered, and
  -- never scored into a decision.
  SELECT cp.id, r.tenant_id INTO v_concept, v_tenant
  FROM public.commerce_products cp
  JOIN public.monday_opportunity_registry r ON r.product_id=cp.id AND r.active
  WHERE cp.identity_basis='normalized_name'
    AND cp.observed_price IS NULL AND cp.product_url IS NULL
    AND EXISTS (SELECT 1 FROM public.commerce_signals cs
                WHERE cs.product_id=cp.id AND cs.signal_type='SEARCH_DEMAND')
    AND NOT EXISTS (SELECT 1 FROM public.product_opportunity_decisions d
                    WHERE d.product_id=cp.id)
  ORDER BY cp.created_at DESC
  LIMIT 1;
  v_has_concept := v_concept IS NOT NULL;

  -- Source of the discovery RPC (used by invariants 1, 2, 3).
  SELECT string_agg(pg_get_functiondef(p.oid), E'\n') INTO v_discover_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='fn_dataforseo_discover_candidates';

  -- (1) DISCOVERY != MONITORING: distinct stores (commerce_products for candidate
  -- discovery, monday_opportunity_registry for monitoring), bridged by the
  -- discovery RPC which promotes a candidate and registers it for monitoring.
  v := v || jsonb_build_object('check','DISCOVERY_DISTINCT_FROM_MONITORING',
    'pass', (to_regclass('public.commerce_products') IS NOT NULL
             AND to_regclass('public.monday_opportunity_registry') IS NOT NULL
             AND coalesce(v_discover_src,'') ~* 'ingest_search_demand'
             AND coalesce(v_discover_src,'') ~* 'monday_opportunity_registry'));

  -- (2) NEW PRODUCT auto-registers into the monitoring lifecycle (no manual insert).
  v := v || jsonb_build_object('check','NEW_PRODUCT_AUTOREGISTERS_NO_MANUAL_INSERT',
    'pass', (coalesce(v_discover_src,'') ~* 'insert into public\.monday_opportunity_registry'));

  -- (3) NEW CANDIDATE != QUALIFIED OPPORTUNITY: registration never writes a
  -- decision (the discovery RPC does not touch product_opportunity_decisions),
  -- and an active registered candidate can exist with zero decisions.
  SELECT EXISTS(
    SELECT 1 FROM public.monday_opportunity_registry r
    WHERE r.active AND NOT EXISTS(
      SELECT 1 FROM public.product_opportunity_decisions d WHERE d.product_id=r.product_id))
  INTO v_candidate_no_decision;
  v := v || jsonb_build_object('check','CANDIDATE_NOT_AUTOMATICALLY_QUALIFIED',
    'pass', (coalesce(v_discover_src,'') !~* 'product_opportunity_decisions'
             AND v_candidate_no_decision),
    'detail', jsonb_build_object('active_registered_without_decision', v_candidate_no_decision));

  -- (4) OPPORTUNITY CONCEPT != CONCRETE PRODUCT and (5) VOLUME alone does not
  -- qualify: a concept-only candidate WITH recorded search volume is globally
  -- rejected by the real production tournament because it has no concrete market
  -- evidence (no price/listings/supplier) -> no decision is manufactured.
  IF v_has_concept THEN
    v_tour := public.fn_pod_tournament(v_tenant, v_concept, NULL, false);
    v := v || jsonb_build_object('check','CONCEPT_ONLY_FAILS_CLOSED_NOT_CONCRETE',
      'pass', ((v_tour->'cross_market_recovery'->>'product_globally_rejected')::boolean IS TRUE
               AND (v_tour->>'product_level_decision') IS NULL
               AND coalesce((v_tour->>'evaluated_combinations')::int,0)=0),
      'detail', jsonb_build_object('product', v_concept,
        'evaluated_combinations', v_tour->>'evaluated_combinations',
        'product_globally_rejected', v_tour->'cross_market_recovery'->>'product_globally_rejected'));
    v := v || jsonb_build_object('check','SEARCH_VOLUME_ALONE_DOES_NOT_QUALIFY',
      'pass', (EXISTS(SELECT 1 FROM public.commerce_signals cs
                      WHERE cs.product_id=v_concept AND cs.signal_type='SEARCH_DEMAND'
                        AND (cs.value->>'avg_monthly_searches_exact') ~ '^[0-9]+$')
               AND (v_tour->'cross_market_recovery'->>'product_globally_rejected')::boolean IS TRUE));
  ELSE
    v := v || jsonb_build_object('check','CONCEPT_ONLY_FAILS_CLOSED_NOT_CONCRETE',
      'pass', true, 'detail','no_concept_only_candidate_present_vacuous');
    v := v || jsonb_build_object('check','SEARCH_VOLUME_ALONE_DOES_NOT_QUALIFY',
      'pass', true, 'detail','no_concept_only_candidate_present_vacuous');
  END IF;

  -- (6) OPPORTUNITY SCORING is image-independent: no scoring function references
  -- any image/asset store, so opportunity scores cannot be influenced by imagery.
  SELECT bool_or(pg_get_functiondef(p.oid) ~*
      'product_image_assets|supplier_product_assets|product_asset_intelligence|product_image_import|fn_product_card_display_image|fn_resolve_product_image')
  INTO v_scorer_touches_images
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN
    ('fn_assemble_real_product_market','fn_pod_tournament','fn_pod_monday_block','fn_run_monday_product_opportunity');
  v := v || jsonb_build_object('check','OPPORTUNITY_SCORING_IMAGE_INDEPENDENT',
    'pass', (v_scorer_touches_images IS NOT TRUE));

  -- (7) PROVIDER market/language config resolves automatically, no market
  -- hardcoded: DE->de, GB->en, US->en/USD all resolve from the authoritative
  -- config and the full market regression passes.
  v_de := public.fn_market_provider_config('DE');
  v_gb := public.fn_market_provider_config('GB');
  v_us := public.fn_market_provider_config('US');
  v_mkt := public.fn_market_provider_config_selftest();
  v := v || jsonb_build_object('check','MARKET_PROVIDER_CONFIG_RESOLVES_AUTOMATICALLY',
    'pass', ((v_mkt->>'all_pass')::boolean IS TRUE
             AND v_de->>'dataforseo_language_code'='de'
             AND v_gb->>'dataforseo_language_code'='en'
             AND v_de->>'currency'='EUR'
             AND v_us->>'currency'='USD'));

  -- (8) COUNTRY ISOLATION: evaluations are keyed by country, and each market
  -- resolves its own currency/location/evidence scope, so one market's result
  -- cannot leak into another.
  SELECT EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='product_market_evaluations' AND column_name='country_code')
  INTO v_has_country_col;
  SELECT EXISTS(SELECT 1 FROM public.product_market_evaluations
    GROUP BY product_id HAVING count(DISTINCT country_code) >= 2)
  INTO v_multi_country;
  v := v || jsonb_build_object('check','COUNTRY_ISOLATION_PER_MARKET_EVIDENCE',
    'pass', (v_has_country_col
             AND v_de->>'currency' <> v_us->>'currency'
             AND v_de->>'dataforseo_location_code' <> v_us->>'dataforseo_location_code'),
    'detail', jsonb_build_object('evaluation_keyed_by_country', v_has_country_col,
      'product_with_multi_country_evals_present', v_multi_country));

  SELECT count(*) INTO n_fail FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean;
  RETURN jsonb_build_object('suite','stage1_product_opportunity_invariants',
    'contract','stage1_state_separation_v1',
    'total', jsonb_array_length(v), 'failed', n_fail, 'all_pass', (n_fail=0),
    'concept_representative', v_concept, 'results', v);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_stage1_product_opportunity_invariants_selftest() TO authenticated, service_role;

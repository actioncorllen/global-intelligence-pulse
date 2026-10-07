-- mig_370 — Make the image-independence regression durable (no frozen score constant)
--
-- ROOT CAUSE: fn_product_image_selftest.image_does_not_change_score asserted that
-- the nightlight's GB market_opportunity_score equals a hardcoded constant (68.2).
-- The opportunity score legitimately drifts as the evidence window advances
-- (the Monday re-scoring recomputes momentum/seasonality from current evidence),
-- so the check went red for a reason with nothing to do with images. A frozen
-- expected value is itself a fixture-value-as-proof: it rots with time and cannot
-- prove the actual invariant.
--
-- PERMANENT FIX (smallest change, correct boundary — the test assertion only):
-- prove the invariant behaviourally and value-independently: snapshot the score,
-- resolve/capture an image, re-read the score, and assert it is byte-identical
-- (delta = 0). This holds for any score at any time, so it can never rot, and it
-- complements the structural proof in mig_369
-- (OPPORTUNITY_SCORING_IMAGE_INDEPENDENT: no scoring function references any
-- image/asset store). The other nine cases are unchanged.
--
-- No asset-pipeline behaviour is modified; this touches only the selftest.

CREATE OR REPLACE FUNCTION public.fn_product_image_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_nl uuid := 'e453eed4-3de4-4ed9-b889-1275c13c0dba';
  v_hu uuid := 'cda3f71a-9947-4344-8664-13735740575f';
  v_ca uuid := (SELECT id FROM public.commerce_products WHERE user_id='7c8ddf9d-172c-4a89-a402-bb7066228b61' AND title='cool air humidifier');
  r_nl jsonb; r_hu jsonb; r_gb jsonb; r_de jsonb; r_ca jsonb;
  v_score_before numeric; v_score_after numeric;
BEGIN
  r_nl := public.fn_resolve_product_image(v_nl, 'GB');
  r_hu := public.fn_resolve_product_image(v_hu, 'GB');
  r_gb := public.fn_resolve_product_image(v_nl, 'GB');
  r_de := public.fn_resolve_product_image(v_nl, 'DE');
  r_ca := public.fn_resolve_product_image(v_ca, 'GB');
  v := v || jsonb_build_object('case','supplier_image_resolves','pass',
        (r_nl->>'image_state'='AVAILABLE' AND r_nl->>'source'='SUPPLIER_PROVIDED' AND coalesce(r_nl->>'image_url','')<>''));
  v := v || jsonb_build_object('case','marketplace_image_resolves','pass',
        (r_hu->>'image_state'='AVAILABLE' AND r_hu->>'source'='MARKETPLACE_LISTING' AND coalesce(r_hu->>'image_url','')<>''));
  v := v || jsonb_build_object('case','no_cross_product_leakage','pass',
        EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.product_id=v_hu AND a.image_url=r_hu->>'image_url'));
  v := v || jsonb_build_object('case','no_keyword_only_assignment','pass',
        NOT EXISTS (SELECT 1 FROM public.product_image_assets a WHERE a.source_provider='EBAY_BROWSE'
                    AND (coalesce(a.source_entity_id,'')='' OR coalesce(a.provenance->>'match','')<>'MATCHED')));
  v := v || jsonb_build_object('case','dataforseo_image_discovery_unchanged','pass',
        (r_hu->>'image_state'='AVAILABLE'
         AND (SELECT source_store FROM public.commerce_products WHERE id=v_hu)='dataforseo'));
  v := v || jsonb_build_object('case','gb_de_same_product_image','pass', (r_gb->>'image_url' = r_de->>'image_url'));

  -- Durable image-independence: resolving/capturing an image must leave the
  -- opportunity score byte-identical. Value-independent, so it never rots.
  v_score_before := (SELECT round(market_opportunity_score,4) FROM public.product_market_evaluations
          WHERE product_id=v_nl AND country_code='GB' AND coalesce(is_fixture,false)=false
          ORDER BY evaluation_ts DESC LIMIT 1);
  PERFORM public.fn_resolve_product_image(v_nl, 'GB');
  v_score_after := (SELECT round(market_opportunity_score,4) FROM public.product_market_evaluations
          WHERE product_id=v_nl AND country_code='GB' AND coalesce(is_fixture,false)=false
          ORDER BY evaluation_ts DESC LIMIT 1);
  v := v || jsonb_build_object('case','image_does_not_change_score','pass',
        (v_score_before IS NOT DISTINCT FROM v_score_after),
        'detail', jsonb_build_object('score_before',v_score_before,'score_after',v_score_after));

  v := v || jsonb_build_object('case','image_does_not_change_decision','pass',
        (SELECT count(*) FROM public.product_opportunity_decisions
         WHERE tenant_id='7c8ddf9d-172c-4a89-a402-bb7066228b61' AND coalesce(is_fixture,false)=false) >= 10);
  v := v || jsonb_build_object('case','missing_image_not_fabricated','pass',
        (r_ca->>'image_url' IS NULL AND r_ca->>'image_state' IN ('PENDING_RESEARCH','UNAVAILABLE_NO_SOURCE')));
  v := v || jsonb_build_object('case','no_credentials_in_assets','pass',
        NOT EXISTS (SELECT 1 FROM public.product_image_assets a
                    WHERE a.image_url ~* 'client_secret|access_token|apikey|service_role'
                       OR a.provenance::text ~* 'client_secret|access_token|service_role'));
  RETURN jsonb_build_object('suite','product_image_coverage',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

GRANT EXECUTE ON FUNCTION public.fn_product_image_selftest() TO authenticated, service_role;

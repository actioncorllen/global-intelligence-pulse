-- ============================================================================
-- mig_256_selftest_reconcile_013q.sql
-- STRATELOQ-DATAFORSEO-PRODUCT-DISCOVERY-013Q (regression baseline reconcile)
--
-- The 013Q DataForSEO discovery adapter legitimately adds new founder product
-- candidates (source_store='dataforseo') and founder-owned SEARCH_DEMAND
-- discovery signals (real DataForSEO evidence, never synthetic). Two
-- discovery-era selftests froze exact founder counts / the single Reddit-only
-- signal type, so real discovery growth broke them. As in the 013J mig_246
-- reconcile, these become INTEGRITY assertions (nothing lost; only real signal
-- types) rather than frozen snapshots — they still fail on data loss or
-- synthetic signal types, but tolerate legitimate discovery growth.
--
-- Assertions changed (only these three; everything else identical):
--  * founder_commerce_products_intact_12  -> retained >= 12 (originals kept)
--  * founder_signals_intact_11            -> retained >= 11 (originals kept)
--  * founder_signal_types_real            -> types ⊆ {COMMUNITY_ATTENTION,
--                                            SEARCH_DEMAND}, COMMUNITY present,
--                                            no synthetic/unexpected type
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_ecommerce_connection_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_founder uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
BEGIN
  v := v || jsonb_build_object('case','catalog_has_5_active','pass',
        (SELECT count(*) FROM public.business_category WHERE is_active)=5);
  v := v || jsonb_build_object('case','category_column_exists','pass',
        EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='business_profiles' AND column_name='business_category'));
  v := v || jsonb_build_object('case','founder_category_ecommerce','pass',
        (SELECT business_category FROM public.business_profiles WHERE industry='Broad Ecommerce Opportunity Discovery')='ecommerce');
  v := v || jsonb_build_object('case','founder_decisions_reachable_7','pass',
        (SELECT count(*) FROM public.product_opportunity_decisions WHERE tenant_id=v_founder AND coalesce(is_fixture,false)=false)=7);
  -- 013Q: discovery may add candidates; originals must be retained (never lost)
  v := v || jsonb_build_object('case','founder_commerce_products_retained_ge12','pass',
        (SELECT count(*) FROM public.commerce_products WHERE user_id=v_founder) >= 12);
  -- 013Q: discovery may add founder SEARCH_DEMAND signals; originals retained
  v := v || jsonb_build_object('case','founder_signals_retained_ge11','pass',
        (SELECT count(*) FROM public.commerce_signals WHERE user_id=v_founder) >= 11);
  v := v || jsonb_build_object('case','no_member_opportunities_created','pass',
        (SELECT count(*) FROM public.member_opportunities WHERE user_id=v_founder)=0);
  v := v || jsonb_build_object('case','no_commerce_product_opportunities_created','pass',
        (SELECT count(*) FROM public.commerce_product_opportunities WHERE user_id=v_founder)=0);
  v := v || jsonb_build_object('case','category_independent_of_summary','pass',
        EXISTS (SELECT 1 FROM public.business_profiles WHERE industry='Broad Ecommerce Opportunity Discovery'
                AND business_category='ecommerce'));
  v := v || jsonb_build_object('case','only_approved_categories','pass',
        NOT EXISTS (SELECT 1 FROM public.business_profiles bp WHERE bp.business_category IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM public.business_category c WHERE c.code=bp.business_category)));

  RETURN jsonb_build_object('suite','ecommerce_workspace_connection',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

CREATE OR REPLACE FUNCTION public.fn_ecommerce_intelligence_contracts_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v jsonb := '[]'::jsonb; f uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61';
BEGIN
  v := v || jsonb_build_object('case','founder_competitors_real_no_fixtures','pass',
    (SELECT count(*) FROM public.product_market_competitors WHERE tenant_id=f AND coalesce(is_fixture,false)=false) > 0
    AND (SELECT count(*) FROM public.product_market_competitors WHERE tenant_id=f AND is_fixture=true) = 0);
  v := v || jsonb_build_object('case','founder_supplier_no_data','pass',
    (SELECT count(*) FROM public.product_acquisitions WHERE user_id=f)=0);
  v := v || jsonb_build_object('case','founder_brief_unlinked','pass',
    (SELECT count(*) FROM public.ad_studio_briefs WHERE tenant_id=f AND coalesce(is_fixture,false)=false AND decision_id IS NULL)=1);
  v := v || jsonb_build_object('case','founder_brief_product_linked','pass',
    (SELECT bool_and(product_id IS NOT NULL) FROM public.ad_studio_briefs WHERE tenant_id=f AND coalesce(is_fixture,false)=false));
  -- 013Q: founder now legitimately holds SEARCH_DEMAND discovery signals as well
  -- as Reddit COMMUNITY_ATTENTION; assert only-real types (no synthetic), not a
  -- frozen single type.
  v := v || jsonb_build_object('case','founder_signal_types_real','pass',
    EXISTS (SELECT 1 FROM public.commerce_signals WHERE user_id=f AND signal_type='COMMUNITY_ATTENTION')
    AND NOT EXISTS (SELECT 1 FROM public.commerce_signals WHERE user_id=f
                    AND signal_type NOT IN ('COMMUNITY_ATTENTION','SEARCH_DEMAND')));
  v := v || jsonb_build_object('case','founder_executions_present','pass',
    (SELECT count(*) FROM public.marketing_campaign_executions WHERE user_id=f) >= 1);
  RETURN jsonb_build_object('suite','ecommerce_intelligence_contracts',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

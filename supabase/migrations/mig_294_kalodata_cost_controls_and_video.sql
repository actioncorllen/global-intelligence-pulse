-- ============================================================================
-- mig_294_kalodata_cost_controls_and_video.sql
-- STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A (Phase 3 — account active:
--   confirmed cost model, cost controls, video-research registration)
--
-- ACCOUNT STATUS UPDATE (verified by the account owner from the authenticated
-- Kalodata Open Center dashboard, 2026-11-11):
--   * Open Center account is ACTIVE (no Enterprise subscription / new purchase needed).
--   * Balance 14.1 credits. 5 historical calls cost 0.5 credits total.
--   * Confirmed consumption: 0.1 credits per call for Product Rank and Product Detail.
--   * Regenerating a new API key IMMEDIATELY invalidates the previous one — so the
--     existing key must be reused, never regenerated.
--
-- This migration is additive, verified-only, makes NO external/API call, deploys
-- nothing, and fabricates no request/response field schema. It:
--   1) refreshes the KALODATA/PRODUCT_INTELLIGENCE capability with the CONFIRMED cost
--      + account state (availability stays SOURCE_UNSUPPORTED until the API key is
--      installed as a Supabase Edge Function secret — see §Supabase secret config in
--      docs/STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A.md);
--   2) registers the Kalodata VIDEO module as research intelligence, with video MEDIA
--      rights explicitly UNRESOLVED (ingestion/display BLOCKED, never ad/storefront
--      eligible) — preserving the research-only media posture of mig_292;
--   3) adds a cost-control layer: a usage ledger + a singleton policy that DEFAULTS TO
--      calls_disabled, and a pre-call budget gate that fails closed — so no chargeable
--      call can occur without an explicit, approved policy change.
-- ============================================================================

-- 1) refresh product-intelligence capability with CONFIRMED cost + account state ----
UPDATE public.provider_capability_registry
   SET capability = capability || jsonb_build_object(
         'per_call_credits', 0.1,
         'per_call_credits_state', 'CONFIRMED_RANK_AND_DETAIL',
         'account_state', 'ACTIVE_OPEN_CENTER',
         'enterprise_required', false,
         'last_known_balance', 14.1,
         'balance_observed_at', '2026-11-11',
         'key_rotation_warning', 'Regenerating a new API key immediately invalidates the previous one; reuse the existing key, never regenerate.',
         'connection_state', 'ACCOUNT_ACTIVE_SUPABASE_SECRET_INSTALL_REQUIRED'),
       limitations = 'Account ACTIVE (Open Center; no Enterprise purchase required). Research intelligence for '
         || 'authenticated Product Discovery only; NOT advertising/storefront rights. Credit-metered: 0.1 credits/call '
         || '(Rank, Detail). Live use requires the existing API key installed as a Supabase Edge Function secret '
         || '(KALODATA_API_KEY) and the verified request/response field schema from Kalodata partner docs. '
         || 'Does NOT cover every Strateloq market (verified 15-country coverage).',
       updated_at = now()
 WHERE source = 'KALODATA' AND evidence_category = 'PRODUCT_INTELLIGENCE';

-- 2) register the Kalodata VIDEO module as research intelligence (media rights UNRESOLVED)
DELETE FROM public.provider_capability_registry
 WHERE source = 'KALODATA' AND evidence_category = 'VIDEO_RESEARCH';

INSERT INTO public.provider_capability_registry
  (source, evidence_category, market, availability, coverage_type, capability, limitations, last_verified_at, updated_at)
SELECT
  'KALODATA', 'VIDEO_RESEARCH', m, 'SOURCE_UNSUPPORTED', 'VIDEO_PERFORMANCE',
  jsonb_build_object(
    'provider', 'Kalodata',
    'provider_market_covered', true,
    'per_market_video_coverage', 'ACCOUNT_LEVEL_ASSUMED_CONFIRM_BEFORE_USE',
    'module', 'Video',
    'data_type', 'VIDEO_PERFORMANCE_INTELLIGENCE',       -- metrics about videos (research data)
    'video_media_rights', 'UNRESOLVED',                   -- rights to store/display the video media itself
    'media_ingestion', 'BLOCKED_PENDING_VIDEO_RIGHTS',
    'research_only', true,
    'ad_eligible', false,
    'storefront_eligible', false,
    'per_call_credits', 'UNCONFIRMED',                    -- no video call observed yet; do not assume 0.1
    'field_schema_state', 'PENDING_PARTNER_DOCS_AND_CREDENTIALS',
    'connection_state', 'ACCOUNT_ACTIVE_SUPABASE_SECRET_INSTALL_REQUIRED'
  ),
  'Kalodata Video module. Video PERFORMANCE INTELLIGENCE (metrics) may be used for research display under '
  || 'the same research-only terms as product intelligence. Video MEDIA RIGHTS (storing/displaying the actual '
  || 'video files or thumbnails) are UNRESOLVED: media ingestion/display is BLOCKED and NEVER ad/storefront '
  || 'eligible until separate video rights are verified. Per-call credit cost for video endpoints is not yet '
  || 'confirmed. Live use requires KALODATA_API_KEY (Supabase secret) + verified field schema.',
  '2026-11-11T00:00:00Z'::timestamptz, now()
FROM unnest(ARRAY[
  'US','GB','DE','FR','ES','IT','MX','BR','ID','MY','TH','VN','PH','SG','JP'
]) AS m;

-- 3a) usage ledger (service-role; RLS deny-all) --------------------------------------
CREATE TABLE IF NOT EXISTS public.kalodata_api_usage_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid,
  endpoint text NOT NULL,                 -- e.g. 'product/rank' | 'product/detail' | 'video/rank'
  market text,
  credits_spent numeric NOT NULL DEFAULT 0,
  call_ts timestamptz NOT NULL DEFAULT now(),
  provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_fixture boolean NOT NULL DEFAULT false
);
ALTER TABLE public.kalodata_api_usage_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.kalodata_api_usage_ledger FROM anon, authenticated;
CREATE INDEX IF NOT EXISTS kalodata_api_usage_ledger_ts ON public.kalodata_api_usage_ledger (call_ts DESC);

-- 3b) singleton cost policy (DEFAULT: calls disabled -> fail closed) ------------------
CREATE TABLE IF NOT EXISTS public.kalodata_cost_policy (
  id boolean PRIMARY KEY DEFAULT true,
  calls_enabled boolean NOT NULL DEFAULT false,        -- no chargeable call until an approved flip to true
  per_call_credits numeric NOT NULL DEFAULT 0.1,       -- confirmed for rank/detail
  max_credits_per_run numeric NOT NULL DEFAULT 2.0,    -- hard cap per batch (approve before raising)
  last_known_balance numeric,
  balance_observed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kalodata_cost_policy_singleton CHECK (id = true)
);
ALTER TABLE public.kalodata_cost_policy ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.kalodata_cost_policy FROM anon, authenticated;
INSERT INTO public.kalodata_cost_policy (id, calls_enabled, per_call_credits, max_credits_per_run, last_known_balance, balance_observed_at)
VALUES (true, false, 0.1, 2.0, 14.1, '2026-11-11T00:00:00Z'::timestamptz)
ON CONFLICT (id) DO NOTHING;

-- 3c) pre-call budget gate (fail closed) ---------------------------------------------
--     A live Kalodata call path MUST pass this before spending credits. It denies
--     unless calls are explicitly enabled AND the estimate is within the per-run cap
--     AND within the last-known balance. Default policy (calls_enabled=false) => deny.
CREATE OR REPLACE FUNCTION public.fn_kalodata_budget_precheck(p_estimated_calls integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE pol public.kalodata_cost_policy%rowtype; v_calls int := greatest(coalesce(p_estimated_calls,0),0); v_est numeric; v_reason text;
BEGIN
  SELECT * INTO pol FROM public.kalodata_cost_policy WHERE id = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'NO_POLICY'); END IF;
  v_est := round(v_calls * pol.per_call_credits, 4);
  v_reason := CASE
    WHEN v_calls = 0 THEN 'NO_CALLS_REQUESTED'
    WHEN NOT pol.calls_enabled THEN 'CALLS_DISABLED_PENDING_APPROVAL'
    WHEN v_est > pol.max_credits_per_run THEN 'OVER_PER_RUN_CAP'
    WHEN pol.last_known_balance IS NOT NULL AND v_est > pol.last_known_balance THEN 'OVER_LAST_KNOWN_BALANCE'
    ELSE 'OK' END;
  RETURN jsonb_build_object(
    'allowed', (v_reason = 'OK'),
    'reason', v_reason,
    'estimated_calls', v_calls,
    'estimated_credits', v_est,
    'per_call_credits', pol.per_call_credits,
    'max_credits_per_run', pol.max_credits_per_run,
    'calls_enabled', pol.calls_enabled,
    'last_known_balance', pol.last_known_balance,
    'note', 'fail-closed budget gate; a live call path must pass this before spending credits');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_budget_precheck(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_budget_precheck(integer) TO authenticated, service_role;

-- 3d) usage recorder (service-role) --------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_kalodata_record_usage(
  p_endpoint text, p_market text, p_credits numeric, p_provenance jsonb DEFAULT '{}'::jsonb, p_tenant uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v_id uuid;
BEGIN
  IF coalesce(p_endpoint,'')='' THEN RETURN jsonb_build_object('status','no_endpoint'); END IF;
  INSERT INTO public.kalodata_api_usage_ledger(tenant_id, endpoint, market, credits_spent, provenance)
  VALUES (p_tenant, p_endpoint, nullif(btrim(p_market),''), coalesce(p_credits,0), coalesce(p_provenance,'{}'::jsonb))
  RETURNING id INTO v_id;
  UPDATE public.kalodata_cost_policy
     SET last_known_balance = greatest(coalesce(last_known_balance,0) - coalesce(p_credits,0), 0), updated_at = now()
   WHERE id = true AND last_known_balance IS NOT NULL;
  RETURN jsonb_build_object('status','recorded','id',v_id);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_record_usage(text,text,numeric,jsonb,uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_record_usage(text,text,numeric,jsonb,uuid) TO service_role;

-- 4) category-aware market gate (adds a VIDEO-aware overload; 1-arg kept for compat) --
CREATE OR REPLACE FUNCTION public.fn_kalodata_market_supported(p_country_code text, p_evidence_category text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  SELECT CASE
    WHEN r.source IS NULL THEN
      jsonb_build_object('country_code', upper(coalesce(p_country_code,'')),
        'evidence_category', upper(coalesce(p_evidence_category,'')),
        'provider_covered', false, 'availability', 'NOT_COVERED', 'sourceable_now', false,
        'note', 'Kalodata does not cover this market/category (verified coverage)')
    ELSE
      jsonb_build_object('country_code', upper(p_country_code),
        'evidence_category', upper(p_evidence_category),
        'provider_covered', true, 'availability', r.availability,
        'sourceable_now', (r.availability = 'AVAILABLE'),
        'connection_state', r.capability->>'connection_state',
        'media_rights', r.capability->>'video_media_rights',
        'note', CASE WHEN r.availability = 'AVAILABLE' THEN 'Kalodata covered and connected'
                     ELSE 'Kalodata covers this market; Strateloq activation pending credentials + verified field schema' END)
  END
  FROM (SELECT NULL::text AS source) z
  LEFT JOIN public.provider_capability_registry r
    ON r.source = 'KALODATA' AND r.evidence_category = upper(coalesce(p_evidence_category,''))
   AND r.market = upper(coalesce(p_country_code,''));
$function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_market_supported(text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_market_supported(text,text) TO authenticated, service_role;

-- 5) refresh the Phase-2 provider selftest: Kalodata is now legitimately registered
--    under TWO research categories (PRODUCT_INTELLIGENCE + VIDEO_RESEARCH). Update the
--    "research categories only" invariant to allow both while still forbidding any
--    commercial category (ADVERTISING/SUPPLIER/MARKETPLACE/SOCIAL_VIDEO/etc). All other
--    Phase-2 assertions are re-stated unchanged. (House style: later migration redefines.)
CREATE OR REPLACE FUNCTION public.fn_kalodata_provider_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE
  v jsonb := '[]'::jsonb;
  v_covered text[] := ARRAY['US','GB','DE','FR','ES','IT','MX','BR','ID','MY','TH','VN','PH','SG','JP'];
  v_uncovered text[] := ARRAY['CA','NL','IE','AT','BE','CH','PL','AU','HK'];
  v_reg_markets text[]; v_other_before int;
BEGIN
  SELECT array_agg(market ORDER BY market) INTO v_reg_markets
  FROM public.provider_capability_registry
  WHERE source='KALODATA' AND evidence_category='PRODUCT_INTELLIGENCE';

  v := v || jsonb_build_object('case','verified_15_markets_registered','pass',
        (SELECT array_agg(x ORDER BY x) FROM unnest(v_reg_markets) x)
          = (SELECT array_agg(x ORDER BY x) FROM unnest(v_covered) x));
  v := v || jsonb_build_object('case','covered_markets_pending_credential','pass',
        NOT EXISTS (SELECT 1 FROM unnest(v_covered) c
                    WHERE (public.fn_kalodata_market_supported(c)->>'provider_covered')::boolean IS DISTINCT FROM true
                       OR (public.fn_kalodata_market_supported(c)->>'sourceable_now')::boolean IS DISTINCT FROM false));
  v := v || jsonb_build_object('case','uncovered_markets_not_claimed','pass',
        NOT EXISTS (SELECT 1 FROM unnest(v_uncovered) u
                    WHERE (public.fn_kalodata_market_supported(u)->>'provider_covered')::boolean IS DISTINCT FROM false));
  v := v || jsonb_build_object('case','no_kalodata_available_without_credentials','pass',
        NOT EXISTS (SELECT 1 FROM public.provider_capability_registry
                    WHERE source='KALODATA' AND availability='AVAILABLE'));
  SELECT count(*) INTO v_other_before FROM public.provider_capability_registry
  WHERE source IN ('DATAFORSEO','EBAY','CJ','META_AD_LIBRARY');
  v := v || jsonb_build_object('case','existing_providers_untouched','pass', (v_other_before > 0));
  -- UPDATED: Kalodata registered ONLY under research categories (never commercial)
  v := v || jsonb_build_object('case','registered_only_research_categories','pass',
        NOT EXISTS (SELECT 1 FROM public.provider_capability_registry
                    WHERE source='KALODATA' AND evidence_category NOT IN ('PRODUCT_INTELLIGENCE','VIDEO_RESEARCH')));
  v := v || jsonb_build_object('case','field_schema_marked_pending','pass',
        NOT EXISTS (SELECT 1 FROM public.provider_capability_registry
                    WHERE source='KALODATA'
                      AND coalesce(capability->>'field_schema_state','') <> 'PENDING_PARTNER_DOCS_AND_CREDENTIALS'));

  RETURN jsonb_build_object('suite','kalodata_provider_registry',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_provider_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_provider_selftest() TO service_role;

-- 6) selftest ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_kalodata_cost_video_selftest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE v jsonb := '[]'::jsonb; v_pre_default jsonb; v_pre_on jsonb; v_pre_cap jsonb; v_pre_bal jsonb; v_rec jsonb; v_fix uuid;
BEGIN
  -- a) confirmed product-intelligence cost recorded (0.1), enterprise not required
  v := v || jsonb_build_object('case','pi_cost_confirmed_no_enterprise','pass',
        EXISTS (SELECT 1 FROM public.provider_capability_registry
                WHERE source='KALODATA' AND evidence_category='PRODUCT_INTELLIGENCE'
                  AND (capability->>'per_call_credits')::numeric = 0.1
                  AND (capability->>'enterprise_required')::boolean = false));
  -- b) video registered as research intelligence with UNRESOLVED media rights, not ad/storefront
  v := v || jsonb_build_object('case','video_media_rights_unresolved_gated','pass',
        (SELECT bool_and(capability->>'video_media_rights'='UNRESOLVED'
                         AND (capability->>'ad_eligible')::boolean=false
                         AND (capability->>'storefront_eligible')::boolean=false
                         AND capability->>'media_ingestion'='BLOCKED_PENDING_VIDEO_RIGHTS')
         FROM public.provider_capability_registry WHERE source='KALODATA' AND evidence_category='VIDEO_RESEARCH'));
  -- c) budget gate FAILS CLOSED by default (calls disabled) -> no unapproved chargeable calls
  v_pre_default := public.fn_kalodata_budget_precheck(5);
  v := v || jsonb_build_object('case','budget_gate_fails_closed_by_default','pass',
        ((v_pre_default->>'allowed')::boolean = false AND v_pre_default->>'reason'='CALLS_DISABLED_PENDING_APPROVAL'));
  -- d) when enabled within cap+balance -> allowed; over cap -> denied; over balance -> denied
  UPDATE public.kalodata_cost_policy SET calls_enabled=true, max_credits_per_run=2.0, last_known_balance=14.1 WHERE id=true;
  v_pre_on  := public.fn_kalodata_budget_precheck(5);     -- 0.5 credits <= 2.0 cap, <= 14.1 balance
  v_pre_cap := public.fn_kalodata_budget_precheck(25);    -- 2.5 credits > 2.0 cap
  UPDATE public.kalodata_cost_policy SET last_known_balance=0.2 WHERE id=true;
  v_pre_bal := public.fn_kalodata_budget_precheck(5);     -- 0.5 credits > 0.2 balance
  UPDATE public.kalodata_cost_policy SET calls_enabled=false, last_known_balance=14.1 WHERE id=true;  -- restore default
  v := v || jsonb_build_object('case','budget_gate_allows_within_limits','pass', ((v_pre_on->>'allowed')::boolean = true));
  v := v || jsonb_build_object('case','budget_gate_denies_over_cap','pass',
        ((v_pre_cap->>'allowed')::boolean = false AND v_pre_cap->>'reason'='OVER_PER_RUN_CAP'));
  v := v || jsonb_build_object('case','budget_gate_denies_over_balance','pass',
        ((v_pre_bal->>'allowed')::boolean = false AND v_pre_bal->>'reason'='OVER_LAST_KNOWN_BALANCE'));
  -- e) ledger records a (fixture) usage then cleans up
  v_rec := public.fn_kalodata_record_usage('product/rank','US',0.1, jsonb_build_object('fixture',true));
  v_fix := (v_rec->>'id')::uuid;
  v := v || jsonb_build_object('case','usage_ledger_records','pass', (v_rec->>'status'='recorded' AND v_fix IS NOT NULL));
  DELETE FROM public.kalodata_api_usage_ledger WHERE id = v_fix;
  UPDATE public.kalodata_cost_policy SET last_known_balance=14.1, updated_at=now() WHERE id=true;  -- restore balance after fixture
  -- f) category-aware gate: video covered-but-pending for US, not covered for CA
  v := v || jsonb_build_object('case','video_gate_us_covered_pending','pass',
        ((public.fn_kalodata_market_supported('US','VIDEO_RESEARCH')->>'provider_covered')::boolean = true
         AND (public.fn_kalodata_market_supported('US','VIDEO_RESEARCH')->>'sourceable_now')::boolean = false));
  v := v || jsonb_build_object('case','video_gate_ca_not_covered','pass',
        ((public.fn_kalodata_market_supported('CA','VIDEO_RESEARCH')->>'provider_covered')::boolean = false));
  -- g) no fabricated field schema asserted anywhere for Kalodata
  v := v || jsonb_build_object('case','field_schema_still_pending','pass',
        NOT EXISTS (SELECT 1 FROM public.provider_capability_registry
                    WHERE source='KALODATA' AND coalesce(capability->>'field_schema_state','') <> 'PENDING_PARTNER_DOCS_AND_CREDENTIALS'));

  RETURN jsonb_build_object('suite','kalodata_cost_video',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
EXCEPTION WHEN OTHERS THEN
  UPDATE public.kalodata_cost_policy SET calls_enabled=false, last_known_balance=14.1 WHERE id=true;
  RETURN jsonb_build_object('suite','kalodata_cost_video','status','error','error',SQLERRM);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_kalodata_cost_video_selftest() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_kalodata_cost_video_selftest() TO service_role;

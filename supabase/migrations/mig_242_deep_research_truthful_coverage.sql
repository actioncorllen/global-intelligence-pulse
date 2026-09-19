-- STRATELOQ-DEEP-MULTI-SOURCE-PRODUCT-INTELLIGENCE-013I
-- Additive, truthful multi-source research infrastructure. NO synthetic evidence, NO external
-- provider calls, NO scoring change, NO Lovable/publish/payment. Makes "fully researched" honest:
--   * a server-owned deep-research-run + per-source-attempt ledger model (for the future
--     orchestrator to populate on real runs),
--   * registers TikTok as a launch-critical evidence category that is currently BLOCKED
--     (external provider required) — the gap is explicit and extensible, never faked,
--   * a pure minimum-evidence GRADE gate (>=3 / >=4 independent corroborating categories +
--     evidence-confidence thresholds), reusing the canonical evidence-confidence concept,
--   * a confidence-SEMANTICS fix separating opportunity attractiveness from evidence confidence
--     (no DB band renamed), and
--   * an authenticated, auth.uid()-scoped research-COVERAGE read contract that truthfully
--     distinguishes NOT_SEARCHED from SEARCHED_NO_EVIDENCE, derived live from EXISTING evidence.
-- The real per-product-market provider execution remains a cost-authorized manual/scheduled n8n
-- action (probes + the weekly Monday orchestrator); nothing here fabricates it.

-- ---------------------------------------------------------------------------
-- Phase F: register TikTok as a launch-critical evidence category, currently blocked.
-- Explicit gap, not a fake integration. evidence_category SOCIAL_VIDEO.
-- ---------------------------------------------------------------------------
INSERT INTO public.provider_capability_registry
  (source, evidence_category, market, availability, coverage_type, capability, limitations, last_verified_at, updated_at)
SELECT 'TIKTOK','SOCIAL_VIDEO','*','SOURCE_UNSUPPORTED','GLOBAL','{}'::jsonb,
   'EXTERNAL_PROVIDER_REQUIRED: no authorized TikTok product/trend/creative/ad intelligence provider connected. Launch-critical gap. Do not scrape TikTok in violation of access controls.',
   now(), now()
WHERE NOT EXISTS (SELECT 1 FROM public.provider_capability_registry WHERE source='TIKTOK');

-- ---------------------------------------------------------------------------
-- Phase C/D: deep-research-run + per-source-attempt ledger (server-owned, RLS deny-all).
-- Empty until the real orchestrator populates it; the read contract derives current truth
-- from existing evidence when no run row exists.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.commerce_research_run (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,                       -- auth.uid()
  product_id uuid NOT NULL,
  market text NOT NULL,                          -- country_code (product research market, NOT business country)
  status text NOT NULL DEFAULT 'RESEARCHING'
    CHECK (status IN ('RESEARCHING','COMPLETE','PARTIAL','PARTIAL_SOURCE_FAILURE','PARTIAL_SOURCE_UNAVAILABLE','INSUFFICIENT_EVIDENCE')),
  sources_expected integer NOT NULL DEFAULT 0,
  sources_attempted integer NOT NULL DEFAULT 0,
  sources_with_evidence integer NOT NULL DEFAULT 0,
  sources_no_data integer NOT NULL DEFAULT 0,
  sources_unsupported integer NOT NULL DEFAULT 0,
  sources_failed integer NOT NULL DEFAULT 0,
  independent_categories integer NOT NULL DEFAULT 0,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  freshness_at timestamptz,
  provenance jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS commerce_research_run_tenant_idx ON public.commerce_research_run(tenant_id, product_id, market);
ALTER TABLE public.commerce_research_run ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commerce_research_run FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.commerce_research_run IS
 'Deep-research run per (tenant, product, market). Server-owned, RLS deny-all; written only by service_role/orchestrator. Records which evidence sources were attempted so "fully researched" is truthful. market is the product research market, never the business home country.';

CREATE TABLE IF NOT EXISTS public.commerce_research_source_attempt (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES public.commerce_research_run(id) ON DELETE CASCADE,
  evidence_category text NOT NULL,               -- COMMUNITY|SEARCH_DEMAND|ADVERTISING|MARKETPLACE|SUPPLIER|SOCIAL_VIDEO
  source text,                                   -- provider name (nullable; category is authoritative)
  state text NOT NULL DEFAULT 'NOT_SEARCHED'
    CHECK (state IN ('NOT_SEARCHED','SEARCHING','SEARCHED_EVIDENCE_FOUND','SEARCHED_NO_EVIDENCE','NOT_APPLICABLE','UNSUPPORTED_MARKET','SOURCE_UNAVAILABLE','BLOCKED_EXTERNAL_ACCESS','SOURCE_FAILED')),
  observed_at timestamptz,
  evidence_ref jsonb,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commerce_research_source_attempt_uk UNIQUE (run_id, evidence_category)
);
ALTER TABLE public.commerce_research_source_attempt ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commerce_research_source_attempt FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.commerce_research_source_attempt IS
 'Per-source attempt ledger for a research run. NOT_SEARCHED is never equivalent to SEARCHED_NO_EVIDENCE. RLS deny-all; service_role only.';

-- ---------------------------------------------------------------------------
-- Phase L: confidence-semantics fix (pure). Separates OPPORTUNITY attractiveness (band)
-- from EVIDENCE confidence. Does NOT rename any DB band. Flags a misleading pairing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_opportunity_labels(p_band text, p_evidence_confidence text)
RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'opportunity_label', CASE upper(coalesce(p_band,''))
        WHEN 'HIGH_CONFIDENCE_TEST' THEN 'Strong test candidate'
        WHEN 'STRONG_TEST'          THEN 'Strong test candidate'
        WHEN 'TRENDING_WATCH'       THEN 'Trending — watch'
        WHEN 'WATCH'                THEN 'Watch'
        ELSE initcap(replace(lower(coalesce(p_band,'unclassified')),'_',' ')) END,
    'evidence_confidence_label', CASE upper(coalesce(p_evidence_confidence,'NONE'))
        WHEN 'HIGH'     THEN 'Evidence: high'
        WHEN 'MODERATE' THEN 'Evidence: moderate'
        WHEN 'LOW'      THEN 'Evidence: low — not yet corroborated'
        WHEN 'VERY_LOW' THEN 'Evidence: very low'
        ELSE 'Evidence: not yet gathered' END,
    -- true when the raw band NAME implies confidence but evidence confidence is NONE/LOW/VERY_LOW
    'label_evidence_mismatch',
      (upper(coalesce(p_band,'')) LIKE '%HIGH_CONFIDENCE%'
       AND upper(coalesce(p_evidence_confidence,'NONE')) IN ('NONE','VERY_LOW','LOW')),
    'note','Opportunity attractiveness and evidence confidence are separate dimensions; never surface a band name that implies confidence when evidence confidence is low.');
$function$;

-- ---------------------------------------------------------------------------
-- Phase M: minimum evidence GRADE gate (pure). Reuses the canonical evidence-confidence LEVEL.
--   STRONG_EVIDENCE_BACKED: >=3 independent corroborating categories AND confidence >= MODERATE.
--   HIGH_CONFIDENCE:        >=4 independent categories AND confidence >= HIGH AND no launch-critical omission.
-- Launch-critical source families: ADVERTISING (Meta) and SOCIAL_VIDEO (TikTok). If either is
-- omitted/blocked for the market, HIGH_CONFIDENCE is not claimable and the gap is explicit.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_evidence_grade(
  p_independent_categories integer, p_evidence_confidence_level text, p_launch_critical_gap boolean)
RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'grade', CASE
      WHEN coalesce(p_independent_categories,0) >= 4
           AND upper(coalesce(p_evidence_confidence_level,'')) = 'HIGH'
           AND NOT coalesce(p_launch_critical_gap,true) THEN 'HIGH_CONFIDENCE'
      WHEN coalesce(p_independent_categories,0) >= 3
           AND upper(coalesce(p_evidence_confidence_level,'')) IN ('MODERATE','HIGH') THEN 'STRONG_EVIDENCE_BACKED'
      WHEN coalesce(p_independent_categories,0) >= 2 THEN 'DEVELOPING_EVIDENCE'
      WHEN coalesce(p_independent_categories,0) = 1 THEN 'SINGLE_SOURCE'
      ELSE 'INSUFFICIENT_EVIDENCE' END,
    'independent_categories', coalesce(p_independent_categories,0),
    'evidence_confidence_level', upper(coalesce(p_evidence_confidence_level,'NONE')),
    'launch_critical_gap', coalesce(p_launch_critical_gap,true),
    'standard','STRONG>=3 categories & confidence>=MODERATE; HIGH_CONFIDENCE>=4 & confidence>=HIGH & no launch-critical omission');
$function$;

-- ---------------------------------------------------------------------------
-- Phase A/D/J/Q: truthful research-COVERAGE read contract. Authenticated, auth.uid()-scoped.
-- For each of the caller's real product decisions, derives per-category source-attempt states
-- LIVE from existing product_market_evaluations evidence + the provider registry (no data
-- written, no provider called), then applies the grade + labels. Distinguishes NOT_SEARCHED
-- from SEARCHED_NO_EVIDENCE and marks launch-critical gaps (TikTok/Meta) explicitly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ecommerce_research_coverage()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','unauthenticated'); END IF;

  SELECT coalesce(jsonb_agg(row ORDER BY (row->>'opportunity_score')::numeric DESC NULLS LAST), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'decision_id', d.id,
      'product_id', d.product_id,
      'product_title', cp.title,
      'market', d.country_code,
      'opportunity_score', d.product_opportunity_score,
      'opportunity_band', d.opportunity_band,
      'evidence_confidence', d.overall_evidence_confidence,
      'labels', public.fn_ecommerce_opportunity_labels(d.opportunity_band, d.overall_evidence_confidence),
      'sources', ss.s,
      'sources_expected', 6,
      'sources_with_evidence', agg.found,
      'sources_not_searched', agg.not_searched,
      'sources_blocked_or_unsupported', agg.blocked,
      'independent_categories', agg.found,
      'launch_critical_gap', agg.launch_gap,
      'research_status', CASE
          WHEN agg.not_searched > 0 THEN 'PARTIAL'
          WHEN agg.blocked > 0 THEN 'PARTIAL_SOURCE_UNAVAILABLE'
          ELSE 'COMPLETE' END,
      'grade', public.fn_ecommerce_evidence_grade(agg.found, d.overall_evidence_confidence, agg.launch_gap)
    ) AS row,
    d.product_opportunity_score
    FROM public.product_opportunity_decisions d
    JOIN public.commerce_products cp ON cp.id = d.product_id
    CROSS JOIN LATERAL (SELECT public.fn_ecommerce_research_source_states(v_uid, d.product_id, d.country_code) AS s) ss
    CROSS JOIN LATERAL (
      SELECT
        (SELECT count(*) FROM jsonb_array_elements(ss.s) e WHERE e->>'state'='SEARCHED_EVIDENCE_FOUND')::int AS found,
        (SELECT count(*) FROM jsonb_array_elements(ss.s) e WHERE e->>'state'='NOT_SEARCHED')::int AS not_searched,
        (SELECT count(*) FROM jsonb_array_elements(ss.s) e WHERE e->>'state' IN ('BLOCKED_EXTERNAL_ACCESS','UNSUPPORTED_MARKET','SOURCE_UNAVAILABLE'))::int AS blocked,
        coalesce((SELECT bool_or(e->>'evidence_category' IN ('ADVERTISING','SOCIAL_VIDEO') AND e->>'state' <> 'SEARCHED_EVIDENCE_FOUND') FROM jsonb_array_elements(ss.s) e), true) AS launch_gap
    ) agg
    WHERE d.tenant_id = v_uid AND coalesce(d.is_fixture,false) = false
  ) z;

  RETURN jsonb_build_object('status','ok','count', jsonb_array_length(v_rows), 'coverage', v_rows,
    'source_contract','product_opportunity_decisions+product_market_evaluations+provider_capability_registry',
    'note','Source states derived live from existing evidence; NOT_SEARCHED != SEARCHED_NO_EVIDENCE. No provider was called.');
END; $function$;

-- Helper (SECURITY DEFINER, service-side): per-category source states for a product+market,
-- derived from existing evidence dimensions + the provider registry. Returns a jsonb array.
CREATE OR REPLACE FUNCTION public.fn_ecommerce_research_source_states(p_tenant uuid, p_product_id uuid, p_market text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v_ev jsonb; v jsonb := '[]'::jsonb; v_comm int;
BEGIN
  SELECT e.evidence INTO v_ev FROM public.product_market_evaluations e
   WHERE e.tenant_id=p_tenant AND e.product_id=p_product_id AND e.country_code=p_market
   ORDER BY e.created_at DESC NULLS LAST LIMIT 1;
  v_ev := coalesce(v_ev,'{}'::jsonb);
  SELECT count(*) INTO v_comm FROM public.commerce_signals s
   WHERE s.user_id=p_tenant AND s.product_id=p_product_id AND s.signal_type='COMMUNITY_ATTENTION';

  -- COMMUNITY (Reddit): available globally
  v := v || jsonb_build_object('evidence_category','COMMUNITY','source','REDDIT',
        'state', CASE WHEN v_comm>0 OR jsonb_typeof(v_ev->'demand_momentum')='object' AND (v_ev->'demand_momentum') <> '{}'::jsonb
                      THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'NOT_SEARCHED' END);

  -- SEARCH_DEMAND (DataForSEO available global; direct Google Ads blocked)
  v := v || jsonb_build_object('evidence_category','SEARCH_DEMAND','source','DATAFORSEO',
        'state', CASE WHEN jsonb_typeof(v_ev->'buyer_search_intent')='object' AND (v_ev->'buyer_search_intent') <> '{}'::jsonb
                      THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'NOT_SEARCHED' END);

  -- ADVERTISING (Meta Ad Library — market-limited to EU/EEA+UK)
  v := v || jsonb_build_object('evidence_category','ADVERTISING','source','META_AD_LIBRARY',
        'state', CASE
          WHEN jsonb_typeof(v_ev->'advertising_activity')='object' AND (v_ev->'advertising_activity') <> '{}'::jsonb THEN 'SEARCHED_EVIDENCE_FOUND'
          WHEN NOT EXISTS (SELECT 1 FROM public.provider_capability_registry r
                           WHERE r.source='META_AD_LIBRARY' AND r.availability='AVAILABLE'
                             AND (r.market=p_market)) THEN 'UNSUPPORTED_MARKET'
          ELSE 'NOT_SEARCHED' END);

  -- MARKETPLACE (eBay Browse)
  v := v || jsonb_build_object('evidence_category','MARKETPLACE','source','EBAY',
        'state', CASE WHEN jsonb_typeof(v_ev->'marketplace_validation')='object' AND (v_ev->'marketplace_validation') <> '{}'::jsonb
                      THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'NOT_SEARCHED' END);

  -- SUPPLIER (CJ)
  v := v || jsonb_build_object('evidence_category','SUPPLIER','source','CJ',
        'state', CASE WHEN jsonb_typeof(v_ev->'supplier_availability_stock')='object' AND (v_ev->'supplier_availability_stock') <> '{}'::jsonb
                      THEN 'SEARCHED_EVIDENCE_FOUND' ELSE 'NOT_SEARCHED' END);

  -- SOCIAL_VIDEO (TikTok) — launch-critical, currently blocked (no authorized provider)
  v := v || jsonb_build_object('evidence_category','SOCIAL_VIDEO','source','TIKTOK','state','BLOCKED_EXTERNAL_ACCESS');

  RETURN v;
END; $function$;

-- Grants
REVOKE ALL ON FUNCTION public.fn_ecommerce_opportunity_labels(text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ecommerce_opportunity_labels(text,text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ecommerce_evidence_grade(integer,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ecommerce_evidence_grade(integer,text,boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ecommerce_research_coverage() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ecommerce_research_coverage() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_ecommerce_research_source_states(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_ecommerce_research_source_states(uuid,uuid,text) TO service_role;

-- ---------------------------------------------------------------------------
-- Self-cleaning selftest (service_role only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_deep_research_selftest()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE v jsonb := '[]'::jsonb; f uuid := '7c8ddf9d-172c-4a89-a402-bb7066228b61'; s jsonb;
BEGIN
  v := v || jsonb_build_object('case','tiktok_registered_blocked','pass',
    EXISTS(SELECT 1 FROM public.provider_capability_registry WHERE source='TIKTOK' AND availability='SOURCE_UNSUPPORTED'));
  -- semantics: HIGH_CONFIDENCE_TEST + NONE evidence -> mismatch flagged, opportunity label not "high confidence"
  v := v || jsonb_build_object('case','semantics_mismatch_flagged','pass',
    (public.fn_ecommerce_opportunity_labels('HIGH_CONFIDENCE_TEST','NONE')->>'label_evidence_mismatch')::boolean = true
    AND (public.fn_ecommerce_opportunity_labels('HIGH_CONFIDENCE_TEST','NONE')->>'opportunity_label') = 'Strong test candidate');
  -- grade gates
  v := v || jsonb_build_object('case','grade_high_needs_4_and_high','pass',
    (public.fn_ecommerce_evidence_grade(4,'HIGH',false)->>'grade')='HIGH_CONFIDENCE'
    AND (public.fn_ecommerce_evidence_grade(4,'HIGH',true)->>'grade')<>'HIGH_CONFIDENCE');
  v := v || jsonb_build_object('case','grade_strong_needs_3_moderate','pass',
    (public.fn_ecommerce_evidence_grade(3,'MODERATE',true)->>'grade')='STRONG_EVIDENCE_BACKED');
  v := v || jsonb_build_object('case','grade_two_source_developing','pass',
    (public.fn_ecommerce_evidence_grade(2,'LOW',true)->>'grade')='DEVELOPING_EVIDENCE');
  -- founder source states: community+marketplace found, search/advertising/supplier NOT_SEARCHED, tiktok blocked
  s := public.fn_ecommerce_research_source_states(f,'275266ba-0569-4a47-a5fc-2c5bef27eb0e','GB');
  v := v || jsonb_build_object('case','founder_community_found','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='COMMUNITY')='SEARCHED_EVIDENCE_FOUND');
  v := v || jsonb_build_object('case','founder_marketplace_found','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='MARKETPLACE')='SEARCHED_EVIDENCE_FOUND');
  v := v || jsonb_build_object('case','founder_search_not_searched','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='SEARCH_DEMAND')='NOT_SEARCHED');
  v := v || jsonb_build_object('case','founder_advertising_not_searched','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='ADVERTISING')='NOT_SEARCHED');
  v := v || jsonb_build_object('case','founder_tiktok_blocked','pass',
    (SELECT e->>'state' FROM jsonb_array_elements(s) e WHERE e->>'evidence_category'='SOCIAL_VIDEO')='BLOCKED_EXTERNAL_ACCESS');
  v := v || jsonb_build_object('case','ledger_tables_empty','pass',
    (SELECT count(*) FROM public.commerce_research_run)=0 AND (SELECT count(*) FROM public.commerce_research_source_attempt)=0);

  RETURN jsonb_build_object('suite','deep_research_infrastructure',
    'total', jsonb_array_length(v),
    'passed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE (x->>'pass')::boolean),
    'failed', (SELECT count(*) FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'all_pass', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x->>'pass')::boolean),
    'results', v);
END; $function$;

REVOKE ALL ON FUNCTION public.fn_deep_research_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_deep_research_selftest() TO service_role;

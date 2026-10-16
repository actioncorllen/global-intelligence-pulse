-- mig_303_stage3b_commercial_verification.sql
--
-- STAGE 3B: SUPPLIER COMMERCIAL VERIFICATION + MARKET/COMPETITOR PRICING (country-specific).
--
-- WHAT THIS DOES (reuse-first; no working component rebuilt):
--   * GATE: commercial verification proceeds only off a GENUINE Stage-2 binding
--     (commerce_concrete_supplier_resolution: identity_result='EXACT_SUPPLIER_IDENTITY_RESOLVED'
--     AND bound=true). No binding -> state BLOCKED_NO_BINDING, never fabricated, never persisted.
--   * ECONOMICS: reuses fn_supplier_economics (landed = supplier_cost + shipping; shipping NEVER
--     assumed 0; FX fail-closed), fn_candidate_pricing_economics (MARKET_LED contribution/band),
--     fn_economics_breakeven (fee-aware). Founder figures are passed as parameters
--     (ad_reserve=10, contribution target 25..30) WITHOUT changing those functions' defaults.
--   * MARKET/COMPETITOR PRICING: reuses fn_pmc_evaluate/fn_pmc_summary + product_market_competitors;
--     country+currency isolated (foreign/converted prices excluded), seller-deduped, exact vs
--     similar split, per-competitor name/link/currency/timestamp/source, average/low/high, and an
--     evidence-based suggested selling-price range. Missing/stale/insufficient -> UNKNOWN, never invented.
--   * STATES: PENDING / PARTIAL / FAILED / COMMERCIALLY_VALIDATED (+ non-persisted gate BLOCKED_NO_BINDING).
--
-- INTEGRITY INVARIANTS (enforced in code AND by a table CHECK):
--   (I1) FIXTURE / non-REAL evidence can NEVER be COMMERCIALLY_VALIDATED (capped at PARTIAL).
--   (I2) The $25-$30 contribution target and the ~$10 ad reserve are DISPLAY/recommendation only;
--        they NEVER drive a FAILED state and NEVER block verification (Stage-3B msg2 #8).
--        FAILED is reserved for hard supplier-side evidence (confirmed out-of-stock / unsupported delivery).
--   (I3) Tenant isolation (user_id on commerce_products), 18-market country isolation
--        (ecommerce_market_universe.default_currency), exact-product matching (fn_market_supplier_match
--        via Stage-2, unchanged) and Product Asset Lock (card identity via fn_ad_product_card_authority,
--        SUPPLIER_PROVIDED invariant, unchanged) are all preserved.
--
-- Conventions: SECURITY DEFINER + SET search_path TO ''; fully-qualified public.*; definer-only grants
-- (read wrapper additionally granted to authenticated); every feature ships a deterministic _selftest.

-- =====================================================================================================
-- Persistence: country-specific commercial verification record (tenant-isolated, definer-only)
-- =====================================================================================================
CREATE TABLE IF NOT EXISTS public.commerce_commercial_verification (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  opportunity_product_id uuid NOT NULL,
  market text NOT NULL,
  state text NOT NULL CHECK (state IN ('PENDING','PARTIAL','FAILED','COMMERCIALLY_VALIDATED')),
  evidence_grade text NOT NULL DEFAULT 'REAL' CHECK (evidence_grade IN ('REAL','FIXTURE')),
  supplier_binding jsonb NOT NULL DEFAULT '{}'::jsonb,
  supplier_evidence jsonb,
  delivery jsonb,
  availability jsonb,
  economics jsonb,
  market_pricing jsonb,
  freshness jsonb,
  blockers jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_fixture boolean NOT NULL DEFAULT false,
  contract text NOT NULL DEFAULT 'pulse_stage3b_commercial_verification_v1',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, opportunity_product_id, market),
  -- I1 (DB-level belt-and-suspenders): fixtures / non-REAL evidence can never be stored as validated.
  CONSTRAINT commercial_verification_no_fixture_validation
    CHECK (NOT (state = 'COMMERCIALLY_VALIDATED' AND (is_fixture = true OR evidence_grade <> 'REAL')))
);
ALTER TABLE public.commerce_commercial_verification ENABLE ROW LEVEL SECURITY;
-- No permissive RLS policy by design: access is via SECURITY DEFINER functions only (same posture as
-- product_market_competitors / commerce_concrete_supplier_resolution).
CREATE INDEX IF NOT EXISTS idx_ccv_tenant_market_state
  ON public.commerce_commercial_verification (tenant_id, market, state);
COMMENT ON TABLE public.commerce_commercial_verification IS
  'Stage-3B country-specific supplier commercial verification. One row per (tenant, product, market). '
  'COMMERCIALLY_VALIDATED requires REAL (non-fixture) complete fresh evidence off a genuine Stage-2 binding; '
  'fixture evidence is capped at PARTIAL (CHECK-enforced).';

-- =====================================================================================================
-- Helper: country -> local currency (authoritative 18-market universe, with safe fallbacks)
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_stage3b_market_currency(p_market text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT upper(coalesce(
    (SELECT default_currency FROM public.ecommerce_market_universe
       WHERE country_code = upper(btrim(p_market)) LIMIT 1),
    public.fn_market_default_currency(p_market),
    public.fn_currency_for_country(p_market)
  ));
$function$;
REVOKE ALL ON FUNCTION public.fn_stage3b_market_currency(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage3b_market_currency(text) TO service_role;

-- =====================================================================================================
-- Market & competitor pricing (country-specific, seller-deduped, exact vs similar, evidence-only).
-- Reuses fn_pmc_evaluate for the engine aggregate; adds per-competitor display + average/low/high over
-- the IDENTICAL local filter (direct match + local country + local currency + OBSERVED/PLATFORM_REPORTED),
-- deduped by seller and freshness-screened. p_competitors inline overrides the persisted read (hermetic
-- tests + ad-hoc evaluation); otherwise reads product_market_competitors for (tenant, product, country).
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_stage3b_market_pricing(
  p_tenant uuid, p_product uuid, p_market text,
  p_market_currency text DEFAULT NULL,
  p_competitors jsonb DEFAULT NULL,
  p_freshness_hours integer DEFAULT 336,
  p_now timestamptz DEFAULT now()
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_country text := upper(btrim(coalesce(p_market,'')));
  v_ccy text := upper(coalesce(nullif(btrim(p_market_currency),''), public.fn_stage3b_market_currency(p_market)));
  v_comps jsonb;
  v_engine jsonb;
  c jsonb;
  v_key text;
  v_seen text[] := '{}';
  v_dups int := 0;
  v_exact jsonb := '[]'::jsonb;
  v_similar jsonb := '[]'::jsonb;
  v_excl_foreign int := 0; v_excl_currency int := 0; v_excl_nonobserved int := 0;
  v_excl_category int := 0; v_excl_unrelated int := 0; v_excl_noprice int := 0;
  v_fresh_prices numeric[] := '{}';
  v_fresh_cnt int := 0; v_unknown_ts_cnt int := 0; v_stale_cnt int := 0;
  v_mc text; v_amt numeric; v_cur text; v_sc text; v_ctry text; v_ident text; v_url text;
  v_ts timestamptz; v_fresh_state text; v_qual boolean; v_age_h numeric; v_newest timestamptz;
  v_avg numeric; v_lo numeric; v_hi numeric; v_med numeric; v_n int; v_status text; v_reason text;
  v_row jsonb;
BEGIN
  -- Tenant ownership (skipped only when the caller supplies inline competitors for a hermetic eval).
  IF p_competitors IS NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.commerce_products WHERE id = p_product AND user_id = p_tenant) THEN
      RETURN jsonb_build_object('status','ERROR','error','product_not_found_for_tenant',
        'market', v_country, 'currency', v_ccy, 'contract','pulse_stage3b_market_pricing_v1');
    END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'competitor_identity', competitor_identity, 'observed_product_url', observed_product_url,
        'competitor_ref', competitor_ref, 'platform', platform, 'match_class', match_class,
        'price', jsonb_build_object('amount', price_original, 'currency', price_currency,
                 'source_class', price_source_class, 'country', country_code),
        'price_observed_at', price_observed_at, 'observed_at', observed_at,
        'source', source, 'evidence_class', evidence_class, 'is_fixture', is_fixture)), '[]'::jsonb)
      INTO v_comps
    FROM public.product_market_competitors
    WHERE tenant_id = p_tenant AND product_id = p_product AND country_code = v_country;
  ELSE
    v_comps := coalesce(p_competitors, '[]'::jsonb);
  END IF;

  -- Engine aggregate (reused, authoritative for competition level/saturation + a cross-check median/range).
  v_engine := public.fn_pmc_evaluate(p_tenant, p_product, v_country, v_ccy, v_comps, NULL, '{}'::jsonb, false, false);

  -- Per-competitor display + deduped, freshness-screened local price stats.
  FOR c IN SELECT * FROM jsonb_array_elements(v_comps) LOOP
    v_mc   := coalesce(c->>'match_class','UNRELATED');
    v_amt  := nullif(btrim(c->'price'->>'amount'),'')::numeric;
    v_cur  := upper(nullif(btrim(c->'price'->>'currency'),''));
    v_sc   := coalesce(c->'price'->>'source_class','UNKNOWN');
    v_ctry := upper(coalesce(nullif(btrim(c->'price'->>'country'),''), v_country));
    v_ident:= nullif(btrim(c->>'competitor_identity'),'');
    v_url  := nullif(btrim(c->>'observed_product_url'),'');
    v_ts   := coalesce(nullif(btrim(c->>'price_observed_at'),'')::timestamptz, nullif(btrim(c->>'observed_at'),'')::timestamptz);

    -- Seller dedup: first occurrence per identity (fallback url/ref) wins.
    v_key := lower(coalesce(v_ident, v_url, c->>'competitor_ref'));
    IF v_key IS NOT NULL AND v_key = ANY(v_seen) THEN
      v_dups := v_dups + 1;
      CONTINUE;
    END IF;
    IF v_key IS NOT NULL THEN v_seen := array_append(v_seen, v_key); END IF;

    -- Count non-direct exclusions (not eligible as local price evidence, but surfaced transparently).
    IF v_mc = 'UNRELATED' THEN v_excl_unrelated := v_excl_unrelated + 1; CONTINUE; END IF;
    IF v_mc = 'CATEGORY_COMPETITOR' THEN v_excl_category := v_excl_category + 1; CONTINUE; END IF;

    -- Local price qualification (identical to fn_pmc_evaluate's filter).
    v_qual := (v_mc IN ('EXACT_PRODUCT','CLOSE_COMPARABLE') AND v_ctry = v_country
               AND v_cur = v_ccy AND v_sc IN ('OBSERVED','PLATFORM_REPORTED') AND v_amt IS NOT NULL);
    v_fresh_state := 'NA';
    IF v_qual THEN
      IF v_ts IS NULL THEN
        v_fresh_state := 'UNKNOWN'; v_unknown_ts_cnt := v_unknown_ts_cnt + 1;
      ELSE
        v_age_h := extract(epoch FROM (p_now - v_ts))/3600.0;
        IF v_age_h <= p_freshness_hours THEN
          v_fresh_state := 'FRESH'; v_fresh_cnt := v_fresh_cnt + 1;
          v_fresh_prices := array_append(v_fresh_prices, v_amt);
          IF v_newest IS NULL OR v_ts > v_newest THEN v_newest := v_ts; END IF;
        ELSE
          v_fresh_state := 'STALE'; v_stale_cnt := v_stale_cnt + 1;
        END IF;
      END IF;
    ELSE
      -- Record WHY a direct row did not qualify as local evidence.
      IF v_mc IN ('EXACT_PRODUCT','CLOSE_COMPARABLE') THEN
        IF v_amt IS NULL THEN v_excl_noprice := v_excl_noprice + 1;
        ELSIF v_ctry <> v_country THEN v_excl_foreign := v_excl_foreign + 1;
        ELSIF v_cur <> v_ccy THEN v_excl_currency := v_excl_currency + 1;
        ELSE v_excl_nonobserved := v_excl_nonobserved + 1; END IF;
      END IF;
    END IF;

    -- Build display row (exact vs similar). Price shown only in its own currency; foreign flagged.
    IF v_mc IN ('EXACT_PRODUCT','CLOSE_COMPARABLE') THEN
      v_row := jsonb_build_object(
        'seller', coalesce(v_ident,'(unnamed seller)'),
        'product_url', v_url,
        'price', CASE WHEN v_amt IS NOT NULL THEN jsonb_build_object('amount',v_amt,'currency',v_cur) ELSE NULL END,
        'currency', v_cur,
        'source_class', v_sc,
        'platform', c->>'platform',
        'observed_at', v_ts,
        'source', c->>'source',
        'evidence_class', c->>'evidence_class',
        'match_class', v_mc,
        'local_price_evidence', v_qual,
        'freshness', v_fresh_state,
        'note', CASE WHEN v_qual THEN NULL
                     WHEN v_ctry <> v_country THEN 'foreign market price — NOT local evidence'
                     WHEN v_cur <> v_ccy THEN 'non-local currency — NOT local evidence (never converted into local)'
                     WHEN v_amt IS NULL THEN 'no observed price'
                     ELSE 'price source not OBSERVED/PLATFORM_REPORTED — NOT counted' END);
      IF v_mc = 'EXACT_PRODUCT' THEN v_exact := v_exact || jsonb_build_array(v_row);
      ELSE v_similar := v_similar || jsonb_build_array(v_row); END IF;
    END IF;
  END LOOP;

  -- Stats over fresh, deduped, local-qualifying prices only (never invented; stale excluded).
  v_n := array_length(v_fresh_prices, 1);
  IF v_n IS NOT NULL AND v_n > 0 THEN
    SELECT round(avg(v)::numeric,2), min(v), max(v),
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY v))::numeric,2)
      INTO v_avg, v_lo, v_hi, v_med FROM unnest(v_fresh_prices) v;
    v_status := 'KNOWN'; v_reason := NULL;
  ELSE
    v_status := 'UNKNOWN';
    v_reason := CASE
      WHEN v_stale_cnt > 0 THEN 'all_local_direct_prices_stale'
      WHEN v_unknown_ts_cnt > 0 THEN 'local_direct_prices_present_but_untimestamped'
      ELSE 'no_local_direct_observed_prices' END;
  END IF;

  RETURN jsonb_build_object(
    'status', v_status,
    'market', v_country,
    'currency', v_ccy,
    'observed', CASE WHEN v_status='KNOWN' THEN jsonb_build_object(
        'sellers', v_n, 'average', v_avg, 'lowest', v_lo, 'highest', v_hi,
        'median', v_med, 'range', jsonb_build_array(v_lo, v_hi))
      ELSE jsonb_build_object('sellers', 0, 'average', NULL, 'lowest', NULL, 'highest', NULL,
        'median', NULL, 'range', NULL, 'reason', v_reason) END,
    'exact_listings', v_exact,
    'similar_listings', v_similar,
    'sellers_deduped', coalesce(v_n,0),
    'duplicate_sellers_removed', v_dups,
    'excluded_from_local_evidence', jsonb_build_object(
        'foreign_market', v_excl_foreign, 'non_local_currency', v_excl_currency,
        'not_observed', v_excl_nonobserved, 'no_price', v_excl_noprice,
        'category_competitor', v_excl_category, 'unrelated', v_excl_unrelated),
    'freshness', jsonb_build_object('window_hours', p_freshness_hours, 'fresh', v_fresh_cnt,
        'unknown_timestamp', v_unknown_ts_cnt, 'stale_excluded', v_stale_cnt, 'newest_observed_at', v_newest),
    'engine_aggregate', jsonb_build_object(
        'market_price', v_engine->'market_price',
        'competition', v_engine->'competition',
        'competitor_counts', v_engine->'competitor_counts',
        'note','fn_pmc_evaluate aggregate (median/range pre-dedup) for competition level + cross-check'),
    'provenance', 'local OBSERVED/PLATFORM_REPORTED direct matches only, seller-deduped, country+currency isolated; '
                  'foreign/converted/non-observed excluded; stale excluded; prices never invented',
    'contract','pulse_stage3b_market_pricing_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage3b_market_pricing(uuid,uuid,text,text,jsonb,integer,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage3b_market_pricing(uuid,uuid,text,text,jsonb,integer,timestamptz) TO service_role;

-- =====================================================================================================
-- Unit economics (reuse wrapper). Landed via fn_supplier_economics; contribution/band via
-- fn_candidate_pricing_economics (fee amount passed as variable_costs, founder ad_reserve/target as params);
-- fee-aware break-even via fn_economics_breakeven. Suggested selling-price range is evidence-anchored
-- to the observed local range. Target/ad are DISPLAY ONLY — they never gate (I2).
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_stage3b_unit_economics(
  p_supplier jsonb, p_market_price numeric, p_display_currency text,
  p_fees jsonb DEFAULT NULL,
  p_ad_reserve numeric DEFAULT 10, p_target_min numeric DEFAULT 25, p_target_max numeric DEFAULT 30,
  p_observed_low numeric DEFAULT NULL, p_observed_high numeric DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_ccy text := upper(coalesce(p_display_currency,''));
  v_landed_econ jsonb := public.fn_supplier_economics(p_supplier, NULL, p_display_currency);
  v_landed_known boolean := coalesce((v_landed_econ->>'known')::boolean, false);
  v_landed numeric := nullif(v_landed_econ->>'landed_cost_display','')::numeric;
  v_landed_orig numeric := nullif(v_landed_econ->>'landed_cost_original','')::numeric;
  v_landed_cur text := coalesce(v_landed_econ->>'landed_cost_currency', v_ccy);
  v_pay_pct numeric := coalesce(nullif(p_fees->>'payment_fee_pct','')::numeric,0);
  v_plat_pct numeric := coalesce(nullif(p_fees->>'platform_fee_pct','')::numeric,0);
  v_pay_fixed numeric := coalesce(nullif(p_fees->>'payment_fixed','')::numeric,0);
  v_other numeric := coalesce(nullif(p_fees->>'other_variable','')::numeric,0);
  v_fee_amt numeric; v_pricing jsonb; v_breakeven jsonb;
  v_req_min numeric; v_req_max numeric; v_sug jsonb;
BEGIN
  IF NOT v_landed_known THEN
    RETURN jsonb_build_object('known', false, 'landed_known', false,
      'reason', coalesce(v_landed_econ->>'reason','economics_unknown'),
      'economics', v_landed_econ, 'display_currency', v_ccy,
      'note','landed economics unknown (supplier cost or destination shipping missing, or FX fail-closed); '
             'shipping is NEVER assumed 0', 'contract','pulse_stage3b_unit_economics_v1');
  END IF;

  IF p_market_price IS NULL OR p_market_price <= 0 THEN
    RETURN jsonb_build_object('known', false, 'landed_known', true,
      'landed_cost', v_landed, 'landed_cost_currency', v_landed_cur, 'display_currency', v_ccy,
      'reason','no_local_market_price',
      'note','landed cost known but no market-supported selling price; contribution is MARKET_LED and '
             'cannot be computed without observed local price (never cost-plus-markup)',
      'contract','pulse_stage3b_unit_economics_v1');
  END IF;

  v_fee_amt := round((v_pay_pct + v_plat_pct) * p_market_price + v_pay_fixed + v_other, 2);
  -- Contribution/band (founder ad_reserve + target passed explicitly; fee amount as variable cost).
  v_pricing := public.fn_candidate_pricing_economics(p_supplier, p_market_price, p_display_currency,
                 p_ad_reserve, v_fee_amt, p_target_min, p_target_max);
  -- Fee-aware break-even (independent cross-check of the fee math).
  v_breakeven := public.fn_economics_breakeven(p_market_price, v_landed_orig, v_landed_cur, p_display_currency, p_fees);

  v_req_min := round(v_landed + p_ad_reserve + v_fee_amt + p_target_min, 2);
  v_req_max := round(v_landed + p_ad_reserve + v_fee_amt + p_target_max, 2);

  -- Evidence-based suggested selling-price range: anchored to the OBSERVED local range; never above the
  -- defensible market high; flags (but does not block) when the target needs a price above observed market.
  IF p_observed_low IS NULL OR p_observed_high IS NULL THEN
    v_sug := jsonb_build_object('status','UNKNOWN','low',NULL,'high',NULL,
      'basis','no observed local market prices — price required for target shown but not market-validated',
      'price_required_for_target', jsonb_build_object('min', v_req_min, 'max', v_req_max));
  ELSIF v_req_min > p_observed_high THEN
    v_sug := jsonb_build_object('status','TARGET_ABOVE_MARKET','low',NULL,'high',NULL,
      'observed_range', jsonb_build_array(p_observed_low, p_observed_high),
      'price_required_for_target', jsonb_build_object('min', v_req_min, 'max', v_req_max),
      'basis','target contribution needs a price above the observed market high; shown as evidence, not a block');
  ELSE
    v_sug := jsonb_build_object('status','EVIDENCE_BASED',
      'low', greatest(v_req_min, p_observed_low), 'high', p_observed_high,
      'observed_range', jsonb_build_array(p_observed_low, p_observed_high),
      'price_required_for_target', jsonb_build_object('min', v_req_min, 'max', v_req_max),
      'basis','within observed competitor range and >= price required for target contribution');
  END IF;

  RETURN jsonb_build_object(
    'known', true, 'landed_known', true, 'pricing_model','MARKET_LED', 'display_currency', v_ccy,
    'market_price', p_market_price,
    'landed_cost', v_landed, 'landed_cost_currency', v_landed_cur,
    'shipping_known', coalesce((v_landed_econ->>'shipping_known')::boolean,false),
    'fees', jsonb_build_object('amount', v_fee_amt, 'known', (p_fees IS NOT NULL),
        'payment_fee_pct', v_pay_pct, 'platform_fee_pct', v_plat_pct,
        'payment_fixed', v_pay_fixed, 'other_variable', v_other),
    'ad_reserve', jsonb_build_object('amount', p_ad_reserve, 'currency', v_ccy, 'assumption', true,
        'source','FOUNDER_INITIAL_AD_RESERVE', 'note','pre-launch ad reserve; replace with real CPA/CAC when live'),
    'projected_contribution', (v_pricing->>'projected_contribution')::numeric,
    'contribution_band', v_pricing->>'contribution_band',
    'meets_target', (v_pricing->>'meets_target')::boolean,
    'target', jsonb_build_object('min', p_target_min, 'max', p_target_max, 'currency', v_ccy,
        'note','target applied in display currency; recommendation only — never blocks verification'),
    'market_price_required_for_target', jsonb_build_object('min', v_req_min, 'max', v_req_max),
    'suggested_selling_price_range', v_sug,
    'break_even', jsonb_build_object(
        'economics_state', v_breakeven->>'economics_state',
        'contribution_before_ads', (v_breakeven->>'contribution_before_ads')::numeric,
        'break_even_cpa', (v_breakeven->>'break_even_cpa')::numeric,
        'contribution_margin', (v_breakeven->>'contribution_margin')::numeric,
        'fees_known', (v_breakeven->>'fees_known')::boolean),
    'suggested_action', v_pricing->>'suggested_action',
    'is_net_profit', false,
    'note','contribution target and ad reserve are recommendation inputs only; they never gate verification',
    'contract','pulse_stage3b_unit_economics_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage3b_unit_economics(jsonb,numeric,text,jsonb,numeric,numeric,numeric,numeric,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage3b_unit_economics(jsonb,numeric,text,jsonb,numeric,numeric,numeric,numeric,numeric) TO service_role;

-- =====================================================================================================
-- Orchestrator: commercial verification for a (tenant, product, market).
--   Real mode  : reads the Stage-2 binding + assembles supplier evidence from commerce_supplier_products.
--   Fixture mode: p_binding/p_supplier_evidence/p_competitors supplied inline; evidence_grade=FIXTURE;
--                 capped at PARTIAL (I1); may be used by the selftest with p_persist=false.
-- Gate applies in BOTH modes: identity_result must be EXACT_SUPPLIER_IDENTITY_RESOLVED and bound=true.
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_stage3b_verify_commercial(
  p_tenant uuid, p_product uuid, p_market text,
  p_supplier_evidence jsonb DEFAULT NULL,
  p_competitors jsonb DEFAULT NULL,
  p_binding jsonb DEFAULT NULL,
  p_fees jsonb DEFAULT NULL,
  p_ad_reserve numeric DEFAULT 10, p_target_min numeric DEFAULT 25, p_target_max numeric DEFAULT 30,
  p_freshness_hours integer DEFAULT 336,
  p_is_fixture boolean DEFAULT false,
  p_persist boolean DEFAULT false,
  p_now timestamptz DEFAULT now()
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_country text := upper(btrim(coalesce(p_market,'')));
  v_ccy text := public.fn_stage3b_market_currency(p_market);
  v_fixture_mode boolean := (p_binding IS NOT NULL) OR p_is_fixture;
  v_binding jsonb; v_binding_is_fixture boolean := false; v_binding_at timestamptz;
  v_grade text; v_sup jsonb; v_ev jsonb; v_delivery jsonb; v_avail jsonb;
  v_pricing jsonb; v_price_point numeric; v_obs_low numeric; v_obs_high numeric; v_market_known boolean;
  v_econ jsonb; v_landed_known boolean;
  v_blockers text[] := '{}';
  v_sup_stale boolean := false; v_market_stale boolean := false; v_binding_stale boolean := false;
  v_sup_newest timestamptz;
  v_delivery_supported boolean; v_avail_ok boolean; v_hard_fail boolean; v_state text;
  v_row public.commerce_supplier_products%rowtype; v_fr jsonb;
BEGIN
  IF v_country = '' THEN
    RETURN jsonb_build_object('ok',false,'error','market_required','contract','pulse_stage3b_commercial_verification_v1');
  END IF;

  -- ---- Binding / gate -----------------------------------------------------------------------------
  IF p_binding IS NOT NULL THEN
    v_binding := p_binding; v_binding_is_fixture := true;  -- inline binding is never a real binding
    v_binding_at := nullif(btrim(p_binding->>'bound_at'),'')::timestamptz;
  ELSE
    -- Real mode: verify tenant ownership, then read the persisted Stage-2 resolution.
    IF NOT EXISTS (SELECT 1 FROM public.commerce_products WHERE id = p_product AND user_id = p_tenant) THEN
      RETURN jsonb_build_object('ok',false,'error','product_not_found_for_tenant',
        'market',v_country,'contract','pulse_stage3b_commercial_verification_v1');
    END IF;
    SELECT jsonb_build_object(
             'identity_result', identity_result, 'bound', bound, 'selected_supplier', selected_supplier,
             'selected_supplier_product_id', selected_supplier_product_id, 'selected_sku', selected_sku,
             'selected_variant', selected_variant, 'market', market, 'is_fixture', coalesce(is_fixture,false),
             'bound_at', bound_at),
           coalesce(is_fixture,false), bound_at
      INTO v_binding, v_binding_is_fixture, v_binding_at
    FROM public.commerce_concrete_supplier_resolution
    WHERE tenant_id = p_tenant AND opportunity_product_id = p_product AND market = v_country
    LIMIT 1;
  END IF;

  -- GATE: a genuine EXACT binding is required. No fabrication.
  IF v_binding IS NULL
     OR coalesce(v_binding->>'identity_result','') <> 'EXACT_SUPPLIER_IDENTITY_RESOLVED'
     OR coalesce((v_binding->>'bound')::boolean,false) <> true THEN
    RETURN jsonb_build_object('ok',true,'state','BLOCKED_NO_BINDING','market',v_country,
      'tenant_id',p_tenant,'product_id',p_product,
      'binding', coalesce(v_binding, jsonb_build_object('identity_result','NONE','bound',false)),
      'persisted', false,
      'note','no genuine EXACT_SUPPLIER_IDENTITY_RESOLVED / bound=true for this (tenant, product, market); '
             'commercial verification is blocked and nothing is persisted (never fabricate a binding)',
      'contract','pulse_stage3b_commercial_verification_v1');
  END IF;

  v_grade := CASE WHEN v_fixture_mode OR v_binding_is_fixture
                    OR coalesce((p_supplier_evidence->>'_fixture')::boolean,false)
                  THEN 'FIXTURE' ELSE 'REAL' END;

  -- ---- Supplier evidence --------------------------------------------------------------------------
  IF p_supplier_evidence IS NOT NULL THEN
    v_sup := p_supplier_evidence;
  ELSE
    -- Real mode: assemble from the CJ supplier-products cache for the bound product id.
    SELECT * INTO v_row FROM public.commerce_supplier_products
    WHERE source_product_id = (v_binding->>'selected_supplier_product_id') LIMIT 1;
    IF FOUND THEN
      v_fr := v_row.supplier_enrichment->'freight'->v_country->'representative';
      v_sup := jsonb_build_object(
        'supplier_cost', v_row.supplier_cost, 'cost_currency', v_row.cost_currency,
        'is_free_shipping', v_row.is_free_shipping,
        'shipping_cost', v_fr->>'shipping_cost',
        'shipping_country_codes', v_row.shipping_country_codes,
        'sale_status', v_row.sale_status,
        'sku', v_binding->>'selected_sku', 'variant', v_binding->'selected_variant',
        'delivery_estimate', CASE WHEN v_fr IS NOT NULL THEN jsonb_build_object(
            'est_min_days', v_fr->>'est_min_days', 'est_max_days', v_fr->>'est_max_days',
            'shipping_cost', v_fr->>'shipping_cost', 'shipping_currency', coalesce(v_fr->>'shipping_currency', v_row.cost_currency),
            'destination', v_country, 'source','CJ_FREIGHT_CALCULATE',
            'observed_at', v_row.enrichment_observed_at) ELSE NULL END,
        'stock', v_row.supplier_enrichment->'stock',
        '_source','commerce_supplier_products', '_observed_at', v_row.enrichment_observed_at);
    ELSE
      v_sup := NULL;
    END IF;
  END IF;

  -- No supplier evidence yet -> PENDING (binding exists, awaiting supplier detail).
  IF v_sup IS NULL THEN
    IF p_persist THEN
      INSERT INTO public.commerce_commercial_verification AS t
        (tenant_id, opportunity_product_id, market, state, evidence_grade, supplier_binding, supplier_evidence,
         blockers, is_fixture, updated_at)
      VALUES (p_tenant, p_product, v_country, 'PENDING', v_grade, v_binding, NULL,
         jsonb_build_array('SUPPLIER_EVIDENCE_MISSING'), (v_grade='FIXTURE'), now())
      ON CONFLICT (tenant_id, opportunity_product_id, market) DO UPDATE
        SET state=excluded.state, evidence_grade=excluded.evidence_grade, supplier_binding=excluded.supplier_binding,
            supplier_evidence=NULL, blockers=excluded.blockers, is_fixture=excluded.is_fixture, updated_at=now();
    END IF;
    RETURN jsonb_build_object('ok',true,'state','PENDING','evidence_grade',v_grade,'market',v_country,
      'tenant_id',p_tenant,'product_id',p_product,'binding',v_binding,
      'blockers', jsonb_build_array('SUPPLIER_EVIDENCE_MISSING'),
      'persisted', (p_persist AND true),
      'note','binding present; supplier commercial detail not yet available (PENDING)',
      'contract','pulse_stage3b_commercial_verification_v1');
  END IF;

  -- ---- Evidence dimensions (reused) ---------------------------------------------------------------
  v_ev := public.fn_supplier_evidence(v_sup, v_country);
  v_delivery := v_ev->'delivery';
  v_avail := v_ev->'availability';

  v_pricing := public.fn_stage3b_market_pricing(p_tenant, p_product, v_country, v_ccy, p_competitors, p_freshness_hours, p_now);
  v_market_known := (v_pricing->>'status') = 'KNOWN';
  IF v_market_known THEN
    v_price_point := (v_pricing->'observed'->>'median')::numeric;
    v_obs_low := (v_pricing->'observed'->>'lowest')::numeric;
    v_obs_high := (v_pricing->'observed'->>'highest')::numeric;
  END IF;

  v_econ := public.fn_stage3b_unit_economics(v_sup, v_price_point, v_ccy, p_fees, p_ad_reserve, p_target_min, p_target_max, v_obs_low, v_obs_high);
  v_landed_known := coalesce((v_econ->>'landed_known')::boolean,false);

  -- ---- Freshness ----------------------------------------------------------------------------------
  v_sup_newest := coalesce(nullif(btrim(v_sup->'delivery_estimate'->>'observed_at'),'')::timestamptz,
                           nullif(btrim(v_sup->'stock'->>'observed_at'),'')::timestamptz,
                           nullif(btrim(v_sup->>'_observed_at'),'')::timestamptz);
  v_sup_stale := (v_sup_newest IS NOT NULL AND extract(epoch FROM (p_now - v_sup_newest))/3600.0 > p_freshness_hours);
  v_market_stale := (coalesce((v_pricing->'freshness'->>'stale_excluded')::int,0) > 0 AND NOT v_market_known);
  v_binding_stale := (v_binding_at IS NOT NULL AND extract(epoch FROM (p_now - v_binding_at))/3600.0 > p_freshness_hours);

  -- ---- Blockers (evidence gaps; NONE of these is the contribution target — I2) ---------------------
  IF NOT v_landed_known THEN v_blockers := array_append(v_blockers,'ECONOMICS_UNKNOWN'); END IF;
  IF NOT v_market_known THEN v_blockers := array_append(v_blockers,'NO_LOCAL_MARKET_PRICE'); END IF;
  IF coalesce(v_delivery->>'state','') IN ('NOT_PROBED','UNKNOWN') THEN v_blockers := array_append(v_blockers,'DELIVERY_NOT_PROBED'); END IF;
  IF NOT coalesce((v_avail->>'known')::boolean,false) THEN v_blockers := array_append(v_blockers,'AVAILABILITY_UNKNOWN'); END IF;
  IF v_sup_stale THEN v_blockers := array_append(v_blockers,'SUPPLIER_EVIDENCE_STALE'); END IF;
  IF v_binding_stale THEN v_blockers := array_append(v_blockers,'BINDING_STALE'); END IF;

  -- ---- State machine ------------------------------------------------------------------------------
  v_delivery_supported := coalesce((v_delivery->>'known')::boolean,false) AND coalesce((v_delivery->>'supported')::boolean,false);
  v_avail_ok := coalesce((v_avail->>'known')::boolean,false)
                AND coalesce((v_avail->>'critical')::boolean,false) = false
                AND coalesce(v_avail->>'value','') NOT IN ('OUT_OF_STOCK','DISCONTINUED');
  -- Hard, supplier-side commercial failure (NOT economics/contribution).
  v_hard_fail := coalesce((v_avail->>'critical')::boolean,false) OR coalesce((v_delivery->>'critical')::boolean,false);

  IF v_hard_fail THEN
    v_state := 'FAILED';
  ELSIF v_grade = 'REAL' AND v_landed_known AND v_market_known AND v_delivery_supported AND v_avail_ok
        AND NOT v_sup_stale AND NOT v_binding_stale THEN
    v_state := 'COMMERCIALLY_VALIDATED';
  ELSIF v_grade = 'FIXTURE' THEN
    v_state := 'PARTIAL';   -- I1: fixtures never validate
  ELSIF v_landed_known OR v_market_known OR v_delivery_supported THEN
    v_state := 'PARTIAL';
  ELSE
    v_state := 'PENDING';
  END IF;

  -- ---- Persist (upsert) ---------------------------------------------------------------------------
  IF p_persist THEN
    INSERT INTO public.commerce_commercial_verification AS t
      (tenant_id, opportunity_product_id, market, state, evidence_grade, supplier_binding, supplier_evidence,
       delivery, availability, economics, market_pricing, freshness, blockers, is_fixture, updated_at)
    VALUES (p_tenant, p_product, v_country, v_state, v_grade, v_binding, v_sup,
       v_delivery, v_avail, v_econ, v_pricing,
       jsonb_build_object('supplier_newest', v_sup_newest, 'supplier_stale', v_sup_stale,
         'binding_stale', v_binding_stale, 'market', v_pricing->'freshness', 'window_hours', p_freshness_hours),
       to_jsonb(v_blockers), (v_grade='FIXTURE'), now())
    ON CONFLICT (tenant_id, opportunity_product_id, market) DO UPDATE
      SET state=excluded.state, evidence_grade=excluded.evidence_grade, supplier_binding=excluded.supplier_binding,
          supplier_evidence=excluded.supplier_evidence, delivery=excluded.delivery, availability=excluded.availability,
          economics=excluded.economics, market_pricing=excluded.market_pricing, freshness=excluded.freshness,
          blockers=excluded.blockers, is_fixture=excluded.is_fixture, updated_at=now();
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'state', v_state, 'evidence_grade', v_grade,
    'market', v_country, 'currency', v_ccy, 'tenant_id', p_tenant, 'product_id', p_product,
    'binding', v_binding,
    'supplier_evidence', jsonb_build_object('sku', v_sup->>'sku', 'variant', v_sup->'variant',
        'availability', v_avail, 'delivery', v_delivery, 'source', v_sup->>'_source'),
    'economics', v_econ,
    'market_pricing', v_pricing,
    'suggested_selling_price_range', v_econ->'suggested_selling_price_range',
    'blockers', to_jsonb(v_blockers),
    'freshness', jsonb_build_object('supplier_stale', v_sup_stale, 'binding_stale', v_binding_stale,
        'market_known', v_market_known, 'window_hours', p_freshness_hours),
    'persisted', (p_persist AND true),
    'integrity', jsonb_build_object(
        'fixture_cannot_validate', (v_grade='FIXTURE'),
        'contribution_target_blocks', false,
        'ad_cost_blocks', false,
        'note','target/ad are display-only; FAILED is supplier-side only (out-of-stock / unsupported delivery)'),
    'contract','pulse_stage3b_commercial_verification_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage3b_verify_commercial(uuid,uuid,text,jsonb,jsonb,jsonb,jsonb,numeric,numeric,numeric,integer,boolean,boolean,timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage3b_verify_commercial(uuid,uuid,text,jsonb,jsonb,jsonb,jsonb,numeric,numeric,numeric,integer,boolean,boolean,timestamptz) TO service_role;

-- =====================================================================================================
-- Product Card composer: authoritative identity (fn_ad_product_card_authority, UNCHANGED — Product Asset
-- Lock preserved) + the latest persisted commercial verification + market pricing, as one actionable card.
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_stage3b_product_card(p_tenant uuid, p_product uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_country text := upper(btrim(coalesce(p_market,'')));
  v_identity jsonb; v_cv public.commerce_commercial_verification%rowtype; v_has_cv boolean;
  v_actions text[] := '{}'; v_econ jsonb; v_mp jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.commerce_products WHERE id = p_product AND user_id = p_tenant) THEN
    RETURN jsonb_build_object('status','not_owned','market',v_country,'contract','pulse_stage3b_product_card_v1');
  END IF;

  v_identity := public.fn_ad_product_card_authority(p_tenant, p_product, p_market);

  SELECT * INTO v_cv FROM public.commerce_commercial_verification
  WHERE tenant_id=p_tenant AND opportunity_product_id=p_product AND market=v_country LIMIT 1;
  v_has_cv := FOUND;
  v_econ := v_cv.economics; v_mp := v_cv.market_pricing;

  IF NOT v_has_cv THEN
    v_actions := array_append(v_actions, 'RUN_COMMERCIAL_VERIFICATION');
  ELSIF v_cv.state = 'PENDING' THEN v_actions := array_append(v_actions, 'AWAIT_SUPPLIER_DETAIL');
  ELSIF v_cv.state = 'FAILED' THEN v_actions := array_append(v_actions, 'REVIEW_SUPPLIER_OR_RESELECT');
  ELSIF v_cv.state = 'PARTIAL' THEN v_actions := array_append(v_actions, 'COMPLETE_MISSING_EVIDENCE');
  ELSIF v_cv.state = 'COMMERCIALLY_VALIDATED' THEN v_actions := array_append(v_actions, 'ELIGIBLE_FOR_NEXT_STAGE_GATE');
  END IF;

  RETURN jsonb_build_object(
    'status','ok', 'product_id', p_product, 'market', v_country,
    'identity', v_identity,
    'commercial_verification', CASE WHEN v_has_cv THEN jsonb_build_object(
        'state', v_cv.state, 'evidence_grade', v_cv.evidence_grade, 'is_fixture', v_cv.is_fixture,
        'blockers', v_cv.blockers, 'updated_at', v_cv.updated_at)
      ELSE jsonb_build_object('state','NOT_VERIFIED','note','no commercial verification run yet') END,
    'economics', CASE WHEN v_econ IS NULL THEN NULL ELSE jsonb_build_object(
        'display_currency', v_econ->>'display_currency', 'landed_cost', v_econ->'landed_cost',
        'projected_contribution', v_econ->'projected_contribution', 'contribution_band', v_econ->>'contribution_band',
        'meets_target', v_econ->'meets_target', 'target', v_econ->'target',
        'suggested_action', v_econ->>'suggested_action', 'break_even', v_econ->'break_even') END,
    'market_pricing', CASE WHEN v_mp IS NULL THEN NULL ELSE jsonb_build_object(
        'status', v_mp->>'status', 'currency', v_mp->>'currency', 'observed', v_mp->'observed',
        'exact_listings', v_mp->'exact_listings', 'similar_listings', v_mp->'similar_listings',
        'sellers_deduped', v_mp->'sellers_deduped', 'freshness', v_mp->'freshness') END,
    'suggested_selling_price_range', CASE WHEN v_econ IS NULL THEN NULL ELSE v_econ->'suggested_selling_price_range' END,
    'supplier', CASE WHEN v_has_cv THEN jsonb_build_object(
        'selected_supplier_product_id', v_cv.supplier_binding->>'selected_supplier_product_id',
        'sku', v_cv.supplier_binding->>'selected_sku',
        'availability', v_cv.availability->>'value', 'delivery', v_cv.delivery->>'state') ELSE NULL END,
    'actions', to_jsonb(v_actions),
    'asset_lock','SUPPLIER_PROVIDED invariant preserved — card identity/assets come only from fn_ad_product_card_authority',
    'contract','pulse_stage3b_product_card_v1');
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage3b_product_card(uuid,uuid,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage3b_product_card(uuid,uuid,text) TO service_role;

-- Authenticated read wrapper (resolves tenant from the JWT; read-only).
CREATE OR REPLACE FUNCTION public.fn_stage3b_product_card_authenticated(p_product uuid, p_market text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('status','not_authenticated','contract','pulse_stage3b_product_card_v1'); END IF;
  RETURN public.fn_stage3b_product_card(v_uid, p_product, p_market);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage3b_product_card_authenticated(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_stage3b_product_card_authenticated(uuid,text) TO authenticated, service_role;

-- =====================================================================================================
-- Deterministic selftest (hermetic: inline fixtures, no provider calls, no persistence, same-currency to
-- avoid FX dependence). Shape: { suite, pass, fail, ok, results }.
-- =====================================================================================================
CREATE OR REPLACE FUNCTION public.fn_stage3b_commercial_verification_selftest()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  r jsonb; results jsonb := '[]'::jsonb; pass int := 0; fail int := 0;
  v_now timestamptz := '2026-10-14T12:00:00Z';
  v_fresh text := '2026-10-10T12:00:00Z';     -- 4 days old (fresh within 336h)
  v_stale text := '2026-07-01T12:00:00Z';     -- > 336h old (stale)
  t uuid := '00000000-0000-0000-0000-0000000003b0';
  p uuid := '00000000-0000-0000-0000-0000000003b1';
  bind_exact jsonb := jsonb_build_object('identity_result','EXACT_SUPPLIER_IDENTITY_RESOLVED','bound',true,
      'selected_supplier','CJDROPSHIPPING','selected_supplier_product_id','CJFIX1','selected_sku','SKU-FIX-1',
      'selected_variant', jsonb_build_object('vid','V1'), 'bound_at', v_fresh);
  bind_nobind jsonb := jsonb_build_object('identity_result','NO_VALID_CJ_MATCH','bound',false);
  -- supplier evidence: EUR cost + EUR shipping -> same-currency landed (no FX), in-stock, fresh freight to DE
  sup_good jsonb := jsonb_build_object('supplier_cost','8.00','cost_currency','EUR','shipping_cost','3.50',
      'shipping_country_codes', jsonb_build_array('DE_FR_US'), 'sku','SKU-FIX-1',
      'delivery_estimate', jsonb_build_object('est_min_days','7','est_max_days','12','destination','DE',
          'shipping_cost','3.50','shipping_currency','EUR','source','CJ_FREIGHT_CALCULATE','observed_at', v_fresh),
      'stock', jsonb_build_object('total_inventory','250','warehouse','CN','observed_at', v_fresh));
  sup_noship jsonb := jsonb_build_object('supplier_cost','8.00','cost_currency','EUR',
      'stock', jsonb_build_object('total_inventory','250','observed_at', v_fresh));  -- no shipping -> landed UNKNOWN
  sup_oos jsonb := jsonb_build_object('supplier_cost','8.00','cost_currency','EUR','shipping_cost','3.50',
      'delivery_estimate', jsonb_build_object('est_max_days','12','destination','DE','observed_at', v_fresh),
      'stock', jsonb_build_object('total_inventory','0','observed_at', v_fresh));   -- out of stock
  sup_negdel jsonb := jsonb_build_object('supplier_cost','8.00','cost_currency','EUR','shipping_cost','3.50',
      'stock', jsonb_build_object('total_inventory','250','observed_at', v_fresh),
      'delivery_estimate', jsonb_build_object('destination','DE','destination_supported','false','observed_at', v_fresh));
  sup_highcost jsonb := jsonb_build_object('supplier_cost','40.00','cost_currency','EUR','shipping_cost','3.50',
      'delivery_estimate', jsonb_build_object('est_max_days','12','destination','DE','shipping_cost','3.50','shipping_currency','EUR','source','CJ_FREIGHT_CALCULATE','observed_at', v_fresh),
      'stock', jsonb_build_object('total_inventory','250','observed_at', v_fresh));
  -- competitors: DE/EUR direct (qualify) + US/USD (foreign) + DE/GBP (wrong ccy) + category + two same-seller dups
  comp_de jsonb := jsonb_build_array(
    jsonb_build_object('competitor_identity','ShopA','observed_product_url','https://a.de/p','match_class','EXACT_PRODUCT','platform','shopify',
       'price', jsonb_build_object('amount','39.90','currency','EUR','source_class','OBSERVED','country','DE'),'price_observed_at',v_fresh,'source','SEARCH'),
    jsonb_build_object('competitor_identity','ShopB','observed_product_url','https://b.de/p','match_class','CLOSE_COMPARABLE','platform','shopify',
       'price', jsonb_build_object('amount','45.00','currency','EUR','source_class','OBSERVED','country','DE'),'price_observed_at',v_fresh,'source','SEARCH'),
    jsonb_build_object('competitor_identity','ShopA','observed_product_url','https://a.de/p2','match_class','EXACT_PRODUCT',
       'price', jsonb_build_object('amount','41.00','currency','EUR','source_class','OBSERVED','country','DE'),'price_observed_at',v_fresh),
    jsonb_build_object('competitor_identity','USSeller','match_class','EXACT_PRODUCT',
       'price', jsonb_build_object('amount','59.00','currency','USD','source_class','OBSERVED','country','US'),'price_observed_at',v_fresh),
    jsonb_build_object('competitor_identity','GBSeller','match_class','EXACT_PRODUCT',
       'price', jsonb_build_object('amount','30.00','currency','GBP','source_class','OBSERVED','country','DE'),'price_observed_at',v_fresh),
    jsonb_build_object('competitor_identity','CatSeller','match_class','CATEGORY_COMPETITOR',
       'price', jsonb_build_object('amount','20.00','currency','EUR','source_class','OBSERVED','country','DE'),'price_observed_at',v_fresh));
  comp_stale jsonb := jsonb_build_array(
    jsonb_build_object('competitor_identity','ShopA','match_class','EXACT_PRODUCT',
       'price', jsonb_build_object('amount','39.90','currency','EUR','source_class','OBSERVED','country','DE'),'price_observed_at',v_stale));
  comp_none jsonb := '[]'::jsonb;
  fees jsonb := jsonb_build_object('payment_fee_pct','0.03','platform_fee_pct','0');
  v_a jsonb; v_b jsonb; v_c jsonb;
BEGIN
  -- S1: gate — no binding -> BLOCKED_NO_BINDING, not persisted
  r := public.fn_stage3b_verify_commercial(t,p,'DE',sup_good,comp_de,bind_nobind,fees,10,25,30,336,true,false,v_now);
  IF (r->>'state')='BLOCKED_NO_BINDING' AND (r->>'persisted')='false'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S1_gate_blocks_no_binding','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S1_gate_blocks_no_binding','ok',false,'got',r->>'state')); END IF;

  -- S2: fixture full good evidence -> PARTIAL (never COMMERCIALLY_VALIDATED), evidence_grade FIXTURE
  r := public.fn_stage3b_verify_commercial(t,p,'DE',sup_good,comp_de,bind_exact,fees,10,25,30,336,true,false,v_now);
  IF (r->>'state')='PARTIAL' AND (r->>'evidence_grade')='FIXTURE' AND (r#>>'{integrity,fixture_cannot_validate}')='true'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S2_fixture_never_validated','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S2_fixture_never_validated','ok',false,'got',r->>'state','grade',r->>'evidence_grade')); END IF;

  -- S3: FAILED when out-of-stock (availability critical), regardless of economics
  r := public.fn_stage3b_verify_commercial(t,p,'DE',sup_oos,comp_de,bind_exact,fees,10,25,30,336,true,false,v_now);
  IF (r->>'state')='FAILED'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S3_failed_out_of_stock','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S3_failed_out_of_stock','ok',false,'got',r->>'state')); END IF;

  -- S4: FAILED when delivery explicitly unsupported (OBSERVED_NEGATIVE)
  r := public.fn_stage3b_verify_commercial(t,p,'DE',sup_negdel,comp_de,bind_exact,fees,10,25,30,336,true,false,v_now);
  IF (r->>'state')='FAILED'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S4_failed_delivery_negative','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S4_failed_delivery_negative','ok',false,'got',r->>'state')); END IF;

  -- S5: shipping missing -> landed UNKNOWN -> PARTIAL (NOT FAILED); shipping never assumed 0
  r := public.fn_stage3b_verify_commercial(t,p,'DE',sup_noship,comp_de,bind_exact,fees,10,25,30,336,true,false,v_now);
  IF (r->>'state')='PARTIAL' AND (r->'blockers') ? 'ECONOMICS_UNKNOWN'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S5_shipping_unknown_partial','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S5_shipping_unknown_partial','ok',false,'got',r->>'state','bl',r->'blockers')); END IF;

  -- S6: UNVIABLE contribution must NOT block (no FAILED from economics); band=UNVIABLE present
  r := public.fn_stage3b_verify_commercial(t,p,'DE',sup_highcost,comp_de,bind_exact,fees,10,25,30,336,true,false,v_now);
  IF (r->>'state')<>'FAILED' AND (r#>>'{economics,contribution_band}')='UNVIABLE'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S6_unviable_does_not_block','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S6_unviable_does_not_block','ok',false,'got',r->>'state','band',r#>>'{economics,contribution_band}')); END IF;

  -- S7: target threshold does NOT gate — state identical for target 25 vs an absurd 9999 (msg2 #8)
  v_a := public.fn_stage3b_verify_commercial(t,p,'DE',sup_good,comp_de,bind_exact,fees,10,25,30,336,true,false,v_now);
  v_b := public.fn_stage3b_verify_commercial(t,p,'DE',sup_good,comp_de,bind_exact,fees,10,9999,9999,336,true,false,v_now);
  IF (v_a->>'state') = (v_b->>'state')
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S7_target_never_gates','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S7_target_never_gates','ok',false,'a',v_a->>'state','b',v_b->>'state')); END IF;

  -- S8: market pricing country+currency isolation + dedup + exact/similar + average/low/high
  v_a := public.fn_stage3b_market_pricing(t,p,'DE','EUR',comp_de,336,v_now);
  IF (v_a->>'status')='KNOWN'
     AND (v_a#>>'{observed,sellers}')::int = 2                  -- ShopA (deduped) + ShopB
     AND (v_a#>>'{observed,lowest}')::numeric = 39.90 AND (v_a#>>'{observed,highest}')::numeric = 45.00
     AND (v_a#>>'{observed,average}')::numeric = 42.45
     AND (v_a#>>'{duplicate_sellers_removed}')::int = 1         -- second ShopA row deduped
     AND (v_a#>>'{excluded_from_local_evidence,foreign_market}')::int = 1      -- US
     AND (v_a#>>'{excluded_from_local_evidence,non_local_currency}')::int = 1  -- GBP
     AND jsonb_array_length(v_a->'exact_listings') >= 1 AND jsonb_array_length(v_a->'similar_listings') >= 1
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S8_pricing_isolation_dedup','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S8_pricing_isolation_dedup','ok',false,'got',v_a)); END IF;

  -- S9: never reuse another country's prices — same DE competitors evaluated for FR -> UNKNOWN
  v_a := public.fn_stage3b_market_pricing(t,p,'FR','EUR',comp_de,336,v_now);
  IF (v_a->>'status')='UNKNOWN' AND (v_a#>>'{observed,average}') IS NULL
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S9_no_cross_country_reuse','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S9_no_cross_country_reuse','ok',false,'got',v_a->>'status')); END IF;

  -- S10: stale-only prices -> UNKNOWN (never counted as fresh evidence)
  v_a := public.fn_stage3b_market_pricing(t,p,'DE','EUR',comp_stale,336,v_now);
  IF (v_a->>'status')='UNKNOWN' AND (v_a#>>'{freshness,stale_excluded}')::int = 1
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S10_stale_unknown','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S10_stale_unknown','ok',false,'got',v_a)); END IF;

  -- S11: no competitors -> UNKNOWN, no invented prices
  v_a := public.fn_stage3b_market_pricing(t,p,'DE','EUR',comp_none,336,v_now);
  IF (v_a->>'status')='UNKNOWN' AND (v_a#>>'{observed,average}') IS NULL
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S11_no_evidence_unknown','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S11_no_evidence_unknown','ok',false,'got',v_a->>'status')); END IF;

  -- S12: breakeven consistency — contribution_before_ads - ad_reserve == projected_contribution
  v_a := public.fn_stage3b_unit_economics(sup_good, 42.45, 'EUR', fees, 10, 25, 30, 39.90, 45.00);
  IF abs(((v_a#>>'{break_even,contribution_before_ads}')::numeric - 10) - (v_a->>'projected_contribution')::numeric) < 0.02
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S12_breakeven_consistency','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S12_breakeven_consistency','ok',false,'got',v_a)); END IF;

  -- S13: suggested price range is evidence-based within observed (low target achievable), UNKNOWN w/o
  --      observed prices, and honestly TARGET_ABOVE_MARKET when the founder target needs a price above market.
  v_a := public.fn_stage3b_unit_economics(sup_good, 42.45, 'EUR', fees, 10, 5, 10, 39.90, 45.00);   -- achievable
  v_b := public.fn_stage3b_unit_economics(sup_good, 42.45, 'EUR', fees, 10, 25, 30, NULL, NULL);     -- no observed
  v_c := public.fn_stage3b_unit_economics(sup_good, 42.45, 'EUR', fees, 10, 25, 30, 39.90, 45.00);   -- target>market
  IF (v_a#>>'{suggested_selling_price_range,status}')='EVIDENCE_BASED'
     AND (v_a#>>'{suggested_selling_price_range,high}')::numeric = 45.00
     AND (v_a#>>'{suggested_selling_price_range,low}')::numeric = 39.90
     AND (v_b#>>'{suggested_selling_price_range,status}')='UNKNOWN'
     AND (v_c#>>'{suggested_selling_price_range,status}')='TARGET_ABOVE_MARKET'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S13_suggested_price_evidence_based','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S13_suggested_price_evidence_based','ok',false,'a',v_a->'suggested_selling_price_range','b',v_b->'suggested_selling_price_range','c',v_c->'suggested_selling_price_range')); END IF;

  -- S14: tenant isolation (real mode) — unknown product for tenant -> product_not_found_for_tenant
  r := public.fn_stage3b_verify_commercial(t,p,'DE',NULL,NULL,NULL,fees,10,25,30,336,false,false,v_now);
  IF (r->>'error')='product_not_found_for_tenant'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S14_tenant_isolation','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S14_tenant_isolation','ok',false,'got',r)); END IF;

  -- S15: product card rejects cross-tenant (Product Asset Lock / isolation path)
  r := public.fn_stage3b_product_card(t,p,'DE');
  IF (r->>'status')='not_owned'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S15_card_cross_tenant_rejected','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S15_card_cross_tenant_rejected','ok',false,'got',r->>'status')); END IF;

  -- S16: stale supplier evidence -> cannot be COMMERCIALLY_VALIDATED (fixture already caps, assert blocker on real-shaped path via stale freight)
  r := public.fn_stage3b_verify_commercial(t,p,'DE',
         jsonb_build_object('supplier_cost','8.00','cost_currency','EUR','shipping_cost','3.50',
           'delivery_estimate', jsonb_build_object('est_max_days','12','destination','DE','shipping_cost','3.50','shipping_currency','EUR','source','CJ_FREIGHT_CALCULATE','observed_at', v_stale),
           'stock', jsonb_build_object('total_inventory','250','observed_at', v_stale)),
         comp_de,bind_exact,fees,10,25,30,336,true,false,v_now);
  IF (r->>'state')<>'COMMERCIALLY_VALIDATED' AND (r->'blockers') ? 'SUPPLIER_EVIDENCE_STALE'
     THEN pass:=pass+1; results:=results||jsonb_build_array(jsonb_build_object('t','S16_stale_supplier_not_validated','ok',true));
     ELSE fail:=fail+1; results:=results||jsonb_build_array(jsonb_build_object('t','S16_stale_supplier_not_validated','ok',false,'got',r->>'state','bl',r->'blockers')); END IF;

  RETURN jsonb_build_object('suite','stage3b_commercial_verification','pass',pass,'fail',fail,
    'ok',(fail=0),'results',results);
END; $function$;
REVOKE ALL ON FUNCTION public.fn_stage3b_commercial_verification_selftest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_stage3b_commercial_verification_selftest() TO service_role;

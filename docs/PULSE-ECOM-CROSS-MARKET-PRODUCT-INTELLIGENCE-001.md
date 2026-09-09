# PULSE-ECOM-CROSS-MARKET-PRODUCT-INTELLIGENCE-001

**VERDICT: PASS.** Pulse can now evaluate a product **per market** and recommend *where* it is most
promising to test — permanent production capability. Reuses the existing chain; nothing redesigned.

## Canonical model
`product_market_evaluations` (mig_160): one row per (tenant, product, country_code, score_version).
Provenance-first — every measurable field carries `source_class`; UNKNOWN stays UNKNOWN and is
**excluded** from the score denominator (never zero-filled). Home / selling / opportunity / campaign
markets remain separate concepts (unchanged on `founder_ecom_test_config`).

## Scoring model (transparent, explainable — `pm_score_v1`)
Component weights (documented, not silently invented): buyer_search_intent 22, demand_momentum 8,
marketplace_validation 15, competition_saturation_gap 10, advertising_activity 15,
market_price_support 10, supplier_availability_stock 8, landed_economics 12 (sum 100).
`fn_pm_score` = weighted mean over **KNOWN** components only; `coverage` = known-weight share;
`evidence_confidence` = HIGH ≥0.75 / MEDIUM ≥0.5 / LOW ≥0.35 / NONE. Component subscores stored
separately from the final score. `landed_economics` subscore derived from
`fn_economics_breakeven` contribution vs the €15 reserve/target.

## Hard gates (fail-closed, override score) — `fn_pm_decision`
stock (OUT_OF_STOCK→FAIL, UNKNOWN/FACTORY_ONLY→WATCH), economics (contribution<0→FAIL,
unknown→WATCH), price (OBSERVED/PLATFORM_REPORTED→PASS, ESTIMATED/INFERRED/UNKNOWN→WATCH),
compliance (CRITICAL→FAIL, HIGH/UNKNOWN→WATCH), fulfilment (no route→FAIL/WATCH). Any FAIL→AVOID;
any WATCH→WATCH (cannot TEST); else score≥70 & confidence≥MEDIUM→TEST, ≥45→WATCH, else AVOID.
A strong demand score can never override a failed stock/economics gate.

## Cross-market price intelligence
Market price is market-specific with source_class OBSERVED/PLATFORM_REPORTED/ESTIMATED/INFERRED/
UNKNOWN. A cross-market **converted** price is a reference only — it scores as INFERRED and trips the
price gate to WATCH; it can never count as local observed validation.

## Currency / provenance
Reuses the global FX system (`fn_economics_breakeven`→`normalize_money`/`get_fx_rate`). Every
converted value preserves original_amount, original_currency, converted_amount, display_currency,
fx_rate, fx_rate_source, fx_rate_timestamp. Source values are never overwritten.

## Ranking + Monday block
`fn_rank_product_markets` orders deterministically by decision-eligibility (TEST>WATCH>AVOID) →
score → confidence → contribution → country (tiebreak). It does **not** prefer home country,
configured selling market, cheapest shipping, or largest search volume. `fn_pm_monday_block` exposes
BEST MARKET TO TEST / score / why / alternatives / confidence / risks for the Monday Product
Opportunity contract. **Monday cadence unchanged; no new recurring workflow.**

## Downstream provenance
Downstream objects reference `product_id` + `country_code` + `evaluation_id` + `score_version`, so the
chain extends Product → Market Evaluation → Competitor → Supplier/Economics → Platform → Audience →
Offer → Page → Ad Studio → Campaign → Performance → Learning. The selected opportunity market does
**not** set `campaign_target_market` (separate approval/execution decision).

## Tests (13/13 PASS, deterministic fixtures — is_fixture=true)
One fixture product across FR/US/DE/GB:
1 differential scores (FR 81.3 / US 75.2 / DE 65.9 / GB 55.9) · 2 strong demand + OUT_OF_STOCK (DE)
→ AVOID · 3 strong demand + negative economics (US, contrib −20.46) → AVOID · 4 cross-market INFERRED
price (GB) → price gate WATCH, not local validation · 5 UNKNOWN stays UNKNOWN (GB coverage 0.77,
components excluded) · 6 home GB not #1 · 7 selling DE not #1 · 8 highest-volume US not #1 ·
9 ranking deterministic (identical re-run) · 10 tenant isolation (other tenant → 0 markets) ·
11 currency provenance survives (money object with fx fields) · 12 opportunity market did not mutate
campaign_target_market (still null) · 13 fixtures flagged, 0 real-acceptance rows.
Fixtures prove the engine only — they are not real product acceptance.

## Roadmap mapping (Product × Market)
- **Phase 2 — Cross-Market Product Intelligence:** ~70% (engine + ranking + Monday block built;
  full real per-market evidence assembly across all sources is incremental).
- **Phase 4 — Market-specific supplier/economics:** foundation in place (per-destination freight +
  per-market economics via fn_economics_breakeven).
- **Phase 5 — Product × Market Decision:** ~65% (per-market decision + gates live; decision-object
  persistence wiring to follow).
- **Phase 6 / 7 / 9 / 14 / 15:** market/country now a first-class key those phases can consume
  (keyword, audience/offer, Ad Studio, performance, learning all keyed by product_id + country_code).

## Safety / invariants
No founder acceptance run, no store/publish/ads/activation/spend, no Meta change, no Monday-schedule
change, no new recurring n8n workflow, no fabricated external evidence, existing Product Opportunity
gates preserved (not weakened). `campaign_activation = FALSE`; `advertising_spend = 0`; cost €/$0.
The Monday Product Opportunity Acceptance gate is **NOT** marked PASS (needs later real evidence).

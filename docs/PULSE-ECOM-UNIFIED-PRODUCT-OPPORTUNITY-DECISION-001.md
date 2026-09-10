# PULSE-ECOM-UNIFIED-PRODUCT-OPPORTUNITY-DECISION-001 + FOUNDER ADDENDUM

**VERDICT: PASS.** The canonical unified **Product × Market Opportunity Decision** now orchestrates the
existing Product × Market × Competitor × Supplier/Economics × Ad-Platform intelligence into ONE
authoritative, explainable recommendation per product × market — evidence by reference, component scores
preserved separately, hard gates that demand can never override, and a decision that is kept strictly
separate from execution readiness. WINNER is never emitted pre-launch.

## Canonical model — `product_opportunity_decisions` (mig_190)
One row per **(tenant, product, country, score_version=`pod_v1`)**. The decision unit is **product ×
market**, never a product alone and never global. Evidence stays **by reference**
(`product_market_evaluation_id`, `primary_platform_evaluation_id`, competitor rows via `lineage`) — the
component numbers stored on a decision are an explicit point-in-time **snapshot** whose authoritative
source is the referenced row. RLS on, **no permissive policy** (SECURITY DEFINER / service-role only),
REVOKE'd from PUBLIC and anon.

## Orchestration — `fn_pod_evaluate` (mig_191 / mig_194)
Pulls the country-specific market evaluation (market/economics/gates), the best **eligible** acquisition
channel for that market, and competitor signals (already folded into the market score), then produces:

- **Component scores preserved separately** — `product` / `market` / `platform` / `competitor` /
  `supplier`, each with its own subscore, confidence, `source_ref`, and scope. Nothing is averaged away.
- **Composite** (`product_opportunity_score`) — a market-led blend of **market (70)** + **acquisition
  channel (30)** over KNOWN dimensions only (competitor/supplier/product already live inside the market
  score, so they are surfaced diagnostically and never double-counted). UNKNOWN dimensions are excluded,
  never zero-filled; `coverage` is exposed.
- **Opportunity band** (0-39 AVOID · 40-54 WATCH · 55-69 TRENDING_WATCH · 70-79 STRONG_TEST · 80-89
  HIGH_CONFIDENCE_TEST · 90-100 EXCEPTIONAL).
- **Overall evidence confidence** = the **weakest** contributing tier (never averaged), capped to MEDIUM
  when the local price is unvalidated/foreign or when no acquisition channel is known.

## Hard gates override the score (fail-closed)
`supplier` (stock), `market_price`, `economics`, `compliance`, `fulfilment` mirror the market
evaluation's gate state. Any FAIL → **AVOID**; any WATCH → **WATCH** (cannot TEST) — a strong score can
never buy past a failed stock/economics/price gate. Proven: DE AVOIDs on out-of-stock at score 65.9; US
AVOIDs on negative economics at score 75.2.

## Decision vs execution (kept separate)
- **Decision blockers** prevent a TEST *decision* (out-of-stock, negative economics, price not locally
  validated, compliance, fulfilment).
- **Execution blockers** prevent *execution only* and **never change the decision**
  (`EXECUTION_PLATFORM_API_BLOCKED` for Google Ads, `EXECUTION_PLATFORM_NOT_CONNECTED` for TikTok,
  `NO_EXECUTABLE_PLATFORM_IDENTIFIED`). Proven: a product can be **TEST** with the best channel
  execution-**BLOCKED** — `action_gating = DECISION_TEST_EXECUTION_BLOCKED`, decision unchanged.
- **Action gating**: NO_ACTION / MONITOR_GATHER_EVIDENCE / ELIGIBLE_FOR_LAUNCH_PREP /
  DECISION_TEST_EXECUTION_BLOCKED (all still subject to founder approval).

## Lifecycle — HIGH_CONFIDENCE_TEST is the pre-launch ceiling
`AVOID` / `WATCH` / `TRENDING_WATCH` / `STRONG_TEST_CANDIDATE` / `HIGH_CONFIDENCE_TEST`. An EXCEPTIONAL
band (score ≥ 90) is still **capped** to HIGH_CONFIDENCE_TEST — **WINNER is reserved for post-launch real
evidence** and is never emitted here.

## Economics + CPA scenarios
`economics_ref` references the market evaluation's break-even and reserve figures. `cpa_scenarios` shows
contribution and state at CPA **€10 / €15 / €20** (VIABLE ≥ €15 / THIN ≥ €0 / NEGATIVE) — surfacing, for
example, a viable product whose margin turns NEGATIVE at a €20 acquisition cost. €15 ad reserve and the
€15-20 target contribution model are preserved.

## Founder Addendum — Product × Country metric provenance
- **Every market-dependent metric identifies product AND country** — `country_code` is mandatory; there
  is no global decision row.
- **Country isolation** — each market is judged only on its own local evidence; US evidence never
  contaminates DE (independent gates, blockers, and scores per country).
- **`metric_scope`** — LOCAL (OBSERVED/PLATFORM_REPORTED price) vs CROSS_MARKET_REFERENCE (converted
  foreign INFERRED price) vs LOCAL_UNVALIDATED. A **CROSS_MARKET_REFERENCE can never satisfy the local
  price gate** — it trips WATCH + `MARKET_PRICE_NOT_LOCALLY_VALIDATED`.

## Founder Addendum — Product × Market tournament (`fn_pod_tournament`, mig_192)
Refreshes a unified decision for **every** market the product has evidence in, then ranks the **product ×
market combinations** deterministically (TEST > WATCH > AVOID → score → confidence → contribution →
country). **Product rollup** identifies the **BEST MARKET** — which is never auto the home, selling, or
campaign market and **never sets `campaign_target_market`**. **Cross-market recovery**: a product that
fails in one market is re-evaluated across all its markets and is **never globally rejected** on a single
market's failure. Proven: a product AVOIDs in DE (stock) and US (economics) yet **recovers to a TEST in
FR** and a WATCH in GB — best market FR.

## Monday contract (`fn_pod_monday_block`, mig_192)
BEST_MARKET / DECISION / LIFECYCLE / SCORE / BAND / CONFIDENCE / WHY / BEST_AD_PLATFORM / METRIC_SCOPE /
DECISION_BLOCKERS / EXECUTION_BLOCKERS / CPA_SCENARIOS / ACTION_GATING / CROSS_MARKET_ALTERNATIVES.
**Contract only — not wired to any recurring schedule; Monday cadence unchanged.** The Monday Product
Opportunity Acceptance gate is **NOT** marked PASS (that requires real external evidence).

## Tests — 44/44 PASS (30 base + 14 addendum, deterministic fixtures `is_fixture=true`)
**Base 1-30:** engine produces per-market decisions · score bounded · five component scores preserved ·
coverage exposed · band mapping (HIGH_CONFIDENCE_TEST, EXCEPTIONAL) · EXCEPTIONAL lifecycle capped ·
never WINNER · supplier gate overrides score (DE) · economics gate overrides score (US) · price gate →
WATCH · TEST needs gates+score≥70+conf≥MEDIUM · decision≠execution blockers · execution readiness never
changes decision · action gating (blocked vs eligible) · CPA 3-tier scenarios crossing NEGATIVE ·
weakest-tier confidence · evidence by reference (pme_id, platform_eval_id) · deterministic tournament ·
best market not home/selling · Monday contract shape · tenant isolation · fixtures ≠ real acceptance ·
campaign_activation FALSE · advertising_spend 0 · campaign_target_market untouched.
**Addendum 51-64:** country_code mandatory · no global row · DE/US isolation · foreign INFERRED →
CROSS_MARKET_REFERENCE · cross-market ref can't satisfy local gate · OBSERVED → LOCAL · cross-market
recovery (not globally rejected) · recovered markets non-empty despite failures · tournament ranks
product×market combos · product rollup best-market · best market ≠ campaign market · each market on its
own evidence · metric_scope on every row · component `source_ref` = that country's pme_id.
Fixtures prove the engine only — they are **not** real product acceptance.

## Final founder-gate additions (mig_195–200)
- **Product Confidence** — a canonical `product_confidence ∈ {HIGH, MEDIUM, LOW}` **only**, kept
  separate from `product_opportunity_score`, market/platform scores, `overall_evidence_confidence`, and
  the TEST/WATCH/AVOID decision. A high numeric score never auto-creates HIGH confidence: it is capped by
  weak local price provenance, UNKNOWN saturation, or unverified stock/economics. Proven: a product×market
  scoring **85.4** with a converted-foreign (INFERRED) price resolves to **Product Confidence MEDIUM,
  decision WATCH**.
- **Saturation gates TEST eligibility** — the same product × country saturation state (from the competitor
  engine) is a hard gate: **VERY_HIGH → WATCH** (demand can never override it); **HIGH → WATCH** unless an
  evidence-backed defensible gap **and** STRONG/PROMISING headroom justify a bounded exception;
  **MODERATE/LOW → eligible**; **UNKNOWN → fail-closed to WATCH** and never read as LOW.
- **Advertising Headroom** — `STRONG / PROMISING / WEAK / INSUFFICIENT_EVIDENCE` from the €10/€15/€20
  economic **stress** scenarios (never CPA forecasts) plus saturation context. Competition is **never**
  converted to bid/CPC/CPA cost; evidence-backed price compression downgrades headroom one tier.
- **Opportunity Sweet Spot** — `STRONG / PROMISING / WEAK / INSUFFICIENT_EVIDENCE`, a **combination**
  (validated demand + manageable saturation + usable supplier + verified stock + defensible local price +
  viable economics + headroom + confidence), not another score.
- **Tournament is an opportunity finder, not a popularity finder** — ranks product × market by
  decision → sweet-spot → saturation penalty → score → product confidence → headroom → contribution →
  country. Proven mandatory invariant: a higher-demand, VERY_HIGH-saturation, compressed USA candidate
  **loses** to a lower-demand, MODERATE-saturation, stronger-headroom Germany candidate; and the same
  product can be **WATCH in the USA (VERY_HIGH) and TEST in Germany (MODERATE)** — US saturation never
  contaminates DE.

## Founder-gate tests — 24/24 PASS (A–X) + 44/44 base retained (68 total)
A product_confidence only HIGH/MEDIUM/LOW · B score≠confidence · C high score + weak evidence≠HIGH · D LOW
saturation + no demand≠TEST · E VERY_HIGH prevents TEST · F HIGH without gap≠TEST · G HIGH bounded
exception needs gap+headroom · H MODERATE stays eligible · I UNKNOWN≠LOW · J UNKNOWN fails closed · K demand
can't override VERY_HIGH · L ad count≠CPC/CPA/ROAS · M competition doesn't fabricate bid cost · N stress
from economics not competition · O headroom doesn't predict CPA · P Sweet-Spot STRONG needs manageable
competition · Q price compression downgrades headroom · R gap requires evidence · S saturated-USA loses to
moderate-Germany · T same product WATCH-US/TEST-DE · U US saturation doesn't contaminate DE · V tournament
best combination · W product rollup best market · X Monday exposes the new fields per-country.

## Reuse (nothing re-implemented)
`fn_pm_score` (composite), `fn_evaluate_product_market` / `product_market_evaluations` (market + gates +
economics), `fn_ppf_evaluate` / `product_market_platform_evaluations` (acquisition channel),
`fn_pmc_*` / `product_market_competitors` (competitor signals), `fn_economics_breakeven` + FX. No Monday
assembler wired; no founder acceptance run.

## Roadmap impact — Phase 5: Product × Market Decision
The canonical decision object now unifies Phases 2-9/14-15 signals into one explainable recommendation
keyed by product_id + country_code + evaluation ids + `pod_v1`, so downstream (Audience/Offer, Keyword,
Product Page, Ad Studio, Campaign Planning, Manual/Bounded Launch, Performance, Learning) consume ONE
decision and future real results can link back. **Monday Product Opportunity Acceptance NOT marked PASS.**

## Safety / invariants
No Monday assembler wired, no founder acceptance run, no workspace publish, no page/ads/campaign, no
Google Ads bypass, no fabricated TikTok evidence, no Monday-cadence change, no new recurring workflow,
existing paused Meta proof campaign untouched, no secrets exposed. Overall paid-beta engineering
readiness ≈ **84%** (unchanged). `campaign_activation = FALSE`; `advertising_spend = 0`; cost €/$0.

# PULSE-ECOM-PRODUCT-MARKET-COMPETITOR-INTELLIGENCE-001

**VERDICT: PASS.** Permanent Phase-3 capability: for a product × market, Pulse answers WHO sells it,
WHERE, at WHAT observed price, WHERE they advertise, HOW crowded the market is, WHAT creative/offer
patterns are visible, and WHAT evidence-backed gaps exist — all intelligence/reference only.

## Canonical model
`product_market_competitors` (mig_170): one row per observed competitor per (tenant, product, country),
linked to `product_market_evaluations.id`. Metrics-safe by construction — there are **no**
sales/revenue/ROAS/conversion columns; only observable counts and reference patterns. Competitor
creative is stored as a **pattern label**, never as a reusable Pulse asset.

## Product matching
`match_class` ∈ EXACT_PRODUCT / CLOSE_COMPARABLE / CATEGORY_COMPETITOR / UNRELATED with confidence +
evidence. **Direct metrics = EXACT + CLOSE only**; CATEGORY and UNRELATED are excluded from direct
counts, local price median, and saturation. Keyword overlap alone never counts as direct competition.

## Competitor identity & privacy
Identity preserved only where the source permits: Meta advertiser page (public Ad Library) is kept;
**eBay/marketplace seller identity is never persisted** (listing-level only). Verified: 0 EBAY rows
carry an identity; Meta advertiser identities retained. Existing privacy restrictions not weakened.

## Price intelligence (market-specific)
Each price keeps original amount/currency, normalized amount, FX provenance (if converted), country,
source_class (OBSERVED/PLATFORM_REPORTED/ESTIMATED/INFERRED/UNKNOWN), timestamp. Local median/range/
sample are computed **only** from direct matches in the local country + local currency + OBSERVED/
PLATFORM_REPORTED. A converted foreign price is a reference only and is excluded from local validation.

## Advertising intelligence
Observable ads per competitor/platform, creative/offer/CTA pattern taxonomy (PROBLEM_SOLUTION,
PRODUCT_DEMO, UGC_STYLE, BEFORE_AFTER, FEATURE_LED, LIFESTYLE, OFFER_LED, COMPARISON, SOCIAL_PROOF) —
classified only where observable evidence supports it. Competitor creative is reference; never copied,
never persisted as a Pulse advertising asset.

## Metrics safety (mandatory)
Observable ad counts / listing counts / search volume are never transformed into sales, revenue,
profit, ROAS, conversion, CPA, or "winning-ad" claims. Every output block carries a metrics_safety note.

## Saturation model (deterministic, explainable)
`saturation_points = direct*15 + observable_ads*4 + direct_listings*1.5` → LOW <20, MODERATE <45,
HIGH <70, VERY_HIGH ≥70; UNKNOWN when no evidence. Confidence from evidence coverage. Demand and
competition are interpreted together downstream (more competitors ≠ automatically bad).

## Opportunity gaps (evidence-backed)
CREATIVE_ANGLE_GAP, PRICE_POSITIONING_GAP, PLATFORM_GAP, OFFER_GAP (+ extensible). Each gap carries
gap_type + evidence + confidence + why_it_matters; produced only when evidence supports it.

## Cross-market isolation
Evaluated per country; the same product yields different competition per market (proven: DE VERY_HIGH
direct 5 vs GB HIGH direct 2). Output links to `product_market_evaluations.id`. No global aggregation.

## Product × Market score integration
`fn_pmc_evaluate` exposes a `score_components` adapter (competition_saturation_gap, advertising_activity,
market_price_support, evidence_confidence) that the existing `pm_score_v1` engine consumes **without any
weight change** — the narrowest safe adapter.

## Monday contract extension
`fn_pmc_monday_block`: WHO_IS_SELLING_IT / WHERE / OBSERVED_PRICES / COMPETITION_LEVEL /
OBSERVABLE_AD_ACTIVITY / ADVERTISING_PLATFORMS / CREATIVE_OFFER_PATTERNS / OPPORTUNITY_GAPS /
EVIDENCE_CONFIDENCE. **Monday cadence unchanged; no new recurring workflow.**

## Downstream
Consumable by Market Selection, Product Decision, Keyword, Audience/Offer, Product Page, Ad Studio
(patterns only, never protected creative), Platform Intelligence, Campaign Planning, Performance,
Learning — keyed by product_id + country_code + product_market_evaluation_id.

## Tests — 16/16 PASS (deterministic fixtures, is_fixture=true)
1 EXACT/CLOSE distinguishable · 2 UNRELATED excluded · 3 DE↔GB isolation (VERY_HIGH/5 vs HIGH/2) ·
4 foreign converted price excluded from local median · 5 UNKNOWN stays UNKNOWN · 6 ad count ≠ sales ·
7 active ad ≠ winning ad · 8 listing count ≠ units · 9 saturation deterministic · 10 gaps require
evidence · 11 tenant isolation (other tenant 0) · 12 privacy (0 eBay identities; Meta permitted) ·
13 pme link preserved · 14 currency provenance survives (59.99 USD→51.65 EUR, ECB fx + timestamp) ·
15 fixtures cannot satisfy real acceptance (0 real rows) · 16 competitor creative not a reusable asset
(0 media assets from competitor). Fixtures are engineering-only; they do NOT satisfy Monday acceptance.

## Roadmap — Phase 3: Product × Market × Competitor Intelligence
Monday Product Opportunity must eventually answer WHO is selling this / WHERE / at WHAT observed price /
WHERE they advertise / HOW crowded / WHAT patterns / WHAT gaps / WHAT evidence. **Final acceptance
requires REAL external competitor evidence** — the Monday Product Opportunity Acceptance gate is NOT
marked PASS here.

## Safety / invariants
No founder acceptance run, no store/page/ads/activation/spend, no Meta change, no Monday-cadence change,
no new recurring workflow, no fabricated competitor metrics, no protected creative copied, existing
Product Opportunity gates preserved. `campaign_activation = FALSE`; `advertising_spend = 0`; cost €/$0.

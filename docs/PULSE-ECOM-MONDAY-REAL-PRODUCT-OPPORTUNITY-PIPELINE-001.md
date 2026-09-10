# PULSE-ECOM-MONDAY-REAL-PRODUCT-OPPORTUNITY-PIPELINE-001

**VERDICT: PARTIAL — `REAL_PIPELINE_CONNECTED = PASS`; automated Monday scheduled delivery has NOT yet
run on a real Monday (stated separately). `FINAL_FOUNDER_PRODUCT_ACCEPTANCE` remains NOT PASS (next unit).**

Real external source evidence now traverses the complete engine chain and produces an honest,
non-forced unified Product Opportunity Decision.

## Audit — what was real vs empty
Before this unit, **all four engine tables were 100% fixtures (real rows = 0)** — the engines had never
been fed real evidence. Real source data that *did* exist: 396 CJdropshipping supplier products, 107
`commerce_signals` (90 MARKETPLACE_ACTIVITY / 11 COMMUNITY_ATTENTION / 5 ADVERTISING_ACTIVITY / 1
SEARCH_DEMAND), 33 `market_price_observations` (eBay Browse: GB/DE/US/FR), 12 `commerce_products`
candidates, 203 `fx_rates`. `commerce_product_opportunities` = 0 (never generated).

## Production assembler (`fn_assemble_real_product_market`, mig_201)
Reads REAL sources and feeds the existing engines with `is_fixture=FALSE`, provenance preserved:
`commerce_products` (identity + tenant) · `commerce_signals` (Reddit community demand, eBay marketplace
presence) · `market_price_observations` (eBay Browse local price → PLATFORM_REPORTED / LOCAL) ·
`commerce_supplier_products` (CJ cost + destination freight enrichment). It then invokes
`fn_evaluate_product_market` → `fn_pmc_evaluate` → (`fn_ppf_evaluate` only where real platform evidence
exists) → `fn_pod_tournament`. **Nothing fabricated:** missing destination freight → economics UNKNOWN →
WATCH; CJ active-listing status is not a hard quantity → `stock_state = UNKNOWN` (never silently
IN_STOCK); no real Meta/DataForSEO evidence → no platform row (execution blocker, decision unaffected).

## Product identity & market set
Candidate resolved by `commerce_products` id; supplier matched by category to a real CJ product; local
price joined by localized query. The market set (DE/FR/GB/US) was **derived from real source coverage**
(`market_price_observations`), not hardcoded to home/selling/largest/USA. Competitor observations are real
eBay listings — **no seller identity persisted** (eBay account-deletion exemption) and never converted to
sales/revenue/ROAS/CPA/winning-ad.

## Real-source verification candidate
**"kids nightlight projector"** (`commerce_products` e453eed4, tenant 7c8ddf9d), CJ supplier "USB
Projection Lamp … Starry-sky Projector Night Light" (cost 5.73 USD, CJ freight to GB 4.50 USD, 5–9 days).
Real eBay Browse local medians: GB £7.90 (743 listings) · US $18.33 (3967) · DE €20.95 (69) · FR €36.00 (7).

| Market | Decision | Score | Confidence | Saturation | Headroom | Why (real) |
|---|---|---|---|---|---|---|
| **FR** (best) | WATCH | 79.4 | LOW | MODERATE | INSUFFICIENT_EVIDENCE | no dest freight → economics UNKNOWN; stock/compliance UNKNOWN |
| DE | WATCH | 79.4 | LOW | HIGH | INSUFFICIENT_EVIDENCE | HIGH saturation, no defensible gap; economics UNKNOWN |
| US | WATCH | 79.4 | LOW | VERY_HIGH | INSUFFICIENT_EVIDENCE | VERY_HIGH saturation; economics UNKNOWN |
| **GB** | **AVOID** | 61.4 | MEDIUM | VERY_HIGH | WEAK | full chain: landed 10.23 USD vs £7.90 median → contribution **−14.88**; VERY_HIGH |

**Product-level decision: WATCH.** Best market FR (least saturated). Cross-market recovery: GB failed,
DE/FR/US recovered, product not globally rejected. **The decision was NOT weakened to produce a TEST** —
this is a genuine, honest non-TEST outcome from real commodity-priced evidence.

## Real vs fixture separation
REAL: 1 candidate · 4 Product×Market evaluations · 24 competitor observations · 0 platform evaluations
(honest — no real ad-platform evidence for this product) · 4 unified decisions. FIXTURE (unchanged): 19
pme / 34 pmc / 12 ppf / 17 pod. Fixtures are excluded from every real count.

## Tests — 27/27 PASS (real-source + regression)
Real rows flagged non-fixture w/ real provenance · fixtures separated · identity match (CLOSE, no
UNRELATED) · market isolation · US VERY_HIGH ≠ DE HIGH (no contamination) · real eBay price → LOCAL ·
UNKNOWN stock never TEST · negative economics → GB AVOID · VERY_HIGH not TEST · HIGH w/o gap not TEST ·
no real market forced TEST · product_confidence HIGH/MEDIUM/LOW · confidence≠score (FR score 79.4 /
confidence LOW / WATCH) · competitor table has no sales/ROAS columns · eBay listings not performance · no
Google CPC→CPA (no fabricated platform) · TikTok missing stays missing · platform opportunity ≠ execution
· tournament ranks Product×Market (FR #1 least saturated) · Monday labels metrics with country · price
evidence preserves country+source+observed_at · currency provenance survives (GB landed FX) · tenant
isolation · campaign_target_market null · no WINNER · campaign_activation FALSE · advertising_spend 0.

## Monday scheduled-delivery status (stated separately)
The real evidence **collectors** exist as **manual** n8n workflows (CJ Supplier Collector, eBay Browse
Probe, Reddit Product-Attention Adapter, DataForSEO Probe, CJ Freight Probe — all inactive/manual); only
the **FX Refresher** runs on a schedule (the sanctioned daily exception). The unified Product Opportunity
assembler + decision is now DB-native and proven on real data via **manual** verification. **Automated
Monday scheduled delivery of the unified Product Opportunity has NOT yet run on a real Monday schedule**,
and per this unit's safety rules no new recurring cadence was added.

## External blockers (not hidden)
`BLOCKED_EXTERNAL_GOOGLE_ADS_API` (Google Ads execution blocked; intelligence may continue) ·
`INSUFFICIENT_EXTERNAL_TIKTOK_INTELLIGENCE` (no standalone real source) · `DEFERRED_POST_LAUNCH_BUDGET`
(BigBuy) · `DEFERRED_NON_BLOCKING` (AliExpress). None blocked the CJ/eBay/Reddit real path.

## Permanent chain (roadmap)
DISCOVER → PRODUCT×MARKET → COMPETITORS → SUPPLIER/STOCK → LOCAL PRICE → ECONOMICS → SATURATION →
HEADROOM → PLATFORM → UNIFIED DECISION → MONDAY PRODUCT OPPORTUNITY. Intelligence-contract extensions are
complete and now fed by REAL evidence. **Final founder product acceptance remains the next unit.**

## Safety / invariants
No final founder acceptance run, no store/page/ads/campaign, no Meta activation, no spend, no recurring
cadence change, no fabricated external evidence. `campaign_activation = FALSE`; `advertising_spend = 0`;
cost €/$0. Overall paid-beta engineering readiness ≈ **84%** (unchanged).

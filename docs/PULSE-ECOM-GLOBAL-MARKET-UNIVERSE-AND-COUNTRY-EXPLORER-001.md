# PULSE-ECOM-GLOBAL-MARKET-UNIVERSE-AND-COUNTRY-EXPLORER-001

**VERDICT: PASS.** Two permanent founder addenda are implemented as backend **data contracts**
(Claude owns the contract; Lovable builds the customer-facing UI later): (1) a **Global Ecommerce
Market Universe** with a two-stage screen→deep-validate architecture, and (2) an **Interactive
Same-Product Country Opportunity Explorer**. No fixed DE/GB/FR/US universe; country isolation,
local pricing, and country-specific economics/saturation/platform are preserved. **No competing
market-intelligence system was built** — existing contracts are reused. Nothing published; no ads,
no spend.

## Reuse audit (built on, not duplicated)
`provider_capability_registry` (per-market source coverage) · `product_market_evaluations`
(deep Product×Country store) · `product_market_platform_evaluations` (×Platform) · `fx_rates`
(global currency) · `marketing_spend_authority.allowed_markets` (selling constraint, read-only).

## 1. Global Ecommerce Market Universe — `ecommerce_market_universe` (mig_214)
Configurable, provider-independent country model: `country_code, country_name, region,
default_currency, currency_supported, supplier_supported, search/marketplace/advertising/
campaign_execution_supported, ecommerce_eligible, evidence_coverage, status, is_operator_config,
authoritative_dataset, basis`. **Eligibility is capability-derived** from real Pulse coverage —
never wealth/size assumptions, never fabricated. `fn_market_universe_sync()` recomputes every
non-operator row from `provider_capability_registry` (market-specific row wins over `*`) + `fx_rates`.
- **35 markets · 18 ELIGIBLE · 17 LIMITED_EVIDENCE · 0 fabricated.** Regions: Europe 17, APAC 11,
  NA 2, LATAM 2, MEA 3.
- Meta advertising correctly restricted to the **7 registered markets** (DE/ES/FR/GB/IE/IT/NL);
  **US is ELIGIBLE but advertising UNSUPPORTED** (no assumed global Meta). eBay marketplace coverage
  registered from the documented Browse marketplace set (18 markets).

**Reported dependency (not fabricated):** Pulse holds **no authoritative global
ecommerce-eligibility dataset** (all ~195 countries + adoption metrics). The universe is therefore
limited to verified-coverage markets and is **configurable** (`authoritative_dataset` + operator
rows) to ingest one later. `BLOCKED_EXTERNAL: AUTHORITATIVE_GLOBAL_ECOMMERCE_ELIGIBILITY_DATASET`.

## 2. Stage A — Global Market Screen · `fn_market_candidacy_screen` (mig_215)
Answers only *"which countries deserve deep Product×Country validation?"* using **already-held
signals only — 0 external API calls**. Documented weighting: base eligibility 40/20 +
evidence_coverage×25 + advertising 10 + existing-local-price 15 + demand-signal 10 (cap 100).
Separate from Product Opportunity Score/Confidence/Sweet Spot/Headroom. Dynamic shortlist (no fixed
N; threshold parameterized). Example (real kids projector): 35 screened → 7 Meta markets @85,
other eligible @70, LIMITED @42.5; shortlist = 18 ELIGIBLE. **Two-stage cost control**: expensive
per-product×country intelligence runs only on the shortlist in Stage B.

## 3. Same-Product Country Opportunity Explorer (mig_216)
- **`fn_product_country_explorer(tenant, product_id, selling_markets)`** — consumes
  `product_market_evaluations` + platform evals + universe. Returns the recommended **BEST MARKET**,
  a per-country card for every ELIGIBLE/LIMITED/evaluated market (decision, score, confidence, buyer
  intent, local price+currency+source_class, competition/saturation, marketplace/advertising
  activity, stock, gate_state, economics, **€10/€15/€20 CPA scenarios in local currency** via FX,
  primary platform), and `evaluation_state` ∈ EVALUATED / ANALYSIS_REQUIRED / LIMITED_EVIDENCE /
  UNSUPPORTED. Keeps **global opportunity** separate from **best-within-selling-markets**.
- **`fn_market_comparison(tenant, product_id, countries[])`** — same-product side-by-side.
- **`fn_country_evaluation_state(tenant, product_id, country)`** — on-demand state; an unevaluated
  ELIGIBLE market returns **ANALYSIS_REQUIRED** (never fabricated, *missing evidence is never
  favorable*).

### Acceptance proof (fixture product `f1f1f1f1…0001`)
| Country | Decision | Score | Buyer intent | Local price | CPA scenarios | Note |
|---|---|---|---|---|---|---|
| 🇫🇷 FR | **TEST** ★ | 81.3 | 78 | €39.99 OBSERVED | €10→+13.89 … in EUR | **recommended** |
| 🇬🇧 GB | WATCH | 55.9 | 60 | £30 INFERRED | in **GBP** via FX | |
| 🇺🇸 US | AVOID | 75.2 | **100** | $14.99 OBSERVED | **negative** in USD | demand ≠ opportunity |
| 🇩🇪 DE | AVOID | 65.9 | 70 | €34.99 OBSERVED | — | **OUT_OF_STOCK** gate |

**Best market = FR (the only TEST)** even though US has the highest buyer intent (100) and score
is not the sole ranker — decision tier wins, not country size. Country isolation holds: each card is
that country's own evidence; US cannot satisfy DE. Selling-market split verified: constrain to
{GB, DE} → `global_opportunity` stays **FR**, `best_within_selling` = **GB** (WATCH beats DE AVOID).
On-demand states verified: NL→ANALYSIS_REQUIRED, JP→LIMITED_EVIDENCE, FR→EVALUATED, XX→UNSUPPORTED.

## Safety / invariants
Business home market and `campaign_target_market` **not overwritten**; selecting a country
**never authorizes** campaign creation/activation/spend (`spend_authorized:false`). Currencies
dynamic (29 FX quote currencies). No customer publication (`commerce_product_opportunities`=0,
`daily_briefs`=5 unchanged); paused Meta proof campaign untouched; `campaign_activation`=FALSE;
`advertising_spend`=0; **no new recurring schedules**. Overall paid-beta engineering readiness
≈ **84%** (unchanged; global market-selection contract now in place).

## Downstream (not built here)
Selected Product×Country context is the contract Store Builder and Ad Studio will consume
(product→country→currency→price→audience→platform→creative→store→campaign continuity). Lovable will
implement the customer-facing country selector + comparison UX against these functions.

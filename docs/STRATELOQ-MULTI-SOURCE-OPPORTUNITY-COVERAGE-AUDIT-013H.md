# STRATELOQ-MULTI-SOURCE-OPPORTUNITY-COVERAGE-AUDIT-013H

**FINAL VERDICT: `PARTIAL_MULTI_SOURCE`.** The *architecture* is genuinely multi-source and is **not**
Reddit-dependent by design: an authoritative `provider_capability_registry` registers **5 independent
evidence categories** (Community, Marketplace, Advertising, Search-demand, Supplier), the WPS V2 evaluation
scores **8 evidence dimensions**, and `fn_evidence_confidence` explicitly rewards **independent source
categories** (not signal volume). However the *founder's actual decisions* are thin — backed by only **2
categories** (Reddit demand + eBay marketplace/saturation); the DataForSEO search-intent, Meta advertising
and CJ supplier dimensions are **empty** for the scored products, so `evidence_confidence` correctly reads
NONE/LOW. Read-only audit — nothing implemented, no data/Lovable/publish change.

---

## 1. Complete source inventory (authoritative: `provider_capability_registry`)
| Source | Evidence category | Availability | Geography |
|---|---|---|---|
| **REDDIT** | COMMUNITY | AVAILABLE | CROSS_MARKET (`*`) — "not market-specific demand proof" |
| **EBAY** (Browse API) | MARKETPLACE | AVAILABLE | 18 markets (US/GB/DE/FR/IT/ES/NL/IE/AT/BE/CH/PL/AU/CA/HK/SG/MY/PH) |
| **META_AD_LIBRARY** (v26.0) | ADVERTISING | AVAILABLE GB/DE/IE/FR/ES/IT/NL; `SOURCE_UNSUPPORTED` elsewhere (commercial archive = EU/EEA+UK only) |
| **DATAFORSEO** | SEARCH_DEMAND | AVAILABLE | GLOBAL — Google-Ads-derived; volume ESTIMATED, intent INFERRED, CPC PLATFORM_REPORTED |
| **GOOGLE_ADS** (direct) | SEARCH_DEMAND | **SOURCE_BLOCKED** — "BLOCKED_EXTERNAL_APPROVAL (no developer token)" | GLOBAL |
| **CJ** (Dropshipping) | SUPPLIER | AVAILABLE | MARKET_SPECIFIC (freight per destination; reliability not observable) |
Plus an **upstream global trend layer** (`trend_signals`, Pulse core): google_news 67,772 · industry_blog
54,561 · reddit 52,759 · google_trends 1,100 · youtube 2 · hacker_news 1. This feeds candidate discovery,
not per-product-market evidence.

## 2. Current ingestion architecture
Entry: edge functions `start-discovery` (website/discovery) + `prepare-product`; orchestration by **n8n**
(external; registry proof "SM-003I real n8n exec 30080"); ingestion RPCs `acquire_commerce_candidates_from_trends`,
`normalize_commerce_products_from_run`, `ingest_search_demand` / `fn_ingest_search_demand_for_product`
(DataForSEO), `fn_ingest_meta_ads` / `ingest_advertising_activity` (Meta), `ingest_cj_supplier_products`
(CJ), eBay Browse ingestion → `commerce_signals` / `product_market_competitors` / `commerce_supplier_products`
→ `fn_assemble_real_product_market` → `fn_evaluate_product_market` → `product_market_evaluations` →
`product_opportunity_decisions`.

## 3. Reddit / community
Source REDDIT via the trend layer + community-attention extraction → `commerce_signals` type
`COMMUNITY_ATTENTION` (provenance `source=reddit`). Founder: **11 rows**; value carries `market`,
`subreddit`, `attention_basis`, `mention_context`, `source_platform`, `intent_indicators`. Feeds the
`demand_momentum` dimension (founder red-light-mask: `{source:reddit, subscore:70, OBSERVED}`). Registry
explicitly flags it **CROSS_MARKET, not market-specific demand proof** — correctly de-weighted. It
contributes to scoring but as **one** category (30-pt cap shared across ≤4 categories in
`fn_evidence_confidence`).

## 4. Google / search demand
A. Google Search — not a direct source. B. Google Trends — in the upstream `trend_signals` (1,100 rows),
candidate discovery only. C. **Google Ads direct — `SOURCE_BLOCKED` (no developer token)** — do not
re-apply. D. Keyword Planner — n/a directly. E. **DataForSEO — AVAILABLE, GLOBAL** = the Google-Ads-derived
workaround: search demand (volume ESTIMATED), buyer-intent (INFERRED), CPC (PLATFORM_REPORTED), seasonality,
related/commercial queries → `SEARCH_DEMAND` signals + the `buyer_search_intent` dimension. So Strateloq
**can** obtain search demand/intent/CPC via DataForSEO today; only the direct Google Ads API is blocked.
Founder `SEARCH_DEMAND` signals globally = 1; `buyer_search_intent` is **empty** on the founder's scored
products (DataForSEO not run for them).

## 5. TikTok
**NOT_BUILT** as an intelligence source — absent from `provider_capability_registry`, no `commerce_signals`,
no ingestion function, no table. TikTok appears in the repo only in publishing/social-ad-execution policy
and conversion-template docs (execution context), never as evidence. No Creative Center / trending / ads /
hashtag ingestion.

## 6. Meta / Facebook / Instagram — separate execution vs discovery
- **CAMPAIGN EXECUTION** (built): `marketing_campaign_drafts`/`_executions`, `meta-capi-adapter`,
  `meta-insights-reader`, campaign builder.
- **MARKET/COMPETITOR DISCOVERY** (built, provider-limited): **Meta Ad Library** (`fn_ingest_meta_ads`,
  `fn_meta_ad_*`) → `commerce_signals` `ADVERTISING_ACTIVITY` (5 global) + `product_market_competitors`
  (3 META_AD_LIBRARY). Observes competitor ads, advertiser presence, offer/creative/CTA patterns, ad
  status/longevity. **Geography-limited to EU/EEA+UK commercial ads** (registry); elsewhere political-only.
  Instagram is covered under Meta Ad Library, not separately. **Founder: `advertising_activity` dimension is
  empty on the scored products** (Meta ingestion not run for them).

## 7. Marketplace
**eBay Browse API** (public data only, account-deletion-exempt, 18 markets). → `product_market_competitors`
(80 EBAY_BROWSE) + `commerce_signals` `MARKETPLACE_ACTIVITY` (90 global). Provides listings, prices,
original currency, offer patterns, comparable-product density → `marketplace_validation` +
`competition_saturation_gap` dimensions. Founder red-light-mask: `{EBAY_BROWSE, subscore:100,
PLATFORM_REPORTED}`. Review counts / ratings / sales figures are NOT treated as verified sales (registry +
saturation note: "counts are not CPC/CPA/ROAS"). Amazon/AliExpress marketplaces = **NOT_BUILT**.

## 8. Competitor stores
Competitor intelligence today = **eBay listings + Meta Ad Library** only (`product_market_competitors`,
74 real founder rows, all `MARKETPLACE_LISTING` on eBay + a few Meta). **Generic competitor-store /
Shopify-site crawling (assortment, discounts, bundles, landing pages, ad destinations) = NOT_BUILT.**
Fields exist for ad destinations/creative/offer/CTA patterns (populated from Meta where available).

## 9. Supplier
**CJ Dropshipping** (`commerce_supplier_products`, 852 catalogue rows; `ingest_cj_supplier_products`,
`fn_evaluate_supplier`, `fn_rank_suppliers`, `fn_supplier_economics`, delivery/stock/reliability states).
Provides supplier availability, observed sourcing cost + original currency, shipping/freight per
destination, variants, alternatives, sourcing confidence. Registry: reliability "not observable". Founder
tenant-owned supplier data = **0** (`product_acquisitions`=0), and `supplier_availability_stock` is empty
on scored products.

## 10. Buyer intent — **PARTIAL**
Modelled as the `buyer_search_intent` component + `ingest_search_demand`/`fn_search_momentum` (DataForSEO
intent INFERRED) plus Reddit `intent_indicators`. The frame and ingestion exist and are AVAILABLE, but on
the founder's scored products `buyer_search_intent` is **empty** (DataForSEO not run). So capability =
PARTIAL: real contract + provider available, but not populated for current decisions.

## 11. Pain-point / solution — **PARTIAL, community-sourced**
Pain/attention is extracted from Reddit community signals (`attention_basis`, `mention_context`,
`intent_indicators`) feeding `demand_momentum`. There is **no dedicated pain→existing-solutions→
solution-failure→unmet-need extraction chain** as a first-class multi-source model; it is currently
community-attention-derived only. No standalone pain-point table or agent. So the PAIN→SOLUTION→UNMET-NEED
ladder is **PARTIAL / community-only**, not multi-source.

## 12. Trend / momentum
Upstream `trend_signals` (multi-source: Google News/Trends/Reddit/blogs/YouTube) → clusters → candidates.
Product momentum via `derive_commerce_momentum` / `fn_search_momentum`. Bands observed on founder decisions:
`TRENDING_WATCH`, `STRONG_TEST`, `HIGH_CONFIDENCE_TEST`. Each evaluation carries `coverage` +
`evidence_confidence`; higher bands are **not** currently gated on a minimum evidence-confidence (see §22).

## 13. Saturation — **STRONG (where marketplace evidence exists)**
Implemented and real: `product_opportunity_decisions.saturation_state` derived from
`product_market_competitors` (founder red-light-mask GB: `level=VERY_HIGH, saturation_points=100,
has_defensible_gap=true, evidence_class=OBSERVED`), plus `fn_ad_saturation` and the
`competition_saturation_gap` component. Honest guard: "demand never overrides saturation; counts are not
CPC/CPA/ROAS". So seller/comparable-product density and marketplace crowding = STRONG; advertiser-density
saturation depends on Meta coverage (EU/UK). Classification: **STRONG** for marketplace saturation,
PARTIAL for advertising saturation.

## 14. Source diversity / confidence — **explicitly modelled (STRONG)**
`fn_evidence_confidence(completeness, categories, corroborated, conflicts, freshness, unknown_critical)`
scores: coverage ×40, **independent categories `least(categories,4)/4 ×30`**, corroboration +15 (else
"single_or_uncorroborated_sources"), freshness ±15/−10, conflicts −20, unknown-critical −7 each →
level HIGH/MODERATE/LOW/VERY_LOW, "independent of opportunity score". So **20 Reddit observations do NOT
beat Reddit+Google+eBay+Meta** — diversity is in the schema/scoring. This is the strongest part of the
architecture.

## 15. Geography
- REDDIT: CROSS_MARKET (global context, not per-market demand).
- DATAFORSEO: GLOBAL (per-country queryable).
- EBAY: COUNTRY (18 markets).
- META_AD_LIBRARY: COUNTRY but only EU/EEA+UK.
- CJ: MARKET_SPECIFIC (freight per destination).
- Trend layer: GLOBAL/REGION.
So per-country intelligence for the same product is possible from eBay (18), DataForSEO (global), Meta
(EU/UK), CJ (freight). GB/DE/FR/US decisions already exist for the founder's kids-nightlight-projector
(013G). Reddit is the weakest geographically (cross-market).

## 16. Freshness
Each evaluation/signal carries `observed_at` / `evaluation_ts` / `evidence_window`; `fn_evidence_confidence`
applies a FRESH(+15)/STALE(−10) freshness term; FX has a daily-refresh + staleness monitor (unit 27).
`provider_capability_registry.last_verified_at` tracks provider liveness. So freshness IS represented in
confidence. Gap: no per-source automatic staleness expiry job for product-market evidence (evidence is
as-of the last run; momentum is not auto-recomputed) — a trending claim rests on the last ingestion date.

## 17. Founder Product Decision source mix (per §7 format; coverage 0.23–0.41, evidence_confidence LOW/NONE)
| Product (GB) | Reddit/community | Google/DataForSEO | TikTok | Meta | Marketplace(eBay) | Competitors | Supplier |
|---|---|---|---|---|---|---|---|
| red light therapy mask (89.6) | YES | NO (empty) | NO | NO (empty) | YES | YES (eBay) | NO (empty) |
| kids nightlight projector (75.5, GB/DE/FR/US) | YES | NO | NO | NO | YES | YES | NO |
| digital picture frame (74.6) | YES | NO | NO | NO | YES | YES | NO |
| over-door shoe organizer (67.4) | YES | NO | NO | NO | YES | YES | NO |
**Every scored founder decision is 2-category (Reddit demand + eBay marketplace/saturation).**
`buyer_search_intent`, `advertising_activity`, `supplier_availability_stock` are empty on these products.
So current founder decisions are **single-to-dual-source in practice**, despite the multi-source frame.

## 18. Coverage matrix
| Source | Status | Real data | Founder data | Country-aware | Pain | Buyer intent | Demand | Trend | Competition | Saturation | Decision input | External access |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Reddit/community | LIVE_REAL_DATA | Y | Y (11) | CROSS_MARKET | Y | partial | Y | Y | N | N | Y | none (public) |
| Google Search | NOT_BUILT (direct) | – | – | – | – | – | – | – | – | – | N | – |
| Google Trends | LIVE (trend layer) | Y | via clusters | GLOBAL | N | N | Y | Y | N | N | indirect | none |
| Google Ads | BLOCKED_EXTERNAL_ACCESS | – | – | – | – | (via DFS) | (via DFS) | – | – | – | N (direct) | dev token (rejected) |
| DataForSEO | LIVE_REAL_DATA | Y | N (empty on products) | GLOBAL/COUNTRY | N | Y | Y | Y | partial | N | Y (dim) | paid API (have) |
| TikTok | NOT_BUILT | – | – | – | – | – | – | – | – | – | N | approval/automation |
| Meta/FB Ad Library | LIVE (EU/UK) | Y | N (empty on products) | COUNTRY (EU/UK) | N | N | N | N | Y | partial | Y (dim) | Graph token (have) |
| Instagram | via Meta Ad Library | Y (EU/UK) | N | COUNTRY | N | N | N | N | Y | N | via Meta | as Meta |
| Marketplaces (eBay) | LIVE_REAL_DATA | Y | Y (74) | COUNTRY (18) | N | N | proxy | N | Y | Y | Y | app OAuth (have) |
| Amazon/AliExpress | NOT_BUILT | – | – | – | – | – | – | – | – | – | N | – |
| Competitor stores (generic) | NOT_BUILT | – | – | – | N | N | N | N | partial(eBay/Meta) | partial | partial | crawler/ToS |
| Supplier (CJ) | LIVE_REAL_DATA | Y | N (0 acq) | MARKET_SPECIFIC | N | N | N | N | N | N | Y (dim) | CJ API (have) |

## 19. Launch-critical gaps
Not "build a new source" — the sources exist. Launch-critical = **make each scored product+market
genuinely multi-category** by ensuring the already-built DataForSEO (buyer_search_intent), Meta Ad Library
(advertising_activity) and CJ (supplier) ingestion actually **run** for the products being decided, so
`fn_evidence_confidence` reflects ≥3 corroborated categories — and **gate high band/confidence labels on
`evidence_confidence`** so nothing ships as "HIGH_CONFIDENCE" while evidence_confidence=NONE (§22).

## 20. Post-beta gaps
TikTok intelligence (Creative Center / trending / ads); Amazon & AliExpress marketplace intelligence;
generic competitor-store crawling; a first-class pain→solution→unmet-need extraction chain; automatic
per-source staleness expiry/recompute.

## 21. External dependencies
- **Google Ads (direct):** `BLOCKED_EXTERNAL_APPROVAL` (dev token rejected as keyword-only). **Do not
  re-apply.** DataForSEO already substitutes for Google search-demand — no blocker for launch.
- **DataForSEO / eBay / Meta Ad Library / CJ:** paid/authorized APIs **already connected** (registry
  AVAILABLE) — no new approval needed to populate founder decisions.
- **Meta Ad Library:** geographic ToS limit — commercial archive EU/EEA+UK only (not a fixable blocker;
  a real-world data limitation to disclose).
- **TikTok / Amazon / AliExpress:** would each need provider access/automation + ToS review →
  `BLOCKED_EXTERNAL_APPROVAL`/POST_BETA; independent work may continue around them.

## 22. Recommended minimum multi-source evidence standard (architecture recommendation only — do NOT change scoring)
Reuse `fn_evidence_confidence`; gate the **surfaced** classification, not the raw opportunity score:
- **STRONG OPPORTUNITY:** ≥ **3 independent evidence categories** with at least one MARKETPLACE or
  ADVERTISING corroboration, saturation OBSERVED, freshness FRESH, and `evidence_confidence` ≥ **MODERATE**
  (≥45).
- **HIGH-CONFIDENCE OPPORTUNITY:** ≥ **4 independent categories**, corroborated, no conflicts,
  `evidence_confidence` ≥ **HIGH** (≥70), saturation + economics both evidenced (not INSUFFICIENT_EVIDENCE).
Favour category diversity + evidence quality over signal volume (already the design intent of
`fn_evidence_confidence`).

## 23. Overclaim audit
- **Band vs evidence (primary):** the founder's top decision surfaces `band=HIGH_CONFIDENCE_TEST` (score
  89.6) while `overall_evidence_confidence=NONE`, `sweet_spot=INSUFFICIENT_EVIDENCE`,
  `advertising_headroom=INSUFFICIENT_EVIDENCE`. Surfacing "HIGH CONFIDENCE" with NONE evidence confidence is
  a truthfulness risk — the band should be gated on evidence_confidence before it reaches the UI.
- **"Winning Product Standard" (WPS):** internal model name appears in migrations/docs; ensure it is not
  surfaced verbatim to merchants as "winning product". Storefront/published copy is already claim-scanned
  (`claim_scan_clean`, unit 34) and largely safe; the risk is workspace decision labels, not published pages.
- **Honest guards already present** (good): saturation note "demand never overrides saturation; counts are
  not CPC/CPA/ROAS", ad-headroom "stress scenarios, not CPA forecasts", sweet-spot/headroom
  `INSUFFICIENT_EVIDENCE`, Reddit "not market-specific demand proof", DataForSEO volume "ESTIMATED".
Report only — do not change.

## 24. Existing capabilities to REUSE
`provider_capability_registry` (source-of-truth), `fn_evidence_confidence` (source-diversity confidence),
the 8-dimension WPS V2 evaluation, `saturation_state` from `product_market_competitors`, `fn_ad_saturation`,
`ingest_search_demand`/`fn_ingest_search_demand_for_product` (DataForSEO), `fn_ingest_meta_ads`/
`ingest_advertising_activity` (Meta), `ingest_cj_supplier_products` + supplier evaluation, eBay Browse
ingestion, `fn_assemble_real_product_market`→`fn_evaluate_product_market`, the multi-source `trend_signals`
layer.

## 25. Capabilities genuinely NOT BUILT
TikTok (any); Amazon & AliExpress marketplace intelligence; generic competitor-store crawling; direct
Google Ads (blocked); a dedicated pain→solution→unmet-need extraction model; automatic per-source
staleness recompute.

## 26. Confirmation: no implementation / mutation
Read-only. No migration, DB write, Lovable change, workflow creation, credential request, or publish. No
data mutated.

## 27. Recommended smallest NEXT implementation unit
**"Multi-source evidence completeness pass" (no new external source):** (a) run the existing DataForSEO +
Meta Ad Library + CJ ingestion for the founder's scored products/markets so `buyer_search_intent`,
`advertising_activity` and `supplier_availability_stock` populate and `fn_evidence_confidence` reflects
≥3 corroborated categories; and (b) add a truthful **band-vs-evidence_confidence gate** so no
"HIGH_CONFIDENCE/STRONG" label is surfaced while `evidence_confidence` is NONE/LOW. This lifts founder
decisions from 2-category to genuinely multi-source using only existing runtimes, and closes the primary
overclaim — the smallest defensible launch-critical step.

## 28. FINAL VERDICT
**`PARTIAL_MULTI_SOURCE`.** By architecture Strateloq is multi-source and diversity-aware (5 registered
evidence categories, 8-dimension WPS V2 scoring, `fn_evidence_confidence` rewarding independent categories,
real marketplace-derived saturation, honest insufficient-evidence states) — **not** structurally
Reddit-dependent. But the founder's current product decisions are **2-category (Reddit + eBay)**, with
DataForSEO/Meta/CJ dimensions unpopulated, so the *live evidence* is partial and the high band labels
currently outrun the evidence confidence. The remedy is to **run the already-built sources** per scored
product+market and gate labels on evidence confidence — not to build new sources (except TikTok/Amazon/
AliExpress, which are POST_BETA). Google Ads direct remains `BLOCKED_EXTERNAL_APPROVAL` and is covered by
DataForSEO.

STOP. Audit only — recommended next unit not implemented.

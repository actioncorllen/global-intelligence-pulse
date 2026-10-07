# STAGE 1 — Product-Native Multi-Lane Opportunity Discovery (WinningHunter-inspired, Strateloq-native)

**Date:** 2026-10-07 · **Tenant:** 7c8ddf9d-… · **Project:** nxaunmyihhjixxxljcqt (live prod) · **Branch:** claude/cool-faraday-kgudh1
**Scope:** STRATELOQ EXECUTION (fast) + PERMANENT-FIX RULE. Stage 1 only — Stage 2 not run. WinningHunter NOT connected.

## CURRENT DISCOVERY SOURCES AUDITED (from provider_capability_registry)
DATAFORSEO (search_demand), EBAY (marketplace), META_AD_LIBRARY (advertising), TIKTOK (social_video:
organic Research API + Commercial Ad Library), REDDIT (community), CJ (supplier), GOOGLE_ADS (blocked).

## SOURCE CAPABILITY CLASSIFICATION (for product-native discovery)
| Source | Class | Why |
|---|---|---|
| DATAFORSEO | DISCOVERY_CAPABLE (keyword) | Keyword expansion → candidates; NOT product-native (no product entities) |
| EBAY (Browse) | RESEARCH_ONLY (as implemented) | Browse API queried by product name for research; category-browse discovery not implemented |
| META_AD_LIBRARY | RESEARCH_ONLY | Queried by term; returns ads, not product entities |
| TIKTOK organic Research API | UNAVAILABLE | EXTERNAL_APPROVAL_REQUIRED (separate developer app) — the WinningHunter-equivalent product/creator/video graph |
| TIKTOK Commercial Ad Library | RESEARCH_ONLY | Connected, but ad-record-level (ad.id/first_shown/last_shown/advertiser) + query-seeded; no revenue/units/creator metrics |
| REDDIT | REFERENCE_ONLY (cross-market) | Community mentions, cross-market, not market-isolated product entities |
| CJ | SUPPLIER_ONLY | Supplier economics (Stage 2) |
| GOOGLE_ADS | UNAVAILABLE | SOURCE_BLOCKED (no developer token) |

## CRITICAL QUESTION — can any connected provider return market product entities WITHOUT a seed?
**NO.** → **PRODUCT_NATIVE_DISCOVERY_PROVIDER_GAP = YES.** DataForSEO is keyword-level; eBay Browse is
implemented research-only; ad libraries are query-seeded ad records; TikTok organic is approval-gated; CJ
is supplier-only. Not fabricated.
**POTENTIAL_EXTERNAL_DISCOVERY_PROVIDER:** WinningHunter API/MCP (TikTok Shop product/shop/creator/video,
revenue/units/growth) — **evaluation only, NOT connected** (no account/credentials/dependency; founder
approval required before any paid integration).

## MULTI-LANE ARCHITECTURE (built; reuses search lane + auto-research bridge; no parallel system)
- `discovery_lane_registry` — 5 lanes with honest capability classification + availability:
  SEARCH (DataForSEO, AUTONOMOUS, **AVAILABLE** — the one live lane) · COMMERCE (**PRODUCT_NATIVE_GAP**) ·
  SOCIAL (TikTok, **BLOCKED_EXTERNAL_APPROVAL**) · ADVERTISING (**RESEARCH_ONLY**) · PROBLEM (**SEEDED_AVAILABLE**).
- `fn_multi_lane_discovery_plan(market, max_lanes, user)` — market-only orchestrator: returns every lane
  with explicit status; attaches the runnable SEARCH lane's autonomous scope plan; a zero/unavailable lane
  never stops the cycle. DataForSEO reframed as the SEARCH-DEMAND lane (not the definition of discovery).
- `fn_autonomous_discovery_plan` (prior unit) = the SEARCH lane; 013Q wired to it (market-only). Scope
  universe refined toward narrower product-type seeds (higher weight) to raise candidate yield.

## DISCOVERY SIGNAL CONTRACT
`fn_discovery_signal_normalize(lane, source, market, raw)` → normalized candidate signal with the full
field set (product identity, first_seen, sales/units/velocity/growth, revenue/growth, price, creator
count/growth/conversion, video/view/share, buyer intent, shop/seller/advertiser counts, ad/search growth,
problem signal, maturity, cross_market_reference). **UNKNOWN stays NULL, never 0**; market-scoped;
cross_market_reference is never local validation.

## FILES / MIGRATIONS / WORKFLOWS
- `mig_373a_multi_lane_discovery.sql` (lane registry + seed + scope refinement + normalizer + orchestrator)
- `mig_373b_multi_lane_discovery_selftest.sql` (regression)
- n8n 013Q (reused; SEARCH lane, market-only autonomous mode from the prior unit)

## REGRESSION — `fn_multi_lane_discovery_selftest()` = 16/16 all_pass (live)
market-alone init · multiple lanes coexist · unavailable lane explicit · zero-result lane not fatal ·
product-native candidate normalizes · keyword candidate still works · cross-lane dup collapses · country
isolation · **UNKNOWN metric ≠ zero** · discovery ≠ qualified · high revenue cannot bypass gates · low
volume keeps acceleration · image-irrelevant · eligible enters research bridge · spend bounded · idempotent.

## REAL MARKET-ONLY RUN — executed (bounded)
Input: market = DE only; no manual product/category.
- LANES ATTEMPTED: SEARCH (runnable) ran; COMMERCE/SOCIAL/ADVERTISING/PROBLEM reported explicit
  non-runnable status (GAP / BLOCKED_EXTERNAL_APPROVAL / RESEARCH_ONLY / SEEDED).
- SEARCH lane auto-selected scope **"car phone mount"** (rotation; discovery run `b9a4d0bc…`).
- PRODUCT-NATIVE CANDIDATES: 0 (COMMERCE lane is a provider gap). SEARCH-DERIVED CANDIDATES: 0 this cycle.
- DEDUPLICATED / ELIGIBLE / AUTO-RESEARCHED / CONCRETE_RESOLVED / QUALIFIED: 0.
- NO_QUALIFIED_OPPORTUNITY_THIS_RUN: YES.

Honest cause: two consecutive clean product seeds ("home organization", "car phone mount") returned 0
candidates. "Car phone mount" is an unambiguously commercial product term that would expand to qualifying
keywords were data returned, so this is consistent with **DataForSEO credit exhaustion (402)** — the
documented recurring external constraint — not qualification or wiring (the autonomous
`keyword_ideas_request` shape is identical to the earlier proven run that produced candidates). The live
SEARCH lane is the only connected discovery provider, so when its credit is exhausted the market-only
cycle yields no candidate. The candidate → normalization → auto-research → evidence → evaluation path was
proven end-to-end in the earlier bounded run (coaxial cable / cable pull-through).

## WINNINGHUNTER GAP ANALYSIS
| Capability | WinningHunter | Strateloq BEFORE | Strateloq AFTER | Remaining gap |
|---|---|---|---|---|
| Product-native discovery | Yes (TikTok Shop) | No | No (lane encoded, provider GAP) | Needs a product-native provider (WH or TikTok organic approval) |
| Country filtering | Yes | Partial | Yes (per-market config, isolation) | — |
| First-seen / newness | Yes | No | Contract field (UNKNOWN until provider) | Provider data |
| Sales velocity | Yes | No | Contract field | Provider data |
| Revenue growth | Yes | No | Contract field | Provider data |
| Creator adoption | Yes | No | Contract field | TikTok organic approval / WH |
| Video momentum | Yes | No | Contract field | TikTok organic approval / WH |
| Shop/seller activity | Yes | Partial (eBay research) | Partial | Market seller-count needs marketplace discovery |
| Advertiser activity | Partial | Partial (Meta/TikTok adlib research) | Partial (research-only) | Autonomous ad-emergence lane |
| Search momentum | No (not core) | Yes (DataForSEO) | Yes (SEARCH lane) | — (Strateloq advantage) |
| Cross-source verification | Limited | Yes (research bridge) | Yes (multi-source bridge) | — (Strateloq advantage) |
| Country isolation | Partial | Yes | Yes (enforced + regression) | — (Strateloq advantage) |
| Early-opportunity detection | Partial | Yes (bands/gates) | Yes (preserved; volume≠winner) | — |
| Supplier economics | No | Yes (CJ, Stage 2) | Yes | — (Strateloq advantage) |
| Opportunity decision | No (raw metrics) | Yes (gated evaluation) | Yes (gated; high-revenue cannot bypass) | — (Strateloq advantage) |
No parity claimed on product-native discovery: that is the explicit gap.

## RECURRENCE PREVENTED: YES
Lane registry + orchestrator + signal contract + 16/16 regression; product-native gap is explicit and
fail-closed; DataForSEO is reframed as one lane, not the definition of discovery.

## VERDICT
Multi-lane architecture, signal contract, lane classification and 16/16 regression are built and proven;
market-only discovery runs across lanes with explicit per-lane status and the product-native gap recorded.
But the one live discovery lane (SEARCH/DataForSEO) produced 0 candidates this cycle (consistent with
provider credit 402), so no candidate entered the research bridge in this real run.

BLOCKED_STAGE_1_MULTI_LANE_DISCOVERY

## OVERALL STAGE 1 — PRODUCT OPPORTUNITY INTELLIGENCE
No newly discovered product has reached CONCRETE_RESOLVED **and** benchmark-qualified country-specific
opportunity. Remaining gaps: (1) a product-native discovery provider (the headline capability gap), and
(2) a live run producing a candidate that resolves concretely and clears the founder benchmark — currently
gated by DataForSEO credit on the only live lane.

OVERALL_STAGE_1_PRODUCT_OPPORTUNITY_INTELLIGENCE: BLOCKED

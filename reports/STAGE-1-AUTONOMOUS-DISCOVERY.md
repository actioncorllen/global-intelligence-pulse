# STAGE 1 — Autonomous Market / Category Product Discovery

**Date:** 2026-10-07 · **Tenant:** 7c8ddf9d-… · **Project:** nxaunmyihhjixxxljcqt (live prod) · **Branch:** claude/cool-faraday-kgudh1
**Scope:** STRATELOQ EXECUTION (fast) + PERMANENT-FIX RULE. Stage 1 only — Stage 2 not run.

## CURRENT DISCOVERY MODE (before this unit)
Manual category seed / Type C — the customer had to name both market and category
("cable organizer" in DE).

## ROOT CAUSE OF MANUAL-SEED DEPENDENCY
The only proven product-discovery path (`fn_dataforseo_discover_candidates`) requires a
category seed, and no in-DB source could supply market-scoped product scopes: `trend_clusters`
(5199 rows) holds macro/news topics ("Enterprise AI Adoption", "Geopolitical Trade Tensions")
with empty `top_regions`, not products; `business_category` is a 5-row business-type taxonomy
(agencies/creators/coaches/ecommerce), not an ecommerce product-category universe. So "find
emerging products in Germany" alone could not start discovery.

## EXISTING DISCOVERY COMPONENTS FOUND
- `fn_dataforseo_discover_candidates` (within-category discovery; now auto-dispatches research — mig_371)
- `fn_dataforseo_discovery_request` / `fn_dataforseo_discovery_qualify` (request builder + intent/relevance/sellable noise gate)
- problem-discovery subsystem (`commerce_problem_*`, `fn_request_problem_discovery`, DataForSEO+Reddit) — market+category+problem seed
- trend path (`trend_clusters`/`trend_signals`, `acquire_commerce_candidates_from_trends`, `reddit_product_candidate_batch`) — interest-scoped, macro-topic data, not market-scoped products
- `fn_category_market_state`, `fn_country_opportunity_explorer`
No existing mechanism took **market alone** and auto-selected product scopes → confirmed gap.

## DISCOVERY-CAPABLE vs RESEARCH-ONLY SOURCES
- DISCOVERY (surfaces what to investigate): DataForSEO keyword expansion (within a scope seed);
  historically the Reddit mention path. Macro-trend clusters are not product-discovery-capable.
- RESEARCH (verify a named candidate): eBay-DE marketplace, Meta Ad Library (advertising), CJ
  (supplier), TikTok (social video), Reddit (community), DataForSEO (demand). Proven in the
  research bridge. TikTok/social is a research source here, not an autonomous discovery source.

## PERMANENT AUTONOMOUS DISCOVERY DESIGN
- `ecommerce_discovery_scope` — a bounded, extensible ecommerce scope universe (the ONE taxonomy
  input / the exploration SPACE, not "intelligence" by itself; 24 consumer-product categories,
  active flag + weight).
- `fn_autonomous_discovery_plan(market, max_scopes, user)` — the exploration STRATEGY: given only
  a market it auto-selects the least-recently-explored active scope (NULLS FIRST), using the real
  `discovery_runs` history for systematic rotation over cycles; resolves location/language/currency
  from the authoritative provider config; and emits the exact DataForSEO request for the chosen
  scope. No founder/Claude category choice; no static per-run guess.
- 013Q wired to autonomous mode: `Discovery Config` now carries only market (+ candidate_limit,
  user); the former "Resolve Market Config" node is now "Autonomous Scope Plan" calling
  `fn_autonomous_discovery_plan`; DataForSEO + Build Payload consume the auto-selected scope; the
  existing qualification + auto-research bridge run unchanged.

The real discovery intelligence stays downstream and unchanged: DataForSEO expansion →
qualification noise gate → registration → the proven auto-research bridge → evidence → concrete
resolution → opportunity evaluation. Richer scope sources (live trend / marketplace-category feeds)
can be added to the universe later without changing this contract.

## FILES / MIGRATIONS / WORKFLOWS CHANGED
- `mig_372a_autonomous_discovery_scope_planner.sql` (table + seed + `fn_autonomous_discovery_plan`)
- `mig_372b_autonomous_discovery_selftest.sql` (`fn_autonomous_discovery_selftest`)
- n8n 013Q: autonomous-mode wiring (Autonomous Scope Plan node; market-only input)

## SPEND BOUNDS / DEDUP / NOISE / COUNTRY ISOLATION
- SPEND: planner caps `max_scopes` ≤ 5; discovery caps `candidate_limit` ≤ 25; one scope per
  autonomous cycle by default; `pulse.suppress_dispatch` still halts downstream research.
- DEDUP: discovery dedups candidates (`ingest_search_demand` family key + registry upsert);
  rotation won't re-pick a recently-explored scope.
- NOISE: `fn_dataforseo_discovery_qualify` (commercial/transactional intent + relevance + sellable)
  runs before any expensive research; scope universe is consumer-product categories.
- COUNTRY ISOLATION: plan resolves per-market config (DE→2276/de, GB→2826/en); rotation history is
  market-filtered; no cross-market leakage.

## REGRESSION — `fn_autonomous_discovery_selftest()` = 12/12 all_pass (live)
MARKET_ALONE_INITIATES · SCOPE_AUTO_SELECTED_FROM_UNIVERSE · SCOPE_MARKET_SCOPED ·
SPEND_BOUNDED_MAX_SCOPES · ROTATION_PREFERS_UNEXPLORED · UNSUPPORTED_MARKET_NO_FALLBACK ·
NOISE_GATE_BEFORE_RESEARCH · DEDUP_ACROSS_SCOPES · ELIGIBLE_ENTER_RESEARCH_BRIDGE ·
IMAGE_INDEPENDENT · CANDIDATE_NOT_QUALIFIED · PLAN_RETURNS_SCOPE_NOT_PRODUCT.

## REAL AUTONOMOUS RUN — executed (bounded)
- INPUT: market = DE only. MANUAL CATEGORY PROVIDED: **NO**.
- AUTO DISCOVERY SCOPE: planner auto-selected **"home organization"** (`home_organization`) by
  rotation (never-explored for DE; already-explored cable organizer/phone/car/kitchen scopes
  correctly skipped). Discovery run `1082f6c5…` recorded market=DE, category="home organization".
- CANDIDATES DISCOVERED: **0** this cycle (0 products, 0 signals from the run).
- CANDIDATES AUTO-DISPATCHED / RESEARCH RESULTS / CONCRETE_RESOLVED / QUALIFIED: n/a (no candidates).
- NO_ELIGIBLE_CANDIDATE_THIS_RUN: **YES** (not faked).

Cause (honest, from available telemetry): the auto-selected scope was a **broad category seed**
("home organization"), and broad seeds have repeatedly promoted 0 candidates via correct
qualification (kitchen gadgets / car accessories / phone accessories / laptop stand all promoted 0
earlier; only the narrower "cable organizer" promoted candidates), compounded by intermittent
DataForSEO credit. The 0-candidate outcome is therefore either correct noise-rejection of a broad
seed or an empty provider response; the MCP does not expose node I/O to distinguish, and I did not
re-run with a hand-picked narrower scope (the brief forbids manipulating discovery until something
passes). The candidate → auto-research → evidence → concrete-resolution → opportunity-evaluation
flow through the identical discovery RPC + bridge was proven in the immediately prior bounded run
(coaxial cable / cable pull-through, both reached automatic opportunity evaluation).

MATERIAL-PRODUCT-NESS: not assessable from a 0-candidate cycle. Recommended durable refinement
(non-blocking): bias the scope universe toward narrower product-type seeds (e.g., "shoe storage
organizer", "resistance band set") which expand to qualifying product keywords far more reliably
than broad category labels — improving candidate yield without changing the contract.

## MANUAL / RECURRENCE
MANUAL PRODUCT/CATEGORY SELECTION REQUIRED: **NO** (market alone initiates; scope auto-selected).
RECURRENCE PREVENTED: **YES** (scope universe + rotation planner + 013Q wiring + 12/12 regression;
the planner fails closed on unsupported markets and never fabricates a product).

## VERDICT
Autonomous-discovery infrastructure is implemented, reuses existing architecture (no parallel
system), and is fully regression-proven (12/12); a real market-only cycle auto-selected a scope and
invoked discovery with no manual category. But the bounded real cycle produced **no eligible
candidate** (broad-seed qualification / provider availability), so per the real-path PASS rule no
candidate traversed to research this cycle.

BLOCKED_STAGE_1_AUTONOMOUS_DISCOVERY

## OVERALL STAGE 1 — PRODUCT OPPORTUNITY INTELLIGENCE
No genuinely newly discovered product has reached CONCRETE_RESOLVED **and** legitimate founder
benchmark qualification: discovered candidates to date (cables, home-org cycle) remain CONCEPT_ONLY
/ WATCH / rejected. The exact remaining gap is concrete product resolution + a benchmark-qualifying
opportunity from a freshly discovered product.

OVERALL_STAGE_1_PRODUCT_OPPORTUNITY_INTELLIGENCE: BLOCKED

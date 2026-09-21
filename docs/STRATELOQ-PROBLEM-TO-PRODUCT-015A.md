# STRATELOQ-PROBLEM-TO-PRODUCT-015A — Architecture + Reuse Audit

**MODE: AUDIT ONLY.** No migrations, no n8n changes, no Lovable, no paid API calls were made. All findings
below are read from the live production project `nxaunmyihhjixxxljcqt`, the migrations, the Edge Function
list and the n8n workflow inventory.

**FINAL VERDICT: `PROBLEM_INTELLIGENCE_REUSE_READY`.**

The product-first spine — evidence model, research run, provider fan-out, evidence normalization, PME,
Product Decision, multi-market catalog and supplier sequencing — is reusable **as-is** for a problem-first
mode. The problem→product transition needs only a **small additive problem-front layer** (a problem/cluster
contract + a problem-mode discovery qualifier + a problem-relevance vocabulary) that feeds the existing
candidate registry and then the unchanged pipeline. No parallel intelligence architecture is required. No
scoring system is duplicated. Details, classifications (REUSE / EXTEND / NEW / DEFER) and the smallest
implementation sequence follow.

---

## A. Existing reusable architecture (exact objects)

**Tables**
- `commerce_products` — canonical product identity (`product_identity`, `identity_basis`, `product_role`,
  `provenance`, `source_store`, `category`, `extended`). `product_id` of everything hangs off this. **REUSE.**
- `commerce_signals` — universal evidence store. Types today: `SEARCH_DEMAND`, `COMMUNITY_ATTENTION`,
  `MARKETPLACE_ACTIVITY`, `ADVERTISING_ACTIVITY` (+ TikTok `SOCIAL_VIDEO_ADVERTISING`). Carries
  `value/evidence/provenance/confidence/observed_at/source_event_at/dedup_key/visibility`. **`product_id`
  is NULLABLE** — evidence can exist before a product is chosen. **REUSE.**
- `commerce_research_run` — per (`tenant_id`, `product_id`, `market`) run with coverage counters
  (`sources_expected/attempted/with_evidence/no_data/unsupported/failed`, `independent_categories`,
  `freshness_at`). **`product_id` NOT NULL** (research is strictly product-anchored). **REUSE.**
- `commerce_research_source_attempt` — per (`run_id`, `evidence_category`) terminal-state row
  (`state`, `source`, `evidence_ref`, `note`, `observed_at`). Live states: `SEARCHED_EVIDENCE_FOUND`,
  `SEARCHED_NO_EVIDENCE`, `BLOCKED_EXTERNAL_ACCESS` (+ `SOURCE_FAILED`, `SEARCHING` in code). **REUSE.**
- `product_market_evaluations` (PME) — canonical per-market WPS (`market_opportunity_score`, `coverage`,
  `evidence_confidence`, `gate_state`, `market_decision`, `component_scores`, `economics`). **REUSE.**
- `product_opportunity_decisions` — decision snapshot (`decision`, `opportunity_band`, `hard_gates`,
  `decision_blockers`, `action_gating`, `saturation_state`, `advertising_headroom`). **REUSE.**
- `provider_capability_registry` — per (`source`, `evidence_category`, `market`) availability
  (eBay/DataForSEO/Meta/CJ/Reddit/TikTok). **REUSE.**
- `monday_opportunity_registry` — the candidate registry that new discoveries enter. **REUSE.**
- `ecommerce_market_universe` — multi-market catalog (market-aware, no hardcoded GB). **REUSE.**
- `commerce_supplier_products` — CJ/supplier evidence. **REUSE.**
- `trend_signals` — the GLOBAL, non-tenant Agent-1 firehose (`raw_topic`, `raw_data`, region, language).
  Not part of the ecommerce evidence spine; see §C for its (limited) problem relevance. **DEFER.**

**RPCs / functions**
- Discovery: `fn_dataforseo_discover_candidates`, `fn_dataforseo_discovery_qualify` (mig_255),
  `reddit_product_candidate_batch`, `ingest_reddit_product_attention`, `ingest_search_demand`,
  `ingest_resolved_product_entity`, `ingest_commerce_product`. **REUSE (discovery scaffolding).**
- Research control plane: `fn_own_request_product_market_research(product_id, market, freshness_hours)`,
  `fn_research_dispatch`, `fn_research_run_manifest`, `fn_research_reuse_source`,
  `fn_research_maybe_finalize`, `fn_finalize_research_run`, `fn_research_ingest_source(run_id, source,
  raw)`. **REUSE.**
- Evidence normalizers (per source, all route through `fn_research_ingest_source`):
  `fn_ingest_ebay_listings`, `fn_ingest_meta_ads`, `fn_ingest_search_demand_for_product`,
  `ingest_cj_supplier_products`, `fn_ingest_tiktok_commercial_content`. **REUSE.**
- Relevance: `fn_classify_search_query_relevance` (v2, mig_248) → `DIRECT_PRODUCT / CLOSE_VARIANT /
  CATEGORY_DEMAND / SOLUTION_DEMAND / ADJACENT / SERVICE / INFORMATIONAL / ACCESSORY / IRRELEVANT`
  + intent (`transactional/commercial/informational`). **REUSE for scoring; EXTEND for problem seed.**
- Evaluation ladder: `fn_evaluate_product_market` (PME), `fn_pmc_evaluate` (competition),
  `fn_ppf_evaluate` (platform fit), `fn_pod_evaluate` / `fn_pod_tournament` (decision),
  `fn_rank_product_markets`, `fn_canonical_product_decision_v2`, `fn_ecommerce_opportunity_band`. **REUSE.**
- Read contracts: `fn_ecommerce_workspace_intelligence`, `fn_ecommerce_research_coverage`,
  `fn_ecommerce_research_source_states`. **REUSE / EXTEND (add problem entry points).**
- Orchestration: `fn_run_monday_product_opportunity`, `fn_monday_top_opportunities`. **REUSE.**

**Edge Functions**
- `tiktok-commercial-token` (broker), `meta-insights-reader`, `meta-capi-adapter`, `start-discovery`,
  `prepare-product`, `storefront`. The research fan-out itself runs in n8n, not Edge Functions. **REUSE.**

**n8n workflows**
- `QjYMzrCm1cDXxUS4` **Research Auto-Dispatch Executor (013N)** — ACTIVE fan-out executor. **REUSE.**
- Per-source executors (manual): eBay `N6OATi91HM8asncc`, Meta `57AYLZgyITU9vfCW`, DataForSEO
  `aVKNL2CFhyA8VUdm`, CJ `vjVn6gILqw4lGYpG`, TikTok `j4bOv9cuuzMbqN9B`. **REUSE.**
- Discovery feeders: **DataForSEO Product Discovery (013Q)** `dyIhrOkFp2QmrmTD`, **Reddit
  Product-Attention Adapter (SM-003D)** `0hmmy8hGfJ7H2pbK`, **Ecom Product-Signal Collector**
  `0aXO9OmUfRXhI5s2`. **REUSE (discovery); EXTEND (problem-mode seed/qualify).**
- `BBxcPXJdF2PliWgf` Monday Orchestrator. **REUSE.**

**Contracts:** `pulse_research_ingest_v1_013j` (ingest), WPS `pm_score_v1` (PME), opportunity band ladder,
6 evidence categories (MARKETPLACE / ADVERTISING / SEARCH_DEMAND / SUPPLIER / COMMUNITY / SOCIAL_VIDEO).

---

## B. Missing capability (the only genuine gaps)
1. **No problem/pain entity.** No `problem`, `pain`, `need`, `complaint` or problem-`cluster` table exists
   (`trend_clusters` belongs to the unrelated global-trend agents). A problem cannot be represented,
   corroborated, or linked to a candidate product today. **NEW (small additive contract).**
2. **No problem-mode discovery qualifier.** `fn_dataforseo_discovery_qualify` *rejects*
   informational/navigational intent — the exact opposite of what problem discovery needs ("how to…",
   "best way to…", "fix …", "solution for …"). **EXTEND (a problem-intent branch), never a rewrite.**
3. **No problem-relevance vocabulary.** `fn_classify_search_query_relevance` classifies a query against a
   **product name**; problem-first starts with no product. A problem-seed relevance/clustering step is
   missing. **NEW (thin), reusing the same token/head-noun machinery.**
4. **Reddit extracts products, not pains.** The Reddit adapter emits `COMMUNITY_ATTENTION` product
   mentions with `intent_indicators{recommendation, purchase_intent}` — no complaint / unmet-need /
   workaround capture. **EXTEND (a pain-signal extraction shape into the same `commerce_signals`).**

---

## C. Existing problem-signal data actually stored today (not assumed — read live)
- **`SEARCH_DEMAND` (DataForSEO):** stores the **raw query string** (`value.headline_query`,
  `evidence[].query`), `relevance` (`DIRECT_PRODUCT`…), `intent_label` (transactional/commercial/
  informational), `avg_monthly_searches`, competition, seasonality, momentum. → **The raw problem/question
  text is retainable through the existing shape**; today the *seeds* are product-name-derived, so stored
  queries are product queries (e.g. "cool mist humidifier"), not "how to humidify a dry room". The
  container already supports problem queries; only the seed set is product-biased.
- **`COMMUNITY_ATTENTION` (Reddit):** stores `subreddit`, free-text `mention_context`, `intent_indicators
  {recommendation, purchase_intent}`, source URL. → Captures *that a product was discussed*, not *what
  problem/frustration was expressed*. No complaint/unmet-need field today.
- **`MARKETPLACE_ACTIVITY` / `ADVERTISING_ACTIVITY` / `SOCIAL_VIDEO_ADVERTISING`:** product-anchored
  competitor/ad presence — corroboration only, no problem semantics.
- **`trend_signals`:** global `raw_topic`/`raw_data` firehose across 14 regions. Contains free-text topics
  that *may* include problems, but it is non-tenant, non-ecommerce, unclassified for pain, and not wired to
  `commerce_*`. Usable later as an opportunistic seed source; **DEFER**.

**Conclusion:** the evidence *container* already retains query text, intent, provenance, freshness and
source-attempt state (everything §4 requires). What is missing is **problem-oriented seeds and a
problem-oriented extraction/classification**, not a new storage substrate.

---

## D. Source-role matrix (problem-first)

| Source | Connected | Legitimate problem-first role | Class |
|---|---|---|---|
| **DataForSEO** | ✅ AVAILABLE | Primary problem *demand*: question/"how to"/"solution for" queries, search volume, informational+commercial intent, category/solution-tier demand. | **EXTEND** (problem-intent qualifier; keep informational) |
| **Reddit** | ✅ AVAILABLE | Primary problem *voice*: complaints, recurring frustrations, workarounds, unmet needs, buyer questions. | **EXTEND** (pain-extraction shape) |
| **eBay / marketplaces** | ✅ AVAILABLE | AFTER a solution product hypothesis: observed listings, competitor presence, pricing, seller count → market-presence evidence. | **REUSE** |
| **Meta Ad Library** | ✅ AVAILABLE (EU/UK) | Advertising/market corroboration of a candidate solution where coverage exists. Absence ≠ absence of demand. | **REUSE** |
| **TikTok Commercial Content** | ✅ AVAILABLE | Commercial/advertising corroboration for a discovered solution product. **Absence of ads ≠ absence of demand** (as 014F.10 proved: 10 ads, 0 product-relevant → NO_EVIDENCE, not "no demand"). | **REUSE** |
| **CJ / suppliers** | ✅ AVAILABLE | Supplier/product-solution availability **only AFTER** a problem→product match exists. **Supplier catalog availability must never, by itself, create demand.** | **REUSE (sequenced last)** |

---

## E. Proposed minimal canonical problem model (design only — not implemented)
Add the smallest additive contract that the existing spine cannot already represent. Two options; **E1 is
recommended** (least surface, reuses `commerce_signals`).

**E1 (recommended, minimal):**
- **One new table `commerce_problem_clusters`** (tenant-scoped): `id, tenant_id, market, seed_topic,
  cluster_label, problem_statement, status, evidence_confidence, coverage, freshness_at, provenance,
  created_at`. `status` enum realizes the truth ladder:
  `PROBLEM_DISCOVERED → PROBLEM_CORROBORATED → SOLUTION_CANDIDATE → PRODUCT_MATCHED → MARKET_ASSESSED →
  PRODUCT_DECISION_READY`.
- **Problem evidence reuses `commerce_signals` with `product_id = NULL`** (already nullable) plus a
  `provenance.problem_cluster_id` link and new signal types `PROBLEM_SEARCH_DEMAND`, `PROBLEM_COMMUNITY`.
  This preserves the required fields verbatim: **source, market, query/topic (`evidence[].query`/context),
  observed evidence, freshness (`observed_at`/`source_event_at`), provenance, source-attempt state.**
- **One link column** on `commerce_products` provenance (`derived_from_problem_cluster_id`) so a
  candidate product traces to its originating problem. **NEW table + EXTEND signals — no new pipeline.**

**E2 (heavier, not recommended):** a full parallel `problem_*` evidence/attempt/evaluation set — rejected;
it would duplicate the run/attempt/PME machinery for no benefit.

Status ladder mapping (reusing existing states, no new scoring):
`PROBLEM_DISCOVERED` = ≥1 problem signal; `PROBLEM_CORROBORATED` = ≥2 independent problem sources
(DataForSEO demand + Reddit voice); `SOLUTION_CANDIDATE` = AI-proposed solution characteristics (hypothesis,
not evidence); `PRODUCT_MATCHED` = canonical `commerce_products` row created via `ingest_commerce_product`;
`MARKET_ASSESSED` = a finalized `commerce_research_run` + PME; `PRODUCT_DECISION_READY` =
`product_opportunity_decisions` row exists.

---

## F. Problem → product matching contract (LLM proposes, evidence disposes)
- The AI (existing n8n LLM nodes) may **propose** a hypothesis: problem cluster → solution characteristics
  → candidate product name/category. **This is a hypothesis, never evidence.**
- Promotion to `PRODUCT_MATCHED` requires an **observable** anchor: a real candidate product created via
  `ingest_commerce_product` + `ingest_resolved_product_entity` (source-independent normalized-title dedup,
  per mig_255 — a rediscovery links to the existing canonical product and preserves original provenance).
- `SOLUTION_CANDIDATE` / `PRODUCT_MATCHED` status **must be gated on real evidence**, not the LLM
  assertion. **Supplier availability alone is NOT customer demand** (locked). The demand basis stays the
  DataForSEO/Reddit problem signals; CJ enters only afterwards. **EXTEND (matcher = thin qualifier + LLM
  hypothesis + evidence gate), reusing dedup/identity.**

---

## G. Existing Product Decision reuse path (no parallel scoring)
Once a candidate product exists (PRODUCT_MATCHED), it enters the **unchanged** pipeline exactly like a
product-first candidate:
```
ingest_commerce_product  (candidate, provenance = problem_cluster)
  → monday_opportunity_registry
  → fn_own_request_product_market_research(product_id, market, freshness)
  → fn_research_dispatch → 013N Auto-Dispatch Executor (eBay/Meta/DataForSEO/CJ/Reddit/TikTok fan-out)
  → fn_research_ingest_source (per-source normalizers)
  → fn_finalize_research_run → fn_evaluate_product_market (PME)
  → fn_pod_evaluate / fn_canonical_product_decision_v2 → product_opportunity_decisions
```
**The same WPS (`pm_score_v1`), the same fail-closed hard gates, the same WATCH ladder.** No new scoring
path. **Existing WATCH gates are NOT weakened.** **REUSE (0 change to the decision core).**

---

## H. Market-presence truth rules (LOCKED)
Strateloq must **NEVER** claim *"this product is not sold in [country]"* from zero listings. The existing
architecture already supports the correct evidence-bounded language:
- Use **`LOW OBSERVED MARKET PRESENCE`** (a coverage/evidence statement), never a non-existence claim.
- The existing `commerce_research_source_attempt` states already distinguish `SEARCHED_NO_EVIDENCE`
  (legitimately searched, nothing found) from `BLOCKED_EXTERNAL_ACCESS` / `SOURCE_FAILED` /
  `NOT_SEARCHED` — so "we looked and saw little" is never conflated with "it does not exist" or "we could
  not look." `fn_ecommerce_research_coverage` already exposes selected market, sources searched, coverage,
  freshness, sources_with_evidence, and blocked/failed sources. **REUSE** — only the *presentation label*
  ("LOW OBSERVED MARKET PRESENCE") needs wording in the eventual read contract. **REUSE + EXTEND (label).**

---

## I. Multi-market reuse
`ecommerce_market_universe` + per-market `commerce_research_run` + per-market PME/decision already provide
market isolation (proven GB vs DE divergence: 68.2 vs 73.2). A problem cluster carries a `market`, and its
matched product runs the standard per-market research. **REUSE (no change).**

## J. Supplier sequencing
CJ runs **last**, only after PRODUCT_MATCHED, as one evidence category among six — it enriches
economics/availability but is excluded from the demand basis. This is already how `fn_research_ingest_source`
treats `CJ → SUPPLIER`. **REUSE** — the only rule to enforce in the problem qualifier is: *supplier
availability may not advance PROBLEM_* status.* **REUSE + guard.**

## K. Minimal user-input contract (no UI yet)
Two workspace entry points: **Discover Products** (existing) and **Discover Problems** (new). For **Discover
Problems** the user minimally selects:
- **market** (required; from `ecommerce_market_universe`).
- **category / niche** (required — bounds the problem space and cost; reuses category vocabulary).
- **optional problem/search seed** (free text, e.g. "back pain while working from home") — improves
  precision; if omitted, the category drives DataForSEO/Reddit seeds.

The result must **truthfully** contain: the problem cluster(s) with status on the ladder; the problem
evidence (source, market, query/topic, freshness, provenance); each proposed solution candidate flagged as
**hypothesis vs evidence-backed**; per selected market — sources searched, coverage, freshness, observed
listing/competitor evidence, and **unavailable/failed sources**; and, where presence is thin, **LOW
OBSERVED MARKET PRESENCE** (never a non-existence claim). No fabricated demand, no supplier-driven demand.

## L. Cost per run estimate (no API calls made)
- **FREE / reusable:** Reddit public JSON (problem voice), eBay Browse (app OAuth), Meta Ad Library, TikTok
  Commercial Content (research scope), CJ product/query, and **all** Supabase RPC/normalization/PME/decision
  compute. The 013N fan-out for a matched product is the same free set already used for product-first runs.
- **PAID (only external dependency):** **DataForSEO Labs** keyword/intent endpoints for problem-demand
  seeding — the same provider already integrated for product search demand. A single problem-discovery run
  is a small bounded batch (≈1–3 Labs requests: keyword ideas/suggestions for the seed/category + search
  volume/intent), i.e. the **same order of magnitude as one product-first DataForSEO research call** and
  within the existing per-run envelope. **Exact per-call price should be read from the DataForSEO account /
  existing pricing evidence at implementation time — not asserted here (no call was made).**
- Optional LLM cost: the problem→solution hypothesis reuses existing n8n LLM nodes (one bounded call).

## M. External blockers
- **None hard.** DataForSEO is live and is the only paid dependency; Reddit/eBay/Meta/TikTok/CJ are all
  connected. TikTok/Meta ad-absence must be treated as *no corroboration*, never *no demand* (locked).
- **Soft:** Meta Ad Library commercial coverage is EU/UK-only (registry already encodes this per market);
  outside those markets Meta is `SOURCE_UNSUPPORTED` and must show as unavailable, not negative.

## N. Smallest implementation sequence (proposed for 015B+, not built here)
1. **015B (NEW, small):** `commerce_problem_clusters` table + status ladder + `commerce_signals` problem
   types (`product_id NULL`, `provenance.problem_cluster_id`) + selftest. No pipeline change.
2. **015C (EXTEND):** problem-mode DataForSEO qualifier (keep informational/question intent) + a thin
   problem-relevance/cluster step reusing `fn_classify_search_query_relevance` machinery; wire the existing
   DataForSEO discovery workflow to a problem seed. Reddit pain-extraction shape into problem signals.
3. **015D (EXTEND, thin):** problem→product matcher (LLM hypothesis + evidence gate + `ingest_commerce_product`
   dedup) → `monday_opportunity_registry`.
4. **015E (REUSE):** run the matched candidate through the **unchanged** 013N research → PME → Product
   Decision; add read-contract fields (problem lineage, `LOW OBSERVED MARKET PRESENCE` label).
5. **015F (DEFER):** optional `trend_signals` opportunistic seeding; optional Meta/TikTok corroboration
   surfacing.

---

## Component classification summary
| Component | Class |
|---|---|
| Evidence store (`commerce_signals`, nullable product_id) | **REUSE** |
| Research run / source-attempt / dispatch / normalizers | **REUSE** |
| PME + Product Decision + hard gates + WATCH ladder | **REUSE** |
| Multi-market catalog + isolation | **REUSE** |
| Candidate registry + identity dedup | **REUSE** |
| Provider registry + coverage/source-state reads | **REUSE** |
| Supplier (CJ) sequencing | **REUSE (+ demand guard)** |
| DataForSEO discovery workflow + relevance classifier | **EXTEND** |
| Reddit adapter (product → pain extraction) | **EXTEND** |
| Market-presence label ("LOW OBSERVED MARKET PRESENCE") | **EXTEND** |
| `commerce_problem_clusters` + problem signal types + status ladder | **NEW (small, additive)** |
| Problem→product matcher (hypothesis + evidence gate) | **NEW (thin)** |
| `trend_signals` seeding / cross-surface corroboration | **DEFER** |

---

## FINAL VERDICT
**`PROBLEM_INTELLIGENCE_REUSE_READY`** — the entire evidence→research→PME→Product-Decision→multi-market→
supplier spine is reusable unchanged; problem-first needs only a small additive problem-front layer (one
new table + problem signal types + a problem-mode qualifier/matcher) feeding the existing candidate registry
and pipeline. No parallel architecture, no second scoring system, no weakened gates.

**STOP. Do not implement 015B.**

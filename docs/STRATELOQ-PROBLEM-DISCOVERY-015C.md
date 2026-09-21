# STRATELOQ-PROBLEM-DISCOVERY-015C — DataForSEO + Reddit Problem Discovery

**FINAL VERDICT: `PROBLEM_DISCOVERY_READY_PAID_TEST_REQUIRED`.**

The problem-discovery backend is built and **fully fixture-verified (15/15, A–O)** on top of the 015B
foundation, reusing the existing SEARCH_DEMAND/DataForSEO and COMMUNITY/Reddit providers in an additional
"problem mode" — product-first discovery is untouched. Deterministic problem-mode qualifiers, evidence
receivers, service-side clustering, canonical source-attempt truth, market isolation and the 015B
corroboration contract are all in place and tested with fixtures only. **No paid call was made.** The
expected real bounded test is exactly costed (2 DataForSEO Labs live requests ≈ **€0.03**; Reddit free),
so per the cost gate I **stop before the paid call** and await founder authorization to run the single
bounded GB test.

---

## 0. Precondition
015B verified live: `fn_problem_foundation_selftest` = **10/10 all_pass**; `commerce_problem_clusters`,
`commerce_signals.problem_cluster_id`, `fn_problem_cluster_upsert/_signal_attach/_corroboration_state/_promote`
all present. Not blocked.

## 1. Architecture reused
Providers: `provider_capability_registry` DATAFORSEO/SEARCH_DEMAND=AVAILABLE, REDDIT/COMMUNITY=AVAILABLE
(no new providers). Evidence store: `commerce_signals` (product_id NULL) via the 015B canonical
`fn_problem_signal_attach`. Corroboration: the 015B deterministic contract verbatim (no new score).
Market catalog: `ecommerce_market_universe.dataforseo_location_code`. Product-first objects unchanged.

## 2. DataForSEO problem-mode implementation
`fn_dataforseo_problem_qualify(query, category, intent, volume)` — PURE/IMMUTABLE. Keeps observable
problem/solution/question queries; classifies `problem_kind` ∈ {SOLUTION_SEEKING, PROBLEM, QUESTION}.
Rejects commercial-product queries (`commercial_product_query` — they belong to product mode) and generic
informational noise (`no_problem_pattern`). Volume/intent are **recorded, never converted to sales**;
volume is not a hard gate (real problems can be low-volume). The existing product-mode
`fn_dataforseo_discovery_qualify` is **not modified** (test A).

## 3. Reddit problem-mode implementation
`fn_reddit_pain_classify(text, category)` — PURE/IMMUTABLE. Returns COMMUNITY_PAIN / COMMUNITY_WORKAROUND /
COMMUNITY_UNMET_NEED / NONE. Rejects promotional & supplier posts first, then generic mentions (`NONE`).
The existing Reddit product-attention path is untouched (this is an additional classifier).

## 4. Signal types produced
`SEARCH_PROBLEM_DEMAND` (DataForSEO), `COMMUNITY_PAIN` / `COMMUNITY_WORKAROUND` / `COMMUNITY_UNMET_NEED`
(Reddit) — all the 015B taxonomy, stored in `commerce_signals` with `product_id NULL`, `problem_cluster_id`
set, raw query/context preserved in `value`/`evidence`.

## 5. Clustering behavior
`fn_problem_cluster_ensure(run_id, canonical_problem, summary)` (service-side) upserts a cluster under the
**run's tenant** (never browser-supplied) and links it via `provenance.discovery_run_id`. The LLM/n8n may
PROPOSE cluster labels; the receivers only ever attach evidence that exists in the fetched payload — no
fabrication (test H: 2 qualifying + 1 non-qualifying → exactly 2 attached). Every cluster retains links to
the underlying real `commerce_signals` rows.

## 6. Market isolation
Receivers stamp `market_scope` = SELECTED_MARKET iff evidence market = cluster market, else
CONTEXTUAL_CROSS_MARKET (015B rule). Corroboration counts only selected-market signals; cross-market is
retained but never corroborates (test K: DE evidence on a GB cluster → SINGLE_SOURCE, contextual≥1).

## 7. Source-attempt behavior
Per-run `source_states` use the canonical vocabulary (`NOT_SEARCHED`, `SEARCHING`,
`SEARCHED_EVIDENCE_FOUND`, `SEARCHED_NO_EVIDENCE`, `SOURCE_FAILED`, `SOURCE_UNAVAILABLE`, `SOURCE_BLOCKED`,
`UNSUPPORTED_MARKET`). A non-array/error payload → `SOURCE_FAILED` (test L). A successful search with zero
qualifying evidence → `SEARCHED_NO_EVIDENCE` (test M). Provider failure is never mislabeled as no-evidence.

## 8. Corroboration behavior
Reuses `fn_problem_corroboration_state` unchanged: 1 qualifying → SINGLE_SOURCE; many from one provider →
MULTI_EVIDENCE_SINGLE_SOURCE (test I); Reddit + DataForSEO → MULTI_SOURCE_CORROBORATED (test J); supplier
(CJ) evidence never counts (test O). Promotion to PROBLEM_CORROBORATED still requires
MULTI_SOURCE_CORROBORATED. No automatic promotion.

## 9. Server contract
`fn_request_problem_discovery(market, category, optional_problem_seed)` — authenticated; tenant =
`auth.uid()`; **category required** (no unconstrained search); validates market via
`ecommerce_market_universe`; creates the run with per-provider source states; returns a dispatch manifest
for n8n. **Makes no paid call.** Browser supplies only market/category/seed — never tenant, corroboration,
evidence or promotion. Read: `fn_problem_discovery_read(run_id?)` (own runs + states + clusters +
corroboration). Evidence write/clustering/promotion are service_role-only.

## 10. Fixture tests — `fn_problem_discovery_selftest()` **15/15 all_pass**
A product-mode unchanged ✓ · B problem mode retains ✓ · C noise+commercial rejected ✓ · D raw query
preserved ✓ · E complaint→PAIN ✓ · F workaround→WORKAROUND ✓ · G generic/promo→NONE ✓ · H no fabrication ✓
· I same-source no corroboration ✓ · J Reddit+DataForSEO corroborated ✓ · K GB/DE isolation ✓ · L failure≠
no-evidence ✓ · M zero-result=SEARCHED_NO_EVIDENCE ✓ · N no product matching ✓ · O supplier no contribution
✓. Fixtures only; self-cleaning (0 residual runs/clusters/signals).

## 11. Product-first regressions
`fn_dataforseo_discovery_selftest` (product mode) ✓ · `fn_problem_foundation_selftest` (015B) 10/10 ✓ ·
`fn_deep_research_selftest` ✓ · `fn_research_orchestrator_selftest` ✓ · `fn_search_relevance_selftest` ✓ ·
`fn_tiktok_executor_selftest` ✓. All green.

## 12. Expected DataForSEO request count / cost
One bounded GB problem-discovery request family = **2 DataForSEO Labs *live* requests**:
`dataforseo_labs/google/keyword_ideas/live` + `dataforseo_labs/google/search_intent/live`
(one `location_code`). Per existing founder cost evidence (013Q §18: "humidifier scan (keyword_ideas +
search_intent) ≈ €0.03"), expected cost ≈ **€0.03**. Reddit problem fetch is **free** (public JSON).
This is the entire paid surface for one bounded test.

## 13. Real bounded test executed?
**No.** Honoring the cost gate ("report expected request count and expected cost… perform ONE
founder-authorized bounded real test only if… permit"), no provider was called — neither the paid
DataForSEO family nor the free Reddit fetch — pending explicit founder authorization to keep the bounded
test a single authorized unit.

## 14–17. Evidence / clusters / corroboration / paid cost (real run)
None — no real run performed. **Paid cost = €0.** No problem clusters or signals persisted (fixtures
self-cleaned).

## 18. Security advisors
**0 ERROR, 1 INFO, 4 WARN** — unchanged baseline (INFO = pre-existing `product_image_assets` deny-all).
Both new tables (`commerce_problem_clusters` 015B, `commerce_problem_discovery_runs` 015C) have RLS enabled
with own-read + service_all policies → no net-new advisor.

## 19. Changes / migrations / workflows
- `supabase/migrations/mig_271_problem_discovery_dataforseo_reddit.sql`: `commerce_problem_discovery_runs`
  (RLS) + `fn_dataforseo_problem_qualify` + `fn_reddit_pain_classify` + `fn_problem_discovery_set_source_state`
  + `fn_problem_cluster_ensure` + `fn_ingest_dataforseo_problem_demand` + `fn_ingest_reddit_problem_pain` +
  `fn_request_problem_discovery` + `fn_problem_discovery_read` + `fn_problem_discovery_selftest`.
- No n8n workflow built/executed (deferred to the authorized bounded test). No Lovable. No product-first
  object modified. No provider availability changed.

## 20. Commit
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`; see delivery message.

---

## Founder authorization requested (bounded real test)
On your go I will run exactly ONE bounded GB problem-discovery test — suggested category **"shoe storage"**
(founder test data includes the over-door shoe organizer), optional seed e.g. "shoes pile up by the door":
- **DataForSEO:** 2 Labs live requests (keyword_ideas + search_intent), GB, ≈ **€0.03**.
- **Reddit:** one bounded public-JSON fetch, **free**.
Result would populate real GB problem clusters, classify evidence, set canonical source states, and evaluate
015B corroboration — **stopping at PROBLEM_DISCOVERED / PROBLEM_CORROBORATED**. No product matching, no
suppliers, no Product Decisions.

**STOP.** No product matching. No suppliers. No Product Decisions. No Lovable. 015D not started. Verdict
`PROBLEM_DISCOVERY_READY_PAID_TEST_REQUIRED`.

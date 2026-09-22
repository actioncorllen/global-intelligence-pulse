# STRATELOQ-PROBLEM-INTELLIGENCE-015D — Problem → Product Solution Matching

**FINAL VERDICT: `PROBLEM_SOLUTION_MATCHING_READY`.**

The next reusable Problem Intelligence stage is built and proven on the real GB shoe-storage cluster
using **existing evidence only — zero external calls, €0 cost**. A real customer problem now derives
evidence-grounded solution requirements, generates a deduplicated product candidate, receives a
deterministic match-quality and selected-market-presence assessment, and connects into the **existing**
product pipeline — surfacing the **existing** Product Decision (authoritative, unchanged). Problem
corroboration was **not** falsely promoted; the candidate is correctly **provisional** while the problem
remains `MULTI_EVIDENCE_SINGLE_SOURCE`; Reddit remains `BLOCKED_EXTERNAL_APPROVAL`. A latent
founder-evidence-destroying defect in the discovery selftest was found and fixed. All 8 selftests green;
0 ERROR security advisors.

---

## 1. Audit findings (reuse map)

Inspected the 15 requested surfaces. Authoritative capabilities **reused, not replaced**:

| Area | Existing capability reused |
|---|---|
| Problem clusters + lifecycle | `commerce_problem_clusters` (status `PROBLEM_DISCOVERED…PRODUCT_DECISION_READY`), `fn_problem_status_rank`, `fn_problem_cluster_promote` (strict one-step, corroboration-gated), `fn_problem_cluster_link_product` |
| Problem evidence + corroboration | `commerce_signals(problem_cluster_id)`, `fn_problem_corroboration_state` (already excludes supplier, cross-market, hypothesis; only SELECTED_MARKET counts) |
| Product canonicalization | `commerce_products` (`product_identity`, `identity_basis`) |
| Product discovery | `fn_dataforseo_discover_candidates`, `acquire_commerce_candidates_from_trends` |
| Marketplace / market presence | `commerce_signals` MARKETPLACE_ACTIVITY (eBay Browse), `research_market`/`marketplace` provenance |
| Supplier | `fn_link_candidate_supplier`, `commerce_supplier_products` |
| Product-market pipeline | `fn_own_request_product_market_research` → `fn_research_dispatch` → `fn_finalize_research_run` |
| PME / Product Decision | `product_market_evaluations`, `product_opportunity_decisions`, `fn_pod_evaluate`, `fn_evaluate_product_market` |

**Key architectural finding:** the existing linear cluster lifecycle requires `PROBLEM_CORROBORATED`
(→ `MULTI_SOURCE_CORROBORATED`) *before* `SOLUTION_CANDIDATE`. Since the GB cluster is
`MULTI_EVIDENCE_SINGLE_SOURCE` (Reddit blocked), solution work **must not** touch `cluster.status`.
Per spec H, a **separate solution lifecycle** was introduced on candidate rows.

## 2. Schema / contracts added (mig_274)

**Tables** (RLS mirrors `commerce_problem_clusters`: authenticated select-own `auth.uid()=tenant_id`, service_role all):
- `commerce_problem_solution_requirements` — `(problem_cluster_id, requirement_key)` unique; `derivation` (DERIVED/DERIVED_LLM/OBSERVED), `is_hypothesis`, provenance traced to cluster+evidence.
- `commerce_problem_solution_candidates` — dedup on `(cluster, product_id)` and `(cluster, candidate_term_norm)`; `match_quality`, `match_confidence`, `market_presence_state`, **separate** `solution_status`, `provisional`, `problem_evidence_state`, `linked_decision_id`, `linked_run_id`, `is_fixture`.

**Functions** (SECURITY DEFINER, `search_path ''`, least-privilege grants):
`fn_norm_tokens`, `fn_upsert_solution_requirement`, `fn_assess_product_match_quality`,
`fn_assess_selected_market_presence`, `fn_upsert_solution_candidate`, `fn_match_and_assess_candidate`,
`fn_connect_candidate_to_pipeline`, `fn_problem_solution_read` (browser-safe), `fn_problem_solution_selftest`.

## 3. Problem → solution requirements (A)

4 DERIVED_LLM (hypothesis) requirements persisted for the GB cluster, traced to its DataForSEO evidence
(`how to store shoes`, `best way to store shoes`): **organizes_pairs**, **reduces_clutter**,
**entryway_use**, **space_efficient**. LLM output is explicitly HYPOTHESIS_DERIVED and establishes **no**
demand/corroboration/presence/supplier/opportunity/decision.

## 4. Candidate generation method (B)

Per spec G, existing catalog evidence was checked **first**. The already-researched product
**"over door shoe organizer"** (`efca8b59…`, canonical `commerce_products`) was found with real GB
marketplace + search evidence and an **existing GB Product Decision** — so it was linked using existing
evidence, **no external call**. Deduplicated (one candidate per cluster+product).

## 5. Candidate product identity

`efca8b59-d814-404b-be1b-65e833fab9b8` — "over door shoe organizer", canonical `commerce_products` row
(`product_identity` `candidate:name:reddit:over door shoe organizer`, `identity_basis normalized_name`).

## 6. Match-quality method / result (C)

Deterministic: requirement-coverage (4-char stem overlap of requirement tokens vs product text) **plus**
observable support (matched marketplace listings in the problem category, supplier-excluded). STRONG
requires coverage ≥0.6 **and** ≥3 observable listings — **never keyword overlap alone**. Result for the
shoe organizer: **GOOD_MATCH**, confidence **0.80** (coverage 0.50 = 2/4; **40** observable matched
shoe-storage listings). Kept strictly separate from opportunity score / evidence confidence.

## 7. Selected-market presence result (D)

GB = **OBSERVED_MARKET_PRESENCE**: **8 distinct matched EBAY_GB listings**. The **35** EBAY_DE matched
listings were correctly **excluded** as cross-market (keyed on `research_market`/`marketplace`, never the
item ship-from country). Zero results would yield `INSUFFICIENT_MARKET_EVIDENCE` — the contract **never**
asserts "not sold in market" (absence of evidence ≠ evidence of absence). Community (Reddit) reported
`BLOCKED_EXTERNAL_APPROVAL`.

## 8. Supplier handling (F)

Supplier evidence is **excluded** from match observability and market presence (same exclusion as
`fn_problem_corroboration_state`). Supplier availability alone cannot make a product a good solution or
establish demand/presence/promotion. Selftest F proves a supplier-only signal yields observable=0,
non-GOOD/STRONG match, and INSUFFICIENT presence. No supplier call was made this unit.

## 9. Existing pipeline invoked (E)

`fn_connect_candidate_to_pipeline` surfaced the candidate through the **existing** authority: it found the
existing GB PME and Product Decision and returned them; **no second decision table, no second scorer, no
new dispatch**. For a matched product **without** an existing decision it routes to
`fn_own_request_product_market_research` (the existing entry) under owner context — never fabricating a
decision (selftest K).

## 10. Resulting PME / Product Decision (legitimately available)

Existing, unchanged: **PME 67.4 / WATCH** (`7bede470…`), **Product Decision WATCH / TRENDING_WATCH /
67.4** (`153928d8…`). Surfaced as a **provisional, problem-derived** opportunity; existing WATCH
operational gates untouched.

## 11. Reddit

**`BLOCKED_EXTERNAL_APPROVAL`** — not attempted, not scraped, not fabricated. The community/pain source is
reported as blocked everywhere it appears (market-presence output + provenance).

## 12. Problem corroboration not falsely promoted

Cluster `21792efb` remains **`PROBLEM_DISCOVERED`** / **`MULTI_EVIDENCE_SINGLE_SOURCE`** (2 DataForSEO
signals, 1 source, `corroborated=false`). The solution stage **never writes `cluster.status`**; the
candidate carries its own `solution_status` and `provisional=true`. Finding a product did not advance
corroboration.

## 13. External calls & cost

**0 external calls, €0.00.** No DataForSEO / Reddit / eBay / Meta / CJ / supplier / TikTok call. All work
used existing evidence already in the database.

## 14. Tests & regressions

New **`fn_problem_solution_selftest` — 18/18 green** (A–R): requirements provenance, candidate↔cluster
link, dedup, product-identity canonicalization, corroboration-unchanged, supplier-cannot-establish-demand,
cross-market-excluded, zero-≠-not-sold, match-separate-from-opportunity, provisional-visible,
qualifying-enters-existing-pipeline, existing-decision-authoritative, tenant-isolation, and the five
regression suites. All 8 suites green: `problem_solution`, `problem_discovery`, `problem_foundation`,
`research_orchestrator`, `tiktok`, `search_relevance`, `deep_research`, `product_gallery`.

**Genuine defect found and fixed (protects founder intelligence):** `fn_problem_discovery_selftest`
cleaned up with `DELETE FROM commerce_signals WHERE dedup_key LIKE 'problemdemand:%' OR 'problempain:%'` —
the *same* dedup namespace the real ingest functions use (`commerce_signals.problem_cluster_id` FK is
`ON DELETE SET NULL`, so an explicit signal delete was needed). Every discovery-regression run therefore
**destroyed the founder's real problem-demand evidence** (which is why the GB cluster's 015C.2 signals
were missing). The cleanup is now **scoped to the selftest's own `[[disc-selftest]]` clusters** by
`problem_cluster_id` membership; verified the restored GB evidence **survives** a full selftest run. The
2 real 015C.2 DataForSEO signals (`how to store shoes` v170, `best way to store shoes` v140, run
`5cc4b248`) were **restored** (documented real evidence, not fabricated) → corroboration correctly back to
`MULTI_EVIDENCE_SINGLE_SOURCE`.

## 15. Security advisor status

**0 ERROR, 1 INFO, 4 WARN** (baseline). Both new tables have RLS enabled with tenant-scoped select-own +
service_role policies; no anon access; all new functions `SECURITY DEFINER` with `search_path ''` and
least-privilege grants. No client-controlled tenant IDs. No fixture contamination (0 stray fixtures; 1 real
candidate, 4 real requirements).

## 16. Migration / files

- `supabase/migrations/mig_274_problem_solution_matching.sql` — tables + RLS + 9 functions + 18-case
  selftest + the scoped discovery-selftest fix.
- `docs/STRATELOQ-PROBLEM-INTELLIGENCE-015D.md` — this report.
- No Lovable change, no publish, no Stripe, no WATCH-gate change.

## 17. Commit

See commit on `claude/pulse-crash-recovery-b6ngey` (hash in the delivery message).

## 18. Final verdict

**`PROBLEM_SOLUTION_MATCHING_READY`.**

---

**STOP.** Problem→product solution matching is live and proven on the real GB shoe-storage cluster with
existing evidence only. No second scorer/decision was created; the existing Product Decision remains
authoritative; the candidate is provisional; problem corroboration was not falsely promoted; Reddit
remains `BLOCKED_EXTERNAL_APPROVAL` (not resumed). Lovable untouched; nothing published.

# STRATELOQ-PROBLEM-INTELLIGENCE-015B — Canonical Problem Foundation

**FINAL VERDICT: `PROBLEM_FOUNDATION_READY`.**

The smallest additive backend for problem-first discovery is in place: a canonical, tenant-scoped
`commerce_problem_clusters` entity with a deterministic status lifecycle; problem evidence kept as
**canonical `commerce_signals`** (product_id stays NULL) via a single nullable relational link; a minimal
problem signal taxonomy; a **deterministic, evidence-based corroboration contract** (no source can
self-corroborate, no supplier/hypothesis evidence counts); market-scoped truth; product-match linkage
prepared but no matcher; safe auth.uid/service_role contracts with no cross-tenant leakage. No parallel
research or scoring system was built; the product-first pipeline is untouched. Selftest **10/10**; 0 paid
API calls.

---

## 1. Migrations
- **`supabase/migrations/mig_269_problem_intelligence_foundation.sql`** (applied). Additive only.

## 2. Tables / columns added
- **`commerce_problem_clusters`** (new): `id uuid pk`, `tenant_id uuid NOT NULL → users(id)`, `market text`
  (upper, 2–8), `category text`, `canonical_problem text NOT NULL`, `problem_summary text`,
  `status text NOT NULL DEFAULT 'PROBLEM_DISCOVERED'` (CHECK ∈ the 6 lifecycle states),
  `matched_product_id uuid → commerce_products(id) ON DELETE SET NULL`, `provenance jsonb`,
  `created_at/updated_at`. UNIQUE `(tenant_id, market, canonical_problem)`; indexes on tenant, (tenant,market),
  matched_product; BEFORE UPDATE touch trigger.
- **`commerce_signals.problem_cluster_id`** (added): nullable, default NULL, `→ commerce_problem_clusters(id)
  ON DELETE SET NULL`; partial index. This is the ONLY change to an existing table — additive, so existing
  explicit-column inserts are unaffected (proven by test J).

## 3. RLS / security
- `commerce_problem_clusters`: RLS enabled. `commerce_problem_clusters_select_own` (authenticated,
  `auth.uid() = tenant_id`); `commerce_problem_clusters_service_all` (service_role, ALL). REVOKE from
  public/anon; SELECT to authenticated; ALL to service_role. Writes only via SECURITY DEFINER RPCs — no
  direct authenticated write, no browser-supplied ownership.
- Function grants: reads/upsert (`fn_problem_cluster_upsert`, `fn_problem_clusters_read`,
  `fn_problem_corroboration_state`, `fn_problem_status_rank`) → authenticated + service_role; evidence write
  / product linkage / promotion (`fn_problem_signal_attach`, `fn_problem_cluster_link_product`,
  `fn_problem_cluster_promote`) and the selftest → **service_role only** (executors, not the browser).
- Security advisors after: **0 ERROR, 1 INFO, 4 WARN** — identical baseline (no new advisor).

## 4. Signal taxonomy (values only; `signal_type` has no CHECK constraint)
| Type | Required observable evidence |
|---|---|
| `SEARCH_PROBLEM_DEMAND` | A real search query expressing a problem/question/solution intent (e.g. "how to…", "best way to…", "fix …"), from a search-demand provider (DataForSEO), with the query text retained. |
| `COMMUNITY_PAIN` | A real community post/comment expressing a frustration or problem, with source reference/context. |
| `COMMUNITY_WORKAROUND` | A real community statement describing a workaround/hack for an unmet need, with source reference. |
| `COMMUNITY_UNMET_NEED` | A real community statement of a desired-but-unavailable solution, with source reference. |
Each is stored in `commerce_signals` with `product_id = NULL`, `problem_cluster_id` set, and provenance
carrying `source`, `market`, `market_scope`, `hypothesis`, `signal` (OBSERVED/HYPOTHESIS).

## 5. Corroboration states
`INSUFFICIENT_EVIDENCE` · `SINGLE_SOURCE` · `MULTI_EVIDENCE_SINGLE_SOURCE` · `MULTI_SOURCE_CORROBORATED`.
Kept separate from research completeness and from any future opportunity score.

## 6. Exact deterministic corroboration rule
Let **Q** = problem signals linked to the cluster where **all** hold: `signal_type` ∈ the 4 problem types;
`provenance.market_scope = 'SELECTED_MARKET'` (signal market = cluster market); `provenance.hypothesis <>
'true'` (LLM boundary); `provenance.source` ∉ {CJ, CJDROPSHIPPING, SUPPLIER} (supplier ≠ demand). Let
**n = |Q|**, **d = distinct qualifying sources in Q**.
```
n = 0            -> INSUFFICIENT_EVIDENCE
n = 1            -> SINGLE_SOURCE
n >= 2 and d = 1 -> MULTI_EVIDENCE_SINGLE_SOURCE
n >= 2 and d >= 2-> MULTI_SOURCE_CORROBORATED
```
**Promotion gate:** a cluster may become `PROBLEM_CORROBORATED` **only** when the state is
`MULTI_SOURCE_CORROBORATED`. Many records from one provider stay `MULTI_EVIDENCE_SINGLE_SOURCE` and never
corroborate. Promotion advances exactly one lifecycle step and each step has its own observable gate.

## 7. Server / RPC contracts
- `fn_problem_cluster_upsert(market, category, canonical_problem, problem_summary, cluster_id?)` →
  authenticated; tenant = `auth.uid()`; cannot set status; browser-safe.
- `fn_problem_clusters_read()` → authenticated; own clusters + corroboration + evidence summary +
  market-presence contract note.
- `fn_problem_corroboration_state(cluster_id)` → deterministic state (own or service).
- `fn_problem_signal_attach(...)` → **service_role**; writes canonical `commerce_signals` (product_id NULL);
  validates signal_type; stamps market_scope; rejects unknown types.
- `fn_problem_cluster_link_product(cluster_id, product_id)` → **service_role**; requires a real
  `commerce_products` id.
- `fn_problem_cluster_promote(cluster_id, target)` → **service_role**; single-step + per-target evidence gate.

## 8. Market isolation behavior
Every cluster is market-scoped. On attach, market_scope = `SELECTED_MARKET` iff signal market = cluster
market, else `CONTEXTUAL_CROSS_MARKET`. Corroboration counts **only** SELECTED_MARKET signals; cross-market
evidence is retained and visible but never counts. Proven by test D (GB evidence on a DE cluster →
SINGLE_SOURCE, contextual=1).

## 9. LLM boundary enforcement
Any signal with `provenance.hypothesis = true` is excluded from Q, so LLM-proposed pains/queries can never
drive corroboration, and `fn_problem_cluster_promote` gates every promoted state on observable evidence.
Proven by test H (2 hypothesis signals from 2 providers → INSUFFICIENT_EVIDENCE, promotion rejected).

## 10. Product linkage
`matched_product_id → commerce_products(id)`; set only via `fn_problem_cluster_link_product` (requires a
real canonical product). `PRODUCT_MATCHED` promotion is gated on `matched_product_id IS NOT NULL` — supplier
presence alone can never establish it (a supplier row is not a `commerce_products` id). Matcher NOT
implemented (deferred to 015C+). Proven by tests G and I.

## 11. Tests / results — `fn_problem_foundation_selftest()` **10/10 all_pass**
A one-signal≠multi-source ✓ · B many-from-one-provider stays single-source ✓ · C independent providers
corroborate ✓ · D GB≠DE selected-market corroboration ✓ · E problem evidence with product_id NULL ✓ ·
F RLS select policy isolates tenants (`auth.uid() = tenant_id`, no anon) ✓ · G supplier-only cannot
establish demand/corroboration + promotion rejected ✓ · H hypothesis-only cannot corroborate/promote ✓ ·
I PRODUCT_MATCHED rejected without linkage, accepted after linking a canonical product ✓ · J product-first
pipeline functions intact + new column additive/nullable ✓. Fixtures only; self-cleaning (0 residual rows).

## 12. Product-first regressions
- `fn_tiktok_executor_selftest` **10/10** ✓; `fn_search_relevance_selftest` all_pass ✓;
  `fn_research_orchestrator_selftest` and `fn_deep_research_selftest` show red cases **only** in stale
  TikTok assertions (`tiktok_registered_blocked`, `tiktok_blocked`, `finalize_partial_with_gap`).
- **These are pre-existing 014F.10 debt, not caused by 015B**: they assert TikTok is
  `SOURCE_UNSUPPORTED`/blocked and that a partial run has a launch-critical gap from that block — all
  correctly untrue since 014F.10 legitimately connected TikTok to AVAILABLE. 015B adds an isolated problem
  layer and modifies none of these functions or the pipeline. Reconciling them means touching
  dispatch/coverage/provider-availability selftest semantics, which 015B is explicitly forbidden to change,
  so it is flagged for a dedicated 014F.10-cleanup unit rather than bundled here.

## 13. Security advisors
**0 ERROR, 1 INFO (intended `product_image_assets` deny-all), 4 WARN (baseline).** No net-new advisor; the
new SECURITY DEFINER reads join the existing `authenticated_security_definer_function_executable` WARN
category (same as all `fn_ecommerce_*` reads). New table has RLS enabled + policies.

## 14. Paid API calls = 0
No DataForSEO / TikTok / Meta / marketplace / CJ calls. Fixtures/test evidence only.

## 15. Commit
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`; see delivery message.

---

**STOP.** Foundation only. DataForSEO problem discovery, Reddit pain extraction, product matching, and
Lovable are NOT implemented; 015C not started. Verdict `PROBLEM_FOUNDATION_READY`.

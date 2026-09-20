# STRATELOQ-DATAFORSEO-WORKSPACE-VISIBILITY-013S

**FINAL VERDICT: `DATAFORSEO_PRODUCT_VISIBLE_BACKEND_FIXED`.**

The DataForSEO-discovered product **`cool mist humidifier`** was invisible in the founder Ecommerce
Products workspace because of a **backend lifecycle gap**, now fixed source-agnostically. It had a
canonical `product_market_evaluations` row (score 80.2) but **no `product_opportunity_decisions`
row**, and the workspace RPC iterates the decision layer — so a researched candidate with an
evaluation but no decision was invisible. Root cause: the on-demand 013N research finalizer
(`fn_finalize_research_run`) recomputed the PME but never materialized the decision layer; only the
discovery/Monday evaluator (`fn_pod_evaluate` / `fn_pod_tournament`) wrote decisions. Fix
(`mig_257`): after the PME recompute, `fn_finalize_research_run` now materializes the canonical
decision via the **same evaluator the Monday orchestrator uses** (`fn_pod_evaluate`, `'pod_v1'`),
isolated so it can never fail the finalize. This closes the missing lifecycle link
**research → evaluation → decision → workspace** for ANY research-finalized candidate, with **no**
special-casing of `source_store='dataforseo'`, no WPS change, no manual decision insert, no provider
call. The workspace now returns `cool mist humidifier` (80.2 / MEDIUM / coverage 0.52 /
HIGH_CONFIDENCE_TEST / WATCH). Expected paid-provider cost this unit: **€0** (achieved — audit +
one decision recompute, no external calls).

---

1. **Why the product was invisible (verified root cause)** — `fn_ecommerce_workspace_intelligence()`
   (and `fn_ecommerce_research_coverage()`) iterate `product_opportunity_decisions d JOIN
   commerce_products` (with a LEFT JOIN LATERAL onto the current PME per 013O3). A product that has a
   `product_market_evaluations` row but **no** `product_opportunity_decisions` row is never emitted.
   `cool mist humidifier` (`cda3f71a-9947-4344-8664-13735740575f`) had **1 evaluation, 0 decisions**,
   so it was structurally invisible despite being fully researched.

2. **Where the decision row should have come from** — the decision layer is written ONLY by
   `fn_pod_evaluate` (per-market) and its product-level wrapper `fn_pod_tournament`. The Monday
   orchestrator (`fn_run_monday_product_opportunity`) calls `fn_pod_tournament`, so Monday-scored
   products always get decisions (e.g. `kids nightlight projector` → 4 evaluations, 4 decisions →
   visible). The on-demand 013N path
   (`fn_own_request_product_market_research` → dispatch → `fn_finalize_research_run`) instead called
   `fn_assemble_real_product_market` (PME only) and **never** the decision evaluator. `cool mist
   humidifier` was researched via on-demand 013N (not Monday), so it was the first product to expose
   this pre-existing gap.

3. **Source-agnostic diagnosis** — the defect is independent of discovery source. Any candidate
   finalized through on-demand 013N research — Reddit, DataForSEO, or a future adapter — would have
   received a PME but no decision and been invisible. The DataForSEO origin was incidental (it was
   simply the first product routed through on-demand research rather than the Monday orchestrator).
   The fix is therefore in the finalizer, keyed on the researched `(product, market)`, never on
   `source_store`.

4. **The fix (`mig_257_finalize_materializes_decision.sql`)** — `fn_finalize_research_run` now, after
   updating the run and recomputing the PME, calls
   `public.fn_pod_evaluate(v_run.tenant_id, v_run.product_id, v_run.market, 'pod_v1', true)` inside a
   `BEGIN … EXCEPTION WHEN OTHERS THEN NULL` block. This materializes/refreshes the canonical decision
   for exactly the researched market using the SAME evaluator, band ladder and gating as the Monday
   pipeline. It is isolated: a decision-materialization error can never fail the finalize (the
   PME/evidence remains the source of truth; the decision is derived). Contract marker bumped to
   `pulse_research_finalize_v2_013s` with `decision_materialized:true`.

5. **Correct product rule (confirmed, not weakened)** — a legitimate tenant-owned Ecommerce
   candidate that has completed canonical multi-source evaluation and holds a Product Decision is
   eligible for the Products workspace **regardless of original discovery source** (Reddit /
   DataForSEO / future authorized adapter). This is now satisfied by the shared
   research→decision→workspace path. No quality/security gate was relaxed: the candidate still must
   pass sellability + relevance + research + `fn_pod_evaluate` band/gating; a candidate that was
   merely discovered (no research, no decision) remains correctly invisible.

6. **No special-casing** — the fix adds no branch on `source_store`, no allow-list, no DataForSEO
   reference in the workspace or finalizer logic. Purely: research finalize → evaluate decision.

7. **All three DataForSEO products verified** —
   - `cool mist humidifier` (`cda3f71a…`): researched via 013N → 1 PME, now **1 decision** →
     **VISIBLE** (WATCH). Correct.
   - `cool air humidifier` (`04b286f2…`): discovered candidate, **never researched** → 0 PME, 0
     decision → **NOT visible**. Correct (nothing to show; not a defect).
   - `humidifier for room` (`a4f098c7…`): discovered candidate, **never researched** → 0 PME, 0
     decision → **NOT visible**. Correct.
   The two siblings are intentionally candidate-only; they will become visible only if/when they
   complete research, at which point the same fixed path will materialize their decisions.

8. **Workspace RPC confirmation (as founder auth)** — `fn_ecommerce_workspace_intelligence()`
   returns 8 product decisions including
   `{product_id cda3f71a…, product_title 'cool mist humidifier', country GB, opportunity_score 80.2,
   coverage 0.52, evidence_confidence MEDIUM, opportunity_band HIGH_CONFIDENCE_TEST, decision WATCH,
   source_store 'dataforseo', evaluation_source 'product_market_evaluations'}` — canonical, live PME
   overlay, not stale.

9. **Regression — existing products intact** — 15 founder `commerce_products` (10 reddit + 3
   dataforseo + 2 originals-lineage), **0 duplicates**; the 12 originals retained. No new product
   created, no discovery run, no synthetic product.

10. **Regression — Reddit path returned** — Reddit-originated decisions still present and emitted by
    the workspace (`red light therapy led mask`, `digital picture frame`, `over door shoe organizer`,
    `kids nightlight projector`, …). Reddit discovery/adapter untouched.

11. **Regression — canonical market binding (013O)** — `kids nightlight projector` **GB 68.2** and
    **DE 73.2** unchanged; cross-market isolation intact (GB/DE/FR/US rows independent). Business
    country **GB** unchanged.

12. **Regression — no synthetic evidence** — `cool mist humidifier` has **0** fixture PME rows; its
    decision derives from the real multi-source research (SEARCH_DEMAND + competitors + supplier
    evidence). The materialized decision is computed by `fn_pod_evaluate`, not hand-inserted.

13. **Regression — TikTok** — TikTok source attempts remain `BLOCKED_EXTERNAL_ACCESS`
    (SOURCE_UNSUPPORTED / pending); not faked, not counted as evidence.

14. **013N auto-dispatch intact** — no change to `fn_own_request_product_market_research`,
    `fn_research_dispatch`, or the webhook path; the finalizer change is additive (decision
    materialization appended after the existing run update + PME recompute).

15. **Discovery (013Q) intact** — no change to `fn_dataforseo_discover_candidates`,
    `fn_dataforseo_discovery_qualify`, ingestion promoters, or the n8n discovery workflow. Discovery
    still enqueues candidates to the registry → weekly Monday pipeline (no cadence change).

16. **Selftests** — all backend selftests pass: `dfs_discovery`, `deep_research`, `connection`,
    `contracts`, `media_creative` (4/4), `paid_access`, `orchestrator`, `search_relevance`,
    `storefront_branding`, `storefront_runtime`, `storefront_publish`,
    `storefront_publish_lifecycle`. The `founder_decisions_reachable_*` baseline in
    `fn_ecommerce_connection_selftest` was converted from a frozen `=7` to a monotonic `>= 7`
    (`founder_decisions_reachable_ge7`), mirroring the mig_256 reconcile, because research-finalized
    candidates now legitimately grow the founder decision count (7 → 8). This is an integrity
    assertion (never fewer than the retained baseline), not a relaxed gate.

17. **Security** — advisors: **0 ERROR** (1 INFO + 4 WARN, unchanged baseline). `fn_pod_evaluate`
    invoked server-side with server-controlled tenant/product/market arguments (never from browser).
    Workspace/finalizer remain SECURITY DEFINER with `SET search_path TO ''`; RLS and tenant scoping
    unchanged. DataForSEO credentials remain server-side (n8n), never exposed to Lovable/browser.
    Migration and this doc secret-scanned clean.

**Cost/safety:** paid-provider cost this unit **€0** — audit-only reads plus one internal
`fn_pod_evaluate` decision recompute (no external/paid call, no force-fresh, no discovery, no
dispatch, no WPS scoring change). No Lovable change, no publish.

**Migration:** `mig_257_finalize_materializes_decision.sql` (updates `fn_finalize_research_run` +
monotonic `fn_ecommerce_connection_selftest` baseline). Both applied to the deployed project and
verified. Commit hash / divergence: see delivery message.

**STOP.** Backend defect confirmed and fixed source-agnostically; `cool mist humidifier` now visible.
No second product created, no new discovery, no paid providers, no Lovable change, no publish.

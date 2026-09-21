# STRATELOQ-ECOM-DECISION-WATCH-AUDIT-013V

**FINAL VERDICT: `DECISION_LIFECYCLE_FIXED_READY_FOR_FOUNDER_TEST`.**

The audit proves the WATCH decisions themselves are **truthful and canonical** — every one is
produced by the WPS decision engine (`fn_pod_evaluate`) from the current per-market evaluation, is
**not** stale (`pme_ts == pod_ts` on every row), **not** a hardcoded default, and **not** a
frontend guess. Decisions are uniformly WATCH because a **mandatory hard gate** (supplier stock /
economics / compliance / fulfilment = UNKNOWN → fail-closed WATCH) is unresolved for every product;
bands vary materially (EXCEPTIONAL → INSUFFICIENT) — exactly the legitimate "band ≠ decision" case.
The **one confirmed lifecycle-representation defect:** two DataForSEO-discovered candidates that
**never underwent deep research** (no research run; PME score NULL) were materialised as Product
Decisions by the weekly Monday orchestrator and surfaced with a top-level "WATCH" chip
indistinguishable from completed ones. Smallest safe, additive, source-agnostic correction applied
(`mig_260`): the workspace now exposes truthful `decision_provisional` + `research_evidence_state`
derived from the canonical PME — **no** decision, score, band, threshold, gate, or historical record
changed. No provider dispatch, no paid call, no synthetic evidence.

---

### 1. Number of workspace products audited
**10 product×market decision rows** across **7 distinct products** (kids nightlight projector spans
GB/DE/FR/US).

### 2. Decision distribution
`WATCH: 10` (100%). No AVOID/TEST/BUY.

### 3. Opportunity-band distribution
`EXCEPTIONAL 1, HIGH_CONFIDENCE_TEST 1, STRONG_TEST 4, TRENDING_WATCH 2, INSUFFICIENT 2`. Evidence
confidence: `HIGH 2, LOW 3, NONE 5`. Bands/scores/confidence vary materially while the decision is
uniformly WATCH → the engine discriminates; the gates uniformly hold.

### 4. Exact source of displayed WATCH
- **Read from PME:** yes — the workspace `decision` field = `coalesce(pme.market_decision,
  d.decision)`; `pme.market_decision = 'WATCH'` is present for all, so the value is sourced from the
  **canonical product_market_evaluations** row. It equals `product_opportunity_decisions.decision`
  ('WATCH') on every row (the two layers agree).
- **Generated at read time?** Only `opportunity_band` is re-derived at read time from the PME score
  (`fn_ecommerce_opportunity_band`). The decision token is **stored**, not generated.
- **Fallback/default?** No hardcoded default. For the 2 null-score humidifiers `evaluation_source`
  labels `product_opportunity_decisions` (because PME score is NULL), but the WATCH value is still a
  real engine output (`score NULL → WATCH`), not a default.
- **Stale?** No — `pme_ts == pod_ts` and `pme_newer_than_pod = false` on **every** row.

### 5. Product-by-product explanation of WATCH
The engine order is: `has_fail→AVOID`, else `has_watch→WATCH (CANNOT_TEST_UNTIL_GATES_RESOLVE)`, else
`score NULL→WATCH`, else `score≥70 & conf∈{MEDIUM,HIGH}→TEST`, else `score≥40→WATCH`. Every founder
product has `gate_state` **stock=WATCH, economics=WATCH, compliance=WATCH, fulfilment=WATCH** (and
several `price=WATCH`, saturation VERY_HIGH) → `has_watch=true` → WATCH, regardless of band:
- `red light therapy led mask` GB — band **HIGH_CONFIDENCE_TEST** (89.6) → WATCH (gates WATCH).
- `cool mist humidifier` GB — band **EXCEPTIONAL** (93.5) → WATCH (gates WATCH).
- `kids nightlight projector` GB 68.2 / DE 73.2 / FR 79.5 / US 79.5 — STRONG_TEST/TRENDING_WATCH →
  WATCH (gates WATCH; GB VERY_HIGH saturation).
- `digital picture frame` 74.6, `over door shoe organizer` 67.4 — WATCH (gates WATCH).
- `cool air humidifier`, `humidifier for room` — **score NULL**, band INSUFFICIENT, no research run →
  WATCH.

### 6. Justified vs stale/default/premature
- **WATCH_JUSTIFIED (8 rows / 5 products):** all evaluated products — WATCH is the truthful output of
  real, unresolved supplier/economics/compliance/fulfilment gates. Not stale, not default.
- **WATCH_PREMATURE (2 rows):** `cool air humidifier`, `humidifier for room` — decisions materialised
  by the Monday orchestrator for candidates that never underwent deep research (null-score PME). The
  values (INSUFFICIENT/NONE/0/null) are truthful, but surfacing them as Product Decisions without an
  explicit provisional marker is the confirmed defect.
- **WATCH_STALE / WATCH_DEFAULT:** none found.

### 7. Is incomplete research presented as final?
Partially — **yes for the two never-researched humidifiers** (surfaced as WATCH Product Decisions).
Classification of the Phase-4 example `humidifier for room`: **(1) intentionally provisional** (the
weekly Monday pipeline's truthful thin-evidence output) that was **insufficiently distinguished** at
the contract level from a completed decision — not (2) an old discovery decision (it is from today's
06:00 Monday run), not (3) a hardcoded default, and not a decision-value defect. Fixed by the new
provisional marker.

### 8. Backend correction required?
**Yes — narrow and additive.** The decision *values* needed no change (truthful). The contract needed
an explicit provisional/research-completeness marker. Applied in `mig_260`: `decision_provisional`
(true ⇔ canonical PME has no usable score) and `research_evidence_state`
(`INSUFFICIENT_EVIDENCE`|`EVALUATED`). Verified: `decision_provisional=true` on exactly
`cool air humidifier` + `humidifier for room` (2), `false` on the other 8. No score/decision/
threshold/gate/record change; GB/DE isolation preserved; all source families treated equally.

### 9. Image availability count
**Image available: 4 rows (1 distinct product: kids nightlight projector, product-global across
GB/DE/FR/US). Missing: 6 rows (6 distinct products).**

### 10. Exact reason each missing-image product has no image
All 6 lack a **canonical supplier link** (`commerce_products.extended` has no `supplier_ref`/
`supplier_refs`), so there is no `commerce_supplier_products` / `supplier_product_assets` primary
image to resolve. Per product — image=no, canonical supplier link=no, authorized source=none:
`cool air humidifier`, `cool mist humidifier`, `humidifier for room` (DataForSEO-discovered, never
CJ-matched); `digital picture frame`, `over door shoe organizer`, `red light therapy led mask`
(Reddit-discovered, never CJ-matched). Only `kids nightlight projector` was matched to a CJ supplier
product (`2608250310481611400`) which carries a rights-cleared `PRIMARY_IMAGE`
(`SUPPLIER_PROVIDED`/`AVAILABLE`). No keyword-similar or AI image is ever attached.

### 11. Recommended future authorized image acquisition path (audit only — not implemented)
During discovery/research, when a canonical product is resolved to a supplier product
(`resolve_product_entity` → CJ match, the same link the nightlight already has), also ingest that
supplier product's **primary image** into `supplier_product_assets` (`rights_state=SUPPLIER_PROVIDED`)
and store the `supplier_ref` on the product — reusing the exact path the workspace already reads. This
attaches an image only via a **canonical, rights-cleared supplier match** for that specific product.
Never: scrape Google Images, attach a keyword-similar product's image, reuse another product's image,
or represent an AI-generated image as the real product. Products with no supplier match correctly
return `product_image_url = null` (placeholder).

### 12. Tests / regressions
- Selftests all pass: `connection`, `contracts`, `orchestrator` (incl. `tiktok_blocked`),
  `deep_research`, `dfs_discovery`, `paid_access`, `search_relevance`.
- Regression: kids nightlight **GB 68.2 / DE 73.2** unchanged (canonical current PME); `cool mist
  humidifier` still visible; DataForSEO products = 3 (provenance intact); Reddit products = 10;
  founder products = 15 (canonical identity intact, no duplicate); business country **GB**; founder
  fixture PME = 0 (no synthetic evidence); TikTok `SOURCE_UNSUPPORTED` (truthful, unchanged).
- No provider dispatch, no paid API call, no force-fresh, no historical decision destroyed
  (`founder_decisions=10` — the two humidifier decisions were materialised by the 2026-09-21 Monday
  orchestrator *before* this unit, not by this change). Advisors: **0 ERROR** (1 INFO/4 WARN
  baseline).

### 13. Files / functions inspected
`fn_ecommerce_workspace_intelligence`, `fn_pod_evaluate`, `fn_pod_tournament`,
`fn_finalize_research_run`, `product_market_evaluations`, `product_opportunity_decisions`,
`provider_capability_registry`, `commerce_research_run`, `mig_243` (state map / ingest),
`mig_251` (dispatch manifest), `commerce_supplier_products`, `supplier_product_assets`.

### 14. Changes made
`supabase/migrations/mig_260_workspace_provisional_decision_flag.sql` — additive read-time
`decision_provisional` + `research_evidence_state` on each workspace decision, derived from the
canonical PME. No scoring/decision/threshold/gate/record change; no Lovable change (frontend may adopt
the flag to badge provisional decisions distinctly).

### 15. Final verdict
`DECISION_LIFECYCLE_FIXED_READY_FOR_FOUNDER_TEST` — WATCH decisions are canonical and truthful; the
narrow lifecycle-representation defect (never-researched candidates surfaced as decisions without a
provisional marker) is fixed with a safe, verified, additive contract flag.

**STOP.** No scoring/threshold/decision change, no data/provider/research-state mutation, no publish.

# PULSE-ECOM-STAGE2-SHARED-IDENTIFIER-BINDING-001

**Unblocked the first genuine Stage-2 exact supplier binding (`mig_304`). Root cause: the resolver
ignored a product's RECORDED CJ supplier linkage. Fix: honor it as a shared identifier with
precedence, guarded by the excluded-subtype + form-conflict fail-closed checks. PASS — new selftest
3/3; B3 10/10, multilingual 8/8, Stage-2 boundary 10/10 unchanged (no regression). No live/paid
calls; no fabricated binding.**

## Selected product
- **kids nightlight projector** — `e453eed4-3de4-4ed9-b889-1275c13c0dba`, tenant
  `7c8ddf9d-172c-4a89-a402-bb7066228b61`, non-branded (`brand=null`), market **GB** (eligible).
- Chosen from the 40 Stage-1 candidates not yet exhausted by CJ research, because it is the only one
  already carrying a **recorded, provenanced CJ supplier linkage** (three agreeing keys in
  `extended`: `supplier_ref`, `supplier_refs[0]`, `cj_source_product_id`; `linked_at 2026-09-07`),
  pointing at a real catalogue product that is also **enriched** (variant + GB freight).

## Supplier route (fastest, evidence-backed, no live/paid call)
- Supplier: **CJDROPSHIPPING** (the only ingested supplier catalogue — 1,296 cached products).
- Bound CJ product: `2608250310481611400` — "USB Projection Lamp … For Children … Dual-mode
  Starry-sky Projector Night Light", **SKU `CJYD3093228`**, cost 5.73 USD, category Night Lights,
  with cached `variant` + GB `freight` enrichment.
- The binding is via the matcher's deterministic `EXACT_CONFIRMED` / `SHARED_PRODUCT_IDENTIFIER`
  path on the **recorded** linkage — not a fuzzy attribute guess. Generic non-branded candidates
  (projector, shoe organizer, digital frame, red-light mask) were empirically tested against the
  cache and all returned `CONCRETE_PRODUCT_AMBIGUOUS`/`NO_VALID` (e.g. projector 67/93 qualify) —
  the strict matcher correctly refuses a 1:1 bind on attributes alone, so a shared identifier is the
  only evidence-backed route to a unique exact match.

## Root cause + fix (`mig_304`, internal)
`fn_resolve_concrete_supplier_identity` always called `fn_market_supplier_match(..., p_shared_identifier
=> false)`, so a recorded CJ linkage was ignored and only fuzzy attribute matching ran. Fix (surgical,
strictness preserved):
1. Read the opportunity's recorded CJ identifier(s) from `extended` (provider CJ only).
2. Always include the linked catalogue row(s) in the candidate set (carrying SKU + variant from
   `supplier_enrichment`), so an identifier match never depends on the LIMIT-40 term window.
3. Pass `p_shared_identifier=true` only for a candidate whose `supplier_product_id` equals a recorded
   linked id; such a candidate binds EXACT **with precedence** over attribute matches, but still
   **fails closed** on `excluded_subtype_hit` or `form_conflict` (a bad link never binds).
4. When no recorded identifier matches, behaviour is byte-for-byte the prior attribute path.

## Actual identity readiness
- `EXACT_SUPPLIER_IDENTITY_RESOLVED`, `bound=true`, `is_fixture=false`, `qualifying_count=1`,
  `match_basis=SHARED_PRODUCT_IDENTIFIER`, SKU `CJYD3093228`, variant present. Persisted to
  `commerce_concrete_supplier_resolution` (GB).
- Concrete *concept* remains `CONCRETE_PRODUCT_AMBIGUOUS` (the opportunity's market evidence does not
  uniquely describe the product), transparently recorded; the recorded supplier identifier is what
  pins the exact CJ product. This is honest, not a fabricated attribute match.
- Stage 3B gate for this product/market is now **unblocked**: `BLOCKED_NO_BINDING → PARTIAL`
  (`evidence_grade=REAL`, landed cost known from cached cost + GB freight).

## Remaining external blocker (to reach COMMERCIALLY_VALIDATED)
- **Stale supplier evidence** — the cached CJ detail/freight (`detail_observed_at`) is now >14 days
  old (`SUPPLIER_EVIDENCE_STALE`); a fresh live CJ product-detail + freight + stock-by-vid call is
  needed (external, founder-gated; not run here — no unapproved provider spend).
- **No local market price** — no GB competitor price observations exist for this product
  (`NO_LOCAL_MARKET_PRICE`), so the MARKET_LED contribution cannot be computed; local competitor
  pricing research is the other external input.
- Neither blocker is a binding/identity gap; the exact supplier identity is established.

## Verification
- `fn_stage2_shared_identifier_selftest()` → 3/3 (identifier→EXACT_CONFIRMED; no identifier→not exact;
  excluded-subtype guard holds).
- No regression: `fn_stage2_query_expansion_selftest` 10/10, `fn_stage2_multilingual_selftest` 8/8,
  `fn_stage2g_boundary_integrity_selftest` 10/10 all still PASS.
- Preserved: strict matching (identifier still fails closed on excluded subtype / form conflict),
  18-market isolation (market passed through unchanged), tenant security (`user_id` ownership),
  Product Asset Lock (untouched). Krippen and the humidifier (no `supplier_ref`) are unaffected and
  still correctly `NO_VALID_CJ_MATCH`.

Stage 3B not rebuilt; Stage 4 not started.

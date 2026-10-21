# PULSE-ECOM-STAGE4B-ALIEXPRESS-CONTINUATION-001

**Stage 4B continuation — approval-free implementation while AliExpress Dropshipping Developer
registration is UNDER REVIEW (2–5 working days). The exact-identity supplier resolver is now
source-generic, and the AliExpress secondary source is prepared behind a DISABLED provider gate. No
AliExpress activation, no live wiring, no invented API response contracts, no scraping, no paid calls.
Existing CJ behaviour is byte-identical and fully regression-verified.** (mig_322)

## What was delivered (all approval-free)

### 1. Reuse of the existing CJ architecture (req 1) — PASS
No new matcher, no schema fork. AliExpress plugs into the same `commerce_supplier_products`
`(source, source_product_id)` catalog, the same `fn_market_supplier_match` identity evaluation, the same
`commerce_concrete_supplier_resolution` output table, and the same pinned requirement
(`PULSE-ECOM-STAGE4B-ALIEXPRESS-SUPPLIER-REQUIREMENT-001`). The resolver was already source-agnostic in
its *matching*; this work makes it source-agnostic in its *labelling* too.

### 2. Source-generic exact-identity resolver — remove the 3 hardcoded CJDROPSHIPPING labels (req 2) — PASS
`fn_resolve_concrete_supplier_identity` carried three hardcoded `'CJDROPSHIPPING'` supplier labels.
Each now derives from the matched candidate's own source:
- **Self-built CJ candidates:** `'supplier', upper(source)` (the only stored source is `cjdropshipping`
  → `CJDROPSHIPPING`, so zero drift; the self-build block is still CJ-scoped by `source ILIKE 'cj%'`).
- **Persisted `selected_supplier` column:** `upper(coalesce(v_sel->>'supplier','CJDROPSHIPPING'))`.
- **Provenance `step2_concrete_to_supplier.supplier`:** `upper(coalesce(v_sel->>'supplier','CJDROPSHIPPING'))`.

For a CJ bind, every one of these resolves to exactly `CJDROPSHIPPING` — the stored value, the provenance
label and the customer-visible `selected_supplier` are **identical to before**. For an AliExpress
candidate (`supplier='ALIEXPRESS'`), they resolve to `ALIEXPRESS`.

**Intentionally unchanged** (stable contracts; not among the "three labels"): the CJ-stage result token
`NO_VALID_CJ_MATCH` (asserted by 4 existing selftests; the AliExpress stage returns the distinct
`NO_VALID_SUPPLIER_MATCH` in the fallback helper instead), the `cj_product_id` provenance key and the
CJ-worded claim text, and the `ON CONFLICT` clause. The `cj_product_id` key / claim wording for a non-CJ
bind are an **authorised-phase provenance refinement** — harmless while AliExpress is gated (it can
produce no live bind) and read by no other function (verified: `cj_product_id` has 0 downstream readers).

### 3. AliExpress preparation behind a DISABLED provider gate (req 3) — PASS (dormant)
- **Provider gate:** `commerce_supplier_provider_config` (RLS-on, service-role only) +
  `fn_supplier_provider_enabled(provider)`. Seeded `CJDROPSHIPPING` = **enabled / AVAILABLE** (priority 10),
  `ALIEXPRESS` = **disabled / EXTERNAL_APPROVAL_REQUIRED** (priority 20). Enabling the AliExpress row is an
  authorised-phase action only.
- **Source-generic candidate normaliser / adapter DTO:** `fn_supplier_candidates_from_canonical(provider, items)`
  maps **OUR canonical supplier DTO** (fields we define: `supplier_product_id, sku, title, category,
  variant`) to the resolver's candidate shape. It deliberately does **not** encode any AliExpress raw API
  response schema — that raw→canonical mapping is unknown until the real API shape is available and is
  **not invented here**. Absent fields are stripped (`jsonb_strip_nulls`), never fabricated.
- **CJ-first → AliExpress fallback helper:** `fn_resolve_supplier_identity_multi(...)`. Runs CJ first; on a
  CJ exact resolution, CJ wins. Only if CJ fails **and** `ALIEXPRESS` is enabled does it attempt
  AliExpress (normalise items → resolver → bind only on exact). While the gate is **DISABLED** it never
  attempts AliExpress and returns the CJ result verbatim with `aliexpress_fallback='PROVIDER_DISABLED'`.
  It is **NOT wired** into `fn_finalize_research_run` (verified: finalize still calls only the direct CJ
  resolver) — AliExpress is fully dormant.

### 4. Mock tests (req 4) — PASS (9/9, persist=false, no API, no writes)
`fn_supplier_sourcegeneric_selftest()` → `ok:true, passed:9, failed:0`:
| Case | Covers | Result |
|---|---|---|
| `cj_exact_regression` | CJ exact candidate still binds + labels `CJDROPSHIPPING` | PASS |
| `aliexpress_exact_variant_match` | exact AliExpress candidate binds + labels `ALIEXPRESS` (lower→upper) | PASS |
| `aliexpress_incorrect_variant_not_bound` | category-adjacent AliExpress → **not bound** (never-approximate) | PASS |
| `tenant_isolation_foreign_rejected` | foreign tenant → `product_not_found_for_tenant` | PASS |
| `market_normalised_GB` | country scoping: `gb` → `GB` carried | PASS |
| `provider_gate_default_disabled` | CJ enabled, AliExpress disabled (case-insensitive) | PASS |
| `normaliser_no_invented_fields` | missing shipping/rights/price/sku/variant never fabricated (keys = `title, supplier, supplier_product_id`) | PASS |
| `fallback_gated_off_no_aliexpress_attempt` | even with a matching AliExpress item, gate OFF → no attempt, CJ result verbatim | PASS |
| `failed_or_empty_api_response_no_candidates` | NULL / empty API payload → `[]`, no crash, no fabricated candidates | PASS |

"Exact / incorrect variant matching, country isolation, missing shipping, missing rights, failed API
responses" are all covered.

### 5. Existing CJ behaviour unchanged (req 5) — PASS (regression-verified)
- **Resolver md5** changed only in the 3 intended label expressions (verified by inspection).
- **Existing CJ selftests, all green, 0 provider calls:** `concrete_identity_product_native` 29/29,
  `ecommerce_intelligence_projection` 25/25 (incl. `supplier_no_valid`, `bound_preserved`,
  `country_isolation_supplier`), `stage2g_boundary_integrity` 10/10, `stage3b_commercial_verification` ok,
  `stage2_cj_pagination` ok.
- **Live Snowman (`873551b0`, GB) persisted resolution unchanged:** `NO_VALID_CJ_MATCH`, `bound=false`,
  `selected_supplier=NULL`, 40 candidates — the migration replaced function bodies only; it ran no
  resolver and changed no data.
- **Security advisors:** my new functions are **absent** from the anon- and authenticated-executable
  SECURITY DEFINER lists (every new function `REVOKE`s EXECUTE from `public, anon, authenticated`) and from
  `function_search_path_mutable` (all pinned `SET search_path TO ''`). The only new mention is the intended
  INFO `rls_enabled_no_policy` on the service-role-only config table. No new WARN/ERROR introduced.

## Preservation & guardrails — PASS
Tenant/country isolation, the never-approximate rule, Product Asset Lock, and the DataForSEO USD budget
guard (mig_318/319, still DISABLED) are untouched. No AliExpress activation, no live provider exposure, no
invented API response contract, no scraping, no paid call, no frontend change.

## Remaining external approval gates (still blocking LIVE AliExpress integration)
These are unchanged from `PULSE-ECOM-STAGE4B-ALIEXPRESS-INTEGRATION-001` and remain **BLOCKED_EXTERNAL**:
1. **AliExpress Open Platform developer approval** — the Dropshipping Developer registration is UNDER
   REVIEW (2–5 working days). On approval: **App Key + App Secret** with a product/dropshipping (or
   affiliate) API scope.
2. **Written confirmation of multi-tenant SaaS usage rights** under AliExpress's API Terms (per-tenant/
   app tokens, rate limits, redistribution + media rights for commercial use).
3. **Approval for any paid/metered API tier** before a single paid call.

## Authorised-phase change set (deploy only after the gates above)
(a) flip `commerce_supplier_provider_config.ALIEXPRESS` to enabled/AVAILABLE; (b) build the AliExpress
raw-API-response → canonical-DTO mapper against the **real** API shape (the one piece deliberately not
invented now); (c) an n8n AliExpress product-detail executor using the App Key/Secret credential,
budget-guarded via mig_318/319 if metered; (d) wire `fn_resolve_supplier_identity_multi` into
`fn_finalize_research_run` with the agreed persist semantics; (e) media + rights provenance mapping, and
the `cj_product_id`→generic provenance key/claim refinement; (f) live verify listing `1005013410315354`
vs the Snowman (`873551b0`, GB). Then mock → live test and verify.

## Status
| Req | Verdict |
|---|---|
| 1 Reuse CJ architecture + pinned requirement | **PASS** |
| 2 Source-generic resolver (remove 3 CJDROPSHIPPING labels), CJ unbroken | **PASS** |
| 3 Disabled provider gate + candidate normaliser + API adapter contract + CJ-first fallback (gated OFF) | **PASS** (prepared, dormant) |
| 4 Mock tests: exact/incorrect variant, country isolation, missing shipping/rights, failed API | **PASS** (9/9) |
| 5 Existing CJ behaviour unchanged | **PASS** (all CJ selftests green; live row + advisors verified) |
| Live AliExpress integration | **BLOCKED_EXTERNAL** (developer approval under review + multi-tenant rights + paid-tier approval) |

**Overall: PASS for the approval-free continuation; live AliExpress remains BLOCKED_EXTERNAL.** The
resolver is source-generic, the AliExpress path is fully prepared and provably dormant, and CJ is
byte-identical. **STOP at Stage 4B** — no BigBuy, saturation or country recommendations; live steps await
the external gates above.

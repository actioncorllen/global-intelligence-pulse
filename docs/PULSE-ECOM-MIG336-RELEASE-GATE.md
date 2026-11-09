# mig_336 + Kalodata edge — Deployment Readiness Gate (2026-11-09)

Read-only pre-deployment verification. No paid calls, no deploy. Verdict at the bottom.

## 1–2. Callers of the replaced signatures + backward compatibility — ✅ PASS
mig_336 changes two signatures (adds defaulted params): `fn_kalodata_discovery_request(text)` → `(text, integer DEFAULT 1)`; `fn_kalodata_run_discovery(uuid,text,integer,text)` → `(…, integer DEFAULT NULL)`.

| Caller | Call site | Args | Compatible? |
|---|---|---|---|
| `fn_kalodata_commerce_adapter_selftest` | `fn_kalodata_discovery_request('DE')`, `('IE')` | 1 | ✅ resolves to new default |
| `fn_fastmoss_commerce_adapter_selftest` | `fn_kalodata_discovery_request('DE')` | 1 | ✅ |
| `fn_multi_lane_discovery_plan` | `fn_kalodata_discovery_request(v_mkt)` | 1 | ✅ |
| `kalodata-discovery` edge (live v11) | RPC `{p_market}` | 1 | ✅ (page defaults to 1) |
| `fn_kalodata_run_discovery` | no DB caller but itself; invoked by operator/n8n via RPC | 4 named | ✅ resolves to new default |

No caller passes the to-be-added argument, and the old signatures are dropped (no ambiguous overload). **No caller needs updating.**

## 3. Pagination cannot consume an unapproved page or exceed the credit budget — ✅ PASS
- `fn_kalodata_run_discovery` fetches **exactly one page per call** (no internal loop). A page is bought only when the caller invokes it, and the caller must pass `fn_provider_budget_try_consume` first — the **atomic, fail-closed** gate (verified: 3rd consume refused `budget_exceeded`; FastMoss/Kalodata fail closed with no budget).
- Page number does **not** change cost: `page_size` stays 10 ⇒ 0.1 credit/call regardless of page. `max_calls` bounds the number of pages/credit exactly as before.
- Cursor advances **only on fire** and is **monotonic** (a repeat never rewinds), so auto-runs never re-buy a page, and an explicit page cannot be bought without a `try_consume` slot.

## 4. Run-scoped suppression cannot affect another tenant/workflow — ✅ PASS
`discovery_dispatch_suppression` is keyed by `tenant_id`; `fn_dispatch_suppressed(tenant)` is tenant-scoped. Verified: with the founder suppressed, a **different tenant is NOT suppressed** (T4d). Opening/closing a token touches only that tenant's row; the shared `research_executor_webhook` is never mutated (T8).

## 5. Suppression fails closed if its record is missing/expired/invalid — ❌ NOT CONFIRMED (blocker)
`fn_dispatch_suppressed` returns **false (not suppressed ⇒ dispatch proceeds)** when the record is missing/expired/inactive — it **fails OPEN**, by design, as a time-boxed control.

What that means in practice (traced through the live n8n executor *"Pulse — Research Auto-Dispatch Executor (013N)"*):
- The executor calls providers **directly with its own n8n credentials**, gated only by each source's `action` in `fn_research_run_manifest` (derived from attempt state).
- **DataForSEO** (the only $-metered provider there) is **independently fail-closed**: `fn_research_dispatch` runs a USD budget reserve (config disabled) → marks it `SOURCE_UNAVAILABLE` → manifest `TERMINAL` → n8n skips it. ✅
- **CJ / eBay / Meta are NOT budget-gated** in `fn_research_dispatch` — their attempts stay `NOT_SEARCHED` ⇒ manifest `DISPATCH` ⇒ n8n calls them whenever the webhook fires. So on a **suppression lapse**, the webhook would fire **CJ** (founder-restricted; $0-direct catalogue read), eBay and Meta (free). No metered $ is spent, but restricted external calls could occur.

**So requirement #5 is not met as a general guarantee.** The run-scoped suppression reliably blocks when *active* (verified), but its fail-open on missing/expired, combined with CJ/eBay/Meta not being budget-gated, is a real residual.

**Recommended fix (needs approval; not deployed):** add CJ (and optionally eBay/Meta) budget-gating to `fn_research_dispatch`, mirroring DataForSEO, so **"unauthorised CJ cannot execute" holds fail-closed independent of suppression**. Plus a procedural guard: the authorised discovery orchestration asserts `fn_dispatch_suppressed(tenant)=true` before firing, with TTL (≤120 min) ≫ run duration (seconds). I can prepare this as `mig_337`.

## 6. Edge + migration deploy without mismatch — ✅ PASS (order-dependent)
**Deploy order MUST be: migration FIRST, then edge.** After the migration, the live v11 edge (`{p_market}` only) still works (page defaults to 1); the new paged edge requires the 2-arg function to exist. Deploying the edge before the migration would call a 2-arg function that doesn't exist yet → discovery breaks. With the correct order there is no breakage window.

## 7. Rollback + order — ✅ PASS
`supabase/migrations/mig_336_ROLLBACK.sql` restores the original function bodies (removes the suppression checks), restores the 1-arg/4-arg signatures, and drops the added tables/helpers. **Reversal validated transactionally** (apply → rollback → assert): `fn_kalodata_discovery_request` back to `p_market text`, `fn_kalodata_run_discovery` back to 4-arg, cursor + suppression tables gone, helper fns gone.
**Rollback order:** redeploy the edge function to **v11 first**, then apply the rollback migration (so no live caller references the 2-arg function after it is dropped).

## 8. Production data + research history preserved — ✅ PASS
mig_336 is **DDL-only**: `CREATE OR REPLACE` functions, `CREATE` two **empty** tables, `DROP` old function signatures. **No DML** on `commerce_products`, `commerce_research_run`, `commerce_signals`, `product_market_evaluations`, or any data table. No deletes/updates to research history. New tables start empty.

## Separate trace — why the 10 DE products are invisible in Product Discovery
Two independent, correct-by-design reasons:
1. **`fn_product_explorer`** (the workspace product list) inner-JOINs `commerce_signals` with `nullif(s.value->>'fastmoss_strategy','') IS NOT NULL`. The 10 Kalodata signals are `COMMERCE_PRODUCT_NATIVE`/DE but carry `source=kalodata` with **no `fastmoss_strategy`** key, so the JOIN drops all 10. Live check: Explorer DE total = **9** (the pre-existing FastMoss set); Kalodata signals with `fastmoss_strategy` = **0/10**. The Explorer was built FastMoss-first (mig_311) and Kalodata-native discovery was never wired into its projection.
2. **`get_own_discovery_intelligence.commerce_opportunities`** reads `commerce_product_opportunities` (scored) `WHERE source_run_id = <DNA run>`. The founder's DNA `source_run_id` is **NULL** and there are **0** scored rows → always `[]`.

**Fix (separate, non-blocking, NOT deployed, does NOT promote to Recommendations):** extend `fn_product_explorer`'s signal JOIN to also admit Kalodata-native signals (`source='kalodata'`), mapping `revenue_growth_rate`/`sales_units`/`revenue` into the explorer fields, so discovered Kalodata candidates appear in the **Discovery** surface (unvalidated, `INSUFFICIENT` — never Recommendations). I can prepare this as a small migration on approval.

## Final verdict
| Component | Verdict |
|---|---|
| **Pagination (B1)** | ✅ **Deployment-ready** — callers compatible, credit-safe, rollback validated |
| **Run-scoped suppression (B2)** | ⚠️ Works when active + tenant-isolated, but **fails OPEN** on missing/expired ⇒ **requirement #5 not met** |
| **Deploy/rollback mechanics** | ✅ Order documented (migration→edge; rollback edge→migration), rollback validated |
| **Data/history** | ✅ Preserved |

**Unresolved blocker:** #5 — suppression fails open and **CJ/eBay/Meta are not budget-gated** in the research-dispatch path (only DataForSEO is). Recommended resolution before relying on suppression for safety: **`mig_337` to budget-gate CJ (+eBay/Meta) in `fn_research_dispatch`** (fail-closed), making suppression defense-in-depth. Pagination may deploy independently.

**Non-blocking follow-up:** Discovery-workspace projection fix so Kalodata candidates are visible on the Discovery surface (not Recommendations).

No paid calls made; nothing deployed.

# Discovery Cost Control & Usage Evidence (2026-11-09)

Isolates basic customer **Refresh Discovery** from the optional **deep-research cascade**, and fixes the
provider-usage instrumentation gap. **Prepared — nothing deployed, published, priced, or activated.** No paid
provider calls were made. All tests are transactional (rolled back) with mocks/spies.

Product = **Strateloq**; company = **Strateloq Technologies**. Unified frontend `c56e6e0` and backend identifiers
preserved.

---

## 1. Exact root cause of the downstream research cascade (VERIFIED from live code)

A customer Refresh Discovery reaches ingestion through the `kalodata-discovery` edge, which calls
`fn_kalodata_ingest_candidates` as a **fresh service-role PostgREST RPC**. Inside that function, for **every
promoted candidate**, two things happen in order:

1. the candidate is **registered `active`-for-market** in `monday_opportunity_registry` (insert/update), then
2. `fn_auto_dispatch_candidate_research(user, product, market)` is called **unconditionally** (only wrapped in an
   exception guard).

`fn_auto_dispatch_candidate_research` has an eligibility gate — the product must be `active` in
`monday_opportunity_registry` for the market — **but step 1 has just satisfied it**. So the gate that would
otherwise return `NOT_ELIGIBLE` always passes for a freshly-ingested candidate, and the function proceeds to
`fn_research_request_core(..., 'auto_fresh_discovery')` → `fn_research_dispatch(run_id)`.

The only pre-existing brake is the `pulse.suppress_dispatch` **session GUC** or a tenant row in
`discovery_dispatch_suppression` (read by `fn_dispatch_suppressed`). **Neither is set on the customer-refresh
path**: the edge's RPC runs in its own transaction (no GUC) and a normal paying tenant has no suppression row.
Therefore a single customer refresh click *does* enter the deep-research cascade for each of up to ~10 promoted
candidates; the only thing then stopping a paid FastMoss/DataForSEO/CJ fan-out is each provider's fail-closed
budget authorization inside `fn_research_dispatch`.

**Root cause, one line:** `fn_kalodata_ingest_candidates` auto-registers each candidate and then unconditionally
crosses the `fn_auto_dispatch_candidate_research` bridge, and the customer-refresh path applies no dispatch
suppression — so basic refresh and deep research were coupled.

---

## 2. Prepared code correction + rollback (smallest safe change)

**`supabase/migrations/mig_344_refresh_isolate_deep_research.sql`** (prepared; not applied)
- Adds a default-false parameter `p_suppress_auto_research` to `fn_kalodata_ingest_candidates` (DROP of the 6-arg
  signature + CREATE of the single 7-arg function, to avoid named-arg overload ambiguity; EXECUTE re-granted to
  `authenticated` + `service_role`, matching the original ACL).
- When `p_suppress_auto_research = true`, **ingestion / identity resolution / de-duplication / storage /
  opportunity-registry registration run byte-for-byte as before**, but the per-candidate research bridge is **not
  crossed** — it records `AUTO_RESEARCH_SUPPRESSED` instead of calling `fn_auto_dispatch_candidate_research`.
- Everything else in the function is unchanged. The response now also carries `auto_research_suppressed`.

**`supabase/functions/kalodata-discovery/index.ts`** (prepared edge; not deployed)
- Passes `p_suppress_auto_research: refreshRequestId !== null` — i.e., **true only for a customer Refresh
  Discovery run** (`refresh_request_id` present). A normal discovery wave passes `false` and is unchanged.

**Rollback:** `supabase/migrations/mig_344_ROLLBACK.sql` drops the 7-arg function and restores the original 6-arg
definition verbatim (re-granting EXECUTE). The edge change is reverted by redeploying the prior file.

**Defence-in-depth:** the per-provider fail-closed authorization in `fn_research_dispatch`
(`fn_dispatch_provider_authorize` / `fn_research_budget_reserve`) is untouched and still stands; this change stops
the cascade from being *entered* on a customer refresh rather than relying on empty budgets.

---

## 3. Other research workflows remain unaffected (VERIFIED)

- The change is scoped to a **single** function (`fn_kalodata_ingest_candidates`) via an opt-in, default-false
  flag set **only** when `refresh_request_id` is present. Normal discovery waves (admin/scheduled/autonomous,
  which pass no `refresh_request_id`) keep the pre-existing auto-dispatch behaviour.
- The **independent on-demand deep-research entrypoint** `fn_research_request_core` is not modified. Test 4 ran it
  directly (trigger `on_demand_user_request`) and it returned `RESEARCHING` with a run created — fully functional
  (and `DISPATCH_SUPPRESSED` in-test so no paid call fired).
- `fn_research_dispatch`, the provider authorization gates, DataForSEO USD budget guard, FastMoss/CJ/TikTok
  dispatch, pagination cursor (`fn_kalodata_next_page`), and the Explorer/PAL objects are **not** touched by
  `mig_344`.
- Backward compatibility: the only other DB caller of the ingest function is
  `fn_kalodata_commerce_adapter_selftest`, which calls it positionally with 6 args and `dry_run=true`; a 7th
  default-false parameter keeps it working and it never dispatches research.

---

## 4. Provider-usage instrumentation results

**Why `discovery_runs.raw_contract.provider_usage` was empty on all 68 historical runs (root cause):** the live
v12 edge records usage only under `if (usage && ib.run_id)`, where `usage` is non-null **only when the Kalodata
rank response carries a recognized `credit/cost/balance` field**. The `tiktok/product/rank` endpoint returns no
per-call cost field, so the recorder was never invoked. (Secondary: the earliest runs predate even this
conditional recorder.) The *function* `fn_kalodata_record_usage` works; it was simply never called.

**Fix (prepared edge):** record a usage/telemetry row for **every paid Kalodata call**, regardless of whether the
provider volunteers a cost field, with verifiable-only fields — provider, operation, tenant, country, endpoint,
`call_count=1`, HTTP status, lane/response status, `cost_field_present`, the provider's own `provider_credit`
when present (else null), `relationship` to the customer refresh (`customer_refresh` vs `discovery_wave`),
`refresh_request_id`, and `recorded_at`. **`monetary_amount` is always explicit JSON null — never inferred from a
call count.** `provider_credit` is clearly the *provider's* metering, kept distinct from Strateloq customer
credits. The provider secret is never included (existing redaction + credit-only extraction).

Verified in Test 2 (below): recorded with provider credit when present; recorded with `call_count=1`,
`cost_field_present=false`, `provider_credit=null`, `monetary_amount=null` when absent.

---

## 5. Remaining external provider-pricing evidence still missing

Internally controllable instrumentation is now fixed, but the **unit prices themselves are external** and still
unverified:
- **Kalodata** $ per `tiktok/product/rank` call (invoice / contract / dashboard). The API returns no per-call
  cost, so this must come from the provider account, not the response.
- **FastMoss / DataForSEO / CJ** $ per call for the deep-research cascade.
- The **`ecommerce_monthly` subscription price** (still COMP, `amount_minor = NULL`).
- An agreed **usage assumption** (refreshes per customer per period).

Until these are supplied, monetary cost per refresh remains **unknown** and is recorded as null (never fabricated).

---

## 6. Tests — transactional, rolled back, no paid calls

| # | Case | Method | Result |
|---|------|--------|--------|
| 1 | One authorized refresh dispatches only its discovery request | Spy on `fn_auto_dispatch_candidate_research`; run ingest with suppress=false vs true | **PASS** — wave called spy once; refresh added no spy call (`research_auto_dispatch=AUTO_RESEARCH_SUPPRESSED`) |
| 2 | Candidate ingestion succeeds independently of deep research | Same test; assert promotion + registry | **PASS** — `promoted_count=1` both modes; both candidates registered |
| 3 | No automatic paid research from customer refresh | Spy count after refresh | **PASS** — spy count unchanged; `spy_markets=[DE]` only from the wave |
| 4 | Existing independent deep-research workflow still functional | Call `fn_research_request_core(on_demand_user_request)` under suppression | **PASS** — `RESEARCHING`, run created, `DISPATCH_SUPPRESSED` (no paid call) |
| 5 | Deduplication + pagination remain correct | Known-kid detected / unknown-kid rejected; `fn_kalodata_next_page` | **PASS** — dedup detect+reject correct; cursor intact; `new` path proven in Test 1 |
| 6 | Provider usage recorded where evidence exists | `fn_kalodata_record_usage` with provider credit | **PASS** — `provider_credit.credit=5`, endpoint + timestamp stored |
| 7 | Monetary cost unknown when evidence unavailable | record_usage with no cost field | **PASS** — `call_count=1`, `cost_field_present=false`, `provider_credit=null`, `monetary_amount=null` |
| 8 | Customer credit accounting stays idempotent | Settle replay + duplicate RESERVE | **PASS** — settle replay no-ops; duplicate RESERVE blocked by unique index; exactly 1 RESERVE row |
| 9 | Successful zero-new searches settle as designed | `fn_discovery_refresh_settle(new=0, SUCCESS)` | **PASS** — `settled=true`, `refunded=false`, balance unchanged (consumed), status `SETTLED` |
| 10 | Country + tenant isolation + PAL intact | Cross-tenant research denied; live Explorer | **PASS** — cross-tenant `NOT_AUTHORIZED`; Explorer `image_gated_display_only:true`, DE 9 visible / 20 hidden; `mig_344` changes no RLS/Explorer/PAL object |

**Failed: none.** (Cases 8/9 were run against the mig_341 credit objects applied inside the test transaction,
since mig_341 is prepared-but-not-applied; mig_344 does not modify the credit model.)

---

## 7. Customer-experience (P3)

The prepared modal (`refresh-discovery-modal.tsx`) already shows, before confirmation, the **required credits +
balance** and a clean **"not activated"** state; after execution it shows **newly-visible / already-known /
waiting-for-image** tiles and the **credit settlement (or "no credits charged")** line. Two P3 items were added as
an **unpublished** preview change (Lovable commit `c1a6afa`, one file only, nothing published; branding/naming
untouched): a before-confirmation note that *a successful search may return no new products (charged for the
search, not the results)*, and an explicit **"New candidates"** total tile alongside the visible/pending split —
mapping the modal 1:1 to the backend status contract (new candidates discovered / newly customer-visible /
already known / pending permitted imagery / credits consumed-or-refunded). All 583 frontend tests pass (incl. 31
refresh-window tests), typecheck + lint clean. The customer-facing Product Explorer stays **image-only**; Product
Asset Lock is not weakened.

---

## 8. Financial-safety posture (P4)

- Provider-call budgets and fail-closed authorization are **preserved** (unchanged).
- Optional downstream research cannot silently bypass its independent authorization: it is now **not initiated at
  all** on a customer refresh, and where it *is* initiated (normal waves, on-demand) each provider is still
  fail-closed budget-gated in `fn_research_dispatch`.
- **One refresh cannot trigger an unapproved paid research cascade** — proven by Tests 1 & 3.
- No customer-credit allowance activated, no subscription price set, no paid provider call executed.

---

## 9. Final release-readiness verdict

**READY for founder-approved Stage-B deployment — not yet deployed.** The isolation change and the usage
instrumentation are prepared, transactionally tested (10/10 pass), backward-compatible, and reversible. They do
not activate billing, set prices, grant credits, or make any paid call. Deploy order when approved:
1. Apply `mig_344` (ingest suppression param).
2. Deploy the prepared `kalodata-discovery` edge (passes the suppress flag + records usage unconditionally).
3. (Already prepared, separate) Stage-B credit activation remains gated on founder pricing/allowance/budget
   decisions and is unaffected by this change.

Rollback: `mig_344_ROLLBACK.sql` + redeploy the prior edge. External unit prices (§5) remain the only blocker to a
real margin number; they are a provider-account/contract input, not an internally-recoverable value.

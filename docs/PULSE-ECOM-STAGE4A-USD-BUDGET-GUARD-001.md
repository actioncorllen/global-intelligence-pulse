# PULSE-ECOM-STAGE4A-USD-BUDGET-GUARD-001

**Stage 4A — real server-side USD spending ceiling for paid product research (DataForSEO), BUILT,
DEPLOYED and VERIFIED. A fail-closed, atomic USD reservation now runs inside `fn_research_dispatch`
BEFORE the 013N executor webhook fires; reconciliation runs on DataForSEO ingest. Enforcement is by
dollars (micro-USD), not call counts. DEFAULT = DISABLED: until the founder authorises a dollar limit,
DataForSEO is removed from every dispatch (no paid call fires). Self-test 11/11 PASS. No paid DataForSEO
call and no Snowman research were run. mig_318.**

## What was added (mig_318, reuses existing architecture)
- **`research_budget_config`** (singleton, RLS, service-role only): `enabled` (default **false**),
  `monthly_cap_micro`, `per_run_cap_micro`, `per_run_worstcase_micro` (default **150000** = $0.15).
- **`research_spend_month`** (`month`,`cap_micro`,`spent_micro`,`reserved_micro`) — the USD ledger.
- **`research_spend_reservation`** (`UNIQUE(run_id,provider)`, status RESERVED|RECONCILED|FORFEITED) —
  per-run reservation + reconcile record.
- Functions (all SECURITY DEFINER, `search_path=''`, **service_role-only** execute):
  `fn_research_budget_set` (founder authorisation lever), `fn_research_budget_state`,
  `fn_research_budget_reserve`, `fn_research_budget_reconcile`, `fn_research_budget_selftest`.
- The design mirrors the proven mig_315 Gemini $2/mo translation cap (reserve-worst-case-before,
  reconcile-actual-after, forfeit-on-uncertainty, never refund). The translation cap is untouched.

## Where it is enforced (req 2 + req 6 — no bypass)
- `fn_research_dispatch` is the **only** function that fires the `research_executor_webhook`
  (verified: it is the sole referencer). The guard sits there, **before** `net.http_post`: when a run
  would dispatch DataForSEO (SEARCH_DEMAND attempt NOT_SEARCHED + GB location present), it calls
  `fn_research_budget_reserve(run,'DATAFORSEO')`. On refusal the DataForSEO attempt is set
  `SOURCE_UNAVAILABLE` (fail-closed), so the manifest emits a non-DISPATCH action and the 013N executor
  **skips the DataForSEO branch**; the free providers (eBay/Meta/CJ/TikTok/Reddit) are unaffected.
- The only alternative paid path, `fn_invoke_provider_broker`, is allow-listed to
  `fastmoss-product-detail` only — it **cannot** invoke DataForSEO, so there is no bypass.
- Reconcile: `fn_research_ingest_source` calls `fn_research_budget_reconcile` on the DataForSEO ingest —
  **success** → spend the known actual **$0.102** (102000 micro, clamped to the reserved worst-case,
  surplus released); **failed/uncertain** (receiver error or bad response) → **forfeit the full
  worst-case** (never refunded). The DataForSEO live endpoints bill whenever the executor reaches
  ingest, so reconcile-on-ingest reflects real spend.

## Enforcement model (req 3 + req 4)
- **USD, not call counts.** The ceiling is a monthly `cap_micro`; each run reserves a conservative
  per-run worst-case ($0.15 > the verified $0.102) and reconciles to actual. This is independent of the
  old `provider_call_budget` (call-count only), which the auto-dispatch path does not use.
- **Approved-per-run + monthly:** a reserve is refused if the worst-case exceeds `per_run_cap_micro`, or
  if `spent + reserved + worst_case > monthly_cap_micro`.
- **Verified pricing baked in:** worst-case default $0.15; reconcile actual $0.102 = $0.09 (search
  volume live) + $0.012 (search intent live).

## Concurrency / retries / duplicates / fail-closed (req 5)
- **Atomic reserve:** the monthly conditional `UPDATE ... WHERE spent+reserved+wc <= cap` row-locks the
  month row, so concurrent reserves serialise and an approved cap can never be exceeded.
- **Idempotent per run+provider:** `UNIQUE(run_id,provider)` + claim-first insert; a retry / duplicate
  dispatch / concurrent caller re-uses the existing reservation (no double-charge). On a monthly-cap
  miss the claim is rolled back (no mutation stands). Upstream, `fn_research_request_core` already
  serialises per (tenant+product+market) with an advisory xact-lock and dedupes in-flight runs.
- **Never refunds uncertain charges:** a failed/uncertain reconcile forfeits the full reserved
  worst-case to `spent`; an un-reconciled reservation (executor never ran) stays reserved and counts
  against the month (fail-closed for that month).
- **Fail-closed default:** disabled, or no authorised monthly cap ⇒ reserve refused ⇒ DataForSEO
  skipped ⇒ no paid call.

## Verification (req 7 — no live paid calls)
`fn_research_budget_selftest()` drives the REAL reserve/reconcile API inside a rolled-back
subtransaction (no persisted state, no paid calls): **11/11 PASS** —
`disabled_refused`, `reserve_ok` (remaining math), `duplicate_idempotent` (no double-charge),
`reconcile_success_actual` ($0.102 spent, surplus released), `reconcile_idempotent`,
`forfeit_uncertain_no_refund` (full worst-case, never refunded), `reconcile_no_reservation`,
`per_run_cap_refused`, `monthly_cap_refused_no_mutation`, `exact_boundary_ok`, `one_micro_over_refused`.
Live post-deploy state: **enabled=false** (fail-closed), 0 month rows, 0 reservation rows, and a live
reserve against the disabled default returns `budget_disabled`.

## Security hardening
The four control functions + the self-test are **service_role-only** (ACL `postgres | service_role`).
Supabase grants EXECUTE to `anon`/`authenticated` directly, so an explicit
`REVOKE ... FROM public, anon, authenticated` was required and applied — the browser and signed-in users
cannot read or change the budget, reserve, reconcile, or run the self-test. The three tables are RLS-on
with no policies (service-role-only access path), consistent with the mig_315 pattern.

## Preservation — PASS
Tenant/country isolation (dispatch/ingest unchanged for auth and market scoping), Product Asset Lock,
all existing n8n workflows (no edit — the 013N executor was not touched), the Gemini $2/mo translation
cap (mig_315, untouched), and all free providers. The only paid provider on this path is DataForSEO.

## How the founder turns it on (not done here)
`SELECT public.fn_research_budget_set(true, <monthly_cap_micro>, <per_run_cap_micro>);`
e.g. `fn_research_budget_set(true, 1000000, 200000)` = $1.00/month cap, $0.20 per-run cap (worst-case
$0.15 fits). Until then the guard stays DISABLED and no paid DataForSEO call can fire.

## Status
| Req | Result |
|---|---|
| 1 — reuse dispatch/ledger/budget architecture | **PASS** (guard in existing `fn_research_dispatch`; mirrors mig_315) |
| 2 — fail-closed atomic USD reserve before the 013N webhook | **PASS** |
| 3 — approved per-run + configurable monthly; default DISABLED | **PASS** |
| 4 — verified pricing; conservative reserve + reconcile actual | **PASS** ($0.15 reserve / $0.102 actual) |
| 5 — concurrency/retry/duplicate/uncertain; never auto-refund | **PASS** (atomic + idempotent + forfeit) |
| 6 — every 013N paid dispatch guarded; no bypass | **PASS** (sole webhook caller; broker fastmoss-only) |
| 7 — over-cap/concurrency/reconcile/duplicate/fail-closed tests, no paid calls | **PASS** (11/11) |
| 8 — fix → re-test → deploy → verify | **PASS** (deployed mig_318; re-verified live) |
| Preservation | **PASS** |

**Overall: PASS.** The USD budget guard is deployed, verified and DISABLED by default. No paid DataForSEO
call and no Snowman research were executed.

**STOP — guard built & verified only.** Awaiting founder authorisation of a dollar limit before any
Snowman run.

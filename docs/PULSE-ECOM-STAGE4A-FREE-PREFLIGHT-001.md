# PULSE-ECOM-STAGE4A-FREE-PREFLIGHT-001

**Free, read-only cost & budget preflight for the one bounded Snowman GB research run
(`873551b0…`, GB, tenant `7c8ddf9d…`). No paid call made, no workflow created or modified. Headline:
the run is structurally capped at exactly two DataForSEO tasks and cannot retry/multiply (PASS), but
the provider-budget system enforces only CALL COUNTS — there is NO USD ceiling, and on the actual
auto-dispatch path the budget is not even consulted (verified GAP, smallest safe correction reported).
Live DataForSEO balance + exact per-task prices remain BLOCKED: the only mechanism is a one-node
read-only probe, which the "do not modify workflows" constraint of this preflight forbids.**

## 1–2. DataForSEO pricing & balance — BLOCKED on live verification (documented values given)
- **Live check not run.** The free `GET /v3/appendix/user_data` endpoint (which returns `money.balance`
  + the account's `price` map) is the right source, but: (a) **no existing n8n workflow** calls it — every
  DataForSEO workflow hits paid endpoints; (b) the DataForSEO credential is held only in n8n
  (`Pulse DataForSEO`, httpBasicAuth `OYKLUdhcUwGJ8ymT`) and is **not readable** from Supabase
  (`server_integration_config` holds only `edge_gateway` + `research_executor_webhook`), so it cannot be
  called directly from the container. The only way to run it is a tiny read-only probe workflow, which
  this preflight's "do not modify workflows" rule forbids — so it was **not** created. Needs an explicit
  one-word go.
- **Documented list prices (NOT live-verified — DataForSEO pricing can change; confirm via the balance
  endpoint before the run):**
  - `keywords_data/google_ads/search_volume/live` ≈ **$0.05 per live task** (one call carries all ~3
    seeds; this per-call charge is effectively the minimum).
  - `dataforseo_labs/google/search_intent/live` ≈ **$0.01 per live task** (Labs base per-task; ~3 keywords
    is the minimum tier).
  - **→ ≈ $0.06 for the two-task run; structural ceiling ≤ ~$0.20 regardless of price (only 2 tasks).**

## 3. Executor permits only the two planned DataForSEO tasks — PASS
The active executor **"Pulse — Research Auto-Dispatch Executor (013N)"** (`QjYMzrCm1cDXxUS4`) is fixed and
loop-free on the DataForSEO branch: `DataForSEO Applicable?` IF-gate (fires only when the manifest action
is `DISPATCH`) → `DFS Search Volume` (1 request) → `DFS Search Intent` (1 request) → `Shape Keywords` →
`Ingest DFS`. There is **no loop / splitInBatches / pagination** node; each node runs once per run. No
node sets `retryOnFail` (n8n default = off) and all use `neverError:true`, so a non-2xx response does not
throw or trigger a retry. The dispatch webhook responds `onReceived` (immediate 200), so the `pg_net`
caller in `fn_research_dispatch` gets an instant ack and does not re-POST. **Exactly 2 DataForSEO tasks
per run; cannot unexpectedly multiply.** A *second* run for the same product+market is independently
prevented by `fn_research_request_core` (advisory xact-lock + 7-day freshness reuse + 1-hour in-flight
dedup), so the run cannot be duplicated either.

## 4. Budget enforcement is CALL-COUNT only — and not even wired into this path — PASS (verified gap)
- `provider_call_budget` columns are `max_calls` / `consumed_calls` — **pure call counts, no price, no USD
  column, no dollar ceiling anywhere.**
- `fn_provider_budget_try_consume` enforces only counts and hard-codes the **metered set to
  `FASTMOSS`/`KALODATA` only**. For every other provider — **including DATAFORSEO** — with no budget row
  it returns `allowed:true, enforced:false, reason:'no_budget_unenforced'`. So DataForSEO is not treated
  as a fail-closed metered provider by this function.
- The budget functions are called only by `fn_invoke_provider_broker` and `fn_preflight_contract_check`.
  **The live auto-dispatch path (`fn_auto_dispatch_candidate_research` → `fn_research_request_core` →
  `fn_research_dispatch` → 013N webhook → `fn_research_ingest_source`) does NOT call the broker or the
  budget at all.** So for the Snowman run, no provider-budget check runs.
- **Conclusion:** there is **no monetary (USD) enforcement** for research providers. The only USD cap in
  the whole system is the separate Gemini translation $2/month cap (mig_315), which does not apply here.

## 5. Monetary-enforcement gap + smallest safe correction (REPORT ONLY — not implemented)
**Gap:** no dollar ceiling on research spend; the call-count budget is unenforced for DataForSEO and is
bypassed by the auto-dispatch path. DataForSEO cost is bounded today only by (a) the executor's fixed
2-task structure, (b) the `fn_research_request_core` idempotency controls, and (c) the manual
`pulse.suppress_dispatch` kill-switch.

**Why the single Snowman run is nonetheless safe:** ~$0.06 worst-realistic, hard-capped at 2 tasks, no
retry, no duplicate run.

**Smallest safe corrections, in ascending size (none applied):**
1. **Zero-code, for the test itself:** run once with `pulse.suppress_dispatch='on'` as a $0 dry-run
   (creates the run, fires nothing), then flip it off for the single real run. Already available.
2. **Minimal real USD enforcement (recommended before any scale-up):** mirror the proven mig_315 pattern
   — a `research_spend_month` table + a **reserve** in `fn_research_dispatch` *before* `net.http_post`
   (expected DataForSEO task-count × known per-task price) and a **reconcile** in
   `fn_research_ingest_source` for `DATAFORSEO` rows, failing closed. This is the smallest change that
   gives a true monthly dollar ceiling without rebuilding the 013N executor. (A `provider_call_budget`
   row alone would NOT help, because 013N never consults it.)

## 6. Preservation — PASS
Entirely read-only: no writes, no workflow created/modified, no paid call. Tenant isolation
(`NOT_AUTHORIZED` guard on `user_id <> caller`), country isolation (GB scoping, loc 2826, `EBAY_GB`,
GBP), existing source evidence and Product Asset Lock all untouched.

## Status
| Req | Result |
|---|---|
| 1 — account pricing & balance | **BLOCKED (live)** — free endpoint needs a one-node probe forbidden by this preflight; documented prices given |
| 2 — exact charges + minimums | **BLOCKED (live)** — documented ≈ $0.05 (search_volume) / ≈ $0.01 (search_intent); confirm via balance endpoint |
| 3 — only 2 tasks, no retry/multiply | **PASS** |
| 4 — USD ceiling vs call-count | **PASS (verified): call-count only, no USD ceiling, unwired on this path** |
| 5 — gap + smallest safe correction | **Reported** (not implemented) |
| 6 — isolation / evidence / Asset Lock | **PASS** |

**Overall: PASS on enforceable-cost structure (2-task cap, no multiply) with a verified MONETARY-ENFORCEMENT
GAP; BLOCKED on live balance/price until a read-only free `appendix/user_data` probe is authorised.**

**STOP — preflight only.** No research dispatched, no paid call, no workflow created/modified, Stage 4B
not started.

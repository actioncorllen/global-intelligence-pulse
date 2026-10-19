# PULSE-ECOM-RELIABILITY-FOUNDATION-001

**Production reliability foundation before paid launch. `mig_310` (additive, no DROP, no paid calls) +
`fastmoss-discovery` edge v5. Fixes the confirmed schema/RPC, deployment-era and discovery-to-workspace
defects, enforces hard provider budgets, separates weekly refresh from new discovery, adds pre-deploy
contract checks + response validation, and adds a reliability monitor. All verified free (no paid
provider calls). Selftest 7/7, preflight 13/13, monitor OK. Status: PASS (backend reliability) /
PARTIAL (one external dependency; live customer verification still required before declaring
paid-launch readiness).**

## 1. Hard provider-call budget (req 2) — FAIL CLOSED
`provider_call_budget` + `provider_call_ledger`; `fn_provider_budget_open` grants an approved N-call
budget; `fn_provider_budget_try_consume` is the single atomic gate, wired into both paid paths:
`fn_invoke_provider_broker` (SQL broker) and the `fastmoss-discovery` edge function (per lane).
- **Metered providers (FASTMOSS, KALODATA) fail closed**: with **no approved budget** a paid call is
  **refused** (`no_budget_fail_closed`) — a refused broker call never reaches `net.http_post`, and a
  refused lane makes no provider fetch. Non-metered/internal providers stay permitted-but-logged so free
  integrations are not broken.
- **An approved N can never become N+1**: the conditional `UPDATE ... consumed_calls < max_calls ...
  FOR UPDATE` is atomic, so **retries (incl. the 60s timeout retry that caused the GB 3→4 overrun) and
  concurrent callers** can never take more than N slots — only one caller wins the last slot.
- Verified: budget of 3 → exactly 3 allowed, 4th `budget_exceeded`; FASTMOSS with no budget →
  `allowed:false`; broker raised `provider_budget_exceeded` before dispatch; every call ledgered.

## 2. Discovery → workspace projection (req 1, 3) — free, no research
Confirmed defect: ingested FastMoss candidates were invisible until the weekly Monday run (no on-demand
projection). `fn_project_discovered_candidates(tenant, market)` assembles a country
`product_market_evaluation` + `fn_pod_evaluate` for **registered candidates lacking a decision**, with
`pulse.suppress_dispatch=on` (NO paid research). Country-isolated; **existing decisions untouched**
(idempotent). Wired into edge v5 so NEW discovery becomes a visible WATCH card immediately. This cleanly
**separates NEW discovery (paid pulls, budget-gated) from the weekly REFRESH (free projection)**.
- Applied to the real projection gap: **9 DE products** (with covers + lanes) that were stuck invisible
  are now visible WATCH cards; the pre-existing 10 DE decisions were not modified. GB re-run → 0
  projected (idempotent). Monitor projection gap: 9 → **0**.

## 3. Preflight contract checks + response validator (req 4)
- `fn_preflight_contract_check()` — asserts 10 workspace/discovery/reliability RPC **signatures**
  (by argument types) + the customer read **contract strings** (`fn_product_discovery_lanes` /
  `fn_product_media_state` fail-closed shape) + the validator guards. **13/13 PASS.** Run before any deploy.
- `fn_validate_provider_rank_response(jsonb)` — safe pre-ingest validation: rejects NULL/non-object
  (the pg_net timeout case), provider error codes (`code<>0`, e.g. 403), missing/invalid product lists,
  and rows without `product_id`; treats a genuinely empty list as a safe no-op (UNKNOWN != 0).

## 4. Reliability monitor + dispatch schedule registry (req 5, 3)
- `fn_reliability_monitor()` (read-only, service_role) — surfaces: provider transport errors
  (pg_net timeouts/HTTP errors), **customer-facing projection gap** (registered without decision),
  **stale discovery markets** (freshest lane signal older than N days), active budgets, and dispatch
  schedule health. Currently reports **health OK** (gap 0, no stale markets); 1 historical provider
  timeout (the GB TOP_SELLING retry) is in the pg_net window and ages out.
- `discovery_dispatch_schedule` — makes the **GB scheduling gap explicit**: NEW_DISCOVERY rows for DE &
  GB are seeded `active=false` (`inactive_gap=true`) — recurring **paid** discovery is never on without
  an explicit flip + approval; REFRESH rows are `active=true` (free weekly Monday projection).

## Preserved (req 6, 7)
Tenant/country isolation (server `auth.uid()` / explicit tenant; GB lanes return empty under DE),
verified identity (`platform_id`, never SKU), evidence truthfulness (UNKNOWN != 0; no fabrication) and
Product Asset Lock (REFERENCE_ONLY unchanged). **GB (28 products) and DE (19 products) discovery data
preserved**; no completed discovery repeated; no paid calls, no RLS bypass.

## Reliability notes on this migration
- The selftest isolates its test records via a **rolled-back subtransaction** (no DELETE; 0 persistent
  rows) — req 3.
- Deployment status was **verified before each retry**; two transient MCP timeouts on one function did
  not apply it (confirmed `exists=0`), and it was then applied cleanly via `apply_migration` — no
  repeated blind retries. The committed `mig_310` file is idempotent (CREATE OR REPLACE / IF NOT EXISTS
  / ON CONFLICT) and is the durable source of truth.

## Status: PASS (backend reliability) / PARTIAL (external + live verification)
**Verified fixes:** selftest 7/7, preflight 13/13, monitor OK, budget fail-closed + atomic cap,
projection gap closed, GB/DE preserved.

### Remaining reliability blockers / dependencies
1. **External n8n dispatcher (GB scheduling gap)** — recurring NEW GB (and DE) discovery is OFF and now
   fails closed without a budget. To turn it on: a human approves, opens a per-run budget
   (`fn_provider_budget_open('FASTMOSS', tenant, market, 3)`), and the external dispatcher
   (`tradingb.app.n8n.cloud`) is wired to read `discovery_dispatch_schedule` + open that budget per run.
   Not activated here (no approval to start recurring paid calls).
2. **On-demand FASTMOSS enrichment** (product detail / video via the broker) now also fails closed — any
   such action must open a 1-call budget first. Intended fail-closed posture; callers must be updated.
3. **Live customer verification** — all checks here are backend/contract-level. **Do not declare
   paid-launch readiness** until a signed-in customer session is verified on the live site
   (Products → GB/DE: cards, covers, lane filter, drawer evidence).
4. Pre-existing data quality: 10 older DE FastMoss products have no stored cover (predate cover
   persistence); they render honestly without an image (no fabrication) and can only be re-covered by a
   fresh paid pull (not done).

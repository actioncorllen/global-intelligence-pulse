# Bounded Live Refresh Discovery Test — Execution Plan (2026-11-10)

The single controlled live acceptance test for paid Refresh Discovery. **PREPARED — NOT executed. No provider
credit is spent and no config is applied until the founder explicitly approves the one paid call (the FIRE step).**
Backend is already deployed (Stage B + edge v13); this plan only adds a temporary, tenant-scoped test config.

## 0. Current state (verified read-only, 2026-11-10)
Fail-closed: **0** active credit prices, **0** active allowances, **0** active Kalodata budgets. Test tenant has an
active entitlement + member. Nothing can refresh today.

## 1. Exact test target
- **Test tenant:** `7c8ddf9d-172c-4a89-a402-bb7066228b61` ("Founder Ecommerce Test") — active `ecommerce_monthly`
  (COMP) entitlement, has `member`, owns products. (Alternate: `80f4875a-4e5d-4fd9-aa22-ea37fe59d15d`.)
- **Market:** **DE** (EUR; Kalodata-enabled; page cursor = 1, so the refresh buys page 1). GB is an equally valid
  alternate.
- **One Kalodata ranking request, one page of ≤10 results** (`fn_kalodata_discovery_request` → `page_size=10`).
- **Maximum provider-credit expenditure: 0.1 provider credit (≈ $0.01 USD estimate)** — hard-capped by
  `provider_call_budget.max_calls = 1`.

## 2. Temporary test-only configuration (apply ONLY on approval; values are not invented — they are the test's)
Keeps the test isolated to one tenant/market; **no global allowance, no other tenant can refresh**:
```sql
-- (a) price the TEST MARKET only (other markets stay PRICING_NOT_CONFIGURED)
INSERT INTO public.discovery_credit_price (market, credits_per_refresh, active, note)
VALUES ('DE', 1, true, 'BOUNDED_TEST 2026-11-xx');

-- (b) grant exactly ONE customer credit to the TEST TENANT ONLY (direct grant, NOT via allowance)
INSERT INTO public.discovery_credit_ledger (tenant_id, entry_type, credits, idempotency_key, reason)
VALUES ('7c8ddf9d-172c-4a89-a402-bb7066228b61', 'GRANT', 1, 'bounded_test_2026-11-xx', 'bounded live test grant');

-- (c) fund the TEST TENANT's provider budget with a HARD CAP OF ONE call, auto-expiring
INSERT INTO public.provider_call_budget (provider, user_id, market, approval_key, max_calls, active, expires_at)
VALUES ('KALODATA', '7c8ddf9d-172c-4a89-a402-bb7066228b61', 'DE', 'bounded-test-2026-11-xx', 1, true, now() + interval '1 day');

-- (d) DO NOT touch discovery_credit_allowance (global allowance stays EMPTY → sweep stays a no-op for everyone)
```
**Why test-only:** the price is DE-scoped; any other tenant in DE still fails `INSUFFICIENT_CREDITS` (no grant) or
`PROVIDER_NOT_AUTHORIZED` (no budget). The second founder tenant has an entitlement but no grant/budget → cannot
refresh. The allowance table stays empty, so the hourly sweep grants nothing to anyone.

## 3. Execution — only the FIRE step spends (everything before it is free)
Driven either by the founder clicking **Refresh discovery** in the UI signed in as the test tenant, or by the
authenticated RPC sequence below (impersonating the test tenant). Measurable, idempotent:
1. **QUOTE** `fn_discovery_refresh_quote('DE')` → expect `can_refresh=true`, `required_credits=1`, `available=1`. *(free)*
2. **RESERVE** `fn_discovery_refresh_reserve('DE', <idem>)` → `-1` credit, request `RESERVED`, `page_number=1`. *(free)*
3. **AUTHORIZE** `fn_discovery_refresh_authorize(<request_id>)` → consumes the one provider budget unit → `EXECUTING`. *(free — no provider call yet)*
4. **FIRE** `fn_discovery_refresh_fire(<request_id>, <publishable_anon_key>)` → **the single paid Kalodata rank call (0.1 credit).** ← **the only step that spends; requires founder approval.**
5. **KALODATA → INGEST** (edge v13, `p_suppress_auto_research=true`) → **COMPLETE_FROM_EDGE → SETTLE**.
6. **STATUS** `fn_discovery_refresh_status(<request_id>)` polled until terminal.

## 4. Exact acceptance checks (record each)
- **Kalodata credits deducted:** Kalodata account balance **14.2 → ~14.1** (0.1 deducted); corroborated by the
  `discovery_runs.raw_contract.provider_usage` telemetry row (`call_count=1`, endpoint, `http_status`,
  `relationship=customer_refresh`).
- **Provider response + candidate count:** edge response `raw_candidate_count`, `scanned`, `qualified`,
  `promoted_count`.
- **New vs duplicate:** `complete_from_edge` `new_total` vs `duplicates` (from `promoted[].dedup_status`).
- **Customer-visible vs image-pending:** `new_visible` vs `new_image_pending` (Explorer gate predicate).
- **Customer-credit settlement:** ledger `SETTLE` (1 credit used); `status` `SETTLED`, `charged=true`, `balance=0`.
- **Provider usage telemetry:** `provider_usage` recorded (monetary null; provider credit distinct from customer
  credit).
- **Request idempotency:** re-RESERVE same key → `idempotent_replay`; re-FIRE → `already_dispatched` (no 2nd call);
  re-COMPLETE → `idempotent_replay` (no double settle).
- **No deep research triggered:** zero new `commerce_research_run` rows for the promoted products in the test
  window; research providers' budgets untouched (`fn_research_dispatch` never invoked by the refresh).

**Invariant:** the test MUST NOT exceed one authorised paid provider call — structurally guaranteed by
`max_calls=1` + atomic consume + one-fire `dispatched_at`.

## 5. Rollback & stop conditions
- **Before FIRE (steps 1–3):** if QUOTE isn't `can_refresh=true` or AUTHORIZE is denied → **stop; no spend has
  occurred**; fix config and retry. FIRE is the only paid step.
- **After FIRE:** never re-fire (idempotent anyway). If the completion callback is lost, the scheduled reconcile
  refunds the customer (`UNRESOLVED_POST_DISPATCH`) automatically; the one provider call stays consumed (it
  happened) — no manual action.
- **Config rollback (instant, any time):**
  ```sql
  UPDATE public.discovery_credit_price     SET active=false WHERE note='BOUNDED_TEST 2026-11-xx';
  UPDATE public.provider_call_budget       SET active=false WHERE approval_key='bounded-test-2026-11-xx';
  -- optional zero-trace cleanup (ledger otherwise remains as the test audit trail: GRANT+1, RESERVE-1, SETTLE 0 → balance 0):
  -- DELETE the test price/budget rows and the test ledger rows by their keys.
  ```
  No migration rollback is needed — Stage B stays deployed and returns to fully fail-closed once price + budget are
  inactive.

## 6. The one explicit approval needed to execute
**Founder authorises spending ~0.1 Kalodata provider credit (≈ $0.01 USD) on the single FIRE step.** On approval:
apply §2, run §3, record §4, then roll back §5. Nothing else is activated — no general subscriptions, no global
allowance, no other tenant, no second wave.

---

## Appendix — founding-member rollout budgeting (post-test, on commercial approval; not part of the test)
Proposed founding config: **1 customer credit/refresh**, **5 included refreshes/period**, **no credit packs**,
independent provider-budget enforcement. Provider exposure is funded per eligible (tenant, market):
`provider_call_budget.max_calls ≥ allowance (5)`. Total Kalodata credit exposure ≈
`Σ(founding members × markets enabled for them × max_calls) × 0.1 credit`. Example: 20 founding members × 1 market
× 5 = 100 rank calls = **10 provider credits ≈ $1.00/period** (estimate at the $0.10/credit reference). Fund the
Kalodata account to cover the chosen fan-out; the customer allowance (5) never authorises more than the funded
`max_calls`.

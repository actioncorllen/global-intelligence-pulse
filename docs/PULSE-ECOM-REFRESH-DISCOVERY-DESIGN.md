# Refresh Discovery — secure end-to-end release design (2026-11-09)

Phase C design to accompany the prepared `mig_341` scaffold (customer-credit ledger + quote + reserve + settle).
Nothing here is deployed or activated. Distinguishes **customer credits** (Strateloq credits) from **external
provider credits** (`provider_call_budget`). No customer-credit price or allowance is invented; a real provider
call stays gated behind a founder-authorised provider budget.

## End-to-end flow (happy path)
1. **Customer confirmation** — customer selects 1 of the 18 supported countries, clicks Refresh Discovery; the UI
   first calls the quote (step 2) and shows required credits + balance; the customer confirms.
2. **Server quote** — `fn_discovery_refresh_quote(market)` (server-authoritative cost from `discovery_credit_price`;
   tenant-scoped balance; checks active subscription entitlement + an authorised KALODATA provider budget for the
   market). Returns `can_refresh` + a `reason` when blocked. Fail-closed.
3. **Credit reservation** — `fn_discovery_refresh_reserve(market, idempotency_key)`: advisory-lock + unique-index
   idempotency (double-click safe); re-checks the quote inside the lock; writes a RESERVE ledger row (−cost) and a
   `discovery_refresh_request` (RESERVED); reads the **next** Kalodata page cursor (`fn_kalodata_next_page`, no
   page-1 re-buy). Does NOT fire the provider call.
4. **Provider authorisation** — dispatch consumes the founder-authorised `provider_call_budget` atomically
   (`fn_provider_budget_try_consume`), fail-closed. Request → EXECUTING. (This is the only step that spends real
   provider credit; it is gated and not activated here.)
5. **Discovery execution** — reuse `fn_kalodata_run_discovery(user, market, limit, key, page_number)` with the
   reserved page; secret only in the edge env; market-scoped.
6. **Canonical deduplication** — existing ingest path excludes previously-discovered canonical identities from
   NEW results (same dedup used by the current discovery).
7. **Result persistence** — country-specific research evidence saved under the tenant + market (existing ingest),
   images resolved via the existing rights-ranked resolver (Explorer v4).
8. **Credit settlement** — `fn_discovery_refresh_settle(request_id, new_products, outcome)` applies the explicit
   policy below. Workspace refreshes for the selected country.

## Explicit outcomes (settlement policy — founder-reviewable)
Refund is driven by **whether a chargeable provider call occurred**, not by the new-product count.

| # | Case | Chargeable call? | Result | Credits |
|---|---|---|---|---|
| 1 | **Provider failure BEFORE execution** (no budget, auth/builder error, UNSUPPORTED_MARKET) | no | REFUND | restored |
| 2 | **Provider failure AFTER a chargeable request** | yes | **REFUND by default (goodwill; Strateloq absorbs provider cost)** — founder decision D3; flip to settle to make the customer bear it | restored (default) |
| 3 | **Zero NEW products from a SUCCESSFUL search** | yes | **SETTLE — no refund** (a charged search that truthfully returns "nothing new in this market" delivered a valid answer) | consumed |
| 4 | **Partial success** (some new found) | yes | SETTLE | consumed |
| 5 | **Duplicate request** (same idempotency_key) | — | idempotent replay, returns the existing request | no 2nd charge |
| 6 | **Concurrent requests** (same tenant) | — | serialised by advisory lock; each distinct key reserves separately (each is a distinct paid refresh); rapid double-clicks share one key → one charge | no accidental double charge |
| 7 | **Timeout / unknown** | unknown | safe default REFUND; a reconciliation sweep may later correct to SETTLE if the run did deliver | restored (default) |
| 8 | **Customer cancellation before execution** | no | REFUND (`CANCELLED_PRE_CHARGE`) | restored |

Verified transactionally (production untouched): case 3 (zero-new SUCCESS → SETTLE, balance unchanged), case 1/8
(pre-charge → REFUND), case 2 (post-charge → REFUND default), case 5/6 (idempotent, no double charge).

## Security properties (enforced in mig_341 / reused infra)
- **Tenant-scoped balances** (ledger keyed by `auth.uid()`; RLS read-own; writes only via SECURITY DEFINER fns).
- **Market-specific execution** (quote/reserve/dispatch are per market; country isolation preserved by the
  Explorer/ingest contracts).
- **Server-authoritative cost** (price from `discovery_credit_price`, never the client).
- **Atomic accounting** (reserve + ledger in one transaction under an advisory lock).
- **Concurrency / double-click protection** (advisory xact lock + unique idempotency index).
- **Idempotency keys** (unique per tenant; replay-safe reserve and settle).
- **Provider-specific budgets** (dispatch consumes `provider_call_budget` fail-closed — no budget ⇒ no call).
- **Fail-closed authorization** (quote denies on missing price / subscription / balance / provider budget).
- **Audit history** (append-only ledger: GRANT/RESERVE/SETTLE/REFUND).
- **No repeated page-one purchases** (`fn_kalodata_next_page` advances the cursor).
- **No duplicate customer charges** (idempotency + lock).

## Remaining implementation gaps (before activation)
- **Dispatch step (4–5) wiring** inside the reserve→settle lifecycle: transition RESERVED→EXECUTING, call the
  kalodata-discovery edge, capture run_id, then settle on the edge result (SUCCESS/POST_CHARGE_FAILURE + new count).
- **Reconciliation sweep** for stuck RESERVED/EXECUTING (case 7): a scheduled job that settles/refunds by run
  outcome after a window.
- **Frontend wiring** (gated): Refresh Discovery button → quote → confirm modal (required credits + balance) →
  reserve → dispatch → settle, with the button disabled + showing `reason` until D1–D4 are met; mobile-fit modal.
- **Credit-grant path (D2)**: who writes GRANT ledger rows (subscription allowance vs purchased packs; possible
  Stripe integration) — not defined.

## Customer-credit commercial decisions required (founder)
- **D1 — Pricing:** credits per refresh, per market (`discovery_credit_price` rows). Not invented.
- **D2 — Credit grant:** how customers receive Strateloq credits (subscription allowance vs purchased packs;
  billing integration). Not defined.
- **D3 — Post-charge-failure refund policy:** confirm the default (refund the customer, Strateloq absorbs the
  provider cost) or amend (`v_goodwill_refund_post_charge`).
- **D4 — Provider budgets:** authorise `provider_call_budget` per market (real provider spend) — the existing
  founder-gated step; without it a refresh cannot execute (fail-closed).

Nothing above is deployed/activated; no customer charge or paid provider call can occur until D1–D4 are set and
`mig_341` is deployed with the dispatch wiring.

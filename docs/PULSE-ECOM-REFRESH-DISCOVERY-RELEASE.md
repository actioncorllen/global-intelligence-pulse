# Refresh Discovery — P0 Release & Activation Gate (2026-11-09)

## STAGE A — DEPLOYED to production ✅ (2026-11-09)

The safe interface release is **live**. The customer credit-spending path is **NOT** activated (no pricing, no
provider budget, no customer credits) — the Refresh modal opens and shows a clear "not activated yet" state.

- **Image gate `mig_342` (Explorer v5)** applied to production (migration `image_gate_product_explorer_v5_
  image_only`). Verified live as the founder tenant: contract `pulse_product_explorer_v5`, Germany **9 visible
  / 20 hidden**, gate on, server-filters preserved; **0 non-DISPLAY items, 0 commercial-asserted (PAL intact),
  0 covers not owned by that exact product+tenant** (no unrelated image); tenant isolation (other uid → 0),
  country isolation (GB independently gated → 28); Recommendations RPC intact.
- **Frontend published**: Lovable commit **`4d029c0`** — deployment ID **`5d5707f2-6242-4ff0-8b38-
  e2dd2aa1e290`**; `https://www.globalintelligenceactions.com` serving **HTTP 200**. (= approved `7d0869c` plus
  the directive-mandated "not activated" quote-state correction; 579 frontend tests pass.)
- **Rollback (Stage A):** re-publish `db027f5`, then restore Explorer v4 via `mig_342_ROLLBACK.sql`.
- **Outstanding for Stage A:** founder-device signed-in visual acceptance (container egress is auth-gated).

Stage B (credit activation) remains prepared and gated — see §4. The rest of this document is the full package.

---

Deploy-ready package for the customer-credit **Refresh Discovery** feature + the **image gate** (now live).
No paid provider call was made; no provider budget, billing, or pricing was activated or invented. The feature
**reuses the existing `kalodata-discovery` edge** — no new discovery engine.

Commits: backend through `a560d01` (branch `claude/nifty-bardeen-f9nddu`); Lovable **production** `4d029c0`
(Stage A). Prepared, NOT deployed/published (Stage B): `mig_341` (+ `mig_341b` reconcile schedule), edge
`kalodata-discovery/index.ts` refresh-awareness, and Lovable **preview** `d1ac526` (adds the inert
authorize→`fn_discovery_refresh_fire` dispatch wiring; 583 tests pass; publish only at Stage B activation).

**Stage B engineering is complete and fixture-tested (all inert):** (1) authorize→fire wired (`d1ac526`);
(2) one-fire idempotency (server `dispatched_at` guard + one fire per authorize→EXECUTING, both tested);
(3) service-role edge completion callback + `service_role`-only grant; (4) credits settle on the real provider
outcome (SUCCESS settles incl. zero-new, failures refund per D3); (5) scheduled reconciliation prepared
(`mig_341b`); (6) reconcile never re-dispatches a chargeable call; (7) interrupted requests stay auditable
(`provider_outcome` = `UNRESOLVED_POST_DISPATCH`); (8) end-to-end fixture/transactional tests green;
(9) credit modal verified 320–430px. The ONLY remaining Stage-B steps are the founder's commercial activation
(D1–D4), applying the prepared migrations + edge, publishing `d1ac526`, and ONE bounded live integration test.

---

## 1. Edge-to-completion callback — exact status

**Was ABSENT. Now PREPARED + fixture-tested (not deployed).**

- The live edge **v12** accepted `{market, user_id, candidate_limit, page_number}` only — **no
  `refresh_request_id`** — and **never** called a settlement function. A *successful* paid refresh would never
  settle; only the reconcile sweep's refund would eventually fire, i.e. a free successful refresh (Strateloq
  absorbs the cost). This was the real correctness gap.
- A second, latent mismatch: the edge runs as **`service_role`** (`auth.uid()` is NULL), but
  `fn_discovery_refresh_complete`/`settle` scope by `auth.uid()` → the edge would get `REQUEST_NOT_FOUND`. The
  completion credential was wrong for a service-role caller.

**Correction (smallest necessary; all prepared, none deployed, no paid call):**
- `fn_discovery_refresh_complete_from_edge(request_id, new_product_ids[], duplicates, outcome)` — **SERVICE-ROLE**
  completion the edge calls. Derives the owning **tenant + market from the request row** (never trusted from the
  edge payload); recomputes `new_image_pending` with the **exact Explorer gate predicate** (so the customer's
  "visible" count equals what the Explorer shows); idempotent; `GRANT … TO service_role` only (a customer can
  never forge a completion).
- `fn_discovery_refresh_fire(request_id, anon_key)` — dispatch bridge: under the tenant advisory lock it
  **claims** the EXECUTING request (`dispatched_at`) **before** invoking the existing edge with
  `refresh_request_id` threaded in. A lost acknowledgement can **never** cause a second provider call (a second
  fire sees `dispatched_at` and no-ops). Consumes **no** budget (authorize already consumed exactly one unit).
- `fn_discovery_refresh_is_refund(outcome)` — one IMMUTABLE refund-policy source used by the customer path, the
  edge callback, and reconcile, so policy can never drift.
- Edge `kalodata-discovery/index.ts` (prepared): optional `refresh_request_id`; after the single paid call +
  ingest, calls the completion with the right outcome at **every** exit — pre-charge (`PROVIDER_FAILED_PRE_CHARGE`
  for secret-missing / request-builder / UNSUPPORTED_MARKET), post-charge (`PROVIDER_FAILED_POST_CHARGE` for a
  network error after the request, a provider HTTP error, or an ingest failure), and `SUCCESS` (incl. zero-new).
  With no `refresh_request_id` the behaviour is **byte-for-byte the original v12** (normal discovery wave).

**Connected chain (prepared):** quote → reserve → authorize (consume budget, fail-closed) → **fire** (claim +
invoke edge with request id) → edge (one paid call → ingest) → **complete_from_edge** (counts + settle/refund) →
status (customer polls terminal result). Only the **live paid Kalodata call** in the middle cannot be exercised
here without spending money; everything around it is fixture/transactionally tested.

---

## 2. Credit-recovery safety (P2)

- **Uncertain post-dispatch outcome is NOT classified as pre-charge.** A stuck `EXECUTING` request (authorized,
  budget consumed, may have fired) is reconciled to an **auditable** `provider_outcome = UNRESOLVED_POST_DISPATCH`
  and the customer is refunded (founding-member beta). A stuck `RESERVED` (never authorized) is a clean
  `CANCELLED_PRE_CHARGE` refund. Distinct, auditable states.
- **No second paid call on recovery.** Reconcile never re-dispatches; `fire`/`dispatch` are idempotent via
  `dispatched_at`; the provider budget `consumed_calls` only ever increments (an approved N can never become
  N+1), so it is a permanent audit record.
- **No contradiction under retries.** The ledger writes RESERVE −cost once (unique index), then exactly one
  SETTLE(0)/REFUND(+cost) (terminal-status guard). A late edge callback arriving after reconcile already
  refunded is an idempotent no-op (verified). Customer balance, provider usage, and request status stay
  mutually consistent.

---

## 3. Final-release compatibility (P3) — verified

- **RPC names/fields:** frontend `7d0869c` calls `fn_discovery_refresh_quote / _reserve / _authorize / _status`
  — all present, fields match; the new `provider_outcome` on status is additive (the fail-closed decoder ignores
  unknown fields). Full `mig_341` applies cleanly (ordering + cross-refs + grants validated in a rollback txn).
- **Migration ordering:** `mig_342` (Explorer v5) builds on live `mig_340`; `mig_341` is independent. Both apply
  cleanly; rollbacks present.
- **RLS / tenant isolation:** ledger + request are RLS read-own; mutating functions are `auth.uid()`-scoped
  (customer) or service-role (edge/reconcile). Cross-tenant access returns `REQUEST_NOT_FOUND` (tested).
- **Country scoping + image-only visibility + counts:** `complete_from_edge` computes `new_visible` with the
  same gate predicate and the request's own market, so the customer count equals the Explorer count by
  construction. DE fixture: Explorer = 9 visible, 20 hidden.
- **Quote / insufficient-credit states, modal polling, mobile 320–430px:** all green in the frontend suite
  (576 tests). **Recommendations and Product Asset Lock untouched** (edge/migrations don't reference them; the
  frontend diffs are scoped to the refresh module + the button wiring).

---

## 4. Two release stages

### STAGE A — safe interface release (no paid path)
Ship independently; nothing here can spend money or charge a customer.
1. Apply `mig_342` (Explorer v5 image gate). Rollback: `mig_342_ROLLBACK.sql` → v4.
2. Publish Lovable `7d0869c` (balanced grid, mobile header/hero, copy, and the Refresh modal which, with no
   pricing/budget configured, opens and shows a clear **"pricing not set up"** unavailable state — Confirm
   disabled). Rollback: re-publish `db027f5`.
3. Founder-device visual acceptance: desktop grid 1280/1440; mobile workspace + credit modal 320/360/375/390/430.

`mig_341` is **not** required for Stage A and must **not** be applied as part of it.

### STAGE B — customer refresh activation (gated; prepared, not done)
Do **not** enable the credit-spending path merely because `mig_341` is installed.
1. Founder sets **D1–D4** (below).
2. Apply `mig_341` (full lifecycle + `fire` + `complete_from_edge` + status + reconcile). Rollback:
   `mig_341_ROLLBACK.sql` (safe while inert).
3. Deploy the prepared edge `kalodata-discovery` (adds the `refresh_request_id` callback; backward-compatible).
4. Add the **one remaining frontend wire**: after `authorize` returns EXECUTING, call
   `fn_discovery_refresh_fire(request_id, anonKey)` before polling status (the modal already polls status). This
   is the only frontend change left and is inert until a budget exists.
5. Schedule the `fn_discovery_refresh_reconcile` service-role sweep.
6. Authorise a **small, bounded** provider budget (D4) and run **one** live integration test (a single real
   refresh) → confirm settle + counts + status. Only after that passes, grant customer credits (D2) and open
   the path to customers.

---

## 5. Rollback order

- **Stage A:** re-publish `db027f5`, then apply `mig_342_ROLLBACK.sql` (→ Explorer v4). Order: frontend first
  (so the client stops expecting the gated shape), then backend.
- **Stage B:** disable customer credit grants (stop writing GRANT rows) → set provider budgets inactive (halts
  any new paid call immediately; fail-closed) → `mig_341_ROLLBACK.sql` → redeploy the prior edge (v12) if the
  callback is to be removed. Any in-flight EXECUTING request is refunded by the reconcile sweep
  (UNRESOLVED_POST_DISPATCH), never re-charged.

---

## 6. Remaining founder commercial approvals (the only external blockers)

- **D1** — credits per refresh, per market (`discovery_credit_price` is empty by design).
- **D2** — how customers receive credits (subscription allowance vs purchased packs; billing).
- **D3** — confirm post-charge-failure refund default (current: refund customer; Strateloq absorbs — beta).
- **D4** — authorise provider budgets per market (real provider spend) + the one bounded live integration test.

None are technical defects; all gate Stage B activation only. Stage A is independent of all of them.

---

## 7. Test evidence (fixtures / transactional only; no paid calls)

- **Service-role completion:** SUCCESS → SETTLED with `new_visible`/`image_pending`/`duplicates` from the gate
  predicate (p1 owned display → visible; p2 none + p3 marketplace/tenant-NULL → pending); POST_CHARGE → REFUNDED;
  idempotent on duplicate **and** on a late callback after reconcile already refunded (no double settle/charge).
  Persisted balances: charged tenant 5, refunded tenants 10 / 20 — exact.
- **Fire guards:** reserved / already-dispatched / other-tenant / no-key all return **before** any
  `net.http_post` (no provider call); the one-fire `dispatched_at` claim holds.
- **Reconcile:** stuck RESERVED → CANCELLED_PRE_CHARGE, stuck EXECUTING → UNRESOLVED_POST_DISPATCH; both
  refunded, no re-dispatch.
- **Full `mig_341`** applies cleanly in a rollback transaction (ordering + cross-refs + grants, incl.
  `service_role`). **Image gate (mig_342):** DE = 9 visible / 20 hidden. **Frontend `7d0869c`:** 576 tests pass,
  typecheck/lint/build clean, modal 320–430px.

---

## 8. Verdict per release question

| # | Dimension | Verdict |
|---|-----------|---------|
| A | Frontend complete | **PASS** (Stage A); one small Stage-B wire (`fire` call) remains, inert |
| B | Backend execution complete | **PASS** (full chain wired + edge callback prepared) |
| C | Credit accounting complete | **PASS** |
| D | Provider authorization complete | **PASS (inert)** — needs founder budget (D4) |
| E | Recovery / reconciliation complete | **PASS** (auditable unresolved state; no re-charge) |
| F | End-to-end tested with fixtures | **PASS for every leg except the single live paid Kalodata call** (not exercisable without spend) |
| G | Ready for safe deployment | **Stage A: READY.** Stage B: PREPARED, blocked on D1–D4 + edge deploy + the one `fire` wire + one bounded live test |

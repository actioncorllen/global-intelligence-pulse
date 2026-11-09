# Product Discovery — Stage B Release Package (2026-11-09)

One integrated, production-safe Stage B release. **Nothing deployed, published, priced, or activated by this
document.** Everything below is INERT until the founder sets pricing / allowance / provider budgets. Product =
**Strateloq**; company = **Strateloq Technologies**. Verified by rollback-only transactional tests + fixtures; no
paid provider calls.

---

## 1. Exact migration sequence (safe order)

`mig_342` (Product Explorer v5) is **already deployed** in production (as `image_gate_product_explorer_v5_image_only`).
Remaining, in this exact order:

| # | Artifact | Depends on | Effect on deploy (pre-activation) |
|---|----------|-----------|-----------------------------------|
| 1 | `mig_341` credit lifecycle (tables + quote/reserve/authorize/fire/complete/settle/status/reconcile) | existing schema (`account_entitlement`, `provider_call_budget`, `fn_provider_budget_try_consume`, `fn_kalodata_next_page`, pg_net) | INERT — price empty ⇒ quote `can_refresh=false` (`PRICING_NOT_CONFIGURED`) |
| 2 | `mig_341c` subscription allowance (table + on-demand grant + sweep fn) | `mig_341` (ledger + balance) | INERT — allowance empty ⇒ grant no-ops (`ALLOWANCE_NOT_CONFIGURED`) |
| 3 | `mig_341b` schedules (pg_cron: reconcile `*/15`, credit sweep hourly) | `mig_341` (reconcile fn) + `mig_341c` (sweep fn); installs `pg_cron` | INERT — reconcile finds nothing; sweep no-ops while allowance empty |
| 4 | `mig_344` ingest suppression param (`fn_kalodata_ingest_candidates` 6-arg → 7-arg) | current production schema only (independent of the credit set) | Safe immediately; normal discovery waves unchanged; refresh not yet active |
| 5 | **Deploy refresh-aware `kalodata-discovery` edge** | **must be AFTER `mig_344`** | Usage instrumentation active; refresh completion callback dormant until a `refresh_request_id` flows (requires `mig_341` + activation) |

**Coexistence / why there is no unsafe window:**
- A paid request can only be created via reserve → authorize → fire, which needs `mig_341` applied **and** pricing +
  provider budget configured. Pricing/budget are **not** set until founder activation (a later step), so during the
  whole migration window `quote` returns `can_refresh=false` and `reserve` is denied — **the frontend cannot
  dispatch a paid request the database cannot complete or reconcile.**
- The **only** ordering hazard is deploying the new edge **before** `mig_344`: the edge's ingest RPC sends
  `p_suppress_auto_research`, which a 6-arg function would reject (PGRST), breaking all discovery. Mitigation: apply
  `mig_344` first (step 4 before step 5). The **current production edge (v12)** does not send the param, so it
  coexists with the current 6-arg function today; after `mig_344` the old edge still works (its 6 named args resolve
  to the 7-arg function with the new param defaulting false).
- Reconcile scheduling (`mig_341b`) is in place before any request can ever exist, so a stuck request is always
  recoverable.

## 2. Exact frontend SHA

- **Unified Lovable preview `c1a6afa`** = branding/rebrand `c56e6e0` (Strateloq product + Strateloq Technologies
  company + `strateloq.com` canonical/`og:url` metadata) **+** the P3 Refresh-Discovery modal CX (pre-confirmation
  "may return no new products" note + "New candidates" total tile). One-file change on top of `c56e6e0`; branding,
  naming, and canonical metadata preserved. 583 frontend tests pass; typecheck + lint clean.
- **Publishing `c1a6afa` is gated on the `strateloq.com` domain cutover** (DNS + Lovable custom domain + Supabase
  Auth Site URL + Google OAuth origin — founder steps). The Refresh-Discovery modal is **already in production**
  (showing the "not activated" state); the branded build goes live at cutover. **Not published by this task.**

## 3. Exact edge source revision

- Repo: `supabase/functions/kalodata-discovery/index.ts` (prepared; **not deployed**). The single current file
  contains all three required changes, verified integrated, no overwrite:
  1. Refresh-request execution + **service-role** completion callback (`fn_discovery_refresh_complete_from_edge` at
     every exit: pre-charge refund / post-charge refund / SUCCESS settle).
  2. Customer-refresh **auto-research suppression** (`p_suppress_auto_research: refreshRequestId !== null`).
  3. **Reliable provider-usage recording** on every paid call (unconditional; structured; monetary null).
- Production is **edge v12** (old code, no `refresh_request_id`), confirmed via the deployed-function read — no newer
  patch has overwritten the prepared file.

## 4. Full integration test results (rollback-only, fixtures/mocks, no paid calls)

**Prior acceptance (still valid, not re-run):** mig_344 isolation + instrumentation, 10/10 pass
(`PULSE-ECOM-DISCOVERY-COST-CONTROL.md`).

**New end-to-end lifecycle** (mig_341 + mig_341c + mig_344 applied together in one transaction; activated test
tenant; QUOTE→GRANT→RESERVE→AUTHORIZE→FIRE→INGEST→COMPLETE→SETTLE→STATUS + interruption recovery) — **all pass:**

| Checkpoint | Observed |
|---|---|
| Subscription allowance grant → balance | granted, balance 5 |
| QUOTE | `can_refresh=true`, required 1, available 5 |
| RESERVE (+ replay) | balance 4; replay **idempotent** |
| AUTHORIZE | provider budget consumed → `EXECUTING` |
| FIRE (+ replay) | fired; re-fire **idempotent / already_dispatched** (no 2nd provider call) |
| INGEST (suppressed) | 2 promoted, `auto_research_suppressed=true`, **cascade spy = 0 calls** |
| COMPLETE (+ replay) | settled; **2 new = 1 visible + 1 image-pending** (Explorer gate predicate); replay **idempotent** |
| STATUS | `SETTLED`, charged, "1 credits used", visible 1 / pending 1 |
| Interruption → RECONCILE | stuck `EXECUTING` → `REFUNDED` / `UNRESOLVED_POST_DISPATCH`, not charged, never re-dispatched |
| Final balance | 4 (correct across grant / reserve / settle / reserve / reconcile-refund) |

Confirms: one discovery-page request · no automatic deep-research cascade · no duplicate charges or provider
execution · correct pagination + product identity (new ids flow ingest→complete) · new-candidate & image-pending
counts · accurate credit settlement · correct provider usage records · safe recovery from interruption · tenant &
country isolation · Product Asset Lock (image-only gate) · founding-member access unchanged.

## 5. Safe rollback sequence (reverse of apply; safe while inert)

1. Redeploy prior edge **v12** (stops sending `p_suppress_auto_research`).
2. `mig_344_ROLLBACK.sql` (restore the original 6-arg ingest; re-grant).
3. `mig_341b` rollback: `SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('discovery-refresh-reconcile','discovery-subscription-credit-sweep');`
4. `mig_341c_ROLLBACK.sql` (drop allowance + grant fns + index + table).
5. `mig_341` rollback (`mig_341_ROLLBACK.sql`: drop refresh fns + 3 tables).

Each step is reversible and inert; no customer data is affected because no credits/prices/budgets are configured.

## 6. What can deploy WITHOUT activating paid research

**All of it.** `mig_341` + `mig_341c` + `mig_341b` + `mig_344` + the edge are fully inert without founder activation:
- No price ⇒ quote denies; no allowance ⇒ grant no-ops; no provider budget ⇒ authorize fails closed; no customer can
  be charged and no paid provider call can occur.
- `mig_344` + the edge's suppression take effect immediately and only **reduce** risk (a customer refresh can never
  auto-start the FastMoss/DataForSEO/CJ cascade); the usage instrumentation is telemetry only.
- Therefore the entire backend Stage B may be deployed now (deploy ≠ activate) with **zero cost exposure**. Paid
  behaviour begins only when the founder sets pricing + allowance + budgets (§7).

## 7. Remaining commercial approvals (founder-only; none assumed)

1. Subscription price for `ecommerce_monthly` (`amount_minor`, currently NULL).
2. Credits per refresh — `discovery_credit_price` (recommend 1).
3. Included allowance per period — `discovery_credit_allowance` (small single-digit, **≤ funded provider budget**).
4. Provider budgets per market — `provider_call_budget` (the hard $ cap; KALODATA fail-closed).
5. External unit prices (Kalodata / FastMoss / DataForSEO / CJ) — required for a real margin number; provider-account
   inputs, not internally recoverable.
6. Research-cascade policy on refresh — now **decoupled** (deep research runs only via the separate, separately
   authorized workflow); confirm it stays decoupled in beta.
7. Domain cutover (`strateloq.com` DNS + Lovable custom domain + Supabase Auth Site URL + Google OAuth origin) before
   publishing the branded frontend `c1a6afa`.

## 8. Genuine technical blockers

- **Backend Stage B: none.** Inert, integration-tested, reversible; safe to deploy in the §1 order on approval.
- **Frontend branded publish:** blocked only by the `strateloq.com` domain cutover (DNS not resolving yet) — a
  founder/DNS step, not a code defect. The refresh modal already ships to production in its "not activated" state.
- `mig_341b` requires `pg_cron` (available on the project; installed by the migration) — a prerequisite note, not a
  blocker.

**Release readiness: the package is ready.** Deploy order, dependencies, permissions, rollback, coexistence, and the
full lifecycle are proven. No further engineering review is required for the acceptance criteria that pass here.
Activation remains a founder commercial decision (§7).

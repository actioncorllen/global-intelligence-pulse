# Product Discovery — Refresh Cost & Customer-Credit Model Analysis (2026-11-09)

Evidence-based evaluation for the Refresh Discovery commercial model. **Analysis only — nothing deployed,
published, priced, or activated.** No paid provider calls were made; figures below are drawn from the live
architecture and records. **Verified** vs **Assumption** vs **MISSING** are labelled throughout.

Product = **Strateloq**; planned company = **Strateloq Technologies**.

---

## 1. Actual refresh execution path (VERIFIED from code)

One **Refresh Discovery** request = **exactly one paid provider call** at the discovery layer, plus a
*separately-governed* downstream research cascade:

1. `fn_discovery_refresh_authorize` consumes **one** `provider_call_budget` unit for `KALODATA` (fail-closed: no
   budget → no call).
2. `fn_discovery_refresh_fire` → the **existing `kalodata-discovery` edge** makes **one** Kalodata
   `tiktok/product/rank` call for the reserved **page** (`fn_kalodata_discovery_request`: `page_size = 10`,
   `page_number` from the per-tenant cursor — never re-buys page 1).
3. `fn_kalodata_ingest_candidates` keeps the product-native, de-duplicated subset (≤ `candidate_limit`, default
   10) and persists a **reference-only** cover.
4. **Per promoted candidate** it calls `fn_auto_dispatch_candidate_research` → `fn_research_request_core(...,
   'auto_fresh_discovery')` — a **deep-research cascade** (FastMoss / DataForSEO / CJ via n8n) that is
   **independently budget-gated** by `provider_call_budget` (fail-closed) and can be suppressed.

**So the per-refresh cost has two layers:**
- **Direct (discovery):** 1 Kalodata rank call → up to ~10 new candidates. **Fixed, 1 call.**
- **Indirect (research cascade):** up to ~10 deep-research dispatches, each a separate budget-gated provider
  call. **Variable; 0 if research budgets are not authorized.** This is the dominant, variable cost lever.

### Answers to Priority-1 questions
| # | Question | Finding |
|---|----------|---------|
| 1 | Which providers per refresh? | **Kalodata** directly (1 call). FastMoss/DataForSEO/CJ only via the *optional, budget-gated* auto-research cascade. DataForSEO/FastMoss are **not** called by the refresh itself. |
| 2 | Paid requests per refresh? | **1 Kalodata** (authorize-gated) **+ up to N≈10** auto-research dispatches (one per promoted candidate), each separately budget-gated (N=0 if those budgets are off). |
| 3 | Verified cost per request? | **MISSING.** 0/68 `discovery_runs` recorded `provider_usage`; `provider_call_budget` meters **call counts, not dollars**; no $-per-call is stored. Kalodata/FastMoss/DataForSEO/CJ unit prices are external/contractual. |
| 4 | Products per refresh? | Up to **10 candidates** per page (`page_size 10`). **Customer-visible new ≈ 0 initially** — the mandatory image gate (mig_342) hides products until a display image resolves (new Kalodata products arrive image-less; images need separate paid CJ/supplier calls). |
| 5 | Country / pagination effect? | One page per refresh; the cursor advances per market (no re-buy). Cost per page is constant across markets (1 call). Unsupported market → **no paid call** (pre-charge, refunded). |
| 6 | Cached or new data? | The refresh **buys new** Kalodata rank data (next page). Ingest **de-dupes** against existing products; the downstream research cascade **reuses cached research** where available. |
| 7 | No new products? | A zero-new result is still a **provider-charged SUCCESS → settles** (consumes the credit). "Nothing new in this market" is a real, paid answer (not auto-refunded). |

---

## 2. Two models compared

**MODEL A — Subscription-included refresh credits (customer sees a balance; e.g. 5/period, 1/refresh).**
- Profitability: predictable **if** 1 credit maps to a known cost — but the per-refresh cost is variable (the
  research cascade), so a fixed credit ≠ fixed cost unless the cascade is decoupled. Credits bound the
  *discovery* calls well.
- CX: clear and familiar; some "credit anxiety"; a visible number to ration.
- Risk/abuse: strong — a hard per-customer ceiling; repeated refresh can't exceed the balance.

**MODEL B — Subscription access, internal cost controls only (no visible balance).**
- Profitability: protected by the **already-built** `provider_call_budget` (fail-closed call caps) — but cost
  per customer is less predictable without a per-customer ceiling tied to the plan.
- CX: best — no credits to think about.
- Risk/abuse: weaker at the UX layer — nothing tells/limits a user hammering refresh except the global budget;
  one heavy user can exhaust a shared budget.

**Hybrid — subscription + a small visible fair-use allowance, backed by internal provider budgets.**
- This is **what the prepared system already is**: customer credits (`mig_341`/`mig_341c`) layered **on top of**
  provider budgets (`provider_call_budget`, consumed at authorize). The customer sees a simple allowance; the
  provider budget is the **hard $ safety net** that no credit count can exceed (authorize fails closed without
  budget). Best balance of predictable margin, clear CX, and abuse prevention.

---

## 3. Profitability (FRAMEWORK — key inputs MISSING, not fabricated)

Margin per customer = **subscription price − (Kalodata calls × $/call) − (research dispatches × $/research)**.

- **Subscription price:** **MISSING** — the only plan (`ecommerce_monthly`) is COMP with `amount_minor = NULL`.
- **Kalodata $/rank call:** **MISSING** (not recorded).
- **Research cascade $/call (FastMoss/DataForSEO/CJ):** **MISSING** (not recorded).
- **Usage per customer:** **ASSUMPTION needed** (low/typical/high refreshes per period).

With all three cost/revenue inputs unknown, **a real margin number cannot be computed without fabricating** —
so none is given. What *is* verified: the architecture already **caps spend by call count per provider/market**
(fail-closed), so worst-case provider spend per customer is bounded by the authorized budgets regardless of the
model chosen. The sizing rule below makes margin safe even with unknown unit costs.

**Sizing rule (safe under unknown costs):** set each customer's **refresh credit allowance ≤ the provider-call
budget you fund for that customer per period**. Then credits can never authorise more paid calls than you have
funded, so provider spend per customer is capped at a number you choose — independent of the (still-unknown)
$-per-call. Decide the actual numbers once the unit costs + subscription price are known.

---

## 4. Recommendation — **Hybrid** (activate the prepared two-layer design)

**Recommend: subscription with a small visible refresh allowance (fair-use), backed by internal provider
budgets.** Concretely, for the initial launch:
- **What customers pay for:** a Strateloq subscription (market-intelligence access), which *includes* a bounded
  number of Product Discovery refreshes per period.
- **What research is included:** each refresh = one Kalodata discovery page (up to ~10 new candidates). Deep
  per-product research (the cascade) should be **decoupled** from the refresh credit and governed by internal
  provider budgets (invisible), or offered on-demand per product — so "1 refresh credit" maps to a single,
  predictable discovery call, not an unbounded research fan-out.
- **Do customers see credits?** Yes — a small, clear allowance (the prepared modal already shows required vs
  available credits and a clean "not activated" state). Credits are a **fair-use ceiling**, framed as "included
  refreshes", not a metered wallet.
- **How Strateloq protects margin:** the hard floor is `provider_call_budget` (fail-closed, call-count caps per
  provider/market), consumed at `authorize`. The credit allowance is set ≤ funded budget (§3 rule). The
  research cascade is separately budgeted. Zero-new still consumes a credit (paid answer), preventing free
  probing.
- **How repeated searches are controlled:** idempotent reserve (double-click safe), one provider call per
  request (`dispatched_at`), the per-period credit allowance, and the provider budget behind it.
- **Scaling to paid customers:** when real unit costs + a subscription price are known, set the allowance from
  the §3 rule and raise provider budgets per market; the ledger + reconcile + sweep already handle
  grants/settlement/refunds/renewals idempotently.

**Proposed refresh limits + justification:** keep the evaluation example's shape — **1 credit per successful
refresh**, allowance a **small single-digit number per period** (the founder sets the exact figure from the
sizing rule, not invented here). Justification: a single-digit allowance is enough for genuine
founding-member research cadence, maps 1:1 to funded Kalodata calls, and bounds worst-case spend per customer
to a known, funded number even while $-per-call is unverified.

---

## 5. Remaining provider-cost evidence needed (to finish profitability)
- **Kalodata** $ per `tiktok/product/rank` call (invoice / contract / dashboard).
- **FastMoss / DataForSEO / CJ** $ per call for the research cascade.
- The **`ecommerce_monthly` subscription price** (set `amount_minor` + `currency`).
- An agreed **usage assumption** (refreshes/customer/period: low/typical/high).
- Decision on whether a refresh should trigger the deep-research cascade in beta (the main variable cost), or
  defer it to on-demand per selected product.

## 6. Exact commercial decisions requiring founder approval
1. **Subscription price** for `ecommerce_monthly` (and any paid tiers).
2. **Credits per refresh** — recommend **1** (`discovery_credit_price`, currently empty).
3. **Included allowance per period** — a small single-digit number, **≤ the funded provider budget**
   (`discovery_credit_allowance`, currently empty).
4. **Provider budgets per market** (`provider_call_budget`) — the hard $ safety net, sized to funded spend.
5. **Research-cascade policy on refresh** — include (budget-capped) vs defer to on-demand per product.
6. Confirm the **beta refund policy** (verified post-charge technical failures refund the customer) stays.

Nothing here changes pricing or activates credits. All allowances/prices remain **unconfigured**; the prepared
engineering (`mig_341`/`mig_341b`/`mig_341c`, refresh-aware edge, unified frontend `c56e6e0`) is untouched, and
Product Asset Lock, country/tenant isolation, permitted-image gating, and founding-member-only access are
preserved.

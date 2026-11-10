# Refresh Discovery — Commercial Activation Readiness Plan (2026-11-09)

Stage B backend is DEPLOYED and fail-closed. This is the **exact configuration plan** to activate paid Refresh
Discovery when the founder approves. **Nothing here is applied. No price, allowance, budget, or paid call is
activated by this document.** Values marked `<FOUNDER: …>` are commercial decisions and are **not invented**.

See `PULSE-ECOM-REFRESH-COST-MODEL.md` for the evidence base and `PULSE-ECOM-STAGE-B-DEPLOYMENT-EXECUTED.md` for
the deployed state.

---

## A. Provider-pricing evidence still required (from the founder's accounts)

The system records **no $ cost** per provider call (verified: the Kalodata `tiktok/product/rank` response carries
no cost field; instrumentation now records call counts + provider credits, never dollars). To compute margin, the
founder must supply, from the provider accounts (not from the API):

1. **Kalodata** — $ per `tiktok/product/rank` call. The system does **not** store this and the connected account
   exposes only an API secret (no plan/billing/pricing metadata), so the founder supplies it from the Kalodata
   **dashboard / invoice / contract**. Exact fields needed (any one route gives the rate):
   - Plan name + **monthly plan price** + **currency** (Billing / Subscription page).
   - **Included API credits (or calls) per month** for that plan.
   - **Credits consumed by the `tiktok/product/rank` endpoint** per call (Kalodata API credit table).
   - **Overage rate** ($ per extra credit/call beyond quota), if the plan bills overage.
   Then effective $/rank call `K` = `(plan_price ÷ included_credits) × credits_per_rank_call` within quota, or the
   overage rate for calls beyond quota. **This is the only provider needed for the refresh itself.**
2. **Subscription price** — the intended `ecommerce_monthly` price (currency + amount). Currently COMP /
   `amount_minor = NULL`.
3. **(Only if deep research is later bundled into refresh — currently DECOUPLED, so NOT required now)**
   FastMoss / DataForSEO / CJ $ per call.
4. **Usage assumption** — expected refreshes per customer per period (low / typical / high).

Until #1 and #2 are supplied, a real margin number cannot be computed and must not be fabricated.

## B. Exact configuration plan (applied ONLY on explicit founder approval, with real values)

All four are small, reversible config inserts. The **sizing rule** binds worst-case spend: set the per-customer
**allowance ≤ the funded provider-call budget**, so credits can never authorise more paid calls than funded —
independent of the (still-unknown) $-per-call.

### B1. Subscription price (`ecommerce_monthly`)
The plan row already exists per tenant in `account_entitlement`. To set a real price on a paid plan:
```sql
-- <FOUNDER: currency ISO code, amount in minor units e.g. 4900 = €49.00>
UPDATE public.account_entitlement
   SET currency = '<FOUNDER: EUR>', amount_minor = <FOUNDER: 4900>
 WHERE plan_code = 'ecommerce_monthly' AND status IN ('ACTIVE','COMP','TRIALING');
-- (Billing collection itself is a separate provider integration; this only records the price.)
```

### B2. Credits per refresh (`discovery_credit_price`) — recommend 1
```sql
-- market NULL = default for every market; add market-specific rows only if pricing differs by market.
INSERT INTO public.discovery_credit_price (market, credits_per_refresh, active, note)
VALUES (NULL, <FOUNDER: 1>, true, 'activation <date>');
```

### B3. Included subscription allowance (`discovery_credit_allowance`) — small single-digit, ≤ funded budget
```sql
-- plan_code NULL = any active plan; credits_per_period is the included refreshes per subscription period.
INSERT INTO public.discovery_credit_allowance (plan_code, credits_per_period, source, active, note)
VALUES (NULL, <FOUNDER: 5>, 'SUBSCRIPTION', true, 'activation <date>');
-- After this, each active subscriber receives the allowance once per period via the hourly sweep
-- (discovery-subscription-credit-sweep) or on-demand fn_discovery_grant_subscription_credits().
```

### B4. Provider call budgets (`provider_call_budget`) — the hard $ safety net, per tenant + market
```sql
-- One row per (tenant, market) you authorise. max_calls caps paid Kalodata calls; fail-closed without it.
-- Set max_calls >= the allowance (B3) for a normal customer, OR deliberately lower to cap spend tighter.
INSERT INTO public.provider_call_budget (provider, user_id, market, approval_key, max_calls, active, expires_at)
VALUES ('KALODATA', '<FOUNDER: tenant auth_user_id>', '<FOUNDER: DE>', 'activation-<date>',
        <FOUNDER: 5>, true, <FOUNDER: now()+interval '30 days' OR NULL>);
```

**Activation order:** B2 (price per refresh) → B3 (allowance) → B4 (provider budget). B1 (subscription price)
independently. Each is a single row; deactivate by `active=false` to roll back instantly.

## C. One bounded live integration test (smallest safe real test; founder-approved)

Purpose: prove the full paid path end-to-end with a **hard cap of one Kalodata call** (worst-case spend = 1 paid
rank call). Run against ONE founder-owned tenant in ONE market.

1. Configure, scoped to the founder test tenant only:
   - `discovery_credit_price`: 1 credit/refresh (active).
   - `discovery_credit_allowance`: grant the test tenant **exactly 1** credit (either a 1-credit allowance, or a
     single direct GRANT ledger row for that tenant).
   - `provider_call_budget`: KALODATA, the test tenant, test market, **`max_calls = 1`** (the hard cap).
2. As the test tenant, run the live flow: `fn_discovery_refresh_quote` (expect `can_refresh=true`) →
   `fn_discovery_refresh_reserve` → `fn_discovery_refresh_authorize` (consumes the 1 budget unit) →
   `fn_discovery_refresh_fire` (invokes the edge; **one** paid Kalodata call) → edge ingests + settles via
   `fn_discovery_refresh_complete_from_edge` → `fn_discovery_refresh_status`.
3. Verify: exactly **one** Kalodata call occurred (provider budget `consumed_calls = 1`, no second call possible —
   `max_calls=1`); the `discovery_runs.raw_contract.provider_usage` row recorded the call (instrumentation);
   **no** FastMoss/DataForSEO/CJ research fired (customer-refresh suppression); the credit settled (SETTLED,
   1 credit used) or refunded per outcome; the Explorer image gate split (visible vs pending) is correct.
4. After review, deactivate the test config (`active=false`) or let the budget expire. A second refresh by the
   same tenant is impossible until the budget is topped up — bounding the test to a single paid call.

**Guardrails during the test:** no allowance beyond the single test credit; provider budget capped at 1; research
cascade stays decoupled; tenant/country isolation and Product Asset Lock unchanged.

## D. What stays fail-closed until A + B are done

With pricing/allowance/budget unset (current production state): `fn_discovery_refresh_quote` returns
`can_refresh=false` (`PRICING_NOT_CONFIGURED`), `reserve` is denied, no credits exist, no paid call is possible,
and the customer modal shows the "not activated" state. The scheduled jobs remain no-ops. Nothing is customer-
facing or cost-bearing.

## E. Decisions requiring founder approval (summary)

1. Kalodata $-per-call evidence (A1) and subscription price (A2).
2. Credits per refresh (B2, recommend 1).
3. Included allowance per period (B3, ≤ funded budget).
4. Provider budgets per market (B4).
5. Go / no-go on the single bounded live test (C).
6. Keep the deep-research cascade decoupled from refresh in beta (recommended).

## F. Kalodata cost evidence + projected provider cost (2026-11-10 scan)

**Kalodata monetary pricing CANNOT be established from available authorised information.** Re-confirmed today:
no `$`/cost/price/amount column holds a Kalodata rate anywhere (the only cost-named column is
`discovery_refresh_request.credits_cost`, which is CUSTOMER credits, not money); 0 `discovery_runs` carry
`provider_usage`; the rank API returns no per-call cost; there is no Kalodata billing connector in this
environment. The $-per-`tiktok/product/rank` call must come from the founder's Kalodata account (invoice /
dashboard / contract).

**Projected provider cost (parametric — keep PROVIDER spend separate from CUSTOMER credits):**
- Let `K` = Kalodata $ per rank call (founder-supplied, currently UNKNOWN).
- Worst-case PROVIDER spend per customer per period ≤ `funded max_calls × K` (the hard, fail-closed ceiling).
- With the sizing rule (allowance ≤ funded `max_calls`), CUSTOMER refreshes can authorise at most `max_calls`
  paid calls, so customer-driven provider spend per period ≤ `max_calls × K`.
- CUSTOMER-facing "included refreshes" (credits/allowance) are an entitlement counter and are **not** money; they
  never appear in provider billing. Provider $ spend is governed solely by `provider_call_budget` × `K`.
- A concrete margin/projection figure is deferred until `K` and the subscription price are supplied; it is not
  invented here.

**Bounded live test cost ceiling:** with `provider_call_budget.max_calls = 1` for one test tenant/market, the
single bounded live research test (§C) costs at most **one** Kalodata rank call = `1 × K`; no second paid call is
possible and no deep-research cascade fires.

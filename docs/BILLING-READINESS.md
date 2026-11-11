# STRATELOQ — Real-Customer Billing Readiness

Date: 2026-11-11. Scope: prepare (not activate) genuine live-card collection and paid-membership
purchase/activation, preserving all production enforcement, the test/live card separation, and
surpyjabu's COMP €0 entitlement. **No live charging, paid plans, provider budgets, subscriptions, or
payment-UI publish are activated here — each remains a separate founder approval.**

> **DO NOT mark paid-customer onboarding ACCEPTED.** The COMP onboarding state machine works, but
> **paid-membership collection and entitlement activation are UNTESTED** (no checkout initiation is
> deployed and no Stripe price is configured). See the acceptance note at the end.

---

## 1. Current status (verified live)

| Item | State |
|---|---|
| Onboarding enforcement (`enforcement_active`) | ON (unchanged) |
| Card enforcement (`card_enforcement_active`) | ON, TEST mode (unchanged) |
| Live-card requirement (`require_live_card`, mig_359) | OFF / inert (no lockout) |
| Stripe mode | TEST only (`sk_test_`); `STRIPE_LIVE_ALLOWED` unset |
| Stripe account activation | **NOT done** — `charges_enabled=false`, `details_submitted=false` |
| Entitlements | COMP × 3 at €0 (surpyjabu + 2) — untouched |
| `discovery_credit_allowance` | EMPTY (no auto credit grant; research credits stay separately prepaid) |
| Provider budgets / wallet prices | 0 active (inert) |
| Leftover test edges `zz-stripe-diag`, `zz-wallet-test-session` | RETIRED (HTTP 410 stubs) |

---

## 2. Remaining founder-side Stripe activation actions (EXTERNAL — blocks genuine card + paid membership)

These are outside Strateloq and only the founder can do them, **in order**:

1. **Activate the Stripe account.** In the Stripe Dashboard, complete business details + identity
   verification until the account shows `details_submitted=true` and `charges_enabled=true`.
2. **Create the live API key.** Generate the LIVE secret key (`sk_live_…`). Do **not** paste it into
   chat — set it as the `STRIPE_SECRET_KEY` edge secret for the live path (controlled; not a blind
   swap of the test key — keep the ability to roll back to test).
3. **Create the live webhook endpoint.** In Stripe (Live mode) add a webhook endpoint pointing at the
   deployed `stripe-webhook` function URL. Subscribe at minimum to:
   `checkout.session.completed`, `payment_method.detached`,
   `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`,
   `invoice.paid`, `invoice.payment_failed`.
   Copy its **live signing secret** into `STRIPE_WEBHOOK_SECRET` for the live path.
4. **(Paid membership only) Create the recurring price.** In Stripe, create the membership Product +
   recurring Price (the founder defines amount, currency, interval, trial). Set its price id as the
   `STRIPE_MEMBERSHIP_PRICE_ID` edge secret. **Strateloq invents none of these values.**
5. **Flip the live gate.** Set `STRIPE_LIVE_ALLOWED='true'` only after 1–4 are verified.

> Until 1–3 are done, **do not ask surpyjabu (or any customer) to enter a real card.** Until 4 is
> done, no paid membership can be collected.

---

## 3. Safe live-card integration checklist (verify each before inviting real cards)

- [ ] Stripe account `charges_enabled=true`, `details_submitted=true`.
- [ ] `STRIPE_SECRET_KEY` is a `sk_live_…` key on the live path; the test key is retained for rollback.
- [ ] `STRIPE_WEBHOOK_SECRET` is the **live** endpoint's signing secret; a signed live test event is
      accepted and an unsigned/forged one is rejected (400).
- [ ] `STRIPE_LIVE_ALLOWED='true'` — the webhook no longer ignores livemode events; `stripe-card-setup`
      no longer returns `LIVE_MODE_NOT_APPROVED`.
- [ ] Live card registration records `payment_method_registry.livemode=true` (mig_359 + webhook
      `p_livemode`).
- [ ] A **sandbox test card cannot** satisfy a live requirement: with `require_live_card=true`, a
      `livemode=false` card leaves the member `CARD_SETUP_REQUIRED` (proven by the mig_359 simulation).
- [ ] The **unactivated** live-card path fails closed with guidance, not a broken checkout:
      `stripe-card-setup` (v7) returns `LIVE_CARD_REQUIRED_NOT_AVAILABLE` when `require_live_card=true`
      but live mode is not ready — it never hands out a sandbox session that can't satisfy the rule.
- [ ] The founder has registered a **live** card BEFORE `require_live_card` is turned on (otherwise the
      founder locks themselves out — proven: a test-only card under `require_live_card` →
      `CARD_SETUP_REQUIRED`).
- [ ] Card setup cannot charge / top-up / subscribe: `stripe-card-setup` is `mode=setup` (€0, no
      PaymentIntent); `stripe-wallet-topup` needs an ACTIVE wallet price (none) and is onboarding-gated;
      membership checkout is a separate, undeployed function.
- [ ] No PAN/CVV/bank credentials are ever stored in Strateloq/Supabase — collection stays on Stripe's
      hosted page.

---

## 4. Paid-membership entitlement architecture — audit

**What already exists and is correct:**
- `account_entitlement` carries every Stripe field already: `source`, `provider`,
  `provider_customer_id`, `provider_subscription_id`, `billing_interval`, `currency`, `amount_minor`,
  `current_period_end`, `cancel_at_period_end`, `trial_end`. **No schema change needed.**
- `fn_entitlement_active(status, period_end)` = `status IN ('ACTIVE','COMP','TRIALING') AND
  (period_end IS NULL OR period_end > now())`. COMP = perpetual-active; paid = ACTIVE/TRIALING with a
  period end; everything else fails closed (no access).
- `fn_grant_founding_member_entitlement` (COMP path) **refuses to overwrite** a row with
  `source='PROVIDER'` or a non-null `provider_subscription_id` (guard + `ON CONFLICT … WHERE`), and is
  `no_payment_provider_call:true`. A paid subscription can never be clobbered by the COMP grant.
- `confirm_membership` gates on `fn_entitlement_active` + business + billing → onboarding is
  **identical** for COMP and paid customers; only *how* the entitlement became active differs.

**What was MISSING (the real-customer membership purchase/activation contracts):**
1. A **checkout initiation** path (no edge created a subscription Checkout Session).
2. **Webhook handlers** for subscription lifecycle events (none mapped Stripe → `account_entitlement`).
3. **Service-only activation RPCs** to write a PROVIDER-sourced entitlement idempotently.

**What is now PREPARED (inert — nothing fires until founder activation):**
- `mig_360` (APPLIED, service-only, dormant — no caller): `fn_psp_membership_activated(...)` and
  `fn_psp_membership_status(...)` + `fn_map_stripe_sub_status(...)`. All commercial values are
  **parameters supplied from the live Stripe objects** — no price/interval/term is hardcoded. Proven by
  a rolled-back simulation (zero residue): a synthetic subscription activated PROVIDER/ACTIVE; the COMP
  grant then returned `preserved` and did not clobber it; cancellation set `CANCELED`/inactive; the COMP
  peer (surpyjabu) was untouched.
- `supabase/functions/stripe-membership-checkout/index.ts` (**PREPARED, NOT DEPLOYED**): a subscription
  Checkout edge mirroring `stripe-card-setup`. Fails closed without `STRIPE_MEMBERSHIP_PRICE_ID`; reads
  the price from Stripe; refuses to charge an already-entitled (COMP) member (`ALREADY_ENTITLED`).
- `stripe-card-setup` (v7, DEPLOYED): the `LIVE_CARD_REQUIRED_NOT_AVAILABLE` fail-closed guard (inert
  while `require_live_card=false`).

---

## 5. Webhook subscription handlers — PREPARED code (apply + redeploy at activation)

The deployed `stripe-webhook` currently handles card setup + wallet top-up. At paid-membership
activation, add these branches (service-only, idempotent via the existing `fn_psp_webhook_begin`
event-dedupe) and redeploy. They call the `mig_360` RPCs. **Not applied yet** to avoid changing the
live webhook before the founder approves paid membership.

```ts
// Inside Deno.serve, in the eventType switch, ADD:

if (eventType === "checkout.session.completed") {
  // ... existing mode==="setup" and mode==="payment" branches stay ...
  const mode = String(obj.mode ?? "");
  const uid = String(obj.client_reference_id ?? "");
  if (mode === "subscription" && uid) {
    const subId = String(obj.subscription ?? "");
    if (!subId) { await finish("sub_missing"); return json(200, { ok: true }); }
    const sub = await stripeGet(`subscriptions/${subId}?expand[]=items.data.price`);
    const item = (((sub.items as Record<string, unknown>)?.data as unknown[])?.[0] ?? {}) as Record<string, unknown>;
    const price = (item.price ?? {}) as Record<string, unknown>;
    const recurring = (price.recurring ?? {}) as Record<string, unknown>;
    const r = await rpc("fn_psp_membership_activated", {
      p_auth_user_id: uid,
      p_provider_customer_ref: String(sub.customer ?? obj.customer ?? ""),
      p_provider_subscription_id: subId,
      p_stripe_status: String(sub.status ?? ""),
      p_plan_code: String((price.lookup_key ?? (price.metadata as Record<string, unknown>)?.plan_code) ?? ""),
      p_billing_interval: String(recurring.interval ?? ""),
      p_currency: String(price.currency ?? ""),
      p_amount_minor: Number(price.unit_amount ?? 0) || null,
      p_current_period_end: sub.current_period_end ? new Date(Number(sub.current_period_end) * 1000).toISOString() : null,
      p_cancel_at_period_end: sub.cancel_at_period_end === true,
      p_trial_end: sub.trial_end ? new Date(Number(sub.trial_end) * 1000).toISOString() : null,
    });
    await finish(`membership_activated:${(r as Record<string, unknown>)?.status}`);
    return json(200, { ok: true, handled: "membership" });
  }
}

if (eventType === "customer.subscription.updated" || eventType === "customer.subscription.deleted") {
  const r = await rpc("fn_psp_membership_status", {
    p_provider_subscription_id: String(obj.id ?? ""),
    p_stripe_status: String(obj.status ?? ""),
    p_current_period_end: obj.current_period_end ? new Date(Number(obj.current_period_end) * 1000).toISOString() : null,
    p_cancel_at_period_end: obj.cancel_at_period_end === true,
  });
  await finish(`membership_status:${(r as Record<string, unknown>)?.status}`);
  return json(200, { ok: true, handled: "membership_status" });
}
// Optional: invoice.paid -> re-activate/extend via fn_psp_membership_activated on renewal;
//           invoice.payment_failed -> fn_psp_membership_status(..., 'past_due').
```

---

## 6. Minimum implementation milestones before inviting real paying members

Ordered; each is a founder-gated step. TEST mode first throughout.

1. **Founder Stripe activation** — §2 steps 1–4 (account live, live key, live webhook secret, recurring
   price created). *External.*
2. **Deploy the webhook subscription handlers** (§5) + redeploy `stripe-webhook`. Still inert without a
   checkout path.
3. **Deploy `stripe-membership-checkout`** and set `STRIPE_MEMBERSHIP_PRICE_ID` (TEST price first).
4. **Wire the onboarding UI** (Lovable, preview) — at `ENTITLEMENT_REQUIRED`, a "Start membership"
   action calling `stripe-membership-checkout`; COMP members skip it. **No publish without approval.**
5. **TEST-mode E2E acceptance** (§7) — prove purchase → webhook → ACTIVE entitlement → membership
   confirmation → workspace, plus renewal and cancellation.
6. **Live-card safeguards** — §3 checklist, including the founder registering a live card and only then
   considering `require_live_card=true`.
7. **Controlled live pilot** — invite one real paying member; verify a genuine charge + ACTIVE
   entitlement before general invitations. *Separate founder approval.*

---

## 7. Test plan (paid membership)

Run in Stripe **TEST** mode (test cards), founder-authorised, one member at a time:

1. **Purchase success** → `checkout.session.completed (subscription)` → webhook →
   `account_entitlement` becomes `source=PROVIDER, status=ACTIVE`, with `provider_subscription_id`,
   `current_period_end`, `amount_minor`, `currency`, `billing_interval` from Stripe.
2. **Idempotency** → replay the same event → no duplicate/role change (`fn_psp_webhook_begin` dedupe +
   `ON CONFLICT (auth_user_id)`).
3. **Onboarding identical** → the paid member passes `confirm_membership` on the same checks as COMP;
   workspace access via the same gates/RLS.
4. **COMP preserved** → run `fn_grant_founding_member_entitlement` against the paid member → `preserved`
   (no clobber); surpyjabu stays COMP/€0.
5. **Renewal** → `invoice.paid` / `customer.subscription.updated` extends `current_period_end`, stays
   ACTIVE.
6. **Cancellation** → `customer.subscription.deleted` → `status=CANCELED`; after period end
   `fn_entitlement_active=false` → workspace access correctly withdrawn.
7. **Failed payment** → `invoice.payment_failed` → `status=PAST_DUE` (inactive); define any grace term
   as a founder decision (none invented here).
8. **No cross-tenant leak** → the activated member sees only their own tenant (RLS unchanged).
9. **Live verification (final, after §2)** → one real charge with a genuine card; confirm money moved in
   Stripe and the entitlement is ACTIVE — the acceptance that COMP €0 can never prove.

---

## 8. Acceptance note (do NOT overstate)

- **Genuine-card registration:** BLOCKED — external (Stripe account not activated). Infrastructure
  prepared + proven; no customer may enter a real card yet.
- **Paid-membership transaction + entitlement activation:** **NOT ACCEPTED — UNTESTED.** The data-layer
  contracts (mig_360) and a prepared checkout edge exist and simulate correctly, but no real (or TEST)
  purchase has been collected, no checkout path is deployed, and no price is configured. The working
  COMP state machine is **not** evidence that paid collection works.
- **COMP founding member (surpyjabu):** preserved at €0, identical core onboarding; no conversion to
  paid.

## Rollback / safety
- mig_360 functions are dormant (no caller) and service-only; dropping them changes nothing live.
- `stripe-card-setup` v7 guard is inert while `require_live_card=false`; reverting to v6 is safe.
- `stripe-membership-checkout` is not deployed; it cannot run until explicitly deployed + priced.
- No change to `enforcement_active`, `card_enforcement_active`, RLS, COMP entitlements, or the
  deployed `stripe-webhook`.

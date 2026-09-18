# STRATELOQ-ECOM-PAID-ACCESS-ARCHITECTURE-AUDIT-012

**Audit only — €0, no data/schema/RLS/Lovable changes. FINAL VERDICT: `BLOCKED_EXTERNAL_PAYMENT_PROVIDER_SETUP`**
(the design is ready; the external payment-provider account/config is the gating dependency).

The system today has **no paid-entitlement concept at all** — workspace access is gated only by
controlled-beta invitation + email verification + discovery readiness. Payment success would currently
be un-enforceable server-side. This audit specifies the smallest safe entitlement architecture, reusing
the existing auth/member/invitation/webhook patterns, and names the external dependency and founder
decisions. No Stripe implemented.

---

## CURRENT STATE (verified in production, read-only)

**1. Auth/account model.** Supabase Auth (`auth.users`) is the durable identity. `public.member`
(`auth_user_id` FK, `email`, `email_verified`, `welcome_seen`, `account_status`, `application_ref`)
binds the auth user to the tenant. `account_status` is presently single-valued (`active` ×5). auth.uid()
drives all ownership/RLS.

**2. Email-verification enforcement.** `member.email_verified` boolean exists; Supabase Auth confirms
email (`auth.users.email_confirmed_at`). Verification is tracked but is **not** an entitlement.

**3. Member/business ownership.** `business_profiles(user_id, application_id)`, `commerce_product_pages
(user_id)`, `product_opportunity_decisions(tenant_id)`, `discovery_state(member_id)` — all keyed to the
auth user / member. RLS on the sensitive tables is deny-all-to-clients; reads go through SECURITY DEFINER
RPCs tenant-scoped by `auth.uid()`.

**4. Onboarding handoff.** `founding_applications` (first/last name, work_email, company, country,
industry, role, company_size, primary_goal, use_case, status, source — 6 rows) is the pre-account
application; `invitation` (token_hash, bound_email, application_ref, expires_at, status, consumed_at)
binds an application to a login; `accept-invitation` / `issue-invitation` / `issue-open-invitation`
edge functions run the grant lifecycle; business is created as `business_profiles` at onboarding.

**5. Workspace authorization/readiness gate.** `get_own_discovery_intelligence()` — the /workspace gate —
resolves readiness solely from `discovery_state.analysis_status = 'ready'`. **There is no entitlement
check anywhere in the workspace or publish path.**

**6. Invitation/controlled-beta model.** Token-based, email-bound, expiring, revocable (`invitation.status`:
issued/consumed/revoked). This is the current access-control mechanism and a good reuse pattern for comp/beta.

**7. Billing/payment/subscription tables.** **None.** No subscription, billing, payment, entitlement,
plan, invoice, checkout, price, or membership-tier table exists.

**8. Stripe integration.** **None.**

**9. Webhook infrastructure.** No payment webhook. But a reusable pattern exists: `meta-capi-adapter`
(edge function receiving external POSTs) and the storefront/invitation edge functions show the project
already deploys signature/secret-verified, service-role-backed HTTP boundaries.

**10. Entitlement/access-control concepts today.** Only: invitation grant + `email_verified` +
`discovery_state` readiness. No paid gate.

---

## TARGET STATE

Enforce, server-side, the locked journey: verified account **AND active entitlement** (**AND** readiness)
⇒ Ecommerce Workspace. Verified-but-unpaid ⇒ pricing/payment. Returning paid ⇒ workspace. Cancelled/
expired/failed ⇒ auth still valid, **data preserved**, workspace access per an inactive-subscription policy
(to be decided). Entitlement is established only by the payment provider → webhook → server; never by the
browser.

---

## GAPS

1. No entitlement store. 2. No server-side entitlement RPC. 3. Workspace gate doesn't consult entitlement.
4. No checkout-session creation boundary. 5. No payment webhook boundary. 6. No plan/price catalogue.
7. No inactive-subscription access policy. 8. No comp/internal entitlement for founder/test tenants (they
must never be locked out once the gate goes live).

---

## REUSE (no rebuild)

- **Auth/member/business ownership** and the `auth.uid()`-scoped SECURITY DEFINER RPC + deny-all-RLS pattern.
- **Edge-function webhook pattern** (`meta-capi-adapter`) for the Stripe webhook; **edge-function + service_role** pattern for a checkout-session creator.
- **Invitation/controlled-beta** model for comp/beta entitlements (founder, test, hand-comped accounts) — bypass payment without weakening the paid gate.
- **`get_own_discovery_intelligence` readiness gate** — compose entitlement into it (or a sibling `fn_workspace_access`), rather than a new parallel gate.

---

## REQUIRED NEW COMPONENTS

**Database (additive migration):**
- `commerce_entitlement` (or `account_entitlement`): `auth_user_id` (PK/unique, durable key), `member_id`,
  `plan`, `status` (`active|trialing|past_due|canceled|expired|comp`), `source` (`stripe|comp|beta`),
  `provider_customer_id`, `provider_subscription_id`, `current_period_end`, `cancel_at_period_end`,
  `trial_end`, `created_at`, `updated_at`. RLS: **deny-all to clients** (read only via RPC); writable only
  by service_role (webhook). An append-only `entitlement_event` audit table for webhook idempotency
  (provider event id unique).
- `plan_catalogue` (optional): plan code → display, provider price id, limits.

**Server functions/RPCs (SECURITY DEFINER, `search_path=''`, authenticated + service_role):**
- `fn_entitlement_status()` → `{ active, plan, status, current_period_end, in_grace }` for `auth.uid()`
  (no provider ids/secrets leaked).
- `fn_workspace_access()` (or extend `get_own_discovery_intelligence`) → composes
  `email_verified AND entitlement_active AND discovery_ready`, returns an explicit reason
  (`NEEDS_PAYMENT | NEEDS_VERIFICATION | PREPARING | READY`).
- `fn_apply_entitlement_event(provider_payload)` — service_role only, idempotent by provider event id;
  the ONLY writer of entitlement (called by the webhook).

**Webhook boundary (edge function, `verify_jwt=false`, signature-verified):**
- `stripe-webhook`: verifies the Stripe signature with the signing secret (server env), then calls
  `fn_apply_entitlement_event` with service_role. Never trusts the browser.

**Checkout boundary (edge function, `verify_jwt=true`):**
- `create-checkout-session`: authenticated user → creates a provider Checkout Session for the chosen plan,
  returns the redirect URL. Secret key stays server-side.

**Frontend states (Lovable, later — not this unit):** pricing/plan select, "redirecting to checkout",
"payment processing", active/paid, `past_due`/grace banner, expired/canceled → pricing, verification
pending. The frontend **displays** entitlement from `fn_entitlement_status`; it never grants it.

---

## SECURITY MODEL

- **Entitlement is server-established only.** Browser state is display-only. The webhook (signature-verified)
  + `fn_apply_entitlement_event` (service_role, idempotent) are the sole writers.
- Entitlement table **deny-all RLS**; clients read a minimal projection via `fn_entitlement_status`
  (no `provider_customer_id`/`provider_subscription_id`/secrets exposed).
- Stripe **secret key** and **webhook signing secret** live only in edge-function env (never in Lovable/browser,
  never in the repo, never service_role to the browser).
- No RLS weakened; ownership continues to key off `auth.uid()`.
- Webhook idempotency + signature verification prevent forged/duplicate entitlement.

## ENTITLEMENT MODEL

Bind entitlement to **`auth_user_id`** (durable; survives email/member profile changes), with `member_id`
denormalised for reporting. `active` iff `status ∈ {active, trialing, comp}` and (`current_period_end` in
future or comp). The workspace gate = verified **AND** active-entitlement **AND** ready. Cancel/expiry sets
`status` accordingly but **never deletes** business/storefront/decision data.

## EXTERNAL DEPENDENCIES → `BLOCKED_EXTERNAL_PAYMENT_PROVIDER_SETUP`

A payment provider account + configuration is required before checkout/webhook units can be built:
- **Provider account** (Stripe, or a Merchant-of-Record like Paddle/Lemon Squeezy — see decisions).
- **Products/Prices** for each plan (+ trial config if any).
- **API keys**: publishable (browser) + secret (edge-function env only).
- **Webhook endpoint + signing secret** (for the `stripe-webhook` edge function).
- **Business/tax details** for the provider (VAT/GST — GB/EU relevant).
Claude cannot create these; they need the founder. No paid resource created in this audit.

## FOUNDER DECISIONS REQUIRED

1. **Provider:** Stripe (you handle EU/GB VAT + Stripe Tax) **vs** Paddle / Lemon Squeezy (Merchant of
   Record — they handle VAT/invoicing; simpler for a UK founder selling into the EU). This choice shapes
   the webhook/checkout contract.
2. **Plans & pricing:** tiers, currency, billing interval(s).
3. **Trial:** none / card-required trial / no-card trial + length.
4. **Inactive-subscription workspace policy:** hard-lock (data preserved, workspace hidden until re-sub) vs
   read-only vs grace period of N days. (Locked target says "follow the eventual product policy" — this is
   the decision to make.)
5. **Comp/beta entitlements:** confirm founder + isolated test tenants get a permanent `comp` entitlement
   so they are never locked out.

## MIGRATION STRATEGY (preserves founder/test tenants)

Additive only. On introducing the entitlement table, **backfill a `comp` entitlement** for the existing
internal/test/founder tenants (member `4bc6b405` = `actioncorllen@gmail.com`, the demo tenant, etc.) so the
gate never locks them out. No existing data deleted or moved; RLS additive; the workspace gate is switched to
consult entitlement only after comp backfill is verified.

## IMPLEMENTATION SEQUENCE (recommended)

1. **012A — Entitlement foundation (no external dep):** entitlement + event tables, RLS, `fn_entitlement_status`,
   `fn_apply_entitlement_event` (idempotent), `fn_workspace_access` composition, comp backfill for internal/test
   tenants, selftests. Ships and is testable with `comp` entitlements before any payment provider exists.
2. **Founder: provider setup** (`BLOCKED_EXTERNAL_PAYMENT_PROVIDER_SETUP`) — account, plans/prices, keys, webhook secret.
3. **012B — Checkout boundary:** `create-checkout-session` edge function (needs secret key).
4. **012C — Webhook boundary:** `stripe-webhook` edge function (signature-verified) → `fn_apply_entitlement_event`.
5. **012D — Gate wiring + E2E:** switch /workspace + publish onto `fn_workspace_access`; prove paid/unpaid/expired
   with the isolated test tenant (comp + a real test purchase in provider test mode).
6. **Lovable (separate):** pricing + entitlement-aware routing, consuming `fn_entitlement_status`.

Units 1 and (4/5 wiring/tests) are safe in-house; 3 & 4 depend on the founder's provider setup.

---

## FINAL VERDICT
**`BLOCKED_EXTERNAL_PAYMENT_PROVIDER_SETUP`.** No paid-entitlement infrastructure exists today; the design
above (entitlement store + server RPC + signature-verified webhook + composed workspace gate, reusing the
existing auth/member/invitation/webhook patterns) is ready to build. Step 012A can proceed with zero external
dependency and comp entitlements; checkout/webhook require the founder to stand up a payment provider first.
No Stripe implemented, no Lovable change, no checkout started, no data modified, €0.

STOP.

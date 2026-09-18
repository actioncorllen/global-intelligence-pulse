# STRATELOQ-ECOM-PAID-ENTITLEMENT-FOUNDATION-012A

**VERDICT: `PASS`.** A provider-independent, server-authoritative paid-access entitlement
foundation is now live. It is additive only, RLS-hardened (browser can neither read nor write
entitlement), and composes the locked launch journey — **authenticated AND email-verified AND
active entitlement AND workspace-ready** — into one explicit access state. COMP entitlements were
granted to exactly the two internal accounts, each verified strictly by `auth.users` identity. No
payment provider, checkout, webhook, or fake payment was created. No existing user, business,
discovery, decision, storefront, or invitation data was modified. €0.

---

## 1. Scope delivered
Entitlement persistence bound to durable identity (`auth_user_id`), a pure active-predicate, a pure
access-state composer, an authenticated entitlement-status RPC, an authoritative workspace-access
RPC, COMP backfill for the two internal tenants, and a self-cleaning regression selftest. All in one
additive migration: `supabase/migrations/mig_239_paid_entitlement_foundation.sql`.

## 2. Locked V1 rules honoured
One paid plan (`ecommerce_monthly`), monthly interval, **no trial** granted. COMP for founder/internal
test tenants only. Authentication alone and email-verification alone do **not** grant access (proven in
tests B and C). Cancelled/expired retain data + business (never deleted; `fn_entitlement_active`
returns false for `EXPIRED`/`CANCELED` but the row and all tenant data persist). Inactive entitlement
blocks the paid workspace (`ENTITLEMENT_INACTIVE`). Customer data is never deleted by this unit.

## 3. Entitlement store
`public.account_entitlement` — one row per `auth_user_id` (UNIQUE `account_entitlement_user_uk`).
Provider-neutral columns: `plan_code`, `status`
(`ACTIVE|INACTIVE|EXPIRED|COMP|TRIALING|PAST_DUE|CANCELED`), `source` (`COMP|MANUAL|PROVIDER`),
`provider` / `provider_customer_id` / `provider_subscription_id` (NULL until a provider connects),
`billing_interval`, `currency`, `amount_minor`, `current_period_end` (NULL = perpetual for COMP),
`cancel_at_period_end`, `trial_end`, `granted_by`, `notes`, timestamps. Deliberately **no FK to
auth.users** — a provider webhook may create a customer row before/without a login, and user deletion
must not cascade-destroy billing history; a dangling row simply never matches a login.

## 4. RLS / client-inaccessibility
`ENABLE ROW LEVEL SECURITY` with **no policy** (deny-all) plus `REVOKE ALL ... FROM PUBLIC, anon,
authenticated`. The table is unreadable and unwritable by any browser role. All client access is
through SECURITY DEFINER projection RPCs. `service_role` (future webhook/backend) bypasses RLS to be
the sole writer.

## 5. Durable-identity binding
Entitlement keys off `auth_user_id` (the durable Supabase Auth identity), with `member_id`
denormalised for reporting. It survives `member.email` profile changes (the exact `+ecom`/`+demo`
alias problem reconciled in 010D/010E) because it never depends on a profile email string.

## 6. Functions (all SECURITY DEFINER / `SET search_path=''` where they touch data)
- `fn_entitlement_active(status, current_period_end)` — IMMUTABLE pure predicate: active iff
  `status ∈ {ACTIVE,COMP,TRIALING}` AND (`current_period_end` NULL or in the future).
- `fn_access_state(authenticated, email_verified, has_entitlement, entitlement_active, workspace_ready)`
  — IMMUTABLE pure composer returning exactly one of the six locked states.
- `fn_entitlement_status()` — authenticated projection for `auth.uid()`; returns
  `has_entitlement/active/plan_code/entitlement_status/source/billing_interval/current_period_end/
  cancel_at_period_end/trial_end`. **Never** returns provider customer/subscription ids or secrets.
- `fn_workspace_access()` — authoritative gate: gathers verification
  (`auth.users.email_confirmed_at` OR `member.email_verified`), entitlement activity, and
  `discovery_state.analysis_status='ready'`, then returns the composed `access_state`.

## 7. Access-state contract (returned states)
`AUTH_REQUIRED` → `EMAIL_VERIFICATION_REQUIRED` → `ENTITLEMENT_REQUIRED` → `ENTITLEMENT_INACTIVE`
→ `WORKSPACE_PREPARING` → `READY`, evaluated in that precedence. State only — no routing decisions,
no sensitive fields — the frontend renders from it but never grants from it.

## 8. Grants (least privilege)
`fn_entitlement_active`, `fn_access_state`, `fn_entitlement_status` → `authenticated` + `service_role`
(anon revoked). `fn_workspace_access` → `anon` + `authenticated` + `service_role` (anon only so it can
return `AUTH_REQUIRED`). `fn_paid_access_selftest` → `service_role` only. No RPC lets a client write
entitlement.

## 9. COMP accounts — verified strictly by auth.users identity
Exactly two, each confirmed against `auth.users` (id + `email_confirmed_at`), **not** inferred from any
`member.email` string and **not** any `+ecom`/`+demo` alias:
- `7c8ddf9d-172c-4a89-a402-bb7066228b61` — `auth.users.email = actioncorllen@gmail.com` (founder /
  internal Ecommerce test tenant, member `4bc6b405`).
- `80f4875a-4e5d-4fd9-aa22-ea37fe59d15d` — `auth.users.email = support@globalintelligenceactions.com`
  (internal demo/support, company domain, member `dae30000-…-0a02`).
Both COMP, perpetual (`current_period_end` NULL), `granted_by='012A internal COMP backfill'`,
idempotent (`ON CONFLICT (auth_user_id) DO NOTHING`). **Zero** COMP or any entitlement granted to any
real/ambiguous customer account (census confirms `non_comp_rows=0`, `total_rows=2`).

## 10. Invitation-model audit conclusion
The existing `invitation` model is **eligibility to create an account**, not paid entitlement.
Overloading its token/status to also mean "paid" would create ambiguous, hard-to-revoke authorization
and couple beta access to billing. Decision: a **dedicated** entitlement primitive, leaving invitation
untouched. No invitation column, token, or status was modified (invitations total unchanged at 11).

## 11. Deferred: `entitlement_event`
The append-only webhook-idempotency table is **deferred to the webhook unit (012C)**. Its sole purpose
is de-duplicating external provider events, which do not exist yet; adding it now would be dead,
unexercised surface. Documented in the migration header for traceability.

## 12. Selftest result (`fn_paid_access_selftest`, service_role)
**17/17 PASS, 0 fail.** Composer states A/B/C/D/G/EF; active-predicate cases
(comp-perpetual active, active-future active, active-past inactive, expired inactive, inactive
inactive, canceled inactive); synthetic cross-row isolation (row A active, row B inactive,
one-row-per-user); and both internal COMP tenants active. Synthetic rows self-deleted; suite leaves no
residue.

## 13. Live impersonation tests (A–L)
| Test | Subject | Result | Verdict |
|---|---|---|---|
| A — anonymous | role `anon` | `fn_workspace_access` → `AUTH_REQUIRED`, `authenticated=false` | PASS |
| B — auth, not verified | composer | `EMAIL_VERIFICATION_REQUIRED` (selftest B) | PASS |
| C — verified, no entitlement | `cleantechbusiness` (verified + ready) | `ENTITLEMENT_REQUIRED`, `has_entitlement=false` | PASS |
| D — entitlement inactive | composer + predicate (EXPIRED/CANCELED/past-period) | `ENTITLEMENT_INACTIVE` / active=false | PASS |
| E/F — active (COMP) | founder `7c8ddf9d` | `READY`; entitlement `COMP` active | PASS |
| G — workspace preparing | composer | `WORKSPACE_PREPARING` (selftest G) | PASS |
| H — cross-tenant isolation | `actionncube67` `1b0fa0a6` | sees only own (`has_entitlement=false`); cannot see founder COMP | PASS |
| I — self-grant denial | authenticated INSERT/UPDATE/SELECT on `account_entitlement` | all `42501 permission denied` | PASS |
| J — no provider-id leak | `fn_entitlement_status` projection | no `provider_customer_id`/`provider_subscription_id`/secret in output | PASS |
| K — storefront regression | runtime/publish/branding/lifecycle | **65/65** unchanged | PASS |
| L — data preserved | full census | members 5 / businesses 6 / pages 2 / decisions 24 / invitations 11 unchanged | PASS |

Notes: C is the strongest ENTITLEMENT_REQUIRED proof — a tenant that satisfies *every* other gate
(authenticated, verified, workspace ready) is still blocked purely for lack of a valid entitlement,
i.e. auth+verification alone genuinely do not grant paid access. H proves the projection is
`auth.uid()`-scoped: a different tenant reads its own absent entitlement, never another's COMP.

## 14. Browser cannot grant or alter entitlement
Proven by test I: with `role authenticated` and a valid JWT sub, direct `INSERT`, `UPDATE`, and even
`SELECT` on `account_entitlement` all fail with `42501 permission denied for table
account_entitlement`. The only mutation path is `service_role` / SECURITY DEFINER (backend/webhook),
never the client.

## 15. Storefront regression
Runtime **38**, publish **9**, branding **8**, lifecycle **10** = **65/65 PASS**, zero failures —
identical to the pre-unit baseline. Publish authorization, Product Decision, Business Discovery, and
intelligence logic were not touched.

## 16. Security-advisor delta
**5 → 5 (no increase).** The set is the unchanged baseline: `extension_in_public`,
`anon_security_definer_function_executable`, `authenticated_security_definer_function_executable`,
`auth_leaked_password_protection` (all WARN), and `rls_enabled_no_policy` (INFO). The new
`account_entitlement` deny-all table falls under the pre-existing `rls_enabled_no_policy` category
(the same intentional deny-all-RLS pattern used across the sensitive tables) and adds no new advisory.

## 17. Data-preservation proof
`account_entitlement` holds exactly 2 rows, both COMP/perpetual/`012A internal COMP backfill`, for the
two internal auth ids only; `non_comp_rows=0`. Existing data unchanged: members 5, businesses 6,
storefront pages 2 (founder `ae458526` present), product decisions 24, invitations 11. No user,
business, discovery, decision, storefront, or invitation row was created, altered, or deleted.

## 18. What was NOT done (per unit boundary)
No Stripe/Paddle/LemonSqueezy integration, no checkout, no webhook, no `create-checkout-session`, no
fake payment, no Lovable change, no gate-wiring of `/workspace` or publish onto `fn_workspace_access`
(that switch is a later unit once a provider exists). RLS was not weakened; storefront publish
authorization and the discovery/decision/intelligence logic were untouched.

## 19. Files / migrations changed
- `supabase/migrations/mig_239_paid_entitlement_foundation.sql` (new; applied as
  `mig_239_paid_entitlement_foundation`).
- `docs/STRATELOQ-ECOM-PAID-ENTITLEMENT-FOUNDATION-012A.md` (this report).

## 20. Production / customer mutation status
Only two internal COMP entitlement rows were inserted (founder + internal support), both verified via
`auth.users`. No real customer data created or altered. No storefront published/unpublished.

## 21. Cost
**€0.** No paid resource, no provider account, no external call.

## 22. Commit / divergence
See delivery message for the hash; branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

---

## FINAL VERDICT
**`PASS`.** The provider-independent entitlement foundation is live and server-authoritative:
durable-identity-bound store with deny-all RLS; pure, tested active-predicate and access-state
composer; authenticated status RPC that leaks no provider ids; authoritative `fn_workspace_access`
composing auth + verification + active entitlement + readiness into the six locked states; COMP for
exactly the two `auth.users`-verified internal accounts and no customer; browser proven unable to
read/grant/alter entitlement; 17/17 selftest; A–L all PASS; 65/65 storefront regression; no advisory
increase; all existing data preserved; €0. `entitlement_event` and the payment-provider/checkout/
webhook and gate-wiring are correctly deferred.

STOP — 012A complete. Not starting 012B / checkout / provider / Lovable.

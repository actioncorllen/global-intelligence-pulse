# RUNBOOK — Mandatory Onboarding Production Activation (enforcement_active = TRUE)

**Status: PREPARED, NOT EXECUTED. Activation requires explicit founder authorisation.**
Project `nxaunmyihhjixxxljcqt` · Target launch 18 Dec 2026 · Prepared 2026-11-10.

The switch is **global and instant**: one row (`onboarding_policy.enforcement_active`)
arms BOTH the PostgREST pre-request gate (mig_351, wired) and the Edge Function gate
(mig_352 + the five guarded functions). There is **no partial / per-tenant mode and no
permanent bypass for selected accounts** (deliberately — a tenant bypass would be a
second security system). Rollback is a single UPDATE, effective on the next request.

---

## 0. Impact assessment — EVERY existing member (measured 2026-11-10)

`fn_edge_onboarding_allowed` under enforcement (rolled-back prod test): **0/5 existing
members onboarding-complete**. On activation, ALL five members (the pilot
surpyjabu@gmail.com included) drop to the onboarding journey on their next request:

- Workspace RPCs / direct workspace tables / guarded Edge Functions → denied
  (`42501 onboarding_incomplete` / HTTP 403) until they complete
  BUSINESS PROFILE → BILLING PROFILE → MEMBERSHIP CONFIRMATION.
- Always available while incomplete (verified 34/34 over real HTTP locally):
  login/auth (separate service), `fn_workspace_access`, `fn_entitlement_status`,
  the business/billing profile RPCs, `confirm_membership`, notifications RPCs,
  own-identity/session/reference tables, the published Lovable onboarding UI
  (flag-aware routing, 04a034a), and `start-discovery` (deliberately unguarded:
  it IS the business-profile step), `accept-invitation`, OAuth callback,
  facebook-disconnect (revocation safety), public storefront.
- COMP entitlements are untouched: billing step shows amount 0; no member is charged.
- Decide BEFORE activation: will the founder walk the pilot through onboarding
  live (recommended), or pre-complete the pilot via the member's own UI journey first?
  (Never by hand-editing their rows.)

## 1. Preflight (no changes)

```sql
SELECT enforcement_active, require_business_profile, require_billing_profile,
       require_membership_confirmation, comp_refresh_allowance_approved
FROM public.onboarding_policy;                       -- expect: false, true, true, true, false
SELECT setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid=s.setrole
WHERE rolname='authenticator';                       -- expect pgrst.db_pre_request=public.fn_pre_request_gate
SELECT public.fn_edge_onboarding_allowed(NULL);      -- expect TRUE (OFF = no-op)
SELECT m.email, public.fn_member_onboarding_state(m.auth_user_id)->>'access_state'
FROM public.member m;                                -- snapshot each member's landing state
```
Record the snapshot in the ops log. Confirm edge versions: meta-insights-reader v19,
product-image-import v10, commercial-image-generate v14, translate-text v8,
prepare-product v21 (verify_jwt=false).

## 2. Activation (founder-authorised only)

```sql
UPDATE public.onboarding_policy
SET enforcement_active = true, updated_at = now(), updated_by = 'founder'
WHERE id;
```
No reload needed — both gates read the flag per request.

## 3. Immediate verification (first 10 minutes)

a. **Data API probes** (anon key only; expected results in brackets):
   - `GET /rest/v1/commerce_products` with anon key → 200 `[]` (RLS; anon never gated)
   - signed-in INCOMPLETE member (pilot): `POST /rest/v1/rpc/fn_product_explorer`
     → **403 onboarding_incomplete**; `GET /rest/v1/commerce_products` → **403**;
     `POST /rest/v1/rpc/fn_workspace_access` → 200 with the required step.
b. **Edge probes**: run n8n workflow `ZZ Strateloq edge-guard post-deploy probes`
   (TNhQYnfGygFdAFNA) → expect exactly: 401 / 401 / 403 forbidden_origin / 401 / 401.
   Signed-in incomplete member invoking translate/commercial-image/prepare/image-import
   from the app → 403 `ONBOARDING_INCOMPLETE` (shown by app error handling).
c. **Founder pilot journey**: log in as the pilot → app routes to onboarding →
   complete business profile → billing profile (amount €0, card fields absent; any
   card-like key rejected `payment_credentials_not_accepted`) → confirm membership →
   workspace loads; Product Discovery/Explorer works; refresh quote path still
   credit-gated (no provider spend without credits).
d. `service_role` job spot check: one n8n scheduled workflow executes normally.

## 4. Monitoring + thresholds (first 24 h)

Supabase Logs (`postgrest_logs`, `function_edge_logs`, `edge_logs`):
- `42501` / `onboarding_incomplete` count: EXPECTED from incomplete members;
  investigate only if it continues for a member who has completed onboarding (bug).
- Edge 5xx rate on the five guarded functions: threshold >1% of calls or any boot
  error → investigate; sustained → rollback.
- Auth errors (`/auth/v1`): unaffected path; any spike is unrelated regression → investigate.
- `fn_translation_budget_*` / provider budget tables: no change expected (0 active prices).

## 5. Rollback (instant, in escalation order)

```sql
-- 1. Disarm everything (PostgREST + Edge gates) — the normal rollback:
UPDATE public.onboarding_policy SET enforcement_active = false WHERE id;
-- 2. Additionally unwire the PostgREST hook (only if the hook itself misbehaves):
ALTER ROLE authenticator RESET pgrst.db_pre_request; NOTIFY pgrst, 'reload config';
-- 3. Edge-level rollback (only for an edge-specific defect): redeploy the pre-guard
--    function versions (marker-stripped A variants in supabase/tests/local-acceptance/edge-ab),
--    THEN optionally mig_352_ROLLBACK.sql. Never drop fn_edge_onboarding_allowed first.
```

## 6. Stop / Go criteria

GO when ALL hold: preflight matches §1; founder explicitly authorises; founder is
available to run §3c personally; §3a/§3b probes return exactly the bracketed results;
no open P0 on auth/onboarding.
STOP + rollback when ANY hold: a COMPLETED member is denied; service_role jobs fail;
edge 5xx above threshold; auth regression; the pilot cannot finish the journey for a
product reason (fix first, re-activate later — the switch is cheap and repeatable).

## 7. Remaining production-specific verification (accepted residual before GO)

- Hosted PostgREST/Kong behave like the local stack (same code paths; config deltas
  only) — covered by §3a probes on activation day.
- Edge-runtime parity: guards were proven on the same source under plain Deno +
  live negative probes; the authenticated-member edge path over hosted edge-runtime
  is exercised by §3c (founder) on activation day.
- storefront / meta-capi-adapter stay public BY DESIGN (visitor paths); capi event
  forgery mitigations = per-tenant config + consent + dispatch ledger (pre-existing posture).

---

# ADDENDUM — Final Activation Preflight (executed 2026-11-10, enforcement untouched)

## §A. Member states (masked; snapshot in ops log)

Current (gates off) vs enforced landing (measured in a rolled-back transaction):
**ALL FIVE members land at `BUSINESS_PROFILE_REQUIRED`** — one uniform entry point.

| Member | ds rows | discovery (status/analysis) | app link | verified | entitlement | route to complete |
|---|---|---|---|---|---|---|
| cl***@gmail.com | 1 | not_started/ready | yes | yes | NONE | profile+billing OK; blocked at membership (needs founder grant — invitation-only by design) |
| su***@gmail.com (pilot) | 1 | not_started/not_started | no → backfill RPC | yes | COMP ACTIVE | full route open |
| su***@globalintelligenceactions.com | 1 | not_started/ready | yes | yes | COMP ACTIVE | full route open |
| ac***@gmail.com | 1 | not_started/not_started | no → backfill RPC | yes | NONE | profile+billing OK; blocked at membership (needs grant) |
| ac***@gmail.com | 1 | in_progress/ready | yes | yes | COMP ACTIVE | full route open |

Route prerequisites verified for all 5: exactly one `discovery_state` row (the
`save_business_profile` cardinality requirement), email verified, app-less members
covered by `fn_ensure_member_business_profile` backfill (allowlisted).

## §B. COMP money-safety (verified)
All 3 entitlements are `COMP/COMP` (0 PROVIDER). `save_billing_profile` forces
`billing_kind=COMP`, `amount_minor=0` for them and REJECTS any card-like key
(`payment_credentials_not_accepted`) — HTTP-proven (local C4/C5). 0 billing rows
with nonzero amount. Paid posture inert: 0 active `discovery_credit_price`,
every `provider_call_budget` row `active=false`, `research_budget_config.enabled=false`
(caps 0), `comp_refresh_allowance_approved=false`.

## §C. Frontend/backend state parity (verified in live Lovable code)
`src/lib/onboarding/onboarding-routing.ts` + `onboarding-guard.tsx`: the ONLY
authority is `fn_workspace_access()`; the UI maps the server's exact state names
(BUSINESS/BILLING/MEMBERSHIP_CONFIRMATION_REQUIRED, ENTITLEMENT_*,
WORKSPACE_PREPARING, READY), is `onboardingEnforced`-aware (flag-off = current
behaviour), never decides completion client-side, and maps `confirm_membership`
blocked-reasons back to the right step.

## §D. Edge health (post-deploy, live traffic)
3h window after the guarded deploys: translate-text v8 served real authenticated
members **4×200** (no-op preservation proven on hosted edge-runtime); probes
401/403 as designed; **zero 5xx** on all five guarded functions.

## §E. Pilot founder-device test script (Stage 2)
1. Sign in as the pilot → app routes to /onboarding at **Business profile**.
2. Business profile step (calls `fn_ensure_member_business_profile` backfill, then
   `save_business_profile` complete) → advance to **Billing profile**.
3. Billing profile: fields show NO card inputs; amount **€0** (COMP). Submitting any
   card-like field name is rejected server-side. Complete → **Membership confirmation**.
4. Confirm membership (requires active COMP entitlement — pilot has it) → state
   becomes **WORKSPACE_PREPARING**.
5. **Expected behaviour while discovery analysis is NOT ready** (pilot's
   `analysis_status='not_started'`): the SERVER already counts onboarding complete
   (`fn_onboarding_complete` accepts WORKSPACE_PREPARING → RPCs/tables/edges allowed),
   but the UI keeps the member on the **“Preparing” screen** (step 4/5) and
   `OnboardingGuard` holds /workspace/* until `analysis_status='ready'`.
   → FOUNDER DECISION before/at the pilot test: run the pilot's business-discovery
   analysis (its own authorised, budget-gated step) to flip `analysis_status`,
   or accept the pilot parking at “Preparing”. NO direct DB edit of the member.
6. Once READY: workspace loads; Product Discovery/Explorer verified per §3.

## §F. Preserved paths re-confirmed
Account recovery/status (`fn_workspace_access`, `fn_entitlement_status`, profile and
notification RPCs) allowlisted (34/34 local HTTP); Supabase Auth untouched (separate
service); invitation functions (`issue-*`, `accept-invitation`) unmodified this round
and NOT onboarding-guarded; no notification/invitation sent; public signup
configuration untouched (one-line founder dashboard glance recommended at GO).

---

# EXECUTION RECORD — ACTIVATED 2026-11-10 18:02:20 UTC (founder-authorised)

- Pre-execution snapshot matched the accepted preflight on every item (policy flags,
  hook, gate function hashes, 3×COMP/COMP, 2 pending members, 0 prices/budgets,
  research disabled, 0 nonzero billing, clean 1h error baseline).
- `UPDATE public.onboarding_policy SET enforcement_active=true, updated_at=now(),
  updated_by='founder' WHERE id;` → **rows_updated=1**, singleton row verified
  (`enforcement_active=true`, `updated_by='founder'`, 18:02:20.747 UTC).
- Live hosted acceptance (immediately after):
  * All five members: `fn_member_onboarding_state` → **BUSINESS_PROFILE_REQUIRED** (live).
  * Edge gate live: `fn_edge_onboarding_allowed` → false for NULL/random/all 5 (0/5).
  * Data API (n8n, anon key): table read → 200 `[]` (RLS empty); table INSERT →
    401 `42501` RLS violation (probe row verified NOT inserted); allowlisted RPC
    `get_own_billing_profile` → 200 `{"status":"unauthenticated"}` (alive through the
    armed gate); protected RPC with anon → denied (PGRST202/no anon EXECUTE).
  * Edge functions (n8n): insights 401 / translate 401 / prepare 403 forbidden_origin /
    cig 401 / image-import 401 — all handlers serving under enforcement.
  * Auth: `/auth/v1/health` 200 (GoTrue v2.197.0); `/auth/v1/recover` 200 (no enumeration).
  * Post-activation integrity: entitlements 3×COMP/COMP unchanged, 0 confirmed members,
    prices/budgets/research still inert, 0 nonzero billing.
  * 20-min log window: zero 5xx; only probe traffic + normal 200s; no lockout loops.
- Limitation (accepted): authenticated incomplete-member HTTP denials over hosted
  infra are evidenced at SQL level + local 34/34; the live member-credential proof is
  the founder pilot journey (§E) — no member credentials are held and none were
  fabricated or impersonated.
- Monitoring: first self check-in armed ~50 min post-activation; rollback
  (`enforcement_active=false`) standing by per §5.

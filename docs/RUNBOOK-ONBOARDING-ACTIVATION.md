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

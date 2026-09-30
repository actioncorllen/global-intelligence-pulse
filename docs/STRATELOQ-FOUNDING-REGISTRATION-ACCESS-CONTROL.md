# STRATELOQ — Founding-Member Registration Access Control

**Status:** `PASS (backend-enforced)` — registration into a workspace is gated server-side; approved
invited members activate and sign in; unapproved visitors cannot register or enter a workspace.
Two auth-config hardenings remain (external, dashboard-only). Nothing destructive; no auth method disabled.

## Verified existing enforcement (reused, unchanged)

- **Member/workspace provisioning is gated to one path.** `accept_invitation` (SECURITY DEFINER) is
  the ONLY function that inserts a `member` identity row (and its `discovery_state` workspace). It
  requires a valid, **ISSUED**, **unexpired**, **single-use** invitation whose `bound_email` equals
  the caller's **CONFIRMED** auth email, then marks the invitation `consumed`. Verified live: expired,
  revoked, reused/consumed, wrong-email and malformed-token invitations are all rejected.
- **No self-provisioning.** `member`, `invitation`, `discovery_state`, `founding_applications` have RLS
  enabled with **no anon/authenticated INSERT/ALL policy** → direct inserts are default-denied (probed
  live: `ANON_INSERT_BLOCKED_BY_RLS`). Only SECURITY DEFINER functions / service role can write.
- **No approval bypass.** `issue_invitation`, `issue_open_invitation`, `accept_invitation`,
  `validate_invitation` are `EXECUTE`-granted **only to `postgres` + `service_role`** — not
  anon/authenticated — so they cannot be called directly via PostgREST. The two issuance edge functions
  additionally gate the caller against a server-held **founder allowlist**
  (`FOUNDER_ISSUER_AUTH_USER_IDS`) with origin allowlisting → applicants cannot self-approve/self-issue.
- **Trusted identity on acceptance.** The `accept-invitation` edge derives the auth user id and
  email-verified strictly from a verified `auth.getUser(bearer)` — never from client-supplied fields;
  `accept_invitation` re-validates against `auth.users` regardless.
- **An auth account ≠ membership.** There is currently one confirmed auth user with **no member row**
  (inert): they hold a session but can access no workspace data (all member-scoped RLS keys on
  `member.auth_user_id = auth.uid()`, and they have no member row). This is the enforcement on **every**
  signup/OAuth path: however an `auth.users` row is created, it grants nothing without a valid invitation.
- **Cross-tenant isolation.** Every member-scoped table's RLS is keyed to the caller's own member.

## Fixes made (mig_343)

1. **Controlled public application intake.** Direct anon INSERT into `founding_applications` is (correctly)
   RLS-blocked, and no safe intake path existed. Added `fn_submit_founding_application` (anon-executable,
   SECURITY DEFINER, `search_path=''`, input-validated, deduped per email, status forced `new`). It writes
   **only** a `founding_applications` row — **no account, member, workspace or invitation**. This is item 1 & 7's
   least-privilege backend path.
2. **Least-privilege grant tightening.** Revoked over-broad `anon`/`authenticated`
   `INSERT/UPDATE/DELETE/TRUNCATE` on `founding_applications`, `users`, `business_profiles` (these were
   RLS-blocked for API writes already; `TRUNCATE` is **not** RLS-governed). Revoked `SELECT` on
   `founding_applications` from anon/authenticated (lookup is founder/service-role only). `member`,
   `discovery_state`, `business_profiles` **SELECT** for authenticated is preserved, so existing members
   sign in and read their own data normally. SECURITY DEFINER functions and service role are unaffected.

## Test evidence — `fn_founding_access_control_selftest` 12/12 (writes rolled back, nothing persisted)

| Scenario | Result |
|---|---|
| Approved + valid issued invite activates | `accepted` |
| Returning member re-accepts | `accepted / already_provisioned` |
| Expired invitation | `invalid_invitation / expired` |
| Revoked invitation | `invalid_invitation / revoked` |
| Reused (consumed) invitation, no member | `integrity_conflict / missing_member` |
| Invite bound to a different email | `authentication_failed` |
| Malformed token | `invalid_invitation / not_found` |
| Application intake | application created, **no account/member** |
| Self-provision write policy (member/invitation/discovery/apps) | none (0) |
| Direct `issue_invitation` RPC as anon/authenticated | denied |
| Direct `accept_invitation` RPC as anon/authenticated | denied |
| Over-broad anon/authenticated write+TRUNCATE grants | revoked (0) |

Regression: `member`=5 and `founding_applications`=6 unchanged; existing-member reads preserved;
security advisors **0 ERROR** (4 WARN / 1 INFO baseline).

## Genuine external items (auth-config; dashboard/Management API — cannot be set via SQL)

1. **Raw Supabase Auth signups (defense-in-depth).** The member gate already makes any un-invited auth
   account inert. To also stop bare account creation on the raw email/OAuth path, either (a) enable a
   *Before User Created* auth hook that requires an ISSUED invitation for the sign-up email (lets invited
   users through, blocks others), or (b) keep public sign-up disabled and create invited users via admin
   invite. **Do not blindly disable sign-ups** — the current flow relies on invited users self-signing-up
   then accepting, so a naive disable would block legitimate invitees. This is a config decision for the founder.
2. **Leaked-password protection** (`auth_leaked_password_protection`) is disabled — enable it in Auth
   settings for stronger password recovery/security (item 6 hardening). Password recovery itself is native
   Supabase Auth and remains intact.

## Lovable wiring (small)

Point the public "Apply to Become a Founding Member" form at `fn_submit_founding_application` (anon
Supabase RPC) instead of a direct table insert (which is RLS-blocked). Visitors without an invitation see
this Apply action; there is no unrestricted self-registration path in the UI. No other frontend change.

# Billing-staging automated security gate

Automated recurrence protection for the `rls_disabled_in_public` remediation on
`strateloq-billing-staging` (`nlfkwrjmhxbubtlwepwx`). **Staging only — production
`nxaunmyihhjixxxljcqt` is never targeted.**

## Two tiers (least privilege)

| Tier | File | Privilege | Where it runs |
|---|---|---|---|
| **1 — catalog (read-only)** | `security_gate_catalog.sql` | **Least-privilege** `security_gate_ro` (catalog reads only; no data, no `SET ROLE`, no RPC execute) | **GitHub Actions** (`.github/workflows/billing-staging-security-gate.yml`) |
| **2 — behavioural (privileged)** | `security_regression_test.sql` | Elevated (`SET ROLE` + `fn_billing_selftest`) | **MCP / protected manual** only — never untrusted CI |

This split satisfies the least-privilege requirement: the only credential stored in
CI is a read-only role that **cannot read any customer/billing data**, cannot assume
`anon`/`authenticated`/`service_role`, and cannot execute billing functions. The
privileged behavioural checks are kept out of CI so no administrator credential is
stored for untrusted pull requests.

### Tier-1 checks (catalog)
T1 RLS on every public table · T2 no anon/PUBLIC table grants · T3 no authenticated/PUBLIC
writes · T4 no authenticated billing-table grants · T5 member tenant-scoped SELECT policy ·
T6 no anon/PUBLIC policies · T7 billing RPC execute grants (anon=none; backend RPCs not
authenticated) · T8 billing fns are SECURITY DEFINER with locked `search_path`.
Fails (non-zero) on any violation.

## Least-privilege CI role

`security_gate_ro` is provisioned by `provision_ci_gate_role.sql` (already applied to
staging). It is **inert** until an operator sets a password — this script deliberately
sets no password, so no secret is ever committed. Verified posture (live): not a member
of any Supabase role, zero table grants, cannot execute `fn_billing_selftest`, cannot read
`member`.

## Verified (live, via MCP, 2026-11-10)
- Tier-1 ran **as `security_gate_ro`**: all 8 catalog checks **PASS**.
- Tier-2 behavioural suite: 14/14 **PASS** (incl. `fn_billing_selftest all_pass=true`).
- Negative test: the gate **RAISES / exits non-zero** when a public table lacks RLS.

## Operator steps to ACTIVATE in GitHub Actions (require repo-admin; see note)

GitHub Actions administration (secrets, Actions settings, branch protection) is **not
reachable from the Claude session** (the egress proxy blocks the Actions API and the
GitHub App token only has `metadata=read`). These steps must be done by a repo admin:

1. **Set the role password** (Supabase SQL editor, so the value never touches CI/source/logs):
   ```sql
   ALTER ROLE security_gate_ro PASSWORD '<generated-strong-password>';
   ```
2. **Create the repository secret** `BILLING_STAGING_DB_URL_RO` (Settings → Secrets and
   variables → Actions) = the `security_gate_ro` pooler connection string:
   ```
   postgresql://security_gate_ro.nlfkwrjmhxbubtlwepwx:<password>@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require
   ```
   (Confirm the exact pooler host/port under Supabase → Project → Connect.)
3. **Trigger a run** — the workflow runs on `workflow_dispatch`, on pushes/PRs that touch
   `supabase/billing-staging/**`, `scripts/security/**`, or the workflow file. Until the
   workflow is on the **default branch** (`claude/pulse-crash-recovery-b6ngey`),
   `workflow_dispatch` is not selectable in the UI; merge it to the default branch (or run
   on a push to a same-repo branch) to make it dispatchable.
4. **Make it a required check** (optional, recommended): Settings → Branches → protect the
   default branch → Require status checks → add `rls-catalog-gate`.

With the secret set, a passing gate is green; a failing security check or a missing secret
makes the workflow **fail** (never a misleading green). Fork PRs are skipped (no secret access).

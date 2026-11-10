# Billing-staging — authoritative schema source & recurrence prevention

**Project:** `strateloq-billing-staging` — Supabase ref `nlfkwrjmhxbubtlwepwx` (eu-central-1).
**Production** (`nxaunmyihhjixxxljcqt`) is a separate project and is **never** deployed from here.

This directory is the version-controlled, authoritative source for recreating the
billing-staging schema **securely**. It exists because the original phase08 billing-staging
migrations were applied directly to the project via the Supabase Management API / MCP and were
**not** version-controlled in this repo — which is how `public.member` shipped with RLS
disabled (`rls_disabled_in_public`, P0, remediated 2026-11-10).

## Authoritative migration source (Supabase migration history)

The project's own migration history is the authority (`supabase_migrations.schema_migrations`):

| Version | Name | What it does | Secure as recorded? |
|---|---|---|---|
| `20261104000847` | `phase08_staging_dependencies` | Creates `member`, `account_entitlement`, pure helper fns | ❌ **Original omitted RLS on `member` and `REVOKE` on both tables** — this was the root cause |
| `20261104001130` | `phase08_billing_provider_neutral` | Creates `billing_plan`, `billing_event`, all `fn_billing_*` RPCs; grants/revokes | ✅ already correct (RLS + `REVOKE ALL … FROM PUBLIC, anon, authenticated` + least-privilege EXECUTE grants) |
| `20261110182057` | `phase08_billing_rls_lockdown_remediation` | **The fix.** Enables RLS on `member`, adds `member_select_own`, revokes drifted grants on `member`/`account_entitlement`, reasserts deny-all on billing tables | ✅ remediation / backstop |

Because the remediation (`20261110182057`) is **recorded in the migration history**, any
version-ordered replay — `supabase db push`, a branch created from this project, or a
point-in-time rebuild from the history — applies it **after** table creation, so the
end-state is secured. It sorts last by version, so it always runs last.

## What this directory adds (recurrence prevention)

- **`migrations/20261104000847_phase08_staging_dependencies.sql`** — a **secure-by-construction**
  copy of the defective bootstrap migration: identical schema, but RLS + `member_select_own`
  policy + least-privilege grants are applied **inline, in the same migration**, so the tables
  are never created in an exposed state (removes even transient exposure on a fresh rebuild).
  Idempotent; produces the same end-state as the live DB.
- The already-correct `20261104001130_phase08_billing_provider_neutral` is **not duplicated here**
  (it is authoritative and correct in the migration history; re-importing the whole billing
  engine would create a second source of truth). To obtain a byte-exact copy for a fully
  self-contained rebuild, export it from the project:
  ```bash
  # returns the exact SQL recorded for that migration version
  # (run via the Supabase SQL editor / MCP execute_sql):
  #   SELECT statements[1] FROM supabase_migrations.schema_migrations
  #   WHERE version = '20261104001130';
  ```
- **`scripts/security/phase08_billing_staging_rls_lockdown_remediation.sql`** — the idempotent
  remediation migration (also recorded as `20261110182057`). The backstop for any
  already-deployed database or any rebuild that used the *original* (defective) bootstrap.
- **`scripts/security/security_regression_test.sql`** — the automated gate (see below).

## Recreate runbook (secure)

1. Apply `migrations/20261104000847_phase08_staging_dependencies.sql` (secure-by-construction).
2. Apply `20261104001130_phase08_billing_provider_neutral` (from the migration history — already correct).
3. Apply `scripts/security/phase08_billing_staging_rls_lockdown_remediation.sql` (idempotent backstop; no-op if 1 & 2 already secure).
4. **Run `scripts/security/security_regression_test.sql`** — it **fails the deploy** if any table
   is exposed, if `anon`/`authenticated` have unintended access, if member tenant isolation is
   broken, or if backend billing operations regress. Treat a non-zero exit as a blocked deploy.

## Approved access model (must remain true)

| Table | RLS | Client access |
|---|---|---|
| `member` | enabled | `authenticated` **SELECT own row only** (`auth.uid() = auth_user_id`); writes via `service_role` |
| `account_entitlement` | enabled | **denied** to clients; `service_role` / SECURITY DEFINER RPCs only |
| `billing_plan` | enabled | **denied** to clients; read via `fn_billing_list_plans()` |
| `billing_event` | enabled | **denied** to clients; written via `fn_billing_apply_event()` |

Authorized billing RPCs (`fn_billing_list_plans`, `fn_billing_create_checkout_intent`,
`fn_billing_portal_intent`) remain `authenticated`-executable by design (self-scoped via
`auth.uid()`). Backend RPCs (`fn_billing_apply_event`, `fn_billing_reconcile_candidates`,
`fn_billing_selftest`) remain `service_role`-only.

## Upstream recommendation (external)

The generator/source that produced the original phase08 migrations lives outside this repo. Fold
the inline security from `migrations/20261104000847_phase08_staging_dependencies.sql` into that
upstream source so the root cause cannot recur at creation time in any future rebuild.

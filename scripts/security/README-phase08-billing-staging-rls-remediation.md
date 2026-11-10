# Security remediation — billing-staging RLS lockdown (P0)

**Finding:** `rls_disabled_in_public` (Supabase Security Advisor, ERROR / critical)
**Project:** `strateloq-billing-staging` — ref `nlfkwrjmhxbubtlwepwx` (eu-central-1) — **staging only**
**Production `nxaunmyihhjixxxljcqt` was NOT touched.**
**Applied:** 2026-11-10, migration `phase08_billing_rls_lockdown_remediation`
**Migration SQL:** [`phase08_billing_staging_rls_lockdown_remediation.sql`](./phase08_billing_staging_rls_lockdown_remediation.sql)

---

## 1. Affected tables & original exposure

| Table | RLS (before) | anon grants (before) | authenticated grants (before) | Actual exposure |
|---|---|---|---|---|
| `public.member` (PII: email, display_name, business_name, auth_user_id) | **DISABLED** | SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER | same | **Critical** — anyone with the anon key could read/insert/update/delete/truncate every row. Table held **0 rows**, so no PII was actually present to exfiltrate, but the table was fully reachable/writable. |
| `public.account_entitlement` (subscription / provider IDs) | enabled, no policy | SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER | same | **Latent** — broad client grants, but RLS-with-no-policy denied all client access, so its 1 real row was never client-readable. Grants were a defense-in-depth risk if a permissive policy were ever added. |
| `public.billing_plan` | enabled, no policy | none | none | Protected throughout (1 row). |
| `public.billing_event` (webhook ledger) | enabled, no policy | none | none | Protected throughout (0 rows). |

## 2. Root cause

`public.member` was created without `ENABLE ROW LEVEL SECURITY` and retained PostgREST's
default broad grants to `anon` + `authenticated`. `public.account_entitlement` kept the
same default broad grants (dormant only because RLS-no-policy denied clients). The sibling
tables `billing_plan` / `billing_event` had already been locked to `service_role`, so this
was **grant/RLS drift on two tables** against the project's own documented contract
(`mig_239_paid_entitlement_foundation`: *"RLS deny-all to clients … REVOKE ALL … FROM
PUBLIC, anon, authenticated"*).

## 3. Remediation (conventions reused, nothing invented)

- **`member`** → production convention (`dr/schema/rls_enable.sql` + `dr/schema/policies.sql`):
  RLS enabled; `authenticated` may `SELECT` **only its own row** via policy
  `member_select_own USING (auth.uid() = auth_user_id)`; `authenticated` grant reduced to
  `SELECT`; `anon` grant removed; all writes performed by `service_role` / edge (bypasses RLS).
- **`account_entitlement`** → `mig_239` convention: RLS deny-all to clients; `anon` +
  `authenticated` grants revoked (drift closed); access only via `service_role` / SECURITY
  DEFINER billing RPCs.
- **`billing_plan` / `billing_event`** → deny-all reasserted (idempotent; already clean).
- **Billing RPCs left unchanged** (`fn_billing_list_plans`, `fn_billing_create_checkout_intent`,
  `fn_billing_portal_intent` remain `authenticated`-executable): intentional, self-scoped via
  `auth.uid()`, the designed customer billing API (per `mig_229` lockdown convention).

No data deleted; no schema/column/type changes; `service_role` and backend operations
preserved (`service_role` and `postgres` have `rolbypassrls = true`).

## 4. Verification (live, on staging)

**Catalog (after):** RLS enabled on all 4 tables; `tables_without_rls = []`; only client grant
is `authenticated → member : SELECT`; policy `member_select_own` present
(`SELECT`, role `authenticated`, `USING (auth.uid() = auth_user_id)`).

**Behavioral role-simulation tests** (`SET ROLE` + JWT claims — what PostgREST enforces;
seeded data, rolled back):

| # | Scenario | Result |
|---|---|---|
| anon → SELECT/INSERT member, SELECT account_entitlement/billing_plan/billing_event | **DENIED** (insufficient_privilege) | PASS |
| anon → RPC create_checkout_intent | **DENIED** | PASS |
| authA → SELECT member (own row) | ALLOWED, 1 row | PASS |
| authA → SELECT member WHERE user=B (cross-tenant) | 0 rows (isolated) | PASS |
| authA → UPDATE / DELETE member | **DENIED** | PASS |
| authA → SELECT account_entitlement / billing_plan / billing_event | **DENIED** | PASS |
| authA → RPC list_plans / create_checkout_intent / portal_intent | ALLOWED (billing workflow intact) | PASS |
| service_role → SELECT/INSERT member, SELECT account_entitlement | ALLOWED (backend intact) | PASS |
| service_role → RPC apply_event (webhook ingest) | ALLOWED (`ok:true, applied:true`) | PASS |

**Security Advisor rerun (2026-11-10T18:34:55Z):** `rls_disabled_in_public` **RESOLVED**.
No ERROR/critical findings remain. Remaining items are intended/accepted:
`rls_enabled_no_policy` (INFO — the deliberate deny-all/function-gated posture) and
`authenticated_security_definer_function_executable` (WARN — the intentional, tenant-guarded
billing RPCs). A pre-existing, unrelated `auth_leaked_password_protection` (WARN) is noted
as a recommended Auth-config follow-up.

> Note: the live HTTPS REST endpoint `nlfkwrjmhxbubtlwepwx.supabase.co` is blocked by this
> session's egress policy (proxy 403 on CONNECT), so end-to-end HTTP testing was performed via
> in-database role simulation, which exercises the identical RLS + grant enforcement path.

## 5. Historical-log investigation

Retained logs cover the exposure window (2026-11-04 creation → 2026-11-10). Sampled start,
middle, and end:
- **Gateway/edge logs:** only Supabase internal health checks (`mgmt-api`, `rest-admin/ready`,
  `auth/health`) and **one authorized backend edge-function read** of `billing_plan`
  (`Deno/SupabaseEdgeRuntime; ref=nlfkwrjmhxbubtlwepwx`, 2026-11-06). **No external/anon request
  to `member`.**
- **Postgres logs:** the two authorized schema-creation migrations (2026-11-04) and authorized
  operator activity over MCP (incl. a self-cleaning "staging sandbox" probe on 2026-11-10 that
  left no residue — verified: no `_gate_probe` table, no `_probe_*` functions, no dangling
  `pgrst.db_pre_request` hook).

**Conclusion:** No evidence of unauthorized access. Because `member` held **0 rows**, any read
during the exposure window would have returned nothing, and no unauthorized rows persist.
Unauthorized read/exfiltration is **ruled out to high confidence within available evidence** —
not claimed as impossible: Supabase default logging does not record every client `SELECT`, and
only representative 24h windows were sampled. Residual uncertainty is low and bounded by the
empty-table fact. The exposed table held no secrets; billing provider identifiers live in
`account_entitlement`/`billing_event`, which were RLS-protected throughout. No credential
rotation is indicated by the evidence (operator may rotate as precaution).

## 6. Remaining risks / external actions

- (Recommended, optional, out of this migration's scope) Enable **Leaked Password Protection**
  in Auth settings (pre-existing WARN, unrelated to this finding).
- The billing-staging schema (phase08) is managed outside this repo; ensure its source applies
  the same `REVOKE ALL … FROM anon, authenticated` lockdown so the drift does not recur on
  rebuild. This committed migration is the reproducible reference.
- No production action required; production (`nxaunmyihhjixxxljcqt`) was not modified.

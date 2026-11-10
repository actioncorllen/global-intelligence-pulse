# Local real-HTTP onboarding-enforcement acceptance harness

Proves the mandatory founding-member onboarding gate (`fn_pre_request_gate`, mig_345–351)
over **real HTTP** with `enforcement_active=TRUE`, in a **free, fully isolated local
Supabase stack** (Supabase CLI + Docker). Production is never touched: its flag stays
FALSE and no production secrets or customer data enter the environment.

## What ran (2026-11-10) — result: 34/34 PASS (`matrix_results.txt`)

- Stack: `supabase start` with only db + auth (GoTrue) + rest (PostgREST) + kong
  (realtime/storage/studio/edge-runtime/analytics disabled in `config.toml`).
- **Parity**: all 17 security/onboarding functions were loaded and verified
  **md5(pg_get_functiondef)-identical to production** (no mocks). RLS policies and
  table/function grants mirror the production `pg_policies` / ACL fetch of 2026-11-10.
  `fn_product_explorer` here is a clearly marked minimal *data-RPC stand-in* (it is not a
  security function); everything security-relevant is verbatim prod.
- Hook wired exactly as prod: `ALTER ROLE authenticator SET pgrst.db_pre_request =
  'public.fn_pre_request_gate'` + REST restart.
- 3 synthetic users (`*@synthetic.test`) via local GoTrue admin API; JWTs via password grant.

## File order

1. `01_tables.sql` — support tables + onboarding_policy/billing_profile (verbatim mig_346/349)
2. `01b_policies_grants.sql` — RLS policies + table grants (run after functions exist)
3. `02_functions.sql` — functions extracted verbatim from repo migrations
4. `02c_prod_transcribed.sql`, `04_prod_exact_overrides.sql`,
   `04b_save_business_profile_prod.sql` — exact production `pg_get_functiondef` text
5. `03_grants_standin_seed.sql` — function grants (mirror prod ACLs) + stand-in RPC + synthetic seed
6. `seed_users.sh` — synthetic users + onboarding state
7. `run_matrix.sh` — the 34-check HTTP matrix (wired-but-OFF no-op proof, then enforcement ON)

## Notes on expected codes

- A nonexistent relation returns **404 before any transaction** (PostgREST schema-cache
  lookup); the gate governs every *existing* resource (A2/A3/F2/F3 prove 403).
- A JWT without a `role` claim is rejected upstream with **401** — still fail-closed.
- Edge Functions are a separate entry path (not behind the PostgREST hook); the local
  edge-runtime image was registry-blocked in this environment, so that row remains
  covered by the production-side assessment (no critical bypass; per-edge guard
  recommended before broad rollout).

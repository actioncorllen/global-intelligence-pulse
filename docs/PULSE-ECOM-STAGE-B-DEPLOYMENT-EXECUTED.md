# Stage B Backend Deployment — EXECUTED (2026-11-09)

Controlled Stage B backend release to the Strateloq production Supabase project, in its **fail-closed,
non-commercially-activated** state, per founder execution directive. Release commit base: `94a99c2`.

**Confirmed DEPLOYED to production. No paid API calls. No provider budgets, customer credits, pricing, allowances,
or billing activated. No public signup. No production data deleted. Frontend `c1a6afa` remains unpublished.**

## 1. Applied migrations and timestamps (production)

| Order | Migration version | Name (file) | Applied (UTC) |
|---|---|---|---|
| 5 | `20261109221204` | `stageb_discovery_credit_refresh` (mig_341) | 2026-11-09 22:12:04 |
| 6 | `20261109221330` | `stageb_discovery_subscription_credit_allowance` (mig_341c) | 2026-11-09 22:13:30 |
| 7 | `20261109221553` | `stageb_discovery_refresh_reconcile_schedule` (mig_341b) | 2026-11-09 22:15:53 |
| 8 | `20261109221712` | `stageb_refresh_isolate_deep_research` (mig_344) | 2026-11-09 22:17:12 |

(Applied under distinct `stageb_*` names to avoid collision with unrelated legacy `mig_341`/`mig_344` names
already in the migration history. `mig_342` / Explorer v5 was already live:
`20261109183305 image_gate_product_explorer_v5_image_only`.)

**Verified present:** 14 Stage B functions (quote, reserve, authorize, fire, dispatch, complete,
complete_from_edge, settle, status, reconcile, balance, is_refund, grant, grant_sweep); 4 tables (ledger,
request, price, allowance); `fn_kalodata_ingest_candidates` now has **exactly one** signature — the 7-arg with
`p_suppress_auto_research` (no 6-arg leftover → no overload ambiguity).

## 2. Actual deployed Kalodata edge version

- **`kalodata-discovery` version 13, status ACTIVE**, `verify_jwt=true`, entrypoint `index.ts`,
  `ezbr_sha256=358f35c66876e6c5f5a36bb94cc2447b206db4cde303f146891ae8e3d409a9bf` (deployed 2026-11-09 ~22:20 UTC).
- Contains all three Stage B changes: refresh execution + service-role completion callback; customer-refresh
  auto-research suppression; unconditional provider-usage recording.
- Previous **v12** source preserved verbatim as a rollback artifact:
  `supabase/functions/kalodata-discovery/_rollback_v12_index.ts.bak`
  (`ezbr_sha256=fba428c9cecc972ed471d6dc8511e361626a78d4db608cf422bf92e0ecbf86ba`).

## 3. Scheduled jobs verified

| Job | Schedule | Command | Active |
|---|---|---|---|
| `discovery-refresh-reconcile` | `*/15 * * * *` | `SELECT public.fn_discovery_refresh_reconcile(30)` | true |
| `discovery-subscription-credit-sweep` | `7 * * * *` | `SELECT public.fn_discovery_grant_subscription_credits_sweep()` | true |

Both **proven unable to initiate paid provider requests**: a manual run returned reconcile `0/0` (no stuck
requests) and sweep `active_tenants=2, granted=0, skipped_no_allowance=2` (no allowance configured → grants
nothing). Neither function contains any provider-call path.

## 4. Provider budgets inactive

0 active KALODATA budgets with headroom (0 active budgets of any provider for the Stage B path). Paid Kalodata
calls remain fail-closed via `fn_provider_budget_try_consume`.

## 5. Customer allowances / pricing unconfigured

`discovery_credit_price` active rows = 0; `discovery_credit_allowance` active rows = 0; `discovery_credit_ledger`
rows = 0; `discovery_refresh_request` rows = 0. Nothing is priced, granted, or charged.

## 6. Non-chargeable production smoke-test results (read-only / rolled back)

- `fn_discovery_refresh_quote('DE')` → `can_refresh=false`, reason `PRICING_NOT_CONFIGURED`.
- `fn_discovery_credit_balance()` → `0`.
- `fn_discovery_refresh_reserve('DE', …)` → `denied`, reason `PRICING_NOT_CONFIGURED` (no request/ledger row
  created).
- `fn_kalodata_discovery_request('DE',1)` (edge step 1, secret-free) → `ok=true`.
- `fn_kalodata_ingest_candidates(…, dry_run=true, suppress=false)` → `SUCCESS_WITH_CANDIDATES`,
  `auto_research_suppressed=false` (normal-wave path callable and unchanged).

## 7. Existing discovery regression results

- Product Explorer v5 (`fn_product_explorer('DE',…)`) → `pulse_product_explorer_v5`,
  `image_gated_display_only=true`, **9 visible / 20 hidden pending image** (unchanged from pre-deploy).
- Normal discovery wave behaviour preserved: the deployed edge passes `p_suppress_auto_research=false` when no
  `refresh_request_id` is present, so wave candidates still auto-dispatch research exactly as before; the only
  other DB caller (`fn_kalodata_commerce_adapter_selftest`, positional 6-arg dry-run) resolves to the 7-arg
  function with the new param defaulting false.
- Tenant/country isolation and Product Asset Lock (image-only gate) intact.

## 8. Rollback readiness

Reverse order, each step inert and reversible; **customer-data note:** no customer data has been written (0
ledger/request rows), so a full rollback loses nothing. If customer data exists at a future rollback, do NOT drop
the ledger/request tables — disable instead.
1. Redeploy edge **v12** from `_rollback_v12_index.ts.bak`.
2. `mig_344_ROLLBACK.sql` (restore original 6-arg ingest).
3. `SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('discovery-refresh-reconcile','discovery-subscription-credit-sweep');`
4. `mig_341c_ROLLBACK.sql`.
5. `mig_341_ROLLBACK.sql`.

## 9. Remaining founder-only domain / commercial steps

- **Activation (commercial):** subscription price (`ecommerce_monthly.amount_minor`); credits per refresh
  (`discovery_credit_price`, recommend 1); allowance per period (`discovery_credit_allowance`, ≤ funded budget);
  provider budgets per market (`provider_call_budget`); external unit prices (Kalodata/FastMoss/DataForSEO/CJ) for
  margin. Until these are set, the entire Refresh Discovery path stays fail-closed.
- **Domain cutover:** `strateloq.com` DNS + Lovable custom domain + Supabase Auth Site URL + Google OAuth origin,
  then publish frontend `c1a6afa`.

**Status: Stage B backend infrastructure DEPLOYED and fail-closed. Launch (18 Dec 2026) track unaffected;
security, quality, and data integrity preserved.**

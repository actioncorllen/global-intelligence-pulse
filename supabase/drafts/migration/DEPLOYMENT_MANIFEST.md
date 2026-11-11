# Kalodata Detail + Video — deployment manifest (PROPOSED, not executed)

STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A · prepared 2026-11-11 · commit lineage `652c315`→readiness.

**Nothing here has been executed.** No production records were modified, no functions deployed, no
chargeable Kalodata call made. Apply only via the **canonical Supabase pipeline** (`supabase db push` /
Management API `apply_migration`) from the real migrations repo — **not** by replaying this DR/docs repo,
and **not** the reference snapshot.

## Artifacts
- **Migration (one file):** `20261111000000_kalodata_detail_video_caller.sql` (wrapped `BEGIN…COMMIT`).
  Author it into the canonical repo with a fresh timestamp at apply time.
- **Edge functions (deploy 3):** `kalodata-product-detail`, `kalodata-video-rank`, `kalodata-video-detail`
  (`supabase/functions/*`). **Do NOT deploy** any `video/url` function (none exists; keep it that way).

## Pre-apply checks
1. Confirm the four documented contracts against the live authenticated Open Center pages
   (`need_extra` applicability, per-call credit cost, live market coverage, live response shapes).
2. Confirm these already exist in prod and are unchanged: `fn_persist_kalodata_product_detail`,
   `fn_discovery_refresh_quote/authorize/settle/is_refund`, `fn_provider_budget_try_consume`,
   `kalodata_invoke_nonce`, `discovery_provider_market_config`, `discovery_credit_ledger`,
   `provider_call_budget`, `discovery_refresh_request`.
3. `KALODATA_SECRET_KEY` Edge secret present (already set).

## Apply sequence (atomic migration, dependency order inside the file)
1. `fn_kalodata_detail_request`
2. `ALTER discovery_refresh_request ADD COLUMN IF NOT EXISTS operation text NOT NULL DEFAULT 'DISCOVERY_REFRESH'`
   — additive; **verified** no triggers, no CHECK conflict (status CHECK unchanged), `page_number` nullable,
   unique `(tenant_id, idempotency_key)` intact, and **no existing function reads `operation`**.
3. `kalodata_video_research` (+ RLS deny-all, indexes) — research-only, **no url/playback/media column**.
4. Video request builders (`video_rank`, `video_detail`, `video_url` HARD-BLOCKED).
5. `fn_kalodata_ingest_video_rank`, `fn_persist_kalodata_video_detail`.
6. `fn_kalodata_op_reserve`, `fn_kalodata_op_complete_from_edge`, `fn_kalodata_op_fire`,
   `fn_kalodata_run_product_detail/_video_rank/_video_detail`.
7. Self-test functions. 8. Grants.

Then: `supabase functions deploy kalodata-product-detail kalodata-video-rank kalodata-video-detail`.

## Pricing + budget (the chargeable approval gate)
- Confirm/add `discovery_credit_price` for detail/video (may differ from the discovery "refresh" price —
  pricing decision outstanding).
- Provision `provider_call_budget` (provider `KALODATA`, per tenant/market, approved `max_calls`,
  `active=true`). **Without an approved budget, `authorize` fails closed → no paid call.**

## Post-apply verification (no paid calls)
- `select public.fn_kalodata_product_detail_selftest();`  → 8/8
- `select public.fn_kalodata_video_selftest();`           → 10/10
- `select public.fn_kalodata_caller_lifecycle_selftest();`→ 12/12 (writes + cleans sentinel rows)
- One smoke call per operation for one market **after** budget approval: verify reserve→settle in
  `discovery_credit_ledger` and read the real per-call credit cost from the account page.

## Rollback
- Edge functions: redeploy the previous version (or delete the three new slugs).
- DB: the migration is additive. To revert, drop the new `fn_kalodata_*` functions + `kalodata_video_research`
  and (optionally) `ALTER … DROP COLUMN operation`. Existing discovery rows are unaffected either way.

## Hard constraints (keep)
- `video/url`, playback, downloads, permanent video storage, advertising reuse: **disabled** until Kalodata
  confirms video media rights.
- 9-market gate, tenant isolation, provider-budget fail-closed, one-time nonce: enforced and tested.

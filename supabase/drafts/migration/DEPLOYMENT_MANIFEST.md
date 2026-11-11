# Kalodata Detail + Video + Product Images — deployment manifest (PROPOSED, not executed)

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

## Product Images multi-image (Phase 13/14 — SECOND migration, apply after the bundle above)
- **Migration (one file):** `20261111010000_kalodata_product_images.sql` (wrapped `BEGIN…COMMIT`).
  **Depends on** the Phase 9 caller wiring (`fn_kalodata_op_reserve/op_fire/op_complete_from_edge`) from the
  bundle above — apply that first.
- **Edge functions (deploy 2):** `kalodata-product-images` (fetch + cache) and `kalodata-research-image-url`
  (short-lived owner-authorised signing; `verify_jwt=true`). Both in `supabase/functions/*`.
- **Storage (create 1 private bucket):** `pulse-research-reference` (private; Storage → New bucket, public=off).
  The edge reads `KALODATA_RESEARCH_BUCKET` (default `pulse-research-reference`). Research bytes are kept
  physically separate from `pulse-product-imports` (customer uploads) and `pulse-generated-media` (creatives).

  Apply sequence inside the file (additive, dependency order):
  1. `ALTER product_image_assets ADD COLUMN IF NOT EXISTS storage_ref / source_url_expires_at / cache_state / content_hash`
     — additive; existing rows default to NULL/`EXTERNAL`; hotlinked-image display is unchanged. `cache_state`
     CHECK + two partial UNIQUE indexes `(product_id, content_hash)` and `(storage_ref)` for dedup.
  2. `fn_asset_rights_class` **CREATE OR REPLACE** — Requirement 10 reclass (PROVIDER_DISCOVERY_REFERENCE +
     providers KALODATA/FASTMOSS → `RESEARCH_REFERENCE_ONLY`). **Verified fail-closed** (see the file header):
     publishable/ai-reference gates exclude research+unknown; the only other consumer
     (`fn_product_commercial_asset_readiness`) gates on RAW `rights_state`, not the derived class.
  3. `fn_kalodata_op_reserve` **CREATE OR REPLACE** — adds `PRODUCT_IMAGES` to the operation allow-list
     (identical body otherwise; lifecycle regression stays 12/12).
  4. `fn_kalodata_images_request`, `fn_persist_kalodata_research_image` (stores the object reference, NOT a
     signed URL), `fn_kalodata_research_image_exists`, `fn_product_image_signed_ref` (owner-only signing authz),
     `fn_kalodata_product_images_cached` (returns descriptors), `fn_kalodata_run_product_images`, selftest + grants.

  Then: `supabase functions deploy kalodata-product-images kalodata-research-image-url`.

- **SECURITY — no durable credentials (Phase 14 correction):** no long-lived signed URL is ever minted or
  stored. `image_url` holds the durable private-object reference (= `storage_ref`, non-http); `source_url` is
  provenance only. Delivery is short-lived (300s) and owner-authorised: the client exchanges `asset_id` for a
  signed URL via `kalodata-research-image-url` → `fn_product_image_signed_ref` (auth.uid()+ownership), the same
  mechanism `media-asset-url` uses for self-hosted video. Service-role never leaves the edge. Confirmed in
  ephemeral Postgres that `fn_product_explorer` (gates on `image_url ILIKE 'http%'`) and `fn_product_media_state`
  (orders `is_primary DESC`; cached refs are `is_primary=false`) keep the public main cover image and never emit
  the private reference as a URL — **no change to those two functions was needed.**
- **Pricing + budget:** reuses the SAME gate as the other operations — add/confirm `discovery_credit_price`
  for the images op and an approved `provider_call_budget` (`KALODATA`, `active=true`). **No approved budget →
  `authorize` fails closed → no paid call.** Cached products short-circuit BEFORE reserve (no credit).
- **Post-apply verification (no paid calls):** `select public.fn_kalodata_product_images_selftest();` → 11/11
  (contract, caching, dedup, tenant isolation, no-durable-credential, source-url-provenance-only,
  owner-only-signed-delivery, expiry, rights-class fail-closed, Product Asset Lock, credit reuse);
  `select public.fn_kalodata_caller_lifecycle_selftest();` → 12/12 (regression).
- **Rollback:** additive. Delete the new `fn_kalodata_*` / `fn_persist_kalodata_research_image` /
  `fn_product_image_signed_ref` functions, revert `fn_asset_rights_class`/`fn_kalodata_op_reserve` to their prior
  bodies, optionally `ALTER … DROP COLUMN storage_ref/source_url_expires_at/cache_state/content_hash`. Existing
  image rows are unaffected (new columns were NULL for them). Remove the two edge slugs.
- **Rights constraint (keep):** cached Kalodata images stay `PROVIDER_DISCOVERY_REFERENCE` / REFERENCE_ONLY —
  never publishable, never an ad / storefront / commercial-creative / AI-generation-reference source. The owning
  tenant only ever receives a short-lived signed URL (auth.uid()+ownership). Research-display use is covered by
  Kalodata's written research-display permission (blocker below — confirm in writing before go-live).

## Hard constraints (keep)
- `video/url`, playback, downloads, permanent video storage, advertising reuse: **disabled** until Kalodata
  confirms video media rights.
- Kalodata **product images are research-reference only** — cached for display to the owning tenant, never
  eligible for ads, storefront publishing, commercial creatives, or AI generation references.
- 9-market gate, tenant isolation, provider-budget fail-closed, one-time nonce: enforced and tested.

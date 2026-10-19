# PULSE-ECOM-FASTMOSS-PRODUCT-VIDEO-VERIFY-001

**One authorised live test (2026-10-19) of FastMoss `/product/v1/videoList` using the corrected broker
(v17) and the existing Krippen product id. Result: `/product/v1/videoList` is `ACCESSIBLE` — provider
returned `code 0 "success"` with 7 genuine product-associated videos. The 7 videos are integrated into
the existing discovery-media contract as REFERENCE_ONLY. Verdict: PASS. Maximum one FastMoss video API
call was made (now spent); no other provider calls, no subscriptions.**

## 1. Endpoint used — Product Video only
- Only `POST https://openapi.fastmoss.com/product/v1/videoList` was called. `/product/v1/search` was
  **not** called: broker v17 adds a `videos_only:true` flag that skips the search lane entirely
  (`search_lane_status:"SKIPPED_NOT_CALLED"`), so the one live call hit the Product-Video endpoint in
  isolation and did not re-touch the entitlement-blocked search endpoint.
- Reused infrastructure only: existing Edge broker `fastmoss-product-detail` (secret
  `FASTMOSS_CLIENT_SECRET` read from Edge env, never logged/returned; `verify_jwt=true`; trusted by
  service role or single-use nonce). Invoked server-side via `net.http_post` (the container egress
  proxy blocks `supabase.co`; `net.http_post` runs on Supabase infra — the same path discovery uses).
- Known product: Krippen — our product `5bc29d0a-b8e0-4fa9-bb80-d77197d770c4` (owner/tenant
  `7c8ddf9d-172c-4a89-a402-bb7066228b61`), FastMoss native id `1729937925462923841`, market **DE**.

## 2. Request body verified against the API contract
- Body sent (broker default videoList shape, `net._http_response` id 159):
  `{"filter":{"product_id":"1729937925462923841","region":"DE"},"page":1,"pagesize":10}`
  (broker echoed `video_request_keys:[page, filter, pagesize]`).
- This matches the FastMoss OpenAPI convention shared by the entitled discovery lane
  (`/product/v1/rank/newListed`) and documented list endpoints: a `filter` object keyed by
  `product_id` (+ `region`) plus `page`/`pagesize` paging. The earlier flat `{product_id}` body was the
  cause of the prior `code 1 "param error"` (PULSE-ECOM-FASTMOSS-EXPANDED-ACCESS-VERIFY-001); the
  corrected filter/paging body was accepted (`code 0`), confirming the contract shape.

## 3. Actual provider status + returned video fields
| Layer | Value |
|-------|-------|
| Edge transport (broker) | HTTP 200 |
| `video_http_status` (FastMoss transport) | 200 |
| `video_lane_status` | OK |
| Provider body `code` / `message` | **0** / **success** |
| `data.total` / `data.list` length | **7** / **7** |

Returned fields per video (genuine, as delivered — no fabrication):
- `video.uid`, `video.tiktok_url`, `video.cover`, `video.region` (DE), `video.duration`,
  `video.video_desc` (German marketing copy), `video.create_time`, `video.fastmoss_url`
- top-level: `video_id`, `product_id` (`1729937925462923841`), `seller_id` (`7494347337901901377`),
  `is_ad`, `gmv`, `play_count`, `digg_count`, `share_count`, `comment_count`, `units_sold`/`sold_count`,
  `sale_amount`, day7/14/28/60/90 gmv+units metrics, and `video_ad_info` (`roas`, `estimate_cost`).

The 7 videos (distinct TikTok creators, highest-reach first): `7695090492375174433` (26,000 plays),
`7695297723976666400` (6,135), `7695316039206325536` (1,005), `7695362161471704353` (780),
`7695227610627951904` (623), `7695292978062986529` (608), `7695296474254478625` (592).

## 4. Integration into the discovery-media contract — REFERENCE_ONLY (`mig_305`)
- The 7 videos are persisted into `public.media_assets` (the discovery-media video table) as
  `media_type='VIDEO'`, `source_type='PROVIDER_DISCOVERY_REFERENCE_VIDEO'`, `provider='FASTMOSS'`,
  `rights_state='PROVIDER_DISCOVERY_REFERENCE'`, `usage_permission='REFERENCE_ONLY'`,
  `is_launch_safe=false`, `country_code='DE'`. Each row's `provenance` carries
  `authority='REFERENCE_ONLY'`, `source_provider='FASTMOSS'`, `source_entity_id` (the video_id),
  `net_response_id=159`, and the exact provider object verbatim under `provider_raw`
  (no invented fields). `spec_ref` holds the genuine video descriptor (tiktok_url, cover, desc, …).
- New functions (definer-only, `service_role`; `SET search_path TO ''`, fully-qualified):
  `fn_persist_reference_video` (idempotent per-video persist; rejects any element with no genuine
  `video_id`/url — no fabrication) and `fn_fastmoss_integrate_reference_videos(response_id)` (resolves
  our product + owner from the provider-native id and the market from the response — no hardcoded ids;
  makes no provider call, only reads the stored response). A partial unique index
  `uq_media_assets_discovery_reference_video` enforces one reference row per (tenant, product, video_id).
- `fn_product_media_state` now surfaces the genuine REFERENCE_ONLY video (`primary_video` + `video_count`,
  authority REFERENCE_ONLY) and reports `VIDEO_AVAILABLE` for the Krippen product in DE (it previously
  reported `VIDEO_ACCESS_BLOCKED`). The video lane is now **market-isolated** (see §5).

## 5. Preserved — Asset Lock, tenant/country isolation, provenance
- **Product Asset Lock**: reference videos live ONLY in `media_assets`; nothing was written to
  `supplier_product_assets`. `is_launch_safe=false` and `REFERENCE_ONLY` authority mean they never
  unlock store / ad / creative / publishing. Selftest `ASSET_LOCK_NO_SUPPLIER_LEAK` = 0 leaks.
- **Tenant isolation**: `tenant_id` = the product owner's `user_id`; `fn_product_media_state`
  authorises by `auth.uid()` ownership (the caller's `p_tenant` arg is ignored). Cross-tenant read
  returns the denied shape with no video (`CROSS_TENANT_VIDEO_DENIED`).
- **Country isolation**: videos carry `country_code='DE'`; the media-state video lane is now
  market-filtered, so the DE evidence does **not** surface under any other market
  (`COUNTRY_ISOLATION_JP_EMPTY` — JP returns `video_count=0`). Legacy videos with no `country_code`
  keep their prior market-agnostic behaviour (backward compatible).
- **Source provenance**: raw provider code/message/data persisted in `net._http_response` id 159; each
  media row records `net_response_id=159` and the verbatim `provider_raw`.

## 6. Verification (PASS)
- `fn_fastmoss_product_video_reference_selftest()` → **7/7 PASS**: SEVEN_REFERENCE_VIDEOS (7),
  ALL_REFERENCE_ONLY_NOT_LAUNCH_SAFE (0 violations), ASSET_LOCK_NO_SUPPLIER_LEAK (0),
  OWNER_DE_VIDEO_AVAILABLE (video_state VIDEO_AVAILABLE, count 7), COUNTRY_ISOLATION_JP_EMPTY (count 0),
  CROSS_TENANT_VIDEO_DENIED (unauthorized), IDEMPOTENT_REINTEGRATION (re-run → still 7, no duplicates).
- No regression: `fn_discovery_media_integrity_selftest` 7/7, `fn_product_media_auth_selftest` 5/5 after
  the `fn_product_media_state` change.

## 7. ACCESSIBLE / BLOCKED summary
- `/product/v1/videoList` — **ACCESSIBLE** (HTTP 200, provider `code 0 "success"`, 7 videos returned).
- `/product/v1/search` — **BLOCKED** (provider 403 "can not access current endpoint"; not called in this
  test — `videos_only` skipped it). Still an external entitlement gap on the FastMoss plan.

## Remaining blockers
1. `/product/v1/search` entitlement remains off (external; founder must add that endpoint permission).
2. The one-call video cap is now spent; additional markets/products would each need a separate
   authorised videoList call. Only the Krippen DE product was integrated under this authorisation, so
   other FastMoss (product, market) pairs still report `VIDEO_ACCESS_BLOCKED` (no fabricated availability).

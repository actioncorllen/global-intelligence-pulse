# PULSE-ECOM-DISCOVERY-MEDIA-001

**Product discovery media integrity — FastMoss/Kalodata cover persistence fix (`mig_296`).**

## Root cause (where images were lost)
FastMoss `POST /product/v1/rank/newListed` returns a genuine product-native `cover` image URL per row
(verified live, e.g. `https://s.500fd.com/tt_product/<hash>~tplv-...-resize-jpeg:800:800.jpeg`). The
discovery broker passes full rows to `fn_fastmoss_ingest_candidates`, which read title/product_id/
price/shop/category/launch_time but **never read `cover`** — the image was dropped at ingest and never
reached `product_image_assets` or the Product Card. `fn_kalodata_ingest_candidates` had the same gap.

## Fix (permanent, reuses existing media tables; no blocked Product Detail API)
- `fn_extract_cover_url(row)` — first genuine http(s) URL among known cover keys (`cover`,
  `master_image_url`, `image`, `main_image`, `image_url`, `product_image`, `thumbnail`, camelCase),
  rejecting provider `/default/` placeholders. Never fabricates.
- `fn_persist_reference_image(...)` — idempotent (unique `(product_id,image_url)`) write of a
  REFERENCE_ONLY primary image into `product_image_assets` (`rights_state='PROVIDER_DISCOVERY_REFERENCE'`,
  `provenance.authority='REFERENCE_ONLY'`, source_provider/source_entity_id/market/observed_at).
- Both ingest functions now call persist on every real (non-dry-run) path (new / idempotent /
  correlated) — future discovery and any re-ingest of a still-listed product carry their cover.
  Historical products whose provider cover was never stored get **nothing fabricated**.
- `fn_product_media_state(tenant,product,market)` — Product-Card-safe media contract:
  `image_state` IMAGE_AVAILABLE|IMAGE_UNAVAILABLE, `video_state` VIDEO_AVAILABLE|VIDEO_UNAVAILABLE|
  VIDEO_ACCESS_BLOCKED (FastMoss-sourced products with no reference video persisted for that market),
  `video_count` and `primary_video` (genuine REFERENCE_ONLY provider video, `mig_305`; the video lane is
  market-isolated), `supplier_media_state` SUPPLIER_MEDIA_AVAILABLE|SUPPLIER_MEDIA_PENDING,
  `card_media_state` MEDIA_COMPLETE (only with a genuine primary image) | MEDIA_INCOMPLETE,
  `authority=REFERENCE_ONLY`.
- Selftest `fn_discovery_media_integrity_selftest()` — 7/7 pass.

## Kalodata image availability (§3)
Kalodata `product/rank` (entitled) exposes a `master_image_url` field but it is **NULL for every row**
on the current plan → `SOURCE_IMAGE_UNAVAILABLE` from the entitled Kalodata endpoint. The extractor
already includes `master_image_url`, so Kalodata covers will persist automatically if the field is ever
populated (or when a higher-tier Kalodata product-detail endpoint is granted).

## Product Asset Lock
Discovery reference media lives only in `product_image_assets` (REFERENCE_ONLY) — never in the Stage-4
authoritative `supplier_product_assets` (bound to exact supplier/SKU/variant, with asset_type/asset_class
covering main/gallery/variant/video + rights). Reference media must never unlock Create Free Store,
Create Ad, Publish Product, or Generate Commercial Creative. CJ exact-supplier media remains the only
authoritative merchant media.

## Frontend contract (§8 — no Lovable change made)
The Product Card consumes `fn_product_media_state`. To render discovery media, wire its
`primary_image.url` into the existing image slot, `gallery_count` for the gallery affordance, and gate
a "video" affordance on `video_state='VIDEO_AVAILABLE'`; show a MEDIA_INCOMPLETE badge when
`card_media_state='MEDIA_INCOMPLETE'` instead of a fabricated image. All such media is REFERENCE_ONLY
and must not enable merchant actions. Existing projection RPCs already key by tenant (`auth.uid()`) and
market, preserving tenant/country isolation.

## Video (§4) — UPDATED 2026-10-19 (`mig_305`)
FastMoss `/product/v1/videoList` is now **ACCESSIBLE** (entitlement opened; one authorised live call,
`net._http_response` id 159, returned `code 0 "success"` with 7 genuine product-associated videos for
the Krippen product in DE). Those 7 videos are integrated as REFERENCE_ONLY into `media_assets`
(`source_type='PROVIDER_DISCOVERY_REFERENCE_VIDEO'`, `is_launch_safe=false`, `country_code='DE'`,
verbatim `provenance.provider_raw`) — see PULSE-ECOM-FASTMOSS-PRODUCT-VIDEO-VERIFY-001.
`fn_product_media_state` now reports `VIDEO_AVAILABLE` + `primary_video` for that product in DE, with the
video lane **market-isolated** (DE evidence never surfaces under another market). The one-call cap is
spent, so FastMoss (product, market) pairs with no persisted reference video still report
`VIDEO_ACCESS_BLOCKED` — no fabricated video URLs. `/product/v1/search` remains BLOCKED (403, not
entitled).

## MCP note
The Supabase MCP `execute_sql`/`apply_migration` path stalls (60s) on destructive top-level statements
(`DELETE`/`DROP`); PostgreSQL is not locked. The selftest is therefore written cleanup-free (idempotent).
A leftover diagnostic no-op `public._stage_del_probe()` could not be dropped through MCP; drop it manually
via the Supabase SQL Editor: `DROP FUNCTION IF EXISTS public._stage_del_probe();` (non-launch-critical).

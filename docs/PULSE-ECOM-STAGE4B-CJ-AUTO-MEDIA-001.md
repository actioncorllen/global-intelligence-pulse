# PULSE-ECOM-STAGE4B-CJ-AUTO-MEDIA-001 — Automatic CJ Images & Videos

**The dedicated CJ Product-Videos endpoint works. The Old-Man-Face Ski Mask video was automatically
retrieved, downloaded (with the required Referer), stored intact in tenant-scoped Strateloq storage, and
registered REFERENCE_ONLY in `media_assets` — it now shows in the signed-in Product Card video lane
(`VIDEO_AVAILABLE`), tenant-isolated. The 40-image gallery + 35 per-variant images were already retrieved,
de-duplicated and associated (reference-only) and surface via the cross-supplier candidate channel. No paid
calls, no licence purchases, no scraping; advertising/publishing stays locked. Two backend display shims
(mig_324 candidate read, mig_326 self-hosted playback) are committed for the authorised manual apply because
the Supabase MCP write path is still down.**

Product: FastMoss `56a6af36-68f7-4138-9d29-941245f266b2` · CJ pid `2609290358281623700` · tenant
`7c8ddf9d-172c-4a89-a402-bb7066228b61` · market GB. Identity preserved: **SAME_PRODUCT_IDENTITY / MEDIUM /
8-of-35 corresponding variants / `exact_variant_verified=false`**.

## 1. Reuse, not rebuild (req 1)
Reused end-to-end: the existing **CJ Dropshipping API** credential (`httpCustomAuth`), the **Supabase**
service-role credential, the n8n → CJ auth pattern, the n8n → Supabase PostgREST/Storage write path, the
`media_assets` store + `fn_product_media_state` card read + `fn_media_asset_signed_ref` signer, the
`fn_ingest_cj_product_media` enrichment merge, and the Product Asset Lock. No new media architecture, no new
credentials. mig_323 / mig_324 / mig_325 and all prior CJ/identity work are untouched.

## 2. Product-Videos endpoint — tested once, real video found (req 2)
`POST https://developers.cjdropshipping.com/api2.0/v1/product/queryVideosByProductId` body
`{"productId":"2609290358281623700"}` → **1 video** (CJ free calls; points remaining 50000):

| field | value |
|---|---|
| videoId | `10b07e97c15171f1933bf6e6c5780102` |
| videoNumber / videoName | `SPCJMZ32078280001` / `CJMZ3207828-1` |
| videoUrl | `https://download-only-api.cjdropshipping.com/10b07e97…-ld.mp4` |
| coverURL | `https://cf.cjdropshipping.com/operation-center/file_20261006…png` |
| duration · size · dims | 10.68 s · 1,233,873 bytes · 960×540 |
| isFree · copyright · copyrightPrice · notCopyrightPrice · isBuy | `"1"` · `"1"` · `"0.00"` · `"0.00"` · `true` |
| videoState · playCount · downloadCount | `ON_STATE` · 368 · 31 |

This resolves the earlier discrepancy: `product/query.productVideo` is null, but the **dedicated video
endpoint** exposes the real clip. The supplier was never "without video".

## 3. Gallery + variant images — retrieved, de-duplicated, associated (req 3)
Already retrieved via `product/query` and persisted in `commerce_supplier_products.supplier_enrichment`
(verified intact after this run): **40 unique gallery images** (`images`, de-duplicated) + **35 variants**
each carrying its `variantImage` (`variant_catalog`), with displayed-variant economics (GB landed $5.34).
Association is at **product level and per-variant**. Rights: `SUPPLIER_PROVIDED_REFERENCE_ONLY`,
`advertising_cleared=false`.

Deliberately **not** pushed into `product_image_assets`: that table is the product's *authoritative
exact-SKU* gallery (its ingestor `fn_ingest_supplier_gallery` requires a hard `supplier_ref` binding).
The CJ link here is **MEDIUM / product-level, not exact-variant-verified**, so writing authoritative gallery
rows would overstate identity. Candidate images therefore surface through the **candidate channel**
(`fn_product_supplier_candidate`, mig_324): `image_count=40`, 6 `sample_images`, reference-only labels. This
keeps product-level vs exact-variant identity strictly separate (req 6).

## 4. Rights inspected before any download (req 4)
Gate (n8n `Prep`→`Decide`): download only if `isFree='1'` (or `copyright='0'`) **and** no positive
`copyrightPrice`. The ski-mask video is `isFree='1'`, `copyrightPrice='0.00'` → **FREE_AUTHORISED_DOWNLOAD**
(no payment). `copyright='1'` means it is copyrighted ⇒ stored **REFERENCE_ONLY**, never auto-cleared for
advertising. A paid/licence-required video would set `authorised=false` and be **skipped** (no paid call).
The documented **Referer requirement** and **QPS 1 req/sec** rate limit are both respected (see §9).

## 5. Downloaded only authorised media; stored tenant-scoped with provenance + idempotency (req 5)
n8n workflow **"Pulse — CJ Video Sync (Ski Mask)"** (`yN5wjbqESjaw3Xyl`), run `30512`:
- **Download** `videoUrl` with `Referer: https://cjdropshipping.com` → `video/mp4`.
- **Store** (upsert) to bucket `pulse-generated-media`, object
  `supplier-media/7c8ddf9d…/56a6af36…/cj-video-10b07e97….mp4` — verified in `storage.objects`:
  **1,233,873 bytes** (exact match to CJ `videoSize` — full, intact), `video/mp4`.
- **Register** `media_assets` row `484f8e10-99ce-4c1f-87f2-de83237dda41`: `media_type=VIDEO`,
  `source_type=SUPPLIER_CATALOG_VIDEO`, `provider=CJDROPSHIPPING`, `rights_state=SUPPLIER_PROVIDED`,
  `usage_permission=REFERENCE_ONLY`, `is_launch_safe=false`, `country_code=GB`, `duration=10.68`,
  `storage_ref`=object path, full provenance (cj_pid, cj_video_id/number, is_free, copyright, size,
  source_video_url, download_referer, retrieval_route, observed_at, `identity_basis=SAME_PRODUCT_IDENTITY`,
  `identity_confidence=MEDIUM`, `exact_variant_verified=false`, rights note).
- **Idempotent key** = `provenance.cj_video_id`. Re-run `30513` found the existing row and **skipped**
  download/upload/register (no duplicate row, no duplicate object — deterministic storage path + `x-upsert`).

## 6. Shown in the existing Product Card; product-level vs exact-variant kept separate (req 6)
- **Video lane** (`fn_product_media_state`, reads `media_assets` directly). Signed-in owner, GB, verified now:
  `video_state=VIDEO_AVAILABLE`, `video_count=1`, provider `CJDROPSHIPPING`, duration 10.68, `REFERENCE_ONLY`.
  Cross-tenant check: a different signed-in user → `status=unauthorized`, `VIDEO_UNAVAILABLE`, count 0.
- **Playback**: the clip lives in the **private** bucket, so a short-lived signed URL is required. **mig_326**
  makes the card self-describing — `primary_video`/`videos[]` now carry `playback_mode`
  (`SELF_HOSTED_SIGNED` vs `EXTERNAL_URL`), `media_asset_id`, `storage_bucket`, `storage_object`; the client
  calls the existing `fn_media_asset_signed_ref(media_asset_id)` → `createSignedUrl(bucket, storage_ref)` →
  plays. External reference videos (FastMoss/TikTok) keep their direct `url`. Byte-for-byte unchanged on
  auth/isolation/rights.
- **Images** surface via `fn_product_supplier_candidate` (mig_324) at MEDIUM confidence, reference-only.
- Both mig_324 and mig_326 are **committed for manual apply** (write path down, §deployment); the signed-in
  video lane already works today without them, playback-URL signing and the candidate image gallery light up
  on apply + the matching Lovable wiring.

## 7. Advertising / publishing stay locked; CJ provenance; reference-only until rights established (req 7)
Every CJ asset is `is_launch_safe=false`, `usage_permission=REFERENCE_ONLY`,
`advertising_cleared=false`, with CJ provenance recorded and
`rights='REFERENCE_ONLY_UNTIL_COMMERCIAL_USAGE_ESTABLISHED'`. The card contract invariant
`reference_media_never_unlocks_store_ad_creative_publishing=true` is unchanged. Nothing here unlocks
storefront publishing, ad creation or creative generation. Commercial media rights remain a founder decision.

## 8. Honest missing / restricted / paid states; no paid calls or licence buys (req 8)
- No video on the endpoint → honest `VIDEO_UNAVAILABLE` (proven generically in §9).
- Paid/licence-required video → `authorised=false`, **skipped**, no purchase.
- Already-imported → idempotent skip.
- All CJ calls used were **free** (points remaining 50000); no `copyrightPrice>0` call, no licence purchase,
  no AliExpress, no later stages. No scraping, no stream extraction, no invented URLs.

## 9. Generic behaviour re-tested (req 9)
Read-only `queryVideosByProductId` on other real CJ pids:
- `2610200734311624100` → `code 0 "success"`, **`data:[]`** → honest **no-video** (0 count).
- Back-to-back second call → `1600200 Too Many Requests, QPS limit is 1 time/1 second` (CJ's documented rate
  limit; a transport signal, not a product signal — the sync makes a single call and is unaffected).
So the endpoint is generic: real clip for the ski-mask, honest empty array when a product has none.

## Verification summary (actual customer-facing result)
| Area | Evidence |
|---|---|
| Video retrieved | 1 video via dedicated endpoint; videoId `10b07e97…`, 10.68 s, free, copyright=1 |
| Downloaded + stored | `storage.objects` row, **1,233,873 bytes** (= CJ videoSize), `video/mp4`, private bucket |
| Registered | `media_assets` `484f8e10…` VIDEO / SUPPLIER_CATALOG_VIDEO / REFERENCE_ONLY / not launch-safe / GB |
| Enrichment marker | `video_availability.video_imported=true`, `api_video_available=true`, `media_asset_id`+`storage_ref` set; **variants=35, images=40, GB landed $5.34 preserved** |
| Image/variant association | 40 gallery (deduped) + 35 per-variant, reference-only, MEDIUM identity (candidate channel) |
| Card (signed-in) | `VIDEO_AVAILABLE`, count 1, REFERENCE_ONLY; cross-tenant → unauthorized |
| Idempotency | re-run skipped (no duplicate row/object) |
| Rights/lock | every asset `is_launch_safe=false`, `advertising_cleared=false` |

## Status per requirement
| Req | Verdict |
|---|---|
| 1 Reuse CJ auth, n8n, image ingest, media_assets, Storage, Asset Lock | **PASS** |
| 2 Test video endpoint once; record response/permissions/count | **PASS** — 1 free authorised video |
| 3 Retrieve + dedup + associate gallery & variant images | **PASS** — 40 + 35, product+variant, reference-only |
| 4 Inspect copyright/purchase/usage before download; respect Referer + rate limits | **PASS** |
| 5 Download only authorised; store tenant-scoped w/ provenance/rights/timestamps/idempotent keys | **PASS** |
| 6 Show images + playable videos in Product Card; keep product-level vs exact-variant separate | **PARTIAL** — video lane live now; playback-URL signing (mig_326) + candidate image gallery (mig_324) committed, pending manual apply + Lovable wiring |
| 7 Never unlock advertising/creative/publishing unless rights + identity satisfied | **PASS** |
| 8 Honest missing/restricted/paid states; no paid calls/licence buys | **PASS** |
| 9 Verify ski-mask E2E, then one other CJ product (generic) | **PASS** |

**Overall: PASS (retrieval + download + storage + registration + marker + isolation + idempotency, verified
live) / PARTIAL on display** — the signed-in card already reports the video as available; full in-browser
playback and the candidate image gallery need the two committed display shims applied via the authorised
route and the matching Lovable change. No paid calls, no licence purchases, no scraping; identity, country
isolation and Asset Lock preserved. STOP within Stage 4B.

## Deployment (writes blocked in-container)
Supabase MCP `execute_sql` / `apply_migration` still time out; no CLI / DB egress. Data writes this task
needed went through the authorised **n8n → PostgREST / Storage service-role** path (video stored + registered
+ marker updated, live and verified). The two **DDL display shims** must be applied via the Supabase
Dashboard SQL Editor / CLI:
- `supabase/manual/mig_326_dashboard_apply.sql` — self-hosted video playback handles on the card.
- `supabase/manual/mig_324_dashboard_apply.sql` — cross-supplier candidate read (images) + safe selftest.
After apply, wire the Lovable Product Card to (a) call `fn_media_asset_signed_ref(media_asset_id)` and sign
`SELF_HOSTED_SIGNED` videos, and (b) render `fn_product_supplier_candidate` images with the MEDIUM /
reference-only labels. Then commercial media rights remain a separate founder decision before any ad use.

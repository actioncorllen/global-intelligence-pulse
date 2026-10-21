# PULSE-ECOM-STAGE4B-SUPPLIER-VIDEO-001

**Supplier/reference video retrieval for the Old-Man-Face Ski Mask (FastMoss `56a6af36…`, CJ pid
`2609290358281623700`, GB). Investigated why video was "missed" (it wasn't — CJ exposes none), confirmed
the existing media architecture already stores + displays videos with rights labelling, and prepared two
reuse-based video-ingest helpers (committed for manual apply). The founder's 10.7s clip is REFERENCE
evidence and can be ingested once its URL/source is provided; it is never treated as supplier-owned.
No new media architecture, no scraping, no paid calls. Writes blocked in-container → deploy via the
authorised Dashboard SQL Editor / CLI.**

## 1. Why the video was "missed" — it wasn't; CJ exposes none (req 1)
Fresh raw `product/query` for the pid (n8n execution 30507, HTTP 200, free) returned **`productVideo: null`**.
Full evidence:
- The only video-like key in the CJ response is `productVideo` (null). Other `material*` keys are fabric
  material ("Cloth"/"FABRIC"), not video.
- **No variant-level video**: every one of the ~37 variants has keys
  `vid,pid,variantName,variantNameEn,variantImage,variantSku,…` — there is **no `variantVideo`** field.
- **No nested media/video array**; the `description` HTML embeds only `<img>` tags, no `<video>`.
So CJ's authorised API genuinely exposes **no video** for this product. The earlier enrichment read the
correct documented field (`productVideo`) and correctly recorded zero — not a parsing bug.
→ **VIDEO_NOT_EXPOSED_BY_PROVIDER** for this CJ product. (CJ API v2 has no separate authorised
supplier-video endpoint beyond `productVideo`.)

## 2–3. Documented fields + reuse of existing media architecture (req 2, 3)
The platform already has a complete video architecture — reused, not rebuilt:
- **`media_assets`** is the canonical store (`media_type='VIDEO'`, `duration`, `rights_state`,
  `usage_permission`, `provenance`, `is_launch_safe`, `country_code`).
- **`fn_persist_reference_video`** already ingests FastMoss-discovery reference videos (REFERENCE_ONLY).
- **`fn_product_media_state`** already surfaces videos to the Product Card (`video_state`, `primary_video`,
  `videos[]`, `video_count`) with `auth.uid()` tenant isolation and country scoping.
- The CJ ingest reads `productVideo`; there is no variant video / nested array to parse for this product.

New (mig_325), reusing `media_assets`:
- **`fn_ingest_reference_video`** — generic independently-supplied reference video (e.g. the founder clip):
  stores `media_type=VIDEO`, `source_type=INDEPENDENT_REFERENCE_VIDEO`, `rights_state=REFERENCE_UNVERIFIED`,
  `usage_permission=REFERENCE_ONLY`, `is_launch_safe=false`, source RECORDED (not assumed), https-only,
  idempotent, tenant-ownership checked.
- **`fn_ingest_cj_product_video`** — future-ready: when a CJ product's `productVideo` is non-null, stores it
  `source_type=SUPPLIER_CATALOG_VIDEO`, `provider=CJDROPSHIPPING`, `rights_state=SUPPLIER_PROVIDED`, but
  `usage_permission=REFERENCE_ONLY`/not-launch-safe until advertising rights are confirmed.

## 4–5. Association + provenance + rights; never infer supplier ownership (req 4, 5)
Both helpers associate the video with the correct tenant + product (+ CJ pid for the CJ helper) and record
source, provenance and `observed_at`. Crucially, the founder clip is stored as **REFERENCE_UNVERIFIED /
REFERENCE_ONLY** with the note *"source and usage rights NOT established; NOT supplier-authoritative; shows
the product but ownership is unproven; never unlocks store/ad/creative/publishing until rights are
verified."* — i.e. it is **never inferred to be supplier-owned merely because it shows the product**.

## 6. No CJ video → report + preserve independently supplied media (req 6)
Result for this product: **VIDEO_NOT_EXPOSED_BY_PROVIDER** (CJ). The independently-supplied founder video is
preserved through the existing media store via `fn_ingest_reference_video` (no scraping). **It cannot be
ingested yet: its URL/source was not provided and it is not in storage** (only bucket `pulse-generated-media`
holds the old Nightlight creatives; 0 uploads in the last 7 days). → **BLOCKED pending the founder video URL
+ its rights basis.**

## 7. Product Card video display (req 7)
Already wired: `fn_product_media_state` returns `videos[]` + `video_state` and is proven to display videos —
the existing `fn_fastmoss_product_video_reference_selftest` shows a DE product with **7 reference videos**
rendering as `VIDEO_AVAILABLE`, all REFERENCE_ONLY / not-launch-safe, with country isolation
(`VIDEO_ACCESS_BLOCKED` for JP) and cross-tenant denial. For the ski mask the card honestly shows
`video_state=VIDEO_UNAVAILABLE` / `video_count=0` now, and will show the founder clip (REFERENCE_ONLY) once
ingested. No core card function was modified.

## 8. Tests (req 8)
- **With video**: existing selftest — 7 reference videos display (PASS).
- **Without video**: ski mask — `VIDEO_UNAVAILABLE`, count 0 (PASS, honest).
- **Invalid URL**: `fn_ingest_reference_video` / `fn_ingest_cj_product_video` reject non-`https` →
  `ok:false, invalid_or_missing_https_url` (verification query provided).
- **Variants**: CJ exposes no variant video, so none are fabricated.
- **Signed-in visibility + tenant isolation**: `fn_product_media_state` uses `auth.uid()` + ownership;
  cross-tenant denied (selftest `CROSS_TENANT_VIDEO_DENIED` PASS); `fn_ingest_reference_video` checks
  product ownership before insert.
- **Pre-existing defect flagged (not mine, not fixed):** `fn_fastmoss_product_video_reference_selftest`
  check `IDEMPOTENT_REINTEGRATION` fails (`count_after=7`) — a latent idempotency issue in
  `fn_fastmoss_integrate_reference_videos` (mig_305), unrelated to this task; recorded for a separate fix.

## Preservation
No writes were made. The SAME_PRODUCT_IDENTITY association (MEDIUM, 8 corresponding variants,
`variant_verified=false`), country/tenant isolation and Product Asset Lock are unchanged. All new video
rows are `is_launch_safe=false` / REFERENCE_ONLY, so they never unlock store/ad publishing.

## Deployment (writes blocked in-container)
Supabase MCP `execute_sql`/`apply_migration` still time out; no CLI/DB egress. Apply **mig_325** via the
Supabase Dashboard SQL Editor using `supabase/manual/mig_325_dashboard_apply.sql` (atomic, pre/post guarded,
idempotent). Then, when the founder video URL is known, run the `fn_ingest_reference_video(...)` call shown
at the bottom of that file.

## Status
| Req | Verdict |
|---|---|
| 1 Why video missed; inspect CJ responses/endpoints | **PASS** — CJ exposes none (`productVideo:null`, no variant/nested video) → VIDEO_NOT_EXPOSED_BY_PROVIDER |
| 2 Support video fields / nested arrays / variant video | **PASS** — read `productVideo`; none present; helpers ready for when CJ provides one |
| 3 Reuse existing media ingestion + Asset Lock | **PASS** — media_assets + fn_product_media_state reused; no new architecture |
| 4 Associate with product/variant + source/provenance/time/rights | **PASS (contract)** — helpers prepared; founder clip pending URL |
| 5 Never infer supplier-owned; founder clip is reference | **PASS** — REFERENCE_UNVERIFIED / REFERENCE_ONLY, ownership unproven |
| 6 No CJ video → report + preserve supplied media, no scraping | **PASS** (report) / **BLOCKED** (ingest pending founder URL) |
| 7 Card displays genuine videos w/ playback alongside images | **PASS (contract)** — card already renders videos; ski mask shows honest none until ingest |
| 8 Tests with/without/invalid/variants; signed-in + isolation | **PASS** (existing) / prepared; one pre-existing idempotency check flagged |

**Overall: PARTIAL.** Investigation complete and authoritative (CJ exposes no video); the existing media
architecture already retrieves + displays videos with correct rights/isolation and is reused; video-ingest
helpers are prepared and committed. Two blockers remain: (a) **the founder video URL/source + rights basis**
(to ingest it as REFERENCE_ONLY), and (b) **the Supabase MCP write path** (apply mig_325 via Dashboard/CLI).
No supplier ownership inferred, no scraping, no paid calls. STOP within Stage 4B.

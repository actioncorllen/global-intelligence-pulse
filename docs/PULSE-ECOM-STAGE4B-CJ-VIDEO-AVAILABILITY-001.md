# PULSE-ECOM-STAGE4B-CJ-VIDEO-AVAILABILITY-001

**Discrepancy resolved: CJ product `2609290358281623700` has a video on its official website product page
(founder-verified), but the authorised CJ Developer API exposes NO retrievable video for it — checked
across every documented product/media endpoint, not just `productVideo`. `WEBSITE_VIDEO_CONFIRMED` is now
preserved in live data; the authorised retrieval route is a user-import of the official file from the CJ
account via the existing media architecture (REFERENCE_ONLY). No scraping, no stream extraction, no invented
URLs, no paid calls.**

## State definitions (req 4)
- **WEBSITE_VIDEO_CONFIRMED = TRUE** — founder verified 1 playable video + 40 images on CJ's official
  product page.
- **API_VIDEO_AVAILABLE = FALSE** — no documented authorised CJ API endpoint returns a retrievable video
  URL for this pid (evidence below).
- **VIDEO_IMPORTED = FALSE** — not yet in `media_assets`; awaiting an authorised user-import of the file.

## 1–2. Authorised endpoints checked — none exposes the video (free CJ calls, no scraping)
| CJ API v2 endpoint (documented) | Result for this pid |
|---|---|
| `product/query` | `productVideo: null`; no variant-level video; `description` embeds only `<img>`; no nested media/video array |
| `product/variant/queryByVid` (vid 2610020815461625600) | variant fields only — **no video field** |
| `product/productComments` (pid, page 1, size 20) | `total: 0`, empty — no review media/video |

`productVideo` is the only video field in the Developer API and it is null; the other documented
product/media endpoints carry no video either. CJ API v2 has **no separate product-video or
marketing-material download endpoint**, and there is no authorised partner integration in this workspace
that would surface it. The website video is served by CJ's site/CMS and is simply **not exposed by the
authorised API** — this is a CJ API limitation, not a parsing miss, and not evidence that the supplier has
no video.

- **Account export / official media download:** CJ's open Developer API provides no product-video download.
  CJ's *merchant portal* (the logged-in CJ account website) does let a user download a product's official
  video/marketing materials — that is a manual, authorised action by the founder in their own account, not
  an API call and not scraping. That is the sanctioned retrieval route.

## 5. WEBSITE_VIDEO_CONFIRMED preserved (req 5) — done, via the authorised write path
Merged a `video_availability` marker into the CJ supplier row's `supplier_enrichment` through the existing
service-role RPC `fn_ingest_cj_product_media` (n8n → PostgREST; the MCP SQL write path is still down). No
video URL was stored or invented. Verified read-back (existing variant_catalog/images/economics preserved):
```
video_availability = {
  website_video_confirmed: true, website_video_count: 1, website_image_count: 40,
  api_video_available: false, video_imported: false,
  api_fields_checked: [product/query.productVideo=null, product/variant/queryByVid=no_video_field, product/productComments=empty_total_0],
  confirmed_by: "founder", retrieval_route: "AUTHORISED_USER_IMPORT_FROM_CJ_ACCOUNT",
  rights: "REFERENCE_ONLY_UNTIL_COMMERCIAL_USAGE_ESTABLISHED", import_fn: "fn_ingest_reference_video" }
```

## 6–7. Approved user-import route (reuse mig_325; CJ-website provenance; REFERENCE_ONLY)
No rebuild — reuse `fn_ingest_reference_video` (mig_325) + `media_assets` + Product Asset Lock. When the
founder downloads the official video from their CJ account, import it (after mig_325 is applied) with
CJ-website provenance and reference-only rights:
```sql
SELECT public.fn_ingest_reference_video(
  '7c8ddf9d-172c-4a89-a402-bb7066228b61'::uuid,        -- tenant
  '56a6af36-68f7-4138-9d29-941245f266b2'::uuid,        -- FastMoss ski-mask product
  'GB',
  'https://<official file the founder downloaded from the CJ account>',   -- never invented/scraped
  'CJDROPSHIPPING_WEBSITE',                            -- source RECORDED; NOT assumed supplier-owned
  10.7,                                                -- duration seconds
  jsonb_build_object('origin','CJ_WEBSITE_PRODUCT_PAGE','cj_pid','2609290358281623700',
                     'website_video_confirmed',true,'rights_basis','commercial_usage_not_established'));
```
This stores `media_type=VIDEO`, `rights_state=REFERENCE_UNVERIFIED`, `usage_permission=REFERENCE_ONLY`,
`is_launch_safe=false` — CJ website provenance recorded, **REFERENCE_ONLY until commercial usage is
established** (req 7). It never unlocks store/ad/creative/publishing.

## 8. Playback + isolation (req 8)
`fn_product_media_state` already renders videos to the signed-in Product Card (`video_state`,
`primary_video`, `videos[]`) under `auth.uid()` tenant isolation + country scoping — proven by the existing
FastMoss reference-video selftest (another product shows 7 reference videos as `VIDEO_AVAILABLE`, all
REFERENCE_ONLY, JP `VIDEO_ACCESS_BLOCKED`, cross-tenant denied). For this ski-mask product the card honestly
shows `VIDEO_UNAVAILABLE` until the file is imported; after import it will play as a REFERENCE_ONLY clip.
Full playback verification for THIS product is pending the imported file.

## Preservation
SAME_PRODUCT_IDENTITY (MEDIUM, 8 corresponding variants, `exact_variant_verified=false`), tenant/country
isolation and Product Asset Lock are unchanged. The only write was the additive `video_availability` marker
(existing enrichment preserved). No supplier ownership inferred; no scraping; no paid calls.

## Status
| Req | Verdict |
|---|---|
| 1 Another documented CJ media/product endpoint / partner integration exposes it? | **PASS (investigated)** — no; product/query, variant/queryByVid, productComments all carry no video |
| 2 Account export / official media download via API? | **PASS (investigated)** — none in the Developer API; only the merchant-portal manual download (authorised user action) |
| 3 No scraping / no stream extraction / no invented URLs | **PASS** |
| 4 Distinguish WEBSITE_VIDEO_CONFIRMED / API_VIDEO_AVAILABLE / VIDEO_IMPORTED | **PASS** — true / false / false |
| 5 Preserve WEBSITE_VIDEO_CONFIRMED | **PASS** — recorded in supplier_enrichment.video_availability (verified) |
| 6 Approved user-import via existing media architecture | **PASS** — fn_ingest_reference_video (mig_325), reuse |
| 7 CJ website provenance + REFERENCE_ONLY until commercial usage | **PASS (contract)** — import call specified; applies on import |
| 8 Signed-in card playback + tenant isolation | **PARTIAL** — contract proven on another product; this product pending the imported file |

**Overall: PARTIAL / RESOLVED-DISCREPANCY.** The API genuinely does not expose the video (confirmed across
all documented endpoints); the supplier is NOT claimed to have no video — `WEBSITE_VIDEO_CONFIRMED` is
preserved. The authorised retrieval mechanism is a founder download from the CJ account + import via the
existing REFERENCE_ONLY path. Remaining to finish playback: (a) the founder provides the downloaded file's
URL, (b) apply mig_325 (Supabase MCP write path still down → Dashboard/CLI). STOP within Stage 4B.

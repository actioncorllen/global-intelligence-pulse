# Kalodata Image Rights & Zero-Duplication Refinement (2026-11-10)

Builds on the 11/11 image-pipeline fixture PASS. **No paid provider call, no production change, no licensing change
deployed. PAL, tenant/market isolation and exact-product matching preserved.** Fixture-verified; prepared only.

## 1. Deployed `need_image` parameter state
The deployed rank request builder (`fn_kalodata_discovery_request`) sends `region, language, currency, date_range,
sort(revenue_growth_rate DESC), page_size:10, page_number, launch_date` — **`need_image` is OMITTED → defaults to 0
→ no image.** That is the exact reason the test's 10 rank candidates returned image-less. Per the official docs
(`/tiktok/product/rank`): `need_image` 0 = none, **1 = official main image URL (`master_image_url`)**, 2 = Kalodata
image URL (**paid service required**).

## 2. Is rank-with-image technically possible?
**Yes — a one-parameter change, zero new architecture.** Adding `'need_image', 1` to the rank `request_body` makes
the response carry `master_image_url`. The existing `fn_extract_cover_url` **already recognises `master_image_url`**,
`fn_kalodata_ingest_candidates` already calls `fn_persist_reference_image(..., fn_extract_cover_url(row))`, and the
Explorer gate already admits the result. **Fixture-proven today** (rolled back, no call): a rank row with
`master_image_url` → extracted → persisted on the exact pending product → `rights_state=PROVIDER_DISCOVERY_REFERENCE`
→ Explorer-visible → `fn_asset_rights_class` = `RIGHTS_UNKNOWN` (PAL blocks commercial) → re-persist idempotent
(1 asset) → `/default/` and image-less rows correctly rejected. **Prepared one-line change (NOT applied):**
```sql
-- in fn_kalodata_discovery_request request_body, add:  'need_image', 1
```

## 3. Best image-acquisition route and documented cost
| Route | Calls | Cost (per docs) | Image | URL persistence | Verdict |
|---|---|---|---|---|---|
| **A. Rank `need_image=1`** | **1 call / page (already made)** | standard rank (0.1 credit/page) **if `need_image=1` is non-paid** — docs flag only `need_image=2` as "paid service" | official main image URL (`master_image_url`) | **standard CDN URL → persistable as-is** | **PREFERRED** — image rides the rank call we already make; no extra call, no new code |
| B. Detail `need_image=1` | 1 call **per product** | detail-endpoint price × N (confirm) | `master_image_url` | standard CDN → persistable | On-demand single-product enrichment only (drawer/My Products), not bulk |
| C. `/tiktok/product/images` | 1 call per product | 0.01 credit/call × N | exact-product **signed URLs, expire in 5 min** | **NOT persistable directly → requires download + re-host** | Highest fidelity but operationally heaviest |

**Recommended: A.** It is the single ranking call the refresh already performs; if `need_image=1` is within the
standard rank price (as the docs imply, `need_image=2` being the paid tier), images arrive at **no extra
provider-credit cost and no extra calls**. The **exact credit cost of `need_image=1` must still be confirmed from
Kalodata billing** before enabling (do not assume the three endpoints price identically).

## 4. Image licensing status
**No written permission is documented in the project.** No provider licence/agreement/rights-grant storage exists
(only an unrelated `user_consent` table; no Kalodata config beyond the API secret). Kalodata's published general
Terms restrict certain commercial and third-party uses **without express written permission**. Therefore:
- Commercial SaaS ingestion, display of product images to paying customers, caching/persistent hosting, and
  multi-tenant/multi-country use are **NOT documented as permitted**; attribution/source-link is likely required.
- Per the directive, acquired images are **NOT marked cleared**. The engineering already keeps them display-only
  (`PROVIDER_DISCOVERY_REFERENCE`, commercial `RIGHTS_UNKNOWN`), but **whether even research display is permitted
  requires founder/legal confirmation of Kalodata's ToS, or written permission.** This is the gating item.
- A concise permission request for founder submission is in the Appendix.

## 5. Signed-URL handling
`fn_persist_reference_image` stores the URL **permanently and does not refresh it**. Consequences:
- **Routes A/B** (`need_image=1` official main image) return **standard CDN URLs** → safe to persist as-is (same as
  the FastMoss reference images already visible).
- **Route C** returns **5-minute signed URLs** → storing them directly would break after expiry. To use C safely,
  the image must be **downloaded within 5 minutes and re-hosted** in tenant-scoped Supabase Storage (the existing
  CJ-video download+rehost pattern), then the Storage URL persisted. **Do not persist C's signed URLs directly.**
  Route A avoids this entirely.

## 6. Fixture-test results (no spend, rolled back) — PASS
`master_image_url` extracted ✅ · persisted on exact product ✅ · Explorer-visible ✅ · rights
`PROVIDER_DISCOVERY_REFERENCE` ✅ · commercial `RIGHTS_UNKNOWN` (PAL) ✅ · idempotent single asset on re-persist ✅ ·
`/default/` placeholder rejected (stays hidden) ✅ · image-less (`need_image=0`) row → no cover ✅ · tenant/market
isolation (from prior run) ✅. Duplicate provider purchases prevented by `provider_call_budget` (unchanged).

## 7. Exact remaining founder action
1. **Cost:** confirm from Kalodata billing whether rank `need_image=1` is within the standard rank price (vs the
   `need_image=2` paid tier).
2. **Rights:** confirm (from Kalodata ToS) that displaying Kalodata product images to Strateloq customers as research
   reference is permitted — or submit the Appendix permission request and obtain written permission. **Gating item.**
3. **Enable:** on confirmation of #1 + #2, approve applying the one-line `need_image=1` change to the rank request
   builder. No separate paid image call is then needed — images arrive with each normal refresh at standard rank
   cost. Until then, nothing changes and image-pending products stay correctly hidden.

---

## Appendix — permission request to Kalodata (for founder submission)
> Subject: Written permission — display & caching of Kalodata product reference images in a commercial SaaS
>
> We operate Strateloq, a commercial SaaS product-intelligence platform, and access the Kalodata Open API
> (`tiktok/product/rank`, `/detail`, `/images`) under account [ACCOUNT]. We request written confirmation of which of
> the following uses our subscription permits, and any attribution/restriction that applies:
> 1. Ingesting Kalodata product data into our commercial SaaS backend.
> 2. Displaying Kalodata-sourced **product reference images** to our paying customers as **research/discovery
>    reference** (clearly non-advertising, non-storefront).
> 3. Caching / persistently hosting those images for display (and, if via the images endpoint, re-hosting the
>    5-minute signed URLs).
> 4. Any required **attribution or source link**.
> 5. Use across **multiple customer tenants** and **multiple supported countries** (e.g. DE/GB/US/…).
>
> We are **not** requesting rights for advertising creatives, resale, or storefront/commercial product listings —
> those remain separately gated in our system. Please confirm what is covered and what, if anything, requires a
> separate licence or written agreement.

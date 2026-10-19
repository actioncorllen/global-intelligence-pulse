# PULSE-ECOM-FASTMOSS-REMAINING-API-VERIFY-001

**Bounded live verification (2026-10-19) of the five remaining selected FastMoss endpoints, reusing the
existing credential (`FASTMOSS_CLIENT_SECRET`) and broker (`fastmoss-product-detail`). Documentation and
request shapes were confirmed first from the official developer docs; then exactly one bounded live call
per endpoint. Result: all five are ENTITLED and WORKING (HTTP 200, provider `code 0`). Two return NO_DATA
for the probed product. `/product/v1/search` remains BLOCKED (403) and was not retried. No new
subscriptions, bulk runs, frontend changes or unrelated audits.**

## Method (reused infra, documentation-first)
- Docs confirmed via `net.http_get` to `developers.fastmoss.com` (Supabase infra resolves it; the
  container's egress proxy does not). The endpoint nav and each endpoint's documented request body/response
  were read before any live call (`net._http_response` ids 160–166).
- Broker extended minimally to **v18**: a new `mode:"fm_raw"` allowlisted passthrough that may call ONLY the
  five paths below (`FM_RAW_ALLOW`) — no arbitrary host/path (no SSRF, no secret exfiltration), secret read
  from Edge env and redacted, `verify_jwt=true`, service-role/single-use-nonce trust unchanged.
  `/product/v1/search` is deliberately excluded from the allowlist.
- One bounded live call per endpoint via `fn_invoke_provider_broker` (mints a single-use nonce + server-side
  `net.http_post`). Product-level endpoints used the known Krippen product id `1729937925462923841` (DE);
  ranking endpoints used `region=DE`, `category_id=2`, `date_info={type:month,value:2026-09}`. Raw provider
  `code/message/data` persisted verbatim (redacted) in `net._http_response` ids 167–171. No ingest, no
  fabrication.

## Per-endpoint result

### 1. Top-selling Products — `POST /product/v1/rank/topSelling` — **WORKING**
- HTTP 200, provider `code 0`. `data.total=500`, `data.list=10` rows (req id 170).
- Returned fields per product: `product_id, title, cover, shop, category, region, currency, real_price,
  gmv, total_gmv, units_sold, total_units_sold, growth_rate, units_sold_growth_rate, commission_rate,
  launch_time, off_shelves`.
- **Relevance to paid Product Discovery: HIGH.** A core discovery ranking lane — best-selling products by
  GMV/units for a region+category+period, with the exact signals discovery uses (title, category, GMV,
  units, growth, price, commission). Complements the already-entitled `rank/newListed` lane.
- **Remaining access requirements:** none (entitled). `category_id` + `date_info` are required filters
  (documented); `category_id` should be a valid TikTok-Shop category.

### 2. Most Promoted Products — `POST /product/v1/rank/mostPromoted` — **WORKING**
- HTTP 200, provider `code 0`. `data.total=500`, `data.list=10` rows (req id 171).
- Returned fields: `product_id, title, cover, shop, category, region, currency, real_price, gmv,
  units_sold, affiliate_count, total_affiliate_count, commission_rate, launch_time, off_shelves`.
- **Relevance to paid Product Discovery: HIGH.** Surfaces products with heavy affiliate/creator promotion
  (`affiliate_count`, `total_affiliate_count`) — an advertising-emergence / commerce-momentum discovery
  signal distinct from raw sales.
- **Remaining access requirements:** none (entitled); same filter requirements as topSelling.

### 3. Historical Product Sales — `POST /product/v1/salesTrend` — **WORKING (+ genuine data)**
- Body `{filter:{product_id, days}}` (no region). HTTP 200, provider `code 0`. `data.list=7` daily rows +
  `data.overview` (req id 167).
- `data.list` fields: `date, units_sold, gmv, currency` (e.g. `2026-10-12 → 37 units, EUR 961.63`).
  `data.overview` fields: `units_sold, gmv, currency, region, live_count, creator_count, aweme_count`.
- **Relevance to paid Product Discovery: MEDIUM–HIGH (product-level evidence).** Daily demand trend + the
  overview counts (related lives/creators/videos) are strong Stage-2/Stage-3B commercial-validation and
  momentum evidence for an already-discovered product — country-specific (returned `EUR`/`DE`).
- **Remaining access requirements:** none (entitled). `days` is 1–28.

### 4. Product Reviews — `POST /product/v1/reviewList` — **WORKING, NO_DATA (for this product)**
- Body `{filter:{product_id}, orderby, page, pagesize}`. HTTP 200, provider `code 0 "success"`,
  `data = {list:[], total:0}` (req id 168) — the endpoint is entitled and the request shape is correct;
  this specific (seasonal, niche) product simply has no reviews.
- Documented fields when present: `review_id, uid, sku_id, sku_specification, rating, digg_count, content,
  create_time`.
- **Relevance to paid Product Discovery: MEDIUM.** Review volume/ratings/voice-of-customer are
  marketplace-validation + messaging evidence; empty here, useful across higher-review products.
- **Remaining access requirements:** none (entitled). Not a request-format defect — no fix needed.

### 5. Product Associated Creators — `POST /product/v1/creatorList` — **WORKING, NO_DATA (for this product)**
- Body `{filter:{product_id}, orderby, page, pagesize}`. HTTP 200, provider `code 0 "success"`; `data`
  returned the request context `{region:"DE", seller_id:"7494347337901901377", product_id:"1729937925462923841"}`
  with no `list`/`total` rows (req id 169) — entitled, documented shape accepted, no associated-creator
  rows for this product in the queried window.
- Documented `data.list` fields: `uid, unique_id, …` (the creators promoting the product, sortable by
  `units_sold | gmv | follower_count | digg_count`).
- **Relevance to paid Product Discovery: MEDIUM–HIGH.** Maps a product to the creators driving it — an
  affiliate/community discovery + outreach signal. (The product's 7 reference videos came from the
  videoList lane; this list-by-sales lane returned none for it, likely because it attributes creator
  **sales**, which this product lacks here.)
- **Remaining access requirements:** none (entitled). Not a request-format defect — no fix needed.

## Summary table
| Endpoint | API path | Verdict | Returned |
|----------|----------|---------|----------|
| Top-selling Products | `POST /product/v1/rank/topSelling` | **WORKING** | 500 total, 10 rows, 17 product fields |
| Most Promoted Products | `POST /product/v1/rank/mostPromoted` | **WORKING** | 500 total, 10 rows, incl. affiliate_count |
| Historical Product Sales | `POST /product/v1/salesTrend` | **WORKING** | 7 daily rows + overview (DE/EUR) |
| Product Reviews | `POST /product/v1/reviewList` | **WORKING / NO_DATA** | `{list:[], total:0}` for this product |
| Product Associated Creators | `POST /product/v1/creatorList` | **WORKING / NO_DATA** | context only, no list for this product |
| (Product Search) | `POST /product/v1/search` | **BLOCKED (403)** | not called (never retried) |

## Entitlement picture
The expanded FastMoss grant now covers **all five** of these endpoints plus the previously-confirmed
`rank/newListed` (discovery) and `videoList` (product videos). The **only** endpoint still denied is
`/product/v1/search` (403 "can not access current endpoint") — an external plan-permission gap the founder
must add. No request-format defect was found in any of the five (all accepted the documented body); the two
NO_DATA results are genuine empties for this specific product, not errors.

## Preserved
Source provenance (raw provider `code/message/data` in `net._http_response` ids 167–171; docs in 160–166);
existing credential + broker reused (no new credentials, subscriptions, upgrades or bulk runs); secret read
only from Edge env and redacted; exact-product matching, 18-market country isolation, Product Asset Lock and
the Product-Video integration untouched (verification only — no ingest, no frontend changes).

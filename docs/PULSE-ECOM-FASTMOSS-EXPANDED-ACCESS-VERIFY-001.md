# PULSE-ECOM-FASTMOSS-EXPANDED-ACCESS-VERIFY-001

**Bounded live verification (2026-10-19) of expanded FastMoss API access after the founder saved
additional permissions on the existing Strateloq FastMoss developer secret. One live call per named
endpoint, via the existing broker + credential (`FASTMOSS_CLIENT_SECRET`). No new credentials, no
subscriptions/upgrades, no extra paid calls. Result: `/product/v1/search` STILL BLOCKED;
`/product/v1/videoList` now REACHABLE but request-shape defect; NO genuine fields returned → nothing
integrated (no fabrication).**

## How the test was run (reused infra)
- Broker: existing Edge function `fastmoss-product-detail` (secret read only from Edge env, never
  logged/returned; trusted by service role or single-use nonce). Invoked server-side via
  `net.http_post` (the container's egress proxy blocks `supabase.co`, so a direct curl is not
  possible; `net.http_post` runs on Supabase infra — the same path `fn_fastmoss_run_discovery` uses).
- One edge invocation with `{market:"DE", product_id:"1729937925462923841", with_videos:true}` →
  exactly one `POST /product/v1/search` + one `POST /product/v1/videoList`. Known product:
  Krippen's FastMoss id (`commerce_products.extended.fastmoss_product_id`, DE).

## Result per endpoint
| Endpoint | HTTP (transport) | Provider body code | Provider message | Verdict |
|----------|------------------|--------------------|------------------|---------|
| `POST /product/v1/search` | 200 | **403** | `can not access current endpoint` | **BLOCKED** — not entitled (unchanged by the new permissions) |
| `POST /product/v1/videoList` | 200 | **1** | `param error` | **REACHABLE, NOT ENTITLEMENT-BLOCKED** — endpoint responded (no 403); broker sent the wrong request body |

- Actual fields returned: **none**. Both responses had `data: []`. No descriptions, attributes,
  images, variants or video URLs were returned by either endpoint. (Secrets redacted by the broker.)
- The `403 "can not access current endpoint"` is FastMoss's explicit entitlement-denied message; the
  distinct `code 1 "param error"` on videoList is a request-schema rejection, not an entitlement block
  — so the expanded permissions appear to have opened the videoList endpoint group but **not**
  `/product/v1/search`.

## Other newly selected APIs (checked without extra paid calls)
- Entitlement is only authoritatively knowable from a live response, and the authorisation caps live
  testing at the two named endpoints, so other endpoints were **not** called.
- Inferred from existing evidence: `/product/v1/rank/newListed` (discovery) is **entitled and working**
  (it populated the 10 ingested FastMoss products). Combined with this test, the grant is **partial**:
  discovery + videoList-group reachable; `/product/v1/search` still denied. A precise per-endpoint
  entitlement map for the remaining APIs needs either the founder's saved-permission list or one
  authorised probe call each (not performed).

## Internal fix deployed (broker `fastmoss-product-detail` v16)
- `videoList` previously sent a flat `{product_id}` → `param error`. Both request bodies now default to
  the **entitled `search` contract shape** (`{filter:{product_id, region}}`, + `page/pagesize` for
  videoList) and accept per-call `search_body` / `video_body` overrides, so the exact documented schema
  can be supplied on the next authorised call **without a redeploy**. Response transparency added
  (`search_request_keys`/`video_request_keys`). Secret handling, nonce/service-role trust, redaction
  and `verify_jwt=true` unchanged.
- The corrected `videoList` body is **UNVERIFIED** — re-testing needs one more founder-authorised live
  call (test cap already reached: 1/endpoint).

## Integration into Product Identity / discovery-media / workspace contracts
- **None.** Access returned no genuine product fields (search blocked; videoList param error, empty
  data). Per the no-fabrication rule, no fields were added to any contract. The contracts remain as
  deployed; FastMoss product-native data still comes only from the entitled discovery lane.

## Preserved
Source provenance (raw provider code/message persisted in `net._http_response` id 158; no fabricated
fields); exact-product matching, 18-market country isolation and Product Asset Lock untouched (no
asset/field ingestion); existing credential + broker reused (no new credentials).

## ACCESSIBLE / BLOCKED summary
- `/product/v1/search` — **BLOCKED** (provider 403 not entitled).
- `/product/v1/videoList` — **REACHABLE / NOT YET USABLE** (entitlement open, request-shape fix
  deployed, pending one authorised re-test).

## Remaining blockers
1. `/product/v1/search` entitlement is still off — the founder must add that specific endpoint
   permission on the FastMoss plan (external).
2. `/product/v1/videoList` usability needs one more founder-authorised live call to confirm the
   corrected request body and capture the real fields (video URLs etc.); only then can genuine fields
   be integrated.
3. The exact FastMoss `videoList` request schema is not documented in-repo; if the mirrored
   filter/paging body still returns `param error`, pass the documented body via the new `video_body`
   override on that one authorised call.

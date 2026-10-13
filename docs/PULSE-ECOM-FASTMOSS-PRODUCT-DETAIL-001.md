# PULSE-ECOM-FASTMOSS-PRODUCT-DETAIL-001

**FastMoss product-native detail enrichment — capability built & verified; BLOCKED on provider endpoint entitlement.**

## Goal
Close the product-identity / reference-media gap for discovered FastMoss products (e.g. the
pipeline cannot resolve a concrete product identity for listings whose only persisted field is a
marketing title) by reusing the existing FastMoss OpenAPI integration to fetch product-native
detail by provider product id.

## What exists (reused, unchanged)
- DB: `fn_fastmoss_discovery_request`, `fn_fastmoss_run_discovery`, `fn_fastmoss_ingest_candidates`,
  `fn_fastmoss_record_lane_outcome` — **discovery-only** (market-wide `New Listed` rank).
- Edge function `fastmoss-discovery` (broker): `POST https://openapi.fastmoss.com/product/v1/rank/newListed`,
  `Authorization: Bearer <FASTMOSS_CLIENT_SECRET>` (secret only in Edge env), trusted by service-role
  or single-use nonce (`fn_kalodata_consume_invoke_nonce`).
- Reference-media tables already present: `product_image_assets` (images; structurally separate from
  the Stage-4 authoritative `supplier_product_assets`) and `media_assets` (video).

## What was added
- Edge function **`fastmoss-product-detail`** (new broker), same trusted-server/secret-safe pattern.
  Calls the documented product-by-id endpoints:
  - `POST /product/v1/search`    body `{ filter: { product_id, region } }`
  - `POST /product/v1/videoList` body `{ product_id }`
  It returns the raw (secret-redacted) provider payloads + HTTP statuses so the real schema and
  entitlement can be verified **before** any persistence mapping is built (never map from a guess).
  No DB writes, no ingest, no persistence yet.

## Verification result (one bounded real call, product id 1729904172727703590, DE)
- Edge transport: HTTP 200 (broker reached FastMoss, auth accepted, response parsed).
- FastMoss application response, **both** endpoints:
  `{ "code": 403, "data": [], "message": "can not access current endpoint" }`.
- Interpretation: the secret is authenticated (it works for `/rank/newListed`) but the account's
  **plan does not entitle the product-detail / product-video modules**. This is a provider
  entitlement blocker, not an auth, code, or request-shape failure (an invalid token or bad params
  would return a different error; both detail endpoints returned the identical access message).

## Status
# `BLOCKED_EXTERNAL_PROVIDER_ENTITLEMENT`
Everything internally controllable is done and verified: integration inspected, broker built,
deployed, and proven to correctly authenticate against FastMoss and parse responses. The only
remaining requirement is **external**: FastMoss account access to `POST /product/v1/search` and
`POST /product/v1/videoList` (the Product-detail / Product-video API modules) under the plan whose
`FASTMOSS_CLIENT_SECRET` is provisioned. No new purchase was initiated.

The broker is the ready **activation point**: it stays deployed but dormant (nothing auto-invokes
it; it requires service-role or a single-use nonce). The moment FastMoss grants the endpoints, one
bounded call returns real detail, after which the persistence → identity (`fn_derive_concrete_product_identity`,
unchanged) → reference-media (`product_image_assets` / `media_assets`, `authority=REFERENCE_ONLY`)
→ brand/IP recheck → Stage-2E readiness path can be wired against the **observed** schema.

Deferred until entitled (intentionally NOT built against a dead endpoint): the persistence RPC,
the on-demand durable enrichment lifecycle, and the frontend-safe `reference_media` projection
block.

## Boundaries honored
No CJ call. No Stage 3. No broad discovery re-run. No DataForSEO/eBay/TikTok scraping. No fabricated
product data/identity/media. No DB writes. Product Asset Lock unchanged — reference media (none
obtained) would live in `product_image_assets`/`media_assets` as `REFERENCE_ONLY`, never in the
Stage-4 authoritative `supplier_product_assets`, and must never unlock store/ad/creative/publishing.

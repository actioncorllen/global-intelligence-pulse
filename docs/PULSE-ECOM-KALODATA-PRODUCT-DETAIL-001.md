# PULSE-ECOM-KALODATA-PRODUCT-DETAIL-001

**Kalodata Product Detail capability test — ENTITLED but ANALYTICS-ONLY (no descriptive identity).**

## What was tested
Newly-documented endpoint `POST https://www.kalodata.com/openapi/v1/tiktok/product/detail`
(Kalodata Open API, `secret-key` header), using the **existing** `KALODATA_SECRET_KEY` through the
existing trusted broker (`fastmoss-product-detail` edge function, new `mode:"kalodata_detail"`,
service-role/single-use-nonce only, secret never logged/returned). Two bounded real calls, DE market.

## Result — capability WORKS (not blocked)
Both calls returned **HTTP 200, `success:true`** with the existing credential — no new subscription,
no 403/entitlement error. Product id + region (`de`) matched on both.

| product | kalodata_product_id | http | product_description | attributes | variants | master_image_url |
|---|---|---|---|---|---|---|
| Hit the Slab | 1729945300622678813 | 200 ok | `[]` (empty) | none | none (max=min price) | `null` |
| SOPAMI Flachmopp | 1729925309691369889 | 200 ok | `[]` (empty) | none | none (max=min price) | `null` |

The response is a **commerce/analytics detail**, not a product-catalog detail. Fields returned:
`product_name` (= the discovery title we already hold), `product_shop_id`, numeric
`pri/sec/ter_cate_id` (category IDs only, **no names**), `max_price`/`min_price`, `revenue` split
(live/video/showcase), `sales_volumn`, `creator/video/live_number`, `unit_price`,
`product_review_count`, `launch_date`, `delivery_type`. It does **not** return: product description
(empty array on both products), structured attributes, variant/SKU arrays, product images
(`master_image_url` null on both), category names, or product videos.

## Consequence for identity resolution
The detail endpoint supplies **no descriptive catalog content**. For a product whose TikTok display
name lacks descriptive nouns (e.g. "Hit the Slab"), it cannot establish a specific physical identity —
`product_name` is the same bare name discovery already captured, and category IDs alone are not a
concrete identity. **Hit the Slab remains `NO_CONCRETE_EVIDENCE` / `INSUFFICIENT`, Stage-2E eligible =
NO.** Category IDs must never manufacture identity; missing description/image/attributes/variants are
never coerced into values.

(SOPAMI's `product_name` *is* descriptive, but that is the title the product-native path already uses;
the detail endpoint added no new descriptive identity. SOPAMI is not a Stage-2 target — qf=1.)

## What was built (smallest durable integration)
- Broker `fastmoss-product-detail` v4: added `mode:"kalodata_detail"` (deployed). Reuses `secret-key`
  auth + the rank request conventions (region/currency/language) + `product_id`; one call, no ingest,
  response redacted; classifies `AUTH_OR_ENTITLEMENT_FAILED`/`PAYMENT_REQUIRED`/`RATE_LIMITED`/etc.
- `fn_persist_kalodata_product_detail(tenant, product, market, detail jsonb)` — persists source-native
  detail under `extended.kalodata_detail` with provenance (provider, kalodata_product_id, market,
  retrieved_at, endpoint), persists `master_image_url` as a REFERENCE_ONLY image **only when genuinely
  present** (never promoted to authoritative supplier assets), and reports
  description/attributes/variants/image presence. Tenant-scoped (`user_id`), fail-closed,
  `SECURITY DEFINER`, **EXECUTE revoked from PUBLIC/anon/authenticated** (internal/service-role only,
  because it authorizes on the supplied `p_tenant`). Identity derivation is unchanged: category IDs and
  analytics are provenance context, never distinguishing identity attributes.

## Deployment note (MCP DDL transport timeout)
On project `nxaunmyihhjixxxljcqt`, `apply_migration` and `execute_sql` **DDL** (and one DML UPDATE)
calls for this migration each timed out at 60s at the MCP transport layer while PostgreSQL was healthy
(read-only `pg_stat_activity`/`pg_locks` showed zero active sessions, zero waiters, zero ungranted
locks; reads and `net.http_post` DML succeeded). The function and the Hit the Slab persistence did
**not** land. `mig_298` is therefore applied once via the Supabase Dashboard SQL Editor (the file is a
single idempotent block: function + revokes + persistence). The broker v4 deploy used a different
transport and succeeded.

## Boundaries honored
No new subscription. No CJ. No Stage 3. No fabricated identity/media. Reference/analytics media never
promoted to Stage-4 authoritative `supplier_product_assets`; Product Asset Lock and Stage-2E guard
untouched. Country/tenant isolation preserved. Secrets referenced by env id only.

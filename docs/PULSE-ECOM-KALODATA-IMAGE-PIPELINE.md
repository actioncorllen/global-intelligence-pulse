# Kalodata Discovery → Visible-Product Image Pipeline (2026-11-10)

Design + fixture verification to make image-pending Kalodata products customer-visible, rights-safely, reusing the
existing asset architecture. **No paid provider call. No deploy. Product Asset Lock not weakened.** Prepared only.

## 1. Kalodata image API compatibility
The platform **already has a Kalodata image contract**: `fn_persist_kalodata_product_detail` (mig_298) consumes a
Kalodata `tiktok/product/detail` response — it reads `master_image_url` (plus `product_description`, `attributes`,
`variants`, `pri/sec/ter_cate_id`) and, when the image is https and not a `/default/` placeholder, persists it via
`fn_persist_reference_image`. The founder's pricing note referenced a separate "Product Images API" at 0.01 credit;
the **exact endpoint and billing unit for images vs. detail must be confirmed from Kalodata's Open Center docs** (I
did not call either). Either way the response is keyed by the **exact Kalodata product id**, so it is compatible.

Answers to the 10 P1 questions:
1. **Endpoint:** existing coded path = `tiktok/product/detail` (returns `master_image_url`); founder-referenced
   `Product Images API` is an alternative — confirm the exact URL from Kalodata docs.
2. **Required id:** the Kalodata `product_id` (stored on each candidate at `commerce_products.extended.kalodata_product_id`). The 3 pending products have theirs.
3. **Exact resolution:** yes — keyed by the exact product id; no similar-product substitution.
4. **Billing unit:** one call per product id. **Do not assume 3 calls = 0.03 credit** until Kalodata's billing contract is confirmed.
5. **Cost:** reference 0.01 credit per Images-API call; detail-endpoint cost needs confirmation.
6. **Quality/quantity:** detail returns a primary `master_image_url`; the Images API may return a gallery — confirm from docs.
7. **Response fields:** `master_image_url`, `product_description`, `attributes`, `variants`, category ids (already parsed by the existing function).
8–10. **Display rights / commercial reuse / written permission:** **NOT established by code — see §2.**

## 2. Verified display and commercial usage-rights evidence — NOT YET ESTABLISHED (legal gate)
The engineering treats a Kalodata image as **`PROVIDER_DISCOVERY_REFERENCE`** — `authority=REFERENCE_ONLY`,
"research media; NOT supplier-authoritative; never unlocks store/ad/creative/publishing"; `fn_asset_rights_class`
classes it **`RIGHTS_UNKNOWN`** for commercial purposes, so Product Asset Lock keeps it out of ads/storefronts.
That is the display-only, not-commercial posture the platform uses for provider research media.

**However, whether Kalodata's Open Platform Terms of Service permit Strateloq to DISPLAY Kalodata-sourced product
images (even as internal research reference), and any attribution/restriction, is a LEGAL determination that must
be confirmed by the founder/legal from Kalodata's documentation/contract. It cannot be inferred from the API
returning an image.** Per the directive, no image-rights change is deployed until this is confirmed. This is the
**#1 gating item**, independent of cost.

## 3. Exact-product matching method
`commerce_products.extended.kalodata_product_id` → Kalodata detail/images call for that exact id → response's
`master_image_url` → `fn_persist_kalodata_product_detail` persists it on **that exact `product_id`** (ownership-
checked). No fuzzy/similar matching. Verified in fixtures (exact match succeeds; wrong tenant → `not_owned`).

## 4. Existing-architecture reuse plan (smallest integration)
Reuse, unchanged: `fn_persist_kalodata_product_detail` · `fn_persist_reference_image` (idempotent, http-only,
`/default/`-rejecting, assigns `PROVIDER_DISCOVERY_REFERENCE`) · `product_image_assets` · Explorer image gate
(mig_342) · `fn_asset_rights_class` / PAL · `provider_call_budget` fail-closed metering.

**Only new component:** a budget-gated edge step that calls Kalodata detail/images for a given product id and feeds
the response to `fn_persist_kalodata_product_detail` — the exact pattern of the existing `kalodata-discovery` edge
(nonce-gated, secret in edge env only, one `provider_call_budget` unit per call, records usage). Flow:
`Kalodata product id → authorised detail/images call → response → rights validation (http + not /default/, class
PROVIDER_DISCOVERY_REFERENCE) → product_image_asset → Explorer visibility`. Commercial use still independently gated
by PAL. If the image is missing / placeholder / rights unconfirmed → product stays hidden, evidence preserved.
**Prepared design; the edge is NOT built or deployed until §2 rights are confirmed.**

## 5. Fixture-test results (no spend, transactional rollback) — 11/11 PASS
Exact-product matching ✅ · wrong-product/tenant rejection (`not_owned`) ✅ · image URL validity (https required) ✅ ·
`/default/` placeholder rejected, product stays hidden ✅ · non-http rejected, stays hidden ✅ · market isolation ✅ ·
rights-state = `PROVIDER_DISCOVERY_REFERENCE` ✅ · display eligibility (gate visible) ✅ · PAL / commercial =
`RIGHTS_UNKNOWN` ✅ · idempotent ingestion (single asset on re-persist) ✅ · no hidden product becomes visible without
eligible rights ✅. (Provider-budget "no duplicate purchase" is enforced by `provider_call_budget` max_calls, as in
the passed rank test.)

## 6. Maximum proposed provider-credit expenditure
**≤ 3 calls — one per pending product** (`cee549c3…`, `4e6acd83…`, `e45a427a…`), hard-capped by a tenant-scoped
`provider_call_budget` `max_calls=3`. At the 0.01-credit reference that is ≤ 0.03 provider credit (≈ $0.003), **but
do not treat 0.03 as fixed** until Kalodata's billing unit per call is confirmed. No purchase authorised by this
document.

## 7. Can all three be made customer-visible safely?
**Technically yes, conditionally.** Up to 3 can become visible **iff** (a) the detail/images call returns a valid
https `master_image_url` per product (detail endpoints normally do), **and** (b) Kalodata's ToS permits research
display of those images (§2, legal — unconfirmed). Any product whose image is missing/placeholder or whose rights
are unconfirmed **stays hidden** (safe by design). So: 0 guaranteed today; up to 3 after rights confirmation + the
bounded test.

## 8. Exact founder approval required before any paid image request
1. **Rights:** confirm (from Kalodata's Open Platform ToS/contract) that displaying Kalodata product images as
   internal research reference is permitted, with any attribution/restriction — the gating item.
2. **Contract:** confirm the exact endpoint + per-call billing unit + cost from Kalodata docs.
3. **Expenditure:** authorise the bounded **≤ 3-call** image test (`provider_call_budget max_calls=3`), ceiling
   ≤ 0.03 credit (pending #2).
No paid image call runs until all three are given. PAL, tenant/market isolation, and exact-product fidelity are
preserved throughout; placeholders are never shown as real product images.

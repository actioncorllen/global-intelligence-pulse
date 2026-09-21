# STRATELOQ-ECOM-HISTORICAL-PRODUCT-IMAGE-ENRICHMENT-013X

**FINAL VERDICT: `PRODUCT_IMAGE_COVERAGE_PARTIAL_TRUTHFUL`.**

The two researched-but-imageless Product Decisions were enriched through the 013W pipeline using
**bounded, free eBay Browse** requests (one per product), lifting founder image coverage from **3 → 5**
distinct workspace products. Every **researched** customer-facing product now carries a legitimate
canonical image (SUPPLIER or MARKETPLACE); the only two without images
(`cool air humidifier`, `humidifier for room`) are legitimately `PENDING_RESEARCH` — never researched,
correctly provisional, and not launch-ready. A smallest additive, server-authoritative launch guard now
blocks a real product-linked storefront from publishing without a trustworthy image (verified both
ways). No image was fabricated, scraped, keyword-matched, or borrowed; no score/decision/discovery-
provenance changed; €0 spent; no Lovable/publish.

---

### 1. Images before
**3 / 7**: kids nightlight projector (SUPPLIER), cool mist humidifier (MARKETPLACE), over door shoe
organizer (MARKETPLACE).

### 2. Images after
**5 / 7**: the three above **plus** digital picture frame (MARKETPLACE) and red light therapy led mask
(MARKETPLACE).

### 3. Digital picture frame result
`256eb5cb-…` GB. Its stored eBay evidence (2026-09-05) predated `image_url` capture (key `item_id`
only). One bounded eBay Browse (GB) returned 50 listings → 48 MATCHED/ingested via the current
`fn_ingest_ebay_listings` (relevance-gated, now stores `image_url`) → 013W backfill captured 1 image →
**image_state AVAILABLE, source MARKETPLACE_LISTING**.

### 4. Red light mask result
`275266ba-…` GB. Same cause. One bounded eBay Browse (GB) → 50 listings → 38 MATCHED/ingested → 1 image
captured → **image_state AVAILABLE, source MARKETPLACE_LISTING**.

### 5. Cool air humidifier state
`04b286f2-…` — `PENDING_RESEARCH`, no image. Never completed research; **not** image-searched (Phase 3).
Image will arrive through the normal research → evidence → canonical resolution → capture pipeline.

### 6. Humidifier for room state
`a4f098c7-…` — `PENDING_RESEARCH`, no image. Same as above; kept provisional until genuine research.

### 7. Exact image source for every product now carrying an image
| product | product_id | research state | image state | image source | canonical linkage proof |
|---|---|---|---|---|---|
| kids nightlight projector | e453eed4 | EVALUATED | AVAILABLE | **SUPPLIER** | `extended.supplier_ref` → CJ `supplier_product_assets` PRIMARY_IMAGE (rights SUPPLIER_PROVIDED) |
| cool mist humidifier | cda3f71a | EVALUATED | AVAILABLE | **MARKETPLACE** | MATCHED eBay `MARKETPLACE_ACTIVITY` signal on this product_id → `product_image_assets` |
| over door shoe organizer | efca8b59 | EVALUATED | AVAILABLE | **MARKETPLACE** | MATCHED eBay signal on this product_id → `product_image_assets` |
| digital picture frame | 256eb5cb | EVALUATED | AVAILABLE | **MARKETPLACE** | fresh MATCHED eBay listing on this product_id (013X enrichment) |
| red light therapy led mask | 275266ba | EVALUATED | AVAILABLE | **MARKETPLACE** | fresh MATCHED eBay listing on this product_id (013X enrichment) |
Vocabulary is SUPPLIER / MARKETPLACE / NULL only — **no** AI_GENERATED, WEB_SEARCH, or inferred image.

### 8. Products still legitimately without images + why
`cool air humidifier`, `humidifier for room` — `PENDING_RESEARCH`: DataForSEO-discovered candidates
that never underwent deep research, so no authorized evidence (supplier link or MATCHED marketplace
listing) exists yet. Correctly left NULL; not fabricated.

### 9. Storefront publication fails safely when imagery is absent?
**Yes (new guard, verified).** `mig_264` adds a fail-closed guard to `fn_storefront_publish`: a page
linked to a canonical product (`product_id NOT NULL`) is blocked with
`BLOCKED_PRODUCT_IMAGE_UNAVAILABLE` unless `fn_resolve_product_image` = AVAILABLE. Proven: a page for
`cool air humidifier` (PENDING) → **BLOCKED_PRODUCT_IMAGE_UNAVAILABLE**; a page for a product with an
image → **ok**. It does **not** hide Product Opportunities from the intelligence workspace, and never
substitutes a fake image. Product_id-less pages (fixtures) are unaffected.

### 10. External / API calls performed
**2 eBay Browse GET requests** (digital picture frame GB, red light mask GB), each preceded by a free
eBay client-credentials token request, via the existing "Pulse eBay Production" credential. No other
provider called; no broad discovery; no new products.

### 11. Cost
**€0.** eBay Browse (client-credentials) is free within the existing entitlement; two bounded reads.

### 12. Tests / regressions
All pass: `fn_product_image_selftest`, `fn_storefront_publish_selftest`,
`fn_storefront_publish_lifecycle_selftest`, `fn_storefront_runtime_selftest`, `deep_research`,
`research_orchestrator`, `ecommerce_connection`, `ecommerce_intelligence_contracts`,
`dataforseo_discovery`, `tiktok_executor`, `paid_access`. Regression verified: kids nightlight image
unchanged (SUPPLIER); GB/DE resolve the **same** product-global image; GB 68.2 / DE 73.2, digital
picture frame 74.6, red light mask 89.6 scores **unchanged** (enrichment never finalized/re-scored);
cool mist humidifier still `dataforseo`; discovery provenance unchanged; 15 products (no duplicates);
business country GB; 0 founder fixture PME (no synthetic evidence); no image copied between products
(each asset is on its own product_id, MATCHED-sourced); advisors **0 ERROR**.

### 13. Functions / migrations / workflows changed
- `supabase/migrations/mig_263_ebay_image_enrichment.sql` — `fn_enrich_product_image_from_ebay`
  (bounded eBay ingest → 013W backfill; no run/score/decision change).
- `supabase/migrations/mig_264_storefront_launch_image_guard.sql` — `fn_storefront_publish` +
  `BLOCKED_PRODUCT_IMAGE_UNAVAILABLE` launch-readiness guard.
- n8n workflow `Pulse — eBay Image Enrichment (013X)` (`TogFNIi8FWh6AhOt`, inactive/manual; reuses the
  existing "Pulse eBay Production" + "Supabase account" credentials by reference). No Lovable change.

### 14. Commit hash / push status
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`; see delivery message.

**STOP.** No Lovable change, no publish, no Stripe, no TikTok credential work, no image generation.
Verdict `PRODUCT_IMAGE_COVERAGE_PARTIAL_TRUTHFUL`: every researched customer-facing product has a real
image; the two remaining are truthfully provisional pending genuine research.

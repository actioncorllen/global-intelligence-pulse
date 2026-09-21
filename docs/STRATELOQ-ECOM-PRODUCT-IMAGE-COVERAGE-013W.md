# STRATELOQ-ECOM-PRODUCT-IMAGE-COVERAGE-013W

**FINAL VERDICT: `PRODUCT_IMAGE_PIPELINE_READY_HISTORICAL_ENRICHMENT_PENDING`.**

Trustworthy product-image acquisition is now a standard, source-agnostic part of the discovery/
research lifecycle. A key audit finding unblocked real coverage from **already-stored** evidence at
**€0**: eBay listing images were never discarded — `fn_ingest_ebay_listings` persists
`image.imageUrl` into `commerce_signals.evidence[].image_url` for MATCHED listings bound to the
canonical `product_id`. A new source-agnostic `product_image_assets` model, a canonical resolver, an
automatic capture wired into research finalize, and a backfill from stored evidence raised founder
workspace image coverage from **1 → 3 distinct products** with zero external calls. Images are tied
to the canonical product only (supplier link or MATCHED marketplace evidence — never keyword-only,
never another product's image, never AI/fabricated). Remaining products legitimately lack a stored
source image and will acquire one when research runs. No score/decision/discovery-source change; no
Lovable change; nothing published.

---

### 1. Current authorized image-capable providers
- **CJ (supplier)** — `IMAGE_AVAILABLE`. Rights-cleared primary image via `supplier_product_assets`
  (`asset_type=PRIMARY_IMAGE`, `rights_state=SUPPLIER_PROVIDED`) / `commerce_supplier_products.image_url`,
  reached through the product's canonical supplier link. In use.
- **eBay (Browse)** — `IMAGE_AVAILABLE`. `item.image.imageUrl` per listing, **already persisted** to
  `commerce_signals.evidence[].image_url` for MATCHED/LIKELY_MATCH listings of the canonical product.
- **DataForSEO** — `IMAGE_NOT_AVAILABLE`. The keyword_ideas/search_intent endpoints return no product
  image.
- **Meta (Ad Library)** — `NOT_AUTHORIZED` for canonical product identity. Ad snapshots are advertiser
  *creatives*, not a canonical product photo; using them as the product image is explicitly forbidden.
- **Reddit** — `IMAGE_NOT_AVAILABLE`. COMMUNITY_ATTENTION is text; no product image.
- **TikTok** — `NOT_IMPLEMENTED` for images (014B is advertising-presence text; credential setup not
  touched here).

### 2. Existing image fields found
- `supplier_product_assets.source_url` (+ `commerce_supplier_products.image_url`) — CJ, supplier-keyed.
- `commerce_signals.evidence[].image_url` (signal_type `MARKETPLACE_ACTIVITY`, source `EBAY_BROWSE_API`)
  — eBay, product_id-bound. Neither is a source-agnostic, product_id-keyed store → new model created.

### 3. Whether eBay currently returns usable images — YES (proven from stored evidence)
`fn_ingest_ebay_listings` line `'image_url', it->'image'->>'imageUrl'` persists the listing image.
Proof from stored founder evidence (no new call): `cool mist humidifier` 99/99 MATCHED marketplace
signals carry an `i.ebayimg.com` image (GB); `over door shoe organizer` 35 with images (GB/DE);
`kids nightlight projector` 95. These were previously unused only because no resolver read them.

### 4. Canonical image hierarchy (`fn_resolve_product_image`, product-global)
1. `product_image_assets` **CJ supplier primary** (rights `SUPPLIER_PROVIDED`, `AVAILABLE`).
2. `product_image_assets` **authorized marketplace listing image** for the resolved canonical product
   (eBay MATCHED).
3. Fallback: existing supplier-link image (back-compat for un-backfilled products).
4. `NULL` → `image_state` `PENDING_RESEARCH` (no scored evaluation yet) or `UNAVAILABLE_NO_SOURCE`.
Every candidate is tied to the SAME `product_id` via the supplier link or a MATCHED (relevance-gated)
marketplace signal — never keyword similarity.

### 5. Asset-model decision
`supplier_product_assets` is **supplier-keyed** (`supplier_product_id`), so it cannot cleanly hold a
marketplace/product_id-keyed image → created the smallest **source-agnostic `product_image_assets`**
(product_id, market, image_url, source_provider, source_url, source_entity_id, rights_state,
availability, is_primary, observed_at, provenance, is_fixture, created_at; RLS deny-all; read only by
SECURITY DEFINER functions; unique per product/provider/entity/market).

### 6. Automatic acquisition architecture
`provider evidence → canonical product resolution → validate relationship →
fn_backfill_product_images_from_evidence (CJ supplier primary + top MATCHED eBay image per market) →
product_image_assets → fn_resolve_product_image picks the canonical primary → workspace exposes it`.
Wired into `fn_finalize_research_run` (after decision materialization), so every finalized product
captures images from its own just-ingested evidence — **regardless of discovery source**
(Reddit/DataForSEO/future TikTok). `fn_capture_product_image` is the idempotent go-forward writer.

### 7. Founder products with images — before
**1 / 7** (only `kids nightlight projector`, CJ supplier-linked).

### 8. Founder products with images — after safe backfill (€0, stored evidence only)
**3 / 7**: `kids nightlight projector` (SUPPLIER_PROVIDED), `cool mist humidifier` (MARKETPLACE_LISTING,
eBay — a **DataForSEO-discovered** product, discovery source unchanged), `over door shoe organizer`
(MARKETPLACE_LISTING). Backfill captured 1 CJ + 5 eBay assets.

### 9. Products still missing images + exact reason
- `cool air humidifier`, `humidifier for room` — `PENDING_RESEARCH`: never underwent deep research;
  **no stored evidence exists**. Acquire when a research run executes (eBay/CJ evidence for the
  product).
- `digital picture frame`, `red light therapy led mask` — `UNAVAILABLE_NO_SOURCE`: researched, but
  their stored eBay marketplace signals contain **no `image_url`** (older runs / listings without an
  image field). Acquire by a fresh eBay research run for that product×market (a normal, authorized,
  free Browse call — not run here).

### 10. Launch lifecycle / gating recommendation (recommended, not destructively implemented)
Use existing lifecycle + the new `product_image_state`:
- `DISCOVERED / RESEARCH PENDING` (decision_provisional=true, image_state `PENDING_RESEARCH`) → image
  may still be pending; do **not** present as a completed customer-facing card.
- `EVALUATED` (non-provisional) → a canonical product image is expected; `image_state=AVAILABLE` should
  gate promotion to a **public/customer storefront**, not the internal intelligence workspace.
- If research finishes but no authorized source can supply an image (`UNAVAILABLE_NO_SOURCE`),
  **preserve** the product and its intelligence internally — never fabricate an image, never delete a
  valid opportunity. This is a recommendation; no destructive filtering was implemented in this unit.

### 11. Workspace contract impact
Unchanged fields `product_image_url` / `product_image_source` / `product_image_source_url` now source
from `fn_resolve_product_image`; added additive **`product_image_state`**
(`AVAILABLE` | `PENDING_RESEARCH` | `UNAVAILABLE_NO_SOURCE`). One canonical product keeps the same
image across GB/DE (product-global) — verified: nightlight GB and DE both return the SUPPLIER image.

### 12. Tests / regressions
`fn_product_image_selftest` **10/10**: no cross-product leakage; no keyword-only assignment (every
eBay asset came from a MATCHED signal with a source id); supplier image works; marketplace image works;
DataForSEO-discovered product gets an image with discovery source unchanged; GB/DE same product image;
image does not change score (nightlight GB 68.2); image does not change decision (≥10 decisions);
missing image not fabricated (never-researched → NULL/PENDING); no credentials in assets. Regressions
pass: connection, contracts, deep_research, orchestrator, dataforseo_discovery, tiktok_executor.
Advisors: **0 ERROR** (1 INFO / 4 WARN baseline).

### 13. Files / functions / migrations changed
`supabase/migrations/mig_262_product_image_coverage_pipeline.sql` — table `product_image_assets`;
`fn_capture_product_image`; `fn_backfill_product_images_from_evidence`; `fn_resolve_product_image`;
`fn_finalize_research_run` (+image capture); `fn_ecommerce_workspace_intelligence` (resolver +
`product_image_state`); `fn_product_image_selftest`. No Lovable change.

### 14. Paid / API calls made
**None.** All image coverage came from already-stored authorized evidence (CJ supplier assets + eBay
marketplace signals). No external/provider call, no paid call.

### 15. Commit / push
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`; see delivery message.

### 16. Final verdict
`PRODUCT_IMAGE_PIPELINE_READY_HISTORICAL_ENRICHMENT_PENDING` — pipeline complete and proven; coverage
1 → 3 from stored evidence; the remaining 4 products legitimately lack a stored source image and will
be enriched by the normal (authorized, free) research step, source-agnostic of discovery origin.

**STOP.** No score/decision/discovery-source change; no image fabricated; no Lovable/publish change.

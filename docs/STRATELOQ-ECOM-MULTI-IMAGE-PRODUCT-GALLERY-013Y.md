# STRATELOQ-ECOM-MULTI-IMAGE-PRODUCT-GALLERY-013Y

**FINAL VERDICT: `PRODUCT_GALLERY_READY`.**

The single-primary image pipeline (013W/013X) is upgraded to a trustworthy **5-image gallery** by
extending the existing `product_image_assets` model — **no external calls, €0**. Every researched
Product Opportunity now exposes a deterministic, URL-deduped, product-global gallery of up to 5
authorized images (canonical CJ supplier + strongly-MATCHED marketplace listings); the two
never-researched products correctly show an empty gallery (no fabrication). No fabricated angles, no
keyword-only/AI/competitor imagery; scores/decisions/discovery-provenance unchanged; the storefront
image guard remains intact.

---

### Phase 1 — existing multi-image evidence (no external calls)
Per researched product: distinct MATCHED eBay listing image URLs = nightlight 95, cool mist humidifier
98, digital picture frame 48, over door shoe organizer 35, red light mask 38. CJ supplier AVAILABLE
images: only nightlight (1). Crucially, eBay `item_summary/search` evidence carries **no**
`additionalImages`/`thumbnailImages` arrays (`ebay_has_additional_arrays=false`) — so the images are
**different sellers' listings of the same product concept (one photo each)**, not verified alternate
angles of one SKU. Honest conclusion: build the gallery from CJ same-SKU images + distinct MATCHED
marketplace listing images, exposed as plain gallery images (never labelled as angles). Stored
evidence is sufficient; **no eBay/CJ/paid call was necessary**.

### Phase 2/3 — data model & trust hierarchy
Extended `product_image_assets` (product_id-keyed) with a `(product_id, image_url)` unique index to
prevent duplicate URLs. Provenance preserved: source_provider, source_url, source_entity_id (item/
supplier id), image_url, is_primary, observed_at, canonical product_id, MATCHED relevance, gallery
ordering. Hierarchy: **CJ supplier → MATCHED marketplace listing → NULL**. Never keyword-only, loosely
related, competitor creative, Reddit images, web search, AI, or another product's image. Gallery is
**product-global** (not bound to market).

### Phase 4 — visual variety (truthful)
No angle metadata exists in the stored evidence, so images are exposed **simply as gallery images**
(no front/side/rear labels). URL-deduplication applied; no duplicate thumbnails; capped at 5.

### Phase 5 — existing products (stored evidence only)
`fn_backfill_product_images_from_evidence` v2 captured all AVAILABLE CJ images + the top-8 distinct
MATCHED eBay images per product (resolver returns 5). Backfill: 0 new CJ (already present), 46 eBay
gallery images, 6 primaries set. **No paid API calls.** Pending products received **no** image-only
enrichment.

### Phase 6 — browser-safe contract (additive)
Workspace `product_decisions[]` now also carries:
- `product_images`: `[{ image_url, image_source, image_source_url, is_primary, position, source_provider }]` (≤5)
- `product_image_count`: integer
- `product_gallery_state`: `AVAILABLE | PARTIAL | PENDING_RESEARCH | UNAVAILABLE_NO_SOURCE`
The existing `product_image_url` / `product_image_source` / `product_image_source_url` /
`product_image_state` remain (unchanged decoding); `product_image_url` is still the canonical PRIMARY.

### Phase 7 — launch rule
Gallery completeness is exposed truthfully (≥3 = AVAILABLE, 1–2 = PARTIAL, 0 = pending/unavailable).
**No** opportunity is blocked for having only 1–2 images. The storefront publish guard (013X) is
unchanged: at least **one** legitimate canonical image is still required for product-linked
publication; five images are **not** required to publish.

### Phase 9 — per researched product
| product | primary source | total trustworthy images found | gallery returned | source composition | gallery state | limitation |
|---|---|---|---|---|---|---|
| kids nightlight projector | **SUPPLIER** (CJ) | CJ 1 + eBay 95 | 5 | SUPPLIER + MARKETPLACE | AVAILABLE | eBay images are distinct sellers' listings, not per-SKU angles |
| cool mist humidifier | MARKETPLACE | eBay 98 | 5 | MARKETPLACE | AVAILABLE | multi-listing (same concept), no angle metadata |
| over door shoe organizer | MARKETPLACE | eBay 35 | 5 | MARKETPLACE | AVAILABLE | multi-listing, no angle metadata |
| digital picture frame | MARKETPLACE | eBay 48 | 5 | MARKETPLACE | AVAILABLE | multi-listing, no angle metadata |
| red light therapy led mask | MARKETPLACE | eBay 38 | 5 | MARKETPLACE | AVAILABLE | multi-listing, no angle metadata |
Pending (unchanged, no fabrication): cool air humidifier, humidifier for room — 0 images,
`PENDING_RESEARCH`; galleries will populate through normal deep research.

1. **Schema/functions changed** — `product_image_assets` (+`(product_id,image_url)` unique index);
   `fn_backfill_product_images_from_evidence` v2; new `fn_resolve_product_gallery`;
   `fn_resolve_product_image` (ordering aligned to is_primary); `fn_ecommerce_workspace_intelligence`
   (additive gallery fields); new `fn_product_gallery_selftest`.
2. **Existing stored evidence sufficient?** — **Yes.** 35–98 distinct MATCHED image URLs per product;
   no new capture needed.
3. **Bounded external calls** — **none.**
4. **Cost** — **€0.**
5. **Gallery contract** — see Phase 6.
6. **Tests/regressions** — `fn_product_gallery_selftest` **10/10** (max 5, no dup URLs, exactly one
   primary, no cross-product leakage, GB/DE same gallery, deterministic order, primary matches
   resolver, gallery_state truthful, pending no fabrication, no AI/web sources). Also pass:
   `product_image`, `storefront_publish`, `storefront_publish_lifecycle`, `deep_research`,
   `orchestrator`, `connection`, `contracts`. GB 68.2 / DE 73.2 unchanged; discovery provenance
   unchanged (cool mist humidifier still `dataforseo`); 15 products (no dup); country GB; storefront
   image guard intact; advisors **0 ERROR**.
7. **Commit hash / push** — see delivery message.
8. **No fabricated images/angles** — confirmed. Only real CJ supplier + MATCHED eBay listing images;
   images exposed as plain gallery images with no invented angle labels; pending products left empty.

**STOP.** No Lovable change, no publish, no TikTok, no Stripe. Verdict `PRODUCT_GALLERY_READY`: every
researched product exposes a truthful 3–5 image gallery from already-authorized stored evidence.

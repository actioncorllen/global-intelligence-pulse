# STRATELOQ-AI-AD-CREATIVE-STUDIO-015O — Authoritative Supplier Gallery Ingestion

**FINAL VERDICT: `AUTHORITATIVE_SUPPLIER_GALLERY_READY`.**
Sub-finding: **`NO_EXISTING_DECISIONED_PRODUCT_WITH_AUTHORITATIVE_SUPPLIER_LINK`** (no non-nightlight candidate for 015N).
**`DOES_015O_WEAKEN_FOUNDER_STANDARD = NO`** (strengthens it).

Built the generic authoritative supplier-gallery ingestion path (strict exact-SKU identity), proved it on the
nightlight reference case with a **single free CJ product-detail call**, and enriched the nightlight Product Card
from **1 → 12** authoritative exact-SKU images. Marketplace-reference (eBay) images remained reference-only and
untouched. No non-nightlight decisioned product has a supplier link, so there is no new candidate for the 015N
quality proof — returned to the founder as instructed (015N not run).

---

## RETURN
1. **Existing supplier/CJ architecture found:** `commerce_supplier_products` (CJ `raw` payloads),
   `supplier_product_assets` (supplier gallery store — was empty), `product_asset_intelligence` (product↔asset
   match), `product_image_assets` (Product Card gallery). CJ workflows exist (auth + `product/query` +
   `freightCalculate` + stock). CJ credential present in n8n (`2IV5tXPu9jAItjKh`).
2. **Why Product Cards had limited supplier imagery:** the stored CJ payload came from the **list/search** endpoint,
   whose `productImage` is a single main image; the full image gallery lives only in the CJ **product-detail**
   (`product/query`) response, which was never fetched or stored. `supplier_product_assets` was empty.
3. **Nightlight stored-media audit:** `supplier_product_assets` = 0 rows; `product_asset_intelligence` = 1
   (SOURCE_PRODUCT_IMAGE, primary); `product_image_assets(CJ)` = 1 (`7c2f476f`). No additional images stored.
4. **Exact CJ images actually available for nightlight:** **12** (from `product/query` on pid
   `2608250310481611400`). Previously only 1 had reached the Product Card.
5. **Existing decisioned products checked:** kids nightlight projector, cool mist humidifier, over door shoe
   organizer, red light therapy led mask, digital picture frame, 2× humidifier.
6. **Proven supplier links found:** ONLY the nightlight (`CJ`, item `2608250310481611400`, supplier_row
   `a7ca5195…`). All others have **no** `supplier_ref` — their images are all eBay marketplace.
7. **Product selected for enrichment:** the nightlight (reference/audit case per §3). No non-nightlight candidate exists.
8. **Provider:** `CJ_SUPPLIER`.
9. **Supplier item ID:** `2608250310481611400`.
10. **Stored payload vs external call:** stored payload had no gallery → one **free** CJ `product/query` call made.
11. **External calls made:** **1** (auth) + **1** (`product/query`). CJ points billing: `usedToday 10 / 50000` —
    **no monetary cost**. Existing credential; no new account.
12. **Cost:** **USD 0.00.**
13. **Images discovered:** **12** exact-SKU images.
14. **Images ingested:** **11** new (1 deduped — the pre-existing `7c2f476f`). Nightlight authoritative gallery = **12**.
15. **Image roles:** 3 `_trans` product-on-transparent shots classified `PRODUCT_ONLY` (deterministic from CJ `_trans`
    naming; the pre-existing primary was one of them, kept as-is), the rest `SUPPLIER_GALLERY_IMAGE`. Creative
    suitability remains the 015M selector's job.
16. **Authoritative gallery result:** `fn_ad_product_card_authority` → 12; customer gallery resolver
    `SAME_PRODUCT_GALLERY_READY`, hero-first ordering.
17. **Marketplace images stayed reference-only:** YES — 19 eBay images untouched; authority excludes them; selftest C
    confirms marketplace cannot become authoritative.
18. **Product Card read-contract result:** `fn_resolve_product_gallery` returns the enriched same-identity gallery
    (fixed to order the hero/primary first).
19. **015M selector against enriched gallery:** `candidate_count = 12`, selects the primary `7c2f476f`; no special-case
    logic needed.
20. **Identity-gate regression:** `product_card_identity` 6/6, `composite_identity` 3/3, `supplier_gallery_ingest`
    (A–G) 7/7, `ad_creative_asset_selector` 4/4 — all green.
21. **Other regressions:** lineage 16/16, product_gallery, creative_production 7/7, media_video_runtime 15/15,
    media_runtime 10/10, static 10/10, product_image 10/10 — all green (after the hero-first gallery-order fix).
22. **Security:** the enrichment writes only to existing tables; no new RLS-exposed table. CJ access token was
    **never persisted** (only image URLs + request id recorded in provenance).
23. **Migrations/workflows changed:** `mig_286_authoritative_supplier_gallery_ingest.sql`
    (`fn_ingest_supplier_gallery`, selftest, hero-first `fn_resolve_product_gallery` fix); `mig_285` selftest updated
    for the enriched gallery; n8n workflow `s5eSmlzH4pkoIBww` (Pulse - CJ Product Card Gallery Fetch, manual/free).
24. **Commit hash:** see delivery message.
25. **DOES_015O_WEAKEN_FOUNDER_STANDARD:** **NO.**
26. **Final verdict:** **`AUTHORITATIVE_SUPPLIER_GALLERY_READY`** (+ `NO_EXISTING_DECISIONED_PRODUCT_WITH_AUTHORITATIVE_SUPPLIER_LINK`).

## For the founder (per §13 — 015N NOT run)
- No **non-nightlight** decisioned Product Card has a supplier link, so there is still no fresh candidate for the
  founder-quality proof on a *different* product.
- However, the nightlight Product Card now holds **cleaner** exact-SKU images, including product-on-transparent
  (`_trans`) shots (`beb8eabe` primary, `96b7c3c7`, `1370070c`) that are better suited to a clean static than the
  busy lifestyle composite used in 015L. If you want, the quality proof can be re-run on the nightlight using one of
  these cleaner product-only images (that would override the 015N "no nightlight" rule — your call), or we wait for a
  different product to gain a CJ supplier link.
- Generic future behavior: any supplier-linked product can now have its full exact-SKU gallery ingested during
  Product Card enrichment via `fn_ingest_supplier_gallery` + the free CJ fetch, with no Creative-Studio external
  search at ad-creation time.

---

**STOP after supplier-gallery verification.** No second creative run, no eBay promotion, no web/visual-similarity
matching, no AI image, no product redraw, no video, no campaign/social. Standard remains LOCKED; Reddit remains
`BLOCKED_EXTERNAL_APPROVAL`.

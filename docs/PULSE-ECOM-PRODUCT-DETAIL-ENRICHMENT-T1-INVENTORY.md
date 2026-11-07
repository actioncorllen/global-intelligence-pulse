# Product Detail Enrichment — TASK 1 Infrastructure Inventory (reuse-first)

Directive: display genuine variants, multiple images, product videos + TikTok product videos on every
product-detail surface (Discovery, Recommendations, My Products, existing detail), reusing established
backend. No new backend unless a genuine gap. No paid calls. Preview only.

Production project: Strateloq Technologies `nxaunmyihhjixxxljcqt`. Frontend: Lovable "Pulse Implementation"
`12db6c84-161b-4c23-aac4-e19e8cd24ab1`.

## A. BACKEND READ CONTRACTS — ALREADY IMPLEMENTED (reuse; no new backend needed)

### Variants — `fn_product_supplier_candidate(p_tenant, p_product, p_market)` (SECURITY DEFINER, auth.uid()-owned)
Returns: `variants`, `variant_catalog`, `total_variant_count`, `corresponding_variant_count`,
`confirmed_sku`, `exact_sku_confirmed`, `exact_sku_status`, `exact_variant_verified`, `verified_exact`,
`displayed_variant_economics`, `display_label`, `sku`, `vid`, `supplier_product_id`, `gallery_images`,
`gallery_image_count`, `reference_images`, `sample_images`, `price_usd`, `design_match`,
`corresponds_to_concept`, `rights_state`, `commercial_use`, `reference_only`, `variant_identification`,
`variant_note`, `missing_evidence`, `supplier_match_binding`, `verification_tier`.
Exact-SKU safety is modelled server-side (confirmed_sku / exact_sku_confirmed / supplier_match_binding).
Frontend hook: `useProductSupplierCandidate`; rendered via `SupplierCandidateSection`.

### Images / gallery
- `fn_product_media_state(...)` → `primary_image`, `cover`, `gallery_count`, `image_state`.
- `fn_resolve_product_gallery(p_product_id, p_limit)` → `images[]` (image_url, source_provider,
  source_item_id, is_primary, position, gallery_identity_state).
- `fn_product_supplier_candidate` → `gallery_images`, `reference_images`, `sample_images`.
Frontend: `useProductGallery` → `ProductDetailMedia`; `useProductMedia` → `cardImageUrl`.

### Videos + TikTok intelligence — `fn_product_media_state(p_tenant, p_product, p_market)`
Tenant-owned (checks `commerce_products.user_id = auth.uid()`; `p_tenant` ignored for authz), market-isolated,
ordered by views desc. Returns `videos[]`, `video_count`, `primary_video`, `video_state`. Each `videos[]`
element (confirmed from the function body):
`video_id, media_asset_id, tiktok_url, fastmoss_url, cover, url, playback_mode (EXTERNAL_URL |
SELF_HOSTED_SIGNED), storage_bucket, storage_object, creator (@handle from tiktok_url), description,
duration, market, provider, source_provider, copyright, is_free, views (play_count), likes (digg_count),
comments (comment_count), shares (share_count), units_sold, is_ad, published_at (from create_time),
observed_at, rights_state, authority='REFERENCE_ONLY'`.
Only non-launch-safe (reference) videos are returned (`is_launch_safe=false`) — generated/ad videos are
excluded. Self-hosted playback requires a signed URL (`fn_media_asset_signed_ref(p_asset_id)`).

### Rights / Product Asset Lock (backend-enforced)
`fn_asset_rights_class(rights_state, source_provider, provenance)`. rights_state ∈ {PRODUCT_CARD_AUTHORITATIVE,
SUPPLIER_PROVIDED, SUPPLIER_AUTHORIZED, FIRST_PARTY_OWNED, GENERATED, MARKETPLACE_PUBLIC_LISTING,
PROVIDER_DISCOVERY_REFERENCE, PROHIBITED, UNKNOWN}; usage_permission ∈ {REFERENCE_ONLY,
INTERNAL_ADVERTISING_TEST, null}. media_state invariants: `reference_media_never_unlocks_store_ad_creative_publishing`,
`self_hosted_video_playback_requires_signed_url`, `video_lane_market_isolated`,
`completed_card_requires_genuine_primary_image`, `no_fabricated_media`.

### Ingest / write paths (not frontend; populate the above)
Variants/stock/shipping: `fn_ingest_cj_variant_evidence`, `fn_cj_variant_evidence_is_fresh`,
`fn_cj_normalize_stock`. Media/gallery: `fn_ingest_cj_product_media`, `fn_ingest_supplier_gallery`,
`fn_capture_product_image`, `fn_resolve_product_image`. Videos: `fn_persist_reference_video`,
`fn_fastmoss_integrate_reference_videos`, `fn_ingest_tiktok_commercial_content`.

## B. ACTUAL DATA COVERAGE (honest — do NOT claim universal coverage)
Videos: **only 2 products** carry reference videos — `5bc29d0a` (DE "Beleuchtete Krippen", **7 FastMoss/TikTok**
videos) and `56a6af36` (1 CJDROPSHIPPING catalog video). All `REFERENCE_ONLY`. Every other product: 0 videos.
Within the founder's 8-product Recommendations feed, exactly **1** product (`5bc29d0a`) has videos.
Gallery images: 257 rows — rich galleries (8–42 images, eBay/CJ) for ~11 products; a single FastMoss cover for
most. Variant evidence (commerce_supplier_products.supplier_enrichment): full `variant_catalog` for 1 product;
`stock`/`freight`/`variant` for ~4–5 CJ-probed products; most products have none.
Sample real TikTok video (`5bc29d0a`): creator `@kathidieke`, tiktok_url present, is_ad=1, views 26,000,
likes 222, shares 26, comments 5, units_sold 3, GMV €102.96 (FastMoss estimate), ROAS 3.27, region DE,
duration 15s, self-hosted (signed-URL playable), REFERENCE_ONLY.
→ Honest states required: most products show "Variants not yet verified", "No videos yet", single-image galleries.
→ Observed video GMV/ROAS is a FastMoss video estimate — must be labelled distinct from verified product sales.

## C. n8n PIPELINES (81 workflows; reuse — do NOT run new paid calls)
- `Pulse — CJ SKU Inventory+Shipping Enrichment (parameterised)` (KwSTn2APVViKGYTf) — freshness-gated
  per-(pid,vid,sku,market) variant stock+freight → fn_ingest_cj_variant_evidence. Reusable variant enrichment.
- `Pulse — CJ Video Sync (Ski Mask)` (yN5wjbqESjaw3Xyl) — CJ free video → Storage → REFERENCE_ONLY media_assets row.
- `Pulse — CJ Media+Displayed Econ Ingest` (Dvxf28AzZ741CVFz) — 35 variants+images+econ → fn_ingest_cj_product_media.
- `Pulse — CJ Product Card Gallery Fetch` (s5eSmlzH4pkoIBww); `Pulse — Stage-2 CJ Supplier Search` (nnoDjxtEeTqwC6q6, active).
- `Pulse — Research Executor: TikTok (014B)` (j4bOv9cuuzMbqN9B). FastMoss reference videos arrive via
  `fn_fastmoss_integrate_reference_videos` from FastMoss discovery responses.

## D. FRONTEND WIRING (ExplorerDrawer → ProductIntelligenceDrawer) — confirmed from product-explorer.tsx
`ExplorerDrawer` already passes to `ProductIntelligenceDrawer`: `videos={media?.videos ?? []}`,
`videoCount`, `videoState`, `mediaPanel={<ProductDetailMedia gallery … />}`,
`asidePanel={<SupplierCandidateSection data={supplier.data} economics readiness …/>}`,
`extraSections={<AdEvidenceSection/><CompetitorEvidenceSection/>}`, `actions` with
`concreteProductActionsAllowed={false}` (locked). So videos + gallery + variants are WIRED into the drawer.
OPEN QUESTION (render inventory in progress): does ProductIntelligenceDrawer actually RENDER a video section
(thumbnails/players/engagement), does ProductDetailMedia render a MULTI-image gallery, does
SupplierCandidateSection render a full variant catalog + selector, and does `useProductMedia` decode the
per-video TikTok fields? → determines whether the build is pure display or also a frontend decoder extension.

## F. FRONTEND RENDER INVENTORY (verified) — MOST OF THIS IS ALREADY BUILT
The product-detail UI is already render-rich. **Do NOT rebuild — this would duplicate existing functionality.**
- **Videos** — `ProductIntelligenceDrawer` delegates to `ReferenceVideoGallery`
  (`reference-video-gallery.tsx`): renders thumbnails, a native `<video controls>` player, SELF_HOSTED_SIGNED
  playback via `fetchSignedMediaUrl(mediaAssetId)` (+Retry), EXTERNAL_URL direct playback, "Watch on TikTok"
  + "Source: FastMoss" links, engagement (views/likes/comments/shares/creator), `is_ad`→`Ad` tag,
  posted/observed dates, duration, and REFERENCE_ONLY notices (banner + per-card tag + RightsCaption).
  Market-filtered. (`videoCount` is a dead prop — received, never rendered.)
- **Images/gallery** — `ProductDetailMedia` renders a MULTI-image gallery (hero + prev/next + counter +
  lightbox Dialog + selectable thumbnail strip), from `gallery.images[].imageUrl`, cap `GALLERY_LIMIT=5`,
  with a "Partial gallery" note. Every image captioned "Reference only". Supplier preview overlay shows
  SKU/VID + "Verified exact supplier variant" vs "exact SKU not verified" + "not cleared for commercial use".
- **Variants** — `SupplierCandidateSection` renders a per-SKU economics catalog (`EconomicsVariantRow`): SKU,
  VERIFIED/POTENTIAL/UNVERIFIED badge, price USD, stock state, CJ warehouse + factory replenishment, shipping
  quote/price, est. delivery days, dispatch country, landed-cost estimate + Excludes list, "Profitability not
  confirmed." Plus `VariantTile` image tiles for exact-SKU-confirmed variants and a reference-image gallery
  with an **identity-based selector** (`variantIdentityMatches`: vid → else sku → never position). Selection
  highlights + previews the image; exact SKU binding preserved.
- **TikTok** — rendered inside `ReferenceVideoGallery`: TikTok link, FastMoss source, `is_ad` tag, creator,
  views. No embed iframe (outbound link or self-hosted player). On Discovery + Recommendations (both use
  `ExplorerDrawer`→`ProductIntelligenceDrawer`) and the existing detail drawer, the full enrichment is present.

Contract types already decode everything: `ReferenceVideo` (tiktokUrl, playbackMode, playbackUrl,
mediaAssetId, cover, creator, views, likes, comments, shares, unitsSold, isAd, publishedAt, duration,
rightsState, authority…), `ResolvedGallery.images[]`, `SupplierVariant`/`EconomicsVariant`
(sku, vid, variantClass, priceUsd, weightG, stock, shipping, exactSkuConfirmed), rights on
`SupplierCandidate.media` + `ReadinessBadge`.

## G. GENUINE GAPS (small) + the ONE structural blocker
1. **Variant human name not shown in the detailed rows.** `EconomicsVariantRow` shows SKU but not the human
   variant descriptor. CJ data provides a variant `key`/`variantClass` (e.g. "Whitebeard 1pcs") — there are
   NO separate colour/size/model fields in supplier evidence, so the honest fix is to render the variant
   name/label where present, never fabricate colour/size/model. (Task 2) — reuse-only frontend.
2. **TikTok match-confidence + "observed vs verified" labelling.** Videos show REFERENCE_ONLY but no
   product-match-confidence label and no "observed video performance ≠ verified product sales" caption.
   FastMoss videos are provider-matched (not exact-SKU verified); CJ catalog videos are supplier-own.
   (Tasks 5, 6) — reuse-only frontend honesty labels.
3. **STRUCTURAL BLOCKER — My Products has no product-detail drawer AND acquisitions carry no canonical
   product_id.** `MyProductsView` renders acquisition/supplier management only; there is no "View Product".
   `get_own_product_acquisitions` / `ProductAcquisition` expose `acquisitionId`, `productTitle`, `productUrl`
   — **no canonical `commerce_products.id` and no market**. `product_acquisitions` stores a
   `winning_product_snapshot` matched by product_url/title, not a canonical id. Opening the exact product's
   enriched drawer from My Products would require resolving identity — which must NOT be done by title/fuzzy
   match. So My Products enrichment needs a minimal **backend read change** to surface a *verified* canonical
   `product_id` (+ market) on each acquisition, then the same `ExplorerDrawer` can be reused. Also:
   `product_acquisitions` is currently EMPTY in prod (nothing to display yet). → Report as a blocker needing
   founder approval for a minimal additive read; do not title-match.

## DATA-COVERAGE REALITY (honest)
Videos: 2 products total (1 in the Recommendations feed: `5bc29d0a`, 7 FastMoss/TikTok videos; 1 CJ catalog
video). Most products: no video. Galleries: rich (8–42) for ~11 products; single cover for most. Variants:
full catalog for 1 CJ product, partial for ~4–5. → honest empty states are the norm, not the exception.

## E. (superseded by F/G above) PRELIMINARY REUSE MAP / GAP
- NO new backend expected: variants, gallery, videos, TikTok intelligence and rights are all already in the
  read contracts above, tenant-safe, market-isolated, REFERENCE_ONLY-tagged.
- Likely gap = FRONTEND DISPLAY only: render the 7 professional sections (Overview, Images, Variants,
  Supplier & Economics, Videos, TikTok & Advertising Intelligence, Country Evidence) from the existing
  contracts, with honest empty states and REFERENCE_ONLY / match-confidence labelling; possibly extend the
  `useProductMedia` frontend decoder if it doesn't yet surface the per-video TikTok fields.

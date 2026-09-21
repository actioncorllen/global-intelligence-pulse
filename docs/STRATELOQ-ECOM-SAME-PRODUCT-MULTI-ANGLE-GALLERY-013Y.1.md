# STRATELOQ-ECOM-SAME-PRODUCT-MULTI-ANGLE-GALLERY-013Y.1

**FINAL VERDICT: `SAME_PRODUCT_GALLERIES_READY`.**

The 013Y multi-listing defect is corrected at its structural root. Every researched product now
exposes a **5-image gallery of ONE and the same eBay item** (one `source_provider` + one
`source_entity_id`), acquired via bounded **free** eBay Browse **getItem** (`image` +
`additionalImages[]`). No gallery is assembled from multiple listings any more — proven on live data:
each product's 5 gallery images resolve to exactly **1 distinct source item**. Scores, decisions,
discovery provenance, hero/primary image, GB/DE isolation and the storefront guard are unchanged; no
synthetic/AI/keyword/competitor imagery; **€0** (eBay Browse is free within entitlement). No Lovable,
no publish, no TikTok, no Stripe.

---

## 1. Root cause of the incorrect gallery
Two layers:
- **Selection layer (013Y):** `fn_resolve_product_gallery` + the v2 backfill built a "gallery" from the
  top-8 primary images of **distinct MATCHED eBay listings**. MATCHED means "same product concept," not
  "same item," so the tiles showed different models/variants (founder screenshots, e.g. cool mist
  humidifier).
- **Structural layer (deeper, newly found):** `product_image_assets` carried a unique index
  `product_image_assets_uniq (product_id, source_provider, coalesce(source_entity_id,''),
  coalesce(market,'*'))` from mig_262 — it physically allowed **at most one image row per item**, so a
  same-item gallery was impossible and the pipeline was *forced* to collect one image each from many
  listings. Proof: pre-fix, every eBay product had `total_images == distinct_source_items`.

## 2. Does CJ provide same-product multi-image galleries?
Partially. CJ *can* (SKU `1980170173102026754` stores 8 `AVAILABLE` `IMAGE` assets), but for the five
researched products only the nightlight is CJ-linked (SKU `2608250310481611400`) and its stored CJ
payload exposes a **single** `productImage` (no same-SKU 3–5 gallery). So CJ was not a sufficient
same-item 3–5 source here; eBay getItem was used (founder priority #3). CJ remains the hero/primary for
the nightlight.

## 3. Does eBay item-detail provide multiple images for one item?
**Yes — proven from live responses.** `item_summary/search` returns only `image.imageUrl` (one), but
`GET /buy/browse/v1/item/{itemId}` returns `image` + `additionalImages[]` for ONE item. Observed
`additionalImages` counts this run: nightlight 7, digital picture frame 7, over door shoe organizer 11,
red light mask 6, humidifier item `117339903959` 5+ (one humidifier listing had 0, so an alternate
strong MATCHED item was used). `search → itemId → getItem(itemId)` reliably retrieves the same-item
gallery.

## 4. Gallery identity rule implemented
A gallery now has a **gallery identity = (source_provider, source_entity_id)**. `fn_resolve_product_gallery`
selects exactly ONE identity — CJ preferred, then the identity with ≥3 images, then most images,
deterministic — and returns up to 5 images **from that identity only**. It never mixes source_entity_ids.
New capture fn `fn_ingest_ebay_item_gallery(product_id, item_id, item_json)` stores `image` +
`additionalImages` under ONE `source_entity_id`, positioned (main = 1). The structural index that
blocked multi-image items was dropped (dup-URL safety kept via `(product_id, image_url)`).

## 5. Invalid existing galleries corrected
No image/evidence deleted. The corrected resolver simply stops combining listings: the pre-existing
one-image-per-listing rows remain in `product_image_assets` as separate 1-image identities and are no
longer selected together. Only the **selection** changed, so a multi-listing set can never again be
returned as one gallery (enforced by selftest).

## 6-9. Result for each researched product (proof of single-item galleries)
| Product | product_id | Gallery provider | Gallery source item ID | Images from that exact item | Same-item gallery state | Reaches 3–5? | Limitation |
|---|---|---|---|---|---|---|---|
| kids nightlight projector | e453eed4 | eBay (getItem) | `v1\|117296648744\|0` | 5 | SAME_PRODUCT_GALLERY_READY | ✅ | hero stays CJ supplier image (Phase 8) |
| cool mist humidifier | cda3f71a | eBay (getItem) | `v1\|117339903959\|0` | 5 | SAME_PRODUCT_GALLERY_READY | ✅ | top MATCHED item had 1 photo → used next strong MATCHED item |
| digital picture frame | 256eb5cb | eBay (getItem) | `v1\|117366632346\|0` | 5 | SAME_PRODUCT_GALLERY_READY | ✅ | — |
| over door shoe organizer | efca8b59 | eBay (getItem) | `v1\|188932376203\|0` | 5 | SAME_PRODUCT_GALLERY_READY | ✅ | strongest MATCHED item is an eBay.de listing (EBAY_DE) |
| red light therapy led mask | 275266ba | eBay (getItem) | `v1\|137659437810\|0` | 5 | SAME_PRODUCT_GALLERY_READY | ✅ | — |

Every gallery: `distinct_items_in_gallery = 1`, provider `EBAY_BROWSE` only. All five reach the founder's
3–5 same-product requirement. **None** is assembled from multiple listings. Angles are NOT labelled
(no source angle metadata) — shown as plain "Product images," all from the one listing (Phase 4). The
two never-researched products (`cool air humidifier`, `humidifier for room`) stay `PENDING_RESEARCH`
(empty, no fabrication).

## 10. External calls and cost
eBay Browse **getItem** only, via the existing "Pulse eBay Production" credential: run 30222 (5 items,
pre-index-drop probe) + run 30223 (7 items, incl. 3 humidifier candidates) = **12 free getItem GETs + 2
free client-credential token requests**. No search/broad discovery, no CJ live call, no paid provider.
**Cost €0.**

## 11. Schema / functions / workflows changed
- `supabase/migrations/mig_266_same_product_gallery_identity.sql` — **drop** `product_image_assets_uniq`
  (structural blocker); new `fn_ingest_ebay_item_gallery`; rewritten single-identity
  `fn_resolve_product_gallery` (+ `gallery_source_provider/gallery_source_item_id/gallery_identity_state`);
  workspace RPC additive identity fields; rewritten `fn_product_gallery_selftest` (same-identity invariants).
- `fn_resolve_product_image` (hero/primary) **unchanged** — `product_image_url` stays the legitimate
  canonical primary (Phase 8); storefront guard untouched.
- n8n workflow `Pulse — eBay Item Gallery (013Y.1)` (`nEFn7VIrbBulhxPL`, inactive/manual; reuses
  "Pulse eBay Production" + "Supabase account" credentials). No Lovable change.

## 12. Tests / regressions
- `fn_product_gallery_selftest` **12/12** incl. new `single_identity_per_gallery`,
  `gallery_identity_matches_images`, `images_trace_to_identity`.
- Pass: `product_image`, `storefront_publish`, `storefront_publish_lifecycle`, `storefront_runtime`,
  `ecommerce_intelligence_contracts`, `deep_research`.
- Regression unchanged: GB nightlight **68.2** / DE **73.2**; discovery provenance (cool mist humidifier
  `dataforseo`); **15** products; pending products still `PENDING_RESEARCH`; heroes AVAILABLE (nightlight
  CJ, others eBay — unchanged); no AI/web sources; security advisors **0 ERROR** (1 INFO = intended
  `product_image_assets` deny-all, 4 WARN baseline).

## 13. Commit / push
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`; see delivery message.

## 14. Confirmation
**Confirmed: no multi-listing gallery is represented as a same-product multi-angle gallery.** Each
product's gallery resolves to exactly one `source_entity_id` (one eBay item), verified on live data and
enforced by the `single_identity_per_gallery` / `gallery_identity_matches_images` selftests. Images are
real photos of that single listing; no fabricated angle labels, no cross-product, keyword-only, AI, web
or competitor imagery.

**STOP.** Verdict `SAME_PRODUCT_GALLERIES_READY`: all five researched products show a truthful 5-image
gallery of one and the same item.

# STRATELOQ-PRODUCT-GALLERY-013Y.2 — Strict CARD ↔ GALLERY Product Identity

**FINAL VERDICT: `STRICT_PRODUCT_GALLERIES_READY`.**

The launch-critical visual-integrity defect is **closed**. The workspace card hero and its
multi-image gallery are now bound to the **exact same source product identity** — for every
researched product, on the card and in the live founder workspace contract. Card hero equals
gallery position 1; every gallery image traces to the one source item the card is built from.
Identity outranks image count: the nightlight's card (a CJ **GINGER TECH** supplier item with a
single genuine image) yields a truthful **1-image** gallery — it is **never** padded from another
listing. No image was invented, deleted, or borrowed across products; the storefront path is
untouched and still fail-closed. All 15 gallery selftests and all 7 regression suites are green;
PME/Decision unchanged; 0 ERROR security advisors. No paid API call — one free, bounded eBay
`getItem` enrichment (already reported) on the exact hero items only.

---

## 1. Audit (root cause established first)

The card hero (`fn_resolve_product_image`) and the gallery (`fn_resolve_product_gallery`, mig_266)
resolved their **source identity independently**:

- **Hero** picked `is_primary DESC, CJ>EBAY>other, image_url` → one source item.
- **Gallery** picked `(n>=3) DESC, CJ, EBAY, n DESC` — an **image-count optimization** that selected
  whichever listing had the **most** photographs, a *different* marketplace item on every researched
  product.

Result on real data: the card displayed product **X** while its 5-image gallery showed product **Y**.
Worst case — the **nightlight**: hero = CJ `GINGER TECH` item `2608250310481611400`; gallery = eBay
item `v1|117296648744|0` (an unrelated listing). This is exactly the mismatch the founder saw.

**Why 013Y.1's test missed it:** `fn_product_gallery_selftest` only asserted a gallery was
*internally* single-identity (all images share one `source_entity_id`). It never asserted
**gallery identity == card/hero identity**. A self-consistent gallery of the *wrong* item passed.

## 2. Fix (deterministic, read-side, generic)

`supabase/migrations/mig_273_strict_card_gallery_identity.sql` — four parts:

1. **`fn_resolve_product_gallery(uuid,int)`** — resolves the **card/hero identity first** (identical
   `is_primary DESC, CJ>EBAY>other, image_url` ordering as the hero), then returns up to 5 images
   from **that `(source_provider, source_entity_id)` only**. It never switches to another item for
   more photos. Missing positions are never filled from another product. Emits explicit
   `card_source_provider/card_source_item_id` == `gallery_source_provider/gallery_source_item_id`
   (equal by construction).
2. **`fn_ecommerce_workspace_intelligence()`** — byte-identical to mig_266 except it now surfaces
   `card_source_provider`, `card_source_item_id`, `gallery_source_provider`, `gallery_source_item_id`
   on every card, so the invariant is inspectable from the storefront-facing contract.
3. **`fn_product_gallery_selftest()`** — adds three strict identity invariants
   (`gallery_identity_equals_card_identity`, `hero_image_in_gallery`, `card_equals_gallery_field`)
   on top of the retained 013Y.1 invariants (15 cases total).
4. **`fn_resolve_product_image(uuid,text)`** — identity selection **identical** to the gallery, then
   within that identity returns the **main full-size** image (lowest `gallery_position`), so the card
   hero equals `gallery[1]` exactly (removes the search-thumbnail `s-l225` vs `getItem` full-size
   `s-l1600` URL-variant mismatch). Supplier fallback and research-state (PENDING/UNAVAILABLE) logic
   preserved.

The fix is **generic** — it operates on any product's image assets by identity, not per-product
special cases. No image row is deleted (marketplace evidence preserved); only the **selection** is
corrected.

## 3. Result — all researched products (live founder workspace card)

| Product | Card identity | Hero == gallery[1] | Identity locked | Images | Gallery state |
|---|---|---|---|---|---|
| cool mist humidifier | EBAY `v1\|236997053613\|0` | ✅ | ✅ | 5 | AVAILABLE |
| digital picture frame | EBAY `v1\|820135612863\|0` | ✅ | ✅ | 4 | AVAILABLE |
| kids nightlight projector | CJ `2608250310481611400` (GINGER TECH) | ✅ | ✅ | **1** | PARTIAL |
| over door shoe organizer | EBAY `v1\|168622415265\|0` | ✅ | ✅ | 5 | AVAILABLE |
| red light therapy led mask | EBAY `v1\|198650570715\|0` | ✅ | ✅ | 5 | AVAILABLE |

- **Nightlight acceptance:** the card is the CJ **GINGER TECH** item (`2608250310481611400`), exactly
  as the founder identified. Its gallery is the truthful **1 image** available for that exact item —
  **not** optimized up to 5 by pulling in another listing. Image count adjusts down honestly.
- Every card: `card_source_item_id == gallery_source_item_id`, `hero_url == gallery[0].image_url`.
- Valid outcome range 1–5 respected: 1 (nightlight), 4 (picture frame), 5 (three others).

## 4. Storefront safety (unchanged, still fail-closed)

`fn_resolve_storefront_assets` resolves published-store images only from a **single fulfilment
supplier_product_id** and rejects marketplace/reference images (eBay → `REFERENCE_ONLY_MARKETPLACE`),
failing closed to `IMAGE_UNAVAILABLE`. It obeys the same "images belong to one exact source" rule and
was **not** modified. No marketplace image can leak onto a published storefront.

## 5. Tests (A–J) — 15/15 green

`fn_product_gallery_selftest → all_pass = true` (15 passed, 0 failed):
`gallery_identity_equals_card_identity`, `hero_image_in_gallery`, `card_equals_gallery_field`,
`single_identity_per_gallery`, `gallery_identity_matches_images`, `images_trace_to_identity`,
`max_5_images`, `no_duplicate_urls`, `exactly_one_primary`, `no_cross_product_leakage`,
`gb_de_same_gallery`, `deterministic_order`, `gallery_state_truthful`, `pending_no_fabrication`,
`no_ai_or_web_sources`.

## 6. Regressions & advisors

All 7 suites green: `fn_product_gallery_selftest`, `fn_deep_research_selftest`,
`fn_research_orchestrator_selftest`, `fn_tiktok_executor_selftest`, `fn_search_relevance_selftest`,
`fn_problem_foundation_selftest`, `fn_problem_discovery_selftest`. Security advisors: **0 ERROR,
1 INFO, 4 WARN** (baseline; the migration only `CREATE OR REPLACE`s three functions with hardened
`SET search_path TO ''` + least-privilege grants).

## 7. Invariants held

- **Identity > image count** — nightlight stays at 1 truthful image, never padded.
- **No invented brand/model** — exact source identity preserved and exposed
  (`card_source_provider/item_id`); nothing fabricated.
- **No cross-product image leakage** — every gallery image traces to the card's exact
  `(source_provider, source_entity_id)`.
- **Provenance clean** — image assets are only `CJ_SUPPLIER` (1) + `EBAY_BROWSE` (139), 0 null
  identities, **0** AI/web/invented sources.
- **Image-less decisions truthful** — the 2 products without a source image surface
  `PENDING_RESEARCH`, not a fabricated image.
- **PME / Product Decision unchanged** — read-only fix; 0 PME recompute, latest PME timestamp
  unchanged; nightlight GB still **68.2 / HIGH / WATCH**.
- **Lovable viewer** — not redesigned; the backend contract feeds it correct, identity-consistent
  data.

## 8. Cost

**€0.00 this unit.** No paid DataForSEO / TikTok / Meta / supplier calls. The gallery enrichment used
one free, bounded eBay Browse `getItem` per hero item on the four already-known exact eBay hero items
(reported previously); the nightlight (CJ) needed no external call.

## 9. Changes

- `supabase/migrations/mig_273_strict_card_gallery_identity.sql` — new (4 parts above). Applied to
  project `nxaunmyihhjixxxljcqt`; DB definitions verified byte-consistent with the committed file.
- `docs/STRATELOQ-PRODUCT-GALLERY-013Y.2.md` — this report.
- No Lovable change, no PME/Decision mutation, no storefront change.

---

**STOP.** Strict card ↔ gallery product identity is enforced and proven on every researched product;
the visual product-integrity defect is closed. Per the founder directive, 015C/015D remain **not
resumed** until this unit is accepted.

# STRATELOQ-AI-AD-CREATIVE-STUDIO-015M — Product Card Creative Asset Selector

**FINAL VERDICT: `NO_CLEANER_PRODUCT_CARD_ASSET_AVAILABLE`.**
**`DOES_015M_WEAKEN_FOUNDER_STANDARD = NO`** (it strengthens it).

Built the deterministic Product-Card creative-asset **selector** (same-SKU only, no pixel fetch, no paid model),
ran it on the Kids Nightlight Projector, and found that the exact Product Card identity has **exactly one** image —
`7c2f476f` (the one already used in the 015L baseline). The other 20 gallery images are `EBAY_BROWSE`
marketplace-reference shots with different item IDs, which the strict identity rule forbids using. There is **no
cleaner exact-product image**, so no new creative was manufactured; the 015L creative remains the truthful baseline.

---

## Selector (mig_285)
- `ad_creative_asset_selections` — provenance store, separate from the source records (RLS deny-by-default;
  SECURITY DEFINER access only). Source `product_image_assets` rows are **never modified**.
- `fn_ad_product_card_select_creative_asset(tenant, product, market, observed?, persist?)` — pulls only exact-identity
  candidates via `fn_ad_product_card_authority` (enforces `CARD_SOURCE_PROVIDER+ITEM == GALLERY_SOURCE_PROVIDER+ITEM`),
  ranks deterministically (observed suitability → primary → id), records selection + suitability metadata. No paid
  model, no pixel fetch, no external search.
- `fn_ad_creative_asset_selector_selftest()` — **4/4**.

## RETURN
1. **Exact-SKU Product Card images inspected:** **1** (of 21 total gallery images for the product; 20 excluded as
   marketplace-reference / different identity).
2. **Candidate asset IDs:** `7c2f476f-acbe-499b-a015-2422e56daa50`.
3. **All candidates share exact Product Card identity:** **YES** — `(CJ_SUPPLIER, 2608250310481611400)`.
4. **Creative-suitability observations** (asset `7c2f476f`, from the existing free 015L render — no paid call):
   product visible and prominent but **shares the frame with a human hand**; busy dark lifestyle scene (whale
   projections) with limited clean negative space; **baked-in supplier feature labels** (Touch Switch / Easy
   Switching / Projection light mode / Night Light Mode / Dual-opening mode); square, adequate resolution; **limited**
   suitability for a clean static, usable as a lifestyle hero. Class: `LIFESTYLE_PRODUCT_ASSET` / `LIMITED_CREATIVE_ASSET`.
5. **Selected asset ID:** `7c2f476f-acbe-499b-a015-2422e56daa50`.
6. **Selection reason:** only one exact-Product-Card-identity image exists; selected by default. Marketplace-reference
   images (different provider/item) are excluded by the strict identity rule.
7. **Primary or gallery:** primary (and the only exact-identity image).
8. **Source provider + item ID:** `CJ_SUPPLIER` + `2608250310481611400`.
9. **External image used?** **NO.**
10. **Product pixels generated?** **NO.**
11. **Compositor result:** not re-run — the selected asset is identical to the 015L baseline's source, so a new
    composite would be identical. No new creative manufactured (per instruction).
12. **Final creative asset ID:** unchanged — `f81fba19-fab1-4d97-baed-bd7b99f5978b` (015L) remains the baseline.
13. **PRODUCT_CARD_SOURCE_VERIFIED:** PASS (baseline creative).
14. **PRODUCT_IDENTITY_PRESERVED:** PASS (baseline creative).
15. **Claim-safety:** deterministic composed text claim-safe; embedded supplier labels in the source image remain
    flagged for human review.
16. **Quality Reviewer:** baseline unchanged — PLATFORM_FORMAT + both identity gates PASS; 7 aesthetic gates
    REVIEW_REQUIRED.
17. **launch_safe:** **false** (pending human review).
18. **Cost:** **USD 0.00.**
19. **Tests:** `ad_creative_asset_selector` **4/4**; all prior suites green (product-card-identity 6, composite-identity
    3, lineage 16, static 10, creative-prod 7, media-runtime 10, video 15, product-image 10). Security advisor: the
    only new note is `rls_enabled_no_policy` (INFO) — intentional deny-by-default on the provenance table.
20. **Commit hash:** see delivery message.
21. **DOES_015M_WEAKEN_FOUNDER_STANDARD:** **NO.**
22. **Final verdict:** **`NO_CLEANER_PRODUCT_CARD_ASSET_AVAILABLE`.**

## Note
The selector is generic and permanent: for any future product whose Product Card has **multiple** exact-identity
images, it will rank them deterministically (observed suitability → primary → id) and select the strongest
`CREATIVE_ASSET_SELECTED` without a paid call, storing provenance separately. For this product the honest answer is
that only one exact-SKU image exists — the cleanest path to a better creative here is a **cleaner product-only
Product Card image** for this SKU, not a different existing asset.

---

**STOP after this one product.** No paid generation, no external creative SaaS, no product redraw, no web image
search, no second SKU, no video, no social posting, no campaign launch. Source records unmodified. Standard remains
LOCKED; Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

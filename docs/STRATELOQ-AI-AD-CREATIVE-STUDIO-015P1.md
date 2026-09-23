# STRATELOQ-AI-AD-CREATIVE-STUDIO-015P.1 — Deterministic Product Edge Polish

**FINAL VERDICT: `POLISHED_FOUNDER_QUALITY_STATIC_READY_FOR_REVIEW`.**
**`DOES_015P1_WEAKEN_FOUNDER_STANDARD = NO`.**

Fixed **only** the edge-fringing on the 015P creative — no new concept, same product, Product Decision, Product Card
asset (`29e5d89c…`), hypothesis, copy, composition direction and 1080×1350 format. The fix is **matte-only** and
**deterministic**: border-connected background removal → 1px alpha erosion → median despeckle → 1px close → light
feather. **Product RGB pixels are the ORIGINAL Product Card source, unaltered (verified pixel diff = 0 in the kept
region).** No AI redraw, no generative fill, no reconstruction, no substitution. Zero cost. Persisted as a **new**
canonical `REAL_PRODUCT_LAYER_COMPOSITE` (015P kept intact for comparison); identity remains
`IDENTITY_REVIEW_REQUIRED` and the creative is **not** launch-safe pending human review.

> Quality proof, **not** a declared founder-quality pass. Founder decides aesthetics.

---

## RETURN

1. **Fringe root cause:** the product is **white-on-white** (a white device on a pure-white `255,255,255` background)
   with **translucent ribbed "solar-panel" wings**. 015P's binary flood-fill matte left (a) an **anti-aliased white
   halo ring** around the solid body / cable / connector (most visible glowing against the dark night sky), and
   (b) **speckle/pinholes and ragged edges** through the semi-transparent panel lattice where the flood leaked between
   the ribs.
2. **Deterministic correction used:** matte-only cleanup — **border-connected** flood-fill background removal, then
   **1px alpha erosion** (removes the halo ring), **median despeckle** (kills 1px speckles / fills 1px pinholes), a
   **1px morphological close** (smooths ragged notches, outer boundary preserved, lattice not solidified), and a
   **0.6px feather**. Least-destructive order; no colour of any product pixel is changed.
3. **Exact extraction operations:** `floodfill(threshold=36)` from ~120 white border seeds → binary alpha →
   `MinFilter(3)`×1 (erode) → `MedianFilter(3)` → `MaxFilter(3)`→`MinFilter(3)` (close) → `MedianFilter(3)` →
   `GaussianBlur(0.6)`; alpha applied to the **unmodified** source RGB; autocrop.
4. **No product regeneration:** confirmed — no image model, no generative fill, no redraw, no external/marketplace/
   competitor image. Pixels come only from the authoritative Product Card asset.
5. **Product geometry/features unchanged:** confirmed — RGB of the kept (opaque) region is **byte-identical** to the
   source (`ImageChops.difference` bbox = `None`); only the boundary matte changed (≈1px edge cleanup). Controls,
   shape, lens, panels and cable geometry are the original pixels.
6. **PRODUCT_CARD_SOURCE_VERIFIED:** **PASS** (`matched_source = 29e5d89c…`).
7. **PRODUCT_IDENTITY_PRESERVED:** **PASS** (mode `REAL_PRODUCT_LAYER_COMPOSITE`).
8. **Final copy (unchanged from 015P):** headline *"Turn any room into a starry night sky"*; support *"A dual-mode
   star projector & night light"*; CTA *"See how it works"*.
9. **Final dimensions:** **1080×1350 (4:5)** Meta/Instagram portrait.
10. **Claim-safety:** `fn_ad_studio_claim_scan` on all three lines → **0 violations** each.
11. **Quality Reviewer (`fn_creative_quality_review`):** `PLATFORM_FORMAT` **PASS**, `PRODUCT_CARD_SOURCE_VERIFIED`
    **PASS**, `PRODUCT_IDENTITY_PRESERVED` **PASS**, `BRAND_COMPLIANCE` N/A; all 7 aesthetic gates (COMPOSITION,
    VISUAL_QUALITY, AI_ARTIFACTS, PRODUCT_IDENTITY, PRODUCT_VISIBILITY, COMMERCIAL_USEFULNESS, CLAIM_SAFETY)
    **REVIEW_REQUIRED** — no fabricated aesthetic PASS. `human_approval_required = true`.
12. **Previous 015P asset ID:** `85268f56-f427-4e13-8d7e-5cca76c54a84` (kept; storage `…/pc-quality-002.jpg`).
13. **Polished asset ID:** **`e75f50f6-679e-4480-aeb2-115c6aa96bc4`** (lineage **CANONICAL**, approval `IN_REVIEW`,
    identity `IDENTITY_REVIEW_REQUIRED`).
14. **Private storage result:** bucket `pulse-generated-media` (private), object
    `creatives/e453eed4-3de4-4ed9-b889-1275c13c0dba/pc-quality-003.jpg`, verified **128635 bytes, `image/jpeg`**
    (byte-exact). The 015P object `pc-quality-002.jpg` is **preserved** for comparison/audit.
15. **Signed-delivery result:** 7-day signed download URL generated via the storage sign endpoint (HTTP 200). Bearer
    token deliberately **not** committed to the repo (no tokens persisted); handed to the founder in-session.
16. **Actual polished creative shown to founder:** **YES** — surfaced in-session for visual inspection.
17. **Human-review state:** `IDENTITY_REVIEW_REQUIRED` (not auto-cleared); founder aesthetic decision pending.
18. **launch_safe:** **false** (`fn_media_launch_eligibility` → `eligible=false`, reason `IDENTITY_REVIEW_REQUIRED`).
19. **Cost:** **USD 0.00.**
20. **Paid calls:** **0** (no image model, no video model, no external creative SaaS).
21. **Regressions (all green):** `ad_creative_product_card_identity`, `media_product_card_composite_identity`,
    `ad_creative_asset_selector`, `supplier_gallery_ingest`, `ad_static_creative_end_to_end` — all `all_pass = true`.
22. **Commit hash:** see delivery message.
23. **DOES_015P1_WEAKEN_FOUNDER_STANDARD:** **NO** — identity rule upheld (matte-only, RGB unchanged), claim safety
    upheld, human-review barrier intact, LOCKED standard intact; aesthetics left to the founder.
24. **Final verdict:** **`POLISHED_FOUNDER_QUALITY_STATIC_READY_FOR_REVIEW`.**

## Honest residual for the founder
The **solar-panel wings are genuinely translucent** (a see-through ribbed lattice on the real product). On a dark sky
they read as fine light structures with slightly ragged edges at the panel tips. This is **real product structure,
not a matte defect** — it can only be made to look "solid" by *adding* non-product (background) pixels into the panel
silhouette, which the product-identity rule forbids. The white **halo/fringe on the body, cable and connector — the
actual defect 015P flagged — is removed.** If you want the panels treated differently, the identity-safe options are:
(a) select a different authoritative Product Card asset where the panels sit on a cleaner backdrop, or (b) accept the
translucent look as the honest product. No redraw will be used on the product.

## Files / workflows changed
`docs/creatives/STRATELOQ-015P1-nightlight-static-polished.jpg` (artifact / byte transport),
`docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015P1.md` (this record). n8n workflow `XJokEc3mpxoRRWoH` reused
(GitHub→Supabase fetch → upload → sign). **No migration** — a production polish on existing 015K–015P contracts.

---

**STOP after the ONE polished version.** No second concept, no video, no campaign, no social posting, no paid
generation, no product redraw. Standard remains **LOCKED**; Reddit remains `BLOCKED_EXTERNAL_APPROVAL`; identity
remains `IDENTITY_REVIEW_REQUIRED` (human review mandatory before launch).

# BE331 — CS.05 founder-only pilot preparation (reusing deployed Gemini edge v27 + authorised-reference resolver)

**Executed:** 2026-11-27 · **Authority:** founder "CS.05 FOUNDER-ONLY PILOT PREPARATION". **No code change, no migration, no deployment, no paid/purchased generation.** Status: **READY FOR FOUNDER INPUT** — every system-side element is verified; the only remaining steps are founder-supplied (one owned image + its rights attestation + approval of the paid run). **CS.05 is NOT marked DONE** (it cannot be until the three generated images are visually inspected and accepted).

---

## 1. Pilot product (selected) — founder-owned, verified identity + variant
- **Product:** `e453eed4-3de4-4ed9-b889-1275c13c0dba` — "kids nightlight projector".
- **Ownership:** `user_id = 7c8ddf9d-172c-4a89-a402-bb7066228b61` (founder). ✓
- **Verified identity + variant:** exact CJ supplier identity `provider=CJ`, `supplier_product_id=2608250310481611400` (the exact SKU/variant). It is the canonical, best-characterised founder product throughout the build.
- **Why it needs the upload:** its only imagery today is 12 `SUPPLIER_PROVIDED` + 28 `MARKETPLACE_PUBLIC_LISTING` (0 owned), so it is not generation-eligible until a rights-cleared owned/licensed image is added. This is by design (fail-closed).

## 2. Eligible input + the upload path (founder-supplied — cannot be fabricated)
The reference must be a genuine **owned or licensed photo of the exact e453 product/variant**, plus an **explicit rights attestation**. The rights attestation is a legal declaration ("I own this image or have permission to use it for this product and advertising") that **only the founder can make**; there is no owned image in the system (0 owned images; `pulse-product-imports` empty). I did not and cannot invent the image or attest rights on the founder's behalf — the registrar `fn_product_image_import_register` rejects any upload without `rights_confirmed=true` and never infers authorisation from a filename.

**Exact upload call (founder, signed-in session):**
```js
await supabase.functions.invoke("product-image-import", {
  body: {
    product_id: "e453eed4-3de4-4ed9-b889-1275c13c0dba",
    market: "GB",
    mime: "image/png",            // or image/jpeg | image/webp
    data_base64: "<the image bytes, base64>",
    rights_confirmed: true,        // the founder's explicit rights attestation
    filename: "e453-owned.png"
  }
});
```
The edge (JWT-protected, onboarding-gated) uploads to the private `pulse-product-imports` bucket and registers a `CUSTOMER_OWNED` / `CUSTOMER_UPLOAD` asset with `provenance.rights_confirmed=true`. Constraints: mime ∈ {png, jpeg, webp}, ≤ 15 MB, product ownership re-checked.

## 3. Resolver rank-1 + execution-time rights — proven (deterministic; rolled back; 0 paid)
Using a synthetic `CUSTOMER_OWNED` upload on e453 shaped exactly as the registrar stores it (inserted in a subtransaction and rolled back — nothing persisted):
| signal | result |
|---|---|
| readiness `ai_generation.reference_eligible` | **true** |
| readiness `ai_generation.execution_state` | **AVAILABLE** |
| readiness `reference_basis` | **CUSTOMER_OWNED_UPLOAD** |
| resolver `status` | **AUTHORISED_REFERENCE_AVAILABLE** |
| resolver `origin_rank` / `origin_basis` | **1 / CUSTOMER_OWNED_UPLOAD** |
| resolver `storage_ref` | `pulse-product-imports/7c8ddf9d…/e453eed4…/pilot.png` (private object; edge signs fresh 10-min URL) |
| resolver `rights_state` | CUSTOMER_OWNED |
| persisted after rollback | **0** |
| e453 live status right now | **NO_AUTHORISED_REFERENCE** (correctly fail-closed until a real image exists) |

So once a real owned image is uploaded, the edge v27 will: pass the readiness gate → resolve the owned image at rank 1 → sign a fresh short-lived URL from the private object → proceed to Gemini. The resolver's full behaviour is also green in its deployed selftest (12/12).

## 4. Gemini provider, pricing, hard cost controls (verified)
- **Provider:** `GOOGLE_GEMINI` **connected=true**, model `gemini-2.5-flash-image`, executor n8n `OYjIUMd0GS7OanbY`, identity validator n8n `HjjGApAXKpWXPh4q` (`gemini-2.5-flash`).
- **Pricing:** ≈ **$0.039/image** (1,290 output tokens @ $30 / 1M); PAL validation (`gemini-2.5-flash`) ≈ $0.001–0.005/image.
- **Hard cost controls in the deployed v27 edge:** `MAX_ATTEMPTS = 2` Gemini calls per scene (only an `IMAGE_OTHER` render-refusal retries, once); `RATE_MAX = 12` generated assets per 10-minute window per tenant.
- **Pilot cost:** 3 scenes ≈ **$0.12–0.13** expected; **hard ceiling ≈ $0.26** (≤ 6 generations) + ≈ $0.02 validation. **Recommended founder spend cap: $0.50.**

## 5. Three scenes (existing, deployed — no new generator)
- **CLEAN_STUDIO** — seamless neutral studio, soft even lighting, subtle shadow; premium hero product photo.
- **LIFESTYLE** — tasteful realistic setting, warm natural light, softly blurred background; premium lifestyle photo.
- **PRODUCT_IN_USE** — product shown naturally in use in a realistic everyday setting; premium e-commerce photo.
All three run the same owned reference + the same product-preservation prompt + the mandatory Product Asset Lock validation.

## 6. Visual acceptance criteria (per image; all must hold to accept)
1. **Product identity** — unmistakably the SAME product as the reference; not a different or generic nightlight projector.
2. **Features** — exact base + control interface preserved (no added/removed/changed buttons, switches, touch controls, ports, indicators); lens/projector head, gooseneck/arm, wings/panels and every accessory faithful.
3. **Proportions** — same overall shape, silhouette, geometry and relative sizes.
4. **Materials / colour / finish** — same materials, textures, finish, colour, and the same projected pattern if shown.
5. **Text / overlays** — NO text, words, letters, numbers, logos, badges, price tags, stickers, watermarks, UI overlays, ratings, reviews, faces or promotional graphics rendered.
6. **Realism** — photorealistic; correct lighting/shadows; no warping, artefacts, duplicated or malformed parts.
7. **Advertising quality** — premium and commercially usable: sharp, well-composed, scene appropriate to the product.
8. **Scene correctness** — the output matches the requested scene (studio / lifestyle / in-use).
9. **Provenance (checked in data, not just by eye)** — `commerce_generated_assets` row shows `reference_provider=CUSTOMER_UPLOAD`, `reference_rights_state=CUSTOMER_OWNED`, `provenance.reference.origin_basis=CUSTOMER_OWNED_UPLOAD`, `identity_validation_status=IDENTITY_VALIDATED`, model/workflow recorded; output stored in the private `pulse-generated-media`.
10. **Gate outcome** — the edge returned `status=READY_FOR_REVIEW usable:true` (only possible when `IDENTITY_VALIDATED`); a materially changed product returns `IDENTITY_VALIDATION_FAILED usable:false` and is rejected for inspection, not accepted.

**Acceptance rule:** accept a scene only if 1–8 hold on inspection AND 9–10 hold in the server response; otherwise reject (optionally regenerate within the cost cap, or revise the reference image). CS.05 is DONE only when all three scenes are accepted.

## 7. No download / subscriber access unintentionally enabled (verified)
- Generated output bucket `pulse-generated-media` is **private** (`public=false`); `pulse-product-imports` is **private**; the in-app review signed URL is short-lived and is not a download grant.
- BE330 added only `fn_resolve_authorised_ai_reference` + redeployed the edge — it changed **no** download gate, feature flag, RLS policy or subscriber-access control. The `media-asset-url` download path and CS.03 download gates are unchanged; the Creative Studio generate UI is not released to subscribers.
- **Historical quarantine intact (not restored):** 3 `commerce_generated_assets` + 6 `media_assets` remain flagged `rights_quarantine_active=true` (9 total), exactly as BE326/BE330 left them.
- Generation remains founder-only in practice: it requires a valid JWT + onboarding + product ownership + an eligible owned image, and only the founder-owned e453 will have one.

## Remaining requirements (founder's steps; the only blockers)
1. Provide one **owned/licensed image file** of the exact e453 product/variant (PNG/JPEG/WebP, ≤ 15 MB).
2. Make the **rights attestation** (`rights_confirmed=true`) — the founder's legal declaration.
3. Perform the **upload** via `product-image-import` from a founder-authenticated session (call above).
4. (I do, free) **Verify** on the real asset: resolver `rank 1 / CUSTOMER_OWNED_UPLOAD` with `storage_ref` under `pulse-product-imports/`; readiness `reference_eligible=true / AVAILABLE`.
5. **Approve the paid spend** (≈ $0.12; cap $0.50).
6. (I do, on approval) **Run** the 3 scenes; then the **founder visually inspects and accepts** per §6. Only then is CS.05 DONE.

## Actual readiness
System side: **READY** — product selected, resolver + readiness proven, provider connected, cost caps in force, scenes prepared, acceptance criteria defined, no download/subscriber leak. Blocked only on founder-supplied input (image + attestation) and the separate paid-run approval. No image was generated or purchased.

## Controls
0 paid Gemini/OpenAI; 0 credits; no code/migration/deployment change; no customer Creative Studio activation; no subscriber image/video downloads; no quarantined-asset restoration; no commercial-rights promotion; no GPD.07; PAL/ownership/RLS/tenant+country isolation + revocation/expiry preserved. GPD.09 + the December launch gates remain the higher priority. **GOLD 11/22 unchanged.** Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · CS.05 IN PREPARATION (not DONE — awaits generated-image inspection + acceptance). Evidence: this report, master-doc Addendum 102, Build Evidence row **BE331**.

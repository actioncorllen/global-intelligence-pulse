# BE332 — CS.05 founder-only pilot upload experience: inspection, rights-clarity fix (preview), findings, concept-mode assessment

**Executed:** 2026-11-27 · **Authority:** founder "CS.05 NEXT STEP — complete the founder-only pilot upload experience". **No production deployment, no paid/purchased generation, no customer release.** One copy-only frontend change made in the **Lovable preview** (not deployed). CS.05 remains **NOT DONE** (no real images generated; awaits generation + visual acceptance).

---

## 1. Inspection — Creative Studio + product-image-import integration
- **Upload API client:** `src/lib/commerce/commerce-actions-api.ts` → `importProductImage({productId, market, file, rightsConfirmed})` invokes the deployed `product-image-import` edge with `rights_confirmed:true` (JSON base64 body); `checkImportInput` pre-checks file + confirmation + accepted mime. Reuses the edge/storage/registrar — no rebuild.
- **Upload UI:** `src/components/commerce/product-commerce-actions.tsx` → `ImportDialog` (file picker restricted to backend `acceptedImageTypes`, a rights checkbox, "Upload image"). Reached from a product's commerce actions via the **"Import Product Images"** button, or auto-opened as **"Add an approved product image"** when an action (Create Ad / Create Free Store / Add to Store) needs an authoritative image and none exists.
- **Gemini 3-scene generator:** `src/components/commerce/commercial-image-generator.tsx` → `CommercialImageGenerator` (scenes Clean Studio / Lifestyle / Product in Use → `generateCommercialImage` → the deployed v27 edge; "Use this image" gated on server `IDENTITY_VALIDATED`). It renders **inline on the product card**, not inside the Creative Studio route.
- **`/workspace/creative` (Creative Studio route)** is the **Ad Studio** (platform + creative format → `generateCreative`), a **separate OpenAI/ad lane** that uses the fixed product-card image ("can't be swapped in this workflow"). It is **not** the Gemini commercial-image pilot path.
- **Identity/authorisation/PAL reused:** the registrar `fn_product_image_import_register` (ownership + `rights_confirmed` + mime/size), the BE326 readiness gate, the CS.04 authorised-reference resolver, and PAL identity validation are all reused unchanged.

## 2. Exact route + usage instructions (the upload interface already works — not rebuilt)
To upload an owned product photo for the pilot product (e453 "kids nightlight projector"):
1. Open the product in the **Workspace product list / Product Research** (signed in as the founder).
2. On the product's actions, click **"Import Product Images"** (or trigger any action that asks for an approved image — the **"Add an approved product image"** dialog opens).
3. In the dialog: **choose an image file** (PNG / JPEG / WebP, ≤ 15 MB) of the exact product/variant, **tick the rights checkbox**, click **"Upload image."**
4. The image is uploaded to the **private** `pulse-product-imports` bucket and registered as `CUSTOMER_OWNED` with `rights_confirmed=true`.

## 3. Rights confirmation — explicit commercial + AI-input (done, preview only)
**Gap found:** the rights checkbox read *"I confirm that I own this image or have permission to use it for this product and advertising."* — it covered ownership + advertising but **not** AI image generation (AI-input). **Smallest fix (copy only, existing component, no rebuild):** the checkbox now reads:

> *"I confirm I own this image or have permission to use it for this product, including its use in commercial advertising and as a reference for AI image generation."*

This makes the uploader **explicitly confirm commercial AND AI-input rights**. Changed exactly one label string in `product-commerce-actions.tsx`; validation, submit handler, upload call and every other file left untouched; 9 existing dialog tests pass. Committed in the **Lovable preview** (`bd7463a`), **not deployed/published**. Claude did **not** attest rights on the founder's behalf — the attestation remains the uploader's explicit action.

## 4. Verification — private storage + resolver never uses uncleared CJ/marketplace
- **Private storage:** `pulse-product-imports` is private (`public=false`); the edge uploads with the service role and registers `CUSTOMER_OWNED`; the durable signed URL is for pipeline fetch, and BE330/BE331 proved the edge signs a **fresh** short-lived URL from the private object at execution.
- **Resolver selects owned, never CJ/marketplace:** the deployed `fn_resolve_authorised_ai_reference` (mig_379) returns rank-1 for the owned upload and **never** a bare supplier/marketplace image — proven live (e453's 40 real supplier/marketplace images → **0** authorised candidates; selftest 12/12). The edge no longer calls the supplier storefront at all.

## 5. Findings reported (NOT changed — they touch the *generate* surface that control #8 keeps inactive)
Fixing these **surfaces/activates** the generate step, so per "keep the three-scene paid pilot inactive" they are reported with exact fixes to apply **at pilot activation**, bundled with the founder's spend approval:

- **F1 (functional — generate button won't appear):** `product-commerce-actions.tsx` gates the Gemini generator on `commercialAssetReadiness === "GENERATABLE_FROM_AUTHORIZED_REFERENCE"`, a value the **BE324/BE326 readiness gate no longer returns** (it returns `READY` for an owned-eligible product). Verified: with the founder's auth + an owned image, `fn_product_commercial_asset_readiness_owned` returns `commercial_asset_readiness=READY`, `ai_generation.execution_state=AVAILABLE`, `reference_eligible=true`. **Exact fix:** gate the generator on `ai_generation.execution_state === "AVAILABLE"` (authoritative), i.e. set `generationAvailable = executionState === "AVAILABLE"` (drop the `GENERATABLE_FROM_AUTHORIZED_REFERENCE` dependency); keep `generationBlocked`/`generationNotEligible` keyed off `execution_state`. Without this, the founder can upload but the "Create publishable product image" button never appears.
- **F2 (honesty/copy — stale post-CS.04):** `commercial-image-generator.tsx` says "from your authorized **supplier** reference" (status line + review dialog) and "authorized **supplier** image". After CS.04 the reference is the customer's **owned/licensed** image, never supplier. **Exact fix:** replace "authorized supplier reference/image" with "authorized product image."
- **F3 (consistency, optional):** a second upload path in `src/components/storefront/publish-controls.tsx` has its own rights copy ("a product image you own or have permission to use"); align it with the §3 wording if/when desired. The §3 `ImportDialog` is the primary CS.05 path.

## 6. TASK 7 — assessment of a future TEXT-ONLY ORIGINAL CONCEPT mode (assessment only; not built)
**Concept:** a *separate* lane where the founder types a text prompt and Gemini produces an **unbranded, generic concept visual** (no product reference image) — for ideation/mood exploration, never a depiction of a specific real product.
**It must obey these hard guardrails (non-negotiable):**
1. **Never represented as exact-product commercial photography.** Labelled everywhere as "Original concept — not a photo of your product"; outputs watermarked/tagged as concept art in provenance.
2. **Separate lane, separate provenance.** A distinct generation type (e.g. `ORIGINAL_CONCEPT`) with **no** `reference_asset`, **not** identity-validated against any product, stored separately; it must not write a product's `commerce_generated_assets` commercial row.
3. **Must not bypass existing generation permissions.** It must not call or weaken the authorised-reference resolver, the readiness gate, PAL, or the rights checks that govern real-product generation; it has no access to uncleared CJ/marketplace imagery (text-only input).
4. **Not attachable to a real product** as its commercial/display image; cannot publish to a storefront/ad as the product's photo; no subscriber release without separate approval; its own spend controls + explicit founder spend approval.
5. **Never implies the product's identity** or that the concept is the real item.
**Feasibility:** reuses the Gemini executor but needs a **new** edge/lane + provenance type + clearly-separated UI (not built here). Recommendation: viable as a clearly-fenced future lane under the guardrails above; it must remain wholly separate from the CS.04/CS.05 exact-product commercial path. **No work started.**

## 7. Roadmap update (only genuinely completed work)
- **Done (preview):** the rights-confirmation clarity — the uploader now explicitly confirms commercial + AI-input rights (BE332, Lovable preview `bd7463a`, not deployed).
- **CS.05: still NOT DONE.** No real images generated; the generate-surfacing fix (F1) + the actual 3-scene paid pilot + visual acceptance remain. The paid pilot stays inactive until a genuine authorised reference is uploaded and the founder approves the spend.

## Controls
0 paid Gemini/OpenAI; 0 credits (Lovable agent cost 0.5 workspace credits for the copy edit); no production deployment; no customer release (preview only); no quarantined-asset restoration; no commercial-rights promotion; no GPD.07; Claude did not attest rights; PAL/ownership/RLS/tenant+country isolation + revocation/expiry preserved. GPD.09 + the December launch gates remain the higher priority. **GOLD 11/22 unchanged.** Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · CS.05 IN PROGRESS (upload experience: rights clarity done in preview; generate-surfacing fix + paid pilot + acceptance pending). Evidence: this report, master-doc Addendum 103, Build Evidence row **BE332**. Frontend change: Lovable project `12db6c84`, commit `bd7463a` (preview, undeployed).

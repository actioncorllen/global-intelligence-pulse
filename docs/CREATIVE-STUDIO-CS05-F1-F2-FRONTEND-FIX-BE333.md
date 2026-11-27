# BE333 — CS.05 founder-pilot frontend fix F1 (generator visibility) + F2 (accurate copy), preview only

**Executed:** 2026-11-27 · **Authority:** founder "CS.05 FOUNDER PILOT FRONTEND FIX — APPROVED (F1 + F2), preview only, not production deployment or paid generation." **Implemented + verified in the Lovable PREVIEW; NOT deployed to production; 0 paid Gemini calls.** CS.05 remains **NOT DONE** (a real three-image pack must be generated and visually accepted first).

---

## F1 — generator visibility now matches the deployed BE326 contract
**File:** `src/components/commerce/product-commerce-actions.tsx` (existing `CommercialImageGenerator` host; no new component). Replaced the obsolete gate:
```
- const canOfferGeneration = commercialAssets?.commercialAssetReadiness === "GENERATABLE_FROM_AUTHORIZED_REFERENCE";
- const generationAvailable = canOfferGeneration && generationState === "AVAILABLE";
- const generationBlocked   = canOfferGeneration && generationState === "BLOCKED_EXTERNAL_CONNECTION";
+ const referenceEligible = commercialAssets?.aiGeneration?.referenceEligible;
+ const generationAvailable = generationState === "AVAILABLE" && referenceEligible === true;
+ const generationBlocked   = generationState === "BLOCKED_EXTERNAL_CONNECTION";
  const generationNotEligible = generationState === "NOT_ELIGIBLE";
```
The generator is now exposed **only** when the authoritative owned-readiness response says the server will accept it — `execution_state === "AVAILABLE"` **and** `reference_eligible === true`. It is never exposed because an unrelated `READY` label is present. The required combination is satisfied:
- **execution_state = AVAILABLE** and **reference_eligible = true** — both required.
- **authenticated authorised owner/founder context** — the frontend reads `fn_product_commercial_asset_readiness_owned`, which returns `unauthorized` / `UNAVAILABLE` with **no** `ai_generation` block for a non-owner (→ `generationAvailable=false`).
- **correct product + selected market** — readiness is fetched per `(productId, market)`; with no market, `commercialAssets` is null → `generationAvailable=false`.
- **server-side Gemini edge remains the final authority** — unchanged; the deployed v27 edge re-checks readiness + resolver + ownership on every call (verify_jwt=true).

## F2 — accurate copy (no more "supplier")
All stale "authorised **supplier** image/reference" wording replaced with accurate product-image wording; the BE332 rights-attestation checkbox (commercial advertising + AI image generation) is **preserved unchanged**:
- `src/components/commerce/commercial-image-generator.tsx`: status line and review dialog now read "from your authorized **product image**".
- `src/components/commerce/product-commerce-actions.tsx` + `src/components/commerce/store-website-panel.tsx` (My Store card): the not-eligible message now reads "A customer-owned or licensed product image is required."
- `src/lib/commerce/commerce-actions-api.ts`: the NOT_ELIGIBLE fallback message updated to the same.
A search of `src` confirms **no "authorized supplier image/reference" wording remains**. The My Store card's generation **gate** already used `aiGenerationState === "AVAILABLE"` (not the obsolete label), so it was left unchanged — only its copy was aligned.

**Changes:** 6 files, preview commits `4b49b049` (F1 + F2 main) and `fd2ddda` (My Store copy + 2 test assertions). Two test assertions that referenced the old copy were updated to the new copy; no other assertion changed.

## Validation — 9/9 (deterministic fixtures + existing infrastructure; 0 paid Gemini calls)
Backend readiness values the frontend receives (proven via `fn_product_commercial_asset_readiness_owned` with auth context + rolled-back synthetic fixtures; nothing persisted):

| # | scenario | backend readiness | new gate result |
|---|---|---|---|
| 1 | Eligible owned product, authorised founder | `READY` / exec `AVAILABLE` / ref_eligible `true` | **generate button VISIBLE** — PASS |
| 2 | Missing image | `CUSTOMER_ASSET_REQUIRED` / `NOT_ELIGIBLE` / `false` | **no generation action** — PASS |
| 3 | Uncleared supplier/marketplace only (live e453) | `CUSTOMER_ASSET_REQUIRED` / `NOT_ELIGIBLE` | **no generation action** — PASS |
| 4 | Supplier image with **revoked** ai_input rights | `NOT_ELIGIBLE` / `false` | **no generation action** — PASS |
| 5 | Different product / market | readiness per (productId, market); null market → null | **no cross-context leakage** — PASS |
| 6 | Subscriber without permissions (non-owner) | `unauthorized` / `UNAVAILABLE` / exec `null` | **no unauthorised action** — PASS |
| 7 | Gemini edge direct unauthorised invocation | edge `verify_jwt=true` + ownership + readiness re-check (unchanged, BE330) | **rejected** — PASS |
| 8 | Mobile + desktop layouts | logic + copy change only; no layout change; preview build "build OK" | **functional** — PASS |
| 9 | Existing regressions | Lovable 9 files / 95–97 tests pass (commerce actions, commercial image generation, asset lock, storefront generation 19, creative studio, market isolation, research images, publish blockers, action dispatch); backend selftests 0 failures (BE330 99 checks) | **pass** — PASS |

Expired per-image rights behave identically to revoked (both excluded by the deployed resolver/readiness predicate, verified in prior selftests). Claude did not invent an eligible upload or make a rights declaration for the founder.

## Founder-only preview acceptance steps
1. Open the Lovable **preview** (`id-preview--12db6c84…lovable.app`), signed in as the founder.
2. Open the pilot product **e453 "kids nightlight projector"** in Product Research → confirm **no** generate button yet, and the message **"A customer-owned or licensed product image is required."**
3. **Import Product Images** → choose an owned/licensed photo of the exact product → tick the rights checkbox (now explicitly covering commercial advertising + AI image generation) → Upload.
4. Confirm the **"Create publishable product image"** generator (scene selector + button) now appears on e453, with the three scenes Clean Studio / Lifestyle / Product in Use.
5. (Separately, on explicit spend approval) select a scene and generate → review → accept per the BE331 visual criteria. Only when a real three-image pack is generated and visually accepted is CS.05 DONE.

Steps 3–5 require a real owned image + the founder's session + spend approval; they are the founder's actions.

## Release boundaries honoured
No production deployment; no paid generation (0 Gemini/OpenAI calls, 0 credits — Lovable agent spent 0.9 workspace credits on the two preview edits); no subscriber Creative Studio release; no customer download enablement; no changes to rights records; no quarantined-asset restoration; no GPD.07; PAL/ownership/RLS/tenant+country isolation + revocation/expiry preserved. Claude did not attest rights for the founder. GPD.09 + the December launch gates remain the higher priority. **GOLD 11/22 unchanged.**

## Roadmap (only genuinely completed work)
- **Done (preview):** F1 generator-visibility fix + F2 accurate copy (BE333), on top of BE332 rights-attestation clarity. The upload→generate flow is now coherent in preview.
- **CS.05: still NOT DONE** — a real three-image pack (Clean Studio / Lifestyle / Product in Use) must be generated from an uploaded authorised reference and **visually accepted** by the founder; the paid pilot stays inactive until the founder supplies a genuine authorised reference and approves the spend. Production deployment of the preview changes is a separate controlled step.

Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · CS.05 IN PROGRESS. Evidence: this report, master-doc Addendum 104, Build Evidence row **BE333**. Frontend: Lovable project `12db6c84`, preview commits `4b49b049` + `fd2ddda` (undeployed).

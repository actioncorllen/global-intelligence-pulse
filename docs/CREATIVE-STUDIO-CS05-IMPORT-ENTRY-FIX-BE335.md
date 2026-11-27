# BE335 — Founder production acceptance failure: the missing "Import Product Images" entry in the Product Research detail Actions panel — DIAGNOSED + CORRECTED (preview only)

**Executed:** 2026-11-27 · **Authority:** founder "BE334 FOUNDER PRODUCTION ACCEPTANCE FAILURE — real production-UX investigation + smallest necessary frontend correction in Lovable Preview; do not deploy to production without separate founder approval." **Verdict: ROOT-CAUSED + FIXED IN PREVIEW + VERIFIED (real rendering path).** The founder upload entry point is now discoverable on the SharkNinja-style product detail without first owning an image; the Gemini generator stays fully gated; **nothing deployed to production** (production remains BE334 `fd2ddda`); **0 paid Gemini/OpenAI calls; GOLD 11/22 unchanged; CS.05 remains IN PROGRESS.**

---

## Founder evidence (the acceptance failure)
On live production `https://strateloq.com/workspace?view=opportunities`, the SharkNinja BlastBoss product detail's bottom-right **Actions** panel showed only **Create Ad** and **Add to My Store**. **Missing:** **Import Product Images** and the **Create publishable product image / Gemini generation** entry. The product reports: identity *identified, not yet confirmed*; commercial rights *NOT VERIFIED*; supplier match *not verified*. The founder had reached the real Actions panel — this was a genuine rendering-path finding, not a scrolling problem.

## TASK 1 — Diagnosis (the real rendering path, source-grounded)

**Where the panel mounts.** The bottom-right Actions panel is `ProductCommerceActions` (`src/components/commerce/product-commerce-actions.tsx`). It is mounted in two routes:
- **Product Research / Workspace opportunity detail** — `src/components/business-discovery/ecommerce-workspace.tsx` (the detail view the founder was looking at), at the detail mount (~line 650–666).
- **Product Explorer** — `src/components/business-discovery/product-explorer.tsx:1179–1190`, with `concreteProductActionsAllowed={false}`.

**Confirmed: it IS mounted in the founder's route.** The SharkNinja detail renders `ProductCommerceActions`; that is why Create Ad + Add to My Store appear. So the finding was not "component absent" — it was "one action suppressed".

**Why Import Product Images was hidden — TWO independent layers (the root cause):**
1. **Backend action list.** `fn_product_card_commerce_actions` returns the Actions list and only offers `IMPORT_PRODUCT_IMAGES` when `needs_import = true`, i.e. when the product has **no** display image. SharkNinja already has a display image (its supplier/marketplace photo), so `needs_import = false` and the backend **does not emit** the import action.
2. **Frontend filter.** Even when the backend emits it, `filterVisibleActions` in `product-commerce-actions.tsx` drops `IMPORT_PRODUCT_IMAGES` when `concreteProductActionsAllowed === false`. SharkNinja is CONCEPT_ONLY (`fn_product_identity_resolution` → `supplier_link_allowed = false` because identity is not `IDENTITY_RESOLVED`), so `concreteProductActionsAllowed = false` (set at `ecommerce-workspace.tsx:474` from `decision.productIdentity?.supplierLinkAllowed === true`), and the action is filtered out.

Because **both** layers must pass for the old button to appear, and SharkNinja fails both (it has a display image AND its identity is unconfirmed), the founder had **no upload entry at all** — exactly the production symptom. The previously-verified upload component (the `ImportDialog` inside `ProductCommerceActions`, wired to `importProductImage` → `product-image-import`) was present in the bundle but **unreachable** on this product: its only trigger was the suppressed/filtered `IMPORT_PRODUCT_IMAGES` action.

**Distinguishing source-exists vs rendered-in-route:** the upload dialog, the registrar call, and the rights checkbox all **exist and are correct in source** (BE332/BE333/BE334). The defect was purely **reachability in this route** — the detail view gave the founder no control that opens the existing dialog for a product that already has a (supplier) image and whose identity is unconfirmed.

## TASK 2 — Correction (smallest frontend change, reuses existing components)

A standalone, clearly-labelled **"Import Product Image"** button was added to `ProductCommerceActions`, gated by a new opt-in prop `allowImageImport?: boolean` (default `false`), and switched on **only** at the Product Research / Workspace **detail** mount. It reuses the existing `ImportDialog` + `importProductImage` + `product-image-import` path unchanged — no new upload component, no new dialog, no backend change.

**Exact changes (preview commit `a94fb28`, 2 files, +24/-0):**
- `src/components/commerce/product-commerce-actions.tsx` (+23/-0): added the `allowImageImport?: boolean` prop (default `false`) and a standalone secondary button rendered **only** when `allowImageImport` is true **and** the backend action list does not already include `IMPORT_PRODUCT_IMAGES` (so there is never a duplicate entry). It opens the existing import dialog:
  ```tsx
  {allowImageImport &&
    !visibleActions.some((a) => a.key === "IMPORT_PRODUCT_IMAGES") && (
      <Button type="button" size="sm" variant="secondary" disabled={busy !== null}
        onClick={() => { pendingRef.current = null; setGateMessage(null); setDialog("import"); }}>
        <ImagePlus aria-hidden="true" /> Import Product Image
      </Button>
    )}
  ```
  Inserted inside the existing `flex flex-wrap items-center gap-2` action row, after `{visibleActions.map(...)}`, so layout and mobile wrapping are preserved. `filterVisibleActions` and the generator gate are **untouched**.
- `src/components/business-discovery/ecommerce-workspace.tsx` (+1/-0): added `allowImageImport={true}` to the **detail-view** `ProductCommerceActions` mount only. The Product Explorer mount (`product-explorer.tsx`, `concreteProductActionsAllowed={false}`, no `allowImageImport`) is **unchanged**, so the new control appears only in the full detail context.

**Does not require an already-authorised image to reveal it.** The button is independent of both suppression layers — it shows regardless of `needs_import` and regardless of `concreteProductActionsAllowed`, so the founder can reach the upload dialog on a product (like SharkNinja) that already has a supplier image and whose identity is unconfirmed. Identity confirmation is **not** a precondition to *offer the upload*; it remains a precondition to *generate* (TASK 3). The dialog itself carries the truthful rights attestation (BE332 copy) the uploader must make, so there is no silent hiding and no false claim: the founder is offered the upload, and the generator only follows once the owned image + authorisation exist.

## TASK 3 — Security preserved (the generator stays gated; SharkNinja cannot generate)

No change was made to generation gating. The Gemini "Create publishable product image" generator is still exposed **only** when `execution_state === "AVAILABLE"` **and** `reference_eligible === true` (the BE333 F1 gate, reading `fn_product_commercial_asset_readiness_owned` under authenticated owner/founder context, scoped to the product + selected market). SharkNinja is CONCEPT_ONLY with an unconfirmed identity and only supplier/marketplace imagery → readiness `NOT_ELIGIBLE` → **the generator stays hidden**, correctly. The unverified SharkNinja supplier photo is never an AI input: the deployed resolver (`fn_resolve_authorised_ai_reference`, mig_379) and the readiness gate never select a bare supplier/marketplace image. No auto-promotion of supplier match, image rights, or product identity. The server-side edge (`verify_jwt=true` + ownership + readiness re-check, v27) remains the final authority. No BE326/BE330 gate was relaxed.

## TASK 4 — Verification of the real rendering path (not isolated fixtures)

A focused regression test was added that renders the **real** `ProductCommerceActions` component (not a mock of it), mocking only the backend API layer the way the existing commerce tests do (`@/lib/commerce/commerce-actions-api`) and the router. The backend fixture mirrors the **live SharkNinja case**: `fetchCommerceActions` resolves actions = `CREATE_AD` + `ADD_TO_STORE` only (no `IMPORT_PRODUCT_IMAGES`), readiness `NOT_ELIGIBLE`; `fetchCommercialAssetReadiness` returns `execution_state = NOT_ELIGIBLE`, `reference_eligible = false`; `importProductImage` is a no-network mock.

**Test file (preview commit `df1e2f6`, 1 new file, +91/-0):** `src/components/commerce/product-commerce-actions.import-entry.test.tsx`. Asserts, in the real render:
1. **Detail view (`allowImageImport={true}`):** a button named **"Import Product Image"** renders — *even though the backend returned no `IMPORT_PRODUCT_IMAGES` action* (proves the fix bypasses both suppression layers).
2. **Dialog opens** on click: the rights-attestation **checkbox is present and NOT checked by default** (both `aria-checked="false"` and `data-state="unchecked"`), and its label contains **both** "commercial advertising" **and** "AI image generation" (the BE332 copy — commercial + AI-reference rights explicit).
3. **Explorer view (`allowImageImport={false}`):** the "Import Product Image" button is **absent** (the new control is scoped to the detail context only).
4. **Generator gated:** the "Create publishable product image" generator is **NOT rendered** in this `NOT_ELIGIBLE` case (no-image / unverified products cannot generate).

**Result: the new test passes; the full commerce suite passes — 12 test files, 129 tests, 0 failures.** The earlier full-suite run after the fix was **200 tests green**. Validation against the founder's TASK 4 checklist:

| Validation item | Result |
|---|---|
| Founder upload entry discoverable when eligible (detail route) | **PASS** — real-render test asserts the button renders on the SharkNinja-shaped fixture |
| Dialog opens from the visible action | **PASS** — click opens the real `ImportDialog` |
| Rights checkbox starts unchecked | **PASS** — `aria-checked="false"` + `data-state="unchecked"` |
| Commercial advertising + AI-reference rights explicit | **PASS** — label contains "commercial advertising" and "AI image generation" |
| Ownership checks work | **PASS (unchanged)** — upload → `product-image-import` → `fn_product_image_import_register` re-checks ownership + requires `rights_confirmed=true` (BE332/BE330) |
| Unverified restrictions truthful (not silently hidden) | **PASS** — the upload is offered with the truthful rights attestation; generation stays restricted with the "customer-owned or licensed product image is required" messaging (BE333 F2), not a blank panel |
| No-image / unverified products cannot generate | **PASS** — generator not rendered in the `NOT_ELIGIBLE` case |
| Non-owner / subscriber restricted | **PASS (unchanged)** — `fn_product_commercial_asset_readiness_owned` returns unauthorized/UNAVAILABLE for a non-owner → generator gate false; edge `verify_jwt=true` + ownership |
| Desktop + mobile | **PASS (artifact)** — the button sits inside the existing `flex flex-wrap items-center gap-2` row; no layout change; preview build OK. Signed-in interactive runtime = founder's browser sighting (BE319/BE299/BE300 precedent — a production session cannot be minted here) |
| BE334 + BE326 regressions green | **PASS** — commerce suite 12 files / 129 tests 0 failures; `filterVisibleActions` + generator gate + resolver/edge v27 untouched |

## Is the e453 pilot reachable through the corrected workflow?
**Yes.** The pilot product **e453 "kids nightlight projector"** is `IDENTITY_RESOLVED` → `supplier_link_allowed = true` → `concreteProductActionsAllowed = true`. On e453 the founder now reaches the upload in **two** ways: (a) the existing backend `IMPORT_PRODUCT_IMAGES` action when e453 has no display image, and (b) the new standalone "Import Product Image" button in the detail view regardless. After the founder uploads one real owned/licensed image of the exact e453 variant and attests rights, `fn_product_commercial_asset_readiness_owned` returns `execution_state=AVAILABLE` + `reference_eligible=true`, and the **existing (unchanged)** BE333 generator gate then surfaces the "Create publishable product image" generator with the three scenes (Clean Studio / Lifestyle / Product in Use). **No generator-gate change was needed** — this is why the fix was *only* the Import button. SharkNinja (CONCEPT_ONLY) correctly keeps the generator hidden.

## TASK 5 — Closeout

- **Root cause:** the founder had no upload entry on the SharkNinja detail because `IMPORT_PRODUCT_IMAGES` is suppressed by **two** independent layers — the backend `fn_product_card_commerce_actions` omits it when a display image exists (`needs_import=false`), and the frontend `filterVisibleActions` drops it when `concreteProductActionsAllowed=false` (CONCEPT_ONLY / `supplier_link_allowed=false`). SharkNinja fails both, so the existing (correct) upload dialog was unreachable in that route.
- **Exact files / conditions changed (preview only):**
  - `src/components/commerce/product-commerce-actions.tsx` — new `allowImageImport?: boolean` prop (default false) + a standalone "Import Product Image" button that opens the existing import dialog, shown only when `allowImageImport && !visibleActions.some(a=>a.key==="IMPORT_PRODUCT_IMAGES")`. `filterVisibleActions` + generator gate untouched. (commit `a94fb28`)
  - `src/components/business-discovery/ecommerce-workspace.tsx` — `allowImageImport={true}` on the detail-view mount only. (commit `a94fb28`)
  - `src/components/commerce/product-commerce-actions.import-entry.test.tsx` — new real-render regression test. (commit `df1e2f6`)
- **Preview test evidence:** real-component test + full commerce suite = **12 files / 129 tests / 0 failures** (post-fix full suite: 200 green). Preview HEAD `df1e2f6`; fix `a94fb28`. Preview URL `https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app`.
- **e453 pilot accessibility:** reachable through the corrected workflow (above).
- **Next BE id:** **BE336.**
- **Production deployment recommendation:** the fix is a small, strictly-additive, fail-closed-preserving frontend change (one new opt-in prop + one button + one test; no backend change; generator gating unchanged). It is **ready for a controlled production deploy on separate founder approval** — same narrowly-scoped Lovable `deploy_project` mechanism as BE334 (production currently `fd2ddda`; this would ship preview HEAD `df1e2f6` once approved, with a pre-deploy diff confirmation that the delta is exactly these 3 files). **Not deployed under this directive.**

## Strict limits — all honoured
No paid Gemini/OpenAI calls (0). No AI generation. No rights attestation on behalf of the founder (the attestation remains the uploader's explicit, unchecked-by-default action). No customer download or subscriber release. No unrelated UI changes (3-file delta; `filterVisibleActions` + generator gate untouched). No relaxation of BE326/BE330 authorisation gates. No GPD.07 activation. GOLD 11/22 unchanged. **CS.05 remains IN PROGRESS** — a real three-image pack must still be generated from an uploaded authorised reference and visually accepted by the founder. Founder UI acceptance is **not** declared passed by this report: the corrected action is genuinely accessible in the real rendering path (verified by the real-component test), and the final human sighting remains the founder's browser confirmation after a controlled deploy.

Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · CS.05 IN PROGRESS. GPD.09 + the remaining 18-December launch gates remain the higher priorities. Evidence: this report, master-doc Addendum 106, Build Evidence row **BE335**. Frontend: Lovable project `12db6c84`, preview commits `a94fb28` (fix) + `df1e2f6` (test), **undeployed**.

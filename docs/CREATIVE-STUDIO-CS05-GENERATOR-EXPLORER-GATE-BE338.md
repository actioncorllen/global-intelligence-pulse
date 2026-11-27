# BE338 — Surface the Gemini generator on the real ExplorerDrawer path, gated by authoritative identity + readiness (preview only)

**Executed:** 2026-11-27 · **Authority:** founder "BE337 FOLLOW-UP — resolve the remaining Gemini generator accessibility on the real ExplorerDrawer path. Smallest safe end-to-end implementation. Preview only; no production deployment; no paid calls." **Implemented + verified in the Lovable PREVIEW (commit `6709e36`); NOT deployed (production remains BE336 `df1e2f6`); 0 paid Gemini/OpenAI calls; GOLD 11/22 unchanged; CS.05 remains IN PROGRESS.** The BE337 Import fix is preserved.

---

## Current defect (recap)
The Explorer mount hard-codes `concreteProductActionsAllowed={false}` ("Explorer rows carry no server identity verdict: fail closed"). In `product-commerce-actions.tsx` the Gemini generator and its status messages were gated by `concreteProductActionsAllowed`, so the generator could never appear on the founder's Product Research drawer — even for an identity-resolved product with a genuinely authorised owned image.

## Requirement 2 — backend readers inspected (authoritative)
Read the deployed definitions of `fn_product_commercial_asset_readiness`, `fn_product_commercial_asset_readiness_owned`, and `fn_product_identity_resolution`:
- `fn_product_commercial_asset_readiness_owned` (EXECUTE: authenticated; SECURITY DEFINER) checks `auth.uid() == owner`, returns `unauthorized`/`UNAVAILABLE` for non-owners, else delegates to `fn_product_commercial_asset_readiness`. **This is the owner-scoped, fail-closed authority.**
- `fn_product_commercial_asset_readiness`: `ai_generation.reference_eligible = has_customer_owned OR has_ai_authorised_owned_asset OR has_ai_evidence`; `execution_state = AVAILABLE` iff `reference_eligible` AND provider connected. **It does NOT require identity resolution.**
- `fn_product_identity_resolution(p_product_id)` (EXECUTE: authenticated; SECURITY DEFINER) returns `identity_state` + `supplier_link_allowed` (true only when `identity_state = IDENTITY_RESOLVED`). This is the canonical "concrete identity resolved" signal (per `AGENTS.md`, `ecommerce-workspace-contract.ts:274`).

**Proof the identity gate is necessary (rolled back, 0 persisted):** a synthetic `CUSTOMER_OWNED` rights-confirmed image on SharkNinja (CONCEPT_ONLY) → `execution_state=AVAILABLE`, `reference_eligible=true`, `commercial_asset_readiness=READY`, **but** `identity_state=CONCEPT_ONLY`, `supplier_link_allowed=false`. So gating the generator on readiness alone would wrongly expose it for a CONCEPT_ONLY product — the generator must additionally require `supplier_link_allowed===true`.

## Requirement 3 — ExplorerDrawer obtains the authoritative server-side decision
`ProductCommerceActions` already fetches `fn_product_commercial_asset_readiness_owned` (owner + rights + market + execution_state + reference_eligible). BE338 adds an identity fetch so the drawer also has the authoritative identity verdict. New reader `fetchProductIdentityResolution(productId)` (`src/lib/commerce/commerce-actions-api.ts`) calls `supabase.rpc("fn_product_identity_resolution", { p_product_id })` and returns `{ supplierLinkAllowed }`, failing closed (`false`) on any error/null.

## Requirements 4–8 — the gate (preview commit `6709e36`)
`src/components/commerce/product-commerce-actions.tsx`:
- New opt-in prop `allowCommercialGeneration?: boolean` (default `false`).
- When `allowCommercialGeneration` is true, a react-query `useQuery` (ENABLED only when the prop is true) fetches identity; `identityResolved = identityData?.supplierLinkAllowed === true`.
- `const generatorSurfaceAllowed = concreteProductActionsAllowed || (allowCommercialGeneration && identityResolved);`
- **Only** the 4 generator-surface blocks (the `CommercialImageGenerator` + its `generationAvailable` / `generationBlocked` / `generationNotEligible` status messages) now gate on `generatorSurfaceAllowed` instead of `concreteProductActionsAllowed`. The BE333 readiness gate is unchanged: `generationAvailable = generationState === "AVAILABLE" && referenceEligible === true`. So the generator shows **only** when `generatorSurfaceAllowed` AND `generationAvailable`.
- `filterVisibleActions(state.actions, concreteProductActionsAllowed)` and every other `concreteProductActionsAllowed`-gated element (View-public-listing link, ProductPageBuilder, all storefront/supplier/publishing actions) are **untouched** → requirement 7 satisfied. `concreteProductActionsAllowed` is **not** hard-coded true anywhere → requirement 6 satisfied.

`src/components/business-discovery/product-explorer.tsx`: the ExplorerDrawer `ProductCommerceActions` mount (which already has `concreteProductActionsAllowed={false}` + `allowImageImport={true}` from BE337) now also has `allowCommercialGeneration={true}` (+1 line). No other mount/file logic touched.

**Net effect:**
- On the Explorer mount: generator shows **only** when `supplier_link_allowed===true` (identity resolved) AND the owner-scoped readiness says `execution_state=AVAILABLE` + `reference_eligible=true`. SharkNinja (CONCEPT_ONLY) → hidden even with an owned image; e453 pre-upload → hidden (NOT_ELIGIBLE); e453 after an authorised owned image → shown. Concrete storefront/supplier/publishing actions stay fail-closed.
- On the DecisionCard mount (no `allowCommercialGeneration`): behaviour is byte-identical (`generatorSurfaceAllowed == concreteProductActionsAllowed`); the identity query does not run.

**Requirement 8 (isolation / PAL / BE326-BE330 preserved):** no backend change. The new frontend gate is strictly MORE restrictive than before (adds an identity requirement on top of readiness); `generationAvailable` derives from the owner-scoped fail-closed `fn_product_commercial_asset_readiness_owned`, so a non-owner gets `UNAVAILABLE` → generator hidden; tenant/country isolation, Product Asset Lock and the deployed v27 edge (`verify_jwt=true` + ownership + readiness + resolver + PAL identity-validation at generation) are unchanged and remain the final authority.

## Requirements 9–11 — verification (real ExplorerDrawer integration tests)
`src/components/business-discovery/product-explorer.import-entry.test.tsx` (extended) renders the **real `ExplorerDrawer` + real `ProductCommerceActions`**, mocking only the data hooks + `@/lib/commerce/commerce-actions-api` (incl. the new `fetchProductIdentityResolution`) + supabase client + router; `importProductImage` and `generateCommercialImage` are no-network `vi.fn`s asserted never called:
1. **SharkNinja** — `supplierLinkAllowed=false` AND readiness `execution_state=AVAILABLE`/`reference_eligible=true`: the "Create publishable product image" generator is **NOT** rendered (identity gate), and the "Import Product Image" button **IS** rendered. (Proves requirement 9 SharkNinja + requirement 5.)
2. **e453 not-yet-eligible** — `supplierLinkAllowed=true`, readiness `NOT_ELIGIBLE`: generator **NOT** rendered; Import **IS** rendered.
3. **e453 eligible** — `supplierLinkAllowed=true`, readiness `AVAILABLE`/`reference_eligible=true`: generator **IS** rendered. (Proves requirement 9 e453 + requirement 4.)

**Results:** product-explorer + commerce suites 19 files / 158 tests; **full suite 119 files / 1,097 tests pass**; preview build OK. Requirement 10 (real ExplorerDrawer, not isolated fixtures) satisfied. Requirement 11: no layout change — the generator renders in the same actions area; mobile/desktop unaffected (artifact-level; final sighting is the founder's browser).

**Test-harness note (no behaviour change):** because `ProductCommerceActions` now uses a react-query hook, two pre-existing tests that rendered it without a `QueryClientProvider` were wrapped in one (`product-commerce-actions.import-entry.test.tsx`, `market-isolation.test.tsx`) — assertions unchanged. The real app always provides a query client at the root.

## Requirement 12 — founder preview acceptance procedure
On the Lovable **preview** (`id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app`), signed in as the founder, `/workspace?view=opportunities` (Products → My research), desktop and mobile:
1. Open **SharkNinja BlastBoss** → confirm the **Import Product Image** button is present, and **no** "Create publishable product image" generator (identity unresolved).
2. Open **e453 "kids nightlight projector"** → confirm **Import Product Image** is present, and **no** generator yet (no owned image → "A customer-owned or licensed product image is required").
3. On e453, **Import Product Image** → upload a genuine owned/licensed photo of the exact e453 product → tick the rights checkbox (commercial advertising + AI image generation) → Upload.
4. Confirm the **"Create publishable product image"** generator now appears on e453 (identity resolved + readiness AVAILABLE), with the three scenes.
5. (Separate spend approval) select a scene → generate → review → accept per the BE331 visual criteria. **Only when a real three-image pack is generated and visually accepted is CS.05 DONE.**

## Deployment readiness
BE337 (`96d0c34`) + BE338 (`6709e36`) together make the Import entry and the correctly-gated generator reachable on the founder's real Product Research path. Preview HEAD `6709e36` is a frontend-only change (6 files: `commerce-actions-api.ts`, `product-commerce-actions.tsx`, `product-explorer.tsx`, 3 tests), strictly additive and fail-closed-preserving, with the full suite green. **Ready for a controlled production deploy on separate founder approval** (same narrow `deploy_project` mechanism as BE334/BE336; would ship `6709e36` — which includes BE337 + BE338, since production is still `df1e2f6` = BE336 — after a pre-deploy diff confirming the delta). **Recommend the founder first confirm steps 1–4 in the signed-in preview, then authorise the production deploy**, so the next production release is founder-sighted before it ships. **Not deployed under this directive.**

## Strict limits — all honoured
Preview only; no production deployment; 0 paid Gemini/OpenAI; no AI generation (`generateCommercialImage` never called); no rights attestation on the founder's behalf; no customer download / subscriber release; no unrelated UI changes (generator renders in the same area; concrete actions + `filterVisibleActions` untouched); no GPD.07 activation; no BE326/BE330 relaxation (frontend gate strictly more restrictive; no backend change). **CS.05 remains IN PROGRESS** (the real three-image pack must still be generated from an uploaded authorised reference and visually accepted). GOLD 11/22 unchanged.

Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · CS.05 IN PROGRESS. GPD.09 + the remaining 18-December launch gates remain the higher priorities. Next BE id: **BE339**. Evidence: this report, master-doc Addendum 109, Build Evidence row **BE338**. Frontend: Lovable project `12db6c84`, preview commit `6709e36` (undeployed); production remains `df1e2f6` (BE336).

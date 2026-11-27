# BE336 — Controlled production deployment of the BE335 Import Product Image entry-point correction — DEPLOYED + VERIFIED

**Executed:** 2026-11-27 · **Authority:** founder "BE335 PRODUCTION DEPLOYMENT — FOUNDER AUTHORISATION: APPROVED — DEPLOY." **Verdict: DEPLOYED + VERIFIED.** The BE335 Product Research Import Product Image entry-point correction + its regression test are now live in production. **0 paid Gemini/OpenAI calls; no commercial-rights change; no subscriber release; no GPD.07; GOLD 11/22 unchanged; CS.05 remains IN PROGRESS.** Automated/artifact checks are distinguished from the founder's in-browser acceptance throughout.

---

## Deployment facts
| | |
|---|---|
| **Deployment ID** | `467568d5-bd8c-4678-a765-08f8dda7b0fc` |
| **Released commit** | `df1e2f699e61e287ddf29f7c93a866bcaf663c96` (BE335 preview HEAD) |
| **Previous production / rollback** | `fd2dddad308ec54dda5a70f26bdeb5679b5a496c` (BE334 deployment `acbfc777`) |
| **Approved commits deployed** | `a94fb28` (the Import button + `allowImageImport` prop) · `df1e2f6` (the real-component regression test) |
| **Live URL** | `https://www.strateloq.com/` (now serves `df1e2f6`) |
| **Timestamp** | deployed 2026-11-27; production flipped `fd2ddda → df1e2f6` confirmed on the 2nd poll |

## Pre-deployment verification (all passed; no stop-condition triggered)
1. **Production still serving BE334 `fd2ddda`** — immediately before deploy, `www.strateloq.com` served `data-commit-sha=fd2dddad…`.
2. **Preview HEAD still `df1e2f6`** — `get_project.latest_commit_sha=df1e2f699e…`, unchanged.
3. **Deployment delta = exactly the 3 approved BE335 files** — `fd2ddda → df1e2f6` = `ecommerce-workspace.tsx` (+1/-0), `product-commerce-actions.tsx` (+23/-0), `product-commerce-actions.import-entry.test.tsx` (new, +91/-0). **No unrelated preview work** (production was exactly one approved-set behind, so the full-HEAD deploy isolates precisely these 3 files — the same clean, isolated situation as BE334).
4. **Founder upload action restricted by authentication + ownership** — the Import button is only a frontend reveal; the upload is gated server-side: `product-image-import` edge `verify_jwt=true`; `fn_product_image_import_register` (SECURITY DEFINER) rejects `p_tenant IS NULL → unauthenticated` and `v_owner <> p_tenant → cross_tenant_rejected`.
5. **product-image-import retains server-side ownership/rights/identity checks** — registrar additionally enforces `p_rights_confirmed IS NOT TRUE → rights_confirmation_required`, mime ∈ {png,jpeg,webp}, ≤15 MB; identity validation (PAL) is enforced at the *generation* step (`commercial-image-generate` live at **v27**, `ezbr 950468…`, `verify_jwt=true`). No backend change in BE335/BE336.

## Deployment
Published preview HEAD `df1e2f6` to production via `deploy_project` (deployment `467568d5`). `deploy_project` runs the production build as it publishes, so a broken build would have failed the publish and left production unchanged; production then flipped to `df1e2f6` (confirmed by polling `www.strateloq.com` until `data-commit-sha=df1e2f6`), so the production build is green at `df1e2f6`. No GPD.07 activation, no paid provider calls, no credit purchases.

## Post-deployment verification — 9/9 acceptance checks
Legend: **AUTOMATED** = deterministic server/test proof on the deployed artifact; **FOUNDER SIGHTING** = the signed-in interactive runtime, which cannot be minted here (BE319/BE299/BE300 precedent), so the live in-browser confirmation remains the founder's.

| # | Acceptance criterion | Result |
|---|---|---|
| 1 | Import Product Image appears for the authorised founder on the relevant product detail | **PASS (AUTOMATED artifact + real-component test; FOUNDER SIGHTING final)** — the deployed build `df1e2f6` includes the standalone button (`product-commerce-actions.tsx`) with `allowImageImport={true}` on the detail mount (`ecommerce-workspace.tsx`); the real-component test renders the REAL `ProductCommerceActions` on the SharkNinja-shaped fixture (actions = Create Ad + Add to Store only, `NOT_ELIGIBLE`) and asserts the "Import Product Image" button renders anyway |
| 2 | The existing upload dialog opens | **PASS (AUTOMATED)** — the test clicks the button and the real `ImportDialog` opens |
| 3 | Rights confirmation starts unchecked | **PASS (AUTOMATED)** — checkbox `aria-checked="false"` + `data-state="unchecked"` on open |
| 4 | Commercial advertising + AI-reference permissions clearly explained | **PASS (AUTOMATED)** — the checkbox label contains both "commercial advertising" and "AI image generation" (BE332 copy, present in deployed `df1e2f6`) |
| 5 | The nightlight pilot product is accessible | **PASS (AUTOMATED, live backend)** — e453 `fn_product_identity_resolution`: `identity_state=IDENTITY_RESOLVED`, `supplier_link_allowed=true` → `concreteProductActionsAllowed=true` → the detail renders the full concrete actions + the Import button; generation currently `execution_state=NOT_ELIGIBLE`/`reference_eligible=false` (no owned image yet; 12 supplier-authorized + 28 research-only; `commercial_asset_readiness=CUSTOMER_ASSET_REQUIRED`), correctly fail-closed until the founder uploads an owned image |
| 6 | SharkNinja remains ineligible for Gemini generation while identity + authorised-reference requirements are unsatisfied | **PASS (AUTOMATED, live backend)** — SharkNinja `caa240db`: `identity_state=CONCEPT_ONLY`, `supplier_link_allowed=false`, `has_supplier_link=false`, `supplier_match.matched=false`; readiness `execution_state=NOT_ELIGIBLE`, `reference_eligible=false`, `reference_basis=NONE`, `commercial_asset_readiness=UNKNOWN`, `commercial_testability=NOT_CURRENTLY_LAUNCHABLE` → the generator gate (`AVAILABLE && reference_eligible===true`) is false → **generator hidden**; the unverified supplier photo is never an AI input |
| 7 | Subscriber and non-owner restrictions remain intact | **PASS (AUTOMATED)** — `fn_product_media_auth_selftest` 5/5 (OWNER allowed; CROSS_TENANT, FORGED_ID, UNAUTHENTICATED all denied; country isolation); resolver `CROSS_TENANT_REJECTED`; registrar `cross_tenant_rejected`; `fn_product_card_commerce_actions` returns `unauthenticated` without a JWT; edge `verify_jwt=true` + ownership + readiness re-check unchanged |
| 8 | Mobile and desktop layouts pass | **PASS (AUTOMATED artifact; FOUNDER SIGHTING final)** — the button sits inside the existing `flex flex-wrap items-center gap-2` row (no layout change); green production build at `df1e2f6`. Authenticated-workspace responsiveness = founder's browser sighting |
| 9 | Existing product research, frontend + security regressions remain green | **PASS (AUTOMATED)** — FE: Lovable commerce suite 12 files / 129 tests / 0 failures at the deployed commit `df1e2f6` (full suite 200 green). Backend security battery = **58/58 checks, 0 failures** across 6 suites: resolver (12/12), asset-use-eligibility (11/11), cross-supplier-identity (13/13), ad-creative-identity/PAL (8/8, RIGHTS_UNVERIFIED stays blocked), cs-media-end-to-end (9/9), product-media-auth (5/5). Resolver + edge v27 intact; e453 fail-closed; `filterVisibleActions` + generator gate untouched |

No synthetic data was written to persistent production (selftests roll back; `NO_SYNTHETIC_PERSISTED=0` across suites); **0 paid Gemini/OpenAI calls**; no three-image generation.

## Founder browser acceptance — still the final human sighting
A production session cannot be minted in this environment (BE319/BE299/BE300 precedent), so the founder should confirm in their own signed-in browser on `strateloq.com/workspace?view=opportunities`: (a) the **Import Product Image** button is now present on the SharkNinja product detail (and on e453); (b) it opens the upload dialog with the rights checkbox starting **unchecked** and the commercial-advertising + AI-reference wording; (c) SharkNinja still shows **no** "Create publishable product image" generator; and (d) after uploading one real owned/licensed image on e453 and attesting rights, the generator appears. The artifact-level verification above is complete.

## Rollback (prepared)
Redeploy `fd2ddda` (BE334 deployment `acbfc777`) via Lovable (revert the 2 BE335 commits on main and deploy, or use Lovable's deployment history). Forward-fix preferred — the change is a strictly-additive, fail-closed-preserving frontend reveal that disturbs no gate.

## Strictly-prohibited items — none performed
No paid Gemini/OpenAI; no AI generation; no rights attestation on behalf of the founder (the attestation remains the uploader's explicit, unchecked-by-default action); no subscriber downloads or Creative Studio release (generation remains founder-only in practice — it needs a founder-owned product with an owned image); no commercial-rights change; no product-rights/supplier/image promotion; no quarantined-asset restoration; no GPD.07 activation; no unrelated production changes (3-file delta only); **no alteration to historical GOLD 11/22**.

## Roadmap (reconciled)
- **Done:** the BE335 Product Research Import Product Image entry-point correction is **live in production** (BE336), on top of the BE334 F1/F2/rights-copy release.
- **CS.05: still IN PROGRESS / NOT DONE** — a real three-image pack (Clean Studio / Lifestyle / Product in Use) must be generated from an uploaded authorised reference and **visually accepted** by the founder; the paid pilot stays inactive until the founder supplies a genuine authorised reference and approves the spend.

Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · CS.05 IN PROGRESS. **GOLD 11/22 unchanged.** GPD.09 + the remaining 18-December launch gates remain the higher priorities. Next BE id: **BE337**. Evidence: this report, master-doc Addendum 107, Build Evidence row **BE336**. Frontend: Lovable project `12db6c84`, deployment `467568d5`, released commit `df1e2f6`.

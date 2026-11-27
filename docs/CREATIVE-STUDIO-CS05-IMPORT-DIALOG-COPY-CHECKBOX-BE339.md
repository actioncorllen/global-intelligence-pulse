# BE339 — BE338 founder preview findings: rights-checkbox initial-state confirmation + upload-description copy fix (preview only)

**Executed:** 2026-11-27 · **Authority:** founder "BE338 FOUNDER PREVIEW FINDINGS — the Import Product Images dialog opens in the real preview (validates BE337). Before production deployment, make two final checks: (1) rights checkbox initial state; (2) replace the misleading upload explanation. Preview only; no production deployment." **Both checks done in the Lovable PREVIEW (commit `1994dae`); NOT deployed (production remains BE336 `df1e2f6`); 0 paid Gemini/OpenAI; GOLD 11/22 unchanged; CS.05 remains IN PROGRESS.** The founder has visually confirmed the Import dialog opens on the real path — BE337 is validated.

---

## Check 1 — rights checkbox initial state: NO DEFECT (confirmed; no code change)
Source inspection of `ImportDialog` (`src/components/commerce/product-commerce-actions.tsx`): the dialog initialises `const [confirmed, setConfirmed] = React.useState(false)` (unchecked) and `const [file, setFile] = React.useState<File | null>(null)` (no file), and **resets both on close**:
```tsx
React.useEffect(() => {
  if (!open) { setFile(null); setConfirmed(false); setError(null); }
}, [open]);
```
So the checkbox is unchecked on first open **and** reset to unchecked on every close→reopen. The founder's screenshot showing it selected = a **manual** selection, not an automatic one. **No defect; no change to the checkbox or rights-attestation logic** (per the directive, backend rights attestation and permissions were not touched). A test now proves the reopen behaviour (below).

## Check 2 — upload explanation corrected (preview commit `1994dae`, one line)
The `ImportDialog` `DialogDescription` fallback (shown on the standalone Import path, when there is no contextMessage) was the misleading:
> "Only needed when Strateloq can't find an official image for this product."

Replaced with:
> "Upload an image you own or are authorised to use for commercial advertising and AI image generation."

Exact structure preserved: `{contextMessage ?? "<new text>"}`. Only that one string changed — the DialogTitle, the checkbox, the rights-attestation label, the file input and the submit handler are untouched. The new text does **not** imply that official supplier photographs automatically carry commercial or AI-input permissions; it places the obligation on the uploader ("you own or are authorised to use").

## Validation (real ExplorerDrawer integration tests; preview)
New test added to `src/components/business-discovery/product-explorer.import-entry.test.tsx` (real `ExplorerDrawer` + real `ProductCommerceActions`; `importProductImage` and `generateCommercialImage` are no-network `vi.fn`s asserted never called):
- Opening the Import dialog from the standalone **Import Product Image** button (no contextMessage) shows the **new** description and the **old** "Only needed when Strateloq can't find an official image" text is **absent**.
- On first open: the rights checkbox is `aria-checked="false"` and the **Upload image** submit button is **disabled** (no file selected by default).
- Reset-on-reopen: open → tick the checkbox (becomes `aria-checked="true"`) → **Cancel** (close) → **Import Product Image** again (reopen) → checkbox is `aria-checked="false"` again and submit is disabled again.

| Founder VALIDATE item | Result |
|---|---|
| Import button visible in the actual Explorer drawer | **PASS** (BE337 test, unchanged) |
| Dialog opens | **PASS** (founder-confirmed live + test) |
| Checkbox initially unchecked | **PASS** (`aria-checked="false"` on open) |
| Rights declaration explicitly covers commercial advertising + AI generation | **PASS** (checkbox label unchanged, asserted) |
| No file selected by default | **PASS** (Upload button disabled on open) |
| SharkNinja Gemini generation remains restricted | **PASS** (BE338 test: unresolved identity → generator hidden even when readiness AVAILABLE) |
| Existing BE338 identity + readiness gates intact | **PASS** (BE338 tests unchanged + green) |
| Mobile + desktop layouts and regressions pass | **PASS (artifact)** — only one text string changed, no layout change; **full relevant suites 159/159 across 19 files; build OK** |

**Results:** new test file 5/5; product-explorer + commerce + lib/commerce suites **159/159 across 19 files**; preview build OK. Preview commit `1994dae`; undeployed. Files changed (2): `product-commerce-actions.tsx` (1 line), `product-explorer.import-entry.test.tsx` (new test).

## Deployment readiness
BE337 (`96d0c34`) + BE338 (`6709e36`) + BE339 (`1994dae`) together deliver, on the founder's real Product Research path: the Import entry, the correctly identity+readiness-gated generator, the unchecked-by-default rights checkbox, and accurate upload copy. Preview HEAD `1994dae` is a frontend-only, strictly-additive, fail-closed-preserving change set with the full suite green. **Ready for a controlled production deploy on separate founder approval** (same narrow `deploy_project` mechanism as BE334/BE336; would ship `1994dae` — which includes BE337 + BE338 + BE339, since production is still `df1e2f6` = BE336 — after a pre-deploy diff confirming the delta). The founder has already visually confirmed the Import dialog on the preview; I recommend a final preview glance at the corrected description text + the e453 generator-after-upload step, then authorise the production deploy.

## Strict limits — all honoured
Preview only; no production deployment; 0 paid Gemini/OpenAI calls; no AI generation; no backend rights-attestation change; no automatic permission grant; no customer download release; no rights promotion; no unrelated changes (2-file preview delta: one copy string + one test); no GPD.07 activation. **CS.05 remains IN PROGRESS** (the real three-image pack must still be generated from an uploaded authorised reference and visually accepted). GOLD 11/22 unchanged.

Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · CS.05 IN PROGRESS. GPD.09 + the remaining 18-December launch gates remain the higher priorities. Next BE id: **BE340**. Evidence: this report, master-doc Addendum 110, Build Evidence row **BE339**. Frontend: Lovable project `12db6c84`, preview commit `1994dae` (undeployed); production remains `df1e2f6` (BE336).

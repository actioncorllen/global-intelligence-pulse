# BE334 — Controlled production deployment of the BE332/BE333 frontend (F1 + F2 + rights-attestation copy) — DEPLOYED + VERIFIED

**Executed:** 2026-11-27 · **Authority:** founder "BE332/BE333 CONTROLLED PRODUCTION FRONTEND DEPLOYMENT — APPROVED." Narrowly-scoped UI-only release of the verified F1 (generator visibility), F2 (accurate copy) and the BE332 rights-attestation wording. **Verdict: DEPLOYED + VERIFIED** (code/artifact level; the signed-in interactive runtime is the founder's browser sighting, per the accepted BE319/BE299/BE300 precedent). **GOLD 11/22 unchanged.**

---

## Deployment facts
| | |
|---|---|
| **Deployment ID** | `acbfc777-c4cc-4477-817a-dd3b724fff69` |
| **Released commit** | `fd2dddad308ec54dda5a70f26bdeb5679b5a496c` |
| **Previous production / rollback** | `0f27681582d439b3f8cdfc8519d8ca3e88720673` (BE319 deployment `a6097aab`) |
| **Approved commits deployed** | `bd7463a` (BE332 rights copy) · `4b49b049` (BE333 F1 + F2) · `fd2ddda` (BE333 F2 My Store) |
| **Live URL** | `https://www.strateloq.com/` (serves `fd2ddda`); `pulse-implementation.lovable.app` 301→www |
| **Timestamp** | deployed 2026-11-27; production serving `fd2ddda` confirmed on first poll |

## Pre-deployment (all passed)
1. **Production target = strateloq.com** — `www.strateloq.com` served `data-commit-sha=0f27681` (BE319's release) before deploy.
2. **Exact approved diff confirmed** — the production→HEAD delta `0f27681→fd2ddda` = **exactly 6 files**: `commercial-image-generator.tsx` (+2/-2), `product-commerce-actions.tsx` (+13/-7), `store-website-panel.tsx` (+1/-1), `commerce-actions-api.ts` (+1/-1), `commercial-image-generation.test.ts` (+1/-1), `store-website-api.test.ts` (+1/-1). These are precisely the three approved commits.
3. **No unrelated preview work** — the delta contains none of the 2026-11-26 commits (GPD.07 panel, internal `/dev` routes, social panel, Product-Research/Workspace redesign); those were already in production from BE319 and are **not** re-deployed. The Lovable deploy mechanism ships main HEAD, and because production was exactly one approved-set behind, the release is clean and isolated (no need to prepare a separate release).
4. **BE326 security migrations + BE330 edge v27 intact** — BE326 migrations ×4 present; `mig_379` applied; `fn_resolve_authorised_ai_reference` present; e453 `reference_eligible=false`; 9 quarantine flags (3 generated + 6 media); buckets private.
5. **Rollback captured** — previous production `0f27681` (deployment `a6097aab`); rollback = redeploy `0f27681` via Lovable (revert the 3 commits on main and deploy, or use Lovable's deployment history). Forward-fix preferred (the change is copy + a strictly-more-fail-closed gate).
6. **Founding-member registration unchanged** — the 6-file delta is entirely commerce/storefront generation components + two tests; no auth/onboarding/registration/sign-up file is touched.

## Deployment
Published main HEAD (`fd2ddda`) via `deploy_project` (deployment `acbfc777`). `deploy_project` runs the production build as it publishes, so a broken build would have failed the publish and left production unchanged; the publish succeeded, so the production build is green at `fd2ddda` (which includes all 6 approved files). No GPD.07 activation; no paid provider calls; no credit purchases.

## Post-deployment verification — 12/12
| # | Check | Result |
|---|---|---|
| 1 | Production serves the new frontend | **PASS** — `www.strateloq.com` → `data-commit-sha=fd2dddad…` (confirmed on first poll) |
| 2 | Product Research + My Store retain layouts/functionality | **PASS (artifact)** — green production build at `fd2ddda`; Lovable 95–97 tests pass; the 6-file diff is logic+copy only, no layout change. **Signed-in interactive runtime = founder's browser sighting** (BE319/BE299 precedent: a production session cannot be minted here) |
| 3 | Rights checkbox explicitly mentions commercial advertising + AI image generation | **PASS** — source-verified in deployed commit `bd7463a` (exact string "…including its use in commercial advertising and as a reference for AI image generation."); live in the authenticated workspace chunk (not reachable via the public bundle graph) — founder confirms in browser |
| 4 | Checkbox not auto-selected | **PASS** — `ImportDialog` initialises `confirmed=useState(false)`; the Upload button is `disabled={!file || !confirmed || busy}` |
| 5 | Upload action connected to product-image-import | **PASS** — `importProductImage` → `supabase.functions.invoke("product-image-import", …)` (unchanged) |
| 6 | Founder-owned eligible product displays the generator under correct readiness (safe fixture) | **PASS** — deterministic backend fixture (rolled back): founder + owned image → `fn_product_commercial_asset_readiness_owned` `execution_state=AVAILABLE` + `reference_eligible=true` → deployed F1 gate `AVAILABLE && reference_eligible===true` → generator visible |
| 7 | Products lacking eligible images do not expose generation | **PASS** — fixture: no image → `CUSTOMER_ASSET_REQUIRED` / `NOT_ELIGIBLE` → gate false |
| 8 | Uncleared CJ/marketplace references remain blocked | **PASS** — live e453 (40 supplier/marketplace images) → `reference_eligible=false`; resolver 0 authorised candidates |
| 9 | Revoked and expired rights remain blocked | **PASS** — fixture: supplier image + revoked `ai_input` evidence → `NOT_ELIGIBLE` (expired identical) |
| 10 | Subscribers/unauthorised cannot invoke founder-only generation | **PASS** — fixture: non-owner → `fn_product_commercial_asset_readiness_owned` `unauthorized`/`UNAVAILABLE`/exec null → gate false; edge `verify_jwt=true` + ownership + readiness re-check |
| 11 | Mobile + desktop presentation | **PASS (artifact)** — no layout change in the diff; green production build; deployed public landing renders (project screenshot). Authenticated-workspace responsiveness = founder's browser sighting |
| 12 | Existing frontend + backend security regressions | **PASS** — FE: Lovable 95–97 tests across 9 files pass at `fd2ddda` + green production build; backend post-deploy: resolver / asset_use_eligibility / ad_creative_identity (PAL) / cs_media_end_to_end / cross_supplier_identity / product_media_auth = **6/6 suites, 0 failures**; e453 fail-closed; quarantine 9 intact; resolver/edge v27 intact |

Deterministic fixtures used where a real owned image is unavailable; **no synthetic rights-attested asset was written to persistent production data** (all fixtures rolled back, 0 persisted); **0 paid Gemini/OpenAI calls**; no three-image generation.

## Defects fixed during deployment
None — the deployment was clean. The pre-deploy "no unrelated work" risk was resolved by confirming production was exactly `0f27681` (one approved-set behind), so the full-HEAD deploy isolated precisely the authorised changes.

## Founder browser acceptance — still necessary
Yes. The signed-in interactive runtime cannot be exercised here (no production session): the founder should, in their own browser, confirm (a) the rights checkbox wording + that it starts unticked; (b) Product Research + My Store render correctly on desktop and mobile; and (c) after uploading one real owned/licensed image, the "Create publishable product image" generator appears on that product. These are the final human sighting; the artifact-level verification above is complete.

## Strictly-prohibited items — none performed
No paid Gemini/OpenAI calls; no three-image generation; no subscriber downloads; no subscriber Creative Studio release (generation remains founder-only in practice — it needs a founder-owned product with an owned image, which only the founder has); no product-rights promotion; no quarantined-asset restoration (9 flags intact); no GPD.07 activation; no unrelated feature changes (6-file delta only); **no alteration to historical GOLD 11/22**.

## Roadmap (reconciled)
- **Done:** the BE332/BE333 frontend corrections (F1 generator visibility, F2 accurate copy, rights-attestation wording) are **live in production** (BE334).
- **CS.05: still IN PROGRESS / NOT DONE** — a real three-image pack (Clean Studio / Lifestyle / Product in Use) must be generated from an uploaded authorised reference and **visually accepted** by the founder; the paid pilot stays inactive until the founder supplies a genuine authorised reference and approves the spend.

Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · CS.05 IN PROGRESS. GPD.09 + the remaining 18-December launch gates remain the higher priorities. Evidence: this report, master-doc Addendum 105, Build Evidence row **BE334**. Frontend: Lovable project `12db6c84`, deployment `acbfc777`, released commit `fd2ddda`.

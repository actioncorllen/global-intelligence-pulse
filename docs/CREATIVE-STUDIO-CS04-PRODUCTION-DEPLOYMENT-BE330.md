# BE330 — CS.04 controlled production deployment: authorised-reference resolver + corrected Gemini edge — DEPLOYED + VERIFIED

**Executed:** 2026-11-27 · **Authority:** founder "BE329 CONTROLLED PRODUCTION DEPLOYMENT — APPROVED" (scope: apply `mig_379` + deploy the corrected `commercial-image-generate` edge; these two changes only). **Verdict: DEPLOYED + VERIFIED.** Strict limits honoured: 0 paid Gemini/OpenAI calls, no customer Creative Studio activation, no subscriber downloads, no quarantined-asset restoration, no GPD.07, no unrelated production changes, GOLD 11/22 unchanged.

---

## What was deployed (two changes, nothing else)
| # | Change | Production ID / version | Time (UTC) |
|---|---|---|---|
| 1 | `mig_379` — `fn_resolve_authorised_ai_reference` + `fn_resolve_authorised_ai_reference_selftest` | migration `20261127143234` | 14:32:34 |
| 2 | `commercial-image-generate` edge (resolver-based reference + fresh short-lived signing) | **version 27** (`ezbr_sha256 950468…`, was v26 `eb92d2f7…`) | ~14:34:40 |

`verify_jwt=true` preserved on the edge. No table, column, rights record, RLS policy, other function or setting was changed.

## Pre-deployment (completed)
- **Exact committed artifacts + target confirmed:** production project `nxaunmyihhjixxxljcqt`; `mig_379` carried the BE329 coalesce + selftest; the edge carried the resolver call, fresh-sign + fail-closed logic; the edge referenced `fn_resolve_storefront_assets` only in a comment (no call).
- **BE326 fail-closed protections active:** all four migrations (`20261127133201`/`133314`/`133352`/`133519`) present; e453 `reference_eligible=false` / `CUSTOMER_ASSET_REQUIRED`; buckets private.
- **Storage bucket/path + ownership validated:** resolver re-checks `commerce_products.user_id = p_tenant`; `signStorageRef` splits `pulse-product-imports/{tenant}/{product}/{obj}` → correct bucket/path.
- **No expired-URL / supplier fallback:** edge signs a fresh 10-min URL from the private object; on sign failure returns a retryable `REFERENCE_RESOLUTION_FAILED` and stops (no stale-URL fallback, no supplier substitution).
- **Prior version captured + rollback prepared:** v26 (`ezbr_sha256 eb92d2f7…`) saved to `docs/ROLLBACK-BE330-commercial-image-generate-prior-v26.ts`.
- **Pre-apply test correction (caught + fixed before applying):** the apply-time selftest inserted two rows sharing `content_hash` on one product, which `UNIQUE(product_id, content_hash)` would reject and the `EXCEPTION WHEN OTHERS` would silently swallow — skipping the rank assertions. Fixed to distinct `content_hash`/`image_url` per row with `CS04STQ%`-prefix cleanup, so all checks run.

## Deployment (in order, stop-on-error)
1. Applied `mig_379`. 2. Ran `fn_resolve_authorised_ai_reference_selftest()` → **12/12**. 3. Confirmed e453 (supplier-only) remains **NOT_ELIGIBLE** (resolver `NO_AUTHORISED_REFERENCE`; readiness `reference_eligible=false`). 4. Only then deployed the corrected edge (→ v27). No error occurred.

## Post-deployment verification — 10/10 PASS (deterministic; 0 paid calls)
| # | Check | Result |
|---|---|---|
| 1 | Resolver exists + passes its selftest | **PASS** — `fn_resolve_authorised_ai_reference_selftest` 12/12 |
| 2 | Customer-owned references prioritised | **PASS** — selftest `RANK1` customer-owned wins over supplier (`origin_basis=CUSTOMER_OWNED_UPLOAD`); strict rank order 1>2>3>4>5 |
| 3 | Research-only images excluded | **PASS** — selftest `MARKETPLACE_NEVER_REFERENCE`; e453 research/marketplace → 0 candidates; `fn_product_media_discovery_selftest` 7/7 |
| 4 | Uncleared CJ supplier images excluded | **PASS** — e453 resolver `NO_AUTHORISED_REFERENCE` (40 supplier/marketplace → 0); readiness `reference_eligible=false`; `fn_asset_use_eligibility_selftest` 11/11 (supplier bare fails closed) |
| 5 | Revoked + expired permissions fail closed | **PASS** — selftest `REVOKED_AI_EVIDENCE_EXCLUDED` + `EXPIRED_AI_EVIDENCE_EXCLUDED`; eligibility selftest expired/revoked |
| 6 | Private storage refs receive fresh short-lived signed URLs | **PASS** — selftest `RANK1` surfaces `storage_ref=pulse-product-imports/…`; deployed edge v27 signs a fresh 10-min URL (`signStorageRef`, `expiresIn:600`) |
| 7 | Signing failures stop generation without fallback | **PASS** — deployed edge: `signStorageRef`→""→`fail("REFERENCE_RESOLUTION_FAILED")`; no stale-URL fallback, no image substitution |
| 8 | Product Asset Lock enforced | **PASS** — `fn_ad_creative_identity_selftest` 8/8 (`all_pass`); edge returns `usable:true` only on `IDENTITY_VALIDATED` |
| 9 | Tenant/product/country isolation intact | **PASS** — resolver `CROSS_TENANT_REJECTED` + `PRODUCT_NOT_FOUND`; `fn_cross_supplier_identity_selftest` 13/13; no RLS change |
| 10 | Existing BE326 rights-safety regressions pass | **PASS** — aggregate failures **0** across resolve_authorised_ai_reference(12), asset_use_eligibility(11), product_media_discovery(7), cs_media_end_to_end(9), ad_creative_identity(8), cj_image_rights(8), product_media_auth(5), creative_production(6), media_runtime(10), cross_supplier_identity(13), product_image(10) = **99 checks, 0 failures** |

## Rollback (prepared, preserves BE326)
Redeploy v26 from `docs/ROLLBACK-BE330-commercial-image-generate-prior-v26.ts` (+ optionally DROP the new functions). Safe because the deployed BE326 readiness gate still blocks supplier-only generation, so rollback reopens no new rights exposure; v27 is strictly safer, so FORWARD-FIX is preferred.

## Overall verdict: **DEPLOYED + VERIFIED.**

## What changes for customers (nothing yet)
No customer Creative Studio activation; the generate UI is not released to subscribers; owned-image generation is now *possible* but inert because **0 authorised owned/licensed images exist** — every product still resolves `NO_AUTHORISED_REFERENCE` until an owned, rights-attested image is uploaded. Supplier/marketplace-only products remain blocked (fail-closed). No paid generation has occurred.

## Next: founder-only upload + 3-image pilot (PREPARED — do not run paid generation without separate founder approval)
1. **Choose the pilot product** (founder-owned) and the exact variant to feature.
2. **Upload one eligible image** via the `product-image-import` edge (founder-authenticated), body `{ product_id, mime: image/png|jpeg|webp, data_base64, rights_confirmed: true, market? }`. The registrar stores it as `CUSTOMER_OWNED` + `rights_confirmed` and the resolver selects it as rank-1.
3. **Verify (free):** resolver → `AUTHORISED_REFERENCE_AVAILABLE / rank 1 / CUSTOMER_OWNED_UPLOAD` with `storage_ref` starting `pulse-product-imports/`; readiness → `reference_eligible=true, execution_state=AVAILABLE`.
4. **On separate founder approval of the paid spend:** invoke `commercial-image-generate` three times (scenes `CLEAN_STUDIO`, `LIFESTYLE`, `PRODUCT_IN_USE`). Expected ≈ $0.12–0.13; hard ceiling ≈ $0.26 (code caps: 2 Gemini attempts/scene, 12/10-min/tenant); recommended founder cap $0.50.
5. **Acceptance:** each scene `READY_FOR_REVIEW usable:true` only when `IDENTITY_VALIDATED`; `commerce_generated_assets` shows `reference_provider=CUSTOMER_UPLOAD`, `provenance.reference.origin_basis=CUSTOMER_OWNED_UPLOAD`, no supplier image used; founder visual review of fidelity, variant consistency and marketing suitability. Output stays internal (no subscriber release).

## Controls
0 paid Gemini/OpenAI; 0 credits; only the two authorised changes deployed; no customer Creative Studio activation; no subscriber image/video downloads; no quarantined-asset restoration; no GPD.07; no unrelated production changes; PAL/ownership/RLS/tenant+country isolation + revocation/expiry preserved. **GOLD 11/22 unchanged.** Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE (backend lane deployed + verified; subscriber release + the paid pilot remain gated). Files: `supabase/migrations/mig_379_cs04_authorised_ai_reference_resolver.sql` (APPLIED `20261127143234`), `supabase/functions/commercial-image-generate/index.ts` (DEPLOYED v27), `docs/ROLLBACK-BE330-commercial-image-generate-prior-v26.ts`, this report, master-doc Addendum 101. Build Evidence row **BE330**.

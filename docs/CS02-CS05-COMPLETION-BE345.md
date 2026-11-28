# BE345 — Complete CS.02 (Exact-Product Media Discovery) + CS.05 (Real Product Image Generation)

**Executed:** 2026-11-28 · **Authority:** founder "COMPLETE CS.02 + CS.05 — finish these two existing roadmap units, reuse-only, end-to-end." **Backend/source-verification/deterministic/prepared work only (Lovable credits unavailable until 7 Dec 2026). NOTHING deployed (production remains `df1e2f6` = BE336); 0 paid AI/provider calls; no subscriber download; no rights promotion; no quarantine restoration; no GPD.07; GOLD 11/22 unchanged. GPD.09 + the 18-December launch gates remain the higher priority.**

**Outcome: CS.02 acceptance criterion MET + the remaining verification implemented and validated (deploy-gated for the real-dimension surfacing). CS.05 remains OPEN — honestly — because no eligible authorised exact-product reference image exists for any product, so a real three-image pack cannot be generated; implementation is complete and the exact missing input + paid-pilot budget are specified.** No mocked output, synthetic image, or founder rights-declaration was used as proof.

---

## 1. CS.02 — actual status + evidence
**Status: acceptance criterion PASS (verified live); verification completion implemented + validated; real-dimension surfacing deploy-gated (free, no paid).**

The CS.02 infrastructure is deployed and sound. Verified **live, read-only** (production DB, as the founder tenant):
- **`fn_product_media_discovery_selftest` (the documented criterion): 7/7 PASS** — UNAUTHENTICATED rejected, CROSS_TENANT_REJECTED, STARTS_FROM_IDENTITY_EXCLUDES_MARKETPLACE, NO_AMBIGUOUS_SUBSTITUTION, NO_MARKETPLACE_CANDIDATE, SEARCH_NOT_COMMERCIAL_ELIGIBILITY, EXACT_IDENTITY_MATCH.
- **e453 "kids nightlight projector"**: discovery returns **12 candidates**, all CJ_SUPPLIER, all verdict **EXACT_SUPPLIER_IDENTITY** (candidate_source_item_id = verified supplier id `2608250310481611400`); **28** marketplace/research (eBay) images **excluded** as creative candidates; **every candidate's `permitted_use` is all-false** (`ai_input: NO_WRITTEN_AI_INPUT_PERMISSION`, `commercial_advertising: NO_AUTHORISATION`, `customer_download: NEVER_FOR_THIRD_PARTY`, …).
- **SharkNinja BlastBoss**: **0 candidates** (no supplier identity; its single Kalodata image excluded) — a truthful **no-authorised-image** result.
- **Honest permission classification** (`fn_asset_use_eligibility`): supplier/marketplace images are discovery/identity candidates only, **never** upgraded to AI-input or commercial; image-analysis ≠ ai_input; fail-closed. Confirmed on real data.

**Gap found + completed:** the discovery reports each candidate's `resolution` from `provenance.width/height`, but stored supplier/marketplace assets carry none → it returned `UNKNOWN`. The founder's acceptance requires **real dimensions + URL accessibility**. This container's proxy **blocks supplier CDNs** (`cf.cjdropshipping.com` → 403), so real measurement must run from the edge network. Delivered as a **prepared, committed, locally-validated** artifact (commit `9a063d7`), **metadata-only / rights-safe**:
- `supabase/functions/product-media-verify/image-dimensions.ts` — pure JPEG/PNG/GIF/WEBP header parser (**6/6 Deno tests**; returns null, never a guess, on truncation).
- `.../index.ts` — owner-scoped Deno edge that ranged-GETs a product's own image URLs (free CDN fetch), measures real width/height + HTTP accessibility + content-type, and records them. Type-check clean.
- `supabase/migrations/mig_381_be345_product_image_metadata.sql` — `fn_record_product_image_metadata` (owner-scoped, **NULL-safe**, writes `provenance.width/height` + accessibility + `cache_state`; **never** changes `rights_state`/availability) + `fn_product_media_verification_status` (owner-scoped reader). **Validated on a throwaway Postgres 16: selftest 5/5** (missing-args rejected; non-owner rejected; records dimensions + accessibility; **rights_state unchanged proven**; unreachable handled honestly); owner-scoped read ok; cross-tenant read rejected. **NOT applied.**

**Per-tested-product evidence table:**
| Product | Candidates (exact identity) | Excluded (marketplace/research) | Source evidence | Match status | Permitted use | Dimensions | No-authorised-image |
|---|---|---|---|---|---|---|---|
| e453 kids nightlight projector | 12 (CJ supplier) | 28 (eBay) | CJ CDN URLs, supplier id 2608250310481611400 | EXACT_SUPPLIER_IDENTITY | research/identity-only; AI-input + commercial + download all DENIED | UNKNOWN until the verify edge runs (free, deploy-gated) | AI-authorised: **none** |
| SharkNinja BlastBoss | 0 | 1 (Kalodata) | — | no supplier identity | — | — | **truthful no-image** |

**CS.02 verdict:** the documented criterion passes, real discovery + identity + honest permission classification are proven on real products, and the missing dimension/URL-accessibility verification is implemented + validated. **Recommend CS.02 DONE on the criterion**, with the real-dimension evidence populating in-product after one controlled deploy of `mig_381` + `product-media-verify` and one verify run per product (free CDN fetches; no paid provider call). Marked **DONE (criterion) — dimension surfacing deploy-gated** rather than unconditionally closed, since the prose acceptance asks the live product to *show* real dimensions.

## 2. CS.05 — actual status + evidence
**Status: OPEN (honestly). Implementation complete; blocked solely on a genuine authorised exact-product reference image + spend approval (+ Lovable credits for the final preview-connection and visual acceptance).**

Authoritatively confirmed **live** that **no eligible authorised exact-product reference exists for any product**:
- `fn_resolve_authorised_ai_reference(e453)` → **NO_AUTHORISED_REFERENCE**.
- `fn_product_commercial_asset_readiness(e453).ai_generation` → `execution_state: NOT_ELIGIBLE`, `reference_eligible: false`, `reference_basis: NONE`, `provider_connected: true`.
- A scan across **all** products for any CUSTOMER_OWNED / FIRST_PARTY_OWNED / LICENSED / AI-reference / CUSTOMER_UPLOAD image → **none** (`customer_upload_count = 0`).

Therefore a **real three-image pack cannot be generated** — there is no rights-cleared pixel to seed Exact/Hybrid from. Per the acceptance, CS.05 is **left OPEN**; no synthetic image or founder rights-declaration was fabricated.

**Implementation that IS complete and reused (BE341–BE344):**
- Three distinct modes (Exact Product / Original AI Concept / Hybrid Verified), kept visibly separate (BE341/BE344).
- Exact + Hybrid gated on authoritative identity (`supplier_link_allowed`) **and** a genuinely authorised reference + readiness AVAILABLE (BE338/BE341).
- The three image types CLEAN_STUDIO / LIFESTYLE / PRODUCT_IN_USE (deployed `commercial-image-generate` scenes).
- Product Visual Identity Pack + stable identity version across assets (BE340/BE341); Product Asset Lock output identity validation (BE326/BE330); private storage + provenance (identity version, model, rights state) (BE326).
- Uncleared supplier/marketplace images are prevented as generation inputs (resolver + BE324/BE326 fail-closed; proven again live above).
- The text-only Original AI Concept path for no-reference products, labelled "AI CONCEPT — NOT PRODUCT VERIFIED" and ineligible for verified exact-product commercial use (BE341–343).
- The consistency review component (BE343 P2) is built and connected to the Studio; it displays per-output criteria once real outputs exist.
- **Gemini model/API compatibility confirmed (BE344):** `gemini-2.5-flash-image` is GA and live until an earliest shutdown of **2027-03-15**; the deployed generation path works on the current model today (the Interactions-API migration is only needed before 2027). So a paid pilot is technically executable now on the current path — once a reference exists and spend is approved.

**The exact missing input (founder action):** a genuine **owned or licensed photograph of the exact product**, uploaded via Product Research → open product → **Import Product Image** → choose file → tick the rights checkbox (commercial advertising + AI image generation) → readiness flips to AVAILABLE → Creative Studio → **Exact Product** → generate the three scenes. Alternatively, written per-image AI-input permission for a specific supplier image. No such input exists for e453, SharkNinja, or any product.

**CS.05 remaining work once a reference + approval exist:** connect the consistency review to the real generated previews (small Lovable wiring, needs credits), generate the 3-image pack (paid), and obtain founder visual acceptance. Only then is CS.05 DONE.

## 3. Exact components reused
`fn_product_media_discovery`, `fn_asset_use_eligibility`, `fn_resolve_authorised_ai_reference`, `fn_product_commercial_asset_readiness(_owned)`, `fn_product_supplier_identity`, `product_image_assets` (+ `source_url_expires_at`/`cache_state`/`provenance`), `fn_product_image_import_register`; the deployed `commercial-image-generate` edge (BE326/BE330) + Product Asset Lock; the BE340 Product Visual Identity Pack; the BE341 unified Creative Studio UI + modes; the BE343 consistency review; the BE344 model-id parameterization. No new architecture; no rebuild.

## 4. Actual changes made
Additive, prepared, not deployed (commit `9a063d7`): `product-media-verify` edge + pure dimension parser + tests; `mig_381` (`fn_record_product_image_metadata` + `fn_product_media_verification_status` + rolled-back selftest). No change to any deployed function or rights gate; no CS.05 code change needed (implementation already complete).

## 5. Tests + failures fixed
- Image-dimension parser: **6/6** Deno (PNG/JPEG incl. APP0+SOF2/GIF/WEBP; truncated→null). Edge type-check clean.
- `mig_381`: **selftest 5/5** on throwaway Postgres 16; owner-scoped reader ok; cross-tenant read rejected.
- **Failures fixed during validation:** (a) a real NULL-safety bug — unreachable URL (`http_status` NULL) made `url_accessible` come back `null` not `false`; fixed with `coalesce(... , false)`. (b) a test-expectation bug — a non-owning tenant correctly gets `asset_not_found` (the `tenant_id` filter is non-leaking); assertion updated to accept either safe rejection.
- CS.02 live criterion: **7/7** (read-only, production). CS.05 generation-readiness: confirmed NOT_ELIGIBLE/no-reference live.

## 6. Products + markets verified
e453 "kids nightlight projector" (GB) — 12 exact-identity CJ candidates, 28 excluded, no authorised reference. SharkNinja BlastBoss (US) — 0 candidates, truthful no-image. System-wide scan — zero authorised/owned/licensed/upload images.

## 7. Real authorised image candidates (if any)
**None.** No CUSTOMER_OWNED / FIRST_PARTY_OWNED / licensed / AI-reference / customer-upload image exists for any product. All supplier/marketplace candidates are research/identity-only (AI-input + commercial DENIED). This is the correct, fail-closed state — not a defect.

## 8. Real-image pilot readiness + budget
Blocked only by the missing authorised reference + spend approval. When a reference exists:
- **Model:** `gemini-2.5-flash-image` (deployed, live). **Price:** **$0.039/image** (Standard, ≤1024×1024). (Replacement `gemini-3.1-flash-lite-image` ≈ $0.0336/image if/when migrated — not required before 2027.)
- **Estimated total (3 scenes):** 3 × $0.039 = **~$0.12**. Worst case with the edge's one IMAGE_OTHER retry/scene (max 2 attempts/scene) = 6 × $0.039 = **~$0.23**, plus a small Product Asset Lock validation call per scene.
- **Recommended hard cap: $0.30** (covers 3 scenes × 2 attempts + validation). Existing rate limit 12 generations / 600s / tenant.
- **Separate founder approval required before any spend.** No paid call made.

## 9. Remaining founder-dependent permissions
- **Authorised exact-product reference** (founder uploads a genuine owned/licensed photo via Import Product Image + rights checkbox, or grants written per-image AI-input permission) — the sole hard blocker for a real CS.05 pack.
- **Paid-generation spend approval** (hard cap $0.30 for the 3-image pilot).
- **Lovable credits** (expected 7 Dec) — to connect the consistency review to the real previews and for founder visual acceptance in the preview.
- **Controlled deploy approval** — to apply `mig_381` + deploy `product-media-verify` (CS.02 real-dimension surfacing) and, separately, the accumulated Creative Studio frontend/backend from BE337–BE344.

## 10. Updated roadmap + next BE evidence
CS.01 DONE · **CS.02 — acceptance criterion PASS (7/7), verification completion implemented + validated; DONE on criterion, real-dimension surfacing deploy-gated** · CS.03 DONE · CS.04 DONE · **CS.05 OPEN** (implementation complete; blocked on an authorised reference + spend + credits; real 3-image pack + founder visual acceptance outstanding) · CS.06–CS.08 OPEN. GOLD 11/22 unchanged. GPD.09 + 18-December launch gates remain the higher priority. Evidence: this report, master-doc Addendum 116, Build Evidence row **BE345**, repo commit `9a063d7`. Next BE id: **BE346**.

## Strict controls — all honoured
Backend/source-verification/deterministic/prepared work only; no production deployment; no production migration applied; 0 paid AI/provider calls; no subscriber download; no rights promotion; no quarantine restoration; no GPD.07; GOLD 11/22 unchanged. **CS.05 left OPEN — not claimed complete.** No mocked/synthetic image and no founder rights-declaration used as proof.

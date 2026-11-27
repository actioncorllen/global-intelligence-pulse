# BE328 — CS.04 controlled-pilot readiness (authorised-reference resolver + corrected Gemini edge)

**Executed:** 2026-11-27 · **Authority:** founder "CS.04 CONTROLLED PILOT READINESS". **No code change this task** — verification + a bounded release package only. No deployment, no migration apply, no paid generation, no customer release.

## VERDICT: **GO (conditional)** — pilot-ready; no engineering blocker.
Every implementation and infrastructure element is verified ready. The pilot cannot *run* until two **founder-controlled** preconditions are met, both anticipated by the directive and neither a code defect:
1. **Founder deployment approval** for the bounded apply (`mig_379`) + edge redeploy, and separate approval for the single paid 3-image generation.
2. **One eligible reference image** provided by the founder via the verified upload + rights-attestation path — because **0 owned/licensed images exist anywhere today** (`pulse-product-imports` is empty; there is nothing uncleared to misuse, and nothing eligible to generate from yet).

No product may be generated from an existing CJ/marketplace photograph: the resolver provably refuses them (verified below).

---

## TASK 1 — implementation verified against the deployed BE326 fail-closed gates

Reviewed `supabase/migrations/mig_379_cs04_authorised_ai_reference_resolver.sql` and `supabase/functions/commercial-image-generate/index.ts` against the **currently deployed** `fn_product_commercial_asset_readiness`, `fn_asset_use_eligibility`, `fn_media_image_execution_context`, PAL and the storage/provenance functions.

| # | requirement | verification | result |
|---|---|---|---|
| 1 | Correct product **and variant** identity | Resolver is scoped to a single `product_id`; it never crosses products. Variant fidelity is held by (a) the reference being the product's own authorised image and (b) the mandatory Product Asset Lock validating the generated output against **that exact reference** before it is usable. The founder chooses the variant by which image they upload. | **PASS** |
| 2 | Tenant ownership + permissions | Edge resolves `userId` from the JWT, re-checks `commerce_products.user_id = userId`; resolver independently re-checks `user_id = p_tenant` (defence in depth) → `CROSS_TENANT_REJECTED` otherwise. Onboarding gate (`fn_edge_onboarding_allowed`, fail-closed) unchanged. | **PASS** |
| 3 | Customer-owned + explicitly-licensed selection | Resolver ranks 1 (`CUSTOMER_OWNED` upload, `rights_confirmed=true`), 2 (`FIRST_PARTY_OWNED`), 3 (`EXPLICITLY_LICENSED`/`LICENSED`/`OWNED`). Synthetic proof: those scenarios return ranks 1/2/3; an **unconfirmed** customer-owned image returns null (excluded). | **PASS** |
| 4 | Per-image AI-use rights | Rank 5 requires a `SUPPLIER_PROVIDED` image whose **exact** supplier item has an unrevoked, unexpired `permission_scope.ai_input` grant — byte-identical to the deployed BE326 `v_has_ai_evidence` predicate. | **PASS** |
| 5 | Expiry + revocation enforcement | Rank-5 predicate excludes `revoked_at IS NOT NULL` and `expires_at <= now()`. Live check: 0 supplier images currently carry live AI-input evidence. | **PASS** |
| 6 | Private-storage signed-URL handling | A `CUSTOMER_OWNED` upload is stored with `image_url` = a durable signed URL to the **private** `pulse-product-imports` object (the import edge mints it precisely for pipeline fetch) and the `storage_ref` **column** NULL. The edge selects the fetch URL as: sign the `storage_ref` column if set → else the https `image_url` → else the https `source_url`. For an owned upload it uses the durable signed `image_url`. **Confirmed compatible with the real upload storage format.** All three buckets are private. | **PASS** |
| 7 | Product Asset Lock validation | Edge unchanged on PAL: identity validator (`gemini-2.5-flash`, n8n `HjjGApAXKpWXPh4q`) runs on every candidate; `fn_register_generated_commercial_asset` sets `IDENTITY_VALIDATED`/`REJECT_GENERATED_ASSET`; the edge returns `usable:true` only on `IDENTITY_VALIDATED`, else `IDENTITY_VALIDATION_FAILED usable:false`. PAL selftest 8/8 (BE326). | **PASS** |
| 8 | No supplier / marketplace substitution | The edge no longer calls `fn_resolve_storefront_assets` at all. Resolver returns a bare supplier/marketplace/research/rights-unknown image with **null rank → excluded**. Live proof: e453 (40 real supplier/marketplace images) → **0 authorised candidates** → `NO_AUTHORISED_REFERENCE`. | **PASS** |
| 9 | No bypass via retry / queued jobs / direct invocation | **Retry:** only an `IMAGE_OTHER` render refusal retries, once, re-using the *same* server-resolved authorised reference (hard cap 2 attempts/action) — no new reference, no gate skip. **Queued jobs:** the Gemini path is synchronous and re-evaluates the readiness gate **and** the resolver on every call (no cached authorisation); the queued `media_image_jobs` path is the separate OpenAI lane, already fail-closed (`fn_media_image_execution_context`, BE324), untouched here. **Direct invocation:** `verify_jwt=true`; the browser never supplies a reference; ownership + readiness + resolver all run server-side. | **PASS** |

**Authorisation is never inferred from a filename or unverified declaration:** the upload registrar `fn_product_image_import_register` **rejects** any upload without `p_rights_confirmed=true` (`rights_confirmation_required`), records the explicit rights statement + timestamp, validates mime + size, and re-checks product ownership. Rank 1 additionally requires `provenance.rights_confirmed='true'`.

**Compatibility:** `mig_379` is purely additive (one new function + its selftest); it alters no existing function, table, column, rights record or RLS policy. The edge's removed calls (`fn_product_supplier_identity`, `fn_resolve_storefront_assets`) remain in use by the unchanged readiness gate, so no other caller is affected. `fn_register_generated_commercial_asset` accepts the enriched `p_reference` cleanly — `asset_id` now populates `reference_asset_id`, and the full object (incl. `origin_basis`) is stored in `provenance.reference`.

**One non-blocking observation:** the resolver does not filter by `p_market` (reference selection is product-identity-based; PAL is the identity guard). With a single owned upload this is immaterial; a future hardening could prefer the requested market when multiple owned images exist. Not a pilot blocker.

## TASK 2 — generation readiness

| element | status |
|---|---|
| Gemini provider | **Connected** — `fn_commercial_image_provider_status().connected = true`; model `gemini-2.5-flash-image`; executor n8n `OYjIUMd0GS7OanbY`; identity validator n8n `HjjGApAXKpWXPh4q` (`gemini-2.5-flash`); infra n8n. |
| Scene templates | The three required categories are the edge's three existing allowlisted scenes, unchanged: **CLEAN_STUDIO** (high-quality product photo), **LIFESTYLE** (premium lifestyle photo), **PRODUCT_IN_USE** (advertising-ready promotional creative). Same reference + product-preservation prompt + PAL for all three. |
| Output storage | Private bucket `pulse-generated-media` (`public=false`); review-only short-lived signed URL; never a download grant. |
| Provenance | `fn_register_generated_commercial_asset` records reference (url/provider/rights_state/origin_basis/asset_id), generation (provider/model/workflow/job/attempts), identity verdict, PAL note; no auto-publish. |
| Cost caps (in code) | `MAX_ATTEMPTS=2` Gemini calls per action (per scene); `RATE_MAX=12` generated assets / 10-min window / tenant. |
| Actual API pricing | **Gemini 2.5 Flash Image ≈ $0.039/image** (1,290 output tokens @ $30 / 1M image-output tokens). PAL validation (`gemini-2.5-flash`) ≈ $0.001–0.005/image. |

**Fidelity / variant / marketing suitability** are enforced structurally (exact reference + PAL identity lock + text/logo/face-free prompt) and then **assessed by founder visual review** of the three outputs in the pilot (acceptance check 9 below) — the engine guarantees identity preservation and rejects materially different output; commercial-suitability judgement stays with the founder.

## TASK 3 — pilot input

**No genuinely owned/licensed reference exists today** (verified live): 0 `CUSTOMER_OWNED`+rights_confirmed / `FIRST_PARTY_OWNED` / `EXPLICITLY_LICENSED`/`LICENSED`/`OWNED` / `ai_reference_only` images across all 262 founder products (and all tenants); `pulse-product-imports` holds 0 objects; 0 supplier images carry live AI-input evidence. The resolver therefore correctly returns `NO_AUTHORISED_REFERENCE` for every product, e453 included.

**Verified upload + rights-attestation path (ready, no change needed):** the deployed `product-image-import` edge (`verify_jwt=true`) →
1. Founder (signed in, owning the pilot product) POSTs `{ product_id, mime (png/jpeg/webp), data_base64, rights_confirmed:true, market? }`.
2. Edge validates the explicit `rights_confirmed` flag (rejects without it), mime and size (≤15 MB), uploads bytes to the private `pulse-product-imports` bucket, mints a durable signed URL.
3. `fn_product_image_import_register` re-checks product ownership + rights confirmation and registers a `CUSTOMER_OWNED` / `CUSTOMER_UPLOAD` image with `provenance.rights_confirmed=true` + the stored rights statement.
4. The resolver then selects it as a rank-1 `CUSTOMER_OWNED_UPLOAD` reference.

The founder must supply **one** image of the exact pilot product/variant for which they own or hold permission. (A first-party or explicitly-licensed image also qualifies, at ranks 2–3.)

## TASK 4 — release readiness

**Bounded deployment plan (nothing runs without the stated approval):**
1. Pre: confirm `mig_379` content matches BE327; confirm resolver absent in prod (verified: `mig_379_applied=false`).
2. Apply `mig_379` (additive: resolver + selftest).
3. Run `fn_resolve_authorised_ai_reference_selftest()` → expect all green.
4. Compat check: e453 readiness still `reference_eligible=false`; resolver on e453 → `NO_AUTHORISED_REFERENCE`.
5. Deploy the corrected `commercial-image-generate` edge (→ v27). `verify_jwt=true` preserved.
6. Founder uploads **one** eligible image via `product-image-import` (`rights_confirmed=true`).
7. Verify: resolver on the pilot product → `AUTHORISED_REFERENCE_AVAILABLE / rank 1 / CUSTOMER_OWNED_UPLOAD`; readiness → `reference_eligible=true, execution_state=AVAILABLE`.
8. **(separate paid approval)** Run the 3-scene pilot for the pilot product only.
9. Post-pilot acceptance checks (below).

**Safe compatibility checks:** additive migration; no existing object changed; removed edge calls still serve the unchanged readiness gate; enriched `p_reference` accepted; owned-upload `image_url` is directly fetchable; `verify_jwt` preserved.

**Full regression suite (post-apply; expect 0 failures):** `fn_resolve_authorised_ai_reference_selftest` (new), `fn_asset_use_eligibility_selftest`, `fn_product_media_discovery_selftest`, `fn_cs_media_end_to_end_selftest`, `fn_ad_creative_identity_selftest` (PAL), plus the BE326 aggregate (`cj_image_rights`, `product_media_auth`, `creative_production`, `media_runtime`, `cross_supplier_identity`, `product_image`).

**Rollback that preserves BE326 protections:** redeploy the previous edge (v26, captured) and optionally `DROP FUNCTION fn_resolve_authorised_ai_reference[_selftest]`. This returns to the pre-BE327 state, in which the **deployed BE326 readiness gate still blocks supplier-only generation** (`reference_eligible=false`) — so rollback reopens **no** new rights exposure (the new resolver edge is strictly safer than the old supplier-storefront edge; the old edge's owned+supplier substitution path is vacuous, 0 such products). **Forward-fix is preferred over rollback**; rollback is only for a functional regression in the edge itself, never to restore an unauthorised path.

**Exact expected pilot cost + hard spending limit:**
- Expected (3 images, no retries): **≈ $0.12** (3 × $0.039) + **≈ $0.01** for 3 PAL validations → **≈ $0.12–0.13**.
- Code-enforced hard ceiling: ≤ 2 Gemini calls/scene × 3 scenes = ≤ 6 image generations ≈ **$0.234**, + ≤ 6 validations ≈ $0.02 → **absolute ceiling ≈ $0.26** per pilot (plus the `RATE_MAX=12`/10-min tenant cap). **Recommended explicit founder cap: $0.50** for the single pilot (comfortably above the ceiling).

**Founder-only access controls:** generation requires a valid JWT + onboarding + product ownership + an eligible owned image. The pilot is founder-only because (a) the pilot product is founder-owned, (b) only the founder uploads the one eligible image, (c) every other tenant/product resolves `NO_AUTHORISED_REFERENCE` (0 owned images elsewhere), and (d) the Creative Studio generate UI is **not released to subscribers**. Run the pilot from a founder-authenticated session only; do not enable the subscriber Creative Studio surface.

**Post-deployment / acceptance checks:**
1. Resolver selftest green.
2. e453 (supplier-only) → resolver `NO_AUTHORISED_REFERENCE`; readiness `reference_eligible=false` (fail-closed unchanged).
3. Pilot product (with owned image) → resolver `AUTHORISED_REFERENCE_AVAILABLE / rank 1`; readiness `reference_eligible=true`.
4. Each scene → `READY_FOR_REVIEW usable:true` only when `IDENTITY_VALIDATED`; otherwise `IDENTITY_VALIDATION_FAILED usable:false`.
5. `commerce_generated_assets`: `reference_asset_id` = the owned asset id; `reference_rights_state=CUSTOMER_OWNED`; `reference_provider=CUSTOMER_UPLOAD`; `provenance.reference.origin_basis=CUSTOMER_OWNED_UPLOAD`.
6. No supplier/marketplace image used (reference provider is never a CJ/marketplace source).
7. Cost reconcile ≤ ceiling.
8. Regression suite 0 failures.
9. Founder visual review of the 3 outputs: exact-product fidelity, realistic features, variant consistency, commercial marketing suitability.

## Controls
0 paid Gemini/OpenAI calls; 0 credits; no production migration applied; no edge deployed; no subscriber Creative Studio release; no quarantined-asset restoration; no commercial-rights promotion; no historical-GOLD change; no GPD.07; RLS/PAL/tenant+country isolation + revocation/expiry preserved. GPD.09 (OPEN, external licensing) + the remaining 18-Dec launch-critical work remain the higher priority. **GOLD 11/22 unchanged.** Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 PARTIAL (implementation + pilot-readiness verified; apply/deploy/pilot pending founder approval + one uploaded reference image). Evidence: this report, master-doc Addendum 99, Build Evidence row **BE328**.

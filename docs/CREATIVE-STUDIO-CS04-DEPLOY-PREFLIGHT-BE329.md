# BE329 — CS.04 final deployment preflight: fresh short-lived signed-reference correction + bounded plan

**Executed:** 2026-11-27 · **Authority:** founder "BE328 NEXT EXECUTION — final deployment preflight". Minimal compatibility correction to the committed-but-undeployed `mig_379` + `commercial-image-generate` edge, verified deterministically. **No production deployment; no paid Gemini calls; no public/subscriber release; no quarantine restoration; no rights promotion; no GOLD change.**

## VERDICT: **GO** — the customer-upload reference path is now robust; pilot-ready under separate founder deployment approval.
The one real weakness in the owned-upload path (reliance on a stored long-lived signed URL) is corrected: the edge now signs a **fresh short-lived URL from the authoritative private storage object at execution time**. All BE326 fail-closed rights controls, ownership checks and Product Asset Lock are preserved. (The pilot still needs the two founder inputs from BE328: deployment approval + one uploaded, rights-attested reference image.)

---

## The five preflight checks

**1. Is `image_url` a signed URL with a fixed expiration? — YES.** The deployed `product-image-import` edge mints the stored `image_url` with `expiresIn: SIGNED_URL_TTL = 315360000` s (~10 years) against the private `pulse-product-imports` object. It is a fixed-expiry signed URL (and is additionally invalidated if the storage signing secret rotates or the object is moved).

**2. Can the Gemini executor reliably fetch the image after that expiration? — NO.** Once the stored URL's fixed expiry passes (or the secret rotates / object relocates) it returns 403 and the executor cannot fetch it. A stored long-lived signed URL is therefore **not** a robust canonical reference.

**3. Prefer an authoritative private object + a freshly generated short-lived URL at execution. — DONE (corrected).**
- **Resolver (`mig_379`):** now returns `storage_ref = coalesce(product_image_assets.storage_ref, provenance->>'storage_ref')`. For a customer upload, `fn_product_image_import_register` leaves the `storage_ref` **column** NULL but records the private object ref in `provenance.storage_ref` (and `source_url`) as `pulse-product-imports/{tenant}/{product}/{obj}.ext`; the coalesce surfaces it reliably. First-party/licensed assets stored with the column keep using it.
- **Edge:** when `storage_ref` is present it **always signs a fresh 10-minute URL** (`signStorageRef`, `expiresIn:600`) at execution time, and uses the stored `image_url`/`source_url` only when no private object exists. The stored long-lived `image_url` is never used as the generative source when a private object reference is available.
- **Verified deterministically (read-only):** customer-upload shape → `storage_ref=pulse-product-imports/T/P/o.png`; split → bucket `pulse-product-imports`, path `T/P/o.png` (exactly what `signStorageRef` sends to `/storage/v1/object/sign/{bucket}/{path}`); first-party-with-column → uses the column; supplier-without-store → null (falls through, and bare supplier is excluded by rank anyway).

**4. Preserve Product Asset Lock, ownership checks and BE326 fail-closed controls. — PRESERVED (unchanged).** The correction touches only the reference **URL minting**, not the eligibility logic: resolver tenant-ownership re-check, the deployed BE326 readiness gate (`reference_eligible`), the candidate ranking, and the mandatory PAL identity validation (`IDENTITY_VALIDATED` before `usable:true`) are all unchanged. Regression: e453 still yields **0 authorised candidates** of 40 (fail-closed intact).

**5. The source image is never replaced with an unauthorised supplier image when resolution fails. — VERIFIED.** The resolver never returns a bare supplier/marketplace/research image (only an authorised owned/licensed/AI-permitted asset, or a rank-5 supplier image that carries explicit per-image `ai_input` evidence). If fresh signing fails, the edge returns a **retryable technical error** (`REFERENCE_RESOLUTION_FAILED`) and stops — it does **not** fall back to the stale URL and does **not** substitute any other image. There is structurally no supplier image in play to substitute.

## Minimal correction + tests (committed, UNAPPLIED / NOT DEPLOYED)
- `mig_379`: one-line resolver change (`storage_ref` coalesce) + a clarifying note; selftest `RANK1` rewritten to mirror the real upload shape (stored signed `image_url`, `provenance.storage_ref` set, `storage_ref` column null) and now asserts the resolver surfaces the private object ref (`storage_ref LIKE 'pulse-product-imports/%'`). No change to ranking, exclusions, tenant isolation or the other selftest checks.
- `commercial-image-generate/index.ts`: reference block now signs a fresh short-lived URL for a private object and fails closed on sign failure (no stale-URL fallback, no substitution); header note added.
- Verification (no apply/deploy/paid): coalesce + bucket/path split proven on synthetic shapes; e453 real data unchanged at 0/40. The resolver selftest (rank 1–5 + exclusions + the new private-ref assertion + revoked/expired + tenant + no-synthetic-persist) runs at apply time.

## Exact bounded deployment plan (for separate founder approval — not executed here)
1. **Pre:** confirm `mig_379` + edge content match BE327/BE329; confirm resolver absent in prod (`mig_379_applied=false`).
2. **Apply `mig_379`** (additive: resolver + selftest).
3. **Run `fn_resolve_authorised_ai_reference_selftest()`** → expect all green (incl. `RANK1_CUSTOMER_OWNED_WINS_AND_SURFACES_PRIVATE_REF`).
4. **Compat check:** e453 readiness still `reference_eligible=false`; resolver on e453 → `NO_AUTHORISED_REFERENCE`.
5. **Deploy the corrected `commercial-image-generate` edge** (→ v27). `verify_jwt=true` preserved.
6. **Founder uploads one** eligible owned/licensed image via `product-image-import` (`rights_confirmed=true`) → `CUSTOMER_OWNED` asset.
7. **Verify:** resolver on the pilot product → `AUTHORISED_REFERENCE_AVAILABLE / rank 1 / CUSTOMER_OWNED_UPLOAD` with `storage_ref` starting `pulse-product-imports/`; readiness → `reference_eligible=true, execution_state=AVAILABLE`.
8. **(separate paid approval)** Run the 3-scene pilot (CLEAN_STUDIO / LIFESTYLE / PRODUCT_IN_USE) for the pilot product only. Expected ≈ $0.12–0.13; hard ceiling ≈ $0.26 (code caps: 2 Gemini attempts/scene, 12/10-min/tenant); recommended founder cap $0.50.
9. **Acceptance:** per scene `READY_FOR_REVIEW usable:true` only when `IDENTITY_VALIDATED`; `commerce_generated_assets` row shows `reference_asset_id`=owned asset, `reference_provider=CUSTOMER_UPLOAD`, `provenance.reference.origin_basis=CUSTOMER_OWNED_UPLOAD`; no supplier image used; regression suite 0 failures; founder visual review (fidelity, variant consistency, marketing suitability).

**Regression suite (post-apply, expect 0 failures):** `fn_resolve_authorised_ai_reference_selftest` (new), `fn_asset_use_eligibility_selftest`, `fn_product_media_discovery_selftest`, `fn_cs_media_end_to_end_selftest`, `fn_ad_creative_identity_selftest` (PAL), plus the BE326 aggregate.

**Rollback preserving BE326:** redeploy the prior edge (v26) + optionally `DROP FUNCTION fn_resolve_authorised_ai_reference[_selftest]`; the deployed BE326 readiness gate still blocks supplier-only generation, so rollback reopens no new rights exposure. Forward-fix preferred.

## Controls
0 paid Gemini/OpenAI calls; 0 credits; no production migration applied; no edge deployed; no public/subscriber Creative Studio release; no quarantined-asset restoration; no commercial-rights promotion; no historical-GOLD change; no GPD.07; PAL/ownership/RLS/tenant+country isolation + revocation/expiry preserved. No already-verified Creative Studio component was reopened or rebuilt — only the two CS.04 artifacts' reference-URL minting was corrected. GPD.09 + the 18-Dec launch-critical work remain the higher priority. **GOLD 11/22 unchanged.** Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 PARTIAL. Files: `supabase/migrations/mig_379_cs04_authorised_ai_reference_resolver.sql` (committed, unapplied), `supabase/functions/commercial-image-generate/index.ts` (committed, not deployed), this report, master-doc Addendum 100. Build Evidence row **BE329**.

# BE327 — CS.04 ORIGINAL AI CREATIVE ASSET LANE (authorised-reference resolver + edge fix)

**Executed:** 2026-11-27 · **Authority:** founder "CS.04 — ORIGINAL AI CREATIVE ASSET LANE". **Status: PARTIAL — working implementation + verification evidence delivered; PREPARED, NOT DEPLOYED.** Strict controls honoured: **no production deployment** (mig_379 unapplied, edge not deployed), **no paid Gemini/OpenAI calls** (0 credits), no subscriber Creative Studio release, no quarantined-asset restoration, no commercial-rights promotion, no historical-GOLD change, no GPD.07. GPD.09 + the 18-Dec launch work remain the higher priority; this is the optional Creative Studio expansion.

This is the smallest fix that closes the exact gap recorded in BE324/BE325/BE326: *"owned-image Gemini generation remains UNAVAILABLE until the `commercial-image-generate` edge's reference resolver is wired to select owned/licensed images."* It is **not** a Creative Studio rebuild.

---

## The defect (confirmed from the deployed edge source)

The live `commercial-image-generate` edge resolves its generative reference from **one place only** — the supplier storefront — and labels it `SUPPLIER_PROVIDED`:

```
const sup = fn_product_supplier_identity(productId);
if (sup.has_supplier && supplierProductId) {
  const resolved = fn_resolve_storefront_assets(...);
  refUrl = resolved.primary_image.source_url; refRights = "SUPPLIER_PROVIDED";
}
if (!refUrl) return NOT_ELIGIBLE "NO_AUTHORIZED_REFERENCE";
```

Consequences after the BE326 readiness gate:
- **Owned-only product** → passes the readiness gate, but `sup.has_supplier=false` → `refUrl` empty → `NO_AUTHORIZED_REFERENCE`. Owned-image generation is impossible.
- **Owned + supplier product** → passes the gate, then the edge resolves the **uncleared CJ supplier image** and feeds it to Gemini — a supplier substitution (prevented today only because `products_with_owned_and_supplier = 0`).

Both violate TASK 1's rule: *"select an actual authorised customer-owned, first-party or explicitly-licensed image; never substitute an uncleared CJ, marketplace or research image."*

## The fix (smallest, additive, rights-safe)

Two committed artifacts. The edge stops reading the supplier storefront and instead asks a new resolver for the **authorised** reference; the supplier storefront is no longer a generative source.

### 1. `supabase/migrations/mig_379_cs04_authorised_ai_reference_resolver.sql` — committed, **UNAPPLIED**
`fn_resolve_authorised_ai_reference(p_tenant, p_product_id, p_market)` returns the highest-ranked **authorised** image for this product, or `NO_AUTHORISED_REFERENCE`. The ranking is the **per-image decomposition of the deployed BE326 readiness-gate predicate** (`fn_product_commercial_asset_readiness`), so it can never admit what that gate rejects:

| rank | basis | condition |
|---|---|---|
| 1 | `CUSTOMER_OWNED_UPLOAD` | `rights_state=CUSTOMER_OWNED` ∧ `source_provider=CUSTOMER_UPLOAD` ∧ `provenance.rights_confirmed=true` |
| 2 | `FIRST_PARTY_OWNED` | `rights_state=FIRST_PARTY_OWNED` |
| 3 | `OWNED_OR_LICENSED` | `rights_state ∈ {EXPLICITLY_LICENSED, LICENSED, OWNED}` |
| 4 | `AUTHORISED_AI_REFERENCE` | `provenance.ai_reference_only=true` |
| 5 | `PER_IMAGE_AI_INPUT_EVIDENCE` | `SUPPLIER_PROVIDED` image whose **exact** supplier item has an unrevoked, unexpired `permission_scope.ai_input` grant |

Anything else — **bare `SUPPLIER_PROVIDED`/`SUPPLIER_AUTHORIZED`, `MARKETPLACE_PUBLIC_LISTING`, research/discovery, `RIGHTS_UNKNOWN`, and even an *unconfirmed* customer-owned image** — yields a NULL rank and is **never** returned. Tenant isolation (`commerce_products.user_id = p_tenant`) is re-checked (defence in depth). The resolver is `STABLE SECURITY DEFINER`, additive, and changes no existing function or rights record. It also ships `fn_resolve_authorised_ai_reference_selftest()` (rolled-back synthetic fixtures; nothing persists).

### 2. `supabase/functions/commercial-image-generate/index.ts` — committed, **NOT DEPLOYED** (also the first time this edge is version-controlled)
Only the reference-resolution block changes; every existing safety layer is preserved. New flow after the BE326 readiness gate:
```
ref = fn_resolve_authorised_ai_reference(tenant=userId, product_id, market)
if ref.status != AUTHORISED_REFERENCE_AVAILABLE → NOT_ELIGIBLE "NO_AUTHORIZED_REFERENCE"
refUrl = sign(ref.storage_ref)   // private owned/licensed asset, short-lived
       ?? ref.image_url (https)  // public owned/licensed
       ?? ref.source_url (https) // only reachable for the rank-5 ai_input-evidenced image
refRights = ref.rights_state; refBasis = ref.origin_basis
```
A `signStorageRef()` helper signs a 10-minute URL so an owned image in a private bucket can be fetched by the executor. Provenance now records `{url, provider, rights_state, origin_basis, asset_id}` — honest about *which* authorised asset was used. Unchanged: JWT auth, onboarding gate, tenant/product ownership, per-tenant rate limit, the BE326 readiness gate, the Gemini executor (n8n `OYjIUMd0GS7OanbY`) + its single IMAGE_OTHER retry, the mandatory Product Asset Lock identity validator, the `IDENTITY_VALIDATED` gate, and the short-lived review-only signed URL.

## TASK 3 — three creative outputs (existing infra, no new generator)
The edge already carries exactly three allowlisted scenes, which map 1:1 to the requested categories — **no new generation code**:
| category | existing scene |
|---|---|
| High-quality product photograph | `CLEAN_STUDIO` (seamless neutral studio, soft even lighting, hero product shot) |
| Premium lifestyle photograph | `LIFESTYLE` (tasteful realistic setting, warm light, blurred background) |
| Advertising-ready promotional creative | `PRODUCT_IN_USE` (product shown in use, premium e-commerce photograph) |
All three run the same reference + the same product-preservation prompt + the same PAL validation, so identity is held across all three. (The OpenAI Ad-Studio path `creative-image-execute` is a separate, already-fail-closed lane — BE324 `fn_media_image_execution_context` — not touched here.)

## TASK 4 — verification (deterministic; no apply, no deploy, no paid calls)
Proven by executing the resolver's exact ranking logic against live production data and a synthetic scenario set (read-only; nothing written):

| # | requirement | evidence | result |
|---|---|---|---|
| 1 | Correct reference selection | **A (real):** e453 has 40 real supplier/marketplace images → **0 authorised candidates** → `NO_AUTHORISED_REFERENCE`. **B (synthetic):** owned-upload→1, first-party→2, licensed/owned→3, ai-ref-flag→4, supplier+evidence→5; bare-supplier, supplier-authorized, marketplace, research, rights-unknown, unconfirmed-owned → **null (excluded)**. Mixed set → **owned wins (rank 1) over supplier**. | **PASS** |
| 2 | Exact-product identity preserved | Edge's PAL path unchanged: identity validator + `IDENTITY_VALIDATED` gate before `usable:true`; prompt locks exact product/variant geometry, controls, materials, colour. | **PASS** |
| 3 | PAL enforced at execution | Non-validated candidate → `IDENTITY_VALIDATION_FAILED / usable:false`; `fn_ad_creative_identity_selftest` 8/8 (BE326, unchanged). | **PASS** |
| 4 | Rights checks at execution | Edge calls the readiness gate **and** the resolver synchronously on every request; no cached authorisation. e453 live → `reference_eligible=false` (never reaches the resolver). | **PASS** |
| 5 | Research-only blocked | Resolver never returns a research image (B: research→null); readiness not eligible. | **PASS** |
| 6 | Failed/revoked blocked | Resolver excludes revoked + expired `ai_input` evidence; the rank-5 predicate is byte-identical to the deployed, BE326-tested `fn_product_commercial_asset_readiness` predicate. **C (real):** e453's supplier item has no unrevoked/unexpired `ai_input` evidence → rank 5 never triggers on live data. | **PASS** |
| 7 | Correct output provenance | `fn_register_generated_commercial_asset` records reference `{url, provider, rights_state, origin_basis, asset_id}` + generation + identity verdict. | **PASS** |
| 8 | No unauthorised downloads | Output is private (`pulse-generated-media`); the signed URL is short-lived, review-only, and never a download grant; mig_377 quarantine gates still apply to generated assets. | **PASS** |
| 9 | No paid execution without approval | Resolver unapplied, edge undeployed, 0 Gemini/OpenAI calls, 0 credits this task. | **PASS** |

**No-regression:** production had **zero changes** this task (`mig_379_applied=false`, resolver + selftest absent from production), so the BE326-verified state (10/10, 0 aggregate selftest failures) is intact by construction.

## TASK 5 — handoff

**Existing components reused (no rebuild):** the `commercial-image-generate` edge end-to-end (JWT auth, onboarding gate, ownership, rate-limit, Gemini executor n8n `OYjIUMd0GS7OanbY`, PAL identity validator, provenance via `fn_register_generated_commercial_asset`, review-only signed URL); the three existing scenes; the BE326 readiness gate `fn_product_commercial_asset_readiness`; `fn_product_supplier_identity`; the `product_image_assets` + `commerce_supplier_image_rights` rights model; Supabase storage buckets; the Creative Studio UI (unchanged).

**Actual code changes:** (1) NEW `fn_resolve_authorised_ai_reference` + selftest (mig_379, committed, **unapplied**); (2) corrected `commercial-image-generate` edge (committed, **not deployed**) — swaps the supplier-storefront resolver for the authorised-reference resolver, signs private owned references, records `origin_basis`. Net new/changed lines are small and additive; no existing function, table, column, rights record, RLS policy or UI was changed.

**Tests / failures fixed:** the BE324–326 "owned-image generation unavailable / supplier-substitution" gap is closed in code and verified (A/B/C above). The committed resolver selftest covers ranks 1–5, the five exclusion classes, revoked/expired evidence, tenant isolation, and no-synthetic-persist (apply-time run). No existing test regressed (production unchanged).

**Preview-readiness status:** the Creative Studio UI is unchanged and **not released to subscribers** (control). The lane cannot produce a real generation preview yet for a structural, rights-correct reason: **there are currently 0 authorised owned/licensed images** in the system (`pulse-product-imports` is empty; no `CUSTOMER_OWNED` product image exists), so every product — e453 included — correctly resolves to `NO_AUTHORISED_REFERENCE`. A real preview requires an uploaded owned/licensed image first.

**Remaining requirements for ONE controlled generation pilot** (each needs explicit founder approval):
1. Apply `mig_379` to production and run `fn_resolve_authorised_ai_reference_selftest()` (expect all green).
2. Deploy the corrected `commercial-image-generate` edge.
3. Upload **one** authorised customer-owned/licensed product image for the pilot product via the existing `product-image-import` path (→ `CUSTOMER_OWNED` + `rights_confirmed`), giving the resolver a rank-1 reference.
4. Confirm the Gemini provider is connected (`fn_commercial_image_provider_status.connected`) and the n8n executor + identity-validator webhooks are live.
5. Approve the paid Gemini spend (below) for a single 3-image pack, kept internal (no subscriber release).

**Estimated cost of the three-image pack** (Gemini 2.5 Flash Image ≈ $0.039/image):
- 3 images, no retries: **≈ $0.12**.
- Worst case (each image uses its single IMAGE_OTHER retry): up to **≈ $0.24**.
- 3 Product-Asset-Lock identity validations (Gemini flash): **≈ $0.01**.
- **Expected total ≈ $0.12–0.13; hard ceiling ≈ $0.25.** No spend occurs without founder approval.

## Controls
0 paid Gemini/OpenAI calls; 0 credits; **no production migration applied; no edge deployed**; no subscriber Creative Studio release; no quarantined-asset restoration; no commercial-rights promotion; no historical-GOLD change; no GPD.07; RLS/PAL/tenant+country isolation + revocation/expiry preserved. **GOLD 11/22 unchanged.** Files: `supabase/migrations/mig_379_cs04_authorised_ai_reference_resolver.sql` (committed, unapplied), `supabase/functions/commercial-image-generate/index.ts` (committed, not deployed), this report, master-doc Addendum 98. Build Evidence row **BE327**.

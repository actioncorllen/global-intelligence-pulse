# STRATELOQ — Nightlight Content & Asset Recovery

**Status:** `PASS_BACKEND` · one small Lovable wiring change required for server-side drafts.
Nothing published or republished.

## What was found (inspection)

Resolved Nightlight (`e453eed4…`, CJ supplier product `2608250310481611400`, SKU CJYD3093228):
identity `IDENTITY_RESOLVED`, CJ supplier linked, cost 5.73 USD, 132 g, ships `["CN","CN_US"]`
(US yes, GB no).

- **Images:** 14 asset rows — 1 published PRIMARY + **11 additional AVAILABLE, `SUPPLIER_PROVIDED`,
  exact-product CJ images** (distinct URLs) that were blocked only by `asset_class`
  (`PRODUCT_ONLY` / `SUPPLIER_GALLERY_IMAGE` from the `CJ_PRODUCT_QUERY` path) + a CJ supplier-name
  normalization gap; 2 rows genuinely UNAVAILABLE (no URL).
- **Verified supplier facts:** USB-powered, dual-mode, starry-sky projection,
  "3 Projection Discs — English Packaging", 132 g, 8 variants.
- **No supplier video** (`isVideo` false); **no operating-instruction / description text** was
  captured by the CJ enrichment.

## What was recovered (mig_341, lock-preserving)

1. **Permissions recorded SEPARATELY** (`fn_record_supplier_asset_commercial_reuse`):
   commercial-reuse **authorized** for storefront display on the `SUPPLIER_PROVIDED` basis
   (12 assets: the primary + 11 additional); AI-processing recorded **NOT authorized**
   (`REQUIRES_EXPLICIT_MERCHANT_GRANT`) — a distinct grant, never inferred from a supplier URL.
2. **Resolver extended** (`fn_resolve_storefront_assets`): CJ supplier-family normalization,
   a recorded `commercial_reuse` acceptance path, and URL de-duplication. The rights lock is
   intact — usable still requires AVAILABLE + `SUPPLIER_PROVIDED/LICENSED/OWNED` + exact product
   + not reference/sourcing/marketplace. **Usable images: 1 → 12.**
3. **Content enriched** (`fn_product_page_strategy`) with supplier-VERIFIED facts:
   benefits `USB-powered`, `Two projection modes`, `Projects a starry-sky scene`,
   `Includes 3 projection discs`; details `Power=USB`, `Projection modes=Two (dual-mode)`,
   `Projection discs included=3`, `Packaging=English packaging`, `Variant options=8`
   (details 4 → 9); one evidence-backed FAQ (`How is it powered? → USB-powered`). No invented
   capabilities, delivery estimates, reviews, certifications or performance claims.

## Deliverable counts

| Item | Count |
|---|---|
| Usable authorized images | **12** (1 primary + 11 gallery, deduped) |
| Usable videos | **0** (no supplier video exists) |
| Verified benefits | **7** (2 identity + 4 supplier features + 1 shipping, US) |
| Verified features (detail rows) | **9** |
| Operating steps | **0** (no supplier operating instructions captured) |
| Evidence-backed FAQs | **1** |

## Unresolved asset-rights / content gaps (external)

- **AI-processing rights** for the recovered images are recorded as **NOT authorized** — a
  separate explicit merchant grant is required before any generative/derivative use.
- **Supplier video** — none exists at CJ for this product (`isVideo` false).
- **Operating instructions / long description** — not captured by the existing CJ enrichment;
  obtaining them requires re-running the CJ detail integration (external), not fabrication.
- 2 supplier image rows remain UNAVAILABLE (no URL) — correctly excluded.

## Draft persistence (mig_342)

Merchant builder drafts were **device-local only** (`builder-spec.ts` localStorage; the Save
button says "Draft saved on this device"). Added the smallest secure, tenant-isolated
**server-side** persistence reusing the existing contract: a separate `builder_draft` column on
`commerce_product_pages` with `fn_save_product_page_draft` / `fn_load_product_page_draft`
(SECURITY DEFINER, `user_id = auth.uid()`). It never touches `runtime_contract` /
`published_spec` / review or publication state, so **published revisions are not altered**.

**Lovable wiring change required (small):** point `saveDraft` / `loadDraft` in
`src/lib/storefront/builder-spec.ts` at these RPCs (keyed by `productContext.productPageId`),
keeping localStorage as an offline fallback. No renderer or builder redesign.

## Verification

- `fn_nightlight_content_asset_selftest` **13/13** (usable images 12, no dup URLs, all rights
  cleared, commercial-reuse recorded 12, AI-processing separately not-authorized 12, feature
  benefits + enriched details + power FAQ present, no unsupported claims, published page untouched).
- `fn_product_page_strategy_selftest` **23/23**; `fn_product_page_builder_selftest` **9/9**;
  `fn_product_page_draft_selftest` **6/6** (round-trip, cross-tenant denied, publication/snapshot
  untouched).
- Regressions green: publish / lifecycle / ux / runtime selftests; `fn_storefront_public_parity`
  0 fail; `fn_page_publish_economics` 0 fail; ad-verification pass. Store membership unchanged
  (**2 products**); current published Nightlight unchanged (`LEGACY_MINIMAL`, no snapshot,
  not republished). Security advisors: **0 ERROR** (4 WARN / 1 INFO baseline).

Nothing was published or republished; write-path proofs ran in rolled-back subtransactions.

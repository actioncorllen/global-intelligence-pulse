# Product Image Quality — investigation, resolution, coverage & release (2026-11-09)

Refinement of the existing media architecture (not a rebuild): make Product Discovery visually professional
without compromising image rights, exact-product identity or Product Asset Lock. No paid API calls; no new
discovery wave; nothing published without founder approval. Backend prepared + tested (NOT deployed); frontend
is a Lovable preview (NOT published).

## P1 — Existing image sources (what is authentic, and what display permissions exist)

Media tables inspected: `product_image_assets` (Explorer resolver source), `product_asset_intelligence`,
`supplier_product_assets`, `commerce_supplier_products` (CJ catalogue), `media_assets` (imported/generated),
`commerce_generated_assets` (AI — never used as authentic), `commerce_concrete_supplier_resolution` /
`commerce_cross_supplier_identity` (exact-SKU binding). Rights vocabulary found in `product_image_assets`:

| source | rights_state | what it is | display permission |
|---|---|---|---|
| `CJ_SUPPLIER` | `SUPPLIER_PROVIDED` | supplier-authorised product image | display-cleared (research); commercial still PAL-gated |
| `FASTMOSS` | `PROVIDER_DISCOVERY_REFERENCE` | authentic provider product image (external CDN) | display-for-research; **not** commercial |
| `EBAY_BROWSE` | `MARKETPLACE_PUBLIC_LISTING` | marketplace listing image (tenant-null) | **reference link only — never copied/displayed** |

A publicly reachable image is **not** licensed for copying: eBay marketplace images are tenant-null,
rights-not-established, and the system already treats them as link-only (confirmed in Recommendations, which
exposes the listing URL and states "image not copied"). AI-generated assets are never treated as authentic.

## P2 — Automatic resolution (prepared, `mig_340`, Explorer v4)

The Explorer image resolver now resolves the best **tenant-owned** image in rights-priority order and preserves
provenance — using only existing data:
1. `SUPPLIER_PROVIDED` (supplier-authorised) → display cover
2. `PROVIDER_DISCOVERY_REFERENCE` (provider research image) → display cover
3. marketplace listing → **never a cover**; surfaced as a link to the public listing (tier-5 research reference)

Per item it emits (additive): `image_status` (`DISPLAY`|`REFERENCE`|`NONE`); an `image` object
`{url, source_provider, rights_state, source_url, observed_at, display_cleared:true, commercial_cleared:false,
reference_only}` for display images; a `reference` object `{url(listing), source_provider, rights_state,
image_copied:false}` for permitted link-only references; `cover` kept for back-compat. Preserved: original
source, product identity (resolution is per canonical `product_id`), supplier identity (`source_provider`/
`rights_state`), country relevance (market-scoped), usage permission (`rights_state` + never asserting
commercial), source timestamp (`observed_at`), commercial-rights classification (`commercial_cleared:false`
everywhere — the Explorer is `authority: REFERENCE_ONLY`). A visually-similar different product is **never**
substituted: images are keyed strictly to the product's own `product_id` and tenant. Non-regressive: for the
current data the chosen cover is identical to v3.

## P3 — Professional card presentation (Lovable preview)

- Products **with** an authorised display image → keep the current high-quality visual card (the 9 FastMoss).
- Products **without** → a compact research-card layout: no large aspect-square image block, no "enormous blank
  placeholder"; a slim header (small icon tile + muted caption) with the opportunity-class/lane chips, then the
  full research content — title (+ translation), price, revenue, sales, growth, promotions, "Seen · Reference
  only" — and exact-product nav preserved (the whole card opens that product's own detail).
- A compact card for a product with a permitted marketplace reference shows a small **"Reference listing ↗"
  link** (opens the public listing in a new tab) — never the marketplace image. Valid research data is never
  hidden because an image is missing.

## P4 — Premium showcase (unchanged, verified)

The premium visual showcase lives in Recommendations and already **requires a rights-cleared supplier image**
(`has_authentic_image`), with `showcase_eligible_count = 0` live. Gold/Platinum thresholds are unchanged.
Research-display permission is never treated as commercial/publication rights: reference-only media never
unlocks advertising or storefront publication (`commercial_cleared:false`; `authority: REFERENCE_ONLY`).

## P5 — The 29 German products — image coverage (live)

| category | count | detail |
|---|---|---|
| Authorised display images | **9** | FastMoss `PROVIDER_DISCOVERY_REFERENCE` (tenant-owned, research-display) |
| Permitted reference images (link only) | **3** | eBay `MARKETPLACE_PUBLIC_LISTING` — listing link, image never copied |
| Supplier-authorised images | **0** | no `SUPPLIER_PROVIDED` / CJ image for any of the 29 |
| No permitted image | **17** | no image or reference at all |
| Reusable existing sources | — | the 9 provider display images + the 3 marketplace listing links |
| Missing permissions / supplier matches | — | 20 products have no display-cleared image; **0** exact-SKU CJ bindings; `product_asset_intelligence`/`media_assets` hold 0 rows for these 29 |

Conclusion: image coverage **cannot be increased from existing data** — a richer image for the 20 requires an
authorised supplier (e.g. CJ) binding with display rights, a separate, approved (paid) sourcing step. The fix
here is honest, professional presentation of the imageless products, plus a rights-ranked resolver that will
surface authorised images automatically once they exist.

## P6 — Testing

- **Backend (mig_340):** transactional test (production untouched via ROLLBACK) — v4 compiles; DE total 29 =
  **9 DISPLAY + 3 REFERENCE + 17 NONE**; no item carries both an image and a reference; display items carry
  `display_cleared:true`/`commercial_cleared:false`; reference items carry `image_copied:false` + an eBay
  listing URL + no cover; no NONE item has a cover; no marketplace image is ever a cover; tenant + country
  isolation and PAL unchanged (same scoping as v3).
- **Frontend (preview commit `db027f5`):** **549 tests passed, 0 failed** across 76 files (+9 new in
  `product-explorer-images.test.ts` unit + `product-explorer-images.test.tsx` component). Verified: exact-product
  image identity (cover keyed to the item's own product, `data-product-id` preserved); DISPLAY renders the
  authorised cover as the only `<img>`, REFERENCE renders a link-only `<a>` (no `<img>`), NONE renders a compact
  card with neither; **no wrong-product substitution** (a card's DOM never contains another item's image, exactly
  one `<img>` for the three-card fixture, no `<img src>` matches a marketplace URL); correct product-detail
  navigation (card body opens that product; the reference link opens the marketplace listing in a new tab and
  does **not** open the card); Product Asset Lock (marketplace image never an `<img>`, drawer treats REFERENCE
  like NONE, `commercial_cleared` never claimed); existing Explorer compatibility (growth 527×/Unverified,
  labels, 24+5 pagination all still pass). **Typecheck** (`bunx tsgo --noEmit`) clean; **lint** 0 errors (6
  pre-existing fast-refresh warnings); **preview build** OK. Responsive/phone-width visual acceptance is a
  founder-device step (egress 403).

## Release control — DEPLOYED 2026-11-09 (founder-approved)

- **Backend:** `mig_340` applied to production → `fn_product_explorer` = `pulse_product_explorer_v4` (SECURITY
  DEFINER, `search_path=''` preserved). Live acceptance: DE total 29 = **9 DISPLAY + 3 REFERENCE + 17 NONE**; 0
  marketplace images as covers; 3 reference links (eBay listing, `image_copied:false`, no cover); tenant isolation
  (other tenant DE = 0); country isolation (0 DE ids in GB); pagination 24 + 5; PAL (`reference_only_media:true`,
  `image_commercial_never_asserted:true`, 0 display items claim commercial); growth 20 Kalodata VERIFIED / 0
  FastMoss numeric; 20 NEWLY_DISCOVERED / 0 NEWLY_LISTED. Recommendations/showcase untouched (mig_340 changes only
  `fn_product_explorer`).
- **Frontend:** Lovable preview `db027f5` published → deployment **`e9e893ff-573a-4341-82d0-fd2370540b9a`**,
  `is_published=true`. Pre-publish: 549 tests pass, typecheck/lint/build clean.
- **Rollback:** `mig_340_ROLLBACK.sql` restores v3; re-publish prior frontend commit `312fce3`.
- No paid provider calls; no discovery wave; no supplier-budget / advertising / billing / signup changes.
- No paid provider calls; no discovery wave; no supplier-budget / advertising / billing / signup changes.

## Remaining source-permission blockers

- The 20 imageless DE products have **no** display-rights-cleared image in existing data; a genuine product
  image requires an authorised CJ (or other) supplier binding with display rights — a separate, founder-
  approved sourcing step. "No image" (now a professional compact card) stays correct until then.
- Signed-in on-device visual acceptance (desktop + mobile) is a founder-device step (container egress to the
  live app is auth-gated / 403).

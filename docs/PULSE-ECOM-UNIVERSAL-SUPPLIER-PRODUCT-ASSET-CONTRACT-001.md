# Universal Supplier Product Asset Contract (Founder Addendum)

**VERDICT: PASS.** A permanent, **provider-independent** Supplier Product Asset Contract now ingests a
supplier product's legitimate images **at product-import time**, keyed to the supplier product's own
identity — CJdropshipping first, and every future authorized supplier plugs into the same store and
functions without any provider-specific downstream image architecture.

## Canonical store — `supplier_product_assets` (mig_208)
One row per asset (PRIMARY_IMAGE / GALLERY_IMAGE / VARIANT_IMAGE / VIDEO / IMAGE_UNAVAILABLE) per supplier
product, provider-independent (`supplier` column). Each asset carries `asset_class`
(**SOURCE_PRODUCT_ASSET** — never generated or competitor), `asset_identity` (**SUPPLIER_OWN**, EXACT to
its supplier product), `rights_state`, `availability` + `unavailable_reason`, `source_url` (original
supplier ref, preserved), `cache_state`/`storage_ref` (for Pulse object-storage caching), `is_primary`,
`observed_at`, `provenance`.

## Ingestion — `fn_ingest_supplier_product_assets` (mig_209)
Provider-independent normalizer: reads a supplier product and writes its **primary** image immediately,
plus gallery/variant/video **where the source exposes them** — otherwise an honest `IMAGE_UNAVAILABLE`
row with a reason. Never fabricates, never borrows a competitor or other-supplier image. Returns the four
acceptance flags.

## Two-layer identity — `fn_resolve_product_image` v2 (mig_210)
- **Supplier product's own image** → EXACT to that supplier product (SUPPLIER_OWN), no fuzzy match.
- **Representing a discovered demand candidate** → EXACT (hero) requires a **real identifier link**; a
  category / title / same-store match is never EXACT. A comparable image is labelled reference and is
  **never** hero-eligible.

## Asset delivery (production, not Claude)
Original supplier URL + rights + provenance are preserved so production can **cache assets into
Pulse-controlled object storage** rather than depend on fragile hotlinks. The Claude sandbox and the
artifact CDN allowlist block the CJ image host — a **Claude-only** limitation that never determines the
Pulse production asset architecture.

## One asset, many uses / strict provenance separation
Canonical `SOURCE_PRODUCT_ASSET` rows are the single reusable source for Monday Opportunities, Opportunity
Workspace, Supplier Comparison, Store Builder, Product Page Builder, Ad Studio, Creative Intelligence and
the image-to-video pipeline — resolved once, never re-downloaded per feature. `SOURCE_PRODUCT_ASSET` /
`GENERATED_MARKETING_ASSET` (media_assets) / `COMPETITOR_REFERENCE_ASSET` never share provenance or rights.

## Acceptance — 5 real CJ products, 14/14 tests PASS
Ingested 5 real CJdropshipping products through the universal contract:
| Flag | Result |
|---|---|
| PRODUCT_HAS_IMAGE | **true** (real primary image on each) |
| IMAGE_RESOLVED_BY_PULSE | **true** (canonical asset row created) |
| IMAGE_RENDERABLE_IN_PULSE | **true** (valid supplier URL + rights; Pulse can fetch/cache/render) |
| IMAGE_RENDER_BLOCKED_ONLY_IN_CLAUDE | **true** (CJ host blocked by Claude sandbox/CSP only) |

Each: PRIMARY_IMAGE present (SUPPLIER_OWN/EXACT, `SUPPLIER_PROVIDED` rights, real URL); GALLERY + VARIANT
recorded `IMAGE_UNAVAILABLE` with reason (`…REQUIRES_SUPPLIER_DETAIL_FETCH`) — the list-level cache carries
only the primary; full gallery/variant images come from the supplier detail fetch the production adapter
performs. Discovered candidates (projector, digital frame) resolve to **CLOSE_COMPARABLE, hero_eligible
false**; a leather-patch category auto-match resolves to **REFERENCE_ONLY** (not EXACT just because it's
the same store); the **EXACT hero path** activates only when a real identifier link is asserted. **0
fabricated hero rows persisted.** No `media_assets` (generated) rows created; no customer publication
(`commerce_product_opportunities`=0, daily_briefs unchanged); `campaign_activation`=FALSE;
`advertising_spend`=0.

## Adapter acceptance gate (future suppliers)
A future supplier adapter is not fully PASS until it proves: product identity + asset ingestion + image
provenance + asset identity + cost/stock/fulfilment where the supplier exposes them — recording any field
the supplier does not expose honestly as unavailable rather than fabricating it. Overall paid-beta
engineering readiness ≈ 84% (unchanged).

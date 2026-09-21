# STRATELOQ-ECOM-PRODUCT-IMAGE-AUDIT-013T

**FINAL VERDICT: `PRODUCT_IMAGE_CONTRACT_ADDED_READY_FOR_UI`.**

Strateloq already stores exactly one class of trustworthy, canonically-tied product image:
the **supplier-provided catalogue image** reachable through a product's EXISTING canonical
supplier link (`commerce_products.extended → supplier_ref/supplier_refs →
commerce_supplier_products → supplier_product_assets` primary image). No AI/ad creative and no
keyword-matched image is ever used. The workspace RPC did **not** previously expose any image
field, so this audit added the smallest additive, read-only, browser-safe contract:
`product_image_url`, `product_image_source`, `product_image_source_url` on each
`product_decision` in `fn_ecommerce_workspace_intelligence()`. The image is resolved **strictly
through the established canonical supplier link** (never a title/keyword match), rights-honoured
(`availability='AVAILABLE'`, `rights_state='SUPPLIER_PROVIDED'`), and is **NULL** when no verified
image exists so Lovable renders a neutral placeholder. Migration `mig_258`. No score/decision/
provenance change, no image generation, no paid provider, no Lovable change, no publish.

---

### 1. Existing image-capable sources
- **CJ supplier catalogue** — `commerce_supplier_products.image_url` (public CDN URL) — populated for
  the founder's supplier catalogue.
- **CJ supplier assets** — `supplier_product_assets` (25 real rows) — a proper media/rights model:
  `asset_type ∈ {PRIMARY_IMAGE, IMAGE, GALLERY_IMAGE, VARIANT_IMAGE}`, `rights_state ∈
  {SUPPLIER_PROVIDED, UNKNOWN}`, `availability`, `is_primary`, `source_url`, `storage_ref`.
- **eBay evidence** (`product_market_competitors`) — **no image column**; `observed_product_url`
  present but empty (0/300 for the audited products); only saturation counts are stored.
- **DataForSEO / Meta evidence** — buyer-intent + advertising signals only; **no product image** is
  captured (and an AI-generated ad is explicitly NOT treated as product identity).
- **`commerce_products`** — no image column; only `provenance`/`extended` JSONB (no image URL).
- **`product_acquisitions`** (acquisition snapshots) — **0 founder rows** (no image there).
- **media_assets / media_video_jobs / generated_content** — internal creative/generation surfaces,
  NOT evidence of what the researched product actually is; deliberately excluded.

### 2. Existing image fields/tables
`commerce_supplier_products.image_url` (text, public CDN) and `supplier_product_assets`
(`source_url`, `asset_type`, `rights_state`, `availability`, `is_primary`). These are the only
truthful product-image stores; both are reachable **only** via the canonical supplier link, which
ties them to a specific `product_id`.

### 3. cool mist humidifier — image availability
**No trustworthy image.** `cool mist humidifier` (`cda3f71a…`, source `dataforseo`) has **no**
`supplier_ref`/`supplier_refs` link, so no canonically-tied supplier image exists. Keyword-similar
humidifiers exist in the CJ catalogue (e.g. "New UFO Raindrop Humidifier", "Flame Humidifier") but
using any of those would be a keyword match to a DIFFERENT product — explicitly forbidden — so the
contract returns `product_image_url = NULL` (placeholder). Correct and safe.

### 4. kids nightlight projector — image availability
**Yes — trustworthy image.** Canonically linked (via `extended.supplier_ref.supplier_row_id =
a7ca5195…`) to CJ supplier product `2608250310481611400` ("USB Projection Lamp … Dual-mode
Starry-sky Projector Night Light"), which has a **PRIMARY_IMAGE** asset: `rights_state =
SUPPLIER_PROVIDED`, `availability = AVAILABLE`, `is_primary = true`, source
`https://oss-cf.cjdropshipping.com/product/2026/08/25/03/beb8eabe-…`. Source: `SUPPLIER_PROVIDED`.

### 5. Image coverage across workspace-visible products
5 distinct visible products (8 market rows). Resolving strictly via the canonical supplier link:
- **images available: 1** — `kids nightlight projector` (carries its product-global image on all 4
  of its market rows: GB/DE/FR/US).
- **no image available: 4** — `cool mist humidifier`, `digital picture frame`, `over door shoe
  organizer`, `red light therapy led mask` (no canonical supplier link → `NULL` → placeholder).

### 6. Recommended authoritative image hierarchy (implemented)
1. Canonical supplier-linked **`supplier_product_assets`** primary image, `AVAILABLE` +
   `rights_state='SUPPLIER_PROVIDED'` (`is_primary` then `PRIMARY_IMAGE` preferred).
2. Fallback: canonical supplier-linked **`commerce_supplier_products.image_url`** (the supplier's
   own catalogue image of the linked product).
3. (Future, when captured) another authorized tenant/product evidence image.
4. **No verified image → `NULL`** (frontend placeholder).
Unrelated web image search and unsupported-site scraping are excluded; AI/ad creative is never used.

### 7. Product-global vs market-specific
**Product-global.** The physical product looks identical in every market; the image is tied to the
canonical `product_id` via the supplier link, not to a market. (Saturation/price/economics remain
market-specific; only the image is shared.) Verified: the nightlight's single supplier image is
returned identically on its GB/DE/FR/US rows.

### 8. Does the workspace RPC already expose images?
**Previously: no.** `fn_ecommerce_workspace_intelligence()` exposed no image field. **Now: yes** —
this unit added `product_image_url`, `product_image_source`, `product_image_source_url`.

### 9. Smallest backend change required
`mig_258_workspace_product_image_contract.sql`: one additive `LEFT JOIN LATERAL` on each decision
row that resolves the canonical supplier image (asset-primary → catalogue fallback) and three new
output keys. No other logic, table, score, decision, or provenance changed. Read-only, STABLE,
SECURITY DEFINER, `search_path=''` preserved.

### 10. Exact Lovable contract fields
On every element of `product_decisions[]`:
- `product_image_url` — `string | null` — display image of the canonical product (public CDN URL).
- `product_image_source` — `string | null` — provenance token; currently `'SUPPLIER_PROVIDED'` or
  `null`.
- `product_image_source_url` — `string | null` — origin URL of the image (provenance).
When `product_image_url` is `null`, render a neutral product placeholder. (Lovable change deferred —
this unit does not modify Lovable.)

### 11. Security / provenance findings
- Only a **public CDN image URL** and a coarse provenance token are exposed. **No** supplier
  credentials, supplier internal id, SKU, or supplier cost is returned.
- Image is resolved **only** through the product's own established canonical supplier link, so an
  image can never leak from a different, keyword-similar product (Section 3 market safety upheld).
- Rights honoured: only `AVAILABLE` + `SUPPLIER_PROVIDED` assets used (denormalised catalogue image
  as fallback — itself the supplier's provided image of the linked product).
- Advisors: **0 ERROR** (1 INFO + 4 WARN, unchanged baseline). RPC stays tenant-scoped via
  `auth.uid()`; RLS unchanged.

### 12. Files / functions / migrations changed
- `supabase/migrations/mig_258_workspace_product_image_contract.sql` — `CREATE OR REPLACE
  fn_ecommerce_workspace_intelligence()` (additive image contract).
- Reused unchanged: `commerce_supplier_products`, `supplier_product_assets`, canonical supplier
  link. No new table, no data write, no Lovable change.

### 13. Tests
- All 12 backend selftests pass (`dfs_discovery`, `deep_research`, `connection`, `contracts`,
  `media_creative` 4/4, `paid_access`, `orchestrator`, `search_relevance`, `storefront_branding`,
  `storefront_runtime`, `storefront_publish`, `storefront_publish_lifecycle`).
- Direct RPC verification (founder auth): 8 decision rows; `product_image_url` non-null on exactly
  the 4 `kids nightlight projector` market rows (`SUPPLIER_PROVIDED`), null on the other 4 — matching
  the canonical-link truth; no keyword leakage.

### 14. Commit / push status
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`. Hash / divergence: see delivery
message.

**STOP.** Audit complete; smallest additive image contract added and verified. No image generated,
no paid provider called, no research run, no decision/score/provenance changed, no Lovable change,
no publish.

# Product Discovery Quality Corrections (2026-11-09)

Continues from the deployed state (mig_336/337/338 + Kalodata edge v12, Explorer v2). No paid provider
calls; no discovery wave; no new provider budgets; nothing published to production without founder approval.

## 1. Root causes

### P1 — "No image" on newly-discovered Kalodata products
- The Kalodata `product/rank` API response carries **no product-image URL** that `fn_extract_cover_url`
  recognises → `fn_persist_reference_image` stored nothing → the 10 new DE Kalodata products have **0**
  display images.
- The only images attached to any of these products are **eBay `MARKETPLACE_PUBLIC_LISTING`** images
  (`tenant_id = NULL`, rights **not** established for display). The Explorer correctly excludes them
  (tenant-scoped + Product Asset Lock). There is **no CJ supplier match** (0/10, branded products) so no
  rights-cleared `SUPPLIER_PROVIDED` image exists.
- **Verdict:** "No image" is the **honest, PAL-correct** state — there is no display-rights-cleared image.
  Fabricating/substituting or showing the marketplace image would violate PAL and the founder's rule.

### P2 — Growth metrics (missing + anomalous "571.17K%", "5.26m%")
- **Missing (Kalodata):** Kalodata growth is stored in `revenue_growth_rate` (a genuine %, range −96…+746),
  but the card read `sales_growth_rate`, which is **null** for Kalodata → blank growth.
- **Anomalous (FastMoss):** `sales_growth_rate` = the provider's `units_sold_growth_rate` stored **raw**.
  That raw value is a **percentage × 100**. Proof from the full live distribution ÷100:
  `−3906 → −39.06%` (impossible as a raw %, valid as /100), `1021 → 10.21%`, `20390 → 203.9%`,
  `571169 → 5711.69%`, `5260000 → 52600%`. Every value becomes a valid percentage; none is < −100%.
  Rendering the raw value as a "%" with K/m formatting produced "571.17K% / 5.26m%".

### P3 — Status labels — **already correct in the backend**
`NEWLY_DISCOVERED` is assigned to Kalodata-native products (Strateloq-identified); `NEWLY_LISTED` is
assigned **only** to products with a FastMoss `NEW_LISTED` lane (marketplace evidence). Live check: Kalodata
products carry `opportunity_class = NEWLY_DISCOVERED` only; **0** are `NEWLY_LISTED`. No conflation of
"discovered recently" with "newly listed". (Display-chip wording is the frontend's job — see §2.)

### P4 — Product Detail navigation — backend identity intact
Every item carries its canonical `product_id`; the market is a client-held filter. Navigation correctness is
a frontend concern (card → detail by `product_id`, preserving the selected country) — see §2.

### P5 — Pagination — **already correct in the backend**
`fn_product_explorer('DE', page=1/2, pagesize=24)` returns 24 + 5 = **29**, with **29 distinct** product_ids
across both pages (no duplicate, no missing), tenant-scoped (no cross-tenant). Reachability is a frontend
page-control concern — see §2.

## 2. Fixes completed

### Backend — `mig_339` (prepared + tested, NOT deployed)
`fn_product_explorer` → **v3** (`pulse_product_explorer_v3`), additive:
- `growth_pct` (number) — **source-aware, verified percentage**: Kalodata `revenue_growth_rate`;
  FastMoss `round(units_sold_growth_rate / 100, 2)`; null when unknown (never fabricated).
- `growth_basis` — `'revenue_7d_pct'` | `'units_sold_7d_pct'` | null.
- `image_status` — `'DISPLAY'` when a rights-cleared cover exists, else `'NONE'` (honest "No image").
- `HIGH_GROWTH` facet + growth filter now use `growth_pct` (so Kalodata growth is filterable and FastMoss
  uses the real %-scale). Raw `sales_growth_rate` / `revenue_growth_rate` kept for transparency.
- No engine/tier/label/identity change; tenant + market scoping and PAL unchanged.
- **Transactional test: 7/7 PASS** — max `growth_pct` = **52600** (not 5.26M); FastMoss = raw/100; Kalodata =
  `revenue_growth_rate`; min = −96.13 (valid %); `image_status` NONE for the 10; total still 29.
- Rollback `mig_339_ROLLBACK.sql` restores v2. Committed `e169774`.

### Frontend — Lovable preview (preview only; production publish gated on approval)
Instructed the Product Explorer card/detail to:
1. Display growth from `growth_pct` (fallback: FastMoss `sales_growth_rate/100`, Kalodata
   `revenue_growth_rate`); format `< 1000%` as "+X.X%", `≥ 1000%` as a multiplier ("527×"); never K%/m%;
   hide when null.
2. Keep the honest "No image" placeholder when `image_status='NONE'`/`cover` null — no fabrication.
3. Render `NEWLY_DISCOVERED` → "Newly discovered", `NEWLY_LISTED` → "Newly listed" strictly from
   `opportunity_class`; show "Research pending" + no score when `research_status` is pending.
4. Open each product's canonical Product Detail by `product_id`, preserving the selected country.
5. Page through all 29 (24 + 5) with controls when `total_pages > 1`.
_(Preview build status + verification recorded at the end of this doc.)_

## 3. Verification results
- Backend diagnosis: all six priorities traced on live data (queries above).
- `mig_339`: 7/7 transactional PASS (production untouched — rolled back).
- Frontend preview: pending (verified at the scheduled check-in; see §6).

## 4. Preview commit / prepared migration
- Prepared backend migration: `supabase/migrations/mig_339_product_explorer_growth_normalization.sql`
  (+ `mig_339_ROLLBACK.sql`). Committed `e169774`, **not deployed**.
- Frontend: Lovable **preview** edit (not published).

## 5. Production deployment requirements (gated on founder approval)
1. Apply `mig_339` (additive; drops nothing; data/history preserved). Rollback restores v2.
2. Publish the Lovable frontend preview to production (after visual confirmation on device).
3. Deploy order: `mig_339` first (so `growth_pct`/`image_status` exist), then publish the frontend. The
   frontend fallback keeps growth correct even before `mig_339`, so order is low-risk.
4. No engine/tier/label changes; no new provider budgets; no paid calls.

## 6. Remaining blockers
- P1 images: no display-rights-cleared image exists for the Kalodata products; a real image requires a CJ
  (or other) supplier binding with display rights — a separate, authorised sourcing step. "No image" stays
  correct until then.
- FastMoss growth unit (×100) is inferred from the data (the −3906 → −39% anchor), not official FastMoss
  docs; if FastMoss later documents a different scale, adjust the single `/100` factor in `mig_339`.
- Lovable preview → production publish and the signed-in visual acceptance are founder-device steps.

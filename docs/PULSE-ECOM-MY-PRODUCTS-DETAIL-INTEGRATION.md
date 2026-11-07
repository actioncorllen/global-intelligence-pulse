# My Products → Enriched Product-Detail Drawer — Integration (PREPARED FOR APPROVAL)

Connect My Products acquisitions to the existing enriched product-detail drawer (ExplorerDrawer /
ProductIntelligenceDrawer) by preserving the verified canonical `commerce_products.id`. Founder approved
preparing the minimal additive backend change. **Backend NOT applied to prod; frontend NOT published.**

## 1. Proposed migration (prepared, awaiting approval)
`supabase/migrations/mig_332_my_products_canonical_product_link.sql`:
- **Additive column:** `product_acquisitions.product_id uuid REFERENCES commerce_products(id) ON DELETE SET NULL`
  (nullable). Table is empty in prod → no backfill; existing records/workflows unaffected (req 7).
- **`create_product_acquisition`:** resolves the canonical id by trusting **only an explicit
  `candidate.product_id`** that is validated to be a real `commerce_products` row **owned by auth.uid()**;
  otherwise stores NULL. No title/URL/position/fuzzy inference (req 4); preserves canonical id (req 2);
  tenant-scoped (req 10). Malformed id → NULL (never guesses).
- **`get_own_product_acquisitions`:** additively surfaces `product_id` and a read-resolved `market`
  (the product's primary EVIDENCED market from product_image_assets, else top video country_code, else NULL —
  never fabricated; req 3/6). Existing fields unchanged.
- Rollback documented in the file header (drop column + restore prior function bodies).

## 2. Why this resolution (existing-architecture review, read-only)
- The member's catalogue products are `product_role='candidate'` with identity `candidate:name:<source>:<title>`
  (basis `platform_id`) — a scheme distinct from `fn_commerce_product_identity`'s url/pid/name output.
  Re-deriving identity from the acquisition snapshot's title/URL would be unreliable **and** is forbidden.
- The acquisition-creation path is currently **dormant**: neither of the 2 members has
  `winning_product_intelligence` populated, so `create_product_acquisition` returns `no_winning_intelligence`
  and `product_acquisitions` is empty. There is no live candidate schema to re-derive from.
- Therefore the only identity-safe resolution is to carry forward an explicit canonical id, validated + owned.
  This can never open the wrong product; when the id is absent/unvalidated, the UI shows an unresolved state
  (req 8).

## 3. Affected contracts
- Backend: `create_product_acquisition(text)`, `get_own_product_acquisitions()`, `product_acquisitions` table
  (+`product_id`). Reused unchanged: `fn_commerce_product_identity` (IMMUTABLE), `commerce_products`,
  `ExplorerDrawer`/`ProductIntelligenceDrawer` and all drawer read RPCs (fn_product_media_state,
  fn_product_supplier_candidate, fn_resolve_product_gallery — all auth.uid()-owned, market-isolated).
- Frontend: `src/lib/business-discovery/acquisition-api.ts` (`ProductAcquisition` gains `productId`,
  `market`; decoded tolerant of missing keys), `src/components/business-discovery/my-products-view.tsx`
  (adds `acquisitionToExplorerItem` + a "View Product" control that opens the reused `ExplorerDrawer` for the
  exact productId+market, or a clear unresolved state when productId is null), + its test file.

## 4. Acceptance evidence (read-only, prod — no writes)
- **Resolver cannot mis-resolve:** it stores `product_id` only when `candidate.product_id` casts to uuid AND
  matches a `commerce_products` row with `user_id = auth.uid()`. No fuzzy/title path exists in the code.
- **Market resolver returns correct, country-isolated markets** for known products:
  `873551b0` (Illuminated Snowman) → **GB**; `5bc29d0a` (Beleuchtete Krippen) → **DE**;
  `1fe5b267`, `d1e42001` → **NULL** (no market-tagged media yet — honest unresolved, not fabricated).
- **Drawer ownership is enforced server-side:** fn_product_media_state etc. check
  `commerce_products.user_id = auth.uid()`, so a resolved product always belongs to the member (req 10).
- **Frontend tests** (Lovable preview build `c9efb95`): **488 tests pass** (71 files, +5 new), typecheck
  clean, lint 0 errors on changed files, preview build OK. Covered: acquisition WITH productId → "View Product"
  opens the reused `ExplorerDrawer` for that EXACT productId+market (cp-222/GB, cp-111/DE), remounts per
  product on switch; acquisition WITHOUT productId (null/blank) → unresolved state ("Product details not
  available yet."), drawer never opens, never another product, Manage still available;
  `acquisitionToExplorerItem` seeds the exact id + market with every metric null (no fabrication); decoder
  reads product_id/market and stays null when missing/null/blank/non-string. Guard-scan of the diff: no new
  backend (no create-or-replace-function / service_role / functions.invoke / new .rpc). Not published.
  Frontend files: `acquisition-api.ts` (+`productId`,`market`), `my-products-view.tsx` (View Product + reused
  drawer + unresolved state), `my-products-view.test.tsx`, new `acquisition-api.test.ts`, and four
  placeholder `ProductAcquisition` literals updated with the two nullable fields for type-check only
  (`product-page-builder.tsx`, `dev.product-page-builder.tsx`, `my-products.test.ts`,
  `product-page-builder.canonical.test.tsx`).

## 5. Follow-up for guaranteed coverage (req 6) — separate, flagged, NOT in this migration
Until the upstream discovery projection that writes `winning_product_intelligence` candidates stamps the
canonical `commerce_products.id` onto each candidate, acquisitions created from candidates lacking an embedded
id will resolve to NULL (unresolved state). Stamping the id at projection time (where it is already known)
guarantees every future acquisition resolves. That producer is outside this DB function and is proposed for
separate review. No existing data is affected.

## 6. Guardrails honored
No new RPC/edge/workflow; no paid research/ads/Stripe/public registration; tenant isolation + RLS + exact-SKU
+ Product Asset Lock preserved; backend not applied to prod and frontend not published without separate
founder approval.

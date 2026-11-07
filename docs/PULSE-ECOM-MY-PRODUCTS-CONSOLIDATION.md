# Customer-Experience Consolidation — My Products → My Store (preview; awaiting approval)

Founder decision supersedes the Add-to-My-Products design. New journey:
**Product Discovery → View Product → Add to My Store → My Store → Manage Product → Create/Edit Product Page →
Publish when authorised.** Recommendations use the same journey. **Nothing published; no backend changed.**
Branch `claude/nifty-bardeen-f9nddu`. Preview HEAD commit `9da86c9` (built on `adc431e`).

## What changed (frontend preview only)
- **Nav (desktop + mobile)** — removed the "My Products" item from `app-sidebar.tsx` and `mobile-nav.tsx`
  (and the now-unused `Package` icon import). Ecommerce nav is now **Products · Recommendations · My Store · My
  Campaigns**. Commit `adc431e`.
- **Product drawer** — removed the "Add to My Products" button from the shared `ExplorerDrawer`
  (`product-explorer.tsx`) and deleted `add-to-my-products-button.tsx` + its test. The drawer's actions are now
  just `ProductCommerceActions`, with **Add to My Store** as the primary product action; locked actions
  unchanged. Commit `adc431e`.
- **Overview hub** — removed the "My Products" capability card from `GoldenStandardHub`
  (`ecommerce-workspace.tsx`) and its now-unused `useProductAcquisitions` import/queries. Five cards remain:
  Product Discovery, Opportunity Intelligence, **My Store**, My Campaigns, Market & Supplier Intelligence.
  Commit `9da86c9`.
- **Recommendations** — unchanged; its "View Product" opens the same `ExplorerDrawer`, so it now shows the same
  Add to My Store flow with no My Products entry point.

## Preserved (not changed)
- **Backend:** mig_332 + mig_333 (already deployed) untouched. `acquisition-api.ts`,
  `use-product-acquisitions.ts` (createAcquisition / get_own_product_acquisitions), and the My Products
  route/view remain in the codebase for internal compatibility — simply not surfaced in nav, the drawer, or
  the hub (reachable only by direct URL).
- **Identity / safety:** canonical product identity, selected country/market, supplier SKU, variant info,
  Product Asset Lock, tenant isolation, RLS — all unchanged (frontend-only, no data path touched).
- **No** billing / research-spend / advertising-permission / founding-member-registration changes.

## My Store handles product management without duplicates (verified in code)
- "Create Free Store" is offered only when the member has **no** hosted store; the server reports if a store
  "already existed" and adds the product to that existing store. The app never creates a store itself.
- "Add to My Store" shows "View in My Store" when the product is already present (no re-add). When the single
  product slot is taken, the server returns a "replace current product" path (replace + unpublish, not
  duplicate). Product pages come only from the server's add/replace steps; the app builds none.
- No code path creates a second hosted storefront or a duplicate product page from this flow. (App-side
  verification; server enforcement is the existing, approved commerce-actions backend.)

## Verification
- `9da86c9`: **489 tests pass** (71 files), `bunx tsgo --noEmit` clean, eslint clean on changed files,
  preview build OK. Nav tests assert My Products is absent (desktop + mobile) and order is Products →
  Recommendations → My Store → My Campaigns; hub tests assert 5 cards, no My Products card/link, My Store
  present → `/workspace/store`. Guard-scan of both diffs: no backend (no create-or-replace-function /
  service_role / functions.invoke / new .rpc).
- Not verifiable from the container (egress 403 + auth-gated): live signed-in appearance — founder device
  acceptance.

## PRODUCTION PUBLICATION (executed 2026-11-07, founder-approved)
1. Preview confirmed still at `9da86c94` (matches approval). ✅
2. No newer/unverified build had replaced it (agentFinished=true, last_edited 12:42:52). ✅
3. Rollback target preserved: prior production `01bf4f5a` (deploy `ce4bb212`). ✅
4–5. Published: `deploy_project` → deployment `80dcdb7d-f691-4bde-9aa9-330bf4c877b9`, target strateloq.com;
   `is_published=true`, published source `latest_commit_sha = 9da86c94`, status `ready`. ✅
6–8. Nav = Products → Recommendations → My Store → My Campaigns; My Products + Add to My Products absent from
   nav, drawer and hub; hub shows 5 cards incl. My Store — asserted by the test suite (nav + hub tests).
   LIVE signed-in confirmation = founder device acceptance (container egress 403 + auth-gated).
9–11. Add to My Store workflow + safeguards unchanged; Product Discovery, Recommendations, canonical identity,
   country isolation, supplier SKU correspondence, Product Asset Lock, tenant security preserved; mig_332,
   mig_333 and backend acquisition contracts NOT modified or rolled back. ✅
12. Regression: 489 tests pass, typecheck + lint clean, build OK; guard-scan of both diffs = no backend. ✅

## Status
- **Current production** still runs `01bf4f5a` (deploy `ce4bb212`), which still shows My Products + the Add
  button, until this consolidation is approved and published.
- **Awaiting founder approval** to publish preview `9da86c9`. After publish, stop and return control; the next
  planned task is Phase 01 verification. ChatGPT maintains the live Google Drive roadmap.

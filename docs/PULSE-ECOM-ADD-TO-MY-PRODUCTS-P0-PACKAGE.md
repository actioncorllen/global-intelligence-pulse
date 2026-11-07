# P0 — "Add to My Products" journey — PACKAGE (awaiting separate production approval)

Completes the journey **Product Discovery → Add to My Products → My Products → View Exact Product**, reusing
the existing acquisition system and canonical identity contract. Founder-approved gate approach:
**authorize on ownership**. **Nothing applied to prod; nothing published.** Branch `claude/nifty-bardeen-f9nddu`.

## 1. What ships
### 1a. Backend `mig_333_acquisition_ownership_authorization.sql` (prepared, NOT applied — commit `9155d8f`)
- Moves `create_product_acquisition`'s **canonical-id-first branch BEFORE** the `member_business_dna` /
  `is_ecommerce` gate, so acquiring one's **own** product authorizes on ownership alone
  (`commerce_products.user_id = auth.uid()`). The DNA/is_ecommerce gate is **preserved unchanged** on the
  legacy winning_product_intelligence path.
- Reason: verified in prod — no current owner (founder included) has a `member_business_dna` row, so the
  mig_332 ordering returned `not_ecommerce` for every owner, blocking the whole journey. Owning a discovered
  product is itself proof of ecommerce membership, so ownership is the correct authorization.
- Single `CREATE OR REPLACE FUNCTION`; no new identity generation; no title/URL/position/fuzzy inference;
  tenant isolation, exact-SKU, Product Asset Lock, market resolution intact. `get_own_product_acquisitions`
  and `fn_acquisition_primary_market` unchanged. Rollback: restore the mig_332 body (captured in git history).

### 1b. Frontend (Lovable preview `01bf4f5a`, NOT published)
- New `AddToMyProductsButton` in the shared `ExplorerDrawer` (Discovery/Recommendations entry), rendered
  ABOVE the existing `ProductCommerceActions` (which is unchanged).
- Reuses the existing `useCreateAcquisition` → `createAcquisition` → `create_product_acquisition`; passes the
  **exact canonical `productId`**. Membership ("In My Products" + a link to `/workspace/my-products`) is read
  from the own-acquisitions list, matched by **`productId` only** (never title/position); no duplicate create.
- States: active "Add to My Products"; "Adding…" (disabled) while pending; "In My Products" after
  created/exists; a calm inline "We couldn't add this to My Products just now." on failure (no crash).

## 2. Test results
- Frontend `01bf4f5a`: **496 tests pass** (72 files, +8 new for the button), typecheck clean, lint 0 errors on
  new files (4 pre-existing prettier errors + 6 warnings in product-explorer.tsx on untouched lines), preview
  build OK. New tests cover: exact-id create; in-my-products match-by-id (no duplicate); different/missing id
  not treated as added; created→toast+state; exists→state (no toast); failure→friendly message, no crash;
  pending→disabled "Adding…". Guard-scan: no new backend (no create-or-replace-function / service_role /
  functions.invoke / new .rpc).
- Backend `mig_333`: the canonical branch it relies on is already proven correct in prod (mig_332 authenticated
  fixture test: created product_id=5bc29d0a, market=DE; cross-tenant rejected; idempotent). mig_333 only
  **reorders** that branch ahead of the DNA gate — no new logic. Final owner-without-DNA create will be
  confirmed by a post-apply authenticated fixture smoke test (below), since mig_333 is not yet applied.

## 3. Post-apply verification (on approval) — full authenticated journey
1. Apply `mig_333`.
2. Authenticated fixture (controlled, cleaned up): as the founder (who owns products but has NO DNA row),
   call `create_product_acquisition('<owned commerce_products.id>')` → expect **created** (proving ownership
   authorization without a DNA row); `get_own_product_acquisitions` returns product_id + market; cross-tenant
   id → not created; discard/cleanup the fixture.
3. Publish the frontend `01bf4f5a`.
4. Founder device acceptance: Discovery → open product → Add to My Products → My Products shows it →
   View Product opens the exact product + market; unresolved never opens another product; country isolation
   and Product Asset Lock intact; no restricted commercial actions.

## 4. Known non-blocker (optional)
The app does not mount a `<Toaster/>`, so toast notifications (this button's and all existing ones) do not
display app-wide. This button does not rely on toasts — it shows inline state ("In My Products", "Adding…",
and the inline failure line). Mounting a `<Toaster/>` is a one-line layout change that would enable every
existing toast across the app; left for founder decision, not included here.

## 5. Guardrails
No new RPC/edge/workflow; no paid research/ads/Stripe/public registration; tenant isolation, RLS, exact-SKU,
Product Asset Lock, country isolation preserved; existing acquisition system reused, not duplicated. mig_333
not applied and frontend not published without separate founder approval.

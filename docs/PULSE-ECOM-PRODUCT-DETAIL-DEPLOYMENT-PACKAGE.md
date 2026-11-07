# Product Detail Integration — CONSOLIDATED DEPLOYMENT PACKAGE (awaiting final production approval)

One package covering the canonical-identity contract for My Products. **Nothing applied to prod; nothing
published.** Return for founder's final production approval.

Production project: Strateloq Technologies `nxaunmyihhjixxxljcqt`. Frontend: Lovable "Pulse Implementation"
`12db6c84-161b-4c23-aac4-e19e8cd24ab1`. Branch: `claude/nifty-bardeen-f9nddu`.

---
## 1. What ships

### 1a. Backend migration — `supabase/migrations/mig_332_my_products_canonical_product_link.sql`
Additive, reversible. Three parts:
- **Columns:** `product_acquisitions.product_id uuid` (FK → `commerce_products(id)` ON DELETE SET NULL) and
  `product_acquisitions.market text`. Both nullable.
- **`create_product_acquisition(text)` — canonical-id-first (the upstream identity propagation).** When the
  reference is a uuid-shaped `commerce_products.id` owned by `auth.uid()`, it stores that exact id as
  `product_id` and the product's primary evidenced `market`, building the snapshot from the live product row.
  No winning_product_intelligence dependency, no title/URL/position/fuzzy inference. The legacy
  winning_product_intelligence path is preserved unchanged, and there it stores ONLY an explicit, validated,
  owned `candidate.product_id`.
- **`fn_acquisition_primary_market(uuid,uuid)` — new helper** (SECURITY DEFINER, service_role-only EXECUTE,
  `search_path=''`, tenant-scoped): resolves a product's primary market — images → top video country →
  best opportunity-decision country → NULL. Needed because `media_assets`/`product_image_assets` have RLS
  enabled with no policies (readable only via SECURITY DEFINER).
- **`get_own_product_acquisitions()`** additively returns the stored `product_id` + `market`. Posture
  unchanged (SECURITY INVOKER, STABLE).

### 1b. Frontend (Lovable preview — verified dependencies, in order)
- `897d9727` — variant human name in the economics rows; TikTok per-video match-confidence + "observed
  performance, not verified sales" honesty labels (Tasks 2/5/6).
- `c9efb952` — My Products "View Product" reuses the exported `ExplorerDrawer` for the exact `productId`+
  `market` (`acquisitionToExplorerItem`, all metrics null — no fabrication); unlinked acquisitions show
  "Product details not available yet." and never open another product; decoder reads `product_id`/`market`.
Both are preview-only on the current published source; publishing is a separate gated step.

---
## 2. Why this design (architecture findings, read-only)
- Live Recommendations/opportunity identity flows through `product_opportunity_decisions JOIN commerce_products`
  (`fn_monday_top_opportunities`), which already carries the canonical `commerce_products.id`.
- `winning_product_intelligence` is EMPTY for all members and no DB function writes it; the legacy
  acquisition-creation path that reads it is dormant, no UI creates acquisitions, and `product_acquisitions`
  is empty. So the correct, minimal propagation is to make the acquisition workflow carry the canonical id
  directly (canonical-id-first), not to modify a dormant producer or re-derive identity.
- The member's catalogue products are `product_role='candidate'` with identity
  `candidate:'||fn_commerce_product_identity(url,pid,title,source)`; re-deriving it from a legacy candidate's
  title/URL is unreliable, so it is never attempted.

---
## 3. Test results
- **Frontend (Lovable preview `c9efb952`):** 488 tests pass (71 files), typecheck clean, lint 0 errors on
  changed files, preview build OK. Covers View-Product-opens-exact-product, unresolved state, no-fabrication
  seed, decoder null-safety. (Earlier `897d9727`: 483 pass, +8 for variant/TikTok labels.)
- **Backend (read-only simulation on prod — no writes):**
  - Canonical path finds owned products and resolves country-isolated market: Illuminated Snowman → **GB**,
    Beleuchtete Krippen → **DE**, Makita → **DE** (via opportunity-decision fallback, 0 media). Honest NULL
    where none.
  - **Cross-tenant denied:** a founder-owned product id queried under a different uid returns 0 rows → the
    canonical branch is skipped → no acquisition for another tenant's product.
  - `product_acquisitions` empty (0) → idempotency path exercised cleanly; no backfill needed.
- **Live execution of the new `create_product_acquisition` path** can only run after apply (the function isn't
  on prod yet); it is covered pre-apply by the above simulation + the frontend fixture tests. A post-apply
  fixture smoke test is listed in §6.

---
## 4. Production safety review (mig_332)
- **SQL vs live schema:** all referenced columns exist — `product_acquisitions`(id,user_id,source_run_id,
  state,winning_product_snapshot,sourcing_spec_snapshot,selected_supplier_snapshot,prepared_package,
  generated_content_id,missing_information,approved_at,created_at,updated_at + new product_id,market);
  `commerce_products`(id,user_id,title,product_url,source_store,source_run_id); `commerce_products.id` is the
  PK (FK target valid); `product_opportunity_decisions`(tenant_id,product_id,country_code,
  product_opportunity_score); media tables as used.
- **SECURITY DEFINER / ownership:** `create_product_acquisition` stays SECURITY DEFINER, VOLATILE, owner
  `postgres`, `search_path=''` (unchanged). `get_own_product_acquisitions` stays SECURITY INVOKER, STABLE
  (unchanged). New `fn_acquisition_primary_market` is SECURITY DEFINER with `search_path=''`, EXECUTE revoked
  from PUBLIC/anon/authenticated and granted only to service_role (callable only from the DEFINER
  create_product_acquisition). No privilege elevation of any existing function.
- **RLS / tenant isolation:** every read/write is scoped to `auth.uid()` (create) or the owner uid passed
  through (helper); cross-tenant denial verified. Adding columns does not alter existing RLS.
- **Nullable FK compatibility:** `product_id` nullable FK → `commerce_products(id)` ON DELETE SET NULL; a
  deleted product degrades an acquisition to unresolved, never dangling.
- **Idempotency / guards:** `ADD COLUMN IF NOT EXISTS` ×2, `CREATE OR REPLACE FUNCTION` ×3, `COMMENT` — all
  safely re-runnable. plpgsql control flow fixed to gate the canonical branch on an explicit flag
  (`v_canon := FOUND` right after the lookup; uuid-shape regex guards the cast).
- **No unrelated production changes:** only the two columns, two function replacements, and one additive
  helper. No discovery/recommendation logic touched. No grants widened. No data modified.

---
## 5. Rollback plan
```sql
-- Reverse mig_332 (safe; product_acquisitions is empty):
ALTER TABLE public.product_acquisitions DROP COLUMN IF EXISTS product_id;
ALTER TABLE public.product_acquisitions DROP COLUMN IF EXISTS market;
DROP FUNCTION IF EXISTS public.fn_acquisition_primary_market(uuid, uuid);
-- Restore prior bodies of create_product_acquisition(text) and get_own_product_acquisitions()
-- (captured verbatim pre-migration; both are the versions currently live on prod).
```
Frontend rollback: re-publish the previously-published source commit (`ae2d91b8`) — frontend-only, no backend
coupling. The new frontend degrades safely without the backend (every acquisition shows the unresolved state),
so frontend and backend can be applied/rolled back independently.

---
## 6. Recommended apply order (on approval) + post-apply smoke test
1. Apply `mig_332` (single transaction).
2. Re-run the read-only checks in §3 (now against the deployed functions).
3. One fixture smoke test (controlled): create a fixture acquisition for an owned product via
   `create_product_acquisition('<owned commerce_products.id>')` as that member, assert `product_id` +
   `market` stored, `get_own_product_acquisitions` returns them, then discard the fixture. (Prod has no real
   acquisitions, so this is additive and reversible.)
4. Publish the frontend (`c9efb952`) once backend is confirmed.
5. Founder live acceptance on device: Discovery → View Product (exact product), My Products → View Product
   (exact product + market), unresolved item never opens another product.

---
## 7. Open items / follow-ups (not blockers)
- **No UI creates acquisitions today.** My Products will stay empty until an "Add to My Products" action is
  wired (a separate product decision). The canonical-id-first workflow is ready to receive the canonical id
  (`commerce_products.id`) from whatever entry point is added. Flagged for a separate change.
- Guardrails honored throughout: no paid research/ads/Stripe/public registration; Product Asset Lock,
  exact-SKU identity, country isolation and existing architecture preserved.

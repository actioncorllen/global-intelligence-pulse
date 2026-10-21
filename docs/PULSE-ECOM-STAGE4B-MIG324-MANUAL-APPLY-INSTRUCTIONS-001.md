# PULSE-ECOM-STAGE4B-MIG324-MANUAL-APPLY-INSTRUCTIONS-001

**mig_324 is ready for safe manual execution via the Supabase Dashboard SQL Editor. It was NOT executed by
Claude (no working write path in-container). Run it yourself when ready; it is one atomic transaction that
changes nothing on failure, and never touches genuine supplier data.**

## Why manual
Both Supabase MCP write routes (`execute_sql`, `apply_migration`) time out; there is no Supabase CLI, DB
credential, DB network egress, or CI pipeline in the session container. The reliable remaining route is the
Dashboard SQL Editor, which runs with elevated DB privileges from your browser session.

## The file to run
`supabase/manual/mig_324_dashboard_apply.sql` — self-contained, wrapped in a single `BEGIN … COMMIT`, with a
PRECHECK (dependencies present) and a POSTCHECK (functions created + fixtures gone). It is generated from and
byte-identical in its function bodies to the committed migration
`supabase/migrations/mig_324_cross_supplier_identity_safe_tests_card.sql`.

What it deploys (prereq `mig_323` is already live on project `nxaunmyihhjixxxljcqt`):
1. `fn_cross_supplier_evidence` — pure in-memory evidence engine (no DB reads/writes).
2. `fn_cross_supplier_identity_selftest` — transaction-safe regression suite (writes to **no** supplier
   records; positive case = deployed resolver read-only, negatives = inline candidates through the engine).
3. `fn_product_supplier_candidate` — customer Product-Card companion read. **Tenant isolation:** it takes
   the caller's tenant from `auth.uid()` (the `p_tenant` argument is never trusted) and verifies product
   ownership, so a signed-in user can only read their own tenant's candidate.
4. Deletes the three synthetic fixtures — `SELFTEST_SKINCARE`, `SELFTEST_BALACLAVA`, `SELFTEST_SIGN` — by
   **exact id only**, with an extra `!~ '^[0-9]+$'` guard (genuine CJ pids are all-numeric, so a genuine
   row can never match). No other data is touched.

## Execute (Dashboard SQL Editor)
1. Open the Supabase Dashboard → project **`nxaunmyihhjixxxljcqt`** (Global Intelligence Pulse) → **SQL
   Editor** → **New query**.
2. Paste the **entire** contents of `supabase/manual/mig_324_dashboard_apply.sql`.
3. **Run**.

## Success looks like
- The Messages/Notices pane shows `PRECHECK OK: …` and `POSTCHECK OK: 3 functions created; synthetic
  fixtures removed.`
- Final result: **Success / COMMIT** (no rows returned). Everything committed atomically.

## How to identify a FAILURE (and what it means)
- **Any red ERROR** ⇒ the transaction **rolled back**; the database is unchanged (safe to fix and re-run).
- `PRECHECK FAILED: mig_323 dependencies missing` ⇒ mig_323 is not applied on this project. Apply mig_323
  first, then re-run.
- `POSTCHECK FAILED: … function(s) were not created` or `… synthetic fixture row(s) still present` ⇒ a
  statement did not take effect; nothing was committed. Capture the error text and report it.
- A dollar-quote / syntax error ⇒ the paste was truncated; re-copy the whole file and re-run.
- Because it is one transaction, there is **no partial state** to clean up after a failure.

## Verify AFTER a successful COMMIT (run each query separately)
- **A) Regression suite** — expect `{"ok":true,"failed":0,...}` (6 cases, or 5 if the snowman fixture
  product is absent):
  `SELECT public.fn_cross_supplier_identity_selftest();`
- **B) Real ski-mask association** — expect `SAME_PRODUCT_IDENTITY / MEDIUM / 8 / 35 / false`:
  ```sql
  SELECT identity_tier, confidence, corresponding_variant_count, total_variant_count, variant_verified
  FROM public.commerce_cross_supplier_identity
  WHERE opportunity_product_id='56a6af36-68f7-4138-9d29-941245f266b2'
    AND supplier_product_id='2609290358281623700';
  ```
- **C) Fixtures removed** — expect `0`:
  `SELECT count(*) FROM public.commerce_supplier_products WHERE source_product_id LIKE 'SELFTEST_%';`
- **Companion read note:** `fn_product_supplier_candidate(...)` returns
  `{"present":false,"status":"unauthorized"}` when called in the SQL Editor (no signed-in `auth.uid()`) —
  that is the isolation guard working as designed. Verify its underlying data with query (B); it returns the
  real candidate only when called by the signed-in owner via the app / an edge function that forwards the
  user JWT.

## After it is applied
- The backend association is already persisted (query B). The next step (separate, not part of this file) is
  to wire the Product Intelligence UI to call `fn_product_supplier_candidate` so the signed-in Product Card
  shows the CJ candidate at **MEDIUM** confidence with **8** corresponding old-man-face variants and
  **reference-only** media rights (`advertising_cleared=false`). Until then the card shows the honest strict
  `NO_VALID_CJ_MATCH`.

## Guardrails honoured
Read-only review only — Claude did not execute this, retry the MCP write routes, use any broad DELETE, or
change production data. No paid calls, no AliExpress activation, no later stages.

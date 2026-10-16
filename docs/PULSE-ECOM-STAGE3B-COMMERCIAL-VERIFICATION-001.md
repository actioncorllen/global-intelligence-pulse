# PULSE-ECOM-STAGE3B-COMMERCIAL-VERIFICATION-001

**Stage 3B — country-specific Supplier Commercial Verification + Market/Competitor Pricing
(`mig_303`). Reuse-first (no working component rebuilt). Gated on a genuine Stage-2 binding;
fixtures can never be counted as commercial validation; the $25–$30 contribution target and ~$10
ad reserve are display/recommendation only and never block. PASS — `fn_stage3b_commercial_verification_selftest`
16/16. No live/paid calls; no supplier binding, store change, publishing or asset acquisition.**

## Real-product eligibility (today)
No genuine persisted `EXACT_SUPPLIER_IDENTITY_RESOLVED` with `bound=true` exists for any real
product (`commerce_concrete_supplier_resolution` holds only `NO_VALID_CJ_MATCH / bound=false`
rows). Therefore **commercial verification is BLOCKED for all real products** — e.g. the Krippen
product (DE) returns `state=BLOCKED_NO_BINDING`, `persisted=false`, and the verification table has
**0 rows**. Stage 3B is proven with deterministic fixtures only; nothing real is validated.

## What was built (one migration, all `SECURITY DEFINER`, `search_path=''`, definer-only grants)
- **Table `commerce_commercial_verification`** — one row per `(tenant, product, market)`; states
  `PENDING / PARTIAL / FAILED / COMMERCIALLY_VALIDATED`; `evidence_grade REAL|FIXTURE`; evidence,
  freshness, blockers. A DB CHECK makes `COMMERCIALLY_VALIDATED` impossible when
  `is_fixture=true` or `evidence_grade<>'REAL'` (belt-and-suspenders for the fixture rule). RLS on,
  no permissive policy (definer-only), same posture as `product_market_competitors`.
- **`fn_stage3b_market_currency(market)`** — country→currency from `ecommerce_market_universe`
  (18-market authoritative), with safe fallbacks.
- **`fn_stage3b_market_pricing(tenant, product, market, ccy?, competitors?, freshness_hours, now)`**
  — country+currency-isolated observed pricing. Reuses `fn_pmc_evaluate` for the engine aggregate
  (competition/median/range) and adds per-competitor display (seller name, product link, currency,
  timestamp, source, evidence class), **seller dedup**, **exact vs similar** split, and
  **average / lowest / highest / median** over the identical local filter (`EXACT_PRODUCT` /
  `CLOSE_COMPARABLE`, local country, local currency, `OBSERVED`/`PLATFORM_REPORTED`). Foreign,
  converted, non-observed and stale prices are excluded and counted, never silently used. Missing /
  stale / insufficient → `status=UNKNOWN` with a reason; prices are never invented; another
  country's prices are never reused as local evidence.
- **`fn_stage3b_unit_economics(supplier, market_price, ccy, fees?, ad_reserve=10, target_min=25,
  target_max=30, observed_low?, observed_high?)`** — reuses `fn_supplier_economics` (landed =
  supplier cost + shipping; shipping never assumed 0; FX fail-closed), `fn_candidate_pricing_economics`
  (MARKET_LED contribution/band, founder ad-reserve/target passed as parameters — defaults
  unchanged), and `fn_economics_breakeven` (fee-aware). Emits landed cost, fees, projected
  contribution, band, `meets_target`, break-even CPA, and an **evidence-based suggested
  selling-price range** anchored to the observed competitor range (`EVIDENCE_BASED` /
  `TARGET_ABOVE_MARKET` / `UNKNOWN`). Contribution/target are recommendation-only.
- **`fn_stage3b_verify_commercial(...)`** — orchestrator. Gate (genuine EXACT + bound, real or
  inline-fixture); assembles supplier SKU/variant/cost/availability/shipping/delivery (real: from
  `commerce_supplier_products` + freight enrichment via `fn_supplier_delivery_state`; fixture:
  injected); computes economics + market pricing; decides state. **FAILED is supplier-side only**
  (confirmed out-of-stock / unsupported delivery) — never economics/contribution. Persists
  country-specific results with evidence + freshness when `persist=true`.
- **`fn_stage3b_product_card(tenant, product, market)`** + `_authenticated(product, market)` wrapper
  — composes the authoritative identity card (`fn_ad_product_card_authority`, **unchanged** →
  Product Asset Lock preserved) with the commercial-verification state, economics summary, market
  pricing, suggested price range, and clear next-step actions.

## States
`BLOCKED_NO_BINDING` (gate, not persisted) · `PENDING` (binding, awaiting supplier detail) ·
`PARTIAL` (incomplete/stale, or any FIXTURE evidence) · `FAILED` (out-of-stock / unsupported
delivery) · `COMMERCIALLY_VALIDATED` (REAL + complete + fresh + bound; contribution band displayed
but never gates). `COMMERCIALLY_VALIDATED` is unreachable with fixture evidence by construction and
by DB CHECK.

## Integrity preserved
Tenant isolation (`user_id` ownership) · 18-market country isolation (prices never cross markets) ·
exact-product matching (`fn_market_supplier_match` via Stage-2, untouched) · Product Asset Lock
(`fn_ad_product_card_authority` SUPPLIER_PROVIDED invariant, untouched). No minimum profit / fixed
ad cost / margin threshold can block discovery or supplier verification (msg2 #8) — verified by
selftest S6/S7. No existing component was modified; only new `fn_stage3b_*` functions and the new
table were added.

## Verification
`fn_stage3b_commercial_verification_selftest()` → **16/16** (hermetic inline fixtures, no provider
calls, no persistence): gate-blocks-no-binding, fixture-never-validated, FAILED on out-of-stock and
on unsupported delivery, shipping-unknown→PARTIAL (never assumed 0), UNVIABLE-does-not-block,
target-never-gates, pricing country+currency isolation + dedup + exact/similar, no cross-country
reuse, stale→UNKNOWN, no-evidence→UNKNOWN, break-even consistency, evidence-based suggested price
(+ honest TARGET_ABOVE_MARKET), tenant isolation, card cross-tenant rejection, stale-supplier
never-validated. Real-product gate confirmed on Krippen (DE → BLOCKED_NO_BINDING, 0 rows persisted).

## Remaining blockers
- **No real product is eligible** until Stage 2 produces a genuine `EXACT…bound=true` (CJ live
  retrieval currently yields no exact Krippen match). Commercial validation stays blocked for real
  products by design.
- Real-mode supplier evidence assembly reads `commerce_supplier_products` (cost/variants + freight
  enrichment). Live CJ product-detail/stock/freight refresh (n8n workflow `OxH9sb6jKCqiqXOk`) is a
  paid/live step and was **not** run here; a real COMMERCIALLY_VALIDATED transition requires that
  fresh supplier evidence plus local competitor price observations.
- Not wired into the existing lifecycle overlay's `commercially_validated` display flag (produced by
  the out-of-repo `fn_stage1_early_opportunity_state`); Stage 3B is the authoritative source and
  exposes its own reader/card. Wiring the overlay to read `commerce_commercial_verification` is a
  follow-up. Stage 4 not started.

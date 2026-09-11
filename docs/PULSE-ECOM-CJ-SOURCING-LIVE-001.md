# PULSE-ECOM-CJ-SOURCING-LIVE-001

**VERDICT: PARTIAL.** The founder-authorized `product/sourcing/create` was executed **once** against the
live CJ API with the existing credential. CJ **validated and rejected** it with `productImage must be not
empty` — i.e. the create endpoint is **reachable and authorized**, and its exact required-field schema is now
known, but **nothing was created** (no sourceId, no charge, no duplicate). Completing the create needs a
**legitimate reference image** of the product to source. Per the locked guardrails (never fabricate/manufacture
product images; §11 "do not generate substitute images"; counterfeit/IP-risk exclusion), I did **not**
fabricate an image or point CJ at a specific branded product — supplying a rights-clear generic reference image
is a **founder input**. `CJ_SOURCING_PENDING`-style completion therefore awaits that one input.
No purchase, no sample, no inventory, no charge, no store/ads/campaign/spend.

## 1. Locked Product×Country
**Nitro Cold Brew Maker × United States** (LOW saturation ≈201, economic ceiling €49.16, strong
differentiation) — reused from PULSE-ECOM-DIFFERENTIATED-PREMIUM-OPPORTUNITY-001. Not replaced.

## 2. Final sourcing specification (used in the create + stored in provenance)
- product noun: nitro cold brew maker / nitro coffee dispenser / nitro brewer
- required subtype: genuine **nitrogen infusion** + cold brew
- required features: nitrogen infusion mechanism (widget/pump/aerator), dispense tap, reservoir ≥1 L, reusable
- excluded: ordinary cold-brew bottle/pitcher/mesh-filter, milk frother, plain coffee maker, beer-only keg,
  "cold brew" wording without nitro
- preferred: pump/electric aerator (avoid pressurized gas cartridge shipping); <1.2 kg; US warehouse
- economics: max landed €49.16; target purchase ≤ $30
The remark sent to CJ explicitly demanded a GENERIC true-nitro maker and excluded the substitutes above.

## 3–5. Create endpoint, authorization, result
- Endpoint: `POST https://developers.cjdropshipping.com/api2.0/v1/product/sourcing/create` (existing
  credential; token never printed).
- Authorization: founder-authorized ONE create (creation only). Idempotency: pre-check found 0 open
  nitro/US request; single manual execution; `cj_sourcing_requests` has `source_id UNIQUE` + partial unique
  index on open (concept,market).
- **Result (exec 30157):** `code 1600300, result:false, message:"productImage must be not empty"` →
  HTTP 400 **validation reject before creation**. Create endpoint reachable + authorized; **no request created**.

## 6. sourceId
**None** — request not created (validation rejected). No sourceId to query.

## 7–8. Provider status / normalized Pulse status
Provider: `1600300 productImage must be not empty` (field validation).
Pulse lifecycle: **`AWAITING_REFERENCE_IMAGE`** (pre-submit; recorded in `cj_sourcing_requests` id
`6df1bd54…`). Not SUBMITTED/PENDING (nothing was accepted by CJ yet).

## 9. Duplicate / idempotency protection
`cj_sourcing_requests` (mig_222): `source_id UNIQUE`; partial unique index
`uq_cj_sourcing_open_concept_market` blocks duplicate SUBMITTED/PENDING/SOURCED rows per concept+market.
Pre-create check ran (0 open). One create attempt only; **no retries** after the ambiguous/blocking result
(per §5/§8). A validation reject creates nothing, so no duplicate risk.

## 10–13. Purchase safety (asserted)
`supplier_purchase = FALSE` · `sample_purchase = FALSE` · `inventory_purchase = FALSE` ·
`paid_sourcing_charge = FALSE`. CJ presented **no charge** (validation error only). Not a payment blocker.

## 14–34. Downstream evidence (CJ PID/VID/SKU, identity, assets, stock, freight, economics, WPS, confidence)
**Not reached** — no product was sourced (create not completed). No downstream evidence fabricated. The
existing chain (SUPPLIER_EXACT → market↔supplier identity → assets → stock-by-VID → US freight → landed
economics → WPS) is ready to run the moment a real sourced CJ PID exists.

## 35. TEST gate
**Not evaluated** (no sourced product). HIGH-CONFIDENCE standards unchanged and not applied.

## 36. Sourcing lifecycle proof
Proven this unit: **Pulse opportunity → approved spec → live create call → CJ field-validation (endpoint
authorized) → provenance recorded.** Also proven earlier (unit -001): read-only `product/sourcing/query`
authorized. **Not yet proven:** create acceptance → sourceId → sourced product → validation chain — blocked
only on the required reference image.

## 37. CJ automation classification
`CJ_SOURCING_PARTIALLY_API_AUTOMATABLE` (create endpoint + auth + required-field schema now empirically
known: `productName` + **`productImage` (required)** at minimum; further required fields may surface once an
image is supplied). Upgrades to FULLY once one create completes with a valid image.

## 38. BigBuy / architecture
CJ sourcing kept **inside the CJ provider adapter**; `cj_sourcing_requests` is CJ-scoped and **not** added to
the universal supplier contract. `CJ = ACTIVE · CJ_SOURCING = ACTIVE EXTENSION (create authorized, needs
image) · BIGBUY = DEFERRED_MONTH_END/PLANNED · ALIEXPRESS_DIRECT = DEFERRED_CONNECTION · FUTURE_PROVIDERS =
EXTENSIBLE`. No BigBuy redesign implied.

## 39–45. Production-scan / cost-control acceptance check
1. Schedules inspected: YES.
2. New recurring schedules created: **NO** (no sourcing/market polling schedule created).
3. Existing production cadence changed: **NO** (Monday orchestrator + FX daily untouched).
4. Manual test executions: 1 (exec 30157, single create attempt) — manual trigger, `active:false`.
5. API/query counts: CJ = 1 auth + 1 sourcing/create (validation-rejected). Supabase = 1 migration + 1 insert
   + reads. No continuous polling; no second create.
6. Test cost: €0 (no CJ points consumed for a rejected create beyond auth; no paid provider).
7. Monday-only production policy preserved: **YES.**

## 46. External blockers
Not a payment blocker (no charge). The stop is a **required content input**: create needs a legitimate,
rights-clear, generic reference image. Classified as `AWAITING_REFERENCE_IMAGE` (founder input), not
`BLOCKED_EXTERNAL_CJ_SOURCING_PAYMENT_REQUIRED`.

## 47–48. Campaign safety / spend
No store/publication/Ad Studio/campaign/activation. `campaign_activation = FALSE`, `advertising_spend = 0`.

## 49. Tests
Live create call proved endpoint reachability + credential authorization + required-field schema
(productImage mandatory); read-only query authorization proven in prior unit; idempotency guard in place;
no mutation completed; no fabricated evidence.

## 50. Git
mig_222 mirrored; doc added. Secret-scanned (no token printed), pushed to `claude/pulse-crash-recovery-b6ngey`;
remote == local, divergence 0 0.

## 51. Paid-beta readiness
≈ **89%** (unchanged): sourcing create is authorized and one field-input away from completing; no supplier #2
spend needed.

## 52. EXACT NEXT ACTION (founder — choose one)
The create needs one legitimate reference image (rights-clear, **generic** true-nitro maker — not a branded
uKeg/NitroBrew clone). Either:
1. **Provide/approve a specific reference image URL** (publicly fetchable by CJ) for a generic nitro cold brew
   maker; Pulse resubmits the single create (same spec), captures the `sourceId`, runs one status query, and
   records the lifecycle — no purchase. OR
2. **Submit via the CJ dashboard** using the exact spec above (upload an image there); then hand Pulse the
   resulting `sourceId`/product and Pulse runs the existing SUPPLIER_EXACT → stock → US-freight → landed →
   WPS chain to a decision.
Either path keeps CJ as Supplier #1; BigBuy remains deferred to month-end.

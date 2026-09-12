# PULSE-ECOM-CJ-SOURCING-REFERENCE-IMAGE-001

**VERDICT: PARTIAL. OUTCOME: `MANUAL_CJ_IMAGE_UPLOAD_REQUIRED`.**
A bounded lookup of already-observed evidence found **no rights-clear, product-accurate reference image** for
a genuine nitro cold brew maker, and none can be resolved from public sources without either instructing CJ
to clone a **branded/patented** product (uKeg / NitroBrew / GrowlerWerks) or **misrepresenting** the product
(a non-nitro image / a beverage photo). Per §3/§5 I **stopped API creation** rather than substitute a
questionable image. **No replacement create was executed. No sourceId. No purchase. No charge.**

## 1. Existing evidence inspected (bounded lookup, no discovery)
- **Demand** (`market_price_observations`, nitro × US): provenance holds only `{"probe":"30153"}` — **no image
  URL, no product URL** (the eBay summariser stored price aggregates only).
- **Supplier** (`commerce_supplier_products`, CJ nitro category discovery exec 30154): candidates **all have
  images but none is a nitro maker** — juicers, grinders, milk frothers, toasters, beverage dispensers, cold
  dishes (`is_nitro = false` for every row). Their images would **misrepresent** the product.

## 2. Candidate reference image found
**NO.**

## 3. Image source
None usable. Public sources for actual nitro makers resolve to **branded/patented products** (uKeg,
NitroBrew, GrowlerWerks) or, on Wikimedia, only a **beverage photo** (the drink, not the appliance).

## 4. Product identity match
No available image both (a) depicts a genuine generic nitro cold brew maker and (b) is rights-clear for use
as a sourcing reference.

## 5. Branding / IP assessment
Using a branded nitro-maker image would instruct CJ to reproduce a **proprietary/patented** product
(counterfeit/IP-clone risk — a locked guardrail). De-branding an image is prohibited (§3). Generating a fake
image is prohibited (§3, and locked intent "never fabricate/manufacture product images").

## 6. Permitted sourcing-reference assessment
No image met the bar: it must be a legitimate reference for a **generic** true-nitro maker with establishable
usage rights. None available.

## 7. Image classification
**NOT `REFERENCE_IMAGE_ACCEPTABLE`.** No provenance stored as an asset; nothing promoted to any Store/Ad
asset library.

## 8. Manual dashboard required
**YES → `MANUAL_CJ_IMAGE_UPLOAD_REQUIRED`.**

## 9. Open-request precheck
`cj_sourcing_requests`: the prior attempt row (`6df1bd54…`) is status `AWAITING_REFERENCE_IMAGE` — **not** an
open CJ request (not SUBMITTED/PENDING/SOURCED), so it does not block a future real create and is not treated
as an open CJ request. No accepted/open sourcing request exists for nitro × US. Row updated with this unit's
lookup conclusion; still no sourceId.

## 10–16. Replacement create / response / downstream
**Create executed: NO** (gated on §5 image failure). CJ response: N/A (no call made). sourceId: none.
Status query count: 0. Returned CJ PID: none. Downstream validation (SUPPLIER_EXACT → stock → US freight →
landed → WPS): not run — no product sourced; no fabricated evidence.

## 17–18. Purchase / charge status
`supplier_purchase = FALSE` · `sample_purchase = FALSE` · `inventory_purchase = FALSE` ·
`paid_sourcing_charge = FALSE`. No CJ mutation attempted this unit → no charge possible. Not a payment blocker.

## 19–21. Production-scan acceptance check
- Recurring schedules created: **NO**.
- Production cadence changed: **NO** (Monday orchestrator + FX daily untouched).
- Monday-only production policy preserved: **YES**. This was a manual acceptance step (in fact, no external
  call was made — evidence lookup + safety determination only).

## 22–23. API calls / cost
CJ API calls this unit: **0** (stopped before any create). Supabase: bounded reads + 1 provenance update.
Test cost: **€0**. No discovery scan run.

## 24. Blockers
`MANUAL_CJ_IMAGE_UPLOAD_REQUIRED` — a rights/safety stop with a clean manual path, **not** an external system
failure and **not** a payment blocker.

## 25. Git
Doc committed (no schema/code change; mig_222 already in place). Secret-scanned; pushed to
`claude/pulse-crash-recovery-b6ngey`; remote == local, divergence 0 0.

## 26. Paid-beta readiness
≈ **89%** (unchanged). CJ sourcing create is authorized and one legitimate reference image away from
completing; the only open item is a founder image choice, which is safest made in the CJ dashboard.

## 27. EXACT NEXT ACTION (founder — the exact CJ dashboard step)
Because the API's `create` requires a `productImage` that Pulse cannot legitimately select on the founder's
behalf without risking branded-clone/misrepresentation, submit the request **manually in CJ** (the founder
controls the image + its rights):
1. CJ Dropshipping dashboard → **Sourcing** → **Post Sourcing Request** (`cjdropshipping.com/sourcing`).
2. **Product name:** "Nitro Cold Brew Coffee Maker (nitrogen-infused cold brew dispenser, home countertop)".
3. **Reference image:** upload a photo of a **generic** true-nitro maker the founder is comfortable using
   (avoid a branded uKeg/NitroBrew clone). Optionally add a reference product URL.
4. **Description/remark (paste Pulse's spec):** genuine nitrogen infusion (widget/pump/electric aerator);
   dispense tap; reservoir ≥1 L; reusable. NOT an ordinary cold-brew bottle/pitcher/mesh-filter, milk frother,
   plain coffee maker, or beer-only keg. Prefer pump/electric aerator (avoid pressurized gas cartridges);
   weight <1.2 kg; prefer US warehouse; target purchase cost ≤ $30 (max landed ≈ €49).
5. Submit (free; nothing purchased) → send Pulse the resulting **sourceId / product link**.

Then Pulse resumes automatically: record the sourceId in `cj_sourcing_requests` (status SUBMITTED/PENDING),
run one `product/sourcing/query`, and on SOURCED push the returned CJ PID through the existing
SUPPLIER_EXACT → stock-by-VID → US-freight → landed-economics → WPS chain to a HIGH-CONFIDENCE decision.
Alternatively, provide Pulse a specific rights-clear generic reference-image URL and it will run the single
authorized API create instead. CJ remains Supplier #1; BigBuy stays DEFERRED_MONTH_END.

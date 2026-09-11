# PULSE-ECOM-CJ-CANONICAL-DISCOVERY-001

**VERDICT: PASS. OUTCOME: B (no qualified TEST — honest, and acceptable per PASS criteria).**
**Provider-capability verdict: CJ_KEYWORD_RETRIEVAL_GAP_CONFIRMED** (with a narrow per-concept
catalogue-coverage signal for one product). Category-scoped provider-native discovery surfaced
**STRONG_SAME_PRODUCT** products that the old keyword path missed entirely — so the prior "0 matches"
was substantially a **retrieval-method** failure, not proof the products are absent from CJ. The one
identity survivor taken to final economics fails on **stock + weight-driven freight**, not on identity.
No second supplier integrated. No store/ads/campaign/spend.

## 1. CJ discovery capabilities audited
Under the current credential (`2IV5tXPu9jAItjKh`), CJ v2 exposes: `product/getCategory` (category
tree), `product/list` (keyword `productNameEn`, **and** `categoryId` filter — the untested lever),
`product/query` (pid → variants/sku/barcode/images/category), `product/stock/queryByVid`,
`logistic/freightCalculate`, `product/comments`. No new account/credential needed.

## 2. Existing capabilities reused
- `product/getCategory` proven by repointing the existing enrichment probe (`ZbhPyAuvDD4h4xid`) — one
  node URL change, reversible.
- Category-scoped `product/list` by adding a `categoryId` query param to the existing collector
  (`NvuwUfW7fyjSb81R`) — no new workflow.
- `product/query` + stock + freight via the existing detail chain (`OxH9sb6jKCqiqXOk`).

## 3. Workflow changes
Collector `NvuwUfW7fyjSb81R`: added `categoryId` param + category+noun query list. Probe
`ZbhPyAuvDD4h4xid`: query node repointed to `getCategory`. Detail chain `OxH9sb6jKCqiqXOk`: PIDs set to
turntable finalists. All manual, no schedules touched. Schema: **mig_221** (classifier bugfix, below).

## 4. Provider-native endpoint(s)
`product/getCategory` (category tree) and `product/list?categoryId=…&productNameEn=…` (category-scoped
search) — distinct from the prior all-catalogue keyword path.

## 5. Real capability proof
`getCategory` (exec `30138`) returned the real 14-top-level tree. Target leaf categories obtained:
Night Lights `538CB48E-…`, Kitchen Appliances `A028998B-…`, Home Audio & Video `D6C23AAE-…`, Garden
Tools `CDB10A90-…`. **Notably CJ's taxonomy has no "hydroponics/indoor-garden" category and no
"turntable/record-player" category** (turntables live under Home Audio & Video).
`product/query` canonical round-trip proven on real data (exec `30140`): pid `2412170349071602700` →
returned `data.pid = 2412170349071602700` with 6 variants, variantSku `CJYD224571504DW`, barcodes,
images, category — **SUPPLIER_EXACT**.

## 6–8. Target concepts, markets, ceilings, discovery, classifications
Reused the prior unit's economic survivors (no new products invented). Category+noun discovery
(exec `30139`, 8 queries) then `fn_market_supplier_match` (title-scoped, mig_221):

| Concept | Category | Market | Ceiling € | keyword-path STRONG (prev unit) | **category-path STRONG** |
|---|---|---|---|---|---|
| bluetooth turntable | Home Audio & Video | GB | 39.88 | 0 | **7** |
| gooseneck kettle | Kitchen Appliances | GB | 25.70 | 0 | 0 (14 CLOSE — plain kettles, cheaper subtype) |
| levitating moon lamp | Night Lights | GB/US | 34.45 / 20.87 | 0 | 0 (15 CLOSE — ordinary lamps) |
| smart herb garden | Garden Tools | GB/US | 37.25 / 17.52 | 0 | 0 (12 CLOSE) |

The turntable result — **7 STRONG_SAME_PRODUCT** where the keyword path found **0** — is the core
proof of the retrieval gap. The classifier held the line elsewhere: plain electric kettles stayed
CLOSE (a cheaper commercial subtype than the €63 gooseneck the price reflects); Night Lights held no
levitating moon lamp.

## Bug found & fixed (mig_221) — FIX → REGRESSION TEST → CONTINUE
Category-scoped discovery exposed a real classifier defect: `fn_market_supplier_match` matched the
product noun against `title || category`, so the department word "garden" in the taxonomy path
"Home, Garden & Furniture" promoted a **"24-inch Moss Pole for Plants"** to STRONG_SAME_PRODUCT.
Fix: match product noun / subtype / attrs against the **supplier title only**; excluded subtypes still
scan title+category. Regression after fix: **11/11 prior cases + the moss-pole case = 12/12 PASS**;
the 7 genuine turntable STRONG matches preserved; herb-garden false positive eliminated (→ UNRELATED).

## 12–14. Canonical PIDs, product/query confirmations, supplier canonical identity
Turntable finalist pid `2412170349071602700`: product/query confirmed same pid + 6 variants →
`fn_supplier_canonical_identity` = **SUPPLIER_EXACT** (`CJ_PID_CONFIRMED_BY_PRODUCT_QUERY_AND_SUBTYPE`).
(Two cheaper turntable pids returned no variants on product/query — delisted/unavailable.)

## 17–21. Stock, warehouse, freight, landed, ceiling comparison (turntable × GB)
| Field | Value |
|---|---|
| Supplier cost | $33.00 = €28.41 |
| Variant | Walnut-EU `2412300919011606500`, 3,320 g |
| **Stock** | cjInventoryNum **0** / factoryInventoryNum **8,957** (China Warehouse) → **OUT_OF_STOCK** (factory-only) |
| GB freight (cheapest) | ~$41.16 CJPacket Special line (≈ $45.48 YunExpress) = €35.4–39.2 |
| **Landed (GB)** | ≈ **€63.8** |
| MAX_ACCEPTABLE_LANDED_COST (GB) | €39.88 (c15) / €34.88 (c20) |
| Margin to ceiling | **−€23.9** |

## 22. Advertising Headroom
Net revenue €77.30 − landed €63.8 = **€13.5 contribution before ads** — below even the €15 ad reserve.
Break-even CPA €13.5; at €10/€15/€20 target CPA the campaign is unviable. **Advertising Headroom
negative.** (Heavy 3.3 kg item → freight, not product cost, is what breaks the economics.)

## 23. Product Confidence
**Not HIGH.** Two independent hard-gate failures: OUT_OF_STOCK (CJ ready-to-ship 0) and negative
landed economics. Identity was strong (SUPPLIER_EXACT + STRONG_SAME_PRODUCT) but identity alone never
grants HIGH.

## 24–26. Final decisions, strongest Product×Country, Outcome
No Product×Country satisfied all hard gates. Strongest = **bluetooth turntable × GB** (SUPPLIER_EXACT +
STRONG_SAME_PRODUCT identity) → **WATCH/AVOID** (fails stock + economics). **Outcome B.**

## 27. RETRIEVAL GAP / CATALOGUE GAP / LIMITED verdict
**CJ_KEYWORD_RETRIEVAL_GAP_CONFIRMED.** Provider-native category-scoped discovery retrieved genuine
STRONG_SAME_PRODUCT products (7 turntables) that the keyword path missed (0), on the same credential
and catalogue. Nuance for the founder:
- **Retrieval gap (dominant):** the old keyword `product/list` under-retrieves; category-scoped
  `categoryId + noun` is materially better and should be the default discovery method going forward.
- **Per-concept catalogue signal (narrow):** for the *levitating moon lamp*, neither keyword nor the
  Night Lights category surfaced the product, and CJ's taxonomy has no hydroponics/indoor-garden or
  turntable category — a targeted coverage thinness for specific novelty items (bounded: page-1
  category samples, not exhaustive).
- Not a blanket CJ_CATALOGUE_COVERAGE_GAP: where CJ *does* stock the concept (turntables), the block
  is freight-weight economics, which a second China-shipping dropshipper would share.

## 28. Supplier-expansion recommendation
**Do NOT add supplier #2 yet.** The bottleneck was substantially a retrieval-method gap (now fixed)
plus concept-fit economics (heavy items). A second dropship supplier would not fix freight-weight
economics. First re-run discovery with the category-scoped method biased to **light, compact,
in-stock (CJ-warehouse) higher-ASP** concepts.

## 29. API / query counts
CJ: 1 auth + 1 getCategory (30138); 1 auth + 8 category product/list (30139); 1 auth + 3 product/query
+ stock + freight fan (30140, ~1 stock resolved + GB/US/DE/FR freight on the 1 resolved pid).
Supabase: 1 migration (mig_221) + reads. €0 cost.

## 30. CJ quota
Healthy — pointsInfo remaining 50,000; usedToday ~1,660 at run end.

## 31. Bugs / fixes
One genuine classifier bug (category-word satisfied product noun) → **mig_221** (title-scoped noun),
regression 12/12 PASS. Known limitation (not blocking, documented): the detail chain's "Normalize
Stock" node reads `$('Pick Variant').first()`, so on multi-pid runs it mislabels; the **raw**
`product/stock/queryByVid` data is authoritative (turntable = factory-only → OUT_OF_STOCK) and was read
directly. No bad stock persisted.

## 32. External blockers
None. CJ credential valid, quota healthy, all endpoints (getCategory, category-scoped list,
product/query, stock, freight) returned real data.

## 33. Campaign safety
No store, publication, Ad Studio, campaign, or activation. Paused Meta proof campaign untouched.
`campaign_activation = FALSE`.

## 34. Advertising spend
`advertising_spend = 0`.

## 35. Tests
12/12 market↔supplier regression PASS (incl. moss-pole false-positive now UNRELATED); real
category-scoped discovery classified; canonical PID round-trip proven on real data; end-to-end turntable
economics computed from real cost + stock + freight.

## 36. Git
mig_221 mirrored to `supabase/migrations/`; this doc added. Secret-scanned, committed, pushed to
`claude/pulse-crash-recovery-b6ngey`; remote == local, divergence 0 0.

## 37. Paid-beta readiness
≈ **86%** (up from 85%): CJ discovery is materially stronger (category-scoped + canonical PID), and the
identity classifier is hardened against taxonomy-word false positives. Remaining gap to a first real
TEST is concept-fit (light/compact/in-stock higher-ASP), not discovery or identity engineering.

## 38. EXACT NEXT ACTION (for founder approval — not executed)
Re-run the demand→economics→**category-scoped canonical discovery**→identity→stock→freight funnel with
the concept filter biased to **light (< ~1 kg), compact, CJ-warehouse in-stock, €40–90 ASP** products
(so freight and stock gates can actually pass), using the now-default category+noun discovery. Only if
that still yields no qualified TEST across a fresh higher-ASP set does supplier #2 become justified.

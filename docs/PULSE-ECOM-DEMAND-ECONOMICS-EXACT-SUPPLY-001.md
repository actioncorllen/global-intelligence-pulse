# PULSE-ECOM-DEMAND-ECONOMICS-EXACT-SUPPLY-001

**OUTCOME B — NO QUALIFIED TEST OPPORTUNITY FOUND.**
Binding bottleneck: **SUPPLIER_COVERAGE_BOTTLENECK_CONFIRMED**, preceded by a dominant
**ECONOMIC-CEILING WALL**. Running the sourcing order in reverse (demand → market → local price →
saturation → economic ceiling → exact spec → CJ search → identity) over Pulse's real evidence, **no
Product × Country reached the stock / freight / final-economics stage**, because the only two demand
concepts whose market economics can absorb the €15 ad reserve + €15–20 contribution have **zero
retrievable exact CJ supplier**. This is a genuine, reproducible funnel result on real data — not a
forced decision. `campaign_activation = FALSE`, `advertising_spend = 0`, no store, no ads, no new
supplier infrastructure.

## Method (reverse sourcing — no CJ-first scanning)
Demand first, supply last. Every stage is real evidence already in Pulse; a live CJ call was spent
**only** on concepts that first survived the economic ceiling (reverse-sourcing discipline).

1. **DEMAND / MARKET / LOCAL PRICE** — `market_price_observations`: 33 real eBay-Browse Product×Country
   observations, 29 distinct concepts, markets DE/GB/US/FR (observed 2026-09-07).
2. **ECONOMIC CEILING** — per observation, local VAT-inclusive median → EUR (fx_rates 2026-09-10:
   USD→EUR 0.86088, GBP→EUR 1.16391), net of VAT (GB 20%, DE/FR 19%), then
   `MAX_ACCEPTABLE_LANDED_COST = net_revenue − €15 ad reserve − €15 min contribution − ~8% variable
   (payment + returns)`. Market-led pricing only; median as the honest ASP anchor (never inflated).
3. **SATURATION** — `total_listings` per market retained as a WPS/quality input (not a hard kill).
4. **EXACT SPEC → CJ SEARCH** — for the survivors only, demand-derived exact specs drove the existing
   CJ collector (`NvuwUfW7fyjSb81R`, `product/list?productNameEn=`), 8 targeted queries.
5. **EXACT SUPPLIER (identity gate)** — every CJ candidate classified by `fn_resolve_supplier_identity`
   (mig_211–213 guard). EXACT_PRODUCT is required for TEST.
6. **STOCK / FREIGHT / FINAL ECONOMICS** — not reached: no candidate passed identity.

## Funnel (real numbers)
| Stage | Count |
|---|---|
| Product × Country demand observations | 33 |
| Distinct demand concepts | 29 |
| Survive economic ceiling (MAX_LANDED_COST ≥ €5) | **2** |
| — thin (0 < ceiling < €5) | 1 |
| — ceiling-dead (≤ 0) | 30 |
| Concepts sent to live CJ exact search | 2 |
| CJ candidates retrieved (8 queries) | 65 |
| CJ candidates classified CLOSE_COMPARABLE or better | **0** |
| CJ candidates classified EXACT_PRODUCT | **0** |
| Reached stock gate / freight / final economics | **0** |
| **Qualified HIGH_CONFIDENCE TEST Product × Country** | **0** |

### The two economic survivors (only concepts that earned a CJ call)
| Concept | Market | Local median | Median € | Net rev € | MAX landed € | Saturation | CJ exact supply |
|---|---|---|---|---|---|---|---|
| digital picture frame wifi | GB | £71.42 | 83.13 | 69.27 | **32.62** | 452 listings (low) | **none** |
| uhrenbeweger (watch winder) | DE | €59.50 | 59.50 | 50.00 | **15.24** | 4,996 listings (moderate) | **none** |

All other 30 priced concepts (jewellery box, crossbody bag, gua sha, sunset lamp, posture corrector,
car organiser, portable blender, laptop stand/sleeve, silk pillowcase, acupressure mat, pet fountain,
watch winder GB, etc.) have a **negative** landed-cost ceiling at their real median ASP — their market
price cannot cover €15 ad reserve + €15 contribution + any COGS. (LED Hollywood mirror GB, ceiling
€0.68, is economically dead in practice.)

## Binding bottleneck (double wall, in sequence)
1. **ECONOMIC-CEILING WALL (dominant volume filter).** 30 of 32 priced concepts die on economics
   alone. CJ's reachable catalogue skews to low-ASP commodity goods, and low-ASP goods are exactly the
   ones whose market prices cannot clear Pulse's contribution model.
2. **SUPPLIER-COVERAGE WALL (blocks the survivors) — CONFIRMED.** The only two concepts with viable
   economics are higher-ASP, more-differentiated products (a motorised watch winder; a wifi digital
   photo frame). Across 8 exact-spec queries and 65 retrieved CJ candidates, **not one** is an actual
   watch winder or digital photo frame — 0 EXACT_PRODUCT, 0 CLOSE_COMPARABLE, all 65 UNRELATED.

**Search was verified responsive, not broken:** 16 of 28 photo-frame-query results carried
frame/photo/digital tokens and watch-winder queries surfaced watch-adjacent items (watch storage box,
smartwatch) — yet the exact product noun (winder / rotator / photo-frame / picture-frame) appears in
**0** of 65 results. The keyword steers CJ correctly; CJ simply has no retrievable exact product in
these categories. The absence is a real coverage fact.

## Structural finding for the founder (important)
**Reverse (demand-led) sourcing and the EXACT_PRODUCT-for-TEST gate are in structural tension under the
current CJ credential.** `fn_resolve_supplier_identity` (correctly) grants EXACT_PRODUCT only on a
**shared product identifier** (SKU/barcode/GTIN); a perfect title+category match reaches only
CLOSE_COMPARABLE (verified: synthetic exact-title test → CLOSE_COMPARABLE / MEDIUM). CJ **redacts**
supplier/product identifiers under this credential. Therefore a demand-concept → CJ-title search can
**never** reach EXACT_PRODUCT by construction — EXACT identity is only establishable when Pulse anchors
on a specific known CJ product (supplier-first) or gains an identifier/spec/image bridge. Combined with
the catalogue skew, this means the first legitimate HIGH_CONFIDENCE TEST will most plausibly emerge
from a **higher-ASP concept for which a specific CJ product identifier can be pinned**, not from
keyword-searching CJ for a demand concept.

## What was NOT done (guardrails honoured)
- No product marked TEST / WINNER; no forced decision ("no qualified opportunity" is the honest result).
- No stock-by-VID and no freight calls spent — nothing passed identity, so nothing earned enrichment
  (reverse-sourcing discipline: exact matches only).
- No new supplier infrastructure: reused the existing CJ collector (`NvuwUfW7fyjSb81R`); only its query
  list changed. No new n8n schedule; manual run only.
- No store, no ads, no campaign, no spend. Paused Meta proof campaign untouched.
  `campaign_activation = FALSE`, `advertising_spend = 0`.

## Provenance / state
- Real demand: `market_price_observations` (33 rows, EBAY_BROWSE). FX: `fx_rates` (ECB via
  frankfurter.app, 2026-09-10). Identity: `fn_resolve_supplier_identity` (mig_211–213).
- CJ search: execution `30134` (success, 2026-09-11), 65 supplier-evidence candidates persisted to
  `commerce_supplier_products` (461 total; +65). No decision rows written (`commerce_signals` = 107,
  unchanged). No migration required — this unit is an evidence run, not a schema change.
- Overall paid-beta engineering readiness ≈ **84%** (unchanged): the full live CJ supplier hard-gate
  chain — identity, images, cost, freight, stock — is operational; the gap is real supply/demand-economics
  coverage, not Pulse engineering.

## Recommended EXACT NEXT ACTION (for founder approval — not executed)
Attack the supplier-coverage wall directly, without lowering standards:
1. **Broaden higher-ASP demand capture.** Add real eBay-Browse observations for more €40–90-ASP,
   differentiated categories (small electronics, motorised/mechanical goods, premium home) so more
   concepts clear the economic ceiling — the current 29-concept demand set is dominated by low-ASP
   commodities.
2. **Enable EXACT identity for reverse sourcing.** Pin CJ products by identifier via CJ category browse
   / the dedicated CJ search endpoint (returns pid/sku), then resolve identity supplier-anchored so a
   demand-matched concept can legitimately reach EXACT_PRODUCT. (This is new supplier-search capability
   — explicitly out of scope here; needs founder go-ahead.)
3. Re-run this exact demand → economics → exact-supply funnel once (1) and/or (2) land.

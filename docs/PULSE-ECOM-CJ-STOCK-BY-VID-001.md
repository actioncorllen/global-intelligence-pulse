# PULSE-ECOM-CJ-STOCK-BY-VID-001

**VERDICT: PASS.** The final CJ supplier hard gate — verified stock / warehouse availability — is
complete. The existing CJ stock-by-VID capability was reused and wired into the current
Pulse → n8n → CJ detail+freight pipeline; a real probe returns genuine warehouse inventory, and
Pulse now distinguishes IN_STOCK / OUT_OF_STOCK / UNKNOWN. No new CJ integration. No product
decision, no store, no ads, no campaign, no spend.

## Reused (no duplicate integration)
- Endpoint: `GET https://developers.cjdropshipping.com/api2.0/v1/product/stock/queryByVid?vid=<vid>`
  (header `CJ-Access-Token`) — the exact call from the P4 probe `ZbhPyAuvDD4h4xid`.
- Credential: **"CJ Dropshipping API"** (`httpCustomAuth`, id `2IV5tXPu9jAItjKh`). Valid; never printed.
- Workflow: extended the existing **CJ Detail + GB Freight Probe** (`OxH9sb6jKCqiqXOk`) — added
  `CJ Stock` + `Normalize Stock` as an **additive branch off "Pick Variant"**; the product-detail
  and destination-freight chain is unchanged.

## Endpoint & response schema (real)
`data[]` of warehouse rows: `{ vid, areaId, areaEn (warehouse name), countryCode (warehouse
country), storageNum, totalInventoryNum, cjInventoryNum (CJ-warehouse ready-to-ship),
factoryInventoryNum (replenishable-only), stock[] }`.

## Normalizer — `fn_cj_normalize_stock(jsonb)` (mig_219)
- `sum(cjInventoryNum) > 0` → **IN_STOCK** (`CJ_WAREHOUSE_READY_TO_SHIP`).
- `cj = 0` and `factory > 0` → **OUT_OF_STOCK** (`ZERO_CJ_WAREHOUSE_FACTORY_REPLENISHABLE_ONLY`) —
  factory stock is not immediately fulfillable.
- `cj = 0` and `factory = 0` → **OUT_OF_STOCK** (`VERIFIED_ZERO_ALL_LOCATIONS`).
- missing / empty / endpoint error → **UNKNOWN** (`NO_WAREHOUSE_ROWS`) — never IN_STOCK.
- Aggregates across warehouse/variant rows: any CJ-warehouse stock → IN_STOCK (a product is not
  marked OUT_OF_STOCK merely because one warehouse is empty). Warehouse identifier/country/vid
  preserved per row.

## Real probe (read-only, execution `30133`, success, 2026-09-11)
Product `2609070153091625100` "High-end Accessory Jewelry Box", variant vid `2609070153091625901`:
- stock endpoint 200; `cjInventoryNum: 0`, `factoryInventoryNum: 9567`, warehouse **China
  Warehouse (CN)** → normalized **OUT_OF_STOCK** (`ZERO_CJ_WAREHOUSE_FACTORY_REPLENISHABLE_ONLY`).
- Freight still returned for US/GB/DE/FR (landed $5.39 / $4.01 / $5.19 / $4.91) — freight regression PASS.

## Hard-gate proof — all three states
| Case | Input | Result |
|---|---|---|
| OUT_OF_STOCK (real) | jewelry box cj0/factory9567 | OUT_OF_STOCK |
| OUT_OF_STOCK (real) | leather patch cj0/factory8631 (P4 exec 30132) | OUT_OF_STOCK |
| IN_STOCK (normalizer logic) | cj120 / US warehouse | IN_STOCK |
| Multi-warehouse aggregation | US cj0 + CN cj40 | IN_STOCK |
| UNKNOWN (normalizer logic) | empty `[]` | UNKNOWN |

IN_STOCK and UNKNOWN are exercised as normalizer-logic tests (no real CJ product currently has
CJ-warehouse stock); no external stock was manipulated and no provider response was fabricated.

## Persistence & provenance
Real stock persisted to `commerce_supplier_products.supplier_enrichment.stock` (state, reason,
cj/factory/total inventory, warehouses[] with name+country+vid, `source: CJ_STOCK_QUERY_BY_VID`,
`observed_at`, `probe_execution_id`). Reused the existing supplier contract; no duplicate stock
architecture.

## Regressions
- `supplier_product_assets` (mig_218) unaffected: jewelry box still resolves PRIMARY_IMAGE
  AVAILABLE + 2 GALLERY_IMAGE AVAILABLE; all four image flags true.
- Destination freight unaffected.

## Destination relationship
Stock is kept separate from destination freight: CJ-warehouse stock does not by itself prove
economical fulfilment to any country. Product × Country validation combines verified stock +
destination availability + freight + delivery.

## API limitations
`product/query` does not carry per-variant inventory (hence the separate stock-by-VID call);
supplier identity redacted under this credential. No external founder action required (credential
valid, quota healthy: ~150/50000 points used today).

## Safety
No product TEST decision, no customer publication, no store/ads/campaign/spend; Marketing Spend
Authority untouched; `campaign_activation=FALSE`, `advertising_spend=0`. Manual run; no schedule
change. Overall paid-beta engineering readiness ≈ **84%** (all CJ supplier hard-gate evidence —
identity, images, cost, freight, and now stock — is obtainable live).

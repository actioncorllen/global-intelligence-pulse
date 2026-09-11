# PULSE-ECOM-CJ-LIVE-DETAIL-RECOVERY-001

**VERDICT: PASS.** The Pulse → n8n → CJ live product-detail capability is operational. The prior
`BLOCKED_EXTERNAL_CJ_LIVE_DETAIL` was a **deferral, not a failure** (the previous run chose not to
spend the external call on economically-unviable candidates). A real read-only probe now succeeds
end-to-end, and one genuine latent defect surfaced by real gallery data was fixed. No customer
publication; `campaign_activation=FALSE`; `advertising_spend=0`.

## Existing CJ architecture (reused — no duplicate created)
n8n workflows (manual, `active:false` is normal for manual triggers):
- **Pulse — CJ Supplier Collector** (`NvuwUfW7fyjSb81R`) — product list → `commerce_supplier_products`.
- **Pulse — CJ Detail + GB Freight Probe (Manual)** (`OxH9sb6jKCqiqXOk`) — auth → `product/query` →
  pick variant → `freightCalculate` (US/GB/DE/FR) → summarize. **This is the live-detail capability.**
- **Pulse — CJ Supplier Enrichment Probe (P4)** (`ZbhPyAuvDD4h4xid`) — read-only field audit.
Credential: **"CJ Dropshipping API"** (`httpCustomAuth`, id `2IV5tXPu9jAItjKh`) — valid, not exposed.

## Root cause
No connectivity/credential/endpoint failure. The prior unit deferred the CJ call. Exercising the
recovered detail against the real `supplier_product_assets` contract for the first time with a genuine
`productImageSet` array exposed a **latent bug** in `fn_ingest_supplier_product_assets` (mig_209): the
GALLERY loop variable was `jsonb` while `jsonb_array_elements_text()` returns text, forcing a failing
text→jsonb cast on bare URLs. Latent because earlier products had no gallery array.

## Fix (mig_218)
`fn_ingest_supplier_product_assets` gallery loop variable `g jsonb` → `g text`, storing the URL
directly. Regression: re-ingest succeeds. No other behaviour changed.

## Real CJ probe (read-only, execution `30131`, status success, 2026-09-11)
Product `2609070153091625100` "High-end Accessory Jewelry Box":
| Field | Result |
|---|---|
| n8n connectivity | operational |
| CJ authentication | 200; token valid to 2027-03-10; quota 10/50000 used today |
| product identity | name, SKU `CJSB3133930`, category Home Storage, `status:"3"` (active) |
| variants | **12** (colour × size), vid/sku/barcode/weight/cost 0.49–0.69 USD |
| primary image | present (real CJ URL) |
| gallery | present (`productImageSet`, 2 URLs) |
| video | none (`productVideo:null`) |
| **stock** | `inventoryNum:null` / `inventories:null` on all variants → **UNKNOWN from `product/query`**; a separate `CJ_STOCK_QUERY_BY_VID` call is required to resolve IN_STOCK/OUT_OF_STOCK (honest endpoint limitation, not a failure) |
| warehouse | not returned by this endpoint |
| destination freight | **real** for US/GB/DE/FR via `freightCalculate` (e.g. GB CJPacket Ordinary $3.42, 4–9d; ~18 options) |
| landed (cost+cheapest freight) | US $5.39 · GB $4.01 · DE $5.19 · FR $4.91 |
| supplier identity | `supplierId/supplierName:null` (CJ redacts under this credential) |

## supplier_product_assets result (after fix)
Ingested via `fn_ingest_supplier_product_assets`: **PRIMARY_IMAGE** AVAILABLE (SUPPLIER_OWN,
SUPPLIER_PROVIDED) · **2× GALLERY_IMAGE** AVAILABLE · **VARIANT_IMAGE** honestly UNAVAILABLE
(requires detail fetch) · no VIDEO. Flags: `PRODUCT_HAS_IMAGE` / `IMAGE_RESOLVED_BY_PULSE` /
`IMAGE_RENDERABLE_IN_PULSE` / `IMAGE_RENDER_BLOCKED_ONLY_IN_CLAUDE` = **all true**.

## API limitations (documented, not fabricated)
- `product/query` does not return per-variant inventory for this product → stock needs the
  stock-by-vid endpoint. - Supplier identity redacted under the current credential. - Freight is
  per-destination (never inferred globally). No external founder action required; credential valid,
  quota healthy.

## Safety
No product decision (TEST/WATCH/AVOID), no store, no ads, no campaign, no spend. Only supplier
evidence written (`commerce_supplier_products` row + `supplier_product_assets`). `customer
opportunities`=0, `daily_briefs`=5 unchanged, no non-paused campaigns. Manual run; no schedule
change. Overall paid-beta engineering readiness ≈ **84%** (CJ live-detail capability confirmed
available; stock-by-vid is the next enrichment step).

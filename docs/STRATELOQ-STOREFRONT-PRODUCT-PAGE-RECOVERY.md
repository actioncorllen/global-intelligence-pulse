# STRATELOQ — Storefront / Product-Page End-to-End Recovery

**Priority:** P0 launch blocker · **Status:** `PASS_BACKEND_FRONTEND_READY_BROWSER_SMOKE_REQUIRED`.

## Root cause

The Product Page Builder (`src/components/storefront/product-page-builder.tsx`,
Lovable) reads Step 1 fields from a `ProductAcquisition` object
(`acq.productType`, `acq.selectedSupplier`, `acq.preparedPackage.listing`, …).
That object is produced only by the **product-sourcing pipeline**
(`create_product_acquisition → select_supplier → prepare → approve`, table
`product_acquisitions`).

Real products reach **My Store** through a *different* path — Product
Opportunity → Product Card → **Create Free Store** — which links the CJ supplier
directly (`fn_link_candidate_supplier`) and **never creates a
`product_acquisitions` row**. The founder has **zero** acquisition records. So
when the builder opens for a My Store product, no `acquisition` prop is passed
and it falls back to a synthetic object with `productType: null`,
`selectedSupplier: null` → the screen shows *"Type: Not classified / Supplier:
Not selected / Selling price: Not configured"* even though canonical
intelligence has the category, the CJ supplier link (cost 5.73 USD), the
supplier-authorized commercial image, and READY readiness.

**This is a contract/handoff divergence, not missing data and not a broken
renderer.** The premium `StorefrontRenderer` + six-step flow are intact.

## Fix (backend, canonical, no shadow table)

`mig_335` adds **`fn_product_page_builder_context(product_id, market)`** — a
read-only RPC that assembles the builder's Step 0/1/6 context directly from the
authoritative contracts that exist for a My Store product:

| Field | Canonical source |
|---|---|
| product / **type** | `commerce_products.title` / `.category` |
| identity | `fn_product_identity_resolution` |
| **supplier + cost** | `fn_product_supplier_identity` + `commerce_supplier_products` (supplier_cost) |
| observed source price | `commerce_products.observed_price` (marketplace; null for the nightlight — honest) |
| suggested selling price | decision `economics_ref` **only when economics are known**; never fabricated |
| commercial image | `fn_product_card_display_image` (commercially eligible only) |
| readiness | `fn_product_commercial_asset_readiness` |
| strategy/listing | `product_acquisitions.prepared_package` when present, else null |
| page/publish | `commerce_product_pages` |

Null fields are genuinely uncollected, never invented. Tenant-guarded
(`auth.uid()` = owner). Also adds `fn_product_page_builder_selftest` (9/9) so
future intelligence upgrades cannot silently re-break the handoff.

### Verified live (Nightlight GB)
`type = "nightlight projector"`, `supplier = CJ` with `supplier_cost 5.73 USD`,
`identity = IDENTITY_RESOLVED`, `commercial_image.publishable = true`
(CJ SUPPLIER_PROVIDED), `readiness = READY`; `observed_source_price = null` and
`suggested_selling_price = null` with an honest economics note (no fabrication).
Humidifier stays `CONCEPT_ONLY` with `supplier_link_allowed = false` (gated).

## Pricing / economics honesty

Supplier cost (5.73 USD) is real and shown. The decision `economics_state` is
`UNKNOWN` for this market (no CAC/economics evidence yet), so **no selling price
is auto-suggested** — the RPC returns `suggested_selling_price: null` plus the
$25–30 profit-target rule as context, and the merchant sets/confirms the selling
price. Opportunity economics and the merchant's publishing decision stay
distinct; nothing is auto-published.

## What did NOT change

Premium renderer, six-step flow, multi-product store, Product Identity,
Commercial Asset Rights, Product Asset Lock, Gemini validation, opportunity
engine, TikTok/Meta research, RLS/tenant isolation, publish lifecycle
(`fn_storefront_publish_context` / `fn_storefront_publish` /
`fn_storefront_transition_state`). My Store composition unchanged (ACTIVE:
cool mist humidifier + kids nightlight projector). 0 ERROR security advisors.

## Frontend (Lovable-owned) — one implementation prompt

The builder must call `fn_product_page_builder_context(product_id, market)` when
opened for a My Store product and map its fields into Step 0 (type, supplier,
supplier cost, observed price, **editable selling price**), Step 1 (strategy
when a prepared listing exists), the commercial image, and Review. The complete
prompt is in the delivery message (field 30). No renderer redesign; reuse
`StorefrontRenderer`, `PublishControls`, existing UI primitives.

## Browser verification

Not performed here — the authenticated Lovable app cannot be exercised from this
backend task (read-only file access only). Backend is verified and the frontend
contract is ready; an authenticated browser smoke test of the six-step flow with
the Nightlight is still required before final sign-off.

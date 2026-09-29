# STRATELOQ — Product Page Conversion Story + Claim-Safety Refinement

**Status:** `PASS` (backend). Browser smoke re-check recommended.

## Root cause of generic + unsupported copy

`fn_product_page_strategy` surfaced `fn_generate_page_copy`'s **default** copy
verbatim. That engine asserts shipping, "Transparent estimated delivery",
"New condition, fulfilled from the supplier warehouse", and delivery/origin/
condition FAQ entries **regardless of evidence**, and uses generic filler
("A practical X you can order online", "Straightforward X", "Shoppers searching
for X want a clear, no-guesswork option"). None of it was gated against
canonical evidence for PRODUCT + SELECTED MARKET.

## Fix (mig_338 — refine existing generation, no new engine)

`fn_product_page_strategy` (v3) now applies a **server-side evidence gate** and
emits only supported customer-facing claims:

- **Shipping** is claimed only when the supplier's `shipping_country_codes`
  actually cover the selected market. The Nightlight supplier ships `["CN","CN_US"]`
  → **US supported, GB not**. Country-isolated: "Ships to United States" renders
  for US; **omitted** for GB.
- **Delivery time** is never claimed (no est-days evidence). **Condition** ("new")
  and **fulfilment origin** ("supplier warehouse") are omitted (no evidence).
- **FAQ** about delivery/origin/condition is **omitted entirely** — never a
  guessed answer. `how_it_works` (ordering/delivery steps) omitted.
- **Product story** is grounded in the RESOLVED identity/category: factual
  use-context ("Adding projected, low-level light in a child's room at night."),
  accurate feature statements from the product type ("Projects light", "Designed
  for use as a night light" — `PRODUCT_IDENTITY_FACT`), and a factual details
  table (type, intended-for, supplier-reported weight, ships-to). No fabricated
  emotion/medical/safety/performance/specs.
- **CONCEPT_ONLY** products get **no** capability claims (humidifier benefits = []).

Every claim carries an internal basis (`PRODUCT_IDENTITY_FACT`,
`SUPPLIER_SHIPPING_EVIDENCE`), and a `claims` object exposes
`ships_to_market`, `shippable_markets`, and `delivery_time_evidence:false` /
`condition_evidence:false` / `fulfilment_origin_evidence:false`.
`fn_generate_page_copy` remains the base engine; its unsafe fields are gated.

## Verified (`fn_product_page_strategy_selftest` 22/22)

- US: no unsupported claims; `ships_to_market=true`; "Ships to United States"
  benefit + shipping_note; product-specific benefit ("Projects light"); details ≥2.
- GB: `ships_to_market=false`; **no** "Ships to" benefit; **no** shipping_note.
- FAQ + how_it_works omitted; no `transparent estimated delivery` /
  `fulfilled from the supplier warehouse` / `new condition` / delivery-FAQ strings
  anywhere; no `you can order online` / `straightforward nightlight` filler.
- Humidifier stays `CONCEPT_LEVEL_DRAFT`/`CONCEPT_ONLY` with **no** capability claim.
- Product step (type/CJ/cost/image) intact; no fixture leak.

## Regression

Country isolation (US ships ≠ GB), Product Identity (nightlight RESOLVED,
humidifier CONCEPT_ONLY), Commercial Asset Rights (humidifier CUSTOMER_ASSET_REQUIRED),
Product Asset Lock, opportunity scorer (78.2), store (humidifier + nightlight),
RLS all unchanged. 0 store writes; nothing published. Security advisors: 0 ERROR.

## Lovable

**Not required.** The frontend renders only what `page_copy`/`key_benefits`
provide; removing unsupported claims server-side removes them from the page, and
empty `faq`/`how_it_works` arrays hide those sections via the existing
`gateSections`. (Optional future enhancement: map `page_copy.details` into the
specifications section for an even richer factual product-info block — not a
claim-safety requirement.)

## Browser

An authenticated smoke re-check of the Nightlight page is recommended to confirm
the unsupported shipping/delivery/condition strings and delivery FAQ no longer
render, while Hero/Problem/Solution/Benefits/Product-info remain.

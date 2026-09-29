# STRATELOQ — Product Page Strategy Intelligence Recovery

**Priority:** P0 product-page quality · **Status:** `PASS_LOVABLE_MAPPING_REQUIRED`.

## Root cause of empty strategy

`fn_product_page_builder_context.strategy` (mig_335) sourced strategy **only**
from `product_acquisitions.prepared_package`. Products that enter My Store via
Product Opportunity → Create Free Store have **no acquisition**, so
`prepared_package` is null → Step 2 showed *"Value proposition: Not supplied /
Customer: Not supplied"* even though Strateloq holds substantial product/decision
intelligence.

## Fix — reuse, not a second engine (mig_336)

`fn_product_page_strategy(product_id, market)` **orchestrates the existing
generators** and maps their output to the builder's strategy contract:

- `fn_select_conversion_template` → template family, hero, evidence, confidence;
- `fn_storefront_conversion_strategy` → objective, angle, awareness, evidence basis;
- `fn_generate_page_copy` → claim-safe positioning, value proposition, benefits,
  problem/solution, CTA.

Inputs are assembled from canonical data (product/category, identity, CJ supplier
+ cost, the market's opportunity decision, store brand). **No new copy/strategy
engine, no new AI provider.** `fn_product_page_builder_context` now returns this
under `strategy` (v2); all Step-1 Product fields are unchanged.

### Fact vs. strategy / claim safety
`fn_generate_page_copy` is claim-safe by construction: `no_reviews_fabricated`,
`no_fake_discount`, `no_urgency_scarcity`, `no_guaranteed_delivery`,
`no_certifications_or_warranty_claimed` — all true. Nothing asserts reviews,
ratings, sales, delivery guarantees, or medical/performance claims. Advertising
presence (Meta 6 advertisers / 29 creatives for the Nightlight) is **never**
converted into sales/profit/satisfaction claims; it informs positioning only.

## Nightlight GB result (real, evidence-grounded)

- **Positioning:** "nightlight projector" (template PROBLEM_SOLUTION, hero HERO_PROBLEM_FRAMING).
- **Value proposition / subtitle:** "A practical nightlight projector you can order online." / honest details + estimated delivery window.
- **Target customer:** "Shoppers actively looking for a nightlight projector (search/marketplace demand observed for this product)" — basis `PRODUCT_IDENTITY+DEMAND_SIGNAL`, confidence MEDIUM. Grounded in the resolved product identity + observed demand; no invented demographics.
- **Key benefits:** Straightforward nightlight projector · Ships to GB · Transparent estimated delivery · New condition, fulfilled from supplier warehouse.
- **Messaging direction:** problem-led angle · awareness PROBLEM_AWARE · problem statement.
- **Objective:** TEST_PURCHASE_INTENT_AT_LANDED_ECONOMICS · **CTA:** Add to cart.
- **State:** `EVIDENCE_VALIDATED_DRAFT` (merchant reviews before publish).

## Country isolation

Search keywords and the opportunity decision are read for the **selected market
only**; benefits reference the selected market ("Ships to GB"). GB evidence is
never used for IE; global product facts (category/identity) remain global.

## Concept-only safety (Humidifier)

`fn_product_page_strategy` returns `strategy_state = CONCEPT_LEVEL_DRAFT` for the
CONCEPT_ONLY humidifier — concept-level copy only, never SKU-specific factual
claims. Identity stays `CONCEPT_ONLY`, supplier linkage/image rights/commercial
readiness (`CUSTOMER_ASSET_REQUIRED`) unchanged.

## Regression

- Product step unchanged: nightlight type "nightlight projector", CJ supplier +
  5.73 USD cost, publishable image, READY — `fn_product_page_builder_selftest` still 9/9.
- `fn_product_page_strategy_selftest` 15/15; `fn_ad_verification_selftest` green.
- Scorer `fn_opportunity_score_v2` untouched; nightlight GB score 78.2 unchanged.
- Rights/PAL, StorefrontRenderer, publish lifecycle unchanged.
- My Store active products unchanged (cool mist humidifier + kids nightlight projector); 0 store writes.
- Security advisors: 0 ERROR (4 WARN / 1 INFO baseline).

## Frontend (Lovable) — one mapping prompt

The builder already fetches `fn_product_page_builder_context`. Map the new
`strategy` object into Step 2: value proposition, target customer, key benefits,
messaging direction, objective, CTA. "Why this page?" stays as explainability.
The complete prompt is in the delivery message (field 28). No renderer redesign.

## Browser verification

Not performed here (authenticated Lovable app not exercisable from this backend
session). Backend verified; the frontend mapping + an authenticated Step-2 smoke
test remain.

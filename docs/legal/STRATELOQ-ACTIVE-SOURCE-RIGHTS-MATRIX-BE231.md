# STRATELOQ — Active-Source Rights Matrix (BE231, 2026-11-20)

Authoritative inputs: `public.catalogue_source_rights` (the system rights register — every
clearance dimension is FALSE for every provider as of this review), the provider
correspondence on file, and the system's enforced posture. Provider public terms pages
(dataforseo.com, kalodata.com, cjdropshipping.com) are **not retrievable from the
engineering session** (network-restricted): no external licence text was read, and none is
interpreted here. `display_cleared`-style flags on individual assets are system
rights-model markers, **never** legal authorisation.

Legend: **P** = Permitted (written evidence on file) · **X** = Prohibited (by evidence or
enforced posture pending approval) · **U** = Unconfirmed (no document either way) ·
**W** = Requires additional written approval before use.

## DataForSEO (incl. Merchant / Google Shopping)

| Permission | Status | Basis |
|---|---|---|
| Derived research findings → paying SaaS customers | **W** | No licence text on file; register display_derived=false; internal posture research-only (founder 19-Nov alignment) |
| Country-local observed product prices (display) | **W** | Same; prices are Shopping-SERP-derived — upstream conditions unknown |
| Observed seller/retailer & competition findings (display) | **W** | Same; system already refuses national-seller claims (observed floors only) |
| Source attribution + observation dates | **U** | Shown by our practice; whether required/permitted/forbidden by terms unconfirmed |
| Google Shopping / Merchant upstream redistribution | **W** | Register flags explicitly; no written Google-conditions analysis on file |
| Merchant imagery (storage/display) | **X** (posture) / **W** | Zero Merchant images stored or displayed (verified BE229); stays prohibited pending written approval |
| Retention / caching / derived-data reuse | **U** | Raw task results stored TENANT_PRIVATE; terms limits unknown |

**GB five-product text-only pilot: NOT AUTHORISED by documents on file.** The exact
missing document: DataForSEO written confirmation that derived listing TEXT data (titles,
observed prices, merchant names) from Google Shopping SERPs may be displayed to paying
research customers, plus the applicable retention terms and any upstream Google
conditions. `customer_source_release.released` stays FALSE (left untouched).

## Kalodata

| Permission | Status | Basis |
|---|---|---|
| Derived analytics (est. revenue/sales/growth, labelled) → customers | **U→W** | LIVE under the founder's direct build authorisation; register display_derived=false; no provider statement on file — needs provider written confirmation or a documented founder risk-acceptance recorded in the register |
| Customer-facing reference images (master_image_url) | **U→W** | Same as above; need_image=1 is a product feature, not a licence; images hotlinked DIRECT_URL (no byte caching) |
| Attribution + dates | **U** | Shown by practice; requirement status unconfirmed |
| Caching / storage of media bytes | **X** (posture) | Not done; keep prohibited pending terms |
| Commercial reuse of media (ads/stores) | **X** | commercial_cleared=false enforced system-wide (PAL) |
| Correspondence on file | — | Andrew Lin, 2026-11-20: API authentication guidance ONLY; contains no rights statements |

**Flagged inconsistency (founder decision):** live customer display vs register FALSE.
Resolve by (a) provider written confirmation (draft email below), or (b) founder
documented risk-acceptance written into `catalogue_source_rights`.

## CJ Dropshipping

| Permission | Status | Basis |
|---|---|---|
| Customer-facing supplier research (identity, SKU, cost, stock, freight) | **W** | Register false; no written SaaS display terms on file |
| Product references / outbound product links | **U** | Low-risk by nature; unconfirmed in writing |
| Supplier images (display) | **U→W** | System practice treats SUPPLIER_PROVIDED media as gallery-eligible while the register holds display=false — flagged inconsistency, same resolution options as Kalodata |
| Commercial reuse of supplier media | **X** | Restricted; unverified |
| Retention / caching | **U** | 1,317 records cached since Aug–Oct; terms limits unknown |

## Register state after BE231
No clearance flag was changed (all remain FALSE). The four active-source
`rights_evidence` entries now carry the BE231 reconciliation verbatim, including both
flagged inconsistencies and the pilot release decision.

## Draft permission-request emails (for founder review — NOT sent)

### 1 → DataForSEO support/legal
Subject: Permission confirmation — displaying derived research findings to our SaaS customers

We operate a market-research SaaS (Strateloq) and use the DataForSEO API (incl. Merchant/
Google Shopping endpoints) under our account. Before enabling any customer-facing use we
want written confirmation of what our licence permits: (1) displaying derived research
findings (opportunity assessments, demand estimates, deduplicated listing statistics) to
our paying customers; (2) displaying observed country-local product prices, titles and
merchant names from Shopping SERP results as clearly-attributed research data; (3)
displaying observed seller/competition findings; (4) your attribution requirements; (5)
any upstream Google Shopping redistribution restrictions we must honour; (6) permitted
retention/caching of task results and reuse of derived data. We do not display or store
Shopping images and do not resell raw API data. Could you confirm each point, or send the
applicable licence sections?

### 2 → Kalodata (ref: Andrew Lin correspondence, 2026-11-20)
Subject: Follow-up — display permissions for analytics and product reference images

Thank you for the API authentication guidance on 20 November. Separately from the
technical integration we want written confirmation of display rights under our plan: (1)
showing Kalodata-derived analytics (estimated revenue/sales/growth, clearly labelled as
estimates with attribution) to paying customers of our research SaaS; (2) displaying the
master_image_url product reference images (returned via need_image=1) to those customers
as research reference covers — hotlinked, not cached; (3) your attribution requirements;
(4) any caching/retention limits; (5) confirmation that commercial reuse of media (ads,
storefronts) is excluded — which we already enforce. Could you confirm each point, or
send the applicable terms?

### 3 → CJ Dropshipping partner/API team
Subject: Permission confirmation — supplier research display in our sourcing SaaS

We use the CJ developer API for sourcing research inside our SaaS (Strateloq). Before any
customer-facing use we want written confirmation of: (1) displaying supplier/product data
(product names, SKUs/variants, costs, stock state, shipping options) to our paying
customers as sourcing research; (2) linking to CJ product pages; (3) displaying
supplier-provided product images in that research context; (4) permitted
retention/caching of catalogue data; (5) exclusion of commercial media reuse unless
separately agreed. Could you confirm each point, or send the applicable API terms?

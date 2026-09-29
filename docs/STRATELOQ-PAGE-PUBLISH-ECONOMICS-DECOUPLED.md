# STRATELOQ — Product Page Publishing Gate: Remove Opportunity-Economics Block

**Status:** `PASS_BACKEND_READY_FOR_MERCHANT_REVIEW`.

## The exact backend gate (found, not inferred from UI copy)

The "Complete required pricing and margin details" blocker was **opportunity
economics**, enforced in the page-publish path in two places:

- `fn_storefront_publish_context` — appended blocker `ECONOMICS_NOT_VIABLE` when
  `runtime_contract.economics_state NOT IN ('VIABLE','POSITIVE')`.
- `fn_storefront_publish` (server-derived branch) — returned
  `BLOCKED_TEST_ELIGIBILITY / REJECT_ECONOMICS_NOT_VIABLE` for the same condition.

`fn_storefront_publish_blocker_detail('ECONOMICS_NOT_VIABLE')` renders exactly
*"Complete the required pricing and margin details before publishing."*

Live proof (Nightlight page `45af3635…`, US): `economics_state = UNKNOWN`, so its
publish blockers were `["NOT_APPROVED","ECONOMICS_NOT_VIABLE"]` — everything else
(content generated, claim-safe, rights-cleared image, PULSE_STORE) already passed.

## The two contracts, now separated (mig_339)

- **Contract A — Product Opportunity Intelligence (economics):** CAC, margin
  target, estimated profit ($25–$30+), economics confidence. Lives in
  `fn_opportunity_score_v2` and `fn_storefront_test_eligibility`. **UNCHANGED.**
- **Contract B — Product Page Publishability:** explicit merchant review approval,
  page content generated, claim safety, publishable/rights-cleared commercial asset
  (Product Asset Lock), publish destination, canonical product image.

Opportunity economics was removed from Contract B only:

- `fn_storefront_publish_context`: no `ECONOMICS_NOT_VIABLE` blocker. Adds a generic
  `page_publish_readiness` matrix (a presentational projection of the same
  server-derived states — **not** a second readiness engine) where CAC / margin /
  estimated-profit / economics-confidence are all `NOT_REQUIRED_FOR_PAGE_PUBLISH`,
  plus an informational `opportunity_economics_state`.
- `fn_storefront_publish`: server-derived branch no longer gates on economics; the
  explicit-gate branch still computes `fn_storefront_test_eligibility` for
  transparency but strips economics-only reason codes before the publish decision.
- `fn_storefront_publish_status_blocker`: never maps a page-publish outcome to the
  pricing/margin message.

Merchant selling price (e.g. 39.99 USD) is accepted without proving CAC/profit — the
publish path has no selling-price/margin condition at all. Checkout still reports
`CHECKOUT_NOT_CONFIGURED`. Review approval stays an explicit merchant action
(DRAFT → IN_REVIEW → APPROVED); nothing is auto-approved or auto-published.

## What still blocks a page (unchanged, evidence-grounded)

Explicit merchant review approval, generated content, claim safety (unsupported
delivery/reviews/offer claims still suppressed), rights-cleared commercial asset
(Product Asset Lock), canonical product image, PULSE_STORE destination.

## Verified

- `fn_page_publish_economics_selftest` (Nightlight, live) **7/7**: economics blocker
  gone (blockers → `["NOT_APPROVED"]`); 4 economics dims `NOT_REQUIRED_FOR_PAGE_PUBLISH`;
  5 page-publish dims `REQUIRED`; publishes with `economics_state=UNKNOWN` (rolled
  back); claim-safety still blocks; review approval still required; **nothing published**.
- Existing suites green: `fn_storefront_publish_selftest` 9/9,
  `fn_storefront_publish_lifecycle_selftest` 10/10, `fn_storefront_publish_ux_selftest` 8/8.
- Contract A intact: `fn_storefront_test_eligibility` still returns
  `REJECT_ECONOMICS_UNKNOWN`; `fn_opportunity_score_v2` untouched.
- Nightlight persisted state still `DRAFT / UNPUBLISHED`, `economics_state=UNKNOWN`.
- Security advisors: **0 ERROR** (4 WARN / 1 INFO baseline).

## Lovable

**No change required.** `publish-controls.tsx` is fully server-driven: it renders
only the blockers `fn_storefront_publish_context` returns and computes no client-side
economics/pricing/margin gate. With the economics blocker removed server-side, the
Nightlight's only remaining blocker is `NOT_APPROVED` — the publish button enables
after the merchant approves review.

*Optional polish:* surface the new `page_publish_readiness` matrix +
`opportunity_economics_state` in the Review step, and drop the now-dead `FIX_DETAILS`
entry from `FALLBACK_GUIDANCE`. Cosmetic only; not required.

# PULSE-ECOM-PRODUCT-EXPLORER-001

**Transform the signed-in Products view into a compact, image-rich, paginated Product Explorer
(WinningHunter-grade usability, Strateloq design + intelligence). Backend `mig_311`
(`fn_product_explorer`, additive, no DROP, no paid calls) + Lovable frontend (commit `67ee050c`,
published to production). GB shows 28 genuine FastMoss products with 100% cover coverage, six
working filters, search, sort and pagination, each opening the existing Product Intelligence
drawer. Status: PASS (backend + deployment, bundle-verified live) / PARTIAL (signed-in visual
verification still required; one deliberate fail-closed design note).**

## 1. What customers now see (req 1, 2)
The Products tab is the **Product Explorer**: a responsive card grid (1→5 columns) over a single
server-owned, tenant- and market-scoped projection (`fn_product_explorer`, contract
`pulse_product_explorer_v1`). Each card shows the real reference cover (https-only, else an honest
"No image" box), a 2-line title, country-specific Price, Revenue, Sales, Growth and Promotions,
lane badges (Newly Listed / Best Sellers / Most Promoted), an opportunity-class chip, the observed
date and a "Reference only" caption.
- **Six filters** with live server facet counts: All, Newly Listed, Best Sellers, High Growth,
  Most Promoted, Early Opportunities.
- **Search** (300 ms debounced title match), **sort** (Newest / Revenue / Sales / Growth / Most
  Promoted), **pagination** (24/page, Prev/Next, "Page X of Y", total count; resets to page 1 on
  any filter/sort/search/market change).
- **UNKNOWN stays UNKNOWN**: every missing numeric renders "—", never a fabricated 0; covers that
  aren't https are dropped.

## 2. Efficient, decision-independent discovery projection (req 4)
`fn_product_explorer(p_market, p_filter, p_search, p_sort, p_page, p_pagesize)` is a **single
paginated query**: a `base` CTE joins `commerce_products` to `COMMERCE_PRODUCT_NATIVE` signals for
the market (aggregating lanes and the max of each metric — never summed), `product_opportunity_
decisions` is **LEFT JOINed only to enrich** (band/decision/lifecycle/score), so a discovered
product displays **without depending on a fully-qualified opportunity decision**. Server-owned auth
(`auth.uid()`; `p_*` args never trusted), fail-closed denied shapes, grants to
anon/authenticated/service_role. `fn_product_explorer_markets()` powers the market selector from
markets that actually have discovered products.

## 3. Deduplication, provenance, reference-only media (req 5, 6)
Dedup is by **verified product identity** (`commerce_products.id`, i.e. platform_id — never SKU or
broad family), enforced by the GROUP BY. Source provenance (`source:FASTMOSS`) and media authority
(`authority:REFERENCE_ONLY`) travel on every row; the cover subquery reads `product_image_assets`
(tenant+market scoped, primary-first, non-default preferred). Covers and metrics are **display-only
and never passed to any commerce, creative, publishing or Product Asset Lock gate** — documented in
AGENTS.md and enforced in the drawer (see §6).

## 4. Reused Product Intelligence drawer (req 3)
Clicking a card opens the **existing** `ProductIntelligenceDrawer`, loading data **only for the
clicked product**: sales history / intelligence (`useProductIntelligence`), videos
(`useProductMedia`), discovery lanes (`useProductDiscoveryLanes`), competitor observations and the
drawer's review/creator/supplier-verification sections. No parallel drawer was built.

## 5. Verification — GB (req 2, 7)
- **Backend selftest `fn_product_explorer_selftest`: 8/8 PASS** — GB page 1 (total 28) + page 2,
  Best Sellers purity, search narrows, cover coverage, dedup by identity, JP country-isolation
  empty, cross-tenant empty.
- **GB data quality (queried directly, GB tenant):** 28 distinct products · **28 with covers
  (100% image coverage)** · 28 enriched with GB decisions (all render as cards). Facets: Newly
  Listed 10 · Best Sellers 10 · High Growth 7 · Most Promoted 10.
- **Live deployment — bundle-verified on the production custom domain**
  `globalintelligenceactions.com`: the served workspace chunk references `fn_product_explorer`,
  `fn_product_explorer_markets`, all six filter labels, all five sorts, the "Product explorer"
  title, the "No FastMoss discovery…" empty state, `Reference only`, `No image`, `no-referrer`,
  and `concreteProductActionsAllowed`. The published build is commit `67ee050c`.
- **Frontend tests (Lovable):** 280/280 pass (43 files, 8 new), `tsc --noEmit` clean, new/changed
  files 0 lint. Decoder tests assert fail-closed empty page, UNKNOWN→null, https-only covers,
  identity dedup.

## 6. Deliberate design note — Explorer rows fail closed on sellable actions
Explorer rows carry **no server product-identity verdict**, so inside the drawer the sellable /
commerce actions and the page builder are **hidden** (`concreteProductActionsAllowed={false}`) —
fail-closed, consistent with Product Asset Lock. All **intelligence** (metrics, covers, videos,
lanes, reviews, creators, supplier verification, evidence) is fully available; only the actions
that would treat a product as sellable are gated. To unlock those from the Explorer, the server
would need to supply the product-identity check for Explorer rows (a follow-up, not a defect).

## Preserved (req 6)
All 18 markets, multilingual handling, founding-member access, tenant RLS, Product Asset Lock
(REFERENCE_ONLY unchanged) and the existing publishing architecture. GB (28) and DE discovery data
preserved; no completed backend work repeated; **no new paid provider calls**, no RLS bypass, no
redesign outside Products.

## Status: PASS (backend + deployment) / PARTIAL (live signed-in visual)
**Verified:** selftest 8/8, GB 28 products @ 100% cover coverage, six facet-counted filters +
search + sort + pagination, reused drawer, dedup by identity, UNKNOWN≠0, build `67ee050c` published
and **bundle-verified live** on `globalintelligenceactions.com`.

### Remaining / caveats
1. **Signed-in visual verification** — this environment cannot hold a founding-member session, so
   the final pixel-level customer experience (cards rendering with images, filter clicks, drawer
   open) must be confirmed by a signed-in member. Not claimed as visual PASS here.
2. **Explorer sellable actions** are intentionally fail-closed (§6); unlocking needs a server
   identity verdict for Explorer rows — a product decision, not a bug.
3. Pre-existing: 10 older DE FastMoss products lack stored covers (predate cover persistence);
   they render honestly without an image and can only be re-covered by a fresh paid pull.

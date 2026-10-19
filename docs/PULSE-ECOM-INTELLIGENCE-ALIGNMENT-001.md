# PULSE-ECOM-INTELLIGENCE-ALIGNMENT-001

**Final intelligence alignment for the signed-in Product Explorer: verify the live Explorer + the
Sales / Pricing / Advertising / Competitor server contracts, and expose GENUINE market-specific
advertising + competitor/pricing evidence in the reused Product Intelligence drawer — honestly
labelled, UNKNOWN never shown as 0, no new paid calls, nothing rebuilt. Backend `mig_312`
(additive: scoped competitor-evidence read + price range, + capture of the already-deployed ad-evidence
contract). Frontend: two new drawer sections wired to the real contracts + a card stale indicator.**

## 0. What is genuinely available (verification, req 1 & 4)
Investigated every advertising/pricing/competitor contract and the actual data behind them:
- **Sales / revenue / growth / promotions / covers** (FastMoss discovery) — populated for all 28 GB
  Explorer products; unchanged and preserved (req 2).
- **Advertising** — `fn_product_ad_evidence` (contract `pulse_product_ad_evidence_v1`, Meta + TikTok
  Ad Library): observed advertisers, creatives, coverage state, `zero_vs_unknown`
  (OBSERVED / ZERO_WITH_ADEQUATE_COVERAGE / UNKNOWN), market support, persistence, freshness. It was
  **deployed but not in a committed migration** — captured now (grant + contract comment) with no body
  rewrite. Grant: `authenticated`, `service_role` (browser-ready).
- **Competitor + pricing** — `product_market_competitors` (per tenant/product/market) carries genuine
  competitor prices, `price_currency`, `observable_ad_count`, `ad_status`, `creative_pattern`,
  `offer_pattern`, `cta_pattern`, and freshness. Read contract `fn_ecommerce_competitor_intelligence`
  exists but returns the WHOLE tenant set unfiltered.
- **Pricing engine** — `fn_stage3b_market_pricing` is `service_role`-only (not browser-callable); not
  used client-side.

**The decisive data fact:** the ad / marketplace / competitor evidence in the database belongs to the
tenant's *older research products* and the global-intelligence pool — **0 rows sit on the FastMoss
Explorer products** (research was suppressed during GB ingestion, so no paid calls). Verified:
- GB Explorer products with advertising rows: **0**; with marketplace rows: **0**; competitor rows: **0**.
- The GB tenant *does* own 1,964 competitor rows (all priced, 10 markets) — but on older research
  products, not the Explorer's.
- A live product that *was* researched returns genuine OBSERVED advertising (e.g. Meta: 22 advertisers,
  29 creatives, 35 days active) — proving the contract lights up where research ran.

Conclusion: for every product currently in the Explorer, advertising + competitor/pricing are honestly
**“not researched yet” / UNKNOWN**, not zero. The correct alignment is to WIRE these real contracts into
the drawer with clear availability/freshness labelling — so the capability is genuine and present and
lights up the moment research runs — never to fabricate numbers.

## 1. Backend — `mig_312` (additive, no DROP, NO paid calls)
- **`fn_product_competitor_evidence(p_product_id, p_country)`** (`pulse_product_competitor_evidence_v1`)
  — scoped per-product + market read of `product_market_competitors` (same row shape as the existing
  contract): competitor rows (identity, price+currency, observable ad count, creative/offer/cta
  patterns, freshness), a **single-currency price range** (`observation` OBSERVED|UNKNOWN, currency,
  sellers, low/median/high, `excluded_other_currency`), an `ad_summary`, and `freshness`
  (newest_observed_at, `stale` at 14 days). `auth.uid()`-scoped, country-isolated, cross-tenant
  fail-closed, REFERENCE_ONLY, **UNKNOWN never 0**. Replaces the drawer's whole-tenant competitor pull
  with an efficient scoped read. Grant: `authenticated`, `service_role`.
- **Captured the ad-evidence contract** (`fn_product_ad_evidence`) grant + a documenting COMMENT, with
  **no behaviour change** (the live body is untouched), fixing the deploy-vs-repo drift.
- **Selftest `fn_product_competitor_evidence_selftest` — 5/5 PASS**: market_required; honest-empty
  (UNKNOWN, low=null) for a discovery-only product; JP country isolation empty; populated case with an
  ordered single-currency range (GBP: 162 sellers, low £4.99 / median £13.99 / high £135.90, 0 excluded);
  cross-tenant rejected.
- **No regression**: Explorer selftest 8/8, preflight contract check 13/13 after mig_312.

## 2. Frontend (Lovable) — reused drawer + compact card (req 3, 5, 6)
Two fail-closed decoders + hooks (one RPC call each, scoped to the selected product+market), rendered as
two new sections inside the EXISTING `ProductIntelligenceDrawer` (the shared drawer is reused, not
replaced); the built-in "Competitors"/"Advertising" count sections are suppressed in the Explorer path so
there is no duplication.
- **"Advertising & competition"** (from `fn_product_ad_evidence`): a combined state chip
  (Observed / Low observed ad competition / Unknown) + per-platform Meta & TikTok rows. Honest labels:
  OBSERVED → "{n} advertisers · {m} creatives" (+ Meta "{d}d active", TikTok first/last shown);
  ZERO_WITH_ADEQUATE_COVERAGE → "0 advertisers (adequate coverage)" (a positive low-competition signal,
  said explicitly); UNKNOWN → "Not researched yet" (NO_RUN) or "Not available in {market}" (unsupported).
  Freshness "As of {date}" / "No research run yet", 14-day stale.
- **"Competitor prices"** (from `fn_product_competitor_evidence`): genuine price range
  (low–high · median · sellers) when OBSERVED, else the honest "No competitor prices observed for this
  market yet."; up to 12 REFERENCE_ONLY competitor rows (identity, price, ad count, creative/offer chips,
  observed date, https-only link); ad summary; freshness + stale.
- **Explorer card**: the existing "Seen {date} · Reference only" line now shows muted "· Stale" when the
  signal is older than 14 days. No per-card advertising/competitor fetches (card stays compact;
  advertiser/seller/video counts remain "—", never a fabricated 0).
- Decoder unit tests: fail-closed on non-ok; UNKNOWN stays null; OBSERVED vs ZERO_WITH_ADEQUATE_COVERAGE
  vs UNKNOWN labelled distinctly; price-range formatting; https-only links; UNKNOWN price never renders 0.

## 3. Preserved (req 2, 7)
Sales/revenue/growth, search, the 6 filter tabs, sorting, covers, pagination, the reused drawer and all
its existing sections; Product Asset Lock (`concreteProductActionsAllowed={false}` for Explorer rows);
18-market isolation (every read passes the drawer's market as `p_country`); tenant RLS / server-owned
auth; founding-member access. No new paid provider calls; no redesign outside the Products/drawer scope.

## 4. What paying subscribers can actually see now
- All 28 GB products with real covers + sales/revenue/growth/promotions, working filters/search/sort/
  pagination (unchanged).
- Opening a product now shows **"Advertising & competition"** and **"Competitor prices"** sections. For
  today's GB products these honestly read **"Not researched yet"** / **"No competitor prices observed for
  this market yet"** (market supported, research suppressed) — never a fake 0. The moment a product is
  researched (a budgeted, approved run), the same sections display genuine advertisers, creatives,
  persistence, competitor prices + range, and freshness.
- Cards flag **stale** discovery signals (>14 days).

## Status: PASS (backend + deployment, bundle-verified live) / PARTIAL (live signed-in visual)
**Backend:** `mig_312` committed + deployed (competitor evidence selftest 5/5; Explorer 8/8; preflight
13/13; no paid calls). **Frontend:** Lovable build `d1af4e35` **published to
`globalintelligenceactions.com`** — 288/288 tests, tsc + production build clean. The refinement
suppresses the drawer's built-in Competitors/Advertising sections in the Explorer path, so the drawer
now has exactly **one** "Advertising & competition" section and **one** "Competitor prices" section (no
duplicates); the legacy DecisionsBody is unchanged.
**Live bundle verification** (production chunk on `globalintelligenceactions.com`): references
`fn_product_ad_evidence`, `fn_product_competitor_evidence`, "Advertising & competition", "Competitor
prices", "Not researched yet", "0 advertisers (adequate coverage)", "No competitor prices observed",
"Low observed ad competition", "Not available in", plus every preserved Explorer marker
(`fn_product_explorer`, filters, "Reference only", empty state, `concreteProductActionsAllowed`,
"Stale") — no regression. **Visual PASS requires a signed-in member session and is NOT claimed here.**

### Remaining / launch-critical gaps
1. **No researched advertising/competitor/pricing evidence exists on the Explorer products yet** — this
   is a data gap, not a code gap. Populating it requires an approved, budgeted research run (paid Meta
   Ad Library / marketplace / Kalodata). The UI is wired and honest in the meantime. Not run here (no
   approval for paid calls).
2. **Signed-in visual verification** — this environment cannot hold a founding-member session; the final
   pixel-level drawer experience must be confirmed by a signed-in member. Not claimed as visual PASS.
3. **Pre-existing, unrelated test drift**: `fn_ecommerce_intelligence_contracts_selftest` reports 2
   failing cases (`founder_signal_types_real`, `founder_brief_unlinked`). `founder_signal_types_real`
   asserts the founder tenant has ONLY community/search signal types — an invariant made stale by the
   earlier (approved) FastMoss discovery population, not by this change. Left as-is (out of scope; would
   mean rewriting an old reconcile test's expectations).

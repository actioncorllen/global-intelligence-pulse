# STRATELOQ-ECOM-MULTI-MARKET-PRODUCT-RESEARCH-013M

**FINAL VERDICT: `MULTI_MARKET_RESEARCH_READY_TIKTOK_PENDING`.**

An authenticated user can now research the SAME canonical product in a different selected market:
`kids nightlight projector` was researched end-to-end in **DE** through the canonical Product × Market
pipeline (real eBay/DataForSEO/CJ + cross-market Reddit reuse; Meta ran but found no product match;
TikTok blocked-pending) as an independent run, producing a market-specific DE decision **without
touching GB evidence or the business home country**. TikTok remains `BLOCKED_EXTERNAL_APPROVAL /
APPLICATION_SUBMITTED`, so full launch-standard deep research stays PARTIAL per market. No Lovable
change, no publish, no payment, no cadence change, no new provider/country beyond DE.

Migrations: `mig_249_market_catalog_contract.sql`, `mig_250_research_inflight_dedup.sql`.

---

1. **Existing market architecture** — `ecommerce_market_universe` (18 eligible markets, country_code/
   default_currency), `provider_capability_registry` (per-market availability), `product_market_evaluations`
   & `product_opportunity_decisions` (keyed by country_code), `commerce_research_run` (per `market`),
   `commerce_signals` (`value->>'market'`), `product_market_competitors` (country_code),
   `commerce_supplier_products` (global catalogue). One `commerce_products` row per canonical product.
   No second architecture created.
2. **Business vs research market** — home country lives in `business_profiles.country`; the product
   research market lives in the evaluation/decision/run rows. Research writes only evidence/eval/decision/
   run tables, never `business_profiles`. Verified: founder `business_profiles.country = GB` before and
   after DE research.
3. **Canonical market catalog** — reused `ecommerce_market_universe` + `provider_capability_registry`;
   added the browser-safe **`fn_ecommerce_supported_markets()`** (authenticated) returning 18 markets
   with country_code / country_name / currency_code / research_supported / available_source_count /
   launch_critical_blocked / per-category provider_coverage. No country list belongs in Lovable.
4. **Product × Market identity** — one canonical product id; market-specific evaluations, decisions,
   signals, competitors, research runs. The product is never duplicated when the market changes.
5. **Secure research request contract** — existing `fn_own_request_product_market_research(p_product_id,
   p_market, p_freshness_hours)`: `auth.uid()` → product ownership check, market validated against the
   universe, tenant resolved server-side (never from browser), no provider credentials to the browser.
6. **Provider applicability** — registry-ranked per market (market-specific AVAILABLE > global AVAILABLE
   > blocking state). DE: Reddit/DataForSEO/eBay/Meta/CJ AVAILABLE, TikTok BLOCKED_EXTERNAL_APPROVAL.
   Providers unsupported in a market surface as UNSUPPORTED_MARKET, never a silent skip or false success.
7. **Research status model** — `fn_ecommerce_research_coverage()` returns per (product, market):
   research_status (`COMPLETE` / `PARTIAL` / `PARTIAL_SOURCE_UNAVAILABLE`), sources_with_evidence,
   sources_not_searched, sources_blocked_or_unsupported, launch_critical_gap, opportunity_score/band,
   evidence_confidence and grade — kept separate from opportunity score. A high score never implies
   research completeness.
8. **Idempotency / duplication** — completed-run freshness dedupe (168h → `CACHE_REUSED`); **new**
   in-flight guard (mig_250): a second request while a run is RESEARCHING (<1h) returns
   `CACHE_REUSED_IN_FLIGHT` instead of a concurrent duplicate; force-fresh (`p_freshness_hours<=0`)
   always creates. The canonical product is never duplicated. (A duplicate concurrent DE run created
   before the guard was added was cleaned up.)
9. **Currency** — each observation keeps its source/original currency (eBay EUR for DE, GBP for GB;
   DataForSEO CPC USD; CJ USD); economics use the market's default currency; historical source prices
   are never silently converted. Execution-platform currency rules unchanged.
10. **DE execution provider matrix** — MARKETPLACE/eBay `SEARCHED_EVIDENCE_FOUND`; SEARCH_DEMAND/
    DataForSEO `SEARCHED_EVIDENCE_FOUND`; SUPPLIER/CJ `SEARCHED_EVIDENCE_FOUND`; COMMUNITY/Reddit
    `SEARCHED_EVIDENCE_FOUND` (cross-market reuse, not GB/DE-verified); ADVERTISING/Meta
    `SEARCHED_NO_EVIDENCE` (German ads returned, none matched the product name — a legitimate no-evidence
    result, not a skip); SOCIAL_VIDEO/TikTok `BLOCKED_EXTERNAL_ACCESS`.
11. **Expected/actual external cost** — DataForSEO DE: estimate ≈ €0.09; actual **$0.09 + $0.013 =
    ≈ €0.09** (search_volume + search_intent, location 2276). eBay/Meta/CJ free; Reddit reused. ≤ €1 gate met.
12. **DE evidence coverage** — 0.63.
13. **DE evidence confidence** — MEDIUM.
14. **DE opportunity score** — 69.2.
15. **DE Product Decision** — WATCH.
16. **GB vs DE**

| | GB | DE |
|---|---|---|
| decision | WATCH | WATCH |
| opportunity_score | 68.2 | 69.2 |
| coverage | 0.78 | 0.63 |
| evidence_confidence | HIGH | MEDIUM |
| buyer_search_intent | 61 | 50 |
| advertising | 48 | none (no product match) |
| marketplace | 100 (743 listings) | 100 (69 listings) |

    Same canonical product, genuinely different demand/competition/advertising/score/confidence by market.
17. **GB not overwritten** — GB evaluation unchanged (68.2 / 0.78 / HIGH / bsi 61 / adv 48); GB
    MARKETPLACE signals still 106; GB run `ae239472` intact. DE evidence is a separate run/market.
18. **Business country not changed** — `business_profiles.country` = GB before and after DE research.
19. **TikTok state** — registry SOCIAL_VIDEO `SOURCE_UNSUPPORTED`, limitations
    `BLOCKED_EXTERNAL_APPROVAL; APPLICATION_SUBMITTED (founder-reported)`; represented truthfully in DE
    coverage (blocked, launch_critical_gap true); no fabrication, no build against unissued credentials.
20. **Security** — market catalog + request contracts authenticated, `auth.uid()`-scoped; anon denied
    (28000); cross-tenant denied (42501, unchanged from 013J); ingest/finalize/reuse service_role only;
    no browser provider credentials. Advisors: 5 categories, unchanged.
21. **Regression** — relevance (013L) 10/10; orchestrator 7/7; deep-research (013I) / 013A / 013E /
    entitlement / storefront (runtime+publish+branding+lifecycle) all_pass. Founder COMP entitlement
    unchanged (2). No fixtures entered founder decisions. No synthetic evidence. No recurring n8n cadence
    change.
22. **Exact Lovable contract for next unit** (read-only spec; not built here):
    - **Market selector** ("Selected market ▾ / Search countries…"): `supabase.rpc('fn_ecommerce_supported_markets')`
      → `{ status, count, markets:[{country_code, country_name, currency_code, research_supported,
      available_source_count, launch_critical_blocked, provider_coverage:[{evidence_category, source, state}] }] }`.
    - **Research this product in <country>** ("Search this product in Germany"):
      `supabase.rpc('fn_own_request_product_market_research', { p_product_id: <uuid>, p_market: 'DE' })`
      → `{ status: RESEARCHING | CACHE_REUSED | CACHE_REUSED_IN_FLIGHT | UNSUPPORTED_MARKET | PRODUCT_NOT_FOUND,
      run_id, market, market_currency, sources_expected, dispatch_manifest[], tiktok }`. Request fields:
      `p_product_id`, `p_market` (+ optional `p_freshness_hours`); **no tenant/business id from the browser**.
    - **Research status**: `supabase.rpc('fn_ecommerce_research_coverage')` → filter the returned rows by
      `product_id` + `market`; render from `research_status` + `launch_critical_gap` + `sources`:
      Researching / Deep research complete / Partial — provider unavailable / Partial — provider failure /
      Insufficient evidence, plus per-source coverage.
    - **Remaining connection**: the request RPC creates the run; the provider executors are dispatched
      server-side (n8n). Auto-triggering the executors from the request (pg_net → executor webhook) is the
      one small wiring left for full one-click operation (same follow-up noted in 013J); execution itself
      is proven real here.
23. **Files/functions/migrations/workflows** — `mig_249_market_catalog_contract.sql`
    (`fn_ecommerce_supported_markets`), `mig_250_research_inflight_dedup.sql`
    (`fn_own_request_product_market_research` in-flight guard + duplicate cleanup). n8n: the four existing
    manual executors were repointed to the DE run/market for the test (no new workflows, no schedule change).
24. **Commit** — see delivery message.
25. **Push / divergence** — branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

**STOP. No Lovable country selector started. No additional market started.**

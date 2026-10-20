# PULSE-ECOM-STAGE4A-LIVETEST-PRODUCT-001

**Final live-test product selection for ONE bounded GB FastMoss research run. Read-only / cached
discovery data only. No paid API call was made, no workflow modified, no stage advanced. The run is
NOT started — this is the selection + confirmed costs for founder approval.**

**Selected: the "Illuminated Snowman Christmas Door Hanger" (`873551b0-a0d0-44f6-8792-7b2650d904cd`),
GB, tenant `7c8ddf9d…`.** Generic/unbranded, concrete distinctive identity, classic CJ seasonal-LED
category (best realistic chance of an exact supplier bind + genuine supplier images), observed price
£9.99, light/cheap (realistic GB dropship freight), no brand/IP token. It is already registry-eligible
for deep research and fully un-researched. The entire run makes **exactly two metered external calls,
both DataForSEO**; every other source is free-tier or cached.

## 1. Why this product (selection from cached GB FastMoss discovery)
The GB FastMoss Explorer holds 29 discovery products. Branded items were excluded for brand/IP risk and
poor generic-supplier odds (Ninja ×2, Shark, medicube ×2, Halara, TYMO, Bellavita ×2, Victoria's Secret,
P.Louise, Laka, Dr.Reju-All, Dr.Melaxin, Wellgard, GoDyna). Among the genuinely generic/unbranded items:

| Candidate (id) | CJ-match odds | IP risk | Price for economics | Verdict |
|---|---|---|---|---|
| **Snowman LED door hanger** `873551b0` | **High** (common CJ seasonal LED decor) | **None** (snowman is generic) | **£9.99 present** | **SELECTED** |
| iPhone colour-block phone case `22ad26d4` | High | "iPhone" tokens → `branded_or_ip` + query pollution | £9.99 | rejected (IP token) |
| Energy-drink-can plush `b90e384f` | Medium | can shape → trade-dress risk | none | rejected (IP) |
| Old-man-face balaclava `56a6af36` | Medium | none | none observed | runner-up (no price) |
| Crystal-bracelet gift set `e68bd67d` | Medium | none | £2.66 | fuzzy identity |
| Men's mid-calf socks `77b59112` | High stock, **no exact identity** | none | none | rejected (no exact bind) |

The Snowman is the only candidate that is simultaneously generic, IP-clean, distinctive enough for an
exact-ish supplier match, in a high-CJ-availability category, and carries an observed price for the
economics projection.

## 2. Concrete identity & variants (confirmed from cached data)
- **Stored identity** (`product_identity`): *"Illuminated Snowman Christmas Door Hanger, Warm Led Lighted
  3D Dimensional Holiday Hanging Decor, for Front Door, Porch Column, Wall, Window & Covered Outdoor
  Entryway."* Source store `fastmoss`, lane `NEW_LISTED`, market GB, price £9.99, units 499.
- **Variants:** FastMoss discovery carries a **single concrete SKU reference** (no variant array stored).
  Variant/colour/size breakdown is **a CJ-run output**, not pre-stored — it would be resolved from the
  CJ supplier match, not invented here.
- **Media today:** one `PROVIDER_DISCOVERY_REFERENCE` FastMoss image (reference-only, **not** store/ad
  usable). Genuine supplier images would come from the CJ match (see §5).
- **Eligibility:** registered in `monday_opportunity_registry` (active, GB) → passes the
  `fn_auto_dispatch_candidate_research` eligibility gate. **Research state: 0 runs, 0 non-native
  signals, 0 open provider budgets — a clean slate.**

## 3. Exact dispatch path (verified, no new workflow)
`fn_auto_dispatch_candidate_research(tenant, product, 'GB')` → eligibility + kill-switch check →
`fn_research_request_core(…,168,'auto_fresh_discovery')` creates the run + one source-attempt row per
evidence category (provider chosen by registry rank for GB) → `fn_research_dispatch(run_id)` fires the
single `research_executor_webhook` → n8n **"Pulse — Research Auto-Dispatch Executor (013N)"**
(`QjYMzrCm1cDXxUS4`, active) reads `fn_research_run_manifest` and runs only the branches whose
`dispatch[source].action = 'DISPATCH'` → each branch posts to `fn_research_ingest_source` →
`fn_finalize_research_run` → projected to the drawer by the Stage-4A contracts
(`fn_ecommerce_product_intelligence` / `fn_product_competitor_evidence` / `fn_product_ad_evidence` /
`fn_product_media_state` / `fn_product_decision_customer`).

## 4. Exact provider calls (the executor is fixed & loop-free — no pagination, no retry fan-out)
| Source (evidence) | Exact call(s) | Metered? | Cost |
|---|---|---|---|
| **DataForSEO** (SEARCH_DEMAND) | **2 live POSTs:** `keywords_data/google_ads/search_volume/live` + `dataforseo_labs/google/search_intent/live`, each ONE task carrying the ~3 title-derived seeds | **YES — the only paid element** | see §5 |
| CJ (SUPPLIER) | 1 auth + 1 `product/list` (pageNum 1, **pageSize 20**, productNameEn = search identity) | No | $0 (CJ API free) |
| eBay (MARKETPLACE) | 1 OAuth + 1 Browse `item_summary/search` (q=identity, limit 100, EBAY_GB) | No | $0 (public Browse) |
| Meta (ADVERTISING) | 1 `ads_archive` GET (search_terms=identity, country GB, limit 50) | No | $0 (public graph) |
| TikTok (SOCIAL_VIDEO) | 1 token (edge fn) + 1 `research/adlib/ad/query` (GB, last 90d, max_count 20) | No | $0 |
| Reddit (COMMUNITY) | **0 new** — manifest action `REUSE` (720h cache) | No | $0 |

**Total new external calls: ~9, of which exactly 2 are metered (both DataForSEO).**

## 5. Confirmed cost + verification done
- **Source access — VERIFIED (read-only):** all five provider credentials exist in n8n and are the exact
  ones wired into the active executor — `Pulse DataForSEO` (`OYKLUdhcUwGJ8ymT`, httpBasicAuth), `CJ
  Dropshipping API`, `Pulse eBay Production`, `Pulse Meta Ad Library User`, `Pulse TikTok Commercial
  Content`. Credential **validity** can only be proven by a live call, which was deliberately **not**
  made.
- **DataForSEO pricing — NOT stored in-system; documented list prices, UNCERTAIN:** the price is not
  recorded anywhere in the database (registry only says "pay-as-you-go"). Documented list prices for the
  two exact endpoints: `google_ads/search_volume/live` ≈ **$0.05/request**; `dataforseo_labs/…/search_intent/live`
  ≈ **$0.01/request** → **≈ $0.06 per run**, dominated by search-volume. **This figure must be confirmed
  against the live account** (DataForSEO dashboard, or the free `appendix/user_data` balance/price
  endpoint) before the run. I did **not** call it: no existing workflow hits only that free endpoint, and
  creating one would be "modifying workflows", which this task's STOP forbids.
- **Enforceable maximum (price-independent):** the executor makes a **fixed 2 DataForSEO live tasks** —
  there is no loop, pagination or fan-out, so the run cannot exceed two tasks regardless of the per-task
  price. So even under a worst-case mispriced account the ceiling is "2 live tasks", realistically
  **≤ ~$0.20**.

## 6. Expected evidence (honest)
- **Supplier (CJ):** a *plausible positive bind* for this generic seasonal item (unlike the branded Ninja)
  — up to 20 candidates with pid, SKU, **one primary supplier image each (`SUPPLIER_PROVIDED`)**, supplier
  cost (USD), weight, free-shipping flag, shipping-country list. **Limitation:** `product/list` returns a
  single image per candidate and **no variant breakdown and no GB freight** — the full image gallery +
  per-variant detail + GB freight are a **separate, also-free** CJ step (CJ Detail + Freight probe), not
  part of this bounded run.
- **Competitor pricing:** genuine GB range from eBay (+ DataForSEO merchant signals) — `OBSERVED`, GBP.
- **Advertising:** Meta GB + TikTok Ad Library advertiser presence, or honest `SEARCHED_NO_EVIDENCE`
  (never a fabricated 0).
- **Search demand:** DataForSEO volume/CPC/competition/intent, clearly `ESTIMATED`/`INFERRED`.
  **Limitation:** seeds are derived from a long descriptive title, so the full-title seed will likely
  return near-zero volume and the tail seeds are generic — search-demand may come back thin.
- **Decision:** a WATCH/AVOID via `fn_product_decision_customer`; campaign launch stays **BLOCKED**
  (Product Asset Lock), never a WINNER pre-spend.

## 7. Preservation (verified in the dispatch contracts)
- **Tenant isolation:** `fn_research_request_core` rejects a product whose `user_id <> caller`
  (`NOT_AUTHORIZED`); tenant resolved server-side.
- **Market isolation:** per-market scoping throughout (GB loc 2826, `EBAY_GB`, market currency GBP);
  a market with no location code is `SKIP_NO_LOCATION`.
- **Product Asset Lock / provenance:** FastMoss image stays `REFERENCE_ONLY`; any CJ image is
  `SUPPLIER_PROVIDED`; campaign launch/handoff stay blocked for non-TEST.
- **Budget controls:** advisory xact-lock on (tenant+product+market) blocks double-spend from
  double-click/retry/concurrency; **7-day freshness reuse** returns `CACHE_REUSED` with no dispatch;
  **1-hour in-flight dedup** returns `CACHE_REUSED_IN_FLIGHT`; the **`pulse.suppress_dispatch='on'`
  kill-switch** creates the run but fires nothing (currently OFF); the executor's fixed 2-task DataForSEO
  shape caps spend by construction.

## 8. Smallest bounded run + approvals needed
- **Scope:** ONE product (Snowman `873551b0`) × ONE market (GB) × ONE `fn_research_request_core` call.
- **Optional $0 pre-flight:** run once with `pulse.suppress_dispatch='on'` to create the run and prove the
  manifest/gating fire correctly with **zero external calls**, before the real (suppress-off) run.
- **Maximum cost:** 2 DataForSEO live tasks ≈ **$0.06** (documented, uncertain), hard structural ceiling
  **≤ ~$0.20**. All other sources $0.
- **External approvals:** (a) **founder spend approval for the 2 DataForSEO live tasks** — the only paid
  element; (b) **recommended $0 precondition:** confirm live DataForSEO balance/price via the free
  `appendix/user_data` endpoint (needs a tiny read-only probe node — not created here, per STOP); (c)
  nothing else — CJ/eBay/Meta-GB/TikTok-AdLib are authorised and free.

**STOP — selection only.** No research executed, no paid provider called, no workflow modified, Stage 4B
not started.

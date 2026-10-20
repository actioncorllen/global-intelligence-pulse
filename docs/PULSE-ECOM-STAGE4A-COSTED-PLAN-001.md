# PULSE-ECOM-STAGE4A-COSTED-PLAN-001

**Read-only, costed execution plan for ONE bounded GB FastMoss product research run. No paid API call
is authorised or made by this document — it is a plan for founder approval. Verified from the live
system (provider_capability_registry, fn_market_provider_config('GB'), the provider-call budget and
Stage-1/Stage-2 dispatch contracts). Headline: the ONLY metered $ provider in the run is DataForSEO;
CJ, Meta (GB), TikTok Ad Library, eBay (GB) and Reddit are free-tier/already-authorised, and FastMoss/
Kalodata are the already-paid discovery subscriptions. Estimated maximum incremental cost for one
product×country run ≈ $0.05 typical, ≤ ~$0.20 worst case, all of it DataForSEO (exact per-call price
is NOT stored in-system — verify against the DataForSEO account before running).**

## 1. Target product
**Ninja 3-in-1 Food Processor & Blender BN800UK** — `306f3e5a-b2a6-4844-beb5-09c642dbe341`, market **GB**,
tenant `7c8ddf9d…`. Strong exact-identity anchor (brand "Ninja" + exact model "BN800UK"); genuine
FastMoss commerce momentum (11,829 units / £1.79M). All six research sources are currently
**NOT_SEARCHED** for it (verified via `fn_ecommerce_research_source_states`).
- **Honest expectation:** because this is a *branded* appliance, the CJ supplier step will most likely
  resolve to **NO_VALID_CJ_MATCH** and the lifecycle may raise the **`branded_or_ip`** disqualifier —
  i.e. a correct "no sellable generic supplier" outcome, not a bind. That makes the Ninja an excellent
  test of the pipeline's *honesty* (no fabricated supplier) but it will not demonstrate a positive
  supplier bind. If the goal is to demonstrate a positive CJ bind + variants + shipping, a **generic
  unbranded** GB discovery product is the better exact-identity case (the night-light already proved
  that positive path in cached data). Recommendation: run the Ninja as requested; I can identify a
  generic alternative on request.

## 2. Existing workflow (discovery → research → supplier → Intelligence drawer)
Single gated entry point — no new workflow needed:
1. `fn_auto_dispatch_candidate_research(user_id, product_id, 'GB')` → creates a `commerce_research_run`
   (`sources_expected/attempted/with_evidence/no_data/unsupported/failed`).
2. `fn_research_dispatch(run_id)` → per source calls `fn_invoke_provider_broker(function, payload,
   user_id, market)`, each gated by the hard provider-call budget `fn_provider_budget_open(provider,
   user, market, max_calls, note, ttl)` + `fn_provider_budget_try_consume(...)` (mig_310), ledgered in
   `provider_call_budget` / `provider_call_ledger`.
3. Provider executors (reused, unchanged): CJ supplier search = n8n `stage2-cj-supplier-search`
   (`fn_stage2_cj_search_claim → fn_stage2_supplier_search_queries / fn_stage2_cj_retrieval_plan →
   CJ product/list (paginated, `fn_stage2_cj_budget` + `fn_stage2_cj_should_continue`) →
   fn_stage2_resolve_from_pages / fn_stage2_cj_finalize_candidates → fn_stage2_cj_search_complete`);
   DataForSEO = n8n DataForSEO discovery; Meta/TikTok/eBay/Reddit via their edge-function brokers.
4. `fn_finalize_research_run(run_id)` + `fn_research_run_manifest(run_id)` close the run; evidence is
   then projected by `fn_ecommerce_product_intelligence` / `fn_product_competitor_evidence` /
   `fn_product_ad_evidence` / `fn_product_media_state` / `fn_product_decision_customer` into the drawer.

## 3. Minimum necessary calls per source (verified access)
| Source | Evidence | GB access (registry) | Calls (min) | Classification | Incremental $ |
|---|---|---|---|---|---|
| **CJ Dropshipping** | Supplier SKU/variants/cost/freight/images | AVAILABLE | ≤ ~40 product/list (paginated, rate-limited ~1/s) | **FREE** (CJ API free; bounded by call-cap, not $) | $0 |
| **DataForSEO** | Search demand + GB merchant/SERP competitor prices | AVAILABLE ("pay-as-you-go", loc 2826/en) | 1–3 tasks | **METERED** | ~$0.05 (≤ ~$0.20) — **UNCERTAIN, verify account** |
| **Meta Ad Library** | GB advertiser presence/creatives | AVAILABLE (UK queryable) | 1 query | **FREE** (public graph API) | $0 |
| **TikTok Ad Library** | Advertiser presence (research.adlib.basic) | AVAILABLE (CONNECTED; re-verified 2026-09-29) | 1 query | **FREE** | $0 |
| **eBay Browse** | GB marketplace listings + price range | AVAILABLE (Browse, app OAuth, public) | 1–few search | **FREE** | $0 |
| **Reddit** | Cross-market community attention | AVAILABLE | 1 query | **FREE** | $0 |
| **FastMoss** | Product detail / media (already discovered) | subscription | 0–1 (mostly **CACHED**) | **CACHED / NOT_NEEDED** | $0 (subscription) |
| **Kalodata** | TikTok-shop analytics | subscription | 0 | **NOT_NEEDED** for GB | $0 (subscription) |
| **Google Ads (direct)** | Search demand | **SOURCE_BLOCKED** (no dev token) | 0 | **BLOCKED** → covered by DataForSEO, NOT_NEEDED | n/a |

## 4. Maximum cost for one bounded GB product run
- **Incremental metered cost = DataForSEO only ≈ $0.05 typical, hard-ceiling ≤ ~$0.20.** Every other
  provider in the run is free-tier (CJ/Meta/TikTok/eBay/Reddit) or already-paid subscription
  (FastMoss/Kalodata). **Uncertainty:** DataForSEO's exact per-task price is not recorded in the
  system (registry only says "pay-as-you-go"); the figure above is an external estimate and must be
  confirmed against the live DataForSEO account/endpoint mix before the run.
- **Volume is hard-bounded regardless of price** by `fn_provider_budget_open` max_calls per provider
  (e.g. CJ ≤ ~40 pages, DataForSEO ≤ a 1–3 task cap, others ≤ 1–few) with a short TTL window, so a
  run cannot run away even if a provider misbehaves. The $2/month Gemini translation cap (mig_315) is
  separate and untouched by a research run.

## 5. Expected outputs (honest)
- **Supplier:** most likely **NO_VALID_CJ_MATCH** (branded) → honest "no generic supplier"; if a match
  existed it would surface exact SKU + variants + weight + supplier cost + GB freight (as proven for
  the night-light: SKU, 8 variants, $4.50 GB shipping).
- **Competitor prices:** genuine GB observed range from eBay + DataForSEO merchant/SERP (the Ninja is
  widely retailed, so a real range is likely) — `OBSERVED`, GBP, `unknown_not_zero`.
- **Advertising:** Meta GB + TikTok Ad Library advertiser presence — `OBSERVED` or honest
  `SEARCHED_NO_EVIDENCE`, never a fabricated 0.
- **Search demand:** DataForSEO estimated volume / inferred intent (clearly labelled ESTIMATED).
- **Media:** keeps the existing FastMoss reference image; supplier/video media only if a CJ match
  (unlikely for branded).
- **Opportunity assessment:** a WATCH/AVOID decision via `fn_product_decision_customer` with full
  WHY/BUT/next-steps; `branded_or_ip` likely flagged; campaign launch stays **BLOCKED** (Product Asset
  Lock), never a WINNER pre-spend.

## 6. Preservation (unchanged by the run)
Country/tenant isolation (server-owned `auth.uid()`, per-market scoping, query-scoped country never
relabelled), Product Asset Lock (`auto_launch_campaign:false`, handoff BLOCKED for non-TEST), rights
provenance (`REFERENCE_ONLY` / `SUPPLIER_PROVIDED`), and the existing hard provider-call budget +
freshness stamping all remain in force.

## 7. Smallest viable live-test scope + approvals needed
- **Scope:** ONE product (Ninja BN800UK) × ONE market (GB) × ONE research run, with provider budgets
  opened at the minimum caps above and a short TTL.
- **Maximum cost:** ≈ **$0.05, ceiling ≤ ~$0.20**, all DataForSEO (uncertain — verify account pricing).
- **External approvals:** (a) **founder spend approval for the DataForSEO metered call(s)** — the only
  paid element; (b) nothing else required — CJ/Meta-GB/TikTok-AdLib/eBay-GB/Reddit are already
  authorised and free. Google Ads (SEARCH_DEMAND) and TikTok Research API (organic) remain
  `EXTERNAL_APPROVAL_REQUIRED`/`BLOCKED` but are **NOT_NEEDED** for this run (DataForSEO + TikTok Ad
  Library cover the gaps).

**STOP — plan only.** No research executed, no workflow modified, no paid provider called, Stage 4B not started.

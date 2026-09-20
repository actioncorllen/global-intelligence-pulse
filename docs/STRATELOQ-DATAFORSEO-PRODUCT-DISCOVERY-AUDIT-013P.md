# STRATELOQ-DATAFORSEO-PRODUCT-DISCOVERY-AUDIT-013P (audit only)

**FINAL VERDICT: `DATAFORSEO_VALIDATION_ONLY_DISCOVERY_EXTENSION_REQUIRED`.**

**Answer to the core question: A — DataForSEO is currently a validation/evidence source only.**
It is genuinely connected and returning real per-market search-demand evidence, but it has never
originated a product candidate. Every founder product was discovered by **Reddit** (10) plus one
`industry_blog` and one supplier/funnel artifact. The candidate-promotion plumbing needed for
search-demand discovery already exists and is source-agnostic (`resolve_product_entity` →
`ingest_commerce_product`, and even a dormant `ingest_search_demand` promoter), so the missing piece
is a small **DataForSEO discovery front-end** (autonomous keyword/category/rising-demand scanning
that emits candidate entities), not the downstream pipeline. No backend/Lovable change made; no paid
call made; nothing published.

---

1. **DataForSEO connected & operational? YES.** Real evidence, most recent **2026-09-20 08:29**.

2. **Evidence** — `commerce_signals` `SEARCH_DEMAND` (founder), all provenance-linked to research runs:
   | Product | Market | product-vol/mo | category-vol | effective | intent | observed |
   |---|---|---|---|---|---|---|
   | kids nightlight projector | GB | 1,600 | 7,390 | 4,186.5 | GOOD | 09-19 20:49 |
   | kids nightlight projector | DE | 110 | 110 | 148.5 | MODERATE | 09-19 22:35 |
   | over door shoe organizer | DE | 230 | 0 | 230.0 | MODERATE | 09-20 08:29 |
   Endpoint families: `keywords_data/google_ads/search_volume/live` + `dataforseo_labs/google/search_intent/live`
   (n8n executor `aVKNL2CFhyA8VUdm`, httpBasicAuth cred `OYKLUdhcUwGJ8ymT`). Markets queried: GB, DE.
   Failures: none. Values are real (GB star-projector category demand 2,900+/mo etc.), cost ≈ €0.09/run.

3. **Current DataForSEO role** — per-supplied-product **buyer-search-demand validation**: given an
   existing product's seeds, fetch search volume + buyer intent + competition + CPC + monthly history,
   classify relevance (013L tiers: product vs category vs solution), and attach `SEARCH_DEMAND` signals
   feeding `buyer_search_intent` in the WPS evaluation. It never creates or promotes a candidate.

4. **DataForSEO-originated products: 0.**

5. **Reddit-originated products: 10** (`cordless ring light`, `side lying support pillow`,
   `travel neck pillow`, `kids nightlight projector`, `reusable cooler ice pack`, `over door shoe organizer`,
   `side sleeper sleep mask`, `red light therapy led mask`, `digital picture frame`, `side sleeper bed pillow`).
   Full census (founder, 12 products, all `product_role=candidate`): **Reddit 10, industry_blog 1,
   other/unclassified 1** (`3 Channel Dash Cam`, 09-12, higher-ASP funnel, no discovery run). eBay 0, Meta 0,
   CJ 0, DataForSEO 0. Traced from `commerce_products.source_store` + `source_run_id → discovery_runs`
   (`entry_mode=no_store_yet`, all runs completed), not the UI label.

6. **Why workspace shows Reddit** — the card's "Source store" is `commerce_products.source_store`, set at
   candidate creation to the **original discovery source**. Because the only active discovery feeder is the
   Reddit Product-Attention Adapter, every candidate carries `reddit`. It is truthful provenance, just
   mislabeled (see §12). DataForSEO/eBay/Meta/CJ only ran later as validators, so they never appear as origin.

7. **Does a DataForSEO discovery capability already exist?** **Partially — the promotion plumbing exists,
   the discovery scanner does not.** `ingest_search_demand(p_user_id, p_source_run_id, p_entity, p_demand)`
   resolves an entity via `resolve_product_entity` (sellability + normalization gate) and, on ACCEPT,
   calls the source-agnostic `ingest_commerce_product(...)` to create a candidate, then attaches demand.
   So a search-demand entity *can* become a candidate. But `ingest_search_demand` is a **promotion
   receiver** that must be *handed* an entity + demand; there is no autonomous DataForSEO keyword/category/
   rising-demand **scan** that surfaces new commercial queries and calls it. `ingest_commerce_product` is
   the sole function that inserts into `commerce_products`, and it is fed only by the Reddit adapter today.

8. **Missing connection** — no n8n workflow (and no scheduled function) queries DataForSEO for
   high/rising commercial product queries and feeds `ingest_search_demand`. The 013K DataForSEO executor
   is validation-only (per-supplied-seed). `ingest_search_demand` has produced **0** products (dormant).

9. **Smallest implementation if discovery is built (NOT built here)** — reuse the existing plumbing:
   - New bounded n8n **"DataForSEO Discovery"** workflow: query a keyword-ideas / related-keywords /
     rising-demand endpoint for a small set of category/solution seeds, per target market.
   - Qualify each query with the existing gates: `fn_classify_search_query_relevance` (product relevance),
     buyer-intent band, meaningful volume, and (where available) demand growth/monthly history — **demand +
     commercial intent + product relevance**, never volume alone.
   - Normalize each qualified query into an entity → `ingest_search_demand` (or `resolve_product_entity` →
     `ingest_commerce_product` with `source_store='dataforseo'`) → register in `monday_opportunity_registry`.
   - Route the new candidate through the **mandatory multi-source deep-research pipeline** (013N auto-dispatch:
     Reddit/eBay/Meta/CJ + DataForSEO validation, TikTok when available) → canonical `product_market_evaluations`
     → Product Decision. **DataForSEO must not declare a winner by itself** — it only surfaces a candidate that
     must pass corroboration and the WPS gates.

10. **eBay / Meta / CJ discovery-vs-validation status** — all **validation-only**:
    `fn_ingest_ebay_listings`, `fn_ingest_meta_ads`, `ingest_cj_supplier_products` attach signals to an
    existing product; none insert candidates. The CJ Supplier Collector writes the global
    `commerce_supplier_products` catalogue (supply evidence), not `commerce_products` opportunities. So the
    architecture today is exactly the concern raised: **Reddit discovers, everyone else validates.**

11. **Recommended canonical multi-source candidate architecture** (target, audit recommendation only):
    each independent source (DataForSEO / eBay / Meta / CJ / Reddit) may **surface** a candidate through a
    thin source-specific discovery adapter → shared **candidate normalization + dedup** (`resolve_product_entity`
    against `commerce_products`) → single candidate registry → **mandatory multi-source deep research** →
    canonical Product×Market evaluation → Product Decision → Workspace. One promoter (`ingest_commerce_product`)
    and one research pipeline (013N) already exist and are source-agnostic; only the per-source discovery
    front-ends are missing. No source may promote straight to a decision.

12. **Is the "SOURCE STORE" label semantically correct?** **No.** `source_store` means the **original
    discovery source** (where the opportunity was first surfaced — a Reddit thread, a blog), not a store
    that sells the product. `reddit` is not a store. Recommend relabeling in Lovable to
    **"Discovered via: Reddit"** (audit recommendation; no Lovable change made here).

13. **Cost impact of enabling DataForSEO discovery** — bounded and controllable under the existing ≤ €1
    auto-proceed rule. DataForSEO keyword-ideas / related-keywords calls are ~$0.01–0.05 each; a weekly
    discovery scan of a small seed set (with a per-run call cap and the same cost gate used for validation)
    stays well under €1. No paid call was made in this audit — existing evidence (3 real signals, latest
    08:29 today) was sufficient.

14. **Files/workflows/functions that a future extension would touch** (none changed here): a new
    "DataForSEO Discovery" n8n workflow; a thin discovery/qualification function (reusing
    `fn_classify_search_query_relevance` + buyer-intent banding) feeding `ingest_search_demand` /
    `resolve_product_entity` → `ingest_commerce_product` (`source_store='dataforseo'`); registry insert
    into `monday_opportunity_registry`; then the unchanged 013N research pipeline. No WPS scoring change.

15. **Regression / security** — audit only: **no** migration, function, workflow, schedule, Lovable, or
    data change; no dispatch; no paid provider call; no force-fresh. 013O canonical market binding untouched;
    business country GB unchanged; product identity unchanged; TikTok still `SOURCE_UNSUPPORTED` (pending).
    Nothing published.

**STOP. Audit complete. Discovery extension NOT implemented.**

# STRATELOQ-DATAFORSEO-PRODUCT-DISCOVERY-013Q

**FINAL VERDICT: `DATAFORSEO_PRODUCT_DISCOVERY_READY`.**

The missing DataForSEO search-demand discovery adapter is implemented as an EXTENSION that
reuses the existing plumbing (no second pipeline). Proven end-to-end with real data: a
market-aware DataForSEO scan of the category **"humidifier" (GB)** surfaced **3 genuine new
product candidates** (`cool mist humidifier`, `cool air humidifier`, `humidifier for room`,
4,400/mo each) that were qualified (demand + commercial intent + product relevance +
sellability), promoted through `ingest_search_demand → resolve_product_entity →
ingest_commerce_product` (`source_store='dataforseo'`), registered, and one of which then passed
the **existing 013N multi-source deep-research pipeline** to a canonical WPS **WATCH** decision —
DataForSEO never declared a winner by itself. Migrations: `mig_255`, `mig_256`. n8n workflow:
`Pulse — DataForSEO Product Discovery (013Q)` (`dyIhrOkFp2QmrmTD`, manual-trigger). No cadence
change, no WPS change, no Lovable/publish.

---

1. **Discovery architecture implemented** — n8n (server-side DataForSEO calls) → `keyword_ideas`
   + `search_intent` → post raw keywords to service-role RPC `fn_dataforseo_discover_candidates`
   → per-keyword qualify (`fn_dataforseo_discovery_qualify`) → source-independent dedup →
   `ingest_search_demand` → `resolve_product_entity` → `ingest_commerce_product` (existing
   promoter) → `monday_opportunity_registry` (existing registry) → [existing 013N deep research →
   WPS → Product Decision]. Nothing duplicated.

2. **DataForSEO endpoint/capability used** — `dataforseo_labs/google/keyword_ideas/live` (candidate
   product queries + search volume + competition + monthly history) and
   `dataforseo_labs/google/search_intent/live` (buyer-intent labels), per market `location_code`
   (GB 2826). Credentials stay in n8n (httpBasicAuth `OYKLUdhcUwGJ8ymT`).

3. **Candidate qualification rules** (`fn_dataforseo_discovery_qualify`, pure/immutable) — a query
   qualifies only when ALL hold: buyer intent ∈ {commercial, transactional}; search volume ≥ 50
   (necessary, never sufficient); product relevance vs the discovery category via the 013L
   `fn_classify_search_query_relevance` ∈ {DIRECT_PRODUCT, CLOSE_VARIANT, CATEGORY_DEMAND,
   SOLUTION_DEMAND} (rejects accessory/service/informational/irrelevant/category-noise); and
   `resolve_product_entity` sellability = ACCEPT (rejects services/jobs/news/non-product). Offline
   selftest `fn_dataforseo_discovery_selftest` 7/7 (accepts real products, rejects service /
   informational / accessory / navigational / low-volume). Real proof: the "posture corrector"
   scan correctly rejected 14 medical/NHS navigational-informational queries and promoted 0 noise.

4. **Deduplication path** — SOURCE-INDEPENDENT match by normalized title against the founder's
   `commerce_products` before promotion. Same-source rediscovery is idempotent: replaying the 3
   humidifier candidates returned all `dedup_status='deduplicated'`, identical `product_id`s, and
   the DataForSEO product count stayed **3** (no duplicate). Cross-source: a rediscovery of an
   existing product reuses that product's `source_store` in the entity so identity dedups AND
   original provenance is preserved (verified read: "kids nightlight projector" → existing product
   `e453eed4`, source `reddit`).

5. **Provenance behavior** — a genuinely new candidate is stamped `source_store='dataforseo'`
   (Discovered via: DataForSEO). A rediscovery of an existing product keeps its ORIGINAL discovery
   source (e.g. reddit) and records DataForSEO only as a validating SEARCH_DEMAND signal
   (`source_platform='dataforseo_labs'`). Original discovery source is never overwritten by later
   evidence.

6. **Cost controls** — candidate cap (`p_candidate_limit`, hard-bounded 1–25); the adapter makes
   NO paid call (n8n fetches; adapter processes); dedup runs before downstream work; per-keyword
   failure isolation; discovery does NOT auto-dispatch research (candidates enter the existing
   registry → weekly Monday pipeline, so no cadence increase). Manual-trigger workflow (no new
   recurring schedule).

7. **Real bounded test result** — DataForSEO scan category "humidifier", market GB, cap 3
   (n8n execution 30209). Scanned 15 keyword ideas → 3 qualified & promoted; the rest rejected as
   non-commercial / non-product.

8. **Candidate discovered by DataForSEO** — `cool mist humidifier` (+ `cool air humidifier`,
   `humidifier for room`). None seeded manually — only the category "humidifier" was seeded;
   DataForSEO returned the specific product queries.

9. **Canonical product_id** — `cda3f71a-9947-4344-8664-13735740575f` (`cool mist humidifier`);
   also `04b286f2-…` and `a4f098c7-…`.

10. **New or deduplicated** — all 3 **new** on first scan; **deduplicated** (same ids, no
    duplicates) on replay.

11. **Search-demand evidence** — GB, source `dataforseo_labs`, 4,400/mo each, competition 1.00,
    confidence 0.80, real monthly history; attached as founder-owned `SEARCH_DEMAND` signals.

12. **Downstream multi-source status** — `cool mist humidifier` entered the existing 013N pipeline
    (`fn_own_request_product_market_research`): status RESEARCHING, `auto_dispatch=DISPATCHED`,
    dispatchable 4 (eBay/Meta/DataForSEO/CJ) + Reddit reuse, TikTok `BLOCKED_EXTERNAL_ACCESS`.
    Finalized to canonical `product_market_evaluations`: **score 80.2 / MEDIUM / coverage 0.52 /
    decision WATCH**.

13. **Proof DataForSEO did not independently declare a winner** — at discovery the candidate had a
    SEARCH_DEMAND signal but ZERO `product_market_evaluations` / `product_opportunity_decisions`
    (a candidate, not a winner). Only after multi-source research did it receive a **WATCH**
    decision (not TEST/WINNER) — the decision came from the unchanged WPS multi-source pipeline.

14. **Reddit regression** — Reddit discovery path untouched; 10 Reddit-originated products intact;
    Reddit adapter unchanged.

15. **Existing product regression** — original 12 founder products intact (now 15 total with the 3
    new discovered); no duplicate canonical products; `founder_decisions_reachable_7` unchanged.

16. **GB/DE nightlight regression** — GB 68.2 / DE 73.2 unchanged (013O canonical binding intact);
    business country GB unchanged; product identity unchanged.

17. **Security results** — `fn_dataforseo_discover_candidates` is **service-role only** (anon &
    authenticated denied); tenant is an explicit server-controlled argument (never from browser);
    DataForSEO credentials remain in n8n and are never exposed to Lovable/browser; the qualifier is
    a pure function with no data access. Advisors: **0 ERROR** (unchanged lint set). All 9 backend
    selftests pass (relevance, orchestrator/013N, deep/013I, contracts/013E, connection/013A,
    storefront runtime + lifecycle, paid-access, new dfs_discovery) after the mig_256 baseline
    reconcile. No synthetic evidence.

18. **Actual/estimated API cost** — humidifier scan (keyword_ideas + search_intent) ≈ €0.03;
    earlier "posture corrector" diagnostic scan ≈ €0.03; one 013N research validation for the
    candidate ≈ €0.09. **Total ≈ €0.13**, under the €1 bound.

19. **Workflows / functions / migrations / files changed** —
    - `mig_255_dataforseo_discovery_adapter.sql`: `fn_dataforseo_discovery_qualify`,
      `fn_dataforseo_discover_candidates` (service-role), `fn_dataforseo_discovery_selftest`.
    - `mig_256_selftest_reconcile_013q.sql`: `fn_ecommerce_connection_selftest` +
      `fn_ecommerce_intelligence_contracts_selftest` frozen-count baselines → integrity assertions.
    - n8n workflow `dyIhrOkFp2QmrmTD` (manual-trigger; existing DataForSEO + Supabase creds reused).
    - Reused unchanged: `ingest_search_demand`, `resolve_product_entity`, `ingest_commerce_product`,
      `monday_opportunity_registry`, 013N pipeline, WPS. No Lovable change.

20. **Commit hash** — see delivery message.

21. **Push / divergence** — branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

**Workspace contract (item 10):** a DataForSEO-originated Product Decision returns through the
existing `fn_ecommerce_workspace_intelligence()` / `fn_ecommerce_research_coverage()` contracts like
any other candidate once its research completes (the `cool mist humidifier` evaluation is now
canonical). The `SOURCE STORE → DISCOVERED VIA` label change is deferred to a later Lovable unit.

**STOP. Discovery adapter implemented and proven. No eBay/Meta/CJ discovery adapters built. No Lovable change. No publish.**

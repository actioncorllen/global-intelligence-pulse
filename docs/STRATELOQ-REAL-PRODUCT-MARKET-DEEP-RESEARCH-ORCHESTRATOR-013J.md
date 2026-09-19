# STRATELOQ-REAL-PRODUCT-MARKET-DEEP-RESEARCH-ORCHESTRATOR-013J

**FINAL VERDICT: `PARTIAL_ORCHESTRATOR_READY`.**

The smallest secure production orchestration path is built, secured, and **proven with a
real, live provider run**: one founder product + selected market (kids nightlight projector,
GB) passed through the new on-demand orchestrator, the real eBay Browse API was called, real
marketplace evidence was ingested through the canonical receiver with provenance, the run was
finalized, and the canonical Product Decision was recomputed from that real evidence
(opportunity score **75.5 → 79.5**). TikTok stays `BLOCKED_EXTERNAL_ACCESS`. The remaining
available providers (DataForSEO, Meta, CJ) are receiver-ready and the executor pattern is
proven, but each provider's live executor + one full multi-source pass is not yet run — so
this is truthfully PARTIAL, not full READY. No synthetic evidence, no Lovable change, no
payment, no schedule change.

Migrations: `mig_243_real_research_orchestrator.sql`, `mig_244_research_provenance_fix.sql`,
`mig_245_research_force_fresh.sql`, `mig_246_selftest_reconcile_013j.sql`.
n8n executor: `Pulse — Research Executor: eBay (013J)` (`N6OATi91HM8asncc`, manual only).

---

### 1. Provider preflight
`REDDIT` READY (community sweep, free); `DATAFORSEO` READY (credential present in vault; **paid**);
`META_AD_LIBRARY` READY for EU/UK markets incl GB (free); `EBAY` READY (free); `CJ` READY (free).
`GOOGLE_ADS` = `SOURCE_BLOCKED` (dev token rejected). `TIKTOK` = `SOURCE_UNSUPPORTED` /
`BLOCKED_EXTERNAL_ACCESS`. All external credentials live only in n8n/vault — none reachable by the browser.

### 2. Existing workflows / receivers reused
The real ingestion path already existed as product+market-scoped receivers:
`fn_ingest_ebay_listings`, `fn_ingest_meta_ads`, `fn_ingest_search_demand_for_product`,
`ingest_cj_supplier_products`. The eBay OAuth+Browse pattern was reused from the existing probe
`ZN6huMtz3DNIMnks`; the Supabase `supabaseApi` service credential from the Monday orchestrator.
No provider workflow was duplicated.

### 3. Hardcoded-probe changes
Existing probes were **not** modified. A single dedicated, parameterized research executor was
built (`N6OATi91HM8asncc`): token → Browse search for the run's product query + market → post the
raw itemSummaries to `fn_research_ingest_source(run_id,'EBAY',…)` → `fn_finalize_research_run(run_id)`.
It no longer depends on a fixed test product.

### 4. Orchestrator contract
`fn_own_request_product_market_research(p_product_id uuid, p_market text, p_freshness_hours int default 168)`
— authenticated, returns a browser-safe dispatch manifest + run_id. Service-role control plane:
`fn_research_ingest_source(run_id,source,raw)`, `fn_finalize_research_run(run_id)`.

### 5. Auth / ownership model
`auth.uid()` → `commerce_products.user_id` ownership check (founder tenant). Caller supplies only
product_id + market; user_id/tenant/currency/query/supplier/credentials are all derived server-side.

### 6. Product + market identity model
Keyed to (canonical product, selected market); currency derived from `ecommerce_market_universe.default_currency`;
each market is independent; the product research market is never confused with the business home country.
No Lovable country selector implemented.

### 7. Research-run lifecycle
`commerce_research_run`: `RESEARCHING` → `COMPLETE` | `PARTIAL` | `PARTIAL_SOURCE_FAILURE` |
`PARTIAL_SOURCE_UNAVAILABLE` | `INSUFFICIENT_EVIDENCE`. The applicable provider/category set and
inputs are snapshotted in `provenance` at request time so later registry changes cannot falsify the run.

### 8. Source-attempt lifecycle
`commerce_research_source_attempt`: `NOT_SEARCHED` → `SEARCHING` → `SEARCHED_EVIDENCE_FOUND` /
`SEARCHED_NO_EVIDENCE` / `SOURCE_FAILED`; or `BLOCKED_EXTERNAL_ACCESS` / `UNSUPPORTED_MARKET`.
Evidence is "found" only when canonical rows are actually accepted — a completed HTTP call is never
auto-success. `NOT_SEARCHED` is never treated as `NO_DATA`.

### 9. Provider applicability logic
Chosen per category from `provider_capability_registry` by ranked availability (market-specific
AVAILABLE > global AVAILABLE > blocking state). Completion is **not** hardcoded to five providers.

### 10–14. Reddit / DataForSEO / Meta / eBay / CJ execution
**eBay = REAL, executed** (see §19–24). Reddit/DataForSEO/Meta/CJ were created as truthful
`NOT_SEARCHED` attempts for this run (receiver-ready, executor pattern proven) but not dispatched in
this pass. Meta is AVAILABLE for GB; DataForSEO is global (paid); CJ is global.

### 15. TikTok blocked state
`SOCIAL_VIDEO` / `TIKTOK` attempt = `BLOCKED_EXTERNAL_ACCESS`, reason `EXTERNAL_PROVIDER_REQUIRED`.
No credentials or sensitive detail stored. Not faked.

### 16. Provenance linkage
Research linkage is written to `commerce_signals.provenance` jsonb
(`research_run_id`,`source_attempt_id`,`research_market`). `source_run_id` is FK-bound to
`discovery_runs` and is deliberately left untouched. 93 signals are provenance-linked to the run;
13 legacy Sept-05 rows remain unlinked (correct). Legacy rows may stay NULL.

### 17. Cache / freshness behaviour
Default 168h dedupe returns `CACHE_REUSED` (no new dispatch, no paid calls) vs a new
`RESEARCHING` run. `p_freshness_hours <= 0` forces a fresh run. Cross-market reuse is impossible —
lookups are keyed on the selected market.

### 18. Duplicate / retry behaviour
Receivers are idempotent (per-item dedup keys, `ON CONFLICT DO NOTHING`); provenance tags only the
rows a call actually inserts (pre-snapshot id diff). Retrying a source does not create duplicate
evidence or duplicate runs.

### 19–20. Founder product tested + selected market
Product `e453eed4` **kids nightlight projector**, market **GB** (currency GBP, query
"kids star projector night light").

### 21. Expected provider calls / cost
eBay Browse API = **free**. This run = 1 OAuth token call + 1 Browse search call = **2 calls, $0.00**.
No paid DataForSEO call was fired.

### 22. Actual provider calls
2 real eBay calls (token + search). eBay returned **752 total GB listings**, 100 sampled.

### 23. Source states after run
`MARKETPLACE/EBAY` = `SEARCHED_EVIDENCE_FOUND` (rows_tagged 93); `SEARCH_DEMAND/DATAFORSEO`,
`ADVERTISING/META_AD_LIBRARY`, `COMMUNITY/REDDIT`, `SUPPLIER/CJ` = `NOT_SEARCHED`;
`SOCIAL_VIDEO/TIKTOK` = `BLOCKED_EXTERNAL_ACCESS`.

### 24. Real evidence ingested
93 real `MARKETPLACE_ACTIVITY` signals from live GB eBay listings (public-only, no seller identity;
eBay account-deletion compliant), provenance-linked to the run. GB competitor set rebuilt from the
real listings (106 GB entries, all real/non-fixture).

### 25–27. No-data / blocked / failed sources
No source returned NO_DATA (none legitimately searched-and-empty); 1 blocked (TikTok); 0 failed.

### 28–34. Before → after (kids nightlight projector, GB)
| Metric | Before | After |
|---|---|---|
| evidence categories | COMMUNITY + MARKETPLACE | COMMUNITY + MARKETPLACE (live-refreshed) |
| coverage | 0.41 | 0.41 |
| evidence_confidence | LOW | LOW |
| marketplace subscore | 89 | **100** |
| opportunity score | 75.5 | **79.5** |
| Product Decision | WATCH | WATCH |
| saturation | — | competitor set grew (106 real GB entries observed) |
| buyer intent | empty (not researched) | empty (DataForSEO not dispatched — truthful) |

Score/subscore rose from **real** new marketplace evidence; band unchanged; evidence can move the
assessment up or down (no manual patching of score/band/confidence).

### 35. Supplier-contract result
`fn_ecommerce_supplier_intelligence` returns NO_DATA for the founder (0 `product_acquisitions`) — CJ
not dispatched this run. Contract is correct.

### 36. Supplier empty-card root cause (013F)
Tenant supplier evidence lives in `product_acquisitions` snapshots (founder has 0), **not** in the
shared `commerce_supplier_products` catalogue. The contract truthfully returns an empty set; the
013F frontend must render an honest NO_DATA/empty state rather than an error card. No backend
fabrication of a supplier observation.

### 37. Deep-research completeness
`PARTIAL` — only the marketplace source was searched for this run; the result is **not** represented
as fully researched.

### 38. Launch-gap result
`launch_critical_gap = TRUE` (TikTok blocked, and other launch-critical sources not yet searched).
The 013I truthfulness gate is intact — no false HIGH_CONFIDENCE.

### 39. Security verification
auth.uid ownership enforced; cross-tenant **denied** (`42501`); anonymous **denied** (`28000`);
ingest/finalize/selftest are **service_role only**; request is authenticated+service_role; anon has
no grant on any 013J function; ledger tables RLS deny-all; no browser-accessible provider credentials.

### 40. Regression verification
`fn_research_orchestrator_selftest` 7/7; `fn_deep_research_selftest` (013I) all_pass;
`fn_ecommerce_connection_selftest` (013A) all_pass; `fn_ecommerce_intelligence_contracts_selftest`
(013E) all_pass; `fn_paid_access_selftest` (entitlement) all_pass; storefront runtime/publish/branding/
lifecycle all_pass; `fn_media_creative_live_selftest` 4/4. Two prior selftests asserted pre-013J frozen
counts (empty ledger; 74 founder competitors) — reconciled in mig_246 to integrity assertions, since
those counts moved because **real** research legitimately populated the ledger and grew the
competitor set (74 → 167 real, 0 fixtures).

### 41. Advisor delta
5 advisor categories — **unchanged from the 013I baseline**. Growth in counts is my deny-all RLS
ledger tables (intentional) and authenticated auth.uid()-scoped SECURITY DEFINER RPCs (the same
intended pattern as every prior 013A/013E/013I contract). No new advisory class, no new vulnerability.

### 42. Files / migrations / workflows changed
`mig_243_real_research_orchestrator.sql` (orchestrator entry, run/attempt lifecycle, applicability,
provenance receiver, finalize+recompute, assembler consumption of DataForSEO/Meta, selftest);
`mig_244_research_provenance_fix.sql` (provenance tag by id-snapshot, jsonb-only; one-time backfill);
`mig_245_research_force_fresh.sql` (force-fresh on-demand + robust selftest);
`mig_246_selftest_reconcile_013j.sql` (013I/013E integrity assertions). n8n executor `N6OATi91HM8asncc`.

### 43. Database rows added / changed
+1 real run, +6 attempts; +93 real marketplace signals; GB competitor set rebuilt (real, non-fixture);
GB evaluation recomputed (79.5). No fixtures created. `account_entitlement` unchanged (2 rows).
(An accidental self-test cleanup deleted a first proof run mid-build; its evidence was removed and the
run was cleanly re-executed — final state is a single intact real run.)

### 44–48. Confirmations
No synthetic evidence (all evidence is real live eBay data). No Lovable changes. No payment/Stripe
work (entitlement untouched). No schedule increase (executor is manual-only; weekly Monday production
cadence untouched). Nothing published.

### 49–50. Commit / push
See delivery message; branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

### 51. Remaining external dependencies
- **TikTok** — `BLOCKED_EXTERNAL_ACCESS`; needs founder-provided TikTok for Business API app +
  approved research scope + credentials in vault. Free at baseline; founder time for app review.
- **DataForSEO / Meta / CJ live executors** — receiver-ready; need their executor branches built and one
  full multi-source pass; DataForSEO is paid, so its cost must be reported before firing.

### 52. Smallest next unit
Extend the executor with the **free** providers first (Meta GB + CJ) and run one full multi-source pass
for the same product+market so a run reaches `COMPLETE` across all currently-free sources; then add
DataForSEO after reporting its expected per-run cost for founder approval. TikTok stays blocked until
access exists.

**STOP. No next unit started.**

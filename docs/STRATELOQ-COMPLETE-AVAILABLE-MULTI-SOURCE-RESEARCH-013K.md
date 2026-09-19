# STRATELOQ-COMPLETE-AVAILABLE-MULTI-SOURCE-RESEARCH-013K

**FINAL VERDICT: `AVAILABLE_SOURCES_DEEP_RESEARCH_READY_TIKTOK_BLOCKED`.**

One coherent Product × Market research run (**kids nightlight projector + GB**, run
`ae239472-e458-4605-936f-c69886a61d31`) now has **all five currently-available launch-critical
sources at terminal `SEARCHED_EVIDENCE_FOUND`** — eBay, Meta, DataForSEO, CJ (live) and Reddit
(cross-market reuse) — with TikTok truthfully `BLOCKED_EXTERNAL_ACCESS`. Available-source
research is complete; **full-launch deep-research remains NOT READY** because TikTok, a
launch-critical source, is blocked. Deeper research legitimately moved the assessment: coverage
**0.41 → 0.78**, confidence **LOW → HIGH**, opportunity score **79.5 → 51.0** (the heaviest
dimension, buyer_search_intent, came in low under the strict product-name relevance classifier —
an acceptable lower score after deeper research). No synthetic evidence, no manual insertion, no
Lovable change, no payment, no cadence change, nothing published.

Migration: `mig_247_research_cache_reuse.sql`. n8n executors: Meta `57AYLZgyITU9vfCW`, CJ
`vjVn6gILqw4lGYpG`, DataForSEO `aVKNL2CFhyA8VUdm` (all manual only); eBay `N6OATi91HM8asncc` reused.

---

1. **Provider preflight** — Reddit `READY`, DataForSEO `READY`, Meta `READY`, CJ `READY`
   (credentials present in n8n/vault). TikTok `BLOCKED_EXTERNAL_ACCESS`.
2. **DataForSEO endpoints** — `keywords_data/google_ads/search_volume/live` + `dataforseo_labs/
   google/search_intent/live`, GB `location_code=2826`, 8 product seed keywords (smallest useful
   single-product request; no broad research).
3. **DataForSEO estimated cost** — ≈ €0.06–0.08 (two live calls), ≤ €1 → proceeded automatically.
4. **DataForSEO actual cost** — search_volume **$0.09** + search_intent **$0.01296** = **$0.103 ≈ €0.09**.
5. **Reddit** — cache-reuse of the existing real cross-market `COMMUNITY_ATTENTION` signal (1;
   ~15 days old, within a 720h community window) → `SEARCHED_EVIDENCE_FOUND`, provenance flagged
   **cross-market, NOT GB-verified demand** (the community pipeline is a cross-market LLM sweep,
   not a per-market fetch — 013H).
6. **DataForSEO** — live executed; `SEARCHED_EVIDENCE_FOUND`; 1 `SEARCH_DEMAND` signal. Real GB
   demand: star projector 2,900/mo, galaxy projector 3,600/mo, night light projector 1,600/mo (HIGH
   competition, CPC ~£0.20–0.29). **Finding:** the receiver's product-name relevance classifier rated
   those high-volume generic terms `IRRELEVANT` to the narrow product name "kids nightlight projector";
   the matched DIRECT/CLOSE variants had null GB volume → buyer_intent_score **0 / LOW**. Truthful,
   not gamed.
7. **Meta** — live executed; 50 GB ads returned, **3 MATCHED** (advertiser "Ggvbeauty", 1 distinct
   page) → `SEARCHED_EVIDENCE_FOUND`; 3 `ADVERTISING_ACTIVITY` signals; advertising subscore **48**
   (1 observed advertiser). Observable presence only — no sales/ROAS/CPA inferred.
8. **eBay** — **reused** the fresh 013J evidence already in this run (93 marketplace signals, GB,
   same day); **no new provider call** (§8). `SEARCHED_EVIDENCE_FOUND`.
9. **CJ** — live executed; 20 supplier products ingested to the shared `commerce_supplier_products`
   catalogue → `SEARCHED_EVIDENCE_FOUND`. CJ's term search returned loosely-related lighting products
   (real catalogue data). The assembler already matches a CLOSE_COMPARABLE cjdropshipping projector
   (supplier subscore 40); no supplier fabricated.
10. **TikTok** — `BLOCKED_EXTERNAL_ACCESS` (`EXTERNAL_PROVIDER_REQUIRED`). Not faked, not scraped,
    not downgraded — the unresolved launch-critical gap.
11. **Coherent research run** — `ae239472-e458-4605-936f-c69886a61d31`.
12. **Product** — kids nightlight projector (`e453eed4`). 13. **Market** — GB.
14. **Provider terminal-state matrix**

| Category | Source | State |
|---|---|---|
| MARKETPLACE | EBAY | SEARCHED_EVIDENCE_FOUND (93 signals, reused) |
| ADVERTISING | META_AD_LIBRARY | SEARCHED_EVIDENCE_FOUND (3 signals) |
| SEARCH_DEMAND | DATAFORSEO | SEARCHED_EVIDENCE_FOUND (1 signal) |
| SUPPLIER | CJ | SEARCHED_EVIDENCE_FOUND (20 catalogue) |
| COMMUNITY | REDDIT | SEARCHED_EVIDENCE_FOUND (cross-market reuse) |
| SOCIAL_VIDEO | TIKTOK | BLOCKED_EXTERNAL_ACCESS |

15. **sources expected** — 6. 16. **attempted** — 5. 17. **with evidence** — 5. 18. **NO_DATA** — 0.
19. **blocked** — 1 (TikTok). 20. **failed** — 0.
21. **evidence categories before/after** — 3–4 → **5** independent categories.
22. **coverage before/after** — 0.41 → **0.78**.
23. **evidence confidence before/after** — LOW → **HIGH**.
24. **evidence grade before/after** — DEVELOPING_EVIDENCE → broader multi-source (5 categories,
    HIGH confidence), still not HIGH_CONFIDENCE due to the launch-critical (TikTok) gap.
25. **opportunity score before/after** — 79.5 → **51.0**.
26. **opportunity band before/after** — WATCH → WATCH.
27. **buyer-search-intent before/after** — `{}` → subscore **0** (real DataForSEO, strict relevance).
28. **advertising-activity before/after** — `{}` → subscore **48** (1 observed advertiser).
29. **marketplace-validation before/after** — 100 → 100.
30. **supplier-availability before/after** — 40 → 40 (CLOSE_COMPARABLE).
31. **saturation before/after** — competitor set 106 real GB entries (marketplace competition observed).
32. **source-diversity verification** — `independent_categories = 5`; counted by category, not raw
    signal volume (106 marketplace signals count as ONE marketplace category).
33. **provenance verification** — 3 ADVERTISING + 93 MARKETPLACE + 1 SEARCH_DEMAND signals carry
    `provenance.research_run_id = ae239472…`; community reused keeps its original sweep provenance
    (cross-market).
34. **supplier-contract result** — `fn_ecommerce_supplier_intelligence` = true **NO_DATA** (count 0);
    CJ evidence lands in the shared catalogue, not tenant `product_acquisitions`. Not fabricated.
35. **available-source research completeness** — **COMPLETE** (all 5 available sources terminal).
36. **full-launch research completeness** — **NOT READY** (TikTok blocked).
37. **TikTok launch gap** — unresolved; requires founder-provided TikTok for Business API access.
38. **Provider call / cost table**

| Provider | Calls | Paid? | Cost |
|---|---|---|---|
| eBay | 0 (reused) | free | $0.00 |
| Meta | 1 | free | $0.00 |
| CJ | 2 (auth + list) | free | $0.00 |
| DataForSEO | 2 (volume + intent) | paid | **$0.103 ≈ €0.09** |
| Reddit | 0 (reused) | free | $0.00 |
| **Total** | | | **≈ €0.09** |

39. **Security** — auth.uid ownership enforced; cross-tenant denied (42501); anon denied (28000);
    ingest/finalize/reuse are service_role only; request authenticated+service_role; no browser
    provider credentials; RLS deny-all ledger unchanged.
40. **Regression** — orchestrator 7/7; 013I/013A/013E/entitlement/storefront (runtime+publish+
    branding+lifecycle)/creative all_pass. Integrity assertions (not frozen counts) retained.
41. **Advisor delta** — 5 categories, unchanged from baseline; new reuse function is service_role
    only (not in anon/authenticated advisor sets). No new vulnerability class.
42. **Database changes** — +3 `ADVERTISING_ACTIVITY` signals, +1 `SEARCH_DEMAND` signal (provenance
    linked), +~20 real CJ catalogue rows; run finalized `PARTIAL_SOURCE_UNAVAILABLE`; GB evaluation
    recomputed to 51.0/0.78/HIGH. No fixtures created; entitlement unchanged (2).
43. **n8n / workflow changes** — +3 manual executors (Meta/CJ/DataForSEO); eBay executor reused.
    No probe modified. No schedule added.
44. **Files changed** — `supabase/migrations/mig_247_research_cache_reuse.sql`, this doc.
45. **No synthetic evidence** — all evidence is real live provider data (or reused real evidence).
46. **No manual evidence insertion** — every provider result passed through a canonical receiver
    (`fn_ingest_ebay_listings`/`fn_ingest_meta_ads`/`fn_ingest_search_demand_for_product`/
    `ingest_cj_supplier_products`). No manual SQL insertion of provider evidence.
47. **No Lovable changes.** 48. **No payment changes** (entitlement untouched).
49. **No cadence increase** (executors manual-only; weekly Monday production untouched).
50. **Nothing published.**
51. **Commit** — see delivery message. 52. **Push / divergence** — branch
    `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.
53. **Remaining external dependencies** — TikTok for Business API access (founder-provided). Two
    non-blocking findings surfaced for a later unit: (a) the buyer_search_intent relevance classifier
    scored strong real GB demand for generic projector terms as IRRELEVANT to the narrow product name
    (dragging score down); (b) CJ term-search returns loosely-related products, so category-exact
    supplier matching is weak.
54. **Smallest next unit** — review/relax the `fn_classify_search_query_relevance` classifier so real
    high-volume category demand is not scored 0 for a narrowly-named product (re-run this same run
    after), OR extend the proven coherent multi-source path to ONE additional founder market (e.g. DE)
    for the same product. TikTok stays blocked until access exists.

**STOP. No next unit started.**

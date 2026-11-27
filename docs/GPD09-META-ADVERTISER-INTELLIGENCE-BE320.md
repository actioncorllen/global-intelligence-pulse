# BE320 — GPD.09 Meta/TikTok competitor-advertiser intelligence: provider-independent progress + rights-gate regression proof

**Executed:** 2026-11-27 · **Authority:** founder "NEXT LAUNCH EXECUTION — PRIORITY: GPD.09 — META COMPETITOR ADVERTISER INTELLIGENCE". **Mandate:** maximum safe, verifiable, *provider-independent* progress with **no licensed commercial data, no extra API cost**. **GPD.09 remains OPEN** (acceptance needs a licensed provider's written analyse rights — external). **Strict controls honoured:** no production deploy, no paid API calls, no credits, no provider subscription, no speculative ingestion, no customer display-rights flag change, no GPD.07 activation, no GOLD checkbox change. **Historical GOLD 11/22 unchanged.**

---

## Headline
The advertiser-intelligence **infrastructure already exists and is rights-correct**. The single remaining blocker is **external licensing** (a provider's written permission to *analyse* commercial advertiser data), not code. This build adds the missing **regression proof** that the system cannot leak or fabricate advertiser evidence, and documents exactly what written rights unblock launch. New deterministic selftest **`fn_product_ad_evidence_selftest()` → 16/16 PASS**; adjacent `fn_product_competitor_evidence_selftest()` **6/6** (no regression).

---

## TASK 1 — Existing system inspection — **DONE**
The Meta/TikTok advertiser path is implemented across:
- **Storage.** The actual ad observations live in `commerce_signals`: `signal_type='ADVERTISING_ACTIVITY'` with `provenance->>'source'='META_AD_LIBRARY'` (Meta), and `signal_type='SOCIAL_VIDEO_ADVERTISING'` (TikTok). Each row carries `value` (`page_id`, `advertiser_page`, `ad_id`, `market`, relevance `match`), `evidence[]` (`snapshot_url`, `delivery_start`), and `provenance` (`source`, `relevance.classifier_verdict`, `research_run_id`, `source_attempt_id`, `api_version`). `product_market_competitors` holds the marketplace-seller/competitor schema (not the ad observations).
- **Reader.** `fn_product_ad_evidence(p_product_id uuid, p_country text)` — SECURITY DEFINER, STABLE. Gates on `auth.uid()` → ownership (`commerce_products.user_id`) → per-country scoping → **BE264 rights gate** → per-platform distinct advertiser/creative counts → honest coverage state. Contract `pulse_product_ad_evidence_v1`.
- **Helpers.** `fn_ad_coverage_class(market_state, attempt_state, advertisers)` (pure classifier: OBSERVED / ZERO_WITH_ADEQUATE_COVERAGE / UNSUPPORTED / UNKNOWN …); `fn_meta_ad_library_market_state(market)` (per-country Meta coverage); `fn_product_identity_badge` (concept-vs-resolved identity); `ingest_advertising_activity` (writer); `fn_source_availability`.
- **Rights registry.** `catalogue_source_rights`: `META_AD_LIBRARY` and `TIKTOK` both have `analyse_cleared=false`, `display_cleared=false`, `display_derived_cleared=false`, `commercial_redistribution_cleared=false`.

## TASK 2 — 5-market (GB/DE/IE/IT/US) per-country classification support — **DONE (infrastructure)** · provider-dependent for live counts
- **Per-country coverage is live and honest.** `fn_meta_ad_library_market_state`: **GB/DE/IE/IT → `AVAILABLE`**; **US → `SOURCE_UNSUPPORTED`**. This encodes the real Meta limitation (the all-ads commercial archive covers EU/EEA + UK; the US only exposes political/issue ads), so the system never pretends US commercial-ad competition is measurable through Meta Ad Library.
- **Classification support present:** exact-product matching (`provenance.relevance` token-overlap + classifier verdict `EXACT_OR_CLOSE_MATCH`), per-platform distinct-advertiser dedup, strict per-country scoping, identity-state guard (ad evidence never merged across materially different candidates).
- **Provider-dependent:** real *authorised* commercial advertiser counts for the four covered markets require a licensed provider (below). Current Meta rows are seeded fixtures and are withheld by the rights gate.

## TASK 3 — Provider-rights and coverage gates — **DONE**
- Reader enforces: `analyse_cleared=false` for a source ⇒ `coverage_state='NOT_AUTHORISED'`, `observed_advertisers`/`observed_creatives` = **NULL**, source **cannot** drive the competition verdict. Raw signals retained for audit only.
- **Meta Ad Library is not assumed to have unrestricted commercial coverage** — US is explicitly `SOURCE_UNSUPPORTED`, and even if a US row exists it can never be classified `OBSERVED` (proven below).
- Meta/TikTok stay **withheld**; the architecture is "licensed-provider-ready" — the moment a provider's `analyse_cleared` is set, the reader emits counts that are already country-scoped, deduped and identity-guarded (proven by the classifier + raw-predicate tests).

## TASK 4 — Safe provider-independent work — **DONE**
Completed inside the existing architecture, with **no** new display and **no** paid ingestion:
| Guarantee | Mechanism | Status |
|---|---|---|
| Exact-product advertiser matching | `provenance.relevance` classifier verdict per signal | present, verified |
| Advertiser deduplication | `count(DISTINCT page_id / advertiser_page)` | proven (47 rows → 16 advertisers) |
| Country isolation / no borrowing | per-market `upper(value->>'market')` scoping | proven (DE 16 / GB 6 / JP 0) |
| Tenant isolation | ownership gate on `commerce_products.user_id` | proven (`cross_tenant_rejected`) |
| UNKNOWN / NOT_AUTHORISED handling | rights gate + `fn_ad_coverage_class` | proven (never turned into evidence) |
| Honest zero-vs-unknown | missing run ⇒ UNKNOWN, not zero-competition | proven |
| Display-rights gate | counts NULL while uncleared | proven |
| **Test fixtures + regression coverage** | **new `fn_product_ad_evidence_selftest()`** | **DONE — 16/16** |

**The new regression selftest is the primary deliverable.** It locks in, permanently, that advertiser evidence cannot leak or be fabricated. It uses **real seeded fixtures** + **pure-logic units** and makes **no rights-flag change** (it never turns NOT_AUTHORISED into a count).

## TASK 5 — Prove what works — **DONE (16/16)**
`SELECT public.fn_product_ad_evidence_selftest();` → `{ok:true, passed:16, failed:0}`. Checks:
1. `UNAUTHENTICATED` → status `unauthenticated`.
2. `PRODUCT_NOT_FOUND` → unknown product rejected.
3. `CROSS_TENANT_REJECTED` → a different tenant cannot read the product's ad evidence.
4. `META_WITHHELD_NOT_AUTHORISED` → `coverage_state=NOT_AUTHORISED`, `observed_advertisers` NULL, `rights_authorised=false` **even though the run's `attempt_state=SEARCHED_EVIDENCE_FOUND`** (a successful search that found Meta ads is still withheld).
5. `TIKTOK_WITHHELD_NOT_AUTHORISED` → same for the second uncleared source.
6. `TOTALS_AND_VERDICT_WITHHELD` → `observed_advertisers_total`/`observed_creatives_total` NULL, `combined_competition_state=ADVERTISING_COMPETITION_UNKNOWN`.
7. `ADVERTISER_NOT_SELLER` → `observed_sellers` stays NULL.
8. `RIGHTS_ENFORCEMENT_LISTS_UNCLEARED` → audit lists `META_AD_LIBRARY` + `TIKTOK`.
9. `PER_COUNTRY_MARKET_STATE_DIFFERENTIATED` → same product: US `SOURCE_UNSUPPORTED`, DE `AVAILABLE`.
10. `US_RAW_OBS_WITHHELD` → US has raw Meta rows, yet the reader exposes no count (rights gate).
11. `DEDUP_COLLAPSES_DUPLICATES` → DE 47 raw rows → 16 distinct advertisers.
12. `COUNTRY_ISOLATION_NO_BORROW` → DE=16, GB=6 (independent), empty market JP=0.
13. `CLASSIFIER_OBSERVED` → adequate coverage + positive count ⇒ OBSERVED.
14. `CLASSIFIER_ZERO_WITH_COVERAGE` → searched, 0 ⇒ ZERO_WITH_ADEQUATE_COVERAGE (positive low-competition, cleared-source only).
15. `CLASSIFIER_US_UNSUPPORTED_NEVER_OBSERVED` → `SOURCE_UNSUPPORTED` market never yields OBSERVED, even with a count of 17.
16. `CLASSIFIER_UNKNOWN_NOT_ZERO` → missing run (null attempt) + 0 ⇒ UNKNOWN, not zero-competition.

**No regression:** `fn_product_competitor_evidence_selftest()` 6/6.

## TASK 6 — Actual launch status

### Component status
| Component | Status | Note |
|---|---|---|
| Ad-observation storage model (`commerce_signals`) | **DONE** | Meta + TikTok, per-market, with provenance/relevance/evidence |
| Rights-gated reader (`fn_product_ad_evidence`) | **DONE** | NOT_AUTHORISED withholding verified |
| Per-country coverage gating (GB/DE/IE/IT/US) | **DONE** | US correctly `SOURCE_UNSUPPORTED` |
| Exact-product match / dedup / country+tenant isolation | **DONE** | proven on real fixtures |
| Honest UNKNOWN/ZERO/NOT_AUTHORISED states | **DONE** | proven |
| **Regression selftest** (`fn_product_ad_evidence_selftest`) | **DONE** | 16/16 |
| Live *authorised* commercial advertiser counts | **BLOCKED (external)** | needs licensed provider analyse rights |
| US commercial-ad coverage | **BLOCKED (external)** | Meta Ad Library cannot serve US commercial all-ads |
| Customer-facing advertiser display | **NOT STARTED (gated)** | needs display rights + founder release decision; out of scope here |

### Tests / evidence
`fn_product_ad_evidence_selftest()` 16/16; `fn_product_competitor_evidence_selftest()` 6/6. Fixture facts: `e453eed4` (kids nightlight projector) Meta obs DE 47→16 adv, GB 29→6 adv, BE 42→3 adv; `77004cbb` (coaxial cable) Meta obs DE 32, US 17. Rights rows: META_AD_LIBRARY + TIKTOK `analyse_cleared=false`.

### Changed files / migrations / commits
- `supabase/migrations/mig_370_gpd09_ad_evidence_selftest.sql` (new function; applied as `mig_370_gpd09_ad_evidence_selftest`).
- `docs/GPD09-META-ADVERTISER-INTELLIGENCE-BE320.md` (this report).
- Master-doc Addendum 91. No frontend/Lovable change. No backend logic change beyond the additive selftest. (Commit recorded in the register row.)

### Provider-dependent remaining work (cannot be done without external licensing)
1. **Authorised commercial advertiser counts** for GB/DE/IE/IT — requires a licensed Meta-ad-data provider granting *analyse* rights. (Adyntel and Adflex enquiries already sent; no reply — **do not duplicate**.)
2. **US commercial-ad competition source** — Meta Ad Library structurally cannot provide it; needs a different licensed US commercial-ad data source, or acceptance that US advertiser-competition stays `SOURCE_UNSUPPORTED`.

### Exact written rights required to unblock
From a commercial advertiser-data provider, in writing:
- **(a) Analyse rights** — permission to analyse the provider's Meta/TikTok advertiser data for commercial product-research. Sets `catalogue_source_rights.analyse_cleared=true` for that source. **This alone turns the reader from NOT_AUTHORISED to live counts** (country-scoped, deduped — already proven).
- **(b) Display/redistribution rights** — only if advertiser counts are shown to customers: permission to display/redistribute derived advertiser counts. Sets `display_derived_cleared` / `commercial_redistribution_cleared`. Not needed for internal analysis.

### Remaining launch blockers for GPD.09
- **External (the only hard blocker):** a licensed commercial advertiser-data provider agreement conveying analyse rights (a) for GB/DE/IE/IT; and a separate licensed US commercial-ad source for US.
- **Internal:** none for the provider-independent layer — it is proven green. Customer display is a deliberate, separate founder release decision once rights land.

**GPD.09 stays OPEN** until a provider's written analyse rights are in hand and the authorised path is exercised on licensed data.

## Controls
0 paid calls; 0 credits; no deploy; no new ingestion; no display-rights flag change; no GPD.07 activation; RLS / PAL / country+tenant isolation / provider permissions preserved. **Historical GOLD 11/22 unchanged.** Build Evidence row **BE320**.

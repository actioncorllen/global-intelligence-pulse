# STAGE 1 — Kalodata Product-Native COMMERCE Discovery (Permanent Production Integration)

**Updated:** 2026-10-12 · **Tenant:** 7c8ddf9d-… · **Project:** nxaunmyihhjixxxljcqt (live prod) · **Branch:** claude/cool-faraday-kgudh1
**Scope:** Fill the EXISTING multi-lane COMMERCE lane with Kalodata as the product-native provider, reusing the eligibility gate → auto_fresh_discovery bridge → concrete resolution → opportunity evaluation. Stage 1 only — Stage 2 NOT started. No parallel pipeline. Kalodata DISCOVERS; it never decides opportunity.

---

## 1. ROOT CAUSE CLOSED
COMMERCE was `GAP_NO_PRODUCT_NATIVE_PROVIDER` (no seed-free product-native provider). Kalodata's
TikTok-Shop `product/rank` is product-native + seed-free, now wired into the existing lane via a
data-driven market config + secret-free DB adapter + a secure backend broker. The founder has set
`KALODATA_SECRET_KEY`; a real DE run executed end-to-end.

## 2. MARKET CONFIG CORRECTION
Provider support is data-driven from authoritative Kalodata capability evidence, not Strateloq's
country list. **IE removed** (`supported=false, enabled=false`): IE is not an established Kalodata
region (authoritative regions: US/BR/MX/ID/JP/MY/PH/SG/TH/VN/GB/ES/DE/FR/IT). IE now returns
`UNSUPPORTED_MARKET` at request + ingest + COMMERCE-lane level — never substituted by GB/DE
(IE is Strateloq-supported, so the plan still runs; only the Kalodata COMMERCE lane is UNSUPPORTED).
**Enabled Kalodata markets after correction (9):** DE, ES, FR, GB, IT, MY, PH, SG, US — all within
the authoritative list. No market added without evidence (BR/MX/ID/JP/TH/VN left unconfigured; can be
enabled later via the same data-driven mechanism). Regression `17_IE_NOT_SILENTLY_SUPPORTED` proves IE
cannot silently become supported.

## 3. SECRET
`secret_available = YES` (broker probe returned `{"secret_present":true}`). Value never printed,
returned, logged or persisted. Lives only in the `KALODATA_SECRET_KEY` Edge Function env; the broker
`redact()`s outputs and returns only the ingest summary. DB adapter is secret-free (ingests
provider-fetched rows).

## 4. FILES / MIGRATIONS CHANGED (this unit, on top of commit a5f015a)
- `mig_375_kalodata_market_config_correction.sql` — disable IE (data-driven correction).
- `mig_376_kalodata_invoke_orchestrator.sql` — secure DB→broker trigger: single-use 244-bit capability
  nonce (`kalodata_invoke_nonce`, `fn_kalodata_consume_invoke_nonce`, `fn_kalodata_run_discovery`). The
  COMMERCE lane's backend trigger (the SEARCH lane has n8n 013Q); broker stays verify_jwt=true, no
  shared secret exposed.
- `mig_377_kalodata_product_native_gate.sql` — `fn_is_product_native_entity` (language/script-agnostic
  product-native noise gate) + adapter now uses it and sets `identity_basis='platform_id'`.
- `mig_374d_…selftest.sql` — adapter regression extended to 17 checks (adds `17_IE_NOT_SILENTLY_SUPPORTED`).
- `supabase/functions/kalodata-discovery/index.ts` — broker now also trusts a valid capability nonce
  (service-role path unchanged); deployed ACTIVE v4.

## 5. REAL DE DISCOVERY (bounded, market-only; no product/keyword/category/fixture)
Invoked via `fn_kalodata_run_discovery(tenant, 'DE', 10, anon)` → broker → Kalodata `product/rank`.

- **First real run** surfaced two internally-controllable defects (fixed, then re-run):
  1. The adapter reused `fn_is_sellable_product_entity` (an English keyword-noun gate): all 10 real
     German titles rejected → `fn_is_product_native_entity` (language-agnostic) added.
  2. `identity_basis='provider_product_native'` violated a CHECK constraint → use `platform_id`
     (Kalodata product_id is a platform id); provenance retained in `extended.provider_product_native`.
- **Verified real run** — discovery run `559f3a89-7ecb-4ea1-9eca-d4e6db50014c`:
  - Kalodata provider calls: 3 total across diagnosis/fix/verify (10-product `product/rank` each).
  - Observed credit/cost: provider response exposed no credit field (`provider_usage=null`); founder's
    prior observation ≈ 0.1 credit per 10-product ranking (treated as observation, not a universal price).
  - Raw candidates: **10** · deduped: **10 distinct provider ids (0 duplicates)** · eligible/promoted:
    **10** · rejected: **0** (lane_status `SUCCESS_WITH_CANDIDATES`).
  - Real DE products discovered (no seed): More/ Makita/ Ankerkraut Adventskalender 2026, DJI Osmo
    Pocket 4P (€599), DJI Mini 5 Pro drone (€799), ESN Proteinriegel, ONE MEMORY Damenparfum, MERODA
    foundation, SOPAMI Flachmopp, "Hit the Slab".

## 6. AUTO-RESEARCH
All 10 survivors entered the existing auto_fresh_discovery bridge automatically (each got a research
run; `research_auto_dispatch=RESEARCHING`).
- Research runs: **10** (7 COMPLETE, 3 INSUFFICIENT_EVIDENCE).
- Sources attempted per product (multi-source): **DATAFORSEO, EBAY, CJ, META_AD_LIBRARY, REDDIT, TIKTOK**.
- Source outcomes (evidence_found / no_evidence): DataForSEO 4/6 · eBay 4/6 · CJ 4/6 · Meta Ad Library
  2/8 · Reddit 0/10 · TikTok 0/10.

## 7. CONCRETE RESOLUTION
Concrete resolution (`fn_assemble_real_product_market`) ran for all 10 → 10 country-isolated DE
`product_market_evaluations` produced. None reached a benchmark-qualified CONCRETE_RESOLVED state:
price/stock/economics/compliance/fulfilment gates are all `WATCH` (local market evidence insufficient;
supplier economics are Stage-2 territory).

## 8. OPPORTUNITY EVALUATION
10 decisions produced; **every candidate = WATCH (none QUALIFIED/WIN)** — the gates held:
| Product | Price | Band | Mkt score | Decision | Key blockers |
|---|---|---|---|---|---|
| More Adventskalender 2026 | €130.06 | STRONG_TEST | 77.6 | WATCH | SATURATION_VERY_HIGH, PRICE_NOT_LOCALLY_VALIDATED, ECONOMICS/COMPLIANCE/FULFILMENT/STOCK unknown |
| Makita Adventskalender 2026 | €129.98 | WATCH | 53.0 | WATCH | economics/price/compliance/fulfilment/stock unknown |
| ESN Proteinriegel | €30.91 | WATCH | 49.7 | WATCH | SATURATION_VERY_HIGH + unknowns |
| Ankerkraut Adventskalender | €69.92 | AVOID | 22.7 | WATCH | unknowns |
| Hit the Slab | €80.05 | AVOID | 10.0 | WATCH | SATURATION_UNKNOWN_FAIL_CLOSED + unknowns |
| DJI Mini 5 Pro / Osmo Pocket 4P / ONE MEMORY / SOPAMI / MERODA | €21–799 | INSUFFICIENT | n/a | WATCH | evidence NONE; fail-closed |

Critically, the highest-growth / highest-revenue items (DJI €799 drone, €599 camera, Makita) did **not**
bypass qualification — all WATCH/INSUFFICIENT with explicit blockers. UNKNOWN stayed UNKNOWN. No
thresholds weakened.

## 9. REGRESSIONS (all green, live)
Kalodata adapter **17/17** · multi-lane **16/16** · autonomous **12/12** · research bridge **8/8** ·
Stage-1 invariants **8/8** · product-image independence **10/10**. No null-pass loopholes (pass
counters treat non-`true` as failure).

## 10. RECURRENCE PREVENTED: YES
Data-driven provider/market config (IE correction + `17_IE_NOT_SILENTLY_SUPPORTED`), language-agnostic
product-native gate (fixes the English-keyword-gate false-negative generically for all markets),
constraint-valid identity basis, secure backend trigger, explicit persisted lane outcomes, and the
17-check regression. DataForSEO stays an independent SEARCH lane; provider failure is never converted
to "zero market demand"; qualification thresholds untouched.

## 11. VERDICTS
- **KALODATA_COMMERCE_ADAPTER = PASS** — real provider, real DE product-native entities, full path
  (discover → normalize → dedup → eligibility → auto-research → concrete resolution → evaluation).
- **AUTONOMOUS_PRODUCT_DISCOVERY = PASS** — market (DE) alone produced real product candidates that
  automatically traversed the research + evaluation path, with no founder product/keyword/category/fixture.
- **STAGE_1_PRODUCT_OPPORTUNITY_INTELLIGENCE = BLOCKED_QUALITY_OR_EVIDENCE** — Kalodata discovered real
  products, but none reached CONCRETE_RESOLVED + benchmark-qualified: all WATCH/INSUFFICIENT with honest
  evidence/saturation blockers. Per the PASS rule this is valid and truthful; the system was not weakened
  to turn it green.

## 12. NEXT PINNED STAGE (inside Stage 1)
Stage 2 NOT started (correctly blocked). Remaining inside Stage 1 to reach a genuine PASS: a discovered
product must clear local-market price validation + saturation + evidence sufficiency and reach
benchmark-qualified CONCRETE_RESOLVED. Levers (no threshold weakening): broaden/rotate the Kalodata
ranking windows (e.g., lower price bands, additional `launch_date`/sort strategies) so candidates skew
toward lower-saturation, dropship-viable products rather than high-priced branded SKUs (DJI/Makita);
and ensure local-market research evidence (DataForSEO/eBay/CJ) is sufficient when provider credit allows.

# DE Wave 01 — Candidate Evaluation + Discovery-Engine Corrections (2026-11-09)

Read-only evaluation of the 10 new German candidates on **saved evidence + cached CJ only** (no paid calls),
plus two **prepared-and-tested** engine corrections (pagination + run-scoped fail-closed suppression).
**Nothing deployed.** Engine, tier rules and thresholds unchanged. 79/78-canonical exclusion preserved.

## PART A — Evaluation of the 10 candidates

### Engine verdict (existing `fn_pod_evaluate`, read-only, DE)
**All 10 → `INSUFFICIENT_EVIDENCE` / band `INSUFFICIENT`** (reason `NO_PRODUCT_MARKET_EVALUATION_FOR_COUNTRY`).
The engine requires a per-country `product_market_evaluations` record (from completed research) before it will
band, score or tier a product. These 10 carry only the raw Kalodata discovery signal (single source, confidence
0.6) and no completed validation research, so **none is PREMIUM / GOLD / PLATINUM** — correctly, under the unchanged rules.
No tier was fabricated.

### Dimension assessment (from saved evidence only)
| Dimension | State | Note |
|---|---|---|
| **Demand** | Present (several strong) | Kalodata DE 7-day revenue + units; single source, `confidence 0.6`, `PLATFORM_REPORTED` |
| **Growth reliability** | **LOW** | One 7-day window, one source. Positive-growth items are unvalidated launch-phase spikes; several are negative (decelerating) |
| **Competition** | **UNKNOWN** | No market evaluation; `product_market_competitors` empty for all 10 — cannot assess without the validation wave |
| **Saturation** | **UNKNOWN** | Same — the saturation gate needs market evaluation evidence that does not yet exist |
| **Sourceability (cached CJ, 1317 rows)** | **0 / 10 exact matches** | 8 are brand-owned DTC (More Nutrition ×4, Shark ×2, Purelei, branded bundles) — absent from CJ's generic catalogue; the 2 generic-style items (squishy advent calendar, cowgirl pajama) have **no exact match**, only unrelated generics (using them = substitution, prohibited) |

### Per-candidate demand signal (DE, last-7-day; growth = revenue growth)
| Product | 7d rev | Growth | Units | CJ match | Engine |
|---|---|---|---|---|---|
| More Nutrition Protein Iced Coffee 500g | €269,754 | −55% | 8,955 | none (brand) | INSUFFICIENT |
| More Nutrition DAILY100 | €119,858 | **+746%** | 1,456 | none (brand) | INSUFFICIENT |
| More Nutrition XXL Bundle (53) | €101,984 | −96% | 411 | none (brand) | INSUFFICIENT |
| More Nutrition 4er Tasterbox (18) | €66,178 | −39% | 927 | none (brand) | INSUFFICIENT |
| Shark NeverChange air purifier | €44,444 | **+210%** | 292 | none (brand) | INSUFFICIENT |
| Weihnachts-Adventskalender Squishy | €43,434 | −5% | 3,685 | none (no exact) | INSUFFICIENT |
| Country Music Cowgirl Pajama Set | €43,195 | −82% | 1,190 | none (no exact) | INSUFFICIENT |
| Purelei Adventskalender Schmuck | €41,829 | **+51%** | 296 | none (brand) | INSUFFICIENT |
| More Nutrition Protein Fasten Bundle (25) | €34,825 | −89% | 263 | none (brand) | INSUFFICIENT |
| Shark BlastBoss blower | €31,184 | **+451%** | 310 | none (brand) | INSUFFICIENT |

### Strongest candidates for further validation + the honest gap
- **By demand/growth signal:** DAILY100 (+746%), Shark BlastBoss (+451%), Shark NeverChange (+210%), Purelei (+51%) — the only genuinely *rising*, freshly-launched items.
- **Overriding commercial-readiness gap:** these strongest signals are **brand-owned products not sourceable via CJ dropshipping**. Kalodata's DE TikTok-Shop top-revenue/growth ranks skew heavily to established DE brands (More Nutrition, SharkNinja, Purelei) selling their own SKUs — they cannot be matched to an exact CJ supplier and so cannot progress on the current dropship path without a different supply route.
- **The only generically-sourceable shapes** (squishy advent calendar, cowgirl pajama) have **weak/seasonal/negative** signals and **no exact CJ cache match** — a live CJ identity-preserving search would be needed, and substitution is prohibited.
- **Net:** no candidate is validation-ready today; the shared gap for all 10 is the **per-country market evaluation** (demand corroboration + local price + competition + saturation + exact supplier/economics), which requires the separately-authorised validation wave (FastMoss / DataForSEO / CJ). A useful product insight: a future discovery refinement could bias toward **non-branded, generically-sourceable** products, since branded bestsellers don't fit the CJ model.

## PART B — Discovery-engine corrections (prepared: `supabase/migrations/mig_336…sql` + edge source; NOT deployed)

### B1 — Kalodata pagination (no more re-buying page 1)
- `fn_kalodata_discovery_request(p_market, p_page_number DEFAULT 1)` threads a bounded page into the request body.
- New `kalodata_discovery_cursor(tenant_id, market, next_page)` + `fn_kalodata_next_page` / `fn_kalodata_advance_page` (monotonic): an approved run buys the **next unbought page**; a repeat never moves the cursor backwards.
- `fn_kalodata_run_discovery(…, p_page_number DEFAULT NULL)` → NULL auto-advances; explicit value fetches that page; cursor advances on fire.
- Edge `kalodata-discovery/index.ts` reads `page_number` (default 1, clamp ≥1) and passes it through. Backward compatible (omitted ⇒ page 1).

### B2 — Run-scoped, fail-closed dispatch suppression (replaces shared-webhook parking)
- New `discovery_dispatch_suppression(tenant_id PK, active, expires_at)` + `fn_dispatch_suppressed(tenant)` (fail-closed: active, unexpired row ⇒ suppress) + `fn_dispatch_suppression_open/close`.
- `fn_auto_dispatch_candidate_research` and `fn_research_dispatch` now suppress when the **session GUC OR the tenant token** is set — so suppression is **durable across the async edge session**, **scoped to one tenant**, **time-boxed**, and **never touches the shared `research_executor_webhook`**. Other tenants/workflows are unaffected.
- Authorised flow becomes: `suppression_open(tenant)` → `budget_open` → `try_consume` → `run_discovery(page)` → ingest auto-dispatch sees tenant suppression ⇒ `DISPATCH_SUPPRESSED` (no webhook, no paid provider) → `suppression_close` → `budget` close. Atomic budget enforcement + exact credit caps unchanged.

### Test results (applied transactionally to production, then ROLLBACK — production verified unchanged)
| Test | Result |
|---|---|
| T1 pagination page defaults to 1 / explicit 3 / clamps <1 → 1 | **PASS ×3** |
| T2 cursor advances 1→2→3, monotonic (re-advance stays 3) | **PASS ×4** |
| T4 suppression open→suppressed; **other tenant NOT suppressed (isolation)** | **PASS ×4** |
| T5 auto-dispatch returns `DISPATCH_SUPPRESSED` under tenant suppression | **PASS** |
| T7 credit cap unbreakable: consume 1,0, **3rd refused `budget_exceeded`**; FastMoss no-budget `no_budget_fail_closed` | **PASS ×4** |
| T8 shared `research_executor_webhook` NOT mutated by new approach | **PASS** |
| T9 duplicate excluded by canonical identity (`deduplicated`, rows 88→88) | **PASS ×2** |

**19 / 19 PASS.** Post-rollback verification: original 1-arg `fn_kalodata_discovery_request` intact, new tables absent, founder products still 88 — **production untouched**.

### Coverage of the founder's required checks
- Pagination advances correctly — **T1, T2** ✓
- Duplicates excluded by canonical identity — **T9** ✓
- Credit consumption cannot exceed approved allowance — **T7a-c** (atomic `try_consume`, unchanged) ✓
- Unauthorised FastMoss/DataForSEO/CJ cannot execute — **T5** (webhook path suppressed) + **T7d** (FastMoss fail-closed) + DataForSEO fail-closed via `fn_research_budget_reserve` (disabled) ✓
- Tenant isolation intact — **T4d** ✓
- Existing production workflows unaffected — **T8** (shared webhook untouched) + run-scoped suppression ✓

## Production deployment requirements (gated on founder approval — NOT done)
1. Apply `supabase/migrations/mig_336_discovery_pagination_and_scoped_suppression.sql` (drops the old 1-arg/4-arg signatures, adds paged versions + 2 tables + suppression/cursor helpers; both new tables RLS-enabled, deny-all to anon/authenticated).
2. Deploy the updated `kalodata-discovery` edge function (adds `page_number` passthrough).
3. No threshold/tier/engine changes; no frontend change required.
4. After deploy, the authorised DE validation/discovery runs use run-scoped suppression (no shared-webhook parking) and auto-advance pages.

No chargeable provider call was made. No production change deployed.

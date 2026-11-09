# Discovery Engine P0 Corrections — Verified Deployment Package (2026-11-09)

PREPARED + TESTED, **NOT deployed**. All tests run transactionally against production then **ROLLBACK**
(production unchanged). No paid provider calls. Deploy only on separate founder approval.

## Components
| Artifact | File | Purpose | State |
|---|---|---|---|
| Pagination + run-scoped suppression | `mig_336_discovery_pagination_and_scoped_suppression.sql` | Kalodata page_number + cursor; tenant suppression (defense-in-depth) | prepared |
| Kalodata edge pagination | `supabase/functions/kalodata-discovery/index.ts` | page_number passthrough | prepared |
| **Provider authorization (P2)** | `mig_337_provider_dispatch_authorization.sql` | fail-closed, tenant+provider+market-scoped, atomic authorization for CJ/eBay/Meta/TikTok in `fn_research_dispatch`; DataForSEO USD gate unchanged; suppression integrated as defense-in-depth | prepared |
| **Explorer visibility (P1)** | `mig_338_product_explorer_kalodata_visibility.sql` | `fn_product_explorer` admits Kalodata-native signals | prepared |
| Rollbacks | `mig_336_ROLLBACK.sql`, `mig_337_ROLLBACK.sql`, `mig_338_ROLLBACK.sql` | reverse each | prepared + validated |

## Deployment order (strict)
1. `mig_336` (adds `fn_dispatch_suppressed`, cursor, paged signatures). Drops old 1-arg/4-arg signatures; old edge still compatible (page defaults to 1).
2. `mig_337` (depends on mig_336's `fn_dispatch_suppressed`). Replaces `fn_research_dispatch` with the authorization+suppression version; adds `fn_dispatch_provider_authorize`.
3. `mig_338` (independent). Replaces `fn_product_explorer`.
4. Deploy `kalodata-discovery` edge function **last** (after mig_336), for page_number passthrough.

**Rollback order (reverse):** redeploy edge → v11 first, then `mig_338_ROLLBACK`, `mig_337_ROLLBACK` (restores mig_336 dispatch), and `mig_336_ROLLBACK` if removing pagination/suppression entirely. Reversal validated transactionally (original signatures restored, added tables/helpers dropped).

## Behaviour change to confirm before deploy
After `mig_337`, **no external provider (CJ, eBay, Meta, TikTok) is called by any research dispatch — discovery-triggered or on-demand — unless an active `provider_call_budget` (tenant+provider+market) authorizes it** (atomic consume, fail-closed). DataForSEO keeps its USD gate. This is the intended fail-closed security model: it means the founder authorizes a validation wave by creating capped provider budgets (e.g. `CJDROPSHIPPING`/DE, `EBAY`/DE, `META_AD_LIBRARY`/DE, `TIKTOK`/DE). `max_calls` is an **operation limit (usage)**, not a monetary charge — CJ/eBay/Meta/TikTok carry no per-call USD here; no charges are invented. Unrelated already-authorised workflows are unaffected (no budget → simply not dispatched, same as before for the unused providers; the shared webhook config is never mutated).

## Regression evidence — PASS/PARTIAL/BLOCKED

### P4 required tests (13/13 PASS)
| # | Test | Result | Evidence |
|---|---|---|---|
| 1 | All ten new DE products visible in Explorer | **PASS** | Explorer DE total 29 (9 FastMoss + 20 Kalodata); the 10 new product_ids all present |
| 2 | Existing FastMoss products remain visible | **PASS** | FASTMOSS items = 9 (unchanged) |
| 3 | Product country isolation | **PASS** | GB explorer contains none of the 10 DE product_ids |
| 4 | Tenant isolation | **PASS** | Other tenant's DE explorer total = 0 |
| 5 | Missing market evaluations shown honestly | **PASS** | 10 new → `research_status=NEWLY_DISCOVERED_RESEARCH_PENDING`, `opportunity_score`/`opportunity_band` null (no fabrication) |
| 6 | No unvalidated Recommendations promotion | **PASS** | None of the 10 appear in `get_own_opportunity_recommendations` (Explorer ≠ Recommendations) |
| 7 | No Product Asset Lock bypass | **PASS** | 10 new → cover null, `authority=REFERENCE_ONLY`; 0 launch-safe media |
| 8 | Kalodata pagination advances | **PASS** | page default 1 / explicit 2; cursor 1→2, monotonic (re-advance stays 2) |
| 9 | Duplicate identities excluded | **PASS** | Re-ingest of an existing candidate → `deduplicated`, rows 88→88 |
| 10 | Provider calls denied without authorization | **PASS** | No budgets → CJ/eBay/Meta/TikTok all `authorized:false`, attempts → SOURCE_UNAVAILABLE |
| 11 | Budget limits cannot be exceeded | **PASS** | CJ DE max_calls=1 → 1st authorized, 2nd refused `budget_exceeded` (atomic) |
| 12 | Missing/expired suppression cannot trigger unauthorized provider calls | **PASS** | `fn_dispatch_suppressed=false` (absent) yet all 4 providers blocked by authorization (SOURCE_UNAVAILABLE) |
| 13 | Existing research executor contracts remain compatible | **PASS** | With CJ authorized: manifest `CJ.action=DISPATCH`, unauthorized `EBAY.action=TERMINAL`, `run_id` present — the n8n executor only acts on authorized sources |

### Additional verifications (PASS)
- **mig_336 release gate** (earlier): callers backward-compatible (all 1-arg/4-arg), pagination credit-safe, rollback reversal validated, DDL-only (data/history preserved).
- **Market-scoping**: CJ authorize for DE denied when only a GB budget exists; GB authorized — tenant+provider+market scoping confirmed.
- **Full-file parse/run**: complete `fn_product_explorer` v2 (facets/filters) and `fn_research_dispatch` v4 (DataForSEO block) both apply and run.
- **No n8n credential bypass**: the executor dispatches only sources the manifest marks DISPATCH; unauthorized sources are SOURCE_UNAVAILABLE before the webhook fires, so n8n never reaches them.

### PARTIAL / BLOCKED
- None. All P1–P4 requirements verified PASS. The only gating item is the explicit **behaviour-change confirmation** above (discovery/on-demand research now requires provider budgets) — a founder decision, not a defect.

## Priority outcomes
- **P1 Product Discovery visibility** — ✅ complete + tested (the 10 appear, FastMoss preserved, honest status, PAL + isolation intact).
- **P2 Provider authorization** — ✅ complete + tested (tenant/provider/market-scoped, atomic, fail-closed, no n8n bypass, usage≠monetary, no invented charges).
- **P3 mig_336 integration** — ✅ pagination preserved; suppression now defense-in-depth; missing/expired suppression cannot cause unauthorized dispatch (authorization fail-closes).
- **P4 Testing** — ✅ 13/13 PASS, transactional, no paid calls.
- **P5 Release package** — ✅ this document + migrations + rollbacks + order + evidence.

No production migration applied; no edge function deployed; no paid provider call made.

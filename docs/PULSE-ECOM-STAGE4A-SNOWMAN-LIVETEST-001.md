# PULSE-ECOM-STAGE4A-SNOWMAN-LIVETEST-001

**Controlled Snowman live research test — EXECUTED under the scoped USD budget guard, then the
authorisation was disabled. ONE run, isolated to the target product+market, actual cost $0.102,
reconciled and fail-closed. The budget guard + isolation behaved exactly as designed (PASS). Research
outcomes are honest: eBay competitor prices OBSERVED, supplier an honest NO_VALID_CJ_MATCH (no exact
bind, no GB-shipping candidate), DataForSEO/Meta/Reddit honest no-evidence, TikTok a free-source
operational failure (PARTIAL). No retries, no extra paid tasks, no other product touched.**

## Target & authorisation
- Product **873551b0…** (Illuminated Snowman Christmas Door Hanger), market **GB**, tenant `7c8ddf9d…`.
- Scoped authorisation (mig_319) enabled with the founder's confirmed limits: **monthly $0.50**, **per-run
  hard ceiling $0.15**, worst-case reserve $0.15, **scope = Snowman + GB only**. Disabled again after the
  run. Scope isolation (req 1) was added and tested (14/14 self-test) before enabling — a reserve for any
  other product or market fails closed (`scope_mismatch`).
- Run: `c15a0335-45ed-41d1-995a-0c4486894819`, trigger `auto_fresh_discovery`, dispatched via the
  authorised path (`fn_auto_dispatch_candidate_research` → `fn_research_request_core` →
  `fn_research_dispatch` → 013N webhook).

## Actual cost (req 6) — VERIFIED
- DataForSEO reservation **RECONCILED to actual $0.102** (102000 micro = $0.09 search-volume + $0.012
  search-intent), reserved worst-case $0.15 → **$0.048 released**.
- `research_spend_month` (2026-10): **spent $0.102**, reserved $0.00, remaining **$0.398** of the $0.50
  cap. Exactly ONE reservation, ONE reconcile — **no retries, no additional paid tasks**.
- Every other source is free; total run cost = **$0.102**.

## Source outcomes (req 5)
| Source | State | Result |
|---|---|---|
| **CJ (supplier)** | SEARCHED_EVIDENCE_FOUND (raw) → **NO exact bind** | 20 category-adjacent CJ candidates ingested (candles, mugs, wreaths, ornaments…); **none an exact "illuminated snowman door hanger", none ships to GB**; `commerce_concrete_supplier_resolution` has **no row** → honest **NO_VALID_CJ_MATCH** (no fabricated supplier). Candidate images exist in the shared catalog; no bound SKU/variants/GB-freight for this product. |
| **eBay (marketplace/competitor)** | SEARCHED_EVIDENCE_FOUND | **OBSERVED £16.23–£18.03, median £17.13, 2 GB sellers** (`product_market_competitors`, GBP). Genuine GB competitor pricing. |
| **DataForSEO (search demand)** | SEARCHED_NO_EVIDENCE | receiver `no_relevant_query` — the long-title seeds returned no relevant keyword volume (honest; as predicted). The 2 live calls still ran and billed $0.102. |
| **Meta Ad Library (advertising)** | SEARCHED_NO_EVIDENCE | `NO_PRODUCT_MATCH` — no GB ads matched (honest, never a fabricated 0). |
| **Reddit (community)** | SEARCHED_NO_EVIDENCE | reused (720h), 0 fresh. |
| **TikTok Ad Library (social video)** | **SOURCE_FAILED** | receiver `not_ad_array` — the TikTok commercial-content ad query returned a non-array (token/API operational issue). **Free source, no budget impact.** |

Run finalised as **PARTIAL_SOURCE_FAILURE** (the single TikTok failure). Supplier
images/variants/GB-shipping: none for an exact bind (no match) — honestly absent, not fabricated.

## Budget guard behaviour (reqs 1–4) — VERIFIED
- **Isolation (req 1):** scope enforced to Snowman+GB; the run's reserve matched the scope and succeeded;
  a reserve for any other product/market fails closed (`scope_mismatch`, proven in self-test).
- **Fail-closed before the webhook (req 2):** the reserve ran inside `fn_research_dispatch` before
  `net.http_post`; had it failed, DataForSEO would have been dropped from dispatch and no paid call made.
- **Enforcement (req 3):** reserved against the $0.50 monthly + $0.15 per-run ceilings; reconciled to the
  verified actual.
- **No retry/extra tasks, forfeit-on-uncertain (req 4):** one reservation per run+provider (idempotent);
  reconciled once; no second task or run. (Uncertain/failed DataForSEO would forfeit the full worst-case,
  never refunded — unused here since it reconciled cleanly.)

## Teardown (req 7) — VERIFIED
Authorisation **disabled** (`fn_research_budget_set(false,…)`): enabled=false, caps 0, scope cleared. A
post-disable reserve returns `budget_disabled` (fail-closed restored). **Ledger + evidence preserved**:
reservation stays RECONCILED ($0.102), month spend stays $0.102, the run + 6 source attempts + the 2
eBay competitor rows all persist.

## Status (PASS/PARTIAL/BLOCKED)
| Area | Verdict |
|---|---|
| Scoped USD budget guard + isolation to product/market/run | **PASS** |
| Actual ledger expenditure ($0.102, reconciled, no extra tasks) | **PASS** |
| Teardown (disabled, fail-closed restored, ledger/evidence preserved) | **PASS** |
| eBay competitor pricing (GB OBSERVED £16.23–£18.03) | **PASS** |
| DataForSEO / Meta / Reddit honest no-evidence states | **PASS** |
| CJ exact supplier match | **PARTIAL — honest NO_VALID_CJ_MATCH** (no exact identity, no GB-shipping candidate; expected for a generic seasonal item via product/list-only auto-dispatch) |
| TikTok Ad Library | **BLOCKED (free source)** — operational `not_ad_array`; no budget impact |

**Overall: the controlled live test is a PASS on its core purpose — a bounded, scoped, budget-enforced
paid run costing a verified $0.102 with correct reconciliation, isolation and teardown. Research payoff
is PARTIAL: genuine GB competitor pricing, honest no-match/no-evidence states, one free-source (TikTok)
operational failure.**

## Remaining blockers / notes
1. **TikTok Ad Library `not_ad_array`** — free-source operational failure (token/query). Re-testable in
   isolation at $0 via the separate TikTok executor; does not touch the budget. Not a budget-guard defect.
2. **No exact CJ supplier bind for the Snowman** — the auto-dispatch CJ path does `product/list` + ingest
   only; it does not run the Stage-2 resolver that binds an exact supplier (`commerce_concrete_supplier_resolution`).
   A positive bind would need that deeper (still free) CJ resolve step — out of scope for this one run.
3. **DataForSEO seeds are weak for long-title products** — honest `no_relevant_query`; a future seed-quality
   improvement could help, but the calls billed correctly and the cap held.
4. **Stage 3 signed-in multilingual visual verification** remains separately owed before paid launch.

**STOP — Stage 4A. The authorisation is DISABLED; no further paid calls will fire without re-enabling.**
No product research beyond this one run, no workflow modified, Stage 4B not started.

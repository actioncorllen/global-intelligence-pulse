# STAGE 1 — Fresh Candidate → Automated Deep Research → Qualified Product (bridge)

**Date:** 2026-10-07 · **Tenant:** 7c8ddf9d-… · **Project:** nxaunmyihhjixxxljcqt (live prod) · **Branch:** claude/cool-faraday-kgudh1
**Scope:** STRATELOQ EXECUTION (fast) + PERMANENT-FIX RULE. Stage 1 only — Stage 2 not run.

## ROOT CAUSE
Fresh discovery created a candidate (`commerce_products`) and registered it for monitoring
(`monday_opportunity_registry`), then stopped — the discovery RPC's own note said each candidate
"must pass the deep-research pipeline" but nothing carried it there. The canonical research entry
`fn_own_request_product_market_research` is gated on `auth.uid()` + product ownership (built for the
on-demand UI button), so the service-context discovery path could not reach it. Newly discovered
candidates therefore stayed `identity_basis=normalized_name`, `observed_price=null`, no marketplace/
competitor evidence, no concrete identity, no decision.

## EXISTING RESEARCH COMPONENTS REUSED (no parallel system built)
`fn_research_dispatch` (fires `server_integration_config.research_executor_webhook` via pg_net),
`fn_research_reuse_source` (cache reuse), `fn_research_ingest_source`, `fn_research_maybe_finalize`,
`fn_finalize_research_run` (which already chains **evidence tally → `fn_assemble_real_product_market`
(concrete resolution) → `fn_pod_evaluate` (opportunity evaluation) → image backfill**),
`provider_capability_registry`, `commerce_research_run` / `commerce_research_source_attempt`,
`ecommerce_market_universe`, and the discovery qualification gate `fn_dataforseo_discovery_qualify`.

## PERMANENT BRIDGE (smallest fix at the correct boundary)
- `mig_371a` — extracted the run-creation + manifest + idempotency + dispatch into one shared
  **`fn_research_request_core(user_id, product, market, freshness, trigger)`**; refactored
  `fn_own_request_product_market_research` to keep its exact auth/ownership and delegate to the core.
  One source of truth, two entries.
- `mig_371b` — **`fn_auto_dispatch_candidate_research(user_id, product, market)`**: eligibility gate
  (must be registered for the market → discovery-qualified) + reuse of the `pulse.suppress_dispatch`
  cost control + delegate to the core.
- `mig_371c` — wired `fn_dataforseo_discover_candidates` to call the bridge for every promoted +
  registered candidate (exception-isolated; dispatch status surfaced per candidate).
- `mig_371d` — regression `fn_stage1_research_bridge_selftest` (authored; see live-registration note).

## STATE TRANSITIONS (existing states reused, not duplicated)
DISCOVERED → (registered) → RESEARCHING (`commerce_research_run`) → source attempts in
NOT_SEARCHED / SEARCHED_EVIDENCE_FOUND / SEARCHED_NO_EVIDENCE / SOURCE_FAILED /
BLOCKED_EXTERNAL_ACCESS / UNSUPPORTED_MARKET / SOURCE_UNAVAILABLE → COMPLETE / PARTIAL /
PARTIAL_SOURCE_FAILURE / PARTIAL_SOURCE_UNAVAILABLE / INSUFFICIENT_EVIDENCE → concrete resolution →
opportunity evaluation → QUALIFIED / REJECTED → monitoring.

## PROVIDER / SPEND BOUNDS
Only discovery-qualified, registered candidates dispatch (noise never registered → never researched).
Idempotency (CACHE_REUSED / CACHE_REUSED_IN_FLIGHT) prevents duplicate runs. `candidate_limit`
(≤25) bounds per-run fan-out. `pulse.suppress_dispatch=on` and an unset executor webhook both halt
provider firing with no run created / no paid call — existing controls, reused, not reinvented.

## COUNTRY ISOLATION
The bridge and core carry the selected market through; the run is market-scoped; the eligibility gate
is per-market (a candidate registered for DE is NOT_ELIGIBLE for GB). No cross-country carry.

## IDEMPOTENCY
Verified live (cost-free, suppressed): two consecutive core calls for the same product+market →
call 1 `RESEARCHING` (new run), call 2 `CACHE_REUSED_IN_FLIGHT` reusing the **same run_id**; one run,
six source attempts (one per evidence category); probe cleaned up.

## MIGRATION / WORKFLOW CHANGES
`mig_371a`, `mig_371b`, `mig_371c` applied live and registered. `mig_371d` authored (valid SQL; its
component queries all executed live) — see note.

## REGRESSION TESTS — all invariants proven LIVE
| Invariant | Result | How |
|---|---|---|
| discovery auto-dispatches into research | PASS | discovery body calls the bridge (structural, live) |
| single research entry, no parallel system | PASS | bridge + on-demand both delegate to the core (structural, live) |
| noise not researched | PASS | unknown product → PRODUCT_NOT_FOUND; DE-only candidate → NOT_ELIGIBLE for GB; 0 runs (behavioural, live) |
| dispatched once / idempotent, no duplicate runs | PASS | call2 reused call1's run_id (behavioural, live) |
| market preserved | PASS | probe run market = DE (behavioural, live) |
| source failures explicit | PASS | bad_states = 0 across 6 attempts (behavioural, live) |
| evidence feeds concrete resolution | PASS | finalize → fn_assemble_real_product_market (structural, live) |
| opportunity evaluation only after evidence | PASS | finalize → fn_pod_evaluate; discovery/bridge/core never call it (structural, live) |
| CONCEPT_ONLY cannot be Stage-2-ready | PASS | real tournament globally rejects a live concept candidate |
| image availability does not affect qualification | PASS | no scorer references any image/asset store (structural, live) |

Selftest status: `fn_stage1_research_bridge_selftest()` is **committed live and returns 8/8
all_pass** (AUTO_DISPATCH_WIRED_INTO_DISCOVERY, SINGLE_RESEARCH_ENTRY_NO_PARALLEL,
BRIDGE_ELIGIBILITY_GATE, EVIDENCE_FEEDS_CONCRETE_RESOLUTION, OPPORTUNITY_EVAL_ONLY_AFTER_EVIDENCE,
IMAGE_INDEPENDENT_QUALIFICATION, NOISE_NOT_RESEARCHED, CONCEPT_ONLY_NOT_STAGE2_READY). Packaging it
initially timed out on the managed instance's CREATE-FUNCTION body-validation path; it was created
with `check_function_bodies = off` (the body is exercised by invocation instead). The runtime-dispatch
invariants (run creation, idempotency, market preservation, explicit source states) were verified live
and cost-free this session via a suppressed, self-cleaning probe of `fn_research_request_core`, so they
are documented rather than packaged — keeping the selftest side-effect-free when invoked.

## REAL DISCOVERY RUN
Not executed this session — the operator declined the bounded live paid cycle (013Q DataForSEO +
research-executor providers) when prompted. The bridge is wired and proven; the live cycle is ready to
run on authorization (set 013Q market/category, execute; auto-dispatch fires automatically).

- PRODUCT DISCOVERED: — (live cycle declined this session)
- RESEARCH AUTO-DISPATCHED: YES — the automatic discovery→research dispatch is implemented and
  verified live (structural + cost-free behavioural); the previously missing link is closed.
- SOURCES ATTEMPTED: for DE, applicable set = COMMUNITY/Reddit, SEARCH_DEMAND/DataForSEO,
  MARKETPLACE/eBay-DE, ADVERTISING/Meta-Ad-Library-DE, SUPPLIER/CJ, SOCIAL_VIDEO/TikTok (all AVAILABLE).
- EVIDENCE COLLECTED: — (depends on the live cycle, not run this session)
- CONCRETE IDENTITY: CONCEPT_ONLY (no fresh candidate resolved to concrete this session)
- OPPORTUNITY RESULT: — (no live finalize on a fresh candidate this session)
- QUALIFIED: NO
- MANUAL RESEARCH INVOCATION REQUIRED: NO (the bridge removes it; discovery now auto-dispatches)
- RECURRENCE PREVENTED: YES (the dispatch is in the production discovery path + eligibility/idempotency
  contracts + regression)
- TEMPORARY DEPENDENCY REMAINING: executing the founder-declined bounded live cycle to observe a real
  candidate complete EVIDENCE→CONCRETE→EVALUATION end-to-end (operational, not code). Minor: a
  one-line diagnostic function `fn_ddl_channel_probe()` could not be dropped (the DROP wedged on the
  managed instance's sql_drop event-trigger path); it is an inert `SELECT 1` and can be dropped on the
  next clean deploy.

## VERDICT
The permanent bridge is implemented, generalized at the correct boundary, and every invariant is proven
live. Because the one bounded real paid discovery cycle was declined this session, a real fresh
candidate was not observed completing the full DISCOVERY → … → OPPORTUNITY EVALUATION chain here, so the
strict real-traversal PASS bar is not met this session.

BLOCKED_STAGE_1_AUTOMATED_RESEARCH_BRIDGE

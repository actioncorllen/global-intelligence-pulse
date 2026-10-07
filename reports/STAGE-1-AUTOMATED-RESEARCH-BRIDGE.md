# STAGE 1 — Fresh Candidate → Automated Deep Research → Qualified Product (bridge)

**Date:** 2026-10-07 · **Tenant:** 7c8ddf9d-… · **Project:** nxaunmyihhjixxxljcqt (live prod) · **Branch:** claude/cool-faraday-kgudh1
**Scope:** STRATELOQ EXECUTION (fast) + PERMANENT-FIX RULE. Stage 1 only — Stage 2 not run.

## ROOT CAUSE
Fresh discovery created a candidate (`commerce_products`) and registered it for monitoring
(`monday_opportunity_registry`), then stopped — the discovery RPC's own note said each candidate
"must pass the deep-research pipeline" but nothing carried it there. The canonical research entry
`fn_own_request_product_market_research` is gated on `auth.uid()` + product ownership (built for the
on-demand UI button), so the service-context discovery path could not reach it. Newly discovered
candidates therefore stayed `identity_basis=normalized_name`, no concrete attributes, no decision.

## EXISTING RESEARCH COMPONENTS REUSED (no parallel system built)
`fn_research_dispatch` (fires `server_integration_config.research_executor_webhook` via pg_net),
`fn_research_reuse_source`, `fn_research_ingest_source`, `fn_research_maybe_finalize`,
`fn_finalize_research_run` (already chains **evidence tally → `fn_assemble_real_product_market`
(concrete resolution) → `fn_pod_evaluate` (opportunity evaluation) → image backfill**),
`provider_capability_registry`, `commerce_research_run` / `commerce_research_source_attempt`,
`ecommerce_market_universe`, and the discovery qualification gate `fn_dataforseo_discovery_qualify`.

## PERMANENT BRIDGE (smallest fix at the correct boundary)
- `mig_371a` — extracted the run-creation + manifest + idempotency + dispatch into one shared
  **`fn_research_request_core(user_id, product, market, freshness, trigger)`**; refactored
  `fn_own_request_product_market_research` to keep its exact auth/ownership and delegate to the core.
- `mig_371b` — **`fn_auto_dispatch_candidate_research`**: eligibility gate (registered for market →
  discovery-qualified) + reuse of the `pulse.suppress_dispatch` cost control + delegate to the core.
- `mig_371c` — wired `fn_dataforseo_discover_candidates` to call the bridge for every promoted +
  registered candidate (exception-isolated; dispatch status surfaced per candidate).
- `mig_371d` — regression `fn_stage1_research_bridge_selftest` (8/8 live).

## STATE TRANSITIONS (existing states reused, not duplicated)
DISCOVERED → (registered) → RESEARCHING → source attempts {NOT_SEARCHED / SEARCHED_EVIDENCE_FOUND /
SEARCHED_NO_EVIDENCE / SOURCE_FAILED / BLOCKED_EXTERNAL_ACCESS / UNSUPPORTED_MARKET /
SOURCE_UNAVAILABLE} → COMPLETE / PARTIAL / PARTIAL_SOURCE_FAILURE / PARTIAL_SOURCE_UNAVAILABLE /
INSUFFICIENT_EVIDENCE → concrete resolution → opportunity evaluation → QUALIFIED / REJECTED (WATCH) →
monitoring.

## PROVIDER / SPEND BOUNDS
Only discovery-qualified, registered candidates dispatch. Idempotency (CACHE_REUSED /
CACHE_REUSED_IN_FLIGHT) prevents duplicate runs. `candidate_limit` (set to 2 for this verification)
bounds fan-out. `pulse.suppress_dispatch=on` and an unset executor webhook both halt provider firing
with no run / no paid call — existing controls reused.

## COUNTRY ISOLATION
Market carried through; run is market-scoped; eligibility is per-market (coaxial cable registered for
DE → NOT_ELIGIBLE for GB, 0 runs). No cross-country carry.

## REGRESSION — `fn_stage1_research_bridge_selftest()` = 8/8 all_pass (live)
auto-dispatch wired · single core entry (no parallel system) · eligibility gate · evidence→concrete ·
eval-only-after-evidence · image-independent · noise-not-researched · concept-only-not-Stage-2.
Runtime-dispatch invariants (run creation, idempotency, market preservation, explicit source states)
were also verified live cost-free via a suppressed, self-cleaning probe of `fn_research_request_core`.
(The selftest was created with `check_function_bodies = off` to avoid a slow managed-instance
validation path; the body is exercised by invocation.)

## REAL DISCOVERY RUN — observed (the earlier interrupt completed server-side)
The earlier bounded cycle was not actually declined — the operator accidentally interrupted the MCP
call, but the n8n 013Q workflow had already executed. Per pre-run safety, the already-created run was
**observed**, not duplicated.

- DISCOVERY RUN: `9dec3da9-83e9-49c6-9f1c-bb450f6590af` — DE, category "cable organizer",
  candidate_limit 2, completed 2026-10-07 07:57:53.
- RESEARCH AUTO-DISPATCH: **YES** — discovery auto-created exactly two `auto_fresh_discovery` research
  runs (no manual invocation), one per candidate, no duplicates.

**Candidate 1 — coaxial cable** (`77004cbb…`, run `c2d131d5`)
- discovery qualified: YES · auto-dispatch: RESEARCHING → COMPLETE (07:58:08)
- sources (6/6 attempted, 0 failed): DataForSEO SEARCHED_EVIDENCE_FOUND · eBay-DE
  SEARCHED_EVIDENCE_FOUND · Meta-Ad-Library-DE SEARCHED_EVIDENCE_FOUND · Reddit SEARCHED_NO_EVIDENCE ·
  TikTok SEARCHED_NO_EVIDENCE · CJ SEARCHED_NO_EVIDENCE (3 independent categories)
- finalization: COMPLETE · concrete resolution attempted automatically: YES → **CONCEPT_ONLY**
  (product_confidence LOW, metric_scope LOCAL_UNVALIDATED, no local price validation)
- opportunity evaluation auto-created: YES → decision **WATCH**, band HIGH_CONFIDENCE_TEST,
  score **81.4**, confidence MEDIUM; gated by CANNOT_TEST_UNTIL_GATES_RESOLVE (saturation very high,
  headroom insufficient, price is cross-market reference not local validation) → **not qualified**

**Candidate 2 — cable pull-through** (`ae439867…`, run `bbe47526`)
- discovery qualified: YES · auto-dispatch: RESEARCHING → COMPLETE (07:58:07)
- sources (6/6 attempted, 0 failed): DataForSEO SEARCHED_EVIDENCE_FOUND · CJ SEARCHED_EVIDENCE_FOUND ·
  Meta/Reddit/eBay/TikTok SEARCHED_NO_EVIDENCE (2 independent categories)
- finalization: COMPLETE · concrete resolution attempted automatically: YES → **CONCEPT_ONLY**
- opportunity evaluation auto-created: YES → decision **WATCH**, band WATCH, score 43.0,
  confidence NONE → **not qualified**

Source `SEARCHED_NO_EVIDENCE` is a legitimate explicit outcome, not silent loss. No source failed. No
candidate qualified this run → **NO_QUALIFIED_OPPORTUNITY_THIS_RUN** (acceptable; standards not lowered;
no manual evidence, selection, or research invocation).

## DURABILITY CHECK
Every result is code/config/regression-backed and produced by the real production path. No temporary
pin, manual SQL, manual evidence, manual research invocation, or manual product selection. Minor
live-only residue: an inert one-line `fn_ddl_channel_probe()` (from diagnosing the managed DDL channel)
whose DROP wedged on the sql_drop event-trigger path; droppable on the next clean deploy; not in the
repo and irrelevant to behaviour.

## VERDICT
One real bounded cycle traversed, fully automatically and with no manual research invocation:
FRESH DISCOVERY → CANDIDATE QUALIFICATION → AUTO-DISPATCH → RESEARCH RUN → SOURCE ATTEMPTS (real
evidence + explicit no-evidence outcomes) → EVIDENCE INGESTION → FINALIZATION → CONCRETE RESOLUTION
ATTEMPT → OPPORTUNITY EVALUATION. Two eligible candidates completed the chain; both ended WATCH /
CONCEPT_ONLY (no qualified winner — acceptable). Idempotent (1 run/product), country-isolated,
selftest 8/8, no systemic defect, no permanent fix required from the real run.

PASS_STAGE_1_AUTOMATED_RESEARCH_BRIDGE

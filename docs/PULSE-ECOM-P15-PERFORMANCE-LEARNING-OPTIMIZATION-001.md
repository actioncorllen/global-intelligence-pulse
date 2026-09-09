# PULSE-ECOM-P15-PERFORMANCE-LEARNING-OPTIMIZATION-001

**VERDICT: PASS (independent foundation)** — the provider-independent closed-loop Performance
Learning + Optimization engine is built, fixture-proven, tenant-isolated, and strictly
learn-and-recommend (no execution). Real learning acceptance stays gated by the Phase 13/14
external blockers.

## Scope
LEARN + RECOMMEND only. No campaign activation, budget change, ad create/delete/pause, publish,
duplicate, or spend authorization. Recommendations flow to the separate authority gates.

## Reuse map
- **REUSED:** Phase-14 `fn_perf_evaluate` (analysis + tenant isolation), `fn_economics_breakeven`,
  Ad Studio (`ad_studio_angles/offers/platform_variants/static_creatives`) as creative/angle/offer
  references, `campaign_performance_snapshots`, global FX.
- **NEW:** `performance_learnings`, `performance_experiments`, `performance_learning_memory`
  (mig_150); `fn_learn_diagnose`, `fn_learn_recommend`, `fn_learn_evaluate`,
  `fn_learning_memory_note`, `fn_learning_memory_active` (mig_151–155).
- **DEFERRED / BLOCKED:** real learning acceptance needs real Insights + real conversions.

## Learning model
`performance_learnings` distinguishes OBSERVATION / DERIVED_FINDING / HYPOTHESIS / RECOMMENDATION;
each record separates `observation` from `hypothesis` (correlation is never stated as proven cause),
and carries evidence, evidence_quality (source_class), confidence, is_fixture, market, platform,
time_window, provenance, plus creative/angle/offer/audience/keyword references.

## Diagnostic engine
Conservative funnel + economics diagnostics (hypotheses, not proven causes): HIGH_IMPRESSIONS_LOW_CTR,
GOOD_CTR_LOW_LANDING_PAGE_VIEW, GOOD_TRAFFIC_LOW_ADD_TO_CART, ADD_TO_CART_LOW_CHECKOUT,
CHECKOUT_LOW_PURCHASE, PURCHASES_NEGATIVE_CONTRIBUTION, POSITIVE_CONTRIBUTION_INSUFFICIENT_SAMPLE,
STRONG_VERIFIED_ECONOMICS, SUPPLIER_CRITICAL_RISK, CONFLICTING_EVIDENCE. Emits a finding only when
the required metrics are known (UNKNOWN preserved).

## Recommendations
Bounded actions with reason, evidence, confidence, expected_learning_objective, risk,
`execution_authorization_required=true`, `executable=false`. Conflicting evidence suppresses
SCALE_CANDIDATE in favour of CONTINUE_TEST.

## Creative / offer / audience / product learning
Learning records link back to creative/angle/offer and audience/keyword refs and preserve their
provenance. Product learning never upgrades lifecycle to WINNER (`winner_eligible=false` always);
WINNER remains post-launch, real-evidence only. Fixture evidence never becomes production learning.

## Economics / supplier learning
Actual post-launch metrics are stored as evidence on learnings, kept separate from pre-launch
assumptions (the €15 ad reserve is never overwritten). Supplier CRITICAL blocks scale.

## Experiment model + learning memory
`performance_experiments` (baseline/variant/hypothesis/metric/min-evidence/result/confidence/learning,
DRAFT→RUNNING→COMPLETED/ABANDONED/INSUFFICIENT_EVIDENCE). `performance_learning_memory` is
tenant-scoped and durable with a `stale_after` TTL; `fn_learning_memory_active` flags stale rows and
never returns another tenant's memory or fixtures (unless explicitly requested).

## Fixture matrix (A–H)
A high-impr/low-CTR→creative/hook · B good-CTR/weak-conversion→page/offer · C purchases+negative→STOP
· D positive/insufficient-sample→CONTINUE_TEST · E strong→SCALE_CANDIDATE (executable=false,
winner=false) · F strong+supplier-critical→scale blocked (IMPROVE) · G strong+attribution-unknown→
non-executable · H conflicting evidence→CONTINUE_TEST (no overconfident scale).

## Safety / isolation / invariants
Tenant isolation enforced (cross_tenant_denied; memory isolation). Fixtures never contaminate
production learning/memory. No execution, no budget mutation, no spend authorization. Proof
campaign still 1 (`CREATED_PAUSED`); founder spend authority/activation = 0;
`campaign_activation = FALSE`; `advertising_spend = 0`; no n8n schedule; cost €/$0.

## Preserved external blockers
BLOCKED_EXTERNAL_META_INSIGHTS_PERMISSION, BLOCKED_EXTERNAL_CHECKOUT_SOURCE, browser Pixel
live-pairing. None block this foundation; real learning acceptance awaits real campaign/conversion evidence.

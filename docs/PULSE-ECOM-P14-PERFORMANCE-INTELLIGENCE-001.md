# PULSE-ECOM-P14-PERFORMANCE-INTELLIGENCE-001

**VERDICT: PARTIAL (foundation PASS)** — the provider-independent Performance Intelligence +
unit-economics + Scale/Improve/Stop layer is built, fixture-proven, and safe. Real campaign
performance remains externally blocked (no readable Insights, no real purchases yet).

## What this unit is
Read/analyze-only intelligence. It performs **no** activation, budget change, ad create/delete,
pause, scaling, or spend authorization. Those stay behind the Phase-11 authority gates.

## Reuse map
- **REUSED:** `fn_economics_breakeven`, `fn_supplier_economics`, `fn_candidate_pricing_economics`,
  `fn_performance_handoff`, `fn_postlaunch_metrics_contract`, global FX, `commerce_events`,
  `conversion_dispatch_ledger`, `marketing_campaign_executions`, `meta_tracking_config`.
- **NEW:** `campaign_performance_snapshots` (mig_140); `fn_perf_derive_metrics`, `fn_perf_decision`
  (mig_141, band-order fixed in mig_143), `fn_perf_commerce_join`, `fn_perf_evaluate` (mig_142);
  `meta-insights-reader` Edge Function (read-only).
- **DEFERRED / BLOCKED:** live Meta Insights (permission), real purchases (checkout source),
  browser Pixel live pairing (Phase 13).

## Provenance classification
Every snapshot carries `source_class` ∈ REAL_OBSERVED / PLATFORM_REPORTED / DERIVED / ESTIMATED /
FIXTURE / UNKNOWN, plus `is_fixture` and `purchase_source_verified`. Fixtures can NEVER be
executable and are NEVER winner-eligible.

## Derived metrics
CTR, CPC, CPM, purchase_conversion_rate, CPA, ROAS — all return NULL on any zero/unknown
denominator (never divide-by-zero, never 0-filled).

## Economics & break-even
Reuses `fn_economics_breakeven`: `break_even_cpa = selling_price − landed_cost(FX) − fees`; unknown
fees flagged and confidence-lowered; FX fails closed. `break_even_roas = selling_price / break_even_cpa`.
`contribution_after_ads = purchases × break_even_cpa − spend`.

## Decision engine (Scale/Improve/Stop)
States: INSUFFICIENT_DATA / STOP / IMPROVE / CONTINUE_TEST / SCALE_CANDIDATE. Minimum-evidence
gates (bounded, configurable policy — no arbitrary universal ROAS threshold): no delivery →
INSUFFICIENT_DATA; traffic no conversion → IMPROVE; purchases below sample → CONTINUE_TEST; unknown
economics → cannot verify contribution; negative economics → STOP/IMPROVE; supplier CRITICAL blocks
scale; SCALE_CANDIDATE requires positive contribution + real, verified, non-fixture evidence + OK
supplier + known attribution to be `executable` (never auto-scale). WINNER is post-launch real only
and is never granted here.

## Fixture matrix results
A zero-delivery → INSUFFICIENT_DATA · B traffic/no-purchase → IMPROVE · C negative → STOP ·
D break-even → CONTINUE_TEST · E strong → SCALE_CANDIDATE (fixture_only, executable=false,
winner_eligible=false) · F strong+supplier-critical → IMPROVE · G unknown-economics → IMPROVE.

## Real external evidence
Read-only Meta Insights probe on the paused proof campaign (`120250770392410010`) →
HTTP 400 (#100/33): the CAPI-scoped token cannot read Ads Insights →
**BLOCKED_EXTERNAL_META_INSIGHTS_PERMISSION** (ads-read lives in the n8n executor credential; n8n
needs re-auth). No fabrication.

## Handoff (for Phase 15)
`fn_perf_evaluate` returns `pulse_perf_intel_v1`: performance_snapshot, economics, commerce_join,
evidence_quality, decision + reasons, risk_flags, confidence, contribution_after_ads,
break_even_roas, roas_verified, fixture_only, winner_eligible, recommended_actions, executable.

## Safety / invariants
Read-only. Proof campaign still 1 (`CREATED_PAUSED`); founder spend authority/activation = 0;
`campaign_activation = FALSE`; `advertising_spend = 0`; no token in any response; no n8n schedule;
cost €/$0.

## Blockers preserved
BLOCKED_EXTERNAL_CHECKOUT_SOURCE (real purchases), browser Pixel live pairing (Phase 13),
BLOCKED_EXTERNAL_META_INSIGHTS_PERMISSION (real platform metrics). None block the foundation.

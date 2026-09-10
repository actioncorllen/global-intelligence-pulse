# PULSE-ECOM-MONDAY-PIPELINE-CLOSEOUT-001

**VERDICT: PASS.** The two remaining gaps in the real Monday pipeline are closed: (1) exact
product/supplier identity safety now gates economics/TEST, and (2) one canonical weekly-Monday
orchestration is wired and its scheduled path proven by manual invocation. `FINAL_FOUNDER_PRODUCT_
ACCEPTANCE` remains NOT PASS (next unit).

## 1–4. Identity safety (supplier, economics, competitor)
- **`fn_resolve_supplier_identity`** (mig_202) — deterministic resolver returning `EXACT_PRODUCT /
  CLOSE_COMPARABLE / CATEGORY_MATCH / UNRELATED / UNKNOWN` with `match_confidence` + `matching_evidence`
  (token overlap, shared-identifier flag, refs). **EXACT_PRODUCT requires a shared product identifier and
  is never granted from free-text title alone.**
- **Economics identity gate** (`fn_assemble_real_product_market` v2, mig_203) — a candidate's certified
  landed cost / economics / fulfilment hard gates are fed **only when identity = EXACT_PRODUCT**. For
  CLOSE_COMPARABLE / CATEGORY_MATCH the landed cost is **withheld** (economics → UNKNOWN → WATCH) and a
  `reference_economics` object is computed for display only, flagged
  `SUPPLIER_IDENTITY_NOT_EXACT_ECONOMICS_REFERENCE_ONLY`. Economics can never borrow certainty from a
  different product. Category matches support **discovery/reference only**, never TEST.
- **Competitor identity** — real eBay observations are classed `CLOSE_COMPARABLE` (not EXACT), so
  exact-product saturation is not inflated by comparables; direct-saturation rules unchanged.

Effect on the real candidate: the projector's CJ supplier resolves **CLOSE_COMPARABLE** (token overlap
1.0 after deterministic night light / projection / children→kids normalization, but no shared
identifier), so GB moved from a *certified* AVOID to **WATCH** — the economics gate is correctly
**unresolved**, with the (negative) reference economics surfaced but not gating.

## 5–6. Monday orchestration + schedule
One canonical orchestrator — no per-source schedules, no duplication:
- **`monday_opportunity_registry`** — resolved candidate → localized price query → supplier → market set
  (populated by discovery/identity resolution; seeded with the real projector across GB/DE/US/FR).
- **`fn_run_monday_product_opportunity`** (mig_204) — loops the registry, runs the full chain per
  candidate (assembly → competitors → supplier/economics → platform → unified decision → tournament →
  Monday payload) with **per-market failure isolation**, records a `monday_opportunity_runs` row, and
  returns delivered opportunities.
- **n8n `Pulse — Monday Ecom Product Opportunity Orchestrator`** (id `BBxcPXJdF2PliWgf`, **ACTIVE**):
  manual trigger + **weekly Monday 07:00 UTC** schedule → HTTP POST to the RPC (Supabase credential
  reused). **Monday-only cadence; FX daily schedule unchanged.**

## 7. Failure isolation
Each market assemble runs in its own sub-block; a failed source records `FAILED` (with error) in
`source_states` and the run continues with the others. States: AVAILABLE / FAILED (extensible to
INSUFFICIENT_EVIDENCE / BLOCKED_EXTERNAL_* / STALE). No substitute evidence is manufactured.

## 8–9. Delivery safety + Product × Country presentation
TEST must satisfy all canonical hard gates; **WATCH is delivered as an emerging opportunity with its
blockers**; **AVOID is retained in history but not promoted**; WINNER is never emitted pre-performance.
Every market metric in the Monday payload is Product × Country scoped (product, country, confidence,
score, buyer intent/demand, saturation, competitor density, local price, supplier match class, stock,
landed economics, advertising headroom, opportunity sweet spot, primary platform, execution readiness,
decision).

## 10. Manual scheduled-path verification
Executed the **schedule trigger path** manually — n8n execution **`30129`**, status **success** — which
fired the "Every Monday 07:00 UTC" trigger → RPC → full chain → Monday payload (`trigger_source:
scheduled`, run_id logged), without waiting for a calendar Monday and without any ad activation or spend.
The test being manually triggered is recorded honestly.

## Real-source result (unchanged pipeline, now identity-gated)
Candidate "kids nightlight projector" (tenant 7c8ddf9d), 4 real markets. Supplier match **CLOSE_COMPARABLE**
→ economics uncertified. All four markets **WATCH** (economics UNKNOWN, stock UNKNOWN, compliance
unverified, fulfilment unconfirmed); saturation market-isolated **FR MODERATE / DE HIGH / US·GB
VERY_HIGH**; product_confidence **LOW**; no real ad-platform evidence → platform UNKNOWN. Best market
**FR**, product-level **WATCH**. Not weakened to TEST.

## 11–13. Regression
12/12 closeout assertions PASS (identity CLOSE_COMPARABLE not EXACT; economics all UNKNOWN/uncertified;
no real market TEST; reference economics separate; risk flag present; competitors CLOSE_COMPARABLE;
FR MODERATE vs US VERY_HIGH isolation; no WINNER; campaign_target_market null; scheduled run logged;
WATCH delivered / 0 AVOID promoted; 17 fixture pod rows intact). Fixture engine suites (44 base + 24
founder-gate) untouched. The prior unit's "GB certified AVOID" assertion is intentionally **superseded**
— GB is now correctly WATCH because a comparable supplier cannot certify economics.

## 14. External blockers
`BLOCKED_EXTERNAL_GOOGLE_ADS_API` · `INSUFFICIENT_EXTERNAL_TIKTOK_INTELLIGENCE` ·
`DEFERRED_POST_LAUNCH_BUDGET` (BigBuy) · `DEFERRED_NON_BLOCKING` (AliExpress). None blocked the path.

## 15. Naturally scheduled Monday status
**AWAITING_FIRST_SCHEDULED_RUN** — the orchestrator is active and armed for the next Monday 07:00 UTC;
the scheduled path itself is already proven (execution 30129).

## Safety / invariants
No final founder acceptance, no store/page/ads/campaign, no Meta activation, no spend, Monday-only
cadence (FX daily unchanged), no fabricated evidence, no gates weakened. `campaign_activation = FALSE`;
`advertising_spend = 0`. Overall paid-beta engineering readiness ≈ **84%** (unchanged).

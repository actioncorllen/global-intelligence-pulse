# PULSE — PRODUCTION SCAN & COST-CONTROL POLICY (founder-approved)

**Status: ACKNOWLEDGED & IN FORCE.** This records the founder's production-scan cost-control policy and the
acceptance check performed against live n8n state. It governs all subsequent build/test units.

## Policy (founder-approved)
- **PRODUCTION market/intelligence scans = MONDAY ONLY.** Covers: product/market opportunity discovery,
  trend, competitor, competitor-product, advertising, supplier catalogue/opportunity, keyword/demand,
  social/community, marketplace, and Product×Country opportunity scanning.
- **Do NOT** (without explicit founder approval): create daily/hourly/continuous scans, increase an existing
  scan frequency, activate additional recurring intelligence workflows, or change Monday schedules.
- **CURRENT BUILD/TEST scans = MANUAL ONLY.** Claude may run the bounded manual tests a unit requires; a
  successful manual test must **not** become scheduled or activated as production.
- **Reuse the existing Monday orchestration** (`BBxcPXJdF2PliWgf`) rather than creating separate recurring
  scanners. Preferred pattern: Monday scan → opportunities → evidence → decisions.
- **Non-scan operations are exempt** (event-driven, not recurring market scans): user-triggered actions,
  approved webhooks, auth, campaign-safety controls, conversion/purchase/event tracking, emergency ad-pause,
  approved operational callbacks. The **FX rate refresh** (`np2MUp83gaZ3C2pJ`, daily 06:00 UTC) is an
  explicitly approved infrastructure exception and stays as-is.
- **CJ sourcing** during the build is **manual test/validation** — do not create a recurring CJ sourcing
  scanner. Future production: Monday scan → supplier discovery → (if a differentiated opportunity has no
  viable supplier) sourcing recommendation → founder/user review → sourcing request. A sourcing request must
  not trigger continuous catalogue polling.
- **BigBuy** = DEFERRED_MONTH_END / PLANNED supplier #2; when integrated it inherits the **same Monday-only**
  policy (no separate daily/continuous BigBuy scanner). Architecture supports more providers without
  multiplying recurring scans.
- **Do not silently repair founder-approved schedules unless actually defective.** Any unauthorized
  production schedule change = FAIL.

## Acceptance check — this session's build/test units (verified live)
Live n8n audit (search_workflows, 2026-09-11):

1. **Schedules inspected:** YES — 30 Pulse workflows enumerated.
2. **New recurring schedules created:** **NO.**
3. **Existing production cadence changed:** **NO.**
4. **Manual test executions performed:** YES — all manual-trigger, bounded to each unit's scope. Workflows
   used (all `active:false`, `triggerCount:0` — manual only, never activated): CJ Supplier Collector
   (`NvuwUfW7fyjSb81R`), CJ Detail+Stock+Freight (`OxH9sb6jKCqiqXOk`), CJ Enrichment/Sourcing Probe
   (`ZbhPyAuvDD4h4xid`), eBay Browse (`ZN6huMtz3DNIMnks`), DataForSEO (`0HGniWXeacHbVTQL`), Reddit collector
   (`0aXO9OmUfRXhI5s2`). Only node parameters/queries were edited; executions were manual.
5. **API/query counts:** reported per unit (eBay Browse, CJ product/list + product/query + stock + freight +
   getCategory + sourcing/query, DataForSEO, Reddit, Supabase). No batch/continuous polling.
6. **Estimated/actual test cost:** ≈ €0 infrastructure; only paid provider was DataForSEO (~$0.10 dash-cam
   buyer-intent + ~$0.10 mini-projector buyer-intent); CJ points well within free daily quota
   (~3,010/50,000 used on the heaviest day); eBay/Reddit free.
7. **Monday-only production policy preserved:** **YES.**
   - `Pulse — Monday Ecom Product Opportunity Orchestrator` (`BBxcPXJdF2PliWgf`): weekly Monday 07:00 UTC,
     `active:true` — **untouched** (updated 2026-09-10, before this session).
   - `Pulse — FX Rate Refresher` (`np2MUp83gaZ3C2pJ`): daily 06:00 UTC exception, `active:true` —
     **untouched**.

**Unauthorized production schedule change: NONE → PASS (not a FAIL).**

## Observation for founder (flagged, NOT changed)
Pre-existing platform workflows that predate this build arc still run sub-weekly and were **not** created or
modified by Claude: `Agent 1 GLOBAL: Trend Collector` (hourly), `Agents 2+3 GLOBAL: Analyzer + Opportunity
Finder`, and various webhook/growth workers. If the Monday-only policy is intended to fold these into the
Monday cadence, that is a **founder-approved schedule change** — flagged here for a decision rather than
altered silently (per the "do not silently repair" rule).

## Standing rule for future units
Every subsequent build/test unit report ends with the 7-point acceptance check above.
`PRODUCTION SCANS = MONDAY ONLY · CURRENT BUILD/TEST = MANUAL ONLY · FREQUENCY INCREASE = EXPLICIT FOUNDER
APPROVAL ONLY.`

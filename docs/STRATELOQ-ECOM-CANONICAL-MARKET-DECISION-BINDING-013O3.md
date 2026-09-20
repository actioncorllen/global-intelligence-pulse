# STRATELOQ-ECOM-CANONICAL-MARKET-DECISION-BINDING-013O3

**FINAL VERDICT: `BACKEND_CONTRACT_FIXED_LOVABLE_CONNECTION_REQUIRED`.**

The Product Decision card showed a stale, market-agnostic `75.5 / 0.70 / STRONG_TEST / LOW`
for every market because **both read RPCs sourced the numeric decision fields from the
discovery-era `product_opportunity_decisions` snapshot (frozen 09-14), never from the current
canonical per-market evaluation (`product_market_evaluations`)**. The research recompute path
updates PME but never refreshes the decision snapshot, so PME diverged (GB 68.2, DE 73.2) while
the snapshot stayed at 75.5. Fixed additively at the read layer: both RPCs now overlay the
current canonical PME per `(product_id, country_code)`. History preserved (the snapshot is
untouched). The frontend already binds the right field names, so it will now show correct
per-market values; one small Lovable connection makes the in-card selector re-scope the card
headline to the selected market.

Migration: `mig_253_canonical_decision_display_binding.sql`.

---

1. **Current canonical GB evaluation** — `product_market_evaluations` (row `75d33991`):
   opportunity_score **68.2**, coverage **0.78**, evidence_confidence **HIGH**, decision **WATCH**,
   band **TRENDING_WATCH** (68.2 < 70), score_version `pm_score_v1`, evaluated 2026-09-20 08:20.

2. **Current canonical DE evaluation** — `product_market_evaluations` (row `c2ca7860`):
   opportunity_score **73.2**, coverage **0.78**, evidence_confidence **HIGH**, decision **WATCH**,
   band **STRONG_TEST** (70 ≤ 73.2 < 80), score_version `pm_score_v1`, evaluated 2026-09-19 22:35.

3. **Origin of displayed 75.5** — the `product_opportunity_decisions` snapshot rows
   (`product_opportunity_score = 75.5`), written by the discovery evaluator `fn_pod_evaluate`
   on 2026-09-14 for all four markets (GB/DE/FR/US). 75.5 is genuinely the *current* canonical
   value for **FR and US** (their PME is still the 09-14 evaluation, coverage 0.41, LOW), but it
   is **stale for GB (now 68.2) and DE (now 73.2)**. Both RPCs read `d.product_opportunity_score`,
   so GB/DE displayed the frozen 75.5.

4. **Origin/meaning of displayed 0.7** — `product_opportunity_decisions.coverage = 0.70`, the
   **evidence-coverage** fraction captured at discovery (09-14). It is the same *metric* as the
   canonical `product_market_evaluations.coverage` (0.78 for GB/DE today) — not a different
   concept, just a stale copy. See §Phase 7 below.

5. **Was the backend contract stale? YES.** `fn_ecommerce_workspace_intelligence()` and
   `fn_ecommerce_research_coverage()` both read opportunity_score / coverage / evidence_confidence /
   band from `product_opportunity_decisions` (frozen), never joining the current PME. Only
   `fn_pod_evaluate` (discovery) writes that table; the research recompute path
   (`fn_finalize_research_run → fn_assemble_real_product_market → fn_evaluate_product_market`)
   writes `product_market_evaluations` **only**. Confirmed by function inspection.

6. **Was the frontend binding stale? NO.** Lovable correctly reads `opportunity_score`,
   `coverage`, `evidence_confidence`, `opportunity_band`, `decision`, `country_code` from the RPC.
   It bound the right field names to the wrong (stale) source. With the backend fixed it now
   renders canonical per-market values with no field-name change.

7. **Authoritative Product Decision display source** — `product_market_evaluations` (the canonical
   WPS V2 per-market evaluation, keyed `tenant_id, product_id, country_code, score_version`,
   updated in place by the research finalize path). Exposed through the two existing RPCs, which
   now overlay it. `product_opportunity_decisions` remains the source of decision *context*
   (reasons, lifecycle, action gating, saturation/headroom/sweet-spot), not the numbers.

8. **Backend correction applied** (`mig_253`): additive read-contract fix — no recompute, no
   number copying, no history rewrite, no WPS change.
   - New immutable helper `fn_ecommerce_opportunity_band(numeric)` reproducing the system's own
     score→band ladder verbatim from `fn_pod_evaluate` (`<40 AVOID, <55 WATCH, <70 TRENDING_WATCH,
     <80 STRONG_TEST, <90 HIGH_CONFIDENCE_TEST, else EXCEPTIONAL`).
   - `fn_ecommerce_research_coverage()` and `fn_ecommerce_workspace_intelligence()` each add a
     `LEFT JOIN LATERAL` to the most-recent non-fixture PME for `(product_id, country_code)` and
     source `opportunity_score`, `coverage`, `evidence_confidence`, `decision`, `opportunity_band`
     (derived from the current score), plus new `evaluated_at`, `score_version`, `evaluation_source`
     fields — falling back (`coalesce`) to the decision snapshot only when a market has no PME row.
     The LATERAL (`ORDER BY evaluation_ts DESC LIMIT 1`) guarantees no row multiplication.

9. **Exact Lovable correction (connection required, handoff — not edited here):** the Product
   Decision card must let the in-card market selector re-scope the card headline. Per selected
   market, bind the card's headline from the `product_decisions[]` entry whose `country_code`
   equals the selected market (fallback: the card's own `country_code`):
   | Card field | Old source | New canonical source (same RPC, now per-market) |
   |---|---|---|
   | Opportunity score | `product_decisions[].opportunity_score` (one row) | `product_decisions[]` where `country_code == selectedMarket` → `opportunity_score` |
   | Coverage | same | matching row `.coverage` (relabel as "Evidence coverage", §Phase 7) |
   | Evidence confidence | same | matching row `.evidence_confidence` |
   | Band | same | matching row `.opportunity_band` |
   | Decision | same | matching row `.decision` |
   | Evaluated at / version | (absent) | matching row `.evaluated_at` / `.score_version` (new) |
   **Selection rule:** `product_id` + selected `country_code`; when the founder has not selected a
   market, use the card's own `country_code`. `fn_ecommerce_research_coverage()` (already fetched
   per selected market by the Deep-Research panel) now carries the identical canonical fields, so
   it is an equivalent binding source if preferred. No number is ever computed in Lovable.

10. **Product+market isolation proof** — live post-fix, same product `e453eed4`:
    | Market | score | coverage | confidence | band | source |
    |---|---|---|---|---|---|
    | GB | 68.2 | 0.78 | HIGH | TRENDING_WATCH | product_market_evaluations |
    | DE | 73.2 | 0.78 | HIGH | STRONG_TEST | product_market_evaluations |
    | FR | 75.5 | 0.41 | LOW | STRONG_TEST | product_market_evaluations |
    | US | 75.5 | 0.41 | LOW | STRONG_TEST | product_market_evaluations |
    GB and DE now return their own current market-specific values (identical numbers no longer
    shown); both RPCs agree. `product_decision_count` unchanged at **7** (no multiplication).

11. **No historical data destroyed** — `product_opportunity_decisions` GB/DE rows still read
    `75.5 / 0.70 / LOW / STRONG_TEST @ 09-14`, byte-unchanged. No decision deleted or rewritten;
    the fix is a live read-time overlay. FR/US decisions untouched. Research runs, PME snapshots
    and provenance preserved.

12. **Regression / security** — relevance ✓, orchestrator/013N auto-dispatch ✓, deep-research/013I ✓,
    ecommerce contracts/013E ✓, workspace connection/013A ✓ (decisions still 7), storefront runtime
    ✓ + lifecycle ✓, paid-access/entitlement ✓ — all `all_pass`. Advisors **0 ERROR** (unchanged
    set). GB & DE evidence unchanged (142 product signals intact); business country **GB** unchanged;
    product identity unchanged; TikTok registry still `SOURCE_UNSUPPORTED` (pending). No paid provider
    call, no force-fresh, no dispatch initiated by this unit; no synthetic evidence; no manual score
    patching (numbers come live from the canonical table).

13. **Files / functions / migrations changed** — `mig_253_canonical_decision_display_binding.sql`:
    new `fn_ecommerce_opportunity_band(numeric)`; `fn_ecommerce_research_coverage()` and
    `fn_ecommerce_workspace_intelligence()` re-sourced from canonical PME. No frontend edit made in
    this unit (handoff only). No WPS/scoring, cadence, provider, country, or business-country change.

14. **Commit hash** — see delivery message.

15. **Push / divergence** — branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

**Phase 7 — coverage semantics:** the card's "Coverage 0.78" is the **evidence-coverage fraction**
of the canonical market evaluation (`product_market_evaluations.coverage`) — how much of the WPS
evidence set is present. It is a distinct concept from the Deep-Research **per-source status list**
(`sources[]` / `research_status`), which is not a 0–1 number. They are not shown under an identical
label today ("Coverage" number vs the "Deep Research" source list), but to remove any ambiguity the
Lovable handoff recommends labeling the number **"Evidence coverage"**. The metric is truthful and
retained (now canonical 0.78, not the stale 0.70).

**STOP. No publish. Backend canonical binding fixed; Lovable headline-to-selected-market connection handed off.**

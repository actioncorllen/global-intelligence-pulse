# PULSE-ECOM-STAGE4A-DFS-PROBE-001

**Free DataForSEO account probe — live, verified, then removed. One temporary read-only n8n workflow
("Pulse - DFS Account Probe (TEMP, free)", `TqB8SY6Bxb8hO8zw`) called ONLY the free
`GET /v3/appendix/user_data` endpoint with the existing `Pulse DataForSEO` credential, shaped out the
login/secrets, and was ARCHIVED immediately after. No paid research call, no production workflow touched.
The probe call itself cost $0.00 (confirmed). Headline: the planned Snowman run's two DataForSEO tasks
cost a verified ≈ $0.10 total; balance is healthy; but there is still NO USD ceiling on the 013N path —
the smallest safe fix is a fail-closed pre-dispatch reserve in `fn_research_dispatch`.**

## 1. Account balance & call cost — VERIFIED
- **Available balance: $47.31** (`money.balance` = 47.31144) of **$51.00 total** (`money.total` = 51).
- **This probe call cost: $0.00** (`cost` = 0, `status_code` 20000 "Ok.") — confirms `appendix/user_data`
  is a free endpoint and no balance was consumed.
- At ≈ $0.10 per Snowman run, the balance covers ~460 such runs — no balance risk for the single test.

## 2. Exact per-task charges — VERIFIED (from the account's own price map)
| Executor node | Endpoint | Account price (live) | Charge for this run |
|---|---|---|---|
| **DFS Search Volume** | `keywords_data/google_ads/search_volume/live` | **$0.09 per live call** (flat — single cost leaf `…search_volume.live.*.0.cost = 0.09`, no per-keyword add-on) | **$0.09** |
| **DFS Search Intent** | `dataforseo_labs/google/search_intent/live` | base/min **$0.012** + **$0.00012 per keyword** (`…search_intent.live.*.1.cost = 0.012`, `….0.cost = 0.00012`) | **$0.012** (~3 seeds → 3×$0.00012 = $0.00036, under the $0.012 minimum, so the $0.012 minimum applies) |

**These are the account's current contracted rates (read live 2026-10-20), not documented estimates.**
Note the Google-Ads search-volume live price is **$0.09**, higher than the earlier documented guess of
$0.05 — the probe corrected this.

## 3. Maximum possible charge for the planned tasks — CONFIRMED
- **search_volume/live:** $0.09 flat per call (no per-keyword scaling) → max **$0.09**.
- **search_intent/live:** $0.012 minimum + $0.00012/keyword; the executor sends the run's ~3 seeds in ONE
  task, so max **$0.012** (and even at 100 keywords it is only ~$0.012–$0.024).
- **Maximum per Snowman run ≈ $0.102 (~$0.10); worst-case under any seed variation < $0.15.**
- **Uncertainty (bounded):** the only soft spot is the Labs index-0/index-1 (per-item vs minimum)
  reading; under the most pessimistic interpretation the search-intent call is still ≤ ~$0.04, so the
  run total is bounded ≤ ~$0.13. The Google-Ads $0.09 is unambiguous and flat.

## 4. How the ≈ $0.10 is (and is not) enforced
- **Enforced structurally (PASS):** the 013N executor fires the DataForSEO branch exactly once —
  `DFS Search Volume` (1) → `DFS Search Intent` (1), no loop/pagination, no `retryOnFail`,
  `neverError:true`, webhook `responseMode:onReceived` (the `pg_net` caller does not retry). One run per
  product+market (advisory xact-lock + 7-day freshness reuse + 1-hour in-flight dedup). So the charge
  **cannot exceed the two tasks ≈ $0.10**.
- **NOT enforced by any dollar ceiling (GAP, unchanged from the preflight):** `provider_call_budget` is
  call-count only; DataForSEO is not in the metered set; and the 013N auto-dispatch path never consults
  the budget. No USD cap governs research spend (the only USD cap in the system is the separate Gemini
  $2/month translation cap, mig_315).

## 5. Minimum safe implementation for a real USD ceiling on 013N (REPORT ONLY — not built)
Goal: a true monthly dollar ceiling that fails closed **before** any DataForSEO call, with the smallest
change and **no edit to the 013N executor**. Smallest safe design (mirrors the proven mig_315 pattern):

1. **New table `research_spend_month`** (month, spent_micro, reserved_micro, cap_micro), service-role
   only, RLS on — identical shape to `translation_budget_month`.
2. **Known per-run cost constant:** DataForSEO is the only paid provider and its cost is now verified and
   fixed per run = **$0.09 + $0.012 = $0.102** (only when the manifest's `DATAFORSEO` action = `DISPATCH`).
3. **A ~15-line fail-closed reserve inside the EXISTING `fn_research_dispatch`**, immediately before the
   `net.http_post` that fires the webhook:
   - compute expected DataForSEO cost for this run (the constant above, else $0 if DataForSEO is not
     dispatching),
   - atomic conditional reserve `… WHERE spent_micro + reserved_micro + cost <= cap_micro`,
   - on failure return `BUDGET_EXCEEDED` and **do NOT POST the webhook** (no paid call happens),
   - on success proceed to `net.http_post`.
4. **(Optional) reconcile** in `fn_research_ingest_source` for DATAFORSEO using the real per-task prices;
   since the executor cost is fixed and now known, the pre-dispatch reserve alone is already a safe
   ceiling, so reconcile is a refinement, not a requirement.

Why this is the minimum: one new table + a short guard in ONE already-existing SQL function; the n8n
executor, credentials, and all other providers are untouched; and because the guard sits before the
single webhook POST, a breach stops spend at $0. A `provider_call_budget` row would NOT work here (013N
never reads it). **Recommended before the Snowman run:** implement this with a small cap (e.g.
$0.50–$1.00/month) so even a defect cannot exceed the cap; then dispatch the single run (reserve $0.102
fits comfortably). This is described for approval and has NOT been implemented.

## 6. Preservation — PASS
Probe was read-only (one free GET), login/secrets never surfaced (shaped out server-side), probe archived
after use, no production workflow modified, no paid research call. Tenant/country isolation, source
evidence and Product Asset Lock untouched.

## Status
| Req | Result |
|---|---|
| 1 — free `appendix/user_data` only | **PASS** — one temp probe, $0.00, archived after |
| 2 — read balance & pricing w/o exposing secrets | **PASS** — balance $47.31; prices verified; login/secrets redacted |
| 3 — max charge for the two planned tasks | **PASS** — $0.09 + $0.012 ≈ **$0.10** (worst-case < $0.15) |
| 4 — remove the probe; don't touch production | **PASS** — archived; no production workflow touched |
| 5 — precise pricing + uncertainty | **PASS** — reported; only bounded Labs index uncertainty |
| + minimum safe USD-ceiling implementation | **Reported** (fail-closed reserve in `fn_research_dispatch`; not built) |

**Overall: PASS. Verified max cost ≈ $0.10/run, balance $47.31, no USD ceiling yet (smallest safe fix
specified).**

**STOP — probe + report only.** No product research dispatched, no paid provider called, no production
workflow modified, Stage 4B not started.

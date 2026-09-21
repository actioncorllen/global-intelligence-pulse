# STRATELOQ-PROBLEM-DISCOVERY-015C.2 — Problem-Shaped Seeds + Reddit Follow-up

**RESULT: DataForSEO problem discovery `LIVE_VERIFIED`; Reddit `BLOCKED_ON_CREDENTIAL`.**

The 015C.1 DataForSEO gap (0 qualifying problem queries from category `keyword_ideas`) is **fixed**.
Switching to `keyword_suggestions/live` with the problem-shaped verb seed **"store shoes"** returned 180 GB
keywords, of which the unchanged 015C qualifier accepted **2 real problem/solution queries** — creating the
first **real GB problem cluster with traceable DataForSEO evidence** and the correct 015B corroboration
state `MULTI_EVIDENCE_SINGLE_SOURCE`. The Reddit half could **not** be completed: n8n has **no Reddit
credential**, and public JSON is IP-blocked, so authenticated Reddit access must be provisioned by the
founder before Reddit pain evidence (and thus `MULTI_SOURCE_CORROBORATED`) is achievable. No product
matching, no suppliers, no PME/Decision change. All six regressions green. Paid cost ≈ **€0.03**.

---

## 1. Run
`commerce_problem_discovery_runs` id **`5cc4b248-a294-40d5-b6e3-651dd0231eb3`** — GB · "shoe storage" ·
seed "store shoes small space no room". n8n workflow **`Pulse — Problem Discovery Fetch v2 (015C.2)`**
(`LhtUctoIOYL2y7TU`), execution `30239`.

## 2. DataForSEO fix (implemented)
- Endpoint changed from `keyword_ideas/live` (category → product terms) to **`keyword_suggestions/live`**
  (phrase-contains) with the **problem-shaped verb seed "store shoes"** + `search_intent/live` for intent.
  The `fn_dataforseo_problem_qualify` / `fn_reddit_pain_classify` contracts were **not changed**.
- **180 keyword suggestions returned; 2 qualified** as problem/solution queries (verified against all 180):
  - **"how to store shoes"** — SOLUTION_SEEKING, intent informational, GB vol 170.
  - **"best way to store shoes"** — SOLUTION_SEEKING, intent commercial, GB vol 140.
  - The other 178 were retail/store-locator/product queries ("shoes store near me", "nike store running
    shoes", "cheap shoes store") → correctly rejected (`no_problem_pattern` / `commercial_product_query`).
- Both qualifying queries attached as `SEARCH_PROBLEM_DEMAND` (product_id NULL, market_scope SELECTED_MARKET,
  raw query + volume + intent preserved) → **SEARCH_DEMAND = SEARCHED_EVIDENCE_FOUND**.

## 3. Reddit (blocked on credential — genuine finding)
n8n has **no Reddit credential** (`list_credentials` type reddit = 0), and `reddit.com/*.json` is blocked
from the n8n datacenter IP (015C.1). Authenticated Reddit access must be provisioned first. Recorded
truthfully as **COMMUNITY = SOURCE_UNAVAILABLE** (not attempted this run; no fabricated failure/evidence).
**Founder action to unblock:** create a Reddit "script" app (reddit.com/prefs/apps), then add an OAuth2
credential in n8n (client id + secret) — do **not** paste secrets into chat. Then a bounded
`oauth.reddit.com/search` fetch (with a descriptive User-Agent) posts real posts to
`fn_ingest_reddit_problem_pain`, enabling `MULTI_SOURCE_CORROBORATED`.

## 4. Problem cluster (real, evidence-backed)
| Field | Value |
|---|---|
| cluster_id | `21792efb-bfa0-4873-ab8a-5accd0b64696` |
| market / category | GB / shoe storage |
| canonical_problem | "how to store shoes / not enough shoe storage space" |
| status | **PROBLEM_DISCOVERED** |
| evidence | 2 × `SEARCH_PROBLEM_DEMAND` (SOLUTION_SEEKING), both DATAFORSEO, SELECTED_MARKET |
| corroboration | **MULTI_EVIDENCE_SINGLE_SOURCE** (2 signals, 1 distinct source) |
| matched_product_id | **NULL** (no product matching) |

Corroboration is correctly **not** advanced to PROBLEM_CORROBORATED (that needs ≥2 independent qualifying
sources; Reddit is unavailable). Not forced.

## 5. Truthfulness / invariants
- No fabricated evidence (only real DataForSEO returns; 2 attached, 178 rejected).
- No supplier evidence (**0** CJ/supplier problem signals).
- No known-product seeding (the over-door shoe organizer was **not** used).
- No cross-market corroboration (GB only).
- No product matching (**0** product links, **0** advanced clusters).
- No PME / Product Decision mutation (nightlight GB still **68.2/0.78/WATCH**).

## 6. Source-attempt states
SEARCH_DEMAND (DATAFORSEO) = **SEARCHED_EVIDENCE_FOUND** (180 returned, 2 qualifying attached); COMMUNITY
(REDDIT) = **SOURCE_UNAVAILABLE** (no credential). Run status COMPLETE.

## 7. Cost
DataForSEO Labs live: **2 requests** (`keyword_suggestions` + `search_intent`) ≈ **€0.03** (within
authorization). Reddit: **0** (not attempted). **Total paid ≈ €0.03.**

## 8. Regressions & advisors
All six green: `fn_problem_foundation_selftest`, `fn_problem_discovery_selftest`, `fn_deep_research_selftest`,
`fn_research_orchestrator_selftest`, `fn_search_relevance_selftest`, `fn_tiktok_executor_selftest`.
No DDL/migration this unit (only an n8n workflow + data rows) → security advisors unchanged:
**0 ERROR, 1 INFO, 4 WARN**.

## 9. Changes
- n8n workflow `Pulse — Problem Discovery Fetch v2 (015C.2)` (`LhtUctoIOYL2y7TU`) — keyword_suggestions +
  search_intent problem-shaped fetch (manual, inactive).
- One `commerce_problem_discovery_runs` row + one `commerce_problem_clusters` row + 2 `commerce_signals`
  (product_id NULL). No migration, no repo code change, no Lovable, no WPS/PME/Decision change.

---

**STOP.** One bounded run performed; no retry, no second category/market, no product matching. DataForSEO
problem discovery is now live-verified end-to-end (first real GB problem cluster + correct 015B
corroboration). Reddit corroboration awaits a founder-provisioned Reddit OAuth credential. 015D not started;
Lovable untouched.

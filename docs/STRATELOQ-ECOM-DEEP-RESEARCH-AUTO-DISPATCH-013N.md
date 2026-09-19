# STRATELOQ-ECOM-DEEP-RESEARCH-AUTO-DISPATCH-013N

**FINAL VERDICT: `DEEP_RESEARCH_AUTO_DISPATCH_READY`.**

The final backend connection is closed. A single authenticated request —
`fn_own_request_product_market_research(product_id, market)` — now **automatically
dispatches every applicable authorized provider server-side, with ZERO manual n8n
intervention**, and the run **auto-finalizes** to a market-specific decision when the
providers report back. Proven end-to-end for **kids nightlight projector × DE**: one
request → `pg_net` → the canonical n8n executor → real eBay + Meta + DataForSEO + CJ
(+ cross-market Reddit reuse) → attempt-state ledger → canonical finalize/recompute
(**DE 73.2 / HIGH / WATCH**), with **no workflow repointing by hand**. TikTok stays
`BLOCKED_EXTERNAL_ACCESS` (never called, never faked). Idempotency, failure isolation,
paid-call control, and security all verified. **The Lovable selector is NOT built**
(backend prerequisite only). No Lovable/publish/Stripe/Create-Store change; no new
provider/country; no cadence change; no second orchestrator; no WPS redesign.

Migrations: `mig_251_research_dispatch_manifest.sql`, `mig_252_research_auto_dispatch.sql`.
n8n: one consolidated executor **"Pulse — Research Auto-Dispatch Executor (013N)"**
(`QjYMzrCm1cDXxUS4`, active). Executor URL + dispatch secret live only in
`server_integration_config` (runtime) — never committed.

---

1. **What was missing / what closes it** — the request contract created a run + truthful
   `NOT_SEARCHED` attempts, but nothing fired the providers (the four manual executors
   were triggered/repointed by hand). 013N adds a server-side dispatch plane
   (`fn_research_dispatch` → `pg_net` → one parameterized n8n executor) and server-side
   auto-finalization, so the request is now self-completing.

2. **Browser boundary (unchanged surface)** — the browser sends only `p_product_id` +
   `p_market` (+ optional `p_freshness_hours`). It never calls providers, never receives
   provider credentials or the n8n secret, and never chooses tenant/business identity
   (tenant resolved from `auth.uid()` server-side). Verified by grant: `authenticated`
   can execute **only** the request RPC (+ catalog/coverage) — **not** dispatch, manifest,
   finalize, or the config table.

3. **Provider selection is registry-driven** — applicability is ranked from
   `provider_capability_registry` (market-specific AVAILABLE > global `*` AVAILABLE >
   blocking state), identical to the catalog/orchestrator ranking. No provider list is
   hardcoded in the dispatcher or the browser.

4. **Server dispatch manifest** — `fn_research_run_manifest(run_id)` (service-role only)
   returns everything the executor needs and nothing sensitive: product query, market,
   `EBAY_<market>`, DataForSEO location code, server-derived search seeds, and a per-source
   `action` (`DISPATCH` / `REUSE` / `SKIP_NO_LOCATION` / `TERMINAL`). The browser cannot
   read it.

5. **Dispatcher** — `fn_research_dispatch(run_id)` (service-role): (a) reuses cross-market
   COMMUNITY/Reddit evidence synchronously; (b) marks SEARCH_DEMAND `SOURCE_UNAVAILABLE`
   when the market has no DataForSEO location code (truthful, never a silent skip, keeps the
   run completable); (c) if nothing is dispatchable, finalizes immediately; (d) otherwise
   fires the n8n executor **once** via `net.http_post`, sending `{run_id}` + the
   `x-pulse-secret` header read from `server_integration_config`.

6. **Consolidated executor (n8n `QjYMzrCm1cDXxUS4`, active)** — webhook POST →
   **Verify Secret** (constant-time header check) → **Get Manifest** (service-role Supabase
   RPC) → **Parse Manifest** → four independent, per-source **`action == 'DISPATCH'` gates**,
   each running the canonical provider call (eBay OAuth+Browse, Meta ads_archive, DataForSEO
   volume+intent, CJ auth+list) then posting to `fn_research_ingest_source`. All provider
   nodes use existing bound credentials; nothing is repointed per run. Reddit/finalize are
   server-side, not in the webhook.

7. **Attempt-state model** — `NOT_SEARCHED → SEARCHING → SEARCHED_EVIDENCE_FOUND /
   SEARCHED_NO_EVIDENCE / SOURCE_FAILED`, plus terminal `UNSUPPORTED_MARKET`,
   `SOURCE_UNAVAILABLE`, `BLOCKED_EXTERNAL_ACCESS`. Ingest is hardened: only
   `NOT_SEARCHED / SEARCHING / SOURCE_FAILED` are (re)processed; every terminal state is
   **`REFUSED_TERMINAL_STATE`** (idempotent — a duplicate/late callback never re-ingests or
   overwrites evidence).

8. **Auto-finalization** — `fn_research_maybe_finalize(run_id)` runs after every ingest/reuse
   transition. Once no attempt is `NOT_SEARCHED/SEARCHING`, it calls the **canonical**
   `fn_finalize_research_run` (real assembler recompute → `product_market_evaluations`).
   It is serialized per run with a transaction advisory lock (concurrent callbacks never
   both finalize or both skip) and no-ops on an already-finalized run.

9. **TikTok (truthful, never called)** — registry SOCIAL_VIDEO `SOURCE_UNSUPPORTED`; the
   attempt is `BLOCKED_EXTERNAL_ACCESS`; the manifest marks it `TERMINAL`; the executor has
   no TikTok node. It surfaces in the run as a launch-critical gap. No fabrication, no build
   against unissued credentials.

10. **Critical end-to-end proof (DE, zero manual work)** — force-fresh
    `fn_own_request(...,'DE',0)` → run `63662581` created, `auto_dispatch=DISPATCHED`
    (dispatchable=4), Reddit reused, `pg_net` request fired → executor execution `30203`
    ran **17 s** (real eBay/Meta/DataForSEO/CJ) → all four posted back → run **auto-finalized**
    with MARKETPLACE/ADVERTISING/SEARCH_DEMAND/SUPPLIER/COMMUNITY = `SEARCHED_EVIDENCE_FOUND`,
    SOCIAL_VIDEO = `BLOCKED_EXTERNAL_ACCESS`. **No manual repointing.** DE recompute:
    **73.2 / HIGH / coverage 0.78 / WATCH** (`is_fixture=false`).

11. **Cost — actual** — DataForSEO DE force-fresh proof ≈ **€0.09** (5 seeds × search_volume +
    search_intent, location 2276); eBay/Meta/CJ free; Reddit reused. Within the ≤ €1
    auto-proceed gate.

12. **Idempotency (three modes, all verified)** — (a) DE default-freshness → `CACHE_REUSED`
    (newest completed run, **no dispatch, no paid call**); (b) repeated executor fire → ingest
    `REFUSED_TERMINAL_STATE` (no duplicate ingestion / no duplicate paid DataForSEO); (c)
    in-flight guard (`CACHE_REUSED_IN_FLIGHT`, mig_250) preserved verbatim — with a fresh
    completed run present, completed-cache reuse correctly takes precedence (also
    non-duplicating). Repeated clicks create no duplicate products/runs/jobs/evidence.

13. **Paid-call control** — DataForSEO fires only when the manifest `action == 'DISPATCH'`
    (fresh `NOT_SEARCHED` + location present); the ingest terminal-state guard blocks
    re-ingestion; and a transaction-scoped `pulse.suppress_dispatch` GUC makes regression
    selftests fire **no** live webhook or paid call. (Selftests that pre-dated the guard fired
    against already-deleted runs → manifest `RUN_NOT_FOUND` → all gates false → **no** provider
    calls; net effect zero.)

14. **Failure isolation** — simulated Meta failure (proof rolled back): ADVERTISING →
    `SOURCE_FAILED` ("evidence unchanged, never zeroed"); MARKETPLACE / SEARCH_DEMAND /
    SUPPLIER preserved as `SEARCHED_NO_EVIDENCE`; COMMUNITY preserved as
    `SEARCHED_EVIDENCE_FOUND`; run auto-finalized to **`PARTIAL_SOURCE_FAILURE`**. One
    provider failing never corrupts or zeroes the others.

15. **Cross-market isolation & business country** — GB run `ae239472` intact
    (**68.2 / HIGH / 0.78 / WATCH**, unchanged); DE is an independent run/decision;
    `business_profiles.country = GB` before and after (research market ≠ business country).
    No founder market other than DE was researched.

16. **Security** — anon → `28000`; cross-tenant → `42501`; `server_integration_config` is
    RLS deny-all with no grants (not readable by `anon`/`authenticated`); `fn_research_dispatch`,
    `fn_research_run_manifest`, `fn_research_maybe_finalize` are **service-role only**;
    the executor secret lives only in the config table + n8n and is never returned to any
    caller. Advisors: **0 ERROR**; remaining INFO/WARN are pre-existing by-design categories
    (deny-all config table, the authenticated RPC surface, `pg_net` in public).

17. **Regressions (all pass)** — search relevance **10/10**; research orchestrator **all_pass**
    (now asserts dispatch is suppressed in selftest); deep-research **11/11** (incl.
    `ledger_integrity_no_synthetic`); ecommerce contracts **6/6** (`founder_competitors_real_no_fixtures`);
    workspace connection **10/10** (founder products 12 / signals 11 / decisions 7 intact);
    storefront runtime **38/38**; publish lifecycle **10/10**; paid-access entitlement **17/17**
    (founder COMP active). No synthetic evidence entered any founder decision; no manual
    score/decision patching; production weekly cadence unchanged.

18. **Truthfulness** — DE score moved 69.2 → **73.2** solely because Meta advertising evidence
    was genuinely found on this real run (previously no product match); it is a real recompute
    via the canonical assembler, not a patch. All ledger states reflect real provider outcomes.

19. **Files / functions / migrations / workflows** —
    - `mig_251_research_dispatch_manifest.sql`: `server_integration_config` (deny-all),
      `ecommerce_market_universe.dataforseo_location_code`, `fn_research_run_manifest`.
    - `mig_252_research_auto_dispatch.sql`: `fn_research_maybe_finalize`; hardened
      `fn_research_ingest_source` (terminal-state guard + auto-finalize); `fn_research_reuse_source`
      (auto-finalize + terminal guard); `fn_research_dispatch` (Reddit reuse + no-location
      handling + `pg_net` fire + `pulse.suppress_dispatch` guard); `fn_own_request_product_market_research`
      (auto-dispatch on new run only); `fn_research_orchestrator_selftest` (suppression-aware).
    - n8n workflow `QjYMzrCm1cDXxUS4` (24 nodes, active); existing credentials reused
      (Supabase service-role, eBay, Meta, DataForSEO, CJ). Executor URL + secret inserted into
      `server_integration_config` at runtime (not committed).

20. **Lovable RPC contract for the next unit** (read-only spec; **not built here**):
    - **A — list / search markets:** `supabase.rpc('fn_ecommerce_supported_markets')` →
      `{ status, count, markets:[{ country_code, country_name, currency_code, research_supported,
      available_source_count, launch_critical_blocked, provider_coverage:[{evidence_category, source, state}] }] }`.
      TikTok appears as `BLOCKED_EXTERNAL_APPROVAL`, never AVAILABLE.
    - **B — request research (auto-dispatches server-side):**
      `supabase.rpc('fn_own_request_product_market_research', { p_product_id, p_market })`
      → `{ status: RESEARCHING | CACHE_REUSED | CACHE_REUSED_IN_FLIGHT | UNSUPPORTED_MARKET | PRODUCT_NOT_FOUND,
      run_id, market, market_currency, sources_expected, dispatch_manifest[], auto_dispatch, tiktok }`.
      Only `p_product_id` + `p_market` (+ optional `p_freshness_hours`); **no tenant/business id, no
      provider/secret from the browser**. `RESEARCHING` means providers were auto-dispatched — no
      further browser action needed.
    - **C — poll status:** `supabase.rpc('fn_ecommerce_research_coverage')` → filter rows by
      `product_id` + `market`; render from `research_status` + `launch_critical_gap` + per-source
      coverage: Researching / Deep research complete / Partial — provider unavailable / Partial —
      provider failure / Insufficient evidence.
    - **D — render decision:** read `product_market_evaluations` / `product_opportunity_decisions`
      for (`product_id`, `country_code`): `market_opportunity_score`, `opportunity_band`,
      `evidence_confidence`, `coverage`, `market_decision`, `decision_reasons`, `risk_flags` —
      opportunity score kept separate from research completeness (a high score never implies
      complete research).

**Commit / push:** branch `claude/pulse-crash-recovery-b6ngey` (see delivery message; divergence 0/0).

**STOP. Backend auto-dispatch connection closed and proven. Lovable selector NOT started.**

# PULSE-ECOM-STAGE2-CJ-BOUNDED-PAGINATION-001

**Stage-2 CJ bounded pagination (`mig_302`). Deterministic DB contract for budgeting, per-page stop
decisions, cross-page dedup by CJ product id, and safe API-error handling; the n8n workflow drives the
bounded HTTP loop. PASS (pagination 10/10; B3 10/10, multilingual 8/8, Stage-2 boundary 10/10 — no
regression). No live CJ calls; $0.00.**

## Retrieval limits — before vs after
- **Before:** `stage2-cj-supplier-search` fetched a single page, `pageNum=1 & pageSize=20`, for one
  hand-supplied `search_query`. An exact product ranked beyond the top 20 was invisible.
- **After:** per canonical-expanded query, page from 1 up to `max_pages_per_query`, dedup across pages
  and queries by CJ `pid`, bounded by an explicit budget. `pageSize` stays 20 (CJ default) — only DEPTH
  is added.

**Budget (`fn_stage2_cj_budget`):** `page_size=20`, `max_pages_per_query=5` (≤100 results/query),
`max_candidates=200`, `max_api_calls=40`.

## DB contract (deployed + self-tested; the orchestrator drives the loop)
- `fn_stage2_cj_budget()` — the request budget.
- `fn_stage2_cj_should_continue(page, page_num, collected, budget)` — per-page stop decision: stop on
  error (`http>=400`), rate-limit (`429`), provider error (`5xx`), malformed page (no `data.list`), a
  partial/last page (`rows < page_size`), `max_pages_per_query`, or the candidate budget; else continue.
- `fn_stage2_cj_finalize_candidates(pages[], budget)` — flatten all collected pages, **dedup by CJ pid**
  (first wins), cap at `max_candidates` (flag `truncated`), skip + record error pages
  (RATE_LIMITED / PROVIDER_ERROR / CLIENT_ERROR / MALFORMED) without aborting, and emit candidates in the
  exact shape `fn_resolve_concrete_supplier_identity` consumes, plus retrieval stats.
- `fn_stage2_cj_retrieval_plan(tenant, product, market)` — canonical query set (mig_300/301) + budget
  (+ `language_coverage_gap` from mig_301). Tenant-isolated.
- `fn_stage2_resolve_from_pages(tenant, product, market, pages[], persist)` — finalize → resolve in one
  RPC; returns the resolver verdict + `retrieval_stats`. Tenant isolation inherited from the resolver.

## n8n workflow
The live workflow is the source of truth; the paginated rebuild is specified authoritatively in
`dr/n8n/nnoDjxtEeTqwC6q6_stage2-cj-supplier-search.json → pagination_upgrade` (replace single `CJ Search` /
`Build Candidates` / `Resolve Identity` with `Get Retrieval Plan` → `Paginate CJ` loop (per page calls
`fn_stage2_cj_should_continue`) → `Resolve From Pages`; idempotency claim/complete, header auth, and
tenant/ownership nodes unchanged). The live rebuild is founder-gated (needs activation + live CJ) and was
**not** performed here.

## Verification (no CJ calls; $0.00; no writes)
- **`fn_stage2_cj_pagination_selftest()` → 10/10**: full page → continue; partial/last page → stop;
  rate-limit (429) → stop + error + rate_limited; provider 5xx → stop + error; empty page → stop, not an
  error; `max_pages_per_query` → stop; finalize dedup across pages (`candidate_count=6`,
  `duplicates_removed=1`, `pages_error=2`, matches `p4`/`p6` recovered beyond page 1); candidate-cap
  truncation; resolver-compatible candidate shape; malformed page (no `data.list`) → error, no crash.
- **End-to-end demonstration (mocked pages, `persist=false`, no write):** for the real Krippen product,
  a genuine `"LED Lighted Nativity Scene Wall Decoration…"` present **only on page 2** →
  `EXACT_SUPPLIER_IDENTITY_RESOLVED`, `bound=true`, `qualifying_count=1`, `retrieval_stats`
  pages_total 2 / candidate_count 3 / errors 0. (Mocked demonstration of the full chain — not a live CJ
  result or a production bind.)
- **No regression:** `fn_stage2_query_expansion_selftest` 10/10, `fn_stage2_multilingual_selftest` 8/8,
  `fn_stage2g_boundary_integrity_selftest` 10/10.

## Preserved
Canonical query expansion (mig_300); multilingual recognition (mig_301); exact-product matching
strictness + form-conflict (`fn_market_supplier_match` unchanged); tenant isolation; country isolation;
Product Asset Lock. `pageSize` unchanged (only depth added). No live CJ/Apify; no new paid service.

## Remaining blockers
- CJ's own ranking/relevance still governs which products appear within the (now deeper) window; the
  budget bounds cost.

## Follow-up: live rebuild + revalidation DONE (2026-10-14)
The n8n paginated loop was integrated and a single controlled live Krippen revalidation was run
under the approved budget. Two in-budget execution defects were found and fixed (no budget
increase): **(1)** CJ rate-limiting degraded recall → added call pacing + single transient-throttle
retry; **(2)** broad queries exhausted the candidate budget before the specific queries ran → the
loop is now **breadth-first (round-robin)** (page 1 of every canonical query before any depth). Final
live run: 11/11 pages HTTP 200, all 8 canonical queries examined, 158 unique candidates,
**trustworthy `NO_VALID_CJ_MATCH`** (0 exact; 42 similar/attribute-subset), `persist=false`, no bind.
Full detail: `docs/PULSE-ECOM-STAGE2-LIVE-KRIPPEN-CJ-REVALIDATION-001.md`.

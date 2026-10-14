# PULSE-ECOM-STAGE2-LIVE-KRIPPEN-CJ-REVALIDATION-001

**One controlled live CJ revalidation of the existing Krippen product (DE), using the deployed
Stage-2 production workflow, existing CJ credentials, and the approved API budget. Two in-budget
internal execution defects were found, fixed, re-tested and revalidated — the budget was never
increased. Final result: trustworthy `NO_VALID_CJ_MATCH` (no exact supplier identity; several
similar / attribute-subset products only). No supplier bind, no store change, no publishing, no
paid actions.**

- Product: Krippen — `5bc29d0a-b8e0-4fa9-bb80-d77197d770c4`
- Tenant: `7c8ddf9d-172c-4a89-a402-bb7066228b61` · Market: **DE** · `persist=false` (evaluate-only)
- Workflow: `nnoDjxtEeTqwC6q6` (Pulse — Stage-2 CJ Supplier Search), active throughout.
- Concrete identity under test (canonical, cross-language): **NATIVITY_SCENE + ILLUMINATED +
  FORM:WALL_DECORATION** (`beleuchtete krippen wanddekoration`).

## Live CJ connection — PASS
CJ `getAccessToken` + `product/list` succeeded against the real CJ API via the existing credential
(`httpCustomAuth` id `2IV5tXPu9jAItjKh`). Final run: **11/11 pages HTTP 200, zero errors**.

## Budget (unchanged throughout — `fn_stage2_cj_budget`)
`page_size=20`, `max_pages_per_query=5`, `max_candidates=200`, `max_api_calls=40`. The fixes below
reallocate and pace calls **within** this budget; none of these numbers was changed.

## What the live runs showed

| Run | Change under test | API calls | Pages OK / err | Unique candidates | Verdict | Trustworthy? |
|-----|-------------------|-----------|----------------|-------------------|---------|--------------|
| 30481 | baseline (single-attempt, no pacing) | 15 | 8 / 7 | 118 | NO_VALID_CJ_MATCH | **No** — 7 pages throttled |
| 30483 | + pacing + retry | 10 | 10 / 0 | 200 | NO_VALID_CJ_MATCH | **No** — broad queries ate the budget |
| 30485 | + breadth-first allocation | 11 | 11 / 0 | 158 | **NO_VALID_CJ_MATCH** | **Yes** |

### Defect 1 — CJ rate-limiting degraded recall (found in 30481, fixed)
The `Paginate CJ` loop fired `product/list` calls with no inter-call delay. CJ enforces ~1
request/second per token, so 7 of 15 calls were **thrown** (`http_status 0`, empty body) — the
`manger scene` query got zero pages and five queries were cut short. The `NO_VALID_CJ_MATCH` there
reflected lost recall, not absence.
**Fix (in-budget):** pace live calls (~1.3 s between) and retry a transient throttle once
(`429` / `5xx` / thrown / CJ body-level throttle message) after a longer backoff. Retries draw from
the same `max_api_calls=40`.

### Defect 2 — broad queries starved the specific queries (found in 30483, fixed)
After pacing, 30483 was throttle-free but the two broadest queries (`nativity scene`, `nativity
set`) returned 5 full pages each and hit the 200-candidate cap **before** the most on-target queries
(`nativity scene wall decoration`, `led nativity scene wall decoration`) ever ran — so absence was
still not trustworthy.
**Fix (in-budget):** the loop is now **breadth-first (round-robin)** — it fetches page 1 of *every*
canonical query before any query goes deeper, so a broad query can no longer starve the
distinguishing-attribute queries. This is budget **allocation only**.

## Final run 30485 — queries & pages searched (trustworthy)
8 canonical multilingual-expanded queries (from `fn_stage2_cj_retrieval_plan`, mig_300/301), each
examined at **page 1**, then depth on the broadest until the candidate budget stopped the run:

- `nativity scene` — p1, p2 (20, 20)
- `nativity set` — p1, p2 (20, 20)
- `christmas crib` — p1, p2 (20, 20)
- `creche` — p1 (1 — CJ's only result for that exact phrase: a *Wooden Easter Creche*)
- `manger scene` — p1 (20)
- `nativity scene wall decoration` — p1 (20)
- `led nativity scene` — p1 (20)
- `led nativity scene wall decoration` — p1 (20)

11 pages, **201 rows seen → 158 unique** (43 duplicates removed), `truncated=false`, 0 error pages.

## Products retrieved & qualifying candidates (run 30485)
158 unique CJ products evaluated by `fn_resolve_concrete_supplier_identity` (matcher unchanged):

- **Exact (`STRONG_SAME_PRODUCT`, all 3 canonical attributes): 0** — `qualifying_count=0`.
- `CLOSE_COMPARABLE` (similar; one or two attributes, not all three): **42**
- `CATEGORY_ONLY`: 1 · `UNRELATED`: 115

**Result class: NO_VALID_CJ_MATCH.** No CJ product combines NATIVITY_SCENE + ILLUMINATED +
FORM:WALL_DECORATION. This is **not** exact-SKU evidence of absence of the physical product from CJ;
it is: across the top results of all eight canonical surfaces, CJ surfaced no product whose
attributes match the concrete Krippen identity.

### Nearest similar products (illustrative — NOT exact matches; attribute subset only)
- `Lighted Nativity Christmas Table Centerpiece Ornament` — nativity + illuminated, **wrong form**
  (table centerpiece, not wall).
- `9FT Lighted ... Inflatable Nativity Scene ... Yard Decorations` — nativity + illuminated, **wrong
  form** (inflatable yard piece).
- `Joy Nativity Scene Outdoor Christmas Sign, Star Silhouette, 3 Piece` — nativity, no illumination,
  yard sign.
- `6-Pack ... Nativity Scene Christmas Tree Hanging Ornaments` / `Wooden Christmas Nativity Animal
  Hanging Decoration` — nativity, hanging ornaments (figurine/ornament form).
- `Wooden Easter Creche - NATURAL` — creche but Easter, unlit, not a wall decoration.
- Wall-art that is not nativity (`Wooden DIY Furniture Wall Art`, `Vintage Metal Wall Art Buddha
  Jesus`), plus many LED lights / pre-lit trees (illuminated only).

(CJ product IDs/SKUs for every candidate are in the run-30485 resolver output
`resolver.candidates_considered[]` — `supplier_product_id` = CJ `pid`. CJ exposes no public per-pid
PDP URL; the evidence link is the `product/list` response captured in the n8n execution record.)

## Preserved controls
Tenant isolation (ownership check) and country isolation (DE only) intact; Product Asset Lock
untouched; exact-match strictness + form-conflict detection unchanged (`fn_market_supplier_match`);
`persist=false` wrote nothing (verified: 0 rows written to
`commerce_concrete_supplier_resolution` for this product by these runs); idempotency claim/replay
intact; secrets referenced by credential id only. No supplier asset publishing, store change, or
paid action was triggered. No new paid service.

## Verification (no cost; deterministic)
- Offline harnesses: pacing/retry **23/23**, breadth-first round-robin **12/12**
  (`dr/n8n/tests/`).
- Mocked n8n regressions: **30482** (pacing/retry node, error page recorded without aborting,
  deep-page match resolved) and **30484** (breadth-first; all 8 queries' page 1 examined;
  `manger scene` http-0 recorded without aborting; deep-query exact resolved). Both mock EXACTs are
  injected test artifacts, not real CJ products.
- Deployed/published: active version `7e8c22c0-f306-40d4-8acf-3418af32e0a6` (fixes live), active
  state preserved.

## Remaining blockers / caveats
- **CJ keyword relevance is weak for precise multi-word phrases.** For `nativity scene wall
  decoration` / `led nativity scene wall decoration`, CJ returned mostly loose token matches (floor
  lamps, wall mirrors, TV brackets, solar lights). If an illuminated nativity wall decoration exists
  in CJ under a differently-worded title, it could rank beyond the examined window. Residual risk is
  low (the nativity catalog itself is represented via the broad queries and consists of figurine
  sets / ornaments / yard signs), but non-zero. Fully closing it would need either a CJ category
  browse (not just keyword search) or a synonym-broadened query set — out of scope for this run and
  not possible without more budget.
- The `NO_VALID_CJ_MATCH` is an **evidence-of-absence-within-the-searched-window** result, not proof
  the physical product is absent from CJ's entire catalog. Exact supplier identity is **not**
  confirmed and must not be marked confirmed.

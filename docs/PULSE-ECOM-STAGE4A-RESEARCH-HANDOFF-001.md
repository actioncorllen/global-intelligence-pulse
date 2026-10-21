# PULSE-ECOM-STAGE4A-RESEARCH-HANDOFF-001

**Completed the research handoff for the Snowman GB product: (A) wired the CJ product-list → Stage-2
exact-supplier resolver into the research path and verified an honest NO_VALID_CJ_MATCH from the cached
candidates (no category-adjacent bind), and (B) diagnosed + fixed + re-verified the TikTok
`not_ad_array` failure (a date-range API rejection). Free/cached only — no new DataForSEO or other paid
calls; the DataForSEO budget stays DISABLED ($0.102 spent, unchanged).**

## A. CJ → Stage-2 exact-supplier resolver handoff

### Trace (req 1) + missing wiring fixed
The resolver chain already existed and is correct: `fn_stage2_cj_finalize_candidates(pages)` →
`fn_resolve_concrete_supplier_identity(candidates, persist)` → `commerce_concrete_supplier_resolution`.
It binds **only** a shared-identifier EXACT match or a single STRONG_SAME_PRODUCT/EXACT_CONFIRMED
attribute match; category-adjacent candidates (CLOSE_COMPARABLE / excluded-subtype) never qualify.
**Missing wiring:** the 013N auto-dispatch path did CJ `product/list` + ingest into the shared catalog
(`commerce_supplier_products`) but **never invoked the resolver**, so a research run produced no
`commerce_concrete_supplier_resolution` row and the drawer showed "not searched" instead of a truthful
resolved/no-match state.

**Fix — mig_320:** `fn_finalize_research_run` now calls
`fn_resolve_concrete_supplier_identity(tenant, product, market, NULL, true)` at run finalisation (gated
on the SUPPLIER/CJ source having been searched) — the correct point, where all marketplace evidence and
all cached CJ candidates are present. It reuses the existing resolver, is **free** (self-selects the
already-ingested CJ candidates; no provider call), and is best-effort (a resolver error never fails the
run). Deployed and verified live.

### Exact SKU verification (req 2) — honest NO_VALID_CJ_MATCH, no false bind
Ran the resolver against the Snowman's **cached** CJ candidates (free):
- `concrete_state = CONCRETE_RESOLVED`, `identity_result = **NO_VALID_CJ_MATCH**`, `bound = false`,
  `selected_supplier_product_id = null`.
- **40 candidates considered, all `CLOSE_COMPARABLE`, 0 qualifying** → correctly **no bind**. The cached
  CJ rows for "illuminated snowman christmas door hanger" are category-adjacent Christmas items
  (candles, mugs, wreaths, ornaments, cookie cutters, trees…), **none an exact snowman door hanger and
  none shipping to GB** — so an honest no-match, never a category-adjacent bind.
- Persisted the resolution row so the drawer now reads the truthful state (backfill for the run that
  finalised before the fix).

## B. TikTok `not_ad_array` — diagnosed, fixed, re-verified

### Diagnosis (req 3) from stored evidence first
n8n execution 30501 (the Snowman run) showed:
- **Get TikTok Token: OK** (token issued).
- **TikTok Ad Query: HTTP 400, `error.code = invalid_params`** —
  *"filters.ad_published_date_range.max: 20261020 is invalid. Please provide a value before today's
  date."*
- Shape TikTok: `api_ok=false`, `raw={error:{code:invalid_params, http_status:400}}`.

So this is an **API REJECTION (400)** — not empty data (that would be a valid empty `ads` array) and not
a malformed response. **Root cause:** the query built `ad_published_date_range.max` from
`$now.minus({days:1})`; at 23:45 UTC the instance clock resolved "yesterday" to today's date in TikTok's
reckoning, and TikTok requires `max` strictly **before** today.

### Fix (the actual contract) + deploy
Patched the 013N executor's **"TikTok Ad Query"** node (`QjYMzrCm1cDXxUS4`) to compute the window in UTC
and lag `max` by 2 days, keeping a ~90-day window:
`ad_published_date_range = { min: $now.setZone("UTC").minus({days:92}), max: $now.setZone("UTC").minus({days:2}) }`.
No other change.

### Re-test (req 7) — free isolated probe → PASS
A temporary, free probe (token + the **fixed** TikTok ad query, archived after) returned **HTTP 200,
`error.code "ok"`, 5 ads (`OK_ADS_FOUND`)** — the `invalid_params` 400 is gone. The probe's classifier
distinguishes `API_REJECTION` / `OK_EMPTY_NO_DATA` / `OK_ADS_FOUND` / `MALFORMED`, confirming the
response-shape contract reads each case correctly. Future research runs will record TikTok as
OBSERVED / SEARCHED_NO_EVIDENCE instead of SOURCE_FAILED. (The Snowman's own run was left as-is — not
re-dispatched — to honour "no new paid tasks"; the fix applies to subsequent runs.)

## Drawer result (req 5) — genuine or truthful states
- **Supplier:** truthful **NO_VALID_CJ_MATCH** (`commerce_concrete_supplier_resolution` row:
  CONCRETE_RESOLVED, bound=false, 40 considered) — no fabricated supplier, no category-adjacent bind.
  No bound SKU/variants/GB-freight because there is no exact match (honest).
- **Competitor pricing:** eBay GB **OBSERVED £16.23–£18.03, median £17.13, 2 sellers** (`product_market_competitors`).
- **Advertising:** Meta `NO_PRODUCT_MATCH` (honest); TikTok fixed → future runs OBSERVED/NO_EVIDENCE.
- **Search demand:** DataForSEO `no_relevant_query` (honest, from the prior paid run).

## Preservation (req 6)
- **Tenant/country isolation:** the resolver verifies the product belongs to the tenant and scopes by
  market; the finalize hook passes the run's own tenant/product/market.
- **Provenance / Product Asset Lock:** unchanged; resolution records provenance + an identity-separation
  note; no media rights change; nothing unlocks store/ad publishing.
- **DataForSEO budget:** still **DISABLED**, month spend **$0.102** unchanged — no paid call in this task.

## Status
| Item | Verdict |
|---|---|
| CJ → Stage-2 resolver handoff wired (mig_320) | **PASS** (deployed, verified) |
| Exact SKU verification from cached candidates | **PASS** — honest NO_VALID_CJ_MATCH, no category-adjacent bind |
| Drawer receives truthful supplier state | **PASS** (resolution row persisted) |
| TikTok `not_ad_array` diagnosed (API rejection) + contract fixed + re-tested | **PASS** (live probe 200, 5 ads) |
| Free/cached only; budget preserved disabled | **PASS** |

**Overall: PASS.** The CJ→resolver handoff is complete and produces truthful supplier resolutions; the
TikTok date-range contract is fixed and verified free. No exact CJ supplier exists for this generic
seasonal Snowman (honest NO_VALID_CJ_MATCH), which is a true data outcome, not a defect.

## Notes / remaining
- A positive CJ bind would require a product that genuinely has an exact CJ supplier; the pipeline is now
  wired to resolve + bind one automatically when it exists.
- The Snowman's existing run keeps TikTok SOURCE_FAILED (pre-fix); a future run (or an approved re-run)
  will show the corrected TikTok state.
- Stage 3 signed-in multilingual visual verification remains separately owed before launch.

**STOP at Stage 4A.** No supplier expansion, saturation or country recommendations; Stage 4B not started.

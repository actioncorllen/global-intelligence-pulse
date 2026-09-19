# STRATELOQ-ECOM-MARKET-RESEARCH-AUDIT-013G

**VERDICT: `SMALL_BACKEND_CONNECTION_REQUIRED`** for the market selector + reading/comparing a product's
existing researched markets (the read/compare/catalog capability already exists and only needs a small
authenticated catalog-read RPC + wiring). **Running a NEW, not-yet-evidenced market on demand is
`BACKEND_CAPABILITY_REQUIRED` (authenticated orchestration) + `EXTERNAL_DEPENDENCY` (provider ingestion).**
The 013F Supplier empty-card is a frontend decoder key-mismatch with a one-line fix. Read-only audit —
nothing implemented, no data/Lovable/publish change.

---

## 1. Business-country field
`public.business_profiles.country` (founder = `GB`). This is the business home country and is **never**
touched by product-market selection. `business_category` (013A) is separate again.

## 2. Product-market field(s)
- **Decision market:** `product_opportunity_decisions.country_code` (+ `market_currency`).
- **Evaluation market:** `product_market_evaluations.country_code` (+ `market_currency`, `landed_cost`,
  `economics`, `evidence`, `gate_state`, `market_decision`) — one row per (tenant, product, country).
- **Signal market:** `commerce_signals.value->>'market'` (context; also product-scoped).
- **Competitor market:** `product_market_competitors.country_code`.
- **Supplier market:** supplier evidence is product/candidate-scoped (shared catalogue + owned
  `product_acquisitions` snapshot), not a first-class country column.
- **Storefront market:** `commerce_product_pages.country_code` (+ `fn_storefront_change_country`).
These are **distinct rows keyed by `country_code`** — selecting a new market adds/updates a per-country row
and never overwrites another market or the business country.

## 3. Product identity model
Canonical identity is `commerce_products` (`id`, `product_identity`, `identity_basis` — the two-context
identity model, mig_220). **One `commerce_product` per canonical product**; the country lives on the
evaluation/decision rows, not on the product. Verified: founder product `e453eed4` ("kids nightlight
projector") has **one** commerce_product with decisions in **DE, FR, GB, US** — so the same product
legitimately carries multiple market decisions. No duplicate product is created when the country changes.

## 4. Market-specific decision model
`product_opportunity_decisions` is per (tenant_id, product_id, country_code) — a product may have many
market decisions (proven above). `product_market_evaluations` is the per-market evidence+scoring row that
feeds each decision. So "same product, many markets" is already the data model; nothing to redesign.

## 5. Existing market-search pipeline (backend, end-to-end)
The building blocks all exist:
- **Catalog / eligibility:** `ecommerce_market_universe` (country catalog + per-capability support),
  `fn_market_universe_sync`, `fn_is_supported_market`, `fn_currency_for_country`,
  `fn_category_market_state`.
- **Candidacy:** `fn_market_candidacy_screen(p_tenant, p_product_id, p_selling_markets[], threshold)`
  — **service_role only**.
- **Assemble evidence for a market:** `fn_assemble_real_product_market(p_candidate, p_country, p_currency,
  p_price_query, p_supplier, p_persist)` — composes ALREADY-INGESTED evidence (`calls_external=false`).
- **Score a market:** `fn_evaluate_product_market(p_tenant, p_product, p_country, p_market_currency,
  p_evidence, …)` — scores supplied evidence (`uses_auth_uid=false`, takes explicit `p_tenant`).
- **Persist tenant evaluation:** `upsert_tenant_product_evaluation_v2(p_product_id, p_target_market, …)`
  — authenticated + `auth.uid()`.
- **Rank markets:** `fn_rank_product_markets(p_tenant, p_product, score_version)`.
- **Read (authenticated, auth.uid()-scoped):** `fn_own_product_country_explorer(p_product_id,
  p_selling_markets[])`, `fn_own_market_comparison(p_product_id, p_countries[])`,
  `fn_own_country_evaluation_state(p_product_id, p_country)`.

**The gap:** there is **no authenticated, `auth.uid()`-scoped orchestrator** that takes (product, country)
and runs assemble→evaluate→rank→decision. The run functions take an explicit `p_tenant` (client-supplied
tenant authority — unsafe to call from a browser) and pre-gathered evidence; the candidacy screen is
service_role only; and gathering **fresh** evidence for a not-yet-covered market needs external providers.

## 6. Existing callable entry point
- **Read existing markets:** `fn_own_product_country_explorer` (auth.uid() → `fn__own_tenant()` →
  `fn_product_country_explorer`) — READY. Cross-market read via `fn_own_market_comparison`; per-country
  state via `fn_own_country_evaluation_state`.
- **Run a new market:** none that is browser-safe. Closest is `upsert_tenant_product_evaluation_v2`
  (auth.uid(), but expects pre-computed scores, not a gather+run).

## 7. n8n / Edge Function involvement
Fresh per-market evidence gathering is external: eBay Browse (marketplace), DataForSEO (search demand),
Meta Ad Library (advertising) — ingested via edge functions (`prepare-product`, `start-discovery`,
`meta-*`) and n8n workflows, then composed by `fn_assemble_real_product_market`. So an on-demand new-market
run has an **EXTERNAL_DEPENDENCY** (provider quotas/cost + orchestration). `fn_assemble_real_product_market`
itself makes no HTTP calls — it reads already-ingested `market_price_observations`, competitors, supplier
data.

## 8. Signal market handling
`commerce_signals` are product-scoped with `value.market` context and `visibility`. Adding a market does
not rewrite existing signals (new observations are new rows). Surfaced today via
`fn_ecommerce_signal_timeline` (013E) and Overview `evidence_summary` (013A).

## 9. Competitor market handling
`product_market_competitors.country_code` per (tenant, product, country). Selecting a new market would
produce new competitor rows for that country; existing GB rows are untouched. Read via
`fn_ecommerce_competitor_intelligence` (013E) — 74 real GB rows for the founder.

## 10. Supplier market handling
Supplier evidence is product/candidate-scoped (`commerce_supplier_products` shared catalogue +
`fn_market_supplier_match`), surfaced tenant-safely only through owned `product_acquisitions` snapshots
(013E). No first-class supplier country column; supplier market is implied by the product-market
evaluation it feeds. Founder has no owned supplier data (0 acquisitions) → NO_DATA.

## 11. Currency handling
Original observed currency is preserved per observation: `commerce_products.price_currency`,
`product_market_competitors.price_currency`, `product_market_evaluations.market_currency` + `landed_cost`
+ `economics`, `product_opportunity_decisions.market_currency`. Canonical currency-per-country =
`ecommerce_market_universe.default_currency` / `fn_currency_for_country`. Conversion is an existing
contract: `fx_rates` (+ daily refresh, unit 27) and `market_price_observations`. **Changing the search
market never rewrites another market's observations** (they are separate country-keyed rows), and no
currency is invented — conversion only via the existing `fx_rates` contract.

## 12. Country catalog / source
**`public.ecommerce_market_universe`** is the canonical catalog: `country_code` (ISO), `country_name`,
`region`, `default_currency`, and per-capability support (`currency_supported`, `supplier_supported`,
`search_intelligence_supported`, `marketplace_intelligence_supported`, `advertising_intelligence_supported`,
`campaign_execution_supported`, `ecommerce_eligible`, `status`, `evidence_coverage`). It already carries
exactly what the selector needs (searchable name + ISO code + supported/unsupported state). RLS-enabled
(deny-all); it is currently read only by internal (`p_tenant`) functions — **no `fn_own_*` authenticated
catalog reader exists yet** (small connection needed).

## 13. Exact contract Lovable would need
- **Selector list:** a small authenticated read of `ecommerce_market_universe` (e.g.
  `fn_own_market_universe()` returning code/name/region/default_currency/eligibility+support flags) — **to
  be added** (SMALL_BACKEND_CONNECTION).
- **A product's researched markets + current state:** `supabase.rpc('fn_own_product_country_explorer',
  { p_product_id })` — **READY**.
- **Cross-market comparison:** `supabase.rpc('fn_own_market_comparison', { p_product_id, p_countries })`
  — **READY**. Per-country state: `fn_own_country_evaluation_state`.
- **"Search this product in <country>":** a new authenticated, entitlement-gated orchestrator
  `fn_own_run_product_market(p_product_id, p_country)` that resolves tenant from `auth.uid()`, screens
  candidacy, and (a) if evidence for that market already exists → assemble→evaluate→persist→decision from
  existing rows (SMALL_BACKEND_CONNECTION), or (b) if not → trigger provider ingestion via edge/n8n
  (BACKEND_CAPABILITY_REQUIRED + EXTERNAL_DEPENDENCY). **To be built.**

## 14. Execution / run states
Supported today by the persisted model: a market either **has** a `product_market_evaluations` row
(with `gate_state` / `market_decision`) or it does **not**. `fn_own_country_evaluation_state` returns the
per-country evaluated/not-evaluated state. There is **no async job/queue table** for on-demand market runs
(the ecom discovery pipeline uses `discovery_runs` for website discovery, not per-product-per-country
research). So truthful states today are effectively **EVALUATED / NOT_EVALUATED / (ELIGIBLE|UNSUPPORTED
from the universe)**; RUNNING/QUEUED/PARTIAL would require the new orchestrator + a run-status record.

## 15. Recommended user interaction (smallest truthful)
- The selector reads `ecommerce_market_universe` (searchable, ISO codes, support flags) and shows the
  product's evaluated markets from `fn_own_product_country_explorer`.
- Choosing an **already-evaluated** market = instant read (no run).
- Choosing a **new** market must **not** auto-run: show a **"Search this market"** confirmation, then call
  the (future) authenticated orchestrator, then poll `fn_own_country_evaluation_state` until an evaluation
  exists, then refresh the decision. Do not promise real-time; treat it as an async research action.
Until the orchestrator exists, the selector should only offer already-evaluated markets for switching and
mark others "not researched yet".

## 16. Same-product / multi-market behavior
Already correct: one canonical `commerce_product`, many `product_market_evaluations` /
`product_opportunity_decisions` keyed by `country_code`. Switching country selects/creates a market row for
the SAME product; it never duplicates the product. **Verified** on `e453eed4` (DE/FR/GB/US).

## 17. Cross-market comparison readiness
**PARTIAL → READY (read side).** `fn_own_market_comparison(p_product_id, p_countries[])` and
`fn_own_product_country_explorer` already return per-country opportunity score / evidence / observed price
for a product. Comparison across markets that have been researched is **READY**; comparison including a
not-yet-researched market depends on the run capability (item 13).

## 18. Security assessment
- **Read contracts** (`fn_own_*`) are `auth.uid()`-scoped via `fn__own_tenant()`, SECURITY DEFINER,
  `search_path=''`, no client tenant — **safe**.
- **Run/scoring functions** (`fn_evaluate_product_market`, `fn_assemble_real_product_market`,
  `fn_rank_product_markets`) take an explicit `p_tenant` and are granted to `authenticated` — a browser
  calling these directly could **assert an arbitrary tenant**. They must **not** be exposed to the browser;
  the future orchestrator must resolve tenant from `auth.uid()` (never a client argument), enforce
  entitlement (`fn_workspace_access`), and prevent arbitrary product mutation. `fn_market_candidacy_screen`
  is correctly service_role-only. **The run path is not browser-safe as-is.**

## 19. Supplier empty-card root cause (013F)
**Cause B — the decoder fabricates one all-null supplier row from the RPC's status wrapper, due to a key
mismatch.** `fetchSupplierIntelligence` (src/lib/business-discovery/ecommerce-secondary-api.ts) passes
`keys: ["suppliers","supplier_intelligence"]`, but `fn_ecommerce_supplier_intelligence` (013E) returns its
rows under **`acquisitions`** (`{status:'ok', count:0, acquisitions:[], source_contract, note}`). In
`extractRows` (ecommerce-secondary-contract.ts) no array key matches, so the permissive fallback
`if (Object.keys(root).some(k => k !== "status")) return [root];` returns the **whole wrapper object as one
row**. `decodeSupplier(wrapper)` finds no supplier/product/price keys → returns a `SupplierIntelligenceRow`
with every field `null` and `id:"row-0"`. The Suppliers view then renders one empty "Supplier observation"
card. It is NOT the RPC (A) — the RPC correctly returns an empty `acquisitions` array; and not a render-on-
empty bug (C) — the list received exactly one (bogus) row. **The same mismatch latently affects Creative**
(keys `["creatives","creative_intelligence","assets"]` vs the RPC's `briefs`/`media`), which would render
one bogus empty creative and hide the real briefs — worth fixing in the same change.

## 20. Smallest supplier correction (frontend; no backend change — 013E backend is correct)
Two-line, safest fix in `ecommerce-secondary-contract.ts` `extractRows`: never treat a status-wrapper as a
row. Replace the tail
```
if (Object.keys(root).some((key) => key !== "status")) return [root];
return root.status === "ok" ? [] : null;
```
with
```
if (root.status === "ok") return [];          // wrapper with no matching array key → empty, not a row
if (!("status" in root)) return [root];       // only a bare object (no status) is a single row
return null;
```
and, so real rows are found when present, correct the keys in `ecommerce-secondary-api.ts`:
`fetchSupplierIntelligence` → `keys: ["acquisitions"]`, `fetchCreativeIntelligence` → `keys: ["briefs"]`
(creative also needs a shape-aware decoder for the nested briefs→angles→creatives, a follow-on). With the
`extractRows` guard alone, the founder's zero-supplier case yields `rows: []` and the UI shows the honest
**"No supplier intelligence is available for your selected products yet."** with no empty card.

## 21. Files inspected
- DB: `product_opportunity_decisions`, `product_market_evaluations`, `product_market_competitors`,
  `commerce_products`, `commerce_signals`, `product_acquisitions`, `ecommerce_market_universe`, `fx_rates`,
  `market_price_observations`, `business_profiles`; functions `fn_own_product_country_explorer`,
  `fn_own_market_comparison`, `fn_own_country_evaluation_state`, `fn_product_country_explorer`,
  `fn_assemble_real_product_market`, `fn_evaluate_product_market`, `fn_market_candidacy_screen`,
  `fn_rank_product_markets`, `upsert_tenant_product_evaluation_v2`, `fn_is_supported_market`,
  `fn_currency_for_country`, `fn_market_universe_sync`, `fn_storefront_change_country`.
- Lovable: `src/lib/business-discovery/ecommerce-secondary-contract.ts`,
  `src/lib/business-discovery/ecommerce-secondary-api.ts` (hook/render behaviour inferred — the defect is
  fully at the api/decoder layer).

## 22. Confirmation: no implementation / mutation
Read-only. No migration, DB write, Lovable change or publish. No data mutated; no run executed.

## 23. FINAL VERDICT
**`SMALL_BACKEND_CONNECTION_REQUIRED`.** The multi-market data model, per-country evaluations/decisions,
canonical product identity, country catalog (`ecommerce_market_universe`), currency preservation, and the
authenticated read/compare contracts (`fn_own_product_country_explorer` / `fn_own_market_comparison` /
`fn_own_country_evaluation_state`) all **already exist** — the market selector, existing-market display and
cross-market comparison need only a small authenticated catalog-read RPC + Lovable wiring. **On-demand
research of a NEW, not-yet-evidenced market is a separate, larger step: `BACKEND_CAPABILITY_REQUIRED`
(an `auth.uid()`-scoped, entitlement-gated orchestrator over the existing assemble→evaluate→decide
functions — which currently take an unsafe client `p_tenant`) plus `EXTERNAL_DEPENDENCY` (eBay/DataForSEO/
Meta ingestion via edge/n8n).** The 013F Supplier empty-card is a frontend decoder key-mismatch fixed by
the two-line `extractRows` guard above (backend 013E is correct).

STOP. Audit only — not implemented.

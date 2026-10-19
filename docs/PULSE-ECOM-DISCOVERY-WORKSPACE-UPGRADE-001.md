# PULSE-ECOM-DISCOVERY-WORKSPACE-UPGRADE-001

**Paid Product Discovery workspace upgrade: the three FastMoss discovery lanes (New Listed /
Top Selling / Most Promoted) now surface to subscribers in the existing Lovable "Pulse
Implementation" workspace — as a discovery filter, card lane tags, and a per-product "Discovery
lanes" evidence section — all driven by one new server-owned read contract. No new paid API calls,
no redesign, no unrelated cleanup. Result: PASS (one "where accessible" verification deferred —
live signed-in rendering, not reachable from this environment).**

Builds on the already-deployed backend: FastMoss three-lane discovery (mig_307, edge v4),
Historical-Sales momentum + review/creator enrichment (mig_308/308b), and Product Videos
(mig_305/306). This unit added only the read contract (mig_309) and the frontend.

## 1. Backend read contract — `mig_309` (applied + verified)
`fn_product_discovery_lanes(p_tenant uuid, p_product uuid, p_market text) RETURNS jsonb`
- **Server-owned identity** via `auth.uid()`; `p_tenant` is NEVER trusted for authorization (same
  model as `fn_product_media_state`). `SET search_path TO ''`, `SECURITY DEFINER`, STABLE.
- **Country-isolated**: every signal is matched on `value->>'market' = upper(p_market)`.
- **Fail-closed**: missing auth / non-owned product / blank market → `{status:"unauthorized",
  discovery_lanes:[], lanes:[], momentum:null, reviews:null, creators:null, ...}`.
- Returns per `(product, market)`: `discovery_lanes[]` (distinct lane keys), `lanes[]` (one per
  lane, latest wins — `sales_units`, `revenue`, `sales_growth_rate` for TOP_SELLING,
  `promotions_affiliate_count` for MOST_PROMOTED, `observed_at`, `source=FASTMOSS`,
  `authority=REFERENCE_ONLY`), `momentum` (latest `COMMERCE_SALES_MOMENTUM`), `reviews`,
  `creators`, `source_freshness`, and an `invariants` block.
- **Integrity (req 5)**: reviews require a non-null `review_count`; creators require a non-null
  `creator_count`. The known spurious empty-creator row (`creator_count=null`) is therefore
  excluded and contributes nothing; empty/UNKNOWN signals never surface, and nothing is ever
  rendered as `0`. Lanes derive from the per-lane, market-scoped `COMMERCE_PRODUCT_NATIVE` signals
  (verified FastMoss identity, `fastmoss_strategy` set), `DISTINCT ON` strategy — never from loose
  family keys.
- Granted to `anon, authenticated, service_role` (read wrapper). The companion
  `fn_product_discovery_lanes_selftest()` is REVOKEd from PUBLIC/anon/authenticated, service_role only.

**Verification (live DB, project `nxaunmyihhjixxxljcqt`):**
- `fn_product_discovery_lanes_selftest()` → **5/5 PASS**: KRIPPEN spurious creator excluded,
  KRIPPEN momentum present, multi-lane evidence present (`MOST_PROMOTED` + `TOP_SELLING`), JP country
  isolation empty, cross-tenant denied.
- Real owner-simulated sample (DE): one product converged across both lanes, each lane carrying its
  own discriminator (`promotions_affiliate_count=2061` / `sales_growth_rate=4826`),
  `source_freshness` present, `creators=null` (spurious row excluded).
- PostgREST boundary: exactly **1 function** (no overload ambiguity), signature
  `(p_tenant uuid, p_product uuid, p_market text)`, EXECUTE granted to `authenticated` + `anon`;
  no-JWT call returns `status="unauthorized"` with 0 lanes (fail-closed path the decoder relies on).

## 2. Frontend — Lovable "Pulse Implementation" (commit `58b0cede`)
Reuses the existing Product Cards, filter bar and Product Intelligence drawer; mirrors the proven
`useProductMedia` / `useProductIntelligenceMany` data pattern. New/changed:
- **New** `src/lib/business-discovery/product-discovery-lanes-contract.ts` — pure decoder + fetch
  (`p_tenant:null`; identity server-owned). Fail-closed: non-object or `status!=="ok"` → `null`;
  every missing metric stays `null`, never `0`; `momentum`/`reviews`/`creators` stay `null` when the
  server omits them. `cardLaneBadges()` returns present lanes in stable order
  `[NEW_LISTED, TOP_SELLING, MOST_PROMOTED]`.
- **New** `src/hooks/use-product-discovery-lanes.ts` — `useProductDiscoveryLanes` (single) +
  `useProductDiscoveryLanesMany` (filter fan-out), sharing one query key so the card's single query
  reuses the list's cache.
- **`product-intelligence.tsx`** — added a 6th **"Discovery lane" filter** (lists only lanes present
  in the selected country; hidden when none); **lane tags** on the card next to the opportunity
  stage; and a **"Discovery lanes" drawer section** (after "Market intelligence", before "Product
  videos") showing per-lane sales/revenue/growth/promotions, historical momentum, marketplace
  reviews, associated creators and source freshness — each row/group rendered only when genuinely
  present, with a "reference only" note. `matchesFilters` extended with the lane predicate.
- **`ecommerce-workspace.tsx`** — `DecisionsBody` fans out lanes for every in-country product, feeds
  the filter's lane list + the visibility predicate, and passes lanes to each card + drawer.
- Three existing card tests updated to stub the new lane hook (exactly as they already stub the media
  hook); nothing weakened or removed. `AGENTS.md` one-line note that lane data is REFERENCE_ONLY.

**Checks (run by the Lovable agent):** vitest **270/270 pass** (incl. 5 new), **typecheck clean**,
**no new lint errors** (repo-wide pre-existing 1113 problems unchanged, all in unrelated files).

## 3. Preserved
Product videos, supplier status/resolution, observed/market prices, competitor evidence and
opportunity classifications/lifecycle are untouched. All markets (FastMoss 20 in config; workspace
runs per eligible market via the `?country=` param), multilingual presentation, tenant isolation
(server `user_id`/`auth.uid()`), and **Product Asset Lock** are preserved: lane data is
REFERENCE_ONLY and display-only — it cannot reach Create Free Store, Create Ad, image generation,
publishing or the asset-lock gates. No deduplication change: products still converge on
`fastmoss_product_id` with distinct per-lane evidence; identity stays `platform_id`, never SKU. The
spurious creator row remains inert (declined cleanup; excluded by the read contract, so it is
invisible to subscribers and contributes no evidence). The failing DELETE was not retried; no new
paid FastMoss/provider calls were made.

## 4. What subscribers can actually see
In Products (signed in, e.g. `?country=DE`): a **Discovery lane filter** (New Listed / Top Selling /
Most Promoted), **lane tags on each product card**, and in **View intelligence → Discovery lanes**:
country-specific sales units, revenue, sales growth (Top Selling), promotions/affiliates (Most
Promoted), historical momentum, marketplace reviews, associated creators and source freshness —
plus the existing videos, supplier, prices, competitors and classifications. Empty/unknown signals
and the spurious creator row never appear.

## Status: PASS
- Backend read contract: **PASS** (applied, 5/5 selftest, PostgREST boundary verified).
- Frontend: **PASS** (built, 270/270 tests, typecheck clean, committed to Lovable `58b0cede`;
  nothing published).
- Backend-to-frontend contract: **PASS** (decoder maps the real payload keys; fail-closed path
  confirmed live).

### Remaining launch blockers
None for this unit. One verification is **deferred, not failed**: live **signed-in rendering** of
the workspace could not be exercised from this environment (no auth session; egress to the app host
is not allowlisted here). To confirm visually: sign in, open Products with `?country=DE`, and use the
Discovery lane filter. The change is unpublished — publish the Lovable project when ready.

Pre-existing, out of scope: `/product/v1/search` stays 403 (external plan permission, not required
here); the one inert spurious-creator row remains (harmless, excluded from all reads).

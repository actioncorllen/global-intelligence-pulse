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

---

## Launch fix — deployment gap (addendum)

**Reported:** the live site `globalintelligenceactions.com` showed old Product Cards and no
discovery experience, despite tests passing on Lovable commit `58b0cede`.

**Root cause (confirmed, not a code defect):** the upgraded UI was committed to Lovable but **never
published to production**. The live custom domain (served by this Lovable project — published slug
`https-www-globalintelligenceactions-com.lovable.app`) was serving a build that **predated**
`58b0cede`: its workspace bundle called `fn_ecommerce_workspace_intelligence` and
`fn_product_media_state` but contained **no `fn_product_discovery_lanes`** and none of the lane UI,
and no discovery chunk existed in the 116-chunk build. (The `dev.`/`workspace_.` chunk prefixes are
TanStack route-group names, not a dev build.)

**GB data reality (no substitution/fabrication):** the only FastMoss discovery-lane evidence in the
database is for **DE** (9 products, `TOP_SELLING` + `MOST_PROMOTED`), owned by tenant
`7c8ddf9d…`. **GB has zero** FastMoss lane evidence. `commerce_products` has no market column;
a product's market is carried by its signals/decisions, and no GB product carries lane signals.
Populating GB would require a FastMoss discovery run for GB (a paid provider call — deliberately NOT
made here).

**Fixes shipped:**
1. **Honest empty state (req 6)** — Lovable commits `870ba37` + `2f2c7af` (project `0e77a72b`): the
   Products view shows *"No FastMoss discovery signals for {market} yet — New Listed, Top Selling and
   Most Promoted lanes appear here when available."* when a market has no lanes, and the drawer now
   **always** renders the "Discovery lanes" section with an honest empty line instead of hiding it.
   The feature is no longer silently hidden. Tests **272/272**, typecheck clean, no new lint.
2. **Published to production** — `deploy_project` (deployment `2574374b…`). Verified on the live
   domain: the entry bundle hash changed (`index-CrkKNnEy.js` → `index-DrRn1PuO.js`); the live
   workspace bundle now carries the `product-discovery-lanes` query key + the empty-state copy; and
   the component chunk `reason-presentation-BjN41R7I.js` now contains `fn_product_discovery_lanes`
   (RPC wiring), `Discovery lane` (filter), `Discovery lanes` (drawer section), `Historical momentum`
   and `Product videos`. The full discovery + video experience is now live.

**Deployment status:** PASS — upgraded UI published and confirmed live at the bundle level.
**Preserved:** tenant/country isolation (server `auth.uid()`), existing Product Cards, Product Asset
Lock (lane data REFERENCE_ONLY/display-only), founding-member access — no backend/RPC change.

**Customer-visible PASS/FAIL:**
- Discovery feature present on the live site: **PASS** (filter, badges, drawer section all deployed).
- DE market (has evidence): **PASS** — genuine lanes/sales/growth/promotions render.
- GB market (no evidence): **PASS (honest empty state)** — the feature is visible and says GB has no
  FastMoss signals yet; it is not fabricated and not silently hidden.
- **Deferred (not failed):** a live **signed-in visual** confirmation — this environment has no auth
  session for the workspace (auth-gated). Verified instead at the deployed-bundle + backend-contract
  level. To confirm visually: sign in, open Products, select **DE** to see populated lanes; other
  markets (incl. GB) show the honest empty state until discovery runs for them.
- **Images:** card images come from `fn_product_media_state` and render only genuine server media
  (Product Asset Lock — no fabricated images); products without stored media show no image by design.

---

## GB live Product Discovery (user-approved paid run)

**Goal:** make genuine, fresh FastMoss products visible in the GB Product Explorer (GB was empty).

**Root cause:** GB is fully supported (FastMoss config: GB enabled, GBP; all 3 strategies enabled) but
GB discovery had **never been dispatched** — only DE had ever been ingested. Discovery is triggered by
an **external** dispatcher (no in-DB cron); it had not posted GB. No captured GB provider responses
existed, so GB required new paid calls. The user approved "run GB now — 3 calls".

**What ran (cost):** fetched the three GB ranking lanes through the existing broker
(`fn_invoke_provider_broker`, `fastmoss-product-detail`): NEW_LISTED via `rank_raw`, TOP_SELLING +
MOST_PROMOTED via allowlisted `fm_raw`. **4 FastMoss API calls total** — NEW_LISTED ×1, MOST_PROMOTED
×1, TOP_SELLING ×2 (the first TOP_SELLING attempt hit the 60s pg_net timeout and was retried once).
**0 research/enrichment calls**: every candidate ingested under `SET LOCAL pulse.suppress_dispatch='on'`,
so `fn_auto_dispatch_candidate_research` returned `DISPATCH_SUPPRESSED` for all — no deep-research
provider spend beyond the approved ranking calls.

**Ingest + projection (free, existing architecture):**
`fn_fastmoss_ingest_candidates_ml` (per lane, suppressed) persisted the products, per-lane
`COMMERCE_PRODUCT_NATIVE` signals, `monday_opportunity_registry` entries and the REFERENCE_ONLY cover
images. Candidates become Explorer cards only once they have a country `product_market_evaluation` +
`product_opportunity_decision`, so for the 28 GB products we ran the free, no-external-call projection
`fn_assemble_real_product_market(..., 'GB','GBP', ...)` then `fn_pod_evaluate(..., 'GB','pod_v1', true)`
— the same steps the Monday run performs. All 28 resolved to `WATCH` (band INSUFFICIENT — honest, since
deep research was not run).

**Verified (tenant 7c8ddf9d, GB):**
- **28 unique GB FastMoss products** (30 lane signals → 2 converged across TOP_SELLING+MOST_PROMOTED;
  deduped on `fastmoss_product_id`, identity_basis `platform_id`, never SKU).
- Lane split NEW_LISTED 10 / TOP_SELLING 10 / MOST_PROMOTED 10; genuine sales/revenue in the lane
  evidence (e.g. Ski Mask 651 units/£3,248; Snowman 499/£4,985) + `source_freshness`.
- **28 Explorer cards** via `fn_ecommerce_workspace_intelligence`, **all 28 with a REFERENCE_ONLY GB
  cover image** (`fn_product_media_state` → `IMAGE_AVAILABLE`); `fn_product_discovery_lanes` returns
  the GB lanes and is **country-isolated** (same product returns 0 lanes under DE).
- `momentum`/`reviews`/`creators` are correctly **null** (no enrichment ran) — honest, not fabricated.
- Fresh observed timestamps (today); 2 iPhone-case candidates correctly held `BRANDED_OR_IP_REVIEW`.
- **DE preserved:** still 10 DE FastMoss cards / 19 products; DE lanes and covers untouched. Tenant &
  country isolation intact. Product Asset Lock intact (covers REFERENCE_ONLY, display-only).

**Images:** not a bug — the FastMoss ingest already persists covers to `product_image_assets`
(REFERENCE_ONLY); DE and now GB products all carry genuine covers. The earlier "no images" was the
stale pre-deploy build.

**Scheduling / going forward:** the 28 GB products are registered and **active** in
`monday_opportunity_registry` (32 active GB entries), so the weekly Monday refresh keeps their decisions
current with no extra provider spend. **Recurring NEW GB discovery** (fresh ranking pulls) still
depends on the **external dispatcher** posting GB — that scheduler lives outside this repo/DB
(configuration there to add GB on the weekly cadence is the one remaining, non-blocking item).

## GB Status: PASS
GB Product Explorer now shows 28 genuine, source-attributed FastMoss products with covers, lane badges
and lane evidence — no fabrication, DE and all other markets preserved. Remaining non-blocker: add GB
to the external discovery dispatcher so new GB products are pulled automatically each week.

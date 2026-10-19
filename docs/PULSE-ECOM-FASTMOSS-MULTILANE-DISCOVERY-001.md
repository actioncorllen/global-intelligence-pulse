# PULSE-ECOM-FASTMOSS-MULTILANE-DISCOVERY-001

**Upgraded FastMoss Product Discovery from one strategy (New Listed) to THREE distinct,
source-attributed discovery lanes — New Listed, Top Selling, Most Promoted — reusing the verified
ranking APIs and the existing research pipeline. Kalodata and every other lane are untouched. Verified
end-to-end live (DE); PASS. (Historical-Sales momentum + review/creator enrichment is the follow-on
unit PULSE-ECOM-FASTMOSS-MOMENTUM-ENRICH-001 / mig_308.)**

## What ships (`mig_307`, edge `fastmoss-discovery` v4)
- **Strategy registry** `fastmoss_discovery_strategy` (data-driven, 3 rows): each lane's api_path,
  orderby field, date granularity (day/month), per-strategy `enabled` flag (budget control) and
  `acquisition_method`.
- **Request builder** `fn_fastmoss_discovery_request(market, strategy)` (+ 1-arg NEW_LISTED wrapper for
  backward compatibility) builds the seed-free body per lane:
  - NEW_LISTED → `/product/v1/rank/newListed`, orderby `day3_units_sold`, date_info day = 3 days ago.
  - TOP_SELLING → `/product/v1/rank/topSelling`, orderby `gmv`, date_info month = last completed month.
  - MOST_PROMOTED → `/product/v1/rank/mostPromoted`, orderby `affiliate_count`, month.
  - Broad (all categories) by default; region/currency from `discovery_provider_market_config`.
- **Localized price parser** `fn_parse_localized_price` — TikTok-Shop `real_price` is a display string
  (e.g. `"28,95 €"`, `"440,97 €"`); parses EU/US formats, returns NULL (UNKNOWN) when it cannot.
- **Ingest** `fn_fastmoss_ingest_candidates_ml(..., p_strategy)` — per-strategy metric mapping
  (NEW_LISTED: day3_gmv/day3_units; TOP/PROMOTED: gmv/units; MOST_PROMOTED affiliate_count→creator_count),
  distinct per-lane evidence claim, **distinct signal dedup key** `fastmoss:<id>:<mkt>:<strategy>`,
  `candidate_acquisition_method` per lane, and an `extended.fastmoss_discovery_lanes[]` array. Published
  under a new name (the original 6-arg ingest is left intact) because a `DROP FUNCTION` on this Supabase
  project stalls on a `sql_drop` schema-reload event trigger.
- **Edge fn v4** runs all three lanes in one invocation (paced 400ms apart; `strategies[]` override for
  budget), so the external Monday discovery dispatcher is unchanged — it still posts
  `{market,user_id,candidate_limit}` once per market and now gets three lanes. Provider body `code 0` is
  the source of truth; one zero/unavailable lane never stops the others.

## Distinct + source-attributed, converging on identity
Lanes are kept distinct (acquisition_method, evidence claim, `discovery_lane` tag, distinct signal per
lane) but **converge on `fastmoss_product_id`**: a product found in several lanes is ONE product carrying
several distinct lane signals — never duplicated, never equated to a concrete SKU.

## Live end-to-end verification (DE, genuine captured candidates; zero extra provider/research spend)
Ran the real ingest on the genuine `topSelling` + `mostPromoted` DE rows (broker responses 172/173,
`code 0`, broad body confirmed valid live) with research auto-dispatch suppressed:
- **TOP_SELLING**: scanned 5, qualified 5, promoted 5 (4 new, Halara held `BRANDED_OR_IP_REVIEW`).
- **MOST_PROMOTED**: promoted 5 (4 new, 1 idempotent = same product as a top-selling row → converged).
- **Convergence**: "Halara Flex" → ONE product, `fastmoss_discovery_lanes=[MOST_PROMOTED, TOP_SELLING]`,
  **two** distinct `COMMERCE_PRODUCT_NATIVE` signals (one per lane), `identity_basis=platform_id`,
  price `28.95 EUR` (localized parse), 1 REFERENCE_ONLY cover.
- **New vs refreshed**: first pass all `new`; re-run → `idempotent=5` per lane (refreshed, not
  duplicated).
- Single-lane products attributed correctly (prices 440.97 / 14.99 / 204.99 / 235.30 EUR parsed),
  `source_store=fastmoss`, DE/EUR country-isolated.

Selftest `fn_fastmoss_multilane_selftest()` → **8/8 PASS** (3 request builders, price parser, TOP/PROMOTED
ingest attribution, lane dedup-key distinctness, unsupported-market fail-closed).

## Preserved
- **Identity safety**: `identity_basis='platform_id'`; branded/IP products held for review
  (`fn_is_branded_or_ip_sensitive`); a marketing title or a similar-looking supplier product is never
  equated to an exact SKU (concrete supplier identity stays Stage-2's job).
- **18-market eligibility** (FastMoss supports 20 markets in config; discovery runs per eligible market),
  **tenant isolation** (`user_id`), **multilingual** product-entity screening (`fn_is_product_native_entity`;
  handled German/Turkish/English titles in the live run), **source freshness** (`observed_at`/`launch_time`
  not treated as authoritative), **Product Asset Lock** (REFERENCE_ONLY covers only; no supplier assets),
  **provider budgets** (bounded pagesize 10; per-strategy enable flags; `strategies[]` override).
- **Kalodata** and the SEARCH/PROBLEM/ADVERTISING/SOCIAL lanes untouched. `/product/v1/search` never
  called.

## Schedules
- **New discovery**: external dispatcher → `fn_fastmoss_run_discovery(user, market, limit, anon_key)` →
  edge `fastmoss-discovery` v4 → now 3 lanes/market. Dispatcher code unchanged.
- **Weekly refresh**: `fn_run_monday_product_opportunity` (MONDAY_WEEKLY) over
  `monday_opportunity_registry` — unchanged; newly discovered candidates from all three lanes register
  there and are refreshed on the Monday cycle.

## Result: PASS (core multi-lane discovery). Follow-on (mig_308): country-specific Historical-Sales
momentum + review/creator enrichment (attach only where real records exist). No remaining launch blockers
for the discovery lanes; `/product/v1/search` stays 403 (external plan permission, not required here).

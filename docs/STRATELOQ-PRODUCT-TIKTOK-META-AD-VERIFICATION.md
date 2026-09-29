# STRATELOQ — Product → TikTok + Meta Ad Verification

**Unit:** Automatic Ad-Library Product Validation · **Status:** `PASS_WITH_SOURCE_LIMITATIONS`.

Every qualifying Product Opportunity is now verified automatically against **both**
advertising ecosystems (TikTok Commercial Content Ad Library + Meta Ad Library)
through the **existing** research-run pipeline, and the country-scoped, deduplicated
advertiser/creative evidence is exposed through one canonical read contract. No new
scoring engine; `fn_opportunity_score_v2` is untouched.

## Launch-critical defect found and fixed

Since TikTok flipped to `AVAILABLE` (mig_267, 2026-09-21), `fn_own_request_product_market_research`
began seeding the `SOCIAL_VIDEO` attempt as `NOT_SEARCHED` (dispatchable), but
`fn_research_dispatch` excluded `SOCIAL_VIDEO` and the auto-dispatch executor had no
TikTok branch. Because finalization requires **zero** `NOT_SEARCHED`/`SEARCHING`
attempts and nothing serviced SOCIAL_VIDEO, **every research run created after
2026-09-21 was stuck in `RESEARCHING`** (8 runs), freezing those markets' evaluations.
The entire opportunity pipeline had not finalized a run in over a week.

Fixes:
- **n8n executor** `Pulse — Research Auto-Dispatch Executor (013N)` (`QjYMzrCm1cDXxUS4`):
  added a parallel **TikTok branch** (Parse Manifest → TikTok Applicable? → token
  broker → `research/adlib/ad/query/` → Shape → Ingest via `fn_research_ingest_source`).
  It mirrors the standalone TikTok executor + the Meta branch, is gated on the
  manifest's `act_tiktok = DISPATCH`, and **always** posts to the ingest RPC so
  SOCIAL_VIDEO always reaches a terminal state (token/API failure → non-array error
  body → `SOURCE_FAILED`). Independent parallel branch; the 4 existing branches are
  untouched.
- **mig_332** `fn_research_dispatch`: add `SOCIAL_VIDEO` to the dispatchable set.
- **mig_333** `fn_research_ingest_source`: call `fn_research_maybe_finalize` at the
  end (idempotent; advisory-locked) so a run self-finalizes the moment its last
  attempt is terminal — regardless of provider order or external triggers. This is
  the robust cure for the stall (there is no cron/trigger/finalize workflow).

Reconcile: all 8 stalled runs finalized (7 `COMPLETE`, 1 `PARTIAL_SOURCE_FAILURE`
from an honest TikTok rate-limit under the reconcile burst — terminal, not stuck).
Zero `RESEARCHING` remain.

## Canonical read contract (mig_334)

- `fn_ad_coverage_class(market_state, attempt_state, advertisers)` — PURE classifier:
  per-source coverage + zero-vs-unknown. Distinguishes `ZERO_WITH_ADEQUATE_COVERAGE`
  (searched, 0 advertisers → real low-competition evidence) from
  `ADVERTISING_COMPETITION_UNKNOWN` (not searched), `SOURCE_UNSUPPORTED`, `SEARCH_FAILED`.
- `fn_product_ad_evidence(product, country)` — cross-platform summary:
  - `observed_advertisers` (distinct advertiser identity) and `observed_creatives`
    (distinct ad id) **per platform**, provenance never merged across TikTok/Meta;
  - `observed_sellers` intentionally `null` — **advertiser is not seller** (sellers
    come from marketplace evidence, not ad libraries);
  - persistence (`max_days_observed_active` / TikTok flight dates);
  - the product **identity state** (concept-level evidence never attaches to a SKU);
  - **country-scoped** counts only (signals stamped with the selected country);
    global momentum is never relabelled as this country's competition.
- `fn_ad_verification_selftest()` — 9/9 pass (dedup, creative dedup, zero-vs-unknown,
  failure≠zero, unsupported, observed, concept-only, identity-resolved).

## Field availability (actual authorized access)

| | Fields returned | Query expansion | Per-market support |
|---|---|---|---|
| **TikTok** Commercial Content Ad Library (`research.adlib.basic`) | `ad.id`, first/last shown date, `advertiser.business_name` — advertiser presence only, **no organic engagement, no creative text** | manifest `product_query` (+ existing seed derivation) | GLOBAL (country_code_list filter) |
| **Meta** Ad Library (Graph `ads_archive` v26.0) | `id`, `page_id`, `page_name`, delivery start/stop, `publisher_platforms`, `ad_creative_bodies`, `ad_snapshot_url` — advertiser page + creative + dates | `fn_generate_meta_ad_queries` (bounded, product-specific) | commercial all-ads = **EU/EEA + UK only** (elsewhere `SOURCE_UNSUPPORTED`) |

These are genuine source limitations, not defects: TikTok organic engagement needs the
separate Research API (approval-gated, out of scope here); Meta commercial coverage is
EU/UK. The engine degrades gracefully (missing → coverage/unknown, never a fabricated
or depressed score).

## Real tests

- **Nightlight GB** (IDENTITY_RESOLVED), fresh run `5b85ef56` COMPLETE:
  Meta `SEARCHED`/`OBSERVED` — **6 distinct advertisers / 29 creatives**, 10 days
  active; TikTok `SEARCHED_NO_EVIDENCE` → `ZERO_WITH_ADEQUATE_COVERAGE` (real query,
  honest 0). Combined = `ADVERTISING_ACTIVITY_OBSERVED`.
- **Humidifier GB** (CONCEPT_ONLY), fresh run `c1349b62` COMPLETE: concept-level ad
  research ran on both platforms; identity **stayed CONCEPT_ONLY** — never became a
  SKU from ad matches. Meta 4 advertisers / 5 creatives; TikTok ZERO_WITH_ADEQUATE_COVERAGE.
- **Country isolation:** nightlight IE returns `ADVERTISING_COMPETITION_UNKNOWN` (no
  run) — GB's 6/29 did **not** leak into IE.

## Regression

- Country isolation intact: nightlight US 79.5 / FR 79.5 / DE 73.2 / GB 78.2 (GB rose
  from 68.2 only because the fresh run found real Meta advertising evidence feeding
  `advertising_validation` — correct market-relative behavior; scorer logic unchanged).
- Product Identity, Commercial Asset Rights (humidifier `CUSTOMER_ASSET_REQUIRED`),
  Product Asset Lock, Gemini eligibility: unchanged.
- My Store unchanged (0 store/page/product writes this unit; nothing auto-published).
- Security advisors: **0 ERROR** (4 WARN / 1 INFO baseline). Tenant isolation intact
  (`fn_product_ad_evidence` rejects cross-tenant). No second scorer.
- `tiktok` SOCIAL_VIDEO signals persisted: 0 (no product-relevant ads matched → no
  fabrication).

## Advertiser vs advertiser vs seller (semantics preserved)

`OBSERVED_ADVERTISERS` (distinct advertiser identity, per platform), `OBSERVED_CREATIVES`
(distinct ad id), and `OBSERVED_SELLERS` (marketplace, separate — null here) are never
conflated. Same advertiser with N creatives = 1 advertiser / N creatives. Persistence is
"advertising activity observed", never "proven profitable".

## Lovable

Not required in this unit. The evidence is exposed via `fn_product_ad_evidence`; when the
Product Card / opportunity evidence UI should surface advertisers-observed /
creatives-observed / source coverage / checked-time / country, hand Lovable that verified
contract. No speculative frontend built before backend verification.

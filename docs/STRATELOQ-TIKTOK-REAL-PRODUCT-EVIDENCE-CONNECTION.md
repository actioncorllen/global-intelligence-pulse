# STRATELOQ — TikTok Real Product Evidence Connection

**Phase:** Social Evidence Ingestion · **Status after this unit:**
`EXTERNAL_APPROVAL_REQUIRED` (for the deep organic evidence the engine wants).

This unit inspected the existing TikTok architecture first (no new integration
built), re-proved the connected surface with a real authenticated bounded live
query today, and recorded the honest capability boundary. It changed no scoring,
RLS, Product Identity, Commercial Asset Rights, Product Asset Lock, or country
isolation.

## Two distinct TikTok surfaces (do not conflate)

| Surface | Developer product / scope | State | What it yields |
|---|---|---|---|
| **Commercial Content Ad Library** | Commercial Content API · `research.adlib.basic` | **CONNECTED_AND_INGESTING_REAL_DATA** (live-verified) | Advertiser *presence* only: `ad.id`, `first_shown_date`, `last_shown_date`, `advertiser.business_name`. Evidence families: `ADVERTISING_VALIDATION` / `CREATIVE_PATTERN`. |
| **Research API (organic)** | TikTok **Research API** · `research.data.*` | **EXTERNAL_APPROVAL_REQUIRED** (separate developer application + eligibility review) | Organic engagement (views/likes/comments/shares), buyer-intent comments, creator info, keyword/hashtag discovery, velocity (from ≥2 observations). |

The organic engagement the Product Opportunity Intelligence Engine most wants
(views/likes/comments/shares, engagement/view **velocity**, buyer-intent
comments, trend **discovery**) is **not** in the connected Ad Library surface —
it requires the separate Research API, which is approval-gated.

## Live re-verification (2026-09-29)

Existing executor `Pulse — Research Executor: TikTok (014B)` (n8n
`j4bOv9cuuzMbqN9B`), execution `30319`, manual, single bounded run:

- **Token** — `tiktok-commercial-token` Edge Function broker → HTTP 200,
  `ok:true`, Bearer, `expires_in` 7200. Secrets live **only** as Edge Function
  secrets (`TIKTOK_COMMERCIAL_CLIENT_KEY` / `TIKTOK_COMMERCIAL_CLIENT_SECRET`).
- **Ad Query** — `POST https://open.tiktokapis.com/v2/research/adlib/ad/query/`
  → HTTP 200, `error.code:"ok"`, **10 real ads** (search "kids nightlight
  projector", country GB). Every ad's advertiser was the generic aggregator
  `"Shopify (USA) Inc."`; the only fields returned were id + flight dates +
  advertiser name.
- **Ingest** — `fn_research_ingest_source('TIKTOK', …)` → all 10 `NO_MATCH` →
  `advertising_activity_state = NO_PRODUCT_MATCH` → `attempt_state =
  SEARCHED_NO_EVIDENCE` → **0 signals ingested**, `rows_tagged 0`.

Connectivity is proven and the pipeline reaches Supabase; evidence is honestly
absent because no product-relevant ads matched. **No signal fabricated.**

### Why the Ad Library rarely matches a specific product

`research.adlib.basic` returns the advertiser business name but **not** the ad
creative text, so product-level relevance can only be judged from the advertiser
name. Aggregator advertisers (e.g. "Shopify (USA) Inc.") therefore score
`NO_MATCH`. This is a genuine limitation of the available data, **not** a defect
to "fix" by loosening the relevance classifier (doing so would fabricate
coverage). It is recorded as a limitation, not worked around.

## Integrity guarantees preserved

- **Country isolation** — the ad-library `country_code_list` filter scopes each
  observation to the queried country; it is never relabelled as another market.
  Live nightlight market scores unchanged: US 79.5 / DE 73.2 / FR 79.5 / GB 68.2.
- **No minimum-view gate / market-relativity** — scorer untouched
  (`fn_opportunity_score_v2`); no new scorer created.
- **Velocity honesty** — velocity is derivable only from ≥2 timestamped
  observations of the same object; a single snapshot never implies acceleration.
- **Product Identity** — a TikTok keyword/topic hit is a concept, not a SKU;
  nightlight stays `IDENTITY_RESOLVED`, humidifier stays `CONCEPT_ONLY`.
- **Commercial Asset Rights / Product Asset Lock** — TikTok media is research/
  reference only; never auto-published, never fed to Gemini as rights-cleared.
  Humidifier rights stay `CUSTOMER_ASSET_REQUIRED`.
- **Store** — this unit wrote nothing to store/pages/products; My Store is
  byte-for-byte unchanged.

## Exact external action required from the founder (for organic evidence)

To unlock organic engagement / comments / velocity / trend discovery:

1. Go to the **TikTok for Developers** portal → your existing app →
   **Products** → add **Research API** (distinct from Commercial Content).
2. Apply for scope **`research.data.basic`**. Provide the research-use
   description; TikTok runs an **eligibility review / approval** (not instant).
3. On approval, the same secure pattern is reused: the Research API client
   credentials go **only** into an Edge Function secret / n8n credential (never
   the DB, repo, chat, or browser); a new bounded executor calls
   `/v2/research/video/query/` (+ `/comment/list/`, `/user/info/`) and posts
   normalized rows through the **existing** `fn_research_ingest_source`
   pipeline into the **existing** scorer. No second scoring engine.
4. Do **not** paste any Client Key/Secret into chat; install it through the
   established secret-management path.

Whether every desired metric is available is confirmed against live docs during
that build; `saves`, `watch/completion rate`, `repeat views`, and audience-market
(viewer-country) attribution are likely **UNSUPPORTED** even after approval.

## Meta (unchanged, documented per instruction)

- **Meta Ad Library** — real advertiser evidence ingesting (unchanged).
- **Meta organic** — publish/profile connection only; not ingesting engagement.
  To be addressed in the next unit, after TikTok.

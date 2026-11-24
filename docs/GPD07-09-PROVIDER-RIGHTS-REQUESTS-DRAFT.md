# GPD.07 (Social Attention) & GPD.09 (Advertiser Intelligence) — provider rights-request DRAFTS

**Status: DRAFT — NOT SENT.** Prepared 2026-11-24 (BE293 / Addendum 68). Do **not** send any external enquiry without explicit founder authorisation. These cover the genuinely-missing permissions for the licensed non-Kalodata routes; the **primary lowest-cost route needs no new rights** (see below).

## Why these are needed (rights state, 2026-11-24)
`catalogue_source_rights` — the only display-cleared source is **KALODATA** (analyse + display + display_derived + cache all TRUE). Every social source (**REDDIT, TIKTOK**) and the advertiser source (**META_AD_LIBRARY**) is `analyse_cleared=FALSE` — so Strateloq is **not even cleared to analyse** them, let alone display derived signals. Stored but withheld: Reddit `COMMUNITY_ATTENTION` 11 rows (10 products, tenant-private); Meta `ADVERTISING_ACTIVITY` 440 rows (11 products). Verified: on a product with 128 Meta ads + 1 Reddit row, the decision function marks `ADVERTISING_EMERGENCE` and `COMMUNITY_SOCIAL` as `NOT_AUTHORISED` (excluded, no raw count exposed).

**Distinction (directive item 4/5):** public API accessibility (Meta Ad Library, Reddit Data API, TikTok) is **not** analysis / commercial-SaaS-display / caching permission. A derived signal from an `analyse_cleared=FALSE` source is itself unlawful (deriving = analysing), so no "presence flag" workaround is available for these sources.

## PRIMARY route — no new rights required (preferred, lowest cost)
**Kalodata is already display-cleared** and is a TikTok-commerce analytics provider that exposes creator/video (social attention) data (capability already built: `kalodata-video-rank` / `kalodata-video-detail`). The Kalodata product schema already declares `creator_count`, `video_count`, `view_growth`, `share_growth`, `creator_growth`, `advertiser_count`, `ad_growth` — but all are currently **NULL** (the discovery endpoint did not populate them) and `kalodata_video_research` is empty. The lowest-cost next action for **GPD.07 social** is therefore a **founder-approved Kalodata ingest** (video-rank / creator metrics; existing cleared provider; Kalodata credits) mapped to a customer-facing **social-attention** signal, explicitly labelled *social attention, not verified demand*. For **GPD.09 advertiser**, first confirm (free question to Kalodata) whether `advertiser_count` is a retrievable Kalodata metric; if yes, the same cleared route applies. These need founder budget approval, **not** a new rights licence.

The drafts below are the FALLBACK, for cases the Kalodata route cannot cover (community-discussion attention via Reddit; a Meta-sourced advertiser signal if Kalodata does not expose advertiser counts).

---

## DRAFT 1 — Meta Ad Library (GPD.09 advertiser) — NOT SENT
**To:** Meta Ad Library / Meta Platforms data-licensing contact (recipient to be confirmed by founder)
**Subject:** Permission to analyse and display derived Ad Library advertiser-presence signals in an authenticated B2B SaaS tool

Strateloq Technologies operates an authenticated, paid B2B product-research SaaS. We query the Meta Ad Library API for competitive advertiser-**presence** observations (counts of distinct advertisers / active ads for a product category, with delivery dates). We request written confirmation of the following, separately from mere API accessibility:
1. The right to **analyse** Ad Library data to derive aggregate intelligence.
2. The right to **display** only **derived, aggregate** signals to our authenticated paying customers — for example "N distinct advertisers observed in {country}, {date window}" — with **no ad creative, no advertiser identities and no restricted content reproduced**.
3. The right to **cache/store** the derived aggregate signal for customer research continuity.
4. Any **attribution** we must render.

We will not reproduce ad creatives, advertiser names/pages or any restricted content; only a derived aggregate presence signal, labelled *advertiser presence / competition — not sales*. Please confirm the permitted scope and any licensing terms.

---

## DRAFT 2 — Reddit (GPD.07 social, community-discussion) — NOT SENT
**To:** Reddit Data API / developer-platform licensing contact (recipient to be confirmed by founder)
**Subject:** Permission to analyse and display derived community-attention signals in an authenticated B2B SaaS tool

Strateloq Technologies operates an authenticated, paid B2B product-research SaaS. We observe Reddit for community-**attention** signals about product categories (mention counts, thread/comment volume, recency). We request written confirmation of the following, separately from API accessibility and consistent with the Reddit Data API terms:
1. The right to **analyse** Reddit content to derive aggregate intelligence.
2. The right to **display** only **derived, aggregate** signals to our authenticated paying customers — for example "community attention: N mentions / recent discussion present in {window}" — labelled *attention, not verified demand*, with **no post content, usernames or restricted material reproduced**.
3. The right to **cache/store** the derived aggregate signal.
4. Any **attribution** we must render.

We will not reproduce posts, comments, usernames or any restricted content; only a derived aggregate attention signal. Please confirm the permitted scope and any licensing terms.

---

## TikTok — no separate request at this time
TikTok social attention is best obtained through the **already-cleared Kalodata** (TikTok-commerce analytics), so a separate TikTok developer/data licence is **not** requested now. Revisit only if a Kalodata ingest cannot supply the needed creator/video signal.

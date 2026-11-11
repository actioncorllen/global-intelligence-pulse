# Kalodata Open API — documented contracts for Strateloq
Prepared 2026-11-11. Extracted from indexed copies of Kalodata's own Open Center documentation, not from a live authenticated API call. Confirm against live docs before production deployment. Never put real API keys in this file.

## General
Base URL: `https://www.kalodata.com/openapi/v1`
Transport: HTTP POST, JSON, header `secret-key: <server-side secret>`.
Individual endpoints have different documented rate limits. Values below are request limits, NOT prices or point costs.
Use existing Strateloq `KALODATA_SECRET_KEY`, 9-market gate, reserved/refunded credit accounting, country isolation, REFERENCE_ONLY images, and production persisters. No deployment or billable requests authorised.

## 1. Product Detail
Source: https://www.kalodata.com/open-center/docs?endpoint=%2Fopenapi%2Fv1%2Ftiktok%2Fproduct%2Fdetail
`POST /openapi/v1/tiktok/product/detail`
Rate limit: 100 requests / 10 seconds.
Request required:
- `region`: string, country code, e.g. `US`
- `language`: string, e.g. `en-US`
- `currency`: string, e.g. `USD`
- `date_range`: string, e.g. `last7Day`
- `product_id`: string (keep identifiers as strings)
Request optional:
- `need_image`: integer, 0 (default), 1 (official URL), 2 (Kalodata-hosted image URL; documentation labels this a paid service).
Response: `success:boolean`, `data:object`, `message`, `debug`, `cached`, `code`.
Documented `data` fields: `product_id`, `product_region`, `product_name`, `product_shop_id`, `pri_cate_id`, `sec_cate_id`, `ter_cate_id`, `max_price`, `min_price`, `revenue`, `video_revenue`, `live_revenue`, `sales_volumn` [sic], `creator_number`, `video_number`, `live_number`, `delivery_type`, `shopping_mall_revenue`, `commission_rate`, `unit_price`, `product_review_count`, `launch_date`, `master_image_url`, `revenue_trend`, `product_description` (array of text/image blocks).
Note: The displayed API Debug fixed-request example additionally includes `need_extra:false`, but `need_extra` is not listed in this endpoint's request-parameter table. Do NOT assume it is a supported/required field.

Minimal documented request (illustrative ID, not for a paid call):
```json
{"region":"US","language":"en-US","currency":"USD","date_range":"last7Day","product_id":"1729587769570529799","need_image":1}
```

## 2. Video Ranking
Source: https://www.kalodata.com/open-center/docs?endpoint=%2Fopenapi%2Fv1%2Ftiktok%2Fvideo%2Frank
`POST /openapi/v1/tiktok/video/rank`
Rate limit: 10 requests / 10 seconds.
Request table marks required: `region` string, `language` string, `currency` string, `date_range` string, `sort_field` object (with optional `field` and `type`).
- Ranking date window is capped at 30 days; allowed `lastDay`, `last7Day`, `last30Day`, `yyyy-MM-dd~yyyy-MM-dd` span <=30 days, or `yyyy-MM`.
- `sort_field`: object, default `{ "field": "revenue", "type": "DESC" }`; documented sort names include `revenue`, `views`, `revenue_growth_rate`, `ads_roas`, `video_id`, `video_title`, `belonged_creator_id`, `belonged_creator_handle`.
Request optional: `rank_field` string (legacy), `asc` boolean (legacy), `page_size` integer <=100 default 10, `page_number` integer starting 1, `category_ids` array<string>, `shop_id` string, `creator_id` string, `product_id` string, `revenue_range` string, `followers_range` string, `ads_roas` string, `keyword` string, `is_ai_video` integer (0,1 or null), `views_range` string, `publish_date_range` string.
Response: `success:boolean`, `data:array<object>`, `message`, `debug`, `cached`, `code`.
Documented row fields: `video_id`, `video_title`, `belonged_creator_id`, `belonged_creator_handle`, `revenue`, `views`, `revenue_growth_rate`, `ads_roas`, `digg_count`, `share_count`, `comment_count`, `ad_revenue_ratio`, `ad_view_ratio`, `creator_debut`, `ad`, `ai_video`, `publish_date`.
**Critical association nuance**: Response does not document a per-video `product_id`. When ranking with a `product_id` filter, preserve the requested `{product_id, region}` as provenance for returned videos; do not infer an exclusive product association (videos can attach multiple products). Validate canonical identity on ingestion.
Minimal documented filtered request (illustrative ID):
```json
{"region":"US","language":"en-US","currency":"USD","date_range":"last7Day","sort_field":{"field":"revenue","type":"DESC"},"page_size":10,"page_number":1,"product_id":"1729587769570529799"}
```

## 3. Video Detail
Source: https://www.kalodata.com/open-center/docs?endpoint=%2Fopenapi%2Fv1%2Ftiktok%2Fvideo%2Fdetail
`POST /openapi/v1/tiktok/video/detail`
Rate limit: 100 requests / 10 seconds.
Request required: `region` string, `language` string, `currency` string, `date_range` string, `video_id` string.
Request optional: `need_extra` boolean (default/example false).
Response: `success:boolean`, `data:object`, `message`, `debug`, `cached`, `code`.
Documented `data` fields: `video_id`, `video_region`, `video_title`, `belonged_creator_id`, `belonged_creator_handle`, `product_number`, `revenue`, `sales_volumn` [sic], `views`, `video_gpm`, `ads_views`, `ads_roas`, `ads_period`, `digg_count`, `share_count`, `comment_count`, `ad_cpa`, `revenue_trend`, `ad`, `ad_view_ratio`, `duration`, `ai_video`.
**Critical association nuance**: `product_number` is a count, not a list of product IDs; do not fabricate linked-product fields.
Minimal documented request (illustrative ID):
```json
{"region":"US","language":"en-US","currency":"USD","date_range":"last7Day","video_id":"7404191282148511007","need_extra":false}
```

## 4. Video URL
Source: https://www.kalodata.com/open-center/docs?endpoint=%2Fopenapi%2Fv1%2Ftiktok%2Fvideo%2Furl
`POST /openapi/v1/tiktok/video/url`
Rate limit: 10 requests / 10 seconds.
Request required: `video_id` string ONLY (per endpoint-specific table).
Response: `success:boolean`, `data:{video_id:string,video_url:string,expires_at:string}`, plus `message`, `debug`, `cached`, `code`.
Signed CloudFront URL expires after 5 minutes. **Not permission to play, download, proxy or store videos for paying users.** Keep this endpoint unexposed/uninvoked until rights and any billable budget are approved.
Minimal documented request (illustrative ID):
```json
{"video_id":"7666138519575743757"}
```

## Controls and cautions
- The Kalodata docs' 'Mock Response' examples show `success:false`; examples are illustrative, not proof of successful live calls. Parse and handle errors/fail-closed.
- `sales_volumn` is the documented spelling; do not silently replace it with `sales_volume` when parsing upstream.
- Do not assume API region-parameter list guarantees live market coverage. Keep production 9-country gate until verified.
- Do not assume an API rate limit is the customer's credit allowance or per-call cost. Check the account pricing/consumption pages.
- Image display and storage permissions were confirmed in the user's Andrew Lin email; video permissions remain unanswered.
- Confirm any ambiguities in the authenticated Open Center pages before enabling live calls.
- Build contract-based mocks, no paid calls, no production writes or deployment.

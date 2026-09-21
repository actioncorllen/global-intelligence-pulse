# STRATELOQ-TIKTOK-AD-DATE-FILTER-014F.9

**FINAL VERDICT: `TIKTOK_AD_QUERY_FAILED`.**

The required `filters.ad_published_date_range` was added to the TikTok Commercial Content Ad Query using
the officially-documented `YYYYMMDD` `{min,max}` contract, generated dynamically from the execution date
(a recent 90-day window). Exactly **ONE** bounded live query was executed — no retry, no pagination, no
second search, no alternative window. The **token minted successfully** (broker `.trim()` hardening
holds) and the Token Success Gate passed. The Ad Query then returned **HTTP 400 `invalid_params`**: TikTok
rejects a `max` equal to today — it must be a date **strictly before today**. Because my dynamic window
used `max = today`, TikTok refused it. The Ad Query Success Gate correctly routed the 400 to its
dead-end branch, so **Normalize/Ingest did not run** and no HTTP-4xx was misclassified as evidence.
No synthetic data written; provider state unchanged.

---

## PHASE 1 — Verified official date contract (reported before implementation)
From the current TikTok Commercial Content **Ad Library / `research/adlib/ad/query`** documentation:
- **Object:** `filters.ad_published_date_range` — required object.
- **Required property names:** `min` and `max`.
- **Required date format:** **`YYYYMMDD`** (8 digits, no separators). NOT `YYYY-MM-DD`.
- **Documented example:** `"ad_published_date_range": { "min": "20221001", "max": "20230510" }`.
- **Lower boundary:** Commercial Content data availability begins ~**2022-10-01**; `min` cannot precede it.
- **Inclusivity:** boundaries are inclusive of the given days.
- **Upper boundary (NEWLY CONFIRMED EMPIRICALLY):** `max` must be a value **strictly before today's
  date**. This exact boundary was **not** stated in the prose I could verify in Phase 1; it was surfaced
  by TikTok's own validation on the single live call (message below). A window whose `max` equals the
  execution date is rejected.

## PHASE 2 — Implementation (n8n workflow `j4bOv9cuuzMbqN9B`, node "TikTok Ad Query")
`jsonBody` changed from `{ filters:{ search_term, country_code_list }, max_count }` to add the date range,
dynamically derived from `$now` (Luxon), formatted `YYYYMMDD`:
```
={{ JSON.stringify({
  filters: {
    search_term: $("Bounded Test Config").item.json.search_term,
    country_code_list: [$("Bounded Test Config").item.json.country_code],
    ad_published_date_range: {
      min: $now.minus({ days: 90 }).toFormat("yyyyLLdd"),
      max: $now.toFormat("yyyyLLdd")
    }
  },
  max_count: $("Bounded Test Config").item.json.max_count
}) }}
```
- Window is **dynamically generated from the execution date**, not hardcoded permanently.
- GB, `"kids nightlight projector"`, the corrected dotted `fields`
  (`ad.id,ad.first_shown_date,ad.last_shown_date,advertiser.business_name`), `max_count:20`, the Token
  Success Gate and the Ad Query Success Gate are all preserved unchanged.
- Credentials, token broker, and both success gates were **not** modified (per instruction).

## PHASE 3 — Offline verification (before the live call)
- Window resolved to **`min=20260623` … `max=20260921`** (today 2026-09-21): both 8-digit `YYYYMMDD`,
  recent, above the 2022-10-01 floor, `max` not in the future. Structurally valid against the documented
  schema.
- The one flaw the documentation did not expose — that `max` must be *before* today — could only be
  learned from the live validation.

## PHASE 4 — ONE bounded live execution (execution `30236`, manual)
| Step | Result |
|---|---|
| Token broker | **HTTP 200**, `ok:true`, access token minted (`expires_in` 7200). Secret trim holds. |
| Token Success Gate | **PASS** → Ad Query reached. |
| TikTok Ad Query | **HTTP 400** `invalid_params`. |
| Ad Query Success Gate | Routed to **FALSE / dead-end** (correct). |
| Normalize / Ingest | **Did not execute** (no runData) → 0 ads, 0 evidence. |

**Exact sanitized TikTok error** (`log_id` retained; no secret material):
> `code: "invalid_params"` — `` `filters.ad_published_date_range.max: 20260921` is invalid. Please
> provide a value before today's date. ``

This is the **only** live query. No retry, no second window, no pagination, no alternate search was run.

## Root cause & the one-line fix for the next unit
- **Root cause:** TikTok requires `ad_published_date_range.max < today` (exclusive of the current day).
  My dynamic window set `max = today`.
- **Minimal fix (deferred — would be a new/alternative window, which this unit forbids):** shift the
  upper bound back by at least one day, e.g. `max: $now.minus({ days: 1 }).toFormat("yyyyLLdd")` (and keep
  `min` = `max − 90d` or `$now.minus({ days: 91 })`). Format, floor, and both gates already conform. With
  that single change the same call structure should return ads (or an empty `data.ads` = truthful
  `CONNECTED_NO_EVIDENCE`).

## Security verification
- TikTok `client_key` / `client_secret` / `access_token` / `Authorization` header / service-role key:
  **never printed, returned, logged, persisted, or written to the repo or docs.** (The access token was
  visible only transiently inside n8n's own execution record; it is not reproduced here and was not stored
  anywhere by this unit.)
- No credential was changed. No Custom Auth. The Supabase broker was not modified. Only one authentication
  route (the broker) was used.
- Redaction (`redact()`) in the broker remains in force; the broker returns only `ok` + token fields.

## State: before == after (no synthetic evidence)
- TikTok provider capability: **`SOURCE_UNSUPPORTED`** (unchanged); evidence category `SOCIAL_VIDEO`.
- **0** TikTok signals in `trend_signals` (and none ingested) — no fabricated Commercial Content evidence.
- Nightlight GB (`e453eed4-3de4-4ed9-b889-1275c13c0dba`) PME **68.2** / coverage **0.78** / `WATCH` /
  `TRENDING_WATCH` — untouched. No score or decision forced.
- No Lovable, no Stripe, no Ecommerce scoring change, no migration, no other workflow change.
- Same-product gallery identity, storefront guard, other providers (eBay/Meta/DataForSEO/CJ/Reddit):
  untouched.

## Files / workflows / database changed
- **n8n** workflow `j4bOv9cuuzMbqN9B` "Pulse — Research Executor: TikTok (014B)" — node **TikTok Ad Query**
  `jsonBody` only: added `filters.ad_published_date_range` (dynamic `YYYYMMDD` 90-day window). No other
  node, credential, or gate changed.
- **No Supabase Edge Function change.** **No database change.** **No migration.**
- **No repo code change** other than this report.

## Commit
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`; see delivery message. (The functional change
lives in the n8n workflow, which is external to the repo; this report records it.)

---

**STOP.** Exactly one bounded live query was performed and it failed on the `max`-must-be-before-today
boundary. No retry, no alternative date window, no second search. Verdict `TIKTOK_AD_QUERY_FAILED`.

# STRATELOQ-TIKTOK-FINAL-DATE-BOUNDARY-014F.10

**FINAL VERDICT: `TIKTOK_CONNECTED_NO_EVIDENCE`.**

The single confirmed correction from 014F.9 was applied — `ad_published_date_range.max` must be **before
today** — and ONE final bounded live query was run. **TikTok Commercial Content is now live-connected:**
token minted, Ad Query returned **HTTP 200 with 10 real ads**, the full pipeline executed end-to-end. The
canonical relevance layer classified all 10 ads as **NO_MATCH** (generic "Shopify (USA) Inc." advertiser
ads, not the researched product) → `NO_PRODUCT_MATCH` → **SEARCHED_NO_EVIDENCE**, **0 signals ingested**
(no fabrication). Connectivity is proven, so TikTok was transitioned through the canonical provider
mechanism to **AVAILABLE**. No WPS score / coverage / decision moved.

---

## 1. Date window used
`ad_published_date_range = { min: "20260622", max: "20260920" }` — dynamically generated from the
execution date (2026-09-21): `min = $now.minus({days:91})`, `max = $now.minus({days:1})` (yesterday),
Luxon `toFormat("yyyyLLdd")`. Offline-verified: `max (20260920) < today`, `min (20260622) < max`, both
8-digit `YYYYMMDD`, both within the ~2022-10-01 data-availability floor. Only the date range changed vs
014F.9; search_term/country/fields/max_count and both success gates were preserved exactly.

## 2. Token success/failure
**SUCCESS.** Broker `tiktok-commercial-token` returned HTTP 200 `ok:true`, Bearer token, `expires_in`
7200. Token Success Gate passed. (`.trim()` credential hardening holds.)

## 3. Ad Query HTTP result
**HTTP 200**, body `error.code:"ok"`, `has_more:true`. Ad Query Success Gate evaluated TRUE → Normalize →
Ingest ran. Execution `30237` (manual, single run).

## 4. Ads returned
**10 ads** — all real TikTok Commercial Content records (ad ids, first/last shown dates, advertiser
`"Shopify (USA) Inc."`). This is genuine live data, not synthetic.

## 5. Evidence ingested
**0 signals.** The canonical relevance layer (`fn_ingest_tiktok_commercial_content` →
`fn_meta_ad_relevance`) scored all 10 ads **NO_MATCH** to "kids nightlight projector"
(`MATCHED:0, LIKELY_MATCH:0, AMBIGUOUS:0, NO_MATCH:10`), `advertising_activity_state:NO_PRODUCT_MATCH`,
`attempt_state:SEARCHED_NO_EVIDENCE`, `rows_tagged:0`. Verified in DB: 0 `SOCIAL_VIDEO_ADVERTISING`
signals, 0 TikTok signals. **No evidence fabricated.**

## 6. Provider before → after
`provider_capability_registry (TIKTOK, SOCIAL_VIDEO).availability`: **`SOURCE_UNSUPPORTED` →
`AVAILABLE`** (project_state `APPROVED_CREDENTIAL_SETUP_REQUIRED` → `CONNECTED_RUNTIME_AVAILABLE`), with
truthful live-verification metadata (10 ads returned, 0 product-relevant, SEARCHED_NO_EVIDENCE). This is
the earned flip deferred in mig_259/mig_261, now due because a real authenticated bounded request
succeeded. TikTok is now dispatchable in future research runs.

## 7. SOCIAL_VIDEO before → after
Attempt state `BLOCKED_EXTERNAL_ACCESS` (never live-run) → **`SEARCHED_NO_EVIDENCE`** for run
`ae239472…` (a genuine search that returned no product-relevant ads). Signals: **0 → 0** (no synthetic
evidence).

## 8. Coverage before → after
Nightlight GB coverage **0.78 → 0.78** (unchanged). No recompute was triggered (0 relevant evidence);
`product_market_evaluations.evaluation_ts` remains `2026-09-21 11:39:15Z`, prior to the 17:31 live query.

## 9. PME before → after
Nightlight GB market_opportunity_score **68.2 → 68.2**, evidence_confidence **HIGH → HIGH** (unchanged).

## 10. Product Decision before → after
Nightlight GB decision **WATCH → WATCH**, band **TRENDING_WATCH → TRENDING_WATCH** (68.2 < 70). No
decision was forced or moved.

## 11. Workspace TikTok state
The workspace now truthfully reflects TikTok as a **connected, AVAILABLE** SOCIAL_VIDEO provider whose
last bounded search found no product-relevant advertising for the nightlight in GB (SEARCHED_NO_EVIDENCE)
— connectivity proven, evidence honestly absent. No product tile gained fabricated social-video signals.

## 12. Security / regression result
- client_key / client_secret / access_token / Authorization / service-role key: **never exposed, logged,
  persisted, or committed.** Secrets live only as Edge Function secrets; the DB row holds capability
  metadata only (no values). Repo secret-scan clean.
- **Security advisors: 0 ERROR, 1 INFO, 4 WARN** — identical to the documented baseline (INFO =
  intended `product_image_assets` deny-all; 4 WARN baseline). No RLS/security regression (change was a
  data UPDATE + one `CREATE OR REPLACE` of an existing function).
- `fn_tiktok_executor_selftest`: **10/10 pass** (the one pre-connection assertion `availability_still_blocked`
  was reconciled to the post-connection truth `availability_now_available`).
- No credential work, no Custom Auth, no broad research, no Lovable, no Stripe. Broker, both success gates,
  fields, search term, country, max_count all unchanged. Other providers untouched.

## 13. Changes made
- **n8n** workflow `j4bOv9cuuzMbqN9B`, node **TikTok Ad Query** `jsonBody`: `ad_published_date_range.max`
  set to `$now.minus({days:1})` (yesterday), `min` to `$now.minus({days:91})` — the single confirmed
  date-boundary fix. Nothing else in the workflow changed.
- **`supabase/migrations/mig_267_tiktok_connected_available.sql`** — canonical provider transition
  `SOURCE_UNSUPPORTED → AVAILABLE` + truthful live-verification metadata. No signal insert, no scoring
  change, no credential value.
- **`supabase/migrations/mig_268_tiktok_selftest_reconcile_available.sql`** — reconcile the one stale
  selftest assertion to the connected truth. No behavioral change.

## 14. Commit
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`; see delivery message.

## 15. FINAL VERDICT
`TIKTOK_CONNECTED_NO_EVIDENCE` — TikTok Commercial Content is live-connected and AVAILABLE (proven by a
real HTTP 200 Ad Query returning 10 ads through the full pipeline); the bounded GB "kids nightlight
projector" search returned no product-relevant ads, so evidence is truthfully absent (0 signals, no
fabrication) and no score/decision moved.

---

**STOP.** Exactly one final bounded query was performed. No retry, no pagination, no second query. TikTok
is connected; the nightlight GB search legitimately found no product-relevant social-video advertising.
Verdict `TIKTOK_CONNECTED_NO_EVIDENCE`.

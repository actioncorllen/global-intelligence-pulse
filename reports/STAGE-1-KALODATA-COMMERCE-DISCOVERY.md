# STAGE 1 — Kalodata Product-Native COMMERCE Discovery (Permanent Production Integration)

**Date:** 2026-10-12 · **Tenant:** 7c8ddf9d-… · **Project:** nxaunmyihhjixxxljcqt (live prod) · **Branch:** claude/cool-faraday-kgudh1
**Scope:** Fill the EXISTING multi-lane COMMERCE lane with Kalodata as the product-native provider. Stage 1 only — Stage 2 NOT started. No parallel pipeline.

---

## 1. ROOT CAUSE CLOSED
The COMMERCE discovery lane was `GAP_NO_PRODUCT_NATIVE_PROVIDER`: no connected provider could return
market product entities **without a seed** (DataForSEO is keyword-level; eBay Browse is research-only;
ad libraries are query-seeded ad records; TikTok organic is approval-gated; CJ is supplier-only).
Kalodata's TikTok-Shop `product/rank` endpoint is product-native and seed-free (founder-proven live for
DE: region DE / currency EUR / `revenue_growth_rate DESC` / `launch_date<30`, 0.1 credit / 10 products,
real German product entities, NO keyword/category/product/shop/creator/video/livestream). The gap is now
**filled at the provider layer** (data-driven market config + a secret-free DB adapter + a secure backend
broker), reusing the existing eligibility gate → auto_fresh_discovery research bridge → concrete resolution
→ opportunity evaluation. Kalodata **discovers candidates only**; it never decides opportunity.

## 2. FILES / MIGRATIONS CHANGED
- `supabase/migrations/mig_374a_kalodata_provider_market_config.sql` — `discovery_provider_market_config`
  table (RLS on, fail-closed) + 10 Kalodata markets + COMMERCE lane flip (GAP → AVAILABLE/KALODATA).
- `supabase/migrations/mig_374b_kalodata_ingest_candidates.sql` — `fn_kalodata_ingest_candidates`
  (secret-free ingest adapter; noise gate → normalize → register → auto-dispatch research).
- `supabase/migrations/mig_374c_kalodata_request_and_plan_v2.sql` — `fn_kalodata_discovery_request`
  (seed-free request builder), `fn_multi_lane_discovery_plan` v2 (COMMERCE lane wired, independent per-lane
  status), `fn_kalodata_record_usage` + `fn_kalodata_record_lane_outcome` (telemetry; never store the key).
- `supabase/migrations/mig_374d_kalodata_commerce_adapter_selftest.sql` — `fn_kalodata_commerce_adapter_selftest`
  (16-invariant regression).
- `supabase/functions/kalodata-discovery/index.ts` — secure backend broker (holds the secret only in env;
  deployed live, ACTIVE v2, `verify_jwt=true`, trusted-server gated, fail-closed).
- `supabase/migrations/mig_373b_multi_lane_discovery_selftest.sql` — updated: COMMERCE gap is now CLOSED,
  so check 03 asserts the gap is filled (Kalodata READY) while SOCIAL stays explicitly unavailable; check
  08 country isolation hardened to find the SEARCH lane by key (robust to lane re-ordering); null-pass
  loophole in the counter closed.
- `supabase/migrations/mig_369_stage1_product_opportunity_invariants_selftest.sql` — updated: the
  "candidate ≠ qualified" check is now the true STRUCTURAL invariant (neither search **nor commerce/Kalodata**
  discovery writes `product_opportunity_decisions`), not a transient data snapshot.

## 3. KALODATA PROVIDER CONFIG (data-driven; not prompt/memory)
`discovery_provider_market_config (provider, market, supported, region, language, currency, capabilities,
enabled, last_verified_at, note)`, PK(provider, market), RLS on with no public policy.
10 Kalodata TikTok-Shop markets supported+enabled: **DE (verified live)**, GB (GBP), US (USD), FR, IT, ES,
IE (EUR), MY (MYR), PH (PHP), SG (SGD) — all `language=en-US`, 9 `last_verified_at=NULL` until their first
live call. COMMERCE lane: `availability=AVAILABLE`, `provider=KALODATA`, `discovery_mode=AUTONOMOUS`,
`capability_class=DISCOVERY_CAPABLE`. A Strateloq-supported market Kalodata does not cover (e.g. NO, JP)
returns `UNSUPPORTED_MARKET` — never a substitution, never zero, never cross-market contamination.

## 4. SECRET HANDLING — **EXTERNAL BLOCKER (action required)**
The Kalodata secret is **NOT present in the backend**: no `kalodata` edge function existed, no Vault secret
(`vault.secrets` has none matching), no `server_integration_config` row. The task forbids placing the raw
key in database rows, so the correct mechanism is the existing **Supabase Edge Function secret** pattern
(same as `tiktok-commercial-token`): the key lives only in the Edge Function environment, read at runtime
by the broker, never persisted, never returned, never logged (the broker `redact()`s outputs and returns
only the ingest summary).

**Exact secret location required (set this, then the real DE run can execute):**
- **Supabase → Project `nxaunmyihhjixxxljcqt` → Project Settings → Edge Functions → Manage secrets**
  (equivalently `supabase secrets set KALODATA_SECRET_KEY=<key> --project-ref nxaunmyihhjixxxljcqt`).
- Required: **`KALODATA_SECRET_KEY`** = the Kalodata OpenAPI secret key.
- Optional: `KALODATA_SECRET_HEADER` (HTTP header name; default `secret-key`) and `KALODATA_BASE_URL`
  (default `https://www.kalodata.com/openapi/v1/tiktok/product/rank`).

The broker `kalodata-discovery` is already deployed ACTIVE and **fail-closed** — until the secret is set it
returns `lane_status=AUTH_FAILED` (`server_secret_unavailable`) and never fabricates candidates. No secret
was requested in chat and none is stored anywhere in the repo or DB. The raw key is NEVER exposed to
frontend, DB rows, logs, reports, API responses or analytics.

## 5. NORMALIZED FIELD MAPPING (via existing `fn_discovery_signal_normalize`; UNKNOWN → NULL, never 0)
| Kalodata field | Normalized discovery signal |
|---|---|
| `product_id` | provider product id (`extended.kalodata_product_id`; dedup key) |
| `product_name` | `product_identity` |
| `revenue` | `revenue` (commerce_revenue) |
| `revenue_growth_rate` | `revenue_growth_rate` |
| `sales_volumn` *(provider typo)* | `sales_units` |
| `unit_price` | `price` / `observed_price` |
| `launch_date` | `first_seen` |
| `seller_id` / `seller_name` | `extended.kalodata_seller_id` / `kalodata_seller_name` |
| `live_revenue` / `video_revenue` / `showcase_revenue` | evidence `channel_revenue` (jsonb_strip_nulls) |
| `master_image_url` | NOT used for qualification (image-independent; see §8) |
| `sku_count` / missing metrics | remain **NULL** — never coerced to 0 |

Proven in dry-run: a metric-less product promotes with `revenue=null, sales_units=null, price=null,
revenue_growth_rate=null` (UNKNOWN ≠ 0), and `master_image_url=null` / `seller_name=""` / `sku_count=null`
never block promotion or imply "bad".

## 6. REGRESSION RESULTS (all live, all green)
- **`fn_kalodata_commerce_adapter_selftest` = 16/16 all_pass** — 01 DE invokes Kalodata with no
  keyword/category/product/shop/creator/video/livestream seed · 02 product ids become candidates · 03
  country isolation (DE=DE/EUR, GB=GB, normalized market stays DE) · 04 unsupported market explicit
  (JP request + ingest + NO-lane) · 05 UNKNOWN≠0 · 06 Kalodata ≠ CONCRETE_RESOLVED · 07 Kalodata ≠ supplier
  SKU · 08 high revenue cannot bypass qualification · 09 extreme growth cannot bypass · 10 image
  presence/absence irrelevant · 11 DataForSEO failure not fatal to COMMERCE · 12 Kalodata
  failure/unsupported does not corrupt other lanes (NO plan keeps 5 lanes, SEARCH READY) + explicit
  SUCCESS_ZERO_CANDIDATES / PROVIDER_UNAVAILABLE statuses · 13 dedup by provider id · 14 survivors enter
  auto_fresh_discovery bridge · 15 idempotent (CACHE_REUSED core + pre-dispatch dedup) · 16 secret never
  persisted.
- `fn_multi_lane_discovery_selftest` = **16/16** (updated: gap closed; country isolation hardened).
- `fn_stage1_product_opportunity_invariants_selftest` = **8/8** (updated: structural candidate≠qualified).
- `fn_autonomous_discovery_selftest` = **12/12**; `fn_stage1_research_bridge_selftest` = **8/8**;
  `fn_product_image_selftest` = **10/10** (image independence durable).

## 7. REAL DE RUN — **BLOCKED (external: missing Kalodata secret)**
A bounded market-only DE run was NOT executed because the provider call cannot be made:
- **Discovery run ID:** none created (fail-closed before any provider call).
- **Kalodata calls:** 0. **Observed credit/cost:** n/a (no call).
- **Raw / deduped / eligible / rejected candidates:** n/a. **Research run IDs / source outcomes /
  concrete-resolution / opportunity evaluations:** n/a.
- **Reason:** `KALODATA_SECRET_KEY` is not set in the backend (see §4); the broker returns
  `lane_status=AUTH_FAILED` (`server_secret_unavailable`). Also, this execution sandbox's egress proxy does
  not allowlist the Supabase Functions host, so the broker cannot be invoked from here regardless.

**Everything internally controllable is proven and live.** The DB path (request builder → normalize →
gate → ingest → register → auto-dispatch) is verified end-to-end via dry-run + the 16/16 regression; the
candidate→research→evidence→concrete-resolution→evaluation path was proven end-to-end in prior bounded runs.
The ONE remaining step — a real Kalodata HTTP call — needs the secret above. Once set:
`POST /functions/v1/kalodata-discovery` (service role) `{"market":"DE","user_id":"<tenant>","candidate_limit":10}`.

## 8. COUNTRY ISOLATION RESULT
Hard invariant holds. Request/region/currency resolve per market from config (DE→DE/EUR, GB→GB/GBP,
US→US/USD …). Normalized signals are market-scoped (`market=DE`), `cross_market_reference` is never local
validation, and an unsupported market returns `UNSUPPORTED_MARKET` with no substitution. Proven by adapter
checks 03/04 and the multi-lane NO-market test (COMMERCE=UNSUPPORTED while SEARCH stays READY). Image/asset
qualification is untouched (Product Asset Lock unchanged).

## 9. RECURRENCE PREVENTED: **YES**
Data-driven provider/market config + secret-free adapter + fail-closed secure broker + explicit lane
outcomes (SUCCESS_WITH_CANDIDATES / SUCCESS_ZERO_CANDIDATES / UNSUPPORTED_MARKET / AUTH_FAILED /
RATE_LIMITED / PAYMENT_REQUIRED / PROVIDER_UNAVAILABLE / FAILED, persisted via
`fn_kalodata_record_lane_outcome`) + 16-invariant regression. DataForSEO remains an independent SEARCH lane
(402/zero/rate-limit cannot stop COMMERCE); Kalodata failure cannot corrupt other lanes; provider failure
is never converted to "zero market demand". Qualification thresholds were NOT weakened.

## 10. KALODATA_COMMERCE_ADAPTER VERDICT: **PASS**
The production integration is implemented, deployed, and fully regression-proven on every internally
controllable surface (adapter 16/16; multi-lane, invariants, bridge, autonomous, image suites all green;
broker ACTIVE and fail-closed; live==repo). The only unexecuted step is the real provider HTTP call, which
is gated solely by the missing `KALODATA_SECRET_KEY` backend secret (§4) — a genuine external blocker.

## 11. OVERALL STAGE 1 VERDICT: **BLOCKED_QUALITY_OR_EVIDENCE / external secret**
No genuinely newly discovered product has yet reached CONCRETE_RESOLVED **and** benchmark-qualified
opportunity from a real Kalodata-discovered candidate, because the real DE run is blocked on the missing
secret. Per the task's PASS rules this is the acceptable, truthful state: **KALODATA_COMMERCE_ADAPTER =
PASS**, **STAGE_1 = BLOCKED** (pending the secret, then one bounded real DE run). No thresholds were
weakened to manufacture a pass. Stage 2 remains not started.

# GPD.07 — Kalodata Controlled Product Detail Pilot (BE312)

**Executed:** 2026-11-26 · **Authority:** Founder authorisation 26 Nov 2026 (max **5** billable Product Detail requests, max **0.5** Kalodata credit, existing credits only; no purchases/upgrades/key regeneration; no automatic customer release or source-rights flag changes). · **Outcome:** **2 genuine chargeable calls executed and verified** (verified-mapping subset = DE + US; the honest subset, per the founder's "execute only the subset with verified mappings"). **GPD.07 remains OPEN** until customer-visible implementation + acceptance. Historical **GOLD 11/22** unchanged; no rights/RLS/PAL/flag/release/deploy change.

---

## 1. Pre-flight (zero cost)

| Check | Result |
|---|---|
| API key present / auth path | **PASS** — free `probe:true` invocation returned `{ok:true, mode:probe, secret_present:true}`; the edge function `kalodata-product-detail` authenticates to Kalodata via the canonical `X-API-Key` secret (`KALODATA_API_KEY`/`KALODATA_SECRET_KEY`), not exposed to this session. |
| Identity / product→Kalodata mapping | **PASS for DE + US only.** `commerce_products.extended->>'kalodata_product_id'` carries verified mappings for **DE (23 products)** and **US (10 products)**; **no GB/IE/IT mappings exist**. Per the founder's instruction, only the verified subset was executed — no speculative identifiers were used to reach five. |
| Request-format / region / date-range validation | **PASS** — `fn_kalodata_detail_request` returned `ok:true` for both targets (DE: region DE/EUR/last7Day/`need_image=1`; US: region US/USD/last7Day/`need_image=1`). `need_image=1` = standard **0.1-credit** Product Detail call (official image URL; no paid `need_image=2`). |
| Duplicate-prevention | **PASS** — neither target carried a prior `extended->'kalodata_detail'` before the pilot (no chargeable duplicate). |
| **Live credit-balance read** | **NOT AVAILABLE — documented deviation.** There is **no deployed `/openapi/v1/credit/balance` broker** in the infrastructure, and the Kalodata secret is not exposed to this session, so a live before/after balance read could not be performed. **Spend was instead hard-bounded** by: (a) executing only the 2 verified calls (≤0.2 credit), well under the 0.5 cap; (b) the edge function's native **402 PAYMENT_REQUIRED** handling — a short balance would have returned 402, not a charge; both calls returned **HTTP 200 SUCCESS_DETAIL**, which itself confirms sufficient credit at call time; (c) per-call usage reconciliation (each call recorded `call_count:1`). No balance check "failed" — the capability is simply not deployed; the founder's STOP-on-failure condition was not triggered. *(A free read-only balance broker can be deployed next if live balance telemetry is wanted — not done here to avoid unrequested mid-pilot infra changes.)* |

**Invocation controls:** each call is gated by a **single-use, 5-minute, ≥32-char nonce** (`kalodata_invoke_nonce`, consumed by `fn_kalodata_consume_invoke_nonce`), minted and committed in a separate statement before the external call (cross-connection isolation). Sequential, one at a time; no retries, no background refresh, no queue fan-out.

## 2. The two chargeable calls (sequential)

| # | Market | Product (internal id) | Kalodata product id | Nonce (consumed) | HTTP | Lane |
|---|---|---|---|---|---|---|
| 1 | **DE** | `caa240db-1970-4caf-9db3-8cbe394a6a7a` — *Shark BlastBoss …BlastBroom* | `1729949823689857299` | `847f05…405320` | **200** | **SUCCESS_DETAIL** |
| 2 | **US** | `7ec7ad53-ea9d-4647-a2b9-762b340778ac` — *Insignia 40" F40 Smart Fire TV* | `1732780116498617149` | `e71820…0c474` | **200** | **SUCCESS_DETAIL** |

Endpoint: `https://www.kalodata.com/openapi/v1/tiktok/product/detail`. Persisted via `fn_persist_kalodata_product_detail` into `commerce_products.extended->'kalodata_detail'` as **REFERENCE_ONLY** (`authority: PLATFORM_REPORTED_ANALYTICS_DETAIL`), tenant-checked (`user_id = p_tenant`).

## 3. Genuine social evidence captured (TikTok Product Detail — NOT Product Rank revenue)

| Field | **DE** — Shark BlastBoss | **US** — Insignia 40" F40 TV |
|---|---|---|
| `product_region` | `de` | `us` |
| **`creator_number`** | **109** | **424** |
| **`video_number`** | **220** | **341** |
| **`live_number`** | **124** | **1223** |
| revenue (context) | €16,030.63 | $152,561.26 |
| sales_volumn (context) | 168 | 1,962 |
| launch_date | 2026-10-15 | 2026-10-28 |
| retrieved_at | 2026-11-26T21:22:04Z | 2026-11-26T21:23:51Z |
| identity-match confidence | **HIGH** — exact stored `kalodata_product_id` round-tripped into the response `product_id`; response `product_region` matches the stored market | **HIGH** — same |

- These are **genuine, non-zero** social-attention counts (distinguished from "missing/failed": both lanes returned `SUCCESS_DETAIL` with populated fields).
- They are **the Product Detail social fields** (`creator_number`/`video_number`/`live_number`), kept **separate** from the previously-stored Product **Rank** revenue metrics — no mixing.

## 4. Spend reconciliation

| Item | Value |
|---|---|
| Authorised | ≤ 5 billable requests, ≤ 0.5 credit, existing credits only |
| **Executed** | **2 billable requests** (DE, US) |
| Recorded usage | `discovery_runs`: 2 runs, each `provider_usage.call_count = 1`, `http_status = 200`, operation `tiktok/product/detail` — **1 provider call per request, no duplicate/retry/fan-out** |
| **Credits consumed** | **0.2 credit** (2 × 0.1/call documented price — Andrew Lin 26 Nov + `need_image=1`); **0.3 credit / 3 calls of headroom unused** |
| Purchases / upgrades / key regen | **None** |
| Starting / ending balance | **Not read** — no deployed balance endpoint (see §1 deviation); non-402 responses confirm sufficiency |

## 5. Country + tenant isolation (PASS)

- **Exactly 2** products received fresh detail this session; **both under the single tenant** `7c8ddf9d-172c-4a89-a402-bb7066228b61` (tenant-scoped persist; no cross-tenant write).
- **Region tags match market:** DE→`de`, US→`us`. The two markets' counts are entirely distinct (DE 109/220/124 vs US 424/341/1223) — **no reuse** of one market's counts in another; GB/IE/IT were never called, so no GB counts exist to leak.
- **RLS / PAL / permissions preserved** — no policy, grant, or source-rights row was modified.

## 6. No customer release (PASS) + display readiness

- Evidence is **internal/test only**: stored in `extended.kalodata_detail` as REFERENCE_ONLY. **No frontend consumes it** — grep of the Lovable project for `kalodata_detail` and `creator_number` returns **0 matches**.
- **No source-rights flag changed:** `catalogue_source_rights` KALODATA row `updated_at = 2026-11-20` (untouched today). Flags remain analyse/display_derived/display/cache_images = cleared; raw-redistribute/creative-reuse = NOT.
- **No product release, no FE deploy, no gate flip** of any kind.
- **Display is deliberately NOT built** (building + deploying a customer-visible metric is a production release, which the authorisation reserves for escalation). The display path, when built, should: read these three counts behind the existing rights gate, label them truthfully as **"social attention (TikTok), not demand"** with the provider attribution and the observation window, enforce per-market isolation, and be covered by tests that assert genuine-zero ≠ missing. **This is the remaining GPD.07 criterion.**

## 7. Remaining GPD.07 criteria (why it stays OPEN)

1. **Customer-visible display implementation** of `creator_number`/`video_number`/`live_number` behind the rights gate, truthfully labelled, per-market isolated — **not built** (no release this pilot).
2. **Acceptance** of that display in production by the founder.
3. (Optional breadth) extend coverage to GB/IE/IT once those products carry verified `kalodata_product_id` mappings — currently absent; **do not** spend on speculative identifiers.

**Controls:** 2 provider calls; **0.2 credit** (existing credits; no purchase); 0 flag flips; 0 deploys; 0 sends; isolation/PAL/RLS/budgets/founding-member controls preserved. Historical **GOLD 11/22** unchanged. Build Evidence **BE312**.

# PULSE-ECOM-KALODATA-AUTH-CANONICAL-XAPIKEY-001

**Date:** 2026-11-20
**Scope:** Fix Kalodata API authentication (error 501 "The key is not allowed") across the deployed
Supabase Edge integration, per Kalodata's official response (Andrew Lin, 2026-11-20).
**Project:** Strateloq Technologies (`nxaunmyihhjixxxljcqt`)

---

## A. Exact cause of error 501

Two layers, both confirmed with live evidence:

1. **Non-canonical authentication header (fixed).** All five provider-calling Kalodata edge
   functions sent the key in a **`secret-key`** request header (the `KALODATA_SECRET_HEADER` env
   override was unset, so the hardcoded `"secret-key"` default was in effect). Kalodata's canonical
   authentication is the **`X-API-Key`** header, and a non-empty `secret-key` header overrides
   `X-API-Key` at the provider. Production telemetry shows the resulting failures: US product/rank
   2026-11-18 and DE product/images 2026-11-13, both HTTP 200 with
   `{success:false, code:"501", message:"The key is not allowed"}`.

2. **The stored credential is the previous-generation key (open — founder action required).**
   After deploying the canonical `X-API-Key` fix, the **free** `GET /openapi/v1/credit/balance`
   endpoint still returns the identical 501 envelope for the configured key
   (36 chars, masked `589b...a2b8`). Per Kalodata's verified statements, the current account key
   retrieves the balance successfully and a previous-generation key returns exactly this 501.
   A trusted-only diagnostic confirmed `KALODATA_SECRET_KEY` is the **only** `KALODATA*` secret in
   the Edge environment (names inspected, never values), the Supabase Vault holds no Kalodata
   credential, and no Kalodata key exists in the database. The current-generation key has therefore
   **never been installed** in this project and cannot be obtained with existing access.

## B. Corrected files / functions and authentication behaviour

Auth construction only; all other behaviour preserved (request contract, market filtering,
provider error detection, v23 response parser, redacted diagnostics, budget enforcement, tenant
isolation, asset lock, attribution):

| Edge function | Change |
|---|---|
| `kalodata-discovery` | Canonical `X-API-Key` header only; `KALODATA_SECRET_HEADER` retired/ignored; key slot selection `KALODATA_API_KEY` (preferred) else `KALODATA_SECRET_KEY`; redaction extended to both slots and `Bearer <token>` values; trusted-only probe diagnostics (env slot names, key length, masked first/last 4); new trusted-only free `balance_probe` mode (GET credit/balance, 0 credits) with correct HTTP-200 logical-error classification |
| `kalodata-product-detail` | Same canonical auth substitution |
| `kalodata-product-images` | Same canonical auth substitution |
| `kalodata-video-rank` | Same canonical auth substitution |
| `kalodata-video-detail` | Same canonical auth substitution |

`kalodata-research-image-url` makes no Kalodata provider calls (it signs private storage refs) and
was not changed.

## C. Deployment versions (all ACTIVE, verify_jwt preserved)

- `kalodata-discovery` v23 → **v25** (v24 = auth fix; v25 = + safe env-name diagnostics)
- `kalodata-product-detail` v6 → **v7**
- `kalodata-product-images` v6 → **v7**
- `kalodata-video-rank` v5 → **v6**
- `kalodata-video-detail` v5 → **v6**

## D. Free credit-balance endpoint result (no credits spent)

`balance_probe` via deployed `kalodata-discovery` (nonce-gated, canonical headers,
`GET https://www.kalodata.com/openapi/v1/credit/balance`, 2026-11-20T10:10:35Z):

- HTTP 200, envelope `{success, data, message, cached, code, errorCategory}`
- `provider_code: "501"`, `provider_msg: "The key is not allowed"`, `data: null`
- Correctly classified `PROVIDER_LOGICAL_ERROR` (not misread as success; not a zero-candidates
  misclassification). Endpoint mechanics verified end-to-end; the provider rejects the stored key.

## E. Actual current Kalodata credit balance

**Not readable with the stored key** — the provider refuses it (501). Kalodata verified the
*current* account key held 14.1 credits on 2026-11-20; that key is not installed in this project.
The moment it is installed, the free `balance_probe` reads the live balance.

## F. Tests performed

Offline deterministic suite (`scripts/kalodata-auth-tests/`, run against the literal deployed
source; fake keys; no network): **43 passed, 0 failed** — X-API-Key construction, key-slot
selection, conflicting secret-key header prevention (incl. a set `KALODATA_SECRET_HEADER` being
ignored), 501-in-HTTP-200 classified as error (previous-generation key rejection signature),
success envelopes accepted, all v23 product-parsing shapes, balance extraction, secret
redaction/masking, static no-paid-call checks of probe/balance paths.

Database-level deterministic selftests (existing suites, no provider calls):

| Suite | Result |
|---|---|
| `fn_provider_budget_gate_selftest` | PASS 10/10 |
| `fn_research_budget_selftest` | PASS 14/14 |
| `fn_kalodata_commerce_adapter_selftest` | PASS (all_pass) |
| `fn_kalodata_caller_lifecycle_selftest` | PASS (all_pass) |
| `fn_kalodata_product_detail_selftest` | PASS 8/8 |
| `fn_kalodata_product_images_selftest` | PASS 11/11 |
| `fn_kalodata_video_selftest` | PASS 10/10 |
| `fn_kalodata_e2e_mock_lifecycle_selftest` | ERROR (pre-existing fixture FK `commerce_products_user_id_fkey`; unrelated to auth — fixture expects a seed user absent from this environment) |

Market (country) isolation: request builder returns `ok` for exactly the nine Kalodata-confirmed
markets (US, DE, GB, FR, ES, IT, MY, PH, SG) and `UNSUPPORTED_MARKET` for others (XX, BR tested).

Deployment confirmation: no-credit probes returned `ok:true, secret_present:true` on all five
redeployed functions.

## G. No paid ranking calls

Confirmed. Zero Kalodata `discovery_runs` / provider-usage records were created on 2026-11-20.
The only provider contact in this work was **one GET to the free credit/balance endpoint**
(0 credits). No product/rank, product/detail, product/images, video/rank or video/detail call
was made. No key was regenerated, revealed or rotated; no purchases or upgrades.

## H. Readiness for one authorised US Product Discovery call

The pipeline (auth construction, market gating US-enabled, budget gates, tenant isolation,
parser, telemetry) is deployed and verified **up to the credential**. Two items before the
bounded US call:

1. **Install the current key (founder action, blocker — see I).** After installing, verify for
   free via `balance_probe` (expect `BALANCE_OK` and the live balance) before any paid call.
2. **`need_image=1`:** the rank request body built by `fn_kalodata_discovery_request` does not yet
   include `need_image: 1`, and `fn_kalodata_ingest_candidates` does not map `master_image_url`.
   Per the preservation requirement, the paid-call request contract was deliberately NOT changed
   in this assignment. When the founder approves the US call with images, add `'need_image',1` to
   the builder's `request_body` (one line) and map `master_image_url` in ingest — both are staged
   recommendations, not yet applied.

FastMoss/Kalodata research-display separation and supplier-media rights handling were not touched.

## I. Genuine remaining access blocker

The **current-generation Kalodata API key is not present in any secure store this integration can
reach** (Edge env holds only the previous-generation key under `KALODATA_SECRET_KEY`; Vault and DB
hold none). It exists only on Kalodata's side / the founder's Kalodata account. Resolution
(founder, ~1 minute): Supabase Dashboard → Project Settings → Edge Functions → Secrets → add
**`KALODATA_API_KEY`** with the current key (preferred; picked up automatically and keeps the old
key for audit), or overwrite `KALODATA_SECRET_KEY`. No code change or redeploy is needed
afterwards. Then re-run the free `balance_probe` to confirm `BALANCE_OK` and the live balance.

---

## ADDENDUM — 2026-11-20 (later): new key verified, image readiness completed

**Authentication RESOLVED.** With the regenerated key saved as `KALODATA_API_KEY`
(36 chars, mask `2052...b656`), the deployed broker selects it (probe: `key_env: KALODATA_API_KEY`)
and the FREE `GET /openapi/v1/credit/balance` returns **`BALANCE_OK`** — HTTP 200, success envelope,
no provider error code. The 501 "The key is not allowed" error is gone.

**Live credit balance: 14.1 credits** (`data.totalRemain`; also `mainRemain`), matching Kalodata's
verified figure. Read at 2026-11-20T11:06:31Z via the free endpoint — 0 credits spent.

**kalodata-discovery v28** (v26/v27 were dashboard secret-save redeploys): `extractBalance` gains a
generic numeric balance/credit/amount/remain* fallback for the `data` envelope, and `balance_probe`
reports the envelope's key NAMES (`data_keys`). Local deterministic suite extended to **46/46 passing**.

**Image readiness implemented (mig_292 / `kalodata_discovery_request_need_image`):**
`fn_kalodata_discovery_request` now sends `need_image: 1` in the Product Rank request body
(contract bumped to `pulse_kalodata_request_v3_need_image`; no other field changed — verified by
key-set comparison). The ingestion side needed no change: `fn_kalodata_ingest_candidates` already
persists the cover via `fn_extract_cover_url` (which recognises `master_image_url`) and
`fn_persist_reference_image`, storing it as `rights_state PROVIDER_DISCOVERY_REFERENCE`,
`authority REFERENCE_ONLY`, never displacing an existing primary asset (Product Asset Lock intact)
and never unlocking store/ad/creative/publishing use — the research-reference vs commercially
authorised supplier/storefront separation is preserved by construction.

**Post-change tests (all pass, no writes, no provider calls):** builder body carries need_image=1
with all nine prior fields byte-identical; `fn_extract_cover_url` unit tests (master_image_url
extracted, /default/ placeholder filtered, non-http rejected, priority order preserved, absent→null);
market gate unchanged (US/DE/GB/FR/ES/IT/MY/PH/SG ok, XX/BR refused); dry-run ingest of a synthetic
rank record carrying master_image_url → SUCCESS_WITH_CANDIDATES, promoted 1, normalized present,
zero rows written; `fn_kalodata_commerce_adapter_selftest` all_pass post-migration.

**No paid requests:** zero Kalodata discovery runs / usage records today; the only provider calls
were free credit/balance GETs.

**READY:** one authorised US Product Rank request with `need_image=1` (0.1 credit, ≤100 records/page,
10 candidates ingested per current caps) can proceed on founder approval. Expected: genuine product
data (native product_id, title, US market, revenue/sales signals) with master_image_url persisted
per candidate as a REFERENCE_ONLY research cover.

---

## ADDENDUM 2 — 2026-11-20: AUTHORISED ONE-CALL US PRODUCT DISCOVERY TEST (EXECUTED)

**Controls.** Research-dispatch suppression opened for the tenant (30-min TTL) and a fail-closed
one-call provider budget opened (`provider_call_budget` b614a5b3, KALODATA/US, max_calls=1,
15-min TTL). Emergency stop verified off. Execution went through the canonical
`fn_kalodata_run_discovery` path: atomic budget consume (remaining 0 immediately after dispatch —
no retry could ever consume a second call), single-use nonce, one guarded pg_net POST (request 270)
to `kalodata-discovery` v28, explicit page 1 (never previously delivered; earlier page-1 attempts
had failed with 501 before purchase).

**Provider result (genuine).** `SUCCESS_WITH_CANDIDATES`: HTTP 200, 10 raw candidates returned,
10 qualified, 10 promoted (run `a57cfc37-7ca5-42b6-90ac-ed5f1177cb5f`). Sample of the real
US TikTok Shop products ingested:

| Product (title) | Native ID | Price | 7-day sales / revenue | Growth |
|---|---|---|---|---|
| Shark PowerPro Cordless Vacuum IZ383H/IZ386H | 1732776966801822384 | $229.99 | 7,487 units / $1,721,935 | −66.0% |
| Beauty Finds by ULTA Beauty Holiday Fragrance Lineup For Him | 1732819733286195924 | $39.65 | 21,475 units / $851,588 | +47.5% |
| Limited Edition 4Patriots Mystery Survival Food Kit | 1732820195618689325 | $231.50 | 3,689 units / $854,019 | −47.9% |
| EcoFlow Delta 4 3800Wh Solar Power Station | 1732776295965102340 | $1,351.10 | — | — |
| Insignia 50" F50 Series 4K Fire TV | 1732780180751225661 | $229.06 | — | — |

**Ingestion verification.** 10 new `commerce_products` rows (23 → 33 Kalodata products), all under
the single authorised tenant (zero wrong-tenant rows); all market-attributed US with USD pricing;
10 `commerce_signals` COMMERCE_PRODUCT_NATIVE rows carrying sales_units / revenue / growth;
10 active `monday_opportunity_registry` entries, so the candidates are live in the existing
Product Discovery backend.

**Images.** `need_image=1` worked: 10 `product_image_assets` rows (0 → 10 for KALODATA), each a
genuine TikTok CDN `master_image_url` (p16-oec-ttp.tiktokcdn-us.com / ibyteimg.com), stored with
`rights_state = PROVIDER_DISCOVERY_REFERENCE`, `authority = REFERENCE_ONLY`; primary flag granted
only because no prior primary existed (Product Asset Lock not bypassed); no commercial/supplier
asset rights granted.

**Suppression held.** Every one of the 10 promoted candidates recorded
`research_auto_dispatch: DISPATCH_SUPPRESSED` — zero downstream paid research calls.

**Cost (actual).** Free balance read before: 14.1. After: **14.0** — exactly 0.1 credit consumed,
the standard single Product Rank charge. Telemetry on the run records operation
`tiktok/product/rank`, country US, `call_count: 1`, HTTP 200. Exactly one Kalodata discovery run
was added (14 → 15 all-time).

**Close-out.** Budget b614a5b3 deactivated after consumption (1/1); no active KALODATA budgets
remain (fail-closed default restored). Dispatch suppression closed (normal settings restored).
No additional provider requests, no publishing, no purchases, no FastMoss, no Lovable credits.

**Outcome: the end-to-end Kalodata Product Discovery pipeline is live** — authentication,
market-gated request with need_image, budget gating, tenant-private ingestion, REFERENCE_ONLY
image persistence and telemetry all verified against real provider data.

---

## ADDENDUM 3 — 2026-11-20: PHASE 2 — LIVE PRODUCT DISCOVERY WORKSPACE (COMPLETED)

**Gap found.** The workspace's authoritative payload (`fn_ecommerce_workspace_intelligence`) lists
products from `product_opportunity_decisions` only; the 10 ingested candidates had zero
`product_market_evaluations` and zero decisions, so they were invisible. The missing step was the
existing projection `fn_project_discovered_candidates`.

**Repair (existing tenant-authorised function, no architecture change).** Ran
`fn_project_discovered_candidates(tenant,'US',168)` once: 35 registered, undecided US candidates
(incl. the 10 new) projected and decisioned — `suppress_dispatch=on` internally, zero paid
research, provisional outcomes only. All 10 new products: `decision WATCH`,
`lifecycle_state WATCH`, `action_gating MONITOR_GATHER_EVIDENCE`,
`research_evidence_state INSUFFICIENT_EVIDENCE`, `decision_provisional true` — nothing auto-TEST.

**Tenant-authenticated verification (production RPCs under the tenant's auth context):**
`fn_ecommerce_workspace_intelligence` → status ok, all **10/10** new Kalodata products present
(titles, USD prices, `source_store kalodata`); `fn_ecommerce_lifecycle_summary('US')` → 37
products (tenant+country isolated; DE summary unaffected); `fn_ecommerce_product_intelligence`
(Shark PowerPro) → kalodata-attributed identity, COMMERCE_MOMENTUM QUALIFYING with genuine
units/revenue (7,487 / $1,721,935), other evidence families honestly UNKNOWN/UNAVAILABLE;
`fn_product_card_display_image` + `fn_resolve_product_gallery` → genuine TikTok CDN image,
`rights_state PROVIDER_DISCOVERY_REFERENCE`, `is_authoritative false`, native source_item_id.
Cross-tenant probe → `no_member` (no exposure).

**Deterministic suites:** discovery render 13/13, media integrity 7/7, product image 10/10,
media auth 5/5, product gallery 14/15 — the one failure (`no_ai_or_web_sources`) is
**pre-existing**: 10 `DATAFORSEO_MERCHANT` images from the founder's 2026-11-19 merchant lane are
absent from the selftest's provider allowlist (stale test allowlist; founder decision).

**Live UI check (www.strateloq.com):** site serves; `/workspace` redirects unauthenticated
visitors to `/auth?next=%2Fworkspace` (sign-in + founding-member application); zero tenant data
leaked pre-auth. **Limitation:** a full founding-member sign-in walkthrough could not be performed
from the agent session (no member credentials exist there; the zz test-token minter is disabled by
design) — API-level verification above is the authoritative evidence.

**Safety/cost:** no further Kalodata requests (runs total unchanged at 15; balance 14.0);
0 DataForSEO spend by this session (today's 18 consumptions were the founder's own 00:00–00:20 UTC
pilot); 0 FastMoss; 0 Lovable credits (read-only inspection); 0 publications
(`commerce_product_pages` untouched); no active provider budgets; suppression restored;
no credentials exposed.

**Milestone recorded:** launch tracker 'Build Evidence & Handoff' row 214 (BE214).

**Next build milestone:** research-driven evidence upgrade for the 10 US WATCH candidates
(budget-gated Kalodata product/detail + product/images lanes and/or CJ exact-SKU supplier
economics) — separate founder authorisation required for any paid call.

---

## ADDENDUM 4 — 2026-11-20: UNIFIED PRODUCT OPPORTUNITY INTELLIGENCE VERIFIED (BE217)

Verification-only pass (zero provider calls of any kind, zero schema/code changes):

- **One unified, tenant-isolated US list.** `fn_ecommerce_workspace_intelligence` returns a single
  `product_decisions` array spanning kalodata (10), dataforseo_merchant (25), dataforseo (1) and
  reddit (1) — 37 US products, all WATCH, 0 TEST, each with source attribution, USD price,
  provisional flag and decision reasons. TikTok sales strength alone never promotes past WATCH.
- **Cross-provider overlay proven on one product.** DE kalodata product "More Adventskalender 2026"
  shows `SEARCH_DEMAND (DATAFORSEO) = QUALIFYING` and `MARKETPLACE_VALIDATION = QUALIFYING`
  alongside its TikTok discovery in one intelligence payload — separately sourced evidence
  families, no blending. US products honestly show UNKNOWN where no evidence exists in either
  direction (Shark: momentum QUALIFYING, demand UNKNOWN; Rossetta: offers QUALIFYING, momentum
  UNKNOWN).
- **Identity integrity.** Zero products carry both TikTok and Google native IDs; no title-only
  joins exist or were created; records remain independent per the Product Identity Resolution
  policy.
- **CJ honesty.** 1,317 supplier product rows; 7 real resolutions; exactly one bound match
  (GB kids nightlight projector → CJ SKU CJYD3093228, $5.73 cost, ships CN/CN→US) surfaced as
  `CONCRETE_PRODUCT_AMBIGUOUS` (not CONFIRMED); all 10 US kalodata candidates show
  `supplier_match UNMATCHED / dispatched false` — honest incomplete-opportunity status.
- **Preserved state.** No Stage-1/GOLD checkbox, formula or completed DataForSEO unit touched
  (BE215/BE216 reconciliation intact). Kalodata balance 14.0; DataForSEO month $0.391; paid
  dispatch OFF everywhere; isolation and rights gates unchanged.
- **Tracker:** Build Evidence & Handoff row 217 (BE217).

Open gates (not prematurely marked): founding-member signed-in UI walkthrough; GOLD
GPD.03/05–11 customer-visible + rights acceptance (8 Stage-1 units); CJ exact-SKU economics for
the US kalodata candidates; image/display licensing (fail-closed).

---

## ADDENDUM 5 — 2026-11-20: PHASE 4 — SUPPLIER-QUALIFIED DISCOVERY PASS (BE218)

**Founder UI acceptance recorded.** Signed-in founding member confirmed genuine Kalodata US
cards + images at www.strateloq.com (US selected, 10 All cards, 4 High Growth) — closes the
authenticated-UI open item.

**Workspace defects.** (1) FIXED: `fn_product_explorer_markets` counted only FastMoss-era
signals, so US read "no data yet"; mig_293 aligns it with the explorer's exact population +
display-image gate (verified US 10=10, GB 28=28, DE 9=9; frontend untouched). (2) NOT a
defect: "37 in research pipeline" (lifecycle total) vs 10 discovery cards (image-gated
provider-discovery view) are different, correctly-labelled populations.

**CJ supplier matching — honestly gated, zero spend.** The authorised Stage-2 CJ search
workflow ran for the one generic candidate (RGBIC floor lamp): the existing claim gate
rejected BEFORE any CJ call — `STAGE2_NOT_SUPPLIER_QUALIFIED / ONLY_ONE_QUALIFYING_FAMILY`.
Claim probes for the other 9 return the same verdict (Apple bundle additionally
`DISQUALIFIED_BRANDED_OR_IP`). By design, supplier search requires ≥2 independent qualifying
evidence families; all 10 Kalodata candidates hold exactly one (COMMERCE_MOMENTUM). No
ambiguous match promoted; supplier economics explicitly INCOMPLETE for all 10; CJ points
50,000/50,000 untouched.

**Decision quality.** WATCH decisions carry explicit machine-readable reasons (8 on the
Shark), `opportunity_score_verified=false`, honest INSUFFICIENT evidence — TikTok sales alone
promote nothing to TEST.

**Regression after the fix:** discovery render 13/13, media integrity 7/7, commerce adapter
pass, provider budget gate 10/10. Spend this pass: 0 across all providers. Tracker: BE218.

**Next milestone:** founder-approved bounded DataForSEO product-level evidence wave for
selected US Kalodata candidates (the second qualifying family) to unlock the existing CJ
supplier-matching gate, then SKU-level CJ inventory/shipping enrichment for any concrete match.

---

## ADDENDUM 6 — 2026-11-20: PHASE 4B — SEARCH PERMISSION ≠ QUALIFICATION (BE219)

**Verdict on the Stage-2 gate: yes, overly restrictive for search.** The ≥2-family rule is an
intentional *qualification* invariant; the claim gate was reusing it as *search* permission
while ignoring identity ambiguity. `fn_pod_evaluate` never reads the supplier-resolution
table, so search results structurally cannot change decisions.

**Fix (mig_294):** search permitted iff ≥1 qualifying family AND NOT branded/IP AND NOT
identity-ambiguous (new, stricter identity requirement for search); rejections now
`STAGE2_SEARCH_BLOCKED` with an explicit reason. The two-family qualification contract, strict
resolver, budgets, idempotency, brand registry and every TEST/publishing gate are unchanged.

**Live proof:** the RGBIC floor lamp (blocked yesterday) searched CJ free of charge
(5 pages / 100 candidates / 0 errors) and resolved honestly to `NO_VALID_CJ_MATCH`,
bound=false — decision remains WATCH; workspace shows `UNBOUND / dispatched: true`.

**Status of the 10 US candidates:** SEARCHED_NO_MATCH 1 (lamp) · NOT_SEARCHED 8 (eligible,
free to run on demand) · SEARCH_BLOCKED 1 (Apple bundle, BRANDED_OR_IP) ·
CONFIRMED_EXACT_MATCH 0 · qualification 0/10 (two families still required — unchanged).
Supplier economics explicitly incomplete everywhere (no match reached economics).

**Regression:** stage2 pagination 10/10, shared identifier 3/3, multilingual 8/8, query
expansion 10/10, boundary integrity 10/10 (check F updated to the new stronger assertion),
concrete-identity native pass, budget gate 10/10, commerce adapter pass.

**Spend:** zero — CJ points 50,000/50,000 (`usedToday: 0`), Kalodata 14.0, DataForSEO OFF.
Tracker: BE219.

---

## ADDENDUM 7 — 2026-11-20: PHASE 5 — DROPSHIPPING QUALIFICATION PASS (BE220)

**Candidates evaluated.** The whole decided pool (DataForSEO pilot + Kalodata US) was scored
with the live qualifier: 0 products fully supplier-resolution-qualified. Multi-family rows are
legacy research concepts (identity-ambiguous + high-saturation — correctly disqualified).
A representative generic set of US star projectors was chosen, deliberately excluding real
brands the registry misses (Govee, DAYBETTER, Thames & Kosmos, Rossetta).

**Searches performed (reuse-first, minimum-necessary).** Existing evidence inspected: 1,317 CJ
rows (54 projector), 7 prior resolutions (GB nightlight kept AMBIGUOUS). One new bounded free
search (n8n 30711): "Star Projector w/ Remote, Timer, 360°" US → `NO_VALID_CJ_MATCH` with
`NO_CONCRETE_EVIDENCE` (0 candidates considered) — the identity-first resolver refuses to bind
from one partial marketplace observation. Read-only identity screening showed the other five
generic merchant candidates are all `INSUFFICIENT` identity — further searches would non-bind
by design, so none were run.

**Outcomes:** CONFIRMED 0 · AMBIGUOUS 1 (pre-existing GB) · SEARCHED_NO_MATCH 2 (lamp:
supplier nonavailability after a real 100-candidate search; star projector: identity evidence
insufficient to bind) · SEARCH_BLOCKED 1 (Apple, BRANDED_OR_IP) · NOT_SEARCHED remainder.

**Economics:** `fn_resolve_supplier_economics` returns `no_candidate` for both the AMBIGUOUS
GB nightlight and the lamp — customer economics correctly withheld until a CONFIRMED match;
raw supplier-row data stays internal. Customer workflow verified: star projector `UNMATCHED`,
lamp `UNBOUND`, both `dispatched: true`, both still WATCH. Regression green (boundary, budget
gate, render, shared identifier). Spend: 0 everywhere (CJ 50,000/50,000; Kalodata 14.0;
DataForSEO OFF).

**Key finding.** The machinery is complete; candidate quality is the binding constraint. No
current product combines authoritative concrete identity + generic/unbranded + ≥2 qualifying
families + an actual CJ equivalent. Remaining requirements for the first supplier-qualified
opportunity: (1) more generic product-native candidates (e.g. one authorised Kalodata page,
0.1 credit, unbranded-niche biased, and/or MY/PH/SG), (2) the approved paid DataForSEO
second-family wave, then (3) the existing pipeline auto-carries to economics and decision.
Tracker: BE220.

---

## ADDENDUM 8 — 2026-11-20: PHASE 6 — SUPPLIER-FIRST DISCOVERY ROUTE (BE221)

Pure existing-data evaluation: zero provider calls, zero writes, zero code changes.

**CJ cache profile (1,317 rows):** 100% native pid + SKU + shipping codes + image; 1,061 with
cost; 199 categories; only 6 deep-enriched; **0 rows within the 14-day freshness contract**
(newest 2026-10-29). Representative generic set: leather patch $0.95, USB projection lamp
$5.73, pet water dispenser, jewelry box, 3-channel dash cam $28.21, ski balaclava $1.83
(35 variants, media SUPPLIER_PROVIDED_REFERENCE_ONLY).

**Sourceability (verified-but-stale, nothing fabricated):** dash cam — US warehouse IN_STOCK
34 units (2026-09-11), USPS domestic freight $0, full prior US unit economics; balaclava —
GB freight 22 options, GB landed $5.34, sampled variant OUT_OF_STOCK.

**Cross-provider (identity resolution only):** exact matches remain 1/9 all-time (GB
nightlight → CJYD3093228, AMBIGUOUS, unchanged); the GB ski-mask market product was honestly
NOT bound to the enriched balaclava. Market coverage of the 6: nightlight concept 5 markets /
394 signals / WATCH ×5; ski mask 1 family; the other four UNKNOWN (no evidence transferred).

**Route comparison:** market-first = strong demand, weak exact supplier matchability;
supplier-first = perfect exact identity + free economics reach, weak market evidence + stale
freshness. Neither alone qualifies anything; the intersection is the requirement. Closest
overall: nightlight (4 qualifying GB families) — still correctly disqualified (high
saturation + ambiguous identity). **Unique bridge case:** dash cam 66b60d77 — concrete
platform_id identity + exact CJ SKU + prior US economics, but 0 evidence families, no
registry entry (pre-dates the pipeline; re-entry is a founder decision).

**No landed-cost calculation is justified today** (stale evidence, no CONFIRMED match;
customer economics correctly return no_candidate). No defect found → no change made; the
inactive CJ enrichment workflow deliberately not run. Spend 0 everywhere. Tracker: BE221.

**Outstanding for the first fully qualified opportunity:** (1) authorised Kalodata
unbranded-niche page(s) (0.1 credit each, incl. MY/PH/SG option); (2) approved paid
DataForSEO second-family wave; (3) free CJ freshness re-probe at confirmation time;
(4) the unchanged pipeline then carries to economics and decision; GOLD gates remain the
final acceptances.

---

## ADDENDUM 9 — 2026-11-20: FASTMOSS RETIRED FROM CUSTOMER WORKSPACE (BE222)

**Retired (reversibly, nothing deleted):** 47 FastMoss-only products (GB 28 / DE 19, one tenant,
batches Oct-12/Oct-19) quarantined via the existing `commerce_discovery_hidden` mechanism with
full source/first-observed snapshots; 38 FastMoss images suppressed (availability=UNAVAILABLE);
FASTMOSS dispatch disabled in all 20 market configs (request builder refuses; budget gate was
already fail-closed). The "110 locally acquired trial products" were never ingested into
production — nothing to retire. The one product with auxiliary independent signals (GB Snowman
Door Hanger) was quarantined with all evidence preserved intact; 0/47 had independent product
authorisation, Kalodata IDs or bound suppliers.

**Reader consistency:** workspace intelligence, lifecycle summary, product-detail wrapper and the
lanes RPC now all honour the quarantine (this also stopped 21 pre-existing Oct-21
legacy-concept hides from leaking into the workspace list). Two pre-existing image-reader gaps
found and fixed (card fallback + signed-ref ignored availability). Two selftests retargeted from
the retired FastMoss ingest path to Kalodata; all suites green again (gallery 14/15 = known
pre-existing allowlist item).

**Verified in production:** 0 fastmoss decisions visible (sources kalodata 33 +
dataforseo_merchant 25; products_tracked 193); explorer GB=0 DE=0 US=10, markets list US-only;
hidden detail → not_found; lanes → provider_retired; `fn_fastmoss_discovery_request` refused;
Kalodata/DataForSEO/CJ counts unchanged (33/169/1,317 + 9 resolutions, 2,841 signals); isolation
untouched.

**Frontend:** Lovable commit 887d50b (1.2 credits) — header wording, empty-state hints removed,
captions/tooltips neutralised, audit labels kept, 724/724 tests — **deployed**: www.strateloq.com
now serves bundle `index-pv5O6SfZ.js` with zero "FastMoss" strings (old bundle had the retired
wording). Product/storefront publishing remains OFF.

**Open item for founder/legal:** whether FastMoss provider terms require deletion of retained
(unpublished, audit-only) FastMoss data on termination. Tracker: BE222.

## ADDENDUM 10 — 2026-11-20: PHASE 7 — CUSTOMER WORKSPACE COMPLETION (BE223)

**Scope.** Save/Monitor (04.07/GPD.18), country comparison (GPD.21), research-display honesty
(GPD.03/05–11), responsiveness/a11y (03.10), regression preserving BE222. Verification basis:
tenant-context RPC execution + live production-bundle greps — not a signed-in member browser
session (that acceptance remains with the founder). Spend: 0 providers; 10.6 Lovable credits.

**Build 1 — Save/Monitor (mig_296).** Full authenticated cycle verified live (emulated member,
Shark 50e1b04e…, US): save `created=true` → duplicate `created=false` (same saved_id) → Saved
list row+title → DE list empty (country context) → Find via `fn_product_explorer` (10 US items)
→ unsave `removed=true` → repeat `false` → empty list; cross-tenant save `forbidden`. Two live
defects fixed: (1) quarantined FastMoss-retired products could be saved and resurfaced in the
Saved list (BE222 leak-back) — hidden products now `forbidden` on save and excluded from the
list (`pulse_saved_products_v2`); (2) `unsave_own_product` returned integer `removed`, which the
deployed decoder rejects — now boolean. Monitoring proven truthful: snapshots read only stored
evidence (no dispatch), run on the saved Shark → checked=1 / reliable=0 / events=0; events only
against a prior reliable baseline, deduped. All test rows rolled back (0 rows remain).

**Build 2 — Country comparison (mig_297 + Lovable e9d5104/fff458d, 8.6 cr).** Root cause: the
released decoder/view call `rpc fn_product_country_explorer(p_product_id)`, but only the
service-side 3-arg core existed (no grant, different payload) and the view was mounted only at
the fixture-labelled `/dev/market-explorer` — member comparison always failed closed. New
authenticated 1-arg adapter: tenant = `auth.uid()` (the commerce tenant key; `fn__own_tenant()`
returns the membership application_ref — v1 bug found and fixed), ownership + hidden gates →
`not_found`, delegates to the untouched per-country core, emits the released decoder contract
with the DF.03B verified-score guard (score only at MEDIUM/HIGH confidence) and honest
why-this-market text. Member route `/workspace/product-markets/$productId` + one
“Compare countries” explorer-drawer button deployed; no request-analysis action wired
(`fn_market_candidacy_screen` is not member-callable; nothing may risk dispatch); inert
store/ads handoff cards suppressed for members (`showNextSteps=false`). Verified: Shark → ok,
35 countries, one evaluated US view (WATCH / confidence NONE / score suppressed), DE =
ANALYSIS_REQUIRED with no decision (decoder UNKNOWN — zero cross-country transfer).

**Build 3 — Research display (mig_298 + Lovable 3dfb6b1, 2 cr).** US cohort audit: freshness +
first_observed truthful; growth VERIFIED on basis `revenue_7d_pct` showing genuine −66.02%;
competitor/sellers/advertisers/saturation all UNKNOWN with claim-safety notes; WATCH +
INSUFFICIENT explainable. Defect: `metrics_basis` hardcoded `revenue_estimated=(FASTMOSS)` and
window `UNSPECIFIED_BY_SOURCE` → Kalodata analytics revenue displayed unlabelled. Fixed:
estimated=true for FASTMOSS+KALODATA; `reporting_window='LAST_7_DAYS'` for KALODATA (genuine:
every rank request is `date_range='last7Day'` by stored contract). Frontend caption now
provenance-aware: “estimated (provider-reported)”.

**Build 4 — a11y/responsive (03.10).** Playwright against live production (public pages; no
member credentials exist here): home + /auth at 390px/1440px — no horizontal overflow, viewport
meta, lang, single h1, alt’d images, labelled inputs, named buttons, visible focus on every tab
stop, logical order; home has main/nav landmarks (/auth lacks landmarks — minor).
Authenticated-workspace a11y evidence remains component-level (728/728 tests).

**Build 5 — regression (mig_299).** Explorer + lanes selftests were pinned to the quarantined
FastMoss GB cohort; retargeted to current intended behaviour: explorer v2 10/10 (incl. new locks
`KALODATA_METRICS_BASIS_HONEST`, `FASTMOSS_RETIRED_ABSENT`) and lanes v2 4/4 (retired-provider
empty contract). Also green: budget gate 10/10, render 13/13, stage2g, stage1 invariants 8/8,
kalodata adapter 17/17; gallery stays at known 14/15 (pre-existing allowlist item, founder
decision, no rights leak). State: 0 open provider budgets; FASTMOSS dispatch 0 / available
images 0 / 47 hidden rows intact; the only “FastMoss” string in the live bundle is the retained
video-match provenance audit label.

**Deployed:** deployment 3e08062d live on www.strateloq.com (route tree carries the new member
route; “Compare countries” and “estimated (provider-reported)” present in live chunks).
**GOLD:** no gate ticked — GPD.18/21 engineering complete and live; acceptance needs the
founder’s signed-in browser journey. Tracker: BE223.

## ADDENDUM 11 — 2026-11-20: PHASE 7 GOLD CLOSEOUT (BE224)

**Founder acceptance recorded.** The founder's eight Phase 7 browser confirmations
(Save; reload persistence; Saved list; Find exact; Unsave; Compare-countries opens from the
drawer; honest single-market comparison with Analysis-required elsewhere; the
"estimated (provider-reported)" + last-7-days label on US cards) are recorded as accepted
human checks per the 2026-11-20 closeout directive — corroborated by four genuine founder
browser saves in live production at 14:50 UTC (after the mig_296 contract fix).

**GPD.18 monitoring acceptance (backend complete + UI shipped).** Genuine change alerts
fired from the real 19-Nov evidence arrivals on the GB cold brew (DEMAND false→true,
COMPETITION seller false→true; real evidence_as_of) after a documented baseline rewind to
the genuine pre-19-Nov state; dedupe proven (identical recompute → 0); scoring alerts
correctly suppressed at confidence NONE; stranger tenants see and check nothing; market
filters hold. The missing monitoring/alerts panel was built (Lovable 779ae40, 3.9 credits;
fail-closed api/hook; on-demand check scoped to the current market; truthful status line;
"never fetches new market data" caption; honest empty state; 736/736 tests) and deployed —
deployment 998af5d2 verified serving on www.strateloq.com.

**GPD.20 server-side subscriber restriction completed (mig_300).** Nine previously ungated
campaign/creative/live-publish mutators now enforce fn_is_founder(); empirically verified
in both directions; service paths unchanged. The one amber selftest case
(ad-engine J_regressions) is the known pre-existing gallery 14/15 allowlist item cascading
through lineage anchors — independent of the gate.

**GPD.05 ticked TRUE** — the first GOLD tick after GPD.04: licensed Kalodata figures carry
country, exact product, last-7-days window, currency and the estimate label
(founder-sighted live); unsupported evidence stays UNKNOWN in cards and APIs; sorting uses
only genuine stored values; the product-package export hardcodes economics
NOT_ESTABLISHED/null with published:false and a missing-information block; absence of
evidence cannot produce TEST (invariant suites green same-day).

**GOLD reconciliation.** GPD.18 FALSE — one remainder: founder sighting of the new
monitoring panel (incl. the two genuine cold-brew alerts). GPD.20 FALSE — authenticated
mobile/keyboard + rights-revoked-state sighting. GPD.21 FALSE — alerts sighting + first
genuinely multi-market-evidenced product (paid acquisition decision). GPD.22 untouched.
Spend: 0 providers; 3.9 Lovable credits (Phase 7 total 14.5). Tracker: BE224.

## ADDENDUM 12 — 2026-11-20: GPD.20 GOLD CLOSEOUT (BE225)

**Subscriber security complete (mig_301).** All nine mig_300 mutators (both
fn_creative_production_request overloads included) individually re-verified as a
non-founder authenticated user → FORBIDDEN_FOUNDER_ONLY with zero side effects; founder
and service paths pass. Equivalent-path audit: zero RLS write policies for members on any
store/campaign/creative/media/page/social table (member-writable surface = own users row
+ own saved_opportunities); three further authenticated writers in founder-only domains
found and gated (ad creative-asset selection, creative format apply, storefront
product-page draft) — 24 founder-gated mutators in total; five founder-path suites green
after the change.

**Rights revocation (Product Asset Lock).** Reversible drill on the Shark US image:
availability → UNAVAILABLE ⇒ resolver no_image, signed ref no_asset, the card is
withdrawn from the explorer entirely (10→9 — no product displays without a rights-cleared
image, no restricted media served); restore ⇒ back to 10 with the image.

**Live-production browser automation (honest scope; no member credentials exist here).**
Unauthenticated /workspace and /workspace/product-markets/* redirect to /auth with the
full return path; the /auth error state renders in an alert region without crashing; the
deployed comparison components on the fixture-labelled /dev/market-explorer route pass at
390px and 1440px: no overflow, mobile table→snap-card swap, aria-pressed chips, 10/10
visible-focus tab stops, zero page errors. Not claimed as a signed-in pass.

**Regression** green across budget gate, media auth, product image, stage-1 invariants,
founding-member access control (non-member uid), explorer v2 and lanes v2; known gallery
14/15 amber unchanged (founder decision). No frontend change; deployment 998af5d2
unchanged and exercised live.

**GOLD decision.** GPD.20 stays FALSE on exactly one criterion — signed-in MOBILE
verification: on a phone, signed in, Product Discovery → cards → product drawer →
Compare countries → return → Saved → Monitoring panel. On that founder confirmation it
ticks TRUE. GPD.21's remainders stay as identified (alerts sighting + paid multi-market
evidence — founder decisions; no unpaid engineering path). Spend: 0. Tracker: BE225.

## ADDENDUM 13 — 2026-11-20: GPD.21 FINAL GOLD CLOSEOUT (BE226) — ACCEPTED

**The product (found in existing data, zero paid calls).** Govee Star Light Projector
`d985e5af-658b-4fdc-abe6-d43797e84f03`, authoritative native identity
google_product_id 18034214886779403846 (dataforseo_merchant, GENERIC_OK), not hidden,
single product row — never title-matched. Independent country-local observations:
GB marketplace observation 2026-11-19 17:26 UTC (+ GB category-demand context: 'star
projector', GBP median 25.49, provenance INFERRED_CATEGORY) vs US marketplace observation
2026-11-20 00:03 UTC. Independent evaluations: GB 19 Nov WATCH/GBP/diagnostic-76 and
US 20 Nov WATCH/USD/diagnostic-56, both confidence NONE.

**Member-facing verification** through the live RPC the deployed UI calls: two EVALUATED
views (GB GBP / US USD, decisions WATCH, scores suppressed under the verified-score
guard), every other supported country ANALYSIS_REQUIRED with no decision, global best GB,
no TEST, no borrowing, no fabrication. Honest depth note recorded: one marketplace
observation per market; confidence NONE is the truthful reading — deep evidence is
GPD.22's benchmark, not this gate's.

**Verdict-change detector** characterized with pure IMMUTABLE comparator calls on the
genuine 19-Nov cold-brew history (76→52.6 + real demand/seller arrivals): δ10 fires
SCORE+DEMAND+COMPETITION; δ30 threshold drops SCORE; identical snapshots → zero (no false
alarms); decision/qualification flips classify as confidence-gated scoring dims. Combined
with BE224's live alert/dedupe/ACL proof and the founder's sighting of the two genuine GB
alerts: "real verdict changes only" fully evidenced. No defect found → no code change.

**Tracker.** LIVE MASTER — GOLD (the only visible tab; nothing unhidden): GPD.21 → TRUE /
ACCEPTED. Accepted gates now: GPD.04, GPD.05, GPD.18, GPD.20, GPD.21 (5 of 22). Spend 0.
Next unit ready: GPD.19 (server-side denial already proven; remaining = signed-in
continuity evidence + subscriber-denial sighting), with GPD.12/13 as same-visit checks.
Tracker: BE226.

## ADDENDUM 14 — 2026-11-20: GPD.19 EXECUTION + GPD.12/GPD.13 ACCEPTED (BE227)

**GPD.19 (kept FALSE, honestly).** The full member continuity chain
(Discovery→country→product→evidence/verdict→Save→Saved→reopen→Compare→Monitoring) is
engineering-verified (BE223–226) and founder-accepted in browser including mobile —
reused, not re-requested. The supplier leg is truthfully unavailable: both member-facing
supplier readers return {no_candidate, present:false} for displayed products (zero
CONFIRMED exact-SKU matches exist all-time) and no match was invented. Subscriber
restrictions: all 27 gated function objects re-verified intact; fresh emulated
non-founder calls refused. Honest limit recorded: no second real member account exists
(registration is founder-only), so live-session subscriber denial remains structural
server-side proof. Remaining criteria named precisely on the board: first CONFIRMED
exact-SKU supplier (paid CJ decision) or a founder ruling on the acceptance's
"when verified" conditional, plus the real-subscriber denial sighting decision.

**GPD.12 ACCEPTED.** Data-wide sweep: zero visible opportunity scores across every
customer-visible explorer item (10/10, all band INSUFFICIENT, zero TEST); the Govee
GB/US diagnostic scores surface only in the service-side comparison RPC flagged
score_verified=false (no member grant) while the member RPC suppresses both; the founder
sighted the live cards. Bonus independence evidence: genuine GB-local observed price
£79 GBP PLATFORM_REPORTED vs US price source UNKNOWN.

**GPD.13 ACCEPTED.** Every explorer sort is DESC NULLS LAST and every range filter
requires IS NOT NULL — an unavailable metric can never rank as zero or top and never
matches a numeric range; behavioural GROWTH sort returned the genuine values in strict
descending order (950.18 → −87.32, all basis-VERIFIED, negatives shown); facet/filter
consistency, search narrowing and HIGH_GROWTH purity remain selftest-locked; compare is
the accepted comparison view.

**Board:** LIVE MASTER — GOLD rows 13/14/20 updated only; 7 of 22 GPD gates now accepted
(04, 05, 12, 13, 18, 20, 21). Spend 0; no code changes (no defect found). Tracker: BE227.

## ADDENDUM 15 — 2026-11-20: GOLD VERIFICATION WAVE (BE228) — 10 OF 22 ACCEPTED

**Accepted this wave:** GPD.03 (fresh acquisition & provenance — 10/10 visible items carry
provider/country/first-observed/as-of with the stale guard; sighted same-day), GPD.14
(explainable decisions — verdict + insufficient-evidence + missing-coverage + per-country
why, all sighted; review triggers = the accepted monitoring alerts), GPD.15 (rights-safe
research detail — identity, price/currency, estimate/window, honest UNKNOWNs, truthful
supplier-unavailable, PAL-governed reference images, zero member store/ads actions).

**Narrowed:** GPD.02 now depends on exactly one thing — the GPD.01 written provider-rights
sign-off (mechanism, sweep and sighting complete; per the rule, unlicensed display rights
are never marked approved).

**Held honestly (GPD.06–11):** one shared gap — no customer-visible product carries
demand/seller/advertiser/price evidence; every honest-empty path is complete and sighted,
and the mechanisms were re-proven on genuine stored observations (GB 162 MATCHED listings
£4.99–£135.90 with sellers honestly UNKNOWN; GB 22 advertisers from 29 ads; IT
independently 35/14; US UNKNOWN; saturation VERY_HIGH only where observed). Key finding:
the founder-tenant resolver call correctly returns UNKNOWN for system-tenant evidence —
tenant isolation proven at the evidence layer, not a regression. No-cost unlock
identified (founder decision): customer-publish the GB pilot products + the gallery
allowlist ruling — closes the sighting gap with evidence already owned, zero paid calls.

**Commercial dependency plan (GPD.01/16/17/19/22):** 01 = legal sign-off, $0 API,
instantly closes 02 + rights legs; 16 = ≤0.5 Kalodata credits + ≤$0.50 DataForSEO +
$0 CJ to the first CONFIRMED exact-SKU match; 17 = $0 once 16 exists; 19 = 16's match or
two zero-cost founder rulings; 22 = ≈2–3 Kalodata credits + ~$5–15 DataForSEO for a
disciplined 10×6 pass (no-waiver). Spend this wave: 0. Tracker: BE228;
LIVE MASTER — GOLD rows 3–4, 7–12, 15–16.

## ADDENDUM 16 — 2026-11-20: EVIDENCE RELEASE READINESS (BE229)

**Gallery 14/15 resolved at root (mig_302).** The "allowlist — founder decision" item was
in fact leaked test-fixture residue: ten orphaned DATAFORSEO_MERCHANT image rows with the
fake URL img.example.invalid, product_ids no longer in commerce_products, mislabelled
is_fixture=false. Deleted exactly those ten (assertion-guarded; audit list in the
migration). No genuine Merchant imagery is stored anywhere — the 19-Nov fail-closed
alignment holds in production data. The one FASTMOSS orphan (real URL, 13 Oct) stays
under the retention flag. Result: gallery 15/15 with the original strict invariant, and
the amber cascade (lineage, video runtime, ad engine J_regressions, media integrity) all
green. No test weakened; PAL untouched.

**Visibility-gap diagnosis (three separable issues).** (1) System-tenant legacy evidence:
isolation working, not transferred. (2) The 160 Merchant products are founder-owned and
eligible in principle but the explorer's base predicate admits only kalodata/fastmoss —
a product decision, not a defect. (3) No Merchant imagery stored; customer cards would be
text-fallback (GPD.02-sanctioned) or need an image-rights determination.

**Rights reconciliation** recorded per source (derived analysis vs field display vs
reference images vs customer display vs commercial reuse vs caching), with the explicit
rule that display_cleared is a system flag, never legal authorisation; written
customer-display terms are on file for none of Kalodata / DataForSEO / CJ → GPD.01
remains the gate for GPD.02 and the rights legs of 08/10/15.

**GB publication plan prepared, not executed** (five founder-owned products: Projecteur,
Cold Brew, two projector listings, Govee), text-fallback mechanism, reversible predicate
migration, revocation and rollback drills specified. Blocked on the founder's
text-fallback product decision + GPD.01 written confirmation for DataForSEO derived
text-field display. No GPD.06–11 ticks. Spend 0. Tracker: BE229.

## ADDENDUM 17 — 2026-11-20: MERCHANT TEXT-FALLBACK BEHIND A RELEASE GATE (BE230)

**Implemented (mig_303–305), publication still disabled.** The explorer and its market
counts now admit dataforseo_merchant products as text-fallback research cards strictly
where a `customer_source_release` row is released=true; the gate is seeded false for the
BE229 five-product GB pilot, so nothing is customer-visible. Tenant scoping, the hidden
quarantine, market scoping and all kalodata/fastmoss behaviour are unchanged; the
deployed frontend already renders a compact no-image card, so zero Lovable credits.

**Drill (live, fully reversed).** Baseline GB=0/US=10 → one pilot product released →
honest GB text-fallback card (DATAFORSEO_MERCHANT attribution, GBP 39.99, genuine 19-Nov
dates, TEXT_FALLBACK status, revenue/sales absent — never zero, growth UNKNOWN,
competitor blocks UNKNOWN, no invented decision) → stranger tenant 0 → **consistency
defect caught and fixed**: the market-selector counts had not been mirrored (GB chip 0 vs
1 card; mig_305 v4) → counts consistent → revocation via hidden row → 0 both readers →
unhide + unrelease → GB=0, US=10, zero residue, zero released rows. Regression battery
green (explorer v2, lanes v2, budget gate, gallery 15/15, render); Kalodata cards
byte-identical throughout.

**To release later (no engineering):** document the DataForSEO derived-data display terms
+ Google Shopping upstream conditions (GPD.01 leg), then flip released=true on the five
pilot rows. GPD.06–11 stay FALSE — a working implementation is not customer-evidence
acceptance. Spend: 0. Tracker: BE230.

## ADDENDUM 18 — 2026-11-20: ACTIVE-SOURCE RIGHTS CLOSEOUT (BE231)

**Documentary review, no interpretation.** The authoritative register
(`catalogue_source_rights`) holds every clearance dimension FALSE for every provider. The
only provider correspondence on file is Kalodata's 20-Nov reply (API authentication
guidance only — no rights statements; need_image/master_image_url is a product feature,
not a display licence) and the FastMoss entitlement enquiry pending since 16-Nov.
Provider public terms pages are not retrievable from this engineering session
(DNS-blocked by network policy) — recorded as not-retrievable, nothing guessed.

**Matrix + decision (docs/legal/STRATELOQ-ACTIVE-SOURCE-RIGHTS-MATRIX-BE231.md).** Full
Permitted/Prohibited/Unconfirmed/Requires-written-approval matrix for DataForSEO (incl.
Merchant), Kalodata and CJ. The GB five-product text-only pilot is NOT authorised by
documents on file; `customer_source_release.released` stays FALSE. The exact missing
document is named (DataForSEO written confirmation for derived listing-text display +
retention + upstream Google conditions).

**Two register-vs-practice inconsistencies flagged for founder decision:** (1) Kalodata
derived analytics + reference images are live in the customer workspace under the
founder's direct build authorisation while the register holds display FALSE; (2) system
practice treats CJ SUPPLIER_PROVIDED media as gallery-display-eligible while the register
holds display FALSE. Resolution for each: provider written confirmation (drafts ready) or
a documented founder risk-acceptance written into the register.

**Actions:** four active-source rights_evidence entries updated with this reconciliation
(no clearance flag changed); three permission-request emails drafted for founder review —
not sent. GPD.01 row updated; no GOLD ticks. Spend 0. Tracker: BE231.

## ADDENDUM 19 — 2026-11-20: KALODATA PERMISSIONS RESOLVED (BE233)

**The recovered provider email** (Andrew Lin <andrew.lin@kalodata.com>, 2026-11-11,
"Re: Commercial API Licensing and Product Image Usage — Strateloq Technologies";
founder-supplied via their connected Gmail, message link recorded in the rights matrix
doc; not independently re-read in-session — Gmail connector pending re-auth) corrects
BE231/232: the system record was incomplete, and the Kalodata gap was a **missing
register entry, not a missing contractual right.**

**Register reconciliation (scoped):** derived/analysed intelligence display to paying
SaaS customers cleared; Product Rank main-image display cleared for authenticated
research WITH attribution (rendered today in the evidence meta/source labels — a
condition to maintain); caching/proxy/hosting cleared (current practice hotlinks;
Product Images API links expire after 5 minutes); raw-data resale recorded as a
**documented prohibition**; creative/storefront/advertising reuse not covered and stays
blocked (PAL, founder gates, commercial_cleared=false). Residual caveats recorded:
standard ToS text not on file; upstream TikTok-Shop conditions unaddressed — caveats,
not blockers to the confirmed research-display use. The live customer display is within
the documented scope; nothing had to be restricted.

**Consequences:** Kalodata draft email withdrawn (fully answered — no repeat enquiry);
DataForSEO and CJ remain separately unresolved (drafts stand; Merchant release gate
FALSE). **GPD.02 ACCEPTED** (its sole remaining dependency now documented for 100% of the
current customer image surface); GPD.01 open on DataForSEO + CJ only. 11 of 22 GPD gates
accepted. Spend 0. Tracker: BE233.

## Addendum 20 — 2026-11-20 — BE237: Lovable credit recovery executed (4 builds, 1 deployment, gates closed)

**Reconciliation first (STEP 1, no credits).** Live production equalled Lovable main
HEAD `779ae40`, so nothing on main was "built not deployed". Classification:
LIVE+ACCEPTED — Refresh Discovery, `/billing/return`, monitoring panel, compare route,
invitation issuance UI; BUILT-NOT-DEPLOYED — the Phase 08 subscription draft
(`thr_hngx5qbpo2ie` @ `9831ee3`, incl. `29eb929`'s server-owned `checkout_open` gate)
and the W0.05 catalogue package (the BE157/158 patch files were lost with the 17-Nov
session scratchpad; the deployed RPC contracts remained authoritative);
PARTIALLY WIRED — notification bell (UI + read RPCs live, `fn_emit_notification` had
zero callers, `pulse_notifications` empty forever); NOT BUILT — application review UI,
member feedback UI, Problem-to-Product UI.

**Shipped (Lovable commits, one deployment `f01f2435-51fe-4e7d-8723-34fd0b1ac9c1`,
28.3 credits, 1,061 tests / 114 files, typecheck+lint+build clean, live bundle
`index-CoFwwWhL.js` crawl-verified 19/19 including preserved surfaces):**
1. `e9b3503` Shared catalogue (W0.05 rebuilt from contracts): browse/adopt via
   `fn_catalogue_browse(_markets)`/`fn_catalogue_adopt`; score suppressed below MEDIUM
   confidence; image only `AUTHORIZED` + https; honest 0-published empty state;
   `not_entitled` panel; no publish/admin controls.
2. `767fa0b` Founder Applications review panel on `/workspace/invitations` + member
   Share-feedback dialog; non-founders get a restricted panel, never applicant data.
3. `56bacb6` Phase 08 subscription UI merged draft→main FAIL-CLOSED: Select enabled
   only by server `checkout_open === true`; today the server returns no open plan, so
   every button renders disabled; `billing-checkout` independently re-refuses
   (env gate + plan inactive + live-price + per-user intent RPC). Nothing charges.
4. `c5e9450` Premium Problem-to-Product (`/workspace/problems`): observed vs inferred
   separation, Hypothesis chips, fit matrix with visible UNKNOWN, "What's missing"
   list, candidates captioned research-stage — never verified supplier matches.

**Backend (migrations, record files mig_306–mig_308):** genuine notification emitters
(`fn_monitor_apply` per-run owner alert with SCORING/dedupe gates untouched;
`accept_invitation` → founder MEMBER_ACTIVATED; `submit_feedback` 'workspace' subject,
trim-guarded, founder FEEDBACK_RECEIVED) — drill T1–T7 green, zero residue;
founder-gated application review RPCs using the table's original status vocabulary;
server-side `not_entitled` gate on the four 05A read RPCs (founder/service pass;
tenant isolation re-verified first). Regression: founding access control 12/12,
05A foundation + discovery suites green.

**Known pre-existing, flagged not fixed:** `fn_research_orchestrator_selftest`
(contract `pulse_research_selftest_v3_013n`) is pinned to the retired
tiktok/meta/ebay dispatch era and fails 5/8 of its cases; it chains into
`fn_problem_solution_selftest` case `N_product_first_pipeline_regression` (17/18).
Retarget decision pending — same genre as the mig_299 explorer/lanes retarget.

**Preserved and re-verified after deployment:** `customer_source_release` 5 rows all
`released=false`; `catalogue_source_rights` cleared only for KALODATA research-display
dims; `platform_catalogue` 0 published; the sole live "FastMoss" string is the honest
historical provenance caption; 11 accepted GOLD gates untouched; no public signup; no
charge, price activation or checkout opening. Tracker: BE237 (Build Evidence row 237,
POLISHED 03.09/04.02/04.08, PINNED P0.10/W0.05, START HERE NOW-5).

## Addendum 21 — 2026-11-22 — BE240: DataForSEO Merchant text-only upstream compliance review

Documentary review of whether the intended GB Merchant **text-only** research display
complies with applicable upstream rights. No provider calls, no code/release change.

### 1. Production data flow (traced) — the 5 GB pilot products
`DataForSEO Merchant/Sellers result → commerce_products (+ product_market_competitors)
→ derived product-market evaluation → fn_product_explorer merchant text-fallback card
(+ GPD.08/10 competitor-offers detail)`. Per-field inventory of what reaches the customer:

| Field | Source class | Displayed to customer? |
|---|---|---|
| Product title | Direct observation (Google Shopping merchant listing title) | Yes (card) |
| Merchant / seller names | Direct observation (Google Shopping seller identities, e.g. DealBeagle, BargainBadger, "Amazon.co.uk-Seller") | Yes, in the **competitor-offers detail** (NOT on the explorer card — fn_product_explorer does not project merchant_seller_name) |
| Country-local observed prices (GBP) | Provider-reported measurement / direct observation (DATAFORSEO_SELLERS, price_source_class=OBSERVED) | Yes |
| Merchant / product links | — | **No** — `observed_product_url` is NULL for every pilot row; no link is stored or displayed |
| Derived demand & competition | Independently calculated analytical conclusion (score, decision, seller count, saturation) | Yes |
| Source attribution / provenance | Metadata (PLATFORM_REPORTED; source DATAFORSEO_SELLERS / dataforseo_merchant) | Yes |
| Retention / caching | Stored observations | Yes (cached; DataForSEO permits, refresh for freshness) |
| Images / media (copyright-sensitive) | — | **No** — 0 product_image_assets across all 5; image_status=TEXT_FALLBACK; cover_url NULL. **Images confirmed blocked** at both data and projection layers. |

Per-product: Projecteur (1def97b0) carries 5 named GB sellers £33.99–£39.99 (EXACT_PRODUCT);
Govee Star Light (d985e5af) one eBay comparable $59.99 (CLOSE_COMPARABLE, USD-labelled);
the other three are observed-empty honesty cases (no seller rows).

### 2. Applicable upstream terms
- **DataForSEO ToS §7** (captured 12 Jun 2026, repo `docs/legal/captures/DATAFORSEO-TERMS-OF-SERVICE-CAPTURE-2026-11-20.md`): §7.1 data must not compete with / adversely affect the search-engine provider; §7.2 customer bears upstream risk/indemnity. Provider permission to store/resell confirmed (BE239).
- **Google Merchant Center Terms** (merchant-facing; scheduled update 15 Jun 2026): bind entities that *use Merchant Center to list products*. Strateloq is **not** a merchant and does **not** use Merchant Center → these terms do not govern Strateloq's use.
- **Google Shopping Content API / developer terms**: bind **direct API users**. Strateloq makes **no** direct Google API call (data arrives only via DataForSEO; marketplace comparables via eBay Browse) → per the directive, these are **not** applied, because that agreement does not govern Strateloq's access or use.
- **Google general ToS (automated-access prohibition)**: binds whoever accesses Google. The extractor is **DataForSEO**, not Strateloq; Strateloq never assented to Google's ToS and has no Google account or direct access → **no Google contract is in privity with Strateloq**.
- **Non-contractual law** (the genuine residual): (a) **copyright** — prices, seller names and short product titles are facts / lack originality, and no images are shown → low; (b) **UK/EU sui generis database right** — re-utilising a *substantial part* of Google's compiled Shopping database could infringe; Strateloq displays a tiny, transformed, derived subset acquired by a third party (DataForSEO) → a genuine but narrow question; (c) DataForSEO **§7.2** assigns any residual upstream risk to Strateloq.
(Secondary web sources on Google Shopping scraping are vendor blogs, explicitly not legal
authority; counsel should pull Google's current policy pages directly.)

### 3. Field-level compliance classification
- **SUPPORTED / low risk:** product title; country-local observed prices; derived demand & competition; source attribution; retention & caching; images (blocked); links (not displayed).
- **UNCERTAIN → legal sign-off:** the **named individual marketplace-seller identities** shown verbatim alongside exact observed prices in the competitor-offers detail — this is the element closest to re-utilising Google's compiled per-seller data and is the only field carrying a non-trivial database-right question.
- Not a DataForSEO-permission question (provider permits it); purely the Google-upstream / database-right question, which DataForSEO cannot and did not clear.

### 4. Release recommendation
A **narrower rights-safe presentation eliminates the one uncertain item without concealing
material evidence**: present the competition signal as an **aggregate** — observed seller
**count** + observed **price range** (min–max) + exact-match flag + country + freshness —
and either omit or anonymise the verbatim per-seller identity list (e.g. "5 GB sellers,
£33.99–£39.99, exact-product"). The material opportunity signal (how many sellers, what
price band, exactness) is fully preserved; only the verbatim compiled-seller list is
withheld. Images stay blocked; no links. This is a small **backend-only** projection
change (not a frontend rebuild) and is offered for founder decision, **not implemented**
here.

**Smallest remaining decision / narrow legal question for qualified counsel:**
> Does displaying to authenticated paying SaaS customers a small set of factual
> Google-Shopping-sourced observations (product titles, named marketplace-seller
> identities, observed country-local prices) acquired via DataForSEO — with no images and
> no links — amount to re-utilisation of a substantial part of Google's Shopping database
> under UK/EU database right, or breach any term binding Strateloq, given Strateloq has no
> direct Google relationship and DataForSEO §7.2 assigns upstream risk to Strateloq? And
> does the aggregate/anonymised presentation in §4 reduce that to acceptable?

### 5. Controls preserved
5 `customer_source_release` rows remain `released=false`; image restrictions intact
(0 assets, TEXT_FALLBACK); tenant/country isolation unchanged; Stripe LIVE closed; 11
accepted GOLD units untouched. GPD.01 remains **OPEN** — provider terms resolved, the
Google-upstream leg is now reduced to the single narrow legal question above plus the
founder production-release authorization. No rows flipped; GPD.01 not accepted.

## Addendum 22 — 2026-11-22 — BE241: aggregated competition presentation + EU database-right closeout

Founder authorised the **engineering change only** (not release, rights, GPD.01, Stripe
LIVE, or paid calls). Implemented the narrower rights-safe competitor-offers presentation
from BE240 §4.

### Provenance of the 5 pilot products' competitor observations (Task 1)
- **Google Shopping (via DataForSEO Sellers):** Projecteur (1def97b0) — 5 GB offers, 5
  distinct named sellers, EXACT_PRODUCT, GBP £33.99–£39.99 (source DATAFORSEO_SELLERS).
- **eBay-derived comparable (not Google-origin):** Govee Star Light (d985e5af) — 1 US
  offer, no seller identity, CLOSE_COMPARABLE, USD $59.99 (source EBAY_BROWSE).
- **Strateloq independently-calculated:** the derived score/decision/demand/competition
  metrics (not in the competitor table).
- Three products (cold brew, Govee Exquisite, pococo) are observed-empty.
Not all stored offers are Google-origin — the eBay comparable is a separate source with
its own rights.

### Aggregation implemented (Task 2 — mig_311, backend-only)
Both customer-facing competitor RPCs (`fn_product_competitor_evidence`,
`fn_ecommerce_competitor_intelligence`) now withhold the verbatim per-seller list
(`competitor_identity` + `observed_product_url`) and return structured aggregates:
observed **offer** count (listings) kept SEPARATE from **distinct-seller** count; distinct
sellers reported only where genuinely verifiable (every row in the group carries an
identity), else UNKNOWN; single-currency observed price range; exact-product vs
comparable-product; observation date / freshness / source; and explicit limitations. The
internal evidence table and the internal evaluators retain full provenance. The existing
frontend renders the aggregated response from `price_summary` without Lovable changes
(the verbatim-list card path now receives an empty `competitors` array).

### Task 5 — EU/Google database-right & contractual closeout
**Directive 96/9/EC** (legal protection of databases, 11 Mar 1996): Art. 3 copyright for
original selection/arrangement; **Art. 7 sui generis database right** for a maker with
**substantial investment in obtaining, verifying or presenting** the contents, to prevent
**extraction / re-utilisation of a substantial part** (qualitative or quantitative);
**Art. 7(5)** bars repeated/systematic extraction of **insubstantial** parts that conflict
with normal exploitation or unreasonably prejudice the maker; 15-year term (Art. 10).
Retained in the UK as the database right under the Copyright and Rights in Databases
Regulations 1997 (as amended). Key CJEU authority: **British Horseracing Board v William
Hill (C-203/02)** — the right protects investment in *obtaining* existing data, not in
*creating* it; **Innoweb v Wegener (C-202/12)** — re-utilisation via meta-search.

Application to the five-product presentation (analysis, not legal advice):
- Whether Google holds the sui generis right in its Shopping compilation turns on the
  BHB obtaining-vs-creating distinction (merchant listings are supplied by merchants;
  Google's investment is arguably in obtaining/verifying/presenting) — genuinely uncertain.
- A single pilot display of 5 products is unlikely to be a quantitatively "substantial
  part"; the aggregation (counts + ranges rather than the verbatim compiled seller list)
  further reduces both the quantum and the "reproduction of the compiled list" character.
  **Aggregation reduces, but does NOT automatically eliminate, the database right** — Art.
  7(5) can still bite on *repeated/systematic* insubstantial extraction at SaaS scale.
- No Google contract binds Strateloq (BE240: no direct access/account/assent). DataForSEO
  §7.2 assigns residual upstream risk to Strateloq.

**Recommendation: yes — qualified Irish/EU counsel should review the specific five-product
(post-aggregation) presentation**, on: (a) whether Google holds an Art. 7 right in the
Shopping data (obtaining-vs-creating); (b) whether Strateloq's display of aggregated,
DataForSEO-sourced observations is extraction/re-utilisation of a substantial part or
triggers Art. 7(5) at scale; (c) copyright in titles (low); (d) the §7.2 indemnity
exposure. This is the narrow, specific question now ready for counsel.

### Verification status (honest)
Verified after the change: competitor-evidence selftest 5/5, stage3b 16/16, w004 11/11,
and no customer-reachable RPC emits identity/url. **Pending:** the explicit 9-scenario
drill and the reversible release-on drill were interrupted by a Supabase MCP
destructive-statement confirmation timeout (the atomic DO block never committed, so no
residue; release rows never touched, still `released=false`). To be re-run
non-destructively. Controls preserved: 5 release rows FALSE, images blocked, tenant/country
isolation, Stripe LIVE closed, 11 GOLD units untouched, GPD.01 unchanged (OPEN).

### BE242 — 2026-11-23 — interrupted verification completed (engineering sign-off)
The BE241 "pending" drill is now complete, run read-only / transaction-safe (no synthetic
production writes). State re-confirmed directly (not by presumed rollback): 0 `BE241_DRILL`
rows, 0 `ZZ`-market rows, 5 release rows `released=false`, rights clearances unchanged,
both RPCs deployed as `*_v2_aggregated`. Nine scenarios all PASS: (1) two-country —
Projecteur GB OBSERVED/GBP vs JP 0 offers; (2) multiple-offers-one-seller — exact
`count(*)` vs `count(DISTINCT identity)` expressions give offers=2 / distinct_sellers=1
(read-only replica; no real group exhibits this, so no production write made); (3) distinct
sellers — 5 offers / 5 distinct, group carries no identity/url key; (4) no competitors —
UNKNOWN, 0 offers, empty aggregate; (5) missing identity — offers=1, distinct_sellers
NULL/UNKNOWN; (6) GBP vs USD separated; (7) exact (Projecteur 5/0) vs comparable (Govee
"Comparable product"); (8) release-disabled — 0 of 5 pilots visible in the explorer while
`released=false`; (9) tenant isolation — `cross_tenant_rejected`, foreign tenant sees 0
rows on both RPCs. Live frontend unchanged (`index-CoFwwWhL.js`): renders `price_summary`
range + withheld `competitors[]`, no identity/url, no offers-as-sellers mislabel, UNKNOWN
honest, currency correct — no Lovable change required. **BE241/BE242 engineering
verification COMPLETE.** Still open and separate: the EU/Google 96/9/EC legal assessment
(qualified Irish/EU counsel, per §Task 5 above) and the explicit founder production-release
decision. Release rows remain FALSE; GPD.01 OPEN; 11 GOLD units unchanged.

## Addendum 23 — 2026-11-23 — BE243: supplier qualification (GPD.16/17/19) + image-rights fix

Supplier qualification from EXISTING data only — no paid provider calls, no new integrations.

### Strongest genuine exact-SKU candidate (GPD.16)
- Opportunity `56a6af36-68f7-4138-9d29-941245f266b2` — "Novelty Old Man Face Ski Mask, Thermal
  Dralon Balaclava" (GB, founder tenant; FastMoss-origin discovery).
- CJ supplier `2609290358281623700` — "Realistic Winter Ski Face Mask", SKU family `CJMZ3207828`,
  cost $1.83, 60 g; 8 of 35 CJ variants correspond to the discovered concept.
- Identity: `SAME_PRODUCT_IDENTITY`, MEDIUM confidence, product-form match, concept corroborated.
- **Not exact-SKU verified:** `variant_verified=false`, `exact_sku_status=EXACT_SKU_UNVERIFIED`,
  binding `UNBOUND_UNTIL_EXACT_SKU`; missing evidence = variant-image vision unavailable, no shared
  product identifier, exact variant unconfirmed. The only *bound* resolution row in the whole
  system is `CONCRETE_PRODUCT_AMBIGUOUS` (opp e453eed4) — ambiguous, not exact.
- **GPD.16 NOT accepted.** The binding constraint is exact-variant verification (vision/identifier
  or a paid CJ exact-SKU confirmation), not tooling. No paid call authorised.

### Economics (GPD.17)
- Real GB landed estimate: supplier $1.83 + CJ freight $3.51 (CJPacket Ordinary, 4–9 days) = **$5.34
  (£4.07)**, excludes duties/VAT/customs/payment/ads/returns/platform fees; freight labelled
  approximate research estimate (mig_310); per-variant GB stock present (mix IN_STOCK / OUT_OF_STOCK
  factory-replenishable).
- **Not acceptable yet:** cost_basis LISTING_REPRESENTATIVE, shipping_basis LISTING_SAMPLED, evidence
  32.5 days STALE (>14 d), margin withheld (no confirmed selling price + requires exact variant).
  **GPD.17 NOT accepted.**

### GPD.19 supplier-positive leg
No confirmed exact-SKU supplier bound to a displayed/released product (the 5 GB merchant pilots are
`released=false`; the ski-mask is a candidate, not a released product). **Supplier-positive leg NOT
satisfied.**

### Defect repaired (mig_312)
`fn_resolve_supplier_economics` emitted unlicensed CJ CDN image URLs in the customer-facing response.
Fixed fail-closed: image URL emitted only when the provider's `display_cache_images_cleared` is TRUE
(CJ=FALSE) → NULL + `BLOCKED_SUPPLIER_IMAGE_UNLICENSED`. Verified no CJ URL leaves the server;
economics/labels unchanged. Honors CJ terms (images not licensed) and PAL.

### CJ permissions applied (BE233/BE239)
Supplier data + SKU/stock/freight research authorised and shown (aggregated, honest). Images BLOCKED
(now enforced at source). Freight estimates approximate-labelled. **Note:** CJ product-page *links*
are authorised but **0 `product_url` are stored** across all 1,317 CJ rows — links cannot be shown
without acquisition.

### Remaining real-world blockers (all require authorised paid acquisition — none taken here)
1. Exact-variant verification for a genuine binding (GPD.16).
2. Fresh CJ evidence — all cached evidence 25–33 days stale (>14 d).
3. Confirmed selling price + exact variant for margin (GPD.17).
4. A confirmed exact-SKU supplier bound to a released/displayed product (GPD.19).
5. CJ product-page link acquisition (0 stored).

Controls preserved: 5 release rows FALSE, Stripe LIVE closed, GPD.01 OPEN, 11 GOLD units unchanged,
images blocked, tenant/country isolation intact. GPD.16/17/19 remain NOT accepted (no real-world
evidence). Pre-existing, not caused here: fn_stage1_supplier_resolution_selftest 20/22
(18_fastmoss_green retired-adapter, 23_idempotency_pass) — flagged, not in scope.

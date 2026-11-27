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

## Addendum 24 — 2026-11-23 — BE244: FastMoss integration PERMANENTLY REMOVED

Founder directive (permanent): FastMoss is no longer a provider. All active and dormant FastMoss
integrations removed; not retained as a fallback. No paid provider calls; no Lovable spend.

### 1. Backend / edge
- **Edge functions neutralized** (the actual FastMoss API callers): `fastmoss-discovery` (v22) and
  `fastmoss-product-detail` (v35) now return HTTP 410 `PROVIDER_RETIRED`, make NO external request,
  read NO secret, route to NO provider. (Supabase MCP has no delete; neutralized to inert stubs.)
- **Active DB route severed**: `fn_multi_lane_discovery_plan` COMMERCE lane is Kalodata-only
  (mig_313); FastMoss request-build / provider object / field removed.
- **FastMoss DB functions dropped** (mig_315): 7 operational + 6 selftests, by exact signature;
  post-condition asserts 0 remain. `fn_fastmoss_commerce_adapter` did not exist.
- **Provider config**: `discovery_provider_market_config` FastMoss rows (20, across markets incl. the
  18 supported) deleted; `provider_capability_registry`, `discovery_lane_registry`,
  `commerce_supplier_provider_config` already had none.
- **Credential**: edge secret `FASTMOSS_CLIENT_SECRET` is now unused by any function. The MCP cannot
  delete secrets — **FOUNDER ACTION: remove `FASTMOSS_CLIENT_SECRET` in the Supabase dashboard**
  (Project → Edge Functions → Secrets). It is inert meanwhile (no function reads it).

### 2. n8n
No FastMoss-named workflow exists (search = 0); no discovery/commerce workflow references FastMoss.
The historical FastMoss workflow was removed in BE222. Any residual node pointing at the retired edge
is inert (410). No enabled FastMoss workflow or schedule; no execution can initiate a FastMoss request.

### 3. Frontend
No active FastMoss provider selector, badge-as-choice, discovery/refresh control, loading/error state
or subscription prompt exists (removed in BE222). The only remaining FastMoss strings in the live
bundle are **historical source-attribution** on retained research records (video-match provenance
caption "Matched via FastMoss discovery — … not exact-SKU verified"; a "Source: FastMoss" link on
retained reference videos; a label-dictionary entry). Per the directive these are **preserved** as
required historical attribution. No Lovable change (no defect).

### 4. Provider registry / database / 18 markets
FastMoss absent from all active routing, supported-provider lists and scheduled dispatch config across
all 18 markets (and the extra legacy markets). Historical audit evidence **retained, quarantined,
non-customer-visible**: 47 FastMoss-origin `commerce_products`, 42 `commerce_signals`, 38
`product_image_assets` kept; the explorer selftest's `FASTMOSS_RETIRED_ABSENT` lock = true confirms
none surface as current intelligence. No shared structures dropped; no unrelated rows/migrations touched.

### 5. Tests (BE243 failures repaired; no suppression)
`fn_stage1_supplier_resolution_selftest` now 21/21 — case 18 (FastMoss adapter) retired (Kalodata case
19 is the current invariant); case 23 idempotency fixed to the durable `CACHE_REUSED_IN_FLIGHT` marker
(the active-logical-key unique index + in-flight dedup invariant preserved). Budget-gate retargeted to
Kalodata (all fail-closed budget invariants preserved). Media-integrity check G retargeted to Kalodata.

### 6. Verification (acceptance)
0 callable FastMoss API integrations (edges 410); 0 enabled FastMoss workflows/schedules; 0 active
FastMoss provider routes; FastMoss credentials needed by Strateloq = none (secret inert, flagged for
founder deletion); 0 customer-facing FastMoss provider options (only historical attribution); 0
FastMoss launch dependencies; 0 FastMoss DB functions. Regression all green: stage1 supplier-resolution
21/21, early-opportunity, evidence-identity, budget-gate, media-integrity, Kalodata adapter, multi-lane,
explorer v2, lanes v2, competitor-evidence, stage3b, cross-supplier, founding-access — DataForSEO / CJ /
Kalodata unaffected.

### 7. Safeguards preserved
5 `customer_source_release` rows FALSE; Kalodata rights preserved (display cleared), DataForSEO Merchant
display FALSE; Stripe LIVE closed (0 active plans); founding-member-only (6 new / 3 accepted, no
auto-approval); PAL + supplier-image block (BE243) intact; tenant/country isolation; 11 accepted GOLD
units unchanged. A historical FastMoss provenance label in retained evidence is NOT an active integration.

---

## Addendum 25 — BE245 CJ supplier qualification (GPD.16/17/19): exact-SKU evidence verdict + release-harness repair

**Date:** 2026-11-23. **Scope:** zero-cost engineering + verification. **No paid/quota provider calls.
No release-row, rights, billing, or GPD.01 change.** FastMoss remains permanently retired (not touched).

### 1. Task 1 — exact-variant qualification (opp `56a6af36-68f7-4138-9d29-941245f266b2` / GB / CJ `2609290358281623700`)
Verdict: **exact-SKU verification is NOT achievable for this candidate, and acceptance would be dishonest.**
Evidence (read-only, persisted + static):
- The system's own persisted verdict in `commerce_concrete_supplier_resolution` is `identity_result = NO_VALID_CJ_MATCH`, `bound = false`, `selected_sku = null`, `selected_supplier = null`. The CJ row was considered and scored `match_class = CLOSE_COMPARABLE`, `shared_identifier = false`, `attrs_ok = false` (opportunity = "Novelty **Old Man Face** Ski Mask"; CJ candidate = "**Realistic** Winter Ski Face Mask" — distinguishable, not same identity).
- The opportunity's concrete identity rests on a **single retired-FastMoss product-native observation** (`product_native_providers:["fastmoss"]`, `marketplace_listing_titles:0`), with **no authoritative identifier** (gtin/brand/model all null; only FastMoss-internal ids).
- Schema-wide there is **no structured authoritative-identifier column** (GTIN/UPC/EAN/MPN/ASIN scan = empty). No opportunity↔supplier pair anywhere can be linked by a shared structured identifier.
- The writer `fn_resolve_cross_supplier_identity` is an **honest floor**: `'variant_verified', true` appears **0** times and `'variant_verified', false` **25** times (hardcoded false on every return path); the tier `EXACT_VARIANT_VERIFIED` is **never assigned**. It can reach at most `SAME_PRODUCT_IDENTITY` from family/form heuristics and structurally refuses to promote resemblance/family-match to exact-SKU. Selftest `fn_cross_supplier_identity_selftest` 13/13, incl. `oldman_potential_no_verified_exact` (potential=8, **verified_exact=0**) and `exact_sku_strict_gate`.
- **Precondition to flip `variant_verified` false→true** (honest): an authoritative shared identifier (GTIN/UPC/EAN/MPN) present on BOTH the demand product and the CJ variant, OR supplier-native variant IDs confirmed as the same physical variant, OR a verified image-vision exact-variant tool. None exists; and the demand identity came from FastMoss (permanently retired), so no richer demand-side identifier can be obtained.

### 2. Task 2 — fresh CJ evidence path, cost, quota, budget, authorization
- CJ integration is **passive RPC ingest only** — there is **no CJ Supabase edge function / live CJ caller**. Fresh evidence enters via `fn_ingest_cj_variant_evidence(p_pid, p_vid, p_sku, p_market, p_inventory, p_shipping, p_observed_at)`; freshness contract `fn_cj_variant_evidence_is_fresh(pid,vid,market,max_age_hours)`.
- For the target: the fresh-evidence table is **`present:false`** for GB — **no stored inventory and no stored GB shipping** (both `needs_refresh=true`). The only cached CJ detail lives in `commerce_supplier_products.supplier_enrichment` and is **33.3 days old** (observed 2026-10-21), with **no stored product-page URL** (`has_product_url=false`).
- CJ config: `provider=CJDROPSHIPPING`, `enabled`, `access_state=AVAILABLE` ("Primary supplier source (live)"). Rights (BE239, intact): `analyse_cleared=TRUE`, `display_derived_cleared=TRUE`; `display/images/raw/reuse/commercial = FALSE`.
- Cost/quota/budget: the in-DB provider budget gate (`fn_provider_budget_try_consume`) governs **metered discovery providers**, not CJ ingest; there is no configured live CJ caller to meter. A CJ product-detail refresh would be an **external** acquisition (CJ Dropshipping API / portal).
- **A paid/quota CJ call is NOT genuinely required for this candidate**, because it cannot cross the identity gate: a CJ detail call returns CJ-side data only and cannot establish same-product identity with a retired-FastMoss demand product that carries no authoritative identifier, and the CJ candidate is already scored a non-match (`attrs_ok=false`). **No costed acquisition plan is proposed for this candidate** — it would spend for evidence that still cannot produce acceptance. A costed CJ call becomes worthwhile only for a *genuine same-product* candidate that already shares an authoritative identifier with a CJ listing (none today).

### 3. Task 3 — landed cost / margin
Reused `fn_resolve_supplier_economics` (read contract inspected; non-persisting). For the target: no `EXACT_VERIFIED` variant exists (basis stays `CANDIDATE_LISTING`), and there is no customer-facing selling price for a verified same product, so **net margin is correctly WITHHELD / UNKNOWN**. Landed cost exists only as a **33-day-stale approximate research estimate** (`supplier_cost=1.83 USD`; `gb_landed_usd_displayed_variant=5.34 USD`), labelled approximate per mig_310. Supplier images remain **BLOCKED** (CJ `display_cache_images_cleared=false`; resolver image gate maps `cj%→'CJ'`).

### 4. Task 4 — customer research integration + isolation
No exact match exists for this candidate (`NO_VALID_CJ_MATCH`), so **nothing new is surfaced** to the UI. Safeguards intact: supplier-image block (mig_312), 5 `customer_source_release` rows FALSE (no unreleased DataForSEO Merchant publication), tenant `CROSS_TENANT_REJECTED` + country isolation (regression green).

### 5. Task 5 — regression + release-harness repair
Green: `fn_stage1_supplier_resolution_selftest` 21/21 (incl. `23_idempotency_pass`; case 18 removed), `fn_cross_supplier_identity_selftest` 13/13, `fn_stage2_shared_identifier_selftest` 3/3, `fn_multi_lane_discovery_selftest` 16/16, `fn_provider_budget_gate_selftest` 10/10, `fn_discovery_media_integrity_selftest` 7/7, `fn_product_competitor_evidence_selftest` 5/5 (offers≠sellers honest), `fn_mig310_reliability_selftest` 7/7. **0 FastMoss DB functions remain.**

`fn_pd_release_verification`: **mig_316** repaired the area-18 outbound-denial **positive control** (it opened a budget for the retired `'FASTMOSS'` provider then called the kalodata driver → dead control, pass=null). Retargeted the fixture budget to `'KALODATA'`/`'DE'`; the routed driver now reaches the guard and is provably blocked (`request_id='-1'`, no enqueue). Result: `failed` 3→2; area 18 PASS, area "1-4,10,15" stable PASS (underlying `fn_stage1_early_opportunity_selftest` independently 20/20).

**Two remaining red areas are PRE-EXISTING STALE ASSERTIONS — left unchanged, proposed corrections tabled for founder approval** (they are release-readiness pass criteria the founder reserves; their real safeguards are independently GREEN):
- **Area 7** `NOT EXISTS(... analyse OR display_derived OR images OR raw OR reuse)` — false since KALODATA's GOLD `display+images` rights (and CJ's BE239 `analyse+display_derived`). Real publication/commercial gates (`commercial_redistribution_cleared`, `redistribute_raw_cleared`, `reuse_creative_cleared`) are **FALSE for all providers**, and the release-gated `DATAFORSEO_MERCHANT` source has `display/images/commercial/raw/reuse` all FALSE. **Proposed:** assert `NOT EXISTS(... WHERE commercial_redistribution_cleared OR redistribute_raw_cleared OR reuse_creative_cleared)` AND the Merchant source's display/images FALSE — allowing the legitimate GOLD/research grants.
- **Area 12-13** asserts `LICENSED_ENABLED=13 AND DISABLED_ADAPTER_ONLY=5 AND NO_PROVIDER=0` — the pre-FastMoss-removal topology. Current: `market_count=18`, `NO_PROVIDER=0` (no silent drop — real safeguard holds), `LICENSED_ENABLED=9 / DISABLED_ADAPTER_ONLY=9`. **Proposed:** assert `market_count=18 AND NO_PROVIDER=0 AND (LICENSED_ENABLED + DISABLED_ADAPTER_ONLY = 18)` (no market dropped; none live-routed to an unlicensed provider) rather than fixed enabled-counts that legitimately vary as markets are toggled.

### 6. Outcome
**GPD.16 / GPD.17 / GPD.19 remain NOT ACCEPTED** — the exact-SKU / fresh-evidence standard is not met and cannot be met zero-cost for the strongest candidate. GPD.01 remains open. Safeguards preserved: 5 release rows FALSE, billing closed to public ("founder-only pilot active; public checkout closed"), CJ/Kalodata/DataForSEO rights unchanged, supplier-image block intact, isolation intact, 11 GOLD units unchanged, FastMoss zero. **Credits/paid calls consumed this build: ZERO.**

---

## Addendum 26 — BE246 Exact-SKU verification engine + release-harness repair

**Date:** 2026-11-23. Founder-authorised engineering: (1) correct the two outdated release-verification assertions; (2) build the missing positive exact-variant verification path; (3) fix demonstrated defects + test. NOT authorised (and not done): paid/quota supplier calls, relaxing exact-SKU standards, FastMoss, releasing the 5 Merchant products, rights/Stripe changes. **ZERO paid/quota calls; ZERO Lovable rebuild; all fixtures synthetic + rolled back.**

### T1 — release-verification assertions repaired (mig_317); `fn_pd_release_verification` now `all_green=true`, 13/13
- **Area 7** replaced the obsolete "all rights FALSE" assertion with **source-specific** invariants: `reuse_creative`/`redistribute_raw`/`commercial_redistribution` FALSE for every provider; image publication cleared only for the documented GOLD source (KALODATA); customer display cleared only for KALODATA; `display_derived` limited to {KALODATA, CJ}; **and the customer-release gate verified independent** of research permissions (0 `customer_source_release` rows released). Documented Kalodata/CJ research rights allowed.
- **Areas 12-13** removed the hardcoded 13/5 topology. New invariant: all **18 markets represented** (`market_count=18`, plan length 18, `NO_PROVIDER=0`), without claiming each market has evidence, and **every dispatching route** (decision not `SKIP%`) uses an authorised+enabled provider with a valid market config, active schedule, approved budget and a call cap. Current topology (9 KALODATA-enabled / 9 disabled-adapter / 0 no-provider) passes; genuine release-safety checks (areas 11/16/17/18) untouched.

### T2 — authoritative identity evidence inventory
- **No universal retail barcode (GTIN/UPC/EAN/MPN) exists on either side** — not a structured column and not in Merchant/CJ JSON.
- Merchant products carry `extended.dataforseo_merchant_product_id` (`native_identity_kind=google_product_id`) + `dataforseo_merchant_correlated_ids` — authoritative **in Google's namespace only**; CJ holds none of these, so they cannot bridge Merchant↔CJ.
- CJ authoritative identifiers are **CJ-native**: `cj_pid`, `sku`, `vid` (variant catalog entries `{key, sku, vid, price_usd, weight_g, image}`; `key` encodes attributes, e.g. "Whitebeard 1pcs", "Combo pack 3pcs").
- **Legitimate cross-source links that DO establish same-product identity**: a CJ-origin demand product whose own identity IS a CJ pid (`candidate:pid:cjdropshipping:<pid>`), or a `supplier_refs` entry carrying an authoritative `match_method`. Title/photo/price/category similarity and legacy name-based supplier links do NOT.

### T3 — positive exact-variant path (mig_318/319), extending the existing resolver (no duplicate engine)
New evaluator `fn_cross_supplier_exact_variant_check` (fail-closed) requires: an authoritative shared product identity (SHARED_GTIN | CJ_NATIVE_NAMESPACE | AUTHORITATIVE_SUPPLIER_REF; conflicting identifiers fail); a **probed + fresh** supplier variant catalog; an exact variant **designated by the researched product** (or genuine single-variant) present in the catalog (a CJ-side-only id is insufficient; multi-variant with no designation is ambiguous → fail); and compatible material variant attributes. Tenant-scoped; FastMoss excluded. Wired into `fn_resolve_cross_supplier_identity`: it overrides to `EXACT_VARIANT_VERIFIED` / `variant_verified=true` / `bound=true` **only** on genuine evidence and never from SAME_PRODUCT_IDENTITY alone or against a form/contra conflict.

### T4 — fixtures (mig_320): `fn_exact_variant_verification_selftest` 11/11, zero residue
Synthetic, clearly-identified TEST fixtures (inserted + rolled back in-function). **Two positive exact results** (single-variant; multi-variant designated) incl. an **end-to-end resolver proof** (`identity_tier=EXACT_VARIANT_VERIFIED`, `variant_verified=true`). Negatives fail closed: wrong/absent variant, similar-title-different-product, missing identifier, conflicting identifiers, ambiguous candidates, stale evidence (400d); plus country-inventory-difference (identity country-agnostic), cross-tenant isolation, and Product Asset Lock / image-rights denial. Explicit disclaimer: fixture success is **not** proof of a real supplier match.

### T5 — real candidate discovery (no paid calls)
Only two real CJ-linked demand products exist, and **neither currently verifies exact**:
- `2f6f6101` "Leather Patch For Sofa Repair" (CJ-native, system tenant) — authoritative identity **present** (`CJ_NATIVE_NAMESPACE`), but `variant_catalog_absent_or_unprobed` (CJ row `c79b8a4c` never detail-probed).
- `e453eed4` "kids nightlight projector" (Reddit, founder tenant) — only a legacy name-based CJ link → `no_authoritative_product_identity`.
**No zero-cost exact match exists.** The single real product with authoritative cross-source identity (`2f6f6101`) needs exactly **one** piece of missing evidence: a CJ product-detail probe for pid `2608261145001630400` to populate the variant catalog (per-variant SKU/vid/attributes + stock + `detail_observed_at`). **Minimum authorised acquisition = 1 CJ product-detail call** (not made; not authorised). If that product is single-variant (or the researched product designates a specific variant with matching attributes), the engine would then verify EXACT. `e453eed4` additionally lacks any authoritative identifier and is not fixable by a CJ call alone. The rejected old-man ski-mask was not reused.

### T6 — architecture/frontend flow (mig_323)
Economics already flows: `fn_resolve_supplier_economics` reads `variant_verified` from `commerce_cross_supplier_identity` gated on a concrete binding with `selected_sku`, switching basis to `EXACT_VERIFIED` only when genuinely verified. Research interface gap fixed: `fn_product_supplier_candidate` had hardcoded `exact_variant_verified=false`; now emits `(d.dm='VERIFIED_EXACT_VARIANT')` (fail-closed; false in production today). Images blocked at source (mig_312 intact); freight approximate / margin UNKNOWN preserved (mig_310). No Lovable rebuild (frontend already reads the field).

### T7 — regression + safeguards
Green: pd_release 13/13 (`all_green`), exact-variant engine 11/11, cross-supplier identity 13/13, stage1 supplier-resolution, stage3b, competitor-evidence 5/5, stage2 shared-identifier, concrete-identity, supplier-gallery. Zero fixture residue. Safeguards intact: 5 release rows FALSE, public checkout closed, CJ images blocked, Kalodata/CJ/DataForSEO rights unchanged, 11 GOLD gates unchanged, 0 FastMoss functions. **GPD.16/17/19 NOT accepted** — the engine exists and is proven, but no genuine real-world exact evidence exists yet; acceptance awaits the one costed CJ detail probe above (founder decision) or a product with an authoritative shared identifier.

---

## Addendum 27 — BE247 First real CJ exact-variant evidence: preflight + image-leak closure + acquisition request

**Date:** 2026-11-23. Objective: move the first authoritative CJ-native product (Leather Patch for Sofa; CJ pid `2608261145001630400`; research product `2f6f6101`; **system/seed tenant** `00000000-0000-4000-8000-000000000001`) toward genuine exact-variant verification via the smallest justified acquisition. Engine NOT rebuilt; completed regression NOT repeated. **No CJ API call was executed; ZERO spend.**

### T1 — CJ product-detail preflight
1. **Endpoint:** the existing CJ integration (n8n credential "CJ Dropshipping API", `2IV5tXPu9jAItjKh`) uses `GET https://developers.cjdropshipping.com/api2.0/v1/product/query?pid=<pid>` for product detail + variant IDs (returns `data.variants[]` = `{vid, variantKey/variantNameEn, variantSku, variantSellPrice, variantWeight, variantImage}`), plus `product/stock/queryByVid` and `logistic/freightCalculate` for inventory/shipping. Established manual workflows exist (`Dvxf28AzZ741CVFz`, `OxH9sb6jKCqiqXOk`, `ZbhPyAuvDD4h4xid`); no duplicate client needed.
2. **Cost/quota:** CJ product/query, stock and freightCalculate are **free** (no provider credits; subject only to CJ's standard request rate limits).
3. **Entitlement/credentials:** working CJ credential present and backing a live search workflow; provider config `CJDROPSHIPPING` `enabled`, `access_state=AVAILABLE`.
4. **Budget:** `provider_call_budget` holds **no CJ row** (all rows are DATAFORSEO_*/KALODATA, all inactive) — CJ is free and was never credit-budgeted; `activation_authorizations` empty; `research_budget_config` a disabled SG row. **No existing founder-approved budget expressly covers this call.**
5. **Image exposure:** acquisition stores CJ image URLs in `supplier_enrichment` (backend). The economics interface blocks them (mig_312). **A latent leak was found and fixed:** the customer-facing research function `fn_product_supplier_candidate` emitted raw CJ image URLs ungated via the variant `image`, `reference_images[]`, `media.sample_images` and `media.gallery_images`. **mig_324 + mig_325** gate all four on the provider's `display_cache_images_cleared` (cj→'CJ'), emitting NULL/`[]` when unlicensed; image counts retained. Verified on the real ski-mask case under the owner's auth context: research output now contains **zero** `cjdropshipping.com`/`oss-cf` URLs, matching the economics interface.

### T2 — acquisition authorisation: NOT PRESENT → not executed
No existing founder-approved budget permits the call, so per the directive the acquisition was **not executed**. Acquisition request tabled for founder approval:
- **Calls (all free):** (1) `POST authentication/getAccessToken`; (2) `GET product/query?pid=2608261145001630400` → variant catalog + `variant_count`; and only if the product is multi-variant and economics are wanted, (3) `product/stock/queryByVid` + (4) `logistic/freightCalculate` to GB. **Minimum for verification = 2 calls; ≤4 total. One product only; no catalogue refresh.**
- **Cost/quota impact:** $0; no credits; CJ rate limits only.
- **Approval requirement:** express founder authorisation to run a single parameterised CJ product-detail probe for this one pid (the existing detail workflow is ski-mask-hardcoded, so a minimal parameterisation or founder-run is required — no new provider client).

### T3/T4 — verification + economics: not reached this build
No new evidence acquired, so the engine verdict is unchanged: `fn_cross_supplier_exact_variant_check` returns `exact=false`, `product_identity_method=CJ_NATIVE_NAMESPACE`, reason `variant_catalog_absent_or_unprobed`. Economics therefore stays `CANDIDATE_LISTING` basis, margin WITHHELD/UNKNOWN, CJ images blocked. (If the authorised probe runs and the product proves genuinely single-variant — or a researched-side variant is designated with matching attributes — the engine would then verify EXACT and economics would recompute.)

### T5 — customer-research eligibility (tenant isolation)
The leather patch is a **system/seed-tenant** product (`00000000-0000-4000-8000-000000000001`), not a founder/customer product. Even a successful supplier-identity verification there would **not** satisfy GPD.19: no system-tenant result is transferred or copied into the founder tenant, and supplier-identity verification is distinct from a customer-visible supplier-positive journey in a real tenant. GPD.19 cannot be accepted from a system-tenant verification.

### T6 — outcome
**GPD.16 / GPD.17 / GPD.19 remain NOT ACCEPTED** (no live exact evidence). Safeguards intact: 5 Merchant release rows FALSE, Stripe LIVE closed, CJ images blocked in **both** economics and research interfaces now, 11 GOLD gates unchanged, 0 FastMoss. **Smallest next action:** founder authorises the single free CJ `product/query` probe for pid `2608261145001630400`; on return the BE246 engine evaluates it (single-variant may qualify; multi-variant without research-side designation stays unverified).

---

## Addendum 28 — BE248 Limited CJ acquisition: bounded probe built; execution blocked on credential binding

**Date:** 2026-11-23. Founder approved **one bounded, zero-charge** CJ product-detail acquisition (pid `2608261145001630400`, leather patch, system/seed research product `2f6f6101`): ≤4 free CJ requests, $0, existing credential/integration, no catalogue refresh.

**Preflight re-confirmed:** CJ `product/query`, `product/stock/queryByVid`, `logistic/freightCalculate` are **free** reads under the current account (not credit-metered); `getAccessToken` throttled ~1/300s (token cached), reads ~1 req/sec, daily caps far above 4 — ≤4 sequential requests fit. **$0.** Reused credential `2IV5tXPu9jAItjKh` ("CJ Dropshipping API"); still exactly one such credential (no duplicate client).

**Built:** n8n workflow `zwTkywEYKsmojs6g` "Pulse — CJ Detail Probe (Leather Patch, BE248)" — Run → CJ Auth (`getAccessToken`) → CJ Detail (`product/query?pid=2608261145001630400`) → Build Enrichment (variant_catalog + `detail_observed_at`) → POST Ingest (`fn_ingest_cj_product_media`). Two free CJ calls; stock/freight deferred (not needed for identity verification).

**Execution blocked (0 CJ requests, $0):** manual run `30720` failed at CJ Auth with **"Credentials not found"** *before any outbound HTTP call*. `create_workflow_from_code` reported that HTTP Request nodes were "skipped during credential auto-assignment — must be configured manually": the **n8n MCP does not let an agent bind credentials to HTTP Request nodes** (a security guardrail). Editing an existing bound workflow hits the same guardrail (agent writes unbind HTTP-node credentials), and all existing CJ *detail* workflows are hardcoded to other pids. So the authenticated call cannot be made autonomously through the MCP.

**Verification unchanged (no new evidence):** `fn_cross_supplier_exact_variant_check` for the leather patch (system tenant) stays `exact=false`, `product_identity_method=CJ_NATIVE_NAMESPACE`, reason `variant_catalog_absent_or_unprobed`. Economics `CANDIDATE_LISTING`, margin UNKNOWN; no inventory/shipping acquired; catalog still unprobed. Image gates, tenant isolation and PAL preserved; no system→founder tenant transfer; no Merchant release; Stripe unchanged.

**Smallest next action (one-time human step, then zero-cost):** in the n8n UI open `zwTkywEYKsmojs6g` (`https://tradingb.app.n8n.cloud/workflow/zwTkywEYKsmojs6g`), bind the existing "CJ Dropshipping API" credential to the **CJ Auth** and **CJ Detail** nodes and "Supabase account" to **POST Ingest**, then **Run** once (2 free CJ calls). On return, the BE246 engine evaluates the real variant catalog — a genuinely single-variant product may verify EXACT; a multi-variant product without a research-side variant designation returns UNKNOWN (no manufactured match). Optional ≤2 further free calls (`stock/queryByVid` + `freightCalculate→GB`) complete economics if verified.

---

## Addendum 29 — BE248 continuation: CJ acquisition EXECUTED and verified (first real CJ supplier evidence)

**Date:** 2026-11-23. The founder bound the credentials in n8n; Claude independently verified the bindings, executed the bounded probe, validated the real response, ingested, and ran the BE246 engine. **Bounded: 2 of 4 free CJ requests, $0.**

### Execution
Workflow `zwTkywEYKsmojs6g`, execution **30721 = SUCCESS**. Verified bindings before running: CJ Auth → credential `2IV5tXPu9jAItjKh`; CJ Detail → auth None + header `CJ-Access-Token = {{ $('CJ Auth').first().json.data.accessToken }}`, `pid=2608261145001630400`; POST Ingest → `supabaseApi` `jMhzgwaHX9jwZ7rA`. (The prior failure `30720` was the unbound credential.)

### Real CJ response (validated, not just HTTP 200)
`code 200, result true, "Success"`, requestId `b12708c23fc548209f3b83a4d9258879`. **pid `2608261145001630400` confirmed** = "Leather Patch For Sofa Repair Restoration And Touch-up"; product SKU `CJYD3099115`; category Home/Garden/Furniture › Home Office Storage; sellPrice **0.95–1.71 USD**; **20 genuine variants** (colour × size — 12 colours @ 50×68CM + 8 @ "100 Length 68 Width Cm"/Beige/Off-White). Example: key `Black-50X68CM`, vid `2608261145001631600`, sku `CJYD309911501AZ`, 0.95 USD, 730 g. `detail_observed_at` 2026-11-23T14:54:14Z.

### Ingestion
`fn_ingest_cj_product_media` → `status ok, updated 1, variant_count 20, image_count 21`. The global supplier row (`cjdropshipping`/`2608261145001630400`) now carries the real `variant_catalog` (20) + fresh `detail_observed_at`; merge added evidence without overwriting/contradicting the authoritative identity (same product/title/SKU; was `variant_count=0`).

### Exact-variant verdict (BE246 engine, REAL evidence)
`fn_cross_supplier_exact_variant_check` → **`exact=false`**, `product_identity_method=CJ_NATIVE_NAMESPACE` (authoritative identity CONFIRMED), reason **`ambiguous_no_variant_designation`**. Resolver end-to-end: `identity_tier=UNVERIFIED`, `variant_verified=FALSE`, `bound=false`, `confidence=NONE`. This is the correct, disciplined outcome: the product genuinely has 20 variants and the system-seed research product `2f6f6101` designates none (`selected/displayed/required_variant` all null), so **no exact-SKU was manufactured.**

### Economics
`fn_resolve_supplier_economics` → `status=no_candidate`, `basis=null`, margin UNKNOWN (no verified exact variant; no fabricated margin). `product/stock/queryByVid` and `freightCalculate` were **not called** (not justified without an exact variant) — 2 of 4 CJ calls used.

### Image rights, tenant isolation, integration
21 CJ image URLs stored **backend-only** (`SUPPLIER_PROVIDED_REFERENCE_ONLY`); `CJ.display_cache_images_cleared=false`; the customer-facing economics path emits **0** `cjdropshipping.com` URLs; research-interface gates (mig_324/325) + economics gate (mig_312) intact; PAL preserved. The product stays **system/seed tenant** — not transferred to the founder tenant and not presented as a released customer-tenant journey. Verified-path functions (`fn_resolve_cross_supplier_identity`, `fn_product_supplier_candidate`, `fn_resolve_supplier_economics`) all return honest unverified/UNKNOWN states; no Lovable rebuild.

### Regression + safeguards
pd_release 13/13 (`all_green`), exact-variant engine 11/11, cross-supplier identity 13/13. Preserved: FastMoss retired (0 functions), CJ images blocked, 5 DataForSEO Merchant release rows FALSE, Stripe public checkout closed, founding-member-only, founder-only store/ads, tenant/country isolation, provider-budget enforcement, PAL, 11 GOLD gates.

### Outcome
**GPD.16 / GPD.17 / GPD.19 remain NOT ACCEPTED** — genuine real CJ evidence is now acquired and the identity is authoritatively confirmed, but exact-SKU is UNKNOWN by design (multi-variant, no research-side designation). **Remaining blocker:** a research/opportunity-side designation of one specific variant (colour+size) mapping to a CJ vid/sku on a real customer product (single-variant auto-qualification does not apply to this 20-variant product); then economics (stock/freight ≤2 further free calls + a credible selling price).

---

## Addendum 30 — BE249 Real exact-variant customer journey: no customer-eligible candidate qualifies

**Date:** 2026-11-23. Read-only investigation (prior BE246 engine + BE248 acquisition not repeated). **0 provider requests, $0** — BE248's unused CJ allowance was explicitly **not** reused for a different product.

### T1 — customer-eligible candidate discovery
Only two tenants hold products: founder `7c8ddf9d` (261, TENANT_PRIVATE) and the system seed (1, the leather patch — not customer-eligible). No separate founding-member product tenants. Founder binding tables: `commerce_concrete_supplier_resolution` has 9 rows (8 `NO_VALID_CJ_MATCH`/unbound; 1 bound = `e453eed4`); `commerce_cross_supplier_identity` has 1 row (ski-mask `56a6af36`, SAME_PRODUCT_IDENTITY, `variant_verified=false`, FastMoss-origin). No DataForSEO Merchant product has a CJ supplier candidate (Google-namespace only); Merchant pilots stay release-gated.

**Quantitative verdict (261 customer-eligible products):** **0** with authoritative product identity, **0** with a research-side variant designation, **1** with a CJ supplier link (non-authoritative).

### T2 — research-side variant-designation preservation
The architecture **can** store a designation: `commerce_products.extended` (`selected_variant_sku`/`displayed_variant_sku`/`required_variant_attributes`, read by the BE246 engine) and `commerce_concrete_supplier_resolution.selected_variant` at the binding level. But **0** customer-eligible products carry any variant-attribute key, because the research sources are keyword/category/product-level (Reddit "ISO" posts, eBay-category titles, DataForSEO merchant product-level) and contain **no** specific colour/size/model/quantity. The information is **absent at source**, not dropped by ingestion — so there is no genuine ingestion/identity defect to fix. Wiring the lone binding's supplier-side `selected_variant` into the engine would promote a random/heuristic variant on a non-authoritative link (explicitly forbidden) — not done.

### T3 — supplier verification (genuine candidates, no synthetic matches)
`e453eed4` "kids nightlight projector": demand is a Reddit keyword resolved via 148 eBay-category titles to a **generic** concept (`variant_attributes:[]`), heuristically linked to CJ `2608250310481611400` (stale 2026-09-05, `variant_count=0`, no URL). Its `concrete_supplier_resolution` over-claims `EXACT_SUPPLIER_IDENTITY_RESOLVED`/`shared_identifier:true` (legacy BE215-era), but the **BE246 engine correctly returns `exact=false`, `no_authoritative_product_identity`**, and the customer-facing `fn_product_supplier_candidate` + `fn_resolve_supplier_economics` both return `no_candidate`, exact flag null, **0** `cjdropshipping.com` URLs. The legacy label does **not** propagate to any acceptance — the strict layer holds; no fix needed and none that wouldn't manufacture a match. Ski-mask stays SAME_PRODUCT_IDENTITY/`variant_verified=false`; leather patch is system-tenant.

### T4–T6 — economics, journey, regression, safeguards
Economics not run (no genuine exact variant; no new provider calls). Customer journey: strict layer safe — no false-exact, CJ images blocked (`display_cache_images_cleared=false`, 0 URLs leaked), tenant isolation preserved (system-tenant leather patch not presented as a customer journey; no cross-tenant copy), Merchant pilots not exposed. Regression green: pd_release 13/13 (`all_green`), exact-variant engine 11/11, cross-supplier identity 13/13. Preserved: FastMoss retired (0 functions), CJ images blocked, 5 Merchant release rows FALSE, Stripe public checkout closed, founding-member-only, founder-only store/ads, tenant/country isolation, provider-budget enforcement, PAL, 11 GOLD gates.

### Outcome
**GPD.16 / GPD.17 / GPD.19 remain NOT ACCEPTED.** **Exact missing evidence** to accept GPD.16 on a customer-eligible product: (1) an **authoritative product identity** (GTIN/UPC/EAN, a CJ-native-origin product, or a genuine shared identifier) — none of the 261 have one; (2) a **source-backed research-side variant designation** (colour+size+model+quantity) — none exist; (3) **fresh CJ detail** for a genuinely same-identity CJ product. Then GPD.17 economics and GPD.19 journey follow. No GOLD gate accepted on fixture-only or system-tenant evidence.

---

## Addendum 31 — BE250 Product-level identity & variant evidence: legacy reconciliation + designation workflow

**Date:** 2026-11-23. Engineering within existing authority. **No provider calls, $0** (BE248's allowance not reused). No BE246 engine rebuild.

### T1 — legacy overclaim reconciled (mig_326)
The founder kids'-nightlight-projector binding (opp `e453eed4`, GB) reported `identity_result=EXACT_SUPPLIER_IDENTITY_RESOLVED` + `bound=true` on a **non-authoritative** demand identity (reddit keyword → generic eBay category; no authoritative shared identifier). Two downstream/customer-research readers surfaced it as verified (`fn_product_bound_supplier_identity` → `has_bound_supplier=true`; `fn_ecommerce_product_intelligence_core` → `status=identity_result`, `variant_state=SUPPLIER_VARIANT_RESOLVED`). **Fix (non-destructive):** downgraded only the two operational verdict fields to `NO_VALID_CJ_MATCH` / `bound=false` (the value the current resolver assigns to every comparable row) and preserved the originals + the `shared_identifier` claim verbatim in `provenance.be250_reconciliation`; `supplier_match_evidence`, `selected_sku`, `selected_variant`, `concrete_identity` all untouched. Verified: **0** `EXACT_SUPPLIER_IDENTITY_RESOLVED` rows remain; both readers now return `has_bound_supplier=false` / no exact status; audit trail intact.

### T2 — identifier preservation in ingestion (no defect)
The authorised ingests already preserve the authoritative identifiers the sources actually supply: CJ `fn_ingest_cj_product_media` keeps `cj_pid`/`sku`/`vid`/variant attributes (BE248); the DataForSEO Merchant ingest captures `google_product_id` (`native_identity_kind=google_product_id`) + `product_url`/`seller` when present (the persister maps `coalesce(product_url,url)`). The 160 merchant rows have no `product_url` because the Google-Shopping responses didn't supply one (a **source absence, not a drop**). No universal barcode (GTIN/UPC/EAN/MPN) appears in any authorised response, so nothing authoritative is dropped, and no unbridged cross-source ID equivalence is inferred. **No ingestion change made** (adding speculative GTIN fields the sources never return would be dead code).

### T3 — research-side variant designation workflow (mig_327/327b/328/329)
New `public.fn_set_research_variant_designation(tenant, product, attributes[], variant_sku, variant_vid, basis, source, overwrite)` — SECURITY DEFINER, `search_path=''`, tenant-auth-guarded (`auth.uid()=p_tenant` or `service_role`; PUBLIC/anon revoked). It retains colour/size/model/quantity + optional supplier-native sku/vid with `basis` (SOURCE_OBSERVED vs USER_SELECTED), source, timestamp, tenant; **rejects ambiguous/conflicting** designations; optionally resolves attributes to the single matching variant in an already-probed CJ catalog (refuses on 0 or >1 — never a random pick); writes `selected_variant_sku/vid` + `required_variant_attributes` that the **existing BE246 engine** reads (no duplicate engine). It sets `authoritative_identity=false` and **never establishes product identity** — a USER_SELECTED preference cannot make identity authoritative (the engine evaluates authoritative cross-source identity independently). Selftest `fn_research_variant_designation_selftest` **5/5** (rolled back): attributes→unique variant→**engine EXACT** on an authoritative CJ-native product; ambiguity rejected; preference-can't-establish-identity; conflict rejected; cross-tenant rejected.

### T4 — real-product qualification
**No customer-eligible founder product qualifies:** 0 of 261 founder products carry an authoritative identity (confirmed). The only authoritative CJ-native product with a probed catalogue is the **system-tenant** leather patch — not copied into the founder tenant, and system-tenant evidence cannot accept a GOLD gate. **Smallest justified acquisition** (not executed — needs its own authorisation, and BE248's allowance is not reusable): the founder picks one specific CJ product to research so the founder-tenant demand product carries an authoritative CJ-native identity, one free `product/query` probes its catalogue, then a variant is designated via the new workflow — at which point the BE246 engine can verify EXACT for a customer-eligible product.

### T5–T7 — economics, regression, safeguards
Economics not run (no customer-eligible verified exact variant; no provider calls). Regression green: pd_release 13/13 (`all_green`), exact-variant engine 11/11, cross-supplier identity 13/13, research-variant-designation 5/5, stage3b. Safeguards intact: FastMoss retired (0 functions), CJ images blocked, 5 Merchant release rows FALSE, Stripe public checkout closed, founding-member-only, founder-only store/ads, tenant/country isolation, provider-budget enforcement, PAL, 11 GOLD gates. **GPD.16/17/19 remain NOT ACCEPTED** — the full pipeline (identity → designation → engine → economics) is now built and proven end-to-end, but no customer-eligible product yet has the authoritative identity it requires. **Exact next action:** founder authorises one specific CJ product-detail acquisition (as in BE248) for a founder-tenant research product, then designate its variant; the engine verifies and economics follow.

---

## Addendum 32 — BE251 First customer-eligible CJ-native product: determination + bounded acquisition request

**Date:** 2026-11-23. Read-only determination; **no DB changes, no provider calls, $0.** Engine/RPC/image safeguards not rebuilt.

### T1/T2 — no eligible already-acquired candidate; no authoritative founder link
The authorised CJ catalogue holds **exactly two** probed (variant-catalogue) products, both excluded for a customer demo: the **leather patch** `2608261145001630400` (fresh, 20 variants — but the directive forbids reusing the system-tenant leather patch as customer proof) and the **ski-mask** `2609290358281623700` (**33.4 days stale**, fails the engine's freshness window, **and** FastMoss-linked on the demand side — excluded). `fresh_probed_non_leatherpatch_non_fastmoss = 0`. Separately, **0 of 261 founder-tenant products** carry an authoritative CJ-native / GTIN identity, so no existing founder product can be authoritatively linked to a fresh CJ product. Every other CJ supplier row is unprobed (`variant_count=0`) and stale.

### T3/T4 — fresh evidence is required; acquisition needs new authorisation
Because no eligible, fresh, probed, non-excluded CJ product exists and no founder product has authoritative CJ identity, **existing data is not sufficient** to establish the first *customer-eligible* CJ-native exact-variant journey. A fresh CJ acquisition of a founder-selected product is necessary. Per the directive this requires **explicit founder authorisation** — BE248's one-off allowance was for the leather patch only and is **not** reused, and the leather patch itself is not reused.

**Bounded acquisition request (smallest justified set; for founder authorisation):**
- **Product:** ONE CJ product the founder selects with a genuine research use case in a supported market (GB/DE/FR/ES/IT/US/MY/PH/SG) — **not** the leather patch and **not** a FastMoss-origin product. (Founder names the pid, or confirms a specific candidate.)
- **Endpoints (all free):** `authentication/getAccessToken` ×1; `product/query?pid=<pid>` ×1 (variant catalogue); and only if a specific variant is designated and economics are wanted, `product/stock/queryByVid` ×1 + `logistic/freightCalculate→<market>` ×1.
- **Calls:** ≤4. **Entitlement:** existing "CJ Dropshipping API" credential (live). **Limits:** CJ standard rate limits only. **Cost:** **$0** (reads are free). **Existing authorisation:** none for a new product — **new explicit authorisation required.**
- **On authorisation**, the fully-built mechanism completes the journey: create a founder-tenant **supplier-origin** research item (clearly labelled supplier-origin, not a market winner) via the existing authorised process; designate the variant via `fn_set_research_variant_designation` (BE250); verify via the BE246 engine; economics via `fn_resolve_supplier_economics` (margins UNKNOWN without a credible selling price); surface through the research interface with images blocked + tenant/country isolation.

### Regression + safeguards
Green: pd_release 13/13 (`all_green`), exact-variant engine 11/11, research-variant-designation 5/5. Intact: 0 released Merchant rows, Stripe public checkout closed, 0 FastMoss functions, CJ images blocked, 0 EXACT overclaims, 11 GOLD gates. **GPD.16/17/19 remain NOT ACCEPTED** — not marked on a supplier-catalogue import or system-tenant evidence. **Remaining blocker:** one founder-authorised, founder-selected CJ product acquisition (as specified above); everything downstream is built and proven.

---

## Addendum 33 — BE252 CJ product shortlist + acquisition decision (proposal only)

**Date:** 2026-11-23. Read-only shortlist from the existing CJ catalogue; **no provider calls, $0, no DB changes.** Excluded: leather patch `2608261145001630400`, FastMoss-origin evidence (ski-mask `2609290358281623700`), category/identity conflicts, and unsupportable commercial claims. All figures are **stored historical** evidence (observed Sept–Oct 2026); none has a probed variant catalogue, so current variants/stock/freight are **UNKNOWN** until a fresh probe, and **none is a market winner** (no independent demand evidence).

### Five-product GB shortlist
| # | Product | CJ PID | SKU | Function | Supplier cost (hist.) | Last obs | Notes |
|---|---|---|---|---|---|---|---|
| 1 ⭐ | Rain Cloud Air Humidifier / 7-colour night-light aroma diffuser | `2103378852506546177` | CJSN3195865 | Desktop humidifier + aroma + night-light | $8.61 USD, 650 g | 2026-09-28 | Single function; likely few variants (colour/plug); coherent category (Night Lights); strong GB home/wellness use case |
| 2 | Portable Nano-Ion Facial Steamer | `2104518362322178049` | CJMB3206221 | Facial steamer (beauty) | $11.70 USD, 155 g | 2026-09-29 | Single function; likely few variants; clear GB beauty use case |
| 3 | 10-pack LED GU10 Bulbs 7 W | `2100846071883689986` | CJTH3176429 | LED spotlight bulbs | $10 USD, 300 g | 2026-09-20 | Simple; likely 1–2 variants (warm/cool white); clear GB home use |
| 4 | Digital Camera Shoulder Bag (DSLR/SLR) | `2104139826061291521` | CJSY3202279 | Camera carry bag | $14 USD, 520 g | 2026-09-27 | Accessory; likely few variants (size/colour) |
| 5 | Children's Touch-Screen Electronic Piano Toy | `2104100222843138050` | CJYZ3201504 | Kids' music toy | $11 USD, 300 g | 2026-09-27 | Likely 1–2 variants; plausible GB toy use case |

Rejected examples: Grim-Reaper costume (many size variants → ambiguity); "Premium ZIP Trading Card Binder" (stored under category *Dual SIM Card* → identity conflict); "99,000,000 LM Military Tactical Flashlight" (unsupportable commercial claim).

### Recommendation (not a market-opportunity ranking)
**#1 — Rain Cloud Air Humidifier, CJ PID `2103378852506546177`.** Preferable because: a clear single-function consumer product with a coherent category and a strong, supportable GB home/wellness use case; low historical supplier cost ($8.61) giving later economics headroom; likely **few, understandable variants** (colour/plug), which minimises the variant ambiguity the exact-SKU engine guards against and maximises the chance of a single clean exact variant; lightest/freshest of the strongest options. Ordering reflects demonstration suitability, **not** verified market opportunity.

### Bounded acquisition proposal (PROPOSAL ONLY — do not execute until founder authorises the exact PID + scope)
- **Product:** one only — CJ PID `2103378852506546177`.
- **Endpoints (free):** `authentication/getAccessToken` ×1; `product/query?pid=2103378852506546177` ×1 (current variant catalogue, cost, title); then only if a specific variant is designated and economics wanted, `product/stock/queryByVid` ×1 + `logistic/freightCalculate→GB` ×1.
- **Max 4 free CJ API requests; $0;** existing "CJ Dropshipping API" credential + the BE248 n8n pattern; **no broad catalogue refresh.**
- **Authorisation:** none yet — requires explicit founder sign-off on this PID and scope (BE248's allowance is not reused). If authorised, the supplier-origin research item is created via the existing founder-tenant workflow with clear CJ-origin provenance, tenant/country isolation, genuine variants, CJ images blocked, and **real exact-variant evidence required before any GPD.16/17/19 acceptance** — never masquerading as an independently discovered market winner.

**GPD.16/17/19 remain NOT ACCEPTED** (shortlist/recommendation is planning, not verified evidence).

## Addendum 34 — BE253 founder-approved CJ acquisition EXECUTED; product delisted; GPD.16/17/19 still NOT ACCEPTED

**Date:** 2026-11-23. Founder granted explicit approval to acquire the BE252-recommended product. Executed within every hard limit: **$0; 2 of 4 CJ requests used; no retries; no activation; one product only.**

### Authorised + executed
- One product only: Rain Cloud Air Humidifier, **CJ PID `2103378852506546177`** (hist. SKU CJSN3195865, $8.61, obs 2026-09-28).
- n8n workflow `zwTkywEYKsmojs6g` retargeted from the BE248 leather-patch pid to this pid using **surgical `setNodeParameter` JSON-Pointer patches** (CJ Detail query param + Build Enrichment fallback) + a metadata rename. This avoided the SDK credential-unbind risk: the founder-set bindings (CJ Dropshipping API on CJ Auth; Supabase account on POST Ingest) were **left intact** (`autoAssignedCredentials:[]`, verified by re-fetch). Activation stayed off. Executed manually (execution 30722), free CJ endpoints only.

### Real CJ response
- Call 1 `authentication/getAccessToken` → success (access token never recorded anywhere).
- Call 2 `product/query?pid=2103378852506546177` → **`code 1602002, result=false, "Product has been removed from shelves", data=null`.**
- **2 of 4 CJ requests used; $0** (CJ `pointsInfo` is a free daily rate-limit allowance, not a monetary charge; no paid endpoint touched).

### Honest reconciliation (non-destructive)
- The ingest (`fn_ingest_cj_product_media`, UPDATE-only) merged an **empty** enrichment into the pre-existing global supplier row `97b4d58f…`. Corrected so it reads as a delisting, not a "successful 0-variant probe": `availability_status=REMOVED_FROM_SHELVES`, `variant_catalog_status=UNAVAILABLE_PRODUCT_DELISTED`, `be253_probe={outcome, cj_code 1602002, cj_message, pid, cj_request_id, observed_at, directive}`. `raw` (historical Sept-2026 fields incl. sellPrice 8.61 / productSku CJSN…) untouched.

### Exact-variant verification — fail-closed (mig_330)
- `fn_be253_delisted_probe_check()` (durable, self-rolling-back fixture) runs the BE246 engine against the REAL delisted supplier row: **`exact=false`, reason `variant_catalog_absent_or_unprobed`, identity_method `CJ_NATIVE_NAMESPACE`.** Safety property proven: a delisted / empty-catalog product never verifies EXACT even with authoritative CJ-native identity.
- No founder-tenant customer-eligible research item was created — a delisted product is not customer-eligible. `0` false-EXACT rows for the pid.

### Economics / customer journey
- **Not run / not applicable.** No genuine exact variant → supplier economics correctly WITHHELD. No customer-eligible product → no browser journey to demonstrate. No stock/freight calls made (the remaining 2 of the 4-call budget were scoped to this now-dead pid).

### Safeguards
- No system-tenant→founder copy; no synthetic demand/variant/economics inserted. Image/rights gates untouched (`CJ.display_cache_images_cleared` stays FALSE; enrichment `images:[]`). No Merchant release; founding-member policy unchanged; no payment/licensing changes.
- Regression: **pd_release all_green=true (13/13)**, research_variant_designation selftest **5/5**, be253_delisted_probe **ok**.

### Acceptance + escalation (founder decision required)
- **GPD.16, GPD.17, GPD.19 remain NOT ACCEPTED.** No GOLD flip. The single authorised product is unavailable at the supplier; exact-SKU verification cannot proceed on it. This is a genuine external blocker (supplier delisting), not a fixable technical failure.
- **Founder to authorise ONE specific replacement PID.** The BE252 shortlist #2–#5 remain candidates, but all were observed Sept 2026 — like #1, which has since been delisted — so **live availability must be re-confirmed by a fresh bounded probe.** A different product requires fresh sign-off; BE253's remaining 2 calls were scoped to the humidifier.
  - #2 Portable Nano-Ion Facial Steamer — `2104518362322178049` (CJMB3206221, $11.70)
  - #3 10-pack LED GU10 Bulbs 7 W — `2100846071883689986` (CJTH3176429, $10)
  - #4 Digital Camera Shoulder Bag — `2104139826061291521` (CJSY3202279, $14)
  - #5 Children's Touch-Screen Piano Toy — `2104100222843138050` (CJYZ3201504, $11)
- Standing recommendation for the next acquisition: have the probe confirm live availability **first** (auth + product/query), and only then spend stock/freight calls — so a delisted product never consumes the economics budget.

## Addendum 35 — BE254 US market pivot: US product discovery + 5-product shortlist + recommendation (read-only, $0)

**Date:** 2026-11-23. Founder directive: change the supplier-qualification target market **GB → US**; prioritise newly discovered, product-specific US opportunities over old CJ catalogue items; do **not** continue the delisted Rain Cloud Humidifier or auto-pick another Sept-2026 CJ catalogue item. **No new CJ/DataForSEO acquisition authorised** — reuse existing evidence; request one bounded approval only after selecting the strongest candidate. Executed **read-only on product data ($0, 0 provider calls)**; only the GOLD tracker + this doc were written.

### What the stored US evidence actually shows
- **Kalodata US video research: 0 rows** (`kalodata_video_research` market='US'). No US TikTok social/ad evidence stored.
- **Fresh US cohort (first-observed 2026-11-20, evaluated 2026-11-23):** ~25+ `dataforseo_merchant` **star/galaxy/night-light projector** listings (identity_basis platform_id, US $14.99–$139.99) + a few `kalodata` US TikTok Shop items. The projectors are product-specific and US but **thin** (1 signal each, n=1 competitor) and **mostly branded** (Govee, POCOCO, Rossetta, Anysun, DAYBETTER, Monster, Cowin, Slagawa, Tradufa, Morfone, Thames & Kosmos) → not CJ-exact-matchable without substitution. The Kalodata US items are largely big-brand/retail (Insignia Fire TV, Shark, ULTA, EcoFlow, refurb MacBook, 4Patriots) → poor CJ/dropship fit.
- **Richest independent US demand** sits on category-level `normalized_name` concepts: **"kids nightlight projector"** (e453eed4 — **394 demand signals**; 56 US competitors $4.95–$283.99 median $17.95; MEDIUM; coverage 0.63; score 73) and "coaxial cable" (77004cbb — multi-source US search + Meta Ad Library + eBay, score 88.6, but a commodity → unsuitable for exact-SKU dropshipping).
- **eBay US price observations** (`market_price_observations`, Sept 2026, EBAY_BROWSE, **not product-linked**): genuine USD price+listing-depth for ~30 generic dropship queries (e.g. automatic laser cat toy $5–$73.99/622 listings; cordless tire inflator $11.99–$189.99/16,792; smart bird feeder camera; smart flame humidifier $6.99–$135.99/55).
- **Supplier bridge reality:** `commerce_cross_supplier_identity` holds exactly **one** CJ bridge — the **EXCLUDED** GB FastMoss ski-mask (56a6af36 ↔ 2609290358281623700, SAME_PRODUCT_IDENTITY, not EXACT, variant_verified=false). **Zero US→CJ bridges; zero EXACT-verified bridges anywhere.** CJ catalogue holds **75** projector/galaxy/night-light SKUs but **0 probed** (no variant catalogues).
- **Freshness honesty:** the Nov-20 cohort is "first observed by Strateloq 2026-11-20" (recent DB import), **not** genuinely new-to-market — bedroom galaxy/star projectors are an established US category. Data-quality flag: Govee d985e5af carries a **GBP** price (not US evidence; excluded from US economics).

### Five-product US shortlist (honest; existing evidence reused only)
| # | Product | Authoritative identifier | Source · first obs | US demand evidence | US competition | US price (USD) | Supplier-match feasibility | Missing evidence / confidence | Suitability |
|---|---|---|---|---|---|---|---|---|---|
| 1 ⭐ | **Bedroom star/galaxy night-light projector (generic)** | Concept e453eed4 (`normalized_name`; NOT single-SKU) + generic listings ca945686/a37f20e0/bf40764c (`platform_id`, name-based) | reddit 2026-09-05 + dataforseo_merchant 2026-11-20 | **Strong** — 394 signals, 56 US competitors median $17.95; corroborated by 25+ fresh listings | 56 independent US competitor listings | $14.99–$139.99 (merchant); $4.95–$283.99 concept | **HIGH** — 75 CJ generic SKUs (0 probed); needs 1 chosen SKU | No authoritative single-SKU identity; no CJ bridge; no verified variant. **MEDIUM (category) / LOW (SKU)** | **BEST research candidate** (anchor to GENERIC SKU) |
| 2 | Generic "13-in-1 Planetarium / 360° Sky" projector | 84af56b0 / ca945686 (`platform_id`, name-based) | dataforseo_merchant 2026-11-20 | Weak standalone (shares #1 category demand) | n=1 merchant listing | $14.99 / $69.99 | HIGH (same CJ pool) | Thin (1 signal); no CJ bridge. **LOW** | Concrete SKU anchor for #1 |
| 3 | RGBIC wall-wash / corner floor lamp | 207dbaa8 (`platform_id`, TikTok Shop) | kalodata (US) 2026-11-20 | **Minimal** — single listing; coverage 0.0 | None observed independently | $30 | MODERATE (CJ has generic RGBIC lamps) | No independent demand/competition; no CJ bridge. **LOW** | Fresh + TikTok-native; needs demand first |
| 4 | Automatic laser cat toy | None (query-level only) | eBay-US 2026-09-11 | 622 US listings | 622 US listings (presence, not sellers) | $5–$73.99 median $27.99 | MODERATE/HIGH (classic CJ dropship) | Older; no product record/identity; no bridge. **LOW** | Genuine generic dropship; needs identity + re-observation |
| 5 | Cordless portable tire inflator | None (query-level only) | eBay-US 2026-09-11 | 16,792 US listings (deepest) | 16,792 US listings (presence) | $11.99–$189.99 median $30.95 | MODERATE (CJ carries inflators) | Older; no identity; high competition; no bridge. **LOW** | High-volume utility; needs identity + freshness |

Excluded with reason: coaxial cable (richest signals but commodity → exact-SKU/dropship meaningless); branded projectors + Kalodata retail brands (Govee/POCOCO/Insignia/Shark/ULTA/EcoFlow/MacBook/4Patriots → IP + not CJ-exact-matchable). No invented revenue, seller identities or demand; absence treated as UNKNOWN, never "low competition".

### Recommendation (Task 3)
**#1 Bedroom star/galaxy night-light projector (generic).** Best *combination* of durable independently-observed US demand (e453eed4: 394 signals, 56 US competitors, median ~$18), freshness corroboration (Nov-20 cohort), clear function/problem (sleep/ambience/kids' night-light) and genuine CJ supplier-match feasibility (75 generic SKUs). Deliberately **not** the highest-score row (coaxial cable 88.6) — chosen on evidence quality + supplier feasibility + IP safety. **Caveats:** demand evidence is category-level (not a single authoritative SKU); fresh product-specific listings are thin; **no authoritative exact-SKU CJ bridge exists yet**; must anchor to a *generic* CJ projector (not branded) to avoid substitution/IP risk.

### Task 4 — exact supplier matching
No existing authoritative US→CJ identity bridge (0). 75 generic CJ projector SKUs available (0 probed). Matching a CJ look-alike to a branded listing would be prohibited substitution. BE246 engine + BE250 designation ready but have nothing authoritative to verify. **Smallest acquisition:** one bounded CJ probe to select + bind a specific generic CJ galaxy-projector SKU, then verify the exact variant.

### Task 5 — US economics (honest UNKNOWN)
US selling-price evidence exists (merchant $14.99–$139.99; concept median $17.95). No verified exact CJ variant ⇒ no CJ unit cost, no US inventory/shipping eligibility, no US freight ⇒ **US landed cost + margin = UNKNOWN**. GB freight / GBP prices not used.

### Task 6 — bounded provider-call request (NOT executed; needs explicit founder sign-off; BE253 allowance NOT reused)
- **Product:** recommended generic bedroom star/galaxy night-light projector (specific CJ pid chosen from the search result).
- **Endpoints (free):** `getAccessToken` ×1; `product/list?keyword` (US) ×1 to pick ONE generic CJ SKU; `product/query?pid=<chosen>` ×1 for the variant catalogue; then only after a clean exact variant is designated: `product/stock/queryByVid` ×1 + `logistic/freightCalculate`→**US** ×1.
- **Calls/cost:** ≤4 free CJ requests, **$0**; existing CJ credential; no catalogue refresh/retries/activation.
- **Expected evidence:** authoritative CJ SKU + variant catalogue → BE246 exact verification → US stock + US freight → US landed cost/margin.
- **Optional (chargeable, NOT requested now):** DataForSEO US search/ads deepening — deferred.

### Task 7 — safeguards
Read-only on product data; writes limited to GOLD tab + this doc. US isolation, founder-tenant ownership, Product Asset Lock, CJ image block (display_cache_images_cleared FALSE), the 5 locked DataForSEO Merchant pilots (untouched/not exposed), customer research-only permissions, attribution/freshness, honest UNKNOWN — all intact. Demand (DataForSEO/eBay/Meta) and supply (CJ) kept distinct. Save/Monitor unaffected.

### Task 8 — GOLD roadmap
Updated only **LIVE MASTER — GOLD** rows GPD.16/17/19 (status/next-action/evidence/date) for the US pivot — **no acceptance flips** (requirements unmet). GPD.06–11 / GPD.22 remain blocked on the GPD.01 display-rights leg, not on evidence; the new US evidence supporting them is recorded here rather than by flipping those gates.

## Addendum 36 — BE255 US projector supplier-selection preflight (read-only, $0, no API calls)

**Date:** 2026-11-23. Continues BE254 (US market, generic star/galaxy/night-light projectors). Inspected the existing CJ projector supplier records only — no provider calls, no market re-investigation, no writes except this doc + GOLD GPD.16 next-action. Field audit of the 63 decorative/relevant CJ projector rows: all carry supplierName/sourceFrom/weight; **none** carries list-level variants, **none** carries any stored US/country shipping hint, **none** is flagged delisted, **0** are probed. So shipping eligibility + current availability are UNKNOWN from the catalogue and must come from the probe (not claimed from historical records).

### Three-product comparison (generic, CJ-native, no known delisting, no FastMoss)
| # | CJ PID | SKU | Product | Cat | Hist. price (USD) | Weight | CJ obs / last seen | Listed | Variant-risk | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 ⭐ | `2610010255571606100` | CJJT3213323 | USB Star Projector Night Light w/ Interchangeable Film Discs — Moon/Galaxy/Saturn, Kids Bedroom Decor | Night Lights | $6.08–$10.76 | 119–150 g | 2026-10-01 / 2026-10-07 | 3 | Moderate — price/weight range ⇒ 2+ variants, but "film-disc" structure likely a small bounded set | Freshest; cleanest match to the category + e453eed4 demand concept; strong margin headroom vs US $14.99–$139.99 selling evidence |
| 2 | `2608140601331627400` | CJYD3060486 | Starry Sky Light USB Mini Projector | Home Office Storage | $4.92–$7.99 | 93–115 g | 2026-08-14 / 2026-09-05 | 7 | Moderate | Simple generic starry-sky mini; most CJ listings (7); miscategorised but clearly a starry projector |
| 3 | `2607070309131601200` | CJYD2971278 | Portable USB Starry Sky Projection Night Light w/ Interchangeable Slides | Projectors | $1.25–$3.68 | 29–88 g | 2026-07-07 / 2026-09-11 | 5 | Moderate | Lowest cost; slide-based variants; oldest of the three |

Considered, not selected: `2608250310481611400` (corporate-gift dual-mode, $0.28–$9.72 / 2–139 g — very wide range ⇒ high variant ambiguity) and `2609030253321622100` (children's bedtime story machine — different function). HD/home-theater video projectors excluded as a different category; keyword false-positives (projector screens, car/Halloween/Christmas projectors, headlight bulb, jewellery, apparel) excluded.

### Recommendation — ONE CJ PID: `2610010255571606100` (SKU CJJT3213323)
- **Name:** USB Star Projector Night Light With Interchangeable Film Discs (Moon/Galaxy/Saturn), Kids Bedroom Decor. **Source/obs:** CJ catalogue, observed 2026-10-01 (last seen 2026-10-07). **Hist. price:** $6.08–$10.76 USD. **Weight:** 119–150 g. **Shipping:** no historical US shipping data stored → UNKNOWN until the probe. **Delisting:** none known (availability still unverified).
- **Why suitable for a US founder-tenant demonstration:** freshest decorative star/galaxy night-light projector; a clean generic CJ-native identity (CJ PID + SKU = the CJ_NATIVE_NAMESPACE the BE246 engine accepts); clear function + real problem (kids' sleep/ambience night-light); understandable, bounded variant structure (interchangeable film discs) that minimises the ambiguity the exact-SKU engine guards against; low supplier cost giving genuine margin headroom against the observed US selling band; directly in the BE254-recommended category and corroborated (at category level only) by the e453eed4 US demand concept.
- **Variant-verification risks:** price/weight ranges imply ≥2 variants (colour / disc-set / plug); if multiple true SKU variants exist, a legitimate single-variant designation (or a genuine customer choice) is required before EXACT verification — exactly the ambiguity that blocked the delisted humidifier. The "film-disc" structure suggests a smaller, bounded set than a 35-variant item, but this must be confirmed by the probe.
- **Licensing / identity concerns:** none material — generic (no brand impersonation; "Moon/Galaxy/Saturn" is descriptive, not a mark); CJ images remain reference-only/blocked; this is a CJ supplier-origin research item and is **not** asserted to match any specific DataForSEO Merchant listing.

### Corrected bounded 4-call acquisition proposal (NOT executed; needs founder sign-off on PID + scope; $0)
1. `authentication/getAccessToken` — only if an existing valid token cannot be safely reused.
2. `product/query?pid=2610010255571606100` — variant catalogue, cost, title, current availability. **No `product/list`** (the exact PID is already stored).
3. `product/stock/queryByVid?vid=<designated>` — only if the product is available AND one legitimate variant has been designated (BE250 RVD).
4. `logistic/freightCalculate`→**US** — only if the verified variant + remaining allowance justify it.

Execution path: retarget the existing bound workflow `zwTkywEYKsmojs6g` to this PID via the same surgical `setNodeParameter` patch (credential bindings preserved), confirm availability first, then BE246 exact-variant verification → US economics. **GPD.16 / GPD.17 / GPD.19 stay OPEN until genuine acceptance evidence is obtained.**

### Integrity preserved
Category-level US demand (e453eed4) is kept distinct from product-specific demand (UNKNOWN for this CJ item) and from CJ supplier identity; no similarly-named CJ product is claimed to match a specific Merchant listing. Founder-tenant ownership, Product Asset Lock, CJ image-rights block, US market isolation, the 5 locked DataForSEO Merchant pilots, Stripe public-checkout restrictions, FastMoss retirement and all 11 accepted GOLD gates are untouched. No new integrations, no Lovable changes, no API calls.

## Addendum 37 — BE256 live CJ acquisition, fail-closed ingestion fix, exact-variant verification (US star projector)

**Date:** 2026-11-23. Founder-approved bounded live acquisition of the US star projector. **2 of 4 CJ requests used, $0; no stock/freight; no retries; activation off; credentials never exposed.**

### Task A — CJ ingestion made fail-closed (mig_331, proven mig_332 7/7)
`fn_ingest_cj_product_media` now validates the provider payload and fails closed: success requires probe_ok + a well-formed non-empty variant_catalog + cj_result≠false; otherwise it records honest availability only (REMOVED_FROM_SHELVES for code 1602002, else UNAVAILABLE_OR_UNVERIFIED), preserves historical data, never writes an empty catalogue as a fresh probe, never bumps enrichment_observed_at, never marks a delisted product purchasable, and never invents a delisting verdict for malformed data. Wrong-PID and not-found reject with no write. The n8n Build Enrichment node was hardened to match (validates result/data/pid/variants; emits a fail-closed payload with no fabricated catalogue) — defense-in-depth, no duplicate service. Verified with 7 rolled-back synthetic scenarios (no live CJ): success, delisted(+history preserved), data:null, wrong PID(no write), malformed items, malformed collection, not_found.

### Task B — live acquisition (n8n zwTkywEYKsmojs6g, exec 30723, manual)
Retargeted to pid `2610010255571606100` via surgical `setNodeParameter` (credentials preserved; verified). CJ Auth (call 1) + `product/query` (call 2) → **code 200, result true, "Success"**. Product is **LIVE**: SKU `CJJT3213323`, "USB Star Projector Night Light With Interchangeable Film Discs Moon Galaxy Saturn Patterns For Kids Bedroom Decor", category Home Improvement > Indoor Lighting > Night Lights, price range $6.08–$10.76, **15 genuine variants** (film-disc/glass-cover patterns; 3 "Glass Cover/Sheets" count SKUs at $7.29/$9.03/$10.76 + 12 single-pattern discs at $6.08). CJ points are free (no charge).

### Task C — ingest
Hardened `fn_ingest_cj_product_media` accepted the success: supplier row `37dd09e5` now carries probe_ok, AVAILABLE_PROBED, FRESH_PROBE_OK, product_sku CJJT3213323, 15-variant catalogue, 15 images (reference-only), enrichment_observed_at 2026-11-23. Stored record matches the live response. No duplicate row.

### Task D — founder-tenant research provenance
No prior founder product, CJ bridge, or CJ-origin research item existed for this PID. Introduced a controlled founder-tenant research item `534d98bc-bf51-4f57-8269-4c5961f071f2`: product_identity `candidate:pid:cjdropshipping:2610010255571606100` (CJ_NATIVE_NAMESPACE), identity_basis platform_id, source CJ Dropshipping, market US, owner = founder tenant, visibility TENANT_PRIVATE, product_role candidate; demand/sellers/advertisers/profitability **UNKNOWN**, opportunity **INSUFFICIENT_EVIDENCE**; provenance records CJ-origin and that category-level US star/galaxy demand (e453eed4) is context only, not product-specific demand. No system-tenant copy; no role bypass.

### Task E — exact-variant engine verdict (held UNVERIFIED, honestly)
`fn_cross_supplier_exact_variant_check` → **exact=false, reason `ambiguous_no_variant_designation`**, identity method CJ_NATIVE_NAMESPACE; `fn_resolve_cross_supplier_identity` (persisted) → identity_tier **UNVERIFIED**, **bound=false**, confidence NONE, variant_verified false, total_variant_count 15, concept STRONG_SAME_PRODUCT, corresponding_variant_count 0 (all 15 OTHER_OR_AMBIGUOUS). The product is genuinely multi-variant with no unambiguous source-observed single variant and **no founder/customer choice has occurred**, so EXACT is held UNVERIFIED and the 15 film-disc options are reported for a genuine choice. **No variant was auto-selected.** (Single-variant rules do not apply — it is 15-variant.)

### Task F — US inventory & freight
**Not run.** No genuine exact variant established → stock/freight not justified; 2 of 4 CJ calls used, remaining 2 deliberately unspent. US landed cost + margin **UNKNOWN**. No GB/GBP substitution.

### Task G — customer research integration (backend-verified)
Chain exercised under founder tenant/US isolation: identity resolution (UNVERIFIED/unbound) → `fn_product_supplier_candidate` / `fn_ecommerce_product_intelligence_core` emit **no** CJ CDN URLs → `fn_resolve_supplier_economics` returns **no_candidate** (margin UNKNOWN). Honest INSUFFICIENT_EVIDENCE throughout. No browser-journey claim (backend only).

### Task H — image rights, security, regression
No `cjdropshipping`/`oss-cf` URLs in any customer-facing function output for the product (verified). PAL, CJ image block (display_cache_images_cleared stays FALSE), the 5 DataForSEO Merchant release rows (FALSE), Stripe public checkout, founding-member access, founder-only mutators, provider rights, tenant/country isolation and FastMoss retirement all untouched. Regression: **pd_release all_green 13/13** (also asserts 0 Merchant release rows released), **RVD 5/5**, **BE256 fail-closed 7/7**, BE253 probe ok.

### GOLD acceptance — GPD.16/17/19 remain NOT ACCEPTED (genuine progress recorded)
- **GPD.16:** first live, available, customer-eligible founder-tenant CJ-native product with a fresh 15-variant catalogue + authoritative identity — but EXACT is UNVERIFIED pending a genuine 1-of-15 variant designation, then stock/variants proof. NOT accepted.
- **GPD.17:** economics no_candidate/UNKNOWN (no exact variant; no US stock/freight; no credible same-product US selling price). NOT accepted.
- **GPD.19:** honest supplier-origin research chain exists but no bound exact variant → supplier-positive journey not sightable; backend only. NOT accepted.

### Remaining blocker (single, founder-specific)
A genuine founder/customer **choice of one film-disc variant** (15 options; e.g. HD-Galaxy 1 `CJJT321332307GT`, HD-Cosmic Journey `CJJT321332306FU`, HD-12 Glass Sheets `CJJT321332303CX`, …). On that choice, `fn_set_research_variant_designation` records it → BE246 re-run (expected EXACT) → then the remaining ≤2 CJ calls (stock + US freight, with an authorised US destination — ZIP not to be invented) → US economics → customer Save/Monitor sighting. No further acquisition is authorised until the founder designates the variant (and supplies a US destination for freight).

## Addendum 38 — BE257 US-discovery-first identity verification & supplier-matching discipline (read-only, $0, 0 new provider calls)

**Date:** 2026-11-23. Re-asserts the correct sequence (US discovery → verified identity → genuine CJ bridge → exact variant). No new CJ/DataForSEO calls; BE256's 2 unused calls NOT reused. BE256 evidence preserved intact.

### §1 BE256 evidence preserved
Supplier row `2610010255571606100` (SKU CJJT3213323, 15 variants, AVAILABLE_PROBED) and the fail-closed ingestion fix (mig_331/332) stand. Founder-tenant CJ-supplier-origin research item `534d98bc` remains honestly labelled: provenance origin=`supplier_catalogue`, opportunity=`INSUFFICIENT_EVIDENCE`, unbound, UNVERIFIED. Not converted into an independently discovered US product; not deleted.

### §2 Genuine US-discovered projector products (DataForSEO merchant; none FastMoss)
Real US-market discoveries exist (source_store `dataforseo_merchant`, market US, first-observed 2026-11-19/20), e.g. Govee Star Light Projector `d985e5af`, Rossetta Dual-Lens `ae58628c`, POCOCO `20d03417`, Anysun 13-in-1 `68559293`, "Bedroom Star Projector w/ Timer" `a37f20e0`, "Star Projector Night Light 1-Pack 360 … 25 slide discs" `ca945686`, "Planetarium Projector Pro 13-in-1" `84af56b0`. All carry identity_basis `platform_id` (name-based), **no GTIN/UPC/EAN/MPN and no populated provider-native id**, thin product-specific US evidence (1–2 US competitors, 1 US eval each, confidence NONE). `fastmoss_dep = false` for all. Generic Reddit keyword/category concept `e453eed4` is explicitly **excluded** as exact-identity proof (category context only).

### §3 Relationship to CJ `2610010255571606100` — NO authoritative bridge
The CJ supplier record carries **no** GTIN/UPC/EAN/barcode/MPN/brand (CJ-native `pid`/`productSku` only; it does carry `shippingCountryCodes` for later US-shipping checks). Neither side shares an authoritative identifier. BE246 engine bridge test (`fn_cross_supplier_exact_variant_check`) for the closest generic (`ca945686`, "25 slide discs") **and** the branded Govee (`d985e5af`) against the CJ pid → **exact=false, reason `no_authoritative_product_identity`** in both cases. Provider-native namespaces (Google-Shopping merchant vs CJ pid) are not interchangeable; similar titles / interchangeable discs / shared category / matching price / visual resemblance do **not** establish identity. **They remain separate records** (0 discovery→CJ bridges persisted; the CJ pid's only identity row is its own unbound CJ-origin item).

### §4 Strongest genuine US discovery + the precise gap
By US evidence the discoveries are uniformly thin (1–2 competitors, confidence NONE); the most evidenced generic, CJ-match-eligible starting point is `ca945686` ($14.99, 360° star/slide-disc, generic). But **no US-discovered projector has an authoritative supplier bridge** — the precise gap, reported rather than resolved by arbitrary catalogue selection. Branded discoveries (Govee/POCOCO/Anysun/Rossetta) have recognisable identity and real US retail presence but **cannot** map to the generic CJ SKU without the brand's own SKU (substitution forbidden). No product is called a winner (insufficient verified evidence); "first observed 2026-11-20 by Strateloq" is not asserted as new-to-market.

### §5 Supplier/variant qualification — not proceeded
No authoritative same-product relationship → supplier qualification does not proceed for any US discovery. `variant_verified=false` everywhere; the CJ item 534d98bc stays UNVERIFIED/unbound; no variant auto-selected; no founder/customer choice fabricated.

### §6 Acquisition controls — precise evidence-acquisition recommendation (NOT authorised; nothing executed)
No new call is justified to force a bridge the identifier evidence cannot support. If the founder wishes to pursue it, one precise option:
- **US-discovered UUID:** `ca945686-18ca-40a9-94a8-2eafcb3bf5a7` (generic US star projector). **Proposed CJ PID:** `2610010255571606100`. **Identity evidence today:** category/title/disc-mechanism resemblance only — NOT authoritative. **Endpoint:** a DataForSEO merchant product-detail lookup for that US listing to retrieve a GTIN/brand/model. **Calls:** 1 (DataForSEO, **chargeable** — monetary + quota impact, exact cost per the provider budget). **Expected evidence / honest yield:** LOW — even if the US listing exposes a GTIN, the CJ product has none to match, so an identifier bridge is unlikely to resolve; image-vision corroboration is unavailable. **Destination:** n/a. Recommendation: **do not spend** on a low-yield bridge; treat the CJ USB star projector as a CJ-origin item on its own terms, and keep US discoveries separate.

### §7 Provenance separation (verified)
(A) Independently discovered US research products keep their own US observations/evaluations; (B) the CJ supplier-origin item keeps CJ catalogue/supplier data and carries **no** independent product-specific US demand (category-level kids'-projector demand is NOT attached to it). No records merged on name/category. The 5 locked DataForSEO Merchant pilot rows remain unreleased (pd_release asserts 0 released).

### §9 Validation
pd_release all_green 13/13, RVD selftest 5/5, BE256 fail-closed 7/7. CJ pid bridge rows = 1 (the CJ-origin item only), bound = 0, discovery→CJ bridges = 0. No FastMoss discovery used. Exact variants fail closed when identifiers/designations are absent (`no_authoritative_product_identity` / `ambiguous_no_variant_designation`). Tenant/US isolation and honest UNKNOWN/INSUFFICIENT states intact. No browser-journey claim.

### GOLD — GPD.16/17/19 remain NOT ACCEPTED
No acceptance on supplier-catalogue identity alone. GPD.16 blocked by the absence of an authoritative US-discovery→CJ bridge (and, for the CJ item alone, an undesignated 15-variant set). GPD.17 economics UNKNOWN. GPD.19 supplier-positive journey not sightable (no bound exact variant; backend only). 11 accepted gates preserved.

## Addendum 39 — BE258 US-discovered product identity resolution for supplier matching (read-only, $0, 0 new provider calls)

**Date:** 2026-11-23. Goal: resolve the evidence gap blocking genuine US discoveries from reaching exact supplier verification — by checking whether authoritative identifiers are present in raw discovery payloads but lost at ingestion. Existing evidence + no-cost engineering only; no FastMoss; no switch to a CJ-origin product.

### What identifiers the US discoveries actually carry (ca945686 et al.)
The DataForSEO Merchant (Google Shopping) ingestion stores, in `commerce_products.extended`: `market`, `merchant_source=google_shopping`, `merchant_seller_name` (e.g. ca945686 "Walmart - Seller", a37f20e0 "hearthfell", d985e5af "Govee", 84af56b0 "Wayfair"), `screening_state` (GENERIC_OK vs BRANDED_OR_IP_REVIEW), `product_family_key`, `listing_position`, and **`dataforseo_merchant_product_id`** — the provider-native Google-Shopping product id (ca945686 = `17536943141369248154`, d985e5af = `18034214886779403846`); `native_identity_kind = google_product_id`. The same native id is also on each product's `MARKETPLACE_ACTIVITY` signal (`native_id`, `marketplace=GOOGLE_SHOPPING`).

### Were usable identifiers lost at ingestion? NO
The provider-native google_product_id is **retained** (extended + signal). BE257 reported "native_id/gtin (none)" only because it queried the keys `google_product_id`/`product_id`/`platform_id` — the real key is `dataforseo_merchant_product_id`. Nothing authoritative was dropped.

### Is a cross-supplier authoritative identifier present anywhere? NO — source-data limitation
A GTIN/UPC/EAN/MPN scan across **all** stored evidence (every DataForSEO-merchant product's `extended`, every `commerce_signals` value/evidence, every `product_market_competitors` row) returns **0**. The Google-Shopping listing results genuinely supply only a Google-namespace product id + seller + title + price — never a GTIN/MPN/brand-model. This is a confirmed **upstream source-data limitation**, not an ingestion defect. No honest mapping fix can add a GTIN that the source never provided; none was fabricated.

### Can an authoritative supplier bridge be established now? NO
A google_product_id is a Google-Shopping-namespace id, **not interchangeable** with a CJ pid, and no shared GTIN exists (the CJ product `2610010255571606100` also exposes no GTIN/UPC/EAN/MPN — CJ-native `pid`/`productSku` only). The BE246 engine (BE257) returns `no_authoritative_product_identity` for both the generic (`ca945686`) and branded (`d985e5af`) discovery vs the CJ pid. No authorised supplier source exposes a GTIN for these generic products (CJ does not; BigBuy/AliExpress are not activated). So the US discoveries and the CJ supplier-origin item `534d98bc` remain correctly **separate** — no match proven; no product/supplier pair named.

### Precise missing evidence + most credible next acquisition path
Missing: a GTIN (or manufacturer brand+MPN) for a specific US discovery **and** a supplier that exposes the same identifier.
- **Proposed request (NOT authorised; present for decision):** one DataForSEO Merchant **product-detail/specification** lookup by google_product_id for ONE US discovery (e.g. branded Govee `d985e5af` native id `18034214886779403846`, best odds of a published brand/GTIN). **Endpoint:** DataForSEO Merchant product-info. **Calls:** 1. **Cost:** chargeable DataForSEO credits (confirm exact cost against the provider budget before authorising; $0 spent now). **Expected evidence:** brand/MPN/GTIN/specs **if** the merchant published them — MODERATE odds for a branded listing, **LOW** for generic marketplace listings (ca945686 "Walmart - Seller"). **Destination:** n/a (identity, not shipping).
- **Honest caveat:** even a retrieved US GTIN cannot bridge to **this** CJ product (CJ has no GTIN). For GENERIC white-label dropship products an identifier bridge is realistically unattainable from any authorised source; the credible routes are (a) a **branded** discovery matched to a **brand-authorised** supplier (new supplier strategy + IP review), (b) image-vision corroboration (capability not available), or (c) verify the CJ item on its **own supplier-origin terms** via a legitimate 1-of-15 variant designation (no US-discovery equivalence claimed).

### Validation / security
No DB writes (no defect to fix; no identifier manufactured). No new provider calls; $0. FastMoss retirement, tenant/country isolation, CJ image-rights block, PAL, DataForSEO upstream/customer-release restrictions, 5 locked Merchant rows, Stripe controls and the 11 accepted GOLD gates all preserved. Intelligence kept separated (discovery identity vs product-specific demand vs category demand vs supplier identity); no attribute/demand bleed. **GPD.16/17/19 remain NOT ACCEPTED.**

## Addendum 40 — BE259 restore & verify the Discovery → Verified-Supplier → Profit journey; cross-provider identity decision (read-only, $0, 0 new calls)

**Date:** 2026-11-23. Assessment of the original business model's implementation + the decisive identity-bridge decision. No rebuild; no new provider calls; BE256/257/258 evidence preserved and separate.

### What is already working (inspection, not rebuild)
- **Genuine US discovery** (DataForSEO Merchant / Google Shopping): product records with product-specific US signals (`MARKETPLACE_ACTIVITY`), seller name, price, freshness, market isolation; FastMoss retired.
- **Opportunity/profitability engine** (`fn_ecommerce_product_intelligence_core`): returns `lifecycle` (`early_opportunity_state` RESEARCH_PRIORITY/DISCOVERED, `commercially_validated`, `stage1_supplier_resolution_qualified`, disqualifiers branded_or_ip / identity_ambiguous / observed_high_saturation, qualifying_family_count), `evidence_families`, `observed_counts`, `freshness`, `supplier_resolution`. GPD.12 customer-facing score suppression intact (no scores exposed; no diagnostic tiers reactivated). Economics via `fn_resolve_supplier_economics` (honest `no_candidate`/UNKNOWN without an exact variant; $10/unit ad assumption + ~$25–30 net target model retained from prior BE work).
- **Product Card fields present**: identity, market, evidence summary, demand/competition observations, freshness, `supplier_resolution` (bound/status), economics, opportunity classification, Save/Monitor (GPD.18 accepted). Image rights fail-closed; 5 Merchant pilots unreleased.
- **Supplier-sourceable publication gate — verified enforced SERVER-SIDE and fails closed.** Validation: cross_supplier_identity `variant_verified=0`, `bound_and_verified=0`; concrete_supplier_resolution `bound=0` of 9. The only bound cross-identity is the excluded GB FastMoss ski-mask (SAME_PRODUCT_IDENTITY, not EXACT, **not** bound at the concrete layer the card reads). So **no product surfaces as a confirmed/sourceable opportunity** — unverified-supplier products stay in evidence-pending (RESEARCH_PRIORITY/DISCOVERED, `commercially_validated=false`). **No demonstrated defect → no fix applied** (none invented).

### End-to-end journey — honest progress (backend-verified; no browser claim)
For the genuine US discovery `ca945686` (google_product_id `17536943141369248154`, "Walmart - Seller", $14.99, GENERIC_OK): discovery ✓ → product-specific US evidence ✓ (thin: 1 marketplace signal/competitor) → identity (name-based platform_id + google_product_id; **no authoritative cross-supplier identifier**) → **exact supplier match ✗ (no authoritative bridge)** → supplier URL ✗ → exact variant ✗ → US economics UNKNOWN → Product Card renders **evidence-pending (RESEARCH_PRIORITY)**, correctly NOT sourceable → Save/Monitor available. The journey stops at *exact supplier match* — exactly the capability gap, not a pipeline bug.

### The real blocker (not ingestion): cross-provider exact-identity mechanism
Generic white-label US dropship discoveries carry no barcode and no manufacturer/model identity; neither DataForSEO Merchant listing data nor CJ exposes a shared GTIN/MPN, so an identifier bridge is unattainable for generics. Per §8, a product-detail call that *could* return a GTIN is insufficient alone because no prospective authorised supplier (CJ) can expose/verify the same GTIN. Provider capability assessment (existing evidence, no calls):
- **DataForSEO** — Google Shopping **product-detail** could add the full merchant-offer set + specs + GTIN/brand *when the merchant published them* (MODERATE yield branded, LOW generic); gives a competitor retail offer URL, not a dropship sourcing link. Chargeable.
- **CJ** — rich product/variant ids, **direct supplier product URL**, stock + US shipping (`shippingCountryCodes`), variant SKUs — but **no GTIN/MPN**, so it cannot be the matched side of an identifier bridge for a barcode-less generic.
- **AliExpress / BigBuy** — not activated; rights NOT presumed. BigBuy (EU wholesaler) typically carries EANs and direct URLs; AliExpress carries variant ids + direct URLs. Either *could* supply authoritative identifiers, but only via a new licensed integration/partnership (founder decision).

### Decisive recommendation — the capability that actually resolves the gap
**Best credible method for the dropshipping model = product-image vision matching** (compare a discovery's merchant image ↔ candidate supplier variant images to establish exact equivalence), paired with the supplier's **direct product URL + exact variant SKU + stock/US-freight**. This is the general solution for barcode-less white-label generics (visually identical across Google-Shopping/CJ/AliExpress), uses imagery already in evidence under *analyse* rights (customer display stays blocked), and is exactly the `variant_image_vision_unavailable` evidence the BE246 engine already names as missing. It is a **new internal capability (vision), not a provider credit.**

**Smallest useful next step (no spend approved):**
- **Primary (recommended):** stand up a bounded **image-vision equivalence check** on ONE pair — US discovery `ca945686` vs CJ `2610010255571606100` variants — using already-stored images. $0 provider cost; needs a vision capability/tool; resolves the generic case the right way.
- **Alternative (identifier route, branded only):** ONE DataForSEO Google Shopping **product-detail** call on the **branded** Govee `d985e5af` (`18034214886779403846`) to test GTIN/brand retrieval — chargeable (confirm exact cost vs provider budget) — worthwhile **only** if paired with a brand-authorised supplier that exposes the same GTIN (new supplier strategy + IP review); **not** recommended for generics, and not repeated low-yield calls.
- **Do NOT** redefine Strateloq as a supplier-catalogue browser, approximate matching, or branded-only discovery.

### Strongest candidate
- Generic dropship model: **`ca945686`** (resolvable via image-vision, option A).
- Identifier/branded model: **`d985e5af`** Govee (resolvable via product-detail GTIN, but needs brand-authorised sourcing).

### Security / tracker
FastMoss retirement, 18-country isolation, founding-member + founder-only controls, PAL, provider licensing, CJ image block, Stripe, Save/Monitor, timestamps and the 11 accepted GOLD gates all preserved. No DB writes; no API calls. **GPD.16/17/19 remain NOT ACCEPTED**; GPD.06–11/22/01 unchanged (no new evidence; not re-audited). GOLD GPD.16 + Build Evidence updated with this finding.

## Addendum 41 — BE260 image-assisted supplier matching: rights/capability gate + identity boundary (read-only, $0, 0 new calls)

**Date:** 2026-11-23. Goal: implement the smallest safe image-assisted candidate matcher (`ca945686` vs CJ `2610010255571606100`) *only if* image-analysis rights and an existing vision capability allow — never letting visual similarity produce EXACT/bound/sourceable. No rebuild; no new provider or vision calls.

### §4 Image-analysis rights (catalogue_source_rights)
- **CJ**: `analyse_cleared=TRUE`, `display_derived_cleared=TRUE`, but **`display_cache_images_cleared=FALSE`** and `display_cleared=FALSE`. Internal transient analysis is arguable; **caching/storing images or features is NOT cleared**; customer display blocked.
- **DATAFORSEO_MERCHANT** (the discovery source): `analyse_cleared=TRUE`, **`display_cache_images_cleared=FALSE`**, `display_cleared=FALSE`, note "Google Shopping / Amazon public merchant listings … display/redistribution rights NOT confirmed."
- Only KALODATA has image display/cache cleared. So **neither** the discovery nor the CJ supplier side has sufficient image **cache** rights for a stored image-feature pipeline, and customer display stays blocked. Product Asset Lock preserved.

### §5 Image evidence + existing vision capability
- Discovery `ca945686`: **no stored image at all** (no signal/extended image; `product_url` null). There is literally nothing on the discovery side to compare.
- CJ `2610010255571606100`: 15 reference-only CDN images (`SUPPLIER_PROVIDED_REFERENCE_ONLY`).
- **No materialized image assets/hashes/asset-intelligence rows** exist for either product (product_image_assets / supplier_product_assets / product_asset_intelligence all empty for them).
- **No internal vision capability**: no embedding/vector/perceptual-hash column anywhere (only a byte `content_hash`); no vision model in the stack; paid vision APIs not authorised ($0).

### §6 Prototype NOT executed (honestly) — three independent blockers
1. No discovery-side image to compare; 2. insufficient image cache/analysis+display rights on **both** sides (`display_cache_images_cleared=FALSE`); 3. no internal vision/embedding capability (and no authorised paid vision call). Per the directive I did **not** pretend the prototype ran and did **not** download unlicensed imagery.

### Authorised candidate comparison (text/attributes only — the permitted non-image method)
From legitimately-available metadata: **Shared observable features** — both are USB star/galaxy **night-light projectors**, disc-based pattern projection, bedroom/decor use, low price tier, Night-Lights concept. **Differences/conflicts** — discovery "**25 slide discs**" single listing (seller "Walmart - Seller", US retail price $14.99) vs CJ "interchangeable **film discs**, Moon/Galaxy/Saturn", **15** pattern variants (supplier cost $6.08–$10.76, a different metric). **Missing material specs** — discovery has no dimensions/weight/brand/GTIN/image; CJ has weight (119–150 g) but no GTIN; **no shared identifier either side**. **Match classification = CANDIDATE_REQUIRES_VERIFICATION** (concept-level STRONG_SAME_PRODUCT per BE257, **not** EXACT). No numeric confidence fabricated.

### §7 Identity boundary — enforced and regression-locked
Visual/attribute similarity cannot set `bound=true`, `variant_verified=true`, `commercially_validated=true`, an EXACT verdict or a sourceable publication state. Proven: BE246 engine requires authoritative identity (SHARED_GTIN | CJ_NATIVE_NAMESPACE | AUTHORITATIVE_SUPPLIER_REF) + a designated variant; RVD selftest locks "non-authoritative identity → no_authoritative_product_identity"; BE257 real bridge test returned exactly that for this pair; validation now: `variant_verified=0`, concrete `bound=0`. Regression green (pd_release 13/13, RVD 5/5, BE256 7/7). **Key nuance:** even a *successful future image match only locates a CANDIDATE* — it does not, by itself, satisfy the identity contract; EXACT still needs authoritative corroboration that does not exist for these barcode-less generics.

### §14 Exact capability + cost required for genuine image-assisted matching (none approved)
To make image-assisted matching real and rights-safe, Strateloq needs **all** of: (a) a **stored discovery image** (fetch the merchant image URL via a DataForSEO Merchant product-detail call — chargeable credits, confirm cost); (b) **image cache/analysis rights** for DATAFORSEO_MERCHANT and CJ (`display_cache_images_cleared`, currently FALSE — a provider-rights/licence step); (c) an **image-embedding/vision capability** (licensed internal model or a paid vision API — per-image cost, confirm); and, decisively, (d) **authoritative corroboration** (GTIN/MPN/brand cross-reference) to convert a visual CANDIDATE into EXACT — absent for generics, so image matching alone cannot complete GPD.16. The genuine founder decision: license an identifier-publishing supplier (e.g. BigBuy EANs) for authoritative corroboration, or set an explicit policy on whether a strongly-corroborated CANDIDATE (visual+attribute+concept) may ever be surfaced as sourceable — which would be a deliberate change to the identity contract, not a silent weakening.

### Security / tracker
No DB writes; no API calls; $0. FastMoss retirement, 18-country isolation, founding-member + founder-only controls, PAL, CJ image block, DataForSEO upstream/Merchant-release restrictions (5 pilots unreleased), Stripe, Save/Monitor and the 11 accepted GOLD gates preserved. **GPD.16/17/19 remain NOT ACCEPTED.** GOLD GPD.16 + Build Evidence updated.

## Addendum 42 — BE261 WinningHunter competitive-gap roadmap, Build Batch 1 (CX.01 + CX.02)

**Date:** 2026-11-23. Implementation batch (not an audit), existing authorised connectors + evidence only, **$0, 0 provider calls**. CX.01–CX.10 roadmap added to LIVE MASTER — GOLD (rows A24:H33) with the status taxonomy; the 22 GPD GOLD gates and their criteria are untouched (a built capability is not an accepted gate).

### CX.01 — Genuine US discovery coverage → ENGINEERING VERIFIED (no fix manufactured)
Verified the existing pipeline rather than inventing changes: **identity dedup sound** (25 US merchant discoveries, 0 duplicated native `google_product_id`s, 0 identity collisions); **FastMoss excluded from every active surface** (47 inert `source_store='fastmoss'` TENANT_PRIVATE historical rows exist but have 0 customer-visible, 0 in `commerce_product_opportunities`, 0 active US `product_market_evaluations`, 0 member-opportunities, 0 projected); **discovery projection functions** (`fn_project_discovered_candidates` US: already_decided 35, projected 0 — idempotent, legacy research-concepts excluded, country-isolated); **supplier-ready vs evidence-pending** enforced by the lifecycle (BE259). No demonstrated defect needed a fix. Minor future enhancement (not a defect): an explicit first-observed-by-Strateloq vs new-to-market honesty flag for merchant discoveries.

### CX.02 — Direct supplier sourcing → ENGINEERING VERIFIED (new build) + BLOCKED — EXTERNAL EVIDENCE
Delivered a genuine new component: **`fn_supplier_candidate_lookup_stored`** (mig_333) — a read-only, $0, zero-provider-call lookup that scores a US discovery against the **already-acquired** stored CJ catalogue, reusing the existing spec-builder (`fn_derive_concrete_product_identity`) and scorer (`fn_market_supplier_match`). It pre-filters by the distinctive head noun, requires ≥1 distinguishing secondary token (concept corroboration, not a confidence score), ranks by shared-token count, and **downgrades any brand-in-title EXACT to a candidate** — so it never emits EXACT. Live test on `ca945686`: 16 projector-family candidates; the BE256 CJ star projector `2610010255571606100` ranked **#1** (6 shared tokens); **every** candidate `CANDIDATE_REQUIRES_VERIFICATION` with `authoritative_identity/variant_verified/bound=false` (`any_exact_or_bound=false`). Tenant-guarded (`auth.uid()=p_tenant` or service_role) + product-ownership check; STABLE/read-only (writes nothing). The **server-side sourceable gate remains enforced** (concrete `bound=0`, `variant_verified=0`); supplier-origin records stay classified (`534d98bc` origin=`supplier_catalogue`). **BLOCKED — EXTERNAL:** authoritative exact-product binding (shared GTIN/MPN or image-vision + corroboration, per BE257–260) and a live supplier search + provider-supplied direct URL are unavailable/unauthorised; these gate EXACT + a verified sourcing link.

### Tests (all 9)
1 discovery→sourced record PASS (already_decided 35); 2 supplier imports can't masquerade as discoveries PASS (supplier-origin classified; 0 fastmoss in opportunities); 3 FastMoss excluded PASS (0 across all active surfaces); 4 no identity collisions/merges PASS (0 dup native ids; lookup is candidate-only, binds nothing); 5 unverified candidate can't become sourceable PASS (`any_exact_or_bound=false`, concrete `bound=0`); 6 exact-variant/direct-link fail closed PASS (`variant_verified=0`; engine `no_authoritative_product_identity`); 7 supplier-origin records classified PASS; 8 rights/tenant/country isolation intact PASS; 9 no regression PASS (pd_release 13/13 clean, RVD 5/5, BE256 7/7). *Note:* `fn_pd_release_verification` returns false when run under a set tenant JWT (a harness-context artifact) but is 13/13 all_green in clean service context — no real regression.

### Batch 2 readiness
CX.03 (verified US landed cost + profitability) and CX.04 (customer-ready discovery→supplier→Save/Monitor) are **blocked on CX.02's authoritative exact bridge** (and a US freight destination for CX.03). The economics engine, sourceable gate and Save/Monitor are already built and will light up once a genuine exact supplier variant with a direct link exists. Do not build Batch 2 while that external dependency is unresolved.

Security/rights preserved: FastMoss retirement, 18-country isolation, founding-member + founder-only controls, PAL, CJ image block, DataForSEO upstream/5-Merchant-release lock, Stripe, Save/Monitor, timestamps, and the 11 accepted GOLD gates. No Lovable/frontend rebuild; no new integrations; no customer publication. GPD.16/17/19 remain NOT ACCEPTED.

## Addendum 43 — BE262 independent US intelligence workstreams (CX.05/06/07) + tracker reconciliation + CX.02 identity decision ($0, 0 provider calls)

**Date:** 2026-11-23. Verified the independently-buildable CX units on real stored US evidence (no new calls, no rebuild), reconciled the CX tracker section, and produced the CX.02 authoritative-identity decision record.

### Tracker reconciliation
`LIVE MASTER — GOLD` now holds a single unique CX.01–CX.10 section (rows 24–33). The stale duplicate CX.09/CX.10 entries (BE260-flavoured, rows 34–35) were confirmed and removed, their useful content merged into the canonical rows. GPD.01–22 rows and boolean acceptance are untouched — **11/22 preserved** (TRUE: GPD.02/03/04/05/12/13/14/15/18/20/21). CX statuses use a separate taxonomy column and do **not** affect the GOLD count. No new spreadsheet; hidden tabs untouched.

### CX.05 — Licensed advertising research → ENGINEERING VERIFIED + BLOCKED — EXTERNAL RIGHTS
The existing US product-specific advertiser/ad-observation path works on stored evidence: **17 US `ADVERTISING_ACTIVITY` observations** (META_AD_LIBRARY, MATCHED, ad_id/page_id) for 1 product. It records ad **presence** only (no performance/sales claim); the accepted GPD.09 display layer labels it "competition/presence, not sales". No customer campaigns; no fabrication. **Live/customer acceptance BLOCKED**: `META_AD_LIBRARY.analyse_cleared=FALSE` + ad-display rights unresolved (GPD.01). (Observation: raw ad signals lack an explicit `claim_safety` key — benign, since the display layer labels them; not a false claim, so no manufactured fix.)

### CX.06 — Competitor store & offer tracking → ENGINEERING VERIFIED + BLOCKED — EXTERNAL RIGHTS
The marketplace competitor/offer/seller-dedup path works on stored US evidence: **180 US competitor observations across 27 products**. Seller-dedup is HONEST — where seller identity is not captured, distinct sellers = **UNKNOWN**, never equated to listing count (top US product: 98 listings, `competitor_identity` null on all → distinct sellers UNKNOWN, not 98). Offers/prices/timestamps country-scoped; attaches to a product only where identity permits; no fabricated totals. **Live acceptance BLOCKED**: `EBAY.analyse_cleared=FALSE` + seller/price display rights ride GPD.01.

### CX.07 — US demand, search & social momentum → ENGINEERING VERIFIED + BLOCKED (display GPD.01)
The demand/search path works on stored US evidence: **US `SEARCH_DEMAND` for 3 products** (DataForSEO, `analyse_cleared=TRUE`) + **204 US `MARKETPLACE_ACTIVITY` signals**. Signals are labelled **ESTIMATED** (Google-Ads-derived) / intent **INFERRED**; search interest kept separate from confirmed sales; missing figures UNKNOWN (never zero); social honestly NOT_SEARCHED/NOT_OBSERVED; country-isolated. No fabricated revenue/growth. **Customer display rides GPD.01** (DataForSEO derived-display leg).

### CX.02 — authoritative product-to-supplier identity: narrow decision record
Evaluated the credible routes within **confirmed access only** ($0, no new licensing):
1. **Existing manufacturer/supplier cross-references** — none available: CJ exposes no GTIN/MPN (CJ-native pid/sku only); DataForSEO Merchant exposes only a google_product_id (Google namespace). ❌
2. **Licensed identifier-publishing supplier** — **BigBuy** (EU wholesaler) typically publishes **EAN** + direct product URLs → the strongest authoritative route *if licensed*; **AliExpress** publishes variant IDs + direct URLs but inconsistent authoritative GTIN. **Both require new access/licensing that is NOT currently authorised and whose access is NOT confirmed** — so neither can be used now. Caveat (directive): do **not** assume a shared GTIN will exist merely because BigBuy supports EAN fields — a US Google-Shopping generic listing with no GTIN may not overlap a BigBuy EAN.
3. **Documented exact-product mapping from a source provider** — none available.
4. **Image-vision + authoritative corroboration** (BE260) — needs a vision capability + image cache/analysis rights (both blocked).
**Decision:** no authoritative route exists within currently authorised providers. The single most credible route to unblock CX.02 is **a scoped BigBuy access/rights + catalogue-identifier-coverage evaluation** (does its EAN/identifier coverage actually overlap US Google-Shopping discoveries? + US shipping + cost) — a founder licensing decision. **No expenditure, licensing or API acquisition performed or authorised here.** Exact verification is NOT weakened to image/title/attribute similarity.

### Tests / regression
US-only country isolation PASS; identity dedup PASS (0 collisions); rights/provenance PASS (per-source catalogue_source_rights honoured); advertising/competitor observation integrity PASS (presence-only, no fabrication); seller dedup PASS (listing≠seller, UNKNOWN honoured); search/social freshness + ESTIMATED labels PASS; UNKNOWN≠zero PASS; subscriber/tenant isolation PASS; supplier-sourceable gate PASS (concrete `bound=0`, `variant_verified=0`); PAL/CJ image block intact; regression GREEN (pd_release 13/13, RVD 5/5, BE256 7/7). No synthetic fixture reported as market acceptance; no customer acceptance claimed. Frontend not rebuilt; no false "verified" US advertising/seller/revenue/supplier displays introduced.

## Addendum 44 — BE263 rights enforcement (actual code fix) + CX.08/CX.10 verification + BigBuy decision ($0, 0 provider calls)

**Date:** 2026-11-23. Rights enforcement was the first priority and produced the one **actual code change** of this batch; CX.08/CX.10 were verified; the BigBuy decision was made from stored evidence. No new provider calls.

### §2 Rights enforcement — demonstrated defect FIXED (mig_334) [ACTUAL CODE CHANGE]
`fn_ecommerce_product_intelligence_core` derived and exposed customer-facing claims from **uncleared** sources: `observed_advertisers.count=5` sourced solely from `META_AD_LIBRARY` (`analyse_cleared=false`), and ADVERTISING_EMERGENCE (META) + MARKETPLACE_VALIDATION (EBAY) families marked `QUALIFYING` / `contributes_to_qualification=true` — without consulting `catalogue_source_rights`. Fixed with the smallest safe additive post-pass: families/counts whose source lacks `analyse_cleared` are rendered **NOT_AUTHORISED + non-contributing** (historical evidence retained for audit, excluded from analysis/display), the META advertiser count is nulled to `NOT_AUTHORISED`, and a `rights_enforcement` object is added. The upstream accepted qualification engine is untouched. Verified on coaxial cable (US): META/EBAY/REDDIT families → NOT_AUTHORISED/non-contributing, DataForSEO (cleared) stays QUALIFYING, derived "5" no longer exposed. **Retention vs analyse/display is now correctly distinguished.** No rights flags were changed.

### CX.08 — US pricing & saturation → ENGINEERING VERIFIED + BLOCKED — EXTERNAL RIGHTS
Verified on stored US evidence (no new calls): **180 US competitor observations, all prices USD** (0 non-USD — correct currency handling), country-scoped (no cross-country leak; the core filters `country_code`). **Seller identity never captured (0/180) → distinct sellers honestly UNKNOWN**, never equated to listing count; a product with few listings is **not** inferred to have <5 US sellers. Live customer display BLOCKED: `EBAY.analyse_cleared=FALSE` → competitor/price evidence is now NOT_AUTHORISED in the core (mig_334).

### CX.10 — research UX → ENGINEERING VERIFIED (backend contracts) / CUSTOMER ACCEPTANCE PENDING
The backend contracts the research UI consumes are verified + rights-enforced: supplier **candidates are distinct from verified matches** (`supplier_resolution.bound`; the candidate lookup is `CANDIDATE_REQUIRES_VERIFICATION`); a **sourceable Product Card requires a bound authoritative supplier** (concrete `bound=0`); **blocked provider data cannot leak** (uncleared sources now return NOT_AUTHORISED + null counts, so the UI cannot render them whatever its logic); **profit is UNKNOWN when inputs are missing** (`no_candidate`); CJ image block + rights-safe media fallback; GPD.12 score suppression preserved. No Lovable change was necessary (the backend fix flows through; no demonstrated UI defect) and no credits were spent. **A signed-in browser sighting remains the customer-acceptance step and is not claimed from backend tests.**

### §5 BigBuy US-sourcing feasibility — decision record
Stored evidence: **no BigBuy access anywhere** — 0 `%bigbuy%` tables, 0 `discovery_provider_market_config` rows, 0 supplier rows, 0 n8n credential. Evaluated against US requirements: BigBuy is an **EU-centric wholesaler** (EU warehouses, EUR pricing, limited/costly US shipping + fulfilment → poor US dropshipping economics); its EAN coverage would **not reliably overlap** barcode-less US Google-Shopping generic discoveries (a supplier publishing EANs is not proof a US generic shares one); and it requires a **new paid subscription/integration** that is not authorised and not in place. **Decision: BigBuy is unsuitable for US supplier-sourcing.** The more appropriate **already-authorised** route is **CJ Dropshipping** (US-capable — US `shippingCountryCodes`, BE256 proved a live US-available product + 15 variants); CJ's only gap is authoritative **identity**, best closed by an authoritative variant designation (BE256-enabled) or image-vision + corroboration (BE260) — not a supplier switch. Most credible supplier-identity route therefore = **CJ + authoritative designation/vision**, not BigBuy.

### Tests / regression
Source analysis-rights enforcement PASS (uncleared → NOT_AUTHORISED, verified live); country-specific prices PASS (USD, isolated); UNKNOWN≠zero PASS; seller dedup PASS (UNKNOWN when identity absent); provenance PASS; candidate vs verified-sourceable PASS (concrete bound=0); customer supplier links — none claimed (no bound supplier); rights-safe media PASS (CJ block); tenant/country isolation PASS; accepted GOLD regression GREEN (pd_release 13/13, RVD 5/5, BE256 7/7). No fixture-only test reported as market/customer acceptance. GPD.01–22 and 11/22 preserved.

## Addendum 45 — BE264 rights enforcement at the DECISION boundary + customer-facing ad/competitor suppression + supplier-identity closeout ($0, 0 provider calls)

**Date:** 2026-11-23. BE263 (mig_334) suppressed unauthorised evidence **fields** in the display core. BE264 verified the layer underneath — that final **decisions** and **customer-visible counts** use only `analyse_cleared` evidence — and fixed the demonstrated gaps. Four migrations (mig_335–338), all server-side; no Lovable change; no credits; no new provider calls.

### §2 Decision-boundary rights enforcement — demonstrated defect FIXED (mig_335) [ACTUAL CODE CHANGE]
`fn_stage1_early_opportunity_state` (the orchestrator that computes `early_opportunity_state` / `qualifying_family_count` / `qualified`, consumed by the intelligence core and the sourceable gate) counted **every** present/qualifying evidence family regardless of source rights. On the real US record **coaxial cable** (77004cbb) this produced `early_opportunity_state = RESEARCH_PRIORITY` driven by **three** qualifying families, two uncleared: ADVERTISING_EMERGENCE←META_AD_LIBRARY and MARKETPLACE_VALIDATION←EBAY (only SEARCH_DEMAND←DATAFORSEO is cleared). Uncleared observations were materially changing the authorised decision — exactly what BE263's display post-pass did not reach, because the upstream qualification engine was untouched. **Smallest safe fix at the computation boundary:** each evidence family is mapped to its provider and gated on `catalogue_source_rights.analyse_cleared`; uncleared families → `present=false, qualifying=false, state=NOT_AUTHORISED` (retained in `evidence_families` for audit); counts/`qualified`/`early_opportunity_state` are recomputed from authorised families only. `qualified` is re-derived **conservatively** (`qualified AND ≥2 authorised qualifying families`) — the gate can only **downgrade**, never upgrade. The investigation function `fn_stage1_supplier_resolution_qualified` is unchanged (full detail retained nested for audit). **Verified:** coaxial US ungated 3/3/RESEARCH_PRIORITY → gated **1/1/EMERGING**, `qualified=false`; the customer-facing core now returns EMERGING (BE263 display suppression still intact — both layers enforce rights). Positive control: across 60 active US products the gate downgraded only the 2 that depended on uncleared evidence; **1 product still reaches RESEARCH_PRIORITY on cleared DataForSEO evidence alone** (no over-suppression); 57 DISCOVERED unchanged. Isolation: GB→DISCOVERED(0) (no cross-country leak), wrong tenant→DISCOVERED(0).

### §3 CX.10 — customer-facing ad/competitor evidence rights gates (mig_336/337) [ACTUAL CODE CHANGE] + rights-aware selftest (mig_338)
Inspecting the signed-in workspace evidence functions revealed a **demonstrated customer-visible leak**: `fn_product_competitor_evidence` (the "Competitor prices" drawer, `CompetitorEvidenceSection → priceRangeLine`) surfaced **98 EBAY_BROWSE offers** (`EBAY`: `analyse_cleared=false`, `display_cleared=false`) for coaxial US as an OBSERVED "Competitor price range" — unauthorised analysis/display of an uncleared source. `fn_product_ad_evidence` likewise computed `observed_advertisers=5` from META_AD_LIBRARY (uncleared); for US the FE hides it (Meta coverage `SOURCE_UNSUPPORTED → "Not available"`) but an EU/UK market would render it — a latent data-boundary leak. **Smallest safe fix (both server-side, at the data boundary — no Lovable credits):** every scan is gated to `analyse_cleared` sources via a rights-table-driven, fail-closed prefix match (`DATAFORSEO_SELLERS→DATAFORSEO` stays; `EBAY_BROWSE→EBAY` and any unlisted source excluded). Uncleared competitor offers no longer populate count/range/ad-summary (a `rights_enforcement.excluded_uncleared_offers` aggregate is added, raw rows retained for audit); uncleared advertiser/creative counts → null + `NOT_AUTHORISED`, cannot assert OBSERVED or low-competition. **Verified:** coaxial US competitor → `UNKNOWN`, count 0, **98 excluded**; coaxial US ad → `observed_advertisers=null`, `NOT_AUTHORISED`, total null; positive control (DataForSEO GB product 1def97b0) → still **OBSERVED, 5 offers, $33.99–$39.99, 0 excluded**. `fn_product_competitor_evidence_selftest` updated to be rights-aware (populated-range fixture drawn from cleared sources only; new `UNCLEARED_SOURCE_EXCLUDED` check) → **6/6**. Remaining CX.10 checklist confirmed by code+backend: candidates labelled; unverified supplier never shown confirmed (`exactVariantVerified && exactSkuConfirmed` gate; supplier images only when `exactSkuConfirmed`); supplier-origin reference gallery separate + "not commercially cleared"; missing evidence → UNKNOWN/NOT_AUTHORISED; **"Profitability not confirmed"** when inputs insufficient; sourcing actions are backend-sole-authority identity-gated (`concreteProductActionsAllowed`, image generation only `GENERATABLE_FROM_AUTHORIZED_REFERENCE`). **A signed-in browser journey was NOT performed this cycle** (no tenant credentials available at $0) — signed-in customer acceptance is therefore **not claimed**; the public signed-out surface loads cleanly; the backend contracts the UI consumes are verified and rights-enforced.

### §4/§5 Supplier identity — contract intact; no authoritative bridge; bounded evidence requirement
Server gate intact: `commerce_concrete_supplier_resolution.bound=0/9`, `commerce_cross_supplier_identity.variant_verified=0/2` — **no US discovery is bound to a CJ supplier.** The stored candidate lookup for the real US discovery **9128d818** ("2026 Upgraded Galaxy Star Projector Night Light") returns exactly 1 candidate, `classification=CANDIDATE_REQUIRES_VERIFICATION`, `variant_verified=false`, `bound=false`, `authoritative=false` — the CJ star projector's 15 variants are **not** treated as proof of exact match. Re-confirmed (not rebuilt): **no authoritative shared identifier exists in permitted records** — zero gtin/upc/ean/mpn/barcode keys anywhere in `commerce_signals`; US-discovery identity is only `platform_id`(242)/`normalized_name`(18)/`canonical_url`(2); the CJ product **2610010255571606100** (SKU CJJT3213323, 15 variants) carries **no** GTIN/UPC/barcode in `raw`/`supplier_enrichment`. So neither `SHARED_GTIN` nor `AUTHORITATIVE_SUPPLIER_REF` can be satisfied; image/attribute similarity alone is insufficient for EXACT. **Smallest outstanding supplier-identity evidence requirement (ONE bounded request, $0, NOT executed):** US product UUID `9128d818-b7b5-45df-bbd6-ee740d3d08f8`; prospective supplier **CJdropshipping** pid `2610010255571606100`/SKU `CJJT3213323`; required authoritative reference = a single same-product identifier present on **both** sides — a GTIN/UPC/EAN (SHARED_GTIN) or an authoritative brand/manufacturer cross-reference naming the CJ SKU/exact model (AUTHORITATIVE_SUPPLIER_REF); permission = both candidate providers are already `analyse_cleared` (DataForSEO, CJ), so no new right is needed — only the identifier, which must come from an **authorised** source (DataForSEO Merchant product endpoint or the brand's own listing), never from a marketplace (`EBAY`/`AMAZON` are `analyse_cleared=false`); verified cost = **$0 authorised now (no new calls)**; if later authorised, ONE DataForSEO Merchant product lookup for the exact US listing to retrieve a GTIN/MPN (only if the listing exposes one). If neither side exposes a GTIN, no permitted data can establish EXACT and the candidate must remain CANDIDATE_REQUIRES_VERIFICATION. **BigBuy** unchanged from BE263: no connected access → unavailable for execution (not re-searched); **CJ remains the authorised supplier.**

### Tests / regression / cost
Decision-boundary gate verified live (coaxial downgrade, positive control, isolation); competitor/ad rights gates verified live (suppression + positive control + isolation); `fn_product_competitor_evidence_selftest` 6/6 (rights-aware); accepted GOLD regression GREEN in clean service context: **pd_release 13/13, RVD 5/5, BE256 7/7**. No provider calls; **$0**. No `catalogue_source_rights` flags changed; no evidence deleted (uncleared observations retained for audit). GPD.01–22 and the 11/22 acceptance preserved; 22 GOLD units preserved.

## Addendum 46 — BE265 supplier-identity acquisition readiness + direct-sourcing-link readiness + economics-contract verification ($0, 0 provider calls)

**Date:** 2026-11-23. Built the smallest independently-useful workflow for collecting and evaluating authoritative supplier-matching evidence, plus the direct-supplier-link readiness gate, and verified the economics input contract — all reusing the existing identity/economics architecture (no parallel engines). Four migrations (mig_339–342), read-only evaluators + selftests; $0; 0 provider calls.

### §2 Authoritative-evidence ledger (mig_339) + selftest (mig_340) [NEW, read-only]
`fn_supplier_identity_evidence_ledger(tenant, product, source, supplier_pid, market)` evaluates a (genuine US discovery, supplier candidate) pair and records, per candidate: the independent US discovery identity, the proposed supplier identity, **supporting** authoritative evidence present, **missing** authoritative evidence, provenance + observation date, verification state, and the **single specific next acquisition requirement**. The verification state comes ONLY from the strict BE246 engine (`fn_cross_supplier_exact_variant_check`) — it never turns title/image/attribute resemblance into EXACT (asserted by the selftest's MIRRORS_BE246_ENGINE check). Evidence vocabulary mirrors the engine: SHARED_GTIN | CJ_NATIVE_NAMESPACE | AUTHORITATIVE_SUPPLIER_REF | SUPPLIER_VARIANT_CATALOG(fresh) | DESIGNATED_EXACT_VARIANT. **Verified live** on the genuine US discovery **9128d818** (2026 Galaxy Star Projector, `dataforseo_merchant`, `dataforseo_merchant_product_id=16421576920176765467`) vs CJ **2610010255571606100** (SKU CJJT3213323): CANDIDATE_REQUIRES_VERIFICATION, supporting=[fresh 15-variant catalogue observed today], missing=[AUTHORITATIVE_PRODUCT_IDENTITY, DESIGNATED_EXACT_VARIANT], next=obtain a shared GTIN OR an authoritative supplier cross-reference (manufacturer+MPN). Selftest 6/6.

### §3 Supplier-side evidence feasibility (CJ, from existing records)
CJ provides: rich **variant-level specs** (15 variants: key, sku, vid, image, per-variant weight 139 g, price $7.29), a **US shipping route** (`shipping_country_codes=[CN, CN_US]`, `AVAILABLE_PROBED`), and a **supplier cost range** ($6.08–$10.76). CJ does **NOT** provide: any GTIN/UPC/EAN, any manufacturer/brand/model/MPN (`supplier_id=9999` generic), or a direct product URL. **Conclusion:** CJ variant specs describe the CJ product but **cannot prove same-product identity** against a barcode-less US Google-Shopping listing. A CJ-native SKU is not equivalence to a Google-Shopping listing.

### §4 Direct supplier-link readiness (mig_341) + selftest (mig_342) [NEW, read-only]
`fn_supplier_sourcing_link_readiness(...)` gates a CONFIRMED direct-sourcing action on: verified exact identity (BE246 engine) AND a supplier-provided link that is present, authorised-origin, product-level, SKU-corresponding, with a fresh availability timestamp — else BLOCKED with explicit reasons; it never fabricates/scrapes a URL. **Findings:** the Product Card contract (`fn_stage3b_product_card`) emits **no direct supplier URL at all** today (only workflow-state actions + the commercial-verification binding; asset-lock keeps identity/assets to `fn_ad_product_card_authority`), and **all 1,317 stored CJ rows have `product_url=NULL`** — so no bad link can leak, and no candidate can receive a confirmed direct-sourcing action. Verified live: 9128d818 ↔ CJ 2610010255571606100 → BLOCKED [exact_identity_unverified, supplier_link_missing]. Selftest 4/4.

### §6 Economics input-contract verification (no change — verified ready)
`fn_resolve_supplier_economics(product, market)` already accepts verified supplier price, selected exact variant (from `commerce_concrete_supplier_resolution.bound`), US stock (per-variant inventory), and destination freight; it **explicitly excludes** import duties, VAT/sales tax, customs, payment processing, advertising, returns and platform fees; and it returns **profitability UNKNOWN** (`available=false`) with specific reasons (`no_candidate`; `requires_exact_variant_confirmation`; `requires_sku_exact_destination_shipping`; `requires_destination_landed_cost`; `requires_confirmed_selling_price`) — never a fabricated profit. The $10/unit ad assumption and the ~$25–$30+ net target remain the selection objective layered on the honest gross building block, not baked in. Verified live: genuine US discovery 9128d818 → `no_candidate`; existing UNVERIFIED candidate 534d98bc → present but `profitability.available=false`. No code change needed (adding a net calc with no verified product would risk fabrication).

### §5/§8 Supplier strategy + the bounded evidence path (NOT executed)
Server gate intact (concrete `bound=0`, `variant_verified=0`). The authoritative bridge for the generic CJ star-projector pair is **not** achievable from existing/permitted data — neither side has a GTIN and CJ exposes no manufacturer/MPN — so **a paid one-sided GTIN request is NOT warranted** (no credible supplier-side cross-reference, per the directive). Structural finding: CJ-sourceable products are **generic** (no identifier either side) while identifier-bearing US discoveries are **branded** (several genuine US **Govee Star Projector** discoveries exist — e.g. `d985e5af`, seller Govee — which carry manufacturer identifiers but which CJ cannot authentically supply). **Smallest realistic paths:** (a) for a generic CJ candidate, authoritative identity can only come from **image-vision corroboration** (needs CJ image-analysis/cache rights — currently `SUPPLIER_PROVIDED_REFERENCE_ONLY` — plus a vision capability); (b) for a branded US discovery, an authoritative GTIN/MPN is retrievable discovery-side via DataForSEO Merchant (`DATAFORSEO_MERCHANT`, analyse_cleared=true) but the supplier side requires a **new authorised branded-goods distributor relationship** (not CJ; not claimed authorised on API availability). Image similarity alone never establishes EXACT.

### Tests / regression / cost
New read-only evaluators + selftests: identity-evidence ledger **6/6**, sourcing-link readiness **4/4**. Accepted GOLD regression GREEN (clean service context): **pd_release 13/13, RVD 5/5, BE256 7/7, competitor_evidence 6/6**. $0; 0 provider calls; no rights flags changed; no evidence deleted. GPD.16/17/19 unchanged; 22 GOLD units and the 11/22 acceptance preserved.

## Addendum 47 — BE266 generic-only dropshipping discovery: brand-exclusion enforcement, CJ URL root-cause + capture, generic-identity method, CJ enquiry draft ($0, 0 provider calls)

**Date:** 2026-11-23. Permanent founder directive: Strateloq discovers **genuine generic, unbranded** dropshipping products only; branded/IP-sensitive items are excluded from active customer recommendations (historical records preserved for audit). This batch fixed two demonstrated defects and added the generic-only enforcement + tests. Four migrations (mig_343–346) + one brand-registry data correction; $0; 0 provider calls.

### §4 CJ product_url — root-caused + capture gap fixed (mig_343) [ACTUAL CODE CHANGE]
Across **all 1,317 CJ rows, 0** carry any product-page URL key in `raw`/`supplier_enrichment` (only image URLs); the CJ product-query schema has no `productUrl` field, and the fields CJ does provide were mapped correctly (1,316/1,317 have a name). So the NULL `product_url` is **NOT a mapping defect of existing data** — it is a provider/capture limitation. But `fn_ingest_cj_product_media` never promoted a product URL to the `product_url` column the Product Card / direct-link readiness evaluator read — a confirmed integration gap. Fixed on the success path: `product_url = coalesce(v_purl, product_url)` where `v_purl` is a supplier-provided **https cjdropshipping.com** URL from the payload (never invented, guessed or scraped). BE256 fail-closed selftest preserved **7/7**. The actual URL must still come from an authorised CJ detail response or the §8 enquiry.

### §1/§11 Generic-only exclusion — two demonstrated defects fixed (mig_344 data + mig_345/346) [ACTUAL CODE CHANGE]
The registry-driven screen `fn_is_branded_or_ip_sensitive` had **both** error directions: a FALSE POSITIVE (bare token `galaxy`→"Samsung Galaxy" over-matched generic astronomy/star projectors, wrongly flagging the genuine US generic `9128d818` as BRANDED) and FALSE NEGATIVES (real brands like **Govee**, **Anker** absent → 6 Govee products sat in the active WATCH recommendations as generic). Separately, **neither** `fn_discovery_product_hidden` nor the customer recommendations producer `fn_monday_top_opportunities` excluded branded products at all. Fixes: (mig_344 data) deactivate `galaxy`, add distinctive brand tokens (govee, anker, dyson, bose, sony, samsung, xiaomi, logitech, fitbit, gopro, dji, philips, lego — `samsung` replaces the astronomy false-positive and still catches Samsung Galaxy), and re-screen the founder tenant's stored `screening_state` (records preserved); (mig_345) add one live-screen predicate to `fn_monday_top_opportunities` so branded/IP-sensitive products are excluded from `ready_to_test`+`watchlist` (contract → `...v5_generic_only`). Verified: generic galaxy/star projectors + coaxial → not flagged; Govee/Anker/Samsung → flagged; founder recommendations (limit 50) → **0 branded / 0 Govee**; `9128d818` now eligible. Selftest `fn_generic_only_discovery_selftest` **7/7** (mig_346).

### §5 Generic-product identity method (no new engine — already supported)
For a barcode-less generic dropshipping product, the strict BE246 engine already accepts a non-GTIN authoritative method: **`AUTHORITATIVE_SUPPLIER_REF`** — a supplier-issued cross-reference recorded in `extended.supplier_refs` with `match_method` in (`shared_identifier`,`gtin`,`authoritative`,`exact_sku`,`barcode`) — plus a fresh variant catalogue and a designated variant. `CJ_NATIVE_NAMESPACE` covers supplier-origin items. The BE265 ledger surfaces exactly which of these is present/missing. A GTIN is therefore **not required** if a supplier-issued confirmation/cross-reference establishes exact identity. Resemblance (name/appearance/category/keywords/approx specs/image-only) is never accepted.

### §8 Focused CJ enquiry (DRAFT — not sent)
Stored evidence cannot establish identity or a direct URL, so a concise CJ enquiry was prepared (`docs/BE266-CJ-SUPPLIER-ENQUIRY-DRAFT.md`) covering the 8 required items (official product URL for PID 2610010255571606100; 15-variant SKU/links; manufacturer/model; documented cross-references; exact-equivalence confirmation; US stock/fulfilment; destination shipping quotes; subscriber sourcing-link permission). It requests no unrelated permissions and does not re-open resolved image/licensing discussions. **Not sent — awaiting founder authorisation.**

### §9/§10 Profitability + Product Card (preserved/verified)
Economics input contract ready (BE265 §6: accepts verified price/variant/stock/freight; excludes duties/taxes/fees/ads/returns; profitability UNKNOWN when unsupported, never fabricated; ~$25–$30 net + $10/unit ad stay the objective). Product Card fail-closed publication gate preserved (concrete `bound=0`); a candidate without authoritative supplier evidence remains an internal research candidate; direct-link readiness (BE265 mig_341) BLOCKS a confirmed direct-sourcing action without verified exact identity + a valid supplier link.

### Tests / regression / cost
`fn_generic_only_discovery_selftest` **7/7**; GOLD regression GREEN (clean service context): **pd_release 13/13, stage1_opportunity_invariants 8/8, RVD 5/5, BE256 7/7, competitor 6/6, ledger 6/6, link-readiness 4/4**. $0; 0 provider calls. No records deleted; 18-country architecture untouched; no `catalogue_source_rights` flags changed; GPD.16/17/19 unchanged; 22 GOLD units and the 11/22 acceptance preserved.

## Addendum 48 — BE267 automatic CJ image-rights classification + customer-display gate ($0, 0 provider calls)

**Date:** 2026-11-23. Built automatic recognition of which CJ images are authorised for display in the authenticated paid research workspace, honouring CJ's 22 Nov reply (product **data/SKUs/variants/stock/links** display-permitted; **images** not automatically licensed). Reuses `catalogue_source_rights` + Product Asset Lock; four migrations (mig_347–350) + the evidence store; $0; 0 provider calls.

### §4 Does CJ provide machine-readable image rights? — NO
CJ image asset records examined: **12** in `product_image_assets` (all `rights_state=SUPPLIER_PROVIDED`) + **36** in `supplier_product_assets` (28 `SUPPLIER_PROVIDED` + 8 `UNKNOWN`); across **1,317** CJ catalogue rows `media_rights` is `SUPPLIER_PROVIDED_REFERENCE_ONLY` on only **4** and **absent on 1,313**, with no `licence/permission/copyright/authorisation` key anywhere. These are **provenance markers, not a display licence** — consistent with CJ's reply. **CJ provides no documented machine-readable per-image or per-supplier image authorisation.** Not manufactured: genuine authorisations, if obtained via the §11 clarification, are recorded in the new evidence store.

### §5/§6 Automatic classification (mig_347 store + mig_348 classifier + mig_349 selftest) [NEW]
New evidence store `commerce_supplier_image_rights` (image/supplier/product-specific permissions; absence => RIGHTS_UNVERIFIED) and classifier `fn_cj_image_display_classification` → **DISPLAY_AUTHORISED | RIGHTS_UNVERIFIED | DISPLAY_RESTRICTED | REVIEW_REQUIRED**. Reuses `catalogue_source_rights.display_cache_images_cleared` as the provider-global baseline; most-specific scope wins (image>product>supplier>provider); image-level overrides broader; revoked evidence ignored; contradiction => REVIEW_REQUIRED; **no blanket CJ permission from one supplier/product**. Display is **separate** from analysis/cache/advertising (each needs its own scope) and **customer download is always false**. Verified live: real CJ image → RIGHTS_UNVERIFIED, display_allowed=false. Selftest **8/8** (synthetic rows rolled back — never counted as genuine).

### §7/§8 Customer image-display gate (mig_350) [ACTUAL CODE CHANGE]
Demonstrated defect: `fn_product_card_display_image` returned supplier images with `has_image=true` without a display-rights check — on BOTH the authoritative branch (`fn_ad_product_card_authority` returned a CJ `SUPPLIER_PROVIDED` image as authoritative, e.g. product `e453eed4`) and the fallback. Fix: for an externally-sourced image (CJ/eBay/DataForSEO/Meta/TikTok/Reddit/marketplace/supplier) the resolver consults the classifier and returns the image **only** when DISPLAY_AUTHORISED; otherwise `has_image=false, image_rights_unverified`, keeping the rights-safe placeholder and permitted product data. Genuine customer-authorised assets (uploads, authorised-reference generations, non-supplier providers) are **not** gated — genuinely authorised images are not blocked. Revocation (`revoked_at`) immediately returns an image to RIGHTS_UNVERIFIED (no cached asset bypasses the update). Verified: CJ product `e453eed4` → image suppressed, product data intact; a non-supplier asset is unaffected; **pd_release 13/13** (Product Asset Lock + image gates intact). No Lovable change (the FE already renders placeholder + data for `has_image=false`).

### §9/§10 Supplier identity + sourcing (preserved)
The CJ generic projector (`9128d818` ↔ CJ `2610010255571606100`/`CJJT3213323`, 15 variants) remains **unverified** as an exact match (image similarity never becomes identity); no stored direct product URL. Remaining external requirements kept visible in the tracker: official CJ product-page URL, authoritative generic-product identity confirmation, exact variant designation, verified US stock/shipping. GPD.16/17/19 remain NOT ACCEPTED. The 1,317-row URL audit was not repeated.

### §11 CJ image-rights clarification (DRAFT — not sent)
Since CJ provides no machine-readable image authorisation, a narrow 7-item clarification was prepared (`docs/BE267-CJ-IMAGE-RIGHTS-CLARIFICATION-DRAFT.md`): supplier image authorisation, scope, documented rights signal, verification/retention, caching, separate analysis rights, revocation. It does not re-ask the already-confirmed data/SKU/link rights. **Not sent — awaiting founder authorisation.**

### Tests / regression / cost
`fn_cj_image_rights_selftest` **8/8**; GOLD regression GREEN (clean service context): **pd_release 13/13, stage1_opportunity_invariants 8/8, RVD 5/5, BE256 7/7, competitor 6/6, ledger 6/6, link-readiness 4/4, generic_only 7/7**. $0; 0 provider calls. No `catalogue_source_rights` flags changed; no records deleted; tenant isolation + Product Asset Lock preserved; GPD.16/17/19 unchanged; 22 GOLD units and the 11/22 acceptance preserved.

## Addendum 49 — Resume (post-BE267): CJ sourcing closure verification + single consolidated enquiry ($0, 0 provider calls, no DB change)

**Date:** 2026-11-23. AliExpress on hold (no work). A verification-and-consolidation pass over the CJ sourcing loop; no code/DB change, so BE267 regression stands. No GOLD checkbox flipped (nothing newly passed real-world acceptance); GPD.16/17/19 remain pending.

- **A1 (CJ exact-product sourcing):** from stored, non-chargeable evidence the CJ candidate `2610010255571606100`/`CJJT3213323` has all **15 variants** with CJ-native VID+SKU+price ($6.08–$10.76), `AVAILABLE_PROBED`, shipping `[CN, CN_US]`; but **no product-page URL, no GTIN, no manufacturer/model (`supplier_id=9999`), no documented US↔CJ cross-reference** → stays `CANDIDATE_REQUIRES_VERIFICATION` (similarity/imagery/name/category never treated as exact). A **single consolidated CJ enquiry** was prepared (`docs/CJ-CONSOLIDATED-ENQUIRY-DRAFT.md`), merging the BE266 supplier draft + BE267 image draft and **dropping items CJ already answered** (data/SKU/variant/stock/link display, per the 22 Nov reply) — Part A (product identity/URL/stock/freight) + Part B (image rights). Not sent.
- **A2 (economics):** honest — genuine US discovery `9128d818` → `no_candidate`; CJ candidate `534d98bc` → `exact_variant_confirmed=false`, exact-variant stock `UNKNOWN`, US destination freight `NOT_CALCULATED_FOR_DESTINATION` (never assumed 0), landed/profitability `UNKNOWN`. No invented margins/availability/delivery.
- **A3 (research journey):** backend contracts verified — rights-safe image placeholder, country-keyed isolation, supplier link `BLOCKED [exact_identity_unverified, supplier_link_missing]`, Save/Monitor/Compare functions present, store/ad founder-gated. **No authenticated browser session available ($0) → signed-in browser acceptance NOT claimed.** No demonstrated defect to fix.
- **A4 (tracker):** CX.02/CX.09 evidence annotated; Build Evidence row added; no acceptance flipped; 18-market scope, formulas and the 22 GOLD / 11-accepted counts preserved.

**Smallest remaining external blocker:** the CJ authoritative product-page URL + a manufacturer/model or documented same-product cross-reference (consolidated enquiry Part A) to bridge US discovery `9128d818` ↔ CJ `2610010255571606100`, plus exact-variant US stock + a US shipping quote for economics. All gated on the founder sending the consolidated enquiry; no AliExpress, no paid calls, $0.

## Addendum 50 — BE267 (rev): supplier sourcing closure within existing CJ permissions — official-link recording method ($0, 0 provider calls)

**Date:** 2026-11-23. Founder decision: **no CJ enquiry, no further image-rights requests.** Operate within CJ's confirmed 22 Nov scope (display of product data, SKUs, variants, stock, direct CJ product links; customers obtain images directly from CJ; rights-safe placeholders inside Strateloq). No AliExpress work. One migration pair (mig_351/352); $0; 0 provider calls.

- **§1/§2 Official supplier link — documented authorised method:** CJ's authorised `product/query` API returns **no product-page URL** (verified on n8n workflow `zwTkywEYKsmojs6g` execution `30723`: `CJ Detail` fields are productImage/productSku/productName/variants/weight/video — no productUrl/link/href). Inventing a format is prohibited and no enquiry will be sent, so the official link is obtained from CJ's own merchant portal (authorised) and recorded via the new `fn_record_supplier_product_url` (mig_351): validates an https cjdropshipping.com **product-level** URL, stores it with `FOUNDER_VERIFIED_SUPPLIER_PORTAL` provenance, service_role only, **never invents/constructs** a URL and never treats an unverified link as confirmed. The BE265 link-readiness evaluator then consumes it (same validation), leaving **exact identity** as the only remaining block. Selftest **7/7** (the real CJ record's `product_url` stays NULL — no synthetic persisted). The CJ ingestion URL-capture (mig_343) remains the other authorised path when CJ data supplies a URL.
- **§3 Identity preserved:** the generic US projector `9128d818` ↔ CJ `2610010255571606100` stays **CANDIDATE_REQUIRES_VERIFICATION** (recording a link does not verify identity); no US generic product currently has an authoritative exact-identity bridge (0 `variant_verified`, 0 concrete `bound`). No branded sourcing; no AliExpress.
- **§4 Verified:** supplier-link integration readiness (recording + readiness evaluator); exact SKU/variant handling (15 CJ variants with VID+SKU+price); US stock/freight **UNKNOWN** (not fabricated); profitability **UNKNOWN**; Product Card eligibility fail-closed (concrete `bound=0`); Save/Monitor/Compare present; rights + tenant restrictions preserved (image gate, tenant guards).
- **§5 Tracker:** CX.02 evidence annotated with the official-link recording method; no GOLD acceptance flipped; CJ image-rights expansion kept outside P0; **GPD.16/17/19 remain OPEN**; 11/22 accepted and 18-market scope preserved.
- **Regression GREEN:** pd_release 13/13, record_url 7/7, cj_image_rights 8/8, ledger 6/6, link-readiness 4/4, generic_only 7/7, BE256 7/7, RVD 5/5, competitor 6/6.

**Smallest remaining external dependency:** the official CJ product-page URL for PID `2610010255571606100` (founder copies it from the CJ portal and records it via `fn_record_supplier_product_url`), plus — for exact identity — a manufacturer/model or documented same-product cross-reference, and — for economics — exact-variant US stock + a US shipping quote. None require an enquiry or payment; the URL path is fully built and waiting on the founder-supplied value.

## Addendum 51 — BE270: Close GPD.16 attempt — official CJ link + exact identity (escalated external blocker, $0, 0 calls, no code change)

**Date:** 2026-11-23. Objective: obtain the real official CJ product URL + authoritative identity using authorised existing access. Outcome: both require external access **unavailable to the build session** — escalated with the precise limitation. No code change; no provider calls; $0. Identity and rights unchanged; no GOLD acceptance flipped (GPD.16/17/19 OPEN).

- **§2 Official CJ URL — NOT obtainable here (specific limitation identified):** CJ's authorised `product/query` API returns no product-page URL (BE267). The portal/browser route is unavailable: this cloud session has **no authenticated CJ merchant-portal session** (no founder CJ credentials), the environment network **blocks `cjdropshipping.com` (403 CONNECT tunnel failed)**, and **no machine is attached** (no built-in/Chrome browser on the founder's computer). Per the directive, no URL was guessed or constructed, and no success was claimed. The recorder `fn_record_supplier_product_url` (mig_351) is ready; the founder must copy the official URL from CJ's portal and record it.
- **§3 Authoritative identity — unchanged:** `9128d818` ↔ CJ `2610010255571606100` stays `CANDIDATE_REQUIRES_VERIFICATION`; CJ provides no GTIN/manufacturer/model in stored data or its API, and the CJ product page (the next source) is inaccessible. No supplier reference fabricated.
- **§4 No stronger alternative:** catalogue-wide `variant_verified=0`, concrete `bound=0`, `0` GTIN/MPN keys; the only two `commerce_cross_supplier_identity` rows are GB (`56a6af36`) and supplier-origin (`534d98bc`) — both out of US-generic scope. No other generic US discovery has stronger authoritative same-product evidence.
- **§5 Revised launch scope confirmed in code:** the sourcing gate blocks on `[exact_identity_unverified, supplier_link_missing]` only — **profitability is not a blocker** (supplier research/direct sourcing are not blocked solely because economics is UNKNOWN). Economics functions preserved; no fabricated profit/shipping. GPD.17 remains NOT ACCEPTED under its original criteria but is excluded from launch-blocking.
- **§6 Integration ready:** once the founder supplies the official link + an authoritative identity reference, the Product Card exposes the verified link, preserves supplier data, shows rights-safe placeholders (customers view images on CJ directly), and Save/Monitor/Compare are present — the server-side identity gate is unchanged.
- **Regression GREEN:** pd_release 13/13, record_url 7/7, link-readiness 4/4, ledger 6/6, cj_image_rights 8/8, generic_only 7/7, BE256 7/7, RVD 5/5, competitor 6/6.

**Escalation:** GPD.16 cannot close from existing authorised access. The two genuinely-external items are (1) the official CJ product-page URL (founder retrieves from the CJ portal → `fn_record_supplier_product_url`) and (2) an authoritative same-product reference. Optionally, allowing `cjdropshipping.com` on the environment network would let Claude attempt a *public* CJ page fetch in future, but the direct, authorised path is the founder recording the URL.

## Addendum 52 — CX.02 Exact Supplier Identity & Verified Sourcing Link: Phase A (stored) + Phase B/C (approved live read-only run) ($0, 0 API points, no orders, no DB change)

**Date:** 2026-11-24. Objective: verify, for the CJ candidate `2610010255571606100` / SKU `CJJT3213323`, the live sourcing facts CX.02 needs — variant US stock, US shipping, a working direct product/variant link, price currency, and an authoritative US↔CJ identifier — exhausting stored evidence first, then running **only** the founder-approved controlled live requests, with no auto-retry. No code change (so BE267/BE270 regression stands); no GOLD acceptance flipped; GPD.16/17/19 remain OPEN.

### Phase A — non-chargeable verification (stored evidence) — recorded Build Evidence row 271
- Selected test variant: key **HD-3 Glass Cover**, SKU `CJJT321332301AZ`, VID `2610010255571607000`, `price_usd 7.29` (one of 15 CJ-native variants).
- **VERIFIED (stored):** (4) **price currency = USD** — `cost_currency=USD`, every variant carries `price_usd`, `sell_price_range_usd` `6.08–10.76`; caveat: the raw CJ payload has no per-field currency code, so this relies on the account currency being USD. Product **ACTIVE + API healthy** (`cj_result=true`, `cj_code=200`, `AVAILABLE_PROBED`, `FRESH_PROBE_OK`). (7) **Gates preserved** — country isolation, supplier-data rights, fail-closed publication; CJ images `RIGHTS_UNVERIFIED`; `pd_release 13/13` earlier; concrete `bound=0`.
- **NOT VERIFIED (data gaps, not errors):** (1) variant US stock — no stock field stored; (2) US freight/delivery — no freight object stored; (3) official product URL — `product_url` NULL and CJ `product/query` returns none; (5) authoritative US↔CJ identifier — none (identity stays `CANDIDATE_REQUIRES_VERIFICATION`).

### Phase B — controlled live requests (founder-approved, exactly one run, no auto-retry) — recorded Build Evidence row 272
Founder approved running the three read-only CJ calls via the existing authenticated **n8n** CJ credential. Built the read-only workflow **`aLdzdQoG4qJCvfkt`** ("Pulse — CX.02 CJ Read-Only Verification"): `Run → CJ Auth → product/stock/queryByVid (vid=2610010255571607000) → logistic/freightCalculate (CN→US, qty 1, that VID) → product/query (pid=2610010255571606100) → Consolidate`. **No ingest, no Supabase write, no order.** Executed **once** (execution `30725`, 2026-11-24 14:26 UTC, workflow status success).

**Outcome — CJ authentication REJECTED.** `authentication/getAccessToken` returned HTTP 200 with `code 1600005`: *"Email or password is wrong, please check and try again. We recommend switching to the apiKey mode."* No access token was issued, so `CJ Stock`, `CJ Freight` and `CJ Detail` each returned `code 1600002` *"access token cannot be empty"* (HTTP 401). **No API points consumed** (`pointsInfo` remaining 50000, usedToday 0); `$0`; no orders; no record changes.

**Root cause (diagnosed, not a workflow bug):** the `CJ Auth` node is **byte-for-byte identical** to workflow `zwTkywEYKsmojs6g` (same `httpCustomAuth` credential id `2IV5tXPu9jAItjKh`, same URL, same empty JSON body) that authenticated successfully on 2026-11-23 (exec `30723`). Nothing in the request shape changed; the **stored credential secret is now rejected by CJ**. The secret cannot be viewed or guessed from here, so this is not a safe local fix — it is an external credential refresh.

### Phase C — results: VERIFIED vs NOT VERIFIED
1. **Variant US stock — NOT VERIFIED** (live call blocked at auth).
2. **US shipping cost / delivery — NOT VERIFIED** (live call blocked at auth).
3. **Direct CJ product/variant link — NOT VERIFIED** (live call blocked at auth; and CJ `product/query` carries no URL field regardless — BE267).
4. **Price currency — VERIFIED USD** from stored evidence (unchanged; not re-confirmed live).
5. **Authoritative US↔CJ identifier — NOT VERIFIED**; identity stays `CANDIDATE_REQUIRES_VERIFICATION` (no GTIN/UPC/EAN, no manufacturer/model, `supplier_id 9999` generic).

Integrity preserved exactly: the authoritative exact-product identity requirement is unchanged (similarity/imagery/name/category never treated as exact), and image rights, 18-market/tenant/country isolation, and the fail-closed publication gates are all unchanged. **No new VERIFIED items; CX.02 not marked complete; no GOLD acceptance checkbox flipped.**

### Tracker / tests / cost
LIVE MASTER — GOLD CX.02 status annotated with the live-run blocker and Addendum-52 reference; Build Evidence rows **271** (Phase A) and **272** (Phase B/C) added; 22 GOLD units and the 11/22 acceptance preserved; GPD.16/17/19 OPEN. No code change, so the standing regression (pd_release 13/13, record_url 7/7, cj_image_rights 8/8, ledger 6/6, link-readiness 4/4, generic_only 7/7, BE256 7/7, RVD 5/5, competitor 6/6) is untouched. `$0`; 0 API points; 0 orders.

**Smallest remaining blocker (external, no auto-retry):** refresh the n8n "CJ Dropshipping API" credential (id `2IV5tXPu9jAItjKh`) to CJ **apiKey mode** with the current working apiKey the local CJ MCP uses (CJ explicitly recommends apiKey mode) — then re-run `aLdzdQoG4qJCvfkt` **once** for stock/freight/detail — **or** run the same three read-only calls through the authenticated local CJ MCP and hand back the raw JSON. Either path unblocks sourcing-data verification; the authoritative exact-identity bridge (item 5) remains separately required and unchanged.

## Addendum 53 — CX.02: CJ apiKey-auth fix + live read-only verification (auth/stock/US freight/currency VERIFIED; URL/identity findings) ($0, ~30 free points, 0 orders, 0 DB writes)

**Date:** 2026-11-24. The n8n→CJ authentication blocker from Addendum 52 is resolved and the three approved read-only CX.02 calls are verified live. No code change; no GOLD acceptance flipped (11/22 preserved); GPD.16/17/19 OPEN (GPD.17 is not a launch blocker under the founder's current scope).

### Root cause and fix (credential, not workflow)
CJ **deprecated the email/password token exchange**. The current/recommended `authentication/getAccessToken` takes **`apiKey` only** — body `{"apiKey":"CJUserNum@api@<hash>"}` (confirmed against CJ API 2.0 docs; corroborated by the `1600005 "…switch to the apiKey mode"` error). The n8n credential `CJ Dropshipping API` (id `2IV5tXPu9jAItjKh`, type **Custom Auth**) was still injecting the old `email`+`password` body. n8n's MCP tools cannot write credential secrets, and the apiKey must never be handled in chat/logs/exports, so the founder re-saved the **same** credential in apiKey mode through n8n's encrypted credential field (no duplicate credential; the workflow node was already correct and needed no change). This also fixes the sibling workflow `zwTkywEYKsmojs6g` that shares the credential.

### Live verification — workflow `aLdzdQoG4qJCvfkt`, execution `30726` (one run, no auto-retry)
- **Authentication — VERIFIED SUCCESS:** valid access token issued; all three calls returned `code 200, result true`.
- **Variant inventory / US availability — VERIFIED:** VID `2610010255571607000` → **6246 units**, **all in China Warehouse (CN)** (`factoryInventoryNum 6246`, `cjInventoryNum 0`); **no US-warehouse entry** returned. The stock call succeeded and returned only a CN warehouse — genuine source data, not an API error → the variant is **not US-warehoused; it ships from China**.
- **US shipping / delivery — VERIFIED** (informational; **not** a launch blocker): CN→US, qty 1 → **20 logistics options, all priced in USD** (CNY equivalents given). Cheapest **CJPacket SP Sensitive $6.11 (7–13d)**; fast economy **YunExpress Sensitive $7.37 (4–7d)** / **CJPacket Sensitive $6.88 (4–9d)**; **USPS $9.28 (4–9d)**; **CJPacket Fast US $10.21 (7–12d)**; premium **DHL Official $30.92 (3–7d)**; taxes/clearance ≈ $0.
- **Currency — VERIFIED USD:** `logisticPrice` USD vs `logisticPriceCn` CNY (~6.19×); `sellPrice` 6.08–10.76 consistent with stored USD evidence.
- **Official product URL — NOT RETURNED:** `product/query` exposes no `productUrl`/`productLink`/`url` field (a CJ API characteristic, not a failure). The `fn_record_supplier_product_url` founder-verified-URL path (mig_351) remains available if a storefront URL is needed.

### Exact identity — still CANDIDATE_REQUIRES_VERIFICATION (fail-closed preserved)
The apiKey-mode detail response now carries a **per-variant `barcode`** (selected variant `1600016885203`, EAN-13 checksum valid). These are **CJ-assigned internal barcodes**, not manufacturer GTINs: they are **sequential across all 15 variants** (`…203`→`…217`), share one `createTime`, and use a **non-GS1-allocated prefix (`160`)**. `supplierId`/`supplierName` are null; `entryCode 8513109000` is only the HS customs code ("Plastic projection lamp"); no brand/model/MPN. The independently-discovered US projector `9128d818` carries no matching barcode/GTIN, so **no `SHARED_GTIN` / `AUTHORITATIVE_SUPPLIER_REF` bridge exists**. `9128d818 ↔ CJ 2610010255571606100` stays **CANDIDATE_REQUIRES_VERIFICATION**; it is **not** marked an authoritative match (no documentary cross-reference). The barcode strengthens only CJ-side variant designation (CJ-native namespace), never the cross-provider bridge.

### Integrity / tracker / cost
Workflow ran clean — **no demonstrated defect to fix**. No DB record changes (the CJ-internal barcode is deliberately **not** written into identity fields, to avoid it being mistaken for a GTIN). Country isolation, supplier-data rights, image-rights (RIGHTS_UNVERIFIED) and the fail-closed publication gates are unchanged. Quota: **~30 CJ API points** used today (free daily pool 50,000; remaining ~50,000); **$0**; **no orders**. LIVE MASTER — GOLD CX.02 updated; Build Evidence rows **272** (blocked run) and **273** (verified run) added; **11/22 GOLD acceptance preserved**; CX.02 **not** marked complete.

**Remaining CX.02 launch blocker:** an **authoritative US↔CJ same-product identifier** — a shared GTIN present on both the US discovery and the CJ variant, a manufacturer/model, or a documented CJ same-product confirmation. US freight, landed cost and profitability are explicitly **out of launch-blocking scope** (customers assess them independently; GPD.17 not reopened).

## Addendum 54 — CX.02 identity-bridge resolution: CJ URL avenue, full US-discovery identifier sweep, two-state integrity ($0, 0 provider calls, 0 DB writes, no code change)

**Date:** 2026-11-24. Post-authentication resolution pass over **existing** evidence to close the remaining CX.02 sourcing blockers without new spend. No GOLD acceptance flipped (11/22 preserved); CX.02 not marked complete; GPD.16/17/19 OPEN (GPD.17 not a launch blocker).

- **§1 Official CJ product URL — no automatic authorised path exists.** CJ API 2.0 documentation exposes no product-page / share-link field or endpoint (product, shop, shopping sections checked); the live `product/query` payload (exec 30726) carries no url/link field; all `commerce_supplier_products.product_url` are NULL. Third-party scrapers only **construct** `cjdropshipping.com/product/<slug>` patterns — unverified, and manufacturing a URL pattern is prohibited. The only authorised path remains **`fn_record_supplier_product_url`** (mig_351) with a founder-copied CJ-portal URL. (Sources: CJ API 2.0 product/shop/shopping docs.)
- **§2 Authoritative identity — full sweep of existing discoveries.** Of **36 US candidates** in `commerce_products` (25 `dataforseo_merchant` + 10 `kalodata` + 1 `cjdropshipping`), **zero** carry any authoritative identifier — 0 GTIN/UPC/EAN, 0 MPN/model, 0 brand. `provider_product_native` is present on all 35 merchant/Kalodata rows but contains **no** `brand`/`gtin`/`mpn`/`product_id` key → **nothing unmapped to recover; no ingestion defect**. The star projector **`9128d818`** (US, `dataforseo_merchant`, seller Amazon.ie) has native identity `google_product_id = 16421576920176765467` — a **platform-scoped Google Shopping id, not a manufacturer GTIN**, which cannot match CJ. CJ side `2610010255571606100` exposes only **CJ-internal sequential barcodes** (supplier-local, non-GS1; treated as supplier-local, not independently validated), `supplierId` null. → No shared authoritative identifier on either side; `9128d818` stays **CANDIDATE_REQUIRES_VERIFICATION**.
- **§3 Alternative US product — none is clearer.** Every US candidate has 0 authoritative identifiers; every `commerce_concrete_supplier_resolution` row is `NO_VALID_CJ_MATCH` / `bound=false` (0 bound anywhere). The star projector is representative, not uniquely deficient — it is **retained as a research candidate**; no better US substitute exists in current evidence.
- **§4 Two states preserved and distinct (not conflated).**
  - **State A — supplier-origin with verified CJ info:** `534d98bc` (US; `source_store=cjdropshipping`; `product_identity=candidate:pid:cjdropshipping:2610010255571606100`) now carries live-verified CJ info (stock 6246 CN-warehouse, US freight all-USD, exec 30726). Its `commerce_cross_supplier_identity` row is **UNVERIFIED / bound=false / confidence NONE** — correctly **not** labeled as an independent-discovery match.
  - **State B — independently-discovered product with an authoritative verified CJ match: does not exist.** The only product-level `bound=true` identity row is `56a6af36` (**FastMoss — a retired source**, **GB**, `SAME_PRODUCT_IDENTITY`/MEDIUM, `variant_verified=false`, `missing: no_shared_product_identifier`) — a product-level combined-evidence claim, not US and not identifier-based. It is distinct from State A and is not presented as an exact verified match.
  - No mislabeling defect found; the decision/publication gates (bound concrete resolution + `variant_verified`, both false everywhere) keep every candidate below "confirmed supplier."
- **§5/§6 Integrity.** No code or DB change (no defect to fix; no identifier to map; URL genuinely absent from the API). Architecture, publication restrictions, image/copyright protections, tenant isolation and country-specific intelligence preserved. US landed-cost/profitability remain informational, not launch blockers (GPD.17 not reopened). Tracker: Build Evidence row **274**; LIVE MASTER — GOLD CX.02 annotated.

**Answer to "do we have ≥1 independently-discovered US product with a verified working CJ sourcing link and defensible exact identity?" — NO.** Precise remaining **external** evidence (neither item synthesizable internally without weakening identity): **(a)** an authoritative shared product identifier bridging a US discovery to a CJ product (a GTIN/UPC/EAN on both sides, a manufacturer/model/MPN, or a documented CJ same-product confirmation); **(b)** a founder-verified working CJ product-page URL (portal copy → `fn_record_supplier_product_url`), since CJ's API exposes none.

## Addendum 55 — CX.02 external-evidence resolution: country correction, US generic anchor reselection, CJ enquiry prepared ($0, 0 provider calls, 0 DB writes, no code change)

**Date:** 2026-11-24. Acting on the two unresolved blockers (A: verified CJ link; B: authoritative exact match) using existing evidence and the authorised support channel. No GOLD acceptance flipped (11/22 preserved); CX.02 **not** accepted (no end-to-end verification); GPD.16/17/19 OPEN.

- **Track B — country correction (no fabrication).** The product long referenced as "the US star projector," `9128d818`, is stored in `commerce_products` as **market `IE`**, seller **Amazon.ie**, `merchant_source=google_shopping` — internally consistent, so the **database is correct: it is an Irish discovery, not US.** The "US" label existed only in prior narrative/tracker prose; there is no DB defect to correct, and **no US evidence was fabricated** to keep it. It is retained as a non-US research candidate and is **not** used as the US anchor.
- **Track B — US generic anchor reselection (existing discoveries only).** Of 36 US candidates, many are branded (Govee, Daybetter, Cowin, Monster, Morfone, Rossetta, Slagawa, POCOCO, Thames & Kosmos, Tradufa — excluded by the generic-only rule). The strongest genuine-US **generic** analog to the CJ interchangeable-film-disc projector is **`ca945686`** — "Star Projector Night Light 1-Pack 360 Sky Projector with **25 Slide Discs**… (6.3 × 5.12 × 1.57 in)", Walmart (US), US$14.99, Google product id `17536943141369248154`, brand screen **GENERIC_OK**. Other GENERIC_OK US analogs on file: `61a8f517`, `bf40764c`, `84af56b0`, `a37f20e0`, `0863986d`. The CJ-origin record `534d98bc` is **not** substituted for an independent discovery. Note: **no US candidate stored a listing URL** (DataForSEO's listing URL was not retained at ingestion; recovering it would need a new paid DataForSEO query — not performed).
- **Track A — supplier link.** No automatic authorised path exists (API exposes no URL — re-confirmed exec 30726; constructing a `/<slug>` pattern is prohibited). Prepared a targeted CJ support request — `docs/CX02-CJ-SUPPLIER-LINK-AND-IDENTITY-ENQUIRY.md` — asking for (1) the official product-page URL, (2) a variant URL if any, (3) whether the API-listed item is **website-visible/sourceable**, and (4) a **documented same-product + same-variant confirmation** of PID `2610010255571606100` / variant `CJJT321332301AZ` against the US listing `ca945686` (with the request stating that generic similarity is insufficient). The Gmail connector was unauthenticated this session, so no draft was created and the existing CJ thread could not be read; the founder sends via the existing authorised CJ thread or `support@cjdropshipping.com`.
- **Integration (deferred, correctly).** The identity resolver was **not** run and **no** Source-Product URL was recorded — both are gated on documented CJ evidence, which has not arrived. On a URL reply: verify the link resolves, then record via `fn_record_supplier_product_url`. On a same-product reply: record the `AUTHORITATIVE_SUPPLIER_REF`, run the resolver, then verify the frontend Source Product opens the correct supplier page. Architecture, publication controls, media rights and tenant/country isolation preserved; economics informational (GPD.17 not reopened).

**Status:** **AWAITING FOUNDER APPROVAL TO SEND** the CJ enquiry → then **AWAITING SUPPLIER CONFIRMATION**. We still do **not** have an independently-discovered US product with a verified working CJ link and defensible exact identity; the two external items above remain the only blockers, and neither is a completed fix.

## Addendum 56 — CX.02 P0 fix-to-completion: URL-resolution mechanism + documented-match recorder built, tested, wired ($0, 0 provider calls, 0 orders, 0 DB data writes)

**Date:** 2026-11-24. Both owned-scope mechanisms the directive asked for are built, tested and integrated as the smallest safe additions (no rebuild; no existing function, table, or row changed). The two remaining blockers are confirmed-external and escalated. No GOLD acceptance flipped (11/22 preserved); **CX.02 remains OPEN**; GPD.16/17/19 OPEN.

- **§1 Reusable CJ URL-resolution mechanism — `fn_resolve_cj_product_url` (mig_353).** Given a CJ source + PID it reads the stored founder-verified `product_url` (the persisted column **is** the cache), revalidates its shape (https + cjdropshipping.com + product-level, the same rules as `fn_record_supplier_product_url`) and returns `RESOLVED` (url + provenance + `cached_at`), `UNRESOLVED` (cache miss — no verified URL recorded), `INVALID`, or `SUPPLIER_NOT_FOUND`. It never invents or constructs a URL. Verified live: real PID `2610010255571606100` → `UNRESOLVED`; bogus id → `SUPPLIER_NOT_FOUND`. The authorised write path remains `fn_record_supplier_product_url` (a founder-copied portal URL).
- **§2 Documented same-product recorder — `fn_record_supplier_identity_confirmation` (mig_354).** Records a **documented** supplier same-product + exact-variant confirmation as an `AUTHORITATIVE_SUPPLIER_REF` in the researched product's `extended.supplier_refs`, and designates the confirmed variant, in exactly the shape the **unchanged** BE246 engine (`fn_cross_supplier_exact_variant_check`) consumes — so the resolver (not this recorder) decides exact status, fail-closed. Guards: service_role only; product + supplier row must exist; a non-empty documented confirmation reference is **required** (generic/title/image similarity rejected); the confirmed variant SKU must exist in the supplier's fresh probed `variant_catalog` (no bogus-variant designation); FastMoss excluded; never fabricates identity. Self-test `fn_record_supplier_identity_confirmation_selftest` (mig_355b) **8/8**, in a rolled-back sub-transaction: before any evidence → resolver fail-closed (`no_authoritative_product_identity`); after a documented confirmation → resolver `exact=true` with `product_identity_method=AUTHORITATIVE_SUPPLIER_REF` and variant `CJJT321332301AZ` / VID `2610010255571607000`; all guards; no residue.
- **§3 Frontend Source Product action — verified already wired and gated (no change).** In the Lovable workspace, `ecommerce-workspace.tsx` renders the supplier anchor `href={decision.productUrl}` only when `concreteProductActionsAllowed` (identity verified) **and** `decision.productUrl` is present; `workspace-sections.tsx` mirrors it; the storefront builder validates with `httpsUrl()`; there are tests for both the present and null states. So the moment a documented confirmation (→ `concreteProductActionsAllowed`) and a verified URL (→ `productUrl`) are recorded, the Source Product link renders and opens — editing it now would risk regressing a working, tested gate, so it was left unchanged.
- **Confirmed-external blocks.** From the container, `cjdropshipping.com`, `developers.cjdropshipping.com` and `app.cjdropshipping.com` all return `CONNECT tunnel failed, 403`, and no machine/browser is attached — the authenticated CJ website/portal is genuinely unreachable here. Identity: all 36 US candidates carry 0 authoritative identifiers; the star-projector discovery `9128d818` is `market=IE`/Amazon.ie (not US); the US generic anchor is `ca945686` (Walmart, GENERIC_OK).
- **Regression GREEN** (no existing object/data changed): exact_variant 11/11, cross_supplier_identity 13/13, record_url 7/7, ledger 6/6, link_readiness 4/4, cj_image_rights 8/8, generic_only 7/7, identity_confirmation 8/8. The only pre-existing `supplier_refs` row is the legacy GB reddit candidate `e453eed4` (no `match_method` → not treated as authoritative/exact; BE250-reconciled). Candidate-vs-verified states, publication gate, rights, tenant/country isolation all preserved.

**End-to-end status (Phase 3):** step 1 (independent discovery) ✓; the mechanism plumbing for steps 2–4 is proven with controlled, rolled-back evidence and the FE render path is ready and gated; but the **real** journey with a genuine product cannot be proven until two external inputs arrive — **(a)** a verified CJ product URL (founder portal copy → `fn_record_supplier_product_url` → `fn_resolve_cj_product_url` RESOLVED → FE link), and **(b)** a documented CJ same-product + exact-variant confirmation (→ `fn_record_supplier_identity_confirmation` → BE246 resolver EXACT → `concreteProductActionsAllowed`). Both are in `docs/CX02-CJ-SUPPLIER-LINK-AND-IDENTITY-ENQUIRY.md`, **awaiting founder approval to send**. CX.02 stays OPEN until that journey is proved with a genuine product.

## Addendum 57 — "Supplier Unknown": founder permanent requirement + 4-state supplier status ($0, 0 provider calls, 0 orders)

**Date:** 2026-11-24. **Founder permanent product requirement (recorded):** Strateloq is a product-discovery / market-intelligence platform; finding a verified supplier is an *additional capability, not a condition* for discovering, viewing, saving, comparing or monitoring an otherwise-eligible product. A verified supplier is required only to **claim a verified supplier relationship** and enable the **direct "View Supplier"** action. No GOLD acceptance flipped (11/22 preserved).

- **Discovery is already supplier-independent (verified, no fix needed).** `fn_discovery_product_hidden` is an explicit hidden-list check only; `fn_monday_top_opportunities` does **not** gate on `commerce_concrete_supplier_resolution` or `bound`. Supplier-less products already appear (the generic-only watchlist shows 50 items, nearly all without a verified supplier). No supplier-dependent exclusion exists to remove.
- **Backend 4-state source of truth — `fn_product_supplier_state(tenant, product, market)` (mig_356 → refined mig_359 → mig_360).** Reuses the **unchanged** BE246 resolver + `fn_resolve_cj_product_url`; reads existing evidence only; never searches, never manufactures a URL, never overclaims. States:
  - **VERIFIED_SUPPLIER** — authoritative exact-product (+ applicable variant) match **and** a working official supplier URL → `view_supplier_allowed=true`, `supplier_url` set ("View Supplier").
  - **POTENTIAL_SUPPLIER_NOT_VERIFIED** — a genuine candidate exists (explicit selected/authoritative candidate, or resolver `identity_result` EXACT_SUPPLIER_IDENTITY_RESOLVED / CONCRETE_PRODUCT_AMBIGUOUS / bound) but not fully verified. Never shown as a confirmed match; no verified action.
  - **SUPPLIER_UNKNOWN** — a completed supplier search (`concrete_state` CONCRETE_RESOLVED/AMBIGUOUS) returned no valid match → "We couldn't verify a supplier … through Strateloq's connected supplier sources." + "Source this product independently…". Rejected title look-alikes do **not** create a false "potential".
  - **SUPPLIER_NOT_YET_VERIFIED** — no supplier check performed, or the concept wasn't concrete enough to search (`NO_CONCRETE_EVIDENCE`), or integration pending. Never claims a supplier does not exist.
- **Tenant-scoped RPCs (mig_357):** `get_product_supplier_state(product, market)` and `get_products_supplier_state(ids[], market)` (auth.uid()-scoped) — the FE's authoritative source; no projection function edited (zero regression).
- **Tests.** `fn_product_supplier_state_selftest` **5/5** (rolled back): A VERIFIED (synthetic CJ supplier row with fresh variant_catalog + valid product URL → exact + url → `view_supplier_allowed` + `supplier_url`), B POTENTIAL, C SUPPLIER_UNKNOWN (verbatim founder message + recommendation), D NOT_YET_VERIFIED, no residue. Regression GREEN: exact_variant 11/11, cross_supplier_identity 13/13, record_url 7/7, ledger 6/6, link_readiness 4/4, cj_image_rights 8/8, generic_only 7/7, identity_confirmation 8/8.
- **Real-state evidence (stored-evidence resolution, $0, no CJ/n8n call).** Genuine **SUPPLIER_UNKNOWN** now displayed on real US discoveries — `207dbaa8` (generic "RGBIC Wall-Wash Floor Lamp"), `50e1b04e` (Shark vacuum), `44643cdb` (EcoFlow), `c351816b` (4Patriots) — each remaining fully research-accessible with "Source this product independently…"; **POTENTIAL** `e453eed4`; **SUPPLIER_NOT_YET_VERIFIED** `ca945686` (generic star projector). `view_supplier_allowed=false` on every real product (no genuine verified supplier exists anywhere).
- **Frontend.** A `SupplierStatusBadge` (4 states) consuming the new RPCs across product cards, the detail drawer, Saved Products, Monitoring, Country comparison and mobile; "View Supplier" strictly gated to `VERIFIED_SUPPLIER` + `supplier_url` (never a broken button); the badge is informational only and never hides/disables/filters a product. Implementation dispatched to the Lovable project `12db6c84`; build + diff verification recorded on completion.
- **CX.02 acceptance split (recorded, no checkbox flipped):** **(A) supplier-independent discovery + accurate supplier states = met** (backend + tests; FE in progress) — supplier-less products remain fully research-accessible with an honest supplier status. **(B) verified supplier linking** remains pending the external CJ product URL + documented same-product/variant confirmation (Addendum 55/56; unchanged). No orders, no CJ email sent, no manufactured URLs; tenant/country isolation, media rights, Product Asset Lock and founder-only store/advertising controls preserved. **CX.02 stays OPEN** (leg B unproven with a genuine product).

## Addendum 58 — Supplier-independent discovery final closeout: verification, tracker reconciliation, GOLD recount, BigBuy readiness ($0, 0 provider calls, 0 orders)

**Date:** 2026-11-24. Closeout of the four-state supplier policy (engineering accepted by the founder). No rebuilds; no supplier emails; no paid provider calls; authorised data only.

- **FE completed + verified (Lovable `72de4a1` + correction `2cf07eb`).** `SupplierStatusBadge` (4 states) on discovery cards, detail drawer, Saved Products, Monitoring, Country comparison and mobile; `useSupplierStates`/`useProductSupplierState` hooks (country-scoped, error-tolerant); View Supplier strictly gated to `VERIFIED_SUPPLIER` + working https `supplier_url`. The over-reach that had gated the **competitor** public-listing link was reverted (`2cf07eb`) — that link is competitor research evidence, independent of supplier verification, and renders whenever `p.productUrl` exists. **1,066 FE tests pass**, typecheck/lint clean, build OK; **preview only, not published**.
- **Visual inspection limitation (honest).** The Lovable preview returns **HTTP 401** from this cloud session (authenticated workspace; no founder session, no attached machine/browser), so authenticated visual QA is the founder's step. The four states are verified authoritatively at the backend (real products return each state) and by the FE suite (incl. the View Supplier gating test). The synthetic **Verified Supplier** case exists only as a rolled-back selftest fixture — never persisted, never exposed to customers (0 real `VERIFIED_SUPPLIER` products).
- **Accessibility + separation of concerns (verified).** Supplier Unknown / Not-Yet / Potential products stay fully viewable/saveable/comparable/monitorable (the badge is informational; hooks default-safe; discovery is supplier-independent). **Supplier confidence is separate from market-opportunity confidence** — `fn_product_supplier_state` is read-only/additive and does not feed the opportunity score (lifecycle/score come from `fn_stage1_early_opportunity_state` evidence families; `supplier_resolution` is a separate block). Profitability remains **UNKNOWN** (CX.03 out of launch scope). Missing supplier evidence never reduces or suppresses an opportunity.
- **No other qualifying product (item 6).** Across existing authorised evidence there is **no** product with an exact US↔CJ identity match **and** an official supplier URL: **0 of 1,317** `commerce_supplier_products` carry a `product_url`, **0** bound concrete resolutions, **0** `variant_verified`. No product is `VERIFIED_SUPPLIER` today. No further projector investigation; no emails; no paid calls.
- **Authorised CJ data only.** CJ image permissions are **not** a launch prerequisite — customers source product images directly from suppliers; the image-rights classifier + customer-display gate remain (rights-safe placeholders). CX.09 reconciled accordingly.
- **BigBuy readiness (no purchase / no unverified integration).** Registration is underway. The future path reuses the existing supplier architecture: a `catalogue_source_rights` row for BigBuy once authorised; `commerce_supplier_products` with `source='bigbuy'`; a BigBuy URL validator analogous to `fn_resolve_cj_product_url`; `fn_product_supplier_state` is already source-agnostic. **No package purchased, no API implemented.** AliExpress remains on hold.
- **Tracker reconciliation (formulas + historical milestones preserved).** CX.02 status now distinguishes the three levels — **engineering = COMPLETE**, **production acceptance = PENDING founder publish**, **genuine verified-supplier-link acceptance = BLOCKED/EXTERNAL**. CX.09 marked descoped-as-launch-prerequisite. Only CX text cells were edited; no GPD boolean/formula cell touched.
- **Authoritative GOLD acceptance recomputed directly from `C2:C23` = 11 / 22** TRUE (GPD.02, 03, 04, 05, 12, 13, 14, 15, 18, 20, 21). Unchanged. GOLD gates are distinct from accepted launch units. No gate flipped.

**Closeout status:** supplier-independent discovery + four-state supplier status is **engineering-complete and verified**; production acceptance is the founder's visual QA + publish of the Lovable preview. CX.02 leg B (a genuine verified supplier link) stays open pending the external CJ URL + documented same-product confirmation.

## Addendum 59 — Production evidence reconciliation: Explorer "Sales & Revenue" (207dbaa8) is real + display-authorised; earlier live-QA "no figure" note corrected ($0, 0 provider calls, 0 DB writes, no code change)

**Date:** 2026-11-24. The one discrepancy from the live-production QA is reconciled. The founder's authenticated screenshot (strateloq.com) for US product `207dbaa8` (RGBIC Wall-Wash Floor Lamp) shows **"Sales & Revenue: 191.24k USD · 6,374 units, Estimated (provider-reported), Reporting period: last 7 days, Source: KALODATA, As of 20 November 2026, Market: US"**, whereas the prior QA note claimed no sales/revenue figure is displayed. The screenshot is correct; the QA note was a false negative. No GOLD acceptance flipped (11/22 preserved); no code or DB change; the Supplier Unknown feature is untouched.

- **Root cause of the false negative — wrong function traced.** The earlier QA inspected `fn_product_discovery_lanes`, which is **not** the Sales & Revenue source: it is the **retired FastMoss momentum lane** (returns empty lanes / null momentum for every product since the 2026-11-20 FastMoss retirement), and the inspection additionally ran as the **service role** (`auth.uid()` NULL → the function's fail-closed `status 'unauthorized' / authority REFERENCE_ONLY / empty`). Both effects are genuine, but neither has anything to do with the displayed figure.
- **Actual data path (traced end-to-end).** `commerce_signals` (`signal_type='COMMERCE_PRODUCT_NATIVE'`, `source='kalodata'`, `market='US'`) → **`fn_product_explorer`** (aggregates `max(revenue)` / `max(sales_units)`, derives `metrics_basis` + `freshness`) → `product-explorer-contract.decodeExplorerItem` → **`ExplorerEvidenceSection`** (`src/components/business-discovery/explorer-evidence-section.tsx`). This is the authenticated, tenant-scoped Product Explorer — not the discovery-lanes panel.
- **Exact origin of the numbers (queried direct, bypassing the auth gate).** The single stored Kalodata signal row for `207dbaa8`: `revenue = 191239.26` (→ `compactNumber` "191.24k"), `sales_units = 6374` (→ "6,374 units"), `observed_at = 2026-11-20 11:13:13Z` (→ "as of 20 Nov 2026"); `currency = USD` from `commerce_products.price_currency='USD'`. Exactly **one** signal row (`market=US`, `source=kalodata`, `fastmoss_strategy=null`) → no market/source ambiguity; `revenue_growth_rate = 64.62`.
- **Provenance labels confirmed.** For a KALODATA (non-FastMoss) source, `fn_product_explorer` emits `metrics_basis = {revenue_estimated: true, provenance: PROVIDER_REPORTED, reporting_window: LAST_7_DAYS}` and `freshness.is_stale = false` (age 4.2 d < 14-day / 336 h window). The deployed FE renders these as **"estimated (provider-reported)"** and **"reporting period: last 7 days"**, with meta **"KALODATA · as of 20 Nov 2026 · US"** — matching the screenshot field-for-field. A controlled reproduction of the Explorer's projection for this product returned the item contract `{revenue 191239.26, sales_units 6374, currency USD, source KALODATA, metrics_basis{estimated, PROVIDER_REPORTED, LAST_7_DAYS}, freshness{as_of 2026-11-20, is_stale false}, market US}`.
- **Display rights.** `catalogue_source_rights` for KALODATA: `display_cleared = true`, `analyse_cleared = true`, `commercial_redistribution_cleared = false`. The figure is **display-authorised** — Kalodata display was resolved at BE233 and is **independent of the GPD.01 blocker**, which concerns DataForSEO / Google-Shopping upstream display for `dataforseo_merchant` rows only. The Explorer displays (it does not redistribute), so this is within the cleared scope.
- **Honesty of the contract preserved.** The component's honest-UNKNOWN branch is intact (`item.revenue === null → "Revenue: unknown"`); `207dbaa8` simply *has* authorised data. The evidence contract is **display-only** (never feeds any gate or opportunity score) and is **test-locked** (`explorer-evidence.test.ts` asserts `decodeExplorerEvidence` for the metrics-basis/provenance/window + the unknown paths).
- **Correction recorded.** The prior live-QA Build Evidence note (row 282, item 2 — "fn_product_discovery_lanes … empty … therefore NO sales/revenue figure displayed") is **corrected to a false negative** for `207dbaa8`. GPD.05 ("Licensed sales/GMV evidence OR explicit UNKNOWN") behaviour is upheld: a genuine figure is shown **with** estimate/provider/window labels; nothing fabricated; UNKNOWN remains the honest fallback where data is absent.
- **Regression / cost.** No code change, no DB change, no rebuild → the standing suites are unaffected (FE 1,066 tests green at `2cf07eb`; backend selftests incl. `fn_product_supplier_state_selftest` 5/5 unchanged). The data contract was proven directly by SQL reproduction of `fn_product_explorer`'s projection and by reading the deployed FE source. **$0; 0 provider calls; 0 orders.** Build Evidence row **283**; LIVE MASTER — GOLD CX.02 evidence annotated.

**Final verified customer-facing behaviour:** for `207dbaa8` (US), the authenticated Explorer shows **"191.24k USD · 6,374 units"** labelled **"estimated (provider-reported) · reporting period: last 7 days"**, sourced **KALODATA**, **as of 20 Nov 2026**, market **US** — a real, Kalodata-sourced, display-authorised, correctly-labelled estimate. The display is honest and requires no change; the earlier QA conclusion is corrected.

## Addendum 60 — GPD.01: rights-safe aggregate competitor display completed across ALL customer surfaces; GB pilot release-ready (gate kept closed) ($0, 0 provider calls, 0 orders, 0 rights/release flips)

**Date:** 2026-11-24. Objective: resolve the remaining GPD.01 *engineering* dependency so authorised, genuinely-observed competitor evidence can become customer-visible as a **rights-safe aggregate** (seller COUNT + price RANGE + exact-match flag), never the verbatim compiled marketplace-seller list — the one upstream-uncertain field. No GOLD acceptance flipped (11/22 preserved); no rights clearance flipped; the 5-product GB `customer_source_release` gate stays **closed**; `display_cleared`/`display_derived_cleared` untouched.

- **State inherited (verified live).** BE241/BE242 (mig_311) already aggregated the two **frontend** competitor RPCs: `fn_product_competitor_evidence` (auth.uid-scoped, `analyse_cleared`-gated, `competitors:[]`, `verbatim_seller_list_withheld:true`) and `fn_ecommerce_competitor_intelligence` (auth.uid; count-distinct only). `catalogue_source_rights`: DATAFORSEO/DATAFORSEO_MERCHANT `analyse_cleared=true`, `display_cleared=false`, `display_derived_cleared=false`; EBAY `analyse_cleared=false`; KALODATA fully cleared. Release rows: 5/5 `dataforseo_merchant` `released=false`.
- **Gap found (this pass).** A sweep of every function projecting seller identity/URL for *member* reachability (GRANT `authenticated`, SECURITY DEFINER) found two helper RPCs BE241 did **not** cover: **`fn_pmc_monday_block`** projected `'who_is_selling_it' = jsonb_agg(DISTINCT competitor_identity)` — the **verbatim compiled Google-Shopping seller list** (demonstrated: GB pilot `1def97b0` → 5 verbatim seller identities), with no `auth.uid()`/rights/release gate; and **`fn_pmc_summary`** took `p_tenant` with no `auth.uid()` check (cross-tenant aggregate read), though its *return* is aggregate-only (it passes identity only *into* `fn_pmc_evaluate`, which never echoes it). Neither is referenced by the frontend (Lovable greps for `who_is_selling_it`/`pmc_monday_block`/`pmc_summary` all empty); `fn_pmc_monday_block` has **no internal DB caller**; `fn_pmc_summary` is called only by internal service-role evaluators (`fn_pod_evaluate`, the w004 selftest). All 18 identity-bearing `product_market_competitors` rows are `GOOGLE_SHOPPING`/`DATAFORSEO_SELLERS` — exactly the restricted upstream source.
- **Smallest safe fix (`mig_361`), consistent with BE240 §4 / BE241.** `fn_pmc_monday_block` → tenant-isolated (a member may only query their own tenant; service-role/internal uses the param) and `'who_is_selling_it'` **replaced** by `'seller_presence'` = `{distinct_sellers` (only where every matched row carries an identity, else UNKNOWN)`, distinct_sellers_known, observed_offers, exact_match_present, verbatim_identities_withheld:true}`, gated to `analyse_cleared` sources only (eBay excluded). `fn_pmc_summary` → same `auth.uid()` tenant guard; projection unchanged (already aggregate-safe; internal scoring inputs unchanged). No rights/release/clearance flips. No frontend change, no rebuild.
- **Tests.** `fn_gpd01_aggregate_display_selftest` **5/5**: (T1) no `who_is_selling_it` key, `seller_presence` is an aggregate object with `verbatim_identities_withheld=true`; (T2) **no verbatim identity string** appears anywhere in the `fn_pmc_monday_block` output; (T3) none in `fn_pmc_summary` output; (T4) aggregate counts correct (offers=5, distinct_sellers=5 for the GB pilot); (T5) the FE surface still advertises `verbatim_seller_list_withheld` + `competitors:[]`. Post-fix sweep: **0** member-reachable functions project verbatim identity/URL. Regression GREEN: `fn_product_competitor_evidence_selftest` **6/6** (GB 5 offers / 5 sellers / £33.99–£39.99; 162 eBay offers excluded as uncleared; `cross_tenant_rejected`), `fn_stage3b_commercial_verification_selftest` **16/16**, `fn_w004_opportunity_scenarios_selftest` **11/11** (exercises `fn_pmc_summary` — unbroken).
- **Release-readiness snapshot (read-only; NO flip).** If the founder flips the 5 release rows, the aggregate (rights-safe) presentation exposes: **Projecteur `1def97b0`** (GB) — 5 offers / 5 distinct sellers / £33.99–£39.99 / exact; **Govee `d985e5af`, Govee Exquisite `0f959bd8`, pococo `2a714fe9`, Cold Brew `7dc13291`** — 0 cleared offers → honest UNKNOWN (the Govee eBay comparable is excluded, `analyse_cleared=false`). No verbatim seller identities in any case. Flip is reversible (`released=false`), BE242-drilled.
- **Residual GPD.01 dependency (NON-ENGINEERING, unchanged) — the exact question for qualified Irish/EU counsel:** *Does displaying to authenticated paying SaaS customers a small set of factual Google-Shopping-sourced observations (product titles, observed country-local prices, and now only **aggregate** seller counts/ranges — verbatim per-seller identities withheld) acquired via DataForSEO, with no images and no links, amount to extraction/re-utilisation of a substantial part of Google's Shopping database under the UK/EU sui generis database right (Directive 96/9/EC Art. 7, incl. Art. 7(5) at SaaS scale), or breach any term binding Strateloq, given Strateloq has no direct Google relationship and DataForSEO §7.2 assigns upstream risk to Strateloq — and does the aggregate/anonymised presentation reduce that to acceptable?* On a positive decision the founder (not Claude) sets `DATAFORSEO_MERCHANT display_derived_cleared=TRUE` and flips the 5 `customer_source_release` rows.
- **Which of GPD.06–GPD.11 this unblocks.** The aggregate mechanism is now complete and leak-free for **GPD.08** (seller count), **GPD.10** (observed competitor offers + GB price range), **GPD.11** (country saturation) and **GPD.09** (advertiser counts) — all become *sightable on a released card* the moment the legal decision + founder release occur. **GPD.06/07** (search / social demand) are **not** unblocked by this work: the merchant pilots carry competition, not search-demand, and the genuine GB demand signals remain TENANT_PRIVATE; those gates still need customer-visible demand evidence.
- **Controls preserved.** Images blocked (0 assets, TEXT_FALLBACK); no links (`observed_product_url` NULL and never projected); tenant + country isolation enforced (auth.uid guards; country_code scoping; `cross_tenant_rejected`); rights revocation-aware by construction (`EXISTS(analyse_cleared)` evaluated live); Stripe untouched. `mig_361` adds functions only — no table/data change. **GOLD 11/22 (C2:C23) unchanged; CX.02 and the Supplier Unknown feature untouched.** Build Evidence row **284**; LIVE MASTER — GOLD GPD.01 next-action annotated.

## Addendum 61 — GPD.01 legal-readiness package + controlled GB-pilot release procedure (preparation only; no release, no clearance, no code change)

**Date:** 2026-11-24. The GPD.01 aggregate-display engineering is complete (BE284 / Addendum 60); this pass prepares the **non-engineering** closeout and does not reopen mig_361. Consolidated the existing terms, correspondence, Google-upstream analysis and database-right questions into one counsel package: **`docs/GPD01-LEGAL-REVIEW-PACKAGE.md`**. No rights clearance granted; no `customer_source_release` row flipped (5/5 `released=false`); `display_derived_cleared` unchanged (FALSE); GOLD 11/22 preserved.

- **Four distinctions (package Part 2).** (A) DataForSEO derived-SaaS-use permission = GRANTED (`analyse_cleared`); (B) Google upstream = the sole OPEN residual (non-contractual — no Google contract binds Strateloq; EU/UK sui generis database right); (C) verbatim seller identities = WITHHELD on every customer surface, vs aggregate seller count + price range + exact flag = DISPLAYED; (D) right to ANALYSE (`analyse_cleared`=TRUE) vs right to DISPLAY derived results (`display_derived_cleared`=FALSE) — separate flags, display not self-authorised.
- **Sources consolidated (Part 3).** DataForSEO ToS §7.1 (data must not compete with/adversely affect the search-engine provider) + §7.2 (indemnity; upstream risk on Strateloq), capture 2026-11-20; DataForSEO/CJ/Kalodata correspondence (recorded, not re-fetched); the no-Google-privity analysis; Directive 96/9/EC Art.7/7(5), *BHB v William Hill* (C-203/02), *Innoweb v Wegener* (C-202/12).
- **Precise counsel question (Part 6).** Whether displaying title + observed local prices + **aggregate** seller counts/ranges (verbatim identities withheld, no images, no links), acquired via DataForSEO with no direct Google relationship, is extraction/re-utilisation of a substantial part of Google's Shopping database (Art. 7 / Art. 7(5) at SaaS scale) or breaches any term/right binding Strateloq, given §7.1/§7.2 and resold-data — and whether aggregation reduces this to acceptable. **Not self-answered.**
- **Exact founder decision (Part 7).** After counsel: founder (not Claude) records `DATAFORSEO_MERCHANT.display_derived_cleared=TRUE`, flips the 5 `customer_source_release` rows TRUE (reversible), and runs post-release QA. Each step individually reversible.
- **Reversible pilot procedure (Part 8).** Pre-release checks (clearance recorded; rights register correct; selftests green; image/link safety; tenant/country isolation); release-gate verification; rollback conditions (any verbatim identity/image/link appears, counsel withdraws, a regression, or a DataForSEO §7.1 notice ⇒ set `released=false`); post-release customer QA.
- **Item 5 — products without cleared observations show UNKNOWN.** Verified on live data + selftest: 4 of 5 pilots have 0 analyse-cleared observations → `fn_product_competitor_evidence` returns `observation=UNKNOWN` (never 0); asserted by `FASTMOSS_PRODUCT_EMPTY_HONEST` + explorer `unknown_not_zero`. eBay-only evidence (Govee `d985e5af`) is excluded as uncleared → UNKNOWN, not a false "1 seller".
- **Item 6 — GPD.06–11 genuine-evidence readiness (independent of the aggregate price display).** On the releasable pilot set: **GPD.10** genuine (Projecteur GB 5 offers £33.99–£39.99); **GPD.08** partial (Projecteur 5 distinct sellers — single product); **GPD.11** weak/derivative (saturation rides the same seller evidence, MEDIUM confidence — not independently passed); **GPD.06 + GPD.07** NOT satisfiable (0 search/social demand on pilots; genuine GB demand signals are TENANT_PRIVATE, not these products); **GPD.09** NOT satisfiable (0 observable ads across all 5 pilots). Closing GPD.06/07/09 needs genuinely-observed demand/advertiser evidence on customer-visible products — a separate acquisition, out of GPD.01 scope.
- **Controls.** $0; 0 provider calls; 0 orders; no release; no rights flip; no engineering change; Build Evidence row **285**; LIVE MASTER — GOLD GPD.01 next-action annotated. GOLD **11/22** (C2:C23) unchanged; CX.02 and Supplier Unknown untouched.

## Addendum 62 — GPD.06 / GPD.07 / GPD.09: real demand & advertiser evidence — provider→rights mapping, live customer-path verification, no defect ($0, 0 provider calls, 0 orders, no code change)

**Date:** 2026-11-24. Established, for the three demand/advertiser gates, which licensed providers can legitimately supply each evidence family and whether genuine observations reach **customer-eligible** products — reusing stored observations only, without bypassing tenant isolation, source rights or the founder release gate, and without new provider spend. GPD.01 engineering not reopened. No GOLD checkbox flipped (11/22 preserved); Supplier Unknown, supplier-independent discovery, country isolation and Product Asset Lock unchanged.

- **Provider → evidence-family → rights map.** **SEARCH_DEMAND** (GPD.06/07) = DataForSEO (`source_platform` DATAFORSEO_GOOGLE_ADS / dataforseo_labs; honest `claim_safety`: search interest ESTIMATED, intent INFERRED, category-weighted ×0.35, NOT sales/orders/revenue) → DATAFORSEO `analyse_cleared=TRUE`, `display_derived_cleared=FALSE`. **ADVERTISING_ACTIVITY** (GPD.09) = Meta Ad Library (`provenance.source=META_AD_LIBRARY`, 440 rows / 11 products) → META_AD_LIBRARY `analyse_cleared=FALSE`. **COMMUNITY_ATTENTION** (GPD.07 social) = Reddit (`source=reddit`, 11 rows) → REDDIT `analyse_cleared=FALSE`. Kalodata `creator_count`/`video_count`/`advertiser_count` keys exist on all 23 DE + 10 US Kalodata products but are **all NULL** (the provider did not supply engagement counts) → no display-cleared social/advertiser signal.
- **Reuse-first coverage vs customer-eligibility.** The **10 US customer-visible Kalodata products carry 0 SEARCH_DEMAND / 0 ADVERTISING / 0 COMMUNITY**. The only products carrying search-demand (4 DE Kalodata) and advertiser (2 DE) observations have **no display image → not customer-visible**; they are not exposed, and tenant isolation + the release gate were not bypassed to surface them.
- **Live customer-path verification** (`fn_ecommerce_product_intelligence_core`, real tenant, product `207dbaa8`/US): COMMERCE_MOMENTUM = QUALIFYING (Kalodata, display-cleared; units 6374 / revenue 191239.26); ADVERTISING_EMERGENCE = **NOT_AUTHORISED** (META_AD_LIBRARY, advertiser count NULL); SEARCH_DEMAND = **UNKNOWN / NOT_SEARCHED** (DataForSEO, honest); COMMUNITY_SOCIAL = **NOT_AUTHORISED** (REDDIT); MARKETPLACE_VALIDATION = NOT_AUTHORISED (EBAY). All three gate families have `contributes_to_qualification=false`. `fn_product_ad_evidence` independently withholds Meta/TikTok advertiser counts (NOT_AUTHORISED, NULL; ADVERTISER-is-not-SELLER, longevity-is-not-PROFIT). The four distinctions are preserved: search ≠ sales, social interest ≠ commercial demand, advertiser ≠ profit, no observed data ≠ verified zero.
- **No defect.** Provider attribution is correct (`source_platform` / `provenance.source`), rights gating is correct, and the customer output is honest. No ingestion/mapping/frontend/evidence-provenance defect found → no code change made (per the "fix only an actual defect" rule).
- **Per-gate status & smallest lawful path (none executed; each needs founder approval and/or external rights).** **GPD.06 / GPD.07-search** — evidence exists but not on customer-visible products; path = a founder-approved bounded DataForSEO Google-Ads SEARCH_DEMAND query for the 10 US customer products (existing integration, DataForSEO credits) **plus** the GPD.01 DataForSEO display clarification. **GPD.07-social** — no authorised path today; needs a Reddit/TikTok analysis+display licence, or Kalodata re-ingestion including creator/video counts. **GPD.09** — no authorised path today; needs Meta Ad Library analysis+display rights (no DataForSEO/GPD.01 route supplies advertiser data). None is satisfiable on UNKNOWN/NOT_AUTHORISED states alone.
- **Controls.** $0; 0 provider calls; 0 orders; no code change; no rights/release flip. Build Evidence row **286**; LIVE MASTER — GOLD GPD.06/07/09 next-actions refined (checkboxes untouched). GOLD **11/22** (C2:C23) unchanged.

**Recommended next unit:** none of GPD.06/07/09 can be closed without an external provider decision. The highest-leverage single step is a **founder-approved DataForSEO Google-Ads SEARCH_DEMAND acquisition for the 10 US customer-visible products** paired with the GPD.01 DataForSEO display clarification — that one decision can make GPD.06 (and the search leg of GPD.07) genuinely sightable; GPD.09 and the social leg of GPD.07 need separate provider rights (Meta / Reddit·TikTok) and should not block the others.

## Addendum 63 — GPD.06 US search-demand pilot: founder-approved DataForSEO call executed, ingested, display-gated (DISPLAY_PENDING_RIGHTS) — $0.09, 1 task

**Date:** 2026-11-24. Phases 1–4 of the GPD.06 search-demand directive. No GOLD acceptance flipped (11/22 preserved); GPD.06/07/09 remain OPEN; Supplier Unknown, Product Asset Lock, country isolation and accepted gates untouched.

- **Preflight (Phase 1, $0).** 10 customer-visible US Kalodata products; 0 existing SEARCH_DEMAND, 0 prior research runs; 9 GENERIC_OK + 1 BRANDED_OR_IP (Apple MacBook `0087e6b6`, excluded). Integration = DataForSEO Google Ads search volume; US config OK (location 2840 / en / USD). Cost projection `SEARCH_VOLUME` = $0.06/task Standard; fail-closed budgets (`research_budget_config` disabled + `provider_call_budget` inactive).
- **Authorisation (Phase 2).** Founder approved the **2-product pilot (~$0.06)**: `207dbaa8` RGBIC Wall-Wash Floor Lamp (generic → category) + `50e1b04e` Shark PowerPro Cordless Vacuum (distinctive → product-specific).
- **Execution (Phase 3).** ONE DataForSEO `keywords_data/google_ads/search_volume/live` call via n8n (bounded workflow `l2OJYTbsMvxaZHZ5`, cred *Pulse DataForSEO*, 16 keywords, execution `30727` success; workflow archived after). **Actual cost $0.09**, not the quoted ~$0.06 — the `/live` priority endpoint (the one the existing P5 probe uses) is dearer than the Standard `task_post` projection. Disclosed; $0.03 over. Genuine US volumes (honest `claim_safety`: ESTIMATED, intent INFERRED, NOT sales): lamp product-specific weak/null (rgbic floor lamp 170/mo) but category strong (led floor lamp 6,600; corner floor lamp 2,900); vacuum product-specific strong (shark cordless vacuum 40,500/mo) + category huge (cordless vacuum 90,500).
- **Ingest.** `fn_ingest_search_demand_for_product` preserves product-specific vs category: `50e1b04e` → `demand_basis=PRODUCT_NO_VOLUME`, product_relevant_volume 0, category_relevant_volume 81,000, buyer_intent LOW/34, persisted (GLOBAL_SAFE, honest provenance `GOOGLE_ADS_via_DATAFORSEO`). `207dbaa8` → `no_relevant_query` (honest null, not ingested): the noisy generic title dilutes token-overlap in `fn_classify_search_query_relevance`; a concise `normalized_name` would fix classification but that field is read by ~22 identity/supplier/ingestion functions (broad blast radius) → **not changed** (scoped follow-up).
- **Display gate (Phase 4, `mig_362`).** `fn_ecommerce_product_intelligence_core` now marks a family whose source is analyse-cleared but **not** display_derived_cleared (DATAFORSEO / DATAFORSEO_MERCHANT) as **DISPLAY_PENDING_RIGHTS** — retained and used for internal analysis, **withheld from customer display** — until the GPD.01 DataForSEO display clarification. Distinct from NOT_AUTHORISED (Meta/Reddit/eBay, not even analyse-cleared). Kalodata (`COMMERCE_MOMENTUM`) and CJ are unaffected (display_derived_cleared=TRUE). Verified live (`50e1b04e`/US): SEARCH_DEMAND=DISPLAY_PENDING_RIGHTS (withheld), COMMERCE_MOMENTUM QUALIFYING (Kalodata, shown), Meta/Reddit/eBay NOT_AUTHORISED, `display_pending_sources=[DATAFORSEO,DATAFORSEO_MERCHANT]`, lifecycle unchanged (RESEARCH_PRIORITY). When the founder sets DATAFORSEO `display_derived_cleared=TRUE` the gate lifts with no code change.
- **Honest seams / governance.** (a) `fn_ingest_search_demand_for_product` writes to the **global** intelligence tenant (GLOBAL_SAFE) while stage1 reads the **product-owner** tenant (`7c8ddf9d`), so the acquired, product-attributed search-demand does not yet surface in the product's stage1 families (`present=false`); display is blocked regardless, so there is no customer-facing effect — connecting the GLOBAL_SAFE read (or writing to the product-owner tenant) is a follow-up for when display clears. (b) The n8n executor calls DataForSEO directly and is **not** gated by the DB `research_budget_config`/`provider_call_budget` (which govern the SQL/edge path); the DB master switch was not flipped.
- **Status / next.** GPD.06 remains OPEN: customer display legally blocked (GPD.01 DataForSEO clarification) + the per-product read-connection follow-up. Evidence for the 2 pilot products is acquired (no further paid calls needed for them); scaling to the other 7 eligible US products = one more `/live` task (~$0.09) on founder approval. Build Evidence row **288**; LIVE MASTER — GOLD GPD.06 next-action annotated. GOLD **11/22** (C2:C23) unchanged.

## Addendum 64 — GPD.06 P0 integration fix: both pilot defects fixed (evidence ownership/retrieval + DataForSEO spend bypass) — no new paid calls, $0

**Date:** 2026-11-24. Fix-to-completion for the two defects found after the BE288 pilot. No GOLD acceptance flipped (11/22 preserved); GPD.06/07/09 remain OPEN; Supplier Unknown, Product Asset Lock, country isolation and accepted gates unaffected. No new DataForSEO call; $0.

### Task 1 — product evidence ownership & retrieval (`mig_363`, `mig_363b`)
- **Intended model confirmed:** provider-acquired market intelligence (SEARCH_DEMAND, ADVERTISING_ACTIVITY, MARKETPLACE_ACTIVITY) is stored GLOBAL_SAFE on the global-intelligence tenant (shared); tenant-private is only the tenant's own COMMERCE/COMMUNITY. The ingest wrote **correctly**; the **read** was the defect — `fn_stage1_supplier_resolution_qualified` derived SEARCH_DEMAND only from the tenant-scoped `product_market_evaluations`, while ADVERTISING already read `commerce_signals` directly by product+market.
- **Read fix (`mig_363`):** SEARCH_DEMAND (buyer search intent) now also resolves the latest SEARCH_DEMAND signal for (product_id, market) restricted to `visibility='GLOBAL_SAFE' OR user_id=p_tenant` — the smallest secure correction (no cross-tenant private leakage; mirrors ADVERTISING). Verified: the acquired pilot evidence now surfaces for the product (`present=true`) while customer display stays `DISPLAY_PENDING_RIGHTS` (mig_362).
- **Noisy-title fix (`mig_363b`):** `fn_ingest_search_demand_for_product` cleans the *classification* name only (strip a leading quantity token; truncate at the first clause separator) — local to search-demand ingestion; **does not touch `normalized_name`** (read by ~22 identity/supplier/ingestion functions). Reconciled the already-acquired volumes (no new paid call; dedup `ON CONFLICT` update in place; market US preserved): lamp `207dbaa8` → `demand_basis=PRODUCT` + category **11,110/mo** (was `no_relevant_query`); Shark `50e1b04e` → `demand_basis=PRODUCT`, product-specific **81,000/mo** (a genuinely-demonstrated upgrade from PRODUCT_NO_VOLUME, allowed by the directive). Exactly one SEARCH_DEMAND signal per product (no duplication).
- **Generic-only (1.8):** registered the real US-cohort brands the registry missed — `shark` (SharkNinja), `ecoflow`, `insignia` (Best Buy), `4patriots` — in `commerce_product_brand_registry`. The Shark vacuum now screens **BRANDED_OR_IP**, so the stage1 branded disqualifier fires (`stage1_supplier_resolution_qualified=false`, stays RESEARCH_PRIORITY) and it is excluded from generic-only recommendations; the research record is preserved (still viewable, evidence retained).

### Task 2 — close the n8n DataForSEO spending bypass + cost reconcile (`mig_364`)
- **Root cause:** the n8n executor calls DataForSEO directly (basic auth) and bypassed the DB authoriser `fn_dataforseo_pilot_consume`.
- **Endpoint-specific cost (2.4):** added `SEARCH_VOLUME_LIVE = 90000` ($0.09, the `/live` priority endpoint the pilot used) distinct from `SEARCH_VOLUME = 60000` ($0.06 Standard `task_post`), so projections match the endpoint actually selected.
- **Authoriser selftest (2.2/2.6/2.7):** `fn_dataforseo_spend_control_selftest` **7/7** in a rolled-back sub-transaction with non-chargeable mocks (the authoriser makes NO provider HTTP): permitted; exhausted → `CALL_BUDGET_BLOCKED`; wrong market → `MARKET_NOT_AUTHORIZED`; over per-run cap → `OVER_PER_RUN_CAP`; disabled → `PAID_DISABLED`; emergency stop → `EMERGENCY_STOP`; duplicate idempotency key → idempotent replay (no double consume). No residue (config/budget/emergency-stop restored).
- **Audit of the $0.09 (2.5):** recorded as a completed `dataforseo_merchant_dispatch` row (`gpd06-pilot-exec30727-audit`, status `INGESTED`, `actual_cost_micro=90000`, op `SEARCH_VOLUME_LIVE`) so month-spend reconciliation counts it; it is **not** a new approved/pending request. Month-spend for the global tenant now reflects $0.09.
- **Bypass removed (2.1/2.3):** archived all three direct-HTTP DataForSEO n8n workflows (pilot `l2OJYTbsMvxaZHZ5`, P5 probe `0HGniWXeacHbVTQL`, research executor `aVKNL2CFhyA8VUdm`) → no active direct-HTTP bypass workflow remains. Sanctioned pattern documented: **authorise via `fn_dataforseo_pilot_consume` (market + per-run cap + monthly cap + provider_call_budget + idempotency + emergency-stop) → execute → `fn_dataforseo_merchant_record_cost`**. Honest limitation: n8n workflows are user-editable, so the DB authoriser + archived workflows + credential discipline are the controls; full technical non-bypassability would require restricting the *Pulse DataForSEO* credential to a single budget-enforcing executor (recommended, not built here). Fail-closed confirmed: no active `DATAFORSEO_SEARCH_VOLUME` budget → chargeable call refused.

### Task 3 — rights & customer display
`mig_362` DISPLAY_PENDING_RIGHTS preserved; `DATAFORSEO.display_derived_cleared` still FALSE (not enabled). An authorised internal reader retrieves the ingested SEARCH_DEMAND under the correct tenant/product (`present=true`) while customer-visible fields are withheld (`DISPLAY_PENDING_RIGHTS`, strength null). Kalodata revenue (COMMERCE_MOMENTUM QUALIFYING), Supplier Unknown, country isolation (stage1 COUNTRY_ISOLATION 8/8), Product Asset Lock and accepted GOLD gates unaffected.

### Regression / cost
GREEN: `fn_stage1_product_opportunity_invariants_selftest` 8/8, `fn_generic_only_discovery_selftest` 7/7, `fn_product_competitor_evidence_selftest` 6/6, `fn_gpd01_aggregate_display_selftest` 5/5, `fn_dataforseo_spend_control_selftest` 7/7, `fn_w004_opportunity_scenarios_selftest` 11/11. **$0 new spend; 0 new paid calls; 0 orders.** Build Evidence row **289**; LIVE MASTER — GOLD GPD.06 next-action annotated. GOLD **11/22** (C2:C23) unchanged.

---

## Addendum 65 — COMPLETE DataForSEO Spending Security (BE290, 2026-11-24)

**Date:** 2026-11-24. Founder directive: *COMPLETE DATAFORSEO SPENDING SECURITY* — close the one outstanding gap from BE289: archived n8n workflows do not stop an authorised operator creating a **new** direct DataForSEO HTTP request with the existing credential. Build the strongest practical enforcement; reuse the existing DB authoriser + ledger; restrict the credential to the budget-enforcing pathway where feasible; if n8n cannot technically restrict the credential, document the limitation honestly and do not claim full non-bypassability. **No accepted features modified; no paid searches; $0 new spend; 0 provider calls; 0 orders.**

### Root cause (inspected, not assumed)
- The n8n credential **Pulse DataForSEO** (`OYKLUdhcUwGJ8ymT`, httpBasicAuth) sits in a **personal project** with full owner scopes (`credential:use/share/update/delete/manageInstance`). **n8n has no mechanism to bind a credential to a single workflow** — any workflow an operator creates can reference it. This is the structural bypass surface.
- DataForSEO was callable **only from n8n** with that credential: there were **0 `dataforseo-*` edge functions** — no server-side chokepoint. The DB authoriser (`fn_dataforseo_pilot_consume`) only enforces when the executor voluntarily calls it, which n8n did not.

### The enforced security boundary (what was built)
1. **Sole server-side chokepoint — Supabase edge function `dataforseo-execute`** (`supabase/functions/dataforseo-execute/index.ts`; deployed v1 ACTIVE, `verify_jwt=false`). It is **meant to HOLD the DataForSEO credential** (as edge secrets, not in n8n) and is the only sanctioned chargeable-DataForSEO path. Control flow — the provider `fetch()` is lexically unreachable unless all three gates pass:
   - **GATE 1 — executor token:** `x-executor-token` must equal the `DATAFORSEO_EXECUTOR_TOKEN` secret; **unset ⇒ every dispatch refused (401)** (fail-closed).
   - **GATE 2 — credential presence:** `DATAFORSEO_LOGIN`/`DATAFORSEO_PASSWORD` must be set; **unset ⇒ 503 BEFORE any budget consume** (a missing secret never burns a budget slot).
   - **GATE 3 — the existing authoriser:** `fn_dataforseo_pilot_consume` (idempotency-key claim + emergency-stop + dispatch-suppression + provider check + `research_budget_config` master switch / `authorized_market` / `per_run_cap` + combined monthly ceiling + **atomic** `provider_call_budget` consume). Not authorised ⇒ 4xx, **no provider call, nothing charged**.
   - After authorise: provider call → **`fn_dataforseo_merchant_record_cost` reconciles the ACTUAL cost** (reports `cost_variance_micro`). A network failure records `FAILED` (excluded from month-spend) with the budget slot still consumed (**fail-closed: a failed attempt can never grant extra spend**); an idempotent replay of a completed dispatch never re-calls the provider. **Reuses the existing authoriser + ledger — no competing budget system.**
   - **Read-only `probe`** branch (`{probe:true}`): returns the live gate decision via `fn_dataforseo_pilot_preauthorize` with **no auth, no secret, no spend, no provider call** — for health/monitoring and endpoint-specific projected-cost checks.
2. **`mig_365`** — `fn_dataforseo_pilot_preauthorize` (read-only, STABLE; pre-dispatch projected-cost + gate state, no side effects) and the spend-control selftest extended to **v2 = 10/10** incl. **T8 concurrency** (against a 1-call budget, two distinct-key consumes → exactly one winner, other `CALL_BUDGET_BLOCKED`, `consumed_calls` never exceeds `max_calls`; true parallelism serialised by `SELECT … FOR UPDATE` + `consumed_calls < max_calls` in `fn_provider_budget_try_consume`).
3. **Least-privilege:** `fn_dataforseo_pilot_consume`, `_merchant_record_cost`, `_pilot_preauthorize`, `_spend_control_selftest` are **service_role-only** (anon + authenticated EXECUTE revoked) — only the edge executor can reach the authoriser/ledger via RPC.
4. **n8n surface reduced:** credential `OYKLUdhcUwGJ8ymT` description set to **DECOMMISSIONED**; **5 paid-capable direct-HTTP DataForSEO workflows archived** (`QOdKRyMPZVUoNhCH` merchant, `Jzz0F6peesqda4gN` submit, `dyIhrOkFp2QmrmTD` discovery, `LhtUctoIOYL2y7TU` + `pXNen4BFhzvXfu1M` problem-fetch). The free read-only workflows (balance / catalogue preflight / `task_get` retrieval) are not a spend surface and remain; all become inert once the credential is deleted.

### Endpoint-specific cost (pre + post)
Projected cost is checked **before** dispatch (`fn_dataforseo_operation_projected_micro`: `SEARCH_VOLUME_LIVE`=90000µ **$0.09** `/live` priority; `SEARCH_VOLUME`=60000µ **$0.06** Standard `task_post`; `MERCHANT_PRODUCTS`=75000µ; `SELLERS`=10000µ) via preauthorize/consume, and the **actual** provider cost is reconciled **after** via `record_cost`. Failed calls/retries cannot silently exceed approval (idempotency dedup + failed-slot-consumed + month-spend excludes FAILED/REFUNDED).

### Verification ($0, 0 provider calls)
- Spend-control selftest **ok=true, 10/10** (approval / denied-default / exhausted / wrong-country / over-cap / disabled / emergency-stop / duplicate / **concurrency ×3**).
- `fn_dataforseo_pilot_preauthorize` live = **PAID_DISABLED** (`research_budget_config.enabled=false`, `authorized_market=SG`, **0 active `provider_call_budget`**, `emergency_stop=false`) — fully fail-closed default preserved.
- Grants confirmed **service_role-only** on all four functions.
- **No dispatch row created this session** — the only recent `dataforseo_merchant_dispatch` row is the prior BE289 audit row `gpd06-pilot-exec30727-audit` ($0.09). **$0 new spend.**
- Stored GPD.06 evidence **retained internally** (both pilots `SEARCH_DEMAND` GLOBAL_SAFE/US/`DATAFORSEO_GOOGLE_ADS`, `demand_basis=PRODUCT`) while **customer display stays `DISPLAY_PENDING_RIGHTS`** (`display_pending_sources=[DATAFORSEO,DATAFORSEO_MERCHANT]`; `mig_362` intact) — GPD.06 display still blocked pending GPD.01.
- Regression GREEN: `spend_control` 10/10, `merchant_budget_bypass`, `provider_budget_gate`, `research_budget` 14/14, `merchant_dispatch`, `stage1_invariants` (GOLD-gating), `generic_only`, `competitor_evidence`, `gpd01_aggregate`, `search_relevance`, `product_supplier_state` (Supplier Unknown), `w004` — all PASS.

### Honest limitations (as the directive requires — full non-bypassability NOT yet achieved)
- **n8n cannot technically restrict credential usage to one workflow.** While the credential **remains in n8n**, an authorised n8n operator can still call DataForSEO directly. Full non-bypassability requires **two founder actions outside the build session**: (1) set Supabase edge secrets `DATAFORSEO_LOGIN` + `DATAFORSEO_PASSWORD` (the existing API login/password) + `DATAFORSEO_EXECUTOR_TOKEN` (a new random token for n8n to send) on project `nxaunmyihhjixxxljcqt`; (2) **DELETE the n8n credential** `OYKLUdhcUwGJ8ymT`. After both, every chargeable DataForSEO run routes through `dataforseo-execute` only.
- **Unavoidable administrator-level bypass (documented, not engineered away):** Supabase **project-owners / service-role** can read the edge secrets or deploy a replacement edge function; the n8n **owner** retains access until the credential is deleted. These are inherent to root/admin access and cannot be removed within this stack.
- **Edge HTTP surface not curlable from the build container:** the agent egress proxy blocks `*.supabase.co` (403; not routed around). Enforcement is proven at the **DB authoriser the function delegates to** (selftest 10/10 + preauthorize fail-closed), the deployed function's **static control flow**, and the **service_role-only grants**. Live smoke from an allowed network / n8n: `POST {probe:true,operation:"SEARCH_VOLUME_LIVE",market:"US"}` → expect gate `PAID_DISABLED`.
- **Pre-existing, out-of-scope:** `fn_stage1_supplier_resolution_selftest` shows **20/21** (check `22_early_opportunity_v2` failing). This session changed **no** stage1 / early-opportunity code (mig_365 is an isolated read-only function + a test case + grants), so it is pre-existing and **not GOLD-gating** (the GOLD stage1 suite `fn_stage1_product_opportunity_invariants_selftest` is GREEN); flagged for a separate task, not fixed here per scope.

### Status
Spend security brought to the **strongest achievable boundary**: a single budget-enforcing server-side executor + decommissioned n8n credential + archived paid workflows, with the exact 2-step founder action to reach full technical non-bypassability and the inherent admin bypass stated plainly. **GPD.06/07/09 remain OPEN** (GPD.06 awaits the GPD.01 DataForSEO display clearance, no code change). **GOLD 11/22 preserved** (C2:C23; no checkbox flipped). Supplier Unknown, Kalodata revenue, country isolation and PAL unaffected. Build Evidence row **290**; LIVE MASTER — GOLD GPD.06 next-action annotated. Migration record `mig_365`; edge function `supabase/functions/dataforseo-execute/index.ts`.

---

## Addendum 66 — Stage-1 selftest check 22 fix (early_opportunity_v2) (BE291, 2026-11-24)

**Date:** 2026-11-24. Follow-up to the BE290 spend-security work, which flagged that `fn_stage1_supplier_resolution_selftest()` returned **20/21** with check `22_early_opportunity_v2` failing. Founder asked to diagnose and fix to 21/21.

### Diagnosis — stale fixture, not a function bug
`fn_stage1_early_opportunity_state` is **correct**. BE264 added **decision-boundary rights enforcement**: evidence families whose source is `analyse_cleared=false` (META_AD_LIBRARY, EBAY, REDDIT) are **excluded from the authorised top-level decision** (`early_opportunity_state`, qualifying/present counts), while the ungated investigation detail is retained in `supplier_resolution` for audit. That safety property is GOLD-relevant and locked by the GOLD-gating `fn_stage1_product_opportunity_invariants_selftest` (8/8).

The **selftest fixture** was stale: the two-family product `p_two` qualified via **COMMERCE_MOMENTUM + ADVERTISING_EMERGENCE**, and ADVERTISING_EMERGENCE maps to **META_AD_LIBRARY** (`analyse_cleared=false`). After BE264, the rights-gated top-level state saw only **one** authorised qualifying family (COMMERCE_MOMENTUM) → `EMERGING`, not `QUALIFIED_FOR_SUPPLIER_RESOLUTION`. Check 04 (the **ungated** `supplier_resolution` sub-object) still passed; only the **gated** check 22 failed. The suite isn't in the standard regression set, so it had gone unobserved (surfaced during BE290; unrelated to it).

### Fix — `mig_366` (fixture-only; no production function changed)
`p_two` now carries a **second authorised qualifying family** — a `SEARCH_DEMAND` signal (`source_platform=DATAFORSEO_GOOGLE_ADS`; DATAFORSEO `analyse_cleared=true`; `buyer_intent_band=HIGH`). With **COMMERCE_MOMENTUM + SEARCH_DEMAND** both authorised and qualifying, the rights-gated top-level state genuinely reaches `QUALIFIED_FOR_SUPPLIER_RESOLUTION`, while `p_two`'s META advertising stays **present but excluded** at the decision boundary. Check 22 is now a **stronger, rights-aware positive assertion** (it proves the gated decision uses the two cleared families and ignores the uncleared one) rather than relying on an uncleared source to reach QUALIFIED. Also added `commerce_signals` cleanup for the fixture product_ids (the selftest previously left orphan signals each run). Suite contract id unchanged.

### Verification
`fn_stage1_supplier_resolution_selftest` **all_pass=true, 21/21** (0 failed). No regression: GOLD-gating `fn_stage1_product_opportunity_invariants_selftest` 8/8, `fn_stage1_research_bridge_selftest` 8/8, `fn_kalodata_commerce_adapter_selftest` 17/17, `fn_generic_only_discovery_selftest` 7/7, `fn_product_competitor_evidence_selftest` 6/6. **$0; 0 provider calls; 0 orders.** No acceptance flipped; **GOLD 11/22 preserved.** Build Evidence row **291**; migration record `mig_366`. The BE264 rights-enforcement behaviour and all accepted features are unchanged.

---

## Addendum 67 — DataForSEO secure-executor verification (BE292, 2026-11-24)

**Date:** 2026-11-24. Founder directive: *GPD.06 — DataForSEO Secure Executor Verification*. Verify the budget-enforcing execution pathway (BE290) is deployed, operational and secure **before any further chargeable requests**. Verification only; no new build; fix only a genuine control failure. **$0; 0 provider calls; 0 orders; no unnecessary n8n executions.**

### TASK 1 — deployment, connection, flow, n8n bypass
- `supabase/functions/dataforseo-execute/index.ts` is **ACTIVE, version 1, verify_jwt=false**; the live source is **byte-identical to the repo** (`ezbr_sha256 44835547…`). `mig_365` functions present and granted service_role-only.
- **Credential access (secure):** the executor reads `DATAFORSEO_LOGIN`/`DATAFORSEO_PASSWORD`/`DATAFORSEO_EXECUTOR_TOKEN` from the **edge secret store only** — never from n8n, never logged, never returned; Basic auth is constructed at call time and only after the authoriser authorises. Secret **values** cannot be read back through available tooling (by design); their provisioning is a founder action (below).
- **Flow (from the deployed source):** GATE 1 executor-token (unset ⇒ all dispatch 401) → GATE 2 credential-presence (unset ⇒ 503 **before** consume) → GATE 3 `fn_dataforseo_pilot_consume`; the provider `fetch()` is unreachable unless GATE 3 authorises; `fn_dataforseo_merchant_record_cost` reconciles actual cost afterward; `probe` is read-only.
- **No active n8n bypass:** only **3** DataForSEO workflows remain and **all are `active:false`** (free retrieve/preflight/balance); the 5 paid-capable direct-HTTP workflows were archived (BE290); the credential is DECOMMISSIONED. No active workflow can bypass.

### TASK 2 — spending controls (non-chargeable)
`fn_dataforseo_spend_control_selftest` **ok=true, 10/10** (founder-approval gate, country, over-per-run-cap, disabled, emergency-stop, idempotency, and T8 concurrency ×3). `fn_dataforseo_pilot_preauthorize` live = **PAID_DISABLED** (`enabled=false`, **0 active provider budgets**, `emergency_stop=false`). Endpoint-specific projection: **SEARCH_VOLUME 60000µ ($0.06) / SEARCH_VOLUME_LIVE 90000µ ($0.09)** / MERCHANT_PRODUCTS 75000 / SELLERS 10000 / unknown-failsafe 100000, checked pre-dispatch and reconciled post via `record_cost` (month-spend excludes FAILED/REFUNDED). Provider failure/retry handled in-executor (records FAILED, slot stays consumed, idempotent replay never re-dispatches). Authoriser/ledger/preauthorize/selftest all **service_role-only**. **0 dispatch rows in the last 30 min** (last row = the prior BE289 audit row).

### TASK 3 — product evidence & rights
US SEARCH_DEMAND retrievable via **GLOBAL_SAFE**, **US-only**: lamp `207dbaa8` `demand_basis=PRODUCT` (product 50 / category 11110); Shark `50e1b04e` PRODUCT (product 81000 / category 214000) — product-vs-category labels distinct. The customer intelligence core **withholds** SEARCH_DEMAND as `DISPLAY_PENDING_RIGHTS` (`present=true` internal, `strength`/`observed_detail` **nulled**, `contributes_to_qualification=false`, customer `source_state=NOT_SEARCHED`; `display_pending_sources=[DATAFORSEO,DATAFORSEO_MERCHANT]`) → **no DataForSEO-derived restricted metric reaches customers**; display gated pending GPD.01. Supplier Unknown (`fn_product_supplier_state_selftest` ok), generic-only (`fn_generic_only_discovery_selftest` ok), PAL, country isolation and accepted GOLD all preserved.

### TASK 4 — fix
**No fix required.** No misconfiguration or control failure was found; the executor is correctly deployed and fail-closed. The only open items are **founder actions**, not defects.

### Remaining security limitations (honest)
Full technical non-bypassability is **not yet established** and requires two founder actions: (1) provision the three edge secrets and enable a budget; (2) **delete** the n8n credential `OYKLUdhcUwGJ8ymT`. Even then, **Supabase project-owners / service-role** can read edge secrets or deploy a replacement function — an inherent admin bypass that cannot be engineered away in-stack.

### Readiness for GPD.07 / GPD.09
- **GPD.06 / GPD.07-search (DataForSEO):** the mechanism is secure and executor-ready; scaling to the other 7 eligible US products is safe **once the founder provisions secrets + approves a budget** (one `/live` task, ~$0.09). Customer display still gated by GPD.01.
- **GPD.07-social:** BLOCKED — Reddit/TikTok `analyse_cleared=false`; Kalodata creator/video counts NULL. Needs a social analysis+display licence (not an executor issue).
- **GPD.09-advertiser:** BLOCKED — META_AD_LIBRARY `analyse_cleared=false`; no DataForSEO path supplies advertiser data. Needs a Meta Ad Library analysis+display licence.

**GOLD 11/22 preserved** (no checkbox flipped). Build Evidence row **292**; LIVE MASTER — GOLD GPD.06 next-action annotated. No code/DB change this pass.

---

## Addendum 68 — GPD.07 social + GPD.09 advertiser: rights determination + withholding re-verification + rights-request drafts (BE293, 2026-11-24)

**Date:** 2026-11-24. Founder directive: establish the smallest lawful, technically feasible routes for genuine social-attention (GPD.07) and advertiser (GPD.09) customer-facing evidence; reuse-first; implement only genuinely-necessary fixes; prepare (not send) one rights request per provider where permission is genuinely missing; keep both gates OPEN until rights-cleared customer evidence exists. **$0; 0 provider calls; 0 orders; no n8n runs; no code/DB change.**

### Rights state (reuse-first)
`catalogue_source_rights`: the **only** display-cleared source is **KALODATA** (analyse + display + display_derived + cache all TRUE). **REDDIT, TIKTOK, META_AD_LIBRARY are all `analyse_cleared=FALSE`** — not cleared even to analyse. Item-4/5 distinction: public API accessibility (Meta Ad Library, Reddit Data API, TikTok) is **not** analysis / commercial-SaaS-display / caching permission.

### Existing stored evidence
- **GPD.07 social:** `COMMUNITY_ATTENTION` = reddit, 11 rows / 10 products (tenant-private, uncleared). No `SOCIAL_ATTENTION` signal type exists.
- **GPD.09 advertiser:** `ADVERTISING_ACTIVITY` = META_AD_LIBRARY, 440 rows / 11 products (GLOBAL_SAFE, uncleared).
- **Kalodata (the cleared source):** all 33 products (23 DE + 10 US) carry the social/advertiser **keys** (`creator_count`, `video_count`, `view_growth`, `share_growth`, `creator_growth`, `advertiser_count`, `ad_growth`) but **every value is JSON null** (`jsonb_typeof='null'` on all 33 — the discovery endpoint did not populate them). `kalodata_video_research` is **empty** (the built `kalodata-video-rank` capability was never ingested).

### Item-6 — any narrow derived signal?
**No** from META/REDDIT/TIKTOK: `analyse_cleared=FALSE` means deriving *is* analysing, which is unlicensed — a "presence flag" is not a lawful workaround. **Only Kalodata** (fully cleared) could lawfully yield a derived social/advertiser signal, but it currently holds no such data. So there is **no rights-cleared customer-facing social or advertiser evidence today**.

### Customer withholding re-verified (present-but-uncleared, not mere absence)
`fn_stage1_early_opportunity_state(e453eed4, GB)` — a product with **128 Meta ads + 1 Reddit row** — returns `ADVERTISING_EMERGENCE` = **NOT_AUTHORISED** (present=false, qualifying=false) and `COMMUNITY_SOCIAL` = **NOT_AUTHORISED**; `uncleared_sources=[FASTMOSS,EBAY,META_AD_LIBRARY,TIKTOK,REDDIT,EBAY_MARKETPLACE]`; the raw **128** advertiser count does **not** leak; `SEARCH_DEMAND` (DataForSEO, analyse-cleared) is used internally only, customer display gated `DISPLAY_PENDING_RIGHTS`. The customer drawers (`fn_product_ad_evidence`) are tenant-auth-gated. **Distinctions preserved:** rights-withheld (`NOT_AUTHORISED`) ≠ no-observation (`present=false`, state null) ≠ zero; social attention ≠ verified demand; advertiser ≠ sales. Attribution/identity/country/tenant verified.

### Fix (item 8)
**None required** — no engineering defect; the honest withholding and UNKNOWN/NOT_AUTHORISED states are already correct. The gates are blocked on **external rights**, not code. GPD.01 kept separate; DataForSEO DISPLAY_PENDING_RIGHTS preserved.

### Lowest-cost next actions (each needs founder approval; none executed)
- **GPD.07 social — PRIMARY (no new rights):** a founder-approved **Kalodata** video/creator ingest (already display-cleared; existing `kalodata-video-rank`), mapped to a customer **social-attention** signal labelled *social ≠ demand*.
- **GPD.09 advertiser:** (a) a **free** question to Kalodata on whether `advertiser_count` is retrievable (if yes, a cleared no-new-rights ingest); else (b) a **Meta Ad Library** analysis + SaaS-display + cache **licence**.
- **FALLBACK social:** a **Reddit** analysis+display licence.

### Rights-request drafts (prepared, NOT sent)
`docs/GPD07-09-PROVIDER-RIGHTS-REQUESTS-DRAFT.md` — **Draft 1 Meta Ad Library** (GPD.09), **Draft 2 Reddit** (GPD.07). Both request analysis + authenticated-SaaS-display + caching (derived aggregate only; no restricted content), not mere API access. **TikTok not requested** (social attention served via the already-cleared Kalodata). Do not send without founder authorisation.

**GPD.07 and GPD.09 remain OPEN.** GOLD **11/22 preserved** (no checkbox flipped). Build Evidence row **293**; LIVE MASTER — GOLD GPD.07/GPD.09 next-actions annotated. No migration (no code/DB change).

---

## Addendum 69 — GPD.07 TikTok product-video integration + GPD.09 Meta advertiser status (BE294, 2026-11-24)

**Date:** 2026-11-24. Founder **permanent product decision**: use TikTok's **official embedding** for discovered-product videos (stop pursuing Kalodata video-playback permission as a launch prerequisite); use **Meta Ad Library** as the preferred advertiser source — both within verified rights, without flipping GPD.07/09 to accepted. Reuse-first; smallest safe change; **$0; 0 provider calls; 0 downloads; no unlicensed media stored**.

### GPD.07 — TikTok product videos (built)
- **Reuse:** the product-video subsystem already existed — `fn_product_media_state` (REFERENCE_ONLY, `auth.uid()`-owned, tenant+market isolated) serving `videos[]` from `media_assets` with `tiktok_url`, decoded by `product-media-contract.ts`, rendered by `reference-video-gallery.tsx`. Media is REFERENCE_ONLY and never feeds store/ad/creative/publishing or qualification gates.
- **Backend (`mig_367`):** added two display-only derived fields per video — `embed_platform` ('TIKTOK' when the url is tiktok.com) and `identity_match` (`EXACT_PRODUCT` | `PROVIDER_ASSOCIATED` | `RELATED_CATEGORY`, never defaulting to EXACT). Nothing else changed.
- **Data (lawful, free):** US lamp `207dbaa8` gained ONE genuine web-discovered public TikTok reference video (`@lennyventure._/video/7426619822433111302`, `RELATED_CATEGORY`, US, `TIKTOK_EMBED_PUBLIC`) — honestly a category reference, not an exact-product demonstration; the DE product `5bc29d0a` already had 7 FastMoss-discovered references → labelled `PROVIDER_ASSOCIATED`. No downloads; playback via TikTok's official embed only.
- **FE (Lovable preview `77d27e8`; NOT published):** `reference-video-gallery.tsx` click-to-plays the **official TikTok Embed Player** (`tiktok.com/player/v1/<id>`) for embeddable videos, keeps **"Watch on TikTok"** as the fallback (covers removed/private/embed-disabled → player renders nothing → link), shows the identity-match caption ("Related video — category match, not an exact product demonstration" / provider-associated / verified), adds a banner line that a related video **is not verified social-demand evidence**, and has **no download control**. `product-media-contract.ts` decodes the new fields fail-closed. Full FE suite **1074 tests** pass (+8), typecheck/lint/production-build clean.
- **Rights:** TikTok official embed/oEmbed/Embed Player needs no API key or app review and is the lawful playback path; no download/cache/rehost; creator attribution shown; private/removed videos fail-closed to the link.
- **GPD.07 stays OPEN:** a video embed is REFERENCE_ONLY recognition, **not** verified social-demand metrics (item 11). The social-demand requirement still needs a Reddit/TikTok analysis+display licence OR a Kalodata creator/video-count ingest (BE293). No checkbox flipped.

### GPD.09 — Meta advertiser intelligence (verified gated; no bypass)
- The customer advertiser/competitor display mechanism already exists and is **rights-gated + tenant-auth-gated** (`fn_product_ad_evidence` / `fn_product_competitor_evidence`, BE264 mig_336/337; contract carries META + TIKTOK with `NOT_AUTHORISED`/`NOT_SEARCHED`/`UNKNOWN`/unsupported-market states). Stored observations: 440 Meta `ADVERTISING_ACTIVITY` rows (fields `ad_id`/`advertiser_page`/`page_id`/`platforms`/`market`/`match`) — enough for distinct-advertiser / active-ad / start-date display **when rights clear**.
- **No bypass:** `META_AD_LIBRARY.analyse_cleared=false` is preserved. Public Ad Library API access ≠ analysis / commercial-SaaS-display / retention / redistribution rights (verified against current docs; non-EU commercial coverage is also API-restricted by design). Advertiser ≠ sales; no customer ad-campaign creation. The display path activates only after the **Meta Ad Library rights licence** (BE293 draft) is granted and the founder sets the rights flags. **GPD.09 stays OPEN.**

### Verification & preservation
Backend regression GREEN: `product_media_auth`, `product_image`, `discovery_media_integrity`, `product_supplier_state` (Supplier Unknown), `stage1_product_opportunity_invariants` (GOLD-gating), `product_competitor_evidence`, `gpd01_aggregate` — all 0 failed. Country isolation (US vs DE) holds; attribution + REFERENCE_ONLY + PAL + tenant auth preserved; GPD.01 kept separate and DataForSEO `DISPLAY_PENDING_RIGHTS` untouched. **GOLD 11/22 preserved** (no checkbox flipped). Build Evidence row **294**; migration record `mig_367`; GPD.07/GPD.09 next-actions annotated. Production publish of the FE preview `77d27e8` awaits founder authorization (same pattern as CX.02).

---

## Addendum 70 — Commercial launch-readiness execution: assessment + GPD.19 test + GPD.22 benchmark (BE295, 2026-11-24)

**Date:** 2026-11-24. Founder-authorised one-assignment execution of three launch-readiness tasks. **Revised criteria remain PROPOSED — nothing accepted or applied**; `LIVE MASTER — GOLD` tab + all checkboxes untouched; **formal GOLD 11/22 preserved**; no source-rights/security/release/budget changes; **$0, 0 provider calls, 0 orders, no n8n runs**. Full deliverable: `docs/COMMERCIAL-LAUNCH-READINESS-ASSESSMENT-DRAFT.md`.

- **Task 1 — 22-unit DRAFT assessment** (separate doc; five states): ACCEPTED 11 (GPD.02/03/04/05/12/13/14/15/18/20/21); RETIRED FROM LAUNCH 1 (GPD.17); READY FOR FOUNDER TEST 3 (GPD.16 research-scope, GPD.19, GPD.22 bounded); BLOCKED — EXTERNAL 7 (GPD.01/06/07/08/09/10/11). GPD.09 may become DEFERRED only on explicit founder approval. The tally is advisory — it does **not** change the formal GOLD count.
- **Task 2 — GPD.19 acceptance test:** backend substrate verified reuse-first (supplier 4-state selftest 5/5; lamp `207dbaa8` 0 bound suppliers → Supplier Unknown; **0/1,317 supplier rows carry a URL** → "View Supplier" unavailable & not required; supplier-independent discovery + save/retrieve/monitor (GPD.18) + founder-gated store/ads). The exact signed-in production-browser steps (discover generic → Supplier Unknown → research → save → retrieve → monitor, 4 screenshots) are listed as the only founder-session-dependent actions. Not marked accepted.
- **Task 3 — GPD.22 bounded 5-market/10-cell benchmark EXECUTED** (reuse-first, $0): generic products `efca8b59` (over-door shoe organizer) + `e453eed4` (kids nightlight projector) × {GB,DE,IE,IT,US}. **10/10 cells genuinely evaluated** — 6 EMERGING (qualifying = authorised DataForSEO SEARCH_DEMAND, dated 19 Sep–7 Oct 2026), 4 honest DISCOVERED/UNKNOWN. Genuine same-product cross-market comparison (projector GB vs US vs DE, independent verdicts & saturation) + a GB-DISCOVERED vs IE/IT/DE-EMERGING divergence for the organizer; **country isolation PASS** (organizer US & projector IE/IT = DISCOVERED/UNKNOWN despite other-market evidence — no leakage); eBay/Meta withheld (NOT_AUTHORISED), prices UNKNOWN. No fabricated cells; original 60-cell GPD.22 stays not accepted.

**Recommendation:** GPD.16 (research-scope), GPD.19 (after the one browser test), GPD.22 (bounded results) and GPD.17 (retirement) are ready for founder acceptance review; **GPD.01 is the critical-path external gate** for GPD.06/07/08/10/11; GPD.09 is keep-or-defer. Build Evidence row **295**. Formal acceptance will be recorded only on explicit founder approval.

---

## Addendum 71 — P0 fix: media-asset-url 403 no_asset / blank Product Research workspace (BE297, 2026-11-24)

**Date:** 2026-11-24. P0: the authenticated Lovable preview showed a runtime error — edge function `media-asset-url` returned **403 `{"error":"no_asset"}`** with a blank Product Research workspace. **$0, 0 provider calls, 0 orders; no RLS/PAL/source-rights/security changes; no manufactured URLs; GOLD 11/22 unchanged; GPD.19 not accepted.**

**Root cause (self-inflicted by BE294):** `fn_product_media_state` derived `playback_mode = storage_ref~https ? EXTERNAL_URL : SELF_HOSTED_SIGNED`. The BE294 reference TikTok video on the US lamp `207dbaa8` has `storage_ref = NULL`, so it was mislabelled `SELF_HOSTED_SIGNED`; the FE then minted a signed URL via `media-asset-url` for an asset with no storage object → `fn_media_asset_signed_ref` → `no_asset` → 403, surfaced by the preview as a runtime error / blank screen. (A tiktok.com page URL in `storage_ref`, used by the 7 FastMoss references, was likewise wrongly treated as a directly-playable `EXTERNAL_URL`.)

**Backend fix — `mig_368` (live in production DB):** `playback_mode` is now three-way — `EXTERNAL_URL` (https, non-tiktok media), `SELF_HOSTED_SIGNED` (non-empty non-https bucket object), or **NULL** (no stored file OR a tiktok.com reference → official embed/link only). A reference-only TikTok video **never** triggers a signed-URL fetch. Verified across all reference VIDEO rows: 8 TikTok rows (lamp + 7 FastMoss) → NULL (embed/link); 4 genuine self-hosted rows (CJ/generated) stay `SELF_HOSTED_SIGNED` with real objects; **no row can be `SELF_HOSTED_SIGNED` with empty storage** → spurious 403 eliminated at the root. Regression GREEN (`product_media_auth`, `product_image`, `discovery_media_integrity`, `product_supplier_state`, stage1 invariants). Because the fix is in the DB (read by both surfaces), preview **and** production stop getting the lamp 403 on reload (old published FE degrades the null-mode video to a "Watch on TikTok" link; preview FE renders the official embed).

**FE defense-in-depth — Lovable PREVIEW commits `dd7edb8` + `8e6a0f6` (NOT published):** embeddable TikTok videos prefer the official player and never signed-fetch; a genuinely missing/forbidden self-hosted asset now renders a neutral **"Video unavailable"** placeholder (no misleading retry; one-off retry only for transient `unavailable`), with errors contained to the card so sibling cards and the research workspace keep working; `no_asset`→`missing` decode added. **1,081 FE tests pass / 115 files; lint + builds clean.**

**Verification limitation (honest):** neither the build session nor the Lovable agent can sign into the authenticated preview (sign-in redirect; `strateloq.com`/`lovable.app` unreachable from the container), so the live desktop/mobile lamp sighting is the founder's step — the backend fix is proven deterministically by SQL and the FE behaviour by regression tests. Preview verified (tests/build); **production FE publish of the embed feature still awaits founder authorisation** — the P0 403 itself is already resolved in production by the backend migration. Supplier Unknown / Save / Retrieve / Monitor and authorised Kalodata images + attribution preserved. Build Evidence row **297** (BE297); migration record `mig_368`.

**Evidence-identifier correction (BE296 → BE297).** This P0 closeout was first recorded as "BE296", which collided with a pre-existing **BE296** already in the register (Build Evidence row 296: *"GPD.19 founder approval of revised supplier-independent research continuity — separate launch scope; original GOLD unchanged"*). Both records are preserved per founder instruction: **BE296 stays the GPD.19 founder-approval record (row 296, untouched)**; this media-error closeout is renumbered to the next unique identifier **BE297 (row 297)**. The commit that first landed this work (`41b16d5`, message *"BE296: P0 fix — media-asset-url…"*) is left as historical — the message is immutable on the shared branch and is not rewritten; the authoritative identifier for the media-error closeout is **BE297**.

---

## Addendum 72 — Final media-fix release preparation (BE298, 2026-11-24)

**Date:** 2026-11-24. Read-only release-verification pass on the Lovable preview to prepare the media fix (BE297) for a production publish. **No application source changed; nothing published; $0 build-session, 2.4 Lovable credits.** This pass does **not** flip any acceptance, rights, release gate, budget or GOLD count; GOLD remains **11/22** and the GPD.19 "ACCEPTED — REVISED LAUNCH SCOPE" Launch Acceptance Decisions entry is preserved.

**Preview integrity.** Preview HEAD = `8e6a0f6ac2bfeff92e7cd73ae95f75a893ed7f80` ("Contain denied reference videos and verify null-mode TikTok playback"). Both `dd7edb8` and the founder-approved TikTok-embed commit `77d27e8` are ancestors — no earlier approved work was lost. Working tree clean (`git status --short` empty, before and after the build).

**Static signed-URL + containment guard (quoted from code).** `product-media-contract.ts`: line 69 `const mediaAssetId = mode === "SELF_HOSTED_SIGNED" ? str(raw.media_asset_id) : null;`; line 77 `playbackMode: mediaAssetId ? "SELF_HOSTED_SIGNED" : playbackUrl ? "EXTERNAL_URL" : null;`; the only `media-asset-url` call lives in `fetchSignedMediaUrl` (174–176). `reference-video-gallery.tsx`: line 28 `if (video.playbackMode !== "SELF_HOSTED_SIGNED" || !video.mediaAssetId) return;`; line 46 `if (video.playbackMode === "SELF_HOSTED_SIGNED") void mint();`; line 205 `{video.playbackMode && !embeddable ? (` (TikTok-embeddable → official player/link, never a signed fetch). Missing/forbidden assets decode to `missing`/`forbidden`, `catch` blocks return a status instead of throwing, each card sets only its own state, Retry is offered only for transient `unavailable`, and the card renders "Video unavailable" — so no error propagates to the Product Research workspace. (Containment relies on these handlers; there is no separate error-boundary wrapper.)

**Checks (independently run this pass).** Full suite `bunx vitest run` → **1,081/1,081 tests passed, 115/115 files**. Standalone `bunx tsc --noEmit -p tsconfig.json` → **exit 0, no errors** (not previously run manually for `8e6a0f6`). Production `bun run build` → **exit 0**; only two benign warnings: a route-export warning for `sitemap.test.ts` (expected — a test file) and `inlineDynamicImports option is ignored because the codeSplitting option is specified`.

**Production publication candidate = `8e6a0f6` (current preview HEAD).** Publishing deploys the whole preview HEAD; Lovable has no partial-publish.

**Deployment risk (must be weighed before publishing).** The live/published commit is **not determinable from the sandbox** (no deployment record exposed). Production was published only once earlier in the project, so a publish of `8e6a0f6` would ship the **entire preview backlog**, not only the three TikTok commits. The ~10 most recent preview-only commits a publish would include: `8e6a0f6`/`dd7edb8` (TikTok media fix), `77d27e8` (founder-approved TikTok player), `2cf07eb` (restore competitor "View public listing" link), `72de4a1` (supplier-status badge + strict "View Supplier" rule), `c5e9450` (Problem→Product page), `56bacb6` (subscription screens + German translations), `767fa0b` (catalogue photo rule + founder Applications review + Share feedback dialog), `e9b3503` (Shared catalogue section), `779ae40` (Monitoring + change alerts). Each was requested and built separately, but none has been in production. **The founder must confirm the true live commit in Lovable's publish history before approving**, and accept that a publish ships this backlog. Independent of the FE publish, **the P0 403 is already resolved in production by backend `mig_368`**, so this publish is not required to clear the P0.

**Remaining founder-only actions.** (1) Confirm the live published commit in Lovable's publish history and authorise publishing `8e6a0f6` (acknowledging the backlog above); publication is through the existing Lovable deployment workflow. (2) After any publish — or on the current production build — an authenticated signed-in sighting of the RGBIC lamp Product Research workspace to confirm no live 403 (neither the build session nor the Lovable agent can sign in: sign-in redirect; `strateloq.com`/`lovable.app` unreachable from the container). **Not published; awaiting founder approval.** Build Evidence row **298** (BE298).

---

## Addendum 73 — Media frontend production release (BE299, 2026-11-24)

**Date:** 2026-11-24. Founder gave conditional approval to publish preview HEAD `8e6a0f6` to production subject to a final pre-deployment gate (no unrelated/unauthorised/security-sensitive changes; no backend/security surface touched; tests + build green). The gate **passed** and the release was published. **$0 provider; ~6.2 Lovable credits (verification + release); GOLD 11/22 unchanged; GPD.19 "ACCEPTED — REVISED LAUNCH SCOPE" preserved (historical C20 still FALSE); no rights/RLS/PAL/source-permission/release-gate/provider-budget change.**

**Live-before commit (determined, not assumed).** Production was live on `2cf07eba3c1ba24e944e4b9088ef20bcf2811594` ("Restore competitor listing link"), read with high confidence from the `data-commit-sha` attribute served by `https://www.strateloq.com/` and cross-checked by feature presence (the live site already had Problem→Product, Supplier status, Shared catalogue, Share feedback, Monitoring; it lacked the TikTok strings). This corrected an earlier worst-case assumption that production trailed a large backlog.

**Pre-deploy gate (publish delta `2cf07eb..8e6a0f6`).** Exactly the three TikTok commits — `77d27e8` (founder-approved TikTok player), `dd7edb8`, `8e6a0f6` (the P0 media fix). **6 files, all frontend** (+426/−18): `reference-video-gallery.tsx` (+ test), `product-detail-video.test.tsx`, `cj-supplier-media.test.tsx`, `product-media-contract.ts` (+ test). **No** backend/edge function, DB, RLS, auth/session, Supabase client/keys, `service_role`/secrets, `.env`, `package.json`/lockfile, route list, build config, rights/release-gate or provider/budget file. Added lines scanned for sign-in, client setup, keys, env reads, `eval`/`atob`, new `fetch` — none; the only new URLs are fixed `tiktok.com` player/link strings, and the existing `media-asset-url` request is made *more* restrictive. On `8e6a0f6`: `vitest` **1,081/1,081** (115 files), `bun run build` **exit 0**, working tree clean.

**Publish.** `deploy_project` on project `12db6c84-161b-4c23-aac4-e19e8cd24ab1` → `deployment_id 63264021-1646-4c00-8527-2dbdd92fc44d`, URL `https://pulse-implementation.lovable.app` (custom domain `https://www.strateloq.com`).

**Post-deploy production verification (what connectors can reach).** Both `https://www.strateloq.com/` and `https://pulse-implementation.lovable.app/` now serve `data-commit-sha=8e6a0f6ac2bfeff92e7cd73ae95f75a893ed7f80` (= the candidate). The live JS (153 files crawled) now contains `Video unavailable`, `tiktok.com/player` and `Watch on TikTok` (all absent pre-publish) and retains the earlier features. Backend `mig_368` is live in the production DB; the US lamp `207dbaa8` TikTok reference resolves to `playback_mode` NULL (embed/link, no signed fetch), and no VIDEO asset can be `SELF_HOSTED_SIGNED` with empty storage — so **(item 6)** a storage-less TikTok reference issues no `media-asset-url` signed request, and **(item 7)** a missing/forbidden self-hosted asset is contained to its card as "Video unavailable" (code-verified; no re-throw to Product Research).

**Remaining founder-only action (item 9).** A single authenticated, signed-in sighting of the RGBIC-lamp Product Research workspace on production — confirming the page loads with no 403, the TikTok embed plays via the official player, and any missing/forbidden asset shows the neutral placeholder. Neither the build session nor the Lovable agent can sign in (sign-in redirect; `strateloq.com`/`lovable.app` unreachable from the container), so no automated authenticated-visual confirmation is claimed. Build Evidence row **299** (BE299); deployment `63264021-1646-4c00-8527-2dbdd92fc44d`.

---

## Addendum 74 — Production deployment-baseline reconciliation (BE301, 2026-11-24)

**Date:** 2026-11-24. The founder flagged a contradiction: BE298 had reported the preview backlog "never published", yet project records show a founder-approved production deployment on 2026-11-24 — deployment `1251f50d-f6ce-430f-80a0-2e3892bbb71c`, published commit `2cf07eba3c1ba24e944e4b9088ef20bcf2811594` — and the founder observed Supplier Unknown live on `strateloq.com`. This note reconciles it. **No publish during this reconciliation; $0 provider; 0.4 Lovable credits; GOLD 11/22 and GPD.19 acceptance preserved; `mig_368` and the FE regression evidence untouched.**

**Resolution.** The BE298 "never published" inference was **wrong**. Production *was* live on `2cf07eb` via deployment `1251f50d` — which is exactly the `live-before` commit the BE299 pre-deploy gate had already determined independently (read from the `data-commit-sha` served by `strateloq.com`, cross-checked by the presence of Supplier status / Supplier Unknown, Problem→Product, Shared catalogue, Share feedback and Monitoring in the live code). So the contradiction was already corrected at BE299; the founder's deployment record and my live read agree on `2cf07eb`.

**Current production (fresh read this pass).** `https://www.strateloq.com/` serves `data-commit-sha=8e6a0f6ac2bfeff92e7cd73ae95f75a893ed7f80`; `https://pulse-implementation.lovable.app/` now 301-redirects to `strateloq.com` (same `8e6a0f6`). Therefore deployment `1251f50d` (`2cf07eb`) is **superseded** by the BE299 release deployment `63264021-1646-4c00-8527-2dbdd92fc44d` (`8e6a0f6`), which this session published under the founder's conditional approval.

**Actual published difference `2cf07eb → 8e6a0f6`.** Exactly the three TikTok commits (`77d27e8` TikTok player, `dd7edb8` + `8e6a0f6` the P0 media fix) — 6 frontend files (+426/−18), no backend/edge/RLS/auth/secrets/env/package/release-gate/provider-budget changes, nothing unrelated, security-sensitive or unfinished. **Affected capabilities:** product-video display only — official TikTok embed/click-to-play for reference videos, and a neutral "Video unavailable" placeholder for missing/forbidden self-hosted media; no change to discovery, supplier states, rights gates, isolation or economics. **Features already in production via `2cf07eb` (not to be described as unpublished):** Supplier status / Supplier Unknown, Problem→Product, Shared catalogue, Share feedback, Monitoring.

**Recommendation.** Publishing HEAD `8e6a0f6` is **safe — and already done**: production is on `8e6a0f6`, so a further publish would introduce **zero delta**. No additional publish is required or recommended.

**Founder production acceptance now recorded (BE300, row 300).** The one item previously flagged as founder-only — the authenticated signed-in sighting of the RGBIC-lamp Product Research workspace on production — has since been completed by the founder: deployment `63264021` / commit `8e6a0f6`, **3/3 signed-in checks PASS** (Product Research loads with no 403/blank; official TikTok player or permitted public-link fallback works; unavailable/forbidden media degrades gracefully with no workspace disruption). That is a founder attestation (not independently replayed screenshots), and it is **not** acceptance of GPD.07 social-demand or GPD.09 advertiser rights, nor any new GPD.19 acceptance. So there is **no remaining media-release action**.

**Evidence-identifier note (BE300 → BE301).** This reconciliation was first appended as "BE300" but collided with the founder's own **BE300** production-acceptance entry (register row 300). Both are preserved: BE300 stays the founder's production-acceptance record; this reconciliation is renumbered to **BE301** (register row 301). Build Evidence row **301** (BE301).

---

## Addendum 75 — Launch-readiness execution for the BE302 assignment: GPD.16 / GPD.22 (founder-approved) · GPD.01 · GPD.06–11 (BE304, 2026-11-24)

**Date:** 2026-11-24. Next approved non-destructive launch-readiness synthesis, with the media P0 closed (BE296–BE301) and the production release founder-accepted (BE300). **$0; 0 provider calls; no n8n; no publish; no code/DB change; no rights/release/budget flip. Formal GOLD 11/22 unchanged; GPD.19 "ACCEPTED — REVISED LAUNCH SCOPE" preserved.** Full working in `docs/COMMERCIAL-LAUNCH-READINESS-ASSESSMENT-DRAFT.md` **Part 5**. **Founder update (BE303, 2026-11-24):** the founder has since **APPROVED** the revised GPD.16 (supplier-independent research scope) and GPD.22 (bounded technical benchmark) as separate launch decisions — both now recorded in the **Launch Acceptance Decisions** tab alongside GPD.19, with **historical GOLD checkboxes unchanged (GPD.16 C17, GPD.22 C23 stay FALSE; GOLD 11/22)**. GPD.01 and GPD.06–11 below remain preparatory (no approval).

- **GPD.16 → FOUNDER-APPROVED (revised, supplier-independent research scope; BE303).** Reuse CX.02 (complete + published), Supplier Unknown 4-state 5/5, **0 of 1,317 supplier rows carry a URL → no VERIFIED_SUPPLIER**, and the live **GPD.19 production acceptance (BE300, 3/3 PASS)** as end-to-end proof. Exact-SKU supplier verification stays **external/optional** (BE270); no supplier link fabricated; original GPD.16 box stays FALSE pending founder acceptance.
- **GPD.22 → FOUNDER-APPROVED (revised bounded 10-cell + BE295 results; BE303).** 6 EMERGING (authorised DataForSEO SEARCH_DEMAND) / 4 honest DISCOVERED-UNKNOWN; genuine cross-market divergence; country-isolation pass; dates/uncertainty preserved. **Not re-run** (no defect). Original 60-cell stays NOT ACCEPTED.
- **GPD.01 → prep COMPLETE; one legal decision outstanding.** Live `catalogue_source_rights` confirmed (Kalodata full; DataForSEO analyse-only / DISPLAY_PENDING_RIGHTS; CJ analyse+derived; Reddit/TikTok/Meta/eBay uncleared); BE264 gating + BE290 chokepoint live; provider replies + legal package recorded. **Precise decision:** whether founder + legal undertake and clear the **Google Shopping / Merchant upstream display-compliance assessment** (DataForSEO ToS §7.2 — provider permission necessary-not-sufficient), then the founder flips the DataForSEO display flag. **Not claimed; not flipped.**
- **GPD.06–11 dependency plan.** Engineering-ready, blocked only on rights: GPD.06, GPD.11, GPD.07-search, GPD.08/GPD.10 mechanisms. Optional/deferred: GPD.09 (Meta licence or founder deferral). **Smallest next engineering batch:** a one-time display-readiness confirmation behind the `DISPLAY_PENDING_RIGHTS` gate (so a GPD.01 clearance is a single flag flip, no new build); the only lawful content advance without a new licence is the Kalodata social-attention ingest (GPD.07), which needs founder Kalodata-credit budget. Nothing executed. This synthesis is recorded as Build Evidence **BE304** (row 304) — renumbered from a duplicate "BE302" to avoid collision with the concurrent BE302 plan (row 302) and the founder's BE303 approval (row 303); all three preserved.

---

## Addendum 76 — GPD rights & evidence resolution (BE305, 2026-11-24)

**Date:** 2026-11-24. Fastest-lawful-route resolution for the remaining original GOLD evidence gates. **Research & proposals only — no external message sent, no API cost, no rights/release flag flipped, no customer data released, no legal-clearance assertion. GOLD 11/22 unchanged; BE303 approvals + infrastructure intact.** Full report: `docs/GPD-RIGHTS-EVIDENCE-RESOLUTION-BE305.md`. *(Founder titled the assignment "BE304"; recorded as **BE305** because BE304 was already consumed by the prior launch-readiness synthesis.)*

- **GPD.01 fastest route = split the counsel question into two legs:** **(1) Google Ads search-volume** — Google *creates/estimates* the metric, so under *BHB v William Hill* the sui-generis database right (which protects *obtaining*, not *creating*) is a weaker claim → the lower-risk leg, clear first; it unblocks **GPD.06** and the **GPD.07 search leg**. **(2) Google Shopping compilation** — Google *obtains/verifies* merchant listings → the genuine Art. 7 / Art. 7(5) question; it unblocks **GPD.08/10/11** together (aggregate counts + price ranges only, verbatim seller list withheld). DataForSEO analyse/derive is **granted**; customer **display** is **not** (gated), and DataForSEO's permission is **not** Google's upstream permission.
- **GPD.07 social / Kalodata:** `kalodata_video_research` is **empty (0 rows)** and the social metrics are not stored — a founder-approved Kalodata-credit ingest (cleared source) is required, plus a prepared (unsent) Kalodata follow-up to confirm the exact-product/country fields and derived-display scope; otherwise defer the social leg.
- **GPD.09 / Meta:** 440 observations stored but `META_AD_LIBRARY.analyse_cleared=FALSE` (cannot even analyse) → recommend **formal founder deferral** of the optional gate, or send the existing smallest licence request (Draft 1); never enable the uncleared observations.
- **Alternatives:** CJ/BigBuy are **supplier** sources (authorised), **not** a marketplace-seller census — must not be mislabelled; an OEM/embedded licence (e.g. Similarweb) only after written field/country/SaaS-display-rights/cost coverage (Similarweb MCP currently proxy-disconnected; not evaluated).
- **Open input:** DataForSEO's 5 Nov 2026 legal FAQ (sections 3–7) was **not** in the repo captures and Gmail is de-authorised — flagged for capture before counsel sign-off; nothing in the matrix changes until it is reconciled. Build Evidence row **BE305**.

---

## Addendum 77 — Live evidence-state verification + consolidated decision matrix (BE306, 2026-11-24)

**Date:** 2026-11-24. Non-chargeable verification of the BE305 rights resolution against the **actual stored evidence**, plus the consolidated decision matrix the founder requested. **$0; 0 provider calls; no sends/flips/deploys; GOLD 11/22; all rights gates, supplier verification, RLS, PAL, isolation and BE303 approvals preserved.** Full detail: `docs/GPD-RIGHTS-EVIDENCE-RESOLUTION-BE305.md` Part 8. *(Founder titled this "BE305"; recorded as **BE306** — BE305 is the report.)*

- **Four-state evidence (live counts):** GPD.06 DataForSEO Google-Ads `SEARCH_DEMAND` **38 obs / 22 products** (analysable, display-gated); GPD.08/10 Google Shopping `DATAFORSEO_SELLERS` **18 obs / 9 products / 5 markets** (analysable, gated); **eBay `EBAY_BROWSE` 1,992 obs / 36 products / 10 markets** — present but `analyse_cleared=FALSE` (**can't even analyse** = the independent-marketplace rights gap); GPD.09 Meta `ADVERTISING_ACTIVITY` **440 obs / 11 products** (present, blocked); GPD.07 social Kalodata **0 rows** (absent), Reddit `COMMUNITY_ATTENTION` 11 (uncleared). The only display-authorised source (Kalodata) holds **zero** rows for these gates.
- **GPD.01 ≠ all gates pass (data-confirmed):** Leg-1 (search-volume) clearance passes GPD.06 for 22 products; Leg-2 (Shopping) clearance passes GPD.08/10 for only **9** products / 5 markets; GPD.11 is derivative/thin; the eBay bulk stays a **separate** rights decision.
- **Replacement provider:** **not necessary** for the launch-minimum (DataForSEO permission is in hand; the gap is upstream *legal*). An eBay/marketplace or OEM (e.g. Similarweb) licence is relevant only to **broaden** GPD.08/10/11 and only after written field/country/SaaS-display-rights/cost coverage.
- **Kalodata:** no entitlement table stored; product-matched, country-specific creator/video/growth is not obtainable from stored data → founder-budget ingest + the narrow enquiry. **Meta:** gate preserved; concise licence request (derived count + observed activity + date windows × GB/DE/IE/IT/US) ready; a **separate** founder deferral decision for optional GPD.09 is prepared (not auto-deferred). Build Evidence row **BE306**.

---

## Addendum 78 — Rights-clearance preparation: final counsel questions, Kalodata enquiry, GPD.09 decision, solicitor dependency (BE307, 2026-11-24)

**Date:** 2026-11-24. Smallest next actions toward GPD.01 clearance. **Preparation only — no legal clearance; no correspondence sent; no credits spent; no rights/release flag changed; GOLD 11/22; GPD.16/19/22 (revised) accepted; GPD.17 retired; all source-rights flags + release gates preserved.** Full founder-ready drafts: `docs/GPD01-FINAL-COUNSEL-AND-PROVIDER-DRAFTS.md`. *(Founder titled this "BE306"; recorded as **BE307** — BE306 is the prior verification; register checked, no concurrent rows past 306.)*

- **DataForSEO public FAQ:** `dataforseo.com` was added to this environment's network allowlist (founder-approved), but the session's **permission-mode classifier then blocked the fetch itself** ("Unauthorized Access" for both a web-fetch agent and `curl`). The FAQ is **not read** this session — it needs a permission rule / less-restricted session / or a founder paste. The two counsel questions rest on the captured 12 Jun 2026 ToS + the 20 Nov provider reply, to be reconciled against the FAQ before counsel sign-off.
- **Two separate counsel questions (final):** **Leg 1** Google Ads search-volume (Google *creates* the metric → weaker sui-generis claim, *BHB*); **Leg 2** Google Shopping aggregate counts/ranges/classifications with verbatim/images/links/raw withheld (Google *obtains* the compilation → the stronger Art. 7 question). Each covers ToS §7.1/§7.2/§8.1, upstream Google terms, and the EU/UK database right (Dir 96/9/EC Art. 7 & 7(5); UK CRDR 1997; CJEU *BHB*, *Innoweb*).
- **Kalodata enquiry (final, unsent):** fields/operations for product-matched country-specific creator/video counts + growth, country coverage, entitlement tier + cost, derived-display rights — prerequisite because `kalodata_video_research` is empty.
- **GPD.09 decision (prepared, not auto-taken):** Meta commercial display-licence vs **deferral of the optional gate** (recommend defer for the 18 Dec launch); licence fields if pursued = derived advertiser count + observed activity + date windows × GB/DE/IE/IT/US.
- **Required external dependency:** a **qualified Irish/EU IP & technology solicitor** must review and decide clearance — the build team cannot and does not issue legal clearance. Send the legal package + the two leg questions. Build Evidence row **BE307**.

---

## Addendum 79 — Provider rights-gap decision matrix + policy-verified clearance plan (BE308, 2026-11-24)

**Date:** 2026-11-24. Policy-verification pass toward clearing GPD.01/06/07/08/09/10/11, with **GPD.09 (Meta) now MANDATORY** per founder directive (supersedes the BE307 defer recommendation). **$0; 0 provider calls; no sends/flips/publish; GOLD 11/22; GPD.16/19/22 (revised) accepted; GPD.17 retired; isolation/PAL/RLS/budgets/founding-member restrictions preserved.** Full matrix + plan: `docs/GPD-PROVIDER-RIGHTS-GAP-MATRIX.md`.

- **Honesty constraint:** the current official **Meta Ad Library terms, eBay API License Agreement (§§3/4/8.4/9) and DataForSEO legal FAQ** could **not be fetched** this session — the permission-mode classifier blocks outbound web fetches and those hosts aren't allowlisted. Those matrix rows are marked **[UNVERIFIED — knowledge-based]** and need a founder-enabled fetch (permission rule / less-restricted session) or pasted documents before any request is finalised.
- **Kalodata GPD.07 (evidence-based):** the documented Product Detail counts `creator_number`/`video_number`/`live_number` are **not in stored data** — our stored Kalodata is Product **Rank** revenue (`live/video/showcase_revenue`, `ad_growth`); `kalodata_video_research` is empty. → a **fresh paid Product Detail ingest** is genuinely required (founder budget); **display is already covered** by the 2026-11-11 permission; open items = operation entitlement + country coverage → a narrow enquiry (not asking whether the fields exist).
- **Meta GPD.09 (mandatory):** 440 obs preserved NOT_AUTHORISED (untouched). Path: verify current terms → rely on standard rights / send a commercial display-licence request / or evaluate a **licensed alternative provider** (no integrate/buy without authorisation + written field/rights/cost verification). If unresolved → **mandatory launch blocker**; no ad-link or public-TikTok substitute.
- **eBay GPD.08/10/11:** derived aggregate seller/offer/price/saturation stats fall in the restricted band → **additional written approval**; narrow request drafted citing §§3/4/8.4/9 (clause text to verify); 1,992 obs stay NOT_AUTHORISED; CJ/BigBuy not a marketplace substitute.
- **DataForSEO/Google:** analyse already granted (not re-requested); the two counsel questions (BE307) stand; `DISPLAY_PENDING_RIGHTS` preserved. Build Evidence row **BE308**.

---

## Addendum 80 — Rights-resolution activation status: DataForSEO FAQ verified; nothing sent (BE309, 2026-11-25)

**Date:** 2026-11-25. Move from research to activation prep. **$0; no sends/flips/publish; no paid calls; GOLD 11/22 re-confirmed** (after a concurrent transient 4/22 discrepancy that the register rows 309/310 restored); GPD.16/19/22 (revised) accepted; GPD.17 retired; isolation/PAL/RLS/budgets/founding-member preserved. Full status: `docs/GPD-RIGHTS-ACTIVATION-STATUS-BE309.md`.

- **New evidence:** the **DataForSEO 5 Nov 2026 legal FAQ** was retrieved via an **authorised n8n HTTP workflow** (zero-cost, read-only; this container's web access is permission-blocked, so an authorised connector was used as the founder directed; the workflow was archived) and captured verbatim (§§1–5) to `docs/legal/captures/DATAFORSEO-LEGAL-FAQ-CAPTURE-2026-11-05.md`. It **confirms**: derived/transformed display is **not** the restricted activity (only **raw** resale/redistribution needs a separate agreement — §3); **no** attribution/transformation-threshold from DataForSEO (§4); the **client** bears Google-upstream compliance + the **§7.2 indemnity** (§5); client **retention is unrestricted** (§2). → the DataForSEO provider side is **cleared for derived customer display**; only the Google-upstream legs remain (counsel). The **eBay** agreement static URL returned 404 (moved) — not fetched; needs the current URL.
- **Enquiries actually sent: none** — no authenticated send channel exists (Gmail de-authorised; no provider send connector). Exact finished messages are prepared; no delivery is claimed or fabricated.
- **Prepared, awaiting founder action:** the Kalodata capped Product-Detail pilot (hard $ cap set after the free price/entitlement enquiry), Meta Track A (per-country commercial-ad coverage + SaaS licence) / Track B (checklist-verified licensed alternative — GPD.09 stays blocked until authorised evidence), the eBay derived-statistics request (pending the agreement URL), and the FAQ-reinforced DataForSEO two-leg counsel package. Founder actions: approve counsel fee; Kalodata budget + enquiry; direct Meta; provide the eBay URL; re-authorise Gmail to enable sending. Build Evidence row **BE309**.

---

## Addendum 81 — Verified FAQ §6 (DataForSEO express paid-SaaS permission); eBay sections; nothing sent (BE310, 2026-11-25)

**Date:** 2026-11-25. **$0; no sends/flips/publish; no paid calls; GOLD 11/22 confirmed intact; GPD.16/19/22 accepted; GPD.17 retired.** Details in `docs/GPD01-FINAL-COUNSEL-AND-PROVIDER-DRAFTS.md` Part 2 and `docs/legal/captures/DATAFORSEO-LEGAL-FAQ-CAPTURE-2026-11-05.md`.

- **DataForSEO FAQ §6/§7/§11 captured** (authorised n8n fetch; workflow archived). **§6 expressly permits** processing API outputs into "analytics, reports, dashboards or scores inside the client's own product, [and] showing those to the client's own paying users … no cap on end-user numbers," limited only by **§7.1**; **§11** — no additional licence/tier needed. **→ No further request is owed to DataForSEO; the only residual is the two Google-upstream counsel legs** (preserved unchanged; §7 confirms §7.1 applies to all service data; §5 leaves upstream compliance to the client).
- **eBay** agreement could not be fetched — `developer.ebay.com/join/api-license-agreement` returned an eBay error/anti-bot page to the authorised server-side fetch (both attempts). The permission request is updated to cite the founder-identified sections **§§3.1, 4.2, 8.1(d), 8.5, 9** by number (verbatim wording to be confirmed from a browser session/paste). 1,992 obs stay NOT_AUTHORISED.
- **Enquiries sent: NONE** — no authenticated send channel (Gmail de-authorised; the Kalodata channel is the founder-accessible Andrew Lin thread). Drafts ready; no fabricated delivery.
- **Kalodata:** Product-Detail entitlement/countries/per-call price/field-population are account-specific → founder confirms via Kalodata, sets a hard $ cap, then a fixed-cap pilot (which is itself the field-population test). No credits bought.
- **Meta GPD.09 (mandatory):** Track A official request + Track B licensed-alternative verification; no vendor selectable without authorised evaluation; stays BLOCKED until authorised evidence is accepted; not deferred.
- **GOLD integrity:** `C2:C23` = **11/22** intact (GPD.02/03/04/05/12/13/14/15/18/20/21); the transient 4/22 was a drop of 7 booleans (C3,C4,C13:C16,C22) restored by the concurrent reconciliation from `LIVE MASTER` + BE279; no broad rewrite. Build Evidence row **BE310**.

---

## Addendum 82 — Correction: two free-assistance counsel enquiries WERE sent (BE311, 2026-11-25)

**Date:** 2026-11-25. **Corrects the earlier "no solicitor enquiries sent" / "approve paid counsel engagement" records.** On 2026-11-25 the founder sent **two free / pro-bono legal-assistance enquiries** via the connected Gmail, both covering the Leg 1 (Google Ads search-volume) and Leg 2 (Google Shopping aggregate) questions:
- **RDJ Startups** — `info.rdj@rdj.ie` — Gmail msg `1a214a31e94464b7` — **sent**; reply **PENDING** (not verifiable this session).
- **UCC IT Law Clinic** — `itlawclinic@ucc.ie` — Gmail msg `1a214a3277b6aae8` — **sent**; reply **PENDING** (not verifiable this session).

**Do not seek a paid engagement or send duplicates while these pend.** I could not read the messages or check replies — **Gmail is de-authorised to this session**; re-authorise it for me to review responses (I will not guess). DataForSEO FAQ §6 already clears the DataForSEO side (no request owed). Kalodata/Meta work continues (prepared, un-sendable this session); eBay clauses remain cited **by number only, not verbatim-verified**, pending the actual text. GOLD **11/22**, revised acceptances, provider rights and release flags unchanged. Full: `docs/GPD01-FINAL-COUNSEL-AND-PROVIDER-DRAFTS.md` Part 3. Build Evidence row **BE311**.

## Addendum 83 — GPD.07 Kalodata controlled Product Detail pilot: 2 genuine chargeable calls, 0.2 credit, verified (BE312, 2026-11-26)

**Date:** 2026-11-26. **Founder authorisation (26 Nov):** max 5 billable Product Detail requests, max 0.5 Kalodata credit, existing credits only; no purchases/upgrades/key regeneration; no automatic customer release or source-rights flag changes. **Andrew Lin written confirmation (26 Nov):** `/openapi/v1/tiktok/product/detail` available on the existing key; GB/DE/IE/IT/US supported; `creator_number`/`video_number`/`live_number` included; 0.1 credit/request; derived attributed social-attention display permitted for paying SaaS customers; no extra licence.

**Executed — the honest verified-mapping subset (DE + US), 2 calls:**
- **DE** product `caa240db-1970-4caf-9db3-8cbe394a6a7a` (Shark BlastBoss), Kalodata id `1729949823689857299` → HTTP 200 **SUCCESS_DETAIL** → `creator_number=109, video_number=220, live_number=124`, region `de`.
- **US** product `7ec7ad53-ea9d-4647-a2b9-762b340778ac` (Insignia 40" F40 TV), Kalodata id `1732780116498617149` → HTTP 200 **SUCCESS_DETAIL** → `creator_number=424, video_number=341, live_number=1223`, region `us`.
- **Only DE + US carry verified `kalodata_product_id` mappings** (DE 23, US 10 products; GB/IE/IT have none). Per the founder's "execute only the subset with verified mappings," no speculative identifiers were used to reach five.

**Spend:** 2 billable calls; `discovery_runs` records 2 runs, each `call_count=1`, `http_status=200` (one provider call each, no duplicate/retry/fan-out); **0.2 credit** consumed (2 × 0.1); **0.3 credit / 3 calls headroom unused**; no purchase/upgrade/key regen. **Balance read: not available** — no deployed `/openapi/v1/credit/balance` broker and the Kalodata secret is not exposed to this session; spend was hard-bounded by the 2-call execution + the edge function's native 402 handling (both calls returned 200, not 402 → sufficient credit) + per-call usage reconciliation. This is a **documented deviation** from the founder's step-1 live-balance request; the STOP-on-balance-failure condition was not triggered (the capability simply isn't deployed).

**Isolation (PASS):** exactly 2 products received fresh detail, both under tenant `7c8ddf9d…`; region tags match market (de/us); the two markets' counts are distinct (no cross-market reuse); RLS/PAL/permissions untouched. **No customer release (PASS):** evidence is REFERENCE_ONLY in `extended.kalodata_detail`; **no frontend consumes it** (grep `kalodata_detail`/`creator_number` = 0 matches); `catalogue_source_rights` KALODATA row unchanged (`updated_at 2026-11-20`); no flag flip, no deploy. Social Product-Detail counts kept **separate** from the prior Product-Rank revenue metrics (no mixing).

**GPD.07 stays OPEN:** remaining = (1) customer-visible display of the three counts behind the rights gate, truthfully labelled "social attention (TikTok), not demand", per-market isolated, with tests (genuine-zero ≠ missing) — **deliberately not built this pilot** (release reserved for escalation); (2) founder acceptance of that display; (3) optional GB/IE/IT breadth once those products carry verified Kalodata ids. **GOLD 11/22 unchanged.** Full report: `docs/GPD07-KALODATA-PRODUCT-DETAIL-PILOT-BE312.md`. Build Evidence row **BE312**.

## Addendum 84 — BE312 follow-up: spend-control exception closed (provider-verified balance), gated GPD.07 display prepared (not released) (BE313, 2026-11-26)

**Date:** 2026-11-26. Closes the BE312 spend-control exception (the founder-required pre-flight live-balance read, which BE312 could not do) and prepares the internal GPD.07 display — **no further paid Kalodata calls** (the unused 3-call / 0.3-credit allowance stays unused).

**T1 — provider-side balance reconciliation (free, read-only).** Deployed a secure, server-side, **read-only** broker `kalodata-credit-balance` (verify_jwt=true; service_role-or-nonce gate; canonical X-API-Key from env, never logged/returned via `redact()`/`safeJson()`; **only** two hard-coded credit endpoints reachable — `GET /openapi/v1/credit/balance`, `POST /openapi/v1/credit/logs` — **no code path to any chargeable endpoint**). Results: **current balance = 13.8 credits** (`totalRemain`/`mainRemain`); the November credit log shows five lifetime `OPEN_API_CALL` −0.1 deductions, of which **exactly two fall in the BE312 window** — `2026-11-26 21:23:50.158Z` (−0.1) and `2026-11-26 21:22:03.941Z` (−0.1) — **aligned to the second** with the two `discovery_runs` (US 21:23:51.307Z, DE 21:22:04.563Z). The other three (20 Nov, 10 Nov, 08 Nov) predate BE312. **BE312 spend = 0.2 credit, provider-confirmed; no discrepancy, no hidden/extra charge; implied pre-BE312 balance 14.0.** Source: `supabase/functions/kalodata-credit-balance/index.ts`.

**T2 — gated internal GPD.07 display (NOT customer-released).** Backend chokepoint: `fn_gpd07_social_attention_display(p_product_id, p_market, p_user_id)` (SECURITY DEFINER; `mig_369` + present-flag fix `mig_369b`) enforces tenant access (auth.uid() pins the caller to their own tenant), the KALODATA `display_derived_cleared` rights gate, **two** country-isolation guards (product's stored market AND the detail's own `product_region` must both equal the requested market — never borrow another market's data), genuine-zero-vs-missing (present numeric incl. 0 ⇒ value+present; absent key ⇒ null+present:false), and honest `UNAVAILABLE_NO_EVIDENCE` for GB/IE/IT; returns no media/images/URLs. Deterministic selftest `fn_gpd07_social_attention_selftest()` = **8/8 PASS** (DE/US availability + exact counts, both isolation guards, GB-unavailable, cross-tenant blocked, zero-vs-missing, rights-blocked — the last two via rolled-back savepoints, so no persisted test data and no flag flip survives; DE data verified intact at 109/220/124, KALODATA flag still TRUE/`updated_at 2026-11-20`). Frontend (Lovable, preview only, **not deployed**): `SocialAttentionPanel` (default-OFF `GPD07_SOCIAL_ATTENTION_RELEASED` flag → renders null and does not fetch) + pure `SocialAttentionPanelView` + typed RPC wrapper + unit test = **5/5 pass**; the panel is referenced **only** in its own files (mounted on no route → doubly non-released). Committed in Lovable `3aae7a7` (2.1 credits); no route/backend/dependency change.

**T3 — acceptance readiness.** **GPD.07 is NOT passed** on two Product Detail responses — the backing social-attention evidence now exists (DE+US) and the gated display is built and tested, but customer-visible release + founder acceptance remain, and **social-attention ≠ search-demand**: the original gate's search-demand and social-demand requirements are assessed separately (GPD.06/search-demand unaffected). Remaining for founder-visible acceptance: (a) founder flips `GPD07_SOCIAL_ATTENTION_RELEASED` to true and mounts `SocialAttentionPanel` on the product-research view (a release decision); (b) production acceptance sighting; (c) optional GB/IE/IT breadth once mapped. **No further Kalodata calls authorised; unused 3-call/0.3-credit allowance preserved.** Controls: 0 new chargeable calls; 0 flag flips (savepoints rolled back); 0 deploys/publishes; RLS/PAL/country-isolation/budgets preserved; **GOLD 11/22 unchanged**. Full report: `docs/GPD07-DISPLAY-AND-BALANCE-RECONCILIATION-BE313.md`. Build Evidence row **BE313**.

## Addendum 85 — GPD.07 founder-only preview connected; inspection path delivered (BE314, 2026-11-26)

**Date:** 2026-11-26. Connects the BE313 gated panel to an **isolated, authenticated, founder-only preview** — **no production deploy, no subscriber release, no paid calls, no rights-flag change.**

**Production preserved:** `strateloq.com` still serves `data-commit-sha=8e6a0f6…` (BE299/BE300 build) — unchanged; the GPD.07 panel is not on production or any subscriber route (no `deploy_project` called). Global `GPD07_SOCIAL_ATTENTION_RELEASED` stays **false**; the preview enables the panel only via an explicit founder-gated route prop.

**Preview route:** new internal `/dev/gpd07-social-attention-preview` (matching the `/dev/*` convention: `ssr:false`, `robots noindex,nofollow`, not in any navigation). Founder-gated via `useSession()` (matches the founder's Supabase auth user id — a UUID constant; the email is **not** embedded). States: loading / sign-in-required (+ link to `/auth`) / "Restricted to the founder account" / founder → the preview. Sections: (A) live genuine observations — Shark BlastBoss·DE and Insignia F40·US (render 109/220/124 and 424/341/1223 via the live RPC on the founder's session); (B) country isolation — the DE product requested as US and GB shows honest UNAVAILABLE with **no borrowed counts**; (C) an explicitly-labelled **illustrative** zero-vs-missing card (not live data). Each panel carries the Kalodata attribution, the last-7-days observation window + acquired timestamp, and the "not verified market demand" label.

**RPC re-confirmed (no raw payload / no other-tenant leak):** the reader returns only a curated projection (3 counts + `*_present` + market + product name + kalodata id + window + acquired-at + label) — **not** the raw `kalodata_detail` (no revenue/shop-id/category/price/image); `user_id = tenant` + `auth.uid()` pin block other tenants; selftest 8/8 (BE313) covers tenant/country/rights/zero-vs-missing enforcement.

**Verification:** `social-attention-panel.test.tsx` **7/7 pass** (adds previewEnabled-on / default-off cases); typecheck passed; the signed-out founder gate rendered via Playwright at 1280px + 375px with **no horizontal overflow** and `noindex`. Scope: only the panel, its test, and the new route file changed (route registry auto-updated); no other route/subscriber page touched. Lovable commit `90f8d752`; **not deployed**.

**Inspection path for the founder:** open the Lovable preview `https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app`, sign in with the founder account if prompted, then go to `/dev/gpd07-social-attention-preview`. (This container's network blocks the lovable.app host, so the public URL could not be loaded from here; verified on the Lovable build server; the authenticated data sighting is intentionally the founder's.)

**GPD.07 acceptance:** **NOT accepted** merely because social metrics display. Social-attention ≠ search-demand (the gate's search-demand signal, GPD.06, is separate and still pending Google-upstream clearance). Remaining: founder release decision (flip the flag + mount on the real research view + deploy) → production acceptance sighting → the gate's own social-demand + search-demand criteria → optional GB/IE/IT breadth once mapped. **GOLD 11/22 unchanged.** Full report: `docs/GPD07-FOUNDER-PREVIEW-BE314.md`. Build Evidence row **BE314**.

## Addendum 86 — GPD.07 social-attention wired into the customer research view behind the release flag; implementation READY (BE315, 2026-11-26)

**Date:** 2026-11-26. BE314 preview founder-accepted (recorded in the Launch Acceptance Decisions tab). This makes the implementation production-ready — **no production deploy, no subscriber release, no rights-flag change, no paid calls; GOLD 11/22 preserved.**

**Wiring (Lovable `be82eeb` + `f33ad85`):** split `social-attention-panel.tsx` into a customer entry point `SocialAttentionPanel({ productId, market })` with **no bypass parameter** (gates only on `GPD07_SOCIAL_ATTENTION_RELEASED`) and a founder-preview-only `SocialAttentionPreviewPanel` (used solely by the `/dev` route) — so the customer path structurally cannot bypass the flag. Mounted the customer panel in **both** `ProductIntelligenceDrawer` layouts (detail + standard), gated on `open && researchProductId && market`, beside `ResearchImagesBlock`; shared by `ecommerce-workspace` and `product-explorer`. Restored a remount `key={productId:market}` on both wrappers so switching products never shows the prior product's counts under a new one (exact-product identity at the display layer) — a test holds the next fetch pending and asserts the old counts vanish during the switch (verified it fails without the key, passes with it). The RPC remains the authoritative rights/tenant/country gate for both paths.

**Verification:** `social-attention-panel.test.tsx` 8/8 + `product-intelligence.social-attention.test.tsx` 2/2 (asserts the drawer issues **no** social-data request and hides the panel in both layouts while the flag is off) + drawer regression suites **19/19**; project typecheck passed. Release flag **false**; not deployed. No unresolved defects.

**Final acceptance separation:** (A) social-attention implementation = **READY** (awaiting only a founder release decision); (B) GPD.07 original search-and-social-demand requirements = **NOT met** (social-attention ≠ verified demand); (C) GPD.01/06 Google-upstream legal dependency = **unresolved** (counsel pending; gates search-demand display, independent of the already-cleared Kalodata display); (D) GB/IE/IT breadth = optional, needs founder-budgeted ingest. **Original GPD.07 GOLD stays OPEN;** GOLD 11/22 unchanged.

**Exact production release change proposed (separate founder-authorised action, NOT performed):** set `GPD07_SOCIAL_ATTENTION_RELEASED = true` in `src/lib/gpd07/release-flag.ts`, then `deploy_project` to publish. No backend or rights-flag change needed. After release each authenticated subscriber sees the panel only for their own products with Kalodata detail in the selected market (currently only the founder tenant's 2 products carry detail); all else shows honest UNAVAILABLE. **Release candidate: READY for the implementation; original GPD.07 acceptance BLOCKED on B and C.** Full report: `docs/GPD07-PRODUCTION-READINESS-BE315.md`. Build Evidence row **BE315**.

## Addendum 87 — Product Research UI redesign to the founder-chosen "Design 2" (BE316, 2026-11-26, preview; visual acceptance pending)

**Date:** 2026-11-26. Founder selected **Design 2** of three Product-Research mockups (a third-party dropship.it dashboard used as a **visual-style reference only** — its demo numbers were NOT copied). Confirmed scope: build from the written requirements 1–10 in that style; **restyle the existing drawer in place**; **Lovable preview only** — no production deploy, no subscriber release, no rights-flag change, no paid calls; GOLD 11/22 unchanged.

**Implemented (Lovable `6ff369d`; files: styles.css, top-nav.tsx, product-intelligence.tsx, product-explorer.tsx, AGENTS.md):** light/white workspace background + dark-navy top nav (scoped `.workspace-nav-navy` token layer) + purple primary / teal secondary, via the design-token system (the portalled detail Sheet now carries the light `workspace-design-3` scope). Product header = REFERENCE image prominent beside title/category/market/identity (image-rights gating + "No reference image" fallback preserved). "Compare countries" + "Save" = high-contrast rounded purple pills on their existing authorised handlers; NO new Export/Refresh/Scan/supplier-verification/paid-refresh/fake actions. Six compact Design-2 stat cards (Opportunity stage, Evidence families, Freshness, Evaluation date, Price from REAL values with honest Unknown/Unavailable; Commercial rights = "Not verified" honestly — the detail contract has no rights field). Four tabs (Overview, Evidence, Market Intelligence, Supplier Match; purple active underline) reorganising the existing sections (inactive panels stay mounted+hidden so every gated section keeps its data source + empty/UNKNOWN state). Only chart = an evidence-coverage ring built from the product's REAL evidence-family states (no fabricated market-share/sales-trend). Two inner sections renamed to avoid tab-name clash (Overview→Opportunity summary, Evidence→Evidence families).

**Preserved:** no invented metrics/suppliers/prices/evidence/scores; real images + rights restrictions; country-isolated intelligence; authenticated access, tenant isolation, RLS, Product Asset Lock, source-rights gates; founder-only store/ad controls; the BE314 founder-only `/dev` social-attention preview; the customer `SocialAttentionPanel` stays gated (`GPD07_SOCIAL_ATTENTION_RELEASED` still false); withheld Meta/eBay/DataForSEO keep DISPLAY_PENDING_RIGHTS / NOT_AUTHORISED.

**Tests:** requested product-research regression **35/35**; **full suite 1,091/1,091**; typecheck pass; build pass. **Not deployed.** Preview: `https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app` → sign in → /workspace → Products → open a product. **Unresolved for the founder's visual acceptance:** commercial-rights card always "Not verified" (needs a rights field wired in to show a real status); pixel-fidelity to the mockup (built from the written spec, not the image); the workspace overview page left as-is per scope; the chrome applies app-wide (confirm or narrow). **Await founder visual acceptance before production deployment.** GOLD 11/22 unchanged. Full report: `docs/PRODUCT-RESEARCH-DESIGN2-REDESIGN-BE316.md`. Build Evidence row **BE316**.

## Addendum 88 — Design 2 finishing/polish pass + founder visual-acceptance handoff; READY (BE317, 2026-11-26)

**Date:** 2026-11-26. Founder clarified **"Design 2" = the second of the three Strateloq mockups** (the dropship.it screenshot was a competitor example only — not reproduced). Authoritative reference = the founder's **written approved direction**. Preview only; no deploy, no rights-flag change, no paid calls; GOLD 11/22 unchanged.

**Self-reviewed with real screenshots:** the `/dev/product-intelligence` fixture harness renders the real drawer without auth, so the build agent captured Playwright screenshots at 1280px + 375px, found genuine issues and **fixed them** (Lovable `f06d035`): removed the competitor-style evidence donut/ring (real evidence data stays in the Evidence tab); reflowed the compact cards with container queries (1→2→3→6 columns, even heights, labels on their own line — fixing pre-fix one-letter truncation / mid-word breaks); registered the missing `--color-teal*` tokens so the teal accent chips render; 44px tabs with focus-visible; left-aligned mobile header; no horizontal overflow; keyboard-reachable "?" tooltips. **Commercial-rights card:** confirmed no authoritative per-product commercial-rights field exists (contract carries media display-rights only — "research display, never commercial rights"), so it keeps "Not verified" + the exact honest tooltip; no provider→product promotion, no score, no flag change. **Chrome regression check:** `/dev/market-explorer` clean. **GPD.07 preserved:** flag false, customer panel gated, `/dev` preview + remount isolation intact.

**Honest limits:** the product-image header + Compare/Save pills are absent from the fixture, so they weren't screenshotted (they appear on the authenticated page, styled as purple pills on the existing Compare-Countries link + Save toggle); and the captured screenshots live in the build sandbox and can't be surfaced into chat (preview host blocked + auth) — the founder does the authoritative visual acceptance in the live preview. **Tests:** product-research regression 35/35; typecheck pass; full suite not re-run (no change required it). **Production unchanged** (`strateloq.com` still `8e6a0f6`). **Verdict: READY FOR FOUNDER VISUAL ACCEPTANCE** (design direction approved only — not production-approved; do not request release authorisation until the founder inspects the live interface). Preview: `https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app` → sign in → /workspace → Products → open a product. GOLD 11/22 unchanged. Full report: `docs/PRODUCT-RESEARCH-DESIGN2-POLISH-BE317.md`. Build Evidence row **BE317**.

## Addendum 89 — Workspace Overview redesign to the founder-chosen "Option 2" (BE318, 2026-11-26, preview; visual acceptance pending)

**Date:** 2026-11-26. Founder selected **Option 2** (premium light) of three Strateloq Workspace-Overview mockups — deep-purple gradient sidebar, clean light top bar, white content, violet primary, cyan/teal secondary, compact cards. Scope = the Workspace Overview (the approved Product Research Design 2 was left untouched). Preview only; no deploy, no rights-flag change, no paid calls, no subscriber-feature activation; GOLD 11/22 unchanged.

**Implemented (Lovable `0f27681`, reuse-first, no backend change; files: ecommerce-workspace.tsx, ecommerce-workspace.golden-hub.test.tsx, refresh-discovery-modal.tsx, workspace-sections.tsx, app-sidebar.tsx, mobile-nav.tsx, top-nav.tsx, styles.css, workspace.tsx, routeTree.gen.ts, new dev.workspace-overview.tsx, roadmap.md):** deep-purple gradient sidebar (all nav items/routes/gating kept) + clean light top bar; header with the real business name + the existing Analyse/Refresh actions (Refresh keeps its gating, no paid bypass); Country Performance card (real Discovered count + dropdown) + five compact lifecycle metric cards (Emerging/Research Priority/Supplier Qualified/Supplier Resolved/Commercially Validated) from real counts; restyled Closest-to-Qualification rows, Needs-Attention empty state, Business Profile, and the lower destination cards; responsive (sidebar→drawer on mobile), keyboard-accessible.

**Data integrity verified:** NO growth % and NO trend/bar chart reproduced — the overview shows "Trend unavailable — no 30-day history is available"; counts are from existing queries; unknowns read "Not available yet"; nothing invented. **Platform rules preserved:** founder-only My Store/My Campaigns + creation/publishing + media/PAL gating unchanged (not exposed to subscribers); country isolation, tenant isolation + RLS, provider rights + customer-display restrictions intact; Product Research Design 2 source untouched; GPD07_SOCIAL_ATTENTION_RELEASED still false (customer panel gated; remount isolation passed); GPD.09 requirement unchanged.

**Self-review + tests:** a no-auth `/dev/workspace-overview` fixture harness (noindex, not in nav, golden-hub fixture — no real data/actions) was added for Playwright screenshots at 1280px + 375px (purple sidebar, light top bar, violet actions, white cards, teal; clean mobile stacking; no overflow; no runtime errors); review fixes applied. Tests: 10 ecommerce + 29 Product-Research/GPD.07 regressions = **39 passed**; typecheck + diff-validation + preview build pass. **Honest limits:** signed-in `/workspace` not agent-verifiable (no app session in the sandbox) → founder does the live visual acceptance; the fixture had no qualification products so populated thumbnail rows weren't visually exercised; screenshots can't be surfaced into chat. **Production unchanged** (`strateloq.com` still `8e6a0f6`; nothing deployed). **Verdict: READY FOR FOUNDER VISUAL ACCEPTANCE** (direction only; not production-approved). Preview: `https://id-preview--12db6c84-161b-4c23-aac4-e19e8cd24ab1.lovable.app` → sign in → Overview. GOLD 11/22 unchanged. Full report: `docs/WORKSPACE-OVERVIEW-OPTION2-REDESIGN-BE318.md`. Build Evidence row **BE318**.

## Addendum 90 — Controlled production UI deployment of BE317 (Design 2) + BE318 (Option 2): DEPLOYED AND VERIFIED (BE319, 2026-11-27)

**Date:** 2026-11-27. Founder authorised one controlled **UI-only** production deployment of the two visually-accepted redesigns (not GPD.07, not any gated feature). **Deployment `a6097aab-4314-4c45-bf61-42d0eadd5ca1`; released commit `0f27681`; previous baseline / rollback `8e6a0f6`; live-confirmed 10:49:01 UTC.**

**Pre-deploy checks (all passed):** baseline 8e6a0f6 → candidate 0f27681; delta 8e6a0f6→0f27681 = 22 frontend/docs files (UI redesigns + gated-OFF GPD.07 panel + two internal noindex `/dev` harnesses + tests + a Lovable build-config devDep bump) with NO Supabase migration/backend/rights/budget changes; `GPD07_SOCIAL_ATTENTION_RELEASED = false`; founder-only/RLS/PAL/country-isolation/founding-member preserved; `/dev` routes safe (gpd07 founder-gated; workspace-overview fixtures + review-only; both show no other-tenant data / no privileged actions); full suite **1,092/1,092** at HEAD + typecheck green at this commit + green Lovable preview build; rollback = redeploy 8e6a0f6.

**Deployed** via deploy_project (no GPD.07 activation; no Meta/eBay/DataForSEO enablement; no paid calls/credit purchases). **Post-deploy VERIFIED:** `strateloq.com` serves `0f27681`; live bundles contain Option-2 markers ("Your Strateloq intelligence", "Trend unavailable", "Closest to Qualification", "Needs Attention", "Commercially Validated") and Design-2 markers ("Opportunity summary", "Evidence families", "Market Intelligence", "Supplier Match"); the GPD.07 panel ships but is gated OFF (flag false → customer panel returns null before any fetch → hidden, no requests); restricted source data withheld; founder-only gating unchanged. **Signed-in interactive runtime (Save/Unsave, country selector, saved products, founder-only menus, in-app console) is the founder's sighting** — a production session cannot be minted here (as with BE299/BE300). No material regression → no rollback. **Verdict: DEPLOYED AND VERIFIED.** GOLD 11/22 unchanged. Full report: `docs/PRODUCTION-UI-DEPLOYMENT-BE319.md`. Build Evidence row **BE319**.

## Addendum 91 — GPD.09 Meta/TikTok competitor-advertiser intelligence: provider-independent progress + rights-gate regression proof (BE320, 2026-11-27)

**Date:** 2026-11-27. Founder prioritised GPD.09 (a mandatory commercial-launch requirement) for **maximum safe, verifiable, provider-independent progress with NO licensed commercial data and NO extra API cost**; GPD.09 **stays OPEN** pending a provider's written *analyse* rights (external).

**Finding — infrastructure already exists and is rights-correct.** Ad observations live in `commerce_signals` (`ADVERTISING_ACTIVITY`/`META_AD_LIBRARY`; `SOCIAL_VIDEO_ADVERTISING`/TikTok), each with provenance/relevance/evidence. The gated reader `fn_product_ad_evidence` enforces the **BE264 rights gate**: META + TIKTOK `analyse_cleared=false` ⇒ `coverage_state='NOT_AUTHORISED'`, advertiser/creative counts **NULL**, cannot drive the verdict; raw retained for audit. Per-country coverage via `fn_meta_ad_library_market_state`: **GB/DE/IE/IT → AVAILABLE, US → SOURCE_UNSUPPORTED** (Meta commercial all-ads archive = EU/EEA + UK only; US political-only — not assumed to have unrestricted US commercial coverage).

**Safe work delivered.** New deterministic selftest **`fn_product_ad_evidence_selftest()` → 16/16 PASS** on **real seeded fixtures + pure-logic classifier units**, with **no rights-flag change** (never turns NOT_AUTHORISED into evidence). Proven: unauthenticated / product_not_found / cross_tenant_rejected gates; META+TIKTOK withheld (null counts) **even when `attempt_state=SEARCHED_EVIDENCE_FOUND`**; totals+verdict withheld; ADVERTISER≠SELLER (`observed_sellers` null); per-country `market_state` differentiation (US SOURCE_UNSUPPORTED vs DE AVAILABLE); **US raw obs withheld AND never classifiable OBSERVED** (classifier returns SOURCE_UNSUPPORTED even for a count of 17); advertiser **dedup** (DE 47 raw rows → 16 distinct advertisers); **country isolation / no borrowing** (DE 16, GB 6, empty JP 0); honest **UNKNOWN ≠ zero-competition**. No regression: `fn_product_competitor_evidence_selftest()` 6/6.

**Component status:** storage / reader / coverage-gating / dedup / tenant+country isolation / honest states / **regression selftest = DONE**; live *authorised* commercial advertiser counts = **BLOCKED (external licensed-provider analyse rights)**; US commercial-ad coverage = **BLOCKED (Meta Ad Library structurally cannot serve US commercial all-ads)**; customer display = **NOT STARTED (gated; separate founder release decision)**.

**Exact written rights required:** (a) provider **ANALYSE** rights → sets `catalogue_source_rights.analyse_cleared=true` and alone flips the reader from NOT_AUTHORISED to live, country-scoped, deduped counts; (b) display/redistribution rights only if counts are shown to customers (`display_derived_cleared` / `commercial_redistribution_cleared`). Adyntel + Adflex enquiries already sent, no reply — **not duplicated**.

**Controls:** 0 paid calls; 0 credits; no deploy; no new ingestion; no display-rights flag change; no GPD.07 activation; RLS / PAL / country+tenant isolation / provider permissions preserved. **GPD.09 remains OPEN.** GOLD 11/22 unchanged. Files: `supabase/migrations/mig_370_gpd09_ad_evidence_selftest.sql` (new), `docs/GPD09-META-ADVERTISER-INTELLIGENCE-BE320.md`. Build Evidence row **BE320**.

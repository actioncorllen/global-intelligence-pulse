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

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

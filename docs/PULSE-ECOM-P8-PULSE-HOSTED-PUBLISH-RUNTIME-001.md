# PULSE-ECOM-P8-PULSE-HOSTED-PUBLISH-RUNTIME-001

**STATUS: PASS (internal publication runtime complete; anonymous public HTTP endpoint deploy is the one
founder-gated step, intentionally not taken).** The Pulse-hosted publishing path is now real:
**APPROVED → publish (re-gated) → PUBLISHED → stable destination URL → public-safe renderer → Ad Studio
destination handoff**. The founder acceptance product (dash cam × US, page `ae458526-…`) was published through
the runtime with all launch-critical gates re-run and passing, a secret-stripped public renderer, explicit
`CHECKOUT_NOT_CONFIGURED`, and Ad Studio addressability with a non-null destination URL. Classification
preserved (WPS 79 / STRONG_TEST / QUALIFIED_TEST_NOT_HIGH_CONFIDENCE — **not** upgraded). No Shopify, no
campaign, **$0 spend**, no Nitro polling, no schedule changes.

## Audit
- **Exists / production-capable:** `commerce_product_pages` + `commerce_store_projects` (slug, public_route,
  settings), the runtime from P8-STOREFRONT-RUNTIME-INTEGRATION (gate, selection, asset resolver, generator,
  state machine, ad addressability), `fn_generate_page_copy` claim-safe copy, `fn_cb_validate_destination`.
- **Fixture/dev-only:** the `/preview/<project_id>` route from `fn_create_pulse_store_draft` (noindex,
  tenant_only) and the `/dev/storefront` design factory (Lovable). The new runtime does **not** depend on the
  fixture.
- **Routing/domain today:** drafts have `public_route=NULL`; the generic transition-to-PUBLISHED set a
  preview-style URL. No public renderer, no custom domain, no anonymous storefront endpoint.
- **Checkout:** intentionally unavailable — page CTA is non-functional (`CHECKOUT_HANDLED_BY_DESTINATION_STORE`);
  Pulse-hosted has no payment provider.
- **Missing (built here):** public-safe renderer data contract, a re-gated publish operation minting a stable
  destination URL, explicit checkout state, and the public HTTP serving layer (founder-gated).
- **Security today:** tenant RLS `select_own` + `service_all`; runtime functions locked to authenticated/
  service_role (anon revoked in prior unit).

## Reuse
`fn_storefront_test_eligibility`, `fn_resolve_storefront_assets`, `fn_storefront_transition_state`,
`fn_storefront_ad_addressable`, `commerce_product_pages`/`commerce_store_projects`, page_model claim-safe copy,
currency provenance, tenant guard. No new storefront system created.

## Implementation (mig_230, additive)
- **`fn_public_storefront_render(slug)`** — public renderer **data contract**, allowlist-only (never dumps
  page_model/runtime_contract wholesale). Returns publishable data **only for PUBLISHED** pages; `NOT_FOUND`
  for drafts/unknown/other. Consumes the universal contract: template_family/version, market, currency,
  economics-safe **offer (price only)**, sections (structure only), supplier assets (image URLs), claim-safe
  copy, product provenance. service_role/authenticated only (the public serving layer calls it server-side;
  anon has no direct DB access).
- **`fn_storefront_publish(page_id, gate_inputs, actor)`** — requires **APPROVED**, re-runs TEST eligibility +
  claim safety + asset safety + destination validation (**fail closed** on any), then sets
  `publication_state=PUBLISHED` and mints a **stable destination URL**. Tenant-guarded.
- **`fn_storefront_publish_selftest()`** — 9-case regression (self-cleaning).

## Public rendering architecture
`GET storefront/<slug>` (future edge function) → `fn_public_storefront_render(slug)` [service_role] →
public-safe JSON → thin HTML/JSON view. The renderer is the single source of publishable data; it enforces
published-only + secret-stripping in the database, so no serving layer can leak internals. The **anonymous
edge endpoint is not deployed** (founder-gated public exposure).

## Publication state / page ID / destination URL
- **page ID:** `ae458526-3fd2-47e0-a613-3da7b7f92f11` · product `66b60d77-…` · US.
- **review_state:** PUBLISHED · **publication_state:** PUBLISHED.
- **destination URL (stable, reserved):** `https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/storefront/pae4585263fd2`
- **public_endpoint_state:** `PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT` (URL live once the founder-approved
  edge endpoint is deployed; the renderer + data are ready now).

## Checkout state
**`CHECKOUT_NOT_CONFIGURED`** · dependency **`BLOCKED_EXTERNAL_CHECKOUT_PROVIDER`** (no payment/checkout
provider connected). CTA non-functional; **no fabricated checkout**.

## Claim safety
Re-checked at publish (`claim_scan_clean=true`, fail-closed). Renderer output verified honest: dash cam
described Front 1080P / Inner 480P / Rear 480P, no GPS, no Wi-Fi; delivery labelled an estimate ("not
guarantees"); no reviews/ratings/sales/scarcity/discount/guarantee/2K-4K/GPS/Wi-Fi/WINNER claims.

## Asset safety
Re-resolved at publish → **ASSETS_AVAILABLE**, 8 rights-clear SOURCE supplier images, 0 rejected. Renderer
exposes image URLs only. Reference-only/Nitro assets can never resolve (proven in prior unit + resolver logic).

## Tenant / security results
- Public renderer returns publishable data **only for PUBLISHED** pages; **NOT_FOUND** for a draft, an unknown
  slug, and (by publication gate) any unpublished/other-tenant page.
- **Secret-stripping verified** on the real published page: output contains no landed/supplier_cost/economics
  internals, no CJ PID/token, no WPS/decision_classification, no user_id (`no_secrets_leaked=true`).
- Publish + admin ops tenant-guarded: cross-tenant publish → `DENIED_CROSS_TENANT` (tested).
- Advisor: renderer/publish functions locked to service_role/authenticated (anon revoked); no new anon
  SECURITY-DEFINER exposure.

## Ad Studio addressability
`addressable=true`, **`destination_url` = the published stable URL (non-null)**, product_id + US market + offer
version resolvable. `campaign_created=false`, `campaign_activation=false`, `advertising_spend_authorized=0`,
`advertising_spend=0`. Existing paused Meta campaign untouched.

## Tests
- Storefront runtime self-test: **38/38 PASS** (no regression).
- Publish/renderer self-test: **9/9 PASS** — publish-requires-APPROVED, cross-tenant denied, fail-closed on bad
  gate, publish OK + stable URL, checkout-not-configured, renderer OK for published, renderer NOT_FOUND for
  draft + unknown slug, renderer secret-stripping.
- One in-scope defect fixed (FIX→TEST→CONTINUE): selftest slug variable/column ambiguity → qualified.

## External API calls
**0** (no CJ/eBay/DataForSEO/Meta). Supabase: 1 migration + reads + the acceptance publish (row updates).

## Schedules inspected / recurring created / cadence changes
Inspected: YES. **New recurring schedules: 0. Cadence changes: 0.** Monday orchestrator + FX daily untouched.

## Cost
**€0.** No purchases (product/sample/inventory/subscription/supplier service). No ad spend.

## Safety flags
`campaign_created=false` · `campaign_activation=false` · `advertising_spend_authorized=0` ·
`advertising_spend=0`. Paused Meta untouched. Nitro × US remains PENDING_EXTERNAL_CJ_SOURCING — not polled, no
new request, no sourcing-reference image used.

## Git
- commit: see below (mig_230 + this report).
- push: `claude/pulse-crash-recovery-b6ngey`.
- divergence: 0 0.

## Progress
Store/Product Page **~96%** (publish runtime + public-safe renderer + stable URL + checkout state done;
remaining: the founder-approved anonymous public HTTP endpoint + a checkout provider). Real Ecommerce E2E
**~68%** (opportunity→decision→gate→storefront→DRAFT→APPROVED→PUBLISHED→renderer→ad-addressable proven on a
real product; live public serving + checkout still pending). Overall paid-beta readiness **~93%**.

## Remaining blockers
1. **Public HTTP endpoint (founder-gated):** deploy the read-only `storefront` edge function that serves
   `fn_public_storefront_render` — the one action that exposes a public internet URL (held for founder
   approval per the guardrail). 2. **`CHECKOUT_NOT_CONFIGURED`:** `BLOCKED_EXTERNAL_CHECKOUT_PROVIDER` — a
   payment/checkout provider must be connected. 3. Custom domain (optional; not provisioned).

## Recommended next launch-critical unit
**`PULSE-ECOM-P8-PULSE-HOSTED-PUBLIC-ENDPOINT-DEPLOY-001`** (founder-approval unit) — with explicit founder
authorization to expose a public internet URL, deploy the read-only, noindex `storefront` edge function that
serves `fn_public_storefront_render`, making the reserved destination URL live for the dash-cam acceptance
product. It performs the single external/irreversible step this unit intentionally deferred; still no checkout,
no campaign, no spend. (Checkout provider connection can follow as a separate unit.)

STOP / WAIT FOR FOUNDER APPROVAL — including for the deferred public-endpoint deployment.

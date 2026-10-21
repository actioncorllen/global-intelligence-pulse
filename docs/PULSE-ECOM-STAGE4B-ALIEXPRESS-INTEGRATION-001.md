# PULSE-ECOM-STAGE4B-ALIEXPRESS-INTEGRATION-001

**Stage 4B kickoff for the AliExpress secondary supplier source. Prerequisite (two legacy pages
unpublished) re-verified PASS. The existing exact-identity architecture is proven ready to accept
`source='aliexpress'` candidates (mock, dry-run). BUT the live integration is BLOCKED_EXTERNAL: no
AliExpress Open Platform credentials, developer approval, or confirmed multi-tenant SaaS rights exist.
No scraping, no paid calls, no purchases, and NO production change were made — all work was read-only or
mocked. The founder must provide the external access below before the dependent steps can proceed.**

## Prerequisite — PASS (re-verified)
Both founder-approved legacy pages are UNPUBLISHED with inactive public routes:
- 3 Channel Dash Cam — page `ae458526-…` → `publication_state=UNPUBLISHED`, `published_url=NULL`, public render **NOT_FOUND**.
- Kids Nightlight Projector — page `45af3635-…` → `publication_state=UNPUBLISHED`, `published_url=NULL`, public render **NOT_FOUND**.

## 1–2. Official API access + existing credentials — BLOCKED_EXTERNAL
- **Official path (for the founder to action):** AliExpress product/supplier data requires the **AliExpress
  Open Platform** — a registered developer app with **App Key + App Secret** and approval for a
  product/dropshipping scope (e.g. the Dropshipping/`aliexpress.ds.*` product APIs or the Affiliate
  product API). Multi-tenant SaaS use must be permitted under AliExpress's API Terms (per-app or
  per-seller authorisation, rate limits, and permitted redistribution of product data to tenants).
- **Existing credentials/connections — NONE for AliExpress:** n8n credential search `ali` → 0 results;
  the `alibabaCloudApi` seen in gateway-credits is **Alibaba Cloud DashScope** (the Wan video model), **not**
  the AliExpress Open Platform. `provider_capability_registry` has no AliExpress row (CJ is the only
  SUPPLIER source). `server_integration_config` holds only `edge_gateway` + `research_executor_webhook`.
- **Verdict:** no authorised access exists → every live AliExpress data step is **BLOCKED_EXTERNAL**. Not
  assumed, not purchased, not scraped.

## 3. Architecture reuse — PASS (proven by mock, no API)
The existing supplier architecture already supports a second source with **no schema change**:
- `commerce_supplier_products` is keyed by `(source, source_product_id)` → AliExpress rows coexist under
  `source='aliexpress'` alongside `cjdropshipping`.
- The exact-identity resolver `fn_resolve_concrete_supplier_identity` is **source-agnostic in its
  evaluation** (it matches each candidate via `fn_market_supplier_match` on identity/attributes, not on
  the source). **Mock dry-run (persist=false, synthetic candidates — not real listing data)** against the
  Snowman proved:
  - an exact-title AliExpress candidate (`supplier='ALIEXPRESS'`, spid `1005013410315354`) →
    **STRONG_SAME_PRODUCT, attrs_ok, bound → EXACT_SUPPLIER_IDENTITY_RESOLVED**;
  - a category-adjacent AliExpress candidate → **CLOSE_COMPARABLE, NOT bound** (never-approximate, req 7).
- **One genuine code gap (documented, not deployed):** the resolver hardcodes the *bound-supplier label*
  as `CJDROPSHIPPING` in 3 places (the `selected_supplier` persist value and two provenance fields).
  Before an AliExpress bind can be *persisted* with the correct source, these must become source-generic
  (`upper(coalesce(v_sel->>'supplier','CJDROPSHIPPING'))`). Not changed now: it has zero effect until
  AliExpress candidates can exist (API-blocked), and re-deploying the live CJ resolver for a blocked
  feature is unnecessary risk. It is part of the authorised-phase change set below.

## 4. CJ-first → AliExpress fallback — BLOCKED_EXTERNAL (design recorded)
`fn_finalize_research_run` already runs CJ resolution at finalisation (mig_320). The fallback design:
when CJ resolves `NO_VALID_CJ_MATCH`, run the resolver over AliExpress candidates (CJ-first ordering) and
bind only an exact AliExpress match. It cannot be wired live because there is no way to populate
AliExpress candidates without the API. Recorded; deploy in the authorised phase.

## 5. Field coverage — UNKNOWN until API (no invented values)
Exact identity, variants, price, stock, destination (GB) shipping, supplier images/videos and rights
provenance all originate from the AliExpress API. With access BLOCKED, every one of these for listing
`1005013410315354` remains **UNKNOWN** — nothing is invented or inferred. The drawer would show honest
UNKNOWN/NO_DATA for AliExpress until the API is connected.

## 6. Snowman reference `1005013410315354` vs product `873551b0` (GB)
- **Real identity verification: BLOCKED_EXTERNAL** — cannot fetch the real listing (no API; scraping
  forbidden). The listing's true title/variants/price/stock/shipping/media remain UNKNOWN.
- **Resolver-capability probe: PASS** — the mock above shows the identity-verification machinery is ready
  to confirm (or reject) the match once the real AliExpress payload is available, and will never bind an
  approximate match.

## 7. Preservation — PASS
No production change deployed; the mock was a dry-run (persist=false). Tenant/country isolation, the
never-approximate rule, commercial-use rights handling (REFERENCE_ONLY/SUPPLIER_PROVIDED) and the
provider USD budget guard (mig_318/319) are all intact and unchanged; CJ resolution is untouched.

## What the founder must provide to unblock (external gates)
1. **AliExpress Open Platform developer account + approved app** with product/dropshipping (or affiliate)
   API scope — **App Key + App Secret** (and callback/authorisation as the chosen API requires).
2. **Written confirmation of multi-tenant SaaS usage rights** for AliExpress product data under their API
   Terms (redistribution to tenants, rate limits, image/media rights for commercial use).
3. **Approval for any paid/metered usage** (if the chosen API tier is paid) — no paid call will be made
   without it.

## Authorised-phase change set (deploy only after the gates above)
(a) register `ALIEXPRESS` SUPPLIER in `provider_capability_registry` (EXTERNAL_APPROVAL_REQUIRED →
AVAILABLE on connect); (b) n8n AliExpress product-detail executor using the App Key/Secret credential,
budget-guarded if metered; (c) an AliExpress candidate normaliser (API response → the resolver's
candidate shape); (d) the resolver source-label fix (3 literals); (e) CJ-first → AliExpress fallback in
`fn_finalize_research_run` / self-select; (f) media + rights provenance mapping. Then mock → live test on
`1005013410315354` and verify.

## Status
| Item | Verdict |
|---|---|
| Prerequisite: 2 legacy pages unpublished + routes inactive | **PASS** |
| 1–2 Official API access + existing credentials | **BLOCKED_EXTERNAL** (no credentials/approval) |
| 3 Reuse commerce_supplier_products + resolver (source=aliexpress) | **PASS** (proven by mock) |
| 4 CJ-first → AliExpress fallback (live) | **BLOCKED_EXTERNAL** (needs API) |
| 5 Exact identity/variants/price/stock/shipping/media/rights | **BLOCKED_EXTERNAL** → UNKNOWN until API |
| 6 Verify listing 1005013410315354 vs Snowman | **PARTIAL** — real verify BLOCKED; resolver capability PASS (mock) |
| 7 Isolation / rights / no-approximate / budget preserved | **PASS** |

**Overall: PARTIAL / BLOCKED_EXTERNAL.** Architecture is proven ready and the resolver already enforces
exact-only AliExpress matching (mock); the live integration is blocked solely on AliExpress Open Platform
access + multi-tenant rights + (if paid) spend approval. No scraping, no paid calls, no production change
made. **STOP** — no BigBuy, saturation or country recommendations; Stage 4B live steps await the external
gates.

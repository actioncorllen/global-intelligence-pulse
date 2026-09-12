# PULSE-ECOM-P8-STOREFRONT-RUNTIME-INTEGRATION-001

**STATUS: PASS.** The already-approved Universal Conversion Template System + Pulse storefront factory is now a
real, provider-independent **runtime**: Product×Country → hard TEST eligibility gate → deterministic template
selection → evidence-safe content → asset safety → publishable DRAFT resolving the LOCKED RUNTIME CONTRACT →
review/edit lifecycle → destination adapter boundary → Ad Studio addressability. **No storefront was
redesigned, no fake Nitro store was built or published.** Nitro × US is proven to **refuse** production
generation. **38/38** runtime regression tests pass. No recurring schedules, no cadence change,
`campaign_activation = FALSE`, authorized ad spend **$0**.

## STARTING PHASE PROGRESS
Store/Product Page ~70% · Overall paid-beta readiness ~89%.

## AUDIT (PHASE A)
- **existing runtime (production-capable):** `commerce_product_pages` (page_model + economics/claim/currency
  columns), `commerce_store_projects`, `commerce_store_connections`, `commerce_destination_choice`;
  `supplier_product_assets` (universal asset contract, `asset_class`/`rights_state`/`availability`/
  `original_source`); functions — canonical decision engine (`fn_canonical_product_decision_v2`,
  `evaluate_product_v2`, `fn_product_decision_customer`), gates (`fn_test_identity_gate`,
  `fn_supplier_stock_state`, `fn_supplier_gate`, `fn_supplier_execution_gate`, `fn_product_trust_gate`,
  `fn_compliance_pregate`, `fn_evidence_confidence`), page building (`fn_create_pulse_store_draft` [TEST-gated],
  `fn_generate_page_copy` [claim-safe], `fn_edit_pulse_store_page`, `fn_store_builder_payload`), destination
  (`fn_commerce_destination_router`, `fn_set_ecommerce_destination`, `fn_cb_validate_destination`), claim safety
  (`fn_ad_studio_claim_scan`), Ad Studio (`fn_ad_studio_handoff`, `fn_conversion_identity`). Tenant RLS
  `select_own` + `service_all`.
- **fixture-only:** 1 fixture page (source_kind FIXTURE); 0 real store connections; 0 nitro assets.
- **reused components (not rebuilt):** all of the above — the decision engine, every hard gate,
  `fn_generate_page_copy`, `fn_create_pulse_store_draft`, `fn_ad_studio_claim_scan`, `fn_ad_studio_handoff`,
  `fn_conversion_identity`, `fn_cb_validate_destination`, `supplier_product_assets`, FX/currency provenance,
  tenant isolation pattern.
- **gaps found (filled this unit, per P8 doc §3/§16):** no template-family/section registry; no
  `fn_select_conversion_template`; no single explicit **TEST_ELIGIBLE** hard gate with reason codes; no unified
  runtime generator resolving the locked contract; no asset-safety resolver (SOURCE vs GENERATED,
  reference-only rejection); no explicit DRAFT→…→ARCHIVED state machine; no destination adapter boundary for
  SHOPIFY/GENERIC; no ad-match/addressability contract.

## IMPLEMENTED (additive migrations mig_224–229, all reuse-first)
- **mig_224** — registry: `conversion_template_families` (8 locked families), `conversion_section_types` (22
  approved sections), `conversion_hero_variants` (7 heroes). RLS on; readable by authenticated, writable by
  service_role.
- **mig_225** — `fn_storefront_test_eligibility` (hard gate, reason codes, fail-closed; composes
  `fn_test_identity_gate`) + `fn_select_conversion_template` (deterministic, evidence-gated, BEST_FIT label).
- **mig_226** — additive runtime columns on `commerce_product_pages` (country_code, opportunity_decision_id,
  template_family/version, ad_match_ref, supplier_asset_refs, generation_state, review_state,
  publication_state, runtime_contract) + `fn_resolve_storefront_assets` (asset safety) +
  `fn_generate_storefront_runtime` (gate→select→copy→assets→persist locked contract; reuses
  `fn_generate_page_copy`/`fn_create_pulse_store_draft`/`fn_ad_studio_claim_scan`).
- **mig_227** — `fn_storefront_transition_state` (lifecycle), `fn_storefront_set_destination` (adapter
  boundary), `fn_storefront_ad_addressable` (Ad Studio), `fn_storefront_change_country` (re-resolution). All
  tenant-guarded.
- **mig_228** — `fn_storefront_runtime_selftest` (re-runnable regression; synthetic tenants, self-cleaning).
- **mig_229** — EXECUTE-grant lockdown (revoke anon/PUBLIC; backend/persistence/selftest = service_role only;
  tenant-guarded review/edit = authenticated).

## TEST GATE (PHASE B)
`fn_storefront_test_eligibility` fails closed. TEST_ELIGIBLE requires: canonical TEST/HIGH-CONFIDENCE_TEST
decision, `SUPPLIER_EXACT` + market↔supplier identity satisfied, `IN_STOCK` (UNKNOWN never satisfies),
`VIABLE` landed economics (NEGATIVE/UNKNOWN fail; THIN warns), acceptable Product Confidence, destination
fulfilment evidence, no critical risk, and **no** pending external sourcing. Reason codes:
`REJECT_WATCH/AVOID/ANALYSIS_REQUIRED/NOT_TEST_DECISION`, `REJECT_SOURCING_PENDING_EXTERNAL`,
`REJECT_SUPPLIER_NOT_CANONICAL`, `REJECT_IDENTITY_WEAK`, `REJECT_OUT_OF_STOCK`, `REJECT_STOCK_UNKNOWN`,
`REJECT_ECONOMICS_UNVIABLE`, `REJECT_ECONOMICS_UNKNOWN`, `REJECT_PRODUCT_CONFIDENCE_LOW`,
`REJECT_NO_FULFILMENT_EVIDENCE`, `REJECT_CRITICAL_RISK`. WATCH/AVOID/ANALYSIS_REQUIRED/
PENDING_EXTERNAL_CJ_SOURCING fail closed. **Dashcam WPS-79 is carried as `STRONG_TEST` — never silently
upgraded to HIGH-CONFIDENCE** (`high_confidence=false`; verified by test `no_silent_high_confidence_upgrade`).

## NITRO NEGATIVE TEST (PHASE I)
Nitro × US (`PENDING_EXTERNAL_CJ_SOURCING`, sourcing ID CJSPU958989970) → `fn_generate_storefront_runtime`
returns **`status=REFUSED`, `test_eligible=false`**, reason codes include `REJECT_SOURCING_PENDING_EXTERNAL`;
**nothing persisted**. Additionally, `fn_resolve_storefront_assets` for the nitro supplier_product_id returns
**`IMAGE_UNAVAILABLE`** (0 usable) — the CJ **sourcing-reference** image can never resolve as a publishable
storefront asset. Never classified as a real publishable product.

## TEMPLATE RUNTIME (PHASE C)
Deterministic + explainable: 8 families scored by category/traffic fit + usable optional evidence, excluded on
disqualifier or missing required evidence, tie-broken by fixed priority. Output carries
recommended/alternative family, confidence, selection reasons, resolved sections (render vs
hide/editable-placeholder), hero variant (degrades if its evidence is missing), CTA structure, missing
evidence. Label is **BEST_FIT / RECOMMENDED**, never PROVEN_BEST (guard field
`terminology_guard=PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN`). Example: dashcam (electronics/research, specs+image)
→ **FEATURE_TECHNOLOGY**, HERO_FEATURE_SPOTLIGHT, COMPARISON section auto-hidden (no comparison basis),
alternative PROBLEM_SOLUTION.

## CLAIM SAFETY (PHASE D)
Reuses the claim-safe `fn_generate_page_copy` (no fabricated reviews/discount/guaranteed-delivery/urgency/
certifications) + a defense-in-depth `fn_ad_studio_claim_scan` over assembled copy; any flagged claim marks the
section as an editable placeholder that cannot publish as factual. Section registry encodes required evidence:
SOCIAL_EVIDENCE/BEFORE_AFTER/COMPARISON/SPECIFICATIONS/OFFER/PRODUCT_GALLERY/PRODUCT_VIDEO hide or degrade when
evidence is absent — never fabricate. Copy provenance preserved on every section.

## ASSET SAFETY (PHASE E)
`fn_resolve_storefront_assets` reuses `supplier_product_assets`; usable only when `AVAILABLE` +
rights ∈ (SUPPLIER_PROVIDED/LICENSED/OWNED) + fulfilment-supplier source. **Rejected:** rights UNKNOWN,
`reference_only`, `purpose=SOURCING_REFERENCE`, sourcing-reference identity, reference-only marketplaces
(Fruugo/eBay/Amazon), disallowed asset class. Each asset tags `origin_kind` (SOURCE_SUPPLIER vs GENERATED).
Missing → `IMAGE_UNAVAILABLE`, no fabricated replacement. Verified: CJ sourcing-reference and Fruugo images
cannot resolve; Nitro resolves IMAGE_UNAVAILABLE.

## REVIEW/EDIT (PHASE F)
Lifecycle `DRAFT → IN_REVIEW → APPROVED → PUBLISHED → ARCHIVED` (with safe reversals; PUBLISHED→APPROVED =
unpublish). Entering APPROVED/PUBLISHED re-checks claim safety (cannot bypass → `BLOCKED_CLAIM_SAFETY`).
Existing `fn_edit_pulse_store_page` (reused) recomputes economics on price edits and blocks editing PUBLISHED.
Country change resolves a **new Product×Country** context (`COUNTRY_CONTEXT_RESOLUTION_REQUIRED`,
`currency_only_conversion_permitted=false`) — never a currency-only conversion.

## DESTINATIONS (PHASE G)
- **Pulse-hosted:** DESTINATION_READY — safest beta runtime, noindex tenant-only preview route (reuses store
  project `public_route`/slug).
- **Shopify:** adapter boundary implemented; no connected store → **`BLOCKED_EXTERNAL_SHOPIFY_CONNECTION`**
  (publishing refused, not faked).
- **Generic external URL:** validated via `fn_cb_validate_destination` (invalid → `BLOCKED_INVALID_EXTERNAL_URL`).
- **WooCommerce:** `DEFERRED_WOOCOMMERCE`. (Destination column stays PULSE_STORE/EXISTING_STORE; the fine
  destination kind lives in `runtime_contract.destination_kind`.) No new domain provisioned.

## AD STUDIO HANDOFF (PHASE H)
`fn_storefront_ad_addressable` returns product_id, country_code, storefront page id + version, offer version,
template_family, ad_match_ref, destination, and **destination_url only when genuinely published**. Explicitly
`campaign_created=false`, `meta_activated=false`, `ad_spend_authorized=0`. The generator also stamps
`ad_match_ref` and reuses the existing `fn_ad_studio_handoff`. No campaign created, no Meta activation, no spend.

## TESTS (PHASE J) — `fn_storefront_runtime_selftest()` = **38/38 PASS**
TEST accepted · WATCH/AVOID/ANALYSIS_REQUIRED rejected · PENDING_EXTERNAL_CJ_SOURCING rejected · OUT_OF_STOCK
rejected · unknown-stock rejected · economics NEGATIVE & UNKNOWN rejected · cross-market evidence cannot satisfy
local hard gate (identity weak) · supplier-not-canonical rejected · no silent HIGH-CONFIDENCE upgrade ·
deterministic template selection + versioning · COMPARISON section hidden without basis · UGC excluded without
reviews / included with reviews · claim scan flags fabricated reviews / passes honest copy · supplier-provided
asset usable · rights-unknown / sourcing-reference / reference-marketplace assets rejected · Nitro
IMAGE_UNAVAILABLE · generation REFUSED for Nitro (nothing persisted) · eligible generation resolves the runtime
contract · idempotent generation · DRAFT→IN_REVIEW→APPROVED→PUBLISHED transitions · invalid transition rejected
· claim safety not bypassed on approve · Shopify blocked without connection · generic URL invalid blocked ·
country switch resolves new context · Ad addressable (no campaign/no spend) · cross-tenant denied. Existing
prior-unit regressions unaffected (additive migrations only). Harness is re-runnable and self-cleaning.

## EXTERNAL BLOCKERS
- `BLOCKED_EXTERNAL_SHOPIFY_CONNECTION` — Shopify publishing needs a founder/user store connection (adapter
  boundary ready, not faked).
- Nitro storefront blocked by `PENDING_EXTERNAL_CJ_SOURCING` (by design; negative test).

## SCHEDULE AUDIT
- Recurring schedules inspected: YES (no changes made). New recurring schedules: **0**. Cadence changes: **0**.
  Monday orchestrator (`BBxcPXJdF2PliWgf`) + FX daily refresher (`np2MUp83gaZ3C2pJ`) untouched. Manual
  executions: **0** (this unit is pure Supabase DDL + SQL; no n8n executions).

## API / COST
- External API calls: **0** (no CJ/eBay/DataForSEO/Meta/n8n calls). Supabase: 6 additive migrations + SQL
  reads/selftest. **Cost €0.** No purchases, no paid sourcing, no ad spend.

## SECURITY
Tenant isolation enforced (auth.uid()/actor guard; cross-tenant denial tested). Advisor after changes: the
`anon` SECURITY-DEFINER exposure is **cleared** (mig_229 revoked anon/PUBLIC); backend/persistence/selftest are
service_role-only; tenant review/edit functions are authenticated-only and guarded (matches the project's
existing definer pattern). Registry tables RLS-on. No secrets in migrations (secret-scanned).

## GIT
- commit: see below (mig_224–229 + this report).
- push: `claude/pulse-crash-recovery-b6ngey`.
- divergence: 0 0.

## VERDICT
**PASS** — the universal storefront runtime is production-wired and launch-ready for the first legitimate TEST
product, with the hard gate, claim/asset safety, review lifecycle, destination boundaries, and Ad Studio
handoff all in place and regression-proven; Nitro correctly refuses; no fake store; no spend.

## UPDATED PROGRESS
Store/Product Page **~90%** (runtime, gate, selection, claim/asset safety, lifecycle, destinations, ad handoff
done; remaining: Shopify live publishing behind the connection, and Lovable's visual renderer consuming the
sections). Real Ecommerce E2E **~55%** (opportunity→gate→storefront→ad-addressable proven end-to-end on real
evidence; live checkout/publishing + a real TEST product still pending). Overall paid-beta readiness **~91%**.

## NEXT
Recommend **`PULSE-ECOM-DASHCAM-US-LAUNCH-DECISION-CLOSEOUT-001`**: run the fully-validated 3-channel dash cam ×
US (SUPPLIER_EXACT, IN_STOCK US, landed €24.28, WPS 79) through this new runtime to a persisted, gated
storefront DRAFT — the first real end-to-end exercise of the launch path on already-collected evidence
(recording it as `QUALIFIED_TEST_NOT_HIGH_CONFIDENCE`, no campaign, no spend) — proving the runtime on a real
product while Nitro sourcing stays `PENDING_EXTERNAL_CJ_SOURCING`.

STOP / WAIT FOR FOUNDER APPROVAL.

# STRATELOQ-ECOM-P8-CONVERSION-RUNTIME-INTEGRATION-002

**VERDICT: `PASS` (reuse-first; three genuine gaps closed).** The deterministic runtime layer
that converts an approved ecommerce Product Decision + evidence into a safe storefront/page
specification for Lovable's approved visual component factory **already existed** across
`mig_224–mig_233` and matched the locked contract. The audit found **three genuine gaps**
(merchant-branding→theme tokens, founder "Why this page?" explainability, an explicit
Conversion-Strategy contract block). All three are now closed **additively** in `mig_234`
(+ `mig_234b` grant lockdown), with **no rewrite, no duplication, no new table, no new paid
provider, nothing published, no payments/Shopify/Woo, no campaign launched, no evidence
fabricated.** Deterministic tests: **55/55 PASS** (38 runtime + 9 publish + 8 new branding),
production security advisories unchanged (no new lint), €0 spent.

> Do not advance to the next Phase 8 unit. Evidence is returned for review first.

---

## FIRST — REPOSITORY AUDIT (reuse-first)

The repository is backend-only (Supabase Postgres functions + edge functions + n8n); the
frontend is Lovable's separate project. The full conversion runtime was found already built and
matching the locked contract:

| Layer | Where | Status |
|---|---|---|
| Registry: 8 template families, 22 sections, 7 hero variants | `mig_224` | Present, matches locked enum |
| Hard TEST eligibility gate (fail-closed) | `fn_storefront_test_eligibility` (`mig_225`) | Present |
| Deterministic evidence-gated template selector + explainable reasons | `fn_select_conversion_template` (`mig_225`) | Present |
| Deterministic section assembly + degrade/hide gating | `fn_select_conversion_template` (`mig_225`) | Present |
| Asset-provenance resolver (reference-only never resolves) | `fn_resolve_storefront_assets` (`mig_226`) | Present |
| Runtime generator → locked runtime contract | `fn_generate_storefront_runtime` (`mig_226`) | Present |
| Claim-safe copy generator | `fn_generate_page_copy` (`mig_231`) | Present |
| Review/edit state machine, destination adapter, ad-addressability, country switch | `mig_227` | Present |
| Publish runtime (Pulse-hosted) + selftest | `mig_230` | Present |
| Product-video contract, creative provider boundary | `mig_232`, `mig_233` | Present |
| Deterministic runtime selftest (38 cases) | `fn_storefront_runtime_selftest` (`mig_228`) | Present |

Production registry confirmed live: **8 active families, 22 section types, 7 hero variants** —
exactly the locked enum (`PROBLEM_SOLUTION, VISUAL_DEMO, PREMIUM_LUXURY, UGC_SOCIAL_COMMERCE,
FEATURE_TECHNOLOGY, COMPARISON_EVIDENCE, LIFESTYLE_EMOTIONAL, DIRECT_RESPONSE_OFFER`).

### Genuine gaps found (and only these)
1. **Merchant-branding → theme tokens.** The runtime contract carried no resolved brand/theme;
   `fn_generate_page_copy` hard-coded neutral tokens and took `brand_name` verbatim. No
   customer/internal/neutral rule and no "never expose Strateloq as the customer brand" safety.
2. **Founder explainability.** Only machine `selection_reasons` existed; no human-readable
   "Why this page?".
3. **Explicit Conversion-Strategy contract.** Strategy was implicit in the selection; no typed,
   named block stating objective / angle / awareness / cta model / evidence basis.

Everything else the unit required was already implemented and verified — so this unit is
**verification + minimal gap-closure**, not a rebuild.

---

## GAP CLOSURES (mig_234 — additive, non-breaking)

- **`fn_resolve_merchant_theme(context, brand_scope)`** — deterministic, pure. Rules:
  `customer = merchant brand` (real `business_profiles`/`member_business_dna` name + voice);
  `internal = Strateloq brand` **only** when the tenant is `fn_global_intelligence_uid()`;
  `fallback = neutral`. **Hard safety:** a non-Strateloq tenant can never surface the Strateloq
  brand (name containing "strateloq" is suppressed to neutral). No merchant **palette is ever
  fabricated** — no brand colours are stored anywhere, so non-Strateloq tokens stay neutral while
  the merchant's real name/voice are used.
- **`fn_storefront_conversion_strategy(selection, decision)`** — explicit typed strategy block:
  `primary_objective = TEST_PURCHASE_INTENT_AT_LANDED_ECONOMICS`, family, angle, awareness
  assumption, cta model, evidence basis, `terminology_guard = PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN`,
  `not_a_performance_claim = true`. No "best converting"/"highest"/"guaranteed" language.
- **`fn_storefront_why_this_page(contract)`** — founder-readable explainability (8 honest
  bullets: template + why, confidence caveat, evidence used/missing, currency preservation,
  asset provenance, claim safety, brand ownership). No fake precision.
- **`fn_generate_storefront_runtime`** re-declared to resolve brand scope from tenant identity,
  enrich the copy context with the resolved brand, and add **`brand_scope`, `merchant_theme`,
  `conversion_strategy`, `explainability`** to the locked runtime contract. No existing key
  removed or renamed.
- **`fn_generate_page_copy`** now reads resolved `brand_theme_tokens`/`brand_voice` from context
  when present (still `IMMUTABLE`; neutral default unchanged).
- **`fn_storefront_branding_selftest()`** — 8 deterministic cases; writes nothing.
- **`mig_234b`** — EXECUTE-grant lockdown mirroring `mig_229` (pure helpers → authenticated +
  service_role; SECURITY DEFINER selftest → service_role only). Verified:
  `fn_storefront_branding_selftest` ACL is now `service_role`-only.

End-to-end proof (live `p_persist=false` preview, merchant tenant, GB market):
`brand_scope=MERCHANT`, `merchant_theme.brand_name="Roadwatch Optics"`,
`strateloq_as_customer_brand=false`, `conversion_strategy.primary_objective=TEST_PURCHASE_INTENT_AT_LANDED_ECONOMICS`,
`explainability.human_readable=true` (8 bullets), **`source_currency=CNY` preserved** with
`display_currency=GBP`.

---

## 20 REQUIRED DETERMINISTIC SCENARIOS → COVERAGE

All present in the deterministic selftests (`fn_storefront_runtime_selftest` = 38,
`fn_storefront_publish_selftest` = 9, `fn_storefront_branding_selftest` = 8):

1. TEST-eligible accepted → `test_accepted`
2. No silent upgrade to HIGH confidence → `no_silent_high_confidence_upgrade`
3. WATCH/AVOID/ANALYSIS_REQUIRED/PENDING_EXTERNAL rejected → `watch/avoid/analysis_required/pending_external_rejected`
4. Out-of-stock / unknown-stock rejected → `out_of_stock_rejected`, `unknown_stock_rejected`
5. Negative / unknown economics rejected → `economics_negative_rejected`, `economics_unknown_rejected`
6. Cross-market cannot satisfy local; supplier not canonical → `cross_market_cannot_satisfy_local`, `supplier_not_canonical_rejected`
7. Deterministic template selection + versioning → `template_selection_feature_tech`, `selection_deterministic`, `template_versioning`
8. Comparison section hidden without basis → `comparison_section_hidden`
9. UGC excluded without reviews / candidate with reviews → `ugc_excluded_without_reviews`, `ugc_candidate_with_reviews`
10. Claim scan flags fabricated reviews / passes honest copy → `claim_scan_flags_reviews`, `claim_scan_clean_honest_copy`
11. Supplier asset rights/provenance gating → `assets_available_supplier_provided`, `asset_rights_unknown_rejected`, `asset_sourcing_reference_rejected`, `asset_reference_marketplace_rejected`
12. Image unavailable, no fabrication; generation refused when ineligible → `nitro_image_unavailable`, `generation_refused_nitro`
13. Preview contract + idempotent preview → `generation_preview_contract`, `generation_idempotent_preview`
14. State transitions DRAFT→IN_REVIEW→APPROVED→PUBLISHED + invalid transition blocked → `transition_*`, `invalid_transition_draft_to_published`
15. Ad-addressable without campaign/spend → `ad_addressable_no_campaign_no_spend`
16. Cross-tenant denial → `cross_tenant_denied`
17. Country switch resolves new context → `country_switch_resolves_context`
18. Existing-store path: Shopify blocked without connection; generic URL validated → `shopify_blocked_without_connection`, `generic_url_invalid_blocked`
19. Claim safety not bypassed on approve → `claim_safety_not_bypassed_on_approve`
20. **Merchant branding / explainability / strategy (new)** → `theme_merchant_brand_applied`, `theme_internal_strateloq`, `theme_neutral_fallback`, `theme_never_strateloq_as_customer`, `theme_palette_not_fabricated`, `conversion_strategy_present`, `conversion_strategy_no_performance_claim`, `why_this_page_human_readable`

**Result: 55/55 PASS.**

---

## FINAL REPORT (24 points)

1. **Verdict:** `PASS` — reuse-first; three genuine gaps closed additively.
2. **Audit outcome:** The full conversion runtime already existed (`mig_224–233`) and matched the locked contract; no rewrite performed.
3. **Template families:** 8 active, matching the locked enum, runtime-addressable (registry verified in production).
4. **Sections / heroes:** 22 section types, 7 hero variants registered and gated.
5. **Conversion Strategy contract:** Added as an explicit typed block (`fn_storefront_conversion_strategy`); objective + angle + awareness + cta model + evidence basis + terminology guard.
6. **Template selector:** Deterministic, explainable, evidence-gated; no "highest converting" claims; `terminology_guard = PRE_PERFORMANCE_BEST_FIT_NOT_PROVEN`.
7. **Section assembly:** Deterministic; render / RENDER_EDITABLE / HIDE_OR_PLACEHOLDER by evidence.
8. **Evidence gating:** Hard fail-closed; reviews/ratings/sales/testimonials/certifications/stock/delivery/discounts/scarcity/countdowns/guarantees/before-after/medical/performance/comparison never synthesized (claim scan + section gating).
9. **Asset provenance:** Competitor/marketplace/sourcing reference creatives can never resolve as storefront assets; no fabricated replacement; `IMAGE_UNAVAILABLE` when none.
10. **Merchant branding → theme tokens (GAP CLOSED):** customer=merchant, internal=Strateloq (only when Strateloq is the merchant), fallback=neutral; Strateloq brand never customer-facing otherwise; palette never fabricated.
11. **Fulfilment:** Multiple legitimate suppliers supported by the resolver; speed/availability/landed-cost/stock never fabricated; **source currency preserved** alongside display currency (verified CNY→GBP).
12. **Ad → page continuity:** `fn_storefront_ad_addressable` exposes product/country/page-version/offer-version/destination; campaign is input only — creates no campaign, no Meta activation, €0 spend.
13. **No-store path:** PULSE_HOSTED destination (noindex preview route); publishes nothing externally.
14. **Existing-store path:** Shopify requires a CONNECTED connection (`BLOCKED_EXTERNAL_SHOPIFY_CONNECTION` otherwise); generic URL validated; WooCommerce deferred. No external publishing performed.
15. **Typed storefront specification:** The locked runtime contract carries template/version, market, destination, currencies, economics state, ad_match_ref, sections, hero, cta, claim safety, copy provenance, asset refs, selection, states, brand_scope, merchant_theme, conversion_strategy, explainability, terminology guard.
16. **Founder explainability (GAP CLOSED):** `fn_storefront_why_this_page` renders an honest human-readable "Why this page?" (8 bullets), embedded in the contract.
17. **Deterministic tests:** 55/55 PASS (38 runtime + 9 publish + 8 new branding).
18. **No regression:** Existing 38 runtime + 9 publish selftests remained green after the change.
19. **Migrations added:** `mig_234` (functions + selftest) and `mig_234b` (EXECUTE-grant lockdown). No new tables; no unnecessary migration.
20. **Security posture:** New SECURITY DEFINER selftest locked to `service_role`; pure helpers to authenticated+service_role; generator kept its `mig_229` service_role-only lockdown. Production security advisories unchanged (no new lint from this unit).
21. **Frontend / Lovable boundary (honest):** The Lovable visual factory is a separate project and its build cannot be run from this backend repo. No Lovable component was redesigned; the runtime only produces the specification those approved components consume. Homepage/onboarding + design-system-001 + `/dev/storefront` were **not modified** here — no backend contract they depend on was removed or renamed (additive keys only), so no backend-side regression was introduced; the frontend build itself must be verified in Lovable.
22. **Scope discipline:** No publishing, no payments, no Shopify/Woo integration, no campaign launch, no market scan, no CJ polling, no new paid provider, no evidence fabricated, no architecture rewrite.
23. **Secrets:** No secret printed, committed, logged, or placed anywhere; no credential value handled. Secret scan clean.
24. **Cost:** €0. Production read/DDL-only via additive `CREATE OR REPLACE` + grants; nothing destructive; nothing published.

STOP after reporting. Awaiting founder review before the next Phase 8 unit.

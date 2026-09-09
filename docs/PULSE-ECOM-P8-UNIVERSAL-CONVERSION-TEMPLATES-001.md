# PULSE-ECOM-P8-UNIVERSAL-CONVERSION-TEMPLATES-001 — Audit + Design Contract

**Type:** AUDIT + CONTRACT (no visual build, no migrations applied, no product invented).
**Verdict:** PASS (contract complete; implementation deferred to post-visual-approval units).

---

## 1. Phase-8 audit

Existing (Supabase, project nxaunmyihhjixxxljcqt):
- **Tables:** `commerce_product_pages` (page_model jsonb, market, destination, store_connection_id,
  decision_classification, page_model, status, published_url, claim_safety, provenance, source_kind,
  product_ref, selling_price, display_currency, source_currency, landed_cost_display, economics_state),
  `commerce_store_projects` (slug, public_route, project_state, settings), `commerce_store_connections`
  (provider, store_domain, connection_state, secret_ref, granted_scopes).
- **Functions:** `fn_build_product_page_model`, `fn_generate_page_copy`, `fn_create_pulse_store_draft`,
  `fn_edit_pulse_store_page`, `fn_store_builder_payload`, `fn_commerce_destination_router`,
  `fn_set_ecommerce_destination`, `fn_cb_validate_destination`, `fn_stamp_commerce_visibility`.
- **page_model today** is a single implicit template (≈PROBLEM_SOLUTION): hero, problem_solution,
  benefits, how_it_works, trust, faq, shipping, price, cta, assets, seo, brand, positioning,
  announcement — with `claim_safety` + `copy_provenance` (evidence safety already enforced).
- 1 fixture page (READY_FOR_REVIEW, PULSE_STORE, source_kind FIXTURE); 0 real store connections.

## 2. Components reused
- Dual-path destination routing (`fn_commerce_destination_router`, `fn_set_ecommerce_destination`,
  `fn_cb_validate_destination`).
- Page persistence + draft/edit (`commerce_product_pages`, `fn_create_pulse_store_draft`,
  `fn_edit_pulse_store_page`, `fn_store_builder_payload`).
- Claim-safety + copy provenance (`claim_safety`, `copy_provenance`, `fn_ad_studio_claim_scan`).
- Currency/market split (selling_price/display_currency/source_currency/economics_state + global FX).
- Ad Studio handoff (`fn_ad_studio_campaign_handoff`), conversion identity (`fn_conversion_identity`,
  `fn_decorate_url`), Phase 13 tracking, Phase 14/15 performance + learning.

## 3. Gaps (to be filled AFTER visual approval)
- No template-family taxonomy; page_model is one implicit layout.
- No typed section registry (sections are ad-hoc jsonb keys, no order/visibility/variant/role contract).
- No `fn_select_conversion_template` (family selection).
- No persisted ad→page message-match record.
- No template_family/version/section-composition dimensions on performance snapshots for learning.
- No Shopify section adapter (only Pulse-store path is exercised).

## 4. Universal page model (provider-independent)
A page = ordered list of typed **sections** + page meta. Proposed canonical shape (assembled at
runtime, persisted in `page_model`):
```
page := {
  template_family, template_version, market, destination ('EXISTING_STORE'|'PULSE_STORE'),
  currency:{display,source}, economics_state, ad_match_ref,
  sections: [ Section... ], claim_safety, copy_provenance, provenance
}
Section := {
  type,                 -- from the section registry (§5)
  order:int, visible:bool, conversion_role,
  variant,              -- style hint (Lovable owns visuals)
  content:jsonb,        -- text/fields, evidence-gated
  assets:[asset_ref],   -- rights-checked media (Phase 10)
  provenance:{source_class, evidence_quality},
  mobile:{sticky?, collapse?, priority}
}
```

## 5. Reusable section registry (types)
HERO, PRODUCT_GALLERY, PRODUCT_VIDEO, PROBLEM, SOLUTION, BENEFITS, FEATURE_GRID, HOW_IT_WORKS,
VISUAL_DEMO, BEFORE_AFTER, SPECIFICATIONS, COMPARISON, SOCIAL_EVIDENCE, OFFER, PRICE, VARIANTS,
SHIPPING, RETURNS, TRUST, FAQ, STICKY_ADD_TO_CART, FINAL_CTA.
Every section carries order, visibility, variant/style, content, assets, provenance, mobile behavior,
conversion_role. No page requires all sections. A section whose evidence is unavailable **hides or
degrades** (§8) — never fabricates.

## 6. Eight template-family contracts
For each: primary use case · suitable categories · traffic-source fit · required · optional ·
ordering strategy · hero · media · CTA · mobile · evidence requirements · disqualifiers.

1. **PROBLEM_SOLUTION** — pain-led problem solvers. Categories: health-adjacent gadgets, home fixes,
   organization. Traffic: interest/problem-aware social. Required: HERO, PROBLEM, SOLUTION, BENEFITS,
   HOW_IT_WORKS, PRICE, FINAL_CTA. Optional: FAQ, TRUST, SHIPPING, SOCIAL_EVIDENCE. Hero: problem
   framing. Media: demonstrative. CTA: solution-oriented. Evidence: problem must be legitimate; no
   medical claims. Disqualifier: product with no articulable problem.
2. **VISUAL_DEMO** — "show it working" products. Categories: gadgets, tools, cleaning, kitchen.
   Traffic: video social (TikTok/Reels). Required: HERO(video), VISUAL_DEMO, HOW_IT_WORKS, BENEFITS,
   PRICE, STICKY_ADD_TO_CART, FINAL_CTA. Optional: BEFORE_AFTER (only if genuine), FAQ. Media: video-first.
   Disqualifier: no usable demo asset.
3. **PREMIUM_LUXURY** — design/quality-led. Categories: home decor, accessories, premium goods.
   Traffic: aspirational/brand. Required: HERO(lifestyle), PRODUCT_GALLERY, BENEFITS, SPECIFICATIONS,
   TRUST, PRICE, FINAL_CTA. Optional: RETURNS, SOCIAL_EVIDENCE. CTA: understated. Disqualifier: low-cost
   commodity with no premium substantiation.
4. **UGC_SOCIAL_COMMERCE** — creator/authentic proof. Categories: broad consumer. Traffic: UGC creative.
   Required: HERO(UGC), SOCIAL_EVIDENCE, BENEFITS, HOW_IT_WORKS, PRICE, FINAL_CTA. **SOCIAL_EVIDENCE only
   renders with real, rights-cleared UGC** — otherwise family is disqualified or degrades to VISUAL_DEMO.
   Disqualifier: no legitimate social proof/UGC assets.
5. **FEATURE_TECHNOLOGY** — spec/innovation-led. Categories: electronics, tech accessories. Traffic:
   research/intent. Required: HERO, FEATURE_GRID, SPECIFICATIONS, HOW_IT_WORKS, BENEFITS, PRICE, FAQ,
   FINAL_CTA. Optional: COMPARISON. Disqualifier: unknown specs.
6. **COMPARISON_EVIDENCE** — "why this vs alternatives". Categories: considered purchases. Traffic:
   comparison/intent. Required: HERO, COMPARISON, BENEFITS, SPECIFICATIONS, TRUST, PRICE, FINAL_CTA.
   **COMPARISON must use factual, non-deceptive claims only**; no fabricated competitor data. Disqualifier:
   no legitimate comparison basis.
7. **LIFESTYLE_EMOTIONAL** — identity/feeling-led. Categories: apparel, lifestyle, gifting. Traffic:
   discovery social. Required: HERO(lifestyle), PRODUCT_GALLERY, BENEFITS, OFFER, PRICE, FINAL_CTA.
   Optional: SOCIAL_EVIDENCE, RETURNS. Disqualifier: purely functional product with no emotional angle.
8. **DIRECT_RESPONSE_OFFER** — offer/urgency-led (legitimate only). Categories: impulse, bundles.
   Traffic: cold direct-response. Required: HERO, OFFER, BENEFITS, PRICE, TRUST, STICKY_ADD_TO_CART,
   FINAL_CTA. **Scarcity/discount/urgency render ONLY when the offer is genuine** (real stock, real
   discount); otherwise those elements hide. Disqualifier: no legitimate offer.

## 7. Template-selection contract (`fn_select_conversion_template`, future)
**Inputs:** product_intelligence, category, market, audience, buyer_pain, buyer_intent,
creative_strategy(angle/hook), campaign_platform, traffic_source, available_assets, offer,
price/economics, evidence(social/spec/comparison availability), supplier/fulfilment_state.
**Output:** recommended_template_family, alternative_template_family, confidence,
selection_reasons[], required_sections[], optional_sections[], excluded_sections[],
missing_evidence[], recommended_section_order[]. Pre-real-performance the label is **BEST_FIT /
RECOMMENDED**, never PROVEN_BEST / "highest converting". Selection is deterministic + evidence-gated:
a family is excluded when its disqualifier holds or its required evidence is missing.

## 8. Evidence safety rules
The engine MUST NEVER fabricate reviews, testimonials, star ratings, sales counts, stock, delivery
time, discounts, guarantees, before/after claims, certifications, medical claims, or supplier
reliability. Each section declares required evidence; when unavailable it **hides**, **degrades to a
legitimate alternative**, or renders a neutral variant. UNKNOWN stays UNKNOWN. All rendered claims
pass `fn_ad_studio_claim_scan`; provenance/source_class travels with every section.

## 9. Ad→page message-match contract
Persist `ad_match_ref`: campaign → creative → angle → hook → audience → offer → landing HERO →
sections. The HERO and lead sections must preserve the ad's promise/angle **without inventing claims
the product evidence does not support**. Mismatch (page cannot honor the ad promise legitimately) is
surfaced as a selection warning, not silently patched.

## 10. Existing-store pathway (EXISTING_STORE)
Shopify/other connected users: Pulse page model → **provider section adapter** (Shopify) that maps
canonical sections to the store's theme sections/metafields. Pulse never forces Shopify users onto
Pulse hosting; the adapter writes to the merchant's store via their connection (`secret_ref`, scopes).

## 11. Pulse-store pathway (PULSE_STORE)
No-store users: Pulse page model → **Pulse-hosted runtime renderer** (existing renderer path,
`commerce_store_projects.public_route`). Lovable designs the visual system; **Lovable is NOT the
runtime renderer** — it produces the design system the Pulse renderer implements.

## 12. Mobile-first contract (mandatory acceptance)
Responsive hero + media, readable typography, touch-safe controls, sticky CTA where appropriate,
mobile variant selection, fast/lazy asset loading, **no horizontal overflow**, accessible interaction
(focus/contrast/labels), checkout handoff intact, analytics/conversion hooks fire on mobile. Every
section carries `mobile` behavior (sticky/collapse/priority).

## 13. Performance Learning integration (reuse Phase 14/15)
Extend `campaign_performance_snapshots` provenance (and learning references) with **template_family,
template_version, section_composition, section_ordering, hero_variant, cta_variant** so Phase 15 can
learn: product_type + market + audience + traffic_source + template + composition → observed
performance. Tenant isolation mandatory; no cross-tenant private performance leakage (existing RLS +
definer pattern). Pre-real-evidence, template performance stays BEST_FIT, never PROVEN.

## 14. Lovable responsibility
Visual design system, responsive layouts, component presentation, spacing, typography, motion,
image/video presentation, premium ecommerce appearance, mobile presentation, accessibility
presentation — for each section type and each family.

## 15. Claude/backend responsibility
Data contracts, section registry, template selection, evidence rules, runtime assembly, persistence,
provider adapters (Shopify/Pulse renderer), analytics/tracking hooks, performance-learning wiring,
security/tenant isolation.

## 16. Migrations / schema changes required (design only — NOT applied here)
- `conversion_template_families` (8 rows: family, use_case, required/optional/excluded section rules,
  hero/media/CTA/mobile strategy, evidence_requirements, disqualifiers, version).
- `conversion_section_types` (registry: type, default conversion_role, required_evidence, mobile defaults).
- Extend `commerce_product_pages.page_model` to the typed `sections[]` shape (+ template_family,
  template_version, ad_match_ref) — additive/back-compatible.
- `page_ad_match` (or `ad_match_ref` column) persisting the campaign→page promise chain.
- `fn_select_conversion_template(...)` + `fn_assemble_page(...)` (runtime assembly) contracts.
- Performance snapshot/learning provenance fields (template_family/version/composition/hero/cta).
All additive; no destructive change to Phase 8; RLS-on, tenant-scoped.

## 17. Implementation units required AFTER visual approval
1. Section registry + template-family tables + seed (contract → data).
2. `fn_select_conversion_template` (evidence-gated selection).
3. Typed page-model migration + `fn_assemble_page` runtime assembly.
4. Ad→page message-match persistence + mismatch surfacing.
5. Shopify section adapter (EXISTING_STORE) + Pulse renderer sections (PULSE_STORE) — implement Lovable's system.
6. Mobile acceptance test harness.
7. Performance-learning template dimensions wiring (Phase 14/15 extension).

## 18. Blockers
None to this contract. Downstream real-store acceptance still gated by prior external blockers
(BLOCKED_EXTERNAL_CHECKOUT_SOURCE, browser Pixel live pairing, Meta Insights permission) and by
Lovable visual approval before implementation begins.

## 19. External cost
€/$0. No purchases, no schedules, no activation, no spend. Existing campaign/supplier strategy unchanged.

## 20. Phase-8 revised completion %
~45% → dual-path routing, persistence, single-template page model, evidence safety, copy provenance
exist and work; the universal template-family taxonomy, section registry, selection engine, typed
assembly, ad-match persistence, Shopify section adapter, and learning dimensions remain (contracted
here, implemented after visual approval).

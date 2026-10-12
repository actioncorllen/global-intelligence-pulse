# STAGE 1 — Evidence Enrichment + Product Family Normalization + Stage-Boundary Separation

**Date:** 2026-10-12 · **Project:** nxaunmyihhjixxxljcqt (live prod) · **Branch:** claude/cool-faraday-kgudh1
**Scope:** Fix why real product-native candidates produce sparse downstream evidence. No gate weakened. Stage 2 NOT started.

## 1. Root cause(s)
- **Research query identity (primary):** `fn_research_request_core` used the raw provider title as the search query for every source. Product-native titles are long, local-language marketing sentences (e.g. "1PC erweiterbares Mikrowellen-Lagerhalter mit 6 Haken, Küchenzähler-Organizer, …"), so DataForSEO/eBay/Meta/Reddit/TikTok searched a sentence → `SEARCHED_NO_EVIDENCE` (notes: "legitimate search returned no product-relevant evidence"). The query was the defect (class B/C), not the provider.
- **Family normalization (secondary):** family key = full normalized title, so a provider decoration suffix ("[Y]") split one product into two families.
- **Stage-boundary conflation (Part E):** Stage-2/3 supplier/commercial gates block the Stage-1 decision.

## 2. Was research query identity defective? **YES.** Confirmed from the real run provenance: `price_query`/`product_title` = the full raw title for all six candidates; all non-CJ sources returned no evidence.

## 3. Source-by-source diagnosis (original run)
CJ 2/6 evidence (supplier catalog fuzzy-matches) → genuine partial. DataForSEO 0/6, eBay 0/6, Meta 0/6, Reddit 0/6, TikTok 0/6 → **B/C unsuitable query** (full sentence), not genuine no-data for the search/marketplace/ad sources. TikTok is external-blocked structurally (F). Reddit genuinely sparse for brand-new items (A/F).

## 4. Permanent fix
`fn_product_search_identity(title)` derives a concise local-language product-search query (cut at first qualifier clause; strip leading quantity prefix only when a unit token is present, so "360"/"3 in 1" are kept and "1PC"/"2 x" stripped; cap 6 tokens; idempotent on clean queries; preserves raw title + brand/variant tokens). Applied at the single chokepoint `fn_research_request_core` (v3): research now searches the concise query, with the raw title preserved in provenance. Never converts an ambiguous concept into a concrete SKU.

## 5. Family normalization fix / result
`fn_product_family_key(title)` strips only short square-bracket provider decorations ([Y], [DE]) before normalizing; keeps sizes/models/variants/brands/quantities. Result: "reisenthel carrybag XS … [Y]" and "… (no tag)" → **same family**; "carrybag XS 5 l" vs "carrybag M 10 l" → **distinct**. FastMoss ingest now uses it; seller evidence stays separate; branded/IP remains fail-closed.

## 6. Stage-boundary diagnosis (Part E)
`fn_pod_evaluate` sets `decision=WATCH` whenever any hard gate is WATCH, including SUPPLIER_STOCK_UNKNOWN / ECONOMICS_UNKNOWN / COMPLIANCE_UNVERIFIED / FULFILMENT_ROUTE_UNCONFIRMED (reason `CANNOT_TEST_UNTIL_GATES_RESOLVE`). Those four are Stage-2/3 (Exact Supplier Resolution / Supplier Commercial Verification) concerns, so the Stage-1 opportunity decision was conflated with commercial launchability. (It already separates *execution readiness* via `action_gating`, but not supplier/commercial readiness from opportunity qualification.)

## 7. Gates moved and why
**None moved; none weakened.** Added a standalone `fn_stage1_opportunity_qualified(tenant,product,country)` that derives Stage-1 qualification from **Stage-1-owned evidence only** (score ≥ 70 + overall confidence MEDIUM/HIGH + metric_scope LOCAL + saturation PASS + market_price PASS), explicitly EXCLUDING the four Stage-2/3 gates. It answers "worth taking into supplier resolution?" and is distinct from SUPPLIER_VERIFIED / COMMERCIALLY_LAUNCHABLE. The existing `fn_pod_evaluate` decision/gates are unchanged.

## 8. Existing six-product replay result (no new FastMoss/Kalodata discovery call)
Re-researched the six existing generic FastMoss candidates (discovery run 5c2ede62…) with the fixed concise query.
- COMPLETE: microwave shelf, Krippen Wanddekoration, Herren-Fleecejacke. INSUFFICIENT_EVIDENCE: cat toy, AiryBare eyelash, "Praktisch…" (genuinely non-identifying title → query "praktisch").

## 9. Evidence improvement before → after
- **Before:** CJ 2/6; DataForSEO/eBay/Meta/Reddit/TikTok 0/6.
- **After:** Meta Ad Library now 2/6 (Krippen, Fleecejacke — previously 0); CJ 1/6 (microwave). DataForSEO/eBay still 0 even for clean German terms ("herren fleecejacke") → provider-side scarcity (DataForSEO credit / eBay-DE), not query.
- Evaluation bands rose: Krippen INSUFFICIENT → **HIGH_CONFIDENCE_TEST, score 87.0**; Fleecejacke → WATCH band, score 48.0.

## 10. Concrete-resolution outcomes
6 DE `product_market_evaluations` (country-isolated). None reached a benchmark-qualified CONCRETE_RESOLVED: `metric_scope = LOCAL_UNVALIDATED` and `overall_evidence_confidence = NONE` for all (no validated local price/demand evidence).

## 11. Opportunity decisions (pod + Stage-1 separation)
All six pod `decision = WATCH`. Stage-1 separated signal `fn_stage1_opportunity_qualified`: Krippen/Fleecejacke → WATCH (score present but conf NONE, price LOCAL_UNVALIDATED); the other four → INSUFFICIENT_EVIDENCE. **None QUALIFIED_FOR_SUPPLIER_RESOLUTION** — the separation did NOT manufacture a pass; the binding gap is Stage-1-owned local evidence, not the supplier gates.

## 12. Regression results
`fn_stage1_evidence_identity_selftest` = **10/10** (search identity, quantity-strip conservatism, family decoration-same / variant-distinct / identity-token preservation, research-core wiring, Stage-1 supplier-gate exclusion, strong-Stage-1-evidence requirement). Existing suites green: FastMoss 19/19, Kalodata 17/17, multi-lane 16/16, research bridge 8/8, Stage-1 invariants 8/8, image 10/10, autonomous 12/12.

## 13. Paid / provider calls consumed
No FastMoss/Kalodata discovery calls. Research bridge re-dispatched for the 6 existing products via the research webhook (DataForSEO/eBay/CJ/Meta/Reddit/TikTok); due to a two-column RPC evaluation in one replay statement, each product dispatched twice (12 bridge dispatches instead of 6) — a construction mistake, not repeated to improve the report; no further calls made.

## 14. OVERALL STAGE 1 verdict
**BLOCKED_STAGE_1_PRODUCT_OPPORTUNITY_INTELLIGENCE** — no product reached CONCRETE_RESOLVED + benchmark-qualified; none reached QUALIFIED_FOR_SUPPLIER_RESOLUTION on Stage-1-owned evidence. No gate weakened.

## 15. Exact remaining blocker
Country-local demand/price evidence is insufficient for these DE new-listed items: `metric_scope = LOCAL_UNVALIDATED`, `overall_evidence_confidence = NONE`. DataForSEO (search demand) and eBay-DE (marketplace price) returned no evidence even for clean German queries — consistent with DataForSEO credit scarcity and thin marketplace presence for brand-new TikTok-Shop items; Meta ad evidence alone yields a score but not confidence or a validated local price. A Stage-1 PASS needs a discovered product whose Stage-1-owned local evidence (validated local price + demand confidence + manageable saturation) clears the existing thresholds — likely requiring DataForSEO credit restored and/or candidates skewed toward items with real German search/marketplace footprint.

## 16. Commit hash
(to be filled by the commit)

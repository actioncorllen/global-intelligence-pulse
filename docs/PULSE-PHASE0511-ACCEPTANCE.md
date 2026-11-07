# Phase 05.11 — Recommendations Quality: Final Acceptance (2026-11-07)

Acceptance of the deployed improvement (backend `mig_335` / contract `v4_recs_quality`; frontend `27ba521c`, live in
production). Verified at live-contract + deployed-source level. No rebuild, no repeated backend re-verification beyond
what each check needs, no paid calls, no new migration, no new publishing. The one external dependency is authenticated
signed-in browser rendering, which is unavailable to Claude (container egress 403 + auth-gated) → founder device acceptance.

## PASS / FAIL

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Live Recommendations experience (existing architecture) | **PASS** | Live RPC `get_own_opportunity_recommendations` returns contract `pulse_monday_top_opportunities_v4_recs_quality`; 8 cards; `tier_counts {PREMIUM:2, UNTIERED:6}`; `showcase_eligible_count=0`; deployed view `opportunity-recommendations-view.tsx@27ba521c` renders over it. |
| 2 | Image **and** placeholder click open the exact product drawer | **PASS (code)** | `RecImage`: the image/placeholder area is `role="button"`, `tabIndex 0`, `onClick`/`onKeyDown` (Enter/Space) → `onView(productId)` by canonical id; placeholder is inside the same clickable div; reference-listing link is a sibling with `stopPropagation`. Covered by Vitest (525 pass). Live click = device acceptance. |
| 3 | Country selection persists through navigation | **PASS (code)** | Each card opens `?product=<canonical id>` on the same route (view not remounted) with `market = rec.bestMarket`; market filter is retained view state; `findRecommendation` matches by product_id only. |
| 4 | PREMIUM appear before untiered research candidates | **PASS** | `groupRecommendations` → shortlist = showcase-eligible (byTier PLATINUM→GOLD→PREMIUM); research = rest, `byTier` puts PREMIUM/GOLD/PLATINUM above untiered; tiered research cards show "Evidence-qualified — supplier imagery pending". Today: shortlist empty; research = 2 PREMIUM (More Adventskalender, ESN) then 6 untiered. |
| 5 | Desktop + mobile layouts | **PASS (code)** | Responsive Tailwind (`grid … sm:grid-cols-2 lg:grid-cols-3`, `aspect-square`, `flex-wrap`, 16px gutters). Live pixel check = device acceptance. |
| 6 | Evidence confidence, freshness, missing descriptions, media labels | **PASS** | `evidenceFreshnessText`: MEDIUM/HIGH → "Evidence: X · fresh/freshness not established"; NONE/LOW/absent → "Evidence unavailable — freshness cannot be established" (never "None · fresh"). Missing description → "Full product specification not yet available." Marketplace → "Supplier image pending" + "View reference listing ↗"; supplier comparable → "Reference" tag. ROI honesty line present. |
| 7 | Marketplace reference images cannot generate ads / create stores / publish | **PASS** | Backend: the 2 PREMIUM (marketplace-image-only) → `fn_product_commercial_asset_readiness = CUSTOMER_ASSET_REQUIRED` / `CUSTOMER_ACTION_REQUIRED`; **0** `MARKETPLACE_PUBLIC_LISTING` media rows are ever `is_launch_safe`; `fn_media_launch_eligibility` rejects reference media (`CANONICAL_PRODUCT_LINEAGE_REQUIRED`). Frontend: marketplace URLs are never rendered as `<img>` (host + rights guards, fail-closed) and the recs surface has no ad/store/publish action ("launch actions locked"). |
| 8 | Tenant isolation, Product Asset Lock, security contracts | **PASS** | Unauthenticated → `status=unauthenticated` (no data); cross-tenant uid → 0 rows; `fn_monday_top_opportunities` SECURITY DEFINER scoped to `auth.uid()` via wrapper; REFERENCE_ONLY media not launch-eligible; RLS/exact-SKU unchanged. |
| 9 | Fix genuine defects, test, verify | **PASS (none found)** | Code + contract review found no genuine defect; the empty premium shortlist and marketplace-link-only behaviour are the correct, rights-respecting honest states. 525 frontend tests pass (typecheck/lint clean, build OK). No internal fix outstanding. |
| 10 | Acceptance report | **This document.** |

**Overall: Phase 05.11 — PASS.** Remaining purely external: live signed-in visual/interaction acceptance on device (authenticated browser unavailable to Claude).

## Next launch-critical blocker (toward 18 Dec 2026)
**Supplier commercial-readiness pipeline for recommended products.** Every rec is held at WATCH with
`commercial_asset_readiness = CUSTOMER_ASSET_REQUIRED` and all hard gates unresolved because there is **no exact-SKU
supplier binding, no supplier-authorised imagery/specs, no landed-cost/margin/stock evidence** for the recommended
products. Consequences: premium showcase is empty, 0 products reach a TEST decision, and none can progress to
launchable. This is the gating path to a credible commercial launch.

It needs a **founder decision**: authorise a **bounded, budgeted supplier-data fetch** (CJ/supplier exact-SKU resolution
+ authorised images + specs + economics + stock/shipping) for the strongest candidates — currently blocked by the
no-paid-calls rule, and note the branded EU retail recs (Adventskalender/ESN/Makita/Ankerkraut) may not exist in CJ's
catalogue, so candidate selection for sourcing should favour products CJ can actually supply. Everything downstream
(tiers, showcase, Ready-to-Test, store/ad readiness) already works and will populate automatically once rights-cleared
supplier evidence exists.

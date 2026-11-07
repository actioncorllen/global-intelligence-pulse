# Recommendations Quality Fix — delivery + deployment-readiness report (2026-11-07)

Improvement of the existing Recommendations experience (not a rebuild). Backend `mig_335` **PREPARED (not applied)**;
frontend **preview `27ba521c`** (not published). Builds on deployed mig_334. **No paid provider calls; no publish; no
advertising/billing/signup; Product Asset Lock + exact-SKU identity preserved.** Branch `claude/nifty-bardeen-f9nddu`.

## 1. Root causes (the 7 reported problems)
1. **Image click didn't open details** — the recommendation image was not a click target; only the "View Product" button navigated. (Frontend.)
2. **No images** — the 8 recs have **no supplier-authorised images**; their only images are eBay `MARKETPLACE_PUBLIC_LISTING` thumbnails, which the media/Asset-Lock contract deliberately hides (`fn_product_media_state` → `IMAGE_UNAVAILABLE`).
3. **Descriptions incomplete** — `commerce_products.description` is **empty for all 8**; real specs require a paid supplier/spec fetch.
4. **Videos not accessible** — only the Krippen has videos (7 FastMoss `REFERENCE_ONLY`); the drawer wasn't surfacing them prominently; the other 7 recs have none.
5. **Weak products dominate** — the page showed all 8 (incl. 6 untiered) in one flat watchlist.
6. **"Real demand" without evidence** — `fn_monday_top_opportunities` hardcoded `why = "Real demand…"` for every card.
7. **"Evidence: None · fresh"** — freshness was computed from evaluation recency independent of evidence confidence.

## 2. Supplier-access verification (founder additional requirement; read-only, no paid calls)
- **CJ cache is readable free:** `commerce_supplier_products` holds **1317 cached CJ rows** (image_url, sku, supplier_cost, shipping_country_codes, is_free_shipping, supplier_enrichment) — inspecting it costs nothing.
- **Rights-cleared CJ media exists but not for the recs:** `product_image_assets` has **12 `SUPPLIER_PROVIDED` (CJ_SUPPLIER)** images + 1 `CJDROPSHIPPING` video — all belonging to **non-recommended** products (kids nightlight projector; a ski mask). **None of the 8 recommendations have any CJ/supplier-authorised media.**
- **No exact-SKU CJ match for the recs:** the cache contains only **different, category-adjacent** products for the rec themes (e.g. "Christmas Snowman Flameless Candles Projector" ≠ "Illuminated Snowman Door Hanger"; "Advent Candle Holder" ≠ "More Adventskalender 2026"). Using them = substitution (forbidden). The 8 recs are branded EU retail items (Adventskalender/ESN/Makita/Ankerkraut) **not in CJ's dropshipping catalogue**, so even an (unauthorised) paid CJ fetch would most likely return no exact match.
- **Conclusion:** no rights-cleared supplier imagery/specs/videos for the recommendations are obtainable from existing/free access; genuine retrieval is both **paid** and **unlikely to match**. Flagged as a genuinely-unavailable external dependency (§7).

## 3. Marketplace image display-rights determination
The recs' only images are eBay `MARKETPLACE_PUBLIC_LISTING` thumbnails. Display rights for third-party display are
**not established** — the system itself classifies and hides them, and no rights grant is recorded. Per the founder
guardrail ("verify permitted display rights before exposing; if rights cannot be established, retain the source
reference without copying the image"), the implementation **never copies/displays eBay images**; it exposes a
**source reference link** to the listing only. (This supersedes the earlier "show marketplace imgs as Reference" to the
degree of showing a link, not the image.)

## 4. Changes delivered
### Backend — `mig_335_recommendations_quality.sql` (PREPARED, NOT APPLIED; v4 of `fn_monday_top_opportunities`)
- `why`: "Real demand" only when demand is **corroborated** (`overall_evidence_confidence ≥ MEDIUM`) **and** has a named source; else **"Demand not sufficiently verified."**
- `evidence_fresh`: gated on corroborated+sourced → a NONE/LOW-confidence product never reads "fresh" (fixes "Evidence: None · fresh").
- **Marketplace image = reference link only**: matched (`provenance.match='MATCHED'`) `product_image_assets` surfaced as `{available:false, reference_available:true, reference_url, display_rights:'NOT_ESTABLISHED', note}` — image **not copied**; never launch-safe; `fn_media_launch_eligibility` unchanged (still rejects). No fabrication/substitution.
- `has_authentic_image` / `showcase_eligible` require a **rights-cleared supplier-authoritative** image (`product_asset_intelligence` hero). Added `authentic_image_count`, `marketplace_reference_count`, `showcase_eligible_count`.
- Preserves tiers (mig_334), `ready_to_test_platinum`, decision, PAL, tenant scoping. Contract → `pulse_monday_top_opportunities_v4_recs_quality`.
- Validated read-only on prod (not applied): 8 cards; **showcase_eligible = 0/8** (no rights-cleared images); "Real demand" only for the 2 corroborated PREMIUM; evidence_fresh true only for them; reference links for 3 matched products.

### Frontend — Lovable preview `27ba521c` (built on d6452bd; NOT published)
- **Image click → drawer**: the image/placeholder is a keyboard-accessible button that opens the exact product drawer (canonical productId), preserving the recommendation's country; "View Product" opens the same product.
- **Marketplace = link-only**: no eBay `<img>` is ever rendered (hard safeguard refuses eBay-origin image URLs even if the server mislabels); shows a "Supplier image pending" placeholder + a separate "View reference listing ↗" link (http(s)-validated, `rel=noopener`, `stopPropagation`) + the server note. Supplier-authoritative images still render as real images.
- **Section hierarchy**: "Ready to Test — Platinum" (unchanged, honest empty) → **Premium shortlist** (showcase_eligible; honest empty state today) → **Research candidates** (PREMIUM/GOLD/PLATINUM first with tier badge + "Evidence-qualified — supplier imagery pending", then untiered; nothing deleted).
- **Honest labels**: evidence line → "Evidence unavailable — freshness cannot be established" for NONE/absent (never "None · fresh"); `why` rendered verbatim (now evidence-gated); reference-only videos surfaced in the drawer (REFERENCE_ONLY, never publish); description fallback "Full product specification not yet available."
- Preserved: premium card design, exact-product nav, locked launch actions, country filter, tier legend, My Store, responsiveness. Fail-closed against the live (v3) backend.

## 5. Verification (NINTH) — per-product coverage of the 8 recommendations
Canonical IDs + coverage (prod read-only). **Authentic (supplier-authorised) images: 0 for all 8. Descriptions: empty for all 8. SKU resolved: none.**

| # | Product | Canonical product_id | Country | Tier | Demand evidence | Supplier-authorised imgs | Marketplace ref (link-only) | Supplier video | Reference video (FastMoss/TikTok) | SKU resolved | Description | Showcase eligible |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | More Adventskalender 2026 | 1fe5b267-587c-4d4d-b600-7083a56bc5ad | DE | **PREMIUM** | MEDIUM (DataForSEO + eBay, fresh) | 0 | 8 (link) | 0 | 0 | UNKNOWN | — | **No** |
| 2 | ESN Designer Proteinriegel | d1e42001-3f6a-43f0-ac20-d6f748a0ee3d | DE | **PREMIUM** | MEDIUM (DataForSEO + eBay, fresh) | 0 | 5 (link) | 0 | 0 | UNKNOWN | — | **No** |
| 3 | Beleuchtete Krippen | 5bc29d0a-b8e0-4fa9-bb80-d77197d770c4 | DE | untiered | NONE | 0 | 0 | 0 | 7 (REFERENCE_ONLY) | UNKNOWN | — | No |
| 4 | Illuminated Snowman | 873551b0-a0d0-44f6-8792-7b2650d904cd | GB | untiered | NONE | 0 | 0 (1 non-MATCHED excluded) | 0 | 0 | UNKNOWN | — | No |
| 5 | Makita Adventskalender 2026 | 27ff4759-bbb8-407c-9956-6bea8cfbe7a0 | DE | untiered | NONE | 0 | 0 | 0 | 0 | UNKNOWN | — | No |
| 6 | Herren-Fleecejacke | 34761bbc-1de0-4a9e-8662-1f52c3f28be4 | DE | untiered | NONE | 0 | 0 | 0 | 0 | UNKNOWN | — | No |
| 7 | Ankerkraut Adventskalender | 1f3bc864-08df-4893-9f06-faa0fa0fb52b | DE | untiered (band AVOID) | LOW | 0 | 2 (link) | 0 | 0 | UNKNOWN | — | No |
| 8 | Hit the Slab | ca4a79b0-41a7-4fc6-b267-82b99a123dff | DE | untiered (band AVOID) | NONE | 0 | 0 | 0 | 0 | UNKNOWN | — | No |

Commercial media permissions: none of the above is cleared for commercial publishing; reference images/videos are
research-only and never unlock Product Asset Lock.

## 6. Before / after eligibility
- **Before (live d6452bd / mig_334 v3):** all 8 shown in a flat watchlist; every card claimed "Real demand"; freshness could read "None · fresh"; no images (eBay hidden; media_state IMAGE_UNAVAILABLE); image not clickable.
- **After (preview 27ba521c + mig_335):** premium shortlist honestly **empty** (no rights-cleared imagery); the 2 evidence-qualified PREMIUM products lead **research** with a reference link + "supplier imagery pending"; "Real demand" only on corroborated products; no false "fresh"; image/placeholder opens the exact drawer; eBay images never copied (link only).

## 7. Test results
- Frontend `27ba521c`: **525 tests pass** (72 files; recommendations 47 → 54), `bunx tsgo --noEmit` clean, eslint clean on changed files (12 pre-existing warnings), preview build OK. Regression covered: image-click (mouse+keyboard) opens correct product + country preserved; no eBay URL ever used as `<img src>`; reference link is http(s)-validated + opens listing (not drawer); premium-showcase empty state; PREMIUM-in-research; honest freshness wording; evidence-gated why; fail-closed decode; PAL (reference media never launch-eligible).
- Backend `mig_335`: validated read-only on prod (not applied) — see §4.
- Not verifiable from container: live signed-in rendering + phone-width (egress 403 + auth-gated) → founder device acceptance.

## 8. Genuinely-unavailable supplier media (external dependencies)
- **Supplier-authorised images** for the 8 recs: none exist; obtaining them needs a **paid CJ/supplier fetch** that also likely won't match (branded EU retail products absent from CJ's catalogue).
- **Product specifications/descriptions**: none ingested; same paid-fetch dependency.
- **Supplier/product videos**: only the Krippen has FastMoss REFERENCE_ONLY research videos; no licensed/commercial videos for any rec.
- **eBay marketplace images**: display rights not established → shown as source link only (by design).

## 9. Deployment-readiness
Two reversible steps, **await founder approval** (nothing applied/published):
1. Apply `mig_335_recommendations_quality.sql` (CREATE OR REPLACE of `fn_monday_top_opportunities`; rollback = restore the mig_334 body).
2. Publish frontend `27ba521c` (rollback = re-publish `d6452bd`).
Guardrails preserved: tenant isolation/RLS, canonical identity, exact-SKU integrity, Product Asset Lock, supplier-media rights, provider budgets — no new paid calls, billing, ads or signup.

## 10. PRODUCTION DEPLOYMENT (executed 2026-11-07, founder-approved controlled sequence)
1. Current versions confirmed: backend `pulse_monday_top_opportunities_v3_tiers` (mig_334), frontend published `d6452bd`; preview head `27ba521c`. ✅
2. DB `ACTIVE_HEALTHY` (PG 17.6.1.127); rollback = restore mig_334 body of `fn_monday_top_opportunities`. ✅
3. Migration matched the reviewed/committed `mig_335_recommendations_quality.sql`. ✅
4. `mig_335` applied (`apply_migration` → success). ✅
5–7. Authenticated (founder JWT) live checks: contract `pulse_monday_top_opportunities_v4_recs_quality`;
   `showcase_eligible_count=0`; `tier_counts {PLATINUM:0, GOLD:0, PREMIUM:2, UNTIERED:6}`; watchlist=8; the 2 PREMIUM
   (More Adventskalender, ESN) → `why="Real demand"`, `evidence_fresh=true`; the 6 untiered → `why="Demand not
   sufficiently verified"`, `evidence_fresh=false`; marketplace images `available:false` + `display_rights:NOT_ESTABLISHED`
   (reference link only). Tenant isolation: unauthenticated → `unauthenticated`; cross-tenant uid → 0 rows. ✅
8. Product Asset Lock: Krippen FastMoss REFERENCE_ONLY videos → `fn_media_launch_eligibility`=`false`
   (`CANONICAL_PRODUCT_LINEAGE_REQUIRED`), unchanged. ✅
9. Frontend published: `deploy_project` → deployment `1c6cd898-f113-4110-a3fb-cb715feb92d4`. ✅
10. Confirmed `is_published=true`, published source `latest_commit_sha = 27ba521c`. ✅
11. Production regression: backend v4 live; `ready_to_test`/`watchlist` arrays intact; adjacent contracts healthy
    (`get_own_product_acquisitions`, `fn_product_explorer`). No re-score, no decision change, no grants widened; no new
    paid calls. ✅

**Expected results — all confirmed:** Premium Showcase 0 eligible; Research Candidates 8; two evidence-qualified PREMIUM
first; unsupported demand/freshness claims removed; reference videos research-only; no marketplace thumbnail rendered as
an authorised product image (link only). Remaining: live signed-in + phone-width device acceptance (container egress 403).
Rollback: backend → restore mig_334 body; frontend → re-publish `d6452bd`.

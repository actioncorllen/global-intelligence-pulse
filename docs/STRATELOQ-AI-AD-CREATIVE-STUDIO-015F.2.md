# STRATELOQ-AI-AD-CREATIVE-STUDIO-015F.2 — Canonical Product + Product Decision Lineage Gate

**FINAL VERDICT: `CANONICAL_CREATIVE_LINEAGE_READY`.**

The canonical product-lineage gap found in 015F.1 is closed with a small, additive contract. A deterministic
`lineage_state` (CANONICAL / INLINE_ONLY / UNRESOLVED) is resolved **only from real foreign keys** (never
text/name match), validated for tenant ownership + Product Decision (product+market+tenant+non-fixture),
propagated brief → job → asset, and enforced by a **hard launch-safety gate**: an asset can become
`is_launch_safe` **only** when lineage is CANONICAL, a matching Product Decision exists, and product identity
is cleared. INLINE_ONLY / UNRESOLVED creatives may still be generated for experimentation but can **never**
become launch-safe. The historical dash-cam asset was **not** fabricated into a canonical link (name match is
insufficient); it is truthfully INLINE_ONLY and remains IN_REVIEW / IDENTITY_REVIEW_REQUIRED / not
launch-safe. 16/16 lineage selftest + all regressions green; 0 ERROR advisors; no paid call, no regeneration,
no duplicate product. Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

---

## 1. Root cause of the dash-cam lineage gap
`fn_ad_studio_build_brief` inserted `product_id`/`decision_id` **without any validation**, so the founder
dash-cam brief (`15f0aabd`) was created with an inline reference `ae458526` that is **not** a
`commerce_products` id, and `decision_id` NULL. `fn_media_complete_image_real` therefore left
`media_assets.product_id` NULL, and `fn_media_approve_asset` would have set `is_launch_safe=true` with **no**
lineage/identity check. Two holes: (a) unvalidated brief lineage, (b) an ungated launch-safe path.

## 2. Whether the canonical dash-cam already existed
**Yes — a canonical product exists**: `66b60d77-d5a3-43a6-8d02-d5020ee50e50`
("3 Channel Dash Cam (Front 1080P / Inner 480P / Rear 480P)", `identity_basis=platform_id`,
`product_identity=1980170173102026754`). **But it shares no deterministic signal with the brief**: the
brief's CJ source asset (`0c425d56…`) is **not** on the canonical product, the canonical product has **no**
Product Decision / PME / image assets, and `ae458526` appears nowhere canonical (not in commerce_products,
product_asset_intelligence, PME, decisions, or product pages). The only overlap is the product **name**.

## 3. Duplicate check
The audit resolved the identity through all product surfaces before any change. **No duplicate commerce
product was created** (selftest L asserts the dash-cam product count is unchanged). Because the only link to
`66b60d77` is name similarity — explicitly forbidden as a basis — the historical asset was **not** linked to
it (`ae458526` → INLINE_ONLY, `product_id_not_in_commerce_products`).

## 4. Schema / contract change
Additive only: `lineage_state text` on `ad_studio_briefs`, `media_image_jobs`, `media_assets` (+ CHECK
CANONICAL/INLINE_ONLY/UNRESOLVED, default UNRESOLVED); `identity_state text` on `media_assets` (default
IDENTITY_REVIEW_REQUIRED). No table/column dropped or repurposed; no new product/decision system.

## 5. Lineage-state implementation
`fn_ad_studio_resolve_lineage(tenant, product_id, decision_id, market)` — deterministic, FK-only:
- `product_id` NULL → **UNRESOLVED**.
- `product_id` not in `commerce_products` → **INLINE_ONLY** (`product_id_not_in_commerce_products`).
- `product_id` owned by another tenant → **INLINE_ONLY** (`cross_tenant_product_rejected`).
- canonical + owned, `decision_id` supplied but not matching product+market+tenant+non-fixture → **INLINE_ONLY**
  (`invalid_decision_for_product_market_tenant`) — an invalid decision is never silently accepted.
- canonical + owned (valid or no decision) → **CANONICAL**.
Name/text is never consulted.

## 6. Brief-builder change
`fn_ad_studio_build_brief` now resolves lineage, **raises** on a cross-tenant product, keeps `decision_id`
only if it validated, and persists `lineage_state`. Existing callers unaffected (same signature).

## 7. Generation pre-flight change
`fn_media_prepare_image_job` computes lineage from the brief, sets `media_image_jobs.lineage_state`, and
returns `lineage_state`, `production_launch_eligible` (= CANONICAL), and `production_gate_reason`
(`CANONICAL_PRODUCT_LINEAGE_REQUIRED` when not canonical). INLINE_ONLY/UNRESOLVED still prepare (experiment
allowed) but are flagged non-launch-eligible. `fn_media_complete_image_real` propagates `lineage_state` to
the asset and backfills the canonical `product_id` from the brief **only** when lineage is CANONICAL (never
for INLINE/UNRESOLVED).

## 8. Production launch-safety gate
`fn_media_launch_eligibility(asset)` + hardened `fn_media_approve_asset`: launch-safe requires
`lineage_state=CANONICAL` **and** `identity_state=IDENTITY_CLEARED` **and** a matching non-fixture Product
Decision. Otherwise approval is blocked with an explicit reason (`CANONICAL_PRODUCT_LINEAGE_REQUIRED` /
`IDENTITY_REVIEW_REQUIRED` / `PRODUCT_DECISION_REQUIRED`) and `is_launch_safe` stays false. INLINE_ONLY /
UNRESOLVED can never be approved.

## 9. Historical dash-cam asset treatment
Backfilled truthfully to **INLINE_ONLY** (brief `15f0aabd`, job `5d4fe8f0`, asset `718b4962`). **Not** linked
to the name-matched canonical product. Provenance preserved (provider OPENAI_GPT_IMAGE, storage_ref, CJ
source asset). Live approve attempt → **blocked** `CANONICAL_PRODUCT_LINEAGE_REQUIRED`; remains **IN_REVIEW**,
**IDENTITY_REVIEW_REQUIRED**, `product_id` NULL, `is_launch_safe=false`.

## 10. Canonical product ID if legitimately resolved
**None legitimately resolvable for the historical asset** — no deterministic signal beyond name, so no
canonical linkage was made (fabrication avoided). (A canonical dash-cam `66b60d77` exists but is not
deterministically the same record.)

## 11. Product Decision ID if legitimately resolved
**None** — neither `ae458526` nor `66b60d77` has a non-fixture Product Decision. No decision fabricated.

## 12. Propagation test product → brief → job → asset
Proven on a fixture canonical product: `fn_ad_studio_build_brief`(product=canonical) → brief CANONICAL →
`fn_media_prepare_image_job` → job CANONICAL → `fn_media_complete_image_real` → asset CANONICAL with
`product_id = canonical product` (selftests F, G).

## 13. Tenant-isolation results
**PASS.** Cross-tenant product → INLINE_ONLY + `build_brief` raises (B); prepare/approve with wrong tenant →
`not_found_or_forbidden` (K).

## 14. Identity-vs-lineage independence result
**PASS (J).** A CANONICAL asset with unreviewed identity is blocked by **IDENTITY_REVIEW_REQUIRED**; an
INLINE_ONLY asset is blocked by **CANONICAL_PRODUCT_LINEAGE_REQUIRED**. The two dimensions are independent and
both required for launch-safe.

## 15. Video readiness impact (015G)
015G inherits this contract unchanged: `media_video_jobs`/`media_video_scenes`/video assets get the same
`lineage_state` propagation from the brief and the same launch-safety gate — no parallel product-identity
system. Video assets stay non-launch-safe unless CANONICAL + decision + identity cleared.

## 16. Marketing Director / campaign lineage impact
Preserved and strengthened: only CANONICAL, decision-backed, identity-cleared assets can become launch-safe,
so a future campaign / Ad-Performance Specialist / Marketing Director consumes only assets traceable to a
canonical product + Product Decision. No third campaign lineage; no performance system built.

## 17. Regression results
All green: `ad_creative_canonical_lineage` (16/16), `ad_creative_runtime` (10/10), `media_creative_live`
(0 failed), `product_gallery`, `problem_solution`, `problem_foundation`, `problem_discovery`,
`research_orchestrator`, `tiktok`. Unchanged: nightlight GB PME **68.2**, gallery identity, GB cluster
corroboration `MULTI_EVIDENCE_SINGLE_SOURCE`, Product Decision scoring, WATCH gates, Problem Intelligence.

## 18. Security results
**0 ERROR, 1 INFO, 4 WARN** (baseline). New functions SECURITY DEFINER + `search_path ''` + least-privilege;
tenant checks throughout; no client-controlled tenant escalation; no secrets.

## 19. Fixture contamination check
0 stray `lin:%` products, 0 stray `[[lin]]%` briefs (selftest self-cleans). Historical asset intact
(INLINE_ONLY / product NULL / not launch-safe / IN_REVIEW). No duplicate commerce product.

## 20. Files changed
- `supabase/migrations/mig_276_canonical_creative_lineage.sql` — columns + 4 functions
  (`fn_ad_studio_resolve_lineage`, `fn_media_launch_eligibility`, updated `fn_ad_studio_build_brief`,
  `fn_media_prepare_image_job`, `fn_media_complete_image_real`, `fn_media_approve_asset`) + A–P selftest.
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015F.2.md` — this report.
- One-time data backfill of the historical dash-cam brief/job/asset to INLINE_ONLY (documented; no canonical
  fabrication).

## 21. Commit hash
See the delivery message (committed to `claude/pulse-crash-recovery-b6ngey`).

## 22. Final verdict
**`CANONICAL_CREATIVE_LINEAGE_READY`** — canonical lineage cannot be fabricated (FK-only, name never
sufficient), cannot cross tenants or markets, and cannot be bypassed for launch-safe media; the historical
asset stays truthful.

---

**STOP.** No paid generation, no new image, no video, no Lovable, no publish, no Stripe, no social/ad account
connection, no posting, no campaign launch, no Marketing Director / Growth Agent activation, no Product
Decision scoring change, no WATCH-gate change, no Problem Intelligence change, no secrets. Reddit remains
`BLOCKED_EXTERNAL_APPROVAL`.

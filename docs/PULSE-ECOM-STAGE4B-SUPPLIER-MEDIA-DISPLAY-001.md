# PULSE-ECOM-STAGE4B-SUPPLIER-MEDIA-DISPLAY-001 — Complete Supplier Media Display

**The Product Intelligence Card now shows the full CJ supplier media: the SAME_PRODUCT_IDENTITY / MEDIUM
match, the eight corresponding Old-Man-Face variants (each marked NOT exact-SKU verified, with images), the
de-duplicated CJ supplier gallery, and the downloaded CJ video playing through a securely signed private-
storage URL — with copyright / commercial-use (reference-only) labels on every asset. Backend contracts
(mig_326, mig_327) are DEPLOYED and verified live; the signed-URL path reuses the existing `media-asset-url`
edge function; the Lovable frontend is wired, unit/component-tested (332/332), build-verified and published.
No exact-variant claim, no advertising/publishing unlock, no paid calls. The one gap: a live signed-in
in-browser click-through could not be run from this container (egress policy blocks the app + Supabase hosts)
— the founder confirms the final pixels in their own browser.**

Continues commit 8851b29. Product: FastMoss `56a6af36-68f7-4138-9d29-941245f266b2` · CJ pid
`2609290358281623700` · tenant `7c8ddf9d…` · GB.

## 1. mig_324 — verified already deployed (not reapplied)
`fn_product_supplier_candidate`, `fn_cross_supplier_evidence`, `fn_cross_supplier_identity_selftest` are all
present; the three SELFTEST fixtures are gone (0 remaining). mig_324 was applied by the founder via the
Dashboard. **Left untouched.**

## 2. mig_326 — reviewed + deployed (write path recovered)
Reviewed for correctness, tenant isolation and secure private-video playback, then DEPLOYED (the Supabase MCP
write path recovered this session — a small-write probe succeeded, then the full `CREATE OR REPLACE` applied).
`fn_product_media_state` now self-describes playback without changing any auth/isolation/rights behaviour:
- `playback_mode` = `SELF_HOSTED_SIGNED` (private object → sign) vs `EXTERNAL_URL` (play `url` directly).
- `media_asset_id`, `storage_bucket`, `storage_object`; `url` is null for self-hosted (never a bare path).
- Verified live (signed-in sim): `video_state=VIDEO_AVAILABLE`, `playback_mode=SELF_HOSTED_SIGNED`,
  `media_asset_id=484f8e10-99ce-4c1f-87f2-de83237dda41`, `storage_bucket=pulse-generated-media`, `url=null`.
Also committed for Dashboard apply at `supabase/manual/mig_326_dashboard_apply.sql` (idempotent, pre/post
guarded) for any environment where the MCP write path is down.

## 3. mig_327 — candidate variants + per-asset rights (deployed)
Additive `CREATE OR REPLACE` of two functions (verified live):
- `fn_product_supplier_candidate` now also returns `variants[]` — all 35 CJ variants with class, families,
  price, **per-variant image** (joined from `supplier_enrichment.variant_catalog`) and
  `corresponds_to_concept`; the eight Old-Man-Face variants are flagged, every variant carries
  `exact_variant_verified=false` + `advertising_cleared=false`. Plus `media.gallery_images` (full 40-image
  de-duplicated gallery) and `commercial_use`. Verified: tier SAME_PRODUCT_IDENTITY, MEDIUM, 8/8 corresponding
  variants have images, 40 gallery images, `commercial_use=NOT_CLEARED_REFERENCE_ONLY`.
- `fn_product_media_state` video lane also carries per-asset `copyright`, `is_free`, `commercial_use`.

## 4. Secure signed private-video playback (reused, verified)
The card never exposes a bare private path. Playback reuses the existing `media-asset-url` edge function
(`verify_jwt=true`): it checks ownership with the caller's JWT via `fn_media_asset_signed_ref` (tenant =
`auth.uid`), then mints a ~300 s signed URL with the service role (never returned-to-client service key).
Verified end-to-end at the real infrastructure level:
- **Authenticated playback** — service-role-signed URL → GET returns the real MP4 (`video/mp4`, 1,233,873
  bytes = CJ `videoSize`).
- **Different-tenant denial** — `fn_media_asset_signed_ref` → `forbidden` for a non-owner (edge → 403).
- **Expired signed URL** — a TTL=1 s URL fetched after 3 s → `400 InvalidJWT, "exp claim timestamp check
  failed"`.
- **Missing video** — a tenant product with no video row → `video_count=0`, no `primary_video` (honest
  unavailable), no fabrication.
- **Media-rights restriction** — every CJ asset `is_launch_safe=false`, `usage_permission=REFERENCE_ONLY`,
  `advertising_cleared=false`, `commercial_use=NOT_CLEARED_REFERENCE_ONLY`.

## 5–6. Frontend wiring (Lovable) + tests
The existing `ProductIntelligenceDrawer` was extended (additive, reference-only, display-only). Files:
- `product-media-contract.ts` — new video fields; `fetchSignedMediaUrl(assetId)` calls `media-asset-url`
  (403 → forbidden, else unavailable), never caches; decoder **fails closed** (a video must be TikTok-linkable
  or genuinely playable) and drops malformed/non-reference entries (dev warning).
- `reference-video-gallery.tsx` — self-hosted videos request a **fresh** signed URL each time the section
  opens, play it, and on failure/refusal/expiry show "Video temporarily unavailable" + **Retry** (re-mints);
  public `url` videos play directly; TikTok links unchanged; rights caption "Reference only — not cleared for
  commercial/advertising use" + "Copyright: yes/no".
- `product-supplier-candidate-contract.ts` + `use-product-supplier-candidate.ts` — null-safe decoder + hook.
- `supplier-candidate-section.tsx` — header `display_label` + MEDIUM chip + a prominent warning "Same product
  — not variant-matched. No exact SKU has been verified." (shown unless the server sends explicit `true`);
  the 8 corresponding variants as an image grid, each tile "Candidate variant — not exact-SKU verified"
  (+ expand to all); de-duplicated supplier gallery "reference only"; rights (rights state, Advertising
  cleared: No, commercial use, rights note) + economics (price, GB landed, stock). **No ad / store / publish
  action anywhere.** Sellable actions stay `concreteProductActionsAllowed={false}`.
- `cj-supplier-media.test.tsx` (+ gallery test data) — covers valid / missing / malformed / no-access data,
  the private video requesting a signed URL and rendering a player, Retry re-minting, and the MEDIUM chip +
  not-exact-SKU warning + 8 variants.

Results (run by the Lovable build): **332/332 tests pass** across 52 files (10 new), `tsc --noEmit` clean,
lint clean on changed files, **preview build succeeds**. Published to production (deployment pending/complete).

## Preservation (req 4)
Strict no-exact-variant is preserved end to end: `exact_variant_verified=false` is surfaced in the contract
and shown as an un-missable badge; the card never presents an exact/verified SKU. Product Asset Lock stays
server-authoritative (media is REFERENCE_ONLY, display-only, never fed to commerce/creative/publishing gates;
card invariant `reference_media_never_unlocks_store_ad_creative_publishing=true` unchanged). Country isolation
and tenant isolation (`auth.uid`) unchanged. No CJ download restarted; no AliExpress/BigBuy/later stages.

## Status per directive requirement
| Req | Verdict |
|---|---|
| 1 Verify mig_324 deployed; don't reapply | **PASS** — present; not reapplied |
| 2 Review mig_326; prepare for founder execution if not deployed | **PASS** — reviewed; deployed (MCP write path recovered); Dashboard file also committed |
| 3 Card shows CJ identity, 8 variants (not exact-SKU), CJ images w/ variant assoc, signed video playback, per-asset rights | **PASS (built + unit/component-tested + published)** / live-browser click-through PARTIAL (see below) |
| 4 Preserve strict no-exact-variant + Product Asset Lock | **PASS** |
| 5 Test authed playback / cross-tenant denial / missing video / expired URL / media-rights | **PASS** — all five verified at the real backend/edge/storage level (+ covered by component tests) |
| 6 Fix failures, re-test, verify actual browser results before customer-facing PASS | **PARTIAL** — code correct, 332 tests green, build OK, published; a live signed-in in-browser render could not be executed from this container (egress blocks the app + Supabase) |

**Overall: PASS on backend + edge + storage + frontend code/tests/build/publish; PARTIAL only on the literal
signed-in in-browser pixel check**, which is blocked by this container's egress policy (the preview app and
`supabase.co` are refused by the proxy; disabling it is not permitted). Everything that gates on data is
proven with real responses, and the UI is unit/component-tested in jsdom (including the signed-URL player and
candidate rendering) with a passing production build.

## Remaining founder actions
1. **Confirm the pixels in your browser** — open the live app (`https://https-www-globalintelligenceactions-com.lovable.app`
   or the preview), sign in, open the Old-Man-Face Ski Mask in the Product Explorer, and confirm: the "Supplier
   match (CJ)" section shows MEDIUM + the "not variant-matched / no exact SKU verified" warning and the 8
   variant tiles; the supplier gallery renders; the video plays (it fetches a fresh signed URL); and the
   rights captions read reference-only / advertising-not-cleared. (All five test scenarios are already proven
   server-side; this is the visual confirmation only.)
2. **Commercial media rights** — the CJ video + images remain REFERENCE_ONLY until you establish commercial/
   advertising rights; nothing here unlocks advertising, creative generation or storefront publishing.

No paid calls, no licence purchases, no scraping. STOP within Stage 4B.

# STRATELOQ-015K.1 — Product Card Asset Identity Lock (permanent) + first-creative decision

**FINAL VERDICT: `PRODUCT_IDENTITY_PRESERVATION_BLOCKED`** (no paid call made).
**Permanent rule enforced: `PRODUCT_CARD_ASSET_IS_AUTHORITATIVE = TRUE`.**

The founder's mandatory correction is now enforced in the schema. The 015K.1 generated asset is exactly the failure
mode the rule forbids: a full-frame `gpt-image-1` **redraw** of the product (it invented translucent side
"panels/wings"), so its product pixels are AI-generated, **not** the authoritative Product Card pixels. Under the
new permanent gates that asset **cannot be launch-eligible**. The only currently-wired generator redraws the
product, so exact product preservation **cannot be achieved with the current pipeline** — therefore, per the
founder's explicit instruction, **no paid call was made** and the blocker is returned.

---

## Permanent architecture (mig_283)
- `fn_ad_creative_identity_policy()` — LOCKED policy: product pixels MUST originate from the workspace Product Card
  asset(s); AI may generate **background/environment only**, never the product; applies to ALL customer creative
  types (static/carousel/video/product-demo/story/reel/tiktok/meta/future); Strateloq-brand exception (real
  screenshots/UI/logo/approved assets); critical text composited deterministically, never generated in the model.
- `fn_ad_product_card_authority(tenant, product_id, market)` — resolves the exact authoritative Product Card
  image(s) by card identity `(source_provider, source_item_id)`; excludes marketplace-reference (eBay) images.
- `fn_media_product_card_source_verified(asset_id)` → **PRODUCT_CARD_SOURCE_VERIFIED**.
- `fn_media_product_identity_preserved(asset_id)` → **PRODUCT_IDENTITY_PRESERVED** (full-frame redraw modes = FAIL;
  `REAL_PRODUCT_LAYER_COMPOSITE` with a recorded product-layer source = PASS-eligible).
- `fn_ad_product_card_safe_route(...)` — the mandated identity-safe route: authoritative product layer (protected)
  + separately generated/deterministic background + deterministic composite + deterministic copy/CTA (video: motion
  around the protected product layer).
- `fn_creative_quality_review` extended with both new gates; `fn_media_launch_eligibility` makes launch-safe
  impossible unless both = PASS (as the final barrier, after canonical lineage + identity cleared + Product Decision).
- `fn_ad_creative_identity_selftest()` — **6/6**.

## RETURN
1. **Exact Product Card asset:** `7c2f476f-acbe-499b-a015-2422e56daa50` (primary), URL
   `…/beb8eabe-…_trans.jpeg`.
2. **Source provider + item ID:** `CJ_SUPPLIER` + `2608250310481611400`.
3. **Confirmation it is the workspace Product Card image:** **YES** — it is the product's `is_primary`
   SUPPLIER_PROVIDED image and matches the card identity `(CJ_SUPPLIER, 2608250310481611400)`; job `449552b4`'s
   source URL equals this asset's URL exactly (`source_is_exact_card_image = true`).
4. **Canonical product_id:** `e453eed4-3de4-4ed9-b889-1275c13c0dba`.
5. **Product Decision:** `ab8607cd-920d-40ca-8e24-e02bf5f8db26` (GB, non-fixture).
6. **PRODUCT_CARD_SOURCE_VERIFIED:** **PASS** (source is the authoritative Product Card asset).
7. **Generation strategy:** the current wired generator is `gpt-image-1 IMAGE_EDIT_FROM_PRODUCT_ASSET`, a
   **full-frame redraw** → now classified identity-unsafe. The mandated safe route is authoritative product layer +
   separate background + deterministic composite; its executor is **not yet built**.
8. **Actual product pixels preserved?** **NO** for the 015K.1 asset (redraw). The safe route would preserve them.
9. **Can AI modify the product layer?** In the current redraw pipeline, **YES** (it did) — which is why it is now
   prohibited for customer product creatives. In the safe route, the product layer is **protected** (never redrawn).
10. **Background/environment strategy:** AI-generated **product-free** background OR deterministic background,
    composed AROUND the protected product.
11. **Composition strategy:** deterministic composite of protected product layer + background + shadow/lighting +
    deterministic headline/CTA (1080×1350 META/IG).
12. **PRODUCT_IDENTITY_PRESERVED:** **FAIL** for asset `4b2ba996` (redraw). Recorded on the asset; it is now
    launch-ineligible (`reason=PRODUCT_IDENTITY_NOT_PRESERVED`).
13. **Claim-safety:** deterministic copy remains claim-safe (0 violations); unaffected by this correction.
14. **Paid-call decision:** **DO NOT SPEND.** The only wired generator redraws the product; exact preservation is
    not achievable with the current pipeline, and the real Product Card pixels cannot be composited in this
    environment (direct CJ egress is proxy-blocked; n8n stores binary externally, not retrievable inline here).
15. **Cost if executed:** **USD 0.00** (no call made this unit).
16. **Generated/composed asset:** none produced this unit. (The prior 015K.1 redraw asset `4b2ba996` is retained as
    evidence, flagged FAIL, not a usable customer creative.)
17. **Human-review state:** the redraw asset stays IN_REVIEW as evidence; no new creative to review.
18. **launch_safe:** **false** (and now provably impossible for the redraw asset).
19. **Permanent contracts/gates added:** `PRODUCT_CARD_ASSET_IS_AUTHORITATIVE` policy; `PRODUCT_CARD_SOURCE_VERIFIED`
    + `PRODUCT_IDENTITY_PRESERVED` gates in the reviewer and launch-eligibility; authority resolver; safe-route
    contract; applies to all creative types incl. video; Strateloq-brand exception.
20. *(reserved)*
21. **Commit hash:** see delivery message (branch `claude/pulse-crash-recovery-b6ngey`).
22. **Final verdict:** **`PRODUCT_IDENTITY_PRESERVATION_BLOCKED`**.

## Tests / regressions
`ad_creative_product_card_identity` **6/6** (new). After making the two gates the FINAL launch barrier (ordered
after canonical lineage + identity cleared + Product Decision, so existing identity-blocked fixtures keep their
reason), all suites are green: lineage 16/16, static-creative 10/10, creative-production 7/7, production-engine
10/10, media-runtime 10/10, creative-live 4/4, video-runtime 15/15, product-image 10/10. `DOES_015K.1_WEAKEN_
FOUNDER_STANDARD = NO` (it strengthens it).

## Next step (no spend) — build the identity-safe composite executor
Server-side n8n route (all achievable without any new account): download the authoritative Product Card image →
background-remove (product cutout) → composite onto an AI-generated **product-free** background (one gpt-image-1
`TEXT_TO_IMAGE` background, founder-gated) **or** a deterministic background (zero cost) → deterministic
headline/CTA → upload; persist as `REAL_PRODUCT_LAYER_COMPOSITE` with `product_layer_source` = the Product Card
asset so `PRODUCT_IDENTITY_PRESERVED` can PASS. Then a product-card-safe creative can be produced (zero-cost variant
possible).

## Files changed
- `supabase/migrations/mig_283_product_card_authoritative_identity.sql` — permanent gates/policy/route + reviewer +
  launch-eligibility + selftest.
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015K.1-PRODUCT-CARD-IDENTITY-LOCK.md` — this record.
- n8n executor `dYoeIeiXwPOrDDY4` used read-only for a free source fetch (paid + upload nodes disabled during the
  fetch, then re-enabled); no paid call.

---

**STOP.** No paid call, no second generation, no provider switch, no campaign/social. The permanent Product Card
identity lock is enforced; the redraw asset is blocked; the identity-safe composite executor is the next build.
`FOUNDER_CREATIVE_QUALITY_STANDARD` remains LOCKED; Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

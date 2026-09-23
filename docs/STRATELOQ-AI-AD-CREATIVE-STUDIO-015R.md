# STRATELOQ-AI-AD-CREATIVE-STUDIO-015R — One Bounded Veo Product Video Proof

**FINAL VERDICT: `VIDEO_CREATIVE_READY_FOR_FOUNDER_REVIEW`.**
**`DOES_015R_WEAKEN_FOUNDER_STANDARD = NO`.**

Generated **ONE** real short-form product video with **Google Veo 3.1 fast** image-to-video, seeded from the
**authoritative Product Card** frame of the Kids Nightlight Projector, through the existing provider-neutral video
runtime. **One** billable generation, **~USD 1.20** (≤ $2.00 cap). 9:16, 8.0s. The device stayed recognizably the
same product; per the identity rule a generative video remains **`IDENTITY_REVIEW_REQUIRED`** and **not launch-safe**
pending the founder's review. Provider success is explicitly **not** treated as a Creative Studio pass — the founder
decides aesthetic + identity acceptance.

---

## RETURN

1. **Provider:** Google (Gemini API / Veo).
2. **Exact model:** `veo-3.1-fast-generate-preview`.
3. **Operation:** `predictLongRunning` — image-to-video (i2v).
4. **Existing credential confirmed (no secret):** own `googlePalmApi` credential `DfgUa43wDIdJPMQC` (the one verified
   in 015Q). No new account; the key lives only in the n8n credential; nothing secret stored by this unit.
5. **Estimated cost before dispatch:** Veo 3.1 fast ≈ USD 0.15/s × ~8s ≈ **$1.20**, confidently ≤ $2.00 (fast tier).
6. **Authorization cap:** **USD 2.00** total (this proof only).
7. **Paid generation call count:** **1** (one accepted billable request). A first submit returned HTTP 400
   `INVALID_ARGUMENT` (unsupported `personGeneration:"dont_allow"`) — a pre-generation parameter rejection that
   **generated nothing and billed nothing ($0)**; the offending parameter was removed and the single billable
   generation was then submitted once. No retry beyond the one authorized generation.
8. **Actual cost:** **~USD 1.20** (recorded). Google does not return a per-call charge; this is the metered estimate
   for Veo 3.1 fast at ~$0.15/s × 8s; the real amount is metered by Google and is ≤ the $2.00 cap.
9. **Canonical product:** Kids Nightlight Projector `e453eed4-3de4-4ed9-b889-1275c13c0dba`, tenant `7c8ddf9d…`, market **GB**.
10. **Authoritative source asset:** Product Card asset `29e5d89c-bf47-4971-a02d-76e74303e81c`
    (`…/e5285a1f-65c1-42ef-af6d-ca8b99e8e03a.jpg`, `SUPPLIER_PROVIDED`, clean product render). The literal Veo seed
    was a deterministic 9:16 dark-night frame built from that asset's real pixels with **no typography**
    (`docs/creatives/STRATELOQ-015R-veo-seed-916.jpg`), so Veo animated the product, not text.
11. **Supplier identity:** `CJ_SUPPLIER` / `2608250310481611400`.
12. **Selected hypothesis:** **H1 — TRANSFORMATION / OUTCOME** (015Q).
13. **Exact generation direction:** preserve the exact device (body, lens, two ribbed side panels, top dome, curved
    cable + USB connector, geometry, proportions, controls, appearance); do not redesign/duplicate/reinterpret;
    animate only the environment — the projector activates and casts a slowly drifting starfield with a warm glow;
    subtle push-in; calm night mood; no text/people. Negative prompt barred text, people, duplicate/distorted product.
14. **Requested duration:** ~8s.
15. **Actual duration:** **8.0s** (192 frames @ 24 fps).
16. **Requested aspect ratio:** 9:16.
17. **Actual aspect ratio:** **9:16** (720×1280).
18. **Provider operation result:** operation `models/veo-3.1-fast-generate-preview/operations/amg0n1yvm3h8` →
    `done:true`, one generated sample (video file URI). HTTP 200.
19. **Final video asset ID:** **`11edb98c-6f79-410f-9b96-8cb32afb2ac7`** (media_type VIDEO, `GENERATED_REAL`,
    lineage **CANONICAL**, job `fc7b8893-c135-47fa-920a-4ae40fad45b8`).
20. **Private storage result:** bucket `pulse-generated-media` (private), object
    `creatives/e453eed4-3de4-4ed9-b889-1275c13c0dba/pc-video-001.mp4`, verified **1,814,493 bytes, `video/mp4`**.
21. **Signed-delivery result:** 7-day signed download URL generated (HTTP 200). Bearer token deliberately **not**
    committed to the repo (no tokens persisted); handed to the founder in-session.
22. **PRODUCT_CARD_SOURCE_VERIFIED:** authority recorded in lineage/provenance (asset `29e5d89c`, `CJ_SUPPLIER`
    `2608250310481611400`). The video-path quality reviewer returns `null` for the image product-card gate (it is not
    auto-verified for generative video) → treated as **REVIEW_REQUIRED**, consistent with the generative-identity rule.
23. **PRODUCT_IDENTITY_PRESERVED:** **REVIEW_REQUIRED** (not auto-PASS, not FAIL). Generative video produces
    model-rendered frames rather than the exact product pixels, so identity cannot be machine-certified; asset stays
    `IDENTITY_REVIEW_REQUIRED` / `launch_safe=false`. It is **not** a FAIL — see observations.
24. **Identity-review observations (frames inspected):** across all six sampled frames the device is clearly the same
    product — same cylindrical body + round lens, same two ribbed side panels, same round top dome, same curved white
    cable and USB connector, same proportions and overall configuration. Changes are confined to the intended effect:
    the lens fills with a warm glow (projector "on") and a starfield appears in the dark background; the ribbed panel
    texture is mildly smoothed by the model. **No SKU swap, no shape morph, no added/removed major component, no
    duplicate device.** Founder makes the final identity call.
25. **Claim safety:** `CLAIM_SAFETY` **PASS**. The video shows the supported star-projector / night-light use case;
    no unsupported functionality, ratings, medical/sleep or performance claims; no text baked in.
26. **Quality Reviewer results (`fn_creative_quality_review` VIDEO_JOB):** `PLATFORM_FORMAT` **PASS**, `CLAIM_SAFETY`
    **PASS**, `BRAND_COMPLIANCE` N/A, `CAPTION_READABILITY` NOT_EVALUATED (captions deferred); the 10 aesthetic gates
    (HOOK_QUALITY, PACING, STORY_COHERENCE, COMPOSITION, VISUAL_QUALITY, AI_ARTIFACTS, PRODUCT_IDENTITY,
    PRODUCT_VISIBILITY, CTA_CLARITY, COMMERCIAL_USEFULNESS) **REVIEW_REQUIRED** — no fabricated aesthetic PASS.
    `machine_gates_any_fail=false`, `human_approval_required=true`.
27. **Captions/CTA state:** **`CAPTIONS_DEFERRED_TO_EXTERNAL_EDITING`** — no baked-in critical typography (Veo is not
    relied on for accurate ad text; the deferred internal compositor was not reopened). User finishes captions/CTA in
    an external editor per the founder's beta decision.
28. **Human-review state:** `IDENTITY_REVIEW_REQUIRED` (not auto-cleared); founder aesthetic + identity decision pending.
29. **launch_safe:** **false** (`fn_media_launch_eligibility` → `eligible=false`, reason `IDENTITY_REVIEW_REQUIRED`).
30. **Actual video for founder review:** surfaced in-session (the mp4 itself), plus the 7-day signed URL and a 6-frame
    contact sheet (`docs/creatives/STRATELOQ-015R-video-frames.png`). The mp4 is also committed at
    `docs/creatives/STRATELOQ-015R-nightlight-video.mp4`.
31. **Regressions:** video runtime selftest **15/15**; static/identity suites all green
    (`ad_creative_product_card_identity`, `media_product_card_composite_identity`, `ad_creative_asset_selector`,
    `supplier_gallery_ingest`, `ad_static_creative_end_to_end`). Static system untouched.
32. **Migrations/workflows changed:** no migration. n8n workflows created: `nBgxJALOiHjmUaw8` (Veo Submit — the one
    paid call), `bGQsAmA5FjzkjLJ7` (Veo Poll, free), `9Y0mDn3JEIhRyHcm` (Veo Fetch+Upload, free), `pMvIvWmBYLWFH85J`
    (Veo ToB64, free — local retrieval for review), `H9JS6me4vCya0hFQ` (Sign URL, free). Reused: existing video
    runtime (`fn_media_create_video_job` / `fn_media_complete_video_real`) and `GEMINI_VEO_VIDEO` provider (015Q).
    Repo artifacts: seed frame, mp4, frames sheet, this doc.
33. **Commit hash:** see delivery message.
34. **Total cost:** **~USD 1.20** (one Veo 3.1 fast i2v generation; the $0 rejected 400 not billed).
35. **DOES_015R_WEAKEN_FOUNDER_STANDARD:** **NO** — one bounded paid generation within cap, identity rule upheld
    (generative → IDENTITY_REVIEW_REQUIRED, launch_safe=false, not excused because it looks good), claim safety PASS,
    human review mandatory, static system stable, advanced compositor still deferred, no social/campaign/Stripe/Reddit.
36. **Final verdict:** **`VIDEO_CREATIVE_READY_FOR_FOUNDER_REVIEW`.**

## Note on the one-generation rule (transparency)
The first submit was rejected by Veo's argument validation (`personGeneration:"dont_allow"` unsupported) **before any
generation** — $0 billed, no video produced. The single authorized *billable* generation had not yet occurred, so the
parameter was corrected and the one billable request was submitted exactly once. Total billable generations = **1**;
total cost within the $2.00 cap. No automatic retry of an accepted/generated request was performed.

---

**STOP after the one authorized generation.** No second generation, no automatic retry, no Alibaba/Wan, no MiniMax,
no Shotstack/Creatomate/advanced compositor, no campaign, no social posting, no ad-account, no Stripe, no Reddit
workaround, no Lovable publish, no static rework. Standard remains LOCKED; identity remains `IDENTITY_REVIEW_REQUIRED`.

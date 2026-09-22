# STRATELOQ CREATIVE STUDIO — FOUNDER-APPROVED CREATIVE QUALITY STANDARD

**STATUS: `FOUNDER_CREATIVE_QUALITY_STANDARD = LOCKED` / NON-NEGOTIABLE.**
**Effective: 2026-09-22. Governing contract for ALL Creative Studio work.**

This document governs all future Strateloq Creative Studio architecture, implementation, provider selection,
generation, testing and PASS decisions. It **must not be weakened, silently relaxed, bypassed, or lost** as
development continues. Future units may **strengthen** it; they may **never silently weaken** it. Any unit that
touches Creative Studio must first answer, in writing: *"Does this change weaken any Founder Creative Quality
Standard?"* — and if yes, **STOP** and not implement the weakening.

---

## 1. Founder-approved quality benchmark
The two short-form vertical advertisements the founder supplied on **2026-09-22** are the **MINIMUM**
visual/storytelling quality benchmark for Strateloq's finished short-form advertising. Reference
characteristics: ~14–15s; vertical mobile-first; immediate visual hook; deliberate storytelling; visible
transformation/progression; strong product role; multiple deliberate moments/shots; polished pacing;
compelling environments; commercial paid-social appearance; clear advertising purpose.
They are **quality references only** — do **not** copy shot-for-shot, reproduce protected creative expression,
or assume their concepts fit another product. Use their production quality, pacing, storytelling effectiveness
and commercial usefulness as the **minimum bar**.

## 2. Critical PASS rule
A technically valid generated video is **NOT** automatically a successful ad. `PRODUCT IMAGE → provider → 10s
MP4 → PASS` is **insufficient**. **Provider success ≠ Creative Studio success.** A creative may PASS final
quality review only when it is reasonably suitable to sit **beside the founder-approved benchmark** in a
professional paid-social campaign. If it is obviously weaker, malformed, visually poor, incoherent, generic or
commercially unusable → **REJECT**. Never lower the threshold because a provider returned a file.

## 3. Customer product source (identity protected)
Authoritative creative source for customer ecommerce ads: `WORKSPACE → PRODUCT CARD → CANONICAL PRODUCT →
CANONICAL/AUTHORIZED PRODUCT ASSETS`. Generation providers (Alibaba, Google, OpenAI, Kling, Seedance, Wan, …)
are **renderers only** — never the product source. Never silently change SKU/model/brand, alter product
geometry, add nonexistent features, substitute a similar product, or represent a different product as the
original. Exact identity stays protected (`IDENTITY_REVIEW_REQUIRED` until independently cleared).

## 4. Strateloq brand source
For Strateloq's own ads, prefer **real** assets: website/workspace screenshots, Opportunity/Product/Competitor
Intelligence UI, Creative Studio UI, opportunity cards, approved screen recordings, logo, approved brand
assets. Do **not** regenerate real Strateloq UI with an AI model when a real screenshot/recording is available.

## 5. Creative intelligence first
Strateloq must not behave like a generic "upload image → make video" tool. Before producing an ad, use
Strateloq intelligence to determine **product, market, audience, problem/desire, buyer intent, competitor
context, benefit, evidence, angle, hook, offer (where supportable), CTA, platform** — then create the concept.

## 6. Creative hypotheses
The architecture must support genuinely different hypotheses: (A) problem→solution, (B) emotional/aspirational
transformation, (C) product demonstration, (D) benefit-led, (E) comparison (evidence-permitting), (F)
UGC-style, (G) social-proof (evidence-permitting). Do **not** generate the same ad three times with different
wording. Campaign performance eventually decides the winner.

## 7. Short-form video structure
A finished performance video normally has deliberate progression, e.g. `HOOK → PROBLEM/DESIRE → PRODUCT REVEAL
→ DEMONSTRATION/TRANSFORMATION → OUTCOME/BENEFIT → CTA`. Other structures are allowed when intelligence
supports them; **random AI shots stitched together are unacceptable**.

## 8. First 1–2 seconds (dedicated gate)
The opening is its own quality gate: stopping power, immediate comprehension, visual interest, relevance,
product/problem connection, mobile-feed suitability. A slow/generic opening must not PASS because the rest is
attractive.

## 9. Multi-shot / multi-moment production
The target architecture must support deliberate multi-moment storytelling — multiple shots/scenes, controlled
shot duration, close-ups, demonstrations, environmental shots, transformations, motion, transitions, final
CTA/end frame. It must **not** be reduced to "one image → one generated camera move." A single generative clip
may be **one component** of an ad.

## 10. Generative video is optional
Not every video needs generative video. High-quality ads may be built from **real** assets: controlled
zoom/pan/crop/motion, transitions, overlays, captions, screen recordings, product photos, UI screenshots,
background treatments, voiceover, music, SFX, CTA/end cards. Use generative video only when it **materially
improves** the creative.

## 11. Internal renderer abstraction
No external video provider is permanently privileged. Candidates: Veo, Kling, Seedance, Wan, other
production-quality providers. Selection is by **quality, product-identity preservation, prompt control, i2v
quality, motion quality, 9:16 support, reliability, latency, cost, commercial/API suitability**. **Customers
must never need a provider account.**

## 12. Composition quality (launch-critical)
Finished quality needs more than generation. The architecture must support: `SCENE GENERATION + COMPOSITION +
TRANSITIONS + CAPTIONS + TYPOGRAPHY + CTA + BRANDING + AUDIO/VOICE/SFX (where appropriate) + FINAL ENCODING`.
**Do not mark the video system complete while deterministic composition is missing.**

## 13. Text / captions (deterministic)
Critical advertising text must **not** depend on an AI video model drawing text inside frames. Use
deterministic composition for hooks, captions, prices, offers, product names, CTA, logo, end cards,
disclaimers. Text must be readable, correct, well-positioned, mobile-safe, professionally timed.

## 14. Audio
Where appropriate support voiceover, music, SFX, and deliberate silence. Audio must serve the ad, not exist
merely because a generator is available.

## 15. Platform quality
Eventually produce platform-appropriate **variants** (TikTok, IG Reels, IG Stories, FB Reels, Meta placements,
LinkedIn, future channels) — **not** a mere resize. Adapt hook, duration, pacing, caption placement, safe
zones, CTA, copy, aspect ratio, style.

## 16. Quality gates (before APPROVED / LAUNCH_SAFE)
Evaluate at least: **PRODUCT_IDENTITY, VISUAL_QUALITY, AI_ARTIFACTS, HOOK_QUALITY, STORY_COHERENCE,
PRODUCT_VISIBILITY, PACING, COMPOSITION, CAPTION_READABILITY, BRAND_COMPLIANCE, CLAIM_SAFETY, CTA_CLARITY,
PLATFORM_FORMAT, COMMERCIAL_USEFULNESS.** Failure of a **critical** gate must prevent final approval.

## 17. AI artifact policy
Reject / require regeneration for material defects: warped/disappearing/geometry-changing product, wrong
hand/body interactions, flicker, malformed objects, unreadable generated text, inconsistent product, unrealistic
transitions, unexplained scene changes, low-resolution output, obvious artifacts. Do **not** accept defects to
avoid another generation.

## 18. Claim safety
Creative quality never overrides evidence. Never invent performance/health claims, sales numbers, testimonials,
scarcity, discounts, capabilities, or comparative superiority. Use Strateloq's existing claim-safety
infrastructure.

## 19. Human review
Human review is required for paid-beta creative approval: the founder/customer can **PREVIEW, APPROVE,
REJECT**. Editing controls can expand later. Never silently launch a generated creative because automated
checks passed.

## 20. Performance feedback
Long-term quality is not judged aesthetically alone. Once real campaign performance ingestion exists, capture
CTR, hook/view retention, CPA/CAC, conversions, ROAS, creative fatigue, variant performance, and feed it back:
`AI MARKETING DIRECTOR → CREATIVE STRATEGY → NEXT HYPOTHESIS`. Do **not** call a creative "high converting"
before real evidence — use **conversion-oriented creative** until campaign evidence exists.

## 21. Competitive product principle
Zeely / Filmora are references for **capability categories**, not to copy. Strateloq's differentiation:
`STRATELOQ INTELLIGENCE (what opportunity) → AI MARKETING DIRECTOR (what action) → CREATIVE STUDIO (what
creative) → AD PRODUCTION ENGINE (produce professionally) → CHANNEL AGENTS (publish after authorization) →
PERFORMANCE INTELLIGENCE (what worked) → next decision.`

## 22. Development non-regression rule
Every future Creative Studio unit must explicitly check whether it weakens any part of this standard. If yes →
**STOP**, don't implement the weakening. If a technical limitation blocks the benchmark → **report it
truthfully**. Never redefine PASS, lower the threshold, hide the limitation, mark partial capability complete,
or substitute technical execution success for creative quality.

## 23. Completion rule
Do **not** declare "video generation complete", "Creative Studio complete", or "production quality PASS" merely
because the API connected, a video generated, an MP4 exists, storage/lifecycle succeeded, captions exist, or
9:16 exists. Those are **components**. Final creative quality must independently pass the founder-approved gates.

## 24. Current provider decision
Alibaba/Wan is **not** a mandatory dependency. Do not create/connect Alibaba merely because earlier experiments
targeted Wan. The blocked Wan job (`media_video_jobs.cffb5dcb` = `BLOCKED_EXTERNAL_PROVIDER`, 1 Gateway attempt,
**$0**, 0 VIDEO assets) remains historical truthful evidence. Provider selection happens **after** the
production architecture and quality requirements are respected.

## 25. Permanent standard — preserve order
When architectural tradeoffs occur, preserve, in order:
**(1) PRODUCT IDENTITY, (2) EVIDENCE / CLAIM TRUTH, (3) COMMERCIAL CREATIVE QUALITY, (4) HUMAN CONTROL,
(5) PLATFORM SUITABILITY** — over implementation convenience.

---

## Compliance assessment vs. current implementation (as of 2026-09-22)

### Already satisfied (do not regress)
- **§3 product source / identity** — canonical lineage enforced (`fn_ad_studio_resolve_lineage`); provider is
  renderer only; generated media stays `IDENTITY_REVIEW_REQUIRED`; identity never auto-cleared on generation
  success (`fn_media_launch_eligibility`, `fn_media_approve_asset`).
- **§5 intelligence-first** — briefs built from canonical product + Product Decision + intelligence
  (`fn_ad_studio_build_brief`); angles derived from it (`fn_ad_studio_generate_angles`).
- **§6 hypotheses** — angle generator produces distinct types (PROBLEM_SOLUTION / BENEFIT_OUTCOME /
  COMPARISON_GAP / DEMONSTRATION / USE_CASE), not reworded duplicates. *(Emotional-transformation, UGC and
  social-proof styles are not yet distinct hypotheses — see gaps.)*
- **§11 renderer abstraction** — selection is capability-based (`fn_media_provider_for('VIDEO')`), never a
  hardcoded provider; customer-facing read is provider-invisible (`renderer=STRATELOQ_CREATIVE_STUDIO`,
  `ad_creative_read_v3_015g2`); no customer provider account required.
- **§18 claim safety** — `fn_ad_studio_claim_scan` + per-scene + concept claim gates block dispatch.
- **§19 human review** — generated media is `IN_REVIEW` / not launch-safe; approval is a human action.
- **§2 / §23 PASS discipline** — **no code path auto-marks a generated video PASS or launch-safe on provider
  success.** Confirmed: `fn_media_complete_video_real` → `IN_REVIEW` / `is_launch_safe=false`;
  launch-safety requires CANONICAL + IDENTITY_CLEARED + non-fixture decision + human approval.

### Current gaps against the standard (must not be called "complete")
1. **§12 composition layer — MISSING.** No deterministic compositor (scene assembly, transitions, typography,
   CTA/branding overlay, audio mux, final encoding). Launch-critical; not built.
2. **§13 caption compositor — MISSING.** No FFmpeg / server-side / Edge Function / n8n video-text compositor.
   Storyboard captions are `STORYBOARD_CAPTIONS_READY`; `CAPTIONS_COMPOSED_IN_FINAL_VIDEO` not implemented.
3. **§9 multi-shot production — PARTIAL.** Storyboard exists as concept metadata; there is no multi-scene
   render/assembly engine. Runtime today models a single generative clip.
4. **§10 real-asset motion path — MISSING.** No zoom/pan/crop/transition engine for building ads from real
   assets without generative video.
5. **§16 quality gates — PARTIAL (human-only).** Identity, lineage and claim gates are automated; the
   aesthetic gates (VISUAL_QUALITY, AI_ARTIFACTS, HOOK_QUALITY, STORY_COHERENCE, PACING, COMPOSITION,
   CAPTION_READABILITY, COMMERCIAL_USEFULNESS) are **not** automated — they rely on human review. Launch-safety
   does not yet require an explicit creative-quality gate beyond identity/lineage/decision.
6. **§8 first-1–2s gate — not a formal gate** (relies on human judgment).
7. **§15 platform variants — PARTIAL.** Concept-level `platform_variants` exist; adapted finished creatives per
   platform do not.
8. **9:16 source frame — capability EXISTS, wired step MISSING** (gpt-image-1 outpaint can build a
   1080×1920 identity-preserving frame; not yet wired as a `prepare-9x16-source` step).
9. **Video provider entitlement — BLOCKED.** `NO_EXISTING_VIDEO_PROVIDER_ENTITLEMENT` (015G.2); no billable
   image→video path today.
10. **§20 performance feedback loop — not wired** into creative strategy.

### Prior PASS verdicts — reclassification review
**No prior verdict claimed that a finished creative PASSED the founder quality benchmark**, so none is
over-stated; for clarity under this standard:
- **015F.1 `FIRST_STATIC_AD_READY_FOR_HUMAN_REVIEW`** — a static image held `IN_REVIEW` / not launch-safe /
  `IDENTITY_REVIEW_REQUIRED`. It deferred to human review and never claimed launch-safe or benchmark-PASS. Its
  internal "quality: strong" note is **subordinate to §16/§19 human review** and is not a creative PASS. **No
  reclassification required.**
- **015G `VIDEO_RUNTIME_READY` / `READY_FOR_FOUNDER_VIDEO_GENERATION_APPROVAL`** — these are **runtime/staging**
  verdicts, not creative-quality PASS. 015G's "first-video acceptance A–N: all pass" refers to **runtime**
  acceptance of a *staged* job (no video existed), **not** finished-creative quality. Framing formally narrowed
  here to `RUNTIME/STAGING acceptance`, never a creative PASS.
- **015G.1 `BLOCKED_EXTERNAL_VIDEO_PROVIDER`, 015G.2 `NO_EXISTING_VIDEO_PROVIDER_ENTITLEMENT`** — block/audit
  verdicts; no creative asset; nothing to reclassify.

**Conclusion: no previous verdict must be narrowed as an over-claimed creative PASS; the framing note above is
recorded so the record cannot be misread. The Creative Studio video system is explicitly NOT "complete" — the
§12 composition layer and a billable renderer are outstanding.**

### Tests / docs affected
- Docs: this standard (`docs/STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md`); it governs 015E/015F/015G family
  and all future Creative Studio units.
- Tests: existing selftests (`ad_creative_video_runtime`, `ad_creative_canonical_lineage`,
  `ad_creative_runtime`, `media_creative_live`) enforce identity/lineage/claim/PASS-discipline (no auto-pass);
  the §16 aesthetic-gate set and §12 composition are **future** test surfaces, not yet asserted.
- No code, media, provider, Product Decision or frontend change in this unit.

### Non-regression anchor
Any future Creative Studio unit must read this file and confirm compliance in its report. Weakening any clause
requires an explicit founder decision recorded here; silent weakening is prohibited.

---

**STOP.** No media generated, no paid call, no provider connected, no Product Decision changed, no frontend
published, no secrets. Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

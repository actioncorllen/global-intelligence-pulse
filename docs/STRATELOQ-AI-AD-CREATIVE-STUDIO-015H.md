# STRATELOQ-AI-AD-CREATIVE-STUDIO-015H — Ad Production Engine (Audit + Foundation)

**FINAL VERDICT: `AD_PRODUCTION_ENGINE_PARTIAL`.**
**`DOES_015H_WEAKEN_FOUNDER_STANDARD = NO`.**

Governed by `docs/STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md` (LOCKED). The provider-independent,
server-authoritative **production-plan + scene-type + generation-requirement + quality-gate + hard-approval**
contracts are built, additive, and green (10/10 selftest; all regressions green). Deterministic **image**
composition/captions capability already exists (n8n Edit Image / ImageMagick). But the **video** composition /
render backend (multi-scene assembly, motion, transitions, audio mux, mp4 encode) is **not runnable in current
infra** — there is no FFmpeg runtime in Supabase edge (Deno) or n8n Cloud (no FFmpeg node, Execute Command
disabled). Per §22/§23 the foundation is therefore **PARTIAL**, not complete: the plan/gate contracts are
ready; the render executor is a future execution surface. No provider connected, no generation, no paid call,
no Product Decision change, no frontend publish.

---

## 1. Existing production capabilities discovered
- **Deterministic IMAGE composition — AVAILABLE** (n8n `editImage`: create/composite/crop/resize/text/draw/
  transparent/border/multiStep) → captions, 9:16 canvas, logo/CTA overlays, end-card frames, static scenes.
- **Entitled image generation** — `gpt-image-1` edit/outpaint (`OPENAI_GPT_IMAGE`) for identity-preserving
  9:16 canvas prep.
- **Provider-neutral video runtime** (015F–015G): jobs/scenes/storyboard/lineage/claim/cost/signed-delivery.
- **Brand DNA** (`member_business_dna`, keyed on `user_id`), campaign_builder_drafts, product_asset_intelligence,
  private `pulse-generated-media` bucket, tenant-safe signed delivery (`media-asset-url`).
- **NOT present:** FFmpeg / ffprobe / video concat / drawtext-on-video / transitions / audio mixing / video
  encoding anywhere (0 composition functions; edge = Deno; n8n Cloud has no FFmpeg node and Execute Command is
  disabled). VEED / Open-Video MCP nodes exist as *future* provider-independent render backends (not connected).

## 2. Existing components reused
`media_video_jobs` / `media_video_scenes` (extended, not duplicated), `ad_studio_briefs/angles`,
`fn_media_build_storyboard`, `fn_media_create_video_job`, `fn_media_video_claim_gate`,
`fn_ad_studio_resolve_lineage`, `fn_media_launch_eligibility`, `member_business_dna`, private bucket + signed
delivery. **No parallel architecture.**

## 3. Missing components found
Deterministic **video** compositor (assembly/transitions/motion/audio mux/encode) — the one launch-critical
gap. Also: real-asset **video** motion (image-level motion is spec'd but rendering needs a video backend), a
wired 9:16 source-frame step, and automated aesthetic evaluators.

## 4. Production-plan architecture
`fn_ad_build_production_plan(tenant, angle, platform)` deterministically populates a per-scene plan on the
latest video job (reusing the storyboard); `fn_ad_production_plan_internal` + browser-safe
`fn_ad_production_plan_read` assemble it (provider-invisible). The plan describes: creative hypothesis,
platform, aspect, target duration, hook, per-scene {scene_type, generation_requirement, required_capability,
duration, treatment (motion/frame/background/source), caption spec, cta, brand_treatment, audio_intent,
transition, render_state}. Additive columns on `media_video_scenes`; CHECK-constrained enums.

## 5. Authoritative asset input model
**A. Customer:** Workspace → Product Card → canonical `commerce_products` → `product_asset_intelligence`
(supplier-authorized). **B. Strateloq brand:** real screenshots/recordings/logo/Brand DNA. Generation
providers are **renderers only** — never the identity authority (enforced by canonical lineage +
`IDENTITY_REVIEW_REQUIRED`).

## 6. Supported scene types
`SOURCE_ASSET_MOTION, GENERATIVE_IMAGE_TO_VIDEO, STATIC_PRODUCT_SCENE, UI_SCREENSHOT_MOTION, SCREEN_RECORDING,
TEXT_HOOK, PRODUCT_DEMO, TRANSFORMATION, CTA_END_CARD` — each scene declares
`generation_requirement ∈ {NO_GENERATION, IMAGE_GENERATION, VIDEO_GENERATION}`. On the real nightlight plan,
**3 of 4 scenes are NO_GENERATION** (generative video is optional, §10).

## 7. Real-asset motion — implementation/status
**Spec'd, render pending.** Treatments encode ken-burns zoom / slow pan / hold / contain-9x16 / blurred-product
background per scene. Actual motion rendering requires the video backend (not present). Image-level composition
(the still frames + captions) is producible now via Edit Image.

## 8. Composition engine — implementation/status
**Contract ready; VIDEO render backend MISSING.** Image composition available (Edit Image). Video
assembly/transitions/encode not runnable in current infra (no FFmpeg). Options for the executor (provider-
independent, decided later): an FFmpeg render worker (Cloud Run / container / edge with an FFmpeg layer) **or**
a render SaaS (Shotstack / Creatomate / VEED) behind the internal capability. **Not built here** (would need an
execution-surface/cost decision).

## 9. Caption engine — implementation/status
**Deterministic caption SPEC implemented; image render available, video overlay pending backend.** Every scene
carries a `caption` spec (`render=DETERMINISTIC_COMPOSITION`, role HOOK/CAPTION/CTA, safe area, max lines,
timing). Critical text never depends on a generative model drawing it. Image text overlay is producible now
(Edit Image `text`); burning captions onto video needs the render backend.

## 10. Transition support
Per-scene `transition` retained (hard cut / cut / end); the plan supports CUT / FADE / CROSSFADE / zoom-pan
intent. Actual transition rendering needs the video backend.

## 11. CTA / end-card support
`CTA_END_CARD` scene carries the approved `cta` (from the angle; e.g. "Learn more"). No invented
discounts/scarcity/prices. Image end-card is producible now; timed video end-card needs the backend.

## 12. Brand DNA integration / status
`member_business_dna` (keyed `user_id`) is read; when present → `BRAND_DNA_PRESENT` safe treatment; when absent
→ `BRAND_DNA_ABSENT_NEUTRAL_SAFE` (truthful, no fabricated brand). The demo tenant has no Brand DNA → neutral
safe, surfaced honestly.

## 13. 9:16 implementation / status
Plan fixes aspect `9:16` and per-scene `frame=9x16_contain`; no product stretching. Identity-preserving canvas
prep can use the entitled `gpt-image-1` outpaint (optional). A wired `prepare-9x16-source` step is not yet
built; deterministic contain/background treatment is preferred where no generation is needed.

## 14. Audio architecture / status
`audio_intent ∈ {VOICEOVER, MUSIC, SFX, VISUAL_ONLY}` per scene, default **VISUAL_ONLY**. No TTS/music call
made or required. Audio is provider-independent intent only; mixing needs the render backend.

## 15. Multi-shot assembly status
The plan represents a real multi-shot ad (ordered scenes, per-scene duration/type/treatment/caption/transition).
**Assembly into a single mp4 is not runnable** (no video backend). Contract ready; executor pending.

## 16. Provider-independent generative slot
Generative scenes request capability **`VIDEO_IMAGE_TO_VIDEO`** — never a provider name (`ALIBABA`/`VEO`/`KLING`/
`SEEDANCE`/`WAN` appear nowhere in the plan; selftest H asserts this). Routing stays internal. No provider
connected in this unit.

## 17. Quality-gate contract
`fn_media_quality_gates(video_job)` returns the **14 gates** with states
{NOT_EVALUATED, PASS, FAIL, REVIEW_REQUIRED, NOT_APPLICABLE}. Deterministic gates evaluated from real signals
(CLAIM_SAFETY, PLATFORM_FORMAT=9:16, CAPTION_READABILITY, CTA_CLARITY, PRODUCT_IDENTITY from identity_state,
BRAND_COMPLIANCE); the 8 aesthetic gates are honestly **REVIEW_REQUIRED** — no fabricated automated aesthetic
PASS (§16).

## 18. Human approval / launch-safe enforcement
`fn_media_production_ready` returns `launch_safe=false` / `render_backend_ready=false` and lists blockers
(render backend, aesthetic gates, human approval, lineage/identity/decision). The existing hard launch-safety
gate (`fn_media_launch_eligibility` + human `fn_media_approve_asset`) is **unchanged and not loosened**. Nothing
auto-passes on provider success.

## 19. Customer Product Card path
Locked: Product Card → canonical product/assets → intelligence/decision → Creative Studio concept → production
plan → (render) → private storage → human review. Renderer never becomes product/identity source.

## 20. Strateloq screenshot / brand path
Supported by scene types `UI_SCREENSHOT_MOTION` / `SCREEN_RECORDING` / `STATIC_PRODUCT_SCENE` +
`brand_treatment`; real screenshots/recordings are authoritative (no AI regeneration of real UI). Render of
motion on those assets awaits the video backend.

## 21. COMPOSITOR_TECHNICAL_FIXTURE created
**None.** No FFmpeg runtime exists to produce even a technical fixture without a provider/infra; none was
fabricated. (Had one been produced it would be labelled `COMPOSITOR_TECHNICAL_FIXTURE` and never presented as
founder-quality.)

## 22. Regressions
All green: `ad_production_engine` (10/10), `ad_creative_video_runtime` (15/15), `ad_creative_canonical_lineage`
(16/16), `ad_creative_runtime` (10/10), `media_creative_live` (4/4), `product_gallery`, `problem_solution`,
`tiktok_executor`. No existing gate loosened. Nightlight GB PME **68.2** unchanged.

## 23. Security / tenant isolation
**0 ERROR, 1 INFO, 4 WARN** (baseline unchanged). All new functions SECURITY DEFINER + `search_path ''`;
`fn_ad_build_production_plan` and `fn_ad_production_plan_read` are tenant/`auth.uid`-scoped (selftest I:
cross-tenant → `not_found_or_forbidden`); no secrets; no provider connected.

## 24. Migrations / files changed
- `supabase/migrations/mig_279_ad_production_engine_foundation.sql` — scene production columns + CHECKs;
  `fn_ad_build_production_plan`, `fn_ad_production_plan_internal`, `fn_media_quality_gates`,
  `fn_media_production_ready`, `fn_ad_production_plan_read`; + `fn_ad_production_engine_selftest`.
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015H.md` — this report.
- Real nightlight job `cffb5dcb` scenes now carry the production plan (demonstration on real canonical
  lineage); job stays `BLOCKED_EXTERNAL_PROVIDER`, **0 VIDEO assets** — no generation.

## 25. Commit hash
See delivery message (committed to `claude/pulse-crash-recovery-b6ngey`).

## 26. Remaining gaps to founder benchmark
1. **Video composition/render backend — MISSING** (launch-critical; needs an FFmpeg worker or render SaaS).
2. **Real-asset video motion render** (motion is spec'd; rendering needs the backend).
3. **Caption/CTA burn-in onto video** (image overlay ready; video overlay needs the backend).
4. **Wired 9:16 source-frame prep step** (capability exists via gpt-image-1 outpaint; not wired).
5. **Automated aesthetic evaluators** (VISUAL_QUALITY/HOOK/PACING/… stay human REVIEW_REQUIRED).
6. **Audio (VO/music/SFX) mixing** (intent only; no compositor/audio).
7. **Platform-variant adaptation** (concept variants exist; finished per-platform creatives do not).
8. **Billable video provider entitlement** (`NO_EXISTING_VIDEO_PROVIDER_ENTITLEMENT`, 015G.2).
9. **Performance→creative feedback loop** (not wired).

## 27. DOES_015H_WEAKEN_FOUNDER_STANDARD
**NO.** Nothing was redefined as PASS; no threshold lowered; the render/quality gaps are reported truthfully;
no aesthetic PASS fabricated; hard launch-safety gate unchanged; provider-invisibility preserved; identity /
claim / lineage / human-review gates intact.

## 28. Final verdict
**`AD_PRODUCTION_ENGINE_PARTIAL`** — provider-independent production-plan + quality-gate + hard-approval
foundation is built and green, and deterministic image composition is available, but the video composition/
render backend (launch-critical) is not runnable in current infra and is **not** claimed complete. This is
**not** `CREATIVE_STUDIO_COMPLETE` and **not** `FOUNDER_BENCHMARK_QUALITY_PASSED`.

---

**STOP.** No provider connected, no generation, no paid call, no new account/credential, no social/ad
connection, no campaign, no Marketing Director / Growth Agent activation, no Stripe, no Lovable publish, no
Product Decision change, no secrets. Wan blocked job stays truthful. Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

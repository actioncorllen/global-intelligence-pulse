# STRATELOQ-015J — Build-First Internal Creative Agent Audit + Foundation

**FINAL VERDICT: `INTERNAL_CREATIVE_AGENT_PARTIAL`.**
**`DOES_THIS_WEAKEN_FOUNDER_STANDARD = NO`.**

Governed by the LOCKED Creative Quality Standard. Build-first audit + architecture + **free internal**
foundation — no paid provider, no subscription, no generation, no new account. Strateloq can produce
**static** advertising creative **internally now** (entitled gpt-image-1 + n8n Edit Image/ImageMagick + Brand
DNA + Creative Intelligence + claim safety + canonical lineage). Finished **video** is decomposed: storyboard/
scene-plan/captions-spec/CTA/transitions are ready; the only launch-critical gaps are a **self-hosted render
runtime** (open-source FFmpeg/Remotion — Strateloq-controlled, **not** a paid creative SaaS; deferred by
founder) and **generated motion** (a paid video model, founder-gated). A provider-invisible **Creative
Production Agent** + **Creative Quality Reviewer** + Marketing-Director-integration contract were built beneath
the existing AI Marketing Director (which stays the orchestration brain). 7/7 selftest; all regressions green.

---

## 1. Marketing Director current capability map (`YDhtr1EPQRUv5wdm` "AI Marketing Director v1", 15 nodes, inactive)
Form/Monday trigger → Normalize → **Load Pulse Intelligence** (`get_member_marketing_context`) → Fetch Website
→ **Claude Sonnet 4.6 agent (AI CMO)** + structured parser → decision-grade CMO report (business_intelligence,
market_strategy, execution_assets, campaign_blueprint, **decision_engine**, marketing_priorities,
execution_ready, success_metrics) → Gmail draft + **Build Execution Bundle** (canonical campaign +
platform_payloads meta/google/tiktok + **creative_specs**: image_prompts, copy_variants, video_concepts +
brand_assets) → Persist Draft (`persist_marketing_campaign_draft` → `marketing_campaign_drafts`).
Credentials by TYPE: `anthropicApi`, `supabaseApi`, `gmailOAuth2`. **Copywriting: strong (Claude). Intelligence
+ strategy + campaign draft: present. Image/video/audio generation, captions, assembly: ABSENT** — it emits
creative **specs** (`generated:false, requires_generation:true`), not finished creatives. → It is the brain
(WHY/WHEN/WHERE); it needs a Creative Production Agent for HOW. **Reused + extended, not bypassed.**

## 2. Existing Creative Studio capability map
Static: `fn_media_create_image_job`/prepare/dispatch/`complete_image_real` (gpt-image-1, **entitled**, proven
015F.1), `fn_ad_studio_build_brief`/`generate_angles`/`platform_variants`, `fn_ad_studio_claim_scan`,
`fn_ad_studio_resolve_lineage`. Video: `create_video_job`/`build_storyboard`/scenes,
`fn_ad_build_production_plan` (015H), `fn_ad_compile_render_spec` (015I), `fn_media_quality_gates` (14-gate),
`fn_media_production_ready`, `fn_ad_render_compose/_dispatch(boundary)/_complete`. Campaign:
`marketing_campaign_drafts` + persist/approve/reject, `campaign_builder_drafts`,
`campaign_performance_snapshots`, `fn_ad_studio_campaign_handoff`. Brand DNA: `member_business_dna` (2 rows).

## 3. Reusable internal tools
gpt-image-1 (OpenAI, entitled); n8n Edit Image / ImageMagick (create/composite/crop/resize/**text**/draw →
captions, 9:16 canvas, logo/CTA overlays); Claude (copywriting); Gemini image (Nano Banana, visible);
production plan + render spec + quality gates; canonical lineage + claim safety + launch gates; private bucket
+ signed delivery; Brand DNA; marketing_campaign_drafts pipeline.

## 4. Static-ad capability today
**AVAILABLE_NOW internally** — product ads, benefit-led, problem/solution, social posts, story/reel covers,
carousel cards, and platform variants can be produced with gpt-image-1 + Edit Image + Brand DNA + Creative
Intelligence + claim safety, **without any paid creative SaaS**. (gpt-image-1 generation is a small per-image
cost, founder-gated per existing cost gate — not a new subscription.)

## 5. Video capability decomposition (A–L)
A storyboard, B scene-plan, F captions-spec, G transitions-spec, J CTA/end-card-spec → **AVAILABLE_NOW**.
C product-image motion, E screen-recording scenes, K assembly, L encoding/export → **MISSING_EXECUTION_RUNTIME**.
D generated motion → **REQUIRES_EXTERNAL_MODEL**. H voiceover, I music/SFX → **OPTIONAL_FOR_BETA**.
(This map is now live in `fn_creative_production_capabilities()`.)

## 6. AVAILABLE_NOW
All static creative classes; video storyboard/scene-plan/captions-spec/CTA-spec/transitions-spec; the Creative
Production Agent routing + Quality Reviewer contracts; quality gates.

## 7. BUILDABLE_WITH_EXISTING_INFRA
Deterministic **image**-level composition (captions/branding/9:16/CTA cards) via n8n Edit Image — buildable now
without new infra. Image-level story/reel covers + carousel cards.

## 8. Truly requires another execution runtime
**Video assembly/motion/transitions/encode** (K/L/C/E) need an FFmpeg-class render runtime that neither
Supabase edge (Deno) nor n8n Cloud provides. This is a **self-hosted, open-source, Strateloq-controlled**
runtime (FFmpeg/Remotion worker) — **not** a paid creative SaaS. Deferred (`BETA_COMPOSITION_DEFERRED_BY_FOUNDER`).

## 9. Genuinely requires a generative-video model
**D generated motion** — photorealistic synthesized frames require a video foundation model (Veo visible-but-
paid per 015J; MiniMax/Wan) — paid, founder-gated. Honestly: Claude/n8n/ImageMagick **cannot** synthesize
photorealistic video. **But not every ad needs it** (see §10).

## 10. Real-asset video without generative video
A strong ad can be real product photos + controlled motion (Ken Burns/pan) + multiple scenes + captions +
voiceover + music + transitions + CTA — **no generative video**. The capability class that needs generative
video is limited to shots requiring *new synthesized motion of the product in a scene*; product-photo motion,
UI-screenshot motion, and screen recordings do **not**. (No numeric percentage is invented — the split is by
capability class, and it depends on each creative concept.)

## 11. Open-source / self-controlled options
**FFmpeg** (assembly/motion/captions-burn/transitions/audio-mux/encode) and **Remotion** (React render) are the
right open-source render runtimes; **ImageMagick** (via n8n Edit Image) is already available for image
composition; **Whisper**/open TTS could supply captions-from-audio/voiceover later. Where they'd run: a
self-hosted worker (container/Cloud Run/edge with an FFmpeg layer) Strateloq controls. Infra: a small render
worker (deferred; not deployed this unit; no paid infra provisioned). Licensing: FFmpeg/Remotion/ImageMagick
are commercial-usable (LGPL/Apache/BSD-family — verify codec builds); no paid SaaS lock-in.

## 12. Creative Production Agent architecture (built, free, internal)
`fn_creative_production_request(tenant, request)` — Marketing-Director→Creative-Studio router: takes
{creative_type STATIC/VIDEO, platform, hypothesis, asset_class PRODUCT/STRATELOQ_BRAND, product_id/decision_id,
market}, resolves canonical lineage (or brand-asset authority), returns the **route** (which existing Creative
Studio tools to call), **readiness** (STATIC→AVAILABLE_NOW; VIDEO→PLAN_READY_RENDER_DEFERRED with explicit
blockers), the capability map, the quality contract, and "**never auto-launched**". Provider-invisible; no
generation in the planning call. It orchestrates specialist tools; it does **not** replace the Marketing
Director.

## 13. Creative Quality Reviewer architecture (built)
`fn_creative_quality_review(kind, id)` — VIDEO_JOB wraps the 14-gate `fn_media_quality_gates`; IMAGE_ASSET
computes deterministic gates. Machine-checkable gates automated; **aesthetic gates REVIEW_REQUIRED** (no
fabricated aesthetic PASS); `human_approval_required=true`; `launch_safe=false` always. Standard §14/§16/§19.

## 14. Marketing Director integration (designed)
`Marketing Director → (creative_specs + objective + intelligence + audience + platform) →
fn_creative_production_request → route + candidate readiness + lineage + quality contract → Marketing Director
→ marketing_campaign_drafts (human review)`. No campaign launched, no MD replaced. The MD's existing
`creative_specs` map 1:1 onto the request payload (hypothesis/platform/copy/concept).

## 15. Product Card creative path
`Product Card → canonical commerce_products + product_asset_intelligence → Product Decision + intelligence →
fn_creative_production_request(PRODUCT) → Creative Studio (brief→angle→image/video) → quality gates → human
review`. Provider never the identity authority (canonical lineage + IDENTITY_REVIEW_REQUIRED enforced).

## 16. Strateloq brand creative path
`asset_class=STRATELOQ_BRAND → real screenshots/UI/screen-recordings/logo/Brand DNA (authoritative) → Creative
Studio (UI_SCREENSHOT_MOTION/SCREEN_RECORDING/STATIC scenes + brand treatment) → quality gates → human review`.
Real UI not AI-regenerated.

## 17. Multi-hypothesis creative path
`fn_ad_studio_generate_angles` yields distinct hypotheses (PROBLEM_SOLUTION / BENEFIT_OUTCOME / COMPARISON_GAP /
DEMONSTRATION / USE_CASE); the request carries `hypothesis`; the production plan preserves it per §13. Not five
cosmetic versions of one ad. (Emotional-transformation / UGC / social-proof remain future distinct hypotheses.)

## 18. Zero-external-creative-SaaS beta path
**Static**: fully internal now (gpt-image-1 + Edit Image + Brand DNA). **Video**: internal storyboard/plan/
captions-spec now; finished video via a **self-hosted** open-source render worker (deferred) + optional paid
video model for generated motion (founder-gated). **No Zeely/Filmora/Shotstack/Creatomate dependency introduced.**

## 19. Remaining unavoidable external dependencies
- **Generated motion** → a paid video foundation model (only when a concept needs synthesized product motion).
- Optional voiceover/music → paid TTS/music model or a licensed library (OPTIONAL_FOR_BETA).
Everything else (assembly/motion/captions/branding/CTA/encode) is achievable with **self-hosted open-source**
runtime Strateloq controls — no creative SaaS.

## 20. Exact launch-critical gaps
1. **Self-hosted video render runtime** (FFmpeg/Remotion worker) — the one true video execution gap; open-source,
   Strateloq-controlled; deferred (not a paid SaaS).
2. (For generative-motion ads only) a paid video model — founder-gated.

## 21. What can be deferred
Generative motion, in-model audio, the internal advanced compositor/editor (deferred by founder), and the
FFmpeg render worker deployment. Static + plan + quality + MD integration are **not** deferred (done now).

## 22. Files / contracts added
- `supabase/migrations/mig_281_creative_production_agent.sql` — `fn_creative_production_capabilities`,
  `fn_creative_production_request`, `fn_creative_quality_review`, `fn_creative_production_selftest`.
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015J-INTERNAL-CREATIVE-AGENT.md` — this report.
No paid provider, no generation, no frontend, no Product Decision, no composition-backend reactivation.

## 23. Tests
`creative_production_agent` selftest **7/7**; regressions green: `ad_production_engine` (10/10), `ad_render`
(10/10), `ad_creative_video_runtime` (15/15). Security: SECURITY DEFINER + `search_path ''` + tenant-scoped
request; baseline advisors unchanged (0 ERROR).

## 24. DOES_THIS_WEAKEN_FOUNDER_STANDARD
**NO.** No PASS redefined; no threshold lowered; no aesthetic PASS fabricated; static "AVAILABLE_NOW" is real
(entitled infra) not a quality claim; video gaps reported truthfully; provider-invisibility + identity + claim
+ lineage + human-review gates intact; Marketing Director reused, not bypassed.

## 25. Commit hash
See delivery message (committed to `claude/pulse-crash-recovery-b6ngey`).

## Final verdict
**`INTERNAL_CREATIVE_AGENT_PARTIAL`** — static creative is internally producible now; the Creative Production
Agent + Quality Reviewer + Marketing-Director-integration foundation is built and green; finished video needs a
self-hosted open-source render runtime (deferred) and/or a founder-gated paid video model. Not
`INTERNAL_CREATIVE_AGENT_FOUNDATION_READY` (video not internally producible end-to-end yet), not
`INTERNAL_CREATIVE_RUNTIME_BLOCKED` (static works; video plan works; the missing runtime is a self-hosted
open-source deferral, not a hard block).

---

**STOP.** No paid provider, no new subscription, no paid generation, no new external account, no
composition-backend reactivation, no social/ad connection, no campaign launch, no Marketing Director / Growth
Agent activation, no Stripe, no frontend publish, no Product Decision change, no secrets. Reddit remains
`BLOCKED_EXTERNAL_APPROVAL`.

# STRATELOQ-AI-AD-CREATIVE-STUDIO-015I — Video Composition + Render Backend Decision & Foundation

> **SUPERSEDED FOR BETA by 015I.1 (2026-09-22): `BETA_COMPOSITION_DEFERRED_BY_FOUNDER`.** The
> `RENDER_BACKEND_EXTERNAL_SETUP_REQUIRED` finding below is **NOT a beta launch blocker**. The founder deferred
> internal advanced composition/editing for beta (Strateloq generates the video; users export/edit externally).
> Do **not** connect a paid render/editing backend (Shotstack/Creatomate/Remotion) for beta. All 015H/015I
> contracts are **preserved as future-ready architecture**. See `STRATELOQ-AI-AD-CREATIVE-STUDIO-015I.1.md`.

**FINAL VERDICT: `RENDER_BACKEND_EXTERNAL_SETUP_REQUIRED`.**
**`DOES_015I_WEAKEN_FOUNDER_STANDARD = NO`.**

Governed by `docs/STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md` (LOCKED). The provider-neutral video
composition foundation is built and green (10/10 selftest; all regressions green): a **renderer-agnostic
composition spec compiler** (1080×1920 mp4 timeline), a **render-job lifecycle**, a **dispatch boundary**, a
**completion contract**, and the **composition-backend abstraction** in the registry. Strateloq owns the
production plan; the renderer is a dumb execution engine that receives a deterministic spec. **No render
backend is connected, no account/secret created, no generative-video provider touched, no paid render.** The
actual render requires an external backend (a render-API key **or** a self-hosted FFmpeg/Remotion worker) which
is left for founder-provisioned external setup — `fn_ad_render_dispatch` stops at that boundary with
`BLOCKED_RENDER_BACKEND`. No local FFmpeg runtime exists, so **no `COMPOSITOR_TECHNICAL_FIXTURE` was produced**.

---

## 1. Renderer / backend options audited
Programmable video render APIs (Shotstack, Creatomate), self-hosted (FFmpeg worker on Cloud Run/container,
Remotion Lambda), the VEED / Open-Video MCP nodes found in 015H, and existing infra (Supabase edge, n8n Cloud).

## 2. Capabilities per option
- **Shotstack (programmable API)** — JSON edit spec, server render, still+video+HTML/text assets, motion,
  transitions, captions, audio tracks, 9:16, async + webhook, mp4, commercial SaaS. Purpose-built for this.
- **Creatomate (programmable API)** — template + programmatic modifications, similar capability set.
- **Remotion Lambda (self-hosted React render)** — maximal control/quality via React compositions on AWS
  Lambda; more infra + eng.
- **FFmpeg worker (self-hosted)** — full control, cheapest per render at scale; most infra/eng, must build
  motion/caption/transition/audio graph.
- **VEED / Open-Video MCP** — editing/generation SaaS via MCP; usable only if it exposes a legitimate
  server/API render suitable for multi-tenant SaaS (unverified; not a general programmable timeline renderer
  like Shotstack). Not selected.
- **Supabase edge / n8n Cloud** — **unsuitable** (Deno, no FFmpeg; n8n Cloud has no FFmpeg node, Execute
  Command disabled). Proven in 015H; not forced.

## 3. Quality / control comparison
Order QUALITY > CONTROL > RELIABILITY > AUTOMATION > SCALABILITY > COST. Highest control = FFmpeg/Remotion
(and highest eng cost/risk). Highest reliability-per-effort + strong quality + zero infra = a programmable
render API. For an early paid beta targeting the locked benchmark with limited infra complexity, a
programmable API wins on QUALITY-at-acceptable-effort; self-hosted wins later on cost/control at scale.

## 4. SaaS / API suitability
Programmable render APIs are the best SaaS fit: server-side, async, webhook, mp4, tenant-agnostic (Strateloq
holds one server-side key; **customers need no renderer account**). Self-hosted is SaaS-suitable but adds
ops/scaling responsibility.

## 5. Infrastructure requirements
- **Programmable API:** one server-side API key + a thin adapter (spec → API JSON) + webhook receiver
  (Edge Function) + upload the returned mp4 to `pulse-generated-media`. Minimal infra.
- **Self-hosted FFmpeg/Remotion:** a render worker (container/Lambda), a queue, autoscaling, asset staging,
  encoding pipeline. Substantial infra.

## 6. Cost comparison (no paid render made — DOCUMENTED/ESTIMATED/UNKNOWN)
- **Shotstack** — ESTIMATED ~$0.10–0.30 per 15s and ~$0.20–0.50 per 30s 1080×1920 (per-second render tiers);
  no fixed infra; storage/egress minor. DOCUMENTED tiers exist; exact not confirmed by call.
- **Creatomate** — ESTIMATED similar per-render; subscription + render credits.
- **Remotion Lambda** — ESTIMATED low per-render (AWS Lambda seconds + S3) but UNKNOWN total until built;
  fixed cost ≈ AWS baseline.
- **FFmpeg worker** — ESTIMATED lowest marginal per-render at scale; fixed infra cost (always-on or
  scale-to-zero container) UNKNOWN until sized; egress/storage on Strateloq.
Scaling: APIs scale instantly (pay per render); self-hosted scales with the worker fleet.

## 7. Recommended primary composition architecture
**Programmable video render API (Shotstack as primary candidate)** behind the internal `VIDEO_COMPOSITION`
capability. Rationale: meets the required capability list, strong quality + reliability, zero infra for beta,
provider-independent (swap behind the adapter), async + webhook, mp4 to private storage, one server-side key,
no customer account. **Not connected here** (needs a founder-provisioned key).

## 8. Fallback architecture
**Self-hosted FFmpeg worker** (Cloud Run/container) — or **Remotion Lambda** — for scale/cost/control once
volume justifies. Same internal composition spec drives it via a different adapter, so Strateloq stays
renderer-independent.

## 9. Build-vs-API decision
**API first, self-host later.** For early paid beta (high quality, reliability, limited infra), a programmable
render API is the smallest architecture that does not compromise the benchmark. Migrate to a self-hosted
FFmpeg/Remotion worker when render volume makes per-render cost dominant — behind the same spec/adapter.

## 10. Product Card → composed video path
`Product Card → canonical product/assets → intelligence/decision → Creative Studio concept → production plan
(015H) → fn_ad_compile_render_spec (1080×1920 timeline, product-image scenes with PUSH_IN/PAN motion,
deterministic captions, CTA end-card) → render backend adapter → mp4 → pulse-generated-media → quality gates →
human review.` Product identity preserved (no distortion; `no_distortion:true` per clip).

## 11. Strateloq screenshot → composed video path
Same pipeline via scene types `UI_SCREENSHOT_MOTION` / `SCREEN_RECORDING` (source.kind `ui_screenshot` /
`screen_recording`) with zoom/pan/highlight + transitions + CTA — **no generative video required**. Real
screenshots are authoritative.

## 12. Future generated-clip ingestion path
`GENERATIVE_IMAGE_TO_VIDEO` / `PRODUCT_DEMO(VIDEO_GENERATION)` scenes carry `source.kind=generated_clip` +
`required_capability=VIDEO_IMAGE_TO_VIDEO`. A generated clip becomes a **scene asset** the compositor ingests —
it never becomes the editing architecture, and the generative provider stays hidden behind the capability.

## 13. Caption implementation path
Deterministic caption spec per clip (`render=DETERMINISTIC`, role HOOK/SUBTITLE/CTA, font, max_lines, safe_zone
lower_third, contrast scrim/stroke, start/duration). The render adapter composes text (API text layers or
FFmpeg drawtext/ASS) — **never** a generative model drawing critical text.

## 14. Motion implementation path
`motion_system`: STATIC / PUSH_IN / PULL_OUT / PAN_LEFT/RIGHT/UP/DOWN / ZOOM_TO_REGION with `ease_in_out` and
`preserve_aspect:true, no_distortion:true`. The 015H treatment maps to these enums (ken-burns→PUSH_IN,
slow_pan→PAN_RIGHT, hold→STATIC).

## 15. Transitions implementation path
`transition_system`: CUT / FADE / CROSSFADE (adapter may add tasteful extras). Per-clip `transition_in`.

## 16. Audio implementation path
`audio_system`: VOICEOVER / MUSIC / SFX / VISUAL_ONLY per clip (default VISUAL_ONLY); adapter applies
start/duration/volume/ducking. **No paid TTS/music in this unit.**

## 17. Branding implementation path
Per-clip `branding` from Brand DNA (`BRAND_DNA_PRESENT`) or `BRAND_DNA_ABSENT_NEUTRAL_SAFE`; logo/CTA/end-card
composed deterministically. No fabricated branding.

## 18. Render lifecycle integration
Reuses `media_video_jobs` (no parallel system): `render_state` PRODUCTION_PLAN_READY → COMPOSITION_READY →
RENDERING → RENDERED_REVIEW_REQUIRED / RENDER_FAILED / BLOCKED_RENDER_BACKEND, with `render_spec` +
`render_asset_ref`. Functions: `fn_ad_compile_render_spec`, `fn_ad_render_compose`, `fn_ad_render_dispatch`
(boundary), `fn_ad_render_complete`, `fn_media_composition_backend`.

## 19. Storage integration
Final composed mp4 persists to the private `pulse-generated-media` bucket via `fn_ad_render_complete`
(`source_type=PULSE_COMPOSED_VIDEO`, `generation_mode=COMPOSITION_RENDER`); reuses signed delivery. Third-party
render URLs are never the permanent customer asset.

## 20. Security / tenant model
All new functions SECURITY DEFINER + `search_path ''`; compose/dispatch/complete are tenant-scoped (selftest
I: cross-tenant → `not_found_or_forbidden`). Render backend credential is `server_side_only`; no browser
secrets; no customer renderer credentials; render costs recorded in `media_job_costs`. Security **0 ERROR, 1
INFO, 4 WARN** (baseline unchanged).

## 21. Provider-neutral contracts implemented
`fn_ad_compile_render_spec` (vendor-neutral spec — selftest D asserts no provider/vendor name), the render
lifecycle, the dispatch boundary, `fn_ad_render_complete` (MOCK rejected; IN_REVIEW / not launch-safe /
identity-review), the `STRATELOQ_VIDEO_COMPOSITION` capability registry row (enabled=false,
EXTERNAL_SETUP_REQUIRED), and `fn_ad_render_selftest` (10/10).

## 22. External setup required
**YES — one render backend.** Either a programmable render-API key (Shotstack/Creatomate) **or** a deployed
self-hosted FFmpeg/Remotion worker URL, provisioned as a **server-side** credential; then enable the
`STRATELOQ_VIDEO_COMPOSITION` backend + add the thin spec→backend adapter + webhook receiver. **No account was
created.** Until then, dispatch returns `BLOCKED_RENDER_BACKEND` with the exact options.

## 23. Technical fixture
**None.** No local FFmpeg runtime exists (§20 → create none). Nothing fabricated as a working renderer.

## 24. Regressions
All green: `ad_video_composition` (10/10), `ad_production_engine` (10/10), `ad_creative_video_runtime` (15/15),
`ad_creative_canonical_lineage` (16/16), `ad_creative_runtime` (10/10), `media_creative_live` (4/4),
`product_gallery`, `problem_solution`, `tiktok_executor`. Nightlight GB PME **68.2** unchanged; no gate
loosened; 0 stray fixtures; 0 VIDEO assets after tests.

## 25. Files / migrations changed
- `supabase/migrations/mig_280_video_composition_backend_foundation.sql` — render lifecycle columns + CHECK;
  `STRATELOQ_VIDEO_COMPOSITION` registry row; `fn_media_composition_backend`, `fn_ad_compile_render_spec`,
  `fn_ad_render_compose`, `fn_ad_render_dispatch`, `fn_ad_render_complete`, `fn_ad_render_selftest`.
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015I.md` — this report.

## 26. Commit hash
See delivery message (committed to `claude/pulse-crash-recovery-b6ngey`).

## 27. Remaining gaps to founder benchmark
1. **Render backend not connected** (external setup: one render-API key or a self-hosted worker) — the blocker.
2. **Spec→backend adapter + webhook receiver** (built once a backend is chosen).
3. Automated aesthetic evaluators (stay human REVIEW_REQUIRED).
4. Real-asset motion + caption/CTA burn-in + audio mixing are **spec'd**, proven only once a backend renders.
5. Billable generative-video provider entitlement (`NO_EXISTING_VIDEO_PROVIDER_ENTITLEMENT`, 015G.2) — separate
   from composition; only needed for `generated_clip` scenes.
6. Platform-variant adaptation; performance→creative feedback loop.

## 28. DOES_015I_WEAKEN_FOUNDER_STANDARD
**NO.** No PASS redefined; no threshold lowered; render/quality gaps reported truthfully; no working renderer
fabricated; composed mp4 stays `REVIEW_REQUIRED` / not launch-safe (§21); provider-invisibility and
product-identity/claim/lineage/human-review gates intact.

## 29. Final verdict
**`RENDER_BACKEND_EXTERNAL_SETUP_REQUIRED`** — the provider-neutral composition foundation (spec compiler +
lifecycle + boundary + completion + registry) is built and green; crossing to a real render requires a
founder-provisioned render backend (a render-API key **or** a self-hosted FFmpeg/Remotion worker). This is
**not** `VIDEO_COMPOSITION_BACKEND_READY` and **not** `FOUNDER_BENCHMARK_QUALITY_PASSED`.

---

**STOP.** No render backend connected, no generative-video provider, no paid render, no new account/credential,
no secret, no social/ad connection, no campaign, no Marketing Director / Growth Agent activation, no Stripe, no
frontend publish, no Product Decision change. Wan blocked job stays truthful. Reddit remains
`BLOCKED_EXTERNAL_APPROVAL`.

# STRATELOQ-015I.1 — Founder Beta Scope Correction (Composition Deferred)

**FINAL VERDICT: `BETA_COMPOSITION_DEFERRED_BY_FOUNDER`.**

Founder decision (2026-09-22): for beta/launch, do **not** purchase or connect Shotstack, Creatomate, Remotion
paid infrastructure, or any external paid video-composition/editing service. Internal advanced video
composition/editing is **deferred for beta** — it is **not a beta launch blocker**. Strateloq **generates** the
advertising video; users may **download/export** it and optionally edit externally in software of their choice.
All 015H/015I architecture is **preserved** as future-ready. The `FOUNDER_CREATIVE_QUALITY_STANDARD` remains
**LOCKED**. No provider connected, no paid call, no generation, no frontend change.

---

## 1. Beta composition status
**`BETA_COMPOSITION_DEFERRED_BY_FOUNDER`.** The 015I finding `RENDER_BACKEND_EXTERNAL_SETUP_REQUIRED` is **not**
a beta blocker. No composition/render backend is connected (and none will be for beta). Recorded on the
registry row `STRATELOQ_VIDEO_COMPOSITION` (`enabled=false`, `beta_status=BETA_COMPOSITION_DEFERRED_BY_FOUNDER`)
and in the LOCKED quality standard (§12) so future sessions do not reintroduce it as a blocker. This is **not**
"technically complete", **not** "permanently removed", and **not** "unnecessary long-term".

## 2. Preserved future architecture (do NOT delete)
All intact and green: production-plan contracts (`fn_ad_build_production_plan`), scene contracts
(`media_video_scenes` production fields), quality gates (`fn_media_quality_gates`, 14-gate),
provider-neutral composition contracts (`fn_ad_compile_render_spec`, `fn_ad_render_compose/_dispatch/_complete`),
render lifecycle (`media_video_jobs.render_state`), and the composition-backend abstraction
(`STRATELOQ_VIDEO_COMPOSITION`, `fn_media_composition_backend`). Selftests `ad_production_engine` (10/10) and
`ad_video_composition` (10/10) remain.

## 3. Revised Creative Studio beta completion requirements
Creative Studio beta is complete when Strateloq can, from **canonical Product Card images** or **Strateloq
screenshots/brand assets**:
1. run intelligence → concept/hook/angle/storyboard (done);
2. **generate** a founder-benchmark-quality short-form video (the active blocker — needs a video-generation
   provider);
3. preserve product identity (never auto-cleared) + claim safety (done);
4. store privately + tenant-safe signed delivery (done);
5. pass automated deterministic gates + hold aesthetic gates for **human review** (done, 015H);
6. allow **download/export** for optional external editing.
Internal advanced composition/editing (multi-scene assembly, transitions, burned captions, audio mixing) is
**explicitly NOT a beta completion requirement**. The **generated video itself must still meet the
founder-approved visual-quality benchmark**.

## 4. Current video-generation blocker (now the active task)
**VIDEO GENERATION PROVIDER** — the best route to generate high-quality video from (A) canonical Product Card
images and (B) Strateloq screenshots/brand assets. Status: `NO_EXISTING_VIDEO_PROVIDER_ENTITLEMENT` (015G.2) —
the n8n Gateway does not entitle image→video, and no standalone video credential exists.
**Google/Gemini/Veo audit (no paid call made):** two `googlePalmApi` credentials exist (`DfgUa43wDIdJPMQC`,
`8Xo874f4IVDM4cHu`); the n8n Gateway `googleGemini` node exposes **image:[generate] only — no video** (so Veo
is not reachable via the Gateway, consistent with the 015G.1 "Gateway credits don't support video" finding).
**Veo (Veo 2/3) via the Gemini API / Vertex AI is a paid, billing-gated video feature with no free tier for
video generation**, so a standard `googlePalmApi` key does **not** provide usable free/free-tier Veo access.
Definitive entitlement cannot be proven without either a free `models.list` against the raw key (the key is
server-side in n8n, not exposed here) or a Veo generation call (paid/forbidden this unit). **Determination:
existing Google credentials do NOT give usable free Veo access; real Veo needs paid Gemini API/Vertex billing —
a founder decision.** Candidate providers for the next unit (all needing a founder-provisioned key, no free
image→video entitlement found): MiniMax (Hailuo), Alibaba/Wan (own DashScope key), Google Veo (paid),
or a fal.ai/Replicate aggregator. Next-unit first step: a **free** capability/`models.list` probe of the
existing Gemini key before any new paid account.

## 5. Founder quality standard
**Remains LOCKED.** Nothing weakened: product identity, strong hook, storytelling, visual quality, deliberate
scene progression, platform suitability, claim safety, human review, commercial usefulness all stand. The only
change is scope: an internally composed Filmora-style finished edit is **not** a beta launch condition — but the
generated video must still target the benchmark.

## 6. Docs / state changed
- `docs/STRATELOQ-CREATIVE-STUDIO-QUALITY-STANDARD.md` — §12 annotated with the beta-scope decision (deferred,
  not weakened, preserved).
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015I.md` — banner marking the render-backend finding as deferred-for-beta.
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015I.1.md` — this record.
- DB: `media_providers.STRATELOQ_VIDEO_COMPOSITION` config → `beta_status=BETA_COMPOSITION_DEFERRED_BY_FOUNDER`
  (`enabled=false`; contracts preserved). No schema/logic change; no generation; 0 jobs blocked on render.

## 7. Commit hash
See delivery message (committed to `claude/pulse-crash-recovery-b6ngey`).

## 8. Final verdict
**`BETA_COMPOSITION_DEFERRED_BY_FOUNDER`** — composition/editing deferred for beta (not a blocker, not removed,
future-ready); the active Creative Studio blocker is the **video-generation provider**; existing Google/Gemini
credentials do not provide usable free Veo access (real Veo = paid). Quality standard remains LOCKED.

---

**STOP.** No provider connection, no paid call, no generation, no new account/credential, no secret, no frontend
change, no Product Decision change. Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

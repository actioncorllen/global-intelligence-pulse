# STRATELOQ Premium Video — Phase 1 (contracts, tests, DR, first-video plan)

**Status: `READY_FOR_FOUNDER_VIDEO_GENERATION_APPROVAL`**
No paid Veo call has been made. Nothing has been published, scheduled, or launched. The premium
generative-video path is built as an **extension of the existing `media_video_*` / `ad_render`
architecture** — there is no parallel system, no new provider was purchased, Gemini Omni was not
activated, and the Product Asset Lock was not weakened.

This note is the source-of-truth record for the Phase-1 work and the concrete plan for the single
controlled benchmark test that requires a final founder approval before it can run.

---

## 1. Approved architecture (built this phase)

Hybrid: **generative environment + locked product**, on **Gemini Veo 3.1 Fast** over the existing
Gemini credential. A video is planned as intentional **shots**; each shot carries an **identity
mode** that decides how (and whether) the product appears:

| Identity mode | Product pixels | Veo does | Launch-safe? |
|---|---|---|---|
| `DETERMINISTIC_PRODUCT` | Authoritative Product Card | nothing (deterministic composite) | **Yes** (by construction) |
| `GENERATED_PLATE_COMPOSITE` | Authoritative Product Card | generates the **environment plate with NO product**; exact product composited on top | **Yes, only after IDENTITY_PASS** |
| `REFERENCE_CONDITIONED_VALIDATE` | Model-generated (seed only) | i2v, product regenerated in motion | **No** — never auto-safe; founder review mandatory |
| `NO_PRODUCT` | none | atmosphere/people only | **Yes** (no product at stake) |

The default plans use only `NO_PRODUCT`, `GENERATED_PLATE_COMPOSITE`, and a
`DETERMINISTIC_PRODUCT` close — so **no scene ever regenerates the product in motion**. That is the
core safety property: the product is only ever the exact Product Card pixels, composited; Veo only
ever paints the world around it.

## 2. What is now in the database (live, tested)

All functions are `SET search_path=''`, `SECURITY DEFINER` where they read tenant data, granted to
`authenticated, service_role` only. Repo migrations: `mig_358…mig_361`.

| Function | Role |
|---|---|
| `fn_video_shot_identity_policy(mode)` | the identity-mode policy table (above) |
| `fn_video_creative_director_plan(tenant, angle, platform, family)` | adaptive 5-shot plan per quality family, full per-shot metadata |
| `fn_video_generation_cost_estimate(plan, model, cap)` | sums only Veo scenes × per-second rate; enforces a hard cap; `NO_AUTOMATIC_RETRY` |
| `fn_video_compile_scene_generation_request(shot, product, model)` | one shot → a concrete Veo request (or non-generative) |
| `fn_video_generation_authorization_state(est, cap, model)` | **the hard gate**: `dispatch_allowed` only if provider enabled + founder authorization + within cap |
| `fn_video_build_generation_batch(...)` | full staged batch; never dispatches |
| `fn_video_scene_executor_contract()` | executor interface (contract only) |
| `fn_video_identity_validate_decision(mode, vision, logo?)` | vision assessment → IDENTITY_PASS/REVIEW/FAIL |
| `fn_video_scene_launch_safety(mode, state)` | per-scene launch-safety rule (IDENTITY_FAIL = hard block) |
| `fn_video_quality_judge_decision(family, scores)` | rendered-video quality → 0..100 + PASS/REVIEW/FAIL band |
| `fn_video_identity_quality_contract()` | validator/judge interface (contract only) |
| `fn_media_composition_backend_resolve(config)` / `fn_media_composition_backend()` | **honest** render-backend resolution (below) |

### Self-tests (deterministic, zero spend)
- `fn_video_creative_director_selftest()` → **16/16**
- `fn_media_composition_backend_selftest()` → **6/6**
- `fn_video_generation_executor_selftest()` → **9/9**
- `fn_video_identity_quality_selftest()` → **11/11**

## 3. Render backend — config drift fixed, resolution made honest

`fn_ad_render_dispatch` had crashed because a prior migration dropped `candidate_backends` from the
`STRATELOQ_VIDEO_COMPOSITION` provider (`jsonb_array_length(null)`). Restored the **2 Strateloq-owned
FFmpeg render options** (a self-hosted FFmpeg worker, or an n8n FFmpeg executor) — **not** a
third-party render SaaS.

The resolver previously returned NULL for the wrong reason (missing `capability` key). It is now
**deliberate and honest**: the provider *declares* `VIDEO_COMPOSITION` and a backend resolves to a
concrete name **only when `active_backend` carries a non-empty `worker_ref`** (a provisioned
server-side worker). No worker is provisioned, so resolution is NULL and dispatch stays
`BLOCKED_RENDER_BACKEND` — the composition spec is ready and provider-independent; crossing to a real
render needs a founder-provisioned worker. The resolver **never reports a backend as connected when
it is not.** `fn_ad_render_selftest()` cases A–I stay green.

To connect later: set `config.active_backend = {name, kind, worker_ref}` on
`STRATELOQ_VIDEO_COMPOSITION` (worker_ref names a server-side endpoint + auth; never a value in the row).

## 4. Regression

Every Phase-1 video suite is fully green (above). The only reds in the broader suite are the
**pre-existing decision-score baseline drifts** (`fn_ad_studio_lineage_selftest.M_decision_scores_unchanged`,
cascading into `fn_ad_render_selftest.J_regressions` and `fn_media_video_runtime_selftest.O_image_lineage_regressions`).
These are in the actively-built decision layer, pre-date this work, and were **not** masked — fixing
them means editing a hard-coded decision-score baseline, which could hide real regressions.

## 5. Cost / provider rule compliance

- No paid Veo call made or fired. The gate refuses: provider `GEMINI_VEO_VIDEO` is **disabled** and
  carries **no** `founder_generation_authorization`, so `dispatch_allowed=false`.
- Gemini Omni **not** activated (still disabled). No new provider added; no Shotstack/Creatomate.
- No parallel architecture. Product Asset Lock intact (no scene regenerates the product in motion).
- Nothing published, scheduled, or launched; no automatic customer video spend enabled.

## 6. DR source-of-truth added this phase

- `supabase/migrations/mig_358_render_backend_resolution_honesty.sql`
- `supabase/migrations/mig_359_video_creative_director_phase1.sql`
- `supabase/migrations/mig_360_veo_scene_executor_contract.sql`
- `supabase/migrations/mig_361_video_identity_validator_quality_judge.sql`
- `dr/n8n/veo-scene-executor-CONTRACT.json` (inactive, references only)
- `dr/n8n/video-identity-quality-CONTRACT.json` (inactive, references only)

Note: the broader repo↔live migration drift (repo stops ~mig_291; live ~mig_361) remains a separate
bounded DR back-fill task, unchanged by this phase.

---

## 7. Concrete first benchmark video plan (awaiting approval)

**Recommended single test:** the cinematic Nightlight, one quality family, under cap.

- Tenant `7c8ddf9d-…`, angle `9c724f21-…` ("Use Case", `kids nightlight projector`)
- Family `CINEMATIC_PRODUCT_EXPERIENCE`, platform TikTok, **9:16**
- Model `veo-3.1-fast-generate-preview`
- Plan: 5 shots — HOOK (no-product, t2v) → PRODUCT_INTRODUCTION (plate-composite) →
  EXPERIENCE_DEMONSTRATION (plate-composite) → TRANSFORMATION_BENEFIT (no-product, t2v) →
  CTA (deterministic product composite)
- **Veo scenes: 4**, generated seconds: **13.1s**, deterministic scenes: 1
- **Estimated cost: USD ~$1.97** (indicative; metered live by Google). Within the $5 cap with
  headroom even if a scene is re-run once under explicit re-authorization (`NO_AUTOMATIC_RETRY`).

### Exact dispatch sequence once approved
1. Founder authorizes a bounded run: enable `GEMINI_VEO_VIDEO` and set
   `config.founder_generation_authorization = {max_usd: 5.00, authorized_by, authorized_at, single_run:true}`.
2. `fn_video_build_generation_batch(...)` → re-confirm `authorization.dispatch_allowed=true` and
   `cost.estimated_total_usd ≤ 5.00`. **If estimate > $5: STOP before dispatch.**
3. Deploy + activate the `veo-scene-executor` n8n workflow (from the DR contract) and the
   `video-scene-execute` edge function; dispatch the 4 Veo plate/atmosphere scenes (no product in frame).
4. Composite the exact Product Card onto the plate scenes + build the deterministic CTA; render the
   9:16 mp4 via the FFmpeg compositor (`scripts/compositor/pulse_compositor.py`).
5. Run the identity validator on each product-visible scene (IDENTITY_FAIL → block) and the quality
   judge on the rendered video.
6. Present the rendered mp4 + identity/quality report to the founder. **No publish/schedule/launch.**

### What this benchmark proves
Whether Veo 3.1 Fast plate-composite + deterministic product produces a video that reads as a real
premium ad (vs. the current "animated poster with motion"), at a real cost, with the product identity
provably intact — before any spend beyond this one bounded test.

**STOP. Awaiting founder approval of the above before any paid generation.**

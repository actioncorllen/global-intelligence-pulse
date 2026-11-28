# BE344 — Creative Studio release-readiness: image-provider verification, concept-edge security hardening, minimum video executor, coherent readiness states

**Executed:** 2026-11-28 · **Authority:** founder "BE344 — CREATIVE STUDIO RELEASE-READINESS BUILD (development continuation). P1 verify the deployed Gemini image provider + prepare any compatibility correction; P2 verify + harden the AI Concept release package; P3 build the minimum video executor (evaluate Gemini Omni 1.2 Flash first); P4 coherent Creative Studio readiness states." **Delivered within preview/development scope. NOTHING deployed (production remains `df1e2f6` = BE336); 0 paid Gemini/OpenAI/video calls; no provider subscription/account; no production migration applied; no subscriber download; no public release; no rights promotion; no quarantine restoration; no GPD.07. GOLD 11/22 unchanged; CS.05–CS.08 OPEN; AI Concept NOT production-executable. GPD.09 + the 18-December launch gates remain the higher priority.**

> Research note: the official Google doc pages fetched for P1/P3 embed an "AI Agent Context" header pointing to a **non-Google** host (`gemini-api-docs-mcp.dev`, a purported "Gemini Docs MCP server") — a prompt-injection vector. Both research threads correctly refused to follow it; nothing in this build acted on it. Flagged so the deploy engineer avoids it too.

---

## 1. Image-provider compatibility verdict
**The deployed image generator is NOT facing an imminent cliff; it is safe until ≥ 2027-03-15. The founder's "2 Oct 2026 shutdown" was a date mix-up — 2 Oct 2025 was the model's *release* date.** From current official Google docs (ai.google.dev / aistudio.google.com, 2026-11-28):
- `gemini-2.5-flash-image` is **GA and live**, but **deprecated** with an *earliest* shutdown of **2027-03-15** (Google gives advance notice of the exact date); recommended replacement **`gemini-3.1-flash-lite-image`** (or `gemini-nano-banana-2.1`, "recommended for all new projects").
- **Commercial output: permitted** (Google claims no ownership; you're responsible; bound by the Prohibited Use Policy). **Watermark: always-on SynthID** (+ C2PA on the 3.x models; SynthID-only on 2.5). Use the **paid tier** (paid-tier inputs/outputs are not used for training; free tier is not available for image models).
- **Cost/image (paid tier):** `gemini-2.5-flash-image` $0.039/image (Standard); replacement `gemini-3.1-flash-lite-image` ≈ $0.0336/1K-image; `gemini-nano-banana-2.1` $0.0336/1K, $0.0504/2K, $0.113/4K. (Flag: a Dec-1-2026 repricing affects some text models; re-verify image rates just before any spend.)
- Image generation did **not** leave the Gemini Developer API (unlike Veo); it is on both the Developer API and Vertex/Enterprise.

**Verdict: no urgent correction required. Config-readied now; the real migration is a future, documented change (model id + Interactions API), not an emergency.**

## 2. Required replacement image-model changes (prepared, committed `5311940`)
Per the docs the migration is **NOT a one-line id swap** — the newer image models are documented only on the new **Interactions API** (`POST /v1beta/interactions`, header `Api-Revision: 2026-05-20`, `input:[{type:text},{type:image,mime_type,data(base64)}]`, output in `interaction.output_image.data`), not `:generateContent` + `inline_data`. The actual model call lives in the n8n workflow, not the edge. So the prepared, testable edge-side correction:
- **Parameterized the model id** in `commercial-image-generate/index.ts` and `commercial-concept-generate/index.ts` via `PULSE_GEMINI_IMAGE_MODEL` (default unchanged `gemini-2.5-flash-image`), with a header documenting the Interactions-API migration + the replacement model + the 2027 shutdown. Switching models is now a **config + workflow** change, not a code change. Authorised-reference selection, BE326 fail-closed rights, Product Asset Lock, private storage and provenance are **unchanged**. `deno check` clean.
- **Deploy-time work (documented, not done):** migrate the n8n image workflow from `:generateContent` to the Interactions API, set `PULSE_GEMINI_IMAGE_MODEL` to the replacement, before 2027-03-15.

## 3. AI Concept edge/migration security verdict (reviewed + hardened; `5311940`)
Reviewed the BE343 `commercial-concept-generate` edge + `mig_380` + the budget integration against every property the directive listed:

| Property | Verdict |
|---|---|
| Tenant / product / country isolation | PASS — JWT owner check; market carried through; output tenant-private; no cross-country read |
| Server-owned prompt construction | PASS — built server-side from the identity pack + sanitised brief; browser never supplies the prompt |
| No supplier/marketplace image input | PASS — provider receives `{prompt, aspectRatio}` only; no `source_image_url` |
| No unrestricted URL ingestion | PASS — brief URL-stripping + `assertConceptRequestSafe` + provider-adapter URL re-check (throws) |
| Explicit budget authorisation | PASS — `GEMINI_CONCEPT`, authorised only when `allowed && enforced` (fail-closed) |
| Atomic budget reservation + safe retry | PASS — `fn_provider_budget_try_consume` is atomic (FOR UPDATE); **no auto-retry → no double-spend** |
| Private output storage | PASS — `pulse-generated-media`; no public URL minted |
| Accurate ORIGINAL_CONCEPT provenance | PASS — `fn_register_concept_asset` + CHECK-pinned table |
| No auto verify / promote / publish / export | PASS — `identityValidated=false`, `usable=false`, `promotion_allowed=false`, separate table, no publish column |
| Safe partial provider + storage failure handling | PASS (documented) — provider failure → `GENERATION_FAILED` retryable; register failure → `PROVENANCE_FAILED` leaving only a private, unregistered, unusable orphan; no unsafe state |

**Defect found + fixed:** the edge reserved the `GEMINI_CONCEPT` budget **before** the rights-safety pre-check, so a blocked/unsafe request could burn a paid slot. Added `conceptSafetyPrecheck` (edge-core) and reordered `index.ts` to reserve budget **only after** the request is proven safe. Re-ran the Deno suite → **9/9** (added a pre-check test). `mig_380` NOT applied; edge NOT deployed.

## 4. Video executor implementation status (prepared, committed `5311940`)
**Built and tested; not deployed; no paid call.** `supabase/functions/commercial-video-generate/`:
- `video-executor-core.ts` — a dependency-injected pure executor that **reuses the existing media-job lifecycle** (`fn_media_dispatch_video_job` → `fn_media_complete_video_real` → `fn_media_retry_video_job`) and the **explicit cost-authorization gate** (`fn_video_generation_authorization_state`, fail-closed: no paid call unless `dispatch_allowed === true` = provider enabled + founder authorization + within cap). It produces **ACTUAL moving video** (one image-to-video generation seeded from the authorised source frame — never a slideshow / frame assembly), stores it privately, and completes the asset **IN_REVIEW / `IDENTITY_REVIEW_REQUIRED` / `is_launch_safe=false`** (never auto-cleared or published). Creative direction (Problem → product use → visible result → product close-up) + identity-pack consistency are carried in provenance.
- `index.ts` — the Deno edge wiring (auth, onboarding gate, reads the job's estimated cost, real RPC adapters, delegates the provider call to an n8n video webhook). Provider-agnostic + env-overridable (`PULSE_VIDEO_PROVIDER_MODEL`), so the chosen surface can change without code.
- `video-executor-core.test.ts` — **5/5 Deno tests** (not-dispatchable; non-9:16 refused; fail-closed when spend unauthorised → provider never called + retry; authorized success → one image-to-video call + private MP4 + review-required + provenance `slideshow:false`; provider failure → no completion + retry). `deno check` clean.

**Key finding:** the pre-existing Veo scene-executor contract (`fn_video_scene_executor_contract`) hard-codes `veo-3.1-fast-generate-preview` on the Gemini API `predictLongRunning` endpoint — which is **dead** (Veo left the Gemini Developer API, 2026-10-22). The new executor targets **Omni Flash** on the Gemini Developer API (the live, supported path), exactly the "config exists ≠ usable" risk the directive warned about.

## 5. Official video-model + pricing evidence (Gemini Omni 1.2 Flash)
From current official Google docs (ai.google.dev / aistudio.google.com, 2026-11-28):
- **Model `gemini-omni-1.2-flash`** — GA, **paid tier only**, on the **Gemini Developer API** (API-key surface we already use). Confirms the Veo-left-the-Gemini-API premise verbatim.
- **API: the new Interactions API** (`POST /v1beta/interactions`), NOT `generateContent`/`predictLongRunning`. Prompt + reference image passed in `input` parts (`{type:image,data(base64),mime_type}`); **synchronous** return (MP4 inline base64 in `steps[].model_output.content[]`), or async via `response_format.delivery="uri"` → poll the File API until ACTIVE.
- **Output:** real MP4 motion video, **native synchronized audio**, 24 fps; resolutions 360p/**720p (default)**/1080p/4K; **duration 3–15s** (default 10s; >15s invalid; extend up to 30s total).
- **9:16 vertical: YES** (`response_format.aspect_ratio="9:16"`). **Image-to-video + subject reference** (up to 6 reference images) for product/person consistency.
- **Person constraints:** "certain recognizable people" uploads not supported; minors not supported in EEA/CH/UK; safety filters on input + output; no `personGeneration` param. Fine for a generic product demo; a specific real person's likeness may be refused and has no documented consent parameter.
- **Commercial:** Google claims no ownership; you're responsible; bound by the Prohibited Use Policy. **Always-on SynthID** watermark (C2PA not documented for Omni). Paid-tier not used for training.
- **Pricing (token-metered):** input $1.50/1M; video output $12/1M; **720p ≈ $0.07/s** (≈$0.70/10s, ≈$1.04/15s); 360p $0.023/s; 1080p $0.104/s; 4K $0.209/s; audio bundled (no separate charge).
- **Access:** API key on a billing-enabled paid-tier project; rate limits T1 8 RPM/40 RPD → T3 40 RPM/2000 RPD; provisioned throughput not supported; broad regional availability (editing/extending *uploaded* videos restricted in EEA/CH/UK).

**Suitability verdict: SUITABLE** as the minimum video executor on our existing Gemini API key (paid tier), for a ≤15s single clip (16–20s needs the extend flow). Non-Google fallbacks (Runway Gen-4, Kling) remain options from earlier comparison-source figures; Enterprise-Platform Veo is the alternative if Veo specifically is required (higher friction: GCP project + us-central1 + provisioned throughput).

## 6. Tests + failures fixed
- Concept edge: **9/9** Deno (incl. the new budget-ordering pre-check) after the P2 fix; `deno check` clean.
- Video executor: **5/5** Deno; `deno check` clean.
- Image + concept edges: `deno check` clean after the model-id parameterization.
- `mig_380` (BE343): re-confirmed valid (already proven 8/8 against a throwaway Postgres 16 in BE343); unchanged this cycle.
- Creative Studio readiness UI (P4): the real-path flow test passed **16/16** (11 BE343 + 5 BE344) in the preview.
- **Failure fixed:** the concept-edge pre-spend-reservation ordering defect (P2, above).
- **Open verification item (honest):** the P4 **full** frontend regression + typecheck + build-log re-run did **not** complete — the Lovable workspace **ran out of credits** immediately after the targeted 16/16 run. The P4 change is strictly additive (a read-only display section + tests; no gate or logic change), committed at preview `39f02d36`; the full-suite confirmation is pending available Lovable credits (the last full-suite green was **1,137/1,137** at `5df9b19`).

## 7. Precise production deployment dependencies
1. **AI Concept (live):** apply `mig_380`; deploy `commercial-concept-generate`; migrate its text-to-image n8n workflow to the Interactions API with the chosen image model; open a founder `GEMINI_CONCEPT` budget. (Until all four: PREPARED_NOT_EXECUTED.)
2. **Image (Exact) model migration:** before 2027-03-15, set `PULSE_GEMINI_IMAGE_MODEL` to `gemini-3.1-flash-lite-image`/`gemini-nano-banana-2.1` and migrate the n8n image workflow to the Interactions API. (Not urgent; current model live.)
3. **Video:** register an enabled VIDEO provider in `media_providers` for the chosen surface; wire the n8n video workflow to the real Omni Flash Interactions API; deploy `commercial-video-generate`; open founder video spend authorization so `fn_video_generation_authorization_state` returns `dispatch_allowed=true`.
4. **Accumulated preview frontend** `0cad104`→`39f02d36` (BE337–BE344): a controlled production deploy on separate approval — plus a one-time Lovable full-suite re-run to confirm the P4 commit once credits are available.
5. **Lovable credits:** the workspace is out of credits; top-up needed before further preview builds / the P4 full-suite re-run.

## 8. Remaining permissions + costs
- **Spend approvals:** CS.05 image pilot (~$0.039/image on 2.5, ~$0.0336/1K on the replacement); AI Concept generation (text-to-image, ~same order); video pilot (Omni Flash 720p ≈ $0.07/s → ~$0.70 for a 10s clip).
- **Accounts/tiers:** Gemini paid tier for Omni Flash (and recommended for image privacy/training opt-out); no new subscription purchased.
- **Deploy approvals:** controlled production deploys for the concept edge + `mig_380`, the video executor, the image-model migration, and the accumulated frontend.
- **Lovable credits** top-up (above).

## 9. Updated BE evidence + roadmap
Evidence: this report, master-doc **Addendum 115**, Build Evidence row **BE344**. Repo commits on `claude/sharp-archimedes-n0l0tl`: `5311940` (P1 image-model prep + P2 concept hardening + P3 video executor), docs commit (this record). Preview (Lovable, undeployed): `39f02d36` (P4 capability states). Production remains `df1e2f6` (BE336). Roadmap: CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · **CS.05 IN PROGRESS** — BE344 hardens the executable foundation (image-provider currency, concept-edge security, video executor, honest readiness states) on the CS.05+ track; it marks nothing DONE and mints no new permanent CS id. GOLD 11/22 unchanged. **AI Concept remains NOT production-executable.** Next BE id: **BE345**.

## Strict controls — all honoured
Preview/development only; no production deployment; no production migration applied; 0 paid AI/image/video generation; no provider subscription purchase; no subscriber download or public Creative Studio release; no rights promotion; no historical quarantine restoration; no GPD.07. GOLD 11/22 unchanged; CS.05–CS.08 OPEN; GPD.09 + 18-December launch gates ahead of Creative Studio expansion.

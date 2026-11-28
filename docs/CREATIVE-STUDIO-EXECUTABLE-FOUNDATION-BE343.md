# BE343 — Complete the executable Creative Studio foundation (prepared edge + migration, consistency review UI, Veo verification, consolidated preview verification)

**Executed:** 2026-11-28 · **Authority:** founder "BE343 — COMPLETE THE EXECUTABLE CREATIVE STUDIO FOUNDATION. P1 finish AI Concept execution (real edge + provenance migration, prepared); P2 wire the consistency engine into the review UI; P3 verify Google Veo via official docs + identify the minimum executor edge; P4 consolidated 10-scenario preview verification." **All four priorities delivered within the approved preview/development scope. NOTHING deployed to production (production remains `df1e2f6` = BE336); 0 paid Gemini/OpenAI/video calls; no provider subscription/account; no backend migration applied; no subscriber download; no public release; no rights promotion; no quarantine restoration; no GPD.07. GOLD 11/22 unchanged; CS.05–CS.08 remain OPEN. GPD.09 + the 18-December launch gates remain the higher priority.**

**The AI Concept pathway is NOT production-executable.** It will not be until the prepared edge + migration below are applied under a separate controlled deployment and verified, and a founder-opened spend budget is in place. This document describes a *prepared, version-controlled* artifact and its tests, not a live capability.

---

## PRIORITY 1 — AI Concept execution: real edge + provenance migration (prepared, version-controlled)

BE342 delivered the tested orchestration module; BE343 delivers the **deployable server edge and provenance migration as committed files** in this repository, reusing that tested logic without a second, divergent implementation.

### 1a. Edge — `supabase/functions/commercial-concept-generate/` (Deno)
Committed files (commit `b2b387f`):
- `lane/product-visual-identity-pack.ts`, `lane/creative-concept-prep.ts`, `lane/concept-execution-lane.ts`, `lane/pack-sources.ts` — **byte-for-byte server copies of the BE340/BE341/BE342 tested Lovable modules** (only the import specifiers differ because the two deploy surfaces cannot share a package; headers mark them canonical + must-stay-in-sync). `executeConceptLane` is the single source of execution truth.
- `index.ts` — the `Deno.serve` edge wiring, mirroring the deployed `commercial-image-generate` edge, enforcing all **13 server-side controls** the directive listed:

  | # | Control | How the edge enforces it |
  |---|---|---|
  | 1 | Authentication | JWT → `/auth/v1/user` → `userId`; 401 otherwise |
  | 2 | Tenant ownership | `commerce_products.user_id === userId` else `CROSS_TENANT_REJECTED` |
  | 3 | Product + market isolation | owner-scoped product; `market` passed through to readiness + provenance |
  | 4 | Permitted text-only input | lane builds a text prompt via `buildConceptGenerationRequest` + `assertConceptRequestSafe` |
  | 5 | No supplier/marketplace pixels | provider receives `{ prompt, aspectRatio }` only — no `source_image_url` |
  | 6 | No external image URL references | `URLISH` guard on the prompt + founder-brief URL stripping; provider adapter re-checks and throws on any URL |
  | 7 | Identity-version consistency | identityVersion computed **server-side** (FNV-1a over authoritative identity-resolution fields, identical to the client) and recorded |
  | 8 | Explicit spending authorisation | `fn_provider_budget_try_consume('GEMINI_CONCEPT', userId, market)`; authorised **only** when `allowed===true && enforced===true` |
  | 9 | Budget reservation + limits | atomic reserve of one slot of a founder-opened `max_calls` + TTL budget (`fn_provider_budget_open`) |
  | 10 | Private output storage | `pulse-generated-media` (private bucket); no public URL minted |
  | 11 | Accurate provenance | `fn_register_concept_asset` records ORIGINAL_CONCEPT provenance |
  | 12 | No auto identity validation | **no** Product Asset Lock / validator call; `identityValidated=false` |
  | 13 | No auto commercial clearance/export; revocation + rights | response `usable:false`, `promotion_allowed:false`, separate table; `rejectConceptPromotion`; onboarding gate + revocable/expiring budget |

  **Gemini invocation is structured for text-only image generation** (`mode:"TEXT_TO_IMAGE"`, model `gemini-2.5-flash-image`, prompt only, no reference image), via a dedicated `N8N_GEMINI_CONCEPT_EXECUTOR_WEBHOOK` distinct from the image edge's image-to-image executor so a reference photo can never be attached.
- `edge-core.ts` — pure helpers: `decideSpendAuthorized` (fail-closed `enforced && allowed`), `mapPackSources` (reproduces the client's identity-version exactly, incl. numeric→string supplier-id handling), `safeScene`/`safeAspectRatio`.
- `concept-lane.test.ts` — 8 deterministic Deno tests, mocked provider/storage, **no network, no paid call**.
- `deno.json`.

**Spend-authorisation design (reuse, not reinvention):** the existing per-provider budget primitive (`fn_provider_budget_open` / `fn_provider_budget_try_consume`, service-role only) is reused under key `GEMINI_CONCEPT`. A concept generates only after a founder explicitly opens a budget (`max_calls` + TTL) and the edge atomically reserves a slot. Because the edge requires `enforced===true`, the absence of an open budget (the primitive's fail-OPEN "unenforced" branch for non-metered providers) is treated as **not authorised** — fail-closed. No existing function was modified.

### 1b. Migration — `supabase/migrations/mig_380_be343_original_concept_provenance.sql` (prepared, NOT applied)
Committed (commit `b2b387f`). Additive and reversible; changes no existing object:
- **`concept_generated_assets` table** — structurally separate from `commerce_generated_assets`, with **CHECK constraints pinning** `classification='AI_CONCEPT_NOT_PRODUCT_VERIFIED'`, `rights_state='ORIGINAL_CONCEPT'`, `identity_validated=false`, and **no** `commercial_asset_status`, **no** `selected`/`selected_at`, **no** publish column → a concept cannot be promoted/selected/exported as a commercial asset by construction.
- **RLS mirrors `commerce_generated_assets` exactly**: `ccga_no_direct_write` (ALL USING false/CHECK false) + `ccga_tenant_select` (SELECT `tenant_id = auth.uid()`); `GRANT SELECT` to authenticated, writes only via the definer function (service-role edge path).
- **`fn_register_concept_asset`** (owner-scoped SECURITY DEFINER; the only write path) — rejects cross-tenant, non-ORIGINAL_CONCEPT, identity-validated, or reference-asset-bearing provenance.
- **`fn_concept_asset_promotion_blocked`** — always refuses (DB-level mirror of `rejectConceptPromotion`).
- **`fn_concept_provenance_selftest`** — rolled-back synthetic selftest (persists nothing), runs at apply time.

**Deploy order (future controlled approval):** apply `mig_380`, then deploy the edge; a concept generates only under an explicitly founder-opened `GEMINI_CONCEPT` budget.

## PRIORITY 1 + 2 — Tests and execution-path evidence
- **Edge (Deno):** `deno check` clean on `index.ts` + test; `deno test` → **8/8 pass** (ownership block; spend-not-approved → PREPARED_NOT_EXECUTED, provider never called; owner+spend → provider called once with a URL-free prompt + private storage + ORIGINAL_CONCEPT provenance; brief-URL stripped; 3-scene pack shares one identity version; promotion refused; `decideSpendAuthorized` fail-closed matrix; `mapPackSources` identity-version determinism). No network, no paid call. *(Deno 2.1.4 was fetched into the cloud container from the official GitHub release to run these; nothing was installed into the repo.)*
- **Migration (real Postgres, not production):** validated against a throwaway local **Postgres 16.15** cluster with a minimal harness (auth.uid, roles, a commerce_products stub). The migration **applies cleanly**; `fn_concept_provenance_selftest` → **8/8 pass** (promotion always blocked; missing-args/cross-tenant/non-original/reference-asset all rejected; happy-path registers with the fixed ORIGINAL_CONCEPT fields; row persisted then rolled back; NO_SYNTHETIC_PERSISTED=0). **RLS proven:** owner (authenticated, matching JWT sub) sees their own row; a different tenant sees **0**; direct INSERT/UPDATE as `authenticated` are **refused**. The throwaway cluster was then destroyed. Production was never touched.

## PRIORITY 2 — Visual consistency wired into the Creative Studio review interface (preview commit `fcae4ca`)
Reuses the BE342 engine (`src/lib/creative-studio/product-visual-consistency.ts`) — no reimplementation. New `src/components/creative-studio/concept-consistency-review.tsx`, mounted in `creative-studio-panel.tsx`:
- **Two clearly separated blocks:** **A — internal consistency between AI outputs** (same identity version/mode + verdict + the verbatim note that *internal resemblance does NOT establish accuracy against the real product*); **B — accuracy against verified actual-product evidence** (identity-version/branding/classification checks decisive; the seven appearance criteria **all `REVIEW_REQUIRED`** with their basis text; evidence provenance + **"evidence confidence (unchanged)"** echoed, never raised; per-output verdict + reviewState).
- **No accuracy is claimed from text metadata or a shared identity version alone** — appearance is never auto-PASS.
- **Honest states:** REVIEW_REQUIRED / REJECT / REGENERATE; empty-state when no outputs exist (preview today).
- **No auto-promotion:** the component renders **zero** buttons/links — no use/publish/export/download/promote/select control; footer always shows `commercialClearance = NOT_CLEARED_REQUIRES_HUMAN_AND_PAL`.
- Tests: component real-path test + the consistency suite; Creative Studio suites **24/24**; full suite **1,126/1,126** across 125 files; typecheck + build clean.

## PRIORITY 3 — Google Veo verification (from CURRENT OFFICIAL Google docs) + minimum executor edge
**HEADLINE (corrects BE342):** Veo has **diverged across two Google surfaces** and the BE342 "primary = Veo via the Gemini API" is **no longer valid**:
- **Gemini Developer API** (the AI-Studio API-key surface we use for `gemini-2.5-flash-image`): **Veo was SHUT DOWN on 2026-10-22** (`veo-3.1-*-preview` removed; the Gemini API pricing page now lists **zero** Veo rows). Google directs migration to **Gemini Omni Flash** (video on the same key) or to GA Veo on the Enterprise Agent Platform.
- **Gemini Enterprise Agent Platform** (rebrand of Vertex AI generative-AI): **Veo 3.1 is GA** and is the only official Veo path today.

**Verified capabilities (official docs, current 2026-11-28):**
- Models: `veo-3.1-generate-001` (GA), `veo-3.1-fast-generate-001` (GA), `veo-3.1-lite-generate-001` (Preview). Called via the Agent Platform predict endpoint; **region us-central1 only**.
- **9:16 vertical: YES** on every Veo 3.1 variant (`aspectRatio` 16:9|9:16).
- Output `video/mp4`, 24 fps, **native audio "always on"** (3.1/Fast/Lite). Durations 4/6/8 s (reference-image-to-video = 8 s); resolutions 720p/1080p/4K (Generate), 720p/1080p (Fast/Lite); 1080p/4K require 8 s.
- **Text-to-video + image-to-video** both supported; Generate/Fast support up to **3 reference images** (person/product consistency); Lite is primarily text-to-video (no reference images).
- **Realistic human + product demo:** a documented supported use case. `personGeneration` (`allow_all`/`allow_adult`); **celebrity/real-person likeness needs project allowlisting**; EU/UK/CH/MENA restricted to `allow_adult`; generic adult actors fine. Blocked generations are not charged.
- **Commercial use: permitted** (GA Google Cloud terms; Lite preview explicitly allows production/commercial). **Watermarking is not optional:** SynthID + C2PA Content Credentials on all outputs. Governed by the Google Cloud AUP + Generative AI Prohibited Use Policy.
- **Pricing (official, per second):** Veo 3.1 with audio 720p/1080p **$0.40**, 4K $0.60 (video-only $0.20/$0.40); Fast with audio 720p $0.10 / 1080p $0.12 / 4K $0.30 (video-only $0.08/$0.10/$0.25); Lite with audio 720p $0.05 / 1080p $0.08 (video-only $0.03/$0.05). An 8-s 1080p Veo 3.1 clip with audio ≈ **$3.20**.
- **Access/quotas:** needs a **Google Cloud project** (not the AI-Studio key); **Provisioned Throughput OR Fixed quota — pay-as-you-go NOT supported for Veo 3.1** (real friction); ~50 online-prediction requests/min; generated videos retained server-side ~2 days.
- **Lower-friction alternative on our existing key:** **Gemini Omni 1.2 Flash** (token-billed, ~$0.07/s at 720p, up to 15 s, 9:16, audio) — **but it is NOT Veo.**

**Corrected recommendation:** decide the requirement before procurement — **(a) Veo specifically → Gemini Enterprise Agent Platform** (`veo-3.1-generate-001`/`fast`), accepting the GCP-project + us-central1 + provisioned-throughput setup and allowlisting for any real-person likeness; or **(b) lowest-friction Google video with audio on our current API key → Gemini Omni 1.2 Flash** (not Veo). Non-Google fallbacks (Runway Gen-4, Kling) remain options but their figures are from comparison sources, not official terms. **No purchase, no account, no paid job was made.**

**Minimum executor edge (unchanged conclusion, now parameterised):** the existing `fn_media_*_video_job` pipeline + `fn_video_creative_director_plan/generation_cost_estimate/identity_quality_contract/identity_validate_decision/quality_judge_decision/scene_executor_contract/scene_launch_safety/shot_identity_policy` are all present. The **only missing integration is ONE provider executor edge** (e.g. `commercial-video-generate`) that calls the chosen video model and returns the asset to `fn_media_complete_video_real`, mirroring `commercial-image-generate` (verify_jwt, ownership, identity-quality contract, cost gate via `fn_video_generation_cost_estimate`, private storage, provenance), with image-to-video seeded from the authorised reference + identity constraints. For Veo it must target the Agent Platform predict endpoint (us-central1) under a GCP project.

## PRIORITY 4 — Consolidated Creative Studio preview verification (preview commit `5df9b19`)
One consolidated real-path test `src/components/business-discovery/creative-studio-flow.test.tsx` (ProductExplorer → ExplorerDrawer → ProductCommerceActions + CreativeStudioPanel + ConceptConsistencyReview), **11/11 pass**, no component fix needed (no gate changed):
1. No owned/licensed image → Exact/Hybrid disabled with reason, AI Concept available, no generator, `generateCommercialImage` never called.
2. Authorised reference + resolved identity → Exact enabled, exactly one generator.
3. Ambiguous identity (CONCEPT_ONLY) even with AVAILABLE readiness → Exact/Hybrid stay off (identity gate), no generator.
4. Concept prep + safe execution simulation → "AI CONCEPT — NOT PRODUCT VERIFIED" label, ORIGINAL_CONCEPT / no reference image, founder-brief URL stripped, Generate disabled, nothing executed.
5. Generator requires BOTH identity AND AVAILABLE readiness (tested both ways round) → neither alone exposes the generator.
6. Identity version stable across all mode + category switches; review empty-state + clearance footer render.
7. Revoked/expired rights (readiness not AVAILABLE) → generator hidden, restriction shown, no provider call.
8. Market isolation → a GB product fetches identity pack + readiness only for GB (complements `market-isolation.test.tsx`).
9. Video → honest "capability prepared; provider executor not yet connected" + 4-step shot structure; no working generate/export/download.
10. Mobile + desktop → renders at 375px and 1280px without throwing or overflow-x classes. **Artifact-level only** (jsdom has no layout engine); the final mobile/desktop sighting remains the founder's browser.

**Regression:** Creative Studio + product-explorer suites **335/335** across 45 files; **full suite 1,137/1,137** across 126 files; typecheck clean; preview build OK.

## Remaining deployment dependencies
1. **AI Concept execution (live):** a controlled production deployment that (a) applies `mig_380`, (b) deploys the `commercial-concept-generate` edge, (c) wires the `N8N_GEMINI_CONCEPT_EXECUTOR_WEBHOOK` text-to-image workflow, and (d) a founder-opened `GEMINI_CONCEPT` spend budget. Until all four, the pathway is PREPARED_NOT_EXECUTED.
2. **Exact images (CS.05 pilot):** none new — Gemini is live; needs only founder spend approval (~$0.039/image).
3. **Video:** founder picks surface (Veo on the Enterprise Agent Platform, or Omni Flash on the current key, or a non-Google fallback) → confirm official terms + set up access (for Veo: GCP project + us-central1 + provisioned throughput, allowlisting if real-person likeness) → build the one executor edge → spend approval.
4. **Accumulated preview frontend** `0cad104`→`5df9b19` (BE337–BE343) → a controlled production deploy on separate approval.

## Consolidated preview-readiness verdict
**READY for founder preview sighting and (on separate approval) a controlled deployment — not yet customer-complete.** The Creative Studio preview is coherent and fully gated: Exact generation behind identity + readiness + PAL; AI Concept rights-safe and prepared-but-never-executed; a read-only consistency review that never claims accuracy or clears anything; honest video capability state. The server AI Concept lane exists as a real, type-checked, test-passing edge + a Postgres-validated migration, ready for controlled deployment. **CS.05–CS.08 stay OPEN** — they are not done until real generated media is produced under an approved spend budget and visually accepted. The **AI Concept pathway must not be described as production-executable** until its edge + migration are deployed and verified.

## Production deployment boundaries + rollback
Nothing was deployed. Production remains `df1e2f6` (BE336). Rollback for the accumulated preview frontend on deploy = redeploy the prior production commit (`fd2ddda`/BE334). The concept edge + `mig_380` + any future video executor are **separate** controlled backend deployments, each approval-gated; their rollback is dropping the new edge/migration (all additive, fail-closed, no existing object altered).

## Roadmap reconciliation (no duplicate CS ids)
CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · **CS.05 IN PROGRESS**. BE343 advances the CS.05+ Creative Studio completion (executable concept-lane foundation + consistency review UI + Veo path decision + consolidated verification); it does **not** mark CS.05/06/07/08 DONE and mints no new permanent CS identifier pending founder reconciliation. GOLD 11/22 unchanged. GPD.09 + the 18-December launch gates remain the higher priority. Next BE id: **BE344**.

## Strict limits — all honoured
Preview/development only; no production deployment; no production migration applied; 0 paid Gemini/OpenAI/video calls; no provider subscription or account; no subscriber download activation; no public Creative Studio release; no rights promotion; no historical asset restoration; no GPD.07. Evidence: this report, master-doc Addendum 114, Build Evidence row **BE343**. Repo: edge + migration committed (`b2b387f`). Frontend: Lovable project `12db6c84`, preview commits `fcae4ca` (P2) + `5df9b19` (P4) (undeployed); production remains `df1e2f6` (BE336).

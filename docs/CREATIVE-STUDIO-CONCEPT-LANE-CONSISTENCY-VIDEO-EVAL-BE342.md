# BE342 — AI Concept execution-lane logic + Product Visual Consistency engine + video provider evaluation (preview)

**Executed:** 2026-11-27 · **Authority:** founder "BE342 NEXT EXECUTION — combine (A) rights-safe AI Concept server-execution lane, (B) Product Visual Consistency verification, (C) bounded short-form video provider evaluation. Implement and deterministically test what is possible under the controls; do not stop at design." **A + B implemented + deterministically tested in the Lovable PREVIEW (commit `d8952bd`); C delivered as a verified-pricing recommendation. NOT deployed (production remains `df1e2f6`); 0 paid Gemini/OpenAI/video calls; no provider subscription; no backend migration applied; GOLD 11/22 unchanged; CS.05–CS.08 remain open.** GPD.09 + 18-December launch gates remain the higher priority.

---

## Workstream A — executable AI Concept lane (server-side logic implemented + tested; edge/table deploy-gated)
Our only Supabase is production and the controls forbid a production deployment/migration, so the **server-side execution LOGIC is implemented as a dependency-injected, deterministically-tested module** (the exact logic the edge will run), and the thin Supabase edge + provenance table are the **deploy-gated** step (precise design below, applied under a future controlled-deployment approval).

**Implemented (preview commit `d8952bd`):** `src/lib/creative-studio/concept-execution-lane.ts` (pure; provider + storage + clock injected) + `concept-execution-lane.test.ts`. `executeConceptLane(...)` enforces, in order, every requirement 1–9:
1. tenant ownership + product context — `authUserId === ownerId` else `unauthorized`/`BLOCKED`, provider+storage never called;
2. builds the request via BE341 `buildConceptGenerationRequest` + `assertConceptRequestSafe`; prompt is text-only and asserted free of `http/https/data:/www.` before any provider call — **never fetches/forwards/attaches any supplier/marketplace/uncleared pixels or URLs**;
3. spend control — `spendApproved !== true` → `spend_approval_required`/`PREPARED_NOT_EXECUTED`, provider+storage never called;
4. only when `spendApproved`: calls the injected `provider.generate({ prompt, aspectRatio })` (text prompt is the ONLY input) then `storage.putPrivate(...)` — output always private;
5. same approved identity version to every scene — `executeConceptPack` runs N scenes reusing one pack so all share `pack.identityVersion`;
6. records provenance `{ prompt, provider, model, inputProvenance:{rightsBasis:ORIGINAL_CONCEPT_TEXT_ONLY, referenceAsset:null}, outputIdentityVersion, rightsState:ORIGINAL_CONCEPT, classification:AI_CONCEPT_NOT_PRODUCT_VERIFIED, identityValidated:false, createdAt }`;
7. classifies outputs `AI_CONCEPT_NOT_PRODUCT_VERIFIED`;
8. concepts stay separate from exact-product commercial assets (ORIGINAL_CONCEPT provenance, never a product commercial row);
9. `rejectConceptPromotion(...)` has no `allowed:true` path — a concept can never be promoted/exported as a verified product ad without validation + commercial clearance.
**Tests (6):** unauthorized → no provider/storage call; spend-not-approved → no call, PREPARED_NOT_EXECUTED; owner + spendApproved → provider called once with a URL-free prompt, private storage, correct provenance; brief with a URL → provider prompt has no URL; 3-scene pack → one shared identity version; promotion rejected. **No paid call occurs — the provider is a mock.**

**Deploy-gated edge + table (precise design, NOT written/applied):** a Supabase edge `commercial-concept-generate` (`verify_jwt=true`), mirroring `commercial-image-generate`, that calls `executeConceptLane` with the real Gemini text-to-image provider + the private `pulse-generated-media` storage + `auth.uid()`/ownership, guarded so the paid call stays disabled until founder spend approval; + a migration adding `commerce_generated_assets.generation_type='ORIGINAL_CONCEPT'` rows (or a dedicated `original_concept_assets` table) carrying the provenance fields above, with RLS owner-scoping. To be implemented-and-applied under a controlled production deployment approval; its logic is already the tested `executeConceptLane` contract.

## Workstream B — Product Visual Consistency engine (implemented + tested, honest)
**Implemented (preview commit `d8952bd`):** `src/lib/creative-studio/product-visual-consistency.ts` + test. No pixel/vision analysis is available without a paid provider, so the engine is **honest by construction**:
- `assessAgainstVerifiedEvidence(pack, output)` — `identityVersionMatch` (PASS/FAIL), `brandingPermissions` (CONCEPT with declared brand names → FAIL), `classificationCorrect`, and the appearance criteria (silhouette/shape, colours/materials, proportions, visible controls, attachments, variant, function/demonstration) → **all `REVIEW_REQUIRED`** ("automated pixel/vision comparison unavailable; human or vision-provider review required") — **never auto-PASS**; evidence provenance + confidence are echoed from the pack and **never raised**. Verdict `INCONSISTENT`/REJECT on any FAIL, else `REVIEW_REQUIRED` (never auto-CONSISTENT while appearance is unverifiable).
- `assessInternalConsistency(outputs)` — same identity version / mode / compatible aspect ratios, with the explicit note that **internal resemblance between AI outputs does NOT establish accuracy against the real product; verified-evidence confidence is unchanged**. This separates the two assessments exactly as required.
- `combineConsistency(...)` — always `commercialClearance: NOT_CLEARED_REQUIRES_HUMAN_AND_PAL` (no automatic commercial clearance); provides review/reject/regenerate states.
**Tests (6):** identity-version mismatch → INCONSISTENT/REJECT; CONCEPT + declared brand → INCONSISTENT; appearance criteria REVIEW_REQUIRED (never PASS) even with matching identity version; internal consistency true while verified-evidence appearance stays REVIEW_REQUIRED (separation honoured); commercialClearance never cleared.

## Workstream C — video provider evaluation (verified pricing; no purchase, no paid job)
**Existing video infrastructure reused (inspected, already present):** the `fn_media_*_video_job` pipeline (create / prepare / dispatch / complete_real / retry / claim-gate / sync-state) + `fn_video_creative_director_plan`, `fn_video_generation_cost_estimate`, `fn_video_identity_quality_contract`, `fn_video_identity_validate_decision`, `fn_video_quality_judge_decision`, `fn_video_scene_executor_contract`, `fn_video_scene_launch_safety`, `fn_video_shot_identity_policy`. **The smallest missing integration is one provider EXECUTOR EDGE** — the function that actually calls a video model and returns the asset to `fn_media_complete_video_real` — mirroring `commercial-image-generate` (verify_jwt, ownership, the identity-quality contract, the cost gate, private storage, provenance). No other pipeline piece is missing.

**Provider comparison (indicative list pricing from 2026 comparison sources; exact rates + commercial/likeness/music terms MUST be confirmed on each vendor's official pricing + terms page before any spend):**
| Provider | Indicative cost | Fit for realistic human product-demo, 9:16, 10–20s MP4, product/person consistency |
|---|---|---|
| **Google Veo (Gemini API / Vertex)** | Veo 3.1 Standard ~$0.40/s (720p/1080p, audio incl.); Fast/Lite ~$0.05–0.12/s → ~**$0.50–8 per 10–20s clip** by tier | Native audio, 9:16 vertical, image-to-video from the authorised reference (consistency), strong realism |
| **Runway Gen-4 / Gen-4.5** | ~$0.12–0.25/s → ~$1.20–5/clip | Strong character/product consistency, mature API, image-to-video |
| **Kling** | ~$0.09/s → ~$0.90–1.80/clip | Strong realism, cheaper; no public official price list |
| Pika / Luma | ~$0.04–0.09/s | Budget; consistency varies |

**Recommendation — PRIMARY: Google Veo via the Gemini API.** Rationale: we **already integrate Google Gemini** (same account, billing, and the commercial-terms umbrella we already operate under for images), minimising new vendor/rights onboarding; it supports native audio, 9:16 vertical, and image-to-video from the authorised reference (product/person consistency); and it is the smallest executor-edge integration (mirror `commercial-image-generate`). Use **Veo Fast/Lite for the pilot** (~$0.50–2.40 per 10–20s clip) and Standard for finals. **FALLBACK: Runway Gen-4** (strongest consistency controls, mature API) or **Kling** (lowest cost). Before any spend: confirm the exact current per-second rate, commercial-use + human-likeness + music licensing, API access, rate limits and regional availability on the chosen vendor's official pages. **No subscription purchased, no account created, no paid video job run.**

## UI capability labels (already accurate from BE341; no change needed)
The three-category Creative Studio already labels honestly: Exact Product available only with an authorised reference + resolved identity; AI Concept prepared (executionState `PREPARED_NOT_EXECUTED` — matches the actual backend state since the concept edge is not deployed); Hybrid subject to identity + reference eligibility; Video "capability prepared; provider executor not yet connected" (unavailable until a real provider executor is connected and tested). No fake playable videos, invented provider results, or fabricated photographs anywhere.

## Preview test results
A + B: 12/12 new tests; targeted regression **716/716 across 75 files** (the agent's requested regression set — product-explorer, commerce, creative-studio, lib); preview build OK; no paid calls. (The prior full suite was 1,111/1,111 at `9c7d673`; BE342 added only pure modules + tests, so the accumulated suite remains green.) Backend rights / tenant-country isolation / PAL regressions are unchanged (no backend change this cycle) and remain green per BE326/BE338/BE340.

## Remaining provider / founder dependencies
- **AI Concept execution:** a controlled production deployment of the `commercial-concept-generate` edge + the ORIGINAL_CONCEPT provenance migration (implementing the tested lane contract) + a text-to-image provider + founder spend approval.
- **Images (Exact):** none new — Gemini live; CS.05 3-image pilot needs only founder spend approval.
- **Video:** founder selection of Veo (primary) or Runway/Kling (fallback) + confirmed official pricing/commercial terms + building the one executor edge + spend approval.

## Production deployment boundaries + rollback
Nothing deployed this cycle. The accumulated preview frontend `0cad104`→`d8952bd` (BE337–BE342) is preview-only, strictly additive, fail-closed-preserving, suite green — ready for a controlled production deploy on separate approval (narrow `deploy_project`, pre-deploy diff; rollback = redeploy the prior production commit `fd2ddda`/BE334, as deployments are full-HEAD and reversible via Lovable deployment history). The concept edge + migration + any video executor are **separate** controlled backend deployments, each gated on approval; their rollback is dropping the new edge/migration (no existing object is altered; the lane is strictly additive and fail-closed).

## Roadmap reconciliation (no duplicate milestones)
CS.01 DONE · CS.02 PARTIAL · CS.03 DONE · CS.04 DONE · CS.05 IN PROGRESS. BE342 advances the Creative Studio completion (Concept lane logic + consistency engine + video provider selection) on the CS.05+ track; it does **not** mark CS.05/CS.06/CS.07/CS.08 DONE (no real generated-media acceptance; concept/video execution still deploy+spend-gated). No new permanent CS identifiers minted pending founder reconciliation. GPD.09 + 18-Dec launch gates remain higher priority.

## Strict limits — all honoured
Preview/dev only; no production deployment; 0 paid Gemini/OpenAI/video calls; no provider subscription/account; no subscriber download activation; no public Creative Studio release; no rights promotion; no quarantine restoration; no GPD.07; no backend migration applied. GOLD 11/22 unchanged. CS.05–CS.08 open. Next BE id: **BE343**. Evidence: this report, master-doc Addendum 113, Build Evidence row **BE342**. Frontend: Lovable project `12db6c84`, preview commit `d8952bd` (undeployed); production remains `df1e2f6` (BE336).

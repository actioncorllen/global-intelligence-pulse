# STRATELOQ-ECOM-CREATIVE-PROVIDER-LIVE-001

**FINAL: IMAGE = PASS_REAL · VIDEO = BLOCKED_EXTERNAL_VIDEO_PROVIDER.**

A real, provider-backed advertising **image** was generated from a rights-clear supplier product asset via the
founder-approved existing OpenAI credential, persisted with full provenance/rights/cost and product×country
linkage, and verified consumable by Ad Studio (safety-gated) and by the storefront GENERATED contract. Total
real spend: **USD 0.01341** (one image; within the founder-authorised ~USD 0.02–0.05 cap). **Image-to-video /
video** has no cents-level path through existing credentials and is honestly blocked pending a founder decision
on a video provider — no account was created and no spend incurred.

Reuse-before-add held: the entire media-generation architecture already existed (mig_120–124) and was validated
with mocks; the only missing piece was a live provider + the thin real-completion path, which this unit added.

---

## 1. Existing capability audit
The DB already contains a complete, provider-agnostic media-generation subsystem (built in DB migrations
mig_120–124; these predate the repo snapshot, which starts at mig_131 — a pre-existing condition, noted):

| Table | Purpose | Rows before this unit |
|---|---|---|
| `media_providers` | provider registry (name, media_type, enabled, config) | **0 (empty → all blocked)** |
| `media_image_jobs` / `media_video_jobs` | job lifecycle, provider/cost/provenance/error | 1 / 3 (fixtures) |
| `media_assets` | canonical asset (provider, rights, storage, provenance, dims, product) | 4 (all MOCK/fixtures) |
| `media_job_costs` | cost telemetry | 4 |
| `media_video_scenes` | storyboard scenes + claim checks | 12 |
| `ad_studio_briefs/angles/platform_variants/static_creatives/offers/assets` | strategy layer | fixture (FlexiDesk) |
| `provider_capability_registry` | capability registry | 0 media rows |

RPCs already present: `fn_media_provider_for`, `fn_media_create_image_job`, `fn_media_create_video_job`,
`fn_media_build_storyboard`, `fn_media_register_source_asset`, `fn_media_approve_asset`,
`fn_media_campaign_safety_gate`, `fn_media_mock_complete_image`, `fn_media_retry_image_job`,
`fn_media_replace_asset`, plus the `fn_ad_studio_*` strategy chain.

Per capability:
- **IMAGE GENERATION** — architecture present; jobs correctly returned `BLOCKED_EXTERNAL_PROVIDER` (empty
  registry). Only completion path was `fn_media_mock_complete_image` (MOCK_FIXTURE, is_launch_safe=false).
  Implementation state: **built, mock-validated, no real provider, no real asset.**
- **VIDEO GENERATION** — same: schema + `fn_media_create_video_job` + storyboard build present; no provider.
- **IMAGE-TO-VIDEO** — `media_video_jobs.source_image_asset_id` + storyboard model support it; no provider.
- **STORAGE** — **no Supabase Storage bucket existed**; mock/fixture assets used `mock://` / `s3://…` refs.
- **PROVENANCE** — strong: `media_assets.provenance`, `source_asset_id`, rights_state, approval_state,
  is_launch_safe; ad_studio assets carry rights_state + is_competitor_source.
- **COST TRACKING** — `media_job_costs` + per-job estimated/actual cost columns present.

Existing providers/integrations discovered for reuse (n8n credentials, names only — no secrets read):
OpenAI (`openAiApi` ×2), Google Gemini (`googlePalmApi` ×2), Anthropic, plus CJ/eBay/DataForSEO/Meta/etc.
**No dedicated image/video generation provider, adapter, or workflow existed.**

## 2. External dependency gate
- **IMAGE:** a real provider was reachable via the **existing** OpenAI credential (no new account, no
  subscription). Founder authorised one bounded image → gate opened by registering the provider.
- **VIDEO:** **`BLOCKED_EXTERNAL_VIDEO_PROVIDER`.** Requirements for the founder (unchanged, no action taken):
  1. **What:** a video / image-to-video generation account. Options: Google **Veo** (reachable via the
     existing Gemini credential but needs billing enabled on that Google Cloud project), or a dedicated
     provider — **Runway, Kling, Pika, MiniMax** (each needs a new account + API key).
  2. **Why:** OpenAI (the connected image provider) has no image-to-video API; no connected credential can
     produce video at cents-level cost.
  3. **Blocked:** VIDEO and IMAGE-TO-VIDEO only (IMAGE is live).
  4. **Pricing (indicative, founder to confirm):** short AI clip ≈ **USD 2–4** per generation (Veo/Runway/Kling
     tiers); materially more than image. No free tier reliably covers a usable ad clip.
  5. **Credential/permission:** an API key with video-generation (text/image-to-video) scope; for Veo, billing
     enabled on the Google project behind the existing Gemini credential.
  6. **Where to obtain:** the chosen provider's console (Google AI Studio/Vertex for Veo; the provider's
     dashboard otherwise).
  7. **Where to store:** **server-side only** — as an n8n credential (mirroring the OpenAI/CJ/Meta pattern),
     never in the DB, frontend, or repo. `media_providers.config` stores only the credential's *name/location*.
  8. **Free/test tier:** none reliably sufficient for a real launch-quality clip; a real bounded spend will be
     required for VIDEO acceptance.

## 3. Provider-independent contract (mig_233)
The canonical generated-media result (`fn_media_generation_result(asset_id)`) returns every required field and,
for the real asset, reports **`contract_complete = true`**: provider, provider_job_id, media_type,
generation_mode, source_asset_refs, specification_ref, product_id, country_code, creative_strategy_ref,
ad_variant_ref, origin_kind=GENERATED, rights_state, usage_permission, generation_timestamp, storage_ref,
mime_type, dimensions/duration, cost_amount, cost_currency, status, approval_state, is_launch_safe,
failure_reason, provenance. Source-product provenance is never lost (the supplier asset id + URL + rights ride
in `source_asset_refs` and `provenance`).

New this unit (all additive/back-compatible):
- Additive `media_assets` columns: country_code, generation_mode, usage_permission, cost_amount, cost_currency,
  failure_reason, source_asset_refs, creative_strategy_ref, ad_variant_ref.
- `fn_media_register_provider` — registers a provider and **never stores a secret** (strips secret-looking
  config keys; records only the credential's name/location).
- `fn_media_complete_image_real` — persists a REAL asset (rejects MOCK; is_launch_safe stays false pending
  approval + safety gate); records cost; preserves provenance + product/country linkage.
- `fn_media_generation_result` — the canonical result contract above.
- `fn_media_creative_live_selftest` — **4/4 PASS** (no-video-provider blocked; register strips secret; real
  completion rejects MOCK; no MOCK fixture is launch-safe). Self-cleaning.
- Private storage bucket **`pulse-generated-media`** created (not public; 15 MB limit; image/video mime allow-list).

## 4. Image generation — REAL execution
- **Provider:** `OPENAI_GPT_IMAGE` (model `gpt-image-1`, `/v1/images/edits`, quality=low, 1024×1024).
- **Source (rights-clear):** dash-cam supplier image `f9180cf5…` (`SUPPLIER_PROVIDED`, `SOURCE_PRODUCT_ASSET`,
  CJ `1980170173102026754`) — not a competitor/reference/sourcing asset.
- **Mode:** product-preserving edit (prompt forbids altering the device and forbids any text/logo/badge/price/
  person/extra object → no fabricated features, no fake reviews/discounts/scarcity/guarantees).
- **Execution:** n8n workflow `dYoeIeiXwPOrDDY4` (manual), execution `30175`, success in ~14 s.
- **Result asset:** `fed67d8a-8ec4-4a79-a0f9-1b0c92f667d9` — media_type IMAGE, origin_kind **GENERATED**,
  rights_state GENERATED, usage_permission INTERNAL_ADVERTISING_TEST, approval_state **IN_REVIEW**,
  **is_launch_safe=false** (human approval required).
- **Persisted:** private bucket object `pulse-generated-media/dashcam/gen-30175.png` — **exists, 1,210,218
  bytes, image/png** (verified in `storage.objects`).
- **Linkage:** product_id = dash-cam page `ae458526…`; country_code **US**; creative_strategy_ref = real
  dash-cam brief `15f0aabd…`; ad_variant_ref = static creative `dc0e0f62…`.
- **Verifications:** provider returned a real asset ✓; asset + provenance + rights persisted ✓; cost recorded
  ✓; product ✓ and Product×Country ✓ linkage; Ad Studio can consume it ✓ (below); storefront can consume it
  where appropriate ✓ (below); no fabricated features/reviews/discounts/scarcity/guarantees ✓.

## 5. Image-to-video / video
`BLOCKED_EXTERNAL_VIDEO_PROVIDER`. `fn_media_provider_for('VIDEO')` → NULL; a real video job
(`080be864…`, using the generated image as source) returned **`BLOCKED_EXTERNAL_PROVIDER`** with a 4-scene
storyboard built and **`source_lineage_preserved=true`**, zero claim violations, and no spend. The pipeline
**Ad Studio → GENERATED_CREATIVE asset → approved-asset resolver → storefront PRODUCT_VIDEO** is architecturally
ready (P8 storefront resolver already accepts asset_class `GENERATED_CREATIVE` / origin_kind `GENERATED`); it
will produce a real video the moment a video provider is connected. `VIDEO_ASSET_NOT_AVAILABLE` remains a valid
production state; video is not required per product.

## 6. Cost safety
Manual only; no recurring/batch/autonomous generation. **API calls:** 3 HTTP (supplier image download, OpenAI
edit, storage upload). **Generation jobs:** 1 image (completed) + 1 video (blocked, no call, no spend).
**Successful assets:** 1. **Failed jobs:** 0. **Total provider cost: USD 0.01341** (311 input + 272 output
tokens). No paid upgrade required or performed for image.

## 7. Security / leak scan
Credentials are server-side only (n8n credentials for OpenAI + Supabase). No provider secret appears in the
frontend, public JSON, HTML, logs, git, or this doc. `fn_media_register_provider` strips secret-looking keys;
`media_providers.config` stores only the credential's name/location (`n8n_credential:OpenAI account (…)`).
Repo diff scanned — no keys/tokens/JWTs. The self-test proves a secret passed to registration is stripped.

## 8. Schedule policy
No new schedules; no cadence changes. Production intelligence scans remain **Monday-only** (orchestrator
`BBxcPXJdF2PliWgf`); FX daily refresher unchanged (approved exception). This creative acceptance was
**manual-only**.

## 9. Acceptance
- **IMAGE: PASS_REAL** — real provider-backed generation executed, persisted, verified; not a mock.
- **VIDEO: BLOCKED_EXTERNAL_VIDEO_PROVIDER** — honest block; no mock promoted to PASS.

---

## Final report (27 points)
1. **Existing capability audit** — full media subsystem present (mig_120–124), provider registry empty → all blocked; storage bucket absent; ad_studio strategy was fixture-only.
2. **Existing providers/integrations discovered** — reusable image credentials (OpenAI, Gemini) in n8n; no media-generation adapter/workflow/provider row existed.
3. **Image generation status** — **PASS_REAL** (OpenAI gpt-image-1 edit).
4. **Video generation status** — **BLOCKED_EXTERNAL_VIDEO_PROVIDER**.
5. **Image-to-video status** — **BLOCKED_EXTERNAL_VIDEO_PROVIDER** (architecture ready; source lineage preserved; blocks cleanly).
6. **External blockers** — video provider account/credential (Veo via Gemini billing, or Runway/Kling/Pika/MiniMax).
7. **Credential requirements** — video-generation API key, stored server-side as an n8n credential; DB stores name only.
8. **Real executions performed** — 1 real image generation (n8n exec 30175); 1 video job created → blocked (no call).
9. **Generated asset IDs** — image `fed67d8a-8ec4-4a79-a0f9-1b0c92f667d9`; storage `pulse-generated-media/dashcam/gen-30175.png`.
10. **Provenance verification** — `contract_complete=true`; source supplier asset + URL + rights preserved in source_asset_refs + provenance.
11. **Rights verification** — source SUPPLIER_PROVIDED; output rights_state GENERATED; usage_permission INTERNAL_ADVERTISING_TEST; is_launch_safe=false.
12. **Storage verification** — object exists in private bucket, 1,210,218 bytes, image/png.
13. **Ad Studio integration** — safety gate consumed the asset and returned REJECTED/NOT_APPROVED, activation NOT_AUTHORIZED, spend_authorization 0 (consumable + correctly gated).
14. **Storefront PRODUCT_VIDEO integration** — resolver accepts GENERATED_CREATIVE/origin_kind GENERATED (P8); video job path ready and blocks cleanly; live storefront not modified.
15. **Cost telemetry** — media_job_costs row IMAGE_GENERATION_REAL = USD 0.01341 (OPENAI_GPT_IMAGE).
16. **Security / leak scan** — no secrets in DB/frontend/logs/git/doc; registration strips secrets.
17. **Schedules inspected** — Monday production orchestrator + FX daily refresher; unchanged.
18. **New schedules** — 0.
19. **Cadence changes** — 0.
20. **Manual executions** — 1 image workflow run (manual).
21. **Total API calls** — 3 HTTP (download, OpenAI edit, storage upload).
22. **Total cost** — **USD 0.01341**.
23. **Tests** — `fn_media_creative_live_selftest` 4/4; provider gating (IMAGE open, VIDEO blocked) verified; canonical contract complete.
24. **Git commit/push** — mig_233 + this doc committed and pushed to `claude/pulse-crash-recovery-b6ngey` (the n8n workflow lives in n8n, as with all external adapters).
25. **Final verdict** — IMAGE **PASS_REAL**; VIDEO **BLOCKED_EXTERNAL_VIDEO_PROVIDER**.
26. **Phase 9/10 %** — Ad Studio creative-generation (Phase 9): image path **live** → ~**85%** (video pending provider); Phase 10 (media/launch automation) unchanged, gated on video + human approval + campaign authorisation.
27. **Overall paid-beta readiness** — real static-creative generation removes a launch-critical blocker; remaining paid-beta blockers: a video provider (founder decision), human creative approval flow, and campaign activation/spend authorisation (still `false`/`0`).

## Safety invariants (unchanged)
`campaign_created=false` · `campaign_activation=false` · `advertising_spend_authorized=0` ·
`advertising_spend=0`. Meta paused campaign untouched. Nitro × US remains `PENDING_EXTERNAL_CJ_SOURCING`
(untouched, not polled). Dash cam remains `QUALIFIED_TEST_NOT_HIGH_CONFIDENCE` / WPS 79 — **not** promoted.
Approved Lovable storefront not modified. No checkout. Generated asset is `is_launch_safe=false` / IN_REVIEW.

STOP — WAIT FOR FOUNDER ACTION on the VIDEO provider (external account/credential/spend). Image capability is
live and awaiting normal human creative approval before any launch use.

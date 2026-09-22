# STRATELOQ-AI-AD-CREATIVE-STUDIO-015E — Architecture + Reuse + Capability Audit

**FINAL VERDICT: `AD_CREATIVE_STUDIO_ARCHITECTURE_READY`.**

**Product boundary respected:** Strateloq remains the Opportunity Intelligence Platform. The AI Ad
Creative Studio is an **internal module** that converts approved intelligence/opportunities into
advertising creatives. Nothing here repositions, renames, or redesigns Strateloq around ad creation.

**Headline finding (audit-first result):** the Creative Studio backbone **already substantially exists**
in the database as deterministic, intelligence-first contracts — brief → angles (concepts) → platform
variants → static/video job models → media assets → campaign handoff → performance schema, with claim
scanning, product-identity safety, and Brand DNA already wired. The launch-critical gap is **not** the
data architecture; it is the **provider-neutral generation *execution* layer** (nothing has actually
rendered — 0 media assets are `READY`) plus **video / voiceover / avatar provider registration** and a
handful of small entities (carousel, explicit UGC script). This audit therefore **reuses** the existing
backbone and scopes the smallest beta that makes the Studio commercially valuable. **No code, no DDL, no
Lovable, no publish, no Stripe, no paid generation** was performed in this unit.

---

## 1. Existing capability inventory (evidence-based)

Audited: Postgres tables/functions, Supabase storage + edge functions, n8n credentials + workflows.

### Database — tables (real row counts)
| Table | Cols | Rows | Role |
|---|---|---|---|
| `ad_studio_briefs` | 30 | 2 | Intelligence-first creative brief (business_id, product_id, opportunity_id, decision_id, evidence_refs, supplier_refs, market, buyer_intent, keyword/competitor/advertising intelligence, offer, product_assets, platform_targets, evidence_completeness) |
| `ad_studio_angles` | 30 | 6 | **Creative Concept entity** (angle_type, customer_problem, desired_outcome, evidence_basis/refs, audience_segment, hook, headline, primary_copy, cta, visual_concept, static_creative_brief, video_hook, video_script, storyboard, claim_risk, claim_violations, review_state, fingerprints) |
| `ad_studio_platform_variants` | 16 | 16 | Per-platform variant (platform, placement, hook, copy_structure, cta, aspect_ratio, visual_composition, script_pacing, opening_seconds, caption_approach, claim_violations) |
| `ad_studio_static_creatives` | 18 | 4 | Static-ad spec (platform, product_asset_refs, headline, layout, aspect_ratio, safe_area, brand_context, generation_provider, generation_status, asset_url) |
| `ad_studio_offers` | 9 | — | Offer elements w/ evidence_state/tier |
| `ad_studio_assets` | 9 | — | Source-asset refs (rights_state, is_competitor_source, provenance) |
| `media_image_jobs` | 26 | 2 | Provider-neutral **image render job** (input_asset_refs, product_facts, visual_concept, brand_context, platform, aspect_ratio, safe_area, provider, provider_job_id, status, output_asset_refs, est/actual cost, error_state, retry_count, max_retries) |
| `media_video_jobs` | 29 | 4 | Provider-neutral **video render job** (source_image_asset_id → image-to-video, video_hook, script, storyboard, duration_target, motion_instructions, text_overlays, cta, provider, status, cost, retry, claim_violations) |
| `media_video_scenes` | 13 | 16 | Scene sequencing (scene_number, visual_action, motion_instruction, text_overlay, voiceover, transition, claim_refs) |
| `media_assets` | 32 | 5 (**0 READY**) | Canonical generated-asset lifecycle (media_type, provider, rights_state, generation_status, approval_state, storage_ref, is_launch_safe, cost, usage_permission, source_asset_refs, creative_strategy_ref, ad_variant_ref, country_code) |
| `media_providers` | 6 | 1 enabled | Provider registry (name, media_type, enabled, config w/ `secret_storage` reference — no secret inline) |
| `media_job_costs` | 9 | — | Per-job cost ledger |
| `member_business_dna` | 14 | 2 | **Brand DNA** (business_model, unique_value_prop, brand_positioning, growth_stage, brand_voice, goals, icp, dna_extended) |
| `product_asset_intelligence` | 18 | 3 | **Product-identity safety** (identity_state, match_class, match_confidence, hero_eligible, rights_state) |
| `campaign_builder_drafts` | 43 | 4 | Campaign assembly (platform, objective, markets, audience, placements, creative_selection, offer, budget, schedule, fx, media_asset_ids, media_gate, meta_payload_preview, tiktok_preview, spend_authorization, activation_authorization) |
| `campaign_performance_snapshots` | 28 | 16 | **Performance-feedback schema** (spend, impressions, reach, clicks, purchases, revenue, currencies, windows) |
| `marketing_campaign_drafts` / `executions` | 17/15 | — | Legacy Meta path (creative/adset/ad ids) |
| `generated_content` / `member_generated_content` | 16/14 | 0 | Text content (script, caption, hashtags, image_prompts, b_roll, cta_variations) |
| `competitor_content` | 10 | 0 | Observed competitor creative (hook, views, likes) |
| `conversion_hero_variants` / `conversion_template_families` | 5/15 | — | Storefront/landing creative templates |

### Database — functions (driving logic, all present)
- **Strategist / concepts:** `fn_ad_studio_build_brief`, `fn_ad_studio_generate_angles`, `fn_ad_studio_platform_variants`, `fn_ad_studio_add_offer`, `fn_ad_studio_edit_angle`, `fn_ad_studio_approve_angle`, `fn_ad_studio_fingerprint`.
- **Claim safety:** `fn_ad_studio_claim_scan` (+ angle `claim_risk`/`claim_violations`, variant/scene `claim_violations`).
- **Media jobs:** `fn_media_create_image_job`, `fn_media_create_video_job`, `fn_media_build_storyboard`, `fn_media_complete_image_real`, `fn_media_mock_complete_image`, `fn_media_retry_image_job`, `fn_media_approve_asset`, `fn_media_replace_asset`, `fn_media_register_source_asset`, `fn_media_register_provider`, `fn_media_provider_for`, `fn_media_campaign_safety_gate`, `fn_media_generation_result`.
- **Campaign:** `fn_cb_build_campaign`, `fn_ad_studio_campaign_handoff`, `fn_ad_studio_handoff`, `fn_ecommerce_campaign_executions`, `approve/reject/persist_marketing_campaign_draft`.
- **Competitor creative intelligence:** `fn_ecommerce_creative_intelligence`, `fn_classify_ad_creative_pattern`, `fn_classify_ad_product_match`, `fn_meta_ad_relevance`, `fn_meta_ad_library_market_state`, `fn_generate_meta_ad_queries`.
- **Selftest:** `fn_media_creative_live_selftest` → **4/4 pass**.

### Supabase storage / edge functions
- Bucket `pulse-generated-media` (private, created 2026-09-14). `storage.objects` has **0 RLS policies** → default-deny; delivery must be server-side signed URLs.
- Edge functions: invitations, `start-discovery`, `prepare-product`, `meta-capi-adapter`, `meta-insights-reader`, `storefront`, `tiktok-commercial-token`, `admin-bootstrap-demo`. **No image/video generation executor edge function.**

### n8n — providers (names/types only; no secrets)
- **OpenAI account ×2** (`openAiApi`) — image (GPT Image), text, TTS voiceover.
- **Anthropic account** (`anthropicApi`) — text/strategist.
- **Google Gemini/PaLM ×2** (`googlePalmApi`) — text + Gemini image.
- **Meta ×2** (`facebookGraphApi`), **TikTok** (`httpCustomAuth`), eBay, DataForSEO, CJ, Apify, Supabase, Drive/Sheets/Gmail/Calendar, Telegram, Airtable, HubSpot, JotForm.
- n8n **Gateway credits** (no credential setup) cover: `openAiApi`, `anthropicApi`, `googlePalmApi`, **`minimaxApi`**, `alibabaCloudApi`, plus browserbase/firecrawl/pdfco/braveSearch/llamaParse.
- **No creative/media generation workflow exists** in n8n (search returned 0).

## 2. Capability classification (LIVE / PARTIAL / CONTRACT_ONLY / UI_ONLY / MISSING / DEFERRED)

| Capability | State | Basis |
|---|---|---|
| AI Content Intelligence (evidence→brief) | **LIVE** | `fn_ad_studio_build_brief` + `ad_studio_briefs` consume decision/opportunity/problem/competitor/advertising evidence |
| Create Content (angles/hooks/headlines/copy/CTA) | **LIVE** | `fn_ad_studio_generate_angles` + `ad_studio_angles` (copy fields populated, claim-scanned) |
| Creative briefs | **LIVE** | `ad_studio_briefs` |
| Creative angles / concepts | **LIVE** | `ad_studio_angles` (= Creative Concept entity) |
| Hooks / headlines / primary copy / CTA | **LIVE** | angle + platform-variant columns |
| Platform variants (Meta/IG/TikTok/LinkedIn) | **PARTIAL→LIVE** | `fn_ad_studio_platform_variants` + `ad_studio_platform_variants` (16 rows); LinkedIn coverage to verify |
| Static image ad **spec** | **LIVE** | `ad_studio_static_creatives` |
| Static image **generation (render)** | **CONTRACT_ONLY** | image job + `fn_media_complete_image_real` + OpenAI provider registered, but **0 READY assets, no executor** |
| Image-to-video / video generation | **CONTRACT_ONLY** | `media_video_jobs`/`media_video_scenes` model exists; **no video provider, no executor** |
| Voiceover / audio (TTS) | **MISSING (provider)** | scene `voiceover` field exists; no TTS provider registered/wired |
| UGC / avatar | **MISSING** | no avatar/presenter provider; UGC script partially expressible via angle/scene |
| Carousel ads | **MISSING (entity)** | no carousel entity; composable from static creatives |
| Written ad creative | **LIVE** | angle + variant copy |
| Promotional creative (offer) | **PARTIAL** | `ad_studio_offers` + offer evidence_state; offer-creative templates POST_BETA |
| Meta creative contract | **PARTIAL** | `campaign_builder_drafts.meta_payload_preview`, `marketing_campaign_executions`, `meta-capi-adapter` |
| TikTok creative contract | **PARTIAL** | `campaign_builder_drafts.tiktok_preview`, `tiktok-commercial-token` |
| LinkedIn creative contract | **CONTRACT_ONLY/MISSING** | platform enum supports it; no LinkedIn execution wiring |
| Campaign execution | **PARTIAL** | `fn_cb_build_campaign`, `campaign_builder_drafts` (spend/activation authorization gates), Meta edge fns |
| Creative storage / assets | **PARTIAL** | `media_assets` + `pulse-generated-media` bucket; signed-URL delivery contract MISSING |
| Brand / Business DNA | **LIVE** | `member_business_dna` (RLS + 2 policies, real data) |
| Product intelligence | **LIVE** | commerce_products / PME / decisions (prior units) |
| Problem intelligence | **LIVE** | 015B–015D contracts |
| Competitor intelligence | **LIVE** | Meta Ad Library integration + `fn_ecommerce_creative_intelligence` |
| Observed competitor **creative patterns** | **PARTIAL** | `fn_classify_ad_creative_pattern` + `competitor_content` (empty — needs population) |
| Evidence / confidence | **LIVE** | evidence_refs / evidence_completeness / claim_risk |
| Performance intelligence | **CONTRACT_ONLY (architected)** | `campaign_performance_snapshots` schema exists; no live ingestion (POST_BETA) |
| n8n workflows (creative) | **MISSING** | none; generation executor to be built |
| AI/model providers | **PARTIAL** | text: LIVE (OpenAI/Anthropic/Gemini); image: LIVE credential, unexecuted; video/voice/avatar: MISSING |

## 3. Missing launch-critical capabilities

1. **Provider-neutral generation *executor*** (the single biggest gap): a service that reads a `media_image_jobs`/`media_video_jobs` row, calls the registered provider, stores output to `pulse-generated-media`, and calls the existing `fn_media_complete_image_real` (idempotent, retry-safe). Nothing renders today.
2. **Tenant-scoped signed-URL delivery** for `pulse-generated-media` (bucket is default-deny; no read path for a future UI).
3. **Static-image provider execution** with **product-identity preservation** (OpenAI GPT Image edit/reference mode from the exact product source asset).
4. **Video provider registration** (none exists) — candidate: MiniMax Hailuo / Alibaba Wan via n8n Gateway credits (no new credential), or a dedicated provider (approval required).
5. **Voiceover (TTS) provider registration** (OpenAI TTS on existing credential).
6. **Browser-safe read RPCs** for the Studio (tables are RLS default-deny; UI needs function-gated reads).

Everything else the founder listed already exists as reusable contracts.

## 4. Proposed Creative Studio architecture (reuse-first)

```
Business DNA (member_business_dna)
 + Selected Market + Product + Product Decision (product_opportunity_decisions)
 + Problem/Pain (commerce_problem_clusters + solution candidates, 015D)
 + Buyer/Search Intent + Competitor + observed creative patterns
 + Evidence/Confidence
        ↓  fn_ad_studio_build_brief  → ad_studio_briefs            [LIVE]
CREATIVE STRATEGIST
        ↓  fn_ad_studio_generate_angles → ad_studio_angles (3–5)   [LIVE]
        ↓  fn_ad_studio_claim_scan (per angle/variant/scene)       [LIVE]
        ↓  fn_ad_studio_platform_variants → per-platform           [LIVE]
CREATIVE GENERATION  (the gap)
        ↓  fn_media_create_image_job / _video_job / build_storyboard [CONTRACT]
        ↓  ◇ NEW render executor → provider → storage → fn_media_complete_image_real [MISSING]
        ↓  media_assets (generation_status, approval_state, is_launch_safe) [LIVE model]
REVIEW / EDIT   fn_ad_studio_edit_angle / fn_media_replace_asset / retry [LIVE]
APPROVE         fn_ad_studio_approve_angle / fn_media_approve_asset       [LIVE]
        ↓  fn_media_campaign_safety_gate                            [LIVE]
PLATFORM VARIANTS + EXPORT  → fn_cb_build_campaign / campaign_builder_drafts [PARTIAL]
LATER: LAUNCH (spend_authorization / activation_authorization gates) [PARTIAL]
LATER: PERFORMANCE → campaign_performance_snapshots                  [SCHEMA LIVE]
        ↓  future creative iteration
```

**Fact separation (already modeled, keep enforcing):**
`SOURCE FACT` (product source, supplier spec, business-provided, approved offer, observed evidence) →
`DERIVED INSIGHT` (evidence_basis) → `CREATIVE HYPOTHESIS` (`creative_hypothesis`/`claim_risk`) →
`GENERATED CREATIVE` (media_assets, labeled with provenance + review requirement).

## 5. Canonical Creative Concept model

**Already exists as `ad_studio_angles`** (do not duplicate). Mapping to the founder's spec:

| Spec field | Existing column |
|---|---|
| creative_concept_id | `id` |
| tenant_id | `tenant_id` |
| business_id / product_id / market | via parent `ad_studio_briefs` (business_id, product_id, market) |
| problem_cluster_id / product_decision_id | `ad_studio_briefs.opportunity_id` / `decision_id` (+ add `problem_cluster_id` — small gap) |
| campaign objective | `ad_studio_briefs`/`campaign_builder_drafts.objective` (add explicit `objective` on angle — small gap) |
| audience hypothesis | `audience_segment` |
| creative angle / hook / core message / benefit | `angle_type` / `hook` / `primary_copy` / `desired_outcome` |
| supporting evidence refs | `evidence_basis` + `evidence_refs` |
| CTA | `cta` |
| format / platform recommendation | `static_creative_brief` / `video_hook` + `platform_notes` |
| confidence / evidence state | `claim_risk` + brief `evidence_completeness` (add explicit `creative_confidence` — small gap) |
| creative_hypothesis flag | `claim_risk` semantics (add explicit boolean — small gap) |
| created_at / updated_at | present |

**Launch-critical additions (small):** `problem_cluster_id`, explicit `objective`, `creative_confidence`
(distinct from Product Opportunity confidence), `creative_hypothesis` boolean. Deferred to build phase.

## 6. Generation / render job model

**Already exists**: `media_image_jobs`, `media_video_jobs`, `media_video_scenes`, `media_assets`,
`media_providers`, `media_job_costs`. Job types needed: IMAGE ✓, VIDEO ✓, UGC_VIDEO (video job +
scene voiceover/avatar refs — extend), VOICEOVER (add lightweight audio job or reuse video scene),
CAROUSEL (compose N image jobs — add carousel grouping), COPY_VARIANT (angle/variant — already text).

**States present:** jobs use `status` (+ `error_state`, `retry_count`, `max_retries`); assets use
`generation_status` + `approval_state`. Recommend the canonical set map to:
`DRAFT→QUEUED→GENERATING→READY→FAILED→REJECTED→APPROVED` (align existing enums in build phase).

**Captured already:** provider, provider_job_id, prompt/spec refs, source assets, product_facts,
brand_context, output_asset_refs, dimensions/duration (asset), est/actual cost + currency,
failure_reason/error_state, timestamps. **Idempotency/retry:** `fn_media_retry_image_job` +
`provider_job_id` give a retry-safe basis; the new executor must upsert by `(job_id, provider_job_id)`.

## 7. Claim-safety model

**Already exists**: `fn_ad_studio_claim_scan` + `claim_risk`/`claim_violations` on angles, variants, and
scenes; offer `evidence_state`; asset `is_launch_safe`. Contract to keep: every factual claim traces to
`product source | supplier spec | business-provided | observed evidence | approved offer`. Prohibited
without support: health/performance/savings/bestseller/scarcity/testimonial/discount/guarantee claims.
Creative hypotheses remain labeled and distinct from factual claims. **Gap:** wire the claim scan as a
hard gate on *generation input* (block a job whose prompt/copy carries an unresolved `claim_violation`).

## 8. Product-identity safeguards

**Authoritative rule (from the strict gallery fix, 013Y.2) carries into the Studio:**
`CARD/PRODUCT SOURCE IDENTITY == CREATIVE SOURCE PRODUCT IDENTITY`. Enforcement basis already present:
`product_asset_intelligence` (identity_state, match_class, match_confidence, hero_eligible) +
`media_assets.source_asset_refs`/`product_id` + `ad_studio_static_creatives.product_asset_refs`. The
render executor must (a) seed image/video generation from the **exact** product source asset (the hero
identity), (b) record which source assets were used, (c) allow context/background transformation but
**never** silently substitute a different brand/model/SKU, and (d) where exact preservation cannot be
guaranteed (e.g. full text-to-image without a product reference), set `is_launch_safe=false` and require
user review. **Gap:** add an identity-preservation check in the executor + a `product_identity_state`
label on `media_assets`.

## 9. Brand DNA reuse plan

**Reuse `member_business_dna`** (do not build a second system). Provides business/product name (via
business_profiles), positioning, brand_voice/tone, audience/icp, goals, dna_extended (visual style,
prohibited terms, CTA preferences). **Launch-critical gaps only:** confirm `dna_extended` carries
logo ref, color palette, prohibited-claims/terms, CTA preferences; if absent, add those keys to
`dna_extended` (no new table). `brand_context` is already threaded into image/video jobs and static
creatives.

## 10. Provider capability matrix

| Capability | Existing provider | Credential | API today | Terms dependency | Cost model (approx) | Launch-suitable? |
|---|---|---|---|---|---|---|
| Strategist / copy / scripts (text) | OpenAI / Anthropic / Gemini | LIVE (n8n) | Yes | Standard API | ~$/1K tokens | **Yes (BETA)** |
| Static image generation | OpenAI GPT Image | LIVE (n8n) + `media_providers.OPENAI_GPT_IMAGE` enabled | Yes | Standard API; commercial-use OK | ~$0.01–0.19 / image (size/quality) | **Yes (BETA)** — needs executor |
| Voiceover (TTS) | OpenAI TTS (same credential) | LIVE credential; **not registered** | Yes | Standard API | ~$/1K chars | POST_BETA (register + wire) |
| Video / image-to-video | **none dedicated**; MiniMax Hailuo / Alibaba Wan via n8n Gateway credits | Gateway (no setup) | Via Gateway | Gateway usage terms; verify commercial rights | usage-based (Gateway) | POST_BETA (approval + register) |
| Avatar / UGC presenter | **none** (HeyGen/Synthesia/Argil not connected) | MISSING | No | New vendor + terms | vendor per-minute | POST_BETA/OPTIONAL |
| Captions / music / SFX | none dedicated | MISSING | No | — | — | POST_BETA/OPTIONAL |
| Campaign delivery (Meta) | Meta Graph + `meta-capi-adapter`/`meta-insights-reader` | LIVE | Yes | Meta terms | ad spend (user) | Launch = POST_BETA (human-gated) |
| Campaign delivery (TikTok) | TikTok Commercial + `tiktok-commercial-token` | LIVE (commercial content) | Partial | TikTok terms | ad spend (user) | POST_BETA |

**New provider justification:** existing providers cover text + static image + TTS for beta. A **video**
provider is genuinely absent; MiniMax/Alibaba via **Gateway credits** is preferred first (no new
credential, usage-based) before recommending a dedicated video vendor — decision deferred to founder,
**no purchase**.

## 11. Storage / asset plan

Reuse `pulse-generated-media` (private). Design: generated asset → `media_assets.storage_ref`;
thumbnail/preview variant; `source_asset_refs` link to product source; versioning via `media_assets`
rows + `fn_media_replace_asset`; approval via `approval_state`/`is_launch_safe`; export/download via
**tenant-scoped signed URLs** (new — bucket is default-deny with 0 policies); tenant isolation via
`tenant_id` on every row + function-gated access; retention/cleanup policy for FAILED/REJECTED and
unapproved drafts (new, small); future campaign linkage via `media_asset_ids` on `campaign_builder_drafts`.
**Gap:** signed-URL delivery function + a retention job.

## 12. Static-ad architecture

`ad_studio_static_creatives` (spec) → `fn_media_create_image_job` → executor → OpenAI GPT Image
(reference/edit from exact product source asset) → `pulse-generated-media` → `fn_media_complete_image_real`
→ `media_assets` (review). Supports product-focused / lifestyle / offer / problem→solution / benefit-led;
comparison + testimonial-style + before/after **only where supportable** (claim-gated). Per-platform
`aspect_ratio` + `safe_area` already modeled. **BETA_REQUIRED.**

## 13. Video-ad architecture

`fn_media_build_storyboard` → `media_video_scenes` (scene sequencing, motion, text overlay, voiceover,
transition, claim_refs) → `fn_media_create_video_job` (image-to-video from an approved static/product
asset) → executor → video provider → asset. Encodes the reference benchmarks as **structural principles**
(not copied assets): hook in first seconds, immediate visual change, clear product role, short 9:16
mobile-first pacing, benefit demonstration, strong CTA/ending, before→product→after. **POST_BETA** (needs
video provider + approval). Reference A/B are quality/structure targets only — no shot-for-shot copying,
no copyrighted assets.

## 14. UGC architecture

Creator-style script (hook/body/CTA) expressible via angle + `media_video_scenes` (voiceover, product
inserts/B-roll). Avatar/presenter requires a new provider (**POST_BETA/OPTIONAL**). Captions + voiceover
via TTS (POST_BETA). **Never fabricate a real customer testimonial** — UGC scripts are labeled creative
hypotheses, not real testimonials.

## 15. Carousel architecture

**MISSING entity.** Design: a carousel = ordered group of static-creative cards (benefits / features /
problem→solution / multi-angle / educational sequence), each card a `media_image_jobs` render sharing one
`ad_studio_angle`. Add a lightweight `carousel_id` grouping (new small entity in build phase) rather than
a parallel system. **POST_BETA** (BETA can ship single-image + copy first).

## 16. Written-copy architecture

**LIVE.** Hooks / primary text / headlines / descriptions / CTA / scripts / voiceover copy already live in
`ad_studio_angles` + `ad_studio_platform_variants` via `fn_ad_studio_generate_angles` /
`fn_ad_studio_platform_variants`, claim-scanned. **BETA_REQUIRED** (already met).

## 17. Platform-variant architecture

**PARTIAL→LIVE.** `ad_studio_platform_variants` differentiates platform, placement, hook, copy_structure,
cta, aspect_ratio, visual_composition, script_pacing, opening_seconds, caption_approach — i.e. genuine
per-platform adaptation, **not** a resize. Meta/IG/TikTok live; **LinkedIn** variant generation to be
confirmed/extended. **BETA_REQUIRED** for Meta/IG/TikTok; LinkedIn POST_BETA.

## 18. Human approval flow

**LIVE.** `GENERATE → PREVIEW (fn_media_generation_result) → EDIT/REGENERATE (fn_ad_studio_edit_angle /
fn_media_replace_asset / fn_media_retry_image_job) → APPROVE (fn_ad_studio_approve_angle /
fn_media_approve_asset) → EXPORT (fn_cb_build_campaign)`. Launch is gated by
`campaign_builder_drafts.spend_authorization` + `activation_authorization` — **nothing spends ad money
because AI generated it.** **BETA_REQUIRED** (already met).

## 19. Performance-feedback future contract

**Architected only (do not build now).** `campaign_performance_snapshots` already models creative →
campaign → platform → spend → impressions → clicks → purchases → revenue (→ derive CTR/CPA/ROAS), with
`campaign_execution_id`/`campaign_draft_id` linkage back to creative. Meta ingestion path exists
(`meta-insights-reader`). **No predictive performance claims** until real data exists. **POST_BETA.**

## 20. BETA_REQUIRED vs POST_BETA vs OPTIONAL

**BETA_REQUIRED (smallest commercially-valuable Studio):**
- Intelligence→brief→3–5 evidence-grounded angles (LIVE).
- Written copy + platform variants for Meta/IG/TikTok (LIVE).
- **Static image generation execution** (OpenAI GPT Image, product-identity-preserving) — the one gap to build.
- Claim safety as a generation-input gate (extend LIVE scan).
- Product-identity safeguard in executor (extend LIVE `product_asset_intelligence`).
- Human approval + signed-URL export (approval LIVE; signed-URL delivery to build).
- Brand DNA reuse (LIVE).

**POST_BETA:** video / image-to-video (needs provider + approval); voiceover TTS; carousel entity;
LinkedIn variants; competitor-creative population; offer-creative templates; performance ingestion; launch
execution.

**OPTIONAL:** avatar/UGC presenter; music/SFX; advanced transitions/editing; text-to-video without product
reference.

Not a Filmora clone: users need no editing skills — they start from *"here are the strongest
evidence-grounded creative directions worth testing"* and approve/edit.

## 21. External dependencies / credentials

- **Present & sufficient for beta:** OpenAI (image + text + TTS), Anthropic, Gemini, Supabase storage,
  Meta/TikTok (later launch).
- **Needed for POST_BETA video:** a video model — MiniMax/Alibaba via n8n Gateway credits (no new
  credential) **or** a dedicated vendor (founder approval; commercial-rights review). No credential exists
  today for dedicated video/avatar.
- **No secrets exposed;** `media_providers.config` stores a `secret_storage` reference, not the key.
- Reddit remains `BLOCKED_EXTERNAL_APPROVAL` (unrelated to Studio).

## 22. Expected cost categories (no purchase, no paid generation this unit)

- **Text (strategist/copy):** ~$/1K tokens (OpenAI/Anthropic/Gemini) — low.
- **Static image:** ~$0.01–0.19 per image (OpenAI GPT Image, size/quality) — the primary beta cost, per generation, human-gated.
- **Voiceover TTS:** ~$/1K chars — POST_BETA.
- **Video:** usage-based via Gateway or vendor per-second — POST_BETA, the largest per-unit cost; must be authorized.
- **Ad spend:** user's own money, fully human-gated (`spend_authorization`/`activation_authorization`).
- **Storage:** Supabase storage/egress — minor.
All generation costs are already captured per job (`media_job_costs`, asset `cost_amount`). No purchase made.

## 23. Recommended implementation sequence (after founder acceptance)

1. **Render executor** (provider-neutral): consume `media_image_jobs`, call OpenAI GPT Image with the exact
   product source asset (identity-preserving), store to `pulse-generated-media`, call
   `fn_media_complete_image_real`; idempotent by `provider_job_id`; retry via `fn_media_retry_image_job`.
2. **Signed-URL delivery** + browser-safe read RPCs for Studio tables (RLS default-deny today).
3. **Claim + identity gates** on generation input; `product_identity_state` on `media_assets`.
4. **Small concept/model fields** (`problem_cluster_id`, `objective`, `creative_confidence`,
   `creative_hypothesis`, carousel grouping) — additive, no duplication.
5. **Beta acceptance:** one real static creative for a real opportunity, product-identity preserved,
   approved, exported — with cost captured (founder-authorized single paid image).
6. POST_BETA: video provider registration + executor; TTS; carousel; LinkedIn; performance ingestion.

## 24. Files / docs changed

- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015E.md` — this architecture/audit (no code, no DDL).

## 25. Commit hash

See the delivery message (committed to `claude/pulse-crash-recovery-b6ngey`).

## 26. Final verdict

**`AD_CREATIVE_STUDIO_ARCHITECTURE_READY`.**

---

**STOP.** Audit-first complete: the Creative Studio backbone already exists and is reused; the launch gap
is a provider-neutral generation executor + signed-URL delivery + video/voiceover provider registration,
scoped to a minimal BETA. No generator built, no Lovable, no publish, no Stripe, no paid generation, no
Product Decision or Problem-corroboration change, no secrets exposed. Reddit remains
`BLOCKED_EXTERNAL_APPROVAL`. Awaiting founder acceptance before implementing generation.

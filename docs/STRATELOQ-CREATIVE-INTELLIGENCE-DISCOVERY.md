# STRATELOQ — Creative Intelligence Discovery & Architecture Map

**Unit:** STRATELOQ-CREATIVE-INTELLIGENCE-DISCOVERY-001
**Type:** Discovery + architecture mapping ONLY (no build, no new providers, no publishing).
**Verdict:** `PASS` — the existing architecture can be extended *minimally* into a production-grade
Creative Intelligence system that answers every success-criterion question. One external dependency
to confirm before the first proof (OpenAI image key/billing live). No parallel system required.

---

## 1. CURRENT CREATIVE ARCHITECTURE (what already exists)

Strateloq already implements most of the founder-pinned pipeline as production Supabase contracts +
active n8n executors — it is **not** "prompt → image → publish":

- **Strategy / Creative Director (product-centric):** `fn_marketing_director_strategy`
  (objective, market/audience, platform, creative_type, brand DNA) →
  `fn_marketing_director_to_creative_request`. `member_business_dna`
  (business_model, unique_value_prop, brand_positioning, brand_voice, goals, icp) + `business_profiles`.
- **Ad Studio (brief → angles → variants → creatives):** `fn_ad_studio_build_brief` →
  `fn_ad_studio_generate_angles` (**3 distinct angle types per brief**: BENEFIT_OUTCOME,
  COMPARISON_GAP, DEMONSTRATION, PROBLEM_SOLUTION, USE_CASE) → `fn_ad_studio_platform_variants` →
  `fn_ad_studio_approve_angle`. Tables: `ad_studio_briefs/angles/offers/assets/platform_variants/
  static_creatives`, `ad_creative_asset_selections`. Each angle carries hook, headline, primary/supporting
  copy, cta, visual_concept, static_creative_brief, claim_risk, fingerprints (approval integrity).
- **Creative production & formats:** `fn_creative_production_request/plan/capabilities`,
  `creative_format_registry` (+ `fn_creative_format_select/route/apply/catalog/qa_criteria`),
  `fn_creative_platform_spec` (platform dims/safe areas), `fn_creative_generation_cost_gate`.
- **Media generation (REAL):** `media_image_jobs` + `fn_creative_fire_image_executor` /
  `fn_media_image_execution_context` → n8n executors; `fn_media_generation_result` /
  `fn_creative_image_job_result`; `media_job_costs`, `media_providers`; video via `media_video_jobs`.
- **Quality / identity gates:** `fn_creative_quality_review` + `fn_media_quality_gates`;
  Product Asset Lock via `fn_media_product_card_source_verified` + `fn_media_product_identity_preserved`
  + the n8n **Gemini Product Identity Validator** (vision: reference vs generated → IDENTITY_VALIDATED/
  REJECT). Claim/truth: `fn_ad_studio_claim_scan`, `fn_media_claim_gate`, `fn_media_video_claim_gate`,
  `fn_ad_creative_identity_policy`, `fn_creative_scene_identity_policy`.
- **Performance learning:** `campaign_performance_snapshots` (impressions, clicks, purchases, revenue,
  `source_class`, `purchase_source_verified`), `performance_learnings`, `performance_learning_memory`
  (confidence, superseded, stale_after), `performance_experiments`; `fn_learn_diagnose/evaluate/recommend`,
  `fn_learning_memory_active/note`, `fn_performance_handoff`, `fn_classify_ad_creative_pattern`.
- **Publishing (just proven):** `fn_social_facebook_organic_execute` (mig_344/345), approval upstream,
  VALIDATE_ONLY default, LIVE grant-gated.

**Active n8n creative/media workflows:** `Strateloq - Creative Image Executor` (OpenAI gpt-image-1,
product-preserving edit), `Strateloq - Gemini Commercial Image Executor` (gemini-2.5-flash-image i2i),
`Strateloq - Gemini Product Identity Validator` (gemini-2.5-flash **vision**). Inactive/manual: OpenAI
& Wan generation, Veo probes, Meta Draft Executor (PAUSED-only). The **Monday Ecom Opportunity
Orchestrator** (Mon 07:00) is the protected scan — untouched by this unit.

## 2. REUSABLE CONTRACTS / WORKFLOWS
Director + Ad Studio brief/angle/variant stack; creative_format_registry + format RPCs; platform spec;
`media_image_jobs` + the two active image executors + result/cost RPCs; `fn_creative_quality_review`
shell + Product Asset Lock gates + the **Gemini vision executor pattern** (reuse for the Judge);
claim gates; `member_business_dna`/`business_profiles`; the performance-learning tables + learn RPCs;
the FB organic publishing executor. **Everything needed already has a home.**

## 3. DUPLICATION TO AVOID
Do NOT create: a second Creative Studio, a parallel media-job/asset system, a new image provider, a new
format registry, a new publishing path, a new learning store, a new claim/identity system, or a new
brand table that duplicates `member_business_dna`/`media_assets`. The upgrade is **extension**, not
replacement.

## 4. CREATIVE DIRECTOR GAP (per dimension)
| Dimension | State |
|---|---|
| objective | EXISTING_PRODUCTION (director + brief) |
| audience | EXISTING_PRODUCTION (brief.audience/buyer_intent, dna.icp) |
| message | EXISTING_PRODUCTION (angle hook/headline/copy) |
| creative angle | EXISTING_PRODUCTION (3 distinct angle types) |
| visual concept | PARTIAL (free-text `visual_concept`/`static_creative_brief`, not a chosen art direction) |
| hierarchy | PARTIAL (`static_creatives.visual_hierarchy` jsonb, single) |
| composition | PARTIAL (`layout`/`visual_composition`, single) |
| colour direction | MISSING (only loose `brand_context` jsonb) |
| imagery direction | PARTIAL (`visual_concept`) |
| asset selection | EXISTING for product (`ad_creative_asset_selections`); MISSING for brand/SaaS assets |
| copy density | PARTIAL (copy fields; no density treatment) |
| typography treatment | MISSING at creative level (`creative_format_registry.text_treatment` is format-level) |
| CTA prominence | PARTIAL (`cta` exists; prominence not modeled) |
| platform context | EXISTING_PRODUCTION (variants, platform spec, aspect/safe_area) |

**Smallest extension:** a `BUSINESS_SELF` source-mode branch in the Director (brief sourced from
`member_business_dna`, no product) + an explicit **art-direction** layer (colour/typography/hierarchy/
composition/copy-density/CTA-prominence) attached to the existing angle/concept rows.

## 5. MULTI-CONCEPT GAP
3 distinct **message** angles already generated per brief (EXISTING). Distinct **visual-direction**
concepts are PARTIAL — visuals vary only by free-text `visual_concept`, with no guarantee of real
art-direction diversity. **Extension:** a concept-set generator that emits 3–5 art directions differing
on storytelling / hierarchy / composition / asset emphasis / typography / density (persisted as angle/
concept rows + art-direction columns), so "different" is structural, not cosmetic.

## 6. CREATIVE QUALITY JUDGE GAP
Machine gates are REAL (identity, product-card source, format/aspect, claim). **Aesthetic gates are
explicit placeholders:** `fn_creative_quality_review` hardcodes VISUAL_QUALITY, COMPOSITION,
AI_ARTIFACTS, PRODUCT_VISIBILITY, COMMERCIAL_USEFULNESS = `REVIEW_REQUIRED`, with the note *"aesthetic
gates stay REVIEW_REQUIRED until a legitimate evaluator exists"*; `launch_safe=false` and
`human_approval_required=true` already prevent auto-advance. **No aesthetic scoring of the actual
image exists** (`quality_review_has_vision = NO`). BUT the **Gemini Product Identity Validator proves
the architecture can send the generated image to a vision model** — scoped today to identity only.
**Extension:** a Creative Quality Judge that reuses that vision-executor pattern to score VISUAL_HIERARCHY,
COMPOSITION, TYPOGRAPHY, READABILITY, BRAND_FIDELITY, ASSET_FIDELITY, MESSAGE_CLARITY, PLATFORM_FIT,
ORIGINALITY, CONVERSION_COMMUNICATION, TRUTH_SAFETY → PASS / REVISE / REJECT, written into the existing
quality-review gate structure (replacing the placeholders). Below-floor never auto-publishes.

## 7. REGENERATION GAP
MISSING as a creative loop. `media_image_jobs.retry_count/max_retries` is transport retry, not
quality-driven regeneration. **Extension (bounded):** Generate → inspect actual image → Judge → extract
weaknesses → revise creative direction (feedback folded into `generation_instructions`) → regenerate →
re-inspect, with **max 2 regeneration cycles** and feedback retained in job/concept lineage. No infinite
loops.

## 8. BRAND ASSET LOCK DESIGN
Mirror Product Asset Lock using existing contracts — **no new asset system.** Represent authoritative
brand assets (logo, brand marks, approved colours, real SaaS/UI screenshots, founder-approved photography,
approved taglines) as `media_assets` rows (or a thin `brand_assets` registry referencing them) with an
`asset_class = BRAND_*`, provenance, rights_state and an approval flag; add a `fn_media_brand_identity_preserved`
gate analogous to the product one, validated by the same Gemini vision executor. `member_business_dna`
supplies colours/voice/positioning. AI must **not fabricate** logos, UI, dashboards, metrics,
testimonials, certifications, awards or customer claims — enforced by requiring authoritative brand-asset
refs for any such element + extending the claim gate (`fn_media_claim_gate`/`fn_ad_studio_claim_scan`) to
business/SaaS claims (observed-evidence only).

## 9. PRODUCT ASSET LOCK INTEGRATION
Preserved unchanged. Ecommerce creatives keep the mandatory authoritative Product Card identity via
`fn_media_product_card_source_verified` + `fn_media_product_identity_preserved` + the Gemini Identity
Validator. AI may alter background/scene/lighting/layout/typography/composition but must not silently
replace or materially alter the SKU. The Brand Asset Lock (item 8) sits beside it, not over it.

## 10. IMAGE PROVIDER READINESS
| Provider | State | Suitability |
|---|---|---|
| OPENAI_GPT_IMAGE (gpt-image-1) | CONNECTED_REAL (enabled + active executor); some jobs observed `BLOCKED_EXTERNAL_PROVIDER` (key/billing/region) | Best for marketing graphics: text rendering, layout/composition, editing, reference use → **primary for SaaS graphic** |
| GEMINI 2.5-flash-image (Commercial Executor) | CONNECTED_REAL (active) | Strong asset-preserving i2i edits + reference use; weaker text; also powers the **vision judge** |
| Gemini image as `media_providers` row | MISSING (only disabled Gemini *video* rows) — but reachable via the active n8n executor | — |
| Wan i2v (video) | CONNECTED_REAL (enabled) | video only |
| Veo | AVAILABLE_NOT_PRODUCTION / paid probes (disabled) | video only |
**Do not purchase another provider.** Primary = OpenAI gpt-image-1; Gemini = asset-preserving edits +
vision judge. Confirm the OpenAI key/billing is live before the first proof (only real external risk).

## 11. CREATIVE FORMAT READINESS
A SaaS/business social graphic — **MISSING** (no registry format; director product-only) → **FIRST**.
B Ecommerce product social — PARTIAL/EXISTING (GRID_MULTI_CARD + Product Asset Lock).
C Paid static — PARTIAL (ad_studio static + variants; paid lane gated, not in scope).
D IG/FB feed — PARTIAL (variants + aspect/safe_area; FB organic publish proven).
E Story/Reel cover — PARTIAL (dims/safe_area modeled; no cover format).
F LinkedIn business graphic — MISSING.
G TikTok static/photo — MISSING (TikTok video-oriented).
H Product/store promo — PARTIAL (storefront + product creatives).
**First format = A (SaaS/business social graphic):** founder benchmark exists, no Product Asset Lock
complexity, quality is visually judgeable.

## 12. PERFORMANCE-LEARNING READINESS
EXISTING and substantial, and it **already separates OBSERVED from INFERENCE**: snapshots carry
`source_class` + `purchase_source_verified`; learnings carry `learning_type/hypothesis/confidence/
evidence_quality`; memory carries confidence + `superseded`/`stale_after`; experiments carry
`min_evidence_policy`. It can attribute creative→angle→performance. **Gap:** organic social performance
(FB post insights for `social_post_results`) is not yet bridged into these tables (snapshots are
campaign/paid-oriented). **Extension (later):** a read-only FB post-insights ingester →
`campaign_performance_snapshots`-style organic rows → `fn_performance_handoff`/learnings, keyed to
`creative_id/angle_id`. Never synthesize learning below the evidence floor.

## 13. APPROVAL / PUBLISHING INTEGRATION
Reuse `fn_social_facebook_organic_execute` (mig_344/345). Judge PASS + Brand/Truth/Asset validation +
**founder approval** → `social_publishing_requests` → executor (VALIDATE_ONLY default; LIVE grant-gated).
Default stays `APPROVAL_REQUIRED`. Do NOT enable AUTO_PUBLISH, schedules, or cross-platform during this
upgrade. The first implementation unit publishes **nothing**.

## 14. COST MODEL (estimates — validate against live provider pricing)
Assumes OpenAI gpt-image-1 at ~medium quality (~$0.04–0.08/image; high ~$0.19), Gemini vision judge
~\$0.001/image (negligible), director/copy LLM ~\$0.02/brief (shared across concepts).
| Item | Estimate |
|---|---|
| 1 generated concept | ~\$0.06–0.10 |
| 3-concept batch (+1 shared reasoning) | ~\$0.25–0.40 |
| 5-concept batch | ~\$0.40–0.65 |
| 1 regeneration cycle | ~\$0.06–0.19 |
| approved final (3 concepts + ~1 regen) | ~\$0.35–0.60 |
Scale (3-concept + ≤1 regen, ~5 approved creatives/tenant/wk): founder beta ~\$5–15/wk;
10 tenants ~\$20–40/wk; 100 tenants ~\$200–400/wk (~\$1–1.7k/mo). **Recommend:** default 3 concepts
(max 5), **max 2 regenerations**, quality floor gate before any regen, cache director reasoning + reuse
brand assets, dedupe near-identical concepts. **Do not buy infrastructure before measured usage.**

## 15. SECURITY / TENANT ISOLATION
Every creative/media/performance/social table is `tenant_id`-scoped with RLS; privileged RPCs are
SECURITY DEFINER `search_path=''`; provider keys live in n8n credentials / the vault and are never
returned; media executors run as service-role webhooks; Product Asset Lock + identity validator + claim
gates already enforce authenticity. New Judge, Brand Asset Lock and SaaS brief must follow the same:
tenant-scoped rows, RLS SELECT-own, definer writes, no secret exposure, service-role-only executor calls,
reuse of the proven vault/identity patterns.

## 16. EXACT MINIMAL ARCHITECTURE EXTENSION
1. **Director `BUSINESS_SELF` mode** + self-business brief from `member_business_dna` (reuse
   `ad_studio_briefs` shape; no product).
2. **Art-direction concept layer** on the existing angle/concept rows (colour, typography, hierarchy,
   composition, copy-density, CTA-prominence) → generate 3 structurally distinct directions.
3. **Creative Quality Judge**: a vision RPC + n8n vision executor (reuse the Gemini-validator pattern)
   scoring the 11 dimensions → PASS/REVISE/REJECT, written into `fn_creative_quality_review`'s aesthetic
   gates (replace placeholders).
4. **Bounded regeneration loop** (max 2) keyed to the Judge verdict, feedback retained in lineage.
5. **Brand Asset Lock**: `asset_class=BRAND_*` on `media_assets` (or thin `brand_assets`) +
   `fn_media_brand_identity_preserved` + business-claim gate.
6. **SaaS social graphic format** in `creative_format_registry` (+ platform spec).
Everything else is reused.

## 17. IMPLEMENTATION SEQUENCE
1. Brand Asset Lock + SaaS self-business brief (authoritative inputs first).
2. SaaS social format registry entry + platform spec.
3. Art-direction multi-concept generator (3 distinct).
4. Generation via existing OpenAI executor (compose-from-brief).
5. Creative Quality Judge (vision) wired into quality-review gates.
6. Bounded regeneration loop.
7. Founder visual-review surface (no publish).
8. Later: organic performance ingestion → learning bridge; then publishing wiring.

## 18. FIRST IMPLEMENTATION UNIT — "PULSE SAAS SOCIAL CREATIVE QUALITY PROOF"
**Input:** one real Pulse business objective.
**Process:** Director → 3 distinct art-direction concepts → generate (OpenAI gpt-image-1) → inspect the
**actual images** → Creative Quality Judge (PASS/REVISE/REJECT) → reject/revise weak outputs (≤2 regens)
→ Brand/Truth/Asset validation → founder review.
**Output:** 3 professional Pulse social creatives for the founder to compare against the approved
benchmark. **NO publishing.** New build limited to: the vision Judge executor, the art-direction concept
spec, a minimal Brand Asset Lock, and the SaaS brief/format — reusing `media_image_jobs`, the active
executor, the cost gate, and the quality-review shell.

## 19. SUCCESS-CRITERION TRACEABILITY & VERDICT
The proposed extension can answer every required question:
- *Why this design?* — persisted Director brief + chosen art-direction concept rows.
- *Why stronger than rejected concepts?* — Judge scores per dimension on each concept.
- *Which authoritative assets?* — Brand/Product Asset Lock selections + provenance.
- *Did the image meet the benchmark?* — vision Judge score vs quality floor on the actual output.
- *What was wrong with a rejected generation?* — Judge weakness notes stored on the attempt.
- *What changed on regeneration?* — revised direction + lineage between attempts.
- *How did it perform after publication?* — organic insights bridged to performance_learnings.
- *What did Strateloq learn?* — performance_learning_memory statements (observed vs inferred).

**VERDICT: `PASS`.** Discovery complete; no architectural blockers. Reusable production contracts cover
most of the pipeline; the real gaps are the **aesthetic vision Judge**, the **art-direction multi-concept
layer**, the **bounded regeneration loop**, the **Brand Asset Lock**, and a **SaaS/business creative
mode/format** — all minimal extensions of existing contracts. Only external item to confirm before the
first proof: OpenAI gpt-image-1 key/billing live (some jobs showed `BLOCKED_EXTERNAL_PROVIDER`). Nothing
built, no providers purchased, no publishing enabled in this unit.

# CS.01 (roadmap 062) — Creative Studio: existing-media architecture audit — DONE

**Executed:** 2026-11-27 · **Authority:** founder "CREATIVE STUDIO EXECUTION — START WITH CS.01". **Unit acceptance (roadmap 062):** *traceable code/component inventory; no duplicate rebuild; no live changes.* **This audit made no code, schema, rights, storage, flag or deployment change — read-only inspection + existing selftest runs only.** No paid AI/API calls, 0 credits. GPD.09 and launch-critical work remain ahead of Creative Studio (CS is roadmap 062–069, "phased / post-launch"). **GOLD 11/22 unchanged.**

---

## Headline
**Creative Studio is already ~80–90% built** across backend (schema + ~90 functions + 2 generation edge pipelines + Product Asset Lock + rights model + storage) **and** frontend (route + API client + tests). The founder's **core product rule is already implemented and enforced in code**: a discovered/marketplace image is research-only and is *never* a publishable or generation-eligible source; product **identity** resolves an *authorized* reference server-side; AI generation is **product-faithful and Product-Asset-Lock-validated**; owned/uploaded/licensed assets are prioritised. The work remaining for CS.02–CS.06 is mostly **wiring + small gap-closing on existing components**, not greenfield. One pre-existing selftest check fails (reported below, not a Creative Studio defect).

---

## Deliverable 1 — Existing implementation inventory (traceable)

### Storage (Supabase buckets, all private)
| Bucket | Purpose | Objects | MIME |
|---|---|---|---|
| `pulse-generated-media` | AI-generated image/video output | 37 | png/jpeg/webp/mp4/webm |
| `pulse-product-imports` | **authorised merchant uploads** (owned originals) | 0 | png/jpeg/webp |
| `pulse-research-reference` | research reference staging (view-only) | 0 | png/jpeg/webp |

### Generation edge functions (both deployed, ACTIVE)
- **`commercial-image-generate`** (v26, JWT) — product-faithful pipeline: auth → onboarding gate (`fn_edge_onboarding_allowed`) → server-side tenant/product ownership → per-tenant rate limit → **eligibility gate** (`fn_product_commercial_asset_readiness`) → **AUTHORIZED reference resolved server-side** (`fn_product_supplier_identity`+`fn_resolve_storefront_assets`; browser never sees it) → product-preservation prompt → **Google Gemini `gemini-2.5-flash-image`** (via n8n) → `pulse-generated-media` → **Product Asset Lock identity validator** → provenance (`fn_register_generated_commercial_asset`) → `IDENTITY_VALIDATED` | `IDENTITY_VALIDATION_FAILED`.
- **`creative-image-execute`** (v22) — generic STATIC ad-image executor: `fn_media_image_execution_context` → **OpenAI `gpt-image-1`** edit (via n8n) → upload → `fn_media_complete_image_real`; per-image **cost cap** `$0.05`, structured provider-error capture, fail-closed job states.
- Supporting media/image edge: `media-asset-url` (signed, tenant-scoped, short-lived broker), `product-image-import` (upload), `kalodata-product-images` / `kalodata-research-image-url` (research images, view-only).

### Data model (key tables)
- **Generated:** `commerce_generated_assets` (PAL-gated; publishable-candidate only when `IDENTITY_VALIDATED`; reference provenance preserved) — live state: 3 `IDENTITY_VALIDATED`, 1 `REJECT_GENERATED_ASSET` (PAL demonstrably rejects a divergent SKU).
- **Unified media ledger:** `media_assets` (34 cols: `rights_state`, `approval_state`, `is_launch_safe`, `usage_permission`, `identity_state`, `lineage_state`) — 39 rows, 1 launch-safe (strict gate), rights spread FIRST_PARTY_OWNED 7 / SUPPLIER_PROVIDED 4 / GENERATED 13 / PRODUCT_CARD_AUTHORITATIVE 4 / PROVIDER_DISCOVERY_REFERENCE 7 / PROHIBITED 1 / TIKTOK_EMBED_PUBLIC 1.
- **Media job queue:** `media_image_jobs` (18), `media_video_jobs` (10), `media_video_scenes` (40), `media_job_costs` (54), `media_providers` (5).
- **Source assets / identity:** `product_image_assets` (277: 207 MARKETPLACE_PUBLIC_LISTING research-only, 50 PROVIDER_DISCOVERY_REFERENCE, 12 SUPPLIER_PROVIDED), `supplier_product_assets` (36), `product_asset_intelligence` (hero_eligible/identity_state/match_class), `commerce_cross_supplier_identity` (canonical identity), `commerce_identity_lexicon` (73).
- **Rights:** `catalogue_source_rights` (provider-global baseline), `commerce_supplier_image_rights` (BE267 per-image evidence; `permission_scope` jsonb + `verified_at` + `revoked_at`; absence ⇒ RIGHTS_UNVERIFIED).
- **Creative/Ad Studio:** `creative_brand_dna`, `creative_brand_assets`, `creative_concepts`/`_sets`/`_generations`, `creative_production_requests`, `creative_quality_evaluations`, `creative_format_registry`, `creative_design_families`, `creative_platform_contracts`, `creative_learning_records`; `ad_studio_briefs`/`_angles`/`_static_creatives`/`_assets`/`_platform_variants`/`_offers`, `ad_creative_asset_selections`.

### Core eligibility gate — `fn_product_commercial_asset_readiness(product, market)` (the product rule, in code)
Priority order (verbatim logic): **customer-owned authorised upload OR supplier-cleared asset → READY**; supplier-authorised reference → **GENERATABLE_FROM_AUTHORIZED_REFERENCE**; supplier matched but no asset → SUPPLIER_ASSET_REQUIRED; **marketplace-only → CUSTOMER_ASSET_REQUIRED** ("Image access is not republishing rights"); none → UNAVAILABLE; undetermined → UNKNOWN. AI-generation eligible **only** from customer-owned OR supplier-authorized reference. Explicit: *"Marketplace/reference images are never a publishable or generation-eligible source. Rights are never fabricated."* Product Asset Lock: *"Generated output must preserve exact product identity/SKU and pass identity validation (IDENTITY_VALIDATED) … a materially different SKU is REJECT_GENERATED_ASSET."*

### Frontend (Lovable)
- Route **`src/routes/workspace_.creative.tsx`** — "Creative Studio" page, product-scoped ("Create Ad" entry from a product).
- **`src/lib/creative-studio/creative-studio-api.ts`** — fail-closed client: format catalog/select/route (video paid-gated flag), `createProductionRequest` (defaults `generation_authorized=false`, `human_approval_required=true`), `applyFormat`, product-card display preview, `generateCreative`, result polling, `media-asset-url` signed fetch, customer-safe wording.
- Wiring + tests: `commerce-actions-api.ts` invokes `commercial-image-generate`; `commercial-image-asset-lock.test.tsx`, `store-website-panel.generation.test.tsx`, `commercial-image-generation.test.ts`, `creative-studio-api.test.ts`.

## Deliverable 2 — Working vs missing (evidence-based)

### Working (verified by live selftests, all 0 failures unless noted)
`creative_production` 6/6, `creative_studio_routing` 11/11, `creative_format` 14/14, `ad_static_creative` 10/10, `ad_creative_asset_selector` 4/4, `media_composite_identity` 3/3, `media_native_composition` 5/5, `media_composition_backend` 6/6, `media_runtime` 10/10, `media_video_runtime` 15/15, `product_media_auth` 5/5, `product_image` 10/10, `cross_supplier_identity` 13/13, `supplier_identity_evidence_ledger` 6/6, `record_supplier_identity_confirmation` 8/8, `kalodata_product_images` 11/11, `cj_image_rights` 8/8, `discovery_media_integrity` 7/7. Plus: Gemini product pipeline producing IDENTITY_VALIDATED assets and rejecting a divergent SKU; OpenAI static pipeline producing GENERATED_REVIEW_REQUIRED outputs; PAL, cost caps, rate limits, onboarding gate, tenant/country isolation all live.

### Missing / partial (the CS.02–CS.06 gap)
- **CS.02 exact-product media discovery:** identity + supplier-asset resolution exist (`fn_resolve_storefront_assets`, `fn_resolve_cross_supplier_identity`, `fn_capture_product_image`), but **no dedicated high-resolution exact-match candidate *search* across supplier/manufacturer/approved sources with resolution + provenance recorded and ambiguous/substitute rejection**. PARTIAL.
- **CS.03 per-asset rights/eligibility:** `commerce_supplier_image_rights.permission_scope` (jsonb) + `verified_at`/`revoked_at` already support granular scope + revocation; **granular rights vocabulary (download/ads/derivatives/AI-input/video/sublicence) is not yet individually recorded or verified at export.** PARTIAL.
- **CS.04 rights-safe original lane:** upload path (`pulse-product-imports` + `product-image-import` + `fn_product_image_import_register`, rights_confirmed), first-party originals (`creative_brand_assets`, FIRST_PARTY_OWNED), and Gemini original-background scenes all exist. **CC0/licensed-component library is not yet a first-class source.** MOSTLY PRESENT.
- **CS.05 AI image MVP:** Gemini pipeline (3 scenes: CLEAN_STUDIO / LIFESTYLE / PRODUCT_IN_USE) + static gpt-image-1 + PAL = the MVP is **largely built**; "three asset types in one preview pack" is assembly of existing outputs. MOSTLY PRESENT.
- **CS.06 secure downloads:** signed tenant-scoped brokers exist (`media-asset-url`, `fn_media_asset_signed_ref`, `fn_product_image_signed_ref`); **no dedicated finished-pack EXPORT with licence verification at export, watermark/provenance stamping, and "restricted research never downloadable" enforcement.** PARTIAL.

### Pre-existing defect found (reported, not changed — launch-critical/rights-adjacent)
`fn_ad_creative_identity_selftest` = **5 pass / 1 fail**. The failing check `authority_resolves_card_image` asserts the Product-Card *displayed* image equals the authoritative primary, on real fixture product `e453eed4`/GB. That product's authoritative primary is now a CJ `SUPPLIER_PROVIDED` image whose **display rights are UNVERIFIED** (no `commerce_supplier_image_rights` row), so the card **correctly** shows a rights-safe placeholder (`has_image:false`) — making `display == authority` vacuously false. This is **data-state drift, not a code bug, and it does not affect the Creative Studio generation path** (generation resolves its reference via supplier identity + PAL, not the display-authority invariant). **Not fixed here** because the only resolutions touch forbidden/launch-critical territory: seeding a display-rights row (a rights-flag change — prohibited) or relaxing a launch-critical ad-studio invariant. **Recommended resolution (separate ad-studio decision, kept behind launch-critical work):** make the invariant tolerant of a correctly-withheld authoritative primary (assert *display==authority OR display correctly withholds because the authority primary's display-rights are unverified*), which preserves the guarantee while matching the rights model.

## Deliverable 3 — Recommended AI image model, integration path, terms, cost
**Recommendation: keep the two already-integrated, approved models; no new provider needed for CS.05.**
- **Primary (product images): Google `gemini-2.5-flash-image`** — already wired in `commercial-image-generate`, product-faithful edit-from-authorized-reference, PAL-validated. **Cost ≈ $0.039/image** ($30 / 1M output tokens × 1,290 tokens/image, per Google). **Terms:** generated-content commercial use is governed by Google's Gemini API Additional Terms (customer may use outputs; **verify ownership/licence against the live Additional Terms before launch** — not confirmed by an official page in this audit). **Lifecycle:** a model-retirement date was reported third-party and unverified → **pin the model version** and record it.
- **Static ad creatives: OpenAI `gpt-image-1`** — already wired in `creative-image-execute` with a `$0.05` cost cap. **Cost ≈ $0.011 (low) / $0.042 (medium) / $0.167 (high) per 1024² image** (portrait/landscape higher). **Terms:** OpenAI Terms of Use assign output ownership to the customer, subject to usage policies — **verify against live ToS**; consider `gpt-image-1.5`/`-mini` successors.
- **Integration path = reuse.** Both already route provider secrets through n8n (keys never in-app), store to `pulse-generated-media`, register cost in `media_job_costs`, and gate via `fn_creative_generation_cost_gate`. The only *new* work: (a) record **documented commercial terms + pinned model version** in `media_providers.config`; (b) enforce **per-image budget authorisation before any paid call** (CS.05 acceptance). **Neither model resolves third-party trademark/copyright, and AI generation does not guarantee exact product accuracy — PAL is the backstop** (matches the founder's caveat).

## Deliverable 4 — Minimum-viable CS.02–CS.06 (reuse-first; implementation is the next units, not CS.01)
- **CS.02:** add an *exact-product media discovery* reader over existing `supplier_product_assets`/`product_image_assets` keyed on stored brand/model/GTIN/SKU/variant/country, recording resolution + provenance and rejecting ambiguous/substitute matches via the existing identity engine (`fn_resolve_cross_supplier_identity`). Research images stay view-only (already enforced).
- **CS.03:** extend `commerce_supplier_image_rights.permission_scope` to a documented granular vocabulary (download / ads / derivatives / AI-input / video / sublicence) with expiry/revocation, and add a **licence-verification-at-use** check reused by generation + export. Server fail-closed (pattern already present).
- **CS.04:** promote the upload lane (`pulse-product-imports`) and first-party originals to first-class Creative Studio sources; add a licensed/CC0 component register; keep Gemini for original backgrounds only (no scraping). Mostly wiring.
- **CS.05:** assemble the **three-asset preview pack** (product photo pack + lifestyle + ad-creative variants) from the existing Gemini/gpt-image-1 pipelines, product-consistent via PAL, **no paid call without budget approval** (reuse `fn_creative_generation_cost_gate`).
- **CS.06:** add a **finished-pack export** edge (reusing `media-asset-url` signing) that verifies licence at export, stamps watermark/provenance, enforces tenant-scoped ACL + signed-URL expiry + revocation, and **blocks restricted-research assets from download**.

## Deliverable 5 — Tests and security controls (existing, verified)
- **Security:** JWT on generation; server-side ownership (`commerce_products.user_id`, `CROSS_TENANT_REJECTED`); onboarding gate (fail-closed); per-tenant rate limit; provider secrets only in n8n/edge env; private buckets + short-lived signed URLs; RLS/PAL/tenant-country isolation (selftests green).
- **Rights:** marketplace/discovery imagery never publishable/generation-eligible; `RIGHTS_UNVERIFIED` default; PAL `IDENTITY_VALIDATED` gate with `REJECT_GENERATED_ASSET`; per-image rights evidence with revocation.
- **Cost:** `$0.05` static cap, `media_job_costs` ledger, `fn_creative_generation_cost_gate`, `generation_authorized=false` default.
- **Regression:** 18 Creative/media selftests green; 1 pre-existing ad-identity check failing (reported above).

## Deliverable 6 — Unit-by-unit completion evidence + next build sequence
| Unit (roadmap) | Status | Evidence |
|---|---|---|
| **CS.01 (062)** Existing-media architecture audit | **DONE** | This inventory (code/components/selftests); no rebuild; no live change |
| CS.02 (063) Exact-product media discovery | PARTIAL — infra present | identity/asset resolvers exist; needs exact-match search + resolution/provenance recording |
| CS.03 (064) Per-asset rights & eligibility | PARTIAL — schema present | `permission_scope`+revocation exist; needs granular vocabulary + verify-at-export |
| CS.04 (065) Rights-safe original lane | MOSTLY PRESENT | upload + first-party + Gemini backgrounds; needs CC0/licensed register |
| CS.05 (066) AI image MVP | MOSTLY PRESENT | Gemini (3 scenes) + gpt-image-1 + PAL; needs 3-asset preview pack + budget-gated calls |
| CS.06 (067) Secure subscriber downloads | PARTIAL | signed brokers exist; needs export w/ licence-at-export + watermark + research-block |
| CS.07 (068) AI video automation | PARTIAL (separate) | `media_video_*`, Qwen/Veo providers; out of CS.01–06 scope |

**Recommended next sequence:** CS.03 (per-asset rights vocabulary + verify-at-use) → CS.02 (exact-product media discovery) → CS.04 (original lane first-class) → CS.05 (3-asset MVP preview) → CS.06 (secure export). Rights (CS.03) first because CS.05/CS.06 both gate on it. **All behind GPD.09 and the 18-Dec launch-critical GOLD work.**

## Controls
Read-only audit; **no** code/schema/rights/storage/flag/deploy change; **0** paid AI/API calls; **0** credits. GPD.09 and launch-critical work kept ahead. **GOLD 11/22 unchanged.** Build Evidence row **BE321**.

### Sources (deliverable 3 pricing/terms)
- [Google — Introducing Gemini 2.5 Flash Image](https://developers.googleblog.com/en/introducing-gemini-2-5-flash-image/) · [Gemini API pricing](https://ai.google.dev/pricing)
- [OpenAI — Image generation API](https://openai.com/index/image-generation-api/) · [GPT-Image-1 model docs](https://developers.openai.com/api/docs/models/gpt-image-1)

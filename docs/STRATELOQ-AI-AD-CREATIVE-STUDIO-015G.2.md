# STRATELOQ-AI-AD-CREATIVE-STUDIO-015G.2 — Existing Video Provider + Provider-Invisible SaaS Audit

**FINAL VERDICT: `NO_EXISTING_VIDEO_PROVIDER_ENTITLEMENT`.**

Audit only — no generation, no paid call, no new account. **No credential Strateloq currently holds is
verified-entitled to video generation.** The only managed path (n8n Gateway credits) is *proven* not entitled
for video (015G.1: Alibaba imageToVideo → HTTP 400 "Gateway credits don't currently support this operation");
by the same plan MiniMax/Sora video are advertised-but-unentitled. No standalone `alibabaCloudApi` /
`minimaxApi` / Sora-video own-credential exists. The provider-invisible architecture is otherwise sound and now
fully locked (customer read no longer leaks the provider name). The smallest unblock is **one** direct
image→video API key (recommended: Alibaba DashScope, which the existing runtime + staged job already target —
zero code change). The founder creates no account in this unit.

---

## 1. Providers audited
OpenAI (image + Sora video), Google Gemini/Veo, MiniMax (Hailuo), Alibaba/Qwen (Wan), Anthropic, plus the n8n
Gateway managed-credit layer that fronts them.

## 2. Existing credentials — by TYPE only (values never exposed)
- `openAiApi` ×2, `googlePalmApi` ×2, `anthropicApi` ×1 (real own-credentials).
- n8n **Gateway credits** (managed, source `aiGateway`) front: `openAiApi`, `googlePalmApi`, `anthropicApi`,
  `moonshotApi`, `minimaxApi`, `alibabaCloudApi`.
- **No** standalone `minimaxApi`, **no** standalone `alibabaCloudApi`, **no** Sora-video credential.
- Supabase: `supabaseApi` (storage/service); media_providers rows: `OPENAI_GPT_IMAGE` (image),
  `ALIBABA_QWEN_WAN_VIDEO` (video, annotated gateway-not-entitled).

## 3. Actual entitlement status per provider
| Provider | Path | Class |
|---|---|---|
| Alibaba/Wan i2v | Gateway credits | **GATEWAY_ADVERTISED_NOT_ENTITLED** (PROVEN, HTTP 400, 015G.1) |
| MiniMax i2v/t2v | Gateway credits | **GATEWAY_ADVERTISED_NOT_ENTITLED** (inferred — same plan refuses video; not re-tested, no paid call) |
| OpenAI Sora (video:generate) | Gateway credits | **GATEWAY_ADVERTISED_NOT_ENTITLED** (same plan) + text→video, not image→video |
| OpenAI Sora | own `openAiApi` | **CREDENTIAL_EXISTS_ENTITLEMENT_UNVERIFIED** (account works for gpt-image-1; Sora-2 video entitlement separately gated; primarily text→video) |
| Google Veo | Gemini/Vertex | **TECHNICALLY_SUPPORTED_NO_CREDENTIAL** (Gateway gemini exposes image only; Veo not wired; entitlement unknown) |
| MiniMax / Alibaba | own key | **TECHNICALLY_SUPPORTED_NO_CREDENTIAL** (no standalone key configured) |
| Anthropic | own | **NOT_SUITABLE** (no video generation) |
| gpt-image-1 (image) | own `openAiApi` | **ENTITLED_AND_READY** (image only — relevant to the 9:16 canvas step, not video) |

**Net: zero video-capable credential is `ENTITLED_AND_READY`.**

## 4. Image→video support (technical)
Wan (yes, {5,10}s), MiniMax Hailuo (yes, 6/10s), Sora-2 (partial/tiered, primarily text→video), Veo (yes, via
Vertex). All technically support it; none is entitled through a credential we hold.

## 5. Supported duration
Wan {5,10}s (max 10). MiniMax 6/10s. Sora ~4–12s (tiered). Veo ~5–8s. (Documented per provider; Wan verified.)

## 6. Vertical / 9:16 capability
None of the i2v models take an explicit 9:16 parameter — output follows the **source image aspect**. A safe
9:16 requires a pre-frame step (see §19). Sora/Veo can target vertical but share the entitlement gap.

## 7. Product-preservation suitability
Best: **image→video** from the rights-clear product frame (Wan, MiniMax Hailuo) — animates the actual product.
Text→video (Sora "generate", Veo t2v) is weaker for exact product identity. Identity stays
`IDENTITY_REVIEW_REQUIRED` regardless.

## 8. Prompt-steering
Wan i2v: yes. MiniMax i2v: yes (some models). Sora/Veo: yes. All adequate for storyboard-driven motion.

## 9. API / runtime readiness
Server API + async + downloadable output: Wan, MiniMax, Sora, Veo all support it. The Strateloq runtime
(prepare/dispatch/complete/retry, private storage, signed delivery) is provider-neutral and ready — only a
billable credential is missing.

## 10. Estimated / documented costs (no paid call made)
- **Wan i2v (DashScope)** — ESTIMATED: ~$0.05–0.10 / 5s and ~$0.10–0.20 / 10s at 720P (flash tier cheapest;
  plus tier higher). 15s not supported.
- **MiniMax Hailuo** — ESTIMATED: ~$0.10–0.30 / 6–10s (720p).
- **fal.ai / Replicate (aggregator, Wan/Kling/Hailuo)** — ESTIMATED: ~$0.20–0.40 / 5s (markup).
- **OpenAI Sora-2** — DOCUMENTED higher/per-second; UNKNOWN entitlement.
- **Google Veo** — DOCUMENTED per-second (Vertex); UNKNOWN entitlement.
Exact tier prices not confirmed by call (per unit rule).

## 11. Best existing provider
**None entitled today.** Best *technical* fit already targeted by the runtime = Alibaba/Wan i2v — but it needs
an own DashScope key (see §13–14).

## 12. Fallback provider
**MiniMax (Hailuo)** direct key, or a **fal.ai / Replicate** aggregator key (single key → many i2v models;
best for provider-invisibility + swapping providers later).

## 13. Is a new external account actually required?
**Yes.** No currently-held credential is entitled to video. → `NO_EXISTING_VIDEO_PROVIDER_ENTITLEMENT`.

## 14. Smallest external setup if required
**One Alibaba Cloud Model Studio (DashScope) API key** → configure as an n8n `alibabaCloudApi` **own**
credential. This is the smallest possible change: the runtime, the provider row `ALIBABA_QWEN_WAN_VIDEO`, the
staged job `cffb5dcb`, and the n8n executor `ONtIYz4uKvRxFZKi` already target Wan — the workflow simply uses
the own-credential instead of Gateway credits (no code change). A fresh cost gate then applies. Fallback:
a MiniMax key, or an aggregator (fal.ai/Replicate) key for maximum provider flexibility. **No account created
in this unit.**

## 15. Provider-invisible SaaS architecture result
**Locked.** Customers never connect a provider. Provider *selection* is capability-based
(`fn_media_provider_for('VIDEO')`) — never a hardcoded provider. The one leak (the browser-safe read exposed
the internal provider name) is fixed: `fn_ad_studio_creative_read` now returns
`renderer:"STRATELOQ_CREATIVE_STUDIO"` + `generation_type` and never the provider name (contract
`ad_creative_read_v3_015g2`).

## 16. Product Card → Creative Studio path (locked)
`STRATELOQ PRODUCT CARD → canonical commerce_products / product_asset_intelligence (Strateloq-owned) →
Product Decision + intelligence → Creative Studio (concept/hook/copy/storyboard) → INTERNAL video renderer
(receives only a rights-clear source frame + claim-safe prompt) → private pulse-generated-media → human review
→ post/campaign.` The renderer is **only a renderer** — never a product source, product DB, intelligence
source, canonical-identity authority, or customer dependency. Enforced by canonical lineage + launch-safety
gates.

## 17. Strateloq brand-marketing path
Confirmed independent of the video provider: `Brand DNA → AI Marketing Director → Creative Studio →
appropriate renderer → approved asset → Channel Agent → Strateloq-owned account`. Text / static / carousel
posting needs **no** video provider (static uses the already-entitled gpt-image-1 or supplier assets). The
video renderer is invoked **only** when the chosen creative is a generated video.

## 18. Customer provider abstraction status
Effectively in place + now hardened. Selection is by capability/media_type, not a hardcoded provider; customer
contracts expose generation type / state / review / cost, never provider credentials or names. (Optional
future nicety: an explicit `VIDEO_IMAGE_TO_VIDEO` capability tag on the registry — not required; not done, to
avoid a refactor.)

## 19. 9:16 source-frame solution (using existing infra)
**Available via existing entitled infra — no video provider needed.** Use the already-working
**gpt-image-1 image-edit** (`OPENAI_GPT_IMAGE`, endpoint `/v1/images/edits`, proven 015F.1) to perform an
identity-preserving **canvas/background extension (outpaint)** of the product image into a 1080×1920 (9:16)
frame — never stretch, crop the SKU, or invent a product. That 9:16 frame becomes the i2v source. This is the
safest provider-neutral path and reuses an entitled capability. (n8n Edit Image can pad but not outpaint
cleanly; gpt-image-1 outpaint is preferred.) Status: **capability EXISTS (image outpaint); a thin
`prepare-9x16-source` step is not yet wired — MISSING as a wired step, PRESENT as a capability.**

## 20. Caption compositor status
**MISSING.** No FFmpeg / server-side video compositor / Edge Function / n8n video node exists (0 composition
functions in the DB; edge functions are Deno without FFmpeg; n8n Edit Image is image-only). Storyboard
captions are `STORYBOARD_CAPTIONS_READY`; `CAPTIONS_COMPOSED_IN_FINAL_VIDEO` is not implemented. Recommended
later: a deterministic FFmpeg drawtext step (Edge Function with an FFmpeg layer, or an n8n Execute Command /
aggregator render) — **not built here** (would be a large editor; out of scope).

## 21. Current Wan blocked-job state (preserved, not rewritten)
`media_video_jobs.cffb5dcb` = `BLOCKED_EXTERNAL_PROVIDER`; Gateway attempts 1; actual cost **$0**; **0 VIDEO
assets**. Not retried, not rewritten.

## 22. Regressions
All green: video runtime (15/15), canonical lineage (16/16), image runtime (10/10), media_creative_live (4/4),
product_gallery, problem_solution, tiktok_executor. Nightlight GB PME **68.2** unchanged; scoring / WATCH gates
/ Problem Intelligence untouched.

## 23. Files changed
- `supabase/migrations/mig_278_provider_invisible_creative_read.sql` — provider-invisible customer read
  (`renderer=STRATELOQ_CREATIVE_STUDIO`, provider name masked).
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015G.2.md` — this audit.

## 24. Commit hash
See the delivery message (committed to `claude/pulse-crash-recovery-b6ngey`).

## 25. Final verdict
**`NO_EXISTING_VIDEO_PROVIDER_ENTITLEMENT`** — nothing we hold is entitled to video today; smallest unblock is
one DashScope (or MiniMax/aggregator) own-credential; architecture is provider-invisible and locked; the
Strateloq product/lineage/renderer boundary is enforced; 9:16 has an existing-infra path (gpt-image-1
outpaint) and captions remain a documented gap.

---

**STOP.** No generation, no paid call, no new account, no new credential, no Lovable, no social/ad connection,
no campaign, no Marketing Director / Growth Agent activation, no Stripe, no Product Decision or Problem
Intelligence changes, no secrets. The Wan blocked job stays truthful. Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

# STRATELOQ-AI-AD-CREATIVE-STUDIO-015Q — Short-Form Video Production Path Reassessment

**FINAL VERDICT: `VIDEO_PRODUCTION_READY_PENDING_COST_APPROVAL`.**
**`DOES_015Q_WEAKEN_FOUNDER_STANDARD = NO`.**

Audit + preparation only — **no video generated, no paid call, USD 0.00.** The video *runtime* is proven and healthy
(selftest **15/15**); the only gap is a generative provider that can actually be dispatched. Reassessment found a
route the old audit missed: the **existing own Google Gemini credential can see Veo 3.1 video models**, i.e. an
**image-to-video route on an already-configured credential with NO new external account**. It is **paid**, so per
§9 I stopped before any generate call and staged it (disabled) pending founder cost approval. Alibaba/Wan was **not**
reopened. The static system (015L/015M/015O/015P/015P.1) and all identity/claim gates are untouched and green.

---

## Three evidence-driven video hypotheses (one SELECTED_FOR_TEST)

Grounded in the nightlight's real function (**dual-mode star projector & night light**) and the authoritative
Product Card asset (`29e5d89c…`, clean product render). Genuinely different story structures, not wording variants.

| # | Category | Structure | Why it fits the evidence | Decision |
|---|----------|-----------|--------------------------|----------|
| **H1** | **TRANSFORMATION / OUTCOME** | Dark ceiling → device switches on → the room fills with a drifting starfield; end on product + CTA. Hook = darkness → burst of stars in the first 1–2s. | The product's core magic *is* the star projection; the transformation is the strongest claim-safe hook and is exactly what an image-to-video model can animate from the real product seed frame. No people/lifestyle actors needed (lower identity/claim risk). | **SELECTED_FOR_TEST** |
| H2 | PRODUCT_DEMO | Reveal both modes: bright star-projector mode, then soft warm night-light mode; product-forward. | Product is genuinely dual-mode. | Not selected — two distinct controlled lighting states are hard to keep clear and on-identity in one short generative clip; splits the hook. |
| H3 | PROBLEM_SOLUTION | "Bedtime feel like a battle?" → calmer room under the stars (the concept already staged as job `cffb5dcb`). | Bedtime friction is a real use context. | Not selected — a credible bedtime scene needs a child/nursery (people + lifestyle context we hold no authoritative assets for), raising fabrication and claim risk. |

**Why H1 is SELECTED_FOR_TEST (not "winner"/"best"):** strongest 1–2s hook, directly demonstrates the product's
actual benefit, best suited to image-to-video seeded from the authoritative product frame, and avoids people/lifestyle
fabrication. It is selected for *this bounded test*, not ranked as a winning creative.

---

## RETURN

1. **Current video architecture found:** `AI Marketing Director → Creative Production Agent → Creative Studio → Video`
   (015J), sitting on a Supabase video runtime: `media_video_jobs` + `media_video_scenes` (storyboard), `media_assets`
   (VIDEO output), `media_providers` (registry), `media_job_costs` (cost ledger); functions `fn_media_create_video_job`,
   `fn_media_prepare_video_job`, `fn_media_dispatch_video_job`, `fn_media_complete_video_real`, `fn_media_retry_video_job`,
   `fn_media_video_claim_gate`, `fn_media_video_runtime_selftest`. Identity + claim + human-review gates shared with the
   static path (015K.1/015L). Renderer-neutral composition contract (`fn_ad_compile_render_spec` + `STRATELOQ_VIDEO_COMPOSITION`)
   exists but is **`BETA_COMPOSITION_DEFERRED_BY_FOUNDER`** and disabled.
2. **Current video job/runtime state:** **5** video jobs, **all `BLOCKED_EXTERNAL_PROVIDER`**, `render_state`
   `PRODUCTION_PLAN_READY`, lineage CANONICAL; **0** VIDEO assets ever completed. Runtime selftest **15/15 pass**
   (create/prepare/dispatch/claim-gate/complete/retry/identity-block/tenant-isolation/aspect-9:16/scenes/duration). The
   latest job (`cffb5dcb`, 9:16, 10s) has a 4-scene hybrid storyboard: TEXT_HOOK (deterministic), PRODUCT_DEMO
   (`required_capability = VIDEO_IMAGE_TO_VIDEO`), SOURCE_ASSET_MOTION (deterministic), CTA_END_CARD (deterministic) —
   all `RENDER_BACKEND_PENDING`.
3. **Existing video workflows (n8n):** `ONtIYz4uKvRxFZKi` (Creative Video Generation — Wan i2v, manual, bounded; blocked
   not-entitled), `y6pvszAOXJcu147U` (Gemini Video Capability Probe — free models.list; used here).
4. **Available provider/tool inventory (video-relevant):** n8n Gateway `supportedActions` — `openAi`: video `["generate"]`
   (text-to-video), audio generate/transcribe; `minimax`: video `["textToVideo","imageToVideo"]`, TTS; `alibabaCloud`:
   video `["textToVideo","imageToVideo"]`; `googleGemini` (gateway node): **no** video (text+image only). Own-credential
   REST: **Google Veo 3.1** (generate/fast/lite) visible to the existing Gemini key; **Gemini TTS + Lyria music** visible;
   **OpenAI** TTS (`tts`) + Whisper transcribe.
5. **Existing credentials by provider/type (NO SECRETS):** OpenAI ×2 (`openAiApi`), Google Gemini/PaLM ×2 (`googlePalmApi`),
   Anthropic (`anthropicApi`), Google Drive/Sheets/Calendar/Gmail OAuth, Meta ×2 (`facebookGraphApi`), CJ (`httpCustomAuth`),
   eBay (`httpBasicAuth`), DataForSEO (`httpBasicAuth`), TikTok (`httpCustomAuth`), Supabase (`supabaseApi`), Telegram,
   HubSpot, Airtable, JotForm, Apify, SMTP, generic header/query. **No** own MiniMax/Alibaba credential (those are Gateway-only).
6. **Verified entitlements:** (a) **Veo 3.1 models visible to the own Gemini credential** — VERIFIED FREE via workflow
   `y6pvszAOXJcu147U` exec `30261` (2026-09-23, metadata-only models.list, $0). (b) Alibaba/Wan **Gateway video NOT entitled**
   — VERIFIED via prior exec `30243` (HTTP 400 `ai_gateway_request_error`). (c) MiniMax/OpenAI **Gateway** video entitlement
   **UNVERIFIED** — a real generate call would be paid, so it was not probed (§9).
7. **Deterministic-asset video capability:** contracts exist (`STRATELOQ_VIDEO_COMPOSITION` renderer-neutral spec), but
   assembling scenes+captions+transitions into an mp4 needs a render backend (FFmpeg/Remotion/Shotstack/Creatomate) which
   is **founder-deferred** and **not present** in this environment (no local ffmpeg/imageio/cv2). Not a beta blocker per §7.
8. **Image-to-video capability:** **YES, executable on an existing credential** — **Veo 3.1 i2v** via the own Gemini key
   (no new account). Also Gateway `minimax`/`alibabaCloud` i2v (Wan not entitled; MiniMax unverified). **Paid.**
9. **Text-to-video capability:** Veo 3.1 t2v (own Gemini), Gateway `openAi` video generate (Sora, unverified),
   `minimax`/`alibabaCloud` t2v. t2v does **not** preserve product identity → dispreferred vs i2v.
10. **Voice/TTS capability:** YES — Gemini TTS + native-audio (own Gemini credential) and OpenAI `tts` (own OpenAI). Paid, low cost.
11. **Caption capability:** YES — deterministic text overlays (the storyboard already specifies `image_text_overlay`
    captions with safe-area/timing); optional speech→caption via OpenAI Whisper / Gemini transcribe. No new dependency.
12. **Aspect-ratio support:** 9:16 supported end-to-end (runtime selftest M; Veo 3.1 supports 9:16/16:9/1:1; Wan aspect-from-source).
13. **Duration support:** storyboard targets 10–15s across scenes; Veo 3.1 ≈8s/clip; Wan {5,10}s. Reaching 10–30s of
    *multi-shot* runtime requires stitching multiple clips → the deferred render backend, OR multiple Veo segments assembled externally.
14. **Product-identity preservation assessment:** deterministic asset-motion preserves identity perfectly but needs the
    deferred compositor. Generative i2v (Veo/MiniMax/Wan) **seeds** the authoritative frame but generates motion frames →
    identity **NOT guaranteed** → any generative-video route stays **`IDENTITY_REVIEW_REQUIRED`** (per §5); provider success ≠ identity pass.
15. **Three hypotheses:** see table above (H1 TRANSFORMATION/OUTCOME, H2 PRODUCT_DEMO, H3 PROBLEM_SOLUTION).
16. **SELECTED_FOR_TEST:** **H1 — TRANSFORMATION / OUTCOME.**
17. **Recommended beta execution path:** ONE bounded **image-to-video** clip via **Veo 3.1** (prefer `veo-3.1-fast`) on the
    **existing Gemini credential**, seeded with the authoritative polished Product Card frame (015P.1 asset `e75f50f6` /
    clean source `29e5d89c`), **9:16 ~8s**, H1 concept, then run identity + claim + quality gates and human review;
    the user downloads/exports and may edit externally (advanced composition stays deferred). No new account.
18. **Requires paid call:** **YES** (Veo generation is billed per second). No verified zero-cost generative-video route exists.
19. **Exact expected cost if paid:** INDICATIVE (not a quote) — Veo 3.1 fast/lite ≈ USD 0.10–0.40/sec → one ~8s clip
    ≈ **USD ~0.8–3.2**; **proposed max authorized = USD 2.00** for a single bounded run (favor the fast/lite tier). Confirm live.
20. **External setup required:** **NO** — the route uses the existing own Gemini credential; no new external media account
    is needed for Veo. (If the founder instead prefers a Gateway provider and Gateway video proves un-entitled like Wan,
    *that* would require an own MiniMax/DashScope key — but it is not required for the recommended path.)
21. **Missing launch-critical capability:** none for a *bounded first video* (Veo i2v is executable pending cost). To reach
    the **full §6 multi-shot** standard *internally* would need the founder-deferred render/assembly backend — explicitly
    NOT treated as a beta blocker (§7); external editing covers it for beta.
22. **Quality-standard compatibility:** the LOCKED Founder Standard is preserved as the target (9:16, strong hook, product
    role, claim-safe, CTA, human review). A single bare i2v clip is a *bounded test*, not proof the video standard is
    complete (§6); multi-shot polish is the user's external step for beta.
23. **Advanced composition remains deferred:** CONFIRMED — `STRATELOQ_VIDEO_COMPOSITION` = `BETA_COMPOSITION_DEFERRED_BY_FOUNDER`,
    disabled; no paid render/editing SaaS connected; no timeline editor built.
24. **Tests/regressions:** video runtime selftest **15/15**; static/identity suites all green after mig_287
    (`ad_creative_product_card_identity`, `media_product_card_composite_identity`, `ad_creative_asset_selector`,
    `supplier_gallery_ingest`, `ad_static_creative_end_to_end`). Adding the disabled `GEMINI_VEO_VIDEO` provider broke nothing.
25. **Files changed:** `supabase/migrations/mig_287_video_path_reassessment_gemini_veo.sql` (records the Veo route as a
    disabled provider row; no dispatch, no secret), `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015Q.md` (this record). n8n:
    ran the existing free probe `y6pvszAOXJcu147U` (no workflow change).
26. **Commit hash:** see delivery message.
27. **DOES_015Q_WEAKEN_FOUNDER_STANDARD:** **NO** — no paid call, identity/claim/human-review gates intact, static system
    untouched, advanced composition still deferred, no new account pushed, no social/campaign/Stripe/Reddit action.
28. **Final verdict:** **`VIDEO_PRODUCTION_READY_PENDING_COST_APPROVAL`.**

## Founder decision needed (one bounded run)
- **Provider:** Google **Veo 3.1** (recommend `veo-3.1-fast-generate-preview`) · **operation:** image-to-video ·
  **credential:** existing own Gemini (`googlePalmApi`) — **no new account** · **seed:** authoritative Product Card frame ·
  **concept:** H1 (dark room → starfield) · **format:** 9:16, ~8s.
- **Cost:** usage-based; est **~USD 0.8–3.2** for one clip; **max authorized requested: USD 2.00**.
- **On approval** I will dispatch exactly one bounded clip, then run identity + claim + quality review and human review,
  and surface the actual video — it will remain `IDENTITY_REVIEW_REQUIRED` (generative motion ≠ guaranteed identity).
- **If you prefer zero paid video:** the only identity-perfect alternative is deterministic asset-motion, which needs the
  **deferred** render backend — say the word and I will scope it separately, but it is not required for this test.

---

**STOP — audit + preparation complete; nothing generated.** Do not generate the video until cost-approved. No social
accounts connected, no campaigns, no Stripe, no Reddit workaround. Alibaba/Wan NOT reopened. Standard remains LOCKED;
static system stable; advanced composition remains `BETA_COMPOSITION_DEFERRED_BY_FOUNDER`.

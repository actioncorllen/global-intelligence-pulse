# STRATELOQ-AI-AD-CREATIVE-STUDIO-015G.1 — First Authorized Video: Gateway Does Not Entitle Video

**FINAL VERDICT: `BLOCKED_EXTERNAL_VIDEO_PROVIDER`.**

The founder authorized one bounded paid `imageToVideo` call (10s, 720P, 9:16, ≤ USD $0.50). Pre-flight passed;
the single call was executed **once** through the authorized path (n8n Gateway managed credential). The n8n
**Gateway credits do not entitle Alibaba (Qwen/Wan) video generation**: the call was refused at the Gateway
with HTTP 400 `ai_gateway_request_error` — *"Gateway credits don't currently support this operation. Switch to
using your own credential to continue."* — **before any DashScope generation ran. $0 was billed, no video was
produced.** Per authorization, no retry, no provider switch, and no own-credential path were attempted. This
is a genuine external-provider block, recorded truthfully; the runtime, lineage, cost gate and staging remain
correct and ready for whichever provider path the founder authorizes next.

---

## 1. Two-stage story
- **Duration (resolved):** the originally-staged 12s is not a valid Wan duration (Wan i2v supports discrete
  {5,10}s, hard max 10s). Founder re-authorized **10s**; runtime corrected (provider ceiling + duration snap);
  job `cffb5dcb` re-staged at 10s / 720P / 9:16, est **$0.30** ≤ $0.50.
- **Provider entitlement (the block):** executing the 10s call revealed the deeper issue — the **Gateway
  credits do not support the Alibaba video operation at all**, despite `list_n8n_gateway_services` advertising
  `imageToVideo`. Advertised capability ≠ actual Gateway entitlement.

## 2. Corrected pre-flight result
All PASS: job `cffb5dcb`, tenant matches owner, CANONICAL lineage, valid GB decision `ab8607cd`, source
`d82b3835` (SUPPLIER_PROVIDED), angle `43e86d08`, 4 scenes, claim gate PASS, provider available (as
registered), **10s** / 720P / 9:16, est $0.30 ≤ $0.50, no existing VIDEO asset, prior calls = 0, prior spend
= $0.

## 3. Provider call executed
**YES — exactly one** (n8n workflow `ONtIYz4uKvRxFZKi`, execution `30243`, manual, ~0.3s).

## 4. Provider execution result
**Refused at the Gateway.** HTTP 400 `ai_gateway_request_error`: *"Gateway credits don't currently support
this operation. Switch to using your own credential to continue."* The Gateway rejected the video operation
before proxying to DashScope; **no image→video generation ran**.

## 5. Cost accounting
- Authorized calls: **1**; executed: **1**; **actual provider cost: USD $0.00** (Gateway refusal → no metered
  DashScope usage). Authorization cap $0.50 **respected** (nothing billed). No second paid call.

## 6. Resulting video asset / duration / resolution / aspect
**None** — 0 VIDEO assets; no artifact to measure. (Note: Wan i2v also has no aspect parameter — output would
have followed the source aspect, so a deterministic 9:16 pre-frame remains a separate beta gap regardless.)

## 7. Storage / signed delivery / tenant isolation
Not exercised (no asset). The private-bucket + signed-delivery + tenant-isolation contracts are unchanged from
015G and independently green in selftests.

## 8. Visual inspection / product-consistency / storytelling / captions / A–N quality
**N/A — no video was generated.** No artifact was fabricated or assessed. (Also independently: the CJ CDN is
egress-blocked from this environment, so even a produced clip could not have been pixel-inspected here — the
founder would review it via the signed URL. Reported honestly, not worked around.)

## 9. Identity state
Source remains `CLOSE_COMPARABLE` → `IDENTITY_REVIEW_REQUIRED`; nothing cleared. No asset became launch-safe.

## 10. Claim safety
Concept + 4 scenes + CTA scan clean (0 violations) — unchanged; no generated content to re-scan.

## 11. Root-cause finding (015G verification gap)
015G trusted `list_n8n_gateway_services`, which listed `alibabaCloud → video:[textToVideo, imageToVideo]`.
Runtime proves the **Gateway credits plan does not entitle that video operation**. The authorized/available
credential path (Gateway managed `alibabaCloudApi`, source `aiGateway`) cannot bill video; no standalone
DashScope key exists. This is the "credential ≠ authorized API" trap the 015G brief warned about.

## 12. What was recorded (truthful bookkeeping, no spend)
- `media_video_jobs.cffb5dcb` → `BLOCKED_EXTERNAL_PROVIDER`, `error_state=gateway_credits_no_video_entitlement_http400`,
  `actual_cost=0`, provenance `gateway_block` (workflow/execution ids, exact provider error, $0 note).
- `media_job_costs` for the job → `actual_cost=0`.
- `media_providers.ALIBABA_QWEN_WAN_VIDEO` → annotated `gateway_video_entitled=false` +
  `runtime_status=GATEWAY_NOT_ENTITLED_FOR_VIDEO` (config/lineage/cost staging valid; only paid dispatch blocked).
- n8n workflow `ONtIYz4uKvRxFZKi` kept **manual + inactive** (provenance record; not scheduled).

## 13. Remaining video-beta gaps
1. **Provider entitlement (blocker):** no billable image→video path — Gateway credits exclude video; needs a
   real DashScope `alibabaCloudApi` key (own credential) or a different authorized, entitlement-verified
   provider.
2. **9:16 framing:** Wan (and MiniMax) derive aspect from the source; a deterministic non-distorting 1080×1920
   pre-frame step is specified but not implemented (must not distort the product).
3. **Caption compositor:** storyboard captions are `STORYBOARD_CAPTIONS_READY` but no post-gen video caption
   compositor exists (`CAPTIONS_COMPOSED_IN_FINAL_VIDEO` = not implemented).
4. **Duration:** first-video short-form capped at Wan's 10s (now correctly enforced).

## 14. Regression results
All green: video runtime (15/15), canonical lineage (16/16), image runtime (10/10), media_creative_live
(4/4), product_gallery, problem_solution, tiktok_executor. Nightlight GB PME **68.2** unchanged; scoring /
WATCH gates / Problem Intelligence untouched.

## 15. Security
No DDL this stage; no secrets (the Gateway managed credential is server-side; the failed provider response
contains no secret). 0 ERROR baseline unchanged.

## 16. Asset review / launch-safe / canonical lineage
No asset. Job stays non-launch-safe by construction. Canonical lineage (product `e453eed4`, GB decision
`ab8607cd`, angle, storyboard, source `d82b3835`) intact and ready to reuse once a billable provider exists.

## 17. Files / workflows changed
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015G.1.md` — this report.
- `supabase/migrations/mig_277_ad_creative_video_runtime.sql` — Wan duration ceiling correction (prior commit).
- DB bookkeeping (job block + provider annotation; no schema change).
- n8n `ONtIYz4uKvRxFZKi` — manual video executor (inactive; provenance).

## 18. What the founder needs to decide
The concept, lineage and runtime are ready; the only blocker is a **billable image→video provider**. Options:
- **Provision a real DashScope / Alibaba Model Studio API key** and configure it as an n8n `alibabaCloudApi`
  own-credential → the same job `cffb5dcb` executes at 10s with no other change (new cost gate applies).
- **Authorize a different entitlement-verified provider** (would be new work + its own cost gate).
No provider was switched or built, and no key was provisioned, without authorization.

## 19. Final verdict
**`BLOCKED_EXTERNAL_VIDEO_PROVIDER`** — the authorized Gateway path does not entitle image→video generation;
one call was attempted and refused with **$0 billed**; no asset produced; runtime and lineage remain correct
and ready.

---

**STOP.** One provider call attempted, **$0 spent**, 0 VIDEO assets. No retry, no second paid call, no provider
switch, no own-credential provisioned, no multi-clip stitch, no static regeneration, no TTS, no music, no
Lovable, no publish, no Stripe, no social/ad connection, no posting, no campaign launch, no Marketing Director
/ Growth Agent activation, no scoring/WATCH/Problem changes, no secrets. Reddit remains
`BLOCKED_EXTERNAL_APPROVAL`.

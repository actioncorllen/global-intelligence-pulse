# STRATELOQ-AI-AD-CREATIVE-STUDIO-015G.1 — First Authorized Video: HELD on Duration Capability

**FINAL VERDICT: `BLOCKED_EXTERNAL_VIDEO_PROVIDER`** *(duration sub-block — the authorized **12s** exceeds the
Wan image-to-video hard maximum of **10s**; the provider is otherwise ready and the job is re-staged at 10s
within cap. No paid call was made — **zero spend**.)*

The founder authorized exactly ONE bounded paid `imageToVideo` call (job `cffb5dcb`, ≤ USD $0.50, 12s, 720P,
9:16). Pre-flight re-verification passed on every point **except duration**: independent Alibaba Model Studio
documentation confirms Wan image-to-video accepts only **discrete durations {5, 10}s (hard max 10s)** — **12
seconds is not a valid Wan duration**. The 015G n8n node exposes a 2–15s field, but the underlying model
rejects/clamps out-of-set values. Spending the single authorized call on an unsupported 12s parameter would
have either been rejected (wasting the authorization) or silently clamped to 10s (an artifact the founder did
not authorize). Per the "STOP if materially changed / do not auto-execute a replacement" directive, the paid
call was **not** executed. The runtime was corrected to the true ceiling and the job re-staged at 10s.

---

## 1. Pre-flight result
All PASS except duration: exact job `cffb5dcb`, tenant matches owner, **CANONICAL** lineage, valid GB Product
Decision `ab8607cd`, source asset `d82b3835` (SUPPLIER_PROVIDED), angle `43e86d08`, 4 scenes, claim gate
**PASS**, provider `ALIBABA_QWEN_WAN_VIDEO` available, 720P, 9:16, no existing VIDEO asset, not executed,
est cost ≤ $0.50. **Duration 12s is NOT supported by the authorized provider.**

## 2. Root cause (a real 015G defect, now fixed)
015G verified the n8n node *exposes* `duration 2–15s` and trusted that range. The underlying Wan
image-to-video models (2.5 / 2.6 / 2.7) accept only **{5, 10}s** (max 10s). Verified via Alibaba Cloud Model
Studio documentation and multiple independent sources. The 12s staged in 015G was never actually honorable by
Wan (and was already inconsistent with its own storyboard, whose 4 scene durations sum to 10s).

## 3. Decision — no spend
Exactly **0** paid provider calls executed. The single authorization was preserved, not wasted. The provider
is genuinely capable of image→video at 5s/10s; only the specific 12s parameter is unsupported.

## 4. Runtime correction (this unit)
- `media_providers.ALIBABA_QWEN_WAN_VIDEO` capability: `min_duration_s 5`, `max_duration_s 10`,
  `supported_durations_s [5,10]`, explicit `duration_note`.
- `fn_media_create_video_job` and `fn_media_prepare_video_job` now snap any requested duration down to the
  nearest supported Wan value (≥10 → 10, else 5); `default_duration_s` = 10.
- Job `cffb5dcb` re-prepared: **10s / 720P / 9:16**, est **USD $0.30** (indicative, usage-based),
  claim PASS, CANONICAL, launch-eligible-gated, `READY_TO_DISPATCH`. Storyboard already summed to 10s, so the
  correction also aligns job duration with its storyboard.
- Video runtime selftest still **15/15**; **0** VIDEO assets.

## 5. What the founder needs to decide (one line to proceed)
The authorized 12s cannot be delivered by Wan. Two clean options — pick one:
- **Authorize 10s** on the same job `cffb5dcb` (720P, 9:16, ~$0.30 ≤ $0.50 cap, single call). This proves the
  full pipeline (real generation, storytelling, storage, delivery, product-preservation) and is the maximum
  Wan supports. → I execute exactly one call and complete the review.
- **Require exactly 12s** → needs a different provider that supports 12s (e.g. a MiniMax H3 path, 4–15s) or a
  two-clip stitch; both are new work + a new cost gate, so I would return for that authorization.

No paid call, no replacement job executed, no second provider introduced, no retry, no spend, no secrets.
Everything else (product `kids nightlight projector`, GB decision 68.2, canonical lineage, angle, storyboard,
9:16, identity IDENTITY_REVIEW_REQUIRED) is unchanged and ready.

## 6. Files changed
- `supabase/migrations/mig_277_ad_creative_video_runtime.sql` — Wan duration ceiling corrected (provider
  capability + create/prepare duration snap).
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015G.1.md` — this report.

## 7. Final verdict
**`BLOCKED_EXTERNAL_VIDEO_PROVIDER`** (duration sub-block: authorized 12s exceeds Wan's 10s max; provider
otherwise ready; job re-staged at 10s within cap; **zero spend**). Awaiting founder go/no-go per §5.

---

**STOP.** No paid video call (0 VIDEO assets, 0 spend). No replacement job executed, no second provider, no
retry, no static regeneration, no TTS, no music, no Lovable, no publish, no Stripe, no social/ad connection,
no posting, no campaign launch, no Marketing Director / Growth Agent activation, no scoring/WATCH/Problem
changes, no secrets. Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

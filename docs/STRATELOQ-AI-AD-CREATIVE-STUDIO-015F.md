# STRATELOQ-AI-AD-CREATIVE-STUDIO-015F — Generation Runtime + First Real Static Ad

**FINAL VERDICT: `READY_FOR_FOUNDER_GENERATION_APPROVAL`.**

The missing **server-authoritative generation runtime** is implemented and proven end-to-end **up to the
paid provider boundary**, entirely on real Strateloq intelligence lineage. One real static-ad job (the
founder's **3-Channel Dash Cam**, US market) is fully staged: claim-gate **PASS**, product identity
preserved from the **rights-clear CJ supplier** source, `IDENTITY_REVIEW_REQUIRED`, cost estimated, awaiting
the **single** bounded gpt-image-1 call (~**USD 0.02**). Executing it would create a new non-zero provider
charge, so per the cost gate it was **not executed**. Runtime selftest **10/10**; all regressions green;
security **0 ERROR**; no fabricated media; no Product Decision / Problem / gallery-identity change; no
Lovable / publish / Stripe / activation / ad spend. Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

---

## 1. Audit of exact existing components reused
Verified against live state (not docs): `ad_studio_briefs/angles/static_creatives/platform_variants`,
`media_image_jobs/assets/providers/job_costs`, and functions `fn_media_create_image_job`,
`fn_media_complete_image_real` (records the real asset IN_REVIEW / is_launch_safe=false / identity
provenance), `fn_media_generation_result` (browser-safe asset read), `fn_media_retry_image_job` (bounded
idempotent retry), `fn_media_provider_for`, `fn_ad_studio_claim_scan` (violation detector),
`fn_media_creative_live_selftest` (4/4). Provider `OPENAI_GPT_IMAGE` registered+enabled. Private bucket
`pulse-generated-media` present. **All reused, nothing duplicated.**

**Live-state correction to 015E:** an n8n executor prototype **does** exist —
`Pulse - Creative Image Generation (Manual, OpenAI)` (`dYoeIeiXwPOrDDY4`, inactive, manual, 5 nodes:
download source → gpt-image-1 `/images/edits` product-preserving edit → compute token cost → upload to
`pulse-generated-media`). It is a **disconnected, hardcoded** prototype (dashcam URL/prompt; does not read a
`media_image_jobs` row and does not call `fn_media_complete_image_real`; 0 executions). So the runtime was
**PARTIAL**, not absent.

## 2. Files / schema / functions changed
- `supabase/migrations/mig_275_ad_creative_generation_runtime.sql` — 6 new functions + runtime selftest.
- `supabase/functions/media-asset-url/index.ts` — signed-delivery Edge Function (deployed, verify_jwt).
- `docs/STRATELOQ-AI-AD-CREATIVE-STUDIO-015F.md` — this report.
No table/column added; no existing function's behavior changed except additive glue.

## 3. Generation executor implementation
Server-authoritative DB executor (SECURITY DEFINER, tenant-scoped, `search_path ''`):
- `fn_media_claim_gate(angle)` — HARD claim gate over hook+headline+primary+supporting+cta+visual_concept+brief.
- `fn_media_prepare_image_job(job, tenant)` — pre-flight: provider check → claim gate → product-identity
  provenance → **real cost estimate**; sets `READY_TO_DISPATCH` (or `BLOCKED_CLAIM_REVIEW` /
  `BLOCKED_EXTERNAL_PROVIDER`). **No provider call.**
- `fn_media_dispatch_image_job(job, tenant)` — executor claim `READY_TO_DISPATCH → GENERATING`, re-runs the
  claim gate, returns the provider call payload (source asset, prompt, model, endpoint, size, quality).
  **Idempotent** (ALREADY_GENERATING / ALREADY_COMPLETE) so it never double-charges.
- Completion via existing `fn_media_complete_image_real` (executor calls it post-upload); bounded failure/
  retry via existing `fn_media_retry_image_job`.
The **provider-call arm** is the credentialed n8n workflow (holds the OpenAI credential); at approval it is
parameterized to a `job_id` and, after upload, calls `fn_media_complete_image_real`. No secret in SQL/browser.

## 4. Executor lifecycle
`DRAFT/READY → (prepare) READY_TO_DISPATCH → (dispatch) GENERATING → (complete) GENERATED_REVIEW_REQUIRED`
→ asset `generation_status=GENERATED`, `approval_state=IN_REVIEW`, `is_launch_safe=false`. Failure →
`fn_media_retry_image_job` → `QUEUED` (bounded) → `FAILED` at max_retries. Gates: `BLOCKED_CLAIM_REVIEW`,
`BLOCKED_EXTERNAL_PROVIDER`.

## 5. Provider verification (REGISTERED ≠ WORKING)
- **Config verified:** `gpt-image-1`, endpoint `https://api.openai.com/v1/images/edits`, modes
  `IMAGE_EDIT_FROM_PRODUCT_ASSET` + `TEXT_TO_IMAGE`, default 1024x1024, cost_model "~USD 0.04 medium",
  `secret_storage: server_side_only`.
- **Credential verified present:** OpenAI account credential in n8n (bound in the executor prototype).
- **Call shape verified:** the prototype demonstrates the exact multipart `/images/edits` request +
  token-based cost extraction + bucket upload.
- **Live execution NOT proven:** a real generation is the single gated paid call. Verdict for the provider:
  configured + credentialed + call-shape-valid; **live execution pending the one approved call.** No
  fabrication of success.

## 6. Provider / model used or proposed
`OPENAI_GPT_IMAGE` / `gpt-image-1`, image **edit** mode (product-preserving), 1024×1024, quality **low** for
the first bounded test.

## 7. Intelligence → creative lineage
`ad_studio_brief 15f0aabd (real, non-fixture)` → `angle 672c7d11 (PROBLEM_SOLUTION)` →
`static_creative dc0e0f62 (META 1:1)` → `media_image_job 5d4fe8f0 (READY_TO_DISPATCH)` → (pending) asset.
Recorded on the job's provenance: brief_id, angle_id, canonical_product_id, source asset, source provider,
identity_state, cost.

## 8. Exact product selected
**3 Channel Dash Cam (Front 1080P / Inner 480P / Rear 480P)** — canonical product ref
`ae458526-3fd2-47e0-a613-3da7b7f92f11`, tenant `7c8ddf9d…`. Real founder brief.
*Lineage note:* the brief's `decision_id`/`opportunity_id` are null and `product_id` does not resolve to a
`commerce_products` row (brief carries product context inline) — a lineage gap to close in a later unit by
linking a Product Decision. Market evidence is PRESENT; product context is real.

## 9. Selected market
**US** (currency USD), from the brief. Platform targets META + TIKTOK.

## 10. Creative concept selected
**PROBLEM_SOLUTION** — hook "Still dealing with capturing clear front, cabin and rear video while driving?";
static execution = product-preserving in-context hero (device mounted on a windshield, soft car interior),
which is a genuine advertising idea, not a plain cutout. `claim_risk=LOW`.

## 11. Product identity provenance
Source = **CJ_SUPPLIER** image `cf.cjdropshipping.com/0c425d56…jpg` (rights-appropriate supplier photo).
Recorded: canonical_product_id, product_name, brief_id, angle_id, source_asset_url, source_provider,
rights_note, `identity_state = IDENTITY_REVIEW_REQUIRED`. gpt-image-1 edit preserves the device but cannot
GUARANTEE pixel-exact identity → human identity review mandatory; never substitute another SKU/model/brand.
**Rights finding:** the first ad correctly uses a **supplier (rights-clear)** source, not an eBay
marketplace reference image (which the runtime labels `MARKETPLACE_REFERENCE — not rights-clear`).

## 12. Claim-safety result
Hard gate **PASS** for the dash-cam angle (0 violations). The image-edit prompt explicitly forbids baked-in
text/logos/badges/price-tags. Selftest proves the gate **blocks** a violating angle (6 violations →
`BLOCKED_CLAIM_REVIEW`, no dispatch). Distinction preserved: SOURCE_FACT / DERIVED_INSIGHT /
CREATIVE_HYPOTHESIS / GENERATED_CREATIVE.

## 13. Brand DNA used / missing
`member_business_dna` for this tenant = **0 rows** → Brand DNA **absent**; proceeded default-safe (no logo/
palette/prohibited-terms invented). Reused the existing contract; did not build a second Brand DNA system.
Populating tenant Brand DNA is a POST_BETA enhancement.

## 14. Storage implementation / result
Reused private `pulse-generated-media` (unchanged, still private). The executor uploads the generated PNG
server-side and `fn_media_complete_image_real` records `storage_ref` + metadata (tenant/product/creative/
source/provider/model/dimensions/cost/provenance/approval). No object made public.

## 15. Signed-delivery implementation
Edge Function `media-asset-url` (deployed, `verify_jwt=true`): authenticates the caller → ownership via
`fn_media_asset_signed_ref` (tenant_id=auth.uid) → mints a **300s** signed URL server-side for the owned
path only. Service-role key never returned to the browser; no public URLs. `storage.objects` stays
default-deny.

## 16. Browser-safe read contract
`fn_ad_studio_creative_read(angle_id)` (authenticated, tenant-scoped) returns brief + concept + platform
variants + generation state + claim-gate + product-identity + asset (via `fn_media_generation_result`) +
approval/failure state. No provider secrets, no service creds.

## 17. Tenant-isolation test
Runtime selftest: prepare/dispatch with the wrong tenant → `not_found_or_forbidden`; `creative_read` under a
simulated other-tenant JWT → `forbidden`; `fn_media_asset_signed_ref` requires auth and checks tenant. **10/10
selftest pass** including these isolation cases. Tenant A cannot reach Tenant B media.

## 18. Campaign-draft lineage finding
Two lineages remain (as 015E.1 found): legacy `marketing_campaign_drafts` (Marketing Director) and newer
`campaign_builder_drafts` (`fn_cb_build_campaign`, Ad Studio handoff). The Creative Studio handoff
(`fn_ad_studio_campaign_handoff` / `fn_cb_build_campaign`) uses **`campaign_builder_drafts`**. **No third
lineage created; no migration performed.** Reconciliation (make `campaign_builder_drafts` authoritative; MD
feeds it) is deferred to a later unit.

## 19. Marketing Director future handoff compatibility
Preserved: the generated asset → `media_assets` (approval-gated) → `campaign_builder_drafts.media_asset_ids`
→ (future) Marketing Director orchestration → (future) Ad-Performance Specialist reading
`campaign_performance_snapshots`. `creative_strategy_ref`/`ad_variant_ref` on the asset keep the concept↔
asset↔campaign lineage intact. No performance loop implemented; no performance fabricated.

## 20. First static generation status
**STAGED, NOT EXECUTED.** Job `5d4fe8f0` = `READY_TO_DISPATCH`. 0 `media_assets` are `READY` (nothing
generated). Awaiting founder approval for the single paid call.

## 21. Provider call count
**1** (one gpt-image-1 image-edit call). No batch.

## 22. Cost / estimated cost
**~USD 0.02** (gpt-image-1, 1024×1024, **low** quality; token-based; ≤ ~USD 0.04 at medium). This is a
**new non-zero charge** → cost gate triggered → not executed.

## 23. Generated asset provenance if executed
N/A (not executed). On approval: asset recorded with provider, provider_job_id, source_asset_refs (the CJ
image), generation_mode `IMAGE_EDIT_FROM_PRODUCT_ASSET`, prompt, cost, `IN_REVIEW`, `is_launch_safe=false`,
`IDENTITY_REVIEW_REQUIRED`.

## 24. Quality acceptance result if executed
N/A (not executed). On approval the output will be judged against the A–K standard (product basis, identity
lineage, visual hierarchy, clear idea, composition, market relevance, Brand DNA where available, no
unsupported claims, CTA, platform fit, commercial usefulness); if it renders but is weak →
`GENERATION_WORKS_QUALITY_NOT_READY` (reported honestly, not hidden).

## 25. VIDEO runtime readiness for 015G
The same runtime extends to video with **no second architecture**: `media_video_jobs` (source_image_asset_id
→ image-to-video, video_hook/script/storyboard, duration, motion, text_overlays, cta) + `media_video_scenes`
(scene sequencing, voiceover, transition) already exist; `fn_media_build_storyboard`, `fn_media_create_video_job`
exist. 015G adds a VIDEO provider registration + a video variant of prepare/dispatch reusing the identical
claim-gate + identity provenance + cost + completion + signed-delivery + read contracts, targeting 9:16
short-form (HOOK→PROBLEM→PRODUCT→DEMO/TRANSFORMATION→OUTCOME→CTA). Video is BETA_REQUIRED.

## 26. Regression results
All green: `ad_creative_runtime` (10/10), `media_creative_live` (0 failed), `product_gallery`,
`problem_solution`, `problem_discovery`, `problem_foundation`, `research_orchestrator`, `tiktok`,
`search_relevance`, `deep_research`. Unchanged: nightlight GB PME **68.2**, gallery identity, Product
Decision scoring, Problem corroboration, TikTok state.

## 27. Security advisor results
**0 ERROR, 1 INFO, 4 WARN** (baseline). New functions SECURITY DEFINER + `search_path ''` + least-privilege
grants; edge function `verify_jwt=true`; private bucket unchanged; tenant isolation enforced; no
client-controlled tenant escalation; no secrets in code/logs/report.

## 28. External blockers
None blocking the runtime. The only remaining step is **founder approval for one bounded ~USD 0.02
gpt-image-1 call**. (Provider live-execution proof is contingent on that call.)

## 29. Fixture contamination check
0 stray `[[mrt]]%` fixtures (runtime selftest self-cleans). 0 `media_assets` READY. The staged dash-cam job
is **real** founder intelligence (non-fixture), intentionally persisted as the pending first ad.

## 30. Commit hash
See the delivery message (committed to `claude/pulse-crash-recovery-b6ngey`).

## 31. Final verdict
**`READY_FOR_FOUNDER_GENERATION_APPROVAL`** — runtime real and proven to the paid boundary; one bounded
gpt-image-1 call (~USD 0.02) on the dash-cam awaits approval.

---

### Founder approval request (one bounded generation)
| Field | Value |
|---|---|
| Provider / model | OPENAI_GPT_IMAGE / gpt-image-1 (image **edit**) |
| Call count | **1** (no batch) |
| Estimated cost | **~USD 0.02** (≤ ~0.04) |
| Product | 3 Channel Dash Cam (US) |
| Source (rights) | CJ_SUPPLIER product image (rights-clear) |
| Creative concept | PROBLEM_SOLUTION — product-preserving in-context hero |
| Output | 1 static 1024×1024 PNG → private bucket → IN_REVIEW, IDENTITY_REVIEW_REQUIRED, not launch-safe |

**STOP.** No provider call executed, no video, no avatar, no Lovable, no publish, no Stripe, no social/ad
account connection, no campaign launch, no ad spend, no Marketing Director / Growth Agent activation, no
fabricated media or performance, no secrets. Product Decision scoring, Problem corroboration, and strict
gallery identity are unchanged. Reddit remains `BLOCKED_EXTERNAL_APPROVAL`. Awaiting founder go/no-go for the
single bounded generation.

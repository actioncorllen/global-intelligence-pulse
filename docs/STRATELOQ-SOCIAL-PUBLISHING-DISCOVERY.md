# STRATELOQ-SOCIAL-CONTENT-PUBLISHING-DISCOVERY-001

Discovery only — no builds, no schema changes, no publishing, no spend, no schedule changes.
Verdict: **PASS (discovery complete)** — ~80% of the target pipeline already exists as production
contracts; the true gap is the organic **publish executor + attempt/result ledger + organic
performance collector**, plus non-Meta platform connections that are external stage-gates.

## 1. EXISTING CAPABILITIES (verified live)

- **Accounts / OAuth / credential vault:** `social_platform_connections` (tenant, platform,
  connection_type ORGANIC|…, external_account_id, authorization_status, granted_scopes,
  capabilities, `secret_ref` vault, expiry/verify/revoke), `social_oauth_states` (PKCE/state),
  `fn_social_oauth_begin/consume`, `fn_social_meta_finalize/list_discovered/set_discovered`,
  `fn_social_required_scopes`, `fn_social_scope_subset_ok`, `fn_social_connection_capabilities`,
  `fn_social_platform_external_requirements`, `fn_social_secret_put/read/clear`. Meta edges:
  `meta-facebook-oauth-begin/callback/select-page/disconnect`. **Live: 1 connection —
  META_FACEBOOK / ORGANIC / CONNECTED (Page, secret vaulted, verified 2026-09-24).**
- **Marketing Director:** `fn_marketing_director_strategy`, `fn_marketing_director_to_creative_request`,
  `marketing_campaign_drafts` (+ approve/reject/persist), `get_member_marketing_context`,
  n8n "AI Marketing Director v1".
- **Creative Director / Ad Studio:** briefs→angles→platform_variants→static_creatives
  (`fn_ad_studio_build_brief/generate_angles/select_test_angle/approve_angle/platform_variants/
  static_creative_prepare/campaign_handoff`), `ad_studio_*` tables, `creative_format_registry` +
  `fn_creative_format_*` (catalog/route/select/QA/apply) with **platform aspect ratios + safe areas**.
- **Content production (organic copy):** `generated_content` (script, caption, hashtags,
  hooks/CTA variations, image_prompts, SEO, per-platform, multilingual) + `start_content_generation`,
  `claim_next_content_job`, `persist_generated_content`; n8n "Agent 6 GLOBAL: Content Generator"
  (active) and "Agent 6 Customer Content Worker" (active).
- **Media generation (image + video):** `media_image_jobs` / `media_video_jobs` full lifecycle
  (`fn_media_create/prepare/dispatch/complete/retry/fail/quality_gates`), providers + cost gates
  (`fn_creative_generation_cost_gate`, `media_job_costs`). n8n executors (active): Gemini Commercial
  Image, OpenAI Creative Image; (gated) Veo 3.1 T2V/i2v, Alibaba Wan i2v.
- **Brand / Truth safety + Product Asset Lock:** `fn_ad_studio_claim_scan`, `fn_media_claim_gate`,
  `fn_media_video_claim_gate`, `fn_media_campaign_safety_gate`, `fn_ad_creative_identity_policy`,
  `fn_media_product_identity_preserved`, `fn_media_product_card_source_verified`,
  `fn_ad_product_card_select_creative_asset`; n8n "Gemini Product Identity Validator" (active,
  IDENTITY_VALIDATED / REJECT). Product Card SKU cannot be silently swapped.
- **Organic publishing spine:** `social_publishing_requests` (platform, connection_type,
  destination_account, content, `scheduled_at`, `approval_id`, `caption_approved`, `publish_mode`,
  `automation_authorized`, `execution_enabled`, `execution_state`, `blocked_reasons`) +
  `fn_social_publishing_preflight` + `fn_social_publishing_request`.
- **Paid lane (separated):** `marketing_spend_authority` (+ create/approve/revoke, ceilings,
  fingerprint), `spend_reservations` (+ `fn_reserve_spend/release_spend`), `marketing_authority_audit`,
  `marketing_campaign_executions`, `fn_cb_build_campaign/fn_cb_approve`, `fn_build_tracking_identity`,
  `fn_tracking_readiness`, edges `meta-capi-adapter`/`meta-insights-reader`, n8n "Meta Draft
  Executor" (DRAFT-first, PAUSED-only) and "Meta Ads Insights Recovery".
- **Performance / learning:** `campaign_performance_snapshots` (paid), `performance_learnings`,
  `performance_learning_memory`, `performance_experiments`, `analytics_events`,
  `fn_performance_handoff`.
- **Intelligence / Product-Platform-Fit:** `fn_ppf_evaluate/rank/monday_block/execution_readiness`,
  n8n "Monday Ecom Product Opportunity Orchestrator" (**Mon 07:00 UTC — do not alter**), trend
  collectors, research executors.

## 2. REUSABLE WORKFLOWS / CONTRACTS (map to target architecture)

| Target stage | Reuse (do not rebuild) |
|---|---|
| Intelligence → Content Opportunity | `fn_ppf_*`, opportunity decisions, trend/research pipeline |
| Marketing Director | `fn_marketing_director_strategy`, `marketing_campaign_drafts` |
| Creative Director | Ad Studio (`fn_ad_studio_*`), `creative_format_registry` |
| Content Production | `generated_content` + Agent 6 workers; `fn_creative_production_request` |
| Brand / Truth Safety | claim/identity gates + Gemini Identity Validator (Product Asset Lock) |
| Platform Adaptation | `ad_studio_platform_variants`, `fn_creative_platform_spec`, format registry |
| Approval Policy | `approve_marketing_campaign_draft`, `fn_media_approve_asset`, `fn_ad_studio_approve_angle`, `caption_approved`/`human_approval_required` flags |
| Publishing Orchestrator (organic) | `fn_social_publishing_preflight` + `fn_social_publishing_request` + `social_publishing_requests` |
| Platform Adapter (connect) | `social_platform_connections`, `social_oauth_states`, `fn_social_oauth_*`, `fn_social_meta_*`, secret vault, Meta OAuth edges |
| Publish Status | `social_publishing_requests.execution_state` (needs attempt/result ledger — gap) |
| Performance Intelligence | `campaign_performance_snapshots` (paid); organic collector is a gap |
| Learning | `performance_learnings/memory/experiments`, `fn_performance_handoff` |
| Paid execution (separate) | spend authority + reservations + Meta Draft Executor |

## 3. DUPLICATION TO AVOID

Do **not** create new `social_accounts` (use `social_platform_connections`), `social_publish_jobs`
(use `social_publishing_requests`), `social_creative_assets` (use `media_assets` +
`ad_studio_static_creatives`), paid `social_post_variants` (use `ad_studio_platform_variants`),
`social_brand_profiles` (use `business_profiles` / `member_business_dna` / `brand_dna`), a second
content generator (reuse Agent 6 / `generated_content`), a second creative/media pipeline (reuse Ad
Studio + media jobs + Product Asset Lock validators), a second spend system (reuse
`marketing_spend_authority`), or a second performance/learning system.

## 4. TRUE MISSING CAPABILITIES

1. **Organic publish executor** (per platform): read APPROVED + READY `social_publishing_requests`,
   call the platform Graph API to post, record outcome. None exists (the Meta Draft Executor is the
   *paid* PAUSED-campaign adapter). `fn_social_publishing_preflight` **always returns
   `execution_enabled=false`** — preflight/queue only today.
2. **Publish attempt/result ledger:** no `social_publish_attempts` / `social_post_results` tables;
   `social_publishing_requests` holds only `execution_state` (no per-attempt history / idempotency /
   platform post id). Small extension needed.
3. **Organic post performance collector + store:** `campaign_performance_snapshots` is paid-only;
   no organic per-post metrics (reach/impressions/likes/comments/shares) table or collector.
4. **Scheduling runner:** `scheduled_at` exists but nothing consumes it (event-driven publish runner).
5. **Per-account autonomy policy (optional):** autonomy is per-request flags (`publish_mode`,
   `automation_authorized`); no per-account default policy row (DRAFT_ONLY / APPROVAL_REQUIRED /
   SCHEDULED_PUBLISH / AUTO_PUBLISH_ALLOWED). Recommend a thin `social_approval_policies` later.
6. **Business (non-product) social graphics:** product creatives are strong; SaaS/business social
   graphic templates for Strateloq/Pulse-owned brand posts are thin (brand tokens exist; templates do not).

## 5. PLATFORM CONNECTION STATUS

| Platform | Connection | Organic publish executor |
|---|---|---|
| Meta / Facebook (Page, organic) | **CONNECTED_REAL** (1 live connection) | MISSING_INTERNAL_IMPLEMENTATION |
| Instagram | ARCHITECTURE_EXISTS_NOT_CONNECTED · REQUIRES_EXTERNAL_OAUTH · REQUIRES_PLATFORM_APPROVAL (IG Content Publishing via linked FB Page/IG Business) | MISSING_INTERNAL_IMPLEMENTATION |
| LinkedIn | ARCHITECTURE_EXISTS_NOT_CONNECTED · REQUIRES_EXTERNAL_OAUTH · REQUIRES_PLATFORM_APPROVAL (Community Management API) | MISSING_INTERNAL_IMPLEMENTATION |
| TikTok | ARCHITECTURE_EXISTS_NOT_CONNECTED · REQUIRES_EXTERNAL_OAUTH · REQUIRES_PLATFORM_APPROVAL (Content Posting API, audited). *Note: existing TikTok token broker is ad-library research, not publishing.* | MISSING_INTERNAL_IMPLEMENTATION |
| Meta Ads (paid, separate lane) | CONNECTED_REAL app + Draft Executor + spend authority | REQUIRES_PLATFORM_APPROVAL for live delivery (Advanced Access / app was development-mode) |

## 6. EXTERNAL APPROVAL / CREDENTIAL BLOCKERS (mandatory stage gates)

- **Instagram / LinkedIn / TikTok publishing:** each needs its own OAuth app + user authorization
  **and** platform review/permission grant (IG content publishing, LinkedIn Community Management,
  TikTok Content Posting audit). These are hard external gates — no mocks.
- **Facebook organic posting** on the existing connection needs `pages_manage_posts` (verify the
  granted scope on the live connection before first real post).
- **Paid Meta live delivery** needs Meta App Review / Advanced Access (separate from organic).
- Do not substitute mocks for real connectivity; each unconnected platform is blocked until its
  external grant is in hand.

## 7. PROPOSED MINIMAL ARCHITECTURE (reuse-first)

Reuse the whole existing chain; add only the execution leg:

`generated_content` / Ad Studio creative (+ Product Asset Lock) → `media_assets` (APPROVED,
launch-safe) → `fn_social_publishing_request` (creates row, `publish_mode=MANUAL`,
`execution_enabled=false`) → `fn_social_publishing_preflight` (READY_FOR_MANUAL_PUBLISH) →
**NEW: organic publish executor** (n8n workflow per platform, manual/event trigger) that:
(a) claims a READY request for a CONNECTED_REAL organic connection, (b) reads the vaulted token via
service role, (c) calls the platform Graph API, (d) writes a **NEW `social_publish_attempts`** row
and on success a **`social_post_results`** row (platform post id, permalink), (e) updates
`social_publishing_requests.execution_state`. Add a thin **organic performance collector** later
(reuse `performance_learnings`). Scheduling = an event-driven runner over `scheduled_at`.

## 8. SECURITY / TENANT-ISOLATION REQUIREMENTS

- Tokens stay in the `secret_ref` vault (`fn_social_secret_*`); never selected into app payloads,
  logs, or the executor's returned JSON. Executor reads secrets via service role only.
- All new tables tenant-scoped (`tenant_id`) with RLS: members read only their own; writes only via
  SECURITY DEFINER functions / service role (mirror the existing member/storefront pattern).
- **Organic authority must never touch spend authority.** The organic executor gets no access to
  `marketing_spend_authority` / `spend_reservations` / ad-account tokens. Keep the lanes on separate
  connections (`connection_type='ORGANIC'` vs paid ad account) and separate executors.
- Default autonomy stays **APPROVAL_REQUIRED**; `AUTHORIZED_AUTO` requires explicit
  `automation_authorized` (already enforced by preflight). No autonomous public publishing is enabled
  in this discovery; `execution_enabled` remains false until a deliberate, gated unit turns it on.
- Publishing runs event-driven and is **not** a market-intelligence scan → the Monday-only research
  schedule is untouched.

## 9. ESTIMATED COST — incremental, monthly (ranges; do not purchase until measured)

Assumes existing self-hosted n8n + Supabase (no new infra). Organic social APIs are free (rate-limited).

| Lane | Founder-only beta | 10 tenants | 100 tenants |
|---|---|---|---|
| n8n execution | ~$0 (marginal on existing instance) | ~$0–20 | ~$20–80 (may need a worker) |
| LLM text (copy/hooks/caption) | ~$2–10 | ~$20–80 | ~$150–500 |
| Image generation | ~$3–15 (gpt-image-1/Gemini) | ~$30–120 | ~$250–900 |
| Video generation (opt-in, gated) | ~$0–30 (Veo/Wan per clip) | ~$50–300 | ~$400–2,500 |
| Media storage (Supabase) | <$1 | ~$1–10 | ~$10–60 |
| Social APIs (organic) | $0 | $0 | $0 (paid ads = separate budget) |
| Analytics/metrics storage | <$1 | ~$1–5 | ~$5–30 |
| **Total (excl. paid ad spend)** | **~$5–70** | **~$100–600** | **~$800–4,000** |

Cost is dominated by media generation; text/storage/APIs are minor. Video is the swing factor — keep
it opt-in and cost-gated (`fn_creative_generation_cost_gate` already exists). Paid advertising spend
is separate and governed by `marketing_spend_authority` (not incurred by organic publishing).

## 10. EXACT IMPLEMENTATION SEQUENCE

1. **Ledger:** add `social_publish_attempts` + `social_post_results` (tenant-scoped, RLS, idempotency
   key, platform post id/permalink) — the only new tables. Extend `social_publishing_requests`
   status transitions to reference them.
2. **FB organic executor (manual trigger):** n8n workflow that claims one READY request for the
   CONNECTED_REAL Facebook Page, posts via Graph API using the vaulted token, records
   attempt+result, updates state. Manual only; `execution_enabled` still false by default.
3. **Verify scope + one real FB post** on the Strateloq/Pulse account behind explicit approval;
   confirm attempt/result + permalink.
4. **Organic performance collector** for FB post insights → `performance_learnings` (event-driven).
5. **Scheduling runner** over `scheduled_at` (event-driven; still APPROVAL_REQUIRED to enter queue).
6. **Per-account autonomy policy** (`social_approval_policies`) with default APPROVAL_REQUIRED.
7. **Instagram** (after IG Business link + content-publishing permission) — reuse the executor shape.
8. **LinkedIn**, then **TikTok** — each gated on its external OAuth + platform approval.
9. **Tenant/customer accounts** — reuse the same connection + executor with tenant RLS.

## 11. FIRST IMPLEMENTATION UNIT

**Organic Facebook-Page publish execution leg for the single CONNECTED_REAL Strateloq/Pulse account:**
add `social_publish_attempts` + `social_post_results` (tenant-scoped, RLS, SECURITY DEFINER writers,
idempotent) and a **manual-trigger** FB organic publish executor that consumes a preflight-READY,
APPROVED, launch-safe, Product-Asset-Lock-clean `social_publishing_requests` row, posts to the
Facebook Graph API via the vaulted token, and records the attempt + result (post id/permalink).
Default remains DRAFT_ONLY / APPROVAL_REQUIRED; no schedule; organic lane has zero spend access.
It is the smallest real end-to-end slice because Facebook organic is the only CONNECTED_REAL platform.

## 12. VERDICT

**PASS** — discovery complete. The architecture is reuse-ready; build the organic execution leg
incrementally starting with the First Implementation Unit. External OAuth/approval for IG/LinkedIn/
TikTok are genuine stage-gates to schedule in parallel. Nothing was built, published, scheduled, or
authorized for spend in this unit.

# STRATELOQ SOCIAL PUBLISHING & ADVERTISING EXECUTION POLICY (CANONICAL — LOCKED)

**Status: LOCKED founder product decision.** Ref unit: `STRATELOQ-SOCIAL-ADS-EXECUTION-POLICY-LOCK-001`.
This is the canonical policy for how Strateloq publishes organic social content and executes paid advertising.
It is a **policy lock + reconciliation** — it does **not** redesign the architecture; it reconciles the
decision with the existing social, Ad Studio, approval, campaign-execution, Spend Authority, tracking and
learning infrastructure and records what to build next. No post, launch, or spend is authorised by this
document.

---

## 1. Canonical policy (the locked decision)

### A. Organic social publishing — SUPPORTED
Flow: Opportunity/Signal/Content Intelligence → Create Content → platform-specific copy →
generate/select image or video → preview → schedule or publish → **Auto Post when authorized** → collect
performance → feed learning.

Publishing modes (user-selectable): **REVIEW_BEFORE_POST** and **AUTO_POST**.
- AUTO_POST requires **explicit user authorization for the connected social account**.
- **Organic posting authority is separate from paid advertising Spend Authority** (independent permissions).

### B. Paid advertising — two permanent first-class execution modes
1. **REVIEW_AND_MANUAL_LAUNCH** — Strateloq generates a DRAFT/PAUSED campaign; the user may review and edit
   primary copy, headline, description, hook, CTA, image, video, creative variant, audience, geography,
   platform, destination/product page, budget, schedule; actions EDIT / REGENERATE / SAVE DRAFT / APPROVE /
   LAUNCH. **Editing must not silently authorize spend.** The **final version shown to the user is the version
   authorized for launch**.
2. **AUTO_LAUNCH** — optional; requires **explicit bounded Marketing Spend Authority** scoped by tenant,
   platform, ad account, currency, authorized total, max daily / max campaign / max product-test spend,
   allowed markets, allowed actions, start/end validity, spent, remaining, status. **Fail closed outside that
   authority. AI confidence alone NEVER authorizes advertising spend.**

Every paid campaign carries an **explicit execution mode** (REVIEW_AND_MANUAL_LAUNCH or AUTO_LAUNCH).
Never infer AUTO_LAUNCH from organic AUTO_POST. A user who defaults to AUTO_LAUNCH must still be able to select
**REVIEW BEFORE LAUNCH** for an individual campaign. Enabling organic AUTO_POST must never enable paid
AUTO_LAUNCH.

### C. Safety / emergency (must be preserved)
Pause Campaign · Pause Product · Pause Platform · Pause All Advertising. Revoking Spend Authority prevents
further paid activation or spend-increasing actions. Revoking organic posting permission stops future
automatic organic posts without affecting unrelated advertising authority.

### D. Performance learning (both modes feed Performance Intelligence)
- Organic: post → impressions/reach → engagement → clicks (where available) → learning.
- Paid: campaign → impressions → clicks → CTR/CPC → conversion → CPA/CAC → revenue/ROAS/contribution (where
  legitimately configured) → Scale / Improve / Stop.
- **Do not claim unavailable metrics.**

### E. Platform direction (platform-independent architecture)
Organic first: Facebook, Instagram, LinkedIn, TikTok (where connected). Paid first: Meta (FB/IG), then TikTok.
Additional platforms remain extensible.

---

## 2. Reconciliation with the existing implementation (audit)

Legend: ✅ satisfies · 🟡 partial · ❌ missing.

### 2.1 What already SATISFIES the policy
- **Paid campaign DRAFT + review/edit surface** ✅ — `campaign_builder_drafts` (platform, objective, markets,
  audience, placements, creative_selection, offer, destination_url, budget, schedule, currency, media_asset_ids,
  media_gate, canonical_campaign, meta_payload_preview, tiktok_preview, status, provenance) built by
  `fn_cb_build_campaign`; `persist_marketing_campaign_draft`, `get_own_marketing_campaign_drafts`,
  `approve_marketing_campaign_draft`, `reject_marketing_campaign_draft`. Statuses seen: INCOMPLETE,
  READY_FOR_REVIEW (nothing launched).
- **"Final shown = authorized" integrity** ✅ — `cb_fingerprint` / `cb_approved_fingerprint` / `cb_approved_at`
  bind approval to an exact campaign version; `spend_authorization` (numeric) and `activation_authorization`
  (boolean) are **separate** fields, so editing does not silently authorize spend.
- **Marketing Spend Authority model** ✅ — `marketing_spend_authority` carries every policy field: tenant_id,
  platform, ad_account, execution_currency, authorized_total, max_daily, max_campaign, max_product_test,
  allowed_markets, allowed_actions, start_at, end_at, spent, remaining, status, mode, reserved,
  allowed_campaign_types, created_by/approved_by/approved_at, authority_fingerprint, revoked_at,
  hard_ceiling_mechanism, executable, is_synthetic. Lifecycle: `fn_create_spend_authority`,
  `fn_approve_spend_authority`, `fn_revoke_spend_authority`, `fn_reserve_spend`, `fn_release_spend`,
  `fn_spend_authority_fingerprint`, `fn_authority_audit` (+ `marketing_authority_audit`, `spend_reservations`).
- **Fail-closed activation** ✅ — `fn_request_activation(actor, tenant, cb_campaign_id, authority_id,
  idempotency_key)` binds launch to an explicit actor + spend authority + idempotency key. Current authority
  rows are INACTIVE/REVOKED and `mode = MANUAL` only → nothing can auto-spend.
- **Emergency: Pause All / Pause Platform + Revoke** ✅ — `fn_pause_all_advertising(actor, tenant, platform)`
  (platform-scoped or all) and `fn_revoke_spend_authority` (blocks further activation/spend).
- **Paid performance learning** ✅ — `campaign_performance_snapshots` (spend, impressions, reach, clicks,
  link_clicks, LPV, ATC, IC, purchases, revenue, currencies, source_class, purchase_source_verified,
  is_fixture, window), `performance_learnings`, `performance_learning_memory`, `performance_experiments`,
  `fn_postlaunch_metrics_contract`. Honest-metric discipline is enforced (source_class / verified flags /
  is_fixture).
- **Creative supply for both modes** ✅ — Ad Studio (`ad_studio_briefs/angles/platform_variants/
  static_creatives/offers`, `fn_ad_studio_*`, `fn_ad_studio_campaign_handoff`) + real media generation
  (`media_*`, image PASS_REAL per `STRATELOQ-ECOM-CREATIVE-PROVIDER-LIVE-001`) + `fn_media_campaign_safety_gate`.
- **Tracking** ✅ — `meta_platform_config`, `meta_tracking_config`, `conversion_dispatch_ledger`,
  `commerce_tracking_identities`, `meta-capi-adapter` + `meta-insights-reader` edge functions.

### 2.2 What PARTIALLY satisfies
- **Explicit campaign execution mode** 🟡 — behaviour today is effectively REVIEW_AND_MANUAL_LAUNCH (manual
  `fn_request_activation`), but there is **no first-class `execution_mode` column** on any campaign table
  (verified: no `execution_mode`/`launch_mode` column exists). The policy requires every paid campaign to
  carry an explicit mode.
- **AUTO_LAUNCH mode** 🟡 — the authority `mode` column exists but only value `MANUAL` is present; there is no
  auto-activation path that, given AUTO_LAUNCH + a valid authority, performs a bounded automatic launch.
- **Pause granularity (Campaign / Product)** 🟡 — Pause All / Pause Platform exist; per-campaign and
  per-product pause are achievable via execution status but have no dedicated, audited functions.
- **Actual platform launch executor** 🟡 — `marketing_campaign_executions` models the Meta object refs
  (meta_campaign_id/adset/creative/ad, effective_status), but the connected edge functions are CAPI
  (`meta-capi-adapter`) and insights (`meta-insights-reader`); a **Meta Marketing API campaign-create/launch
  executor is not yet wired** (intentional — nothing has launched).

### 2.3 What is MISSING
- **Organic Auto Post components** ❌ — no social-account connection table, no organic post/content table, no
  organic scheduler, no `AUTO_POST` organic authorization, no organic publish function, no organic performance
  ingestion. (Content precursors exist: Ad Studio platform variants + generated media.)
- **Organic Review/Edit (REVIEW_BEFORE_POST)** ❌ — no organic post draft/preview/edit surface.
- **Organic performance learning source** ❌ — learning tables exist but there is no organic-post metrics
  ingestion (impressions/reach/engagement/clicks) feeding them.
- **Organic emergency control** ❌ — no "revoke organic posting permission" / pause-organic path (nothing to
  revoke yet).

### 2.4 Authorization separation
Paid Spend Authority is fully modelled and independent. Organic posting authority does not yet exist, so it
**cannot currently be conflated** with spend — but when organic AUTO_POST is built it MUST be a **separate
permission** (its own authorization record), and enabling it must never set any paid activation/spend flag.
This separation is a hard invariant for the organic build.

### 2.5 External platform / API blockers
- **Paid launch:** Meta Marketing API `ads_management` permission + a Meta ad account with billing (only CAPI
  / Ad Library / insights permissions are confirmed today). Required before any real REVIEW_AND_MANUAL_LAUNCH
  or AUTO_LAUNCH can push a live campaign. TikTok Ads API is a later, separate integration.
- **Organic:** publishing APIs + connected accounts with publish scope — Facebook Pages (`pages_manage_posts`),
  Instagram content publishing, LinkedIn (`w_member_social`/organization), TikTok content posting. The
  `Pulse Meta System User` credential exists but organic publish scopes are unverified. No new account or
  permission is provisioned by this unit.

---

## 3. Readiness

| Capability | Readiness | Basis |
|---|---|---|
| **ORGANIC AUTO POST** | **~15%** | Content generation + creative + platform variants exist; connection, authority, scheduler, publish, and performance ingestion all missing. |
| **PAID REVIEW + MANUAL LAUNCH** | **~75%** | Draft/review/edit/approve, approval fingerprint, spend/activation separation, spend authority, reserve/release, activation request, pause-all/revoke, paid learning all present; missing: explicit `execution_mode`, dedicated per-campaign/product pause, and the live Meta campaign-create executor + `ads_management` permission. |
| **PAID AUTO LAUNCH** | **~45%** | Bounded authority model, fail-closed reserve/activation, audit present; missing: `AUTO_LAUNCH` mode modelling, auto-activation trigger, and the same live Meta executor + permission. |

## 4. Launch-critical gaps
1. Meta Marketing API campaign-create/launch executor + `ads_management` permission (blocks all real paid launch).
2. Explicit `execution_mode` (REVIEW_AND_MANUAL_LAUNCH / AUTO_LAUNCH) on every paid campaign, defaulting to
   REVIEW_AND_MANUAL_LAUNCH; per-campaign override even for AUTO_LAUNCH users.
3. Organic social layer end-to-end (connection + authorization + draft/preview/edit + schedule/publish +
   AUTO_POST authority + performance ingestion), with organic authority strictly separate from Spend Authority.
4. AUTO_LAUNCH auto-activation path (mode=AUTO + valid bounded authority → fail-closed automatic launch).
5. Dedicated Pause Campaign / Pause Product actions and a Revoke-Organic-Posting-Permission control.

## 5. Recommended implementation sequence
1. **Reconcile paid mode (small, safe):** add `execution_mode` to the campaign draft/execution model (default
   REVIEW_AND_MANUAL_LAUNCH); enforce per-campaign override; keep launch fail-closed on Spend Authority.
2. **Wire the Meta Marketing API executor** (create paused campaign → apply approved version → launch on
   explicit activation), gated by Spend Authority reserve/commit + idempotency, once `ads_management` is granted.
3. **Add AUTO_LAUNCH** as an authority mode + auto-activation trigger, bounded and fail-closed; independent of
   any organic setting.
4. **Add dedicated Pause Campaign / Pause Product** and audited emergency actions.
5. **Build the organic social layer** (connection → authorization (separate) → Create Content reuse of Ad
   Studio/media → REVIEW_BEFORE_POST + AUTO_POST → schedule/publish → performance ingestion → learning),
   Facebook/Instagram first, then LinkedIn/TikTok.
6. **Close the learning loop** for organic (post metrics ingestion) alongside the existing paid learning.

## 6. Safety honoured by this unit
Documentation/reconciliation only. No organic post published; no campaign activated; no spend authorized; no
existing Meta campaign status changed; no recurring posting schedule created; Monday intelligence-scan cadence
unchanged; no external services purchased. `campaign_activation=false`, `advertising_spend=0`,
`advertising_spend_authorized=0` remain in force. Nitro × US remains `PENDING_EXTERNAL_CJ_SOURCING`; dash cam
remains `QUALIFIED_TEST_NOT_HIGH_CONFIDENCE` / WPS 79 (not promoted).

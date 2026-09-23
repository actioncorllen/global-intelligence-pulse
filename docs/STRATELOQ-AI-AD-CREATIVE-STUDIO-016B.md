# STRATELOQ-016B — Social Connection Readiness + Organic Publishing Foundation

**FINAL VERDICT: `SOCIAL_CONNECTION_FOUNDATION_PARTIAL`.**
**`DOES_016B_WEAKEN_FOUNDER_STANDARD = NO`.**

Audit + internal foundation + external-connection readiness for connecting Strateloq's **own** real social accounts
(Facebook Page, Instagram business, TikTok, LinkedIn) as an **organic** publishing layer beneath the AI Marketing
Director → Creative Production → human approval chain. This unit is **NOT** authorization to publish. **Zero live
posting, zero cost, no OAuth initiated.** The verdict is **PARTIAL** (not READY) because the internal foundation is
complete but every platform still requires real external developer setup/approval before a first connection can exist.

---

## RETURN

1. **Existing social architecture:** there was **no** organic social-publishing layer. What exists is **advertising +
   research + content-generation** only: Meta advertising (Marketing API draft executor, CAPI adapter, insights reader,
   ad-library research), TikTok **research** (Commercial Content adlib), and content-generation workflows that write
   scripts/captions but never post. No Facebook Page / Instagram / TikTok organic / LinkedIn publishing existed. **New in
   `mig_291`:** a generic organic connection model + publishing contract, execution disabled.
2. **Existing credentials by TYPE only (no values):** Meta **advertising** system-user token (n8n cred store) + Meta CAPI
   token (Supabase secret ref `META_CAPI_ACCESS_TOKEN`); TikTok **research** client key/secret (edge-function secret store,
   token broker `tiktok-commercial-token`); DataForSEO / eBay / CJ / Reddit provider creds (n8n). **No organic social
   publishing credential of any kind exists.** No token/secret value was read, printed, or stored.
3. **Existing n8n publishing workflows:** **none for organic social.** Meta workflows are advertising/tracking/research
   (Draft Executor is PAUSED-only ad objects); TikTok executor is research adlib; LinkedIn has nothing; "Agent 6 Content
   Generator/Worker" produce copy, not posts. No generic Social Publishing Agent exists. **Deliberately did not create
   four new publishing workflows** — there is nothing to authorize yet, so the executors are deferred until OAuth exists.
4. **Existing OAuth infrastructure:** the proven secure-connection shape is `commerce_store_connections`
   (`provider / connection_state / granted_scopes / oauth_state / secret_ref / connected_at`). No social-OAuth callback
   edge function exists; TikTok uses a **client-credentials** research broker (not user-context OAuth); Meta advertising
   uses a **system-user** token. **User-context organic OAuth is not yet built for any platform.**
5. **Internal connection model (`social_platform_connections`):** reuses the `commerce_store_connections` pattern and adds
   the organic/advertising boundary + full token lifecycle: `tenant_id`, `platform`, `connection_type`,
   `external_account_id`, `display_name/metadata`, `authorization_status` (NOT_CONNECTED→PENDING_OAUTH→CONNECTED→
   EXPIRED/REVOKED/ERROR), `granted_scopes`, `capabilities`, **`secret_ref` (never a token)**, `oauth_state` (CSRF nonce
   only), `connected_at / expires_at / last_verified_at / revoked_at`, `error_detail`. RLS deny-by-default; a CHECK
   constraint rejects anything that looks like an actual token value in `secret_ref`.
6. **Organic / advertising separation (mandatory):** `connection_type ∈ {ORGANIC, ADVERTISING}` is a hard boundary — one
   row is never both. Facebook Page publishing ≠ Meta Ad Account; TikTok organic ≠ TikTok Ads Manager; LinkedIn org
   publishing ≠ LinkedIn advertising. Advertising-account connection is explicitly **out of scope** for 016B
   (`fn_social_platform_external_requirements` returns `BLOCKED` for non-organic).
7. **Capability model (`fn_social_connection_capabilities`):** a connection describes capabilities **explicitly** —
   CONNECTED ≠ every operation. Organic: `READ_PROFILE / PUBLISH_TEXT / PUBLISH_IMAGE / PUBLISH_VIDEO / PUBLISH_CAROUSEL`
   (per-platform subset). Advertising (separate, deferred): `READ_AD_ACCOUNT / CREATE_CAMPAIGN / CREATE_AD /
   ACTIVATE_CAMPAIGN`. The two sets are **disjoint** and never cross (proven in selftest).
8. **Publishing contract (`social_publishing_requests` + `fn_social_publishing_request`):** generic request carrying
   `tenant / business / marketing_draft_id / creative_request_id / media_asset_id / platform / destination_account /
   content(caption) / scheduled_at / approval_id / caption_approved / publish_mode`. `execution_enabled` is a column-level
   **CHECK-forced `false`** in this unit; a request only ever records the truthful blocked/ready state.
9. **Manual / automatic authorization model:** `publish_mode ∈ {MANUAL, AUTHORIZED_AUTO}`. `AUTHORIZED_AUTO` requires an
   **explicit** `automation_authorized=true` grant — authorization is **never inferred from account connection**
   (`fn_social_publishing_preflight` gate; proven in selftest).
10. **Meta current state:** app configured for advertising/tracking/ad-library only; **no organic Page/IG publishing
    product or permissions.**
11. **Meta required external setup:** add Facebook Login for Business + request `pages_show_list / pages_read_engagement /
    pages_manage_posts / business_management`; App Review needed for use beyond app admins/testers. → **EXTERNAL_SETUP_REQUIRED**
    (plus EXTERNAL_APPROVAL_REQUIRED for customer Pages).
12. **Facebook Page requirements:** OAuth user token → long-lived → **Page access token**; publish via `POST /{page-id}/feed`,
    `/photos`, `/videos`; Strateloq Page added as an app asset with founder as admin.
13. **Instagram requirements:** IG **professional/business** account linked to the Facebook Page; scopes `instagram_basic +
    instagram_content_publish`; publish via container `POST /{ig-user-id}/media` then `/media_publish`; `instagram_content_publish`
    needs App Review for non-owned accounts.
14. **TikTok current state:** approved **only** for Commercial Content **research** (`research.adlib.basic`) via a
    client-credentials broker — **research, not publishing.**
15. **TikTok required external setup/approval:** separate **Content Posting API** product + **Login Kit user OAuth** with
    `video.publish` + pass the **TikTok app audit** (unaudited apps limited to SELF_ONLY/private draft). token: user
    access_token ~24h + refresh ~365d. → **EXTERNAL_APPROVAL_REQUIRED**.
16. **Confirmation — TikTok research auth is SEPARATE:** the research approval does **not** grant organic publishing; the
    capability model excludes any research token from the organic publish set, and the stage gate flags
    `research_auth_separate=true`. **They are kept strictly separate.**
17. **LinkedIn current state:** **no** developer app or connection exists.
18. **LinkedIn required external setup/approval:** create a developer app, verify/associate the Strateloq **Company Page**
    (founder as Page admin), request `w_organization_social` (+ `openid/profile/w_member_social`) via the **Community
    Management API / Marketing Developer Platform** review; publish via `POST /rest/posts`. → **EXTERNAL_SETUP_REQUIRED**
    (plus EXTERNAL_APPROVAL_REQUIRED for the API access review).
19. **Token-storage architecture:** **no plaintext token in the DB.** The connection row holds only a **non-secret**
    `secret_ref` pointing at the existing secure secret stores (n8n credential store / Supabase edge-function secrets —
    the established pattern). `oauth_state` holds a CSRF nonce only. A CHECK constraint defensively rejects token-shaped
    values in `secret_ref`.
20. **Revocation / expiry behavior:** lifecycle columns `expires_at`, `last_verified_at`, `revoked_at` +
    `authorization_status ∈ {…, EXPIRED, REVOKED}`. The publish preflight requires `authorization_status='CONNECTED'`,
    `revoked_at IS NULL`, and `(expires_at IS NULL OR expires_at > now())` — an expired/revoked connection cannot publish.
21. **Tenant isolation:** both new tables have **RLS enabled + FORCE + 0 policies (deny-by-default)**; access is via
    SECURITY DEFINER functions only (`SET search_path TO ''`). Verified: `rls_enabled=true`, `policy_count=0` on both.
22. **Internal zero-cost integration test:** Marketing Director ORGANIC strategy (`a253e2a6`) → Creative Production request
    (`b8fa46e2`) → real 015T asset (`0ad36286`, IN_REVIEW) → `fn_social_publishing_request` → persisted request
    **`89029599`**. No real post, no OAuth, no external call.
23. **Expected `BLOCKED_PENDING_PLATFORM_CONNECTION` result:** **confirmed.** The persisted request resolved to
    `execution_state='BLOCKED_PENDING_PLATFORM_CONNECTION'`, `execution_enabled=false`, with truthful blocked reasons
    (no connected organic IG connection with PUBLISH_VIDEO; creative not approved / not launch-safe; identity review
    required; no destination; caption not approved). The truthful pre-OAuth state **is** blocked.
24. **Platform-by-platform stage gates:** Meta Facebook **EXTERNAL_SETUP_REQUIRED**; Instagram **EXTERNAL_SETUP_REQUIRED**;
    TikTok **EXTERNAL_APPROVAL_REQUIRED**; LinkedIn **EXTERNAL_SETUP_REQUIRED**. None is `READY_TO_CONNECT`.
25. **Founder actions required (exact):**
    - **Meta:** in the Meta app, add Facebook Login for Business + request `pages_manage_posts` etc.; add the Strateloq
      Facebook Page as an app asset with founder admin. (App Review before any customer Page.)
    - **Instagram:** convert the Strateloq IG account to professional/business and link it to that Facebook Page; add
      `instagram_content_publish`.
    - **TikTok:** apply for the **Content Posting API** product + Login Kit user OAuth (`video.publish`) + pass the app
      audit — do **not** reuse the research client.
    - **LinkedIn:** create a developer app, verify the Strateloq Company Page (founder admin), apply for Community
      Management API access.
    - Provide credentials **only** to the n8n/edge secret store when the time comes — **never in chat.**
26. **External calls:** **none.** No OAuth, no social API call, no live write.
27. **Cost:** **USD 0.00.**
28. **Migrations / workflows / code changed:** `supabase/migrations/mig_291_social_connection_publishing_foundation.sql`
    (2 tables + 4 functions + selftest), this doc. **No n8n workflow created/changed. No Marketing Director / Creative
    Studio redesign. No edge function changed.**
29. **Commit hash:** see delivery message.
30. **Remaining blocker before first real connection:** external developer setup/approval per platform (item 25) **and** a
    user-context OAuth callback (a small edge function) to complete the authorization-code exchange and write the
    connection row with a `secret_ref` — deferred to the connection unit that runs after the founder completes the
    external setup. Until then every publish path correctly returns `BLOCKED_PENDING_PLATFORM_CONNECTION`.
31. **DOES_016B_WEAKEN_FOUNDER_STANDARD:** **NO** — no publishing, no OAuth, no ad-account connection, no cost; identity /
    claim / human-approval gates preserved (the publish preflight additionally requires APPROVED + launch-safe + resolved
    identity + approved caption + explicit automation authorization); no plaintext secrets; RLS deny-by-default; PLG
    agents and TikTok research untouched; Strateloq is **not** hardcoded (it appears only as tenant data in the test).
32. **Final verdict:** **`SOCIAL_CONNECTION_FOUNDATION_PARTIAL`** — internal foundation complete and proven blocked;
    external platform setup/approval still required before a first real connection.

## Target model (locked)

Strateloq Intelligence → AI Marketing Director → **ORGANIC_CONTENT** strategy → Creative Production Agent → Creative
Studio → **human approval** → **Social Publishing Layer** (this foundation, execution disabled) → Facebook / Instagram /
TikTok / LinkedIn. Advertising (`PAID_CAMPAIGN` → separate ad-account connection → campaign execution) stays a **separate**
lineage, deferred. Strateloq's own accounts connect **first** as the controlled proving ground.

---

**STOP.** Do not initiate OAuth automatically. Do not connect social accounts. Do not publish, schedule, delete, or modify
any social profile or advertisement. No paid campaign, no ad-account connection, no Marketing Director / Creative Studio
redesign, no Veo, no Stripe, no Reddit workaround, no Lovable publish. The founder-quality standard remains **LOCKED**.

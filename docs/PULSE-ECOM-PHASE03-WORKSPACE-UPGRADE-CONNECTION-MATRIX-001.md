# PULSE-ECOM-PHASE03-WORKSPACE-UPGRADE-CONNECTION-MATRIX-001

**Task 1 (current-state inventory) + Task 2 (connection matrix) for Phase 03 — Workspace Upgrade.
Everything below is VERIFIED against live sources (Lovable route tree + sidebar nav, Supabase prod
`nxaunmyihhjixxxljcqt` `pg_proc`, deployed edge functions, n8n workflows) or explicitly marked
INFERRED / UNKNOWN(needs roadmap). No code was changed, no credits spent, no production touched.**

## Systems of record
- **Frontend:** Lovable "Pulse Implementation" `12db6c84-161b-4c23-aac4-e19e8cd24ab1` (published; head
  `f0377262`). TanStack file-based routing. Frontend source is NOT in this repo — only Lovable.
- **Backend:** Supabase prod **Strateloq Technologies** `nxaunmyihhjixxxljcqt` (ACTIVE_HEALTHY).
  (`strateloq-billing-staging` `nlfkwrjmhxbubtlwepwx` is the separate Phase-08 billing staging.)
- **Edge functions:** 25 ACTIVE (incl. start-discovery, fastmoss-discovery, fastmoss-product-detail,
  kalodata-discovery, prepare-product, storefront, media-asset-url, translate-text,
  product-image-import, commercial-image-generate, creative-image-execute, meta-* , tiktok-*,
  issue/accept-invitation).
- **n8n:** 88 workflows; active & Phase-03-relevant: Research Auto-Dispatch (013N), Business Discovery
  Worker, Monday Product-Opportunity Orchestrator, Stage-2 CJ Supplier Search, Gemini Text Translator,
  FX Rate Refresher, Trend/Analyzer/Opportunity agents, Product Preparation Worker, creative
  image/identity executors, DR Weekly Encrypted Backup.

## Signed-in navigation TODAY (verified: `app-sidebar.tsx`, ecommerce branch)
Workspace: **Overview** · **Products** (`?view=opportunities`) · **My Store** (`/workspace/store`,
shown only when `hasHostedStore`) · **Competitors** · **Suppliers**.
Account: Explore · **Beta Invitations** (founder-only) · Connected Channels · Settings (Soon) · Support.
Other signed-in routes present: `/workspace/creative` (Ad/Creative Studio), `/workspace/discovery`,
`/workspace/invitations`, `/billing/return`, `/studio`, `/launch`. Public: `/store/$slug`,
`/api/public/storefront/$slug`.

**The important gap:** several Phase-03 surface names in the directive are NOT in the signed-in nav
(My Products, My Campaigns, Notifications), and the backend for most of them already exists — i.e. the
pattern is largely **"built backend, not surfaced in the workspace,"** not "missing."

---

## Connection matrix (Task 2)

Legend — state: **CONNECTED** (frontend uses the live contract) · **PARTIAL** (surfaced but
incomplete) · **BUILT-NOT-CONNECTED** (backend exists, no/limited frontend surface) ·
**MISSING-DEP** (no backend contract) · **BLOCKED** (external provider/permission/cost).

| ID | Surface | Frontend (verified) | Authoritative backend contract(s) (verified present) | State |
|----|---------|---------------------|------------------------------------------------------|-------|
| 03.02 | Golden Standard Intelligence Hub | `/workspace?view=overview` → `OverviewSection` (`workspace-sections.tsx`); `useDiscoveryIntelligence` (`get_own_discovery_intelligence`) + `useEcommerceWorkspace` | `fn_ecommerce_workspace_intelligence`, `get_own_discovery_intelligence` | **CONNECTED** as "Overview"; conformance to the "Golden Standard" spec = **UNKNOWN (needs roadmap)** |
| 03.03 | Product Discovery Explorer | `/workspace?view=opportunities` ("Products"); `product-explorer-contract.ts`, `useProductMedia`, `useProductDiscoveryLanes`, `ProductIntelligenceDrawer` | `fn_product_explorer`, `fn_product_media_state`, `fn_product_discovery_lanes`, `pulse_ecommerce_product_intelligence_v2`, `fn_resolve_supplier_economics`, `fn_product_commercial_readiness_badge`, `fn_fx_convert`, `fn_text_translations` | **CONNECTED & WORKING** (shipped + published; DISCOVERY-WORKSPACE-UPGRADE-001) |
| 03.04 | My Products | **No dedicated nav/route** (not in sidebar) | Store product-set lifecycle: `fn_store_attach_product`, `fn_store_remove_product`, `fn_store_product_set_lifecycle`, `fn_store_set_product_visibility`, `fn_store_replace_active_product` | **BUILT-NOT-CONNECTED** (no "My Products" surface; needs roadmap to define scope) |
| 03.05 | My Store | `/workspace/store` (`workspace_.store.tsx`); nav item conditional on `hasHostedStore` | `fn_store_website`, `fn_hosted_store_get`/`_or_create`, `fn_hosted_store_entitlement`, `fn_store_website_publish_context`, `fn_store_set_display_name`/`_set_website_hero` | **CONNECTED (conditional)** — route+contracts exist; wiring depth not yet re-verified this pass |
| 03.06 | Create Free Store | Action from product card / store flow | `fn_create_free_store`, `fn_create_pulse_store_draft`, `fn_product_card_create_store`, `fn_generate_storefront_runtime`, `fn_storefront_publish`, edge `storefront` | **CONNECTED (action)** — P8 storefront runtime shipped; end-to-end re-verify pending |
| 03.07 | My Campaigns | **No "My Campaigns" nav**; nearest is `/workspace/creative` (Ad/Creative Studio) | `fn_ecommerce_campaign_executions`, `get_own_marketing_campaign_drafts`, `persist/approve/reject_marketing_campaign_draft`, `fn_cb_build_campaign`, `fn_ad_studio_campaign_handoff`, `fn_creative_campaign_handoff`, `fn_media_campaign_safety_gate`; edges `meta-capi-adapter`, `meta-insights-reader` | **BUILT-NOT-CONNECTED** (campaign backend rich; no consolidated "My Campaigns" surface) |
| 03.08 | Opportunity Intelligence recommendations | Generic `?view=opportunities` exists but is **replaced by "Products"** for ecommerce; no dedicated recs surface | `fn_monday_top_opportunities`, `fn_learn_recommend`, `fn_stage1_opportunity_qualified`, `fn_stage1_early_opportunity_state`, `fn_opportunity_score_v2`, `fn_ecommerce_opportunity_band/labels`; n8n Monday Orchestrator | **PARTIAL / BUILT-NOT-CONNECTED** (scoring + top-opportunities exist; no "what to do next" recs surface for ecommerce) |
| 03.09 | Notifications & progress indicators | Progress: `AnalyzingView` pipeline stages + loading states exist. **No notifications UI** | Progress = client-derived from `analysis_status`. **No notifications contract found** (`pg_proc` net for `notif` = 0) | Progress **PARTIAL**; Notifications **MISSING-DEP** (no backend) |
| 03.10 | Desktop/mobile acceptance | Responsive shell: `AppSidebar` (lg+), `MobileNav`, `TopNav`; Tailwind responsive grids | n/a (cross-cutting) | **PENDING** — acceptance QA across 03.02–03.09 after they're connected |

## Preserved invariants (confirmed present in the architecture)
Founding-member-only access (server `fn_workspace_access` gates: auth + email + entitlement + readiness;
`GateNoAccess`/`GatePaidAccess`); tenant isolation + RLS (`auth.uid()` server-owned identity on every
read contract); 18-country research context (`?country=` param, country-isolated reads); evidence
provenance + honest UNKNOWN (ProvenancePanel; empty/unknown never rendered as 0); Product Identity
Resolution (`fn_product_identity_candidate_select`, server-owned identity); exact-SKU gate separate
(`exact_variant_verified=false`); Product Asset Lock (media/lanes REFERENCE_ONLY, display-only, never
feeding commerce/creative/publishing); authorised supplier media (signed-URL `media-asset-url`);
existing storefront architecture (`fn_storefront_*`, edge `storefront`); research cost controls
(suppress_dispatch, broker budget); approved Strateloq design (Design-3 shell).

## What this means for Task 3 (first unfinished requirement)
`03.03 Product Discovery Explorer` is the one Phase-03 surface that is unambiguously CONNECTED & WORKING.
The first genuinely unfinished items, in roadmap order, are **03.02** (confirm the "Golden Standard
Intelligence Hub" spec vs today's "Overview") and then the not-surfaced backends **03.04 My Products**,
**03.07 My Campaigns**, **03.08 recommendations**, and **03.09 Notifications** (the last needs a backend
contract first).

**Blocker to starting Task 3 safely:** the authoritative acceptance criteria for 03.02–03.10 live in
the founder-held "LIVE master launch roadmap" (not in the repo, Lovable knowledge, or project
knowledge — all checked). Building 03.02 without it risks the redesign/rebuild the directive forbids.
Awaiting the 03.02 acceptance criteria (or confirmation that Overview IS the Golden Standard Hub) before
touching Lovable.

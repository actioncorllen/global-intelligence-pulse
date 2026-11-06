# PULSE-ECOM-PHASE03-02-GOLDEN-STANDARD-HUB-001 — 03.02 Golden Standard Intelligence Hub

**Milestone 03.02 (roadmap "POLISHED Build Sequence"): replace the REJECTED generic ecommerce Overview
with the approved feature-first "Golden Standard Intelligence Hub" — six distinctive capability cards
wired to real existing backend contracts, with the stale "featured products as current opportunities"
carousel removed. Reuse only; no redesign of unrelated surfaces, no new backend, no fabricated metrics,
no paid calls, no production publish.**

## What is being replaced (verified)
For ecommerce members, `OverviewSection` (src/components/business-discovery/workspace-sections.tsx)
delegates to `EcommerceWorkspaceSection view="overview"` → **`OverviewBody`** in
`src/components/business-discovery/ecommerce-workspace.tsx`. `OverviewBody` leads with a **"Strongest
product opportunities"** block that renders the top-3 ranked product *decisions* as `DecisionCard`s —
this is the "stale featured products presented as current opportunities" the founder rejected. It is
replaced by the feature-first hub. The generic (non-ecommerce) Overview is unchanged.

## The six capability cards (feature-first), each backed by a REAL existing contract
Grounded in the roadmap's own Phase-03 capabilities. Each card: title, one-line value, an HONEST live
signal (a count/status the server actually returned — never fabricated, `null`/empty shown plainly),
and a CTA that routes to the capability's existing surface. No card performs a commerce/creative/
publishing action; the hub is navigation + display only (Product Asset Lock preserved).

| # | Card | Live signal (hook → contract) | CTA route | Roadmap |
|---|------|-------------------------------|-----------|---------|
| 1 | **Product Discovery** — explore researched products for your market | `useEcommerceWorkspace` → `fn_ecommerce_workspace_intelligence` (`productsTracked`) | `/workspace?view=opportunities` (Products) | 03.03 |
| 2 | **Opportunity Intelligence** — ranked TEST/WATCH/AVOID with country evidence | `useEcommerceWorkspace` (`productDecisionCount` / grouped decisions) | `/workspace?view=opportunities` | 03.08 |
| 3 | **My Products** — products you've selected to pursue | `useProductAcquisitions` → acquisitions count | `/workspace?view=opportunities` (dedicated My Products surface lands in 03.04) | 03.04 |
| 4 | **My Store** — your hosted storefront & product pages | `useHostedStore` (`hasHostedStore`) + `intel.storefronts` count | `/workspace/store` | 03.05 / 03.06 |
| 5 | **My Campaigns** — ads & creative campaigns | `useEcommerceSecondaryIntelligence` → `campaignDrafts` + `campaignExecutions` count | `/workspace/creative` (dedicated My Campaigns lands in 03.07) | 03.07 |
| 6 | **Market & Supplier Intelligence** — competitors, suppliers, pricing, saturation | `useEcommerceSecondaryIntelligence` → `competitors` + `suppliers` counts | `/workspace?view=competitors` / `?view=suppliers` | — |

A compact business/market context strip (business name, industry, selected country) is kept from
`OverviewMarketHeader` / `intel.business`. No "Strongest product opportunities" decision carousel on
the hub.

## Honesty / invariants (must hold)
- **No fabricated metrics.** A card's signal renders only when the server returned it; otherwise show a
  plain "—" / "Not available yet" / "None yet". Counts are real array lengths / server counts.
- **No stale featured products** presented as current opportunities (the rejected pattern).
- **Country isolation**: signals follow the workspace `?country=` context already used by the hooks.
- **Tenant isolation / founding-member access**: unchanged — all reads are server `auth.uid()`-owned;
  the hub adds no new data path.
- **Product Asset Lock**: the hub neither displays supplier media nor triggers commerce/creative/
  publishing; it only counts and routes.
- **Reuse**: no new RPC/edge/workflow; no change to Explorer, PDP, supplier, storefront or publishing.

## Lovable integration prompt (sent to the Pulse Implementation project; preview only, no publish)
> Build Phase 03.02 — the Golden Standard Intelligence Hub — replacing the rejected generic ecommerce
> Overview. In `src/components/business-discovery/ecommerce-workspace.tsx`, add a new `GoldenStandardHub`
> component and render it from `EcommerceWorkspaceSection` when `view === "overview"` INSTEAD of
> `OverviewBody` (leave `OverviewBody` for reference/other callers but it must no longer be the ecommerce
> overview; do not change the non-ecommerce `OverviewSection`). The hub is feature-first: a compact
> business/market context strip (reuse `OverviewMarketHeader` + `intel.business`) then SIX distinctive
> capability cards in a responsive grid (1 col mobile, 2 col sm, 3 col lg). Reuse existing hooks only —
> `useEcommerceWorkspace`, `useEcommerceSecondaryIntelligence`, `useProductAcquisitions`,
> `useHostedStore` — and existing UI (`GlassCard`, `Button`, lucide icons). The six cards, each with a
> title, one-line description, an HONEST live signal and a CTA:
> 1. Product Discovery — "Explore researched products for your market." Signal: `intel.productsTracked`
>    products tracked (omit the number if null). CTA "Explore products" → onNavigate("opportunities").
> 2. Opportunity Intelligence — "Ranked TEST / WATCH / AVOID with country evidence." Signal:
>    `intel.productDecisionCount` (fallback grouped decisions length; omit if none). CTA "View
>    opportunities" → onNavigate("opportunities").
> 3. My Products — "Products you've selected to pursue." Signal: acquisitions count from
>    `useProductAcquisitions` (0 → "None selected yet"). CTA "Manage my products" →
>    onNavigate("opportunities").
> 4. My Store — "Your hosted storefront and product pages." Signal: if `useHostedStore().hasHostedStore`
>    → `intel.storefronts.length` pages, else "No store yet". CTA → Link to `/workspace/store`.
> 5. My Campaigns — "Ads and creative campaigns." Signal: count of campaignDrafts + campaignExecutions
>    from `useEcommerceSecondaryIntelligence` (0 → "None yet"). CTA → Link to `/workspace/creative`.
> 6. Market & Supplier Intelligence — "Competitors, suppliers, pricing and saturation." Signal:
>    competitors + suppliers counts (omit a count if its query isn't "ok"). CTA "View competitors" →
>    onNavigate("competitors") and a secondary "Suppliers" → onNavigate("suppliers").
> RULES: never fabricate a metric — render a signal only when the server returned it, else a plain
> "Not available yet"/"—"/"None yet"; do NOT render the old "Strongest product opportunities" decision
> carousel on the hub; keep all existing loading/error/empty handling from `EcommerceWorkspaceSection`;
> preserve tenant/country isolation and Product Asset Lock (hub only counts + routes, no media, no
> commerce/creative/publish actions); no new RPC/edge/workflow. Keep the Design-3 look (GlassCard,
> existing tokens), fully responsive. Update/add component tests alongside the existing ecommerce
> workspace tests (hub renders six cards; honest empty states; CTAs navigate). Run vitest + typecheck +
> lint and report results. DO NOT publish to production — preview only.

## Verification plan (Task 5 for 03.02)
Confirm in the Lovable preview build: six cards render; counts match the server payload (or honest
empty); each CTA routes to the correct existing surface; the stale "Strongest product opportunities"
carousel is gone from the hub; non-ecommerce Overview unchanged; tests + typecheck + lint pass. Mark
03.02 PASS only when the hub uses real contracts with correct auth/tenant/country and no fabricated
metrics. Production publish is deferred to a separate founder approval (rule 9).

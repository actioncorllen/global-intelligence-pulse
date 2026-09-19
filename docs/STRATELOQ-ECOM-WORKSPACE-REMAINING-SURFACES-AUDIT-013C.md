# STRATELOQ-ECOM-WORKSPACE-REMAINING-SURFACES-AUDIT-013C

**VERDICT: `READY_FOR_REMAINING_CONNECTION_FIX`.** Read-only audit. No migration, no DB write, no Lovable
change, no synthetic data, no discovery run, no entitlement/payment change; tenant isolation preserved.

After 013A+013B, **Overview** and **Opportunities** are correctly connected to the authoritative Ecommerce
contract (`fn_ecommerce_workspace_intelligence`). The remaining sidebar surfaces — **Signals, Audience,
Content, Analytics** — still read the **generic** `get_own_discovery_intelligence` lineage
(`member_opportunities` / `member_business_dna` / `daily_briefs`), all of which are **empty for the
founder**, producing misleading "nothing produced" states. Separately, the platform contains substantial
**already-built ad-creative, media, competitor, supplier and campaign runtime with real founder data**,
but none of it has a browser-safe authenticated read contract, so it cannot yet be surfaced.

---

## Surface-by-surface audit

| # | Surface | Frontend component | Hook/RPC | Backend source | Founder data | Browser output | Class |
|---|---|---|---|---|---|---|---|
|1|**Overview**|`EcommerceWorkspaceSection view="overview"`|`useEcommerceWorkspace` → `fn_ecommerce_workspace_intelligence`|`product_opportunity_decisions`+`commerce_products`+`commerce_signals`+`commerce_product_pages`|7 decisions, 11 signals, 1 storefront|Correct|**CONNECTED_ECOMMERCE**|
|2|**Signals**|`SignalsSection`|`useDiscoveryIntelligence` → `get_own_discovery_intelligence`|`daily_briefs` (morningBrief) + `member_opportunities.evidence`|0 / 0|Empty; reads generic, **not** `commerce_signals`|**GENERIC_AND_WRONG_FOR_ECOMMERCE**|
|3|**Opportunities**|`EcommerceWorkspaceSection view="decisions"`|`fn_ecommerce_workspace_intelligence`|`product_opportunity_decisions`|7 decisions|Correct|**CONNECTED_ECOMMERCE**|
|4|**Audience**|`AudienceSection`|`get_own_discovery_intelligence`|`member_business_dna` (DNA + ICP) + `business_profiles`|0 DNA rows|Empty/generic; no ecommerce audience data exists|**MISSING_ECOMMERCE_CONNECTION** (ecommerce audience **NOT_BUILT_YET**)|
|5|**Content**|`ContentSection`|`get_own_discovery_intelligence`|`member_opportunities.content_reco`|0|"No content recommendations were produced for this analysis."|**GENERIC_AND_WRONG_FOR_ECOMMERCE**|
|6|**Analytics**|nav item, `soon`|— none —|—|—|Disabled placeholder|**NOT_BUILT_YET**|

## 1. Overview status — CONNECTED_ECOMMERCE
Authoritative, correct (013B). Business/market context, strongest decisions, evidence summary
(from `commerce_signals`), next steps, storefront status — all real.

## 2. Signals status — GENERIC_AND_WRONG_FOR_ECOMMERCE
`SignalsSection` reads `data.morningBrief` (`daily_briefs`, founder = 0) and `data.opportunities[].evidence`
(`member_opportunities`, founder = 0). It does **not** read `commerce_signals`. The founder's 11
`commerce_signals` (all `COMMUNITY_ATTENTION`) are **already surfaced** in the Ecommerce Overview's
`evidence_summary`. So a separate generic Signals tab is empty and redundant for ecommerce. Evidence for
the decision (not made here): the ecommerce signal evidence already has a home in Overview; a dedicated
Signals tab would need either to read `commerce_signals` directly or be hidden for ecommerce V1. **Do not
copy `commerce_signals` into generic tables for presentation.**

## 3. Opportunities status — CONNECTED_ECOMMERCE
Correct (013B). Real product decisions with browser-safe fields.

## 4. Audience status — MISSING_ECOMMERCE_CONNECTION / NOT_BUILT_YET
`AudienceSection` reads `businessDna` + `icp` (`member_business_dna`, founder = 0) — the generic
website-discovery Business-DNA/ICP. **No ecommerce-specific audience/buyer/persona capability exists** in
the backend (no persona/ICP tables for the commerce lineage; the only ICP source is `member_business_dna`,
which the ecommerce no-store journey never populates). Evidence: ecommerce audience intelligence is
**NOT_BUILT_YET**. Options (evidence only, decision deferred): hide for ecommerce V1, or build ecommerce
buyer intelligence later. Do **not** invent buyer personas.

## 5. Content status — GENERIC_AND_WRONG_FOR_ECOMMERCE
See item 13 for the exact reason. The generic Content surface is empty and misleading for ecommerce; the
real ecommerce content/creative capability lives in the ad-studio/media runtime (items 10–11), which is
not read here.

## 6. Analytics status — NOT_BUILT_YET
Nav item is a disabled "Soon" placeholder. `campaign_performance_snapshots` exists as a table and the
founder has 1 `marketing_campaign_executions` row, but there is **no per-tenant analytics read contract**
and no wired surface. Correctly unbuilt.

## 7. Competitor intelligence status — IMPLEMENTED (data) / MISSING read contract
`product_market_competitors` is a rich, real table (competitor identity, price, ad presence, creative/
offer/CTA pattern, match confidence, `is_fixture`, provenance), keyed by `tenant_id`+`product_id`. **The
founder has 74 rows** (108 globally). It feeds the WPS decision internally, but there is **no `get_own_*`
authenticated read contract** exposing it to the browser. 013B correctly omitted Competitors. Gap: a
browser-safe per-decision competitor read contract + a workspace surface.

## 8. Supplier intelligence status — IMPLEMENTED (runtime) / MISSING read contract
Extensive supplier runtime exists (`fn_evaluate_supplier`, `fn_rank_suppliers`, `fn_supplier_gate`,
`fn_supplier_economics`, `fn_supplier_delivery_state`/`_stock_state`/`_reliability_state`,
`select_product_supplier`, `commerce_supplier_products` catalog, `supplier_product_assets`). It informs the
product decision's economics/lineage. There is **no browser-safe per-tenant/per-decision supplier read
contract**; `commerce_supplier_products` is a shared catalog (no tenant key). Gap: a projection contract if
suppliers are to be surfaced. No mocks.

## 9. Action Intelligence status — PARTIAL
The Ecommerce contract exposes each decision's `action_gating` (e.g. `MONITOR_GATHER_EVIDENCE`) and
`decision_reasons` (surfaced in Overview/Decisions as "Next action" / reasoning). The generic
`member_actions` (quick-wins/next-stage/next-best-move) is **0 for the founder** and not ecommerce.
Executable actions today: **only Build Product Page** (item 12). Everything else is descriptive text.

## 10. Create Content status — CONTRACT_ONLY (generic) + IMPLEMENTED-but-unlinked (ad studio)
- Generic: `start_content_generation` / `persist_generated_content` / `get_own_generated_content` runtime
  exists, but `generated_content` is **0 globally** — never produced output. Effectively CONTRACT_ONLY.
- Ecommerce ad-creative: the **ad-studio** pipeline is IMPLEMENTED (`fn_ad_studio_build_brief`,
  `_generate_angles`, `_platform_variants`, `_add_offer`, `_approve_angle`, `_edit_angle`,
  `_campaign_handoff`, `_claim_scan`). The founder has **1 brief, 3 angles, 1 static creative** — but the
  brief's `decision_id` is **NULL** (not linked to any of the 7 real decisions), and there is **no
  `get_own_*` read contract**. So: PARTIALLY_IMPLEMENTED for a workspace connection (real runtime + data,
  but weak decision linkage and no browser read path).

## 11. Ads / creative / media intelligence status — IMPLEMENTED (runtime + founder data) / MISSING read contract
Media pipeline IMPLEMENTED (`fn_media_create_image_job`/`_create_video_job`/`_build_storyboard`/
`_approve_asset`/`_campaign_safety_gate`/`_generation_result`; `media_assets`, `media_video_jobs`,
`media_image_jobs`). Founder has **1 media asset, 1 video job**. Campaigns IMPLEMENTED
(`fn_cb_build_campaign`, `marketing_campaign_drafts`/`_executions`, `campaign_performance_snapshots`) with
a **read contract that already exists** — `get_own_marketing_campaign_drafts` (authenticated) — and the
founder has **2 drafts + 1 execution**. Meta ad-library ingestion IMPLEMENTED (`fn_ingest_meta_ads`,
`fn_meta_ad_*`). Gap: no browser read contract for ad-studio/media; the campaign-drafts contract exists but
is not surfaced in the ecommerce workspace.

## 12. Product Page Builder status — CONNECTED
IMPLEMENTED and connected (013B): Product Decision → Build Product Page (gated on an existing APPROVED
acquisition) → existing `ProductPageBuilder` → publish, via server `page_id`. The only executable action
wired today.

## 13. Exact reason Content is empty
`ContentSection` renders `data.opportunities.filter(o => o.contentReco !== null)`, where `data` is the
generic `get_own_discovery_intelligence` payload and `contentReco` comes from
`member_opportunities.content_reco`. The founder has **0 `member_opportunities`** (the ecommerce
no-store journey never populates the generic lineage), so the filtered list is empty and the component
prints the literal fallback **"No content recommendations were produced for this analysis."** It is the
same generic-vs-ecommerce lineage split that 013 identified for Opportunities — Content was simply not part
of the 013B connection, and its real ecommerce counterpart (ad-studio/media) has no read contract.

## 14. Existing reusable backend contracts
- `fn_ecommerce_workspace_intelligence()` — decisions + evidence + storefronts (013A). **Reused.**
- `get_own_marketing_campaign_drafts()` — authenticated; founder has 2 drafts. **Reusable now.**
- `get_own_generated_content()` — authenticated; empty (no output ever). Reusable but nothing to show.
- `fn_own_product_country_explorer` / `fn_own_market_comparison` / `fn_own_country_evaluation_state` —
  Market Explorer per-product/country intelligence (authenticated). Reusable.
- `get_own_product_acquisitions()` — powers the builder. **Reused.**
- `fn_workspace_access()` — access gate. **Reused.**

## 15. Missing connections (data exists, no browser-safe read contract / not surfaced)
1. **Content/Ads** — ad-studio (brief/angles/creatives) + media (asset/video) exist for the founder but
   have no `get_own_*` read contract, and the ad-studio brief is not decision-linked.
2. **Competitors** — `product_market_competitors` (74 founder rows) has no `get_own_*` read contract.
3. **Suppliers** — supplier evaluation feeds decisions but has no browser-safe per-decision read contract.
4. **Campaigns** — `get_own_marketing_campaign_drafts` exists (2 founder drafts) but is not surfaced.
5. **Signals** — `commerce_signals` is exposed only as Overview `evidence_summary`; the Signals tab reads
   the empty generic lineage.

## 16. Truly unbuilt capabilities (NOT_BUILT_YET)
- **Ecommerce Audience/buyer intelligence** — no persona/ICP capability for the commerce lineage.
- **Analytics** — no per-tenant analytics read contract/surface (placeholder only).
- **Decision-linked ad creative** — the ad-studio brief carries no `decision_id`, so a Product-Decision →
  Ad-Creative linkage for the workspace is not yet established.

## 17. Ecommerce workspace capability map (truthful, today)
```
Overview                → CONNECTED (real intelligence)
Products / Opportunities→ CONNECTED (7 real decisions)
Product Page Builder    → CONNECTED (executable: Build → Publish)
Signals                 → data exists (commerce_signals) but only surfaced in Overview;
                          standalone tab reads empty generic lineage
Competitors             → DATA IMPLEMENTED (74 rows), no read contract → not surfaceable yet
Suppliers               → RUNTIME IMPLEMENTED (feeds decisions), no browser read contract
Content / Ads           → RUNTIME IMPLEMENTED + founder data (ad-studio/media), no read contract,
                          weak decision linkage; generic Content tab is empty & misleading
Campaigns               → read contract EXISTS (get_own_marketing_campaign_drafts, 2 drafts), unsurfaced
Audience                → NOT_BUILT_YET for ecommerce (generic DNA/ICP only, empty)
Analytics               → NOT_BUILT_YET
```

## 18. Minimum launch-critical connection work
1. **Stop the misleading generic empty states for ecommerce (Lovable-only, no backend).** Make
   Signals / Audience / Content category-aware: for ecommerce, hide them (or fold Signals evidence into
   Overview, which already shows it) rather than showing "No … were produced for this analysis." This is
   the launch-critical fix — the founder currently sees false "nothing produced" messages on real data.
2. Optionally relabel/point Content for ecommerce at the next real action (Build Product Page / future
   ad-creative), instead of the empty generic contentReco list.

## 19. What should be deferred
- Surfacing Competitors, Suppliers, Ads/creative, Campaigns, and Analytics — each needs a new browser-safe
  `get_own_*` read contract (Claude Code) plus UI (Lovable), and for ads a Product-Decision → creative
  linkage. Real data exists but this is a follow-on connection unit, not launch-critical for the founder
  E2E. Ecommerce Audience intelligence is a genuine build, deferred.

## 20. Next implementation: Claude Code, Lovable, or both
- **Launch-critical (item 18): Lovable only** — category-aware hiding/relabelling of Signals/Audience/
  Content for ecommerce; no backend change.
- **Deferred (item 19): both** — Claude Code adds browser-safe `get_own_*` read contracts (competitors,
  ads/media, suppliers, campaigns, analytics) + decision→creative linkage; Lovable renders them.

## 21. FINAL VERDICT
**`READY_FOR_REMAINING_CONNECTION_FIX`.** Overview and Opportunities are correctly connected. The
remaining surfaces are the same generic-vs-ecommerce lineage split: Signals/Audience/Content read the empty
generic lineage and show misleading "nothing produced" states, while real Ecommerce ad-creative, media,
competitor, supplier and campaign intelligence exist (with founder data) but lack browser-safe read
contracts. The minimum launch-critical fix is a **Lovable-only category-aware nav change** to stop the
misleading empty states; surfacing the additional real intelligence is a deferred Claude-Code + Lovable
connection unit. No capability is blocked; nothing was changed.

STOP. Audit only — not implemented.

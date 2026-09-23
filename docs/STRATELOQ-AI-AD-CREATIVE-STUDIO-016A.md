# STRATELOQ-016A — AI Marketing Director → Creative Production Integration

**FINAL VERDICT: `MARKETING_DIRECTOR_CREATIVE_PRODUCTION_CONNECTED`.**
**`DOES_016A_WEAKEN_FOUNDER_STANDARD = NO`.**

Connected the **existing** AI Marketing Director (n8n workflow `YDhtr1EPQRUv5wdm`) as the **orchestration brain**
above the now-production-ready Creative Production Agent (015U / `mig_289`). The Marketing Director produces
**structured strategy** and hands off to the Creative Production contract; it does **not** render creatives. No second
brain was created, no third campaign lineage was introduced, no social account was connected, and the n8n workflow was
left **inactive**. One **real founder-tenant, USD $0** integration test was run end-to-end. `publish=false`,
`activation=false`, `spend_authorized=false` throughout.

---

## RETURN

1. **Existing Marketing Director audited (not replaced):** deployed n8n workflow **`YDhtr1EPQRUv5wdm`** ("AI Marketing
   Director / CMO"), **inactive**, 15 nodes. It is a Claude-backed CMO-report generator: Monday-schedule + form
   triggers → pulls tenant intelligence → Claude strategy synthesis → writes a strategy report into
   **`marketing_campaign_drafts`**. This is the single orchestration brain; it was **upgraded, not bypassed**.
2. **No new brain / no third lineage:** confirmed the two existing draft lineages are sufficient — no new Marketing
   Director, no new campaign entity, no parallel orchestrator was built.
3. **Reconciliation of the two draft tables (explicitly modelled):**
   - **`marketing_campaign_drafts` = STRATEGY** (Marketing Director output: objective, audience, positioning, channel
     mix, messaging, creative direction). This is the *brain's* artifact.
   - **`campaign_builder_drafts` = EXECUTION CONFIG** (Campaign Builder: concrete budgets, targeting, placements,
     schedule — 4 rows already present). This is the *hands'* artifact.
   - The bridge links strategy → creative request → (future) execution config without collapsing the two.
4. **Consumes real intelligence (nothing fabricated):** the integration test drove off the **real** nightlight decision
   `ab8607cd` (WATCH / TRENDING_WATCH, saturation VERY_HIGH, recommended action MONITOR_GATHER_EVIDENCE). The strategy
   produced was **intelligence-consistent**: because saturation is VERY_HIGH and the action is evidence-gathering, the
   Director selected **`ORGANIC_CONTENT`**, not a paid push — the strategy follows the signal rather than inventing a
   campaign.
5. **Marketing Director → Creative Production bridge (`mig_290`):** three new SECURITY DEFINER functions plus a
   selftest, and two columns added to `creative_production_requests`:
   - `ALTER TABLE creative_production_requests ADD marketing_draft_id uuid` (lineage back to the strategy draft) and
     `ADD execution_mode text` (`ORGANIC_CONTENT | PAID_CAMPAIGN`).
   - **`fn_marketing_director_strategy(...)`** — validates enums (source_mode, execution_mode, platform, creative_type),
     builds a `MARKETING_DIRECTOR_STRATEGY_V1` object (structured objective / audience / positioning / channel /
     messaging / creative_direction), stamps `authorization = {publish:false, activation:false, spend_authorized:false}`
     and `renders_creative:false`, and (optionally) persists it into `marketing_campaign_drafts`
     (`lifecycle = {"stage":"MD_STRATEGY"}`, `status='DRAFT'`).
   - **`fn_marketing_strategy_to_request(...)`** — translates a strategy object into a Creative Production request via
     the generic `fn_creative_production_request` (015U `mig_289`), then stamps `marketing_draft_id` + `execution_mode`
     on the resulting row. **The Director hands off; it does not render.**
   - **`fn_marketing_director_to_creative_request(p_draft_id, ...)`** — loads a persisted strategy draft and produces the
     Creative Production request from it (the live orchestration path).
   - **`fn_marketing_director_integration_selftest()`** — **5/5**.
6. **Director produces strategy, not creatives:** every strategy object carries `renders_creative:false`; rendering only
   ever happens downstream through the Creative Production Agent + native compositor. No generation lives in the brain.
7. **Connected to the generic 015U contract (`mig_289`), not a fork:** the bridge calls
   `fn_creative_production_request` / `fn_creative_production_plan` unchanged. No creative feature was added or altered.
8. **Both source modes supported:** the bridge validates and carries `CUSTOMER_PRODUCT` and `STRATELOQ_BRAND` through to
   the creative request (test exercised `CUSTOMER_PRODUCT`).
9. **Organic vs paid modelled separately:** `execution_mode` distinguishes **`ORGANIC_CONTENT`** (no ad spend, content
   calendar / posting path) from **`PAID_CAMPAIGN`** (ad spend, campaign execution path). The two are not conflated, and
   selection is intelligence-driven (see #4).
10. **Real founder-tenant integration test (USD $0):** end-to-end, all green —
    - **Strategy draft `a253e2a6`** persisted into `marketing_campaign_drafts` (`execution_mode=ORGANIC_CONTENT`,
      authorization all `false`, `renders_creative:false`, `lifecycle.stage=MD_STRATEGY`).
    - **Creative Production request `b8fa46e2-1a78-4879-8112-e894f1180b9a`** created and linked:
      `source_mode=CUSTOMER_PRODUCT`, product `e453eed4`, decision `ab8607cd`, market `GB`, `creative_type=VIDEO`,
      `platform=TIKTOK`, **`marketing_draft_id=a253e2a6`** (lineage confirmed in a fresh statement),
      `execution_mode=ORGANIC_CONTENT`, `generation_authorized=false`, `human_approval_required=true`, `status=REQUESTED`.
    - **Dry-run plan `PLAN_READY`**: cost tracking all `0`, `publish/activation=false`, human approval required, and
      per-scene identity correct (`AUTHORITATIVE_PRODUCT_CARD_PIXELS` for product scenes,
      `NO_DEVICE_IDENTITY_NA` / `IDENTITY_REVIEW_REQUIRED` where applicable).
    - **Campaign handoff** on the real 015T asset `0ad36286` → `publish=false`, `activation=false`,
      `handoff_ready=false` (correct — asset is `IN_REVIEW`).
    - `fn_marketing_director_integration_selftest` **5/5**; **all 6** creative regression suites green.
    - **No Veo, no TTS, no paid API, no generation. Total external cost USD $0.00.**
11. **Authorization posture locked for 016A:** `publish=false`, `activation=false`, `spend_authorized=false` on every
    produced object (strategy, request, plan, handoff). Nothing in this unit can launch or spend.
12. **PLG Growth Agents untouched:** the Behavioral / Conversion / Customer-Success / Churn agents were **not** reused,
    repurposed, or wired into this path. This is the ad/marketing lineage only.
13. **Ad-Performance Specialist NOT built (lineage preserved):** no performance-optimization agent was created, per the
    unit. The feedback-loop attachment point already exists — **`campaign_performance_snapshots`** is present in the DB —
    so a future Ad-Performance Specialist can attach without rework. Lineage exists; the agent is deferred.
14. **n8n workflow remains inactive:** `YDhtr1EPQRUv5wdm` was **not** activated. No trigger was enabled, no schedule was
    turned on. The bridge is exercised at the DB/contract layer; activation is a later, explicit unit.
15. **No social accounts connected:** no Meta / Instagram / TikTok / LinkedIn / Reddit account was linked; Reddit remains
    `BLOCKED_EXTERNAL_APPROVAL`. No posting, no campaign launch, no Stripe, no Lovable publish.
16. **Identity / claim / quality contracts unchanged and enforced through the bridge:** the strategy path routes into the
    same 015U identity policy (`AUTHORITATIVE_PRODUCT_CARD_PIXELS`, generative-device = `IDENTITY_REVIEW_REQUIRED`),
    claim-safety, and human-approval gates. The brain cannot weaken them.
17. **Tenant isolation:** all new functions are SECURITY DEFINER with `SET search_path TO ''`; `marketing_campaign_drafts`
    and `creative_production_requests` remain RLS-scoped / deny-by-default.
18. **No secrets in repo:** no tokens, keys, or signed-URL bearer tokens were committed. The n8n Claude/Supabase
    credentials stay in n8n; nothing credential-bearing is in the migration.
19. **Migrations / files changed:** `supabase/migrations/mig_290_marketing_director_creative_bridge.sql` (new), this doc.
    No compositor code changed, no storyboard changed, no creative feature added, no n8n workflow definition changed.
20. **Regressions:** `fn_marketing_director_integration_selftest` 5/5; `creative_production_contract` 6/6,
    `media_native_composition` 5/5, video runtime 15/15, and the product-card identity / asset-selector / static-creative
    suites all green.
21. **External calls:** **none.** **Total cost: USD 0.00.**
22. **Commit hash:** see delivery message.
23. **DOES_016A_WEAKEN_FOUNDER_STANDARD:** **NO** — no new generation, no cost, no launch/spend, identity & claim & human
    review gates preserved and now reachable *only* through the same production contract; the single Marketing Director
    was upgraded (not duplicated), PLG agents untouched, n8n inactive, no social connected.
24. **Final verdict:** **`MARKETING_DIRECTOR_CREATIVE_PRODUCTION_CONNECTED`.**

## Orchestration model (locked)

Strateloq Intelligence (decisions) → **AI Marketing Director** (`YDhtr1EPQRUv5wdm`, the brain: strategy into
`marketing_campaign_drafts`, `renders_creative:false`) → **bridge** (`mig_290`: strategy → Creative Production request,
`execution_mode` ORGANIC/PAID, `marketing_draft_id` lineage) → **Creative Production Agent** (015U `mig_289`: storyboard,
authoritative assets, cost-gated bounded generation) → **Strateloq Native Compositor** (015S) → claim / identity /
quality review → **human approval** → **Campaign Builder** (`campaign_builder_drafts` = execution config) →
[future] channel execution + **Ad-Performance Specialist** (`campaign_performance_snapshots` loop) —
**publish / activation / spend all `false` until an explicit launch unit.**

---

**STOP.** Do not activate the n8n Marketing Director, do not connect social accounts, do not build the Ad-Performance
Specialist, do not repurpose the PLG Growth Agents, and do not publish / launch / spend. The founder-quality standard
remains **LOCKED**; product identity remains `IDENTITY_REVIEW_REQUIRED` for any generative device footage.

# STRATELOQ-GROWTH-AGENT-AUDIT-015E.1 — Existing Growth Agent + Marketing Director Integration Audit

**FINAL VERDICT: `GROWTH_AGENT_NOT_CONNECTED`.**

A Growth Agent **exists** and is well-formed — but it is a **product-led-growth (PLG) user-lifecycle
suite** (engagement / activation / conversion / churn on *users of Strateloq*), **not** the ad-campaign
Performance + Growth specialist the target role describes (CTR / CPA / ROAS / creative fatigue). It is
**inactive**, carries **no real data**, and is **NOT_CONNECTED** to `campaign_performance_snapshots`, the
internal Ad Creative Studio, campaign execution, or Meta/TikTok/LinkedIn ad performance. The AI Marketing
Director also exists (inactive strategy agent) and runs **parallel and disconnected** from the Growth
Agents. No implementation, activation, connection, spend, posting, Lovable, publish, Stripe, paid call, or
secret exposure occurred. Product Decision scoring and Problem Intelligence untouched. Reddit remains
`BLOCKED_EXTERNAL_APPROVAL`.

---

## 1. Growth Agent — found / not found
**FOUND** (8 n8n workflows + 3 DB tables), but as a **PLG lifecycle system**, not an ad-performance agent.

## 2. Exact location(s)
n8n instance `tradingb.app.n8n.cloud` (all **inactive**, triggerCount 0):

| ID | Name | Cadence (if activated) | Role |
|---|---|---|---|
| `3Yj5HSiXyYhqpwaq` | Pulse Growth — Agent A: Behavioral Intelligence | every 6h, **zero LLM** | reads `user_events` → engagement score + activation status → `user_growth_profile` |
| `rnciSjlba8Mr2rt1` | Pulse Growth — Agent B: Conversion Intelligence | every 12h | free/trial upgrade-propensity → templated nudges or Gemini email |
| `WdD6nhQmt5vvqSmm` | Pulse Growth — Agent C: Customer Success | every 4h | onboarding/discovery/stalled-activation nudges, 14-day rate limit |
| `KZLVN1lfJ7iTsT9N` | Pulse Growth — Agent D: Churn Prevention | daily | churn-risk scoring + warm re-engagement email; critical → founder alert |
| `kSY75oQLXJuKdJps` | Pulse Growth — Event Collector | webhook | privacy-gated event ingestion → `user_events` |
| `9QUT5BpsUC0NNOM2` | Pulse Growth — Shared: Send Message | sub-workflow | consent-gated send (email/in_app) → logs `growth_messages` |
| `0cqJjsnJJhjTl3BI` | Pulse Growth — Synthetic Events: Brief Not Opened | daily | writes `brief_not_opened` to `user_events` |

DB tables (public): `user_events` (**0 rows**), `user_growth_profile` (**1 row**), `growth_messages` (**0 rows**).

## 3. Current maturity
**CONTRACT_ONLY / DISCONNECTED.** Workflows + tables are built and coherent, but **all inactive**
(`active:false`, `triggerCount:0`) and effectively **empty** (no events, no messages). Nothing has run in
production. It is *not* the ad-performance specialist.

## 4. Current trigger
Schedule triggers (A 6h / B 12h / C 4h / D daily / synthetic daily) + one webhook (Event Collector).
**None currently armed** (inactive).

## 5. Current inputs
`user_events` (behavioral events), user profile/activation state, consent + rate-limit state. **No**
campaign/ad/creative/performance inputs.

## 6. Current outputs
`user_growth_profile` (engagement score, activation stage: new/profile_set/first_brief/first_action/
activated/power_user, churn/conversion tiers), `growth_messages` (consent-gated lifecycle nudges/emails),
founder alerts (critical churn). **No** creative/campaign/performance outputs.

## 7. Tools / providers used (types/names only)
Supabase (DB), Google Gemini (personalized conversion/churn emails), Anthropic (some copy), email/in_app
channels. No ad-platform nodes. No secrets exposed.

## 8. DB reads / writes
- **Reads:** `user_events`, `user_growth_profile`, consent/rate-limit state.
- **Writes:** `user_growth_profile` (Agent A), `user_events` (Event Collector + synthetic), `growth_messages` (Send Message).
- **Never touches:** `campaign_performance_snapshots`, `campaign_builder_drafts`, `ad_studio_*`, `media_*`, `marketing_campaign_*`.

## 9. Current Strateloq connection map
```
frontend/product events ─▶ Event Collector ─▶ user_events
user_events ─▶ Agent A ─▶ user_growth_profile
user_growth_profile ─▶ Agents B/C/D ─▶ Send Message ─▶ growth_messages ─▶ (email/in_app to USER)
```
This is a **self-contained PLG lifecycle loop about Strateloq's own users.** It does **not** read Product/
Opportunity/Decision/Creative/Campaign/Performance intelligence, and does not feed them.

## 10. Whether anything currently calls it
**NO.** All workflows inactive; Event Collector webhook exists but the suite is not armed; `user_events`
is empty. Nothing in the ad/campaign pipeline references it.

## 11. Marketing Director — location + maturity
**FOUND, inactive.** `YDhtr1EPQRUv5wdm` — "AI Marketing Director v1", 15 nodes, `active:false`,
triggerCount 0. Triggers: **Monday 08:00 schedule** + **New Business Form**. Flow: Normalize →
**Load Pulse Intelligence** (RPC `get_member_marketing_context`) → Fetch website (4k excerpt) →
**Claude Sonnet 4.6 agent** (elite CMO) → CMO report JSON (business_intelligence, market_strategy,
execution_assets, campaign_blueprint, decision_engine, marketing_priorities, execution_ready,
success_metrics, memory_updates) → Gmail draft **and** Build Execution Bundle → Assemble Draft →
**persist `marketing_campaign_drafts`** (RPC `persist_marketing_campaign_draft`). Maturity: **PARTIAL /
CONTRACT_ONLY** — a strategy/planning agent that emits PAUSED, `publish:false` platform payloads
(meta/google/tiktok, each `requires: api_connection + human_review`), `creative_specs`
(`requires_generation:true`, `generated:false`), `brand_assets` (`asset_library_status: NOT_CONNECTED`),
and a **`performance_schema` placeholder** (`connected:false`; metric rows for impressions/clicks/ctr/cpc/
spend/conversions/cpa/roas all `NOT_CONNECTED`). Providers: Anthropic, Gmail, Supabase.

## 12. Marketing Director ↔ Growth Agent relationship
**PARALLEL / DISCONNECTED.** Neither calls the other. Different domains: MD = campaign *strategy/planning*
for a business; Growth Agents = *product-led user lifecycle* for Strateloq's own users. The MD's
`performance_schema` is a placeholder that **no Growth Agent fills**; the Growth Agents never read the MD's
drafts. `memory_updates: []` in the MD is explicitly "reserved for future adaptive learning" — an unused
seam where a performance→learning loop would attach.

## 13. Campaign execution connections
`marketing_campaign_drafts` (2 rows) + `marketing_campaign_executions` (1 row) + Meta Draft Executor
(`DxVfPg5fickAB1sr`, **PAUSED-only**, launch-critical/paid, inactive) + edge fns `meta-capi-adapter`,
`meta-insights-reader`, `tiktok-commercial-token`. A **newer** lineage (`campaign_builder_drafts` +
`fn_cb_build_campaign`, from the Ad Studio) exists in parallel — see §19. Neither Growth Agent participates.

## 14. Performance-data connections
**MISSING/PLACEHOLDER.** `campaign_performance_snapshots` (16 rows; **15 fixtures, 1 real**) is the ad-
performance schema (spend/impressions/clicks/purchases/revenue/currencies/windows) — but **no function or
workflow ingests into it or reads it for optimization** (searched: no `roas`/perf-ingest/growth-optimize
function exists). The MD carries its own `performance_schema` placeholder (`connected:false`). `meta-
insights-reader` (`0e976435…`) + "Meta Ads Insights Recovery" (`LJePIvYVTnW8WDPv`, manual, read-only) can
*read* Meta insights but are not wired to persist snapshots or feed any agent.

## 15. Social-media connections
Organic social: **NONE connected** for Strateloq's own brand (no FB/IG/TikTok/LinkedIn page node in an
armed workflow). Growth Agents send only email/in_app to users. **NOT_CONNECTED.**

## 16. Paid-ad connections
Meta system-user credential exists (Meta Draft Executor PAUSED-only). **No armed** paid path; TikTok has a
commercial-content token (organic/creative intel, not ads). LinkedIn: **NONE.** No ad account is connected
for auto-spend. **NOT_CONNECTED (paid launch).**

## 17. Reusable capabilities
- **Growth Agents (reuse for the LIFECYCLE half of "growth"):** consent-gated + privacy-gated event
  ingestion, engagement/activation scoring, churn/conversion tiering, rate-limited multi-channel messaging,
  shared Send-Message sub-workflow, founder-alert path. Directly reusable for **Strateloq's own brand
  retention/onboarding** and as the pattern for consent-gated automation.
- **Marketing Director (reuse as the ORCHESTRATION brain):** intelligence-grounded planning that already
  loads `get_member_marketing_context`, emits a canonical campaign + platform payloads + a performance
  schema seam + `memory_updates` reserved for learning. It is the natural home for a performance-feedback
  sub-agent.
- **Shared infra:** `campaign_performance_snapshots` schema, `meta-insights-reader`, PAUSED Meta executor,
  `campaign_builder_drafts` authorization gates (spend/activation).

## 18. Missing capabilities (for the target Performance + Growth specialist)
1. **Performance ingestion** into `campaign_performance_snapshots` from connected ad accounts (none today).
2. **Creative-performance comparison / CTR / CPA / ROAS analysis** (no function exists).
3. **Underperformer / stronger-concept detection + pause/continue/test recommendations.**
4. **Creative-fatigue detection** (needs time-series performance — absent).
5. **Feedback wiring:** performance insight → Marketing Director → Ad Creative Studio (`ad_studio_*`) → next test.
6. **Connected ad/social accounts** (Strateloq's own + customers').
None of these exist; the current Growth Agent does not cover them (different domain).

## 19. Duplicate / orphan components
- **Two campaign-draft lineages (partial duplication):** legacy `marketing_campaign_drafts` (via Marketing
  Director + `persist_marketing_campaign_draft`) vs newer `campaign_builder_drafts` (via Ad Studio +
  `fn_cb_build_campaign`, 015E). They overlap on platform payloads + performance schema. **015F/015G must
  reconcile** which is authoritative (recommend the newer `campaign_builder_drafts`/`ad_studio_*` lineage;
  keep MD as the planner that feeds it).
- **Growth Agents:** a coherent suite, **not** duplicated, but currently **orphaned** (inactive, empty, no
  caller). "v1" MD naming implies an intended successor.

## 20. Security / permission findings
- Growth Agents: **consent-gated + privacy-gated** (metadata whitelist) + **rate-limited** (14-day). Good posture.
- MD: `publish:false`, all payloads **PAUSED**, `requires: human_review + explicit_publish_approval`; ad account IDs are `<PHASE2…>` placeholders.
- `spend_authorization` / `activation_authorization` (on `campaign_builder_drafts`) are **not consumed** by MD or Growth Agents → any future auto-optimize must gate on them.
- Credentials referenced by **type/name only** (Anthropic, Gemini, Supabase, Gmail, Meta System User) — **no secret exposed**. `media_providers.config` uses a `secret_storage` reference, not inline keys.

## 21. n8n execution / cost concerns
**Currently zero cost** — every Growth + MD workflow is **inactive**. **If reactivated**, Agent C (4h),
Agent A (6h), Agent B (12h), Agent D + synthetic (daily) are **sub-weekly recurring** and conflict with the
project preference (*avoid unnecessary executions; weekly-Monday where appropriate; tests manual only*).
Recommendation for 015F/015G: before arming any lifecycle agent, right-size cadence (e.g. daily/weekly) and
keep tests manual. (Separately noted in the DR inventory: two *older global trend* workflows —
`vjretQJdnd3OEyd0` hourly, `3CSvKgEGjSzRWpEO` — are active and unrelated to this suite; already flagged for
founder review.) **No schedule changed in this audit.**

## 22. Suitability for Strateloq brand marketing
**Good fit as a proving ground**, in two halves:
- **Lifecycle (reuse now, low risk):** Growth Agents can run on Strateloq's own users (retention/onboarding)
  once armed with right-sized cadence + consent — no ad spend, no external accounts.
- **Ad performance (new capability, higher risk):** requires connecting Strateloq's own **organic social**
  (FB/IG/TikTok/LinkedIn pages) and, separately, **paid ad accounts** (Meta/TikTok/LinkedIn Ads). Keep
  **organic-social connection** distinct from **paid-ad-account connection** (different scopes/permissions).
  **Do not connect any account in this audit.**

## 23. Recommended future role
Per the reuse rule, **do not build a second Growth Agent.** Instead:
- **Keep the existing Growth Agents as the Lifecycle/Retention specialist** (rename scope clearly:
  *Lifecycle Growth*), beneath the Marketing Director.
- **Add a NEW Performance sub-agent** (*Ad Performance / Optimization specialist*) beneath the Marketing
  Director that ingests `campaign_performance_snapshots` and feeds insights back to the Marketing Director
  and Ad Creative Studio. This is the target "Performance + Growth Specialist" — it is **missing**, not the
  existing PLG suite.
- **Upgrade the Marketing Director** into the orchestration brain that fans out to: Ad Creative Studio,
  Lifecycle Growth agents, Campaign Execution, and the new Ad Performance sub-agent.

Target hierarchy (adjusted from the founder's, justified by evidence):
```
STRATELOQ
├── Intelligence systems (Product / Opportunity / Decision / Problem / Creative)
└── AI Marketing Director  (upgrade YDhtr1EPQRUv5wdm — orchestration brain)
     ├── Internal Ad Creative Studio (ad_studio_* / media_*, 015E)
     ├── Lifecycle Growth agents (EXISTING Pulse Growth A–D — reuse)
     ├── Campaign Execution (campaign_builder_drafts + Meta/TikTok/LinkedIn)
     └── Ad Performance / Optimization sub-agent (NEW — the target role)
          └── campaign_performance_snapshots → insights → MD + Creative Studio
```

## 24. Exact upgrade requirements
1. **Reconcile draft lineages** — make `campaign_builder_drafts`/`ad_studio_*` authoritative; MD feeds it (deprecate/bridge legacy `marketing_campaign_drafts`).
2. **Performance ingestion function** → `campaign_performance_snapshots` from `meta-insights-reader` (and TikTok/LinkedIn later), tenant-scoped, is_fixture-safe.
3. **Deterministic performance-analysis contracts** (CTR/CPA/ROAS where data exists; creative comparison; fatigue detection) — never invent performance data; require real snapshots.
4. **Feedback contracts:** performance insight → MD (`memory_updates` seam) → Ad Creative Studio (new creative test) → next iteration.
5. **Mode + authorization gates:** RECOMMEND_ONLY → MANUAL_APPROVAL → AUTO_OPTIMIZE, each gated on connected account + tenant + platform permissions + `spend_authorization` + `activation_authorization` + budget + max-change limits + audit trail.
6. **Right-size Growth Agent cadence** before arming; keep tests manual.
7. **Account connection (separate unit, founder-driven):** organic social vs paid ad accounts, distinct.

## 25. Proposed closed-loop connection map (EXISTS / PARTIAL / MISSING / EXTERNAL_DEPENDENCY)
| Link | State |
|---|---|
| Strateloq Intelligence → Marketing Director | **PARTIAL** (`get_member_marketing_context` loaded; MD inactive) |
| Marketing Director → Ad Creative Studio | **MISSING** (MD emits `creative_specs` but does not call `ad_studio_*`/`media_*`) |
| Ad Creative Studio → Approved Creative | **PARTIAL** (015E backbone exists; no generation executor) |
| Approved Creative → Organic/Paid Execution | **PARTIAL** (PAUSED Meta executor; `campaign_builder_drafts`; LinkedIn MISSING) |
| Execution → Meta / TikTok / LinkedIn | **PARTIAL / EXTERNAL_DEPENDENCY** (Meta creds exist; accounts not connected; LinkedIn MISSING) |
| Platforms → Real Performance Data | **MISSING / EXTERNAL_DEPENDENCY** (read-only insights fn exists; no ingestion; needs connected accounts) |
| Real Performance → Growth/Performance Agent | **MISSING** (no consumer of `campaign_performance_snapshots`) |
| Performance insights → Marketing Director | **MISSING** (`memory_updates` seam unused) |
| Marketing Director → Ad Creative Studio (next test) | **MISSING** |
| (Existing PLG loop: events → lifecycle agents → messages) | **EXISTS but inactive/empty, and orthogonal to the ad loop** |

## 26. What 015F / 015G must account for
- The target Performance specialist is **new**, not the existing PLG Growth Agent — build it **beneath** the upgraded Marketing Director; **do not** create a second Growth Agent.
- **Reconcile the two campaign-draft lineages** before wiring execution.
- **Performance data is external-dependency-gated** (connected ad accounts) — architect ingestion but do not fabricate metrics; the 1 real snapshot + 15 fixtures must never be treated as live performance.
- **Reuse** the Growth Agents for Strateloq brand lifecycle; **separate** organic-social from paid-ad connection; right-size cadence to the weekly-Monday/avoid-waste preference.
- Respect existing gates: `publish:false` / PAUSED / `spend_authorization` / `activation_authorization` / human review; consent + rate limits for lifecycle messaging.
- No Product Decision or Problem-corroboration changes; Reddit stays `BLOCKED_EXTERNAL_APPROVAL`.

## 27. Files changed — documentation only
- `docs/STRATELOQ-GROWTH-AGENT-AUDIT-015E.1.md` — this audit. No code, no DDL, no workflow change, no activation.

## 28. Commit hash
See the delivery message (committed to `claude/pulse-crash-recovery-b6ngey`).

## 29. Final verdict
**`GROWTH_AGENT_NOT_CONNECTED`** — a well-formed PLG lifecycle Growth Agent exists but is inactive, empty,
and not connected to the ad-campaign performance loop; the target Performance + Growth specialist is a
**new** capability to add beneath an **upgraded** Marketing Director, reusing (not replacing) the existing
agents. Awaiting founder review before any upgrade or connection.

---

**STOP.** Audit only. No implementation, activation, account connection, ad-account connection, campaign
launch, auto-posting, ad spend, Lovable, publish, Stripe, paid provider call, or secret exposure. Product
Decision scoring and Problem Intelligence unchanged. Reddit remains `BLOCKED_EXTERNAL_APPROVAL`.

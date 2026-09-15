# STRATELOQ DR — n8n WORKFLOW INVENTORY

Instance `tradingb.app.n8n.cloud` holds **51 workflows total**, several belonging to unrelated projects
(AI Career Copilot ×5, Construction Quote ×3, AI Receptionist, AI Recruitment, AI Lead Qualification, Setup
Sheet Headers) — **out of Strateloq DR scope**. Strateloq/Pulse workflows below. Credential column shows
**references only** (see SECRETS-RECOVERY.md). Recovery priority: P1 (launch-critical) → P3.
Full definitions: export with `scripts/dr/dr_n8n_export.sh`; the two P1 approved-schedule defs are committed
in `dr/n8n/*.json`.

| ID | Name | Active | Trigger / schedule | Credential refs | Criticality | Priority |
|---|---|---|---|---|---|---|
| BBxcPXJdF2PliWgf | Monday Ecom Product Opportunity Orchestrator | ✅ | **weekly Mon 07:00 UTC** + manual | Supabase account | launch-critical (ecom scan) | P1 (def committed) |
| np2MUp83gaZ3C2pJ | FX Rate Refresher | ✅ | **daily 06:00 UTC** + manual | Supabase account | critical (FX freshness) | P1 (def committed) |
| HzCiA223z3pKOUSc | Business Discovery Worker | ✅ | webhook | Supabase, Gemini, Anthropic | launch-critical | P1 |
| OhjyxfdGMHwh9kRc | Product Preparation Worker | ✅ | webhook | Supabase, Gemini | launch-critical | P1 |
| A8fTV08XOvUMq93n | Agent 0 — Founding Member Intake + Business DNA | ✅ | webhook | Supabase, Gemini, Gmail | critical (onboarding) | P1 |
| DxVfPg5fickAB1sr | Meta Draft Executor (PAUSED-only) | ⚪ | manual/api | Meta System User, Supabase | launch-critical (paid) | P1 |
| dYoeIeiXwPOrDDY4 | Creative Image Generation (Manual, OpenAI) | ⚪ | manual | OpenAI account, Supabase | critical (creative) | P2 |
| LJePIvYVTnW8WDPv | Meta Ads Insights Recovery (read-only) | ⚪ | manual | Meta System User | important (perf) | P2 |
| KwcYYuHR53ONLFPZ | Meta Connection Test (read-only) | ⚪ | manual | Meta System User | important | P2 |
| ixC4UXe2JAcF4ajF | Meta Ad Library Probe | ⚪ | manual | Meta Ad Library User | important (intel) | P2 |
| NvuwUfW7fyjSb81R | CJ Supplier Collector | ⚪ | manual | CJ Dropshipping API, Supabase | important (supply) | P2 |
| OxH9sb6jKCqiqXOk | CJ Detail + GB Freight Probe | ⚪ | manual | CJ Dropshipping API | supporting | P3 |
| ZbhPyAuvDD4h4xid | CJ Supplier Enrichment Probe | ⚪ | manual | CJ Dropshipping API | supporting | P3 |
| ZN6huMtz3DNIMnks | eBay Browse API Probe | ⚪ | manual | Pulse eBay Production | supporting | P3 |
| 0HGniWXeacHbVTQL | DataForSEO Buyer Intent Probe | ⚪ | manual | Pulse DataForSEO | supporting | P3 |
| 0aXO9OmUfRXhI5s2 | Ecom Product-Signal Collector (Reddit) | ⚪ | manual | (public JSON) | supporting | P3 |
| 0hmmy8hGfJ7H2pbK | Reddit Product-Attention Adapter | ⚪ | manual | Anthropic | supporting | P3 |
| nh9tUaplw6SdSSY4 | Storefront HTTP Acceptance (Manual) | ⚪ | manual | (public) | test-only | P3 |
| YDhtr1EPQRUv5wdm | AI Marketing Director v1 | ⚪ | form/schedule | Anthropic, Gmail | legacy CMO report | P3 |
| vjretQJdnd3OEyd0 | Agent 1 GLOBAL: Trend Collector | ✅ | **hourly (schedule)** | (search/RSS) | ⚠ drift review | P2 |
| 3CSvKgEGjSzRWpEO | Agents 2+3 GLOBAL: Analyzer + Opportunity Finder | ✅ | **schedule** | Gemini | ⚠ drift review | P2 |
| UUm5NR7en5Y3IW0K | Agent 6 GLOBAL: Content Generator | ✅ | on-demand/trigger | Anthropic | supporting | P3 |
| L9GmhqestJ1hZVmk | Agent 6 Customer Content Worker | ✅ | trigger | Supabase, Anthropic | supporting | P3 |
| sIuakWYVmI0LryeI / ACE0U5jrEXkqleEy / xHWwUelZINWpAAFL / KZ… (growth agents A–D, event collector, send-message) | Meta probes / Pulse Growth agents | ⚪ | manual/schedule (inactive) | Meta / Supabase / Gemini | supporting | P3 |

## ⚠ Schedule-drift finding (report first, do NOT change in this unit)
Two older **GLOBAL trend-intelligence** workflows run on **sub-weekly schedules** while active:
`vjretQJdnd3OEyd0` (Agent 1 Trend Collector, ~hourly) and `3CSvKgEGjSzRWpEO` (Agents 2+3). These predate the
ecommerce "Monday-only" policy and belong to the original creator-trend subsystem, not the ecom scan. They are
**not** the ecom product/intelligence scan, so they do not violate the Monday-only ecom policy on their face —
but they are active recurring compute and should be **confirmed intentional by the founder** (cost/drift). No
change was made. The only ecom production schedule is the Monday orchestrator; FX daily is the approved exception.

## Credential recovery (references only)
Recreate each credential in n8n per SECRETS-RECOVERY.md (provider console → key/OAuth → reconnect), then
re-bind on the imported workflows. n8n exports carry credential references, never values.

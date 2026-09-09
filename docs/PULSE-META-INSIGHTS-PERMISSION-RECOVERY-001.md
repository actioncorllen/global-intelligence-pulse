# PULSE-META-INSIGHTS-PERMISSION-RECOVERY-001

**VERDICT: PASS — BLOCKED_EXTERNAL_META_INSIGHTS_PERMISSION = RESOLVED (real evidence).**

Resolved using the existing n8n credential **Pulse Meta System User** (facebookGraphApi,
id CUPOz84CelhVBvzd) — no token exposed, no credential changed, read-only.

## Real evidence (Graph v26.0, via n8n)
- **Connectivity / identity:** token_valid=true, identity "Pulse Automation" (122093269557470021), HTTP 200.
- **Permissions granted:** pages_show_list, **ads_management, ads_read**, pages_read_engagement,
  pages_manage_ads, public_profile (this is the permission the CAPI token lacked in Phase 14).
- **Ad account:** act_2761487367369763 "Smart actions store Ad account", status 1, USD, amount_spent 0.
- **Campaign read (HTTP 200):** 120250770392410010 "Founding Beta User Signups … [PULSE DRAFT]",
  status PAUSED, effective_status PAUSED, objective OUTCOME_LEADS.
- **Ads Insights read (HTTP 200):** `data: []` — credential can read Insights; empty array = genuine
  zero delivery (never activated). Header: ads_insights, ads_api_access_tier=development_access.
  Development tier did NOT block reading Insights for the owned account.

## Integration path (proven)
Meta → n8n credential (Pulse Meta System User) → Ads Insights → canonical Phase-14 snapshot.
Reusable read-only workflow: "Pulse — Meta Ads Insights Recovery (read-only)" (n8n id LJePIvYVTnW8WDPv).
The secret stays inside n8n; nothing moved to Supabase.

## Canonical ingestion
Inserted one real snapshot into `campaign_performance_snapshots` (tenant 7c8ddf9d…, execution
ef1ba0c9…, campaign 120250770392410010): source_class=PLATFORM_REPORTED, is_fixture=false,
spend/impressions/clicks=0 (genuine zero delivery), provenance records "empty_data_no_delivery".
`fn_perf_evaluate` → decision INSUFFICIENT_DATA (NO_DELIVERY), executable=false. Real zero, not fabricated.

## Safety / invariants
Read-only. campaign_activation=FALSE (proof still CREATED_PAUSED, executions=1); advertising_spend=0
(amount_spent 0, spend authority 0); no budget/campaign/ad change; token never exposed; no recurring
n8n schedule added; cost €/$0.

## Remaining founder action
None to unblock Insights reads for the owned account. Note: the app is on Meta
**development_access** tier — sufficient for reading the founder's own ad account/objects, but a
future move to standard/advanced Ads API access tier would be required only for broader/production
scale beyond owned objects. Not blocking Performance Intelligence on the proof account.

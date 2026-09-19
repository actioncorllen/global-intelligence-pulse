# STRATELOQ-ECOM-WORKSPACE-INTELLIGENCE-CONTRACTS-013E

**VERDICT: `PASS`.** Five existing Ecommerce runtimes (competitor, supplier, creative/ad, signal,
campaign-execution) are now reachable through authenticated, `auth.uid()`-scoped, browser-safe read
contracts. Additive only; no new intelligence, no synthetic data, no historical mutation, no Lovable
change, no Store Builder, no payment. €0.

Migration: `supabase/migrations/mig_241_ecommerce_intelligence_contracts.sql`.

---

## 1. Pre-implementation architecture map
All source tables are **RLS deny-all to clients**; the new SECURITY DEFINER RPCs are the only browser read
path. Ownership keys (verified): `product_market_competitors`(tenant_id,product_id),
`ad_studio_briefs`(tenant_id,product_id,decision_id)/`ad_studio_angles`(brief_id,tenant_id)/
`ad_studio_static_creatives`(angle_id,tenant_id), `media_assets`(tenant_id,product_id)/
`media_video_jobs`(tenant_id,angle_id), `commerce_signals`(user_id,product_id),
`marketing_campaign_drafts`/`_executions`(user_id), `product_acquisitions`(user_id). For the founder tenant
`tenant_id == user_id == auth.uid()`. The global `commerce_supplier_products` catalogue has **no tenant
key** — tenant-owned supplier data lives in `product_acquisitions` snapshots.

## 2. Competitor tables / relationships
`product_market_competitors` — real observed listings/ads, keyed `tenant_id`+`product_id`+
`product_market_evaluation_id`, `is_fixture` flag. Founder: **74 rows, all non-fixture**
(MARKETPLACE_LISTING, e.g. eBay, GBP prices). Internal-only fields present: `match_evidence`,
`price_normalized`, `ad_window`, `marketplace_presence`, `provenance`, `competitor_ref`, `source_reference`.

## 3. Competitor contract
`fn_ecommerce_competitor_intelligence()` — authenticated, `tenant_id = auth.uid()`, `is_fixture=false`,
joined to `commerce_products` for `product_title`. Returns browser-safe fields (identity, country, kind,
observed URL, platform, match_class/confidence, price_original+currency+source_class, ad platform/count/
status, creative/offer/cta pattern, evidence_class, confidence, observed_at). Never returns provenance,
match_evidence, normalized price, marketplace raw, or fixtures. **Never labels "winning".**

## 4. Supplier tables / relationships
Tenant-owned supplier data is in `product_acquisitions` (`user_id`): `sourcing_spec_snapshot.
supplier_options` + `selected_supplier_snapshot`. The shared `commerce_supplier_products` catalogue is
**not** tenant-owned and is **not exposed**. Founder: **0 acquisitions** → honest NO_DATA.

## 5. Supplier contract
`fn_ecommerce_supplier_intelligence()` — authenticated, `product_acquisitions.user_id = auth.uid()`.
Projects a curated safe supplier shape (supplier_name, source, observed_cost, cost_currency,
is_free_shipping, shipping_country_codes, rank) from the caller's OWN snapshots. Observed cost/currency
only — **no invented margins or delivery times**; catalogue never exposed. Returns empty for the founder
(NO_DATA), which is correct.

## 6. Campaign contracts reused / added
- **Reused:** `get_own_marketing_campaign_drafts()` (existing, authenticated, `user_id`-scoped) — **not
  duplicated**; founder has 2 drafts.
- **Added:** `fn_ecommerce_campaign_executions()` — safe projection of `marketing_campaign_executions`
  (execution_id, draft_id, platform, status, `launched` flag, timestamps). **Never** exposes
  `meta_account_ref`/`meta_page_ref`/`meta_campaign_id`/`_adset_id`/`_creative_id`/`_ad_id`,
  `effective_status` raw, notes, tokens or webhook data. Founder: 1 execution.

## 7. Ad Studio / creative contract
`fn_ecommerce_creative_intelligence()` — authenticated, `tenant_id = auth.uid()`, `is_fixture=false`.
Returns briefs (product_title, market, status, honest linkage flags) → angles (name/type/problem/outcome/
hook/headline/copy/cta/visual_concept/video_hook/claim_risk/review_state) → static_creatives (platform/
headline/supporting_text/cta/layout/aspect_ratio/generation_status/asset_url), plus a media summary
(images: type/status/approval/launch-safe/aspect/country; videos: platform/status/aspect/duration/hook/
cta). Excludes evidence/keyword/competitor blobs, provider job ids, storage refs, costs, fingerprints,
claim internals. Founder: 1 brief, 3 angles, 1 static creative, 1 image.

## 8. Creative → decision linkage status
**Honest and unrepaired.** The founder brief's `decision_id IS NULL` → the contract returns
`linked_to_decision = false` and `linked_to_product = true` (brief is tied to the Dash Cam product
`ae458526`). No historical record was mutated to fake a decision link. Establishing a Product-Decision →
creative link is **LINKAGE_REQUIRED** (future generation-time work), not repaired here.

## 9. Signal timeline contract / status
`fn_ecommerce_signal_timeline()` — authenticated, `commerce_signals.user_id = auth.uid()`. Returns a
timeline (signal_type, product_id, confidence, observed_at, source_event_at, visibility, and safe context
`market`/`source_platform`/`attention_basis`) plus a type summary. **Only signal types that exist** —
founder has **11 `COMMUNITY_ATTENTION`** only; no Search/Customer types invented. Never returns raw mention
text, evidence, provenance or dedup keys. (This complements the Overview `evidence_summary` from 013A
without duplicating storage.)

## 10. Founder real-data verification (impersonated, live)
`fn_ecommerce_intelligence_contracts_selftest` → **6/6 all_pass**. Live founder reads:
competitors **74** (e.g. "over door shoe organizer", eBay, 11 GBP, CLOSE_COMPARABLE, OBSERVED);
suppliers **0** (honest NO_DATA); creative **1 brief / 3 angles / 1 image**, `linked_to_decision=false`,
`linked_to_product=true`; signals **11 COMMUNITY_ATTENTION**; executions **1**.

## 11. Cross-tenant tests
Impersonating `cleantech` → competitors **0**, creative **0**, signals **0**, suppliers **0**,
executions **0**. No founder data leaks across tenants. **PASS.**

## 12. Anonymous tests
`anon` role → `42501 permission denied for function fn_ecommerce_competitor_intelligence` (all five
contracts revoke anon). **PASS.**

## 13. Leakage / security tests
Concatenated output of all four founder-facing contracts scanned for
`provenance|match_evidence|price_normalized|storage_ref|provider_job_id|meta_account_ref|meta_campaign_id|
effective_status|mention_context|is_fixture|raw` → **no match (leak_scan=false)**. All contracts SECURITY
DEFINER, `search_path=''`, `auth.uid()`-scoped, authenticated+service_role only, anon revoked. No
service-role exposure, no secrets, no client-supplied tenant authority, RLS unchanged. **PASS.**

## 14. Regression results
Storefront **65/65** (runtime 38 / publish 9 / branding 8 / lifecycle 10); entitlement selftest
**all_pass**; 013A ecommerce-connection selftest **all_pass**. Product Decision / entitlement / storefront
contracts untouched (M/N/O). **PASS.**

## 15. Data-integrity results
Members 5, decisions 24, competitors 108, ad_studio_briefs 2, entitlement 2, storefront pages 2 — all
unchanged. No rows created/updated/deleted; only functions added. All impersonated tests were read-only
(the two mutation-free `set local` transactions were not committed). **No synthetic records (Q).**

## 16. Migrations / files changed
- `supabase/migrations/mig_241_ecommerce_intelligence_contracts.sql` (applied) — 5 read contracts +
  1 selftest. No schema/table/RLS change; no data migration.
- `docs/STRATELOQ-ECOM-WORKSPACE-INTELLIGENCE-CONTRACTS-013E.md` (this report).

## 17. Exact browser-safe contracts Lovable should consume (013F)
Authenticated, no args, `auth.uid()`-scoped:
- `supabase.rpc('fn_ecommerce_competitor_intelligence')` → `{status,count,competitors[]}`
- `supabase.rpc('fn_ecommerce_supplier_intelligence')` → `{status,count,acquisitions[{selected_supplier,supplier_options[]}]}`
- `supabase.rpc('fn_ecommerce_creative_intelligence')` → `{status,brief_count,briefs[{linked_to_decision,linked_to_product,angles[{static_creatives[]}]}],media{images[],videos[]}}`
- `supabase.rpc('fn_ecommerce_signal_timeline')` → `{status,count,signal_types[],timeline[]}`
- `supabase.rpc('fn_ecommerce_campaign_executions')` → `{status,count,executions[]}` + existing
  `supabase.rpc('get_own_marketing_campaign_drafts')` for drafts.
Render only fields present; honor `linked_to_decision`; treat empty `count` as an honest NO_DATA state.

## 18. Capabilities now READY_FOR_UI
- **Competitors** — READY (74 real rows).
- **Creative / Ads** — READY (1 brief / 3 angles / 1 image; honest linkage flags).
- **Signal timeline** — READY (11 signals).
- **Campaigns** — READY (drafts via existing contract + safe executions projection).
- **Suppliers** — contract READY; **NO_DATA** for the founder (no acquisitions yet).

## 19. Capabilities still blocked / missing
- **Supplier data** — NO_DATA until the founder runs a sourcing/acquisition (contract is ready).
- **Creative → Product-Decision linkage** — LINKAGE_REQUIRED (brief `decision_id` NULL; a generation-time
  fix, not a read contract).
- **Audience / Analytics** — NOT_BUILT (out of scope, per 013C).

## 20. Create Store reuse audit (audit only — not built)
Existing backend: `commerce_store_projects` + `fn_create_pulse_store_draft` / `fn_edit_pulse_store_page` /
`fn_store_builder_payload` (Pulse Store builder), `commerce_store_connections` (external store connection),
`fn_storefront_set_destination`, and the full storefront publish suite. Founder pages: both
`destination=PULSE_STORE` (1 REAL Dash Cam + 1 FIXTURE); **0 external store connections**. So:
- **Existing-store vs no-store** can be distinguished from `commerce_store_connections` (any connected
  external store?) and/or `commerce_store_projects` (a Pulse Store project exists?). The founder is a
  **no-store** user (0 connections).
- **`+ CREATE PRODUCT PAGE`** → fully reusable today (`fn_storefront_publish_context`/`fn_storefront_publish`
  + `product-page-builder`).
- **`+ CREATE STORE`** → the Pulse Store draft/edit runtime exists; what remains is a small authenticated
  "own store state / create-store entry" read contract + the UI. **Not built in this unit.**

## 21. Confirmation: no synthetic data
No competitor, supplier, campaign, ad, creative, signal or any other record was created. Only functions
were added; all data counts are unchanged.

## 22. Confirmation: no payment work
No Stripe, subscription, checkout or entitlement change. `account_entitlement` untouched (2 COMP rows).

## 23. Commit / divergence
See delivery message; branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

## 24. FINAL VERDICT
**`PASS`.** Competitor, supplier, creative/ad, signal and campaign-execution intelligence are now exposed
through secure, tenant-scoped, browser-safe authenticated contracts over the EXISTING runtimes, with honest
linkage and NO_DATA states, no leakage, cross-tenant + anonymous denial, 65/65 storefront + entitlement +
connection regressions green, advisors unchanged at 5, and zero synthetic data. Lovable can now build
Competitors/Suppliers/Signals/Creative/Campaign surfaces on real data (013F). Create Store remains audited
but unbuilt.

STOP. No Lovable implementation, no Create Store, no payment integration started.

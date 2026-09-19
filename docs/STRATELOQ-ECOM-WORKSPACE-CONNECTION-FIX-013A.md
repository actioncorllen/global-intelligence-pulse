# STRATELOQ-ECOM-WORKSPACE-CONNECTION-FIX-013A

**VERDICT: `PASS`.** The existing Ecommerce intelligence (lineage #3: `product_opportunity_decisions`
+ `commerce_products` + `commerce_signals` + storefront) is now connected to the authenticated
workspace through one authoritative, category-aware, tenant-scoped contract — plus a durable
server-owned business category persisted via the existing onboarding save. Additive only; no rebuild,
no synthetic opportunities, no generic `member_opportunities` manufactured, no Lovable change, no
payment, RLS intact, advisors unchanged, all existing data preserved. €0.

Migration: `supabase/migrations/mig_240_ecommerce_workspace_connection.sql`.

---

## 1. Root cause addressed
Audit 013 showed the workspace read the generic/commerce-projection lineages (empty for the founder)
and never read the real `product_opportunity_decisions`; and it classified "Ecommerce" from the absent
`member_business_dna.dna_extended.commerce` rather than a durable category. Both are fixed: a durable
`business_category` now carries classification, and `fn_ecommerce_workspace_intelligence()` composes the
real lineage #3 directly (no dependency on `member_business_dna`, no `v_run` gate, no website discovery).

## 2. Existing architecture reused (not rebuilt)
`product_opportunity_decisions` (WPS V2 decisions), `commerce_products`, `commerce_signals`,
`commerce_product_pages` (storefront), and the existing `save_business_profile` onboarding contract and
`business_profiles` ownership/RLS model. No parallel intelligence architecture created.

## 3. Canonical category persistence design
- `public.business_category` catalog (code PK, label, sort, is_active) seeded with the 5 approved
  categories: `marketing_agencies`, `creators`, `local_businesses`, `coaches`, `ecommerce`. RLS enabled
  with a read-only policy (client-readable labels/routing, never client-writable).
- `public.business_profiles.business_category text NULL REFERENCES business_category(code)` — the
  authoritative per-tenant category, on the existing owned profile, fully independent of
  `business_summary` / `opportunity_preferences.businessDiscovery`. Existing rows stay NULL and remain
  compatible. `business_description` semantics are untouched (it was never a DB column; the frontend
  draft field is unaffected).

## 4. Migration / schema changes
Additive: new `business_category` table (RLS + read policy); new nullable FK column
`business_profiles.business_category`; deterministic founder backfill; `save_business_profile` extended
(4 minimal additions); new `fn_ecommerce_workspace_intelligence()`; new `fn_ecommerce_connection_selftest()`.
No column dropped, no type changed, no RLS weakened.

## 5. Onboarding persistence contract (for 013B)
`save_business_profile(p_content jsonb, p_complete boolean)` now accepts `business_category` in
`p_content`: validated against the active catalog (unknown value → `{status:'invalid', fields:
['business_category']}`), tenant-scoped, ownership-enforced, partial-save safe (absent → unchanged),
independent of every other field. A browser cannot target another tenant — the target row is resolved
from `auth.uid()` and `p_content` has no tenant/id key (a rogue `user_id` key is rejected as unknown).

## 6. Ecommerce workspace intelligence contract
`fn_ecommerce_workspace_intelligence()` — authenticated, `auth.uid()`-scoped, SECURITY DEFINER,
`search_path=''`. Returns `{ status, category, is_ecommerce, business, product_decisions[],
product_decision_count, products_tracked, evidence_summary[], storefronts[], source_contract }`. Works
for the no-store-yet journey (composes lineage #3 directly; no website discovery, no `member_business_dna`,
no `member_opportunities`). Granted to `authenticated` + `service_role`; `anon` has no EXECUTE.

## 7. Product Decision exposure (browser-safe)
Per decision: product_title, product_category, product_url, source_store, observed_price+currency,
availability, decision, opportunity_band, opportunity_score, coverage, product_confidence,
evidence_confidence, country_code, primary_platform, lifecycle_state, action_gating, decision_reasons,
saturation_state, advertising_headroom, opportunity_sweet_spot, and the storefront link (page_id /
status / publication_state) when a page exists. **Not exposed** (verified `leaks_check=false`): lineage,
hard_gates, decision/execution blockers, economics_ref, cpa_scenarios, provenance, evaluation ids, raw
evidence payloads, service-role data. `commerce_signals` are exposed only as an aggregate summary
(type + count + last_observed), never raw.

## 8. Commerce projection decision — NOT required for the workspace
`finalize_commerce_from_run → score_commerce_products → commerce_product_opportunities +
member_business_dna.dna_extended.commerce` is left **unchanged** and continues to serve its
Market-Explorer consumer (`get_global_market_intelligence`). The authoritative Ecommerce *workspace*
contract supersedes it by composing lineage #3 directly, so it was **not** executed to patch the UI and
**no** synthetic/duplicate opportunity rows were created (census: `commerce_product_opportunities` = 0
for the founder). This also removes the founder-manual-execution dependency Audit 013 flagged.

## 9. Founder Ecommerce repair
Category backfill only: `business_category='ecommerce'` set on the single profile whose industry is
exactly `'Broad Ecommerce Opportunity Discovery'` (verified unique → the founder tenant). No opportunity
data created or altered; the 7 decisions / 12 products / 11 signals were already present and are read
as-is. Idempotent (`… AND business_category IS NULL`).

## 10. Dash Cam relationship finding
`commerce_product_pages.opportunity_decision_id` is **never populated anywhere** (0 of 2 pages globally)
— a forward-looking column not yet wired by the page builder. The Dash Cam (`ae458526`, a manually
prepared publishing fixture, `source_run_id` NULL, not one of the 7 decisioned products) having a NULL
link is therefore **expected legacy test data, not a linkage defect**. Not mutated (the contract surfaces
the storefront by `product_id`, independent of that column).

## 11. Tenant isolation
All reads scoped by `auth.uid()`. Cross-tenant read denied: `actionncube67` → `is_ecommerce=false`, 0
decisions, 0 products; never sees the founder's 7 (test L). `business_profiles` RLS confirmed to block
cross-tenant profile reads (an impersonated tenant reads NULL for another's category).

## 12. Category isolation
A non-Ecommerce tenant (`cleantech`) → `is_ecommerce=false`, category null, 0 product decisions — cannot
receive founder Ecommerce intelligence (test K). Category classification never leaks across tenants.

## 13. No-store-yet verification
The founder tenant is `entry_mode='no_store_yet'`, `website` NULL, `member_business_dna` absent — and the
contract still returns full Ecommerce intelligence (`is_ecommerce=true`, 7 decisions). Generic website
discovery is **not** a prerequisite (test I).

## 14. Returning-user verification
Resolution is deterministic by `auth.uid() → member → business_profiles → business_category`; a returning
sign-in resolves the same business + category. A valid `save_business_profile({business_category})`
returns `status='saved'` and persists the category (test J).

## 15. Existing Product Decisions verification
`fn_ecommerce_workspace_intelligence()` for the founder returns `product_decision_count=7` — red light
therapy led mask (89.6, HIGH_CONFIDENCE_TEST), kids nightlight projector (STRONG_TEST ×4 markets),
digital picture frame (STRONG_TEST), over-door shoe organizer (TRENDING_WATCH), all `WATCH` — reachable
with browser-safe reasoning + evidence summary + storefront link (tests E, F).

## 16. Storefront regression
Runtime **38/38**, publish **9/0**, branding **8/0**, lifecycle **10/0** = **65/65 PASS** (test N).

## 17. Entitlement regression
`fn_paid_access_selftest` → **all_pass true** (17/17). `account_entitlement` unchanged (2 COMP rows).
Category is independent of entitlement (test O).

## 18. Invitation / auth regression
No invitation/auth object was modified by this migration (it touches only `business_category`,
`business_profiles.business_category`, `save_business_profile`, and two new functions). No DB
invitation/auth selftest suite exists; the onboarding/auth-adjacent contract `save_business_profile` was
verified to preserve prior behavior — unknown-key rejection (rogue `user_id` → invalid), ownership
resolution, partial save, and the `discovery_state` transition all intact. Member/auth bindings unchanged
(5 members, all active) (test P).

## 19. Data mutation summary
- **Schema:** +`business_category` table (5 seed rows); +`business_profiles.business_category` column.
- **Data:** 1 row backfilled (founder profile → `ecommerce`). Nothing else created/updated/deleted.
- **Not touched:** members, businesses (all 6 rows; only 1 categorized), product decisions (24), commerce
  products/signals, storefront pages (2, Dash Cam link still NULL), invitations (11), entitlement (2 COMP),
  `member_opportunities` / `commerce_product_opportunities` (no synthetic rows — test H). All impersonated
  onboarding write-path probes were executed inside rolled-back transactions (no persistence).

## 20. Security / advisor delta
**5 → 5 (no increase).** The new SECURITY DEFINER RPC folds into the existing
`authenticated_security_definer_function_executable` category; the `business_category` table (RLS + read
policy) adds no lint. No RLS weakened, no service-role browser exposure, no hardcoded founder logic
(backfill is an evidence-based industry rule), COMP/entitlement untouched.

## 21. Cost
**€0.**

## 22. Commit / divergence
See delivery message; branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

## 23. Exact contract Lovable should consume in 013B
- **Category options (render):** `select code, label from business_category where is_active order by sort`
  (client-readable).
- **Read current category / route:** `select business_category from business_profiles` (owner-read RLS) —
  or take it from the `fn_ecommerce_workspace_intelligence` / `save_business_profile` responses. Route to
  the Ecommerce workspace when `business_category === 'ecommerce'` (or `is_ecommerce === true`).
- **Persist category (onboarding save):**
  `supabase.rpc('save_business_profile', { p_content: { business_category: 'ecommerce', ...otherFields },
  p_complete })`. Category is validated server-side; invalid → `{status:'invalid', fields:['business_category']}`.
  Do not treat `business_description` as the category.
- **Ecommerce workspace intelligence:** `supabase.rpc('fn_ecommerce_workspace_intelligence')` →
  `{ status:'ok', category, is_ecommerce, business{business_name,industry,country,business_category},
  product_decisions:[{ decision_id, product_id, product_title, product_category, product_url, source_store,
  observed_price, currency, availability, decision, opportunity_band, opportunity_score, coverage,
  product_confidence, evidence_confidence, country_code, primary_platform, lifecycle_state, action_gating,
  decision_reasons[], saturation_state, advertising_headroom, opportunity_sweet_spot,
  storefront{page_id,status,publication_state}|null }], product_decision_count, products_tracked,
  evidence_summary:[{signal_type,count,last_observed}], storefronts:[{page_id,product_id,product_title,
  status,publication_state,market,country_code,opportunity_decision_id}] }`. Authenticated only; the
  frontend renders these fields and never fabricates opportunities. The existing publish/Product-Page-Builder
  contracts (`fn_storefront_publish_context`, `fn_storefront_publish`, public `storefront` edge function)
  are unchanged and reached via the `storefront{page_id}` links.

## 24. FINAL VERDICT
**`PASS`.** Durable server-owned category added and persisted through the existing onboarding save;
authoritative category-aware Ecommerce workspace contract composes the existing real intelligence
(7 decisions + products + signals + storefront) with a browser-safe projection; no-store-yet works;
tenant + category isolation enforced; generic categories untouched; Dash Cam NULL confirmed expected
legacy; no synthetic opportunities; 65/65 storefront, 17/17 entitlement, ecom selftest 10/10; advisors
unchanged; existing data preserved; €0. Lovable can consume the contract in 013B.

STOP after 013A. Not starting 013B / provider / checkout / Lovable changes.

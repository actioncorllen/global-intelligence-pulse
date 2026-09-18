# STRATELOQ-ECOM-WORKSPACE-PRODUCT-INTELLIGENCE-E2E-AUDIT-013

**VERDICT: `READY_FOR_CONNECTION_FIX`.** Read-only audit. No schema/data/RLS/entitlement/storefront/
Lovable change; no synthetic opportunities. Every finding is from live production reads.

The founder's real Ecommerce intelligence exists, but it lives in a **different lineage** than the one
the authenticated workspace reads. The workspace "Opportunities" view reads the **generic** Pulse
opportunity tables (`member_opportunities`) and the Ecommerce presentation reads the **commerce-discovery
projection** (`commerce_product_opportunities` + `member_business_dna.dna_extended.commerce`). Both are
**empty for the founder**, because the commerce-projection/finalize step was never run for the founder's
discovery run — while the founder's actual product intelligence sits in `product_opportunity_decisions`
(7 real decisions) and a published storefront, which the workspace contract does not read. No data is
missing at the source; the connection between the existing intelligence and the workspace contract is.
This is a **connection/data-linkage + category-routing** fix, not an architecture rebuild.

---

## 1. Founder identity resolution (AUDIT 1, by auth.users only)
- **auth user:** `7c8ddf9d-172c-4a89-a402-bb7066228b61`, `auth.users.email = actioncorllen@gmail.com`, confirmed.
- **member:** `4bc6b405-2e6a-4fd0-a0cf-b2c409fd4177`, active, `member.email = actioncorllen@gmail.com` (aligned in 010E), `application_ref = NULL`.
- **entitlement:** `COMP` (internal test tenant, 012A).
- **discovery_state:** 1 row, `analysis_status = 'ready'`, `status = 'not_started'` (the 010C bootstrap row).
- Identity resolves cleanly; **hypothesis E (identity mismatch) is NOT the cause.**

## 2. Ecommerce business resolution
- **business_profiles** `8d0b22ca-6095-4c7c-a579-e065a85c3f5b`, `business_name = "Founder Ecommerce Test (GB)"`,
  `industry = "Broad Ecommerce Opportunity Discovery"`, keyed by `user_id = 7c8ddf9d` (not `application_id`;
  `application_id = 5351ad83…` but `member.application_ref` is NULL — resolved via the `user_id` fallback added in mig_238).
- **1 discovery_run** `658216ee-4a42-4c71-a783-334bc600b7c7`, completed, `entry_mode = 'no_store_yet'` (the Ecommerce, no-store journey).

## 3. Persisted category resolution (AUDIT 4 / AUDIT 6)
- **Backend:** category lives only as `business_profiles.industry = "Broad Ecommerce Opportunity Discovery"`.
  There is **no first-class category/business-type column**; no enum of the five categories in the DB.
- **Frontend onboarding** (Lovable plan `ecommerce-onboarding-business-type-2026-09-17`): the Ecommerce
  business-type single-select is stored by **reusing the existing `business_description` draft value**
  ("without backend or schema changes"). So the category the user picks pre-account is **not** persisted as a
  durable server-owned category signal.
- **Workspace category gate:** the workspace shell decides "is this an Ecommerce business?" from
  **`member_business_dna.dna_extended.commerce`** (see item 9), **not** from `business_profiles.industry`.
  The founder has **zero `member_business_dna` rows**, so the workspace does not recognise the tenant as
  Ecommerce even though `business_profiles.industry` says so. **Category is not durably reaching the workspace →
  hypothesis D (category resolution missing) is a real contributing cause.**

## 4. Existing Ecommerce data inventory (AUDIT 2 — read-only, unchanged)
For tenant `7c8ddf9d`:
| Table | Rows | Notes |
|---|---|---|
| `product_opportunity_decisions` | **7 real** (is_fixture=false) | red light therapy led mask (89.6, HIGH_CONFIDENCE_TEST, GB); kids nightlight projector (75.5, STRONG_TEST, GB/DE/FR/US); digital picture frame (74.6, STRONG_TEST, GB); over door shoe organizer (67.4, TRENDING_WATCH, GB). **All decision=`WATCH`, lifecycle `TRENDING_WATCH`.** |
| `commerce_products` | 12 | 11 tied to run `658216ee`; the Dash Cam has `source_run_id = NULL`. |
| `commerce_signals` | 11 | run `658216ee`. |
| `commerce_product_pages` | 1 | Dash Cam `ae458526`, `PUBLISHED` / `READY_FOR_REVIEW`, **`opportunity_decision_id = NULL`**. |
| `commerce_product_opportunities` | **0** | the workspace/RPC-facing ranked projection — empty. |
| `member_opportunities` | **0** | the generic workspace opportunity feed — empty. |
| `member_actions` | **0** | — |
| `member_business_dna` | **0** | the Ecommerce classification + `source_run_id` carrier — absent. |

- **Relationships:** the 7 decisions map to 5 distinct commerce_products. The published Dash Cam storefront is
  **not** one of the 7 decisioned products and its `opportunity_decision_id` is NULL — **0** storefront pages link
  back to any decision. So the three islands (7 decisions / 1 published storefront / 0 workspace projection) are
  only loosely connected.
- **TEST vs production:** the entire tenant is the **isolated internal COMP test tenant** ("Founder Ecommerce
  Test (GB)"). Its 7 decisions are **real (not fixtures)**; the 17 fixture decisions (is_fixture=true) belong to a
  separate synthetic tenant `aaaaaaaa-…`, not the founder. No customer data is involved.

## 5. Existing Product Opportunity runtime
Two parallel Ecommerce opportunity lineages exist in the backend:
- **Lineage A — commerce-discovery scoring:** `discovery_run → commerce_products + commerce_signals →
  score_commerce_products(source_run_id) → commerce_product_opportunities` (ranked cards) **and**
  `member_business_dna.dna_extended.commerce`. Called by `finalize_commerce_from_run`. **Never run for the
  founder's run `658216ee`** (both outputs are empty).
- **Lineage B — WPS V2 / product decision:** the evidence-backed tournament (`product_opportunity_decisions`,
  `fn_monday_top_opportunities`, `fn_run_monday_product_opportunity`). **Populated** for the founder (the 7 real
  WATCH decisions). This lineage is **not read by the workspace contract at all.**

## 6. Existing Product Decision runtime
`product_opportunity_decisions` holds the real founder decisions (bands, hard-gates, economics refs, decision =
WATCH). Surfaced today only through the Product-Decision/Product-Page-Builder path (which produced the Dash Cam),
**not** through `get_own_discovery_intelligence`.

## 7. Existing Action runtime
`member_actions` (generic quick-wins / next-stage / next-best-move) — **0 rows** for the founder. The workspace
`action_intelligence` block reads this table gated on `source_run_id = v_run`. Ecommerce "recommended actions"
also exist inside `commerce_product_opportunities.recommended_actions` (empty because Lineage A never ran).

## 8. Existing Product Page Builder / storefront connection
Fully built and working (units 004–012): `fn_storefront_publish_context`, `fn_storefront_publish` (server-derived
gate), public `storefront` edge function. The founder's Dash Cam is PUBLISHED. This path is healthy and
**independent** of the workspace opportunity feed — it does not depend on the missing projection.

## 9. Current workspace Opportunities data source (AUDIT 3)
- **Route:** `/workspace?view=opportunities` (Lovable project "Pulse Implementation" `12db6c84`).
- **Component:** `src/components/business-discovery/workspace-sections.tsx`; top-level
  `WorkspaceView = "overview" | "signals" | "opportunities" | "audience" | "content"` — **no Ecommerce/Products
  top-level view.** The Opportunities view renders `data.opportunities`; when empty it prints the exact string
  **"No ranked opportunities were produced for this analysis."**
- **Ecommerce surface:** a *nested* `EcomTab` (overview/products/competitors/suppliers) that is "Presentation-only
  projection of the persisted ecommerce intelligence (**`business_dna.extended.commerce`**) … **Appears ONLY for
  genuinely classified ecommerce businesses**." Its Products tab reads `commerce.winningProductIntelligence`.
- **RPC / DB function:** `public.get_own_discovery_intelligence()` (SECURITY DEFINER, `auth.uid()`-scoped).
- **Tables/views it reads for opportunities:** `member_opportunities` (+`opportunities`) → `opportunity_radar` /
  `decision_intelligence`; `member_actions` → `action_intelligence`; `commerce_product_opportunities` JOIN
  `commerce_products` → `commerce_opportunities`; `member_business_dna` → `business_dna`. **It never reads
  `product_opportunity_decisions`.**
- **Response contract:** `{ status, analysis_status, business_profile, business_dna, opportunity_radar,
  decision_intelligence, action_intelligence, commerce_opportunities, morning_brief, … }`.

## 10. Exact reason the browser shows zero ranked opportunities
Mechanically, inside `get_own_discovery_intelligence()`:
1. `v_run := v_dna.source_run_id`, taken from `member_business_dna`. The founder has **0** DNA rows, so `v_dna`
   is not found and **`v_run` stays NULL**.
2. `opportunity_radar` / `decision_intelligence` query `member_opportunities WHERE user_id = uid AND
   source_run_id = v_run`. With 0 rows (and `v_run` NULL) → **`[]`**. The frontend Opportunities view sees
   `opportunities.length === 0` → **"No ranked opportunities were produced for this analysis."**
3. `commerce_opportunities` is built inside `IF v_run IS NOT NULL THEN …`. Because `v_run` is NULL the entire
   commerce block is **skipped**, so even the Ecommerce field returns `[]` — and `commerce_product_opportunities`
   is empty anyway.
4. The Ecom `EcomTab` needs `member_business_dna.dna_extended.commerce`; with no DNA row it cannot classify the
   business as Ecommerce, so the Ecommerce tab does not present the existing decisions either.

So the RPC **genuinely returns zero** for both `opportunity_radar` and `commerce_opportunities` (hypothesis A is
true as a symptom), but the **root** is that the founder's real intelligence was never projected into the tables
the contract reads, and the contract is not category-aware.

## 11. Classification of the cause
**Mixed — data-linkage + contract/category-routing (not identity, not a pure frontend bug).**
- **C (separate contracts):** true — generic (`member_opportunities`) vs Ecommerce-discovery
  (`commerce_product_opportunities` / `member_business_dna.commerce`) vs product-decision
  (`product_opportunity_decisions`) are three separate contracts.
- **F (existing Ecommerce decisions not connected to the workspace):** true and primary — the 7
  `product_opportunity_decisions` are not read by `get_own_discovery_intelligence`, and Lineage-A projection was
  never generated for the founder's run.
- **D (category resolution missing):** true — the workspace classifies Ecommerce from `member_business_dna`, which
  is absent; `business_profiles.industry` is not consulted for that gate.
- **A (RPC returns zero):** true as a symptom of the above.
- **B/E/G:** not the cause (frontend reads the correct field; identity resolves; no other hidden cause found).

## 12. Existing components that should be reused (AUDIT 5 — do NOT rebuild)
| Existing capability | Current contract | Current UI/route | Missing connection |
|---|---|---|---|
| Product Decision / WPS V2 | `product_opportunity_decisions`, `fn_monday_top_opportunities` | Product-Decision / Product Page Builder | not surfaced by `get_own_discovery_intelligence` |
| Commerce opportunity scoring | `score_commerce_products` → `commerce_product_opportunities` + `member_business_dna.commerce` | `commerce_opportunities` field + `EcomTab` Products | `finalize_commerce_from_run`/`score_commerce_products` never run for run `658216ee` |
| Ecommerce workspace tab | `member_business_dna.dna_extended.commerce` | nested `EcomTab` (overview/products/competitors/suppliers) | no DNA row → tab never classifies/appears |
| Storefront publish | `fn_storefront_publish_context/publish`, `storefront` edge fn | Product Page Builder | healthy; only unlinked (`opportunity_decision_id` NULL) |
| Generic opportunity feed | `member_opportunities`, `member_actions` | `/workspace?view=opportunities` | intentionally empty for the ecom/no-store journey |
The Ecommerce presentation components (`CommerceOpportunities`, `EcomProductsTab`, `ProductOpportunityCard`) already
exist in the frontend — no rebuild required.

## 13. Minimum launch-critical fix (specification only — NOT implemented)
Connect the existing intelligence to the workspace contract for an Ecommerce business, smallest safe path:
1. **Populate Lineage A for the founder's run** by running the existing `finalize_commerce_from_run` /
   `score_commerce_products('658216ee-…')`, which writes `commerce_product_opportunities` **and**
   `member_business_dna.dna_extended.commerce` (giving the RPC a non-NULL `v_run` and the frontend its Ecommerce
   classification). This uses existing functions on the founder's real data — no synthetic opportunities.
2. **Make the workspace contract category-aware** so an Ecommerce business's opportunity feed also surfaces the
   real `product_opportunity_decisions` (Lineage B), and add a top-level Ecommerce/Products `WorkspaceView` with
   category-driven default routing (so an Ecommerce tenant lands on Product Opportunities, not the generic feed).
3. **Durably persist category** server-side at onboarding (a first-class business category), instead of the
   frontend reusing `business_description`, so the workspace no longer depends on `member_business_dna` being
   present to know the business is Ecommerce.
Item 1 alone would light up the existing Ecommerce workspace surface immediately; items 2–3 make it correct and
durable. The exact division and sequencing is the next unit's decision.

## 14. Whether Claude Code, Lovable, or both are required
**Both.**
- **Claude Code (backend):** run/route the ecom projection; make `get_own_discovery_intelligence` category-aware and
  read `product_opportunity_decisions`; add a durable category signal. (Primary effort.)
- **Lovable (frontend):** add a top-level Ecommerce/Products `WorkspaceView` and category-driven default routing so
  an Ecommerce tenant is taken to the product-opportunity surface rather than the generic Opportunities view.
- No n8n change required for the connection itself.

## 15. Security impact
**None in this audit** (read-only). The eventual fix must preserve `auth.uid()` scoping, deny-all RLS + SECURITY
DEFINER RPCs, tenant isolation, and the server-authoritative storefront publish/entitlement gates. Surfacing
`product_opportunity_decisions` must stay tenant-scoped by `tenant_id = auth.uid()`.

## 16. Data impact
**None.** No rows created, altered, or deleted; all statements were reads. The observed emptiness is genuine
production state, not a side effect of this audit.

## 17. Recommended implementation order
1. Backend: run existing `finalize_commerce_from_run` / `score_commerce_products` for the founder's run to
   populate the Lineage-A projection (proves the surface lights up with real data). →
2. Backend: category-aware `get_own_discovery_intelligence` (Ecommerce reads `product_opportunity_decisions`;
   decouple `v_run` resolution from the DNA row for the ecom journey). →
3. Backend: durable server-owned business category at onboarding. →
4. Lovable: top-level Ecommerce/Products view + category default routing. →
5. E2E re-verify with the founder tenant; keep the storefront/entitlement gates unchanged.

## 18. FINAL VERDICT
**`READY_FOR_CONNECTION_FIX`.** The Ecommerce intelligence, product decisions, scoring functions, Ecommerce
workspace components, and storefront publishing all already exist. The founder sees zero opportunities because
(a) the commerce-discovery projection (`commerce_product_opportunities` + `member_business_dna.dna_extended.commerce`)
was never generated for the founder's discovery run, so `get_own_discovery_intelligence` resolves `v_run = NULL` and
returns empty opportunity + commerce feeds; (b) the workspace contract never reads the real
`product_opportunity_decisions`; and (c) the workspace classifies Ecommerce from the absent DNA row rather than from a
durable category. Nothing needs to be rebuilt or fabricated — the existing capabilities need to be connected and made
category-aware.

STOP. Audit only — fix not implemented; no synthetic opportunities generated; no new roadmap phase started.

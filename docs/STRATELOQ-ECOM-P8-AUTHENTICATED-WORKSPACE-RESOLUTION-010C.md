# STRATELOQ-ECOM-P8-AUTHENTICATED-WORKSPACE-RESOLUTION-010C

**VERDICT: `PASS`.** The authenticated test tenant now resolves into a **ready** Ecommerce
workspace and the publishing E2E can proceed. Root cause: the approved isolated test tenant
was **missing its `discovery_state` bootstrap record**, so the workspace-readiness contract
(`analysis_status`) resolved NULL → "workspace being prepared". A secondary robustness gap made
the business profile resolve only via `application_id`. Both fixed with the smallest safe
corrections (isolated test-data repair + one systemic function robustness fix). No auth/RLS
weakened, no readiness gate bypassed, no founder account hardcoded, no payment, no new tenant,
no customer data touched, €0.

---

## 1. Exact reason /workspace showed "being prepared"
The workspace-readiness contract (`get_own_discovery_intelligence().analysis_status`) is sourced
from the member's `discovery_state` row. Healthy/ready tenants carry `analysis_status = 'ready'`.
The ecommerce test tenant (member `4bc6b405…`) had **0 `discovery_state` rows** (it has a completed
`discovery_run` but no state row), so `analysis_status` resolved NULL → the frontend held it in
"ALMOST READY / workspace being prepared".

## 2. Workspace readiness contract
`/workspace` gates on the authenticated `get_own_discovery_intelligence()` — specifically
`analysis_status = 'ready'` (with `status='ok'`). Reference tenants confirm: `support+demo` and
`cleantechbusiness` both carry `discovery_state.analysis_status='ready'`; `not_started`/NULL ⇒ preparing.

## 3. Test tenant state
`actioncorllen+ecom@gmail.com` — auth `7c8ddf9d…` (exists), member `4bc6b405…` (active), business
profile "Founder Ecommerce Test (GB)" (valid, by `user_id`), eligible Dash Cam storefront `ae458526`
(GENERATED, VIABLE, claim-clean, assets available). Missing: the `discovery_state` bootstrap row.

## 4. Missing/incorrect state discovered
(a) No `discovery_state` row → readiness NULL. (b) `member.application_ref` is NULL while the business
profile is keyed by `application_id`, so `get_own_discovery_intelligence` resolved the business as null.

## 5. Correction made
- **(a) Test-data repair (isolated tenant only):** created the canonical `discovery_state` bootstrap
  row for member `4bc6b405…` with `analysis_status='ready'`, `status='not_started'` (matching healthy
  tenants). Idempotent insert; no fabricated intelligence.
- **(b) Systemic fix (`mig_238`):** `get_own_discovery_intelligence` now falls back to resolving the
  caller's OWN business profile by `user_id` when the `application_id` lookup misses (the ownership
  guard is unchanged; `business_profiles.user_id` is authoritative). Helps any member whose
  `application_ref` is null, not just the test tenant.

## 6. Test-data-only vs systemic
(a) is **test-data-only** (one bootstrap row for the isolated approved test tenant). (b) is a
**systemic** robustness correction to a shared function. No founder-account special-casing anywhere.

## 7–11. Auth / member / business / Ecommerce category / workspace-ready (verified, impersonating the real tenant)
- Auth user resolves (`auth.uid()` = the tenant); member binding active.
- **Business resolves:** `business_name = "Founder Ecommerce Test (GB)"`.
- **Ecommerce category resolves:** `industry = "Broad Ecommerce Opportunity Discovery"`.
- **Workspace ready:** `status=ok`, `analysis_status='ready'`, `workspace_ready=true`.

## 12–13. Publish-context + Dash Cam automatic discovery
`fn_storefront_publish_context()` → `status=ok`, count 1, `page_id=ae458526`,
`product_title="3 Channel Dash Cam (Front 1080P / Inner 480P / Rear 480P)"`, `publish_ready=true` —
discovered automatically, **no manual page ID, no browser-constructed gate inputs**.

## 14. Anonymous denial
Anonymous `get_own_discovery_intelligence()` → `status='unauthenticated'`; `fn_storefront_publish_context`
and publish/unpublish have no anon EXECUTE. **PASS.**

## 15. Cross-tenant denial
A different authenticated tenant (`support+demo`): `get_own_discovery_intelligence` returns its OWN
business ("Pulse Demo Coffee"), does **not** see the ecom business, `publish_context` count 0, does
not see `ae458526`. **PASS.**

## 16. RLS/security result
No RLS weakened; no readiness gate bypassed (the canonical bootstrap record was created, not skipped).
Functions remain SECURITY DEFINER with `search_path=''`; grants unchanged (authenticated + service_role;
anon none). Ownership guard on business profile preserved. Security advisories unchanged (5 baseline).

## 17. Regressions
Storefront: runtime **38**, publish **9**, branding **8**, lifecycle **10** = **65/65 PASS**. Healthy
tenant workspace/business resolution unaffected (demo tenant still `ok` + correct business). Anon/cross
-tenant isolation intact.

## 18. Files / migrations changed
- `supabase/migrations/mig_238_own_intelligence_business_profile_user_id_fallback.sql` (systemic function fix).
- `docs/STRATELOQ-ECOM-P8-AUTHENTICATED-WORKSPACE-RESOLUTION-010C.md` (this report).
- Isolated test-tenant data: one `discovery_state` row inserted for member `4bc6b405…` (not a migration; tenant-specific bootstrap data).

## 19. Production / customer mutation status
Only the **isolated approved test tenant** was written: one `discovery_state` bootstrap row for
`actioncorllen+ecom`. No real customer data created or altered; no fabricated intelligence. The Dash Cam
page and all other tenants were read-only.

## 20. Cost
**€0.**

## 21. Commit / divergence
See delivery message for hash; branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

## 22. Exact founder action after correction
**FOUNDER ACTION:** In the Lovable preview (already signed in as `actioncorllen+ecom@gmail.com`), click
**"Check again"** (or refresh). The workspace now resolves to the real Ecommerce workspace. Open the
Product Page Builder → the **"3 Channel Dash Cam"** storefront loads automatically → **Review** →
**Publish** → optionally **View live** / **Unpublish** / **Publish again**. (The Dash Cam is currently
already PUBLISHED from prior backend tests; you can Unpublish then Publish again to exercise the full
cycle.) No password/token/ID needed by Claude.

## 23. Final verdict
**`PASS`.** Authenticated test user → member resolves → business resolves → Ecommerce category resolves →
workspace readiness resolves (ready) → publish-context accessible → Dash Cam discovered automatically;
anonymous + cross-tenant denied; RLS intact; 65/65 storefront regression; no advisory delta; no customer
data touched; €0. Founder can now complete the live publishing E2E by refreshing the workspace.

STOP.

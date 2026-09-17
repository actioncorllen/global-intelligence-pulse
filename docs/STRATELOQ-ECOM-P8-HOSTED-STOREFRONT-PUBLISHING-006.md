# STRATELOQ-ECOM-P8-HOSTED-STOREFRONT-PUBLISHING-006

**VERDICT: `PASS`.** The safe server-side Pulse-hosted publishing lifecycle
(Approved → Review → server pre-publish validation → Publish → stable public URL →
View live → Unpublish → republish) **already exists and is hardened** across
`mig_227` (state machine), `mig_230` (`fn_storefront_publish` + public renderer),
and `mig_229` (grant lockdown). The audit found **no behavioral gap** — every PASS-gate
requirement is enforced server-side with persisted data and fails closed. The only
change is **additive regression coverage** (`mig_236`: a self-cleaning, service_role-only
lifecycle selftest) for the transitions the unit closes that lacked a committed test.
No storefront redesign, no builder rebuild, no payments/Shopify/Woo/advertising, no
RLS weakening, no real customer storefront published, €0.

> STOP after this unit.

---

## 1. Architecture audit
- **Draft persistence:** `commerce_product_pages` (+ `commerce_store_projects`), with `runtime_contract`, `page_model`, `review_state`, `publication_state`, `destination`, `published_url`.
- **Lifecycle/state model:** `fn_storefront_transition_state` (DRAFT → IN_REVIEW → APPROVED → PUBLISHED → ARCHIVED, with safe reversals incl. PUBLISHED → APPROVED = unpublish). Tenant-guarded; never bypasses claim safety.
- **Publish transition:** `fn_storefront_publish(page_id, gate_inputs, actor)` — requires APPROVED, re-runs TEST/claim/asset/destination gates fail-closed, mints stable slug + destination URL, sets PUBLISHED, checkout-not-configured, public HTTP endpoint founder-gated.
- **Unpublish:** `fn_storefront_transition_state(page,'APPROVED')` from PUBLISHED → publication_state UNPUBLISHED, published_url NULL; page/draft preserved.
- **Public slug:** `p` + 12 hex of the page uuid (stable, unique, URL-safe, non-secret, not an auth credential); stored on `commerce_store_projects.public_route`.
- **Public renderer:** `fn_public_storefront_render(slug)` — allowlist-only, PUBLISHED-only, secret-stripped; NOT_FOUND otherwise.
- **Tenant ownership + RLS:** SECURITY DEFINER functions compare `coalesce(auth.uid(), p_actor)` to `page.user_id`; `commerce_product_pages`/`product_opportunity_decisions` are RLS deny-all to clients (access only via hardened RPCs).
- **Pre-publish validation:** TEST eligibility (`fn_storefront_test_eligibility`), claim safety (persisted `claim_scan_clean`), asset safety (`fn_resolve_storefront_assets`), destination (PULSE_STORE only for hosted publish).
- **Checkout:** always `CHECKOUT_NOT_CONFIGURED` / `BLOCKED_EXTERNAL_CHECKOUT_PROVIDER` (no fake checkout).
- **Existing-store:** `fn_storefront_set_destination` returns `BLOCKED_EXTERNAL_SHOPIFY_CONNECTION` without a connected store; hosted publish of EXISTING_STORE → `BLOCKED_DESTINATION`.
- **Selftests/RPCs:** `fn_storefront_publish_selftest` (9), `fn_storefront_runtime_selftest` (38), `fn_storefront_branding_selftest` (8).
- **Product Decision → storefront:** page created only via the gated `fn_generate_storefront_runtime`; `opportunity_decision_id` column exists but is NULL in the live flow (the decision gate is enforced at generation + re-run at publish, not via a stored FK link).

## 2. Existing components reused
All of the above — no parallel publishing system created.

## 3. Genuine gaps discovered
**None behavioral.** One considered hardening (verify a linked Product Decision's ownership/eligibility at publish) was found to be **dead code in practice** — `opportunity_decision_id` is NULL on every page including the published one — so it was **not** added (would be untested, inert surface; the decision gate is already enforced at generation and re-run at publish). The only real gap was **missing durable regression coverage** for unpublish / post-unpublish NOT_FOUND / draft preservation / republish / invalid-destination / unsafe-claims.

## 4. Exact changes made
Added `fn_storefront_publish_lifecycle_selftest()` — a self-cleaning, service_role-only regression suite (10 cases) covering the lifecycle transitions above. No change to any publish/render/transition function.

## 5. Files changed
- `supabase/migrations/mig_236_storefront_publish_lifecycle_selftest.sql`
- `docs/STRATELOQ-ECOM-P8-HOSTED-STOREFRONT-PUBLISHING-006.md`

## 6. Migrations/functions changed
- New: `public.fn_storefront_publish_lifecycle_selftest()` (SECURITY DEFINER, `search_path=''`, service_role-only). No existing function modified.

## 7. Publish authorization result
Server-side: publish denied unless `coalesce(auth.uid(),p_actor) = page.user_id`. Frontend state is never sufficient — anon has **no EXECUTE** on `fn_storefront_publish` (`anon_can_publish=false`); authenticated callers are bound to their own `auth.uid()` (a supplied `p_actor` cannot override it). **PASS.**

## 8. Pre-publish validation result
Server-side, fail-closed: APPROVED required (`NOT_APPROVED`), TEST eligibility (`BLOCKED_TEST_ELIGIBILITY`), claim safety from persisted contract (`BLOCKED_CLAIM_SAFETY`), asset safety (`BLOCKED_ASSET_SAFETY`), destination (`BLOCKED_DESTINATION`). **PASS.**

## 9. Evidence-safety result
Claim safety is read from the **persisted** runtime contract (set under the gated generator), not caller input; a contract with `claim_scan_clean=false` (or missing → coalesced false) blocks publish. A frontend edit cannot turn missing evidence into claims. **PASS.**

## 10. Public-contract leakage result
`fn_public_storefront_render` is allowlist-only. Verified on the **real published storefront** (`pae4585263fd2`, unit 004) and by the publish selftest `renderer_no_secrets`: no explainability, conversion_strategy, selection scores/reasons, supplier identifiers, supplier/internal economics, ad_match_ref, security metadata, member/tenant info. **PASS.**

## 11. Slug / public URL result
`p`+12-hex slug: stable, unique, URL-safe, non-secret, not an authorization credential, derived from a non-sensitive page uuid (not a private/tenant id); collisions astronomically unlikely and namespaced per store project. Regex-verified (`^p[0-9a-f]{12}$`). **PASS.**

## 12. Owner publish test
`owner_publish_ok` → ok / PUBLISHED, stable URL minted. **PASS.**

## 13. Cross-tenant publish denial
`publish_cross_tenant_denied` (publish selftest) → `DENIED_CROSS_TENANT`. **PASS.**

## 14. Unauthenticated publish denial
`anon` has no EXECUTE on `fn_storefront_publish` (grant model). **PASS.**

## 15. Draft-public-access test
`renderer_notfound_for_draft` (publish selftest) → NOT_FOUND for a DRAFT slug. **PASS.**

## 16. Published public-render test
`render_published_ok` → OK, customer-safe payload, checkout `CHECKOUT_NOT_CONFIGURED`. **PASS.**

## 17. Owner unpublish test
`owner_unpublish_ok` → ok, publication_state UNPUBLISHED. **PASS.**

## 18. Cross-tenant unpublish denial
`unpublish_cross_tenant_denied` → `DENIED_CROSS_TENANT`. **PASS.**

## 19. Post-unpublish NOT_FOUND test
`render_notfound_after_unpublish` → NOT_FOUND on the same slug. **PASS.**

## 20. Draft preservation result
`draft_preserved_after_unpublish` → page row intact, `review_state=APPROVED`, `page_model` intact. **PASS.**

## 21. Edit/republish behaviour
Unpublish returns to APPROVED (draft/config preserved); `republish_ok` re-runs the full publish gate and re-publishes. Safe published → edit → review → validation → republish lifecycle preserved (no silent unsafe push to live). **PASS.**

## 22. Existing-store fail-closed result
Hosted publish of `EXISTING_STORE` → `BLOCKED_DESTINATION`; `fn_storefront_set_destination` SHOPIFY without a CONNECTED store → `BLOCKED_EXTERNAL_SHOPIFY_CONNECTION`. No external publication faked. **PASS.**

## 23. Checkout-disabled result
Publish + public render both report `CHECKOUT_NOT_CONFIGURED` / `BLOCKED_EXTERNAL_CHECKOUT_PROVIDER`, add-to-cart non-functional; no fake checkout, no card collection. **PASS.**

## 24. Regression test counts/results (actual discovered baseline)
- `fn_storefront_runtime_selftest`: **38/38 PASS**
- `fn_storefront_publish_selftest`: **9/9 PASS**
- `fn_storefront_branding_selftest`: **8/8 PASS**
- `fn_storefront_publish_lifecycle_selftest` (new): **10/10 PASS**
- Total storefront regression: **65/65 PASS.**

## 25. RLS/security verification
Grants: `fn_storefront_publish`, `fn_public_storefront_render`, `fn_storefront_transition_state` → authenticated + service_role; generators/selftests → service_role only; anon → none. All SECURITY DEFINER functions keep `search_path=''`. Security advisories unchanged (5 pre-existing baseline; `mig_236` added none). **PASS.**

## 26. Production/customer mutation status
No production/customer data mutated. Inline verification ran in a rolled-back transaction; the committed selftest is self-cleaning (page count returned to baseline). The one pre-existing published storefront (owned by the ecommerce **test** tenant) was not touched. **No real customer storefront published.**

## 27. Test cleanup
Confirmed: `commerce_product_pages` count returned to the pre-test baseline (2). No residue.

## 28. Cost
**€0.**

## 29. Intentionally deferred work
Anonymous public HTTP endpoint deploy (founder-gated, `public_endpoint_state=PENDING_FOUNDER_APPROVAL_PUBLIC_ENDPOINT`); payments/checkout; Shopify/WooCommerce publishing; Lovable publishing UI (backend PASS delivered for it to follow).

## 30. Final verdict
**`PASS`** — safe server-side hosted publishing lifecycle verified end to end (publish, stable public URL, published render, draft-not-public, unpublish, post-unpublish NOT_FOUND, draft preservation, republish), authorization + validation are server-side and fail closed, evidence safety and public/private separation hold across publishing, existing-store and checkout are honestly fail-closed, 65/65 regression, RLS/security intact, no customer storefront published, €0. Durable regression coverage added (`mig_236`); no behavioral change required.

STOP.

# STRATELOQ-ECOM-P8-AUTHENTICATED-PUBLISHING-E2E-TEST-SESSION-010

**VERDICT: `PASS` (backend) — `FOUNDER ACTION REQUIRED` (one normal sign-in) to run the live E2E.**

The `BLOCKED_AUTHENTICATED_TEST_SESSION` boundary is resolved at the backend. The real
gap was a missing **authenticated product contract**: the merchant frontend had no way to
obtain its own `page_id` + publish eligibility (the storefront table is RLS deny-all to
clients), and publish required the browser to **construct gate inputs** (forbidden). Both are
now closed with the smallest safe correction, reusing the verified publish lifecycle. No
auth/RLS weakened, no anon grant, no service_role exposed, no new tenant, no customer data
mutated, €0. The only remaining step is the founder signing into the Lovable preview with the
approved Ecommerce test account through the normal product sign-in.

---

## 1–5. Approved test tenant / auth / member / profile / auth-path
- **Tenant:** `actioncorllen+ecom@gmail.com` — auth_user_id `7c8ddf9d-172c-4a89-a402-bb7066228b61`, member `4bc6b405-2e6a-4fd0-a0cf-b2c409fd4177` (active), business profile "Founder Ecommerce Test (GB)". The founder-approved isolated Ecommerce test tenant from prior E2E units; reused, not recreated.
- **Auth path:** the same Supabase Auth used by the Strateloq frontend (this account authenticates as `authenticated` with `auth.uid()` = the tenant). No password handled or requested.

## 6–7. Eligible Product Decision / storefront
- The tenant already owns **one eligible, generated storefront** (`ae458526-3fd2-47e0-a613-3da7b7f92f11`, FEATURE_TECHNOLOGY, PULSE_STORE, currently PUBLISHED). Its persisted runtime contract shows `generation_state=GENERATED`, `economics_state=VIABLE`, `claim_scan_clean=true`, `assets_state=ASSETS_AVAILABLE` — genuinely publish-eligible. **No fixture needed.**

## 8–9. pageId + gate-input acquisition (the blocker root cause)
- **Before:** `commerce_product_pages` is RLS deny-all to clients, and there was **no authenticated RPC** returning the merchant's own page(s). `fn_storefront_publish` required a caller-supplied `gate_inputs` object. So the frontend could not obtain `page_id` nor a safe gate without DB console / hardcoded IDs / browser-constructed gates — exactly what it (correctly) refused to do.
- **After:** `fn_storefront_publish_context()` returns the caller's own pages with `page_id`, states, destination, `publish_ready` + `publish_blockers`, `slug`, published-only `destination_url`, and the exact `publish_call`/`unpublish_call` (page_id only). `fn_storefront_publish` now derives eligibility **server-side** from persisted state when no gate is supplied.

## 10. Frontend/workspace contract result
Authenticated, tenant-scoped, no manual copying:
- **List/context:** `supabase.rpc('fn_storefront_publish_context')` → `{ storefronts: [{ page_id, product_title, review_state, publication_state, destination_kind, publish_ready, publish_blockers, slug, destination_url, checkout_state }] }`.
- **Publish:** `supabase.rpc('fn_storefront_publish', { p_page_id })` → `{ status:'ok', publication_state:'PUBLISHED', destination_url, eligibility_source:'SERVER_DERIVED_PERSISTED', checkout_state:'CHECKOUT_NOT_CONFIGURED' }`.
- **Unpublish:** `supabase.rpc('fn_storefront_transition_state', { p_page_id, p_target_state:'APPROVED' })`.
- **View live:** `fetch(destination_url + '?format=json')` (public, CORS-enabled in 008).
Verified (impersonating the real tenant): context returns page `ae458526` with `publish_ready=true`, `publish_blockers=[]`, real `destination_url`, and **no internal leakage** (`leaks_internal=false` — no user_id / supplier_product_id / landed / scoring / selection / explainability / ad_match / service_role).

## 11. Gaps discovered
(1) missing authenticated page/publish-context contract; (2) publish depended on browser-constructed gate inputs. Both are genuine launch-critical product-integration gaps; both closed.

## 12. Changes made
- Added `fn_storefront_publish_context(page_id?)` — authenticated, tenant-scoped read (page identity + eligibility, no sensitive fields).
- Made `fn_storefront_publish` gate-input **optional**: when the browser passes no gate (no `recommendation` key), eligibility is **server-derived** from persisted `generation_state=GENERATED` + `economics_state ∈ {VIABLE,POSITIVE}`, then the same persisted claim/asset/destination gates run (fail-closed). Explicit-gate callers are unchanged (all selftests keep exact behavior).

## 13. Files / migrations / functions changed
- `supabase/migrations/mig_237_authenticated_publish_context_and_derived_gate.sql`
- New: `fn_storefront_publish_context(uuid)`. Modified: `fn_storefront_publish(uuid,jsonb,uuid)` (optional/derived gate; same type signature, grants preserved).

## 14. RLS / security result
`fn_storefront_publish_context` and `fn_storefront_publish` = SECURITY DEFINER, `search_path=''`, EXECUTE = authenticated + service_role; **anon has none** (`anon_ctx=false`). Table RLS deny-all unchanged. auth.uid()-bound; frontend-supplied actor cannot override authenticated identity. No new security advisory (5 baseline before and after).

## 15. Cross-tenant result
Context as a different authenticated tenant → `count=0`, does not see `ae458526`. Publish with a non-owner actor (page_id only) → `DENIED_CROSS_TENANT`. **PASS.**

## 16. Lovable real-E2E readiness
**READY** pending one normal sign-in. With an authenticated session for the approved test account, Lovable can run the full chain using only page_id: context → Review → Publish (server-derived) → real `destination_url` → public JSON render → Unpublish → 404 → draft preserved → Publish again. Server-derived publish proven end-to-end on a self-cleaning synthetic tenant: derived publish ok (`SERVER_DERIVED_PERSISTED`), render ok, cross-tenant denied, unpublish→NOT_FOUND, republish ok, and fail-closed on non-viable economics (`REJECT_ECONOMICS_NOT_VIABLE`) and not-generated (`REJECT_NOT_GENERATED`).

## 17. Exact founder action required
**FOUNDER ACTION REQUIRED**
1. Open the Lovable preview of the Strateloq app.
2. Click **Sign in** and sign in with the approved Ecommerce test account **`actioncorllen+ecom@gmail.com`** using the normal Strateloq sign-in (the usual method for that account; if it is magic-link/OTP, the link/code arrives in your `actioncorllen@gmail.com` inbox via the `+ecom` alias). Do **not** send the password or any code to Claude.
3. Go to the Product Page Builder → the "3 Channel Dash Cam" storefront (it loads automatically via the publish-context contract — no ID to copy) → **Review** → **Publish** (then optionally **View live**, **Unpublish**, **Publish again**).
_(If the Lovable app is not yet pointed at production, also complete the 008 config: Supabase URL `https://nxaunmyihhjixxxljcqt.supabase.co` + the project **publishable** key — the public `sb_publishable_…` browser key from Supabase → API settings.)_

## 18. Regression counts
Runtime **38**, publish **9**, branding **8**, lifecycle **10** = **65/65 PASS** (explicit-gate path unchanged). Plus new server-derived publish + context checks all pass.

## 19. Production / customer mutation status
**None.** The real tenant page `ae458526` was only read (still PUBLISHED, untouched). The server-derived verification ran on a throwaway synthetic tenant inside a rolled-back transaction (nothing persisted). Total storefront pages unchanged (2). No customer storefront published.

## 20. Temporary fixture status
No fixture created; the eligible test storefront already existed. The synthetic derive-path test self-rolled-back (no residue).

## 21. Cost
**€0.**

## 22. Commit / divergence
See delivery message for hash; branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

## 23. Final verdict
**`PASS` (backend) + `FOUNDER ACTION REQUIRED`.** The authenticated product contract now carries page identity and publish eligibility safely; publish/unpublish work by `page_id` alone with a server-derived, fail-closed gate; RLS/tenant isolation and public-renderer safety intact; 65/65 regression; no advisory delta; €0; no customer data touched. The single remaining step is the founder's normal sign-in to the Lovable preview with the approved Ecommerce test account.

STOP — awaiting founder sign-in.

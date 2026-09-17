# STRATELOQ-ECOM-P8-PUBLIC-STOREFRONT-ENDPOINT-ACTIVATION-008

**VERDICT: `PASS`.** The production-capable public HTTP boundary is active and the full
real lifecycle was proven over real HTTP: authenticated owner publish → canonical public
address → **anonymous HTTP GET returns a customer-safe storefront** → owner unpublish →
**same address returns 404** → draft preserved → republish. The only change was adding
**CORS + OPTIONS** to the already-deployed anonymous public `storefront` edge function so a
browser frontend (Strateloq/Lovable) can fetch the public JSON contract cross-origin. No
publishing architecture rebuilt, no payments/checkout/Shopify/Woo, no RLS weakened, no
service-role exposed, no real customer storefront published, no DNS change, €0.

> STOP after this unit.

---

## 1. Architecture discovered
- **Publish boundary:** `fn_storefront_publish(page_id, gate_inputs, actor)` — SECURITY DEFINER RPC, EXECUTE = authenticated + service_role. Reachable over HTTP as `POST {SUPABASE_URL}/rest/v1/rpc/fn_storefront_publish` with the user JWT (PostgREST). auth.uid()-bound; APPROVED-required; fail-closed TEST/claim/asset/destination gates.
- **Unpublish boundary:** `fn_storefront_transition_state(page_id,'APPROVED',actor)` — authenticated RPC; PUBLISHED→APPROVED sets publication_state UNPUBLISHED, published_url NULL; draft preserved.
- **Public storefront:** `storefront` Edge Function (anonymous, `verify_jwt=false`) → `fn_public_storefront_render(slug)` (allowlist-only, PUBLISHED-only, secret-stripped). Path `GET {SUPABASE_URL}/functions/v1/storefront/{slug}`; `?format=json` (or `Accept: application/json`) returns the JSON contract, else server-rendered HTML.
- **Slug / public URL:** `p`+12-hex from the page uuid; `published_url = {SUPABASE_URL}/functions/v1/storefront/{slug}`, minted by publish and stored on the page + store project (`public_route`). Stable, unique, URL-safe, non-secret.
- **Project:** `nxaunmyihhjixxxljcqt` — `SUPABASE_URL = https://nxaunmyihhjixxxljcqt.supabase.co`.

## 2. Endpoint/service deployment state before work
- `storefront` edge function: **already deployed**, status ACTIVE, **version 4**, `verify_jwt=false`. It already supported the JSON contract but had **no CORS headers / no OPTIONS handler**.
- Publish/unpublish: already live as authenticated RPCs (no separate edge function; none needed).

## 3. Blocker root cause
Lovable's "no publish endpoint responds here" has two parts: (a) the production publish/unpublish are **RPCs**, not a named edge function, and the public render endpoint, while deployed, **could not be fetched cross-origin by the browser app** (no CORS) — so the app could not exercise/verify real publishing from its own origin; and (b) the frontend must be pointed at this production project with its publishable key (config). This unit fixes (a) and supplies the exact contract + config for (b).

## 4. Existing functions/endpoints reused
`fn_storefront_publish`, `fn_storefront_transition_state`, `fn_public_storefront_render`, the `storefront` edge function, existing slug architecture, existing RLS + grant model. No parallel endpoint created.

## 5. Exact changes made
Added to the `storefront` edge function only: wildcard **CORS for the public read** (`Access-Control-Allow-Origin: *`, `GET, HEAD, OPTIONS`, allowed headers `authorization, apikey, content-type, accept`, max-age 86400) and an **OPTIONS 204 preflight** handler. No change to auth, slug validation, the renderer, secret-stripping, or the published-only gate.

## 6. Deployment performed
Redeployed `storefront` edge function with `verify_jwt=false` preserved.

## 7. Deployed function/version
`storefront` → **version 5** (id `b25a9480-d5c8-4ccf-8f70-da4842087c99`), ACTIVE, `verify_jwt=false`.

## 8. CORS configuration result
Public read endpoint returns CORS headers on GET/HEAD and answers OPTIONS with 204. Wildcard is correct here: it is a public, anonymous, read-only endpoint returning only published, secret-stripped data (no credentials/cookies). Authenticated mutation (publish/unpublish) is **not** wildcarded — it stays on the authenticated Supabase RPC path.

## 9. Authentication result
Publish/unpublish authenticated-only (anon has no EXECUTE: `anon_can_publish=false`, `anon_can_unpublish=false`); auth.uid()-bound (frontend-supplied actor cannot override). Public read anonymous only through the strict renderer. Service-role used only server-side inside the edge function, never returned to the browser.

## 10. Owner publish REAL boundary test
Isolated TEST fixture (throwaway tenant `…0e2e08`) published via `fn_storefront_publish` → `ok`, PUBLISHED, canonical `published_url` minted. **PASS.**

## 11. Non-owner publish denial
`fn_storefront_publish` with a different actor → `DENIED_CROSS_TENANT` (publish selftest). **PASS.**

## 12. Unauthenticated publish denial
`anon` has no EXECUTE on `fn_storefront_publish`; the edge boundary is read-only (publish is not anonymous). **PASS.**

## 13. Canonical public URL result
`https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/storefront/p421fe92a874c` — returned by the publish response (`slug` + `destination_url`), no client-side guessing required. **PASS.**

## 14. Anonymous published-render result (REAL HTTP)
Real HTTP GET (from Supabase's network via `pg_net`, sandbox egress to `*.supabase.co` is proxy-blocked) of `…/storefront/p421fe92a874c?format=json` → **HTTP 200, `application/json`**, `{"status":"OK","storefront":{…}}` with customer-safe copy (hero, benefits, shipping, trust disclaimers, faq, checkout disabled). Unknown slug → **HTTP 404**. **PASS.**

## 15. Public allowlist / leakage result (REAL HTTP body)
The real 200 JSON body contained **none** of: user_id, tenant, supplier_product_id, economics/landed cost, scoring/selection, explainability/conversion_strategy, ad_match, decision_classification, secrets/service_role. `CHECKOUT_NOT_CONFIGURED` present. **PASS.**

## 16. Owner unpublish REAL boundary test
`fn_storefront_transition_state(page,'APPROVED',owner)` → `ok`, publication_state UNPUBLISHED. **PASS.**

## 17. Post-unpublish result (REAL HTTP)
Real HTTP GET of the **same** slug after unpublish → **HTTP 404** (`No published storefront exists`). **PASS.**

## 18. Draft preservation result
After unpublish: page row intact, `review_state=APPROVED`, `page_model.product_title` preserved. **PASS.**

## 19. Republish result
`fn_storefront_publish` on the same page after unpublish → `ok`, PUBLISHED. **PASS.**

## 20. Frontend contract compatibility
Publish response provides authoritative fields for every 007 UI state: `status` (`ok` / `NOT_APPROVED` / `BLOCKED_TEST_ELIGIBILITY` / `BLOCKED_CLAIM_SAFETY` / `BLOCKED_ASSET_SAFETY` / `BLOCKED_DESTINATION` / `DENIED_CROSS_TENANT` / `PAGE_NOT_FOUND`), `publication_state`, `slug`, `destination_url`, `checkout_state`, `public_endpoint_state`. Public GET returns `{status: OK|NOT_FOUND, storefront}`. This maps cleanly to Publish / Publishing / Published / View live / Copy link / Unpublish / Publish again / Validation required / Connection required / Endpoint unavailable. No UI redesign; no backend logic duplicated.

## 21. Lovable 007 remaining blocker status
**CLEARABLE.** The real reachable boundary now exists and is contract-compatible + CORS-enabled. Lovable replaces its simulated publishing state with: `supabase.rpc('fn_storefront_publish', { p_page_id, p_gate_inputs })` and `supabase.rpc('fn_storefront_transition_state', { p_page_id, p_target_state: 'APPROVED' })` for unpublish, using the user session; "View live"/verify fetches `destination_url + '?format=json'`. Requires the app to point at project `nxaunmyihhjixxxljcqt` with its **publishable** key (see §28 founder note).

## 22. Regression counts/results
Runtime **38/38**, publish **9/9**, branding **8/8**, lifecycle **10/10** = **65/65 PASS** (baseline unchanged).

## 23. RLS/security result
Grants intact (publish/unpublish authenticated+service_role; renderer authenticated+service_role for direct RPC; anon reaches the renderer only via the edge function's server-side service-role call). RLS deny-all on storefront tables preserved. **PASS.**

## 24. Security advisory delta
**No change** — 5 pre-existing baseline lints before and after (edge-function deploy creates no DB objects/grants). No new advisory introduced.

## 25. Production/customer mutation status
No customer data mutated. Only an isolated throwaway TEST fixture was created, published, unpublished and deleted. The one pre-existing published storefront (owned by the ecommerce **test** tenant) was not touched. No real customer storefront published.

## 26. Temporary fixture cleanup
Fixture fully removed: 0 pages / 0 projects for the test tenant; total pages back to baseline (2); the test slug now resolves NOT_FOUND.

## 27. Cost
**€0.** Reused existing Supabase edge-function infrastructure; no new paid service.

## 28. Deferred items / founder note
- **Founder config (not a code gap):** point the Lovable app's Supabase client at `https://nxaunmyihhjixxxljcqt.supabase.co` with the project's **publishable** key (Supabase → Project Settings → API; the `sb_publishable_…` key — a public browser key, safe to embed). This is the remaining wiring for Lovable to exercise the real service; no secret is committed to the repo.
- **Custom domain for HTML rendering (founder DNS decision, deferred):** the default `*.supabase.co/functions/v1` domain rewrites HTML page responses to `text/plain` (platform anti-abuse), so the pretty HTML view requires a Supabase Pro custom domain OR the frontend rendering the JSON contract (recommended, now CORS-enabled). No DNS changed in this unit.
- Payments/checkout, Shopify/WooCommerce publishing, Ad Studio, campaigns — out of scope, untouched.

## 29. Commit / divergence
See commit hash in the delivery message; branch `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.

## 30. Final verdict
**`PASS`** — public storefront endpoint activated (CORS + OPTIONS on the anonymous read-only function), full publish → real public address → anonymous customer-safe render → unpublish → 404 lifecycle proven over **real HTTP**, no leakage, authenticated + fail-closed publishing preserved, 65/65 regression, no advisory delta, no customer storefront published, fixture cleaned up, €0. The single Lovable-007 blocker is cleared at the backend; remaining item is founder env wiring (publishable key), not a code gap.

STOP.

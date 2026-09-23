# STRATELOQ-016C — Meta Facebook Organic OAuth Connection

**FINAL STATUS: `016C_BLOCKED` — implementation complete in source; blocked on DEPLOYMENT
of the callback (and live verification), which cannot be performed from the build
environment. Secure dynamic token storage is NOT the blocker (Supabase Vault is present
and used).**

Builds the real, secure Meta Facebook **ORGANIC** connection layer on top of the 016B
foundation: OAuth initiation, callback, authorization-code exchange, Page discovery,
Page-token acquisition, capability derivation, connection persistence, non-publishing
verification, and disconnect/revoke. **No publishing executor. No post is ever created,
edited, or deleted. No autonomous posting. No Meta advertising capability.** Organic
(`connection_type = ORGANIC`) stays strictly separate from advertising.

---

## A. Files / migrations / functions added or changed

**Migration**
- `supabase/migrations/mig_292_meta_facebook_organic_oauth.sql`
  - Table `social_oauth_states` (single-use, expiring, tenant/user-bound; **hash-only** at rest; FORCE RLS, deny-by-default).
  - Vault wrappers (service_role only): `fn_social_secret_put`, `fn_social_secret_clear`, `fn_social_secret_read`.
  - Contracts: `fn_social_required_scopes`, `fn_social_scope_subset_ok`, `fn_social_capabilities_from_meta_tasks`.
  - Lifecycle RPCs: `fn_social_oauth_begin` (user-context), `fn_social_oauth_consume`, `fn_social_meta_set_discovered`, `fn_social_meta_finalize` (service-context), `fn_social_connection_disconnect` (user-context).
  - **§8 hardening**: revokes PUBLIC/anon EXECUTE on all 016B + 016C SECURITY DEFINER functions; grants `service_role` (privileged) and `authenticated` (only the two user entrypoints + `fn__own_tenant`).
  - Selftest `fn_social_meta_oauth_selftest()` (deterministic; no live call).

**Edge functions** (each with `deno.json`)
- `supabase/functions/meta-facebook-oauth-begin/index.ts` — initiation (verify_jwt = **true**).
- `supabase/functions/meta-facebook-oauth-callback/index.ts` + `logic.ts` — callback (verify_jwt = **false**, state-gated).
- `supabase/functions/meta-facebook-select-page/index.ts` + `logic.ts` — Page selection + finalize (verify_jwt = **true**).
- `supabase/functions/meta-facebook-disconnect/index.ts` — disconnect/revoke (verify_jwt = **true**).
- `supabase/functions/_shared/meta_oauth/{scopes,capabilities,security,graph,http}.ts` — shared helpers; `meta_oauth.test.ts` (Deno tests).

**Tests**
- `scripts/tests/meta_oauth_pure.test.mjs` — 45 deterministic assertions, **executed under Node, all passing**.
- `supabase/functions/_shared/meta_oauth/meta_oauth.test.ts` — Deno test mirror for CI.

Unchanged: 016B tables/contracts (only EXECUTE grants tightened), Marketing Director, Creative
Studio, TikTok research, Meta advertising/tracking (`meta-capi-adapter`, `meta-insights-reader`).
`social_publishing_requests.execution_enabled` remains CHECK-forced `false`.

## B. OAuth initiation (`meta-facebook-oauth-begin`)
Requires an authenticated user → resolves tenant + authorization **server-side** via
`fn__own_tenant()` inside `fn_social_oauth_begin` (the client cannot assert a tenant) →
mints a 256-bit CSPRNG state (raw only on the authorize URL; **SHA-256 hash** persisted) →
writes a `PENDING_OAUTH / ORGANIC / META_FACEBOOK` row → builds the Meta authorize URL
server-side with the minimum Page scopes (or a Facebook Login for Business `config_id`) →
returns **only** the authorize URL. App secret and tokens are never exposed.

## C. Callback (`meta-facebook-oauth-callback`)
Authorized solely by the single-use state (no user JWT on Meta's redirect). Truthfully
handles Meta `?error`; rejects missing/expired/reused/mismatched state (single-use consume
in SQL, generic message to the browser); exchanges the code → long-lived user token;
discovers Pages (safe metadata only); stores the **user token in Vault** (never in the row,
never logged, never returned); records discovered Pages; redirects to the app for **explicit
Page selection** (never auto-connects).

## D. Page discovery
`GET /me/accounts?fields=id,name,tasks` via the user token. Per-Page tokens are deliberately
**not** surfaced at discovery. If multiple Pages are eligible, the user selects one; the
chosen Page must be within the discovered set (server-enforced in `fn_social_meta_finalize`).
No Page access is fabricated. Pulse Intelligence is connected only if Meta legitimately
returns it.

## E. Secure token storage
**Supabase Vault** (`vault` schema, present in the project) is the dynamic, per-connection,
encrypted-at-rest store, readable only by `service_role` via `vault.decrypted_secrets`.
`social_platform_connections.secret_ref` holds only the **Vault secret name** (e.g.
`social:<connection_id>:page`) — never a token. Raw tokens never touch the row, the browser,
frontend state, logs, Git, migrations, or docs. The 016B CHECK still rejects token-shaped
`secret_ref` values, and the Vault name is guarded the same way.

## F. Connection persistence (`fn_social_meta_finalize`)
Writes `CONNECTED` with the real Page id/name, **actual granted scopes**, capabilities
**derived only from the real Meta Page `tasks`** (never from requested scopes),
`secret_ref`, `connected_at`, `last_verified_at`, and `expires_at` (from `debug_token`;
null when non-expiring). Enforces: chosen Page discovered, required-scope **subset**,
verification succeeded, token-shape guard. Retires the temporary user-token Vault secret.

## G. Disconnect / revoke (`meta-facebook-disconnect` + `fn_social_connection_disconnect`)
Re-verifies tenant ownership; optionally attempts Meta-side revocation (`DELETE
/me/permissions`) and **only claims success when Meta confirms it**; sets `REVOKED` +
`revoked_at`, clears the Vault secret. Publishing preflight already refuses non-`CONNECTED`
/ revoked / expired connections, so a revoked connection can never publish.

## H. Security hardening
Server-side tenant resolution/authorization (`fn__own_tenant`, `auth.uid()`); FORCE RLS +
deny-by-default on the new table; SECURITY DEFINER with `SET search_path TO ''`; **EXECUTE
revoked from PUBLIC/anon** on all 016B + 016C functions, granted to `service_role` and (only
the two user entrypoints) `authenticated`; single-use/short-lived/hash-only OAuth state;
capability derivation from real grant; token redaction on all error output.

## I. Test results
`node --experimental-strip-types scripts/tests/meta_oauth_pure.test.mjs` → **45 passed, 0
failed** (scope subset incl. extra-accepted/missing-rejected, capability-from-tasks,
token-shape guard, crypto state/hash, redaction, and the full callback + select-page branch
matrix with mocked Meta: valid/invalid/expired/reused state, missing code, provider error,
tenant mismatch, page-not-discovered, insufficient scopes, verification failure).
The DB selftest `fn_social_meta_oauth_selftest()` and the Deno mirror are authored but **not
executed here** (no Deno / no DB in the build environment). No mocked run is reported as a
live connection.

## J. Regression results
No existing runtime code was modified (only function EXECUTE grants tightened, which the 016B
recovery explicitly requested). 016B contracts, MD lineage, Creative Studio, TikTok research,
and Meta advertising/tracking are untouched. Full regression suites (md_integration,
creative_production, media_native_composition, 016B preflight) run in Supabase and were **not
executable in this environment**; must be re-run post-deploy.

## K. Exact OAuth redirect URI
```
https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/meta-facebook-oauth-callback
```
Derived from `SUPABASE_URL` + the fixed function name (overridable via
`META_FACEBOOK_OAUTH_REDIRECT_URI`). Must match the project's edge base; confirm the base
after deploy before entering it in Meta.

## L. Deployed or source-only?
**Source only.** The build environment has no `supabase` CLI, no deploy credentials, and no DB
connection, so the migration was not applied and the functions were not deployed. Nothing was
deployed and no live Meta call was made.

## M. External Meta blocker
Founder-side (Meta app): Facebook Login for Business config, `pages_show_list /
pages_read_engagement / pages_manage_posts / business_management` (extra scopes such as
`pages_manage_metadata`, `public_profile` are accepted — validated as a subset), Strateloq
Page added as an app asset with founder admin, and the exact redirect URI (K) registered.
App Review is not required for the founder's own Page under app admins/testers.

## N. Environment variables required (names only; values go to the Edge secret store)
`META_APP_ID`, `META_APP_SECRET`, optional `META_FB_LOGIN_CONFIG_ID`, optional
`META_GRAPH_VERSION` (default `v21.0`), optional `META_FACEBOOK_OAUTH_REDIRECT_URI`,
`APP_BASE_URL` (post-callback app screen). `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` /
`SUPABASE_ANON_KEY` are built-in. **No secret is ever pasted into chat.**

---

## Deploy runbook (to lift the block)
1. Apply `mig_292` to the project DB.
2. Set the Edge secrets in (N).
3. Deploy the four functions; deploy **`meta-facebook-oauth-callback` with `verify_jwt = false`**,
   the other three with `verify_jwt = true`.
4. Confirm the deployed callback URL equals (K); register it in Meta → Facebook Login for
   Business → Settings → Valid OAuth Redirect URIs.
5. Run `select fn_social_meta_oauth_selftest();` and the existing regression selftests.
6. Only then perform the first real founder OAuth against the Strateloq/Pulse Page.

**STOP.** Do not initiate OAuth automatically. No publishing, no autonomous posting, no ad-account
connection. Founder-quality standard remains LOCKED.

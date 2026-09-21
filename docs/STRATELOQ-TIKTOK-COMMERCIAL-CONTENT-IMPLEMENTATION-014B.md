# STRATELOQ-TIKTOK-COMMERCIAL-CONTENT-IMPLEMENTATION-014B

**FINAL VERDICT: `TIKTOK_EXECUTOR_READY_CREDENTIAL_REQUIRED`.**

The TikTok Commercial Content path is now fully implemented as an extension of the existing 013N
research architecture — a normalizer, the `TIKTOK → SOCIAL_VIDEO` receiver branch in
`fn_research_ingest_source`, an offline selftest (10/10), and the bounded n8n executor workflow —
**without a live API call and without any credential ever touching the repo/DB/logs**. Credentials
live only in n8n's encrypted store. TikTok runtime availability remains `SOURCE_UNSUPPORTED`
(BLOCKED); it must not flip to AVAILABLE until the founder installs the credential and one bounded
authenticated request succeeds. The exact founder action is the n8n **Custom Auth** credential in §3.
No WPS/DataForSEO/Meta/eBay/CJ/Reddit/product-identity/market-isolation/decision/Lovable change.

---

### 1. Official TikTok auth contract verified
Verified against TikTok for Developers (Commercial Content API); the docs domain is egress-blocked
from this environment, so confirmed via search of the official pages:
- **Token endpoint:** `POST https://open.tiktokapis.com/v2/oauth/token/`, content-type
  `application/x-www-form-urlencoded`.
- **Params:** `client_key`, `client_secret`, `grant_type=client_credentials`.
- **Token response:** `{ access_token, expires_in: 7200, token_type: "Bearer" }` — **no refresh
  token**; re-request on expiry.
- **Authorization header:** `Authorization: Bearer <access_token>`.
- **Ad Library query:** `POST https://open.tiktokapis.com/v2/research/adlib/ad/query/`; body filters
  `search_term`, `country_code_list`, `ad_published_date_range`, `max_count`; `fields` in the query
  string; response `data.ads[]` + `search_id` + `has_more` (pagination — not used for the bounded
  single query). Sibling endpoints: `advertiser/query`, `commercial_content/query`.
- **Scope:** `research.adlib.basic` = public commercial data for research; covers the adlib query.
  Compatible with the intended SOCIAL_VIDEO advertising-presence read. (This matches the 014A
  assumptions; no divergence found.)
Sources: developers.tiktok.com/docs/en/commercial-content-api-getting-started;
developers.tiktok.com/docs/en/commercial-content-api-query-ads; developers.tiktok.com/doc/client-access-token-management.

### 2. Exact n8n credential type
**Custom Auth (`HTTP Custom Auth`) is CORRECT — no type change required.** TikTok's token endpoint
needs the raw `client_key`/`client_secret` in the request **body** with `grant_type=client_credentials`,
and Custom Auth injects arbitrary body fields, so it safely holds both raw values and the executor
performs the two-step token→query exchange. (n8n's generic **OAuth2 API** credential is unsuitable:
its client-credentials grant sends `client_id`, but TikTok requires the parameter name `client_key`.)

### 3. Exact placeholder-only credential configuration
In the open n8n **Custom Auth** screen, name the credential **`Pulse TikTok Commercial Content`** and
paste this JSON (placeholders only — enter the real values locally in n8n, never in chat):
```json
{
  "body": {
    "client_key": "<CLIENT_KEY>",
    "client_secret": "<CLIENT_SECRET>"
  }
}
```
(The executor's token node already sends `grant_type=client_credentials` in the body, so the
credential holds only the two secrets.) A second Custom Auth credential
**`Pulse Supabase Service Role`** feeds the ingest node:
`{ "headers": { "apikey": "<SUPABASE_SERVICE_ROLE_KEY>", "Authorization": "Bearer <SUPABASE_SERVICE_ROLE_KEY>" } }`.

### 4. Allowed HTTP Request Domains
Narrowest setting for the TikTok credential: **`https://open.tiktokapis.com`** (token + adlib query
share this host). For the Supabase ingest credential:
**`https://nxaunmyihhjixxxljcqt.supabase.co`**.

### 5. Executor implementation
n8n workflow **`Pulse — Research Executor: TikTok (014B)`** (id `j4bOv9cuuzMbqN9B`, **inactive /
manual-trigger**, 6 nodes), extending the 013N executor family (no parallel system):
`Manual Trigger → Bounded Test Config (run_id, search_term, country_code, max_count) → TikTok Access
Token (Custom Auth) → TikTok Ad Query (Bearer) → Normalize TikTok Ads (data.ads[]) → Ingest to
Supabase fn_research_ingest_source(run_id,'TIKTOK',ads)`. Credentials are unbound placeholders the
founder attaches; the workflow is not activated and was not executed.

### 6. TikTok ingestion implementation (`mig_261`)
- `fn_ingest_tiktok_commercial_content(product, market, ads, dry_run)` normalizes TikTok ad/query
  results into **SOCIAL_VIDEO advertising evidence** in `commerce_signals`
  (`signal_type='SOCIAL_VIDEO_ADVERTISING'`, written under the global-intelligence uid like Meta),
  preserving source (`TIKTOK_COMMERCIAL_CONTENT`), market, observed_at, advertiser, ad id, first/last
  shown dates, product relationship (via `fn_meta_ad_relevance`), provenance, and a raw ad reference.
  It **never fabricates** engagement/sales/revenue/virality/conversion. A non-array (auth/API error)
  body returns `not_ad_array` (evidence unchanged, never zeroed).
- `fn_research_ingest_source` gains the `TIKTOK → SOCIAL_VIDEO` branch reusing existing terminal-state
  machinery: matched ads → `SEARCHED_EVIDENCE_FOUND`; zero ads → `SEARCHED_NO_EVIDENCE`; auth/API
  failure → `SOURCE_FAILED`. Feeds normal `fn_finalize_research_run` unchanged.

### 7. Provider state before / after
Before: `provider_capability_registry` TikTok = `SOURCE_UNSUPPORTED`,
`project_state=APPROVED_CREDENTIAL_SETUP_REQUIRED` (014A). After: **unchanged** — still
`SOURCE_UNSUPPORTED` (runtime BLOCKED). No flip to AVAILABLE (that is gated on a real successful
authenticated request, which has not occurred). Every research run still seeds TikTok as
`BLOCKED_EXTERNAL_ACCESS`.

### 8. Tests
`fn_tiktok_executor_selftest` **10/10**: provider applicability; availability still blocked; zero-result
→ NO_PRODUCT_MATCH (SEARCHED_NO_EVIDENCE); evidence-found → OBSERVED (dry-run, nothing persisted);
auth failure → `not_ad_array` (not zeroed → SOURCE_FAILED); market isolation (DE); ingest routes
`TIKTOK→SOCIAL_VIDEO` via the normalizer; terminal-state mapping present; **no secret literal** in
either function; no founder TikTok evidence persisted. Regressions pass: `research_orchestrator`
(incl. `tiktok_blocked`), `deep_research`, `ecommerce_connection`, `ecommerce_intelligence_contracts`.

### 9. Security verification
No credential requested, printed, or stored. Secrets remain only in n8n's encrypted store; the DB,
migration, selftest, workflow JSON and this doc contain **placeholders only**. The executor logs no
secret (token used transiently via Bearer expression). `mig_261` secret-scan clean. Advisors: **0
ERROR** (1 INFO/4 WARN baseline). Ingestion RPCs are `service_role`-only.

### 10. Files / workflows / migrations changed
- `supabase/migrations/mig_261_tiktok_commercial_content_executor.sql` —
  `fn_ingest_tiktok_commercial_content`, `fn_research_ingest_source` (+TIKTOK branch),
  `fn_tiktok_executor_selftest`.
- n8n workflow `Pulse — Research Executor: TikTok (014B)` (`j4bOv9cuuzMbqN9B`, inactive).
- `docs/STRATELOQ-TIKTOK-COMMERCIAL-CONTENT-IMPLEMENTATION-014B.md`.

### 11. Commit hash / push status
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`; see delivery message.

### 12. Exact next founder action
1. In the open n8n **Custom Auth** screen, create **`Pulse TikTok Commercial Content`** with the §3
   JSON (paste the real Client Key/Secret locally) → **Save**.
2. Create Custom Auth **`Pulse Supabase Service Role`** (§3 headers) if not reusing an existing one.
3. Open workflow **`Pulse — Research Executor: TikTok (014B)`**, attach `Pulse TikTok Commercial
   Content` to **TikTok Access Token** and `Pulse Supabase Service Role` to **Ingest to Supabase**.
4. Tell Claude the credential is installed; Claude sets `Bounded Test Config` (a real `run_id` +
   product query + market) and runs **one** bounded execution. On a successful authenticated response
   (200; zero results is valid), the provider flips to AVAILABLE.

### 13. Final verdict
`TIKTOK_EXECUTOR_READY_CREDENTIAL_REQUIRED` — executor + ingestion + tests are implemented and green;
the one bounded live test awaits the founder installing the n8n credential.

**STOP.** No real credential requested/printed; no live TikTok call; no frontend/publish change.

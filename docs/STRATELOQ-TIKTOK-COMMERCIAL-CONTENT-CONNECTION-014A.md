# STRATELOQ-TIKTOK-COMMERCIAL-CONTENT-CONNECTION-014A

**FINAL VERDICT: `TIKTOK_IMPLEMENTATION_GAP`.**

TikTok Commercial Content API is officially approved (client **Connected**, scope
**`research.adlib.basic`**, Client Key + Secret issued), and the founder must next install those two
credentials in the **established n8n credential store** (steps in §3). But the existing 013N provider
path does **not yet** support TikTok end-to-end: there is **no** TikTok executor branch, **no** n8n
TikTok workflow, **no** server-to-server token step, and **no** SOCIAL_VIDEO ingestion contract
(`fn_research_ingest_source` returns `UNKNOWN_SOURCE` for `TIKTOK`). Credentials alone therefore
cannot enable the one bounded live test — a small executor + ingestion build is required first. No
credential was requested, exposed, or stored. The project-level TikTok state was truthfully advanced
to **`APPROVED_CREDENTIAL_SETUP_REQUIRED`** while the runtime deliberately **stays
`BLOCKED_EXTERNAL_ACCESS`** (not AVAILABLE/CONNECTED/EVIDENCE_FOUND). Migration `mig_259` (metadata
only). No live call, no WPS change, no Lovable change, no publish.

---

### 1. Existing secure secret architecture
Two tiers, both keeping provider API secrets **out of the database and out of the browser**:
- **Provider API credentials → n8n credential store** (the established pattern). Each provider is a
  named n8n credential consumed only by its executor workflow at runtime:
  - DataForSEO → n8n HTTP Basic Auth credential ("Pulse DataForSEO").
  - eBay → n8n Basic Auth credential ("Pulse eBay Production"); executor does **Client Credentials
    OAuth** to get a token, then calls Browse — the closest existing analogue to TikTok's flow.
  - Meta → n8n credential ("Pulse Meta System User"); Meta CAPI edge functions additionally read a
    Supabase **secret reference name** `META_CAPI_ACCESS_TOKEN` (env var; value never in the DB).
  - CJ → n8n CJ credential ("Pulse CJ"); Reddit → public JSON (no secret).
- **Executor webhook URL + shared dispatch secret → Supabase `server_integration_config`** (RLS
  deny-all; no anon/authenticated grants; read only inside SECURITY DEFINER functions). This holds
  the n8n webhook URL + dispatch secret — **never** provider API keys.
- **Runtime that consumes them:** the n8n executor workflows (e.g. "Pulse — Research Auto-Dispatch
  Executor (013N)", and per-provider executors for eBay/Meta/DataForSEO/CJ). Supabase pg_net posts
  only `run_id` + the dispatch secret to n8n; n8n attaches the provider credential server-side.
- **TikTok should use the same mechanism** — a new n8n credential, exactly like eBay/DataForSEO.
  Nothing about TikTok's Client Key/Secret belongs in Supabase, Lovable, or the repo.

### 2. Where TikTok credentials should live
In the **n8n credential store**, as a dedicated credential (recommended name **"Pulse TikTok
Commercial Content"**) — an HTTP Header/Generic or OAuth2 credential holding `TIKTOK_CLIENT_KEY` and
`TIKTOK_CLIENT_SECRET`. The DB stores only capability/state metadata (no values). This mirrors the
eBay Client-Credentials pattern precisely.

### 3. Exact founder UI steps to install them (no secret shared with Claude)
1. Open **n8n** (the same workspace that runs the Pulse executors).
2. In the left sidebar click **Credentials**.
3. Click **Add credential** → choose **Header Auth** (or **Generic Credential / OAuth2** if you
   prefer) → name it exactly **`Pulse TikTok Commercial Content`**.
4. Add field **`TIKTOK_CLIENT_KEY`** and paste the **Client Key** from the TikTok Developer Portal
   **locally in n8n** (do not paste it into Claude/ChatGPT).
5. Add field **`TIKTOK_CLIENT_SECRET`** and paste the **Client Secret** **locally in n8n**.
6. Click **Save**. (Do not commit, screenshot, or share the values. n8n encrypts credentials at
   rest.)
Keep both values only in n8n and the TikTok Developer Portal.

### 4. Existing TikTok executor status
- **Present:** registry entry `provider_capability_registry(source='TIKTOK',
  evidence_category='SOCIAL_VIDEO', market='*')`; per-run attempt seeding as `BLOCKED_EXTERNAL_ACCESS`
  (state map in `mig_243`); orchestrator selftest case `tiktok_blocked`. The 013N dispatch plane
  (manifest + webhook + `server_integration_config`) exists generically.
- **Missing:** no TikTok executor branch in any n8n workflow; no TikTok n8n workflow at all; no
  server-to-server token step; **no ingestion/normalization** — `fn_research_ingest_source` handles
  EBAY/META/DATAFORSEO/CJ/REDDIT only and returns `UNKNOWN_SOURCE` for `TIKTOK`; no
  SOCIAL_VIDEO→evidence writer; no tests/docs for a live TikTok path.

### 5. Authentication flow verified
**No approved TikTok auth contract is present in the project/docs to verify against** (searched
migrations + docs; only a policy note that "TikTok Ads API is a later, separate integration"). Per
Section 3's instruction, this is reported as a **mismatch/absence before any live call**. The
**official** TikTok Commercial Content API server-to-server flow to implement is:
- **Token endpoint:** `POST https://open.tiktokapis.com/v2/oauth/token/`
  (`Content-Type: application/x-www-form-urlencoded`).
- **Grant type:** `client_credentials`.
- **Client credentials:** `client_key` + `client_secret` (from the n8n credential).
- **Access-token handling:** response returns `access_token` + `expires_in` (~7200s) + `token_type`
  (Bearer); used as `Authorization: Bearer <token>` on the adlib query.
- **Expiration/refresh:** client-credentials tokens have **no refresh token**; re-request a fresh
  token on expiry (cache until ~60s before `expires_in`).
- **Commercial Content endpoint for the first bounded test:** the Commercial Content **Ad Library**
  query under `.../v2/research/adlib/...` (e.g. `ad/query/`) — a single minimal, region-scoped query
  for one product term. **This flow must be confirmed against TikTok's live docs during the build
  unit** before the bounded call, since no in-repo contract pins it.

### 6. Approved scope compatibility
Approved scope **`research.adlib.basic`** = "Access to public commercial data for research purposes"
— this is exactly the Commercial Content **Ad Library** research surface Prompt intends (SOCIAL_VIDEO
advertising-presence evidence). Compatible with the intended first bounded read; it does **not** grant
posting/ads-management (consistent with the existing "TikTok Ads API is a later, separate
integration" policy).

### 7. Missing implementation
To make the existing 013N path support TikTok (no parallel architecture): (a) an n8n **TikTok
executor** that does the `client_credentials` token fetch + one bounded adlib query using the new
credential; (b) a **SOCIAL_VIDEO branch in `fn_research_ingest_source`** (`TIKTOK` → `SOCIAL_VIDEO`)
plus a normalization/ingest writer for TikTok adlib rows; (c) a registry flip to `AVAILABLE` **gated
on a real successful authenticated call**; (d) a selftest + doc. These are the build unit's scope.

### 8. Current truthful TikTok provider state
`APPROVED_CREDENTIAL_SETUP_REQUIRED` (registry `capability.project_state`), while runtime availability
remains `SOURCE_UNSUPPORTED` → every research run still seeds TikTok as `BLOCKED_EXTERNAL_ACCESS`.
**Not** AVAILABLE / CONNECTED_RUNTIME / EVIDENCE_FOUND. No credential value stored in the DB.

### 9. Exact next test after credentials are installed
Once the credential is saved **and** the executor + ingestion branch are built: run one **bounded**
n8n TikTok executor execution → `client_credentials` token → a single region-scoped adlib query for
one existing product term (e.g. a founder product) → post normalized rows to
`fn_research_ingest_source(run_id,'TIKTOK',raw)`. Success (HTTP 200 + a well-formed adlib response,
even zero results) is what earns the registry flip to `AVAILABLE`; only then may state advance beyond
`APPROVED_CREDENTIAL_SETUP_REQUIRED`.

### 10. Files changed
- `supabase/migrations/mig_259_tiktok_approved_credential_setup_state.sql` — metadata-only UPDATE of
  the TikTok `provider_capability_registry` row (`capability.project_state =
  APPROVED_CREDENTIAL_SETUP_REQUIRED`, approved scope, `credentials_installed=false`,
  `runtime_executor_implemented=false`, `ingestion_contract_implemented=false`; truthful
  `limitations`). **availability unchanged** (`SOURCE_UNSUPPORTED`). No credential value; no executor
  code (deferred to the build unit).

### 11. Tests
- Runtime safety: TikTok availability still `SOURCE_UNSUPPORTED` → still `BLOCKED_EXTERNAL_ACCESS` in
  runs (verified).
- `fn_research_orchestrator_selftest` → `all_pass` (case `tiktok_blocked` still true);
  `fn_deep_research_selftest` and `fn_ecommerce_connection_selftest` → `all_pass`.
- Secret scan of `mig_259`: clean (no secret-shaped tokens; no Client Key/Secret).

### 12. Commit / push status
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`. Hash / divergence: see delivery
message.

**STOP.** No secret requested, exposed, or stored. No live TikTok call. Credentials must be installed
in n8n (§3) and the TikTok executor + SOCIAL_VIDEO ingestion built before any bounded live
verification.

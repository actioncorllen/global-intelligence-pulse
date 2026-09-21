# STRATELOQ-TIKTOK-SECURE-TOKEN-BROKER-014E

**FINAL VERDICT: `TIKTOK_TOKEN_BROKER_READY_SECRET_INSTALL_REQUIRED`.**

Option B is built. A narrowly-scoped Supabase Edge Function **`tiktok-commercial-token`** now brokers the
TikTok token server-side, mirroring the established trusted-server pattern (`meta-insights-reader`). The
n8n Token node calls it via the **existing Supabase service-role credential** — the failed
`httpCustomAuth` path is removed and the old credential is no longer referenced (not deleted). TikTok
`client_key`/`client_secret` exist **only** as Edge Function environment secrets (names below), never in
Lovable, browser, DB, RPC args, workflow JSON, repo, logs, docs or execution output. **No live TikTok
request was made.** Two Edge Function secrets must be installed by the founder (I cannot and must not
handle their values); after that, a separate unit runs one bounded live verification.

---

## 1–3. Edge Function, name, authentication model
- **Created & deployed:** `tiktok-commercial-token` (ACTIVE, version 1), at
  `https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/tiktok-commercial-token`.
- **Authentication (two layers, fail closed):**
  1. Supabase gateway **`verify_jwt = true`** → any request without a valid project JWT is rejected
     (401) before the code runs.
  2. In-function **service_role claim check** → the already-verified JWT's `role` must be `service_role`;
     an anon/browser JWT is denied `403 forbidden_requires_service_role`. n8n authenticates with the
     existing Supabase service-role credential, so it passes; browser/anon cannot.
- No CORS headers are emitted (server-to-server only; browser preflight cannot use it).

## 4. Secret names (values never shown, never handled)
- `TIKTOK_COMMERCIAL_CLIENT_KEY`
- `TIKTOK_COMMERCIAL_CLIENT_SECRET`

Read only via `Deno.env.get(...)`; never logged, never returned.

## 5. Are secrets installed?
**Not confirmed installed — treated as NOT installed (founder action required).** The prior TikTok work
used n8n Custom Auth, not Edge Function secrets, so these two env secrets almost certainly do not exist
yet, and there is no path for me to install them without handling values. The function has a **presence
probe** (`?probe=1` or body `{"probe":true}`) that returns only `secrets_present: boolean` — no values,
no TikTok call — so installation can be confirmed safely at bounded-test time.

## 6. Exact form-urlencoded token implementation
```ts
const form = new URLSearchParams();
form.set("client_key", clientKey);        // from Deno.env
form.set("client_secret", clientSecret);  // from Deno.env
form.set("grant_type", "client_credentials");
await fetch("https://open.tiktokapis.com/v2/oauth/token/", {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: form.toString(),
});
```
Returns only `{ ok, access_token, token_type, expires_in }`. On failure returns a **redacted** error
(`client_key`/`client_secret`/`access_token` scrubbed); on missing secrets returns `424
server_secret_unavailable`. The access token is not persisted to any table.

## 7. n8n Token node change (workflow `j4bOv9cuuzMbqN9B`, node "TikTok Access Token")
- **Was:** `genericCredentialType` → `httpCustomAuth` (credential `Pulse TikTok Commercial Content`),
  POST to `open.tiktokapis.com/v2/oauth/token/`.
- **Now:** `predefinedCredentialType` → `supabaseApi` (existing `Supabase account` credential),
  POST to the broker URL with body `{}`; `neverError` on. Node rebuilt so **only** the Supabase
  credential is bound.
- Ad Query, Normalize, Ingest **unchanged**. Ad Query still consumes the Bearer token via
  `={{ "Bearer " + $json.access_token }}` — the broker returns `access_token` at top level, so no
  expression change was needed.

## 8. Old Custom Auth no longer used
Confirmed: the Token node references only `supabaseApi`. The `httpCustomAuth` credential
`Pulse TikTok Commercial Content` (`id9au7UBaSXn3dq0`) is **not referenced by any node** in the
workflow. It is **not deleted** (kept as deprecated/unused, per instruction).

## 9. No TikTok secret in n8n / DB / repo
- n8n workflow JSON: no `client_key`/`client_secret` (the broker holds none; the Token node sends only
  `{}` + the Supabase service-role auth the credential already stores).
- Database: broker touches no tables; 0 TikTok/SOCIAL_VIDEO signals; no token persisted.
- Repo: `supabase/functions/tiktok-commercial-token/index.ts` contains only env-var **names**, no values
  (secret-scan clean).

## 10. Unauthorized-access test
Direct HTTP probing from this session's shell is blocked by the workspace egress policy (proxy 403 to
`supabase.co`), so the gate was proven **deterministically offline** against the real project anon JWT +
the function's exact `callerRole` logic:
- anon JWT (`role=anon`) → **DENY (403)**
- no Bearer → **DENY (403)**
- malformed Bearer → **DENY (403)**
- `service_role` JWT → **PROCEED**

Combined with the platform guarantee (`verify_jwt=true` → 401 for missing/invalid JWT) and no CORS, a
normal anon/browser caller cannot obtain a TikTok token.

## 11. Offline / security tests
- Deployed & ACTIVE, `verify_jwt=true` ✓
- service_role gate enforced (offline proof, 4/4) ✓
- secret presence checkable without reading values (probe mode) ✓
- fail-closed on missing secrets (`424`) ✓; malformed body (`400`); non-POST (`405`)
- TikTok error sanitized via `redact()`; no secret returned in any error ✓
- no secret literals in function or workflow ✓
- Token node → broker ✓; old `httpCustomAuth` unreferenced ✓
- Ad Query still expects Bearer token ✓; Ingest RPC unchanged ✓
- TikTok provider remains `SOURCE_UNSUPPORTED`; SOCIAL_VIDEO remains `BLOCKED_EXTERNAL_ACCESS`; 0
  SOCIAL_VIDEO signals ✓
- No RLS/Edge-Function security weakened; advisors unchanged (no DDL this unit)

## 12. Founder action required (STOP gate — Phase 5/7)
Install the two Edge Function secrets, then confirm — I did not run TikTok. **Use placeholders; never
paste values into Claude/chat.**

- **Supabase Dashboard:** Project `nxaunmyihhjixxxljcqt` → **Edge Functions → Secrets** (Project
  Settings → Edge Functions) → **Add secret** twice:
  - Name `TIKTOK_COMMERCIAL_CLIENT_KEY`, Value `<your TikTok Commercial Content client key>`
  - Name `TIKTOK_COMMERCIAL_CLIENT_SECRET`, Value `<your TikTok Commercial Content client secret>`
- **or Supabase CLI:**
  `supabase secrets set TIKTOK_COMMERCIAL_CLIENT_KEY=<KEY> TIKTOK_COMMERCIAL_CLIENT_SECRET=<SECRET> --project-ref nxaunmyihhjixxxljcqt`

After you confirm installation, the next unit will run **one** bounded live verification (presence probe
→ single token → single Ad Query).

## 13. Files / functions / workflows changed
- **New:** `supabase/functions/tiktok-commercial-token/index.ts` (deployed).
- **n8n:** workflow `Pulse — Research Executor: TikTok (014B)` (`j4bOv9cuuzMbqN9B`) — Token node only,
  repointed to broker via Supabase credential; old `httpCustomAuth` binding removed. No other node
  changed. No Lovable, no scoring, no migration.

## 14. Commit / push
Committed and pushed to `claude/pulse-crash-recovery-b6ngey`; see delivery message.

## 15. Live-request confirmation
**No live TikTok request occurred.** No token was minted, no Ad Query ran, 0 TikTok/SOCIAL_VIDEO signals.
Live verification is deferred to a separate unit after founder secret installation.

**STOP.** No Lovable, no Ecommerce scoring change, no publish, no Stripe, no broad research.
Verdict `TIKTOK_TOKEN_BROKER_READY_SECRET_INSTALL_REQUIRED`.

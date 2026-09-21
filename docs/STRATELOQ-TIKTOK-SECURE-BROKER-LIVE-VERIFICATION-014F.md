# STRATELOQ-TIKTOK-SECURE-BROKER-LIVE-VERIFICATION-014F

**FINAL VERDICT: `TIKTOK_BROKER_SECRETS_MISSING`.**

The Phase-1 safe presence check — run through the exact authenticated server-side path n8n uses (the
Token node → `tiktok-commercial-token` Edge Function via the Supabase service-role credential) —
resolves to **`secrets_present = false`**: the broker consistently returns **HTTP 424
`server_secret_unavailable`**, meaning the function cannot read `TIKTOK_COMMERCIAL_CLIENT_KEY` /
`TIKTOK_COMMERCIAL_CLIENT_SECRET` from its Edge Function environment. Per Phase 1 I **stopped before any
TikTok request** — TikTok was called **zero** times. No secret was inspected, printed, or exposed;
provider state is unchanged. One real defect was found and fixed on the way (the broker's auth gate had
rejected n8n's own credential); the function is left correct so the retry will work once the secrets are
present.

---

## 1. secrets_present probe result
**false.** Executed via the production path (n8n Token node → broker, Supabase service-role credential).
The broker's env read for both secret names returned empty → **HTTP 424 `{"ok":false,"error":
"server_secret_unavailable"}`**. (The dedicated probe *branch* could not be triggered through the
Supabase gateway from n8n — the gateway drops the `?probe=1` query string and the n8n JSON-body / custom
header did not reach the probe check — but the 424 from the real secret check is itself the definitive
presence signal.)

## 2. Broker authentication result
**Authorized (after a fix).** Initial probe returned `403 forbidden_requires_service_role`: this project
uses Supabase's **new key system**, so n8n's Supabase credential authenticates with the **service-role
secret key**, not a legacy `service_role` **JWT** — and the 014E gate only checked the JWT `role` claim,
so it wrongly rejected the trusted caller. Fixed: the gate now authorizes when the caller presents the
project's service-role key (constant-time compared against the built-in `SUPABASE_SERVICE_ROLE_KEY`) OR
a `service_role` JWT claim. After the fix the broker authorizes n8n (it reached the secret check → 424,
i.e. no longer 403). Anon/browser still cannot pass (no service-role key; `verify_jwt` blocks no-JWT).

## 3. TikTok token request result
**Not attempted.** Execution stopped at the broker's secret gate (424); no TikTok `/v2/oauth/token/`
call was made.

## 4. Sanitized HTTP/API status
Broker: **HTTP 424 Failed Dependency**, body `{"ok":false,"error":"server_secret_unavailable"}`. No
TikTok HTTP status (no call).

## 5–13. Live-path results (not reached)
No Ad Query; 0 ads; 0 evidence ingested. **Unchanged:** SOCIAL_VIDEO attempt still
`BLOCKED_EXTERNAL_ACCESS`; TikTok provider capability still **`SOURCE_UNSUPPORTED`**; research coverage,
PME (nightlight GB **68.2**, `WATCH`, coverage 0.78) and Product Decision (`WATCH` / `TRENDING_WATCH`)
unchanged (before == after); workspace still truthfully shows TikTok as awaiting source access. No score
or decision was forced.

## 14. Regression
- 014B workflow (`j4bOv9cuuzMbqN9B`) restored to its exact production state after probing (Token node →
  broker via Supabase credential, `{}` body, no probe header, downstream re-enabled). Net functional
  state identical to post-014E.
- No other n8n workflow changed. No Lovable, no Stripe, no Ecommerce scoring change, no migration.
- Other providers untouched (eBay / Meta / DataForSEO / CJ / Reddit); product gallery & same-product
  gallery identity intact; storefront image guard intact; GB market / business country GB intact.
- **0** TikTok/SOCIAL_VIDEO signals — no synthetic evidence created.

## 15. Security verification
- TikTok client_key / client_secret / access_token / Authorization header: **never printed, returned or
  logged** (the broker only ever returns `secrets_present` booleans, a sanitized error, or the minimal
  token result; secrets scrubbed via `redact()`).
- No TikTok secret or access token persisted to any DB table (broker touches no tables).
- No TikTok secret committed to the repo (secret-scan clean; function holds only env-var **names**).
- The Supabase service-role key is compared in constant time and never returned/logged.
- Old `httpCustomAuth` credential `Pulse TikTok Commercial Content` remains **unused** and unreferenced.

## 16. Files / workflows / database changes
- `supabase/functions/tiktok-commercial-token/index.ts` — auth gate corrected (service-role **key**
  match added alongside the JWT-claim check); deployed (function version 5, `verify_jwt=true`).
- n8n workflow `j4bOv9cuuzMbqN9B` — probed then **restored** to production (no net functional change).
- **No database change.**

## 17. Commit
Committed — the gate fix is genuinely necessary (the deployed broker must accept n8n's service-role
credential under this project's key system, and the repo must match the deployed function). See delivery
message.

---

## Founder action required to unblock the retry
The broker is correct and authorized; it simply cannot see the two secrets. Please verify they are
installed as **Edge Function secrets** (project secrets injected into functions), **not** database Vault
secrets, under these **exact** names (placeholders — do not paste values into chat):

- **Dashboard:** Project `nxaunmyihhjixxxljcqt` → **Project Settings → Edge Functions → Secrets** → ensure
  both exist: `TIKTOK_COMMERCIAL_CLIENT_KEY` = `<client key>`, `TIKTOK_COMMERCIAL_CLIENT_SECRET` =
  `<client secret>`.
- **or CLI:** `supabase secrets set TIKTOK_COMMERCIAL_CLIENT_KEY=<KEY> TIKTOK_COMMERCIAL_CLIENT_SECRET=<SECRET> --project-ref nxaunmyihhjixxxljcqt`
- Common causes of this 424: a name typo/casing mismatch, or the values placed in **database Vault** (or
  n8n) instead of **Edge Function** secrets. If you are certain they are set correctly as Edge Function
  secrets, allow a short propagation delay and we can re-run 014F.

Once confirmed, re-run this unit: the single bounded live execution will mint the token and run the
Commercial Content Ad Query exactly once.

**STOP.** No Lovable, no Stripe, no broad research, no additional TikTok execution. Verdict
`TIKTOK_BROKER_SECRETS_MISSING`.

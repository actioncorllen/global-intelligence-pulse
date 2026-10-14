# PULSE-ECOM-EDGE-BROKER-AUTH-CONTRACT-001

**Root-caused the recurring `401 UNAUTHORIZED_LEGACY_JWT` on internal broker calls and added a durable
server-side invocation contract (`mig_299`). No production code defect existed; the fix removes the
recurrence vector and standardizes on the non-legacy publishable key.**

## Symptom
pg_net `net._http_response` requests **137** and **143** returned
`HTTP 401 {"code":"UNAUTHORIZED_LEGACY_JWT","message":"Invalid JWT"}` when invoking the
`fastmoss-product-detail` edge function (gateway `verify_jwt=true`).

## Root cause — operator transcription error, at the gateway (not the function)
The two failing calls were **ad-hoc, hand-authored investigative SQL** in which the ~220-character
gateway JWT was pasted directly into the `net.http_post` `Authorization: Bearer <...>` literal and
**mistyped**. The Supabase Edge **gateway** rejected the malformed JWT **before the function body ran**.

Proven, not inferred:
- The `{"code","message"}` envelope is the **gateway's** error shape. The function never emits it — its
  own auth denial is `403 {"ok":false,"error":"forbidden_requires_service_role_or_valid_nonce"}`, and it
  never returns 401.
- Every correctly-keyed sibling request (133, 136, 138–142, 144) reached the function (200/400/403 with
  the function's envelope). The 401s correlate **1:1** with the mistyped tokens.
- A controlled reproduction (test **C** below: valid `apikey` + deliberately malformed `Authorization`)
  reproduces the gateway 401 exactly.

**No committed caller is affected.** `fn_fastmoss_run_discovery` / `fn_kalodata_run_discovery` receive
the public anon key as a **parameter** from the frontend (never hand-typed); `server_integration_config`
holds only the n8n research webhook (url + opaque secret), no Supabase JWT. The recurrence vector was
that server-side (frontend-less) calls had **no sanctioned helper**, so manual SQL hand-pasted the key.

## Gateway key-class finding
The gateway currently accepts **both** the legacy anon JWT (`eyJ…`) **and** the new publishable key
(`sb_publishable_…`). The durable fix standardizes on the **publishable** key (not a legacy JWT),
de-risking the eventual legacy-key cutoff.

## Fix (`mig_299`) — `fn_invoke_provider_broker(p_function, p_payload, p_user_id, p_market)`
The single sanctioned server-side path to the broker:
- reads the gateway credential from `server_integration_config` key `edge_gateway` (**never hand-typed**),
  standardized on the publishable key;
- allowlists the target edge function (`fastmoss-product-detail` only);
- mints a **single-use nonce** (the broker's independent in-function authorization gate — unchanged);
- posts via `net.http_post` with correct `apikey` / `Authorization` / `x-pulse-nonce` headers.
- `SECURITY DEFINER`, `search_path=''`, **EXECUTE revoked from PUBLIC/anon/authenticated**, granted to
  `service_role` only.

`verify_jwt` stays **ON**. The publishable key only satisfies the gateway; it grants nothing on its own
(a valid gateway credential with no/forged nonce is still denied `403` by the broker). The credential
value is populated **live only** (not committed); the migration contains no secret.

## Verification — free auth regression (broker `probe` path; zero provider calls, $0.00)
| Test | Headers | Result | Verdict |
|---|---|---|---|
| A | valid anon JWT + valid nonce | `200 probe` | ACCEPTED |
| B | no auth header | `401 UNAUTHORIZED_NO_AUTH_HEADER` (gateway) | DENIED |
| C | valid apikey + **malformed** Bearer | `401 UNAUTHORIZED_INVALID_JWT_FORMAT` (gateway) | DENIED — reproduces 137/143 |
| D | valid anon JWT + **no** nonce | `403 forbidden_requires_service_role_or_valid_nonce` (function) | DENIED |
| E | valid anon JWT + **forged** nonce | `403 forbidden_requires_service_role_or_valid_nonce` (function) | DENIED |
| F | **new publishable key** + valid nonce | `200 probe` | ACCEPTED |
| helper | `fn_invoke_provider_broker(probe)` | `200 probe` | ACCEPTED (sanctioned path, no hand-typed JWT) |

Grants: anon=EXECUTE✗, authenticated=EXECUTE✗, service_role=EXECUTE✓.
Broker restored to committed **v4** (probe returns no `apify_secret_present`; temporary Apify test modes
removed). FastMoss & Kalodata request builders return `ok=true`.

## Follow-ups (not done here; out of scope / need founder go-ahead)
- `fn_creative_fire_image_executor` hard-codes a JWT literal for the `creative-image-execute` function —
  a separate edge function and a latent legacy-key-migration risk. Recommend migrating it to the same
  config-sourced publishable-key contract.
- Optional hardening: move the gateway credential to the new **secret** key / `service_role` in Vault for
  end-to-end server authentication (gateway + in-function gate) without a nonce.

## Boundaries honored
`verify_jwt` not disabled. Function not made public. No secret in source control. Tenant isolation,
nonce single-use, secret redaction, and Product Asset Lock unchanged. No CJ. No Stage 3. No Apify.
**Paid provider calls: 0. Apify cost: $0.00.**

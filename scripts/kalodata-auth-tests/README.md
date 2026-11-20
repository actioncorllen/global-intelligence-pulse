# Kalodata canonical-auth deterministic tests (2026-11-20)

Offline, deterministic tests for the canonical Kalodata authentication fix
(X-API-Key header only; no conflicting secret-key header), run against the
LITERAL deployed `kalodata-discovery` source. No network, no credits, fake
keys only.

Run (Node 22+):

```bash
L=$(grep -n "^Deno.serve" ../../supabase/functions/kalodata-discovery/index.ts | cut -d: -f1)
head -n $((L-1)) ../../supabase/functions/kalodata-discovery/index.ts > kalodata-logic.v24.ts
echo 'export { redact, kalodataKey, kalodataAuthHeaders, keyMask, extractProducts, extractUsage, extractBalance, providerCode, providerMsg, looksLikeProviderError, topLevelKeys, PROVIDER_SUCCESS_CODES, AUTH_HEADER, API_KEY_ENV, SECRET_ENV, DEFAULT_BALANCE_ENDPOINT };' >> kalodata-logic.v24.ts
node --experimental-strip-types --no-warnings kalodata-auth.test.mts
```

Covers: X-API-Key construction and key-slot selection (KALODATA_API_KEY
preferred, KALODATA_SECRET_KEY fallback), conflicting secret-key header
prevention, 501-in-HTTP-200 provider logical-error classification, success
envelope acceptance, v23 product response parsing shapes, balance extraction,
secret redaction / masking, and static no-paid-call checks on the probe and
balance_probe paths.

Last run 2026-11-20: 43 passed, 0 failed.

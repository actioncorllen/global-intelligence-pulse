# PULSE-ECOM-P13-META-CONVERSION-TRACKING-001

**VERDICT: PARTIAL** — server-side conversion measurement (canonical model + consent + ledger +
Meta CAPI) is real and verified; browser Pixel emission and real PURCHASE are externally blocked.

## Flow delivered
Pulse canonical commerce event → consent gate → conversion dispatch ledger → Meta CAPI
(server, token in env only) → Meta acceptance → dedup by event_id → ledger finalize →
attribution on `commerce_events` → Performance Intelligence handoff.

## Reuse map
- **REUSED:** `commerce_events` (canonical model), `fn_ingest_commerce_event`, `fn_decorate_url`,
  `fn_build_tracking_identity`, `fn_conversion_identity`, `fn_tracking_readiness`,
  `fn_performance_handoff`, global FX, `user_consent` (consent gate), `meta_tracking_config`,
  `meta_platform_config`, existing Meta executor + `marketing_campaign_executions` ledger.
- **EXTENDED:** `meta-capi-adapter` Edge Function (added `emit` path: consent + ledger + idempotency
  + PURCHASE guard); `meta_tracking_config` (pixel identity + pixel_state).
- **NEW:** `conversion_dispatch_ledger` (mig_132); `fn_meta_pixel_config` + `fn_conversion_ledger_summary`
  (mig_133); browser Pixel adapter template `pulse-meta-pixel.template.js`.
- **DEFERRED:** browser Pixel live emission (no connected storefront); real PURCHASE
  (no payment/order source).

## Canonical dataset
`954179950185340` (Smart Action Store, Direct Integration). Domain `globalintelligenceactions.com`
verified by founder. Old dataset `1337435870834827` not used. In Meta's unified model this id
serves both the browser Pixel and server CAPI.

## Deduplication
One canonical `event_id` (`pulse_<uuid>`) is shared by browser Pixel `eventID` and server CAPI
`event_id`. Ledger is idempotent on `(tenant, provider, event_id)`: a retry of an ACCEPTED event
returns `DEDUPLICATED` and is **not** resent to Meta (verified).

## Consent / privacy
Reuses `user_consent.behavioral_tracking` (tenant master switch) combined with a per-event consent
flag. Privacy-safe default: Meta transmission occurs ONLY when consent resolves to `GRANTED`;
`DENIED`/`UNKNOWN` → ledger `REJECTED`, no Meta call (verified).

## PURCHASE source of truth
No connected payment/order provider exists (0 store connections; no orders/webhook table). PURCHASE
is structurally ready but blocked: emitting a Purchase without `order_source_verified` →
`REJECTED / BLOCKED_EXTERNAL_CHECKOUT_SOURCE`. A browser signal can never be a purchase source.

## Real Meta evidence
`emit` PageView (consent granted) → HTTP 200, `events_received: 1`, `fbtrace_id`, event_id retained,
ledger `ACCEPTED`. All test events are flagged `is_test`; `accepted_non_test = 0`.

## Security
Token server-only (env), never client-side, never in DB plaintext, never in logs/responses
(scans clean), redacted error text, tenant isolation (RLS-on ledger, per-tenant config lookup,
wrong tenant → 404), dataset override rejected, idempotency/replay protection.

## Invariants
Proof campaign executions = 1 (`CREATED_PAUSED`); founder spend authority / activation /
commerce_events = 0; no advertising spend; no campaign activation; no supplier/media calls;
no recurring n8n schedule added; cost €/$0.

## Founder actions to reach full READY
1. Connect a storefront + install the Pixel (`954179950185340`) using the shared-event_id contract.
2. Connect a payment/order source of truth (Shopify order webhook / payment provider) to unblock PURCHASE.
3. (Optional) Provide a Test Event Code for clearly-TEST routing in Events Manager.

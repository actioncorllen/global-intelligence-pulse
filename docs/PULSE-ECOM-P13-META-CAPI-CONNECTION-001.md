# PULSE-ECOM-P13-META-CAPI-CONNECTION-001 — Real Meta CAPI Configuration + Verification

Completes the previously blocked real Meta tracking sub-capability from
`PULSE-ECOM-P13-CONVERSION-TRACKING-001`.

## Result
- **Provider-independent tracking foundation:** PASS (P13, unchanged).
- **Real Meta CAPI authentication + dataset acceptance:** VERIFIED (real external evidence).
- **Overall founder tracking readiness:** `PARTIAL` — CAPI verified; browser/store event
  capture not yet connected; domain verification not yet confirmed.
- **`BLOCKED_EXTERNAL_META_TRACKING_CONFIGURATION`:** CLEARED (CAPI portion).
- New remaining blockers: `BLOCKED_EXTERNAL_META_DOMAIN_VERIFICATION`,
  `BLOCKED_EXTERNAL_META_BROWSER_PIXEL_INSTALL`.

## Dataset
- Name: **Smart Action Store**, id **`954179950185340`** (Direct Integration).
- Old dataset `1337435870834827` is **not** used anywhere by Pulse CAPI.

## Secret handling
- Access token lives ONLY in the Supabase Edge Function environment secret
  `META_CAPI_ACCESS_TOKEN`. The database stores only the **reference name**, never the value.
- The adapter never returns, logs, or echoes the token; error text is redacted server-side.

## Components
- `supabase/migrations/mig_131_meta_capi_connection_config.sql` — non-secret config delta + founder row.
- `supabase/functions/meta-capi-adapter/index.ts` — server-side CAPI adapter.
  Modes: `verify` (harmless PageView/ViewContent send), `map` (build payload, no send),
  `quality` (dataset-node read), `send` (guarded non-Purchase send). Dataset is resolved
  server-side; the client cannot override it. Purchase is never transmitted in this phase.

## Real verification evidence
- `map` (Purchase): structural mapping correct (EUR/49.99, event_id preserved, no fabricated PII).
- `verify` (PageView): Meta returned **HTTP 200, `events_received: 1`, `fbtrace_id`**; event_id retained.
  Technical `external_id`/`fbp` only (no customer PII, no revenue). Sent to the live stream —
  a Test Event Code (Events Manager → Data Sources → Smart Action Store → Test Events) would
  route future verification clearly to the Test Events tab.
- Dataset-node read → `(#100) Missing Permission`: expected (CAPI-scoped token cannot read node
  metadata); does not gate event ingestion.

## Invariants (unchanged)
- Existing Meta proof campaign: `marketing_campaign_executions` still 1 (`CREATED_PAUSED`).
- Phase 11 launch authority: founder tenant has 0 spend authority / 0 activation / 0 reservations.
- Canonical Pulse events: adapter is outbound-only; founder `commerce_events` = 0 (no duplicate).
- No advertising spend, no campaign activation, no supplier/media-provider calls, no n8n schedule added.
- Cost: €/$0.

## Founder actions to reach full READY
1. **Domain verification** for `globalintelligenceactions.com` in Meta Business Settings →
   Brand Safety → Domains (DNS TXT / meta-tag / file upload). Cannot be done programmatically
   with the CAPI-scoped token.
2. **Browser Pixel install** on the storefront using dataset id `954179950185340`
   (unified Pixel+CAPI identity), plus event-dedup wiring so Pixel and CAPI share `event_id`.
3. (Optional) Provide a **Test Event Code** for clearly-TEST verification routing.

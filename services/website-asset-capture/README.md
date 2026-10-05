# Website Asset Capture (STRATELOQ-WEBSITE-ASSET-CAPTURE-001)

Smallest reusable service that captures **real** public Pulse webpages/UI as
**authoritative-candidate** visual assets for Creative Intelligence. Public routes
only. Not part of Growth Agent.

## What it is
A headless-browser capture worker (Playwright + Chromium — **real rendering, never
HTTP fetch**) plus a Supabase registration/approval contract (`mig_347`). A capture
becomes a `creative_brand_assets` row of class `UI_SCREENSHOT`, **PENDING /
non-authoritative**, until the founder approves it.

```
real public Pulse page
  → Playwright/Chromium render (JS, fonts, deterministic viewport)
  → screenshot (VIEWPORT | FULL_PAGE)  + sha256
  → validate (domain allowlist + SSRF + redirect-escape)
  → store in pulse-generated-media/website-captures/<tenant>/<date>/<hash>.png
  → fn_website_capture_register  → media_assets (source_type=WEBSITE_CAPTURE)
                                 → creative_brand_assets (UI_SCREENSHOT, PENDING, authoritative=false)
  → founder approval (fn_website_capture_set_approval APPROVE) → authoritative=true
  → Creative Director / Brand Asset Lock can now select it
```

## Files
- `validate.mjs` — pure URL/SSRF validation (allowlist, scheme, userinfo, private/reserved IPs, redirect-escape).
- `capture.mjs` — the worker. `capture({url,captureType,device,tenantId})` → `{buffer, provenance, storagePath}`; `toRegisterParams()` builds the exact RPC args. CLI included.
- `selftest.mjs` — 21 checks: validation rejections + a **real** local-fixture render proof (JS executes, 1440×1200, sha256, full-page, allowlist blocks localhost, no secrets).
- `../../supabase/migrations/mig_347_website_asset_capture.sql` — `fn__wac_host_allowed`, `fn_website_capture_register`, `fn_website_capture_set_approval`, `fn_website_capture_selftest` (26 checks), idempotency index.

## Viewport contract
- desktop `1440 × 1200`, mobile `390 × 844` (override with `--w/--h`). Capture types `VIEWPORT`, `FULL_PAGE` (`ELEMENT` reserved).

## Security
- https-only; strict host allowlist (`globalintelligenceactions.com`, `www.…`); rejects userinfo spoofs, suffix spoofs, localhost, loopback/metadata/private IPs, `file:`/`data:`/`javascript:`.
- Network-layer route guard aborts non-http(s) requests and any top-level navigation off the allowlist; final-URL redirect-escape check.
- Provenance is secret-free (no cookies/tokens/passwords/headers). Public routes only — **no authenticated workspace capture** (future unit).
- DB: SECURITY DEFINER `search_path=''`, tenant-scoped, RLS SELECT-own, service_role-only execute. Never auto-approves.

## Run (requires network egress to the Pulse host)
```bash
NODE_PATH=/opt/node22/lib/node_modules \
  node capture.mjs --url https://www.globalintelligenceactions.com/ \
       --type VIEWPORT --device desktop \
       --tenant 5351ad83-5ce8-47b1-aef6-23f64daf415f --out ./out
```
Then register (service role): call `fn_website_capture_register` with `toRegisterParams(cap,{tenantId})`
after uploading `cap.buffer` to `cap.bucketPath` (reuse the existing `Pulse - Storage Upload (base64)`
n8n workflow, server-side). Surface for review with the existing `Pulse - Sign Storage URL` workflow.
Founder approves with `fn_website_capture_set_approval(tenant, brand_asset_id, 'APPROVE')`.

## Environment note
This cloud session's egress policy denies `www.globalintelligenceactions.com` (the live
render returns `net::ERR_TUNNEL_CONNECTION_FAILED`). Run the worker from a network that can
reach the host, or add the host to the environment's **Allowed domains** (Custom network
access), then re-run — no code change needed.
```
```

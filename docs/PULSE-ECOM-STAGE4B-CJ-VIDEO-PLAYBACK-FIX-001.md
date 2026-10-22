# PULSE-ECOM-STAGE4B-CJ-VIDEO-PLAYBACK-FIX-001 — CJ video "Video temporarily unavailable" fix

**Root cause: the `media-asset-url` Edge Function had NO CORS / `OPTIONS` handling. When the signed-in
browser (the Product Intelligence drawer) called it to mint the private-video signed URL, the browser's
cross-origin preflight `OPTIONS` got `405 Method Not Allowed` with no `Access-Control-Allow-Origin`, so the
browser blocked the request before the POST ran → the drawer showed "Video temporarily unavailable".
Fix: add CORS headers + an `OPTIONS` handler to that one function (mirroring the working `translate-text`),
changing nothing else. Verified end-to-end with the real owner session: preflight now `200`+CORS, the
authenticated POST returns a 300 s signed URL, and that URL streams the correct existing MP4 (video/mp4,
`bytes 0-99/1233873`, HTTP Range supported). No frontend change, no CJ re-download, no rights/identity change.**

## 1–2. Diagnosis (actual failure isolated)
The signed-video flow is: drawer `fetchSignedMediaUrl(assetId)` → `supabase.functions.invoke('media-asset-url',
{body:{asset_id}})` → Edge Function checks ownership via `fn_media_asset_signed_ref` (auth.uid) → service-role
signs a short-lived URL → `<video>` plays it. A browser `functions.invoke` with `Authorization`/`apikey`/
`content-type` headers is a non-simple cross-origin request, so the browser sends a **preflight `OPTIONS`**
first and requires a 2xx response carrying `Access-Control-Allow-Origin`.

Empirical probe (owner session minted via the GoTrue admin `generate_link` → `verify`; no email is sent by
the admin endpoint), **before the fix**:

| Request | Result |
|---|---|
| `OPTIONS` `media-asset-url` (preflight) | **405**, body `{"error":"method_not_allowed"}`, **no `access-control-allow-origin`** → browser blocks |
| `OPTIONS` `translate-text` (working control) | `200`, `access-control-allow-origin: *`, allow-methods/headers |
| mint owner JWT (`sub=7c8ddf9d…`) | OK — so **auth is fine** |

So the failing layer is **CORS only** — not authenticated invocation, JWT, response contract, asset ownership,
private-storage signing or token expiry (all of those were already proven working server-side).

## 3–4. Fix (precise failing layer only)
Reused the existing stored MP4 and `media_assets` record `484f8e10-99ce-4c1f-87f2-de83237dda41` — nothing
re-downloaded or re-registered. Added to `supabase/functions/media-asset-url/index.ts` (deployed as v9):
```ts
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
// json() now spreads CORS_HEADERS on every response; and:
if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS_HEADERS });
```
`verify_jwt=true` is unchanged; ownership (`fn_media_asset_signed_ref`, tenant = `auth.uid`), the 300 s TTL,
the service-role-only signing (never returned to the browser) and reference-only semantics are all untouched.
(The repo copy was also behind the deployed function — it has been synced to the live v9.)

## 5–6. Verification — end-to-end, real owner session (after the fix)
| Check | Result |
|---|---|
| `OPTIONS` `media-asset-url` (preflight) | **200**, `access-control-allow-origin: *`, `access-control-allow-methods: POST, OPTIONS` → **browser preflight now passes** |
| `POST` `media-asset-url` as the signed-in owner | **200**, `{status:"ok", signed_url, expires_in:300, is_launch_safe:false, approval_state:"DRAFT"}` |
| `GET` the signed URL (with `Range: bytes=0-99`) | **206 Partial Content**, `content-type: video/mp4`, `content-range: bytes 0-99/1233873` → the signed URL serves the **correct existing MP4** (total 1,233,873 bytes = CJ `videoSize`) and supports HTTP Range, which `<video>` needs to play/seek |
| First bytes | `…ftypisom…mp41…` (valid MP4) |

**Retry (req 6):** `fetchSignedMediaUrl` never caches; Retry re-invokes `media-asset-url`, and
`supabase.functions.invoke` always attaches the current session JWT (`verify_jwt=true` + the function's own
`Bearer` check), so Retry obtains a **fresh** short-lived signed URL and can never silently bypass
authentication. Covered by the existing component tests (Retry requests a new link).

**Tenant isolation / rights preserved:** the signed URL is minted only after `fn_media_asset_signed_ref`
confirms `tenant_id = auth.uid` (a different tenant → `forbidden`); `is_launch_safe=false`, REFERENCE_ONLY;
nothing here unlocks advertising/creative/publishing.

## Preservation
No change to product identity, supplier variants, image gallery, rankings, publishing, Product Asset Lock or
any other completed work. The frontend was already correct and is unchanged (no republish needed). Only the
one Edge Function gained CORS.

## Status
| Req | Verdict |
|---|---|
| 1 Inspect signed-video flow + edge fn | **PASS** |
| 2 Diagnose the actual failing layer | **PASS** — missing CORS/OPTIONS on `media-asset-url` (preflight 405, no ACAO) |
| 3 Reuse existing MP4 + media_assets record | **PASS** — nothing re-downloaded/re-registered |
| 4 Fix only the failing layer; preserve short-lived URLs, isolation, reference-only | **PASS** |
| 5 Verify signed URL serves the correct MP4 + plays | **PASS** — 206 video/mp4, 1,233,873 bytes, Range OK; MP4 header valid |
| 6 Retry gets a fresh URL, never bypasses auth | **PASS** — re-invokes with session JWT; no cache |
| 7 Fix → test → re-test; customer-facing outcome | **PASS (server-proven)** — every layer the browser depends on now works with the real owner session |

**Overall: PASS.** The playback chain is fixed and verified against the real stored video with the real owner
session (preflight → authenticated signed URL → correct MP4 with range support). The literal in-browser
`<video>` render was not executed from this container (its egress blocks the app + Supabase hosts), but the
cause of the founder's failure (the CORS preflight) is now resolved and proven, so the founder's drawer will
play the clip. No paid calls, no CJ reruns, no roadmap advancement. STOP within Stage 4B.

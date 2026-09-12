# PULSE-ECOM-P8-PUBLIC-STOREFRONT-HTML-RENDER-FIX-001

**FINAL: PARTIAL.** Two defects were fixed in the deployed `storefront` function — the **UTF-8 mojibake**
(now fully eliminated) and the **declared Content-Type** (now `text/html; charset=utf-8` for pages,
`application/json; charset=utf-8` for API). However, **normal browser rendering on the raw functions URL
cannot be achieved on the current Supabase tier**: the default `*.supabase.co/functions/v1` domain
**forcibly rewrites any HTML page response to `text/plain` + a `default-src 'none'; sandbox` CSP** as an
anti-abuse measure — proven for BOTH `text/html` and `application/xhtml+xml`. Because the spec requires
returning PARTIAL/FAIL if browser rendering is not proven, this unit is **PARTIAL** with a proven root cause
and concrete remediation (below). No classification/economics/campaign/Nitro changes; $0 spend.

## 1. Root cause
The Supabase Edge Functions platform, on the shared `functions/v1` domain, intercepts responses whose
Content-Type is an HTML page type and **rewrites them to `Content-Type: text/plain`** while injecting
`Content-Security-Policy: default-src 'none'; sandbox`. Chrome therefore renders the bytes as plain text
(source view). The missing charset in that forced `text/plain` also caused the `â€"` mojibake. Evidence
(live headers via external n8n GET, execs 30165–30167):
- Function returned `text/html` → observed `content-type: text/plain` + sandbox CSP.
- Function returned `application/xhtml+xml` → **still** observed `text/plain` + sandbox CSP (so it is not a
  `text/html`-only rule; it is a general HTML-page sanitization).
- Function returned `application/json` → observed `application/json; charset=utf-8` (untouched).
This is a documented platform behavior; serving real HTML from Edge Functions requires a **Pro plan + custom
domain for functions**, or serving the page from a **frontend host** that consumes the JSON contract.
(Refs: Supabase discussions [#31238](https://github.com/orgs/supabase/discussions/31238),
[#35627](https://github.com/orgs/supabase/discussions/35627); [Supabase Functions
docs](https://supabase.com/docs/guides/functions/http-methods).)

## 2. Files / functions changed
`supabase/functions/storefront/index.ts` only. Fixes: (a) `x()` now entity-encodes every non-ASCII codepoint
to a numeric character reference → output is pure ASCII and cannot mojibake regardless of transport;
(b) HTML responses declare `text/html; charset=utf-8`, JSON responses `application/json; charset=utf-8`;
(c) valid HTML5 markup (self-closed void tags, `<meta name="robots" content="noindex,nofollow">`). No DB,
migration, or runtime-contract change. `fn_public_storefront_render` unchanged.

## 3. Edge Function version
`storefront` **version 3** (`verify_jwt=false`), id `b25a9480-…`. Only this function was touched.

## 4. Live HTML HTTP status
**200** (external n8n GET, `Accept: text/html`, exec 30167).

## 5. Exact HTML Content-Type
Function **declares** `text/html; charset=utf-8`. **Observed at the browser** on the functions domain:
`text/plain` (+ `content-security-policy: default-src 'none'; sandbox`) — **forced by the platform**, not the
function. This is the reason the browser shows source.

## 6. Live JSON HTTP status
**200** (`Accept: application/json`, exec 30167).

## 7. Exact JSON Content-Type
`application/json; charset=utf-8` (preserved, valid JSON, not sandboxed).

## 8. UTF-8 verification
**FIXED.** The returned body now contains only ASCII entities — em dash `&#8212;`, en dash `&#8211;`,
middot `&#183;`. No `â€"`, `â€™`, `â€œ`, `â€` sequences anywhere. Charset can no longer corrupt output.

## 9. Browser-render readiness
**NOT achievable on the raw functions URL** (platform forces `text/plain`). On any non-sandboxed host
(a Pro custom domain, or a frontend/static host), the same bytes render correctly as a responsive HTML page
(valid `<!doctype html>`, viewport, single→two-column grid at ≥760px, images, disabled checkout CTA).

## 10. Invalid / unpublished 404
Both **404** (exec 30167): invalid-format slug `/ab` and valid-but-unknown `/p000000000000`. No enumeration.

## 11. Noindex
Preserved: response header `X-Robots-Tag: noindex, nofollow` (verified on 200 and 404) **and** page
`<meta name="robots" content="noindex,nofollow">`.

## 12. Leak-scan (HTML and JSON bodies, from the actual returned responses)
**No leaks.** Absent from both bodies: `access_token`/`accessToken`, `authorization`, `service_role`,
`apikey`, JWT (`eyJ`), `user_id`, `application_ref`, supplier cost / landed cost (`28.21`, `landed`,
`supplier_cost`), internal WPS/scoring (`wps`), internal `decision_classification`, CJ credentials, and the
internal CJ PID `1980170173102026754`. Present (intended/public): public price `USD 91.79`, public CDN image
URLs, claim-safe copy. Service-role key is used only server-side and never emitted.

## 13. Runtime regression
`fn_storefront_runtime_selftest()` = **38/38 PASS**.

## 14. Publish regression
`fn_storefront_publish_selftest()` = **9/9 PASS**.

## 15–18. Safety
`campaign_created=false` · `campaign_activation=false` · `advertising_spend_authorized=0` ·
`advertising_spend=0`. Paused Meta campaign untouched. Dash cam unchanged: PUBLISHED,
QUALIFIED_TEST_NOT_HIGH_CONFIDENCE, price $91.79; supplier identity/stock/economics/decision unchanged.
Checkout remains `CHECKOUT_NOT_CONFIGURED` (disabled CTA). Nitro × US remains `PENDING_EXTERNAL_CJ_SOURCING`
(not touched).

## 19. External calls
Read-only external GETs against the endpoint via n8n (execs 30167) + the Edge Function deploy. No CJ/eBay/
DataForSEO/Meta business calls.

## 20–22. Schedules / cost
New recurring schedules **0** · cadence changes **0** (Monday + FX untouched). **Cost €0.**

## 23. Git commit
`supabase/functions/storefront/index.ts` (v3) + this report committed (see below).

## 24. Git push / divergence
Pushed to `claude/pulse-crash-recovery-b6ngey`; divergence 0 0. No force push, no history rewrite.

## 25. FINAL PASS/FAIL
**PARTIAL.** Mojibake fixed and correct Content-Types declared; 404/security/checkout/classification/
regressions all preserved. Browser rendering on the raw functions URL is **blocked by a proven Supabase
platform limitation** and cannot be fixed in-function on the current tier — hence PARTIAL, not PASS.

## Remaining blocker & remediation (founder decision — architecture/billing)
To make the storefront render in a browser, choose one (no code redesign needed; the JSON contract already
works and is the integration point):
1. **Frontend renders the JSON (recommended, no cost, matches the P8 design):** point a route in the existing
   Lovable frontend (or any static/frontend host) at
   `…/functions/v1/storefront/pae4585263fd2?format=json` and render the returned public-safe contract. This is
   the intended architecture (backend = API, frontend = HTML) and needs no plan change.
2. **Supabase Pro + custom domain for Edge Functions:** serving from a custom functions domain removes the
   text/plain sandbox, so the function's `text/html` renders directly at a branded URL (recurring cost —
   billing decision).
Both are outside this bug-fix unit's scope (billing / frontend architecture). No action taken on either.

STOP — reporting PARTIAL. Not proceeding to checkout, advertising, custom domain, or any other integration.

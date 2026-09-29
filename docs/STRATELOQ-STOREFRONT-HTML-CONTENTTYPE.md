# STRATELOQ — Public storefront renders HTML as source text (Content-Type)

**Status:** `BLOCKED_EXTERNAL_DEPENDENCY` — the defect is a Supabase Edge Functions
platform policy on the shared `*.supabase.co/functions` domain, not an internally
fixable header bug. The Edge Function response is now as correct as the platform allows.

## Root cause (proven empirically via server-side `pg_net`, not inferred)

The live GET `…/functions/v1/storefront/p45af36356648` returns **HTTP 200 with a correct
HTML body**, but the response header is **`Content-Type: text/plain`** with
**`X-Content-Type-Options: nosniff`**. Chrome therefore refuses to interpret the HTML and
shows it as raw source.

The Edge Function code explicitly sets `Content-Type: text/html; charset=utf-8`. Controlled
tests proved the **Supabase functions gateway rewrites it**:

| Content-Type set by function | Content-Type actually served |
|---|---|
| `application/json; charset=utf-8` | `application/json; charset=utf-8` ✅ |
| `text/html` | `text/plain` |
| `text/html; charset=utf-8` | `text/plain` |
| `text/html;charset=UTF-8` | `text/plain` |
| `application/xhtml+xml` | `text/plain` |

A throwaway function that set **no** `X-Content-Type-Options` still came back with
`nosniff`, proving the platform **force-adds `nosniff` too**. So on this domain:

- `text/html` is impossible (forced to `text/plain`), and
- content-sniffing is impossible (`nosniff` forced).

This is Supabase's anti-abuse policy for the shared `supabase.co` functions domain
(it must not serve arbitrary web pages). It cannot be changed from Edge Function code.

## What was fixed internally (kept)

`storefront` Edge Function **v17** (`verify_jwt=false`) now builds response headers as an
explicit `Headers` instance (`buildHeaders`) and hard-sets the Content-Type. Effect:

- The **JSON contract** (`?format=json`) is now served correctly as
  `application/json; charset=utf-8` (verified live).
- The HTML branch still sets `text/html; charset=utf-8`; the platform downgrades it to
  `text/plain`. **The moment the domain constraint is lifted (below), the page renders with
  no further code change.**

No stale content, no test banner, Product Asset Lock, claim safety, checkout-disabled and
the canonical-snapshot architecture are all unchanged (mig_340 preserved). Nothing was
published or republished.

## Unblock paths (both external to this function's code; pick one)

1. **Custom domain for Edge Functions** (Supabase Custom Domains add-on + DNS). Served from
   your own domain, the anti-phishing `text/plain` rewrite does not apply, so the existing
   `text/html` response renders directly. This keeps the "Pulse-hosted at the storefront URL"
   model with zero code change. *Infra/config decision for the founder.*
2. **Render on the app web host** using the already-correct JSON contract
   (`…/storefront/<slug>?format=json`, `application/json`, CORS enabled). The app host serves
   its own domain and can emit `text/html`. This is an app/frontend route, not a second
   backend renderer, and it consumes the same canonical contract.

Lovable is **not** the cause of this defect, so no Lovable change is being requested as the
fix; option 2 is offered only as an alternative rendering surface if a custom domain is not
desired.

## Live Nightlight state (unchanged; not republished)

`page 45af3635-… / slug p45af36356648`: `publication_state=PUBLISHED`, `has_snapshot=false`,
`published_revision_id=null`, `render_mode=LEGACY_MINIMAL_NEEDS_REPUBLISH`. Full canonical
content still requires a merchant republish (per mig_340); not done automatically.

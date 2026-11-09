# Official Domain Migration → strateloq.com (2026-11-09)

Rebrand: company = **Strateloq Technologies**, official site = **https://strateloq.com** (apex). This is a
configuration + branding correction, not a rebuild. Supabase project, database, edge functions, n8n, and all
backend identifiers are unchanged. No paid calls, billing, signup, or Product Asset Lock changes.

## Current verified state
- **strateloq.com / www.strateloq.com** — `getaddrinfo ENOTFOUND` from an independent fetch: **no DNS record
  yet**, not reachable, not yet a Lovable custom domain.
- **Legacy `www.globalintelligenceactions.com`** — still the live Lovable custom domain (HTTP 200). This is
  what production currently serves; it must stop being treated as the primary site.
- **Supabase** — project `nxaunmyihhjixxxljcqt`, name "Strateloq Technologies", `eu-central-1`,
  ACTIVE_HEALTHY. Auth callback stays on `https://nxaunmyihhjixxxljcqt.supabase.co/auth/v1/callback`
  (project-hosted; do NOT move).
- **n8n** — webhooks use Header Auth at the n8n instance URL and call Supabase/providers; **no public-web-domain
  references**, nothing to change (infra callbacks preserved).

## Done (internally controllable) — Lovable preview `20a4d3c` (NOT published)
Final branding preview SHA = **`20a4d3c`** (= `cca9344` company/canonical rebrand + the Pulse→Strateloq pass).
- Company name: "Global Intelligence Actions" → **"Strateloq Technologies"** (legal pages + site footer).
- Platform name: "Pulse Intelligence"/"Pulse" → **"Strateloq"** across the site-wide default `<title>` +
  description, the error screen, legal pages, Content Studio, Launch page, the OAuth consent screen, and the
  downloadable beta invitation. ("Pulse AI Assistant" → "Strateloq Assistant", deliberately avoiding the banned
  "Strateloq AI".)
- `og:site_name = Strateloq Technologies` site-wide; homepage + legal pages carry `<link rel="canonical">` and
  `og:url` on **https://strateloq.com/…** (paths preserved).
- No remaining customer-facing "Global Intelligence Actions", "Strateloq AI", or `globalintelligenceactions.com`.
- 583 tests pass; typecheck/lint/build clean. **Preview only**, to be published at the domain cutover.

## Left for a founder decision (surfaced, not presumed)
- **"Global Intelligence Pulse™"** — the trademarked homepage world-graphic label and the demo-modal title
  (`global-pulse-visual.tsx`, `experience-pulse-modal.tsx`). A trademarked feature name → brand decision.
- **MCP server name/descriptions** ("Pulse Intelligence" in `src/lib/mcp/`) shown to EXTERNAL AI clients (not the
  website) — rename only if the connector brand should change too.
- **Legal-entity / jurisdiction clauses (flagged, NOT altered; founder legal review):** "operated by Strateloq
  Technologies (Ireland)" (terms/privacy), "governed by the laws of Ireland / Irish courts", footer "© 2026
  Strateloq Technologies · Ireland". No company number or registered address appears; the only address (Privacy
  policy) is Ireland's data-protection regulator (correct, unchanged).
- **`.env VITE_APP_URL = https://globalintelligenceactions.com`** — currently unused by the app, but stale.
  Update to `https://strateloq.com` (or remove) in the Lovable project env when convenient.

## Founder-only steps to make strateloq.com canonical (external access required)
1. **Lovable custom domain** (Lovable dashboard → this project → Settings → Domains → Add domain →
   `strateloq.com`, and add `www.strateloq.com` if a www redirect is wanted). Lovable will display the exact DNS
   records to add — **use those exact records** (do not invent any). Set `strateloq.com` as the **primary**
   domain so Lovable issues the SSL cert and 301-redirects the other domain(s) to it.
2. **Registrar DNS** — add exactly the records Lovable shows (typically an A/ALIAS for the apex and a CNAME for
   www). Wait for DNS propagation + automatic SSL issuance (Lovable shows "verified"/"active").
3. **Publish** Lovable `cca9344` (or the latest approved commit) once the domain shows active, so the canonical
   `strateloq.com` goes live with the branding.
4. **Supabase Auth** (dashboard → Authentication → URL Configuration): set **Site URL = https://strateloq.com**;
   add `https://strateloq.com/**` (and keep the legacy entry during transition) to **Redirect URLs**. Do NOT
   change the Supabase auth callback host (`…supabase.co/auth/v1/callback`).
5. **Google OAuth** (and any other OAuth provider, Google Cloud Console → Credentials): add
   `https://strateloq.com` to **Authorized JavaScript origins**. Leave the **Authorized redirect URI**
   (`https://nxaunmyihhjixxxljcqt.supabase.co/auth/v1/callback`) **unchanged** — it is Supabase-hosted and must
   not move.
6. **Legacy redirect** — once both domains are on the Lovable project with `strateloq.com` primary, Lovable
   redirects the legacy domain to it (paths preserved). Do NOT repoint any provider webhook or OAuth callback.

## What cannot be verified from here (mark pending)
- Live strateloq.com HTTPS / homepage / workspace / login / Explorer / canonical — **pending** the founder DNS +
  domain + publish steps above (the domain does not resolve yet).
- Founder-authenticated signed-in browser checks — the container's egress to the authenticated app is
  auth-gated (same as the Stage A acceptance item).

## Access-control note (unchanged)
Public founding-member application stays accessible; direct public registration stays closed — governed by the
existing access-control backend (`mig_343_founding_registration_access_control`), untouched by this migration.

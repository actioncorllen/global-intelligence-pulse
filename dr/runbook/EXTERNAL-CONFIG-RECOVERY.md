# STRATELOQ DR — EXTERNAL CONFIGURATION RECOVERY

Non-secret operational references and the reconstruction order for external systems. **No secrets here.**

## Reconstruction order (full environment loss)
1. **Supabase project** (`nxaunmyihhjixxxljcqt`) — restore DB (pg_restore from logical backup or provider PITR),
   re-create Storage bucket `pulse-generated-media` (private), re-set edge function env, redeploy the 10 edge
   functions from `supabase/functions/*`.
2. **Secrets** — recreate per `SECRETS-RECOVERY.md` (values from operator vault / provider consoles).
3. **n8n** (`tradingb.app.n8n.cloud`) — recreate credentials (references in SECRETS-RECOVERY), import workflow
   defs (`dr/n8n/*.json` + `dr_n8n_export.sh` output), re-enable ONLY the approved schedules
   (Monday orchestrator weekly 07:00 UTC; FX daily 06:00 UTC) — see SCHEDULE recovery.
4. **Frontend** (Lovable) — the customer storefront/app is a separate Lovable project consuming the Supabase
   JSON contract; re-point it at the restored Supabase URL/keys.
5. **Meta Business** — verify Business portfolio, Page, ad account, app; keep the paused proof campaign paused;
   do not activate (see ADVERTISING-INCIDENT-RECOVERY.md).
6. **DNS / domains** — currently provider-managed subdomains (Supabase functions domain, n8n cloud, Lovable
   preview). No custom domain is configured yet; if/when added, record registrar + records here.

## External systems (IDs only where non-secret and operationally useful)
| System | Reference | Notes |
|---|---|---|
| Supabase project | `nxaunmyihhjixxxljcqt` | Postgres + Auth + Storage + Edge Functions |
| Supabase Storage bucket | `pulse-generated-media` (private) | generated media; recreate as private with image/video mime allow-list |
| n8n instance | `https://tradingb.app.n8n.cloud` | personal project `Action Ncube` |
| n8n webhooks (public URLs, not secrets) | `/webhook/pulse-product-preparation`, discovery webhook | authenticated by shared webhook secret |
| Supabase Edge public base | `https://nxaunmyihhjixxxljcqt.supabase.co/functions/v1/` | storefront, meta-capi-adapter, meta-insights-reader, invitations, discovery, prepare |
| Meta | Business portfolio / Page / ad account / app IDs | store the concrete IDs in the operator vault (kept out of Git); paused proof campaign must stay paused |
| Payment provider | none yet (placeholder) | BLOCKED_EXTERNAL — no checkout/subscriptions in scope |
| Domain / DNS | none custom yet | provider subdomains only |

## DNS/domain in repository/config
No custom domain or DNS records are represented in the repository today (provider-managed subdomains only).
Adding a Pro custom functions domain (to serve real HTML storefront) is a separate founder billing decision.

# STRATELOQ DR — SECRET RECOVERY INVENTORY (REFERENCES ONLY)

**NEVER put a secret value in this file, in Git, in any backup doc, or in an acceptance report.**
This lists WHERE each secret lives and HOW to recreate/verify it. Values live only in the provider
console + the operator's password manager.

| Reference name | System | Purpose | Where configured | Recreation source | Required scopes | Verify |
|---|---|---|---|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase | server-side full DB/storage access (edge fns, n8n) | Supabase project API settings + edge fn env + n8n `Supabase account` cred | Supabase dashboard → API → rotate | service_role | read a row via RPC as service role |
| `SUPABASE_ANON_KEY` | Supabase | public client key | Supabase API settings + edge fn env | Supabase dashboard → API | anon | anon read of a public table |
| `SUPABASE_URL` | Supabase | project URL (non-secret) | edge fn env / n8n | Supabase dashboard | n/a | reachable |
| `PULSE_DISCOVERY_WEBHOOK_SECRET` | Supabase edge ↔ n8n | authenticates discovery/prepare handoff | edge fn env + n8n Header Auth cred | regenerate + set both sides | shared secret | handoff returns 200 |
| `ISSUANCE_ALLOWED_ORIGINS` / `FOUNDER_ISSUER_AUTH_USER_IDS` | Supabase edge | CORS allow-list / founder gate (non-secret config) | edge fn env | reset by value | n/a | invitation fn behaves |
| `OpenAI account` (`openAiApi`) | n8n | real image generation (gpt-image-1) | n8n credential | platform.openai.com API keys | image generation | one bounded image gen |
| `Google Gemini(PaLM) Api` (`googlePalmApi`) | n8n | Gemini/Veo (future video) | n8n credential | Google AI Studio / Vertex | generateContent (+ Veo billing) | model list call |
| `Anthropic account` (`anthropicApi`) | n8n | Claude synthesis in workers | n8n credential | console.anthropic.com | messages | small completion |
| `CJ Dropshipping API` (`httpCustomAuth`) | n8n | supplier freight/stock/product | n8n credential | CJ developer portal | product/freight | auth + product/query |
| `Pulse eBay Production` (`httpBasicAuth`) | n8n | eBay Browse API | n8n credential | eBay developer portal | Browse | client-credentials token |
| `Pulse DataForSEO` (`httpBasicAuth`) | n8n | buyer-intent search volume | n8n credential | dataforseo.com | Google Ads data | small live query |
| `Pulse Meta System User` (`facebookGraphApi`) | n8n | Meta insights / CAPI / (future) ads | n8n credential | Meta Business → system user token | ads_read, business_management, (ads_management for launch), (pages_manage_posts for organic) | /me + /me/adaccounts |
| `Pulse Meta Ad Library User` (`facebookGraphApi`) | n8n | Ad Library intelligence | n8n credential | Meta app | ads_archive read | ads_archive probe |
| Meta CAPI token | Supabase (`meta_platform_config`/edge) | server conversions | DB config + edge env | Meta Events Manager | capi | test event |
| n8n API key | operator | DR export (`dr_n8n_export.sh`) | operator env | n8n → API settings | workflow:read | list workflows |
| `Supabase account` (n8n `supabaseApi`) | n8n | RPC + storage from workflows | n8n credential | holds SUPABASE_URL + service role | service_role | RPC 200 |
| `DR_GPG_RECIPIENT` | operator | encrypt DR backups | operator gpg keyring | operator generates gpg key | encrypt/decrypt | gpg round-trip |

**Rotation:** rotate service-role and provider keys on any suspected compromise (see
ADVERTISING-INCIDENT-RECOVERY.md and the COMPROMISED SECRET runbook scenario). After rotation, update every
place the reference is configured (edge fn env, n8n credential, DB config) and re-run the verify step.

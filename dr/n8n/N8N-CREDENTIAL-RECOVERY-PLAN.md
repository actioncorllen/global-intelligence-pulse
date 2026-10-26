# STRATELOQ DR — n8n CREDENTIAL RECOVERY PLAN

Ref: `STRATELOQ-DR-N8N-CREDENTIAL-RECOVERY-001` · Date: 2026-10-26
Companion to `dr/n8n/N8N-RESTORE-VALIDATION-001.md`.
**REFERENCES ONLY — never put a secret value in this file, in git, or in any report.**
Authoritative secret inventory + rotation steps: `dr/runbook/SECRETS-RECOVERY.md`.

---

## How credentials behave in a restore

n8n workflow exports contain credential **references** (`{id, name}`) attached to nodes — **never
secret values**. The restore (`dr_n8n_restore.sh`) imports those references as-is; the nodes show
the credential name but have no usable secret until the matching credential object is **recreated in
the restore instance and re-bound**. This was verified by `scripts/dr/dr_n8n_credential_refs.py`,
which refuses to print any field other than `{id, name}` — so even a malformed export cannot leak a
value through this tooling.

### On the "24 credential references"
A *reference* is one credential bound on one node. The same credential object is referenced by many
nodes/workflows, so the ~24 references across the 133-workflow set resolve to the **12 distinct
credential objects** below. Produce the exact, instance-specific reference list with:

```bash
python3 -I scripts/dr/dr_n8n_credential_refs.py dr/n8n/export-live
# prints each (type, name, id) + node-uses + workflow count, ending with
# DISTINCT_CREDENTIAL_REFERENCES=<n>
```

In this validation environment only the 2 committed P1 defs are present; the extractor confirms the
mechanism on them: **1 distinct reference — `supabaseApi` "Supabase account" (`jMhzgwaHX9jwZ7rA`),
3 node-uses across 2 workflows**.

---

## Credential objects to recreate (12)

Recreate each in the provider console (per `SECRETS-RECOVERY.md`), create the n8n credential of the
listed **type** with the **same name**, then re-bind it on the referencing workflows. Priority
mirrors the workflow recovery priority in `dr/n8n/N8N-WORKFLOW-INVENTORY.md`.

| # | n8n credential (name) | Type | Referenced by (examples from inventory) | Recreation source | Verify |
|---|---|---|---|---|---|
| 1 | Supabase account | `supabaseApi` | Monday Orchestrator, FX Refresher, Discovery/Prep Workers, Agent 0, Meta Draft Executor, Creative Image Gen, CJ Collector, Agent 6 Customer Content, growth agents | Supabase dashboard → API (service role); holds `SUPABASE_URL` + service_role key | RPC returns 200 as service role |
| 2 | Google Gemini(PaLM) Api | `googlePalmApi` | Discovery/Prep Workers, Agent 0, Agents 2+3 GLOBAL, growth agents | Google AI Studio / Vertex | model-list / `generateContent` call |
| 3 | Anthropic account | `anthropicApi` | Discovery Worker, Reddit Product-Attention Adapter, Agent 6 Content Generator, Agent 6 Customer Content Worker, AI Marketing Director | console.anthropic.com → API keys | small messages completion |
| 4 | Gmail (OAuth2) | `gmailOAuth2`/`googleApi` | Agent 0 (Founding Member intake), AI Marketing Director v1 | Google Cloud OAuth client → reconnect in n8n | send/list self-test mail |
| 5 | Pulse Meta System User | `facebookGraphApi` | Meta Draft Executor (PAUSED-only), Meta Ads Insights Recovery, Meta Connection Test | Meta Business → system-user token | `/me` + `/me/adaccounts` |
| 6 | Pulse Meta Ad Library User | `facebookGraphApi` | Meta Ad Library Probe | Meta app (ads_archive) | ads_archive probe |
| 7 | OpenAI account | `openAiApi` | Creative Image Generation (Manual, gpt-image-1) | platform.openai.com → API keys | one bounded image gen |
| 8 | CJ Dropshipping API | `httpCustomAuth` | CJ Supplier Collector, CJ Detail+GB Freight Probe, CJ Supplier Enrichment Probe | CJ developer portal | auth + product/query |
| 9 | Pulse eBay Production | `httpBasicAuth` | eBay Browse API Probe | eBay developer portal | client-credentials token |
| 10 | Pulse DataForSEO | `httpBasicAuth` | DataForSEO Buyer Intent Probe | dataforseo.com | small live query |
| 11 | Pulse Discovery Webhook (Header Auth) | `httpHeaderAuth` | edge ↔ n8n discovery/prepare handoff (`PULSE_DISCOVERY_WEBHOOK_SECRET`) | regenerate shared secret; set BOTH sides (edge fn env + n8n cred) | handoff returns 200 |
| 12 | Google Drive (OAuth2) ×3 | `googleDriveOAuth2Api` | DR offsite upload to `Strateloq-DR/` (see `dr/manifests/BACKUP-ARTIFACT-INDEX.md`) | Google Cloud OAuth client → reconnect | upload→download→SHA-256 parity |

> Credentials 4 and 12 are Google OAuth2 and require an interactive OAuth reconnect in the n8n UI —
> they cannot be restored headlessly. Credentials 1–3, 5–11 are key/token based and are recreated in
> the provider console then pasted into the n8n credential.

---

## Rebind procedure (per workflow)

1. Complete the DR restore (`dr_n8n_restore.sh`) — all workflows land **inactive** with their
   credential references intact but unbound.
2. In the restore instance, for each credential object above: **Credentials → New → <type>**, name it
   exactly as in the table, and enter the recreated value. (OAuth types: use the n8n "Connect"
   button to complete the flow.)
3. Open each workflow; for every node showing an unresolved credential, pick the matching recreated
   credential. `dr_n8n_credential_refs.py` lists exactly which workflows reference each credential,
   so this can be driven top‑down by credential rather than node‑by‑node.
4. Keep workflows **inactive** until an intentional cutover. Activation is a deliberate production
   step, out of scope for a DR validation restore, and must not be done against recreated credentials
   that still point at production providers unless that cutover is intended.

## Rotation / compromise
If any secret may be compromised, rotate it at the provider, then update **every** place the
reference is configured (edge-function env, n8n credential, DB config) and re-run the verify step —
see `dr/runbook/SECRETS-RECOVERY.md` and `dr/runbook/ADVERTISING-INCIDENT-RECOVERY.md`.

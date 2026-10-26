# STRATELOQ DR — n8n CREDENTIAL-RECOVERY READINESS (001)

Ref: `STRATELOQ-DR-N8N-CREDENTIAL-READINESS-001` · Date: 2026-10-26
Checkpoint after the 133-workflow restore PASS. Builds on
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md` and `dr/runbook/SECRETS-RECOVERY.md`.
**No secret values appear here. No production credential, key, or workflow was touched.**

---

## Verdict: **PARTIAL** (ready, with 2 production credentials requiring your manual action)

Every production credential has a hostable type and a documented recovery source, and the
restored instance holds zero secrets — so recovery is *ready to execute*. It is **PARTIAL**, not
PASS, only because two essential credentials recover through interactive steps that cannot (and
must not) be automated here: an **OAuth reconnect** (Gmail) and a **shared-secret regeneration on
both sides** (discovery webhook). Nothing is BLOCKED.

| Essential (production-active) credential | Type | Recovery mechanism | Readiness |
|---|---|---|---|
| Supabase account | `supabaseApi` | recreate secret key in console → paste into n8n | ✅ READY |
| Google Gemini (PaLM) Api | `googlePalmApi` | recreate API key → paste | ✅ READY |
| Anthropic account | `anthropicApi` | recreate API key → paste | ✅ READY |
| Gmail (Agent 0 intake) | `gmailOAuth2` | **interactive OAuth reconnect** | ⚠ MANUAL (you) |
| Pulse Discovery Webhook (edge ↔ n8n) | `httpHeaderAuth` | **regenerate shared secret, set on BOTH sides** | ⚠ MANUAL (you) |

Non-production credentials (their workflows are inactive; needed only at launch/cutover) are
documented and hostable too — see the second table below — including one OAuth reconnect (Google
Drive) and the AI-gateway-managed OpenAI credential.

---

## Essential credential references used by production workflows

"Production" = the ACTIVE (`active=true`) workflows in `dr/n8n/N8N-WORKFLOW-INVENTORY.md`
(Monday orchestrator, FX refresher, Business Discovery worker, Product Preparation worker, Agent 0
intake, Agents 1/2+3 GLOBAL, Agent 6 generator + customer-content worker). The distinct credentials
they reference are the five in the verdict table. The authoritative, instance-specific list is
produced by running the readiness tool against the real export set on the host (below); this report
is grounded in the committed inventory + the verified facts in the Evidence section.

---

## Secure recovery / reconnection procedure (per credential)

Full per-provider steps, scopes and verify checks are in `dr/runbook/SECRETS-RECOVERY.md` and
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md`. Summary, by recovery mechanism:

**Key / token re-entry (operator-held value → n8n), no interactive step:**
- `supabaseApi` "Supabase account" — Supabase dashboard → API keys → recreate secret (service role);
  create n8n `supabaseApi` credential with the same name; verify with an RPC that returns 200.
- `googlePalmApi` "Google Gemini(PaLM) Api" — Google AI Studio / Vertex key; verify with a model-list
  (free) call, not a paid generate.
- `anthropicApi` "Anthropic account" — console.anthropic.com API key; verify with a minimal (free)
  model-list; avoid a billed completion during a DR check.

**Interactive OAuth reconnect — requires your manual action:**
- `gmailOAuth2` "Gmail" (Agent 0 intake) — in the restore instance open the credential and use n8n's
  **Connect** button to complete Google OAuth. Cannot be scripted; no secret is exportable.

**Shared secret, set on BOTH sides — requires your manual action:**
- `httpHeaderAuth` "Pulse Discovery Webhook" (`PULSE_DISCOVERY_WEBHOOK_SECRET`) — regenerate the
  shared secret and set it in **both** the Supabase edge-function env **and** the n8n Header Auth
  credential; verify the discovery/prepare handoff returns 200. (If the real workflow validates the
  secret in-code rather than via a node credential, it still requires this both-sides manual step.)

**Non-production (inactive-workflow) credentials — documented, hostable, recover at cutover:**

| Credential | Type | Mechanism | Note |
|---|---|---|---|
| OpenAI account | `openAiApi` | key re-entry **or** AI-gateway-managed | if exported with `__aiGatewayManaged`, it is an n8n-managed credit credential: supply your own key or enable the AI gateway |
| CJ Dropshipping API | `httpCustomAuth` | key re-entry | CJ developer portal |
| Pulse eBay Production | `httpBasicAuth` | key re-entry | eBay developer portal |
| Pulse DataForSEO | `httpBasicAuth` | key re-entry | dataforseo.com |
| Pulse Meta System User | `facebookGraphApi` | token re-entry | Meta system-user token |
| Pulse Meta Ad Library User | `facebookGraphApi` | token re-entry | Meta app |
| Google Drive (DR offsite ×3) | `googleDriveOAuth2Api` | **interactive OAuth reconnect** | manual, like Gmail |

---

## Readiness verification (how it was checked — all offline, no secrets)

A committed tool, `scripts/dr/dr_n8n_credential_readiness.py`, assesses readiness from the exports
without displaying any secret, contacting any provider, modifying any credential, rotating any key,
activating any workflow, or making any paid call. It checks four dimensions per credential:

1. **Type hostable** — the credential TYPE exists in n8n 2.44.7 (checked against the committed
   registry `dr/n8n/n8n-2.44.7-credential-types.txt`, 450 types extracted from the image). A type
   not present would require a community-node install (BLOCKED).
2. **Documented** — the credential name or type appears in `SECRETS-RECOVERY.md` /
   `N8N-CREDENTIAL-RECOVERY-PLAN.md` (a recreation source is on record).
3. **Mechanism** — key / oauth2 / shared-secret / ai-gateway, driving the MANUAL flag.
4. **Production** — referenced by at least one active workflow.

Status = READY (hostable + documented + key) · MANUAL (needs an interactive/both-sides step) ·
BLOCKED (type not hostable, or no documented source). Overall = BLOCKED › PARTIAL › PASS.

### Evidence (verified in this session)
- **All 11 candidate credential types are hostable** in n8n 2.44.7 (`supabaseApi`, `googlePalmApi`,
  `anthropicApi`, `gmailOAuth2`, `googleApi`, `httpHeaderAuth`, `httpBasicAuth`, `httpCustomAuth`,
  `openAiApi`, `facebookGraphApi`, `googleDriveOAuth2Api`) — no community-node install needed.
  OAuth2 types detected: `gmailOAuth2`, `googleDriveOAuth2Api`.
- **No-secret baseline**: every restored instance checked holds `credentials_entity = 0 rows` — the
  restore carries references only, with nothing to leak and everything to recreate.
- **Tool tested**: the 2 real committed P1 defs → `supabaseApi` READY, overall **PASS**; an edge-case
  fixture correctly yields READY (key) / MANUAL (oauth2, shared-secret, ai-gateway) / BLOCKED
  (unknown type, undocumented type); output contains zero value-like tokens.

### Run it against the real 133 on the host (authoritative, read-only)
```bash
python3 -I scripts/dr/dr_n8n_credential_readiness.py \
  --exports /home/strateloqbackup/strateloq-backup/n8n-workflow-export \
  --report  ./N8N-CREDENTIAL-READINESS-RESULT.md
# exit 0 = PASS, 1 = PARTIAL (manual actions listed), 2 = BLOCKED
```

---

## Requires your manual action (cannot be automated; must not be, per the constraints)
1. **Gmail (`gmailOAuth2`)** — interactive Google OAuth reconnect in the restore instance.
2. **Discovery webhook (`httpHeaderAuth` / `PULSE_DISCOVERY_WEBHOOK_SECRET`)** — regenerate the shared
   secret and set it on both the edge-function env and the n8n credential.
3. **(Launch/cutover only) Google Drive (`googleDriveOAuth2Api` ×3)** — OAuth reconnect for DR-offsite
   upload; and decide the OpenAI path (own key vs AI-gateway-managed).

## Constraints honored
No secret values displayed; no production credential created or modified; no key rotated; no workflow
activated; no paid API call. The existing encrypted backups and the restore report
(`dr/n8n/N8N-RESTORE-VALIDATION-001.md`) are unchanged — this checkpoint only adds a readiness tool,
the credential-type registry, and this report.

# STRATELOQ DR — n8n CREDENTIAL-RECOVERY READINESS (001)

Ref: `STRATELOQ-DR-N8N-CREDENTIAL-READINESS-001` · Date: 2026-10-26 (rev. 2)
Checkpoint after the 133-workflow restore PASS. Builds on
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md` and `dr/runbook/SECRETS-RECOVERY.md`.
**No secret values appear here. No production credential, key, or workflow was touched.**

---

## Status

- **Genuine 133-export readiness run (operator host): BLOCKED** — nine credential references were
  undocumented (no recorded recovery source), which keeps the run BLOCKED by design.
- This revision makes those nine **actionable** by classifying every credential two ways — by
  **usage** (active-production / inactive / archived) and by **scope** (in Strateloq inventory vs
  co-resident out-of-scope) — so a BLOCKED that is really a *foreign* credential no longer masks the
  true Strateloq state, while a genuine Strateloq gap stays BLOCKED.

The tool does the split; the **operator re-runs it on the host** to get the refined, evidence-based
verdict (see command below). It is not asserted here which of the nine are foreign — that is read
from the host data, not invented.

### How the nine undocumented entries are handled
| If a nine-entry is… | Classified as | Readiness effect |
|---|---|---|
| referenced only by out-of-scope workflows (AI Career Copilot, Construction Quote, AI Receptionist, AI Recruitment, AI Lead Qualification, Setup Sheet Headers) | **FOREIGN** | excluded from the Strateloq verdict; recover via that project's owner, not this plan |
| referenced by an **active** Strateloq workflow | **BLOCKED** (launch-critical) | stays BLOCKED until operator supplies an evidenced source |
| referenced only by an **inactive/archived** Strateloq workflow | **BLOCKED** (historical) | stays BLOCKED, lower urgency; needed only if that workflow is revived |

The instance holds 51 cloud workflows of which the inventory marks 12+ as out-of-scope
(`dr/n8n/N8N-WORKFLOW-INVENTORY.md`); every credential *type* used by a Strateloq/Pulse workflow is
already documented. So the nine are expected to resolve mostly or wholly to FOREIGN — but that is
confirmed by the host re-run, not assumed.

---

## Essential (launch-critical) credentials — used by ACTIVE production workflows

| Credential | Type | Recovery mechanism | Readiness |
|---|---|---|---|
| Supabase account | `supabaseApi` | recreate secret key → paste into n8n | ✅ READY |
| Google Gemini (PaLM) Api | `googlePalmApi` | recreate API key → paste | ✅ READY |
| Anthropic account | `anthropicApi` | recreate API key → paste | ✅ READY |
| Gmail (Agent 0 intake) | `gmailOAuth2` | **interactive OAuth reconnect** | ⚠ MANUAL (you) |
| Pulse Discovery Webhook (edge ↔ n8n) | `httpHeaderAuth` | **regenerate shared secret, set BOTH sides** | ⚠ MANUAL (you) |

## Historical / cutover-only credentials — used only by INACTIVE/ARCHIVED workflows
Documented and hostable; recover only if the workflow is deliberately revived: Pulse Meta System
User, Pulse Meta Ad Library User (`facebookGraphApi`); OpenAI account (`openAiApi`, possibly
AI-gateway-managed); CJ Dropshipping API (`httpCustomAuth`); Pulse eBay Production, Pulse DataForSEO
(`httpBasicAuth`); Google Drive ×3 (`googleDriveOAuth2Api`, **OAuth reconnect**). Full steps:
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md`.

---

## Readiness verification (offline, no secrets)

`scripts/dr/dr_n8n_credential_readiness.py` assesses readiness from the exports without displaying a
secret, contacting a provider, modifying/rotating a credential, activating a workflow, or making a
paid call. Per credential it reports usage, scope, type-hostability (vs the committed registry
`dr/n8n/n8n-2.44.7-credential-types.txt`), documentation coverage (this plan + `SECRETS-RECOVERY.md`),
and recovery mechanism, then assigns READY / MANUAL / BLOCKED / FOREIGN and a scope-aware verdict.
Scope uses the committed allowlist `dr/n8n/strateloq-workflow-ids.txt`; with no allowlist it stays
conservative (every undocumented credential is BLOCKED).

### Evidence (verified in this session)
- **All 11 candidate Strateloq credential types are hostable** in n8n 2.44.7 (no community-node
  install needed); OAuth2 types: `gmailOAuth2`, `googleDriveOAuth2Api`.
- **No-secret baseline**: every restored instance holds `credentials_entity = 0 rows`.
- **Tool tested** on fixtures: in-scope undocumented → **BLOCKED** (kept); out-of-scope undocumented →
  **FOREIGN** (excluded); active/inactive/archived usage classified correctly; the 2 real P1 defs →
  `supabaseApi` READY, verdict **PASS**; scope-off → undocumented stays BLOCKED; output carries zero
  value-like tokens.

### Run on the host to get the authoritative, refined verdict (read-only)
```bash
python3 -I scripts/dr/dr_n8n_credential_readiness.py \
  --exports      /home/strateloqbackup/strateloq-backup/n8n-workflow-export \
  --strateloq-ids dr/n8n/strateloq-workflow-ids.txt \
  --report       ./N8N-CREDENTIAL-READINESS-RESULT.md
# exit 0 = PASS, 1 = PARTIAL (manual actions listed), 2 = BLOCKED (in-scope source unknown)
```
Each of the nine undocumented entries prints with its **usage** and **scope**. Paste the result back
to finalise: any that are in-scope stay BLOCKED and need you to supply the source; FOREIGN ones are
recorded as out-of-scope and do not block Strateloq DR. (If the inventory's truncated `KZ…` growth-agent
ids are in your export, add their full ids to the allowlist first so they are not mis-scoped.)

---

## Requires your manual action
1. **Gmail (`gmailOAuth2`)** — interactive Google OAuth reconnect in the restore instance.
2. **Discovery webhook (`httpHeaderAuth` / `PULSE_DISCOVERY_WEBHOOK_SECRET`)** — regenerate and set on
   both the edge-function env and the n8n credential.
3. **Any in-scope nine-entry the host run marks BLOCKED** — supply its evidenced recovery source
   (provider + account + scope); it is then added to the plan. Not invented here.
4. **(Launch/cutover only)** Google Drive OAuth ×3 reconnect; decide the OpenAI path (own key vs
   AI-gateway-managed).

## Constraints honored
No secret values displayed; no production credential created/modified; no key rotated; no workflow
activated; no paid API call. Existing encrypted backups and the restore report
(`dr/n8n/N8N-RESTORE-VALIDATION-001.md`) are unchanged — this checkpoint only adds usage/scope
classification to the readiness tool, the in-scope workflow-id allowlist, and these doc updates.

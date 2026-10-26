# STRATELOQ DR — n8n CREDENTIAL-RECOVERY READINESS (001)

Ref: `STRATELOQ-DR-N8N-CREDENTIAL-READINESS-001` · Date: 2026-10-26 (rev. 2)
Checkpoint after the 133-workflow restore PASS. Builds on
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md` and `dr/runbook/SECRETS-RECOVERY.md`.
**No secret values appear here. No production credential, key, or workflow was touched.**

---

## Status: **BLOCKED** (3 in-scope undocumented credentials; 6 of the 9 were out-of-scope/FOREIGN)

The genuine 133-export run flagged nine undocumented credentials. With usage+scope classification,
six resolved to **FOREIGN** (co-resident non-Strateloq workflows — excluded) and **three remain
in-scope blockers**:

| Credential | Type | Required for current ecom launch? | Status |
|---|---|---|---|
| Query Auth account | `httpQueryAuth` | No — legacy/drift-review path, not the ecom scan | ⛔ BLOCKED (source unknown) |
| Query Auth account 2 | `httpQueryAuth` | No — same path (2nd provider/backup key) | ⛔ BLOCKED (source unknown) |
| SMTP account | `smtp` | No — production email uses Gmail; SMTP is legacy | ⛔ BLOCKED (source unknown) |

**Determination:** none of the three is used by a documented launch-critical (active ecom production)
workflow; on current evidence they belong to the legacy GLOBAL trend-intelligence (drift-review) and
the legacy AI Marketing Director paths. They are **not required for current production/launch**, and
they stay **BLOCKED** because no recovery source is on record — `httpQueryAuth` and `smtp` appear
nowhere in the plan, `SECRETS-RECOVERY.md`, or the inventory. No source is invented. Full analysis,
the exact "what the founder must provide", and the drill-down command are in
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md` → "In-scope undocumented blockers — current (3)".

The six FOREIGN entries are out-of-scope and excluded from the Strateloq verdict (recover via their own
project owners). The exact per-credential workflow/node/service mapping is produced on the host with
`dr_n8n_credential_refs.py --detail` (host-only output; no secret, no path/query).

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

## Requires your (founder) action
1. **Resolve the 3 in-scope BLOCKED credentials** by supplying their recovery *source* (no secret
   values needed in the repo — just where/what):
   - `httpQueryAuth` "Query Auth account" and "Query Auth account 2" — per account: the service/API it
     authenticates (provider + endpoint host), the query-parameter name carrying the key
     (`api_key`/`key`/`token`/…), where the key is issued, and whether it is still in use or retired.
   - `smtp` "SMTP account" — SMTP host + port + security, the sending username/from-address, the SMTP
     provider that issues the password/app-password, and whether it is still used or superseded by Gmail.
   Run `dr_n8n_credential_refs.py --detail --type httpQueryAuth` (and `--type smtp`) on the host first;
   the HTTP Request **host** it prints for the query-auth nodes is the provider to recover from.
2. **Gmail (`gmailOAuth2`)** — interactive Google OAuth reconnect in the restore instance.
3. **Discovery webhook (`httpHeaderAuth` / `PULSE_DISCOVERY_WEBHOOK_SECRET`)** — regenerate and set on
   both the edge-function env and the n8n credential.
4. **(Launch/cutover only)** Google Drive OAuth ×3 reconnect; decide the OpenAI path (own key vs
   AI-gateway-managed).

Until (1) is answered the three stay **BLOCKED** (no source invented). They are **not** launch-critical
(not on the active ecom production path), so they do not block the current launch — but they remain
unrecoverable until the source is provided or the integration is confirmed retired.

## Constraints honored
No secret values displayed; no production credential created/modified; no key rotated; no workflow
activated; no paid API call; no repeat restoration test. Existing encrypted backups and the restore
report (`dr/n8n/N8N-RESTORE-VALIDATION-001.md`) are unchanged — this checkpoint adds a `--detail`
credential drill-down to the inspection tool and these documentation updates.

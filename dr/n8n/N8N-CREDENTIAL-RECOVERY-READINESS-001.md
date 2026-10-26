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

The host drill-down (`--detail`) identified what these three actually are — **superseding the earlier
inventory-only guesses** (trend collector / AI Marketing Director were wrong):

| Credential | Type | Confirmed usage (drill-down) | Recovery source (evidence) | Status |
|---|---|---|---|---|
| Query Auth account | `httpQueryAuth` | → `generativelanguage.googleapis.com` (Google **Gemini**) | Google AI Studio / Cloud **API key** (same source as `googlePalmApi`) | ⛔ BLOCKED — confirm acct↔host + project/key |
| Query Auth account 2 | `httpQueryAuth` | → `www.googleapis.com` (Google API / **YouTube**) | Google Cloud Console **API key** (confirm exact API) | ⛔ BLOCKED — confirm API + project/key |
| SMTP account | `smtp` | **ACTIVE Agent 0 intake** (`A8fTV08XOvUMq93n`) — "Send Confirmation Email", "Notify Founder" | SMTP provider — not in repo (founder vault) | ⛔ BLOCKED — source unknown |

**Determination (corrected, evidence-based):**
- **Query Auth ×2** authenticate **Google APIs by `?key=` API key**, so the recovery *source* is now
  known: a **Google Cloud / AI Studio API key** (the Gemini one is the same key source already
  documented for `googlePalmApi`). They stay BLOCKED only pending the founder confirming the exact
  account↔host mapping, which Google API the `www.googleapis.com` key targets (YouTube Data API v3 is
  the evidenced candidate), and which Cloud project/key.
- **SMTP is NOT nonessential** — it is bound in the **active** founding-member intake. But the launch
  email-**verification** gate does **not** depend on it: verification is owned by **Supabase Auth**
  (`auth.users.email_confirmed_at` / `member.email_verified`; `STRATELOQ-ECOM-PAID-ACCESS-ARCHITECTURE-AUDIT-012` §2,
  and the invitation/acceptance edge functions derive `emailVerified` only from the trusted Supabase
  Auth timestamp). The n8n SMTP nodes send the **member acknowledgement** and a **founder
  notification**; no repo-visible path (Resend/SendGrid/edge-function) supersedes them, so they still
  run through this credential while the workflow is active. SMTP stays **BLOCKED** (source unknown)
  until the founder supplies the SMTP source or confirms those two notifications are retired/moved.

All three are held BLOCKED by `dr/n8n/credential-blocked.txt` so that documenting their analysis does
not flip them to READY. No source is invented; nothing is rotated or activated. Full "what the founder
must provide" and the account-binding command are in `dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md`
→ "In-scope undocumented blockers — current (3)".

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
1. **Resolve the 3 in-scope BLOCKED credentials** by confirming their recovery *source* (no secret
   values in the repo — just where/what):
   - `httpQueryAuth` "Query Auth account" / "Query Auth account 2" — both are **Google Cloud API keys**
     (`?key=`): one for `generativelanguage.googleapis.com` (Gemini — same key source as the documented
     `googlePalmApi`), one for `www.googleapis.com` (confirm the API — YouTube Data API v3 is the
     evidenced candidate). Confirm the account↔host 1:1 (from `--detail --type httpQueryAuth`) and which
     Google Cloud project/key to reissue from.
   - `smtp` "SMTP account" — SMTP host + port + security, the sending username/from-address, the SMTP
     provider that issues the password/app-password; **or** confirm the active Agent 0 "Send Confirmation
     Email" / "Notify Founder" nodes are retired / moved to a verified path. (Email *verification* itself
     is already handled by Supabase Auth, not this credential — so launch verification is not blocked.)
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

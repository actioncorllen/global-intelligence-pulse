# STRATELOQ DR — n8n CREDENTIAL-RECOVERY READINESS (001)

Ref: `STRATELOQ-DR-N8N-CREDENTIAL-READINESS-001` · Date: 2026-10-26 (rev. 2)
Checkpoint after the 133-workflow restore PASS. Builds on
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md` and `dr/runbook/SECRETS-RECOVERY.md`.
**No secret values appear here. No production credential, key, or workflow was touched.**

---

## Status: **BLOCKED** (2 in-scope blockers remain; SMTP RESOLVED; 6 of the 9 were out-of-scope/FOREIGN)

The genuine 133-export run flagged nine undocumented credentials. Six resolved to **FOREIGN**
(co-resident non-Strateloq workflows — excluded). Of the three in-scope, **SMTP is now RESOLVED**
(founder recovered it) and **two Google query-auth credentials remain BLOCKED**:

| Credential | Type | Confirmed usage (drill-down) | Recovery source (evidence) | Status |
|---|---|---|---|---|
| Query Auth account | `httpQueryAuth` | → `generativelanguage.googleapis.com` (Google **Gemini**) | Google AI Studio / Cloud **API key** (same source as `googlePalmApi`) | ⛔ BLOCKED — confirm acct↔host + project/key |
| Query Auth account 2 | `httpQueryAuth` | → `www.googleapis.com` (Google API / **YouTube**) | Google Cloud Console **API key** (confirm exact API) | ⛔ BLOCKED — confirm API + project/key |
| SMTP account | `smtp` | **ACTIVE Agent 0 intake** (`A8fTV08XOvUMq93n`) — "Send Confirmation Email", "Notify Founder" | **Hostinger Mail** `smtp.hostinger.com:465` SSL, user `support@strateloq.com` (password in n8n/vault, not repo) | ✅ RESOLVED — **auth VERIFIED** (n8n connection test SUCCESS 2026-10-26); delivery test separate/pending |

**Determination (corrected, evidence-based):**
- **Query Auth ×2** authenticate **Google APIs by `?key=` API key**, so the recovery *source* is now
  known: a **Google Cloud / AI Studio API key** (the Gemini one is the same key source already
  documented for `googlePalmApi`). They stay BLOCKED only pending the founder confirming the exact
  account↔host mapping, which Google API the `www.googleapis.com` key targets (YouTube Data API v3 is
  the evidenced candidate), and which Cloud project/key.
- **SMTP — RESOLVED, auth verified in production.** The founder recovered the credential (Hostinger
  Mail, `smtp.hostinger.com:465` SSL, user `support@strateloq.com`) and the n8n **connection test
  passed (SUCCESS, 2026-10-26)** → SMTP **authentication is verified**. Kept separate and **still
  pending**: email **delivery** verification (sending a real message through the intake path and
  confirming receipt) — intentionally not run, as it would exercise the active production workflow.
  SMTP is **NOT nonessential** (it is on the active intake), but it is **not** the launch verification
  gate — that is Supabase Auth (`auth.users.email_confirmed_at` / `member.email_verified`;
  `STRATELOQ-ECOM-PAID-ACCESS-ARCHITECTURE-AUDIT-012` §2). The password is never stored in this repo.

The two query-auth entries are held BLOCKED by `dr/n8n/credential-blocked.txt` so that documenting
their analysis does not flip them to READY. SMTP has been removed from that list now that its source is
recorded and auth-verified. No source is invented; nothing is rotated or activated. Full detail is in
`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md` → "In-scope undocumented blockers".

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
1. **Resolve the 2 remaining in-scope BLOCKED credentials** (`httpQueryAuth` "Query Auth account" /
   "Query Auth account 2") — both are **Google Cloud API keys** (`?key=`): one for
   `generativelanguage.googleapis.com` (Gemini — same key source as the documented `googlePalmApi`),
   one for `www.googleapis.com` (confirm the API — YouTube Data API v3 is the evidenced candidate).
   Confirm the account↔host 1:1 (from `--detail --type httpQueryAuth`) and which Google Cloud
   project/key to reissue from. No secret values in the repo — just the source.
2. **SMTP account — DONE (auth).** Recovered: Hostinger Mail, `smtp.hostinger.com:465` SSL, user
   `support@strateloq.com`; n8n connection test SUCCESS (2026-10-26). **Still open (separate):** run an
   email **delivery** test — send one real message through the intake path and confirm receipt — when
   you choose to; it is intentionally not run here (it would exercise the active workflow).
3. **Gmail (`gmailOAuth2`)** — interactive Google OAuth reconnect in the restore instance.
4. **Discovery webhook (`httpHeaderAuth` / `PULSE_DISCOVERY_WEBHOOK_SECRET`)** — regenerate and set on
   both the edge-function env and the n8n credential.
5. **(Launch/cutover only)** Google Drive OAuth ×3 reconnect; decide the OpenAI path (own key vs
   AI-gateway-managed).

Until (1) is answered the two query-auth credentials stay **BLOCKED** (no source invented). They are
**not** on the active ecom production path, so they do not block the current launch — but they remain
unrecoverable until the source is provided or the integration is confirmed retired.

## Constraints honored
No secret values displayed; no production credential created/modified; no key rotated; no workflow
activated; no paid API call; no repeat restoration test. Existing encrypted backups and the restore
report (`dr/n8n/N8N-RESTORE-VALIDATION-001.md`) are unchanged — this checkpoint adds a `--detail`
credential drill-down to the inspection tool and these documentation updates.

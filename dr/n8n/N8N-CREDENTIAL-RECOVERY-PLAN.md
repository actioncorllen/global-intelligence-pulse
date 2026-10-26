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

## Launch-critical vs historical references

Classified by the **usage** of the workflows that reference them (`dr/n8n/N8N-WORKFLOW-INVENTORY.md`
Active column; confirmed per-run by `dr_n8n_credential_readiness.py`, which labels each credential
`active-production` / `inactive` / `archived`):

| Tier | Credentials | Referenced by |
|---|---|---|
| **Launch-critical** (used by ACTIVE production workflows) | Supabase account, Google Gemini, Anthropic account, Gmail, Pulse Discovery Webhook (Header Auth) | Monday orchestrator, FX refresher, Discovery/Prep workers, Agent 0, Agents 1/2+3, Agent 6 ×2 |
| **Historical / cutover-only** (used only by INACTIVE or ARCHIVED workflows) | Pulse Meta System User, Pulse Meta Ad Library User, OpenAI account, CJ Dropshipping API, Pulse eBay Production, Pulse DataForSEO, Google Drive ×3 | Meta Draft Executor (paused), Creative Image Gen, Meta/CJ/eBay/DataForSEO probes, AI Marketing Director, DR-offsite upload |

Recover launch-critical credentials first; historical ones are only needed if/when their workflow is
deliberately revived at cutover. Reviving a workflow is a separate, intentional step — this DR plan
neither activates nor rotates anything.

## Undocumented credential references (how the readiness check handles them)

`dr_n8n_credential_readiness.py` compares every credential reference in the exports against this plan
and `SECRETS-RECOVERY.md`, and against the in-scope workflow allowlist
`dr/n8n/strateloq-workflow-ids.txt`. An **undocumented** credential (name/type on no record) is handled
by **scope**, never by invention:

- **Out-of-scope (FOREIGN)** — referenced only by co-resident, non-Strateloq workflows
  (AI Career Copilot, Construction Quote, AI Receptionist, AI Recruitment, AI Lead Qualification,
  Setup Sheet Headers). These are **not Strateloq recovery items**; they belong to their own projects
  and are excluded from the Strateloq verdict. Recover them, if ever, through that project's owner and
  provider console — not from this plan.
- **In-scope and undocumented → BLOCKED and kept BLOCKED.** A Strateloq workflow referencing a
  credential with no recorded recovery source is a genuine gap. It stays BLOCKED until the operator
  supplies the evidenced source (provider + account + scope), which is then added to this plan and to
  `SECRETS-RECOVERY.md`. **Do not invent a source or mark it recoverable without evidence.** If the
  gap is on an *active* workflow it is launch-critical; if on an inactive/archived one it is a
  historical gap (lower urgency) but still BLOCKED until documented.

### In-scope undocumented blockers — current (3) — status: BLOCKED (sources now evidence-identified)

The genuine 133-export **host drill-down** (`dr_n8n_credential_refs.py --detail`) resolved what these
three actually are. This **supersedes the earlier inventory-only hypotheses** (which had guessed the
trend-collector / AI Marketing Director); use the drill-down evidence below.

| Credential | Type | Confirmed usage (host drill-down) | Recovery source (evidence) | Status |
|---|---|---|---|---|
| Query Auth account | `httpQueryAuth` | HTTP Request node → **`generativelanguage.googleapis.com`** (Google **Gemini** / Generative Language API), key passed as `?key=` | **Google AI Studio / Google Cloud API key** — the *same* source as the documented Gemini credential (`googlePalmApi`) | BLOCKED pending founder: confirm account↔host + which Cloud project/key |
| Query Auth account 2 | `httpQueryAuth` | HTTP Request node → **`www.googleapis.com`** (Google API; **YouTube Data API** per the drill-down host labeling), key as `?key=` | **Google Cloud Console → APIs & Services → Credentials → API key** with that API enabled | BLOCKED pending founder: confirm exact Google API + Cloud project/key |
| SMTP account | `smtp` | **ACTIVE founding-member intake (Agent 0, `A8fTV08XOvUMq93n`)** — nodes **"Send Confirmation Email"** and **"Notify Founder"** | SMTP provider — **host/port/account not in the repo** (lives in the n8n credential / founder vault) | BLOCKED pending founder: SMTP host/account/provider |

> Account↔host binding is read from the per-account lines of
> `python3 -I scripts/dr/dr_n8n_credential_refs.py <export-dir> --detail --type httpQueryAuth`
> (host-only output; no secret, no path/query). Paste those lines to finalise the 1:1 mapping.

**Query Auth — determination.** Both accounts authenticate **Google APIs by API key in the `key`
query parameter**. The recovery *source* is therefore known with evidence: a **Google Cloud / AI
Studio API key**. The Gemini one is the same key source already documented for `googlePalmApi`. They
remain **BLOCKED** only pending the founder confirming (a) the exact account↔host mapping, (b) which
Google API the `www.googleapis.com` key targets (YouTube Data API v3 is the evidenced candidate), and
(c) which Google Cloud project/key to reissue from. No key value is handled here; nothing is rotated.

**SMTP — determination (onboarding architecture verified, read-only).** SMTP is **NOT nonessential**:
it is bound in the **active** founding-member intake workflow. But the launch email-**verification**
gate does **not** depend on it — verification is owned by **Supabase Auth**
(`auth.users.email_confirmed_at`, mirrored by `member.email_verified`;
`docs/STRATELOQ-ECOM-PAID-ACCESS-ARCHITECTURE-AUDIT-012.md` §2, and the invitation/acceptance edge
functions derive `emailVerified` only from the trusted Supabase Auth timestamp). The n8n SMTP nodes
send the **intake acknowledgement to the member** and a **founder notification** — operational emails,
not the verification gate. No repo-visible alternative (Resend/SendGrid/Mailgun/edge-function email)
supersedes those two notifications, so on current evidence they still run through this credential while
the workflow is active. It therefore stays **BLOCKED** (source unknown) and must not be dropped as
"legacy": either the founder supplies the SMTP source, or confirms those two notifications are to be
retired / moved to a verified path (e.g. Supabase Auth email or an edge function) — a deliberate change
to the workflow, out of scope for DR.

**To clear each blocker, the founder must provide (no secret values in the repo — just the source):**
- `httpQueryAuth` (both): the exact account↔host mapping; for `www.googleapis.com`, which Google API
  it calls; the Google Cloud **project + API key** to reissue (enable Generative Language API / the
  relevant API); confirm the `key` query-param name. Both are recreated in the Google Cloud Console /
  AI Studio — the same place as the Gemini credential.
- `smtp` "SMTP account": SMTP **host + port + security**, the sending **username / from-address**, and
  the **provider** issuing the password/app-password (Gmail app-password, SendGrid, Mailgun, SES,
  Postmark, …); or confirmation the two notification nodes are retired / superseded.

Until then all three stay in `dr/n8n/credential-blocked.txt`, which forces the readiness tool to keep
them BLOCKED even now that their analysis is documented. Remove a line only when its evidenced source
is recorded above and in `SECRETS-RECOVERY.md`.

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

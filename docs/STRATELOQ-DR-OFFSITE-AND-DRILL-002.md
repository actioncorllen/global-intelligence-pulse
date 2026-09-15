# STRATELOQ-DR-OFFSITE-AND-DRILL-002

**VERDICT: `PARTIAL_PASS` — DR foundation advanced; full VERIFIED PASS still gated on two founder actions.**
Offsite destination selected from **existing** infrastructure (Google Drive — €0, no new account); the full-scale
drill is fully planned and ready; but populating the offsite backups and creating an isolated restore environment
require founder/operator action. RPO/RTO remain **TARGET (not VERIFIED)**. €0 spent; nothing purchased; no
production change; no schedule activated; no advertising/posting.

---

## 1. OFFSITE BACKUP DESTINATION
Reuse-first audit of already-connected storage (from the credential/infra inventory). Ranked:

| Rank | Destination | Existing acct? | €0? | Independent of Supabase+GitHub? | Encryption | Automation | Restore simplicity | Ongoing cost |
|---|---|---|---|---|---|---|---|---|
| **1** | **Google Drive** (connected ×3 OAuth + Drive MCP) | ✅ yes | ✅ (15 GB free) | ✅ (separate provider + account boundary) | client-side gpg before upload | n8n Google Drive node / rclone | download + gpg -d | €0 until 15 GB |
| 2 | Local/offline encrypted archive (operator downloads bundle + gpg dumps) | ✅ (operator machine) | ✅ | ✅ (fully offline) | gpg | manual | copy + gpg -d | €0 |
| 3 | GitHub Release / 2nd private repo | ✅ (same GitHub acct) | ✅ | ⚠ partial (same GitHub account) | gpg for data | gh CLI / API | download | €0 (100 MB/file cap — bundle+snapshot only, not DB data) |
| 4 | Airtable (connected) | ✅ | ✅ | ✅ | n/a | limited | poor for binaries | not suitable |
| 5 | New object storage (S3 / Backblaze B2 / Cloudflare R2) | ❌ new account | mostly free tier | ✅ | server/client | rclone/SDK | good | ~€0–5/mo | 

**Decision:** primary = **Google Drive** (existing, €0, independent), secondary = **local offline encrypted archive**.
GitHub Release is a fine third copy for the `*.bundle` + schema snapshot (small, non-secret) but not for DB data.

**Status:** destination SELECTED from existing infra — **no new account and no purchase required**, so this is
NOT a hard `BLOCKED_EXTERNAL_DR_STORAGE`. The residual is **operator action**: run `scripts/dr/*` (which need
operator-held secrets this session does not hold) with output uploaded to Google Drive, then approve recurring
automation (§5). This environment cannot itself write to the founder's personal Drive or run pg_dump (no DB
connection string, and auto-writing to a personal account is out of scope), so population is a founder/operator step.

**Founder action:** (a) create a dedicated Drive folder `Strateloq-DR/` (or reuse one); (b) run
`scripts/dr/dr_db_logical_backup.sh`, `dr_storage_backup.sh`, `dr_git_bundle.sh` and upload the encrypted outputs
there; (c) decide on §5 automation.

## 2. RECOVERY ENVIRONMENT
- Supabase org `viobdmzcngdcfjagiceb` (free) has **3 projects**: `nxaunmyihhjixxxljcqt` Global Intelligence Pulse
  (ACTIVE), `fxynkidbziobqsyjmwwr` Action Betting (INACTIVE/paused), `zhscjdnbfqwieysrkxgz` RAG AI (INACTIVE/paused).
- **New-project cost (org): €0/month** (verified via cost API). So a throwaway restore project is technically free.
- **BUT** creating a Supabase project is an irreversible provisioning action + free tier limits active projects,
  and reusing a paused project would touch the founder's other data. Per unit rules I did **not** create or alter
  anything.
- **Status: `BLOCKED_EXTERNAL_RECOVERY_ENVIRONMENT`** (founder authorization required; cost €0).
- **Exact minimal setup (founder):** Supabase dashboard → New project → org `actioncorllen@gmail.com` → name
  `strateloq-dr-restore` → region eu-central-1 → free plan → copy its connection string to the operator vault as
  `RESTORE_DB_URL`. (Do not reuse Action Betting / RAG AI.) Tear down (delete/pause) after the drill.

## 3. FULL RESTORE PLAN
Complete, step-by-step drill committed at `dr/runbook/FULL-RESTORE-DRILL-PLAN.md`:
encrypted logical DB backup → isolated pg_restore → schema (93t/370f/75p/24trg) → representative data → RLS →
functions (3 self-tests) → Auth reconciliation → Storage restore + manifest reconcile → Edge Function
deployability (10) → n8n importability → schedules (Monday+FX only) → credential references → advertising
FAIL CLOSED. No activation, no spend.

## 4. RPO / RTO
- **RPO: TARGET ≤24h — NOT VERIFIED** (requires the drill to measure backup age / data-loss window).
- **RTO: TARGET ≤4h — NOT VERIFIED** (requires the drill to measure T1→T3 recovery duration).
- Prior unit measured only restore *mechanics* (121 ms, schema-isolated). Full measurement is pending §2.

## 5. BACKUP CADENCE (recommended; NOT activated)
- **Daily** independent logical DB backup (`dr_db_logical_backup.sh`, gpg → Google Drive).
- **Daily** Storage manifest reconciliation (`dr_storage_manifest.sql`) + **weekly** full Storage byte backup
  (`dr_storage_backup.sh`); daily byte backup once generated-media volume grows.
- **Weekly** git bundle (`dr_git_bundle.sh`).
- **Expected executions/month:** ~30 DB + ~30 manifest + ~4 storage + ~4 bundle ≈ **~68/mo**.
- **Storage growth:** DB dump ≈ tens of MB compressed (dominated by 176k `trend_signals` rows); at 30-day
  retention ≈ **~0.5–1.5 GB** — well within Google Drive free 15 GB. Generated media grows with Ad Studio use.
- **API calls:** ~1 pg_dump + 1 upload/day; negligible Supabase egress.
- **Estimated monthly cost: €0** (Drive free tier; n8n executions within existing plan).
- **Retention:** 30 daily, plus keep 1 weekly for 90 days (point-in-time coverage without unbounded growth).
- **NOT ACTIVATED** — recurring production backup automation requires explicit founder approval (cost-control policy).

## 6. EXISTING SCHEDULE DRIFT — re-audit (CORRECTION)
The prior unit's "sub-weekly drift" flag was a **false alarm** on re-inspection:

| Workflow | Active | Actual trigger / cadence | Still consumed? | Duplicates Monday orchestrator? | API/cost | Recommendation |
|---|---|---|---|---|---|---|
| `vjretQJdnd3OEyd0` Agent 1 GLOBAL Trend Collector | ✅ | **Schedule "Every Monday 08:00"** (weekly, not hourly — "~620 signals/hour" is per-run throughput) | writes `trend_signals` (176,196 rows) → global trend/opportunity layer | No (ecom orchestrator uses commerce_* + registry, not trend_signals) | zero-LLM; low | **KEEP** (Monday-aligned, cadence-compliant) |
| `3CSvKgEGjSzRWpEO` Agents 2+3 Analyzer+Opportunity | ✅ | **Webhook** `pulse-agent-2-analyze` (triggered by Agent 1 → effectively Monday only) | clusters/scores → `opportunities` (global creator layer) | No | Gemini calls only when Agent 1 fires (weekly) | **KEEP** (no independent schedule) |

Both are **Monday-aligned**, so they do **not** violate the Monday-only ecom cost policy. They belong to the
original **GLOBAL creator-trend intelligence** subsystem (distinct from the ecom Monday orchestrator). Whether
that subsystem is still strategically in scope for the ecom paid-beta is a **product decision, not a DR/cost
issue** → tag **UNKNOWN_NEEDS_FOUNDER** on strategic relevance only; cadence/cost = KEEP. No change made.

## 7. MIGRATION RECOVERY GAP — canonical recommendation
Problem: **221 DB migrations vs partial repo files** (repo has ~mig_131→234; 001–130 are DB-only). Do NOT
fabricate historical migrations.

**Recommended (safest, zero production risk): adopt a canonical schema BASELINE + forward migrations.**
- Treat the committed `dr/schema/` snapshot + a `supabase db dump --schema public` (schema-only, no history
  rewrite) as the **canonical rebuild baseline** — this already reconstructs the full current schema.
- All FUTURE changes continue as committed, numbered migrations (mig_234+). The repo therefore becomes:
  *baseline snapshot (current state) + forward migrations* — replayable from today on.
- Regenerate the baseline whenever schema changes materially (script: `scripts/dr/dr_schema_snapshot.sql`), and
  keep the encrypted `pg_dump` as the data+schema recovery source of truth.
- **Do NOT** retro-write the missing 001–130 files or `supabase migration repair` against production (history
  conflict risk). An optional future "baseline squash" (mark current state as `mig_000_baseline`, existing DB
  migrations flagged applied) should be trialled in the isolated restore environment first — never on production.

## 8. Safety
No production restore, no data deletion, no project created/altered, no campaign activation, no advertising spend,
no organic posting, no Auto Launch, no CJ polling, no video-provider purchase, no subscription, no new paid
service, no schedule activated. €0.

---

## FINAL REPORT
- **OFFSITE BACKUP** — status: destination SELECTED (Google Drive, existing account); recommended destination:
  Google Drive primary + local offline archive secondary (+ GitHub Release for bundle/snapshot); cost: **€0**;
  founder action: create `Strateloq-DR/` folder + run backup scripts + upload + approve automation (§5).
- **RECOVERY ENVIRONMENT** — status: **BLOCKED_EXTERNAL_RECOVERY_ENVIRONMENT**; cost: **€0** (free project);
  founder action: create free `strateloq-dr-restore` project, share `RESTORE_DB_URL` to operator vault, tear down
  after drill (do not reuse the two paused projects).
- **FULL DRILL** — **ready** (plan committed); remaining blocker: offsite backups populated + isolated env (above).
- **RPO** — **TARGET ≤24h** (not verified).
- **RTO** — **TARGET ≤4h** (not verified).
- **BACKUP CADENCE** — recommended: daily logical DB + daily manifest / weekly storage byte + weekly bundle;
  retention 30 daily + 90-day weekly; est. **€0/mo**; **NOT ACTIVATED** (needs founder approval).
- **LEGACY SCHEDULE AUDIT** — both `vjretQJdnd3OEyd0` (weekly Mon 08:00) and `3CSvKgEGjSzRWpEO` (webhook from
  Agent 1) are Monday-aligned → **KEEP**; prior "drift" flag corrected; strategic relevance of the GLOBAL
  creator-trend subsystem = UNKNOWN_NEEDS_FOUNDER (product call, not cost). No change made.
- **MIGRATION GAP** — adopt committed schema snapshot + `pg_dump` as canonical rebuild **baseline**; continue
  forward migrations (mig_234+); never rewrite production history; trial any squash in the isolated env first.
- **DR readiness %** — ~**78%** (was ~70%): offsite selected, full drill planned, cadence costed, legacy audit
  corrected, migration path decided; remaining = populate offsite + create env + run+measure drill + activate
  (approved) backups.
- **Overall paid-beta readiness %** — recoverability ~78%; the DR blocker is now down to two clearly-scoped,
  €0 founder actions.

STOP for founder action: (1) authorize + create the free isolated restore project; (2) create the Google Drive
`Strateloq-DR/` folder, run the backup scripts, and approve the daily backup automation. On completion, run
`dr/runbook/FULL-RESTORE-DRILL-PLAN.md` to VERIFY RPO/RTO and reach full DR PASS.

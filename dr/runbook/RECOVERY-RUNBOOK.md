# STRATELOQ DISASTER RECOVERY RUNBOOK

Ref: `STRATELOQ-DR-FOUNDATION-AUDIT-AND-RECOVERY-001`. Targets **RPO ≤ 24h, RTO ≤ 4h** (not yet fully verified
end-to-end — a full isolated-environment drill is BLOCKED_EXTERNAL_RECOVERY_ENVIRONMENT). Every recovered system
must **fail closed on advertising** (no auto-activation, no spend). Never restore over production.

Companion docs: `DR-INVENTORY.md`, `SECRETS-RECOVERY.md`, `EXTERNAL-CONFIG-RECOVERY.md`,
`ADVERTISING-INCIDENT-RECOVERY.md`, `../n8n/N8N-WORKFLOW-INVENTORY.md`. Scripts: `scripts/dr/`.

Restore order (full rebuild): **DB → secrets → edge functions → storage → n8n (creds+workflows) → frontend →
verify → re-enable approved schedules only.**

---

### 1. DATABASE LOSS
- **Detect:** RPCs 5xx, tables missing, provider incident.
- **Contain:** stop writers (pause n8n active workflows); do not accept new customer writes.
- **Source:** provider PITR/backup (verify availability in dashboard) OR independent `pg_restore` from
  `dr_db_logical_backup.sh` output; schema-only fallback from `dr/schema/*.sql` + `migrations_manifest.txt`.
- **Restore:** `pg_restore` into a fresh/isolated DB, then cut over. **Never** restore over a live DB.
- **Verify:** 93 tables, 370 functions, 75 policies, 24 triggers present; run storefront/publish self-tests;
  `fn_media_creative_live_selftest`; spot-check tenancy RLS.
- **Security:** confirm RLS enabled on all expected tables; service-role not exposed.
- **Reopen:** advertising authorities remain INACTIVE/REVOKED (fail closed).
- **RPO/RTO:** ≤24h / ≤2h.

### 2. STORAGE LOSS
- **Detect:** 404s on media; `storage.objects` empty vs manifest.
- **Source:** `dr_storage_backup.sh` archive (offsite); reconcile against `dr/manifests/storage_manifest.json`.
- **Restore:** recreate bucket `pulse-generated-media` (private); re-upload objects; verify checksums (eTag) vs
  manifest; relink to `media_assets.storage_ref`.
- **Note:** DB backup does NOT contain object bytes — storage backup is mandatory.
- **RPO/RTO:** ≤24h / ≤1h.

### 3. N8N WORKFLOW LOSS
- **Source:** `dr/n8n/*.json` (P1 defs) + `dr_n8n_export.sh` output.
- **Restore:** import definitions; re-bind credentials; re-enable ONLY approved schedules (Monday weekly,
  FX daily). Leave everything else inactive/manual.
- **Verify:** Monday orchestrator + FX run manually OK; no unexpected active schedule.
- **RPO/RTO:** ≤7d (defs) / ≤2h.

### 4. N8N CREDENTIAL LOSS
- **Source:** `SECRETS-RECOVERY.md` (references) + operator vault/provider consoles.
- **Restore:** recreate each credential (OAuth reconnect / new API key), re-bind on workflows, run each
  credential's verify step.
- **RPO/RTO:** n/a / ≤2h.

### 5. GIT / DEPLOYMENT LOSS
- **Source:** GitHub remote (primary) or independent `git clone strateloq-<date>.bundle`.
- **Restore:** re-clone; redeploy edge functions (`supabase functions deploy <name>` for each of the 10);
  re-apply any missing DB migrations from the live snapshot (repo migrations alone are NOT complete — see audit).
- **RPO/RTO:** ≤minutes / ≤1h.

### 6. BAD DEPLOYMENT
- **Detect:** post-deploy errors / failing self-tests.
- **Contain:** revert to previous git commit; redeploy prior edge function version; for DB, roll forward with a
  corrective migration (never destructive rollback over production).
- **Verify:** self-tests green.
- **RPO/RTO:** ~0 / ≤30m.

### 7. COMPROMISED SECRET
- **Contain:** rotate the implicated key immediately (SECRETS-RECOVERY.md); if Meta/ads implicated, follow
  ADVERTISING-INCIDENT-RECOVERY.md (pause all + revoke authority first).
- **Reconcile:** update every configured location (edge env, n8n cred, DB config); invalidate old token.
- **Verify:** old key rejected; new key passes verify; audit trail preserved.
- **RPO/RTO:** n/a / ≤2h.

### 8. META / ADVERTISING INCIDENT
- Follow `ADVERTISING-INCIDENT-RECOVERY.md` in full (DETECT → PAUSE ALL → REVOKE → preserve → rotate →
  reconcile → verify fail-closed → founder approval → reopen). Never touch the paused proof campaign.

### 9. PARTIAL SUPABASE FAILURE (one subsystem)
- **Auth down:** app data intact; reconcile identities on recovery (auth.uid ↔ member/users bindings).
- **Storage down:** DB intact; restore storage per §2.
- **Edge down:** redeploy from git; DB/data unaffected.
- **Verify** only the affected subsystem; avoid full restore.
- **RPO/RTO:** subsystem-scoped / ≤2h.

### 10. FULL STRATELOQ ENVIRONMENT LOSS
- Execute the full restore order (top of doc). Provision a new Supabase project + n8n workspace if needed
  (founder/billing), then DB → secrets → edge → storage → n8n → frontend.
- **Verify:** all self-tests; tenancy; advertising fail-closed; approved schedules only.
- **Blocker:** a standby project/offsite encrypted store requires founder provisioning
  (BLOCKED_EXTERNAL_RECOVERY_ENVIRONMENT / BLOCKED_EXTERNAL_DR_STORAGE).
- **RPO/RTO:** ≤24h / ≤4h (target; verify once a standby exists).

---

## SCHEDULE RECOVERY (must not restore unsafe/obsolete schedules)
Re-enable ONLY:
- **Monday Ecom Orchestrator** `BBxcPXJdF2PliWgf` — weekly Monday 07:00 UTC.
- **FX Rate Refresher** `np2MUp83gaZ3C2pJ` — daily 06:00 UTC (approved exception).
All development/acceptance/probe workflows stay **manual**. Do NOT re-enable the legacy GLOBAL trend schedules
(`vjretQJdnd3OEyd0`, `3CSvKgEGjSzRWpEO`) on recovery without founder confirmation (see n8n inventory drift note).
Never restore a schedule that activates advertising or posts organically.

## RESTORE-DRILL EVIDENCE (this unit)
A schema-isolated restore drill ran non-destructively (`dr_restore_test` schema): 2 tables + data restored with
**row parity**, RLS + policy re-enabled, and a restored function executed correctly, in **121 ms**; schema then
dropped; production intact (93 tables). This proves restore MECHANICS. A full data+scale RPO/RTO measurement
needs a separate isolated environment (BLOCKED_EXTERNAL_RECOVERY_ENVIRONMENT).

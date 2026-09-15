# STRATELOQ-DR-FOUNDATION-AUDIT-AND-RECOVERY-001

**FINAL VERDICT: `PARTIAL_PASS_RECOVERY_FOUNDATION_READY`.**

An independent, non-destructive recovery foundation was built and a controlled schema-isolated restore drill
was executed and measured. Full DR PASS is not claimed: a full data-scale restore into a **separate** isolated
environment, and an independent **encrypted offsite** backup destination, both require founder provisioning
(`BLOCKED_EXTERNAL_RECOVERY_ENVIRONMENT`, `BLOCKED_EXTERNAL_DR_STORAGE`). RPO ≤24h / RTO ≤4h remain **targets,
not yet VERIFIED** (only restore mechanics were measured). €0 spent; no destructive action; no post/launch/spend.

Artifacts (this unit): `dr/schema/*` (functions/policies/triggers/rls/migrations snapshot), `dr/manifests/`
(storage manifest), `dr/n8n/*` (inventory + 2 critical workflow defs), `dr/runbook/*` (inventory, runbook,
secrets refs, external config, advertising incident), `scripts/dr/*` (git bundle, encrypted DB dump, storage
backup, n8n export, schema/manifest regen), and **7 recovered Edge Functions** now in `supabase/functions/`.

---

## Component audit (Stage 1) — status
| Component | Status | Existing backup | Independent copy | Restore tested | Est. RPO | Est. RTO |
|---|---|---|---|---|---|---|
| Git/source | PARTIALLY_PROTECTED | GitHub remote | GitHub only (bundle script added) | n/a (clone) | minutes | ≤15m |
| DB provider backup/PITR | EXTERNAL_PROVIDER_DEPENDENCY | Supabase-managed (unverified) | no | no | UNKNOWN | UNKNOWN |
| DB independent logical | PARTIALLY_PROTECTED | schema snapshot committed; data dump script | not yet offsite | mechanics ✅ | ≤24h (once scheduled) | ≤2h |
| DB schema (93t/370f/75p/24trg) | PROTECTED | `dr/schema/*.sql` | in git | drill ✅ | commit | ≤1h |
| Auth | PARTIALLY_PROTECTED | app bindings in logical backup | with DB | partial | ≤24h | ≤2h |
| Storage (`pulse-generated-media`) | PARTIALLY_PROTECTED | manifest committed; byte-backup script | not yet offsite | manifest ✅ | ≤24h | ≤1h |
| Edge Functions (10) | PROTECTED | git (7 recovered this unit) | in git | deployable | commit | ≤1h |
| n8n workflows | PARTIALLY_PROTECTED | inventory + 2 P1 defs + export script | in git | importable ✅ (def valid) | ≤7d | ≤2h |
| n8n credentials | PARTIALLY_PROTECTED | references + recovery process | vault | n/a | n/a | ≤2h |
| Secrets/config | PARTIALLY_PROTECTED | reference inventory | vault | n/a | n/a | ≤1h |
| DNS/external config | EXTERNAL_PROVIDER_DEPENDENCY | doc | n/a | n/a | n/a | ≤4h |
| Meta/advertising state | PARTIALLY_PROTECTED | app state in DB backup | with DB | fail-closed verified | ≤24h | ≤2h |
| Schedules | PROTECTED | committed defs + policy | in git | n/a | commit | ≤30m |

**Top DR finding:** the repository migrations are **not** a complete replayable schema source — **221
migrations** are applied in the DB but only ~mig_131→233 exist as repo files (001–130, incl. ad_studio 120–124,
campaign/authority 125–128, conversion 129–130, are DB-only). The live DB is effectively the sole complete
schema source. Mitigated by the committed schema snapshot + the `pg_dump` runbook; fully closing it needs the
provider logical dump stored offsite.

## Controlled restore drill (Stage 14–15) — evidence
Isolated schema `dr_restore_test` (never touched production): restored 2 representative tables **with row parity**
(`conversion_template_families` 8=8, `media_providers` 1), **re-enabled RLS + a policy**, and **created + executed
a restored function** returning correct counts — in **121 ms** — then dropped the schema; production verified
intact (93 public tables). This proves restore mechanics (schema + data + security state + function exec).
A full-scale, cross-environment RPO/RTO measurement is BLOCKED_EXTERNAL_RECOVERY_ENVIRONMENT.

## Advertising fail-closed (Stage 12) verified
`fn_pause_all_advertising` and `fn_revoke_spend_authority` present; authorities are INACTIVE/REVOKED, mode=MANUAL;
recovered/imported campaigns default to REVIEW_AND_MANUAL_LAUNCH and require Spend Authority to launch. Incident
sequence documented. Paused proof campaign untouched.

## Schedule audit (Stage 9)
Approved production schedules: Monday Ecom Orchestrator (weekly Mon 07:00 UTC) + FX Refresher (daily 06:00 UTC) —
both captured. **Drift flagged (reported, not changed):** two legacy GLOBAL trend workflows
(`vjretQJdnd3OEyd0` ~hourly, `3CSvKgEGjSzRWpEO`) are active on sub-weekly schedules — confirm intentional.

---

## FINAL REPORT (37 points)
1. **Overall verdict** — PARTIAL_PASS_RECOVERY_FOUNDATION_READY.
2. **Starting DR %** — ~15% (GitHub remote + a few edge fns in git; no schema snapshot, no manifests, no runbook, no drill).
3. **Ending DR %** — ~70% (schema snapshot, storage manifest, edge fns all in git, n8n inventory + critical defs, full runbook/inventory/secrets/external/advertising docs, backup scripts, measured restore-mechanics drill; remaining 30% = offsite encrypted store + separate restore environment + scheduled automation + full-scale RPO/RTO proof).
4. **Git/source protection** — PARTIALLY_PROTECTED (GitHub primary; clean; 0/0 divergence).
5. **Independent Git protection** — script added (`dr_git_bundle.sh`); no off-GitHub mirror yet (founder to store bundle offsite).
6. **Database backup state** — PARTIALLY_PROTECTED (independent schema snapshot in git; logical data dump is operator-run script).
7. **Provider backup state** — EXTERNAL_PROVIDER_DEPENDENCY / UNKNOWN (verify PITR/backups + retention in Supabase dashboard; not assumed).
8. **Independent logical DB backup state** — script ready (`dr_db_logical_backup.sh`, pg_dump -Fc + gpg); offsite destination BLOCKED_EXTERNAL_DR_STORAGE.
9. **Auth recovery state** — PARTIALLY_PROTECTED (app member/tenant bindings in logical backup; `auth.users` (6) export via provider/Admin API; no plaintext passwords; reconciliation documented).
10. **Storage backup state** — PARTIALLY_PROTECTED (manifest committed; byte-backup script ready; offsite BLOCKED_EXTERNAL_DR_STORAGE).
11. **generated-media recovery state** — manifest captures the 1 object (dashcam/gen-30175.png, checksum eTag, 1.18MB); reconciles to `media_assets`; byte backup via script.
12. **Edge Function recovery state** — PROTECTED; all 10 now in git (recovered 7 this unit: issue-invitation, accept-invitation, list-issuable-applications, start-discovery, prepare-product, issue-open-invitation, admin-bootstrap-demo).
13. **n8n workflow recovery state** — PARTIALLY_PROTECTED; 51 inventoried (Strateloq set classified P1–P3); 2 P1 approved-schedule defs committed; export script for the rest.
14. **n8n credential recovery state** — PARTIALLY_PROTECTED; references + recreation/verify process documented; no values stored.
15. **Secrets recovery inventory** — complete (references only) in `SECRETS-RECOVERY.md`.
16. **DNS/external configuration recovery** — documented; provider-managed subdomains only; no custom domain (EXTERNAL_PROVIDER_DEPENDENCY).
17. **Advertising incident recovery** — documented + contracts verified; fail-closed.
18. **Schedule recovery state** — PROTECTED (2 approved schedules captured; drift flagged, not changed).
19. **Recovery runbook** — complete (10 scenarios + schedule recovery + drill evidence).
20. **Restore test performed** — YES (schema-isolated, non-destructive).
21. **Restore-test evidence** — 2 tables restored, row parity, RLS+policy restored, restored function executed; schema dropped; 93 production tables intact.
22. **Measured recovery duration** — 121 ms (schema-isolated mechanics drill).
23. **Measured backup age / data-loss window** — snapshot age = time of this unit (fresh); continuous data-loss window not yet measurable without scheduled backups.
24. **Measured/estimated RPO** — estimated ≤24h once the logical backup is scheduled + offsite; **not VERIFIED**.
25. **Measured/estimated RTO** — estimated ≤4h for full rebuild; restore-mechanics ≤ minutes; **not VERIFIED** end-to-end.
26. **Unresolved external blockers** — BLOCKED_EXTERNAL_DR_STORAGE (offsite encrypted destination); BLOCKED_EXTERNAL_RECOVERY_ENVIRONMENT (separate restore project); provider PITR/retention verification; recurring backup automation approval.
27. **New recurring schedules** — 0.
28. **Schedule changes** — 0 (drift reported only).
29. **API calls / external actions** — read-only Supabase/n8n metadata + schema/manifest reads + edge-function source fetches; 1 isolated schema create/drop (non-prod); 0 external business API calls; 0 posts/launches/spend.
30. **Cost** — €0.
31. **Security/secret scan** — see commit step; no service-role/JWT/Meta/OpenAI/Gemini/CJ/n8n keys in any committed artifact (edge fns read from env; n8n defs carry references only; snapshot has no secrets).
32. **Tests** — restore drill PASS; `fn_media_creative_live_selftest` 4/4 (prior); n8n FX def re-validated as importable.
33. **Git commit** — DR artifacts + recovered edge functions committed.
34. **Git push / divergence** — pushed to `claude/pulse-crash-recovery-b6ngey`; divergence 0/0.
35. **Launch-critical gaps remaining** — (a) offsite encrypted backup destination; (b) separate restore environment for a full drill + real RPO/RTO; (c) scheduled (automated) logical DB + storage backups (founder cadence/cost approval); (d) verify Supabase provider PITR/retention; (e) close the repo-vs-DB migration gap (adopt the snapshot as source or backfill migrations).
36. **Updated overall paid-beta readiness** — recoverability foundation ~70%; a launch-critical DR blocker is materially reduced (schema, functions, storage manifest, runbook, drill) but full DR PASS pending founder-provisioned offsite + restore environment.
37. **Recommended NEXT phase** — `STRATELOQ-DR-OFFSITE-AND-DRILL-002`: founder provisions (1) an encrypted offsite store and (2) a throwaway restore Supabase project; then run a full pg_restore + storage restore drill to MEASURE and VERIFY RPO/RTO, and schedule the (approved-cost) daily logical + storage backups.

## Safety honoured
No destructive/irreversible action; no production overwrite (drill was isolated + dropped); no advertising
activation/spend; paused Meta campaign untouched; no organic post; no new/changed schedules; Monday cadence +
FX exception intact; no CJ polling; no external purchases; no secrets committed.

STOP after this unit — recovery foundation delivered; awaiting founder provisioning for the offsite store and
isolated restore environment to reach full verified DR PASS.

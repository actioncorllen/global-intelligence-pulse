# STRATELOQ DR — n8n WORKFLOW RESTORE VALIDATION (001)

Ref: `STRATELOQ-DR-N8N-RESTORE-VALIDATION-001` · Date: 2026-10-26
Scope: diagnose and fix the n8n CLI workflow-restore failure, validate an isolated
restore method, and produce credential-recovery + recovery instructions.
**No secrets in this file — credential references only.**

---

## 1. Verdict

| Item | Result |
|---|---|
| Root cause of `SQLITE_CONSTRAINT: FOREIGN KEY constraint failed` identified | ✅ PASS (reproduced deterministically) |
| Working, compatible restore method built and tested | ✅ PASS |
| Restore is isolated — execution + external access disabled, nothing activated | ✅ PASS |
| Restore of the workflow definitions available in this repo (2 P1 defs) verified | ✅ PASS (names, nodes, connections, inactive) |
| Method validated at full scale (133 workflows) and against a polluted instance | ✅ PASS |
| Credential-recovery plan for the identified credential references (no values) | ✅ PASS → `dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md` |
| Restore of the full **133 real** definitions | ⚠ GATED — see §8. The 131 non‑committed real exports are not present in this validation environment; the operator runs the shipped, verified script against the real export set on the host. |

**Overall: PASS** for every locally controllable objective. The only outstanding action is
a mechanical run of the shipped, verified tool against the real 133 exports on the host that
holds them (they were deliberately never committed to git).

---

## 2. Environment used for this validation (transparency)

This validation was executed in a **clean, isolated cloud session**, not on the operator's
Ubuntu/WSL host. Consequences, stated plainly so the evidence is not over‑read:

- The paths/containers named in the task (`/home/strateloqbackup/strateloq-backup`, the running
  Docker daemon, the `strateloq-restore-ui` container) **do not exist in this session**; it is a
  separate machine. A Docker daemon was started here and the **exact specified image
  `n8nio/n8n:2.44.7`** was pulled (digest `sha256:942bc274709f27f99f7c6024a785d8e8f75ac06838cabcba448abb8d9127ec7b`).
- Only **2 of the 133** real workflow definitions are present in this repo — the two committed P1
  defs in `dr/n8n/*.json`. The other 131 live only on the operator's host / export set and were
  not accessible here. They were **not** reconstructed or faked.
- Production n8n Cloud, Supabase, existing backups and the two committed JSON archives were **not
  modified**. No workflow was activated; no provider was contacted; no paid charge was possible
  (every import ran with `--network none` and all workflows inactive).

What this means: the **bug, the fix, and the method** are validated end‑to‑end against the real
n8n 2.44.7 engine and the real committed definitions; the **remaining 131 real definitions** are a
data‑availability gap on this host, not an unsolved problem.

---

## 3. Root cause (reproduced, not inferred)

The failure is **not** in the workflow content and **not** in the active flag of the export. It is
triggered by n8n's workflow **deactivation / publication‑teardown** path running against a workflow
row that already carries a **dangling `activeVersionId`** — an active-version pointer to a
`workflow_history` version that is absent from the target DB.

Mechanism in n8n 2.44.7 (`dist/services/import.service.js` → `dist/workflows/workflow.service.js`):

1. `ImportService.importWorkflows()` loads any existing rows for the incoming IDs and records each
   non‑null `activeVersionId` (`activeVersionIdByWorkflow`).
2. For every incoming workflow that already exists **with a non‑null `activeVersionId`**, it calls
   `WorkflowService.deactivateWorkflow(..., { source: 'import' })`.
3. `deactivateWorkflow()` → `_teardownActiveVersion()` → (with `useWorkflowPublicationService=true`,
   the **default**) `_unpublishViaOutbox()`, which inserts a `workflow_publish_history` row keyed on
   the workflow's current `activeVersionId`.
4. `workflow_publish_history.versionId` has FK `FK_b4cfbc7556d07f36ca177f5e473 → workflow_history(versionId)`.
   If that version id is not in `workflow_history`, the insert fails:
   **`SQLITE_CONSTRAINT: FOREIGN KEY constraint failed`.**

A freshly imported, **inactive** workflow has `activeVersionId = NULL`, so
`deactivateWorkflow()` returns immediately (`if (deactivatedVersionId === null) return;`) and the FK
is never exercised. That is exactly why a *simple* test workflow imports and the *real* ones (sitting
in an instance that had been booted/activated or partially imported before) do not.

### Why the earlier mitigations could not work
- **Clearing IDs / version fields in the JSON**: `deactivateWorkflow` reads `activeVersionId` from
  the **existing DB row**, not from the JSON. Editing the export cannot clear a dangling pointer that
  already exists in the restore DB.
- **`--activeState=fromJson`**: in n8n 2.44.7 this flag throws unless the instance runs in
  **queue/multi-main** mode (`import/workflow.js`: *"can only be used when n8n is running in queue or
  multi-main mode"*), so in a normal restore instance it never applies.

### Evidence — the exact failing statement (reproduced)
A clean restore DB was polluted with one dangling active version
(`UPDATE workflow_entity SET active=1, activeVersionId='deadbeef-…-doesnotexist'`) and the real FX
workflow re-imported:

```
query failed: INSERT INTO "workflow_publish_history"(..., "versionId", "event", "userId")
  VALUES (...) -- PARAMETERS: ["np2MUp83gaZ3C2pJ","deadbeef-…-doesnotexist","deactivated", <ownerId>]
error: QueryFailedError: SQLITE_CONSTRAINT: FOREIGN KEY constraint failed
An error occurred while importing workflows.          (exit code 1)
```

Relevant FK (from the live restore DB schema):
```
workflow_publish_history.versionId  ->  workflow_history(versionId)   [FK_b4cfbc7556d07f36ca177f5e473]
workflow_entity.activeVersionId     ->  workflow_history(versionId)   ON DELETE RESTRICT
```

---

## 4. The fix

Restore every workflow **inactive, with version/publication metadata stripped**, into a **fresh (or
repaired) DB**, and import **offline**. Inactive import never enters the deactivation/publish
teardown, so the FK is structurally unreachable.

Implemented as three committed, non-destructive tools (sources read-only throughout):

| Tool | Role |
|---|---|
| `scripts/dr/dr_n8n_sanitize.py` | Rewrites each export to `active:false`, keeping only `id,name,nodes,connections,settings,staticData`; strips `activeVersionId`/`versionId`/publication metadata. Credential **references** are preserved; no secret value is ever read or written. |
| `scripts/dr/dr_n8n_credential_refs.py` | Lists distinct credential references `(type,name,id)` + usage counts; asserts each reference contains only `{id,name}` so it can never surface a value. |
| `scripts/dr/dr_n8n_restore.sh` | Orchestrates the isolated Docker restore: sanitize → (optional `--repair` of a polluted DB) → `import:workflow --separate` with `--network none`, diagnostics/telemetry off, nothing activated → verify with `list:workflow`. |

`--repair` recovers an instance already left in the failing state (e.g. the existing
`strateloq-restore-ui`): with FKs off it nulls every `active`/`activeVersionId` and clears the
publication tables (`workflow_publication_outbox`, `workflow_published_version`,
`workflow_publish_history`, `workflow_publication_retry_state`), then imports cleanly.

---

## 5. What was restored and verified (real definitions present here)

Both committed P1 definitions were restored into an isolated `n8nio/n8n:2.44.7` instance via the
shipped script and verified three independent ways — direct SQLite inspection, n8n's own
`list:workflow`, and a full `export:workflow --all` round-trip.

| Workflow | ID | active | activeVersionId | nodes | conn. source‑keys | triggers | settings |
|---|---|---|---|---|---|---|---|
| Pulse — FX Rate Refresher | `np2MUp83gaZ3C2pJ` | **0 (inactive)** | NULL | 5 | 4 | Manual + Daily 06:00 UTC schedule | `executionOrder=v1, timezone=UTC` |
| Pulse — Monday Ecom Product Opportunity Orchestrator | `BBxcPXJdF2PliWgf` | **0 (inactive)** | NULL | 4 | 2 | Manual + Every Monday 07:00 UTC schedule | `executionOrder=v1` |

Instance-level invariants after restore: **active workflow count = 0**; publication tables empty;
2 ownership rows (`shared_workflow` → personal project); `import:workflow` reported *"Successfully
imported 2 workflows"* and `export:workflow --all` read both back with identical node counts and
names (incl. the em‑dash in the names). Node types, connection graph and the `supabaseApi` credential
**reference** on the Supabase ingest/orchestration nodes are preserved intact.

---

## 6. Scale + robustness validation

- **133-workflow scale:** 133 synthetic workflows shaped like the real ones (`active:true`, schedule
  + manual triggers, a `supabaseApi` credential reference, and publication metadata present) were
  sanitized and imported in one `--separate` run → *"Successfully imported 133 workflows"*,
  **133/133 inactive**, 0 active, 0 dangling `activeVersionId`, 133 ownership rows. This proves the
  method handles the full set in a single pass and never enters the FK path even when the source
  exports carry active/publication state.
- **Polluted-instance recovery:** an instance deliberately left with a dangling active version (the
  exact FK-failing condition) was recovered with `dr_n8n_restore.sh --repair` and re-imported cleanly.
- **Negative control:** importing that same dangling instance *without* the fix reproduces the exact
  `SQLITE_CONSTRAINT: FOREIGN KEY constraint failed` (§3).

---

## 7. Credential recovery

n8n exports carry credential **references** only (`{id,name}`), never values — confirmed by the
extractor's hard assertion. The two committed defs reference one credential: `supabaseApi` →
"Supabase account" (`jMhzgwaHX9jwZ7rA`), used on 3 nodes across the 2 workflows. The full identified
credential-reference set (the "24 references" across the Strateloq workflow inventory), mapped to
recreation sources with no values, is in **`dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md`**. Run
`dr_n8n_credential_refs.py` over the real export set on the host to print the authoritative
reference list for that instance.

---

## 8. Limitations / the one remaining requirement

- **Not an authentication gap, a data-availability gap:** 131 of the 133 real workflow definitions
  are not present in this validation environment (only the 2 P1 defs are committed; the rest were
  intentionally never committed to git). They must be supplied as the export set on the host where
  they exist. **Precise requirement:** a directory of the 133 real n8n workflow export JSONs (produced
  by `scripts/dr/dr_n8n_export.sh`, which needs the operator-held `N8N_BASE_URL` + `N8N_API_KEY`), on
  the host that runs the restore. With that directory, `dr_n8n_restore.sh --exports <dir>` completes
  the full restore unattended — the method is already proven on real + 133-scale inputs.
- The two committed defs' `settings` differ slightly (FX has `timezone=UTC`, orchestrator has only
  `executionOrder=v1`); both restore faithfully. This is inherited from the source exports, not the
  restore.
- The inventory notes a schedule-drift finding on two legacy GLOBAL trend workflows
  (`vjretQJdnd3OEyd0`, `3CSvKgEGjSzRWpEO`); that is a founder decision, out of scope for this restore
  unit, and nothing here changes it.

---

## 9. Exact recovery instructions (operator runbook)

Prerequisites on the restore host: `docker`, `python3`, and the n8n image
`docker pull n8nio/n8n:2.44.7`.

```bash
# 0. (first time only) produce the real export set — needs operator-held n8n creds
export N8N_BASE_URL="https://<instance>.app.n8n.cloud"
export N8N_API_KEY="<operator n8n API key>"      # secret; never commit
scripts/dr/dr_n8n_export.sh dr/n8n/export-live   # writes one JSON per workflow

# 1. restore ALL workflows into a FRESH isolated, offline, inactive instance
scripts/dr/dr_n8n_restore.sh \
    --exports dr/n8n/export-live \
    --data    ./n8n-restore-data

#    If reusing an instance that already hit the FK error (e.g. strateloq-restore-ui),
#    recover it in place instead of starting fresh:
scripts/dr/dr_n8n_restore.sh --exports dr/n8n/export-live --data ./n8n-restore-data --repair

# 2. verify (n8n's own view; all workflows must be inactive)
scripts/dr/dr_n8n_restore.sh --data ./n8n-restore-data --verify-only

# 3. recreate credentials per dr/n8n/N8N-CREDENTIAL-RECOVERY-PLAN.md, then — only when
#    an intentional cutover is wanted — activate workflows individually in the UI.
#    This DR restore leaves everything inactive and never contacts a provider.
```

The restore instance is disposable and fully isolated: no ports are published, it runs
`--network none`, telemetry/diagnostics are off, and no workflow is ever activated. Nothing in this
procedure touches production n8n Cloud, Supabase, or the existing encrypted/Drive backups.

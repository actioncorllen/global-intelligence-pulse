# Strateloq-DR-Weekly-Backup — Repair Procedure

Operational procedure to diagnose and repair a failed `Strateloq-DR-Weekly-Backup`,
take a fresh encrypted backup, and verify it is restorable. Runs **inside WSL (Ubuntu)**
as the operator user (`strateloqbackup`) on the established checkout
`/home/strateloqbackup/strateloq-dr-validate`.

Driver: `scripts/dr/strateloq-dr-repair.sh`. Windows entry point: `scripts/windows/Invoke-StrateloqDR.ps1`.

## Guarantees
- **Diagnostics first, read-only** until `--repair --approve` are both given.
- **No git checkout / branch switch / overwrite** of the working tree.
- **Preserves** existing credentials, the `Strateloq-DR-Weekly-Backup` task configuration,
  and the `strateloqdrive:` destination — the orchestrator only *reads* their presence.
- **Never** touches the production database beyond a read-only `pg_dump`, never restores
  over production, never deletes a backup, never prints a secret, never deploys Kalodata,
  never makes a paid API call.
- **No RESTORE-READY claim** unless an isolated `pg_restore` into a non-production DB
  actually succeeds.

## Steps

1. **Diagnose (read-only).** Confirm: the checkout exists; the operational backup script
   `scripts/dr/dr_db_logical_backup.sh` exists and is **non-empty**; this repair procedure
   and the recovery runbook are present; `pg_dump`/`pg_restore`/`gpg`/`rclone` are installed;
   operator secrets `SUPABASE_DB_URL` and `DR_GPG_RECIPIENT` are set (values never shown);
   the `strateloqdrive:` remote is configured. Blocking issues stop here.

2. **Approve.** The launcher requires you to type `APPROVE` (or pass `-Approve -Force`)
   before any change. Nothing mutates before this.

3. **Repair (minimal, safe).** Apply only reversible, non-credential fixes (e.g. make the
   operational backup script executable). If a blocker is an operator prerequisite (missing
   tool/secret/remote), it is **reported, not faked**.

4. **Fresh encrypted backup.** Run the established `dr_db_logical_backup.sh`
   (`pg_dump -Fc` of production, read-only → `gpg` encrypt to `DR_GPG_RECIPIENT` → shred
   plaintext). Write a secret-free manifest (sizes + `ciphertext_sha256` + timestamp) and
   upload both to the existing `strateloqdrive:Strateloq-DR/backups`.

5. **Verify restorability.** Decrypt to a `0600` temp file and run `pg_restore --list` to
   prove the archive is a valid, restorable custom-format dump (non-empty TOC). The plaintext
   is shredded immediately.

6. **Isolated restore (earns RESTORE-READY).** Only when you supply an **empty, isolated**
   database URL (`--isolated-db-url '<url>' --i-understand-isolated`, with a fail-closed guard
   that refuses any production-looking target) does the orchestrator `pg_restore` into it and
   count restored tables. **`RESTORE_OK` is printed only if that restore actually succeeds.**

## Verdict codes (relayed verbatim by the launcher)

| Verdict | Meaning |
|---|---|
| `DIAGNOSE_OK` / `DIAGNOSE_BLOCKED` | read-only health result |
| `PREREQUISITE_MISSING` | an operator tool/secret is required before a backup can run |
| `BACKUP_VERIFIED_RESTORE_PREREQUISITE` | fresh encrypted backup made + proven restorable; **isolated DB URL still needed for a full restore** |
| `BACKUP_MADE_RESTORE_UNVERIFIED` | backup made but `pg_restore` unavailable to verify TOC |
| `RESTORE_OK` | **restoration actually succeeded** into an isolated DB (the only RESTORE-READY state) |
| `RESTORE_REFUSED_PRODUCTION` / `RESTORE_NOT_ACKNOWLEDGED` | fail-closed restore guards |

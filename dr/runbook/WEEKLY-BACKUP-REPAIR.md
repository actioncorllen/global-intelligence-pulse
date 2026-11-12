# Strateloq-DR-Weekly-Backup — Repair Procedure

Operational procedure to diagnose + repair a failed `Strateloq-DR-Weekly-Backup`, take a
fresh encrypted backup, verify its Drive upload and integrity, and prove it restores — run
**inside WSL (Ubuntu)** as `strateloqbackup` on the established checkout
`/home/strateloqbackup/strateloq-dr-validate`.

Driver: `scripts/dr/strateloq-dr-repair.sh`. Windows entry point: `scripts/windows/Invoke-StrateloqDR.ps1`.

## Guarantees
- **Diagnostics first, read-only** until `--repair --approve`.
- **No git** checkout / branch switch / overwrite of the working tree.
- **Reuses** existing credentials, GPG keys/recipient and the `strateloqdrive:` connection;
  the scheduled task, credentials and Drive destination are only *read*, never changed.
- **Never** modifies production (read-only `pg_dump`); the restore target is an **ephemeral
  local** cluster only (a provided DSN is refused unless local + non-production); never deletes
  a backup; never prints a secret; never deploys Kalodata; never makes a paid API call.
- **No `RESTORE_OK`** unless the scheduled-task action + exit-code propagation, the backup
  integrity, and an actual isolated restore all pass.

## Steps

1. **Diagnose the task failure** (Windows, read-only). Task state; `LastTaskResult` decoded
   (e.g. `0x2` = the action's script path is wrong; non-zero = the invoked program returned
   that code); missed runs; recent Task Scheduler events; the task **action** and the durable
   script it invokes.
2. **Exit-code propagation self-test.** `wsl … bash -lc 'exit 7'` must surface as `7`, proving
   failures reach Task Scheduler rather than being swallowed.
3. **Verify/repair the durable + operational scripts.** Present, non-empty, `bash -n` clean,
   executable; warn if a `bash` durable script lacks `set -e` (silent-failure risk).
4. **Approve.** Type `APPROVE` (or `-Approve -Force`) before any local change.
5. **Fresh encrypted backup.** `dr_db_logical_backup.sh`: `pg_dump -Fc` (production, read-only)
   → `gpg` encrypt to `DR_GPG_RECIPIENT` → shred plaintext; write a secret-free manifest.
6. **Upload + verify upload.** `rclone copy` to `strateloqdrive:Strateloq-DR/backups`, then
   confirm the remote object exists with **matching size and hash**.
7. **Integrity.** ciphertext SHA-256 → `gpg` decrypt (0600 temp) → `pg_restore --list` (valid
   custom-format archive, non-empty TOC).
8. **Isolated restore (earns `RESTORE_OK`).** `initdb` a throwaway cluster in a temp dir
   (unix-socket only, `listen_addresses=''`, trust), `pg_ctl start`, `pg_restore` into it,
   count restored user tables, then stop + delete. `RESTORE_OK` only if tables ≥ 1.

`strateloq-dr-repair.sh --verify-artifact <file.gpg>` reruns steps 7–8 against any existing
encrypted backup (e.g. one pulled from Drive) — no production read, no upload.

## Verdicts

| Verdict | Meaning | Exit |
|---|---|---|
| `DIAGNOSE_OK` / `DIAGNOSE_BLOCKED` | read-only health | 0 |
| `PREREQUISITE_MISSING` | operator tool/secret needed before a backup | 7 |
| `UPLOAD_FAILED` / `UPLOAD_VERIFY_FAILED` | Drive upload or its verification failed | 13 |
| `ORCH_BACKUP_OK_RESTORE_PREREQUISITE` | backup made+uploaded+verified; local PG server tools missing | 0 |
| `ORCH_RESTORE_OK` | backup integrity + actual ephemeral-local restore passed | 0 |
| `ARTIFACT_RESTORE_OK` / `ARTIFACT_VERIFY_FAILED` | `--verify-artifact` restore / integrity result | 0 / 9 |

The Windows launcher prints the final `RESTORE_OK` only when `ORCH_RESTORE_OK` **and** the
task-action + exit-code-propagation checks also pass.

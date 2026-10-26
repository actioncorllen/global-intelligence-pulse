# Strateloq encrypted backup

Encrypt-before-upload, authenticated, independently verifiable backups of the
Strateloq production data (Supabase Postgres + Storage, n8n workflows, source),
satisfying the mandatory backup-encryption policy.

## What it does (policy mapping)

| Policy req | How it's met |
|---|---|
| 1. AES-256-GCM / established AEAD | `aesgcm_stream.py` — streaming **AES-256-GCM** (1 MiB frames, per-frame nonce, header bound as AAD, final-frame flag to detect truncation). `age`/ChaCha20-Poly1305 is a fine alternative if you prefer. |
| 2. Encrypt locally **before** upload | The archive is encrypted on disk first; only the `.sgcm` ciphertext + its `.sha256` are ever uploaded. Google Drive's own encryption is never relied on alone. |
| 3. Strong, unique key from a CSPRNG | You generate a 256-bit key with a CSPRNG (command below). |
| 4. Key stored separately in your password manager; never uploaded/logged | The key is read **only** from `$BACKUP_KEY` and is never printed, written to disk, or uploaded. It must live in *your* password manager. |
| 5. Never create an archive with an unrecoverable key — STOP if no secure handoff | The script **aborts before producing anything** if `$BACKUP_KEY` is missing or malformed. |
| 6. SHA-256 checksums + auth-tag verification + isolated test-decrypt | After encrypting, it writes + verifies a SHA-256, then **really decrypts** into an isolated temp dir (auth tag checked), confirms the decrypted SHA matches the original, and test-extracts the tar. |
| 7. Securely remove plaintext temp; preserve production | All plaintext temp is `shred`-deleted on exit (even on error, via a trap). Every production operation is **read-only** (pg_dump, storage GET, workflow GET, git bundle). |
| 8. No "BACKUP COMPLETE" until upload + integrity + recoverability verified | It prints `BACKUP READY (local)` after local verify, and only `BACKUP COMPLETE` once the encrypted file is confirmed uploaded. |

## Where it must run

**Not** from the Claude Code chat container: that environment's egress to the
Supabase hosts is policy-denied, and environment secrets only load into a *new*
session. Run it where the production data and the key are both reachable:

- **Recommended:** your own machine or a controlled server, with the source
  credentials and `BACKUP_KEY` provided as local environment variables sourced
  from your password manager / secret store.
- **Alternative:** a fresh Claude Code cloud session with (a) `BACKUP_KEY` and
  the source credentials added as **environment secrets**, and (b) **Network
  access** widened to the Supabase host. (See the cloud-environment settings:
  environment menu in the session title bar → Edit → Network secrets / Network
  access.) The key is then read from the env var and never printed.

Either way, the script itself is identical and the key never transits chat or logs.

## One-time setup

1. **Generate a 256-bit key** (CSPRNG) and copy the output into a **new secret
   entry in your password manager** (e.g. 1Password / Bitwarden), labelled
   `STRATELOQ_BACKUP_KEY`:
   ```sh
   python3 -c 'import os,base64;print(base64.b64encode(os.urandom(32)).decode())'
   ```
   Do **not** paste this value into chat, a ticket, a commit, or any log. The
   backups are unrecoverable without it, and anyone who has it can decrypt them.

2. **Keep a second copy** in a separate secure location you control (e.g. an
   offline/break-glass entry). Losing the key = losing the backups.

3. On the backup host, provide the key and the source credentials as env vars
   (sourced from your secret store at run time, not hard-coded):
   - `BACKUP_KEY` — the value from step 1
   - `SUPABASE_DB_URL` — Postgres connection string (prefer a **read-only** role)
   - `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` — for Storage export
   - `N8N_BASE_URL` + `N8N_API_KEY` — for workflow export
   - optional `BACKUP_RCLONE_REMOTE` (e.g. `gdrive:Strateloq/backups`) with
     `rclone` configured for Google Drive, and `BACKUP_OUT_DIR`

   Each source is **optional** — if its vars are unset, that source is skipped
   with a notice (so you can back up just the DB, say).

## Run

```sh
# dry run: collect + package + verify the key gate, then shred (no encrypt/upload)
BACKUP_KEY=... SUPABASE_DB_URL=... ./strateloq-backup.sh --dry-run

# real backup
BACKUP_KEY=... SUPABASE_DB_URL=... SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
N8N_BASE_URL=... N8N_API_KEY=... BACKUP_RCLONE_REMOTE=gdrive:Strateloq/backups \
  ./strateloq-backup.sh
```

If no `rclone` remote is set, the verified `.sgcm` + `.sha256` are left in
`BACKUP_OUT_DIR` (default `./backup-out`) for you to upload to Google Drive by
whatever means you control. Recovery is documented in `RESTORE.md`.

## Uploading to Google Drive without rclone

`rclone` is the simplest, but any method works since the file is already
encrypted: the Drive web UI, `gdrive`, the Drive API, or a Claude Code session
that has the Google Drive connector (hand it the `.sgcm` + `.sha256`). **Never**
upload `BACKUP_KEY` alongside the archive, and keep the Drive folder restricted.

## Files

- `aesgcm_stream.py` — streaming AES-256-GCM encrypt/decrypt + `selftest`.
- `strateloq-backup.sh` — orchestrator (collect → package → encrypt → checksum →
  verify → upload → shred plaintext).
- `storage_export.py`, `n8n_export.py` — read-only exporters.
- `RESTORE.md` — recovery procedure (test it periodically).

## Verified

The crypto + orchestration were proven on **synthetic data with throwaway keys**
(never a real backup key, never production data): `selftest` passes (round-trip
across 7 sizes, tamper-detect, truncation-detect); a full orchestrator run
produced an encrypted archive, verified its SHA-256, test-decrypted + extracted
it, and a fresh-shell decrypt restored it byte-for-byte; a wrong key fails closed;
plaintext temp is shredded. The missing-key and malformed-key gates both abort
before producing any archive.

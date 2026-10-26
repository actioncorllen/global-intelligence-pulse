# PULSE-ECOM-BACKUP-ENCRYPTION-001 — Mandatory backup encryption

**A vetted, authenticated, encrypt-before-upload backup routine now exists in the repo
(`scripts/backup/`), implementing all 8 mandatory requirements. The crypto and orchestration are
proven on synthetic data with throwaway keys. It is NOT yet run against production, and no
"BACKUP COMPLETE" is claimed, because two founder-controlled preconditions are outstanding: (1) the
256-bit key must be generated into the founder's password manager and supplied as a secret
(`BACKUP_KEY`), and (2) the routine must run where production is reachable — which this Claude Code
chat container is not (its egress to Supabase is policy-denied and environment secrets load only in a
new session). Per requirement 5, I stopped before producing any encrypted archive rather than create
one with a key the founder cannot retrieve.**

## Key-handoff decision
The founder chose **"You hold the key; supply as secret."** Accordingly the routine reads the key
**only** from `$BACKUP_KEY`; it is never printed, written to disk, uploaded, or placed in chat/logs.
I never generate or hold the founder's key.

## Why it does not run from this session (honest blocker)
- Environment **secrets load only into a new session**, so a `BACKUP_KEY` added now is invisible here.
- Network **egress to the Supabase/app hosts is policy-denied** in this container, so it cannot reach
  the production DB or Storage to dump them.
- Pulling the production DB/Storage through the chat channel would also risk exposing sensitive data
  in logs — contrary to the policy.

So the routine is designed to run on a host the founder controls (or a fresh cloud session with
egress widened + secrets configured). See `scripts/backup/README.md`.

## Requirement status
| Req | Status | Evidence |
|---|---|---|
| 1 AES-256-GCM / established AEAD | **PASS (implemented+tested)** | `aesgcm_stream.py` streaming AES-256-GCM; `selftest` passes (round-trip ×7 sizes, tamper-detect, truncation-detect) |
| 2 Encrypt locally before upload; not Drive-only | **PASS (implemented)** | only the `.sgcm` ciphertext + `.sha256` are ever uploaded |
| 3 Strong unique key via CSPRNG | **PASS (documented)** | `os.urandom(32)` generation command in README; founder generates it |
| 4 Key in founder's password manager; never uploaded/logged | **PASS (enforced)** | key read only from `$BACKUP_KEY`; never printed/stored/uploaded |
| 5 Never create an unrecoverable archive; STOP if no secure handoff | **PASS (enforced)** | missing/malformed key → **abort before any archive**; verified in test |
| 6 SHA-256 + auth-tag verify + isolated test-decrypt/extract | **PASS (implemented+tested)** | orchestrator writes+verifies SHA-256, test-decrypts into isolated dir, matches SHA, test-extracts |
| 7 Secure plaintext removal; preserve production | **PASS (implemented+tested)** | `shred` trap on exit (0 leftover in tests); all prod ops read-only |
| 8 No "BACKUP COMPLETE" until upload+integrity+recoverability verified | **PASS (enforced)** | prints `BACKUP READY (local)` until upload confirmed; `BACKUP COMPLETE` only after remote hash check |
| **Live production backup executed** | **BLOCKED (on founder)** | awaits `BACKUP_KEY` secret + a run location with Supabase egress |

## Verification performed (synthetic only)
- `selftest`: round-trip across 7 sizes, tamper-detection, truncation-detection — **PASS**.
- Full orchestrator run (throwaway key, git-bundle source, no prod creds): encrypt →
  **SHA-256 verified** → **isolated test-decrypt + auth-tag + extraction OK** → `BACKUP READY (local)`.
- Fresh-shell independent decrypt restored the archive byte-for-byte (SHA match) and extracted it.
- Wrong key → fail-closed (exit 5, auth-tag error). Missing/malformed key → abort before any output.
- Plaintext temp shredded (0 leftover); output files `0600`.

**No production data was read, no secrets were handled, nothing was uploaded, and no production system
was modified.** `age`/ChaCha20-Poly1305 is a documented alternative; the implemented path is the
AES-256-GCM the policy names.

## Remaining founder actions (to run a real backup)
1. Generate the 256-bit key into your password manager (command in README) + keep a break-glass copy.
2. Provide `BACKUP_KEY` and the source credentials to the backup host (local env or new-session
   environment secrets; widen Network access to Supabase if using a cloud session).
3. Run `scripts/backup/strateloq-backup.sh`; confirm it prints verification OK, then upload the
   `.sgcm` + `.sha256` to Google Drive (or set `BACKUP_RCLONE_REMOTE`).
4. Periodically rehearse `RESTORE.md` on a scratch host.

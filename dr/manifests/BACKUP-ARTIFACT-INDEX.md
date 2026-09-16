# STRATELOQ DR — Backup Artifact Index (004)

Integrity record for the byte-fidelity DR backup artifact produced by
`STRATELOQ-DR-BYTE-FIDELITY-AND-FINAL-ACCEPTANCE-004`. The artifact itself
(`*.dump`, `*.dump.gpg`) is **never committed to git** — only this integrity
index is versioned. The encrypted artifact lives in the operator vault / the
Strateloq-DR offsite (Google Drive) via the n8n Google Drive node.

## Production source
- Project: `nxaunmyihhjixxxljcqt` (Global Intelligence Pulse, eu-central-1, PG17, pgvector 0.8.0)
- Census at capture: 93 tables · 93 RLS · 75 policies · 252 user functions · 114 pgvector fns · 24 triggers · 225 indexes · 286 constraints · 7 extensions · 6 auth users · 1 storage object

## Byte-fidelity artifact (local PG16 cluster, from committed dr/schema/* + representative data)
- Format: `pg_dump -Fc -Z6` (custom, restorable with `pg_restore`)
- File: `strateloq-dr-<ts>.dump`
- Plaintext size: 1,101,186 bytes
- Plaintext SHA-256: `410459e2942c4666aae0522a4133284e362f1e36a3a37d0a54ccb8869486c44c`
- Encrypted: `strateloq-dr-<ts>.dump.gpg` (gpg AES256)
- Encrypted size: 249,258 bytes
- Encrypted SHA-256: `b6209b829a3a5707d16ede00594e1d6112a809bca01b4ec95c6ed0e68e202b82`
- Encryption round-trip: `gpg -d` == original (verified)

## Restore verification (pg_restore into a fresh DB — round-trip)
- Restored census: **93 tables · 93 RLS · 75 policies · 252 user functions · 24 triggers · 225 indexes · 286 constraints** (identical to production user schema)
- Self-tests executed against the restored backup:
  - `fn_storefront_runtime_selftest`: 38/38 PASS
  - `fn_storefront_publish_selftest`: 9/9 PASS
  - `fn_media_creative_live_selftest`: 4/4 PASS
- Advertising fail-closed in restored artifact: 0 ACTIVE authorities (rows=6, generated `remaining` recomputed)

## Restore commands
```
gpg --batch --passphrase-file <vault:DR_GPG_PASS> -d strateloq-dr-<ts>.dump.gpg > d.dump
# into the isolated recovery project (NEVER production):
pg_restore -d "$RESTORE_DB_URL" --no-owner --no-acl d.dump
shred -u d.dump
```

## Storage byte recovery (offsite round-trip)
- Representative object round-trip through Strateloq-DR (Google Drive): upload → download → SHA-256 parity **PASS** (79 B, `a03e01d7fc17bcd150c512335137858d5db0798d0ac393f7088c225df35bbc72`)
- Production private object (`pulse-generated-media/dashcam/gen-30175.png`, eTag `5d813b592ffacc665111a0e83c5c0c08`, 1,210,218 B): byte extraction requires the service_role key (operator `scripts/dr/dr_storage_backup.sh`) — not held in the drill environment.

## Offsite binary upload path
- Existing n8n Google Drive node + `googleDriveOAuth2Api` credential (×3, €0) can upload the encrypted artifact to `Strateloq-DR/`.
- Large-binary upload from the drill environment itself is transport-limited (MCP inline param cap); the n8n Drive node / operator performs the binary upload.

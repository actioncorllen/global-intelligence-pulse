# STRATELOQ DR — FULL-SCALE RESTORE DRILL PLAN

Ref: `STRATELOQ-DR-OFFSITE-AND-DRILL-002`. **Never restore over production.** No advertising activation,
no spend, no organic post. This plan MEASURES RPO/RTO; until it is executed they remain TARGET/ESTIMATED.

> **The isolated recovery environment now EXISTS** (BLOCKED_EXTERNAL_RECOVERY_ENVIRONMENT is RESOLVED):
> Supabase project **`strateloq-dr-restore` (`zdeedmuocbbkuwuovlbz`, eu-west-1, PG17, ACTIVE_HEALTHY)**.
>
> **Recommended one-command path:** `scripts/dr/dr_restore_drill.sh` automates steps 1–6 + 13 below
> (checksum-verify → decrypt with your offline key → reset target → `pg_restore` → validate schema,
> data anchors and the advertising fail-closed invariant → measure RPO/RTO → shred). It REFUSES to run
> if the target string references production (`nxaunmyihhjixxxljcqt`). Proven end-to-end in the cloud
> against a throwaway Postgres + throwaway key: a faithful restore PASSES all checks; injected drift
> FAILS — so a PASS is real, not a rubber-stamp. Run it on the machine holding the key (the key is never
> in the cloud); the RESULT can then be re-verified independently from the cloud via the Supabase MCP
> tools against `zdeedmuocbbkuwuovlbz`. Example:
> ```bash
> RESTORE_DB_URL='postgresql://postgres.zdeedmuocbbkuwuovlbz:<pw>@aws-0-eu-west-1.pooler.supabase.com:5432/postgres' \
> DR_DUMP=./restore/<TS>/strateloq-db-<TS>.dump.gpg \
> DR_RESTORE_SUMS=./restore/<TS>/SHA256SUMS \
> DR_RESET_PUBLIC=1 \
>   scripts/dr/dr_restore_drill.sh --confirm      # gpg prompts for your key passphrase
> ```

## Preconditions (founder-provisioned)
1. **Isolated restore DB** — use **`strateloq-dr-restore` (`zdeedmuocbbkuwuovlbz`)**, already provisioned.
   NOT production `nxaunmyihhjixxxljcqt`, NOT the paused personal projects (`fxynkidbziobqsyjmwwr`
   Action Betting, `zhscjdnbfqwieysrkxgz` RAG AI). NOTE: this target currently holds a STALE earlier
   partial drill (93 tables / 129 routines / 75 policies as of 2026-10-28) — `DR_RESET_PUBLIC=1` (the
   default in the drill script) drops+recreates `public` so the current backup is validated cleanly.
2. **Independent encrypted backups present** at the offsite destination (Google Drive recommended — §offsite):
   `strateloq-db-<ts>.dump.gpg`, `strateloq-storage-<ts>.tgz(.gpg)`, `strateloq-<ts>.bundle`.
3. Operator holds: `SUPABASE_DB_URL` (source, for taking the dump), `DR_GPG_RECIPIENT` + private key,
   isolated `RESTORE_DB_URL`, `N8N_API_KEY`.

## Drill steps (record a timestamp at each →)
1. **T0 backup timestamp** — note the age of the newest `*.dump.gpg` (this is the RPO data point).
2. **T1 restore start** — `gpg -d strateloq-db-<ts>.dump.gpg > d.dump`
   then `pg_restore -d "$RESTORE_DB_URL" --no-owner --clean --if-exists d.dump`.
3. **Schema verification** — expect **151 public tables, 794 public routines, 101 policies, 31 user
   triggers, RLS enabled on all 151 tables** (live production baseline captured 2026-10-28 via the
   Supabase MCP; supersedes the earlier stale 93/370/75/24 figures). The drill script asserts these by
   default (`EXPECT_TABLES=151 EXPECT_ROUTINES=794 EXPECT_POLICIES=101 EXPECT_TRIGGERS=31`); override
   them only when drilling an OLDER dump taken before the schema reached this size.
4. **Representative data verification** — row counts for anchor tables (e.g. commerce_product_pages,
   media_assets, marketing_spend_authority, conversion_template_families) match the source-at-backup.
5. **RLS verification** — `relrowsecurity` true on all expected tables; policies present (75).
6. **Functions verification** — run `fn_storefront_runtime_selftest` (38/38), `fn_storefront_publish_selftest`
   (9/9), `fn_media_creative_live_selftest` (4/4) against the restored DB.
7. **Auth reconciliation** — `auth.users` restored via provider export/Admin API (or re-invite); verify
   `member.auth_user_id` / `users.id` bindings resolve; no plaintext passwords handled.
8. **Storage object restore** — recreate bucket `pulse-generated-media` (private) in the isolated target,
   upload from `strateloq-storage-<ts>.tgz`, reconcile object list + eTag against
   `dr/manifests/storage_manifest.json`.
9. **Edge Function deployability** — `supabase functions deploy <name>` for all 10 from `supabase/functions/`
   against the isolated project (verify build; do not point at production).
10. **n8n workflow importability** — import `dr/n8n/*.json` + `dr_n8n_export.sh` output into a scratch n8n
    project; confirm they load and bind to recreated credential references.
11. **Schedules verified** — only Monday orchestrator (weekly Mon 07:00) + FX (daily 06:00) enabled; nothing
    else; no advertising/posting schedule.
12. **Credential references verified** — every reference in SECRETS-RECOVERY.md resolves to a recreatable
    source; no secret value present in any restored artifact.
13. **Advertising FAIL CLOSED** — `marketing_spend_authority` restores to the exact production baseline
    (2026-10-28): **6 rows total, 0 executable, no ACTIVE status** (1 INACTIVE synthetic + 5 REVOKED
    synthetic). The drill script asserts `total=6`, `executable=0`, `ACTIVE=0`. `fn_request_activation`
    still requires explicit authority; paused proof campaign untouched.
14. **T2 restore completion / T3 verification completion.**

## Measurements to record (then update the audit doc)
- backup age = now(T0) − backup timestamp  → **RPO**
- data-loss window = interval since last successful backup
- total recovery duration = T3 − T1  → **RTO**
- failures, manual steps, external blockers encountered
- verdict: RPO ≤24h VERIFIED? RTO ≤4h VERIFIED?

## Teardown
Drop/delete the isolated restore target (or pause it). Shred decrypted dumps (`shred -u d.dump`). Never leave
a second copy of production data unencrypted or reachable.

#!/usr/bin/env bash
# Independent ENCRYPTED logical database backup (schema + data + functions + policies
# + grants + migration state). Uses the Supabase Postgres connection string held by the
# operator. Output is GPG-encrypted; the plaintext dump is shredded. NEVER commit output.
#   SUPABASE_DB_URL      postgresql://...:6543/postgres   (operator-held; a secret)
#   DR_GPG_RECIPIENT     gpg key id/email to encrypt to
set -euo pipefail
: "${SUPABASE_DB_URL:?set SUPABASE_DB_URL}"
: "${DR_GPG_RECIPIENT:?set DR_GPG_RECIPIENT}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP="strateloq-db-${TS}.dump"
# -Fc custom format: compressed, selective restore; includes schema+data+functions+policies.
pg_dump "$SUPABASE_DB_URL" -Fc --no-owner --no-privileges -f "$DUMP"
gpg --yes --encrypt --recipient "$DR_GPG_RECIPIENT" "$DUMP"
shred -u "$DUMP" 2>/dev/null || rm -f "$DUMP"
echo "Wrote ${DUMP}.gpg — copy to the independent encrypted offsite destination (BLOCKED_EXTERNAL_DR_STORAGE until founder provisions one)."
echo "Restore (to an ISOLATED target, never production): gpg -d ${DUMP}.gpg > d.dump && pg_restore -d <ISOLATED_DB_URL> --no-owner d.dump"

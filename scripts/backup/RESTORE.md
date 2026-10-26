# Restoring a Strateloq encrypted backup

You need: the encrypted archive (`strateloq-backup-<stamp>.tar.gz.sgcm`), its
`.sha256`, and `BACKUP_KEY` from your password manager. Without the key the
archive **cannot** be decrypted — that is by design.

> Test this procedure periodically on a scratch host. An untested backup is a
> hope, not a backup.

## 1. Integrity check (before decrypting)

```sh
sha256sum -c strateloq-backup-<stamp>.tar.gz.sgcm.sha256
```
Must print `OK`. If it fails, the file is corrupt/incomplete — fetch it again.

## 2. Decrypt (auth tag verified automatically)

```sh
export BACKUP_KEY='<value from your password manager>'
python3 aesgcm_stream.py decrypt \
  < strateloq-backup-<stamp>.tar.gz.sgcm \
  > strateloq-backup-<stamp>.tar.gz
```
If the key is wrong, or the file was tampered with/truncated, decryption **fails
closed** with a non-zero exit and an auth-tag error — you never get silent
garbage. Unset `BACKUP_KEY` again when done.

## 3. Extract

```sh
mkdir restore && tar -C restore -xzf strateloq-backup-<stamp>.tar.gz
ls restore/strateloq-backup-<stamp>/
#   db.dump         (Postgres custom-format dump, if DB was backed up)
#   storage/        (Supabase Storage objects, by bucket)
#   n8n/            (workflow JSON exports)
#   source.bundle   (git bundle of the repo)
#   MANIFEST.txt
```

## 4. Restore each component (into a NON-production target first)

**Postgres** (restore into a fresh/empty DB, then promote — never straight over
prod without a tested rehearsal):
```sh
pg_restore --no-owner --no-privileges -d "$TARGET_DB_URL" \
  restore/strateloq-backup-<stamp>/db.dump
```

**Supabase Storage** — re-upload objects per bucket (Storage API or dashboard);
the directory layout under `storage/<bucket>/...` mirrors the object paths.

**n8n workflows** — import each `n8n/<id>.json` via the n8n UI/API. Note the
export holds workflow definitions and credential *references*, not credential
secret values (those live in n8n's own encrypted store and must be re-entered).

**Source** — recover from the git bundle (GitHub is the primary mirror):
```sh
git clone restore/strateloq-backup-<stamp>/source.bundle recovered-src
```

## 5. Verify the restore

Confirm row counts / key tables in the restored DB, spot-check restored Storage
objects, and confirm workflows load. Only then consider cutting over.

## Key loss

If `BACKUP_KEY` is lost, these archives are permanently unrecoverable (that is
the point of authenticated encryption). This is why the policy requires the key
in your password manager **plus** a separate break-glass copy.

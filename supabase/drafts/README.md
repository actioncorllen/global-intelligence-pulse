# supabase/drafts — PROPOSED, NOT DEPLOYED

This directory holds **proposed** Kalodata integration components authored in this repo for review.
They are **not** deployed and **must not** be treated as numbered production migrations.

Context (see `docs/STRATELOQ-KALODATA-PROVIDER-ONBOARDING-017A.md`):
- Production (`nxaunmyihhjixxxljcqt`) is **not** deployed from this repo. Migrations are applied directly
  to the project via the Supabase CLI / Management API (the authority is
  `supabase_migrations.schema_migrations`, 507 applied as of 2026-11-10).
- Therefore anything here must be applied through that canonical pipeline — after the stated
  verification items are satisfied — not by replaying files from this repo.

Each draft states its own verification gates and the fact that it makes **no** chargeable API call and
is **not** deployed.

# Supabase Edge Functions — deployed inventory & source-backup coverage

**Project:** `nxaunmyihhjixxxljcqt` (Strateloq Technologies) · region eu-central-1 · status ACTIVE_HEALTHY
**Captured:** 2026-10-27 via the Supabase Management connector (`get_edge_function`), read-only.
**Why this file exists:** a verification on the real production project found **25 Edge Functions deployed and ACTIVE**, but only **12 were in version control**. The other **13 were not backed up anywhere recoverable** (the git bundle backs up only what is committed). Their deployed source has now been captured into `supabase/functions/` so `scripts/dr/dr_git_bundle.sh` → GitHub backs them up like the rest. This replaces the earlier, stale "Edge Functions (10) … all 10 now in git" note in `dr/DR-INVENTORY.md`.

Source integrity: every captured file was scanned — **no hardcoded secrets**; all provider credentials are read at runtime via `Deno.env.get(...)` (Supabase Edge Function secrets), never embedded in source. `ezbr_sha256` below is Supabase's deployed-bundle hash as reported by the Management API at capture time (provenance only; it is a bundle hash, not a file hash, so it is recorded, not recomputed here).

## Inventory (25 ACTIVE functions)

| Function | Version | verify_jwt | In git before | Status now | Deployed bundle sha256 |
|---|---|---|---|---|---|
| accept-invitation | 20 | false | yes | backed up | 04a50f9e0b7faec96c3f24ab85310260271bb5feac93d0269d03cb322c464b2a |
| admin-bootstrap-demo | 19 | true | yes | backed up | b81ecf54fccca971fef3ca2dee1e6e14953b374c7fb79d5ecd2b05b66e1c2b92 |
| issue-invitation | 21 | false | yes | backed up | 090d9f4cdcedd3a9cb3abeb62a87897413dbc42200490f1abf3b191abf6eafbb |
| issue-open-invitation | 14 | false | yes | backed up | 969662755b0e8d71788f8a7a51839b4a701495d4469bfc94b79df68d82e3dace |
| list-issuable-applications | 20 | false | yes | backed up | 4d1749424dcf82620e57fe69cc70481f9cea6c193d28be177450ea4c9b7ff219 |
| media-asset-url | 9 | true | yes | backed up | fd4d34771f06273f6ad92d5d5f5cf1d8738bf125372280fb48f452a8b9ed9586 |
| meta-capi-adapter | 16 | true | yes | backed up | 6a4c4a6520348999d10e6bcec1e8ccf1a00fc853ca88bda9960a1d4d38b7ec8e |
| meta-insights-reader | 13 | true | yes | backed up | 9bb33369fb699c5a27329d3f289e575cf65f81646d216a5d749e39bafbc415c5 |
| prepare-product | 14 | false | yes | backed up | cd81dc5dd8cbc2cd76202fd99a859f00899ef9bb78aad7de422574c559b0208d |
| start-discovery | 21 | false | yes | backed up | fd9c8f84e09281c25ac6edbc4318c7f8ee7dcdf6e7e8d6352fbcd161e0c28236 |
| storefront | 20 | false | yes | backed up | d9f125d88a10872b2930554f499773ef35e6bc82af23e3c54ac7c36faef3716a |
| tiktok-commercial-token | 27 | true | yes | backed up | b0c1dea6ff5782e8256784c5808ce2f47964f4d247373152729c3d0a5d2636ed |
| **commercial-image-generate** | 8 | true | **NO** | **captured now** | df074b8063b5dca5ae2944858d9bb6213a27400ec54c73d292554762e5247564 |
| **creative-image-execute** | 5 | false | **NO** | **captured now** | 34939ac39a811f11f47199f84179b3480b035852f2f1660e7f8572c4091fe27c |
| **product-image-import** | 4 | true | **NO** | **captured now** | b0cb95ec14d95216c99eaa7dbb0f97a0a885c4eff6928c8e4a83ef8add68b647 |
| **kalodata-discovery** | 6 | true | **NO** | **captured now** | a097f4c83381584bfc62bef780154a91c193b0867770f7d65306d6bd41a62b6a |
| **fastmoss-discovery** | 5 | true | **NO** | **captured now** | dddfbd98637b7746097818ef15d993fea8bd157d8fc5675820c07e21d4c237b6 |
| **fastmoss-product-detail** | 18 | true | **NO** | **captured now** | 93819bdec2e5db76d149258ef1855bd54d0f0551a384d63f39403c43bcdbcd12 |
| **translate-text** | 2 | true | **NO** | **captured now** | 699090f98d96106aefa703b91a98eac922d28055bb1bc15d0856e80250f24c69 |
| **meta-facebook-oauth-begin** | 9 | false | **NO** | **captured now** | 779ec18345e612902067daa59b9fcec62721ccfa5c49c0eb58201a4937a8e570 |
| **meta-facebook-oauth-callback** | 6 | false | **NO** | **captured now** | f71408990cbc72f73a746458b16576ec1008aea04bdc159096334bed87d42242 |
| **meta-facebook-select-page** | 10 | false | **NO** | **captured now** | f21f7956385fe976294d344274e184ef96bf127118bc18608a69dde94e41c9d9 |
| **meta-facebook-disconnect** | 9 | false | **NO** | **captured now** | 54b00d8b4ad481929d37b4a54dd0a8bd48317a20855234392d6b0525bd34df59 |
| **zz-test-mint-token** | 5 | true | **NO** | **captured now** (see note) | 85c211082edc82a6533500e4153f9466d5cf06f090688734f2c433ca854c6733 |
| **cttest** | 5 | true | **NO** | **captured now** (see note) | 69269a3627a38d5cb2cd51a6b308ada515d251a0562a9b0df6687b79ab637345 |

## Notes / findings (for the founder — not blocking the backup)

1. **`meta-facebook-*` shared modules.** The four `meta-facebook-*` functions import `../_shared/meta_oauth/{http,security,graph,scopes}.ts`. Each deployed bundle carried its own copy, and `meta-facebook-oauth-begin`'s copy of `scopes.ts` was **older** (it listed `business_management` as a *required* scope; the newer copy in callback/select-page/disconnect correctly makes it *optional* — fixing the 016C.9 bug where every organic connection failed the scope gate). The repo now stores **one canonical `_shared/meta_oauth/`** using the newer/correct versions. `begin` does not run the scope-validation path and only uses `metaFacebookOrganicRequestedScopeParam()` (whose output set is unchanged), so this capture does not change `begin`'s behavior — but it means `begin` in production is running a slightly stale shared bundle. Redeploying from this captured source would make all four consistent. **No action required for the backup; flagged for the next edge-function deploy.**

2. **Test/retired endpoints still ACTIVE.** `zz-test-mint-token` (returns 410 DISABLED) and `cttest` (returns 404 GONE) are retired stubs but are still deployed and ACTIVE. They are harmless as-is. Consider deleting them from the project to reduce surface area — not required for DR.

## Keeping this complete going forward

The weekly backup now captures edge functions two ways: (a) committed source in `supabase/functions/` is included in the git bundle, and (b) `scripts/dr/dr_backup_resume.sh` step `source_edge_verify` re-lists the deployed functions (via `supabase functions list`, when the Supabase CLI + access token are present) and **warns if any deployed slug is missing from `supabase/functions/`**, so a newly-deployed-but-uncommitted function is caught instead of silently unbacked.

# STRATELOQ DR — Creative Studio Execution Coverage (post-P0 integrity)

Scope: ensure the **launch-critical creative execution definitions** are represented in the
repository source-of-truth. No secrets or credential values are exported anywhere below —
n8n exports and edge functions carry **references only** (keys live in the n8n credential store /
Supabase edge env).

## Now represented in source-of-truth (added this unit)

| Component | Source of truth | Was in repo before? |
|---|---|---|
| **Creative Image Executor** (live customer static path) — n8n workflow `xgqAoBnZbI2vwFPW` | `dr/n8n/xgqAoBnZbI2vwFPW_creative-image-executor.json` | No |
| **creative-image-execute** edge function (dispatch + finalize orchestrator) | `supabase/functions/creative-image-execute/index.ts` | No |
| Post-P0 integrity DB changes (state sync, selftests, format robustness, provider-error) | `supabase/migrations/mig_352..mig_357_*.sql` | New |

The P0 fix itself (mimetype normalization) is in the n8n workflow JSON above; it is published as
the active version on the n8n instance and reversible via n8n version history.

## Source-of-truth drift (REPORTED — not reconciled here, to keep scope narrow)

The live Supabase database is at **mig_351**; the repository `supabase/migrations/` tree stops at
**mig_291**. Migrations **mig_292 … mig_351** (~60, applied directly to the live DB by ongoing
build sessions) are **not committed** to the repo. This includes several creative-execution
migrations (e.g. `mig_296_creative_format_expansion`, `mig_299_creative_studio_static_autodispatch`,
`mig_300_creative_image_executor_context`, `mig_301_creative_studio_static_autoexecute`,
`mig_306_creative_studio_display_image_and_static_result`, the commercial/Gemini asset pipeline
`mig_320..mig_328`, `mig_341_nightlight_content_asset_recovery`).

Several live **edge functions** are likewise absent from `supabase/functions/`, including
`commercial-image-generate`, `product-image-import`, `media-asset-url`, and the
`meta-facebook-oauth-*` set. The DB schema itself remains recoverable from the committed
`dr/schema/*.sql` snapshots; the **n8n workflows and edge-function source are the only artifacts
that live solely on their external platforms**, which is why those are prioritized above.

### Recommended follow-up (separate, bounded DR unit — NOT done here)
1. Back-fill `supabase/migrations/mig_292 … mig_351` into the repo from the live DB (schema is
   already snapshotted in `dr/schema/`; the migration *files* are what is missing).
2. Commit the remaining live edge-function sources listed above.
3. Export the remaining active creative/commercial n8n workflows (Gemini executors, identity
   validator, quality judge) to `dr/n8n/` once that work stabilizes.

Do not export credential values at any step.

# BE326 — Controlled production security release of the fail-closed generative-AI corrections — PASS

**Executed:** 2026-11-27 · **Authority:** founder "BE325 CONTROLLED PRODUCTION SECURITY RELEASE — APPROVED". **Applied to production** (`nxaunmyihhjixxxljcqt`) in the authorised order mig_375 → 376 → 377 → 378. **Verdict: PASS.** Release boundaries honoured: no customer Creative Studio activation, no paid Gemini/OpenAI generation, no image/video download release, no GPD.07, no unrelated feature deployment, no rights-flag promotion, no deletion of historical assets, GOLD 11/22 unchanged.

---

## Production migration IDs + deployment time (UTC, 2026-11-27)
| # | Migration | Version (ID) | Applied |
|---|---|---|---|
| 1 | `mig_375_cs03_ai_input_fail_closed` | `20261127133201` | 13:32:01 |
| 2 | `mig_376_be324_generation_gate_fail_closed` | `20261127133314` | 13:33:14 |
| 3 | `mig_377_be325_rights_quarantine_gates` | `20261127133352` | 13:33:52 |
| 4 | `mig_378_be325_historical_quarantine_data` | `20261127133519` | 13:35:19 |

Applied individually, each verified before the next. **One stop-on-error event handled:** the first `mig_378` attempt failed a CHECK constraint (`commerce_generated_assets_commercial_asset_status_check` rejects `QUARANTINED_RIGHTS_UNVERIFIED`); its transaction rolled back with no partial write. Per the stop-on-error rule I halted, corrected `mig_378` to a **flag-only** quarantine (`provenance.rights_quarantine_active=true` + `is_launch_safe=false`, which the already-applied `mig_377` gates enforce; no enum column touched), re-applied, and it succeeded. No subsequent migration existed to block.

## Pre-deployment (completed)
Content matched BE325; dependency order + definitions + affected callers verified; recoverable pre-deploy definitions captured (`docs/ROLLBACK-BE326-pre-deploy-capture.sql`); `mig_378` made idempotent (skips already-flagged rows, never re-captures prior state) and targeted only the specifically verified IDs; pre-deploy asset states captured (3 generated = GENERATED_VALIDATED unquarantined; 6 media incl. `b51602e2` APPROVED/launch_safe=true); 2 active jobs noted (`37f393e5` READY_TO_DISPATCH, `6028e2fc` GENERATING) — both unclaimed with no resolved source, so neither bypassed the gate; they are re-validated by the corrected guard at execution.

## Post-deployment verification — 10/10 PASS
| # | Check | Result |
|---|---|---|
| 1 | Supplier-only CJ images DENIED for Gemini + OpenAI generation | **PASS** — `ai_generation.reference_eligible=false`; `fn_asset_use_eligibility` supplier `ai_input=false`; OpenAI source guard denies non-owned (`ai_input_not_authorised`) |
| 2 | Marketplace research images DENIED | **PASS** — marketplace `ai_input=false` |
| 3 | Commercial publishing does not classify uncleared supplier imagery as publishable | **PASS** — e453 `commercial_asset_readiness=CUSTOMER_ASSET_REQUIRED`, `publishable_asset_path=NONE` |
| 4 | Revoked/expired permissions fail closed | **PASS** — `fn_asset_use_eligibility_selftest` EXPIRED_SCOPE_BLOCKS + REVOKED_BLOCKS (11/11) |
| 5 | All 3 previously selectable generated assets unselectable | **PASS** — `fn_commercial_generated_asset_use` → `rights_quarantined` for 6603a98d / d2a6e09a / 03f03347 |
| 6 | All 6 identified media assets blocked from launch/use | **PASS** — `fn_media_launch_eligibility` → `RIGHTS_QUARANTINED` for 8ab3a7f0 / 7c6ff093 / 469a7aa1 / 6ed3d3dd / f8c569bb / b51602e2 |
| 7 | Existing owned/licensed assets retain only verified permissions | **PASS** — owned → all seven uses; supplier/marketplace → none |
| 8 | Product Asset Lock, RLS, tenant + country isolation intact | **PASS** — `fn_ad_creative_identity_selftest` (PAL) 8/8; cross-tenant rejected; no RLS/policy change |
| 9 | All relevant selftests + regression suites | **PASS** — aggregate failures = **0** across fn_asset_use_eligibility, product_media_discovery, cs_media_end_to_end, ad_creative_identity, cj_image_rights, product_media_auth, creative_production, media_runtime, cross_supplier_identity, product_image |
| 10 | Product Research + Workspace Overview functional + truthful readiness | **PASS (backend)** — badge now truthfully reads "Commercial assets: Customer image required"; readiness readers return ok; **no frontend change** (production UI unchanged; the interface consumes these now-truthful backend states) |

## Asset quarantine counts
- **Generated assets quarantined: 3** (6603a98d, d2a6e09a, 03f03347 — all reference SUPPLIER_PROVIDED; the 4th, e51e31f9, was already REJECT_GENERATED_ASSET).
- **Media assets quarantined: 6** (5 generated supplier/marketplace outputs + 1 launch-safe SUPPLIER_AUTHORIZED image b51602e2).
- **Total: 9**, reversible (provenance flag + prior state captured), **0 deletions**.

## Remaining restrictions (in force)
- Supplier/marketplace-only products cannot AI-generate and are not shown as commercially publishable (rights-safe original lane required: owned upload / first-party / licensed, or written per-image AI/commercial permission).
- Owned-image **Gemini** generation remains **unavailable** until the `commercial-image-generate` edge's reference resolver is wired to select owned/licensed images (a separate edge deployment, not in this release). Until then the Gemini path stays fail-closed and never substitutes a supplier image.
- Customer Creative Studio downloads/activation, paid generation, and GPD.07 remain **off**.

## Rollback safety (in force)
Per policy, a rollback must never silently restore unauthorised AI generation, publishing, downloads or quarantined-asset access. The captured pre-deploy definitions reintroduce the over-grant and are therefore not a safe standalone rollback (`docs/ROLLBACK-BE326-pre-deploy-capture.sql`); the sanctioned path is forward-fix preserving fail-closed, or escalate. The `mig_378` quarantine un-flags only if the assets' rights are later verified.

## Overall verdict: **PASS** — production verification complete.

## Controls
0 paid AI calls; 0 credits; no customer release; no download/GPD.07 activation; no rights-flag promotion; no historical-asset deletion; RLS/PAL/tenant+country isolation + revocation/expiry preserved. **GOLD 11/22 unchanged.** Deployed: `mig_375`/`376`/`377`/`378`. Build Evidence row **BE326**.

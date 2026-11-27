# BE324 — Rights-safety hotfix package: FAIL-CLOSED generative-AI authorisation

**Executed:** 2026-11-27 · **Authority:** founder "BE323 RIGHTS-SAFETY CORRECTION — adopt FAIL-CLOSED". **Policy:** production Creative Studio must NOT treat CJ supplier photographs as authorised generative-AI references merely because supplier product-DATA analysis is permitted. **This is a prepared package for separate founder deployment approval — NOT applied.** Controls: no production migration/deployment, no rights-flag promotion, no paid AI calls, no Creative Studio customer release, no GPD.07, GOLD 11/22 unchanged; existing product-research + workspace interfaces unchanged.

**Recommendation: READY for separate founder deployment approval.**

---

## 1. Exact changed functions
| File | Function | Change |
|---|---|---|
| `mig_375` (committed BE323) | `fn_asset_use_eligibility` | `ai_input` fails closed: owned/licensed OR explicit `AUTHORIZED_FOR_AI_REFERENCE` OR per-image `ai_input` evidence only; bare supplier never. |
| `mig_376` (this) | `fn_product_commercial_asset_readiness` | **Only** `ai_generation.reference_eligible`/`execution_state`/`reference_basis`/`requires` change. `commercial_asset_readiness`, `commercial_testability`, `publishable_asset_path`, `images`, `rights`, `supplier_match` and all other fields are **unchanged** (workspace badge + storefront publish path untouched). |
| `mig_376` (this) | `fn_media_image_execution_context` | One additive guard: the source image must carry AI-use permission (owned/first-party/licensed), else `BLOCKED_EXTERNAL_PROVIDER` / `ai_input_not_authorised`. |

**Production dependency chain (inspected):** Gemini path = `commercial-image-generate` edge → sole gate `fn_product_commercial_asset_readiness.ai_generation.reference_eligible` (also consumed by `fn_generate_storefront_runtime`); reference then resolved by `fn_resolve_storefront_assets` (downstream of the gate). OpenAI/Ad-Studio path = `creative-image-execute` edge → `fn_media_image_execution_context` (source from `fn_product_card_display_image`). No other generation entry point; no direct edge bypass (each edge's only gate is one of the two corrected functions).

## 2. Current vs corrected permission decision tables
**`fn_asset_use_eligibility` — `ai_input`:**
| asset | current (deployed) | corrected |
|---|---|---|
| bare CJ supplier (`SUPPLIER_AUTHORIZED`) | **ALLOW (over-grant)** | **DENY** |
| explicit `AUTHORIZED_FOR_AI_REFERENCE` | ALLOW | ALLOW |
| owned upload / first-party / licensed | ALLOW | ALLOW |
| per-image `ai_input` evidence (unrevoked, unexpired) | — | ALLOW |
| marketplace / revoked / expired | DENY | DENY |

**`fn_product_commercial_asset_readiness` — `ai_generation.reference_eligible`:**
| product assets | current | corrected |
|---|---|---|
| supplier-only (e453eed4) | **ELIGIBLE (over-grant, basis SUPPLIER_AUTHORIZED)** | **NOT_ELIGIBLE** |
| marketplace-only | NOT_ELIGIBLE | NOT_ELIGIBLE |
| owned upload (rights-confirmed) | ELIGIBLE | ELIGIBLE |
| first-party / licensed / AI-ref-flagged | (wrongly) NOT_ELIGIBLE | ELIGIBLE |
| per-image `ai_input` evidence | — | ELIGIBLE |

**`fn_media_image_execution_context` — source AI-use guard:**
| source `rights_state` | current | corrected |
|---|---|---|
| CUSTOMER_OWNED / FIRST_PARTY_OWNED / LICENSED | ALLOW | ALLOW |
| SUPPLIER_PROVIDED | ALLOW (if display-cleared) | **DENY (`ai_input_not_authorised`)** |
| MARKETPLACE_PUBLIC_LISTING | ALLOW (if display-cleared) | **DENY** |
| RIGHTS_UNVERIFIED (no display) | DENY (`no_product_image`) | DENY |

## 3. Proof both readers AND the Gemini execution path fail closed (deterministic, deployed data)
- **Gemini guard:** e453eed4/GB — current deployed `ai_generation.reference_eligible = true` (basis `SUPPLIER_AUTHORIZED`); corrected predicate `has_customer_owned=false ∧ has_ai_authorised_asset=false ∧ has_ai_evidence=false ⇒ reference_eligible = FALSE` (legacy `SUPPLIER_PROVIDED` flag **ignored** for AI). → **fails closed.**
- **Gemini execution path:** `commercial-image-generate` returns `NOT_ELIGIBLE` whenever `ai.reference_eligible !== true` (its sole gate). With the corrected gate, a supplier-only product → `NOT_ELIGIBLE` → **no generation**. (The edge also has no owned-reference resolver, so it cannot substitute another source — see limitations.)
- **`fn_asset_use_eligibility`:** bare CJ supplier `ai_input` pre-fix `true` → fixed `false` (proven on deployed `fn_asset_rights_class`); marketplace `false`; revoked/expired `false`; owned `true`.
- **OpenAI guard:** decision table computed live — SUPPLIER_PROVIDED/MARKETPLACE → DENY; owned/first-party/licensed → ALLOW.

## 4. Test results (against committed migrations + read-only production evidence) + limitations
Required scenarios: **CJ supplier w/o AI rights → DENY** (readiness NOT_ELIGIBLE + `ai_input=false`); **marketplace → DENY**; **revoked/expired → DENY** (mig_375 selftest + readiness evidence predicate excludes revoked/expired); **authorised owned/licensed → ALLOW, documented uses only** (CS.03 per-use; readiness ELIGIBLE); **ambiguous/wrong-product → DENY** (CS.02 rejects AMBIGUOUS; non-owned/no-evidence → DENY); **no edge bypass** (each edge's only gate is a corrected function); **no unrelated behaviour change** (readiness changes only `ai_generation`; existing regressions **11/11, 0 failures** on live). 
**Limitation (stated explicitly):** mig_375/376 are **not applied** (no production write; no usable staging — DR + billing-staging INACTIVE and without the Creative Studio schema), so the corrected functions' **own selftests cannot be executed** here; proof is by deterministic predicate evaluation on deployed data + confirmation of the live over-grant. Final green selftests are a **post-apply check**.

## 5. Rollback procedure
mig_375 and mig_376 are idempotent `CREATE OR REPLACE FUNCTION`. Rollback = re-apply the **pre-BE324 definitions** of the three functions (preserved verbatim in git history immediately prior to mig_375/376, and currently live in production). No data migration, no schema change, so rollback is a pure function redeploy with zero data impact. Post-rollback check: `fn_product_commercial_asset_readiness(e453,'GB')->'ai_generation'->>'reference_eligible'` returns to `true` (legacy behaviour).

## 6. Production risk + user-impact assessment
- **Risk: LOW.** Additive fail-closed tightening; only generative-AI authorisation changes; no schema/table/data/rights-flag/RLS/policy change; workspace readiness badge + storefront publish label unchanged; PAL, tenant + country isolation, revocation/expiry gates preserved.
- **User impact:** products whose only imagery is supplier/marketplace can no longer trigger AI generation (Gemini → `NOT_ELIGIBLE`; OpenAI → `ai_input_not_authorised`); they must use the rights-safe original lane (customer upload / first-party / licensed) or obtain explicit per-image AI-use permission. Historically the now-blocked path produced 4 generated assets and ≥9 media jobs (6 SUPPLIER_PROVIDED + 3 MARKETPLACE) — existing records are retained, not deleted. Products with owned images are unaffected. **No impact** on product-research, workspace, discovery or any non-generation feature.
- **Separate findings (not in this hotfix, flagged for a future decision):** (a) the readiness **publish** label still reports `SUPPLIER_AUTHORIZED_COMMERCIAL_ASSET`/`READY` for supplier-only products (a display/publish over-grant distinct from AI generation; left unchanged here to avoid altering the accepted workspace interface); (b) the `commercial-image-generate` edge resolves its reference only from the supplier storefront (no owned-reference path) — an **edge** change (deployment) is needed before owned-image products can actually generate; until then the Gemini path is simply fail-closed.

## 7. Recommendation
**READY** — apply `mig_375` then `mig_376` (order matters only for clarity; independent), under separate founder deployment approval. **Post-apply checks:** run `fn_asset_use_eligibility_selftest`, `fn_product_media_discovery_selftest`, `fn_cs_media_end_to_end_selftest`, `fn_ad_creative_identity_selftest` (expect green); confirm `fn_product_commercial_asset_readiness(e453,'GB')->'ai_generation'->>'reference_eligible' = false` and `commercial_asset_readiness` unchanged; re-run the 11 existing Creative/media selftests (expect 0 failures); spot-check an owned-image product → `reference_eligible = true`.

## Controls
0 paid AI calls; 0 credits; **no production migration/deployment applied**; no rights-flag promotion; no Creative Studio customer release; no GPD.07; RLS/PAL/tenant+country isolation preserved. **GOLD 11/22 unchanged.** Files: `supabase/migrations/mig_375_cs03_ai_input_fail_closed.sql`, `supabase/migrations/mig_376_be324_generation_gate_fail_closed.sql` (both committed, **unapplied**). Build Evidence row **BE324**.

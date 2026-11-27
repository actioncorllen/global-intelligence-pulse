# BE323 — CS.04 + CS.02 gap: two correctness checks, ai_input fail-closed fix, rights-safe original lane

**Executed:** 2026-11-27 · **Authority:** founder "CREATIVE STUDIO NEXT EXECUTION — CS.04 + CS.02 GAP CLOSURE". **Controls honoured:** no production deployment, **no new production migrations**, no paid Gemini/OpenAI calls, no commercial-rights promotion without evidence, no subscriber-download release, no GPD.07 activation, GOLD 11/22 unchanged. GPD.09 + 18-Dec launch gates remain prioritised.

**Because the founder's new control forbids new production migrations and no usable staging exists, the ai_input fix and CS.04 are delivered as a committed, UNAPPLIED migration file (`mig_375`) + verification against already-deployed functions. Two decisions are required from the founder (end of report).**

---

## Correctness check 1 — ai_input rights basis for CJ supplier images → NO WRITTEN BASIS → FAIL CLOSED
**Authoritative evidence (`catalogue_source_rights` + BE239, CJ Support's written reply):** CJ has `analyse_cleared=TRUE`, `display_derived_cleared=TRUE` (text/data/identity/SKU/stock/links) — but **`reuse_creative_cleared=FALSE`, `commercial_redistribution_cleared=FALSE`, image clearance FALSE**. BE239 verbatim: *"supplier IMAGES are NOT automatically licensed for third-party research-SaaS use — individual copyright + brand permission is required (image clearance stays FALSE)."*

**Conclusion:** image-data *analysis* (`analyse_cleared`) and *generative-AI input of the image pixels* are **independent rights**. There is **no written basis** to treat a bare CJ `SUPPLIER_PROVIDED` image as a generative-AI input. My CS.03 reader over-granted `ai_input=true` for `SUPPLIER_AUTHORIZED` — corrected to **fail closed**.

**Fix (`mig_375`, committed, not applied):** `ai_input` is allowed **only** for an owned/licensed asset, an explicitly `AUTHORIZED_FOR_AI_REFERENCE` asset (`provenance.ai_reference_only=true`), or per-image evidence with an explicit `permission_scope.ai_input` grant (unrevoked, unexpired). **Proven deterministically on deployed primitives** (`fn_asset_rights_class`):

| asset | origin_class | ai_input pre-fix | ai_input FIXED |
|---|---|---|---|
| bare CJ supplier | SUPPLIER_AUTHORIZED | true (over-grant) | **false** |
| CJ supplier flagged `ai_reference_only` | AUTHORIZED_FOR_AI_REFERENCE | true | **true** |
| owned upload (rights-confirmed) | CUSTOMER_OWNED | true | **true** |
| first-party original | FIRST_PARTY_OWNED | true | **true** |
| explicitly licensed | EXPLICITLY_LICENSED | true | **true** |
| eBay marketplace | RESEARCH_REFERENCE_ONLY | false | **false** |

No rights record changed; no permission granted.

## Correctness check 2 — were mig_371–374 applied to production or staging? → **PRODUCTION**
- **Environment:** the org has 3 Supabase projects — **`nxaunmyihhjixxxljcqt` "Strateloq Technologies" = ACTIVE_HEALTHY = production** (backs strateloq.com); `strateloq-dr-restore` and `strateloq-billing-staging` are both **INACTIVE** (DR copy / billing-only; neither carries the Creative Studio schema). No dev branches exist.
- **Deployment evidence:** `mig_371_cs03_cs02_media_use_rights_and_discovery`, `mig_372_cs03_cs02_selftests`, `mig_373_fix_ad_creative_identity_selftest`, `mig_374_cs_media_end_to_end_selftest` are recorded in the production migration history (versions 20261127123102–123848, today). **So 371–374 were applied to production** — consistent with the project's established pattern (all prior BE migrations went to this project).
- **Backwards compatibility:** all four are additive `CREATE OR REPLACE FUNCTION` (new readers/selftests + one selftest fix). No table/column/data/rights/RLS/policy change; no existing function signature changed except the `fn_ad_creative_identity_selftest` test harness.
- **Observed effects:** new callable functions only; **unwired** (no frontend/edge path calls `fn_asset_use_eligibility` / `fn_product_media_discovery` yet), so zero change to customer-facing behaviour or the live generation pipeline. Full regression green (11/11 selftests, 0 failures).
- **Going forward:** no new production migrations — honoured; `mig_375` (and any CS.04 build) stay as committed files pending an authorised apply.

## MATERIAL FINDING (escalation) — the LIVE readiness gate carries the SAME over-grant, and it IS wired
`fn_product_commercial_asset_readiness` (production, wired to the `commercial-image-generate` Gemini pipeline) returns, for product e453eed4/GB (images: supplier + marketplace only, **no customer-owned**): `commercial_asset_readiness=READY`, `publishable_asset_path=SUPPLIER_AUTHORIZED_COMMERCIAL_ASSET`, `ai_generation.reference_eligible=true` (`reference_basis=SUPPLIER_AUTHORIZED`). **The live pipeline therefore treats a bare CJ supplier image as both a publishable commercial asset AND a generative-AI reference — the same over-grant, contradicting BE239 (CJ images not licensed; `reuse_creative_cleared=FALSE`).** This is **not** changed here: it is launch-critical, wired to the founder-accepted media flow, needs a founder rights decision, and cannot be migrated under the current control. **This is a genuine pre-launch rights-compliance item requiring a decision (below).**

## CS.04 — rights-safe original asset lane (verified on existing infra; fail-closed fix is the key correctness piece)
The rights-safe original path already exists in deployed infrastructure, and with `mig_375` it is correct:
- **Customer-uploaded images (explicit rights attestation):** `product-image-import` edge + `fn_product_image_import_register` write `CUSTOMER_OWNED` + `provenance.rights_confirmed=true` to `pulse-product-imports`; `fn_product_commercial_asset_readiness` then returns `READY` / `CUSTOMER_OWNED_ASSET`; CS.03 grants all seven uses including `ai_input`. **Verified.**
- **Strateloq-owned originals / verified-permission assets:** `FIRST_PARTY_OWNED` and `EXPLICITLY_LICENSED` / `AUTHORIZED_FOR_AI_REFERENCE` classes grant the lane (CS.03 table above). **Verified.**
- **Original AI-generated backgrounds:** `commercial-image-generate` scenes (`CLEAN_STUDIO`/`LIFESTYLE`/`PRODUCT_IN_USE`) generate the *surrounding scene* while PAL preserves exact product identity/SKU; the product layer is the authorised reference, never a research image. **Exists.**
- **Research-only images are never a generative reference:** marketplace/discovery → `RESEARCH_REFERENCE_ONLY` → `ai_input=false` (CS.03). With `mig_375`, bare supplier is also `ai_input=false`. **Verified.**

**Status: CS.04 = PARTIAL.** The lane and its correctness (fail-closed) are verified on deployed functions; the explicit lane-assembler reader (`fn_product_rights_safe_asset_lane`) and the customer-upload rights-attestation UI remain to be built + applied in an authorised environment (and the merchant-upload surface is not released; no subscriber-download release).

## CS.02 gap closure — media-quality evidence
Deployed `fn_product_media_discovery` already returns per candidate: **source attribution, identity-match (exact-variant verdict), resolution (`UNKNOWN` when pixel dimensions are not stored — it never claims high-resolution readiness), download eligibility and AI-input eligibility (via CS.03, now fail-closed), and freshness**; research/marketplace images are excluded. The founder's rule *"do not claim high-resolution readiness when pixel dimensions are unavailable"* is **already honoured** (honest `UNKNOWN`). **Remaining (spec'd, pending authorised apply):** an explicit `high_resolution_ready` boolean (false when dims unavailable) and capture of real pixel dimensions during ingestion (provider-dependent). **Status: CS.02 = PARTIAL** (unchanged scope; honest UNKNOWN already met).

## Tests — the 8 required scenarios (verified on deployed functions + the fail-closed proof)
| # | Requirement | Result |
|---|---|---|
| 1 | No research-only image becomes an AI reference | **PASS** — marketplace `ai_input=false` (deployed); with `mig_375` bare supplier `ai_input=false` too |
| 2 | Unverified CJ image rejected for generation unless specifically licensed | **PASS (with `mig_375`)** — bare CJ `ai_input=false`; per-image `ai_input` evidence → true (proven); *currently the deployed pre-fix reader still returns true — apply `mig_375`* |
| 3 | Valid owned/uploaded image accepted | **PASS** — owned → all seven uses incl `ai_input` (deployed) |
| 4 | Revocation/expiry block use | **PASS** — CS.03 selftest (deployed) proves expired + revoked blocked |
| 5 | No cross-product / cross-country / cross-tenant borrowing | **PASS** — `cross_tenant_rejected`; candidates anchored to the product's own verified identity |
| 6 | Existing Product Asset Lock remains authoritative | **PASS** — `fn_ad_creative_identity_selftest` 8/8 (deployed) |
| 7 | No commercial download URL without asset-specific permission | **PASS** — `customer_download`/`subscriber_export`=false for supplier/marketplace (deployed) |
| 8 | Existing Creative Studio regressions pass | **PASS** — 11/11 selftests, **0 failures** (live) |

## Remaining blockers + decisions required
1. **Apply authorisation.** `mig_375` (ai_input fail-closed) is committed but **not applied** (no-new-prod-migration control). It is a strict safety *tightening* of an unwired function. **Decision:** apply `mig_375` to production now, OR keep as a file for your release process, OR provide a staging/branch to run its selftest.
2. **Production readiness-gate rights policy (launch-critical).** The live `fn_product_commercial_asset_readiness` treats bare CJ supplier images as AI-reference-eligible + commercial-ready without written AI-input/reuse permission (BE239 says images are not licensed). **Decision:** (a) fail closed — require owned/uploaded/licensed/explicit-AI-permission before any generation (CS.04 original lane is the remedy; supplier-only products would need a customer upload first), or (b) keep as-is pending your rights judgement (transformative, PAL-gated, reference never redistributed), or (c) treat as a launch blocker to resolve with a CJ per-image AI-input permission. I did not change it.

## Controls
0 paid Gemini/OpenAI calls; 0 credits; no production deploy; **no new production migration applied**; no rights-flag promotion; no subscriber-download release; no GPD.07 activation; RLS/PAL/tenant isolation preserved. **GOLD 11/22 unchanged.** Build Evidence row **BE323**. File: `supabase/migrations/mig_375_cs03_ai_input_fail_closed.sql` (committed, unapplied).

# BE325 — Consolidated FAIL-CLOSED security-release package (Creative Studio generative-AI)

**Executed:** 2026-11-27 · **Authority:** founder "BE324 FINAL SECURITY-RELEASE READINESS". **Prepared, NOT applied** (no production migration/deployment; no customer Creative Studio release; no paid AI; no GPD.07; GOLD 11/22 unchanged; product-research + workspace interfaces preserved). **Decision: GO** for separate founder deployment approval.

This single package supersedes the fragmented view: it carries the BE323/BE324 gate corrections **plus** the four BE325 release-readiness items.

---

## Package contents (all committed, UNAPPLIED; apply in order 375 → 376 → 377 → 378)
| File | Scope |
|---|---|
| `mig_375` | `fn_asset_use_eligibility` — `ai_input` fail-closed (BE323). |
| `mig_376` | `fn_product_commercial_asset_readiness` — AI-generation guard fail-closed **and** commercial-PUBLISH label fail-closed (§1); `fn_media_image_execution_context` — OpenAI source AI-use guard. |
| `mig_377` | `fn_commercial_generated_asset_use` + `fn_media_launch_eligibility` — reversible rights-quarantine gates (§2). |
| `mig_378` | Reversible historical-quarantine **data** (§2) + inline rollback. Deletes nothing. |

## §1 — Commercial publishing (verified → corrected)
**Finding:** a supplier-only product reports `commercial_asset_readiness=READY` / `publishable_asset_path=SUPPLIER_AUTHORIZED_COMMERCIAL_ASSET` — i.e. a CJ supplier image treated as commercially publishable **without verified commercial reuse rights** (BE239: CJ `reuse_creative_cleared`/`commercial_redistribution_cleared`=FALSE).
**Smallest correction (`mig_376`):** READY/`SUPPLIER_AUTHORIZED_COMMERCIAL_ASSET` now requires a rights-confirmed customer-owned image **or** verified supplier commercial reuse rights; otherwise a supplier image → **`CUSTOMER_ASSET_REQUIRED` / `NONE`** (truthful). This reuses an existing, UI-handled status (`fn_product_commercial_readiness_badge` renders "Commercial assets: Customer image required") — **badge layout preserved, value truthful; no old over-grant retained**.
**Proof (deployed data):** e453eed4/GB current `READY / SUPPLIER_AUTHORIZED_COMMERCIAL_ASSET` → corrected `CUSTOMER_ASSET_REQUIRED / NONE` (has_customer_owned=false ∧ resolve_available=true ∧ has_commercial_reuse_rights=false).

## §2 — Historical generated assets (quarantined, reversible)
**Inspected:** the 4 generated assets (`commerce_generated_assets`) all have `reference_rights_state=SUPPLIER_PROVIDED`; the 9 supplier/marketplace jobs produced 5 output `media_assets` (2 supplier, 3 marketplace) + 4 FAILED; and 1 additional `media_asset` was `is_launch_safe=true`/`APPROVED` with `SUPPLIER_AUTHORIZED` rights. **None has verified commercial-reuse, derivative or AI-input rights** (all derive from CJ supplier/marketplace photographs; CJ images not licensed for reuse).
**Reversible restriction/quarantine (no deletes):**
- `mig_377` gates: `fn_commercial_generated_asset_use` refuses a quarantined generated image; `fn_media_launch_eligibility` refuses a quarantined media asset.
- `mig_378` data: flags **3** selectable generated assets (`6603a98d`, `d2a6e09a`, `03f03347`; the 4th is already `REJECT_GENERATED_ASSET`) and **6** media assets (5 generated outputs + the launch-safe supplier image `b51602e2`) with `rights_quarantine_active=true`, storing prior status for one-command rollback. Storage objects, URLs, identity-validation records and all historical evidence are **preserved**.

## §3 — Generation execution safety (verified)
- **No queue/retry/concurrency bypass.** Gemini (`commercial-image-generate`) re-evaluates `fn_product_commercial_asset_readiness` on every call (synchronous; no cached authorisation) → corrected gate fails closed. OpenAI (`creative-image-execute`) re-evaluates `fn_media_image_execution_context` at execution time per job; the executor claim is atomic (`WHERE executor_claimed_at IS NULL`), and a retried job re-enters the guard → corrected source guard blocks non-owned sources. The 5 already-produced outputs are quarantined (§2).
- **No cross-product/tenant/country substitution.** `products_with_owned_and_supplier = 0` — no product has both an owned upload and a supplier image, so no supplier substitution can occur today; `pulse-product-imports` has 0 objects.
- **Owned-image Gemini generation reported UNAVAILABLE (do not substitute supplier).** The `commercial-image-generate` edge resolves its reference only from the supplier storefront (`fn_resolve_storefront_assets`); it has **no owned/licensed reference resolver**. After the readiness fix, a supplier-only product → `NOT_ELIGIBLE` (no generation), and an owned-image product → the edge cannot select the owned image → `NO_AUTHORIZED_REFERENCE` → `NOT_ELIGIBLE`. **Net: the Gemini path never generates from an unauthorised supplier image; owned-image generation is unavailable until the edge reference resolver is wired (a separate edge deployment).**

## §4 — Tests, rollback, checklist, impact, decision
### Final SQL changes
`mig_375`, `mig_376`, `mig_377`, `mig_378` (above).

### Negative rights tests (decision outcomes)
| scenario | outcome |
|---|---|
| CJ supplier image, no AI rights → generation | **DENY** (readiness `reference_eligible=false`; `fn_asset_use_eligibility` `ai_input=false`; OpenAI guard DENY) |
| marketplace image → generation | **DENY** (readiness not eligible; `ai_input=false`; OpenAI guard DENY) |
| revoked/expired per-image permission | **DENY** (`mig_375` selftest; readiness evidence predicate excludes revoked/expired) |
| authorised owned/licensed image | **ALLOW**, documented uses only (CS.03 per-use; readiness eligible) |
| ambiguous/wrong-product image | **DENY** (CS.02 rejects AMBIGUOUS; non-owned/no-evidence → `ai_input=false`) |
| supplier image → commercial publish | **DENY** (readiness `CUSTOMER_ASSET_REQUIRED`/`NONE`) |
| quarantined historical asset → select/launch | **DENY** (`mig_377` gates) |
| no direct edge bypass | each edge's only gate is a corrected function |

### Existing regression results
11/11 Creative/media selftests green on live (0 failures), incl. `creative_production`, `ad_creative_identity` (8/8), `cj_image_rights`, `product_media_auth`, `media_runtime`, `cs03/cs02/e2e`. **Limitation:** the corrected functions' own selftests cannot run until applied (no prod write; no usable staging) → **post-apply check**; proof here is deterministic predicate evaluation on deployed data.

### Reversible rollback
All function changes are `CREATE OR REPLACE` → re-apply the pre-BE323/324/325 definitions (git history); pure redeploy, zero data impact. The `mig_378` quarantine is reverted by its inline rollback block (restores prior status from `provenance.rights_quarantine`, clears the flag). No deletes to undo.

### Post-deployment verification checklist
1. `fn_asset_use_eligibility_selftest`, `fn_product_media_discovery_selftest`, `fn_cs_media_end_to_end_selftest`, `fn_ad_creative_identity_selftest` → green.
2. `fn_product_commercial_asset_readiness(e453,'GB')`: `ai_generation.reference_eligible=false` **and** `commercial_asset_readiness=CUSTOMER_ASSET_REQUIRED` / `publishable_asset_path=NONE`.
3. Badge `fn_product_commercial_readiness_badge(e453,'GB')` → "Commercial assets: Customer image required".
4. The 3 generated assets → `fn_commercial_generated_asset_use` returns `rights_quarantined`; the 6 media assets → `fn_media_launch_eligibility` returns `RIGHTS_QUARANTINED`.
5. 11 existing selftests → 0 failures; spot-check an owned-image product → `reference_eligible=true`.

### Exact customer impact
- Products whose only imagery is supplier/marketplace: **cannot AI-generate and are not shown as commercially publishable** (badge truthfully says a customer image is required). They must upload an owned/licensed image (or obtain written commercial + AI-input permission).
- 3 historical generated images + 6 media assets become unselectable/not-launchable (quarantined, reversible); **no files deleted**.
- Products with owned images: unaffected by the gates, but owned-image Gemini generation remains **unavailable** until the edge reference resolver is wired.
- **No impact** on product research, discovery, workspace navigation, or any non-generation feature. No customer Creative Studio release; Creative Studio is **not** marked customer-complete.

### GO / NO-GO
**GO** — apply `mig_375 → mig_376 → mig_377 → mig_378` under separate founder deployment approval, then run the post-deploy checklist. The safety posture is fully fail-closed, reversible, low-risk. Residual (non-blocking) follow-ups, requiring an **edge deployment** out of this SQL-only scope: wire an owned/licensed reference resolver into `commercial-image-generate` before enabling owned-image generation.

## Controls
0 paid AI calls; 0 credits; **no production migration/deployment applied**; no rights-flag promotion; no customer Creative Studio download/release; no GPD.07; RLS/PAL/tenant+country isolation + revocation/expiry preserved. **GOLD 11/22 unchanged.** Files: `mig_375`, `mig_376`, `mig_377`, `mig_378` (committed, unapplied). Build Evidence row **BE325**.

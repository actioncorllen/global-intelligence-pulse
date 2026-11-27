# BE322 — CS.03 (per-asset rights & eligibility) + CS.02 (high-quality media discovery) + Task C fix

**Executed:** 2026-11-27 · **Authority:** founder "CREATIVE STUDIO NEXT BUILD — CS.03 + CS.02". **Approach:** reuse-first — no rebuild of Gemini/OpenAI/media-job/storage/product-identity/Product-Asset-Lock/Creative-Studio infrastructure. **Controls honoured:** no production deploy, no paid Gemini/OpenAI calls, no rights-flag promotion, no subscriber creative-download release, no GPD.07 activation, GOLD 11/22 unchanged. GPD.09 + the 18-Dec launch-critical requirements remain ahead.

**Decision: CS.03 = DONE (backend rights model + tests). CS.02 = PARTIAL (identity-anchored discovery + proofs DONE; live external high-res acquisition + resolution capture + multi-market breadth are provider-dependent and not authorised to spend now).**

---

## What was built (additive readers over existing primitives)
Reused: `fn_asset_rights_class` (origin class), `fn_cj_image_display_classification` (per-image evidence, specificity image>product>supplier>provider, revocation), `fn_ad_product_card_authority` (authoritative candidate set), `fn_product_supplier_identity` (verified identity). Tenant = `auth.uid()` (strong isolation).

### CS.03 — `fn_asset_use_eligibility(product, market, rights_state, source_provider, supplier_product_id, image_ref, provenance)`
Per-asset verdict across **7 use-classes**, fail-closed: `research_display`, `customer_download`, `commercial_advertising`, `derivative_creation`, `ai_input`, `video_production`, `subscriber_export`. Rules enforced in code:
- A research/marketplace image or a provider-global permission is **never** upgraded to commercial asset rights.
- Commercial uses require **per-image authoritative evidence** (unrevoked, unexpired) **OR** an owned/licensed/authorised-upload asset.
- `customer_download` and `subscriber_export` are permitted **only** for owned/licensed/uploaded assets — never third-party supplier/marketplace imagery.
- Revoked evidence ignored; **expired** `permission_scope.expires_at` voids commercial grants; attribution (provider/ownership/evidence level) and tenant isolation preserved.
- `ai_input` is allowed for an owned asset or an authorised supplier reference (consistent with the existing PAL-gated generation pipeline), never for a research/marketplace image.

Observed on real data (e453eed4): **owned upload → all 7 allowed; CJ supplier image → `ai_input` only; eBay marketplace → nothing.**

### CS.02 — `fn_product_media_discovery(product, market)`
Starts from the product's **verified identity** (never a marketplace research image). Returns per-candidate: source, **identity-match verdict** (EXACT_SUPPLIER_IDENTITY / OWNER_SUPPLIED; ambiguous substitutions dropped), resolution (from provenance; `UNKNOWN` when not stored), **permitted_use** (via CS.03), freshness (`observed_at`). Research/marketplace images are **excluded** as creative candidates and counted (`excluded_research_reference_images`). Explicit note: *"a successful media match is NOT proof of commercial eligibility."* Fallback sources enumerated: merchant upload (`pulse-product-imports`, rights-confirmed) + first-party originals. On e453eed4/GB: **12 exact-identity candidates, 28 research images excluded.**

## Task C — fixed the BE321 `ad_creative_identity` self-test failure
**Diagnosis: invalid/stale test expectation, NOT a production defect.** `fn_product_card_display_image` **correctly withholds** the CJ `SUPPLIER_PROVIDED` authoritative primary for e453eed4/GB because its display rights are UNVERIFIED (rights-safe placeholder) — the exact restriction the founder requires. The old check 2 asserted the card always *displays* the authoritative primary, contradicting the rights rule. **Smallest safe fix (self-test only; no rights record altered, no invariant weakened):** check 2 refined to the correct launch-critical invariant — *the display equals the authoritative primary OR correctly withholds an uncleared one; it never shows a different or marketplace image* — plus two **negative** checks: `rights_unverified_stays_blocked` (RIGHTS_UNVERIFIED → placeholder, never shown) and `marketplace_never_displayed` (eBay image → `display_allowed=false`). Result: **8/8 all_pass**.

## Tests / evidence (all deterministic, synthetic fixtures rolled back, no paid calls)
| Selftest | Result |
|---|---|
| `fn_asset_use_eligibility_selftest` (CS.03) | **10/10** — unauth, cross-tenant, owned-all-uses, marketplace-all-blocked, supplier-ai-only, evidence-scoped-advertising-only, **expired-blocks**, **revoked-blocks**, no-download/export-for-supplier, no-synthetic-persisted |
| `fn_product_media_discovery_selftest` (CS.02) | **7/7** — unauth, cross-tenant, starts-from-identity+excludes-marketplace, no-ambiguous-substitution, no-marketplace-candidate, search≠commercial-eligibility, exact-identity-match |
| `fn_ad_creative_identity_selftest` (Task C) | **8/8** (was 5/1) |
| `fn_cs_media_end_to_end_selftest` (Task D) | **9/9** — D1 product/variant match, D2 research-image-rejected-for-generation, D3 rights-safe-only-authorised-uses, D4 unknown-fail-closed, D5 revoked-or-expired-block, D6 cross-tenant-prevented, D7 no-unauthorised-download, D8 existing-paths-intact (0 failures across 8 existing Creative Studio selftests), no-synthetic-persisted |

**Task D — the 8 required scenarios, all proven:** (1) correct product+variant matching ✓; (2) research-only image rejected for creative generation ✓; (3) rights-safe candidate accepted only for its authorised uses ✓; (4) unknown rights fail closed ✓; (5) revoked/expired rights block use ✓; (6) cross-tenant substitution prevented ✓ (media candidates are anchored to the product's own verified identity — never borrowed from another tenant or country's product); (7) no unauthorised download URL / export right issued for third-party imagery ✓; (8) existing Creative Studio paths remain functional ✓.

## Security controls (preserved + verified)
Tenant isolation via `auth.uid()` (cross_tenant_rejected on both readers); RLS/PAL unchanged; marketplace/research imagery never commercial or generation-eligible; `RIGHTS_UNVERIFIED` default; per-image evidence with revocation + expiry; no download/export right for supplier/marketplace imagery; no rights-flag promotion; no subscriber-download release.

## Changed files / migrations / commits
- `supabase/migrations/mig_371_cs03_cs02_media_use_rights_and_discovery.sql` — `fn_asset_use_eligibility` (CS.03) + `fn_product_media_discovery` (CS.02).
- `supabase/migrations/mig_372_cs03_cs02_selftests.sql` — CS.03 + CS.02 selftests.
- `supabase/migrations/mig_373_fix_ad_creative_identity_selftest.sql` — Task C fix.
- `supabase/migrations/mig_374_cs_media_end_to_end_selftest.sql` — Task D end-to-end proof.
- `docs/CREATIVE-STUDIO-CS03-CS02-RIGHTS-AND-DISCOVERY-BE322.md` (this), master-doc Addendum 93. (Commit recorded in the register row.)

## DONE / PARTIAL decision + remaining work
- **CS.03 — DONE.** The per-asset rights model (7 use-classes, fail-closed, expiry/revocation, owned/upload/licensed lane, never-upgrade rule, tenant isolation) is implemented and proven. Remaining (non-blocking, separate units): customer-facing surfacing of per-use eligibility in the Creative Studio UI, and a merchant-upload rights-attestation UI (frontend; no subscriber-download release now).
- **CS.02 — PARTIAL.** Identity-anchored discovery, exact-match, substitute rejection, research-image exclusion, per-candidate rights, provenance/freshness, and fallback sourcing are DONE and proven. **Remaining (provider-dependent, no paid spend authorised):** (a) live acquisition of *new* high-resolution exact-product candidates from external supplier/manufacturer/approved media sources (requires provider calls); (b) capturing/recording actual pixel resolution (CJ-cached rows currently store none → `UNKNOWN`); (c) multi-market breadth testing beyond GB. These need budget/provider authorisation and are intentionally not executed under the strict controls.

## Controls
0 paid Gemini/OpenAI calls; 0 credits; no production deploy; no rights-flag promotion; no subscriber creative-download release; no GPD.07 activation; RLS/PAL/tenant isolation preserved; **GOLD 11/22 unchanged.** Build Evidence row **BE322**.

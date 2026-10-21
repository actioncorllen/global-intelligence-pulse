# 📌 PULSE-ECOM-STAGE4B-ALIEXPRESS-SUPPLIER-REQUIREMENT-001 (PINNED)

**PINNED STAGE 4B REQUIREMENT — RECORDED, NOT STARTED.** Add AliExpress as a *secondary* supplier
source, used **after** CJ Dropshipping, to support a truthful `NO_VALID_CJ_MATCH → AliExpress` sourcing
fallback. This document only *records and pins* the requirement per the founder's roadmap update. No
AliExpress API was called, no content scraped, no paid call or API purchase made, and no build was
started. Execution happens in **Stage 4B**, after current Stage-4A verification is complete and after
explicit approval for any authorised/paid AliExpress API access.

## Reference candidate (to verify in Stage 4B, not now)
- **AliExpress listing:** `1005013410315354`
- **Product:** Illuminated Snowman Christmas Door Hanger — commerce_products `873551b0-a0d0-44f6-8792-7b2650d904cd`
- **Research market:** GB
- **Why this candidate:** the Snowman's CJ supplier result is a truthful **NO_VALID_CJ_MATCH** (verified
  2026-10-21 — 40 CJ candidates, all CLOSE_COMPARABLE, no exact identity, none GB-shipping). It is
  therefore the ideal first test of the CJ→AliExpress fallback (item 4).

## Current state (read-only grounding, 2026-10-21)
- `provider_capability_registry` has **CJ as the only SUPPLIER source**; **no AliExpress entry exists**.
- No AliExpress credential, executor, or code path exists. This is a genuinely new secondary source.

## Architecture to REUSE (do not rebuild)
AliExpress must plug into the existing supplier architecture exactly as CJ does:
- **Supplier catalog:** `commerce_supplier_products` already keys rows by `(source, source_product_id)` —
  AliExpress rows coexist with `cjdropshipping` rows under `source='aliexpress'`. Same fields: sku,
  title, image_url, supplier_cost, cost_currency, weight_grams, shipping_country_codes, listing counts.
- **Exact-identity resolver:** `fn_resolve_concrete_supplier_identity` / `fn_stage2_resolve_from_pages` /
  `fn_stage2_cj_finalize_candidates` → `commerce_concrete_supplier_resolution`. The resolver binds ONLY a
  shared-identifier EXACT or a single STRONG/EXACT attribute match; **category-adjacent never binds**
  (item 5). AliExpress candidates must flow through the same resolver (generalise the CJ-specific
  finalize to accept an AliExpress page/candidate shape), never a bespoke approximate matcher.
- **Supplier-resolution handoff:** `fn_finalize_research_run` already runs the resolver at finalisation
  (mig_320). The fallback is: run CJ resolution first; if `NO_VALID_CJ_MATCH`, attempt AliExpress
  resolution over AliExpress candidates and bind only on an exact match (item 4).
- **Images + rights:** `product_image_assets` with `rights_state` (`REFERENCE_ONLY` / `SUPPLIER_PROVIDED`)
  and provenance — AliExpress media must carry truthful rights, never relabelled.
- **Product Asset Lock:** `auto_launch_campaign:false`, handoff BLOCKED for non-TEST — unchanged; an
  AliExpress bind never unlocks store/ad publishing on its own.
- **Budget:** if the AliExpress API is metered, reuse the USD budget guard (mig_318/mig_319:
  `fn_research_budget_*`, scoped, fail-closed) before any paid AliExpress call — do not add an unguarded
  paid path.
- **Registry:** first Stage-4B step is to add an `ALIEXPRESS` row to `provider_capability_registry`
  (evidence_category `SUPPLIER`) marked `EXTERNAL_APPROVAL_REQUIRED` until authorised access is confirmed,
  so the system honestly reflects a known-but-unavailable source. (Not added now — recording only.)

## Stage 4B verification gates (to perform during Stage 4B)
1. **Authorised access + multi-tenant SaaS permissions** — verify the official AliExpress Open Platform
   API (e.g. the dropshipping/affiliate product APIs), that the app's authorisation model supports a
   multi-tenant SaaS (per-tenant or app-level tokens, rate limits, ToS for resale of product data).
   Confirm before any call. No API purchase without approval.
2. **Exact product/variant identity** — check listing `1005013410315354` against the Snowman FastMoss
   discovery identity via the existing resolver; bind only on an exact product + variant identity, never
   an approximate/category match.
3. **GB shipping, prices, inventory, media, rights** — verify GB deliverability, supplier price, variant
   inventory, authorised media and their rights where the API genuinely exposes them; mark absent fields
   honestly (NO_DATA / UNSUPPORTED), never invented.
4. **Truthful fallback** — CJ `NO_VALID_CJ_MATCH` → attempt AliExpress; surface the bound source in the
   drawer (`selected_supplier='ALIEXPRESS'`) only on an exact bind, else truthful `NO_VALID_SUPPLIER_MATCH`.
5. **Isolation + no approximate binds** — preserve country/tenant isolation (server-owned tenant, market
   scoping); never bind an approximate match.

## Hard guardrails (apply throughout Stage 4B)
- **No scraping** of protected AliExpress content — official authorised API only.
- **No invented supplier evidence** — every supplier fact is API-sourced and provenance-stamped, or
  honestly absent.
- **No paid calls or API access purchase without explicit founder approval.**

## Dependencies / do-not-skip (current stage first)
Stage 4B must not start until these **current Stage-4A verification items** are closed (not skipped):
- **Stage 3 signed-in multilingual visual verification** (owed before paid launch).
- The Snowman research run's **TikTok SOURCE_FAILED** was fixed for future runs (UTC date contract,
  verified live); the Snowman's own run was not re-dispatched — a future/approved run confirms its
  corrected TikTok state.
- The **2 legacy products with live PUBLISHED pages** (3 Channel Dash Cam, kids nightlight projector)
  await a separate founder take-down decision (hidden from discovery but still published).

## Status
**PINNED · STAGE 4B · NOT STARTED · BLOCKED pending (a) authorised/paid AliExpress API approval and
(b) completion of the current Stage-4A verification items above.** Recorded only — no build, no API
call, no scraping, no paid call, no operational/registry change made by this task.

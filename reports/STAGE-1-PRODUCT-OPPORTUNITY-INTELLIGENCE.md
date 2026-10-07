# STAGE 1 — Fresh Discovery → Qualified Winning Product + Permanent Root-Cause Fixes

**Date:** 2026-10-07
**Tenant:** 7c8ddf9d-172c-4a89-a402-bb7066228b61 · **Project:** nxaunmyihhjixxxljcqt (live prod)
**Branch:** claude/cool-faraday-kgudh1
**Scope rule:** STRATELOQ EXECUTION (fast) + STRATELOQ PERMANENT-FIX RULE. Stage 1 only — no Stage 2.

---

## 0. Headline

- **Fresh discovery works** and is now **permanently wired to the authoritative market config** — a selected country resolves its own provider location, valid language, currency and evidence scope with nothing hardcoded. Proven end-to-end on a live DE run (language `de`, not `en`).
- **State separation is now enforced by production code and regressions, not prompts** — discovery ≠ monitoring, candidate ≠ qualified, concept ≠ concrete, country-isolated, image-independent. All green.
- **The 6 freshly discovered DE candidates did NOT qualify.** Driven through the REAL production opportunity tournament, every one is globally rejected: they are CONCEPT_ONLY (a normalized keyword name + search demand), with no concrete market evidence. Coaxial cable (search volume 2400) did **not** win — exactly as cautioned.
- Honest run result: **NO_QUALIFIED_OPPORTUNITY_THIS_RUN.** Standards were not lowered.

---

## 1. Permanent root-cause fixes

### Issue A — DE (and every non-English market) was a latent DataForSEO `40501`

- **ROOT CAUSE:** production resolved a provider *location* per market but had **no authoritative language**. The discovery relay carried a hardcoded `language=en`, correct for GB/US but invalid for DE/IT/FR/… DataForSEO rejects a location+language mismatch (`40501 Invalid Field: language_code`; DE location 2276 requires `de`). The only "fix" was a human remembering to change it — the "remembering config" anti-pattern.
- **SMALLEST PRODUCTION FIX:** carry `dataforseo_language_code` for each market in the one authoritative table `ecommerce_market_universe`, and resolve everything from there.
- **DURABLE CONTRACT:** `fn_market_provider_config(country)` → `{location_code, language_code, currency, ecommerce_eligible, evidence_scope, ok, reason}`, fail-closed (`UNKNOWN_MARKET` / `NO_PROVIDER_LOCATION` / `NO_PROVIDER_LANGUAGE`). `fn_dataforseo_discovery_request(market, category)` builds the exact DataForSEO request so no caller re-derives location/language.
- **MIGRATION:** `mig_368a` (language column + 21-market mapping), `mig_368b` (resolver + request builder + regression), `mig_368c` (completed HK/MY/PH/SG provider locations surfaced by the regression).
- **REGRESSION:** `fn_market_provider_config_selftest()` — 8/8 pass (DE→`de`/2276, GB→`en`, IT→`it`, BE→`nl`, US→`en`/2840/USD, unknown→unsupported, no eligible market missing config, request builder resolves language).
- **REAL-PATH VERIFICATION:** executed the live 013Q workflow for DE; run `918345cb` resolved DE→location 2276 + language `de` automatically and recorded **`language="de"`** on the search-demand evidence (coaxial 2400, vb cable 1000, cable tray 480 …) — DataForSEO accepted `de`, no `40501`.
- **RECURRENCE PREVENTED:** language is now data in the authoritative config; no code or workflow hardcodes it; a missing/invalid market fails closed instead of silently calling the wrong language.

### Issue B — the n8n discovery relay (013Q) hardcoded per-market config

- **ROOT CAUSE:** the 013Q "Discovery Config" node hardcoded `location_code` and `language`; a new market needed a human to hand-edit them (and get them right).
- **FIX (small launch-critical wiring, reversible):** added a **Resolve Market Config** node that calls `fn_dataforseo_discovery_request(market, category)`; the DataForSEO Keyword Ideas / Search Intent nodes now read the resolved `location_code`/`language_code`, and Build Payload records the authoritative language on each keyword. The operator now sets only `market` + `category`. Patch applied via atomic operations; **all existing credentials preserved**; previous version retained for rollback.
- **VERIFICATION:** live test execution `30408` succeeded; run `918345cb` wrote `language="de"` with no manual pin (see Issue A).
- **PENDING (founder action):** the wired workflow version is saved but **publish/activate is gated as a production deploy** and was not auto-approved. Publish 013Q to make the wired version canonical for scheduled/production runs. (Functionally it already runs via manual/MCP execution.)

### Issue C — image-independence proof was a frozen constant (fixture-as-proof)

- **ROOT CAUSE:** `fn_product_image_selftest.image_does_not_change_score` asserted the GB score equals a hardcoded `68.2`. Scores legitimately drift as the evidence window advances, so the check went red for a reason unrelated to images — and a frozen expected value is itself a fixture presented as proof.
- **PERMANENT FIX (test-assertion only, no asset-pipeline change):** snapshot the score → resolve/capture an image → re-read the score → assert **byte-identical** (delta 0). Value-independent, cannot rot. Complemented by the structural proof in `mig_369` that no scoring function references any image/asset store.
- **MIGRATION:** `mig_370`. **REGRESSION:** `fn_product_image_selftest()` now 10/10 (was 9/10).
- **RECURRENCE PREVENTED:** image-independence is proven by behaviour + structure, not a magic number.

---

## 2. State-separation invariants — enforced in code, proven by regression

`mig_369` adds `fn_stage1_product_opportunity_invariants_selftest()` — **8/8 pass** against the real schema and the real scoring functions:

| Invariant | Check | How it is proven |
|---|---|---|
| DISCOVERY ≠ MONITORING | `DISCOVERY_DISTINCT_FROM_MONITORING` | distinct stores (`commerce_products` vs `monday_opportunity_registry`), bridged by the discovery RPC |
| New product enters lifecycle w/o manual insert | `NEW_PRODUCT_AUTOREGISTERS_NO_MANUAL_INSERT` | discovery RPC body contains `INSERT INTO monday_opportunity_registry` |
| NEW CANDIDATE ≠ QUALIFIED | `CANDIDATE_NOT_AUTOMATICALLY_QUALIFIED` | discovery RPC never touches `product_opportunity_decisions`; active candidates exist with 0 decisions |
| CONCEPT ≠ CONCRETE | `CONCEPT_ONLY_FAILS_CLOSED_NOT_CONCRETE` | real tournament globally rejects a live concept-only candidate (0 evaluated combinations) |
| Volume alone ≠ qualification | `SEARCH_VOLUME_ALONE_DOES_NOT_QUALIFY` | candidate with recorded search volume is still globally rejected |
| Image independence | `OPPORTUNITY_SCORING_IMAGE_INDEPENDENT` | no scoring function references any image/asset table |
| Provider config resolves automatically | `MARKET_PROVIDER_CONFIG_RESOLVES_AUTOMATICALLY` | DE→`de`/EUR, GB→`en`, US→USD; full market regression passes (not hardcoded to one market) |
| Country isolation | `COUNTRY_ISOLATION_PER_MARKET_EVIDENCE` | evaluations keyed by `country_code`; each market resolves its own currency/location/evidence scope |

Representative concept-only candidate auto-selected at runtime (no fixture UUID): porter cable — globally rejected.

---

## 3. The 6 DE candidates — deep research through the real path

All six were discovered fresh (DataForSEO keyword expansion of the `cable organizer` seed), auto-registered in `monday_opportunity_registry`, and carry real DE search demand. Driven through the **real production tournament** `fn_pod_tournament` (and assembler `fn_assemble_real_product_market`, contract `pulse_real_assembler_v3_013j`):

| Candidate | DE search volume | Tournament result |
|---|---|---|
| coaxial cable | 2400 | globally rejected · 0 combinations evaluated |
| cable pull-through | 2400 | globally rejected |
| vb cable | 1000 | globally rejected |
| overhead extensions cable | 720 | globally rejected |
| cable tray | 480 | globally rejected |
| porter cable | — | globally rejected |

**Why (honest, not a defect):** each is `identity_basis = normalized_name` with `observed_price = null`, `product_url = null`, `availability = null`. The assembler reports `competitor_entries = 0`, `price_median = null`, `total_listings = null`, `supplier_match_class = UNKNOWN`, `economics_certified = false`. With **no concrete market evidence**, the tournament evaluates 0 product×market combinations and the product is globally rejected with **no decision manufactured**. This is the system correctly fail-closing: a bare keyword cannot become a qualified opportunity.

**Control (the path is not broken):** on the same code path, products that *do* carry concrete evidence score real decisions — nightlight projector DE 73.2 (STRONG_TEST), humidifier BE/GB/IT 100 (EXCEPTIONAL) on the 2026-10-05 run. The cables simply lack evidence.

**Run result: `NO_QUALIFIED_OPPORTUNITY_THIS_RUN`.** No newly discovered product became CONCRETE_RESOLVED or met the founder benchmark. Standards were not lowered; no product was manually selected.

---

## 4. Discovery mode & capability gap

- **DISCOVERY MODE: manual-category-seed (Type C).** The operator supplies a category seed (`cable organizer`); DataForSEO Keyword Ideas expands it into related candidate names. It **does** surface names the operator did not type (coaxial cable, cable tray, porter cable were not seeded) — so it is genuine within-category discovery, not merely research of named candidates.
- **Discover (A) vs Research (B):** DataForSEO keyword expansion = category-seeded **discovery (A, bounded)**. There is **no autonomous market-wide or social-trend discovery** wired (the historical Reddit path is a mention/research path, not a live trend crawler). TikTok/social is an *evidence/research* source for already-named candidates, not an independent discovery engine.
- **DISCOVERY_CAPABILITY_GAP (the chain break):** the fresh-discovery path produces a keyword-named CONCEPT_ONLY candidate, but there is **no automated step that gathers concrete market/merchant evidence** (competitor listings, observed prices, supplier match) for a freshly discovered DE keyword. Until that evidence exists, a new candidate cannot become CONCRETE_RESOLVED and therefore cannot be ranked. This is the single missing link between "discovered" and "qualified" for the fresh path.

---

## 5. Downstream image / Product Asset Lock contract — already encoded

The architecture already encodes the downstream contract (not rebuilt here, per scope):
`fn_resolve_product_image` (EXACT_PRODUCT vs CLOSE_COMPARABLE vs REFERENCE_ONLY; `hero_eligible` only for EXACT + SUPPLIER_PROVIDED/OWNED rights; comparable/marketplace imagery labelled reference, never silently authoritative; rights_state + provenance carried; canonical `supplier_product_assets`), persisting to `product_asset_intelligence`. `fn_product_image_selftest` (10/10) proves: supplier/marketplace resolve, no cross-product leakage, no keyword-only assignment, same product image across GB/DE, missing image not fabricated, no credentials in assets, **and image independence from score and decision**. No fabrication; `AUTHORITATIVE` honesty preserved.

---

## 6. DURABILITY CHECK

| Delivered result | Depends on a pin / manual SQL / manual selection / founder memory / fixture-only? | Durable? |
|---|---|---|
| Market→location/language/currency/evidence-scope resolution | No — authoritative table + resolver + regression | ✅ |
| 013Q relay uses resolved config | No — workflow wired to the resolver; verified live with `de` | ✅ (saved; **publish is a pending founder action**) |
| State-separation invariants | No — enforced by schema + function source + live tournament | ✅ |
| Image independence | No — behavioural delta + structural proof (no frozen constant) | ✅ |
| 6-candidate verdict | No — produced by the real tournament, not a manual pick | ✅ |
| DataForSEO balance | External — credit is low/intermittent; unrelated to the fixes | n/a (founder-owned) |

**Only remaining non-code dependency:** publishing the wired 013Q version (gated as a production deploy; founder to approve) and DataForSEO account balance. Neither is a code durability gap.

---

## 7. Migrations in this change

- `mig_368a_market_universe_language_config.sql`
- `mig_368b_market_provider_config_resolver.sql`
- `mig_368c_complete_missing_provider_locations.sql`
- `mig_369_stage1_product_opportunity_invariants_selftest.sql`
- `mig_370_image_independence_durable_regression.sql`

All applied to live prod and registered in the migration ledger. Regressions: market config 8/8 · stage-1 invariants 8/8 · image contract 10/10.

---

## 8. Verdict

Permanent root-cause fixes are delivered, generalized at the authoritative boundary, and regression-proven. Fresh discovery → current evidence → deep research ran on the real system. But **no newly discovered product reached CONCRETE_RESOLVED or met the founder benchmark this run**, and the concrete-product-resolution/merchant-evidence link for the fresh path is a real capability gap. Honest result: **NO_QUALIFIED_OPPORTUNITY_THIS_RUN**.

BLOCKED_STAGE_1_PRODUCT_OPPORTUNITY_INTELLIGENCE

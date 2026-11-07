# Product Opportunity Tier Refinement — PREMIUM / GOLD / PLATINUM (proposed; prepared-only)

**Nothing applied to prod; nothing published.** Branch `claude/nifty-bardeen-f9nddu`. This is a **refinement** of the
existing Product Opportunity Intelligence engine — it adds a derived `tier` label computed from evidence contracts the
engine already produces. It does **not** rebuild the recommendation engine, re-score products, or change the
TEST/WATCH/AVOID decision for any product.

---

## 0. FIRST — existing systems inspected (contracts reused, not replaced)

All tier logic is derived from fields the engine **already computes and already loads** in the recommendation path.
No new tables, no new scoring, no new paid provider calls.

| Contract | Where | Fields reused for tiering |
|---|---|---|
| **Product Opportunity Decisions** | `public.product_opportunity_decisions` (per product × country) | `decision` (TEST/WATCH/AVOID), `product_opportunity_score`, `opportunity_band`, `overall_evidence_confidence`, `product_confidence`, `saturation_state.level`, `opportunity_sweet_spot.state`, `advertising_headroom.state`, `metric_scope`, `hard_gates{supplier,economics,compliance,fulfilment,saturation,market_price}`, `decision_blockers[]`, `execution_blockers[]`, `is_fixture` |
| **Market Evaluation (per country)** | `public.product_market_evaluations` | `evidence.supplier_identity.match_class`, `evidence.observed_market_price.source_class`, `economics.known` / `economics.contribution_after_reserve`, `landed_cost`, `stock_state`, `evidence_window`, `evidence_confidence`, `gate_state`, `risk_flags` |
| **Recommendation RPCs** | `get_own_opportunity_recommendations(p_limit)` → `fn_monday_top_opportunities(tenant,limit)` | Already server-identity-scoped (`auth.uid()`), already `DISTINCT ON (product_id)` best-country, already excludes AVOID + null-score + hidden; returns `ready_to_test[]` (decision=TEST), `watchlist[]` (decision=WATCH), counts. **The tier field is added to each card object here.** |
| **Supplier exact-SKU (CJ)** | `evidence.supplier_identity.match_class = 'EXACT_PRODUCT'` → card `supplier_match='EXACT'` | Platinum "verified supplier SKU/variant" |
| **Commercial readiness** | `fn_product_commercial_readiness_badge(product_id, market)` → `fn_product_commercial_asset_readiness` | Independent launch-readiness dimension (unchanged) |
| **Recommendations frontend** | Lovable `recommendations` view + premium cards + `ExplorerDrawer` exact-product nav | Tier badge + country selector + tier legend added; **premium card design preserved** |

**Key architectural facts confirmed in prod (read-only):**
- The engine already evaluates **every product independently per country** — one `product_opportunity_decisions` row
  per (product, country), one `product_market_evaluations` row per (product, country). Country isolation is native.
- `opportunity_band` (EXCEPTIONAL / HIGH_CONFIDENCE / HIGH_CONFIDENCE_TEST / STRONG_TEST / TRENDING_WATCH / WATCH /
  AVOID / INSUFFICIENT) is a **score bucket**, independent of the gated `decision`. A product can be band=EXCEPTIONAL
  and still `decision=WATCH` because the commercial-readiness **hard_gates** are not satisfied.
- `hard_gates` is the authoritative 6-dimension commercial-readiness rollup. **This, not the score, is what
  separates the tiers** — which is exactly why tiers are "evidence-based," not "arbitrary scoring thresholds."

---

## 1. SECOND/THIRD — proposed tier eligibility rules (derived from existing contracts)

Tiers are evaluated **per (product, country)**. A product may be a different tier (or untiered) in each country.
The tier is **orthogonal to the decision**: it describes *evidence/commercial-readiness strength*; the decision
(TEST/WATCH/AVOID) is unchanged and still governs launch-eligibility.

Notation (all from the contracts above, for the given country):
- `gates` = the 6 `hard_gates` values. `ALL_GATES_PASS` ⇔ all six = `PASS`.
- `no_critical_blocker` ⇔ `decision_blockers` has no unresolved critical entry **and** `execution_blockers` is empty.
- `supplier_exact` ⇔ `supplier_identity.match_class = 'EXACT_PRODUCT'`.
- `econ_credible` ⇔ `economics.known = true` **and** `landed_cost IS NOT NULL` **and** `contribution_after_reserve` is present.
- `stock_known` ⇔ `stock_state` is a concrete in-stock value (not `UNKNOWN`) **and** `gates.fulfilment = PASS`.
- `price_local_validated` ⇔ `metric_scope = 'LOCAL'` **and** `observed_market_price.source_class <> 'UNKNOWN'` **and** `gates.market_price = PASS`.
- `saturation_ok` ⇔ `gates.saturation = PASS` **and** `saturation_state.level ∈ {LOW, MODERATE}`.
- `conf_high` ⇔ `overall_evidence_confidence = HIGH`.
- `fresh` ⇔ `evidence_window` non-empty **and** its observation window is within the engine's freshness horizon.
- `demand_signal` ⇔ `opportunity_band ∈ {EXCEPTIONAL, HIGH_CONFIDENCE, HIGH_CONFIDENCE_TEST, STRONG_TEST, TRENDING_WATCH}`
  **or** `overall_evidence_confidence ≥ MEDIUM` (engine's own corroboration rollup).

### PLATINUM (per country) — highest-confidence, commercially validated. ALL of:
1. `decision ≠ AVOID` (never Platinum on an AVOID product)
2. `ALL_GATES_PASS` (all 6 hard gates PASS)
3. `no_critical_blocker`
4. `supplier_exact` — verified exact product identity + supplier SKU/variant
5. `stock_known` — destination stock & shipping confirmed
6. `econ_credible` — credible landed-cost + contribution-margin estimate
7. `price_local_validated` — attractive, locally-validated market price
8. `saturation_ok` — suitable competitor/saturation conditions
9. `conf_high` and `product_confidence ∈ {MEDIUM, HIGH}`
10. `fresh` — adequate evidence provenance & freshness

### GOLD (per country) — strong, credibly validated with minor gaps. Not Platinum, and ALL of:
1. `decision ≠ AVOID`
2. `overall_evidence_confidence ≥ MEDIUM`
3. `price_local_validated` (validated local market price)
4. `saturation_ok`
5. `econ_credible` (supplier economics / contribution computed)
6. `gates.supplier = PASS` and `supplier_identity.match_class ∈ {EXACT_PRODUCT, STRONG, CLOSE}`
7. no gate = `FAIL`; no `execution_blocker`; at most non-critical gaps remaining (e.g. compliance/fulfilment provisional)

### PREMIUM (per country) — meaningful early opportunity evidence, incomplete commercial validation. Not Gold/Platinum, and ALL of:
1. `decision ≠ AVOID` and `product_opportunity_score IS NOT NULL`
2. `opportunity_band ≠ AVOID`
3. `demand_signal` (a positive engine band **or** corroborated MEDIUM+ evidence)

### Untiered — "Emerging signal, insufficient evidence to tier" (shown, honestly, under WATCH):
- In the feed but below the Premium floor: `opportunity_band ∈ {AVOID, WATCH, INSUFFICIENT}` **and** `overall_evidence_confidence < MEDIUM`.
- Rendered under the existing WATCH lane with an honest "not yet tiered — evidence incomplete" note. **Never** promoted to a tier to fill a section.

### Ready to Test — Platinum Opportunities (THIRD):
- A card appears **only if** `tier = PLATINUM` **AND** `decision = TEST`.
- If none qualify → **honest empty state** ("No products currently meet Platinum + Test requirements"). No artificial promotion.

**Why this is defensible, not arbitrary:** every predicate is a direct read of a field the engine already emits
(`hard_gates`, `decision_blockers`, `supplier_identity.match_class`, `economics.known`, `landed_cost`, `stock_state`,
`metric_scope`/`observed_market_price`, `saturation_state`, `overall_evidence_confidence`, `evidence_window`,
`opportunity_band`). No new numeric cutoff is introduced on top of the score; the score alone never promotes a product.

---

## 2. FOURTH — country isolation

- Tier is computed from the **(product, country)** decision + market-evaluation rows only. No cross-country field is
  read. `fn_monday_top_opportunities` already picks the best country **per product** via `DISTINCT ON (product_id)`;
  the tier is computed for *that* country's row. When the frontend country selector changes the market, the tier is
  recomputed from that country's row.
- A product can be PLATINUM in one country and PREMIUM/untiered/AVOID in another. No global suppression or promotion.
- Test evidence for isolation is in §5.

---

## 3. FIFTH — ROI & profitability honesty (display contract)

The tier badge and card must **never** imply guaranteed profit or measured ROI. The card distinguishes, using only
fields that exist:
- **Observed sales** — only if a real attributable sales count exists (none in current evidence). TikTok views / est. GMV are labelled **"observed interest, not verified sales."**
- **Estimated revenue** — labelled "estimated," shown only when `observed_market_price.source_class` supports it.
- **Gross margin / contribution margin** — shown only when `economics.known = true`; contribution uses `contribution_after_reserve` and is labelled "estimate after ad reserve."
- **Break-even CAC** — shown only if the economics contract provides it; otherwise "not yet computed."
- **Advertising performance evidence** — from `advertising_headroom` / ad-signal evidence, labelled as *headroom signal*, not performance.
- **Actual measured ROI** — shown **only** with real attributable outcome data (post-performance). Absent today → the card states "No measured ROI yet."
- A PLATINUM badge asserts **evidence quality & commercial readiness**, explicitly *not* a profit guarantee. Copy: "Platinum = highest-confidence evidence & commercial-readiness; not a profit guarantee."

---

## 4. SEVENTH — evaluation of the current 8 recommendations (real evidence, prod read-only, 2026-11-07)

Feed-eligible universe = 8 rows (one best-country row per non-AVOID, scored, non-hidden product). **All 8 are
`decision = WATCH`** (zero TEST). Per-row evidence and resulting tier:

| # | Product | Mkt | Decision | Band | Score | Overall evid | Saturation | Gates PASS (of 6) | Supplier match | Economics | Landed cost | Stock | Local price | **Tier** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Beleuchtete Krippen Wanddekoration | DE | WATCH | HIGH_CONFIDENCE_TEST | 87.0 | NONE | UNKNOWN | 0 | UNKNOWN | unknown | – | UNKNOWN | unvalidated | **PREMIUM** (positive band) |
| 2 | More Adventskalender 2026 | DE | WATCH | STRONG_TEST | 77.6 | MEDIUM | VERY_HIGH | 0 | UNKNOWN | unknown | – | UNKNOWN | unvalidated | **PREMIUM** (band + MEDIUM evid) |
| 3 | Illuminated Snowman Christmas | GB | WATCH | TRENDING_WATCH | 56.0 | NONE | MODERATE | 1 (saturation) | UNKNOWN | unknown | – | UNKNOWN | unvalidated | **PREMIUM** (positive band) |
| 4 | Makita Adventskalender 2026 | DE | WATCH | WATCH | 53.0 | NONE | LOW | 1 (saturation) | UNKNOWN | unknown | – | UNKNOWN | unvalidated | **Untiered** (band WATCH + evid NONE) |
| 5 | ESN Designer Proteinriegel | DE | WATCH | WATCH | 49.7 | MEDIUM | VERY_HIGH | 0 | UNKNOWN | unknown | – | UNKNOWN | unvalidated | **PREMIUM** (MEDIUM evid) |
| 6 | Herren-Fleecejacke für den Winter | DE | WATCH | WATCH | 48.0 | NONE | UNKNOWN | 0 | UNKNOWN | unknown | – | UNKNOWN | unvalidated | **Untiered** (band WATCH + evid NONE) |
| 7 | Ankerkraut Premium Adventskalender | DE | WATCH | AVOID | 22.7 | LOW | MODERATE | 1 (saturation) | UNKNOWN | unknown | – | UNKNOWN | unvalidated | **Untiered** (band AVOID) |
| 8 | Hit the Slab | DE | WATCH | AVOID | 10.0 | NONE | UNKNOWN | 0 | UNKNOWN | unknown | – | UNKNOWN | unvalidated | **Untiered** (band AVOID) |

**Per-product read:**
- **Missing commercial information — identical across all 8:** no exact supplier identity/SKU (`match_class=UNKNOWN`),
  economics unknown (`economics.known=false`), no landed cost, stock `UNKNOWN`, market price `LOCAL_UNVALIDATED`
  (`source_class=UNKNOWN`), evidence provenance window empty, `product_confidence=LOW`, `opportunity_sweet_spot=INSUFFICIENT_EVIDENCE`.
- **Decision:** all 8 = **WATCH** (engine's own gated decision; unchanged).
- **Eligible tier:** 4 × **PREMIUM** (#1,2,3,5), 4 × **Untiered** (#4,6,7,8). **0 GOLD, 0 PLATINUM.**
- **Downgrade / disqualification reasons:**
  - **No product reaches GOLD:** every one fails validated local price, credible economics, and ≥MEDIUM evidence
    simultaneously — `market_price` gate PASS = 0/8, `economics.known` = 0/8.
  - **No product reaches PLATINUM:** all-6-gates-pass = 0/8; exact supplier = 0/8; landed cost = 0/8; stock known =
    0/8; validated local price = 0/8; evidence window present = 0/8. Fails on every Platinum dimension except (for 3
    products) saturation.
  - **#4 Makita / #6 Herren-Fleecejacke untiered:** neutral band (WATCH) with no corroborated evidence (NONE) — no
    genuine demand signal to justify even Premium.
  - **#7 Ankerkraut / #8 Hit the Slab untiered:** band = AVOID (negative opportunity assessment) — not "promising."
- **Ready to Test — Platinum:** **EMPTY** — both because 0 products are PLATINUM **and** because 0 products are TEST.
  This is the honest state; nothing is promoted to fill it.

**This directly answers the founder's "do not assume any currently qualifies for Platinum": none does, and the
evidence for each disqualification is a concrete, named contract field.**

---

## 5. Country isolation — test evidence (same product, different countries)

Products evaluated in multiple countries, showing country-relative, independent assessment (prod read-only):

| Product | Country | Band | Score | Saturation gate | → tier signal differs by country |
|---|---|---|---|---|---|
| cool mist humidifier | GB | EXCEPTIONAL | 100.0 | WATCH | demand-positive band |
| cool mist humidifier | NL | STRONG_TEST | 75.0 | WATCH | demand-positive band |
| cool mist humidifier | IT | STRONG_TEST | 72.1 | WATCH | demand-positive band |
| cool mist humidifier | BE | STRONG_TEST | 72.5 | WATCH | demand-positive band |
| over door shoe organizer | CA | STRONG_TEST | 79.0 | WATCH | demand-positive band |
| over door shoe organizer | GB | TRENDING_WATCH | 67.4 | WATCH | demand-positive band |
| over door shoe organizer | IE | TRENDING_WATCH | 65.9 | WATCH | demand-positive band |
| over door shoe organizer | IT | STRONG_TEST | 72.0 | **PASS** | saturation suitable only in IT |
| kids nightlight projector | GB | STRONG_TEST | 78.2 | WATCH, market_price **PASS** | local price validated only in some markets |
| kids nightlight projector | BE | TRENDING_WATCH | 61.1 | WATCH | lower band in BE |

Same product, materially different per-country band, saturation-gate and price-gate outcomes → tier must be (and is)
computed per country. None of these reach GOLD/PLATINUM either (same missing supplier/econ/stock/landed/price), but
they demonstrate the isolation the rules depend on.

---

## 6. Changes delivered (prepared-only; NOT applied / NOT published)

- **Backend (prepared migration `mig_334_opportunity_tiers.sql`, NOT applied):** pure, read-only
  `fn_opportunity_tier(jsonb)` + `fn_evidence_window_fresh(jsonb)` helpers, and a derived `tier` + `tier_reasons[]`
  (plus `evidence_confidence`, `evidence_fresh`, `roi_basis`) added to each card inside `fn_monday_top_opportunities`,
  with new top-level `ready_to_test_platinum` (tier=PLATINUM AND decision=TEST), `ready_to_test_platinum_count`,
  `tier_counts`, `tier_policy`. Surfaced through the unchanged `get_own_opportunity_recommendations` wrapper. No new
  table, no re-score, no decision change, no new grants, SECURITY DEFINER + `search_path=''` preserved, tenant scoping
  via `auth.uid()` unchanged; `ready_to_test`/`watchlist` + counts preserved; contract →
  `pulse_monday_top_opportunities_v3_tiers`.

- **Frontend (Lovable preview `28b4c4f2`, built on `9da86c94`; NOT published):**
  - `opportunity-recommendations-api.ts` — fail-closed decoder extended: `tier` (only the three literals else null),
    `tierReasons`, `evidenceConfidence`, `evidenceFresh` (only explicit `true`), `roiBasis`; outcome adds
    `readyToTestPlatinum`, `readyToTestPlatinumCount`, `tierCounts` (null unless all four counts finite — never
    0-filled). Existing keys unchanged; still calls `get_own_opportunity_recommendations(p_limit:20)`.
  - `opportunity-recommendations-view.tsx` — restrained tier badge beside the decision badge (only when the server
    returns a tier; PLATINUM strongest → GOLD → PREMIUM muted, each with a one-line tooltip); headline
    **"Ready to Test — Platinum Opportunities"** section over `readyToTestPlatinum` with the honest empty state; tier
    legend (shows `tier_counts` only when all four present); per-card **evidence-freshness** line; per-card
    **ROI-honesty** line ("No measured ROI yet — evidence & readiness only, not a profit guarantee"; adds "Economics are
    estimated, not measured" when flagged); **country-filter** chip row ("All markets" default) narrowing all sections by
    best market. Premium card design, exact-product `?product=` nav, translations, images (no generation), locked launch
    actions preserved.
  - **Fail-closed:** `mig_334` unapplied → live RPC returns no tier fields → preview shows no badges, Platinum section
    honest-empty, watchlist = the 8 current WATCH items (today's honest state). Lights up once `mig_334` is approved+applied.

### Frontend verification (Lovable preview `28b4c4f2`)
- **500 tests pass** (71 files; **+11 new**): tier decode for each literal + null; `tier_reasons`/`roi_basis`/
  `evidence_*` fail-closed; `ready_to_test_platinum` + counts + `tier_counts` decode; **absent tier fields → tier null,
  Platinum [], tierCounts null** (regression — pre-tier fixtures still decode); Platinum+Test fixture renders under the
  Platinum section with a PLATINUM badge; empty Platinum → honest empty state; tier-null card → no badge; country filter
  narrows by market; ROI-honesty line present; View Product still navigates by canonical `productId`.
- `bunx tsgo --noEmit` clean; eslint clean on changed files (8 pre-existing-style warnings re: co-located helper
  exports); preview build OK.
- **Not verifiable from container:** live signed-in appearance (egress 403 + auth-gated) → founder device acceptance;
  populated-tier appearance in preview requires `mig_334` applied (founder approval).
- **Production unchanged:** still runs `9da86c94`; `28b4c4f2` is preview-only (`deploy_project` NOT called).

### Open UX decision (does not block approval)
With 0 TEST products today this is theoretical: the build keeps the existing decision-based "Ready to test" section (all
decision=TEST) **below** the new Platinum section, so a future PLATINUM+TEST product would appear in both. Options:
(a) keep as-is; (b) make "Ready to Test" show only Platinum+Test and group other TEST-decision products separately.
Recommend (a) for now; switch on your word.

## 6b. EIGHTH — rule behaviour tests (read-only on prod data + synthetic cases; migration NOT applied)

Tier predicates were exercised against the real 8 feed rows **and** synthetic positive cases, in a read-only query
that mirrors `fn_opportunity_tier` exactly (no write to prod). Results:

**Real feed (matches §4):** 4 PREMIUM (Beleuchtete Krippen, ESN, Illuminated Snowman, More Adventskalender),
4 untiered (Makita, Herren-Fleecejacke — band WATCH + evid NONE; Ankerkraut, Hit the Slab — band AVOID),
**0 GOLD, 0 PLATINUM, 0 TEST** → Ready-to-Test-Platinum empty. ✅

**Synthetic boundary cases:**
| Case | Inputs (abridged) | Expected | Got |
|---|---|---|---|
| platinum_DE | all 6 gates PASS, exact supplier, econ+landed, stock IN_STOCK, local validated price, sat LOW, HIGH conf, fresh, decision TEST | PLATINUM | **PLATINUM** ✅ |
| platinum_DE (**FR**, same product) | sat VERY_HIGH, gates WATCH, no local price, not fresh | not Platinum (country isolation) | **PREMIUM** ✅ |
| gold_ok | MEDIUM evid, local price, sat MODERATE+PASS, econ+landed, supplier STRONG, 1 gate (compliance) WATCH | GOLD | **GOLD** ✅ |
| gold_exact | all gates PASS + exact supplier + stock + econ + price + sat, but conf MEDIUM & not fresh | GOLD (held below Platinum) | **GOLD** ✅ |
| gold_satfail | otherwise GOLD but saturation VERY_HIGH + gate WATCH | PREMIUM | **PREMIUM** ✅ |
| premium_GB | positive band, no commercial validation | PREMIUM | **PREMIUM** ✅ |
| untiered_DE | band WATCH + evid NONE | untiered | **null** ✅ |

Tests covered (EIGHTH): **country isolation** (platinum_DE vs FR diverge), **tier eligibility** (each tier's floor),
**missing-evidence handling** (unknown supplier/econ/stock/price → never Platinum/Gold), **no unsupported Platinum
promotion** (gold_exact held at GOLD for lack of freshness/HIGH-conf; all 8 real products ≤ PREMIUM), **correct
supplier economics** (econ_credible requires `economics.known` AND `landed_cost`), **stable identity** (keyed on
canonical `commerce_products.id`, unchanged). **No cross-tenant access:** `fn_monday_top_opportunities` remains
SECURITY DEFINER scoped to `p_tenant` supplied only by the `auth.uid()` wrapper `get_own_opportunity_recommendations`;
the browser cannot choose the tenant (unchanged). **Regression:** `ready_to_test` (decision=TEST) and `watchlist`
(decision=WATCH) arrays and their counts are preserved byte-compatibly; `tier`, `tier_reasons`, `evidence_confidence`,
`evidence_fresh`, `roi_basis`, `ready_to_test_platinum`, `tier_counts`, `tier_policy` are **additive**.

Literal execution of the applied plpgsql `fn_opportunity_tier` / refined `fn_monday_top_opportunities` is confirmed by
a post-apply authenticated smoke test on founder approval (same pattern as mig_332/mig_333); the logic exercised above
is identical to the shipped function body.

## 6c. FINAL REVIEW (founder correction, 2026-11-07) — evidence-quality tightening + decision/band investigation

### A. Corrected PREMIUM floor (no promotion on score/band alone)
Per the founder: PREMIUM must require **a defensible, corroborated demand signal with source provenance and
sufficient freshness**; if evidence confidence is NONE and no independently-supported demand evidence exists, the
product is **UNTIERED**. `mig_334` `fn_opportunity_tier` was updated accordingly (the band-only path is removed):

- **`corroborated`** = `overall_evidence_confidence ∈ {MEDIUM, HIGH}` (the engine's own corroboration rollup).
- **`has_sourced_demand`** = at least one demand sub-signal (`buyer_search_intent` / `marketplace_validation` /
  `demand_momentum`) carries a named `source` (provenance). Computed in `fn_monday_top_opportunities` from `pme.evidence`.
- **`fresh`** = explicit `evidence_window` timestamp when present, else the evaluation snapshot time
  (`product_market_evaluations.created_at`), within a **45-day** horizon.
- **PREMIUM** now requires `band ≠ AVOID` **AND** `corroborated` **AND** `has_sourced_demand` **AND** `fresh`.
- **GOLD** additionally requires `corroborated + has_sourced_demand + fresh` (on top of validated local price,
  credible economics, suitable saturation, resolved supplier). **PLATINUM** additionally requires `has_sourced_demand`
  (it already required HIGH confidence + freshness). GOLD/PLATINUM commercial-readiness requirements are otherwise
  **preserved**; PLATINUM + TEST still gates Ready-to-Test; country isolation, honest UNKNOWNs, Product Asset Lock and
  tenant isolation all preserved. `tier_reasons` now also emits `demand_not_corroborated`, `no_sourced_demand_evidence`,
  `evidence_provenance_stale_or_absent` for transparency.

### B. Revised evaluation of the 8 recommendations (corrected rule; prod read-only)
| # | Product | Mkt | Decision | Band | Score | OverallEvid | Sourced demand | Fresh | **Tier (revised)** | Change |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | More Adventskalender 2026 | DE | WATCH | STRONG_TEST | 77.6 | MEDIUM | DataForSEO + eBay | yes | **PREMIUM** | — |
| 2 | ESN Designer Proteinriegel | DE | WATCH | WATCH | 49.7 | MEDIUM | DataForSEO + eBay | yes | **PREMIUM** | — |
| 3 | Beleuchtete Krippen | DE | WATCH | HIGH_CONFIDENCE_TEST | 87.0 | NONE | none | — | **UNTIERED** | ↓ was PREMIUM |
| 4 | Illuminated Snowman | GB | WATCH | TRENDING_WATCH | 56.0 | NONE | eBay only | — | **UNTIERED** | ↓ was PREMIUM |
| 5 | Makita Adventskalender | DE | WATCH | WATCH | 53.0 | NONE | eBay only | — | **UNTIERED** | — |
| 6 | Herren-Fleecejacke | DE | WATCH | WATCH | 48.0 | NONE | none | — | **UNTIERED** | — |
| 7 | Ankerkraut Adventskalender | DE | WATCH | AVOID | 22.7 | LOW | DataForSEO + eBay | yes | **UNTIERED** | — (band AVOID) |
| 8 | Hit the Slab | DE | WATCH | AVOID | 10.0 | NONE | DataForSEO | — | **UNTIERED** | — (band AVOID) |

**Revised distribution: 2 PREMIUM, 0 GOLD, 0 PLATINUM, 6 UNTIERED, 0 TEST → Ready-to-Test-Platinum EMPTY.**
The two high-score/no-corroboration products (Beleuchtete Krippen 87, Illuminated Snowman 56) correctly drop to
UNTIERED. Only the two products with MEDIUM engine-corroborated demand **and** named sources (DataForSEO search
intent + eBay marketplace validation) **and** recent evidence (26 days) remain PREMIUM.

### C. Investigation — `opportunity_band=AVOID` with `decision=WATCH`: INTENTIONAL, not a defect
Validated against the engine contracts (read-only), **engine not changed**:
- `fn_opportunity_band(score)` / the inline band in `fn_pod_evaluate` is a **pure score bucket** (score<40 → AVOID).
  The band is a score descriptor, **not** a decision.
- `fn_pod_evaluate` derives `decision` by an **ordered precedence** (lines 128–133): `has_fail`→AVOID;
  **`has_watch`→WATCH (`CANNOT_TEST_UNTIL_GATES_RESOLVE`)**; score NULL→WATCH; score≥70 ∧ conf∈{MEDIUM,HIGH}→TEST;
  score≥40→WATCH; else→AVOID. Because **`has_watch` is evaluated before the low-score→AVOID branch**, a low-scoring
  product whose readiness gates are still WATCH is held at **WATCH ("gather evidence"), not condemned to AVOID**.
- Confirmed in data: *Hit the Slab* (score 10, band AVOID, decision WATCH) has `decision_reasons =
  ["CANNOT_TEST_UNTIL_GATES_RESOLVE","BAND_AVOID",…]` and all six gates WATCH. The engine transparently records both
  the AVOID band and the reason the decision is WATCH.
- Engine contract note: *"Execution readiness gates ACTION, never the opportunity decision."* This is the documented,
  validated design (`pulse_product_opportunity_decision_v1`). **No engine decision is changed.**
- **Customer-facing clarification added** (Lovable copy): "Test / Watch / Avoid is decided on commercial-readiness
  evidence, not the raw opportunity score. A product with a low score can still show Watch — it is being held for more
  evidence, not rejected — and a high score never becomes Test until the readiness gates pass."

### D. Regression tests (read-only on prod data + synthetic; migration NOT applied)
Corrected predicates exercised exactly as shipped:
| Case | Expected | Got |
|---|---|---|
| High score (88) + band HIGH_CONFIDENCE_TEST + evidence NONE + no source | UNTIERED | **null** ✅ |
| MEDIUM conf + named source + fresh | PREMIUM | **PREMIUM** ✅ |
| MEDIUM conf + named source but **stale** (>45d) | UNTIERED | **null** ✅ |
| MEDIUM conf but **no source** | UNTIERED | **null** ✅ |
| GOLD (corroborated+sourced+fresh + local price + econ + sat + supplier) | GOLD | **GOLD** ✅ |
| PLATINUM (all + HIGH conf + sourced + fresh + decision TEST) | PLATINUM | **PLATINUM** ✅ |
| Same product DE PLATINUM vs **FR** (no corroboration) | country isolation | DE PLATINUM / FR **null** ✅ |
| AVOID-band / WATCH-decision consistency | WATCH held, band AVOID, untiered | confirmed ✅ |
| Real 8 recommendations | 2 PREMIUM / 6 UNTIERED / 0 GOLD / 0 PLATINUM | **matches** ✅ |

No cross-tenant access (SECURITY DEFINER scoped to `auth.uid()` via the wrapper, unchanged); stable canonical
`commerce_products.id`; honest UNKNOWNs preserved; no prod writes; no paid provider calls.

## 7. Guardrails honored
No new paid provider calls; Product Asset Lock, exact-SKU identity, country isolation, tenant RLS preserved; research
cost controls and commercial permissions untouched; nothing applied to prod and nothing published without founder
approval.

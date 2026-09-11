# PULSE-ECOM-SUPPLIER-BACKED-MULTI-PRODUCT-TOURNAMENT-001

**VERDICT: PASS — outcome B: NO QUALIFIED TEST OPPORTUNITY FOUND (correct honest rejection).**
The Supplier Product Asset Contract was exercised inside real opportunity discovery: a bounded pool of
real CJdropshipping catalog products was scanned as `SUPPLY_ONLY`, pre-filtered on supplier signals, then
demand-validated **independently** against real eBay market observations through the canonical identity
resolver. No candidate earned a qualified TEST; none was weakened to manufacture one. Founder-only —
**nothing published to Pulse customers**, no ads, no spend.

Founder preview (real CJ image URLs, stays in Claude):
`https://claude.ai/code/artifact/46ae915f-b8b1-4966-b6f0-36ef6cb04c88`

## Discovery funnel (tenant 7c8ddf9d, real)
| Stage | Count | Rule |
|---|---|---|
| CJ products scanned | **200** | bounded pool, deterministic order (`SUPPLY_ONLY`) |
| Pre-filtered survivors | **161** | usable primary image + supplier cost + active sale status |
| Rejected at pre-filter | **39** | no image / no cost / inactive |
| Market-validated | **9** | identity ∈ EXACT_PRODUCT / CLOSE_COMPARABLE vs real eBay demand |
| Rejected — no demand match | **152** | no product-identity match (category/keyword overlap never validates) |
| Product × Country evaluated | **2 families × GB** | compact makeup mirror, gua sha |
| READY_TO_TEST | **0** | — |
| WATCHLIST | **2** | held with explicit blockers |

Identity mix of the 9 survivors: **0 EXACT_PRODUCT · 9 CLOSE_COMPARABLE**. No exact supplier identity was
earned, so **no economics can be certified** — the exact-identity economics gate (mig_203) holds.

## Genuine defect found & fixed mid-scan (git rule #21: STOP → FIX → REGRESSION → RESTART)
The first scan pass reported **14** "validated" matches; **5 were false** — a short generic demand search
phrase matching a keyword-stuffed CJ title on generic category words alone:
- `"wooden desk organizer"` → *3D Printed Skull Eyeglasses Holder … Desk Organizer* (shared: `desk`,`organizer`)
- `"aluminium laptop stand adjustable"` → *Foldable Camping Table … Aluminium Adjustable* (shared: `aluminium`,`adjustable`)
- `"car back seat organizer"` → *… Car Back Seat Cover Organizer* (shared: `car`,`back`,`seat`,`organizer`)

Symmetric overlap cannot separate these from genuine comparables (projector↔projector, digital picture
frame↔digital photo frame): both sit at the same overlap statistics. The **only** honest discriminator is
the founder's own rule — the false matches share **only generic category / material / placement words**,
never a product-discriminating token. **mig_213** adds that requirement: CLOSE_COMPARABLE now needs
`overlap ≥ 0.5 AND ≥2 shared tokens AND ≥1 shared NON-GENERIC token`. (mig_212 had already removed an
earlier 0.34 single-token tier that produced false matches such as *pet water fountain* → *stainless-steel
necklace* and *watch winder* → *watch hands*.)

**Regression — 11/11 PASS.** Legit comparables preserved (projector, digital frame, gua sha → CLOSE_COMPARABLE);
generic-only matches rejected (skull organizer, pen holder, seat cover, camping table, pet/necklace,
watch/hands → UNRELATED); EXACT (shared identifier) and CATEGORY_MATCH tiers intact. **Acceptance restarted:**
re-run scan **14 → 9**, all 5 false matches dropped, every founder-accepted comparable kept.

## Tournament economics — real, honest, uncertified (EUR, GB, ECB FX 2026-09-10)
`contribution = market price − CJ cost − €15 ad reserve − CPA`. Target contribution €15–20.

| Family × GB | Identity | CJ cost | Comparable price | Listings | Contrib CPA €15 | Decision |
|---|---|---|---|---|---|---|
| Compact pocket makeup mirror (7 CJ variants, $0.58) | CLOSE_COMPARABLE | €0.50 | €40.73\* | 2,395 | +€10.23\* | **WATCH** |
| Gua sha — electric board ($12.19) | CLOSE_COMPARABLE | €10.49 | €6.93† | 774 | −€33.57 | **WATCH** |
| Gua sha — neck cream ($2.94) | CLOSE_COMPARABLE | €2.53 | €6.93† | 774 | −€25.61 | **WATCH** |

**\*** €40.73 is the observed price of **LED Hollywood vanity mirrors** (the 2,395-listing demand) — a
different, electronic sub-type. It is **not** a validated price for a €0.50 pocket compact mirror (which
sells for ~€2–5). The apparent +€10.23 is an artifact of cross-sub-type price attribution, exactly what the
LOCKED rule forbids, so economics for the real CJ product stay **UNKNOWN** and never justify a test.

**†** €6.93 is the "gua sha jade roller set" comparable (a different SKU). Even at face value it sits below
the electric board's landed cost and leaves no room for the €15 reserve; CPA €10/€15/€20 all land deeper
negative.

## Why 0 READY_TO_TEST is the correct outcome
Every survivor is blocked from TEST by canonical hard gates, on real evidence:
- **Supplier identity not EXACT** → economics uncertified (CLOSE_COMPARABLE cannot certify landed cost).
- **No validated same-product price** (mirror) / **negative economics** (gua sha) after the €15 reserve.
- **Stock UNKNOWN** — CJ list-level; never silently promoted to IN_STOCK.
- **High saturation** on the makeup-mirror category (2,395 listings).

The two families are retained as **WATCHLIST** (real supplier products with real *category* demand), each
with its blockers named. WINNER remains reserved for post-launch real performance.

## Image contract (Universal Supplier Product Asset Contract, exercised)
All 9 survivors: `PRODUCT_HAS_IMAGE` ✓ · `IMAGE_RESOLVED_BY_PULSE` ✓ · `IMAGE_RENDERABLE_IN_PULSE` ✓ ·
`IMAGE_RENDER_BLOCKED_ONLY_IN_CLAUDE` ✓. Images are the suppliers' own `SOURCE_PRODUCT_ASSET` URLs (EXACT
to the supplier product). The CJ host is outside Claude's artifact CSP allow-list, so it cannot paint inside
the sandbox — a **Claude-only** limitation that never determines Pulse's production asset architecture (which
caches assets into Pulse-controlled object storage).

## Production safety — before & after
`commerce_product_opportunities` = **0** · `daily_briefs` = **5 (unchanged)** · pre-existing paused Meta proof
campaign **untouched** (CREATED_PAUSED, campaign PAUSED) · `campaign_activation` = **FALSE** ·
`advertising_spend` = **0** · **no new n8n schedules** (Monday-only cadence + FX daily exception preserved).
The scan is read-only (`STABLE`); no customer-facing opportunity, brief, page, creative or campaign was
created. Overall paid-beta engineering readiness ≈ **84%** (unchanged).

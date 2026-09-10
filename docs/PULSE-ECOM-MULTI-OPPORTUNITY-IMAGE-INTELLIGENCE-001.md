# PULSE-ECOM-MULTI-OPPORTUNITY-IMAGE-INTELLIGENCE-001

**VERDICT: PASS.** The Monday experience is upgraded from one detailed opportunity to a **portfolio of the
strongest legitimate Product × Market opportunities**, each carrying a legitimate SOURCE product image
(or an honest IMAGE_UNAVAILABLE). Backend/contracts only — no Lovable UI in this unit. Nothing published
to the live customer workspace; no ads, no spend. The previous acceptance result (NO QUALIFIED TEST) is
unchanged.

## Product Asset Intelligence (mig_205 / mig_206)
- **`product_asset_intelligence`** — canonical SOURCE product image contract: product_id,
  supplier_product_id, source, source_url/ref, asset_type, **rights_state**, **identity_state**,
  match_class/confidence, **hero_eligible**, is_primary, observed_at, provenance.
- **`fn_resolve_product_image`** — resolves the best legitimate CJ supplier image, identity- and
  rights-aware. **hero_eligible requires identity_state = EXACT_PRODUCT + usable rights**; a
  CLOSE_COMPARABLE / CATEGORY image is shown only as labelled reference, never as the exact candidate.
  Competitor/marketplace creative is never resolved as a hero (SOURCE_PRODUCT_IMAGE only, kept separate
  from PULSE_GENERATED_CREATIVE in `media_assets`). Rights preserved (SUPPLIER_PROVIDED / OWNED /
  REFERENCE_ONLY / UNKNOWN); never fabricated.

## Portfolio selector (mig_207 / 207b)
- **`fn_monday_top_opportunities`** — one best-market row per product (rollup), **AVOID excluded**,
  quality-ranked (decision → validated-local-price → sweet-spot → saturation penalty → score), capped at
  the limit, **READY_TO_TEST separated from WATCHLIST**, each card reading the persisted primary image.
  Bounded discovery policy returned (stop on candidate exhaustion / max scan / sufficient portfolio);
  **fewer than the limit is allowed and no gate is lowered to fill slots**.

## Real founder preview (manual — NOT published)
Tenant 7c8ddf9d, limit 5 → **0 READY_TO_TEST · 4 WATCHLIST** (7 Product×Market rows scanned):
| # | Product | Country | Score | Sat | Price | Supplier | Image |
|---|---|---|---|---|---|---|---|
| 1 | kids nightlight projector | 🇫🇷 FR | 75.5 | MODERATE | €36.00 (LOCAL) | CLOSE_COMPARABLE | CJ comparable (labelled, not hero) |
| 2 | digital picture frame | 🇬🇧 GB | 74.6 | VERY_HIGH | £71.42 (LOCAL) | CLOSE_COMPARABLE | CJ comparable (labelled, not hero) |
| 3 | red light therapy led mask | 🇬🇧 GB | 89.6 | VERY_HIGH | UNKNOWN | unresolved | IMAGE_UNAVAILABLE |
| 4 | over door shoe organizer | 🇬🇧 GB | 67.4 | VERY_HIGH | UNKNOWN | unresolved | IMAGE_UNAVAILABLE |

**Quality beats popularity:** the highest raw score (red-light mask, 89.6) ranks **#3** — behind the
validated-local-price, lower-saturation projector (75.5) and digital frame (74.6). VERY_HIGH saturation
and missing local price are penalised, not rewarded. Every card names its country; saturation is
Product × Country scoped; the same product's other markets stay isolated (projector FR MODERATE vs US
VERY_HIGH).

## Tests — 24/24 PASS
Discovery continues past the first candidate · multiple candidates · up to 5 · fewer-than-5 allowed · no
weak fill · AVOID excluded · TEST/WATCH separated · country on every card · saturation Product×Country ·
market isolation · every image has provenance · comparable image cannot masquerade as EXACT (hero_eligible
false) · competitor creative never a hero (SOURCE_PRODUCT_IMAGE, source≠EBAY) · exact CJ image linked to
supplier identity · missing image honestly unavailable · source image ≠ generated creative (no
media_assets created) · rights preserved · quality > popularity · VERY_HIGH penalised · no TEST weakened ·
no WINNER · no customer publication (commerce_product_opportunities=0, daily_briefs unchanged) ·
campaign_activation FALSE · advertising_spend 0.

## Next
After founder approval of this data/asset/selection contract, the approved visual spec goes to **Lovable**
for the customer-facing frontend (Claude Code owns backend/contracts/evidence; Lovable owns the UI).
Overall paid-beta engineering readiness ≈ 84% (unchanged).

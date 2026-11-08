# New Product-Discovery Execution Plan (for founder approval) — 2026-11-08

Discover **entirely new** products with fresh, current, country-specific commercial signals, targeting GOLD/PLATINUM.
Read-only planning: **no paid calls made, no code deployed, no money spent.** Uses the existing Product Opportunity
Intelligence infrastructure + the existing Premium/Gold/Platinum rules unchanged. Return for approval before any
chargeable research.

## 1. Fresh research sources (authorised; from `discovery_lane_registry` + `discovery_provider_market_config`)
Autonomous product-native discovery:
- **KALODATA** — TikTok-Shop product ranking (`/openapi/v1/tiktok/product/rank`). AUTONOMOUS, DISCOVERY_CAPABLE,
  AVAILABLE. Verified live (DE): **0.1 credit / 10 products**. Of the 18 markets, covers: **US, GB, DE, FR, IT, ES, MY,
  PH, SG** (9).
- **FASTMOSS** — New-Listed TikTok-Shop ranking (`/product/v1/rank/newListed`). DISCOVERY-capable, AVAILABLE (DE
  verified). Of the 18: **DE, US, GB, ES, FR, IT, NL, BE, AT, PL, MY, PH, SG** (13).
- **DATAFORSEO** (SEARCH lane) — keyword search-demand discovery. AUTONOMOUS, AVAILABLE for **all 18** (each market has a
  `dataforseo_location_code`). Keyword volume is a *signal*, never a winner definition.

Validation / corroboration only (not product discovery):
- **META Ad Library** (ADVERTISING lane) — seeded, validates advertising emergence of a named candidate; full-coverage
  (ad intelligence) in DE, ES, FR, GB, IE, IT, NL.
- **DataForSEO + Reddit** (PROBLEM lane) — seeded need/problem discovery.
- **eBay Browse / marketplace** — competitor price + marketplace validation (reference only).
- **BLOCKED:** TikTok organic Research API (EXTERNAL_APPROVAL_REQUIRED) and AliExpress supplier (dormant). Not used.

## 2. Search strategy
- Drive the existing **autonomous discovery scope planner** (`ecommerce_discovery_scope` + lane registry) per market: pull
  fresh **Kalodata product-rank** + **FastMoss new-listed** pages (product-native, current), corroborated by
  **DataForSEO search-demand** for buyer intent. No manual product seeds — genuinely enumerated from live provider ranks.
- Category breadth: let each provider's rank return across categories; do not pre-bias to a category. Keyword volume and
  rank are **candidate signals only**; the engine decides opportunity.
- Every candidate is evaluated **independently per country** (the engine is already per product × country).

## 3. All 18 supported countries (country isolation enforced)
| Full coverage (1.00, incl. ads) | Product-native discovery | Search-demand only (no TikTok-Shop rank) |
|---|---|---|
| **DE, ES, FR, GB, IE, IT, NL** | US, GB, DE, FR, IT, ES, NL, BE, AT, PL, MY, PH, SG (Kalodata and/or FastMoss) | **AU, CA, CH, HK, IE** (DataForSEO + supplier/marketplace only) |

Full 18: AT, AU, BE, CA, CH, DE, ES, FR, GB, HK, IE, IT, MY, NL, PH, PL, SG, US. A product is evaluated per country; it
may qualify in one and not another. (Note: IE has full evidence + ads but **no** TikTok-Shop rank provider — discovered
there via search/supplier, not product-rank.)

## 4. How old products are excluded (canonical identity, not name)
- The existing resolver computes `fn_commerce_product_identity(url, platform_id, title, source)` →
  `url:<hostpath>` / `pid:<source>:<id>` / `name:<source>:<title>`; `ingest_commerce_product` already **dedups by this
  canonical identity**.
- Build the exclusion set = the **79 existing `commerce_products`** canonical identities (+ their resolved CJ supplier
  identities). Every freshly discovered candidate's canonical identity is checked against this set; **matches are dropped
  before scoring** (reliable identity match — URL/platform-id/identity string — never name-only comparison).
- Explicitly excludes the prior pilot items (kids nightlight projector `e453eed4…`, over-door shoe organizer `efca8b59…`)
  and all current recommendations.

## 5. New-product qualification rules (existing rules, unchanged — no invented metrics)
- Candidate enters only with a **real, fresh** per-country decision from `fn_pod_evaluate` (demand, growth, competition,
  seller saturation, pricing, advertising evidence — each evaluated independently per country). **Freshness: only
  evidence observed in this run counts**; cached market evidence is never used as proof of current demand (old supplier
  catalogue data may be reused for *matching* only, with freshness re-checked).
- Tier via the deployed `fn_opportunity_tier` (unchanged): **PREMIUM** = corroborated demand + source provenance + fresh;
  **GOLD** = + validated local price + credible supplier economics + suitable (LOW/MODERATE) saturation; **PLATINUM** = all
  six hard gates PASS + exact supplier + stock + landed-cost/margin + validated local price + **HIGH** evidence
  confidence + fresh + no open blocker. **Ready-to-Test = PLATINUM + decision=TEST.**
- No thresholds lowered, no incomplete product promoted. Realistic target of a first pilot: surface genuine **GOLD**
  candidates (saturation-suitable + corroborated demand); **PLATINUM also needs HIGH-confidence demand evidence**, which
  requires strong multi-source corroboration in-run.

## 6. Exact-SKU supplier matching (promising products first, then suppliers)
For each promising candidate (post-scoring), resolve the exact supplier via the existing chain: CJ identity-preserving
search → `fn_resolve_concrete_supplier_identity` / `fn_resolve_cross_supplier_identity` → `fn_validate_bound_supplier_identity`
→ store exact CJ PID + SKU + variants. **Reuse the cached CJ catalogue (1317 rows) for matching first** (free), fetching
live CJ detail only when no fresh cached match exists. No substitution — if no exact CJ match, the product stays research.

## 7. Media & readiness verification
- CJ detail → authentic **SUPPLIER_PROVIDED** images/video (rights-cleared), variants, **live stock**, **destination
  shipping/freight**, supplier cost → **landed cost + margin** via `fn_resolve_supplier_economics` / `fn_economics_breakeven`.
- Preserve source provenance + freshness; **Product Asset Lock** unchanged (reference/marketplace media never launch-safe);
  commercial media rights recorded; country isolation enforced.

## 8. Expected provider calls + costs
Provider calls are **call-metered** via the approval-gated `provider_call_budget`; CJ catalogue/detail reads record **no
per-call USD** (CJ bills on fulfilled orders, which this does not place).
| Stage | Unit cost | Pilot volume (3 markets) | Est. |
|---|---|---|---|
| Kalodata product-rank | 0.1 credit / 10 products | ~5 calls/market → ~50 products/market | ~1.5 credits |
| FastMoss new-listed | ~1 call / rank page | ~3 calls/market | ~9 calls |
| DataForSEO search-demand validation | ~$0.15 / run | ~2 runs/market | ~$0.90 |
| CJ supplier match + detail + variant + freight (top candidates only) | call-metered, ~$0 direct | ~6 calls × up to 5 candidates | ~30 CJ calls |
| Local price validation (promising only) | ~$0.15 / run | ~5 runs | ~$0.75 |

**Estimated pilot direct cost ≈ $1.65 USD + ~1.5 Kalodata credits + ~40 call-metered CJ/FastMoss calls.** (Kalodata
credit→USD rate to be confirmed by founder; the 0.1-credit/10-products unit is the only in-system evidence.)

## 9. Bounded pilot design (for approval)
- **Markets (3):** **DE, GB, US** — strongest discovery coverage (Kalodata + FastMoss + DataForSEO; DE full 1.00). (Can
  extend to ES/FR/IT/NL in a second wave.)
- **Lanes:** Kalodata product-rank + FastMoss new-listed (product-native) + DataForSEO demand validation.
- **Candidate cap:** ≤ 50 freshly-discovered candidates per market (≤150 total) → dedup vs the 79 existing identities →
  engine-scored per country → take the **top ≤5 GOLD/PLATINUM-looking** (saturation-suitable + corroborated demand) for
  supplier + media verification.
- **Hard caps (one `provider_call_budget` per provider/market, short expiry):** Kalodata **≤ 2 credits**; FastMoss **≤ 15
  calls**; DataForSEO/research **≤ $3.00**; CJ **≤ 40 calls**; **no orders, no ads, no billing, no AliExpress.**
- **Stop conditions:** candidate cap reached, budget cap reached, or no new-identity candidates remain.

## 10. Safest execution sequence (on approval, within caps)
1. One market first (**DE**, fully verified providers): run Kalodata + FastMoss + DataForSEO discovery → dedup → score →
   report the fresh candidate set + any GOLD/PLATINUM-looking ones, **before** spending on the other markets.
2. For the top DE candidates only: CJ exact-SKU + media + economics verification; re-evaluate vs the rules.
3. Expand to GB then US on the same pattern. Re-run acceptance (country isolation, exact-SKU, PAL, no fabricated claims)
   and report GOLD/PREMIUM outcomes with evidence before any further spend.

## Guardrails
No money spent, no production data modified, no deploy, no advertising/billing/signup. Fresh evidence only (no cached
demand as current proof); exact-SKU identity, country isolation, tenant security, media rights and Product Asset Lock
preserved; existing engine + tier rules unchanged. Execution is gated on this approval + the capped budgets.

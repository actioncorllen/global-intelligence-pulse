# Bounded Supplier-Sourcing Readiness Plan (for founder approval) — 2026-11-08

Read-only analysis of the existing CJ Dropshipping cache + opportunity evidence. **No paid calls made, no production data
modified, no deploy.** Uses the existing engine + Premium/Gold/Platinum rules unchanged. Presented for approval before any spend.

## Honest headline findings (why the shortlist is small)
1. **CJ cache = 1317 products**, all with image/SKU/shipping, 1061 with cost — but deep enrichment (variants, live
   stock, video, rights) exists for only **6** and is **fresh (<45d) for 1**. Basic sourcing data is broad; current
   commercial-grade enrichment is thin and stale.
2. **GOLD needs saturation to already pass** (LOW/MODERATE) + corroborated (≥MEDIUM) demand. Across the whole
   catalogue, **exactly one (product × country) meets that today: _over door shoe organizer — IT_.** The other
   high-demand generic products (cool mist humidifier, red light mask, digital picture frame, kids nightlight) are
   **VERY_HIGH / HIGH saturation** in their markets — the gate correctly blocks GOLD, and **sourcing cannot fix
   saturation.**
3. **PLATINUM is unreachable by sourcing** for any product now: PLATINUM requires HIGH demand-evidence confidence, and
   **no product exceeds MEDIUM.** Raising that needs more/better demand evidence, not supplier data. So the realistic
   target of this spend is **GOLD (one candidate) + a fully-imaged PREMIUM showcase proof (one candidate)** — not PLATINUM.
4. The branded EU-retail items currently shown as recommendations (More Adventskalender, ESN, Makita, Ankerkraut) are
   **not in CJ's dropshipping catalogue** — not sourceable from CJ; excluded.

## Shortlist (2 genuinely sourceable candidates)

### Candidate 1 — Primary GOLD attempt: **over door shoe organizer** (`efca8b59-d814-404b-be1b-65e833fab9b8`)
- **Recommended country: IT** (STRONG_TEST, score 72.0, evidence **MEDIUM**, **saturation gate PASS**). The *only*
  GOLD-reachable product×country in the catalogue.
- **CJ identifier: none yet** — not in the CJ cache (closest cached row is a floor shoe *rack*, a different product —
  not used, would be substitution). Requires a fresh CJ identity-preserving search to find + bind the exact over-door
  organizer, if CJ carries it.
- **Verified:** demand (MEDIUM, country-isolated to IT), acceptable saturation. **Missing:** exact CJ supplier identity,
  variants, stock, IT shipping, landed cost + margin, validated local IT price. **Stale:** n/a (nothing sourced yet).
- **Media/rights:** current images are eBay marketplace (reference-link-only, no display rights). CJ images, once bound,
  are SUPPLIER_PROVIDED (rights-cleared for display).
- **To reach GOLD (existing rules):** corroborated demand ✓ → add validated local IT price (market_price gate PASS) +
  credible landed cost/margin (economics gate) + exact CJ supplier + resolved variants + stock, saturation already ✓.
  Risk: **exact CJ match is uncertain** — over-door fabric organizers may not have a clean CJ identity; if no exact
  match, it stays research (we will NOT substitute a different product).

### Candidate 2 — PREMIUM showcase proof (already CJ-identified; cheapest path to a real imaged card)
**kids nightlight projector** (`e453eed4-3de4-4ed9-b889-1275c13c0dba`)
- **CJ identifier: PID `2608250310481611400`, SKU `CJYD3093228`** ("USB Projection Lamp"), supplier cost **$5.73 USD**.
  Already has **12 rights-cleared CJ SUPPLIER_PROVIDED images** ingested.
- **Recommended countries: GB (78.2), DE (73.2), US (73), FR (70.9)** — all STRONG_TEST, **MEDIUM** evidence.
- **Verified:** exact CJ identity, authentic rights-cleared images, corroborated multi-country demand. **Stale:** CJ
  enrichment is from 2026-09-05 (~2 months) — cost/stock/shipping need a refresh. **Missing:** live stock, destination
  shipping/freight, landed cost + margin, validated local price.
- **Reachable tier: PREMIUM only — NOT GOLD/PLATINUM** (saturation VERY_HIGH/HIGH in every one of its countries blocks
  GOLD; the gate is correct). **Value:** it is the one product that can become the **first fully-imaged card in the
  Premium showcase** (its CJ images make `showcase_eligible=true`), proving the end-to-end premium experience with
  authentic supplier imagery — without claiming GOLD.

## Required additional provider calls + estimated charges
Cost model (verified in-system): CJ calls are **metered as call-count** through an **approval-gated
`provider_call_budget`** (per user + market + provider, with `max_calls`, `approval_key`, expiry). The system records
**no per-call USD** for CJ — CJ's catalogue/detail/variant/freight queries are standard-tier API reads (CJ bills on
**fulfilled orders**, which this plan does **not** place). So expected **direct charges ≈ $0**; the real control is the
**call-count cap** + rate limits. Any local-price validation via the research/DataForSEO path is separately budgeted
(research worst-case ≈ **$0.15/run**, currently disabled).

| Step | Candidate 1 (shoe organizer, IT) | Candidate 2 (kids nightlight refresh) |
|---|---|---|
| CJ identity search (paginated) | 1–3 calls | 0 (already bound) |
| CJ product detail (variants/images/desc) | 1 | 1 (refresh) |
| CJ variant inventory / stock | 1 | 1 |
| CJ freight/shipping to destination(s) | 1 (IT) | 1–4 (GB/DE/US/FR) |
| Local price validation (research path) | 1 run (~$0.15) | optional, 1 run (~$0.15) |
| **Subtotal** | **~4–6 CJ calls + 1 price run** | **~3–6 CJ calls + optional price run** |

**Total worst case: ~12 CJ catalogue calls + 2 price-validation runs (~$0.30 USD direct).**

## Proposed maximum spending cap (for approval)
- **CJ call cap: 20 calls** (one `provider_call_budget` per market, `provider=CJDROPSHIPPING`, short expiry) — comfortably
  covers both candidates with retries; hard-stops at 20.
- **Research/price-validation cap: USD $2.00** (≈13 runs at $0.15) — covers IT + the nightlight markets with margin.
- **No order placement, no fulfilment, no ads, no billing, no AliExpress** (dormant/approval-required).

## Safest next execution sequence (on approval)
1. **Candidate 2 first (lowest risk, already identified):** refresh CJ detail/variant/stock + freight for 1 market
   (e.g. GB) for kids nightlight; recompute economics; confirm it surfaces as a **PREMIUM showcase card with authentic
   CJ imagery**. Proves the full pipeline end-to-end at ~3–4 calls. (Will not become GOLD — saturation.)
2. **Candidate 1 (the GOLD attempt):** run the CJ identity-preserving search for the over-door organizer. **If** an exact
   match is found → resolve identity, ingest detail/variants/stock/IT freight/images, validate IT local price, recompute.
   Re-evaluate against the GOLD rule. **If no exact CJ match → stop, keep it in research, no substitution.**
3. Re-run the acceptance checks (country isolation, PAL, exact-SKU, no fabricated claims) and report GOLD/PREMIUM outcome
   per candidate with evidence, before any further spend.

## Guardrails
No money spent, no production data modified, no deploy, no advertising. Existing engine + Premium/Gold/Platinum rules
unchanged. Exact-SKU identity, country isolation, tenant security, media rights and Product Asset Lock preserved. Any
execution is gated on this approval + the capped `provider_call_budget`.

# STAGE 1 — FastMoss Product-Native COMMERCE Discovery Adapter (2nd provider)

**Date:** 2026-10-12 · **Project:** nxaunmyihhjixxxljcqt (live prod) · **Branch:** claude/cool-faraday-kgudh1
**Scope:** FastMoss New Listed as a SECOND independent product-native provider in the existing COMMERCE lane,
reusing the Kalodata-established patterns. No redesign. Stage 2 NOT started.

## 1. Capability / provider roles
FastMoss New Listed = early/new product-native discovery; Kalodata = product-native + momentum evidence;
Strateloq = qualification/decision. FastMoss discovers candidates only; it never auto-qualifies.

## 2. Date-contract correction (root cause + fix)
The New Listed request builder originally derived `date_info.value` as **yesterday** (UTC); the FastMoss
contract requires **3 days ago** (`YYYY-MM-DD`). Fixed in `fn_fastmoss_discovery_request`: offset
centralized as `v_offset_days=3` and exposed as an explicit invariant `date_offset_days` (request contract
`pulse_fastmoss_request_v2`) so it cannot drift back; never a hardcoded date. Regression check
`19_DATE_CONTRACT_3_DAYS_AGO` asserts `date_offset_days=3` and value = (UTC today − 3). Verified live:
request date `2026-10-09`. No other provider touched.

## 3. Files / migrations
- `mig_378a` — 20 FastMoss regions (data-driven; IE excluded).
- `mig_378b` — `fn_fastmoss_discovery_request` (3-days-ago contract), `fn_is_branded_or_ip_sensitive`,
  `fn_fastmoss_record_lane_outcome`, multi-lane plan v3 (additive `commerce_providers`).
- `mig_378c` — `fn_fastmoss_ingest_candidates`.
- `mig_378d` — `fn_fastmoss_run_discovery`.
- `mig_378e` — `fn_fastmoss_commerce_adapter_selftest` (19 invariants).
- `supabase/functions/fastmoss-discovery/index.ts` — secure broker (ACTIVE; Bearer; env secret only;
  nonce + service-role gated; fail-closed; redacting).

## 4. FastMoss provider contract
`POST https://openapi.fastmoss.com/product/v1/rank/newListed`, `Authorization: Bearer <client_secret>`.
Body `{filter:{region, date_info:{type:"day", value:<UTC today − 3>}}, orderby:[{field:"day3_units_sold", order:"desc"}], page:1, pagesize:10}`.

## 5. Security/secret status
`FASTMOSS_CLIENT_SECRET` installed by founder; lives only in the Edge Function env; never in
DB/frontend/logs/errors/migrations/tests/fixtures. Backend probe: `secret_present = true`.

## 6. Market-support configuration
20 FastMoss regions supported+enabled; **IE → UNSUPPORTED_MARKET** (not substituted); country isolation enforced.

## 7. Normalization mapping (UNKNOWN→NULL)
product_id→provider id/dedup · title→product_identity · region→market · real_price→price/observed_price ·
day3_units_sold→sales_units · day3_gmv→revenue · total_units_sold/total_gmv/commission_rate→evidence ·
seller→separate seller evidence · category→evidence · cover→reference media only · **launch_time→RAW only,
never first_seen**.

## 8. Identity / dedup / IP
Idempotent dedup by `fastmoss_product_id`; country-isolated normalized-family correlation keeps sellers as
separate evidence; branded/IP → `BRANDED_OR_IP_REVIEW` (held, fail-closed). Correlation/cross-provider
agreement enriches evidence only.

## 9. Regression results
`fn_fastmoss_commerce_adapter_selftest` = **19/19 all_pass**. Existing suites green: Kalodata 17/17,
multi-lane 16/16, research bridge 8/8, Stage-1 invariants 8/8, image 10/10, autonomous 12/12.

## 10. Real DE production run (ONE bounded call; discovery run `5c2ede62-0688-438c-afc3-68ee81987748`)
- Request date used: **2026-10-09** (3 days ago). FastMoss provider calls consumed: **1**.
- Lane outcome: **SUCCESS_WITH_CANDIDATES**. Products returned: **10** (10 distinct provider ids; all DE).
- Qualified (product-native gate): 10. Rejected: 0. **Branded/IP held: 4** (2× Pokémon boosters, 2×
  reisenthel carrybag). **Eligible generic auto-dispatched: 6**. Correlated: 0. Idempotent: 0.
- Product IDs → names: 1729948374291814880 AiryBare Soft-Magnetic Wimpernset · 1729904172727703590
  "Praktisch für unterwegs…" · 1729907499745384637 Herren-Fleecejacke · 1729882714932942908 ABS
  automatisches Katzenspielzeug · 1729937925462923841 Beleuchtete Krippen Wanddekoration ·
  1729933862317299919 1PC erweiterbares Mikrowellen-Lagerhalter · (held) 1729815094138018351 Pokemon
  Celebrations Booster · 1729695883069856303 Pokemon Mega-Entwicklung Booster · 1729948765705706283 &
  1729948736859838949 reisenthel carrybag XS.
- Research runs (6, generic only): `7a0fcffb…`, `769b5ee7…`, `5ce045e8…`, `82cd80c0…`, + 2; 2 COMPLETE,
  4 INSUFFICIENT_EVIDENCE. Source outcomes: CJ 2 found/4 none; DataForSEO/eBay/Meta/Reddit/TikTok 0 found.
- Concrete resolution: attempted for the 6 → 6 DE `product_market_evaluations`; none reached a
  benchmark-qualified CONCRETE_RESOLVED (all gates WATCH).
- Opportunity evaluation: **all 6 WATCH / INSUFFICIENT** (evidence NONE; blockers: local price unvalidated,
  supplier stock/economics/compliance/fulfilment unknown, saturation fail-closed). FastMoss sales/GMV/
  newness did not auto-qualify; branded held; images irrelevant; UNKNOWN stayed UNKNOWN.
- FastMoss↔Kalodata cross-provider correlation found: none this run (the two near-identical reisenthel
  records differ by a trailing "[Y]" tag → distinct normalized family keys; both held as branded anyway).

## 11. Provider usage / calls consumed
**1 live FastMoss call** (the single bounded DE run). Regression used fixtures/dry-run. Trial quota respected.

## 12. FASTMOSS ADAPTER verdict
**PASS_FASTMOSS_COMMERCE_ADAPTER** — real production path verified end-to-end (DE → New Listed → normalized
→ gate → branded/IP → identity/dedup+seller evidence → eligibility → auto_fresh_discovery → deep research →
concrete resolution → evaluation).

## 13. OVERALL STAGE 1 verdict
**BLOCKED_STAGE_1_PRODUCT_OPPORTUNITY_INTELLIGENCE** — no genuinely newly discovered product reached
CONCRETE_RESOLVED + benchmark-qualified; all FastMoss (and prior Kalodata) candidates are
WATCH/INSUFFICIENT with honest evidence gaps. No gate weakened. Stage 2 not started.

## 14. Exact remaining blocker (evidence, not secret)
Candidates clear discovery but fail qualification on insufficient country-local evidence: local-market
price not validated, supplier economics/stock unknown (Stage-2 territory), competition/saturation
fail-closed, and most research sources returned no evidence for these DE new-listed items. Reaching a
Stage-1 PASS needs a discovered product with sufficient real DE evidence to clear the existing thresholds
(unchanged) to CONCRETE_RESOLVED.

# PULSE-ECOM-DIFFERENTIATED-PREMIUM-OPPORTUNITY-001

**VERDICT: PASS. OUTCOME: B — no HIGH-CONFIDENCE TEST.**
The early differentiation screen worked exactly as intended: it surfaced genuinely superior commercial
shapes (LOW/MODERATE saturation, high ceilings, defensible desire, non-commodity). But every
differentiated premium concept that cleared demand + economics + differentiation **failed on exact CJ
supply at a viable cost tier**. The recurring structural finding is now decisive: **CJ supplies commodity
goods abundantly but is thin on differentiated premium products at consumer cost.** This is the
evidence-based case for **SUPPLIER_2_JUSTIFIED** (recommendation for founder decision; not auto-integrated
per unit constraints). No store/ads/campaign/spend.

## 1. Markets screened
US (weighted, no VAT), GB, DE — via `ecommerce_market_universe`; claims evidence-gated.

## 2. Concepts discovered (28 differentiated premium)
phone gimbal, golf rangefinder, portable/castable fish finder, cordless tire inflator, OBD2 scanner,
automatic laser cat toy, dog GPS tracker, smart pet treat dispenser camera, nitro cold brew maker, phone
teleprompter, bike radar tail light, roll-up piano, smart flame humidifier, electric wine preserver, smart
bird feeder camera, phone thermal camera, inspection endoscope, precision screwdriver set, laser tape
measure (+ GB/DE variants). First-beta risk filter applied.

## 3–6. Demand / Buyer Intent / price identity
Real eBay Browse medians (exec 30153). PRICE_IDENTITY enforced per concept (§11) to avoid the dash-cam
blended-median error. Buyer Intent (DataForSEO) reserved for finalists — funnel terminated at supply before
finalists needed it.

## 7–10. Saturation & economic ceilings (US no-VAT favourable)
| Concept × Country | ASP € | Ceiling € | Saturation | Differentiation |
|---|---|---|---|---|
| thermal imaging camera (phone) × US | 154.10 | **111.77** | MOD (1,202) | STRONG |
| nitro cold brew maker × US | 86.04 | **49.16** | **LOW (201)** | STRONG |
| golf rangefinder × US | 74.89 | 38.90 | HIGH (14,420) | WEAK (brand) |
| angeln echolot × DE | 83.99 | 33.86 | LOW (233) | PROMISING |
| bike radar tail light × US | 66.11 | 30.82 | LOW (503) | WEAK (Garmin) |
| phone teleprompter × US | 64.57 | 29.40 | LOW (240) | PROMISING |
| roll-up piano 88-key × US | 61.54 | 26.62 | LOW (133) | PROMISING |

## 11. Pre-supplier survivors (differentiation + economics + saturation)
Commodity/brand-dominated traps deprioritized (§5): golf rangefinder (HIGH sat, Bushnell/Nikon), OBD2
(VHIGH sat), tire inflator (commodity), phone gimbal (DJI), bird feeder (bulky/HIGH). **Top differentiated
survivors sent to CJ: nitro cold brew maker, phone teleprompter, phone thermal camera, roll-up piano.**

## 12–17. CJ categories, category-scoped discovery, list-level survivors
Provider-native `getCategory` + category-scoped `product/list` (execs 30154–30155):
| Concept | CJ category | STRONG | Reality |
|---|---|---|---|
| nitro cold brew maker | Kitchen Appliances / Barware | **0** | **0 titles contain "nitro"/"cold brew"** — differentiated feature absent from CJ |
| phone teleprompter | Photo Studio / Camera&Photo | 1 | only match **$97.59** (cost €84 ≫ €29.40 ceiling) — economically dead |
| phone thermal camera | Measurement&Analysis / Camera&Photo | 1* | returned **industrial machine-vision lenses + 1 pro imager (UNI-T, ~1 kg, no consumer price)** — no consumer phone-thermal |
| roll-up piano | Musical Instruments | 5 | STRONG exist but **$35+/1.7 kg+** (cost €30.4 > €26.62 ceiling, heavy) |

## 18. Identity
`fn_market_supplier_match` (title-scoped, mig_221) applied. No fuzzy EXACT. The classifier correctly refused
to promote generic cold-brew carafes to "nitro", accessories to "teleprompter/piano", or industrial lenses
to "thermal camera" — 0 false positives.

## 19–31. Feature fit / stock / freight / landed economics
Not reached: **no differentiated concept produced a SUPPLIER_EXACT candidate at a viable cost tier**, so no
concept earned stock/freight enrichment (reverse-sourcing discipline; §17 list-level rejection: supplier
cost > ceiling, or subtype/feature absent). The one commodity product that fully passed supply+stock+freight
this arc (dash cam × US) was rejected in the prior unit at WPS 79.

## 32. Community / 33. Competitor evidence
Community pass (§24) reserved for finalists reaching supply/economics; none did, so no community calls spent
(§33 cost control — do not deep-validate failed candidates). Competitor/saturation captured at screen level
(eBay density + brand observation).

## 34–38. Evidence breadth / WPS / confidence / sweet spot / tournament
No finalist reached WPS scoring — all differentiated candidates terminated at the **supply gate** before
identity/stock/economics could complete. No Product×Country qualifies. Strongest *commercial shape* was
**nitro cold brew maker × US** (LOW sat, €49 ceiling, viral-demonstrable, no dominant brand) — but **CJ has
no nitro maker**, so it cannot be tested via CJ.

## 39–41. Final tournament / strongest / HIGH-CONFIDENCE gate
No HIGH-CONFIDENCE candidate. HIGH-CONFIDENCE gate not reachable — fails at SUPPLIER_EXACT / viable-landed
for every differentiated concept.

## 42. Outcome
**B.**

## 43. Funnel counts
28 concepts priced → ~7 cleared economic ceiling ≥ €15 → 4 passed the differentiation + non-commodity +
low-saturation screen (nitro, teleprompter, thermal, roll-up) → 4 sent to CJ category discovery → **0 with
exact CJ supply at a viable cost tier** → 0 identity survivors → 0 stock → 0 TEST.

## 44. Binding bottleneck (quantitative)
**DIFFERENTIATED_SUPPLY_CATALOGUE_GAP.** Across 4 economically-viable, low-saturation, differentiated
concepts: nitro = 0 exact (feature absent); thermal = 0 consumer-tier (only industrial/pro); teleprompter =
1 exact but cost €84 vs €29 ceiling; roll-up piano = exact but €30.4 cost / 1.7 kg vs €26.62 ceiling. The
intersection Pulse needs — **differentiated + premium + low-saturation + viable economics + exact CJ supply +
in-stock** — is **empty in CJ's catalogue**. CJ yields either commodity (saturated, e.g. dash cam) or nothing
(for differentiated premium).

## 45. Supplier verdict — **SUPPLIER_2_JUSTIFIED** (recommendation; not auto-integrated)
The §32 criterion is now met: strong demand + economics + differentiation + low saturation **repeatedly**
pass, and CJ **repeatedly** fails specifically on **catalogue** (differentiated product absent or only at a
cost tier that erases margin) — not on Pulse's economics or identity engineering. This holds across this unit
(nitro/thermal/teleprompter/piano) and earlier units (levitating moon lamp, wifi photo frame, smart herb
garden all lacked viable exact CJ supply). The commodity products CJ *does* stock are brand-saturated
(dash cam → WPS 79). Recommend the founder authorize evaluating **supplier #2** (e.g. AliExpress/BigBuy),
whose catalogues carry these differentiated premium SKUs at consumer cost tiers. **Not integrated here** per
unit constraints — this is the evidence to support that decision.

## 46–47. API / query counts & costs
eBay: 1 auth + 28 searches (30153). CJ: getCategory reused; 1 auth + 6 category list (30154) + 1 auth + 3
category list (30155). DataForSEO: 0 (finalists never reached buyer-intent stage). CJ detail/stock/freight: 0
(no viable supply survivor). Supabase: reads + 28 inserts. CJ quota healthy (~2,600/50,000). €0 infra.

## 48. Bugs / fixes
None. Classifier (mig_220/221) held: 0 false positives across nitro/teleprompter/thermal/piano.

## 49. External blockers
None. eBay + CJ returned real data; quotas healthy.

## 50. Campaign safety
No store/publication/Ad Studio/campaign/activation. Paused Meta proof campaign untouched.
`campaign_activation = FALSE`.

## 51. Advertising spend
`advertising_spend = 0`.

## 52. Tests
28 real price observations; differentiation screen applied pre-enrichment; category-scoped discovery
classified with subtype/attr precision (0 false positives); economics computed US no-VAT; PRICE_IDENTITY
enforced.

## 53. Git
Report doc committed; no schema/code change. Secret-scanned, pushed to `claude/pulse-crash-recovery-b6ngey`;
remote == local, divergence 0 0.

## 54. Paid-beta readiness
≈ **88%** (unchanged): the discovery/differentiation/economics/identity pipeline is complete and trustworthy.
The remaining blocker to a differentiated HIGH-CONFIDENCE TEST is **supplier catalogue coverage**, now
evidence-established — not Pulse engineering.

## 55. EXACT NEXT ACTION (for founder approval — not executed)
**Authorize a bounded supplier #2 evaluation** (AliExpress or BigBuy) — a read-only capability probe mirroring
the CJ chain (category/keyword discovery → canonical identity → stock → freight), tested against the exact
differentiated survivors that CJ lacked (**nitro cold brew maker**, **phone teleprompter**, **phone thermal
camera**, **roll-up piano**). If supplier #2 supplies these at viable cost + stock, re-run this differentiated
funnel to a HIGH-CONFIDENCE decision. If the founder prefers to stay CJ-only, the fallback is to accept the
**dash cam × US STRONG_TEST** (WPS 79) with a higher-spec variant. Supplier #2 remains a **recommendation**,
not an automatic integration.
